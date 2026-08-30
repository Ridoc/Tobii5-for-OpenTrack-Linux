// tobii_filter.zig — Tobii "Extended View"-style filtering pipeline for the
// OpenTrack bridge.
//
// Replicates the OEM Tobii feel without a separate OpenTrack filter stage:
//   - 3-state dynamic EWMA gaze filter (fixation / smooth pursuit / saccade),
//   - neck-pivot head-rotation approximation from the eye-origin midpoint,
//   - velocity-adaptive (Accela-style) smoothing, time-corrected per frame,
//   - Tobii 85/15 head/eye blend,
//   - non-linear response curve (linear / power / Tobii spline),
//   - preset persistence (JSON in $XDG_CONFIG_HOME/tobiifree-opentrack).
//
// Math follows the OEM defaults: gaze edge angle ±20° (±15° pitch), head
// sensitivity 2.0, roll 1:1 (unavailable here → 0), position doubled, center
// stabilization deadzone 0.10–0.20°, adaptive retention 0.90 at rest down to
// 0.05 at 180°/s flicks.

const std = @import("std");
const core = @import("tobiifree_core");

pub const CurveMode = enum(u8) {
    linear = 0,
    power = 1,
    tobii = 2,
};

pub fn curveModeName(m: CurveMode) []const u8 {
    return switch (m) {
        .linear => "Linear",
        .power => "Power",
        .tobii => "Tobii",
    };
}

pub const SmoothMode = enum(u8) {
    accela = 0,
    one_euro = 1,
    none = 2,
};

pub fn smoothModeName(m: SmoothMode) []const u8 {
    return switch (m) {
        .accela => "Accela",
        .one_euro => "One Euro",
        .none => "None",
    };
}

/// All tunable parameters. `curve_mode` is stored as u8 so it round-trips
/// cleanly through JSON (0=linear, 1=power, 2=tobii).
pub const Preset = struct {
    name: []const u8 = "tobii-official",
    max_yaw: f64 = 180.0, // output cap, yaw °
    max_pitch: f64 = 90.0, // output cap, pitch °
    gaze_scale: f64 = 40.0, // gaze → yaw ° at screen edge
    gaze_scale_pitch: f64 = 30.0, // gaze → pitch ° at screen edge
    smoothing: f64 = 0.90, // rotation rest retention (Accela-style, heavy)
    pos_smoothing: f64 = 0.95, // translation rest retention (heavier)
    deadzone: f64 = 0.15, // ° yaw/pitch deadzone
    head_gain: f64 = 2.0, // head-sensitivity multiplier
    eye_ratio: f64 = 0.15, // gaze contribution to rotation (OEM 85/15)
    pitch_gain: f64 = 1.0, // extra pitch input multiplier (X4 pitch is weak)
    pos_gain: f64 = 2.0, // translation multiplier
    neck: f64 = 13.0, // cm from neck pivot to eye plane
    curve_mode: u8 = 2, // CurveMode.tobii
    curve_exp: f64 = 0.5, // power-mode exponent (<1 expands edges)
    smooth_mode: u8 = 1, // SmoothMode.one_euro
    flip_yaw: bool = false,
    flip_pitch: bool = false,
    send_position: bool = true,
    pre_curve_dz: f64 = 0.02, // ° pre-curve deadzone (kills smoother noise before Catmull-Rom amplifies it)
    eye_ratio_core: f64 = 0.80, // eye_ratio at screen center (eyes dominate)
    core_zone_radius: f64 = 0.10, // gaze_dev radius for core zone (normalized 0–1)
    // Phase 2A: error-map-derived gaze correction (v0.2.1). Controlled
    // capture (2026-08-22, 11 dumps) showed the device reads gaze-y LOW by a
    // linear map: device_y = 1.278·y_true − 0.394  →  y_true = (y_raw + 0.394)
    // / 1.278. At center this was 0.245 instead of 0.5 — a +7.5–11.5° phantom
    // pitch that pinned the view up all session and blocked rest-follow
    // (window ±4°). The map was fitted on the reliable points (center×2,
    // bottom_edge, BR, BL-y); the "plane geometry mismatch" hypothesis was
    // tested and FALSIFIED (no eye+plane explains the readings — the device's
    // ray estimation itself is biased, growing with gaze elevation, and the
    // top 31% of the screen is unreadable → garbage at corners).
    gaze_y_offset: f64 = 0.394, // additive correction: y_true = (y_raw + off)/scale
    gaze_y_scale: f64 = 1.278, // multiplicative correction (>=0.1)
    // v0.2.6: X-axis affine correction (fitted by the calibration wizard,
    // overlaid from calibration.json — see main.zig applyCalFit).
    gaze_x_offset: f64 = 0.0, // additive correction: x_true = (x_raw + off)/scale
    gaze_x_scale: f64 = 1.0, // multiplicative correction (>=0.1)
    // v0.2.6: device display area = physical screen × this factor (expanded
    // track box). Raw device gaze coords are normalized to the EXPANDED area;
    // the pipeline converts them to physical-screen normalized coords BEFORE
    // applying the affine correction, so GUI viz and UDP output agree.
    track_box_factor: f64 = 2.5,
};

pub const BUILTIN_PRESETS = [_]Preset{
    .{
        .name = "tobii-official",
        // Clean OEM-style defaults, closest to Tobii's own head-tracking:
        // Tobii spline curve, wide 180°/90° caps, 2× head gain, 15% gaze lead.
        // Direction: interocular atan2(ez, ex) yields POSITIVE yaw on a
        // head-LEFT turn (verified in trace), which is opposite to X4's
        // expectation (head-left = negative yaw), so flip the whole yaw
        // signal (head AND gaze — see blend section) at the source.
        .max_yaw = 180.0,
        .max_pitch = 90.0,
        .gaze_scale = 40.0,
        .gaze_scale_pitch = 30.0,
        .smoothing = 0.90,
        .pos_smoothing = 0.95,
        .deadzone = 0.15,
        .head_gain = 2.0,
        .eye_ratio = 0.15,
        .pitch_gain = 1.0,
        .pos_gain = 2.0,
        .neck = 13.0,
        .curve_mode = 2,
        .curve_exp = 0.5,
        .flip_yaw = true,
        .gaze_y_offset = 0.0,
        .gaze_y_scale = 1.0,
        .track_box_factor = 2.5,
    },
    .{
        .name = "x4",
        // X4 build: same OEM spline feel as tobii-official but with a 120°
        // yaw cap so the screen edge doesn't blow to 180 and feel bimodal.
        .max_yaw = 120.0,
        .max_pitch = 90.0,
        .gaze_scale = 40.0,
        .gaze_scale_pitch = 30.0,
        .smoothing = 0.90,
        .pos_smoothing = 0.95,
        .deadzone = 0.15,
        .head_gain = 2.0,
        .eye_ratio = 0.15,
        .pitch_gain = 1.0,
        .pos_gain = 2.0,
        .neck = 13.0,
        .curve_mode = 2,
        .curve_exp = 0.5,
        .flip_yaw = true,
        .gaze_y_offset = 0.0,
        .gaze_y_scale = 1.0,
        .track_box_factor = 2.5,
    },
    .{
        .name = "x4-smooth",
        // X4-Smooth: the buttery setup (matches what felt great in testing),
        // now with head_gain raised 2.0 → 2.4 (+20%) so head turns are
        // stronger while keeping the smooth, stable feel.
        .max_yaw = 120.0,
        .max_pitch = 90.0,
        .gaze_scale = 40.0,
        .gaze_scale_pitch = 30.0,
        .smoothing = 0.90,
        .pos_smoothing = 0.95,
        .deadzone = 0.15,
        .head_gain = 2.4,
        .eye_ratio = 0.15,
        .pitch_gain = 1.0,
        .pos_gain = 2.0,
        .neck = 13.0,
        .curve_mode = 2,
        .curve_exp = 0.5,
        .flip_yaw = true,
        .gaze_y_offset = 0.0,
        .gaze_y_scale = 1.0,
        .track_box_factor = 2.5,
    },
};

// ─── Preset persistence ──────────────────────────────────────────────

const PresetFile = struct {
    presets: []Preset,
};

pub fn presetsFilePath(buf: *[512]u8) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| {
        return std.fmt.bufPrint(buf, "{s}/tobiifree-opentrack/presets.json", .{x}) catch null;
    }
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/tobiifree-opentrack/presets.json", .{home}) catch null;
}

pub fn findPreset(presets: []const Preset, name: []const u8) ?usize {
    for (presets, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) return i;
    }
    return null;
}

fn isBuiltinName(name: []const u8) bool {
    for (&BUILTIN_PRESETS) |b| {
        if (std.mem.eql(u8, b.name, name)) return true;
    }
    return false;
}

/// Returns built-in presets followed by user presets from disk. Allocations
/// come from `allocator` (pass an arena for the app lifetime; the name slices
/// reference the parsed file buffer, which stays owned by that arena).
pub fn loadAllPresets(allocator: std.mem.Allocator) ![]Preset {
    var list = std.array_list.Managed(Preset).init(allocator);
    errdefer list.deinit();
    try list.appendSlice(&BUILTIN_PRESETS);

    var pathbuf: [512]u8 = undefined;
    const path = presetsFilePath(&pathbuf) orelse return list.toOwnedSlice();
    const data = std.fs.cwd().readFileAlloc(allocator, path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return list.toOwnedSlice(),
        else => return err,
    };
    const parsed = std.json.parseFromSlice(PresetFile, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.scoped(.preset).warn("presets.json: {s}", .{@errorName(err)});
        return list.toOwnedSlice();
    };
    for (parsed.value.presets) |p| {
        if (findPreset(list.items, p.name) != null) continue;
        try list.append(p);
    }
    return list.toOwnedSlice();
}

/// Writes only user-defined presets (built-ins are seeded from code).
pub fn saveUserPresets(allocator: std.mem.Allocator, presets: []const Preset) !void {
    var user = std.array_list.Managed(Preset).init(allocator);
    defer user.deinit();
    for (presets) |p| {
        if (!isBuiltinName(p.name)) try user.append(p);
    }

    var arr = std.array_list.Managed(u8).init(allocator);
    defer arr.deinit();
    const bytes = std.json.Stringify.valueAlloc(allocator, PresetFile{ .presets = user.items }, .{
        .whitespace = .indent_2,
    }) catch |e| return e;
    defer allocator.free(bytes);
    try arr.appendSlice(bytes);

    var pathbuf: [512]u8 = undefined;
    const path = presetsFilePath(&pathbuf) orelse return error.NoConfigDir;
    const dirname = std.fs.path.dirname(path) orelse return error.BadPath;
    var dir = try std.fs.cwd().makeOpenPath(dirname, .{});
    defer dir.close();
    const file = try dir.createFile(std.fs.path.basename(path), .{ .truncate = true });
    defer file.close();
    try file.writeAll(arr.items);
}

// ─── Gaze state filter (dynamic EWMA) ────────────────────────────────

pub const GazeStateFilter = struct {
    state_x: f64 = 0.5,
    state_y: f64 = 0.5,
    init_x: bool = false,
    init_y: bool = false,

    const target_dt: f64 = 0.0111; // ~90 Hz baseline
    const alpha_fixation: f64 = 0.03; // heavy lock for micro-tremors
    const alpha_pursuit: f64 = 0.25; // responsive tracking of moving targets
    const alpha_saccade: f64 = 0.015; // lazy pan for sudden darts
    const thresh_jitter: f64 = 0.02; // ~2% screen distance
    const thresh_saccade: f64 = 0.12; // ~12% screen distance

    pub fn filter(self: *GazeStateFilter, raw: [2]f64, dt: f64) [2]f64 {
        return .{
            self.axis(&self.state_x, &self.init_x, raw[0], dt),
            self.axis(&self.state_y, &self.init_y, raw[1], dt),
        };
    }

    fn axis(self: *GazeStateFilter, state: *f64, init: *bool, raw: f64, dt: f64) f64 {
        _ = self;
        if (!init.*) {
            state.* = raw;
            init.* = true;
            return raw;
        }
        const delta = @abs(raw - state.*);
        var base: f64 = 0;
        if (delta < thresh_jitter) {
            base = alpha_fixation;
        } else if (delta > thresh_saccade) {
            base = alpha_saccade;
        } else {
            const t = (delta - thresh_jitter) / (thresh_saccade - thresh_jitter);
            base = alpha_fixation + t * (alpha_pursuit - alpha_fixation);
        }
        const alpha_dt = 1.0 - std.math.pow(f64, 1.0 - base, dt / target_dt);
        state.* += alpha_dt * (raw - state.*);
        return state.*;
    }
};

// ─── Velocity-adaptive (Accela-style) smoother ───────────────────────

pub const AdaptiveSmoother = struct {
    state: f64 = 0,
    last_raw: f64 = 0,
    init: bool = false,

    const target_dt: f64 = 0.0111; // ~90 Hz baseline

    /// Update with a per-frame delta limit (`max_step`). Samples that jump
    /// more than `max_step` from the last accepted raw value are treated as
    /// tracker glitches (a dropped eye shifting the eye-origin midpoint,
    /// re-acquisition spikes) and REJECTED outright — state and `last_raw`
    /// are held, so a glitch can never sweep or yank the view. A legit fast
    /// head turn spans many frames and each frame stays under `max_step`.
    pub fn update(self: *AdaptiveSmoother, value: f64, dt: f64, rest_smoothing: f64, max_step: f64) f64 {
        if (!self.init) {
            self.state = value;
            self.last_raw = value;
            self.init = true;
            return value;
        }
        const delta = value - self.last_raw;
        if (@abs(delta) > max_step) return self.state; // reject glitch, hold
        const dt_safe = @max(dt, 1e-6);
        const vel = @abs(delta) / dt_safe;
        self.last_raw = value;
        const retention = retentionForVelocity(vel, rest_smoothing);
        const retention_dt = std.math.pow(f64, retention, dt_safe / target_dt);
        const ewma = 1.0 - retention_dt;
        self.state += ewma * (value - self.state);
        return self.state;
    }
pub fn resetTo(self: *AdaptiveSmoother, value: f64) void {
        self.state = value;
        self.last_raw = value;
        self.init = true;
    }
};

fn retentionForVelocity(v: f64, rest: f64) f64 {
    if (v <= 5.0) return rest;
    const anchors = [_][2]f64{
        .{ 5, rest },
        .{ 45, 0.60 },
        .{ 90, 0.35 },
        .{ 180, 0.05 },
    };
    if (v >= anchors[anchors.len - 1][0]) return anchors[anchors.len - 1][1];
    var i: usize = 0;
    while (i < anchors.len - 1 and anchors[i + 1][0] < v) i += 1;
    const a0 = anchors[i];
    const a1 = anchors[i + 1];
    const t = (v - a0[0]) / (a1[0] - a0[0]);
    return a0[1] + t * (a1[1] - a0[1]);
}

// ─── One Euro filter (Casiez 2012) ────────────────────────────────────
//
// A low-pass whose cutoff rises with signal speed: at rest the cutoff drops
// to `fc_min` (kills Z-depth jitter), during fast motion it scales up by
// `beta` × the low-passed derivative (minimal lag). Designed to replace the
// velocity-adaptive retention for rotation, where the depth axis is noisy.

pub const OneEuroFilter = struct {
    x_hat: f64 = 0,
    x_prev: f64 = 0,
    dx_hat: f64 = 0,
    init: bool = false,
    fc: f64 = 0, // last computed cutoff (Hz), exposed for the trace

    const fc_d: f64 = 1.0; // derivative low-pass cutoff (Hz)

    fn alpha(fc: f64, dt: f64) f64 {
        const tau = 1.0 / (2.0 * std.math.pi * fc);
        return 1.0 / (1.0 + tau / dt);
    }

    /// `smoothing` (0..1) drives EVERYTHING: the rest-state cutoff floor
    /// (`fc_min = 6·(1−s)+0.3`), the speed→cutoff scaling (`beta`), and a hard
    /// motion cap (`fc_max`). Older builds had a fixed beta=0.5, so any motion
    /// blew the cutoff up to tens of Hz and the slider only affected the
    /// rest-state floor — that's why "max smoothing" felt identical to "low".
    pub fn update(self: *OneEuroFilter, value: f64, dt: f64, smoothing: f64) f64 {
        const dt_safe = @max(dt, 1e-6);
        if (!self.init) {
            self.x_hat = value;
            self.x_prev = value;
            self.dx_hat = 0;
            self.init = true;
            self.fc = 0;
            return value;
        }
        const s = std.math.clamp(smoothing, 0.0, 1.0);
        const fc_min = 6.0 * (1.0 - s) + 0.3;
        const beta = 0.02 + 0.48 * (1.0 - s);
        const fc_max = 1.0 + 30.0 * (1.0 - s);
        const dx = (value - self.x_prev) / dt_safe;
        self.x_prev = value;
        const a_d = alpha(fc_d, dt_safe);
        self.dx_hat += a_d * (dx - self.dx_hat);
        const fc = @min(fc_max, fc_min + beta * @abs(self.dx_hat));
        self.fc = fc;
        const a = alpha(fc, dt_safe);
        self.x_hat += a * (value - self.x_hat);
        return self.x_hat;
    }

    /// Re-initialise with a known value (instant adopt on eye re-acquisition —
    /// the internal state is stale from before the loss, and easing from it
    /// reads as "lag when returning into the tracking range").
    pub fn resetTo(self: *OneEuroFilter, value: f64) void {
        self.x_hat = value;
        self.x_prev = value;
        self.dx_hat = 0;
        self.init = true;
        self.fc = 0;
    }
};

// ─── Response curve ──────────────────────────────────────────────────

const YAW_PTS = [_][2]f64{
    // Proportional ramp, no dead flatline: the interocular yaw only spans
    // ~+/-9 deg pre-gain, so the old {2,0}+{8,40}+{16,110} curve was bimodal
    // (nothing near center, then a cliff to huge values). This set maps the
    // reachable range smoothly: 4 deg -> 30, 12 -> 70, so a modest turn
    // always produces a proportionate sweep (+~20% middle response vs the
    // previous 25/60, corners unchanged). The micro center is handled
    // by the deadzone, not a curve flatline. max_yaw (120 in x4/x4-smooth) caps it.
    .{ 0, 0 }, .{ 4, 30 }, .{ 12, 70 }, .{ 20, 100 }, .{ 35, 160 },
};
const PITCH_UP_PTS = [_][2]f64{
    // Symmetric with DOWN. v0.2.1 B4: flattened the top end from 90° at 20°
    // input to 50° — the eye-Y baseline bias (≥20° pre-curve) was amplified
    // straight to the 90° ceiling, so a residual baseline now reads as a
    // strong-but-sane pitch instead of a session-long pin.
    .{ 0, 0 }, .{ 2, 0 }, .{ 10, 25 }, .{ 20, 50 },
};
const PITCH_DOWN_PTS = [_][2]f64{
    .{ 0, 0 }, .{ 2, 0 }, .{ 10, 25 }, .{ 20, 50 },
};

fn catmullRom(pts: []const [2]f64, x: f64) f64 {
    if (x <= pts[0][0]) return pts[0][1];
    const n = pts.len;
    if (x >= pts[n - 1][0]) return pts[n - 1][1];
    var i: usize = 0;
    while (i < n - 1 and pts[i + 1][0] < x) i += 1;
    const p0 = pts[if (i == 0) 0 else i - 1];
    const p1 = pts[i];
    const p2 = pts[i + 1];
    const p3 = pts[if (i + 2 < n) i + 2 else n - 1];
    const t = (x - p1[0]) / (p2[0] - p1[0]);
    const t2 = t * t;
    const t3 = t2 * t;
    return 0.5 * ((2 * p1[1]) +
        (-p0[1] + p2[1]) * t +
        (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 +
        (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3);
}

/// Apply the response curve. `v` in degrees, output capped at `cap`.
pub fn applyCurve(mode: CurveMode, v: f64, cap: f64, exp: f64, is_pitch: bool) f64 {
    if (v == 0 or cap <= 0) return 0;
    const sign = std.math.sign(v);
    const a = @abs(v);
    return switch (mode) {
        .linear => std.math.clamp(v, -cap, cap),
        .power => blk: {
            const scaled = cap * std.math.pow(f64, @min(a / cap, 1.0), 1.0 / @max(exp, 0.1));
            break :blk sign * @min(scaled, cap);
        },
        .tobii => blk: {
            const norm = if (is_pitch) blk2: {
                const pts: []const [2]f64 = if (v >= 0) &PITCH_UP_PTS else &PITCH_DOWN_PTS;
                const x = @min(a, pts[pts.len - 1][0]);
                break :blk2 catmullRom(pts, x) / 90.0;
            } else blk2: {
                const x = @min(a, YAW_PTS[YAW_PTS.len - 1][0]);
                break :blk2 catmullRom(&YAW_PTS, x) / 180.0;
};
            const out = sign * norm * cap;
            break :blk std.math.clamp(out, -cap, cap);
        },
    };
}

/// Inverse of applyCurve: given an OUTPUT degree value `out`, return the
/// pre-curve INPUT degree that maps to it. Used to express the n=1 corner
/// drift bound in OUTPUT space (see n1_drift_max_out_deg) instead of raw
/// space — the raw space is rig-dependent (head_gain + curve amplification),
/// which is exactly why the earlier raw-degree bound overshot on the user's
/// rig (gain 2.0 + Tobii spline edge ~8x). Monotonic curves only; for tobii
/// we linear-interpolate the pts table (fine for a safety bound).
pub fn invertCurve(mode: CurveMode, out: f64, cap: f64, exp: f64, is_pitch: bool) f64 {
    const a = @abs(out);
    if (a <= 0 or cap <= 0) return 0;
    const target = @min(a, cap);
    const inv = switch (mode) {
        .linear => target,
        .power => blk: {
            // out = sign * cap * (a/cap)^(1/exp)  =>  in = cap * (out/cap)^exp
            break :blk cap * std.math.pow(f64, target / cap, @max(exp, 0.1));
        },
        .tobii => blk: {
            // out = sign * catmullRom(pts, in) * cap/180 (yaw) or * cap/90
            // (pitch). Invert by scaling the output target back to CATMULL
            // units first (out * 180/cap or * 90/cap), then bisecting the
            // monotonic pts segment for the exact input. (A plain lerp of the
            // bracketing segment is off by the spline's curvature — ~2.3 deg
            // near the {20,100}->{35,160} knot pair at cap=120 — which was
            // enough to fail the BATCH_2.5 round-trip regression.)
            // BATCH_2.5: without the cap scaling this was only exact at
            // cap=180/90 — on x4/x4-smooth (max_yaw=120) invertCurve(95)
            // returned raw 18.67 whose REAL output is 63.3° (cap/180=0.667),
            // so the n=1 drift under-capped and the view stopped short of
            // the edge. Behavior-neutral at cap=180 (scale 1.0).
            const cap_scale: f64 = if (is_pitch) 90.0 / @max(cap, 0.1) else 180.0 / @max(cap, 0.1);
            const catmull_target = target * cap_scale;
            const pts: []const [2]f64 = if (is_pitch) &PITCH_UP_PTS else &YAW_PTS;
            if (catmull_target <= pts[0][1]) break :blk pts[0][0];
            const last = pts[pts.len - 1];
            if (catmull_target >= last[1]) break :blk last[0];
            var i: usize = 0;
            while (i + 1 < pts.len and pts[i + 1][1] < catmull_target) i += 1;
            var lo = pts[i][0];
            var hi = pts[i + 1][0];
            var iter: usize = 0;
            while (iter < 40) : (iter += 1) {
                const mid = 0.5 * (lo + hi);
                const ym = catmullRom(pts, mid);
                if (@abs(ym - catmull_target) < 1e-9) break;
                if (ym < catmull_target) lo = mid else hi = mid;
            }
            break :blk 0.5 * (lo + hi);
        },
    };
    return std.math.copysign(inv, out);
}

fn deadzone(v: f64, dz: f64) f64 {
    return if (@abs(v) < dz) 0 else v;
}

/// Local slope of the YAW response curve (dOutput/dInput, output ° per
/// pre-curve °) at a pre-curve input. The corner-hold release ease step is
/// scaled by this so the eased OUTPUT sweeps at corner_release_rate_deg_s
/// regardless of the curve shape — near the corner the Tobii spline edge
/// slope is ~4x, so a fixed pre-curve step moved the output at ~225°/s there
/// (a visible pop-like sweep back from the corner, v4.5).
fn yawCurveSlope(p: *const Preset, input: f64) f64 {
    const eps: f64 = 0.25;
    const hi = applyCurve(@enumFromInt(p.curve_mode), input + eps, p.max_yaw, p.curve_exp, false);
    const lo = applyCurve(@enumFromInt(p.curve_mode), input - eps, p.max_yaw, p.curve_exp, false);
    return @max((hi - lo) / (2.0 * eps), 0.05);
}

// ─── Main pipeline ───────────────────────────────────────────────────

/// Rotation smoother that dispatches on the preset's smoothing mode. Position
/// axes stay on the velocity-adaptive reject-and-hold smoother regardless.
pub const RotationSmoother = struct {
    accela: AdaptiveSmoother = .{},
    euro: OneEuroFilter = .{},

    pub fn update(self: *RotationSmoother, value: f64, dt: f64, mode: SmoothMode, smoothing: f64, max_step: f64) f64 {
        return switch (mode) {
            .accela => self.accela.update(value, dt, smoothing, max_step),
            .one_euro => self.euro.update(value, dt, smoothing),
            .none => value,
        };
    }

    pub fn cutoff(self: *RotationSmoother) f64 {
        return self.euro.fc;
    }

    pub fn resetTo(self: *RotationSmoother, value: f64) void {
        self.accela.resetTo(value);
        self.euro.resetTo(value);
    }
};

pub const TobiiPipeline = struct {
    gaze: GazeStateFilter = .{},
    rot_yaw: RotationSmoother = .{},
    rot_pitch: RotationSmoother = .{},
    roll_s: RotationSmoother = .{},
    pos_x: AdaptiveSmoother = .{},
    pos_y: AdaptiveSmoother = .{},
    pos_z: AdaptiveSmoother = .{},
ref_set: bool = false,
    had_ref: bool = false,
    ref_mid: [3]f64 = .{ 0, 0, 0 },
    settle_frames: u32 = 0,
    settle_sum: [3]f64 = .{ 0, 0, 0 },
    last_out: [6]f64 = .{ 0, 0, 0, 0, 0, 0 },
    // Head yaw speed (deg/s), used to gate the gaze blend: when the head is
    // actively rotating, the vestibular-ocular reflex counter-rotates the
    // eyes, so adding the fast-flying gaze signal shoves the output opposite
    // to the turn (the "spike to the upper-left when turning right").
    last_head_yaw: f64 = 0,
    has_last_head_yaw: bool = false,
    last_head_pitch: f64 = 0,
    has_last_head_pitch: bool = false,
    // Eased copy of the VOR gate: the raw gate is near-binary (dir_gate 0/1
    // times a speed taper), and toggling it 1↔0 snaps the gaze tug in/out in
    // one frame — a visible step even at small eye ratios. We low-pass it so
    // the tug eases in/out over ~150 ms instead.
    gate_smooth: f64 = 1.0,
    // Anti-latch state: a pre-occlusion glitch frame can spike the
    // interocular depth, and a subsequent n=1 frame would then latch that
    // spike forever (the one-eye fallback never gets within the reject
    // threshold). n1_timer/last_good* let us hold through short drops and
    // gently unstick toward the real pose on long ones.
    n1_timer: f64 = 0,
    was_n1: bool = false, // previous frame had one eye (or glitched pair)
    was_lost: bool = false, // eyes fully gone last frame — re-acquire instantly
    // v4.3: re-acquisition catch-up state. On n1→n2 (or loss→return) the
    // interocular may deliver a pose far from the frozen n=1 pose (the head
    // kept turning while rotation was frozen). Adopting it INSTANTLY pops the
    // output (the curve amplifies a 25° raw step into 60-80° output — trace
    // 2026-08-30: 206 jumps >10°, all n1→n2 re-acquisitions). Instead ease
    // last_good_yaw toward the new pose at n1_catch_rate.
    n1_catch_target: f64 = 0,
    n1_catch_active: bool = false,
    // v4.3: last center-translation turn estimate during n=1 (velocity gate
    // for the non-corner follow — only follow while the head is genuinely
    // turning, so a held corner's static/lean dx never creeps).
    n1_last_turn_est: f64 = 0,
    // v0.2.7: debounced eye-count state. The RAW per-frame eye count flaps
    // 2↔1↔2 when an origin-validity flicker or a blink drops one eye for a
    // few frames; switching rotation paths on every flap is what made corner
    // holds wobble. n_eff only switches after 6 consecutive disagreeing
    // frames (~66 ms at 90 Hz), so brief excursions HOLD the current path
    // instead of engaging the n=1 anchor/settle/drift churn.
    n_eff: u32 = 2,
    n_eff_frames: u32 = 0, // consecutive frames raw n != n_eff
    // v0.2.7: low-passed single-eye Y (alpha 0.3) used during n=1 episodes —
    // the far eye's raw Y carries mm-scale jaw/cheek wobble at corners.
    n1_y_lp: f64 = 0,
    n1_y_lp_set: bool = false,
    // v0.2.7: settle-window anchor averaging. The single-eye Y anchor used to
    // be captured at the transition INSTANT — if the jaw was mid-wobble the
    // anchor landed on a phase value, leaving a fixed DC pitch step at settle
    // end that saturated the pitch One-Euro's adaptive cutoff (fc rose to max
    // for ~1 s, letting the 2-5 Hz jaw wobble straight through). Averaging
    // the single-eye Y over the 1.0 s settle window makes the anchor the MEAN,
    // so tracking starts at ~0 DC and the One-Euro stays at rest cutoff.
    n1_y_anchor_sum: f64 = 0,
    n1_y_anchor_cnt: u32 = 0,
    n1_anchor_finalized: bool = false, // anchor averaged over the settle window
    last_good_yaw: f64 = 0,
    last_good_pitch: f64 = 0,
    last_good_roll: f64 = 0,
    last_good_y: f64 = 0, // last sane eye-midpoint Y (mm) — n=1 sanity gate
    has_last_good: bool = false,
    // Single-eye Y anchor: when n drops 2→1 the remaining (far) eye's raw Y is
    // offset from the true eye midpoint (interocular Y separation) and the
    // estimate can settle over the first ~0.5 s. Adopting it directly pins
    // pitch up/down at corner holds. The anchor ties the single-eye Y to the
    // last n=2 midpoint so we track CHANGES, not the absolute offset.
    n1_y_anchor: f64 = 0, // single-eye Y captured at the n→1 transition
    n1_y_base: f64 = 0, // last n=2 midpoint Y at the transition (= last_good_y)
    n1_y_anchor_set: bool = false, // anchor captured for the current n=1 episode
    n1_settle: f64 = 0, // elapsed n=1 settle time (s)
    pos_hold: [3]f64 = .{ 0, 0, 0 },
    has_pos_hold: bool = false,
    // Absolute-pose recentering: interocular yaw/roll are ABSOLUTE
    // measurements of the eye line (not ref-relative like pitch/position), so
    // a calibration/seat offset survives every recenter. Capture them during
    // the settle window and subtract, so dead-center head = 0°/0°.
    yaw_ref: f64 = 0,
    roll_ref: f64 = 0,
    settle_yaw_sum: f64 = 0,
    settle_roll_sum: f64 = 0,
    settle_yaw_frames: u32 = 0,
    manual_recenter: bool = false, // next valid frame captures ref instantly
    // Gaze-witnessed corner hold: at the far corner the interocular yaw
    // estimate saturates/reverses as the eyes approach the tracking edge,
    // even though both eyes are still "seen" (n=2) — the view collapses back
    // to center while the user still stares at the screen edge. The pinned
    // gaze is the witness that they're still at the corner: hold the last
    // reliable peak yaw until the gaze comes back.
    corner_hold: bool = false,
    corner_side: f64 = 0, // sign of the pinned gaze (+right / -left)
    corner_peak: f64 = 0, // last reliable pre-curve yaw at the corner
    // v4.2: center x (mm) when the hold ENGAGED — the head-return witness. The
    // hold may only pin the peak while the user is still displaced toward the
    // corner they are looking at; when the head comes back the view must
    // follow it, not stay pinned (the interocular/head rotation signal is
    // FROZEN during n=1, but the IPD-compensated center translation stays
    // live in both n=1 and n=2 — trace 2026-08-30: the user swept the head
    // from the corner back past center (center X -63 -> +29 mm) with the gaze
    // still pinned, and the old hold kept the view at the corner peak the
    // whole way, then popped +182° in ONE frame when the gaze finally
    // unpinned).
    corner_hold_cenx: f64 = 0,
    // v4.2: once the head-return witness releases the hold, do NOT re-pin
    // while the gaze is still at the edge (the head is coming back — re-pinning
    // at the new position would re-latch the stale peak). Latched until the
    // gaze unpins (the else branch clears it).
    corner_release_latch: bool = false,
    // v4.2: release EASE. On release the pinned yaw (corner_peak) can be far
    // from the smoother state (which tracked the live head back during the
    // hold) — snapping yaw to the live signal pops the view by the whole
    // difference in one frame. Ease from the peak toward the live signal at a
    // bounded rate (0 = not easing).
    corner_release_ease: f64 = 0,
    // v4.4: whether the hold PINNED the output to corner_peak last frame
    // (only when the pin condition fired). The release ease must start from
    // the value the output ACTUALLY held: the pinned peak if the pin was
    // active, else the live yaw — starting from the capped witness when the
    // output never sat there would snap the return (BATCH_2i).
    corner_pin_active: bool = false,
    // v4.6: the value the output ACTUALLY held last frame while a hold was
    // active (the post-pin yaw — corner_peak when the pin held, else the live
    // yaw a deep-turn output tracked). The release ease must start from THIS,
    // not corner_peak, when the head-rotation estimate crosses center while
    // the gaze is still pinned (@449 pop: the same-side pin guard hard-fails
    // and the view reverted to the live signal in one frame) or when a deep
    // past-cap turn never pinned. Cleared on hold engage/release so a stale
    // side can't leak into a fresh hold.
    corner_held_yaw: f64 = 0,
    // Tug-only gaze low-pass: the raw scaled gaze flickers ±2-3°/frame from
    // micro-saccades, and the fine-aim term (gaze·ratio·gate) passes that
    // straight into the output as visible jitter while the head rests. This
    // pair smooths ONLY the tug path — corner-pin detection and the VOR gate
    // keep the raw signal so their timing stays sharp.
    tug_yaw_f: OneEuroFilter = .{},
    tug_pitch_f: OneEuroFilter = .{},
    // Rest-follow ref: the reference is captured once at startup (or on the
    // Recenter button), but seat drift / tracker baseline leaves the eye-Y
    // offset stuck, which pins pitch at the ceiling all session. When the
    // head is genuinely at rest AND the gaze is NOT pinned at a corner, very
    // slowly nudge the ref toward the current pose so the baseline decays
    // without ever dragging a held corner pose to center.
    rest_time: f64 = 0,
    last_rest_yaw: f64 = 0,
    last_rest_pitch: f64 = 0,
    // B1: last validated raw gaze. Garbage frames (device sentinel −1.0/−1.0,
    // off-plane [−0.05,1.05] bounds, exact (0,0)) feed the HOLD instead of
    // the filter, so a single bad frame can't poison the gaze EWMA, the
    // corner-hold witness, or the rest-follow gaze-center check.
    last_good_gaze: [2]f64 = .{ 0.5, 0.5 },
    // v0.2.7 BATCH_1: frozen tug output + eye ratio for n=1 episodes. The
    // combined gaze collapses toward center when one eye is lost; holding the
    // last n=2 tug and ratio keeps the gaze-tug fine-aim term from chasing the
    // collapsing signal on a pose that is otherwise held (see process()).
    last_tug: [2]f64 = .{ 0, 0 },
    has_last_tug: bool = false,
    last_ratio_n2: f64 = 0,
    has_last_ratio_n2: bool = false,
    // BATCH_2: last effective eye ratio applied (trace/test probe).
    last_ratio: f64 = 0,
    // B3: pitch-pin safety net. If the OUTPUT pitch is stuck at ≥19° for >2 s
    // while the corrected gaze is at screen center, the eye-Y baseline is
    // pinned (the old rest-follow never engaged because the biased gaze sat
    // outside its ±4° window). Nudge the ref baseline toward the current pose
    // at a bounded rate so the view unbinds without dragging a held pose.
    pitch_pin_time: f64 = 0,
    // BATCH_2: hysteresis state for the n=1 corner drift (engage >10, disengage <6).
    n1_drift_active: bool = false,
    // BATCH_2 v4: eased cap (OUTPUT deg) on the gaze TUG contribution while at
    // a corner. The v3 drift cap holds the head output at the natural edge
    // (n1_drift_max_out_deg=95), but the tug is added post-cap and crept the
    // final fy to ~102.7° while holding (trace 2026-08-30). Eased at
    // gate_react so it never snaps. Starts unconstrained (= edge) — only
    // tightens when a corner hold/drift is active.
    tug_out_clamp: f64 = 95.0,
    // BATCH_2 REWORK v2 (user gate FAILED twice -> overshoot + upper corners):
    // drift STOP control. n1_anchor_yaw = the last validated n=2 raw yaw at the
    // moment the eye was lost (the occlusion turn); the drift may NEVER extend
    // the pose more than n1_extra_max_deg raw past it. v2: the drift TARGET is
    // GAZE-ANCHORED (n1_anchor_yaw + side*clamp(|gaze_yaw|*n1_gaze_gain, 0, max))
    // instead of the LIVE single-eye translation — the translation CREPS on the
    // real device while the user holds a corner (trace RD: gaze pinned gy 13-19
    // but lg carried -4.07 -> -18.12 = the 90-deg view swing), so chasing it
    // overshot; the gaze is STABLE while holding, so the target is stable and
    // the drift converges + stops. Engagement is a GAZE-DWELL (radial > 10 +
    // |gy| > 2 sustained n1_gaze_dwell_s) — the old translation-velocity gate
    // froze the drift at upper corners (eyes-only look, head still, est_motion
    // 0) which is exactly the "upper corners not captured" failure. The pitch
    // gets the same gaze-anchored treatment (n1_pitch_anchor + clamp(gaze_pitch
    // * n1_pitch_gain, ±max)) so lower corners stop diving toward 90° and upper
    // corners follow the up-look.
    n1_anchor_yaw: f64 = 0,
    has_n1_anchor: bool = false,
    n1_pitch_anchor: f64 = 0,
    has_n1_pitch_anchor: bool = false,
    n1_gaze_dwell: f64 = 0,

    const settle_target: u32 = 90; // ~1 s of samples to average the ref
    const half_ipd_mm: f64 = 32.5; // average eye-to-head-center offset
    const corner_pin_deg: f64 = 12.0; // |gaze yaw| beyond this = pinned at the screen edge
    const corner_hyst_deg: f64 = 0.5; // estimate must sag this far below the peak to engage
    // v4.2: the hold releases when the center translation returns toward the
    // ref by this many mm from the engage position (a real head-back, not
    // lean noise — corner holds wobble ±5 mm; a return is 30-90 mm).
    const corner_hold_release_mm: f64 = 12.0;
    // v4.2: max rate the held view may sweep back after the hold releases
    // (pre-curve deg/s — a hard snap pops ~160° in one frame; the trace's
    // release pops were 119-182° single-frame).
    const corner_release_rate_deg_s: f64 = 60.0;
    // BATCH_2 (corner RANGE): constants for the n=1 corner drift — the one-eye
    // lateral-translation continuation that carries the view to the screen edge.
    const n1_corner_authority: f64 = 0.70; // B2: 0.36 -> 0.70 — recover 70% of the remaining turn
    const n1_drift_rate: f64 = 8.0; // v4.2: 15 -> 8 deg/s pre-gain. At 15 the drift converged the corner extension in ~0.5 s (~36 deg/s output on the rig) — the user felt it as a "jump ~20° more" at the corner instead of a linear continuation. 8 makes the extension a gradual glide (~2 s to the edge cap).
    const corner_engage_deg: f64 = 10.0; // B2: drift engages when the RADIAL gaze deviation > 10 deg (both axes — upper corners are diagonal looks with small horizontal component)
    const corner_disengage_deg: f64 = 6.0; // B2: ...disengages below 6 deg radial (hysteresis: no cut-out on micro-sags)
    const corner_ratio_floor: f64 = 0.35; // B2: eye-ratio floor at the corner (gaze tug keeps pulling ±7 deg)
    // BATCH_2 REWORK v2: drift stop control (see fields note).
    const n1_extra_max_deg: f64 = 15.0; // drift may extend at most ~15 deg raw past the n=2 occlusion turn (overshoot bound)
    const n1_gaze_gain: f64 = 0.5; // v4.2: 0.7 -> 0.5 — gaze yaw (deg) -> raw-turn extension factor. 0.7 × a 20° corner look = 14 raw ≈ +20° output on the rig (head_gain 2.0 + Tobii spline) — the other half of the "jump 20° more". 0.5 × 20 = 10 raw ≈ +14° output, still a full corner recovery but no overshoot past the head's actual turn.
    // BATCH_2 REWORK v3 (user gate FAILED twice on the real rig): the drift
    // bound must live in OUTPUT degrees, not raw. The v2 raw bound
    // (anchor + n1_extra_max_deg raw) was tuned with head_gain=1.0 + linear
    // curve in the tests, but the user's rig runs head_gain=2.0 + the Tobii
    // spline whose edge slope is ~4x — so even a small raw extension blew the
    // OUTPUT past the natural ~93-100 deg edge to 124+ deg (user: "still have
    // 90 deg overshoot on left/right"). n1_drift_max_out_deg caps the drift
    // so the final OUTPUT (post-gain, post-curve) can never exceed the natural
    // corner edge. invertCurve() back-maps that output cap to a raw bound for
    // the anchor+extra comparison.
    const n1_drift_max_out_deg: f64 = 95.0; // natural corner edge in OUTPUT deg (post-gain+curve) — the drift may not exceed it
    const tug_edge_band: f64 = 12.0; // v4: tug output is capped only while |fy_head| is within ±12° of the natural edge
    const n1_gaze_dwell_s: f64 = 0.12; // gaze must be pinned at the corner this long before the drift engages (kills single-glance yanks)
    const n1_pitch_gain: f64 = 0.5; // gaze pitch (deg) -> raw-pitch extension factor (upper corners follow the up-look)
    const n1_pitch_extra_max: f64 = 12.0; // max raw-pitch extension past the n=2 occlusion pitch (lower corners stop diving to 90)
    const n1_pitch_rate: f64 = 8.0; // pitch-drift ease rate (deg/s pre-gain)
    const n1_turn_min_deg: f64 = 2.5; // min |target| for the drift to act (lean-crosstalk guard)
    const pitch_glitch_deg: f64 = 5.0; // max genuine pitch change per frame (~450°/s)
    const n1_y_sanity_mm: f64 = 25.0; // single-eye Y can't be this far from the midpoint
    const n1_y_settle_s: f64 = 1.0; // hold pitch while the single-eye Y estimate settles (v0.2.7: 0.5→1.0)
    const rest_follow_s: f64 = 1.0; // head still this long before following
    const rest_vel_deg_s: f64 = 6.0; // head yaw+pitch speed below this = at rest
    const rest_follow_rate: f64 = 0.004; // ref blend per frame once at rest (slow, no pop)
    const rest_center_deg: f64 = 12.0; // only follow when the output pose is near center
    const rest_gaze_deg: f64 = 4.0; // AND the gaze is near screen center (both axes):
    // a held down-look (reading, taskbar) has a still head too — without this
    // check the ref crept toward the eye position and the view wandered off.
    const pitch_pin_deg: f64 = 19.0; // B3: output pitch at/above this = pinned up/down
    const pitch_pin_s: f64 = 2.0; // B3: pinned this long before the bounded ref nudge
    const pitch_pin_rate: f64 = 0.05; // B3: ref blend per frame once pinned (bounded, no pop)
    const tug_smoothing: f64 = 0.88; // v4.6: 0.85 -> 0.88 (fc_min 1.2 -> 1.08 Hz) — mild tug-path low-pass tightening for the "small jitter everywhere" (user gate v4.5); corner-pin detection + VOR gate keep the raw signal
    const min_ipd_mm: f64 = 45.0; // biological lower bound on interocular distance
    const max_ipd_mm: f64 = 80.0; // biological upper bound (glitch detector)
    const zero_eps: f64 = 1e-3; // treat (x,z)≈(0,0) as a dropped eye
    const glitch_deg: f64 = 10.0; // max genuine interocular yaw change per frame
    // v4.3: re-acquisition catch-up rate (raw deg/s pre-gain). A human head
    // turns ~300-700 °/s max; the n1 freeze can leave last_good_yaw far behind
    // the real pose. Ease back at up to this rate so the re-arm glides instead
    // of popping (~35 °/s raw ≈ 70-140 °/s output on the rig — a visible but
    // smooth catch-up, not a snap).
    const n1_catch_rate: f64 = 35.0;
    // v4.3: non-corner n=1 follow rate (raw deg/s pre-gain). Slower than the
    // re-arm catch so the view glides, not lags — the head translation during
    // an n=1 turn is the only live turn signal.
    const n1_follow_rate: f64 = 20.0;
    // v4.3: the n=1 follow only runs while the center translation is genuinely
    // MOVING (> this, deg/s equivalent) — a held corner or a lean has a slow/
    // static dx that would otherwise creep the view.
    const n1_est_move_deg_s: f64 = 8.0;
    const n1_hold_s: f64 = 0.5; // hold through n=1 (blinks/glances) this long
    const unstick_rate: f64 = 2.0; // lerp rate toward the fallback once stuck

    /// Full reset (fresh acquisition / manual recenter). Preserves the
    /// reference (ref_mid, yaw_ref/roll_ref) and the last-good pose so a
    /// re-settle can't yank the view: the OLD refs keep tracking while the new
    /// settle window accumulates, then swap atomically. Only the settle
    /// accumulators and ref_set are cleared so a fresh ref re-captures.
    pub fn reset(self: *TobiiPipeline) void {
        self.manual_recenter = true;
        self.settle_frames = 0;
        self.settle_sum = .{ 0, 0, 0 };
        self.settle_yaw_sum = 0;
        self.settle_roll_sum = 0;
        self.settle_yaw_frames = 0;
        self.n1_timer = 0;
        self.ref_set = false;
        self.corner_hold = false;
        self.corner_side = 0;
        self.corner_peak = 0;
        self.corner_hold_cenx = 0;
        self.corner_release_latch = false;
        self.corner_release_ease = 0;
        self.corner_pin_active = false;
        self.corner_held_yaw = 0;
        self.n1_catch_active = false;
        self.n1_last_turn_est = 0;
        self.rest_time = 0;
        self.n_eff = 2;
        self.n_eff_frames = 0;
        self.n1_y_lp = 0;
        self.n1_y_lp_set = false;
        self.n1_y_anchor_sum = 0;
        self.n1_y_anchor_cnt = 0;
        self.n1_anchor_finalized = false;
        self.has_last_tug = false;
        self.has_last_ratio_n2 = false;
        self.has_n1_anchor = false;
        self.n1_anchor_yaw = 0;
        self.has_n1_pitch_anchor = false;
        self.n1_pitch_anchor = 0;
        self.n1_gaze_dwell = 0;
        self.n1_drift_active = false;
        self.tug_out_clamp = 95.0;
    }

    /// v4.4: shared n=1 corner-drift step. Extends the held pose
    /// (last_good_yaw / last_good_pitch) toward the GAZE-ANCHORED corner target
    /// at a bounded rate. Called from BOTH the genuine n=1 branch and the n=1
    /// debounce hold (n_eff==2 && n==1) so a quick flickering corner look
    /// (n 1↔2) keeps extending instead of freezing mid-way — the old code ran
    /// the drift only in the genuine branch, so a flicker interrupted the
    /// extension and one side under-reached. Callers gate on n1_drift_active;
    /// the anchor is captured here (guarded) so either entry point works.
    ///
    /// Design (BATCH_2 v2/v3/v4, user gates FAILED twice on the real rig):
    ///   - YAW target = anchor + side·clamp(|gaze_yaw|·n1_gaze_gain, 0, extra).
    ///     Direction = the GAZE side (the user looks at the edge they turn
    ///     toward). flip_yaw=true mirrors the output, so the raw side is the
    ///     OPPOSITE of the gaze side there. Outward-only + anchor bound.
    ///   - OUTPUT-space cap: the raw bound (anchor + n1_extra_max_deg) was
    ///     tuned on head_gain=1.0 + linear curve, but the user's rig (gain 2.0
    ///     + Tobii spline edge ~4x) amplified a raw 8.5->13-15 extension into
    ///     OUTPUT 124-145 deg while raw ~9 maps to ~95 deg = the natural edge.
    ///     invertCurve() back-maps n1_drift_max_out_deg to a raw bound; the
    ///     TARGET is capped (not the live lg) so the drift eases without snap.
    ///   - v4.4 live clamp: while the drift owns lg it may never exceed the
    ///     output edge even when the n=2 anchor was already deeper (the old
    ///     "deeper holds lg" rule held a 124° deep-turn pose for the whole
    ///     occluded hold — the user's "creep").
    ///   - PITCH target = anchor + clamp(gaze_pitch·n1_pitch_gain, ±max): the
    ///     single-eye Y drifts down at lower corners (old Y-derived pitch dove
    ///     toward 90°); the gaze is stable, so the pose holds sane pitch and
    ///     upper corners follow the up-look.
    /// Returns the effective n=1 pitch for this frame.
    fn runCornerDrift(self: *TobiiPipeline, gaze_yaw: f64, gaze_pitch: f64, dt: f64, p: *const Preset) f64 {
        if (!self.has_n1_anchor and self.has_last_good) {
            self.n1_anchor_yaw = self.last_good_yaw;
            self.has_n1_anchor = true;
            self.n1_pitch_anchor = self.last_good_pitch;
            self.has_n1_pitch_anchor = true;
        }
        const flip_sign: f64 = if (p.flip_yaw) -1.0 else 1.0;
        const side = (if (gaze_yaw < 0) @as(f64, -1.0) else @as(f64, 1.0)) * flip_sign;
        const yaw_extra = std.math.clamp(@abs(gaze_yaw) * n1_gaze_gain, 0.0, n1_extra_max_deg);
        var yaw_target = self.n1_anchor_yaw + side * yaw_extra;
        const out_cap_raw = invertCurve(
            @enumFromInt(p.curve_mode),
            n1_drift_max_out_deg,
            p.max_yaw,
            p.curve_exp,
            false,
        ) / @max(p.head_gain, 0.1);
        if (@abs(yaw_target) > out_cap_raw) {
            yaw_target = std.math.copysign(out_cap_raw, yaw_target);
        }
        if (@abs(yaw_target) > n1_turn_min_deg) {
            const deeper = (yaw_target - self.last_good_yaw) * side > 0.0;
            const n1_target = if (deeper) yaw_target else self.last_good_yaw;
            const n1_drift = n1_drift_rate * dt; // °/frame pre-gain
            self.last_good_yaw += std.math.clamp(n1_corner_authority * (n1_target - self.last_good_yaw), -n1_drift, n1_drift);
            // Hard clamp to the anchor bound (safety net).
            const bound = self.n1_anchor_yaw + n1_extra_max_deg * side;
            if ((self.last_good_yaw - bound) * side > 0.0) self.last_good_yaw = bound;
            // v4.4: while the drift owns lg it may never stay past the output
            // edge (the old "deeper than the cap keeps lg held" rule left a
            // deep-turn pose at 124° for the whole occluded hold — the user's
            // "creep", trace 2026-08-30). The TARGET cap above already eases lg
            // back to the edge while the deeper-check fires; this live net
            // covers the case it cannot (a BARELY-pinned gaze at a deep hold
            // → |yaw_target| <= n1_turn_min_deg → the drift body is skipped).
            // It must EASE back at n1_drift_rate, never snap — an instant live
            // clamp yanked the whole overshoot in one frame (BATCH_1e's
            // lg=-24 -> -9.5 snap, dy 11.6°/frame).
            if (@abs(self.last_good_yaw) > out_cap_raw and @abs(yaw_target) <= n1_turn_min_deg) {
                const pull = n1_drift_rate * dt;
                self.last_good_yaw += std.math.clamp(
                    std.math.copysign(out_cap_raw, self.last_good_yaw) - self.last_good_yaw,
                    -pull,
                    pull,
                );
            }
        }
        const pitch_extra = std.math.clamp(gaze_pitch * n1_pitch_gain, -n1_pitch_extra_max, n1_pitch_extra_max);
        const pitch_target = self.n1_pitch_anchor + pitch_extra;
        const p_drift = n1_pitch_rate * dt;
        self.last_good_pitch += std.math.clamp(n1_corner_authority * (pitch_target - self.last_good_pitch), -p_drift, p_drift);
        return self.last_good_pitch;
    }

    /// v4.5: value the release ease must START from. The corner hold freezes
    /// the view at `corner_peak` while the interocular estimate sags — but the
    /// pin (corner_pin_active) only engages once the sag EXCEEDS corner_hyst_deg
    /// below the peak. When the estimate sits exactly AT the peak (a perfect
    /// hold, trace 2026-08-30 i=236-242: yaw == peak, pin inactive) the output
    /// is STILL held at the peak — so a release in that state must ease back
    /// from the peak, not from this frame's already-sagged live yaw (which
    /// popped 3-12° in ONE frame, i=243: ease=yaw=-10.79 vs the held -13.81).
    /// The old `if (corner_pin_active) corner_peak else yaw` missed exactly
    /// this "sitting on the peak" state. Peak is used whenever the live yaw is
    /// at-or-below the peak on the GAZE side (the view was held at the peak);
    /// a yaw DEEPER than the peak (deep turn past the capped peak never pins —
    /// the output followed the live signal there) still starts from live yaw.
    fn cornerReleaseStart(self: *const TobiiPipeline, yaw: f64, gaze_side: f64) f64 {
        // v4.6: the head-rotation estimate CROSSED CENTER while the gaze was
        // still pinned (trace @449: yaw +6.76 -> -0.54 in ONE frame, gy +15
        // held) — the same-side pin guard (yaw*gaze_side > 0) hard-fails and
        // the view would revert to the live signal in one frame (fy 44.52 ->
        // -1.67, the 46°/frame pop). Start the ease from corner_held_yaw: the
        // value the output ACTUALLY held last frame (the pinned peak when the
        // pin was active, else the live yaw a deep past-cap turn tracked).
        if (yaw * gaze_side <= 0 and self.corner_held_yaw * gaze_side > 0) {
            return self.corner_held_yaw;
        }
        if (self.corner_pin_active or
            (self.corner_peak != 0 and yaw * gaze_side > 0 and yaw * gaze_side <= self.corner_peak * gaze_side))
        {
            return self.corner_peak;
        }
        return yaw;
    }

    /// Process one gaze sample into a 6-DOF pose
    /// (X, Y, Z in cm; Yaw, Pitch, Roll in degrees).
    /// Re-acquisition re-centering is triggered by the caller via `reset()`
    /// (based on eye validity over time), not by dt.
    pub fn process(self: *TobiiPipeline, sample: *const core.GazeSample, p: *const Preset, dt: f64) [6]f64 {
        // Gatekeeper: eye validity + zero-vector shield (a dropped eye is
        // sometimes defaulted to (0,0,0); feeding that to atan2 explodes), then
        // a biological IPD clamp for the rotation path.
        // v0.2.7: the 3D origin validity flag can FLICKER (validity_L/R turns
        // 4) while the tracker still sees the eye — the per-eye 2D projection
        // stays plausible (shared core.eye2dPlausible predicate, same as the
        // calibration loop and the GUI viz). Treat "validity==0 OR 2D
        // plausible" as tracked so n=2 (rot_both) is held instead of flapping
        // to the n=1 fallback while both eyes are visibly tracked.
        const lx = sample.eye_origin_L_mm[0];
        const lz = sample.eye_origin_L_mm[2];
        const rx = sample.eye_origin_R_mm[0];
        const rz = sample.eye_origin_R_mm[2];
        const l_plaus = core.eye2dPlausible(sample.gaze_point_2d_L_norm[0], sample.gaze_point_2d_L_norm[1]);
        const r_plaus = core.eye2dPlausible(sample.gaze_point_2d_R_norm[0], sample.gaze_point_2d_R_norm[1]);
        const left_valid = (sample.validity_L == 0 or l_plaus) and (@abs(lx) > zero_eps or @abs(lz) > zero_eps);
        const right_valid = (sample.validity_R == 0 or r_plaus) and (@abs(rx) > zero_eps or @abs(rz) > zero_eps);

        // Head-center estimate from VALID eyes only (a dropped eye otherwise
        // shifts the midpoint toward the remaining eye → camera yanks).
        // With one eye we compensate the missing half-IPD so the estimate stays
        // on the true head center: n=2 uses the exact midpoint, n=1 uses the
        // single eye offset toward center. This kills both the position
        // offset and the seamless n=1/n=2 handoff.
        var center: [3]f64 = .{ 0, 0, 0 };
        var n: usize = 0;
        if (left_valid) {
            for (0..3) |i| center[i] += sample.eye_origin_L_mm[i];
            n += 1;
        }
        if (right_valid) {
            for (0..3) |i| center[i] += sample.eye_origin_R_mm[i];
            n += 1;
        }
        const has_origins = n > 0;

        // v0.2.7: debounce the raw eye count so brief 2↔1 flaps don't switch
        // rotation paths. n_eff switches only after 6 consecutive frames of
        // disagreement (~66 ms at 90 Hz). Seeded to 2 (both eyes) and reset on
        // pipeline reset() so a fresh acquisition assumes the full state.
        if (n != self.n_eff) {
            self.n_eff_frames += 1;
            if (self.n_eff_frames >= 6) {
                self.n_eff = @intCast(n);
                self.n_eff_frames = 0;
            }
        } else {
            self.n_eff_frames = 0;
        }

        // Rotation uses BOTH eyes only when the interocular distance is within
        // human bounds and the right eye is truly on the right (an eye-swap
        // hallucination flips ex negative; a Z hallucination blows up dist).
        // Otherwise degrade to the frozen one-eye path below. Computed up
        // front so the settle window can also average the pose.
        var rot_both = false;
        var inter_yaw: f64 = 0;
        var inter_roll: f64 = 0;
        if (left_valid and right_valid) {
            const ex = sample.eye_origin_R_mm[0] - sample.eye_origin_L_mm[0];
            const ey = sample.eye_origin_R_mm[1] - sample.eye_origin_L_mm[1];
            const ez = sample.eye_origin_R_mm[2] - sample.eye_origin_L_mm[2];
            const dist = @sqrt(ex * ex + ey * ey + ez * ez);
            rot_both = dist >= min_ipd_mm and dist <= max_ipd_mm and ex > 0.0;
            if (rot_both) {
                inter_yaw = std.math.atan2(ez, ex) * 180.0 / std.math.pi;
                inter_roll = std.math.atan2(ey, ex) * 180.0 / std.math.pi;
            }
        }

        if (has_origins) {
            if (n == 2) {
                for (0..3) |i| center[i] *= 0.5;
            } else if (left_valid) {
                center[0] += half_ipd_mm; // left eye sits -IPD/2 from center
            } else {
                center[0] -= half_ipd_mm; // right eye sits +IPD/2 from center
            }
            if (!self.ref_set) {
                // Manual recenter: capture the CURRENT pose as the new
                // reference instantly (no 1s average — a moving head or a
                // dropped eye during the settle would land the ref somewhere
                // random and make recenter appear dead).
                if (self.manual_recenter) {
                    self.manual_recenter = false;
                    self.ref_mid = center;
                    self.ref_set = true;
                    self.had_ref = true;
                    self.has_last_good = false;
                    if (rot_both) {
                        self.yaw_ref = inter_yaw;
                        self.roll_ref = inter_roll;
                    }
                    self.settle_frames = 0;
                    self.settle_sum = .{ 0, 0, 0 };
                    self.settle_yaw_sum = 0;
                    self.settle_roll_sum = 0;
                    self.settle_yaw_frames = 0;
                } else {
                // Settle window: average the origin before locking the ref so
                // the tracker's acquisition wobble can't become a fixed offset.
                // Also average the absolute interocular yaw/roll so dead-center
                // head → 0° (a seat/calibration offset can't persist).
                for (0..3) |i| self.settle_sum[i] += center[i];
                self.settle_frames += 1;
                if (rot_both) {
                    self.settle_yaw_sum += inter_yaw;
                    self.settle_roll_sum += inter_roll;
                    self.settle_yaw_frames += 1;
                }
                if (self.settle_frames >= settle_target) {
                    for (0..3) |i| {
                        self.ref_mid[i] = self.settle_sum[i] / @as(f64, @floatFromInt(self.settle_frames));
                    }
                    if (self.settle_yaw_frames > 0) {
                        self.yaw_ref = self.settle_yaw_sum / @as(f64, @floatFromInt(self.settle_yaw_frames));
                        self.roll_ref = self.settle_roll_sum / @as(f64, @floatFromInt(self.settle_yaw_frames));
                    }
                    self.ref_set = true;
                    self.had_ref = true;
                    // The ref just moved: re-arm last-good so the new rel_yaw
                    // (≈0 after a recenter) can't trip the 10°/frame glitch
                    // latch against the pre-swap pose, which would freeze yaw
                    // at the old offset forever.
                    self.has_last_good = false;
                    self.settle_frames = 0;
                    self.settle_sum = .{ 0, 0, 0 };
                    self.settle_yaw_sum = 0;
                    self.settle_roll_sum = 0;
                    self.settle_yaw_frames = 0;
                } else if (!self.had_ref) {
                    // Startup: no reference yet — emit zeros until the first
                    // settle completes (~1 s).
                    return .{ 0, 0, 0, 0, 0, 0 };
                }
                }
                // Re-settle (had_ref, manual recenter): fall through and keep
                // tracking with the OLD refs. No freeze, no pop — the refs
                // atomically swap when the new settle completes.
            }
        } else {
            // No valid eye at all (zero-vector shield caught both, or origins
            // are gone). Hold the last full pose instead of snapping to 0 —
            // the view waits here until a NEW pose can be calculated.
            self.was_lost = true;
            return self.last_out;
        }

        // 1. gaze → angles, heavily filtered.
        //    B1: validate the raw gaze before it can poison the pipeline.
        //    The device emits -1.0/-1.0 as the no-tracking sentinel and exact
        //    (0,0) / off-plane values on single-eye garbage frames (confirmed
        //    in the v0.2.1 dumps). Bad frames feed the HOLD so the EWMA, the
        //    corner-hold witness and the rest-follow gaze check never see them.
        const g_raw = sample.gaze_point_2d_norm;
        const g_ok = g_raw[0] >= -0.05 and g_raw[0] <= 1.05 and
            g_raw[1] >= -0.05 and g_raw[1] <= 1.05 and
            !(g_raw[0] == 0.0 and g_raw[1] == 0.0) and
            !(g_raw[0] == -1.0 and g_raw[1] == -1.0);
        if (g_ok) self.last_good_gaze = g_raw;
        //    v0.2.6: convert expanded track box coords → physical screen
        //    coords BEFORE the affine correction (single shared helper
        //    core.deviceToGui — same math as GUI viz and calibration fit).
        //    Device display area = physical × track_box_factor; the physical
        //    screen is CENTERED in the box: device span [0.5−0.5/f, 0.5+0.5/f]
        //    maps to [0,1] on BOTH axes. raw_y grows DOWNWARD (GUI-like), so
        //    Y is NOT inverted (inverting it broke pitch in v0.2.6).
        const f_tb: f64 = @max(p.track_box_factor, 1.0);
        const phys = core.deviceToGui(self.last_good_gaze, f_tb);
        const phys_x = phys[0];
        const phys_y = phys[1];
        //    Phase 2A: error-map-derived correction (see Preset fields),
        //    applied on PHYSICAL coords.
        const y_scale = @max(p.gaze_y_scale, 0.1);
        const x_scale = @max(p.gaze_x_scale, 0.1);
        const g_corr = [2]f64{
            (phys_x + p.gaze_x_offset) / x_scale,
            (phys_y + p.gaze_y_offset) / y_scale,
        };
        // v0.2.7 BATCH_1 fix: while one eye is lost (raw n==1) the device's
        // combined gaze COLLAPSES toward screen center (measured: gaze_yaw
        // swings -1 -> +6 deg while the user stares at the corner). The
        // collapsing signal must NOT feed the gaze tug (it would chase it) nor
        // the eye-ratio ramp (it would read "core zone" -> ratio jumps to 0.80
        // and the tug runs at full strength), but it MUST keep feeding the
        // corner-drift gate and the corner-hold witness (the collapse is what
        // correctly disengages the drift). So the filtered gaze `g` stays LIVE
        // and the FREEZE is applied to the tug output and the ratio only
        // (below): during n=1 both hold the last n=2 corner value.
        const g = self.gaze.filter(g_corr, dt);
        const gaze_yaw = (g[0] - 0.5) * p.gaze_scale;
        const gaze_pitch = (0.5 - g[1]) * p.gaze_scale_pitch;
        // BATCH_2 REWORK: radial (2D) gaze deviation from screen center, in
        // degrees. Upper-left/right corners are DIAGONAL looks — their
        // horizontal gaze component alone is small (< the old yaw-only 10°
        // gates), so every corner gate below (drift engage, ratio floor, corner
        // hold witness) keys on the RADIAL distance instead.
        const gaze_radial_eff = @sqrt(gaze_yaw * gaze_yaw + gaze_pitch * gaze_pitch);
        // Tug-only low-pass: the state filter's pursuit band (α up to 0.25)
        // still passes ±2-3°/frame fixation flicker, which the fine-aim term
        // would render as jitter while the head rests. Corner/gate logic
        // below keeps the raw values.
        // v0.2.7 BATCH_1: during n=1 the tug holds the last n=2 output (do NOT
        // update the filters from the collapsing gaze), and the effective eye
        // ratio below holds its last n=2 value the same way.
        var tug_yaw = self.tug_yaw_f.update(gaze_yaw, dt, tug_smoothing);
        var tug_pitch = self.tug_pitch_f.update(gaze_pitch, dt, tug_smoothing);
        if (n == 1) {
            if (self.has_last_tug) {
                tug_yaw = self.last_tug[0];
                tug_pitch = self.last_tug[1];
            }
        } else {
            self.last_tug = .{ tug_yaw, tug_pitch };
            self.has_last_tug = true;
        }

        // 2. head rotation.
        //    Yaw/roll come from the interocular line when both eyes are
        //    valid: turning the head makes one eye closer (depth difference),
        //    so atan2(ez, ex) is the genuine head-turn angle and atan2(ey, ex)
        //    is the genuine head roll. The center's Δz is never used for
        //    rotation, so leaning forward can't flip the angle to ±180°.
        //    Pitch = atan(dy / neck) (the "two-point problem": two eyes can't
        //    geometrically encode nodding, so it's a biomechanical estimate).
        //
        //    Validation: with one eye (or both-valid-but-glitched), rotation is
        //    FROZEN to the last good pose — one eye cannot measure yaw/roll
        //    without translation crosstalk (atan(dx/neck) flips to ±180° on a
        //    lateral lean), and a swapped/hallucinated eye pair is rejected by
        //    the IPD gate. Translation stays live (IPD-compensated) so you can
        //    still lean. The 10°/frame interocular clamp rejects pre-occlusion
        //    depth spikes so the held pose is always a sane one.
        var head_yaw: f64 = 0;
        var head_pitch: f64 = 0;
        var head_roll: f64 = 0;
        if (has_origins and (self.ref_set or self.had_ref)) {
            const dy = center[1] - self.ref_mid[1];
            const neck_mm = p.neck * 10.0;
            const pitch_est = std.math.atan(dy / neck_mm) * 180.0 / std.math.pi;
            if (rot_both) {
                // Interocular yaw/roll is authoritative whenever BOTH eyes are
                // valid. Use it directly (no fallback blend) so a fast turn
                // can't be fought by the position fallback mid-sweep.
                self.n1_timer = 0;
                // BATCH_2 REWORK v2: back in n=2 — the n=1 drift anchor/dwell
                // state is stale, re-capture on the next n=1 episode.
                self.has_n1_anchor = false;
                self.has_n1_pitch_anchor = false;
                // The n=1 corner drift re-arms ONLY from the genuine n=1
                // branch's gaze dwell — every n=2 frame zeroes the dwell so a
                // corner hold in n=2 can never pre-arm the drift for a later
                // n=1 episode (BATCH_1e: when the device's combined gaze
                // COLLAPSES toward center during n=1, an already-armed drift
                // would chase it and move the held pose). The drift itself,
                // once armed in genuine n=1, survives brief n=2 blips (the
                // debounce path below keeps running it) so quick flickering
                // corner looks still extend.
                self.n1_gaze_dwell = 0;
                var rel_yaw = inter_yaw - self.yaw_ref;
                const rel_roll = inter_roll - self.roll_ref;
                if (!self.has_last_good or self.was_n1 or self.was_lost) {
                    // Fresh n=1→n=2 re-acquisition (or first sample, or the
                    // eyes just came back from a full loss): the n=1 drift may
                    // have left last_good off the real pose by more than
                    // glitch_deg, which the clamp would latch forever. v4.3:
                    // instead of adopting the real pose INSTANTLY (which pops
                    // the curve-amplified output — trace 2026-08-30 showed
                    // 60-80° single-frame pops on every n1→n2), ease
                    // last_good_yaw toward it at n1_catch_rate. The first
                    // sample ever / no last_good still adopts instantly.
                    if (!self.has_last_good) {
                        self.last_good_yaw = rel_yaw;
                        self.n1_catch_active = false;
                    } else {
                        self.n1_catch_target = rel_yaw;
                        self.n1_catch_active = true;
                        const step = n1_catch_rate * dt;
                        const delta = std.math.clamp(rel_yaw - self.last_good_yaw, -step, step);
                        self.last_good_yaw += delta;
                    }
                    self.last_good_roll = rel_roll;
                    // Pitch sanity on re-arm: a tracker eye-Y jump (like a
                    // re-acquisition snapping the Y estimate) would otherwise
                    // be adopted as a "new pose" and pin the view at the pitch
                    // ceiling. Only adopt pitch if it's within a genuine
                    // frame's reach of the last sane one — else keep the last
                    // good pitch ("wait until a new one can be calculated").
                    if (!self.has_last_good or @abs(pitch_est - self.last_good_pitch) <= pitch_glitch_deg) {
                        self.last_good_pitch = pitch_est;
                    }
                    self.last_good_y = center[1];
                    self.has_last_good = true;
                    if (self.was_lost) {
                        // Eyes just came back: reset the smoothers to the
                        // CATCH-UP pose (not the far target) so the eased
                        // re-arm continues smoothly through them — resetting
                        // to the target would snap the output anyway.
                        self.rot_yaw.resetTo(self.last_good_yaw);
                        self.rot_pitch.resetTo(self.last_good_pitch * p.pitch_gain);
                        self.roll_s.resetTo(rel_roll);
                        self.tug_yaw_f.resetTo(gaze_yaw);
                        self.tug_pitch_f.resetTo(gaze_pitch);
                        self.was_lost = false;
                    }
                } else if (self.n1_catch_active) {
                    // Still catching up to the re-acquired pose from a
                    // previous frame: keep easing last_good_yaw at the bounded
                    // rate (do NOT let the glitch clamp freeze it).
                    const step = n1_catch_rate * dt;
                    const delta = std.math.clamp(self.n1_catch_target - self.last_good_yaw, -step, step);
                    self.last_good_yaw += delta;
                    if (@abs(self.n1_catch_target - self.last_good_yaw) < 0.5) self.n1_catch_active = false;
                    self.last_good_roll = rel_roll;
                    if (@abs(pitch_est - self.last_good_pitch) <= pitch_glitch_deg) {
                        self.last_good_pitch = pitch_est;
                    }
                    self.last_good_y = center[1];
                } else if (@abs(rel_yaw - self.last_good_yaw) > glitch_deg or
                    @abs(pitch_est - self.last_good_pitch) > pitch_glitch_deg)
                {
                    // Pre-occlusion hardware spike (impossible depth) or a
                    // tracker eye-Y jump: drop the frame, hold the last known
                    // good pose. Pitch never pins to the ceiling from a Y
                    // glitch — it waits at the last sane position.
                    rel_yaw = self.last_good_yaw;
                } else {
                    self.last_good_yaw = rel_yaw;
                    self.last_good_roll = rel_roll;
                    self.last_good_pitch = pitch_est;
                    self.last_good_y = center[1];
                }
                head_yaw = self.last_good_yaw;
                head_roll = self.last_good_roll;
                head_pitch = self.last_good_pitch;
                self.was_n1 = false;
                // n=2 again: the single-eye anchor is stale, re-capture on the
                // next n=1 transition against this fresh midpoint.
                self.n1_y_anchor_set = false;
                self.n1_y_lp_set = false;
                self.n1_y_anchor_sum = 0;
                self.n1_y_anchor_cnt = 0;
                self.n1_anchor_finalized = false;
            } else if (self.n_eff == 2 and n == 1 and self.has_last_good) {
                // v0.2.7 debounce: a brief one-eye excursion (< 6 frames) while
                // debounced to n=2 — pure HOLD of the last good pose. Running
                // the n=1 machinery here (anchor re-capture, settle window,
                // corner drift) on every flicker is what made corner holds
                // wobble. The pose never leaves last_good, so was_n1 stays
                // false and the return to n=2 is seamless (no re-arm).
                self.n1_timer += dt;
                head_yaw = self.last_good_yaw;
                head_roll = self.last_good_roll;
                head_pitch = self.last_good_pitch;
                // The single-eye anchor/LP are stale after the excursion:
                // re-capture them on the NEXT genuine n=1 episode.
                self.n1_y_anchor_set = false;
                self.n1_y_lp_set = false;
                self.n1_y_anchor_sum = 0;
                self.n1_y_anchor_cnt = 0;
                self.n1_anchor_finalized = false;
                // v4.4: a quick corner look flickers n=1↔2 (debounced) — the
                // pure hold above would FREEZE the view mid-extension. If the
                // corner drift is already ACTIVE (armed in the genuine n=1
                // branch — the dwell never accumulates here), keep easing the
                // held pose toward the gaze-anchored target so the extension
                // continues through the flicker. No anchor re-capture or
                // settle machinery runs in this path (that stays genuine-n1);
                // only the drift step, gated on the arm.
                if (self.n1_drift_active) {
                    _ = self.runCornerDrift(gaze_yaw, gaze_pitch, dt, p);
                    head_yaw = self.last_good_yaw;
                    head_pitch = self.last_good_pitch;
                }
            } else {
                // One eye (or a glitched pair): HOLD yaw/roll, keep pitch live.
                // Head ROTATION does not translate the eye midpoint (it
                // pivots), so a fallback to the center's lateral angle
                // measures translation, not rotation — it would collapse yaw
                // toward 0 and snap the view back to center at the tracking
                // edge. So yaw/roll freeze at the last-good pose. But pitch is
                // atan(dy/neck) from center-Y = genuine translation, which a
                // single (IPD-compensated) eye still measures, so it stays
                // LIVE. Both eyes return -> interocular resumes seamlessly.
                //
                // Corner continuation: at far turns the NEAR eye is occluded
                // by the nose and n stays 1 for a long stretch — a pure
                // freeze makes the view "stop at halfway" and jitter when the
                // eye re-acquires. The remaining eye still tracks the head's
                // lateral translation, which correlates with the turn:
                // yaw1e = atan(dx / neck) is calibrated to the interocular
                // scale (post-gain hp ≈ 0.36·yaw1e on this rig), and we ease
                // the held pose toward it, rate-limited so lean crosstalk or
                // noise can't snap the view.
                self.n1_timer += dt;
                if (!self.has_last_good and !self.n1_y_anchor_set) {
                    self.last_good_yaw = 0;
                    self.last_good_roll = 0;
                    self.last_good_pitch = pitch_est;
                    self.last_good_y = center[1];
                    self.has_last_good = true;
                    // No n=2 midpoint to anchor against (first sample is n=1):
                    // adopt the raw single-eye Y as the anchor so the effective
                    // Y is a no-op this episode. finalized=true: no settle
                    // window exists to average, so skip the window-mean path.
                    self.n1_y_anchor = center[1];
                    self.n1_y_base = center[1];
                    self.n1_y_anchor_set = true;
                    self.n1_anchor_finalized = true;
                    self.n1_settle = 0;
                    self.n1_y_lp = center[1];
                    self.n1_y_lp_set = true;
                }
                // Single-eye Y anchor: at the n=2→1 transition the remaining
                // (far) eye's raw Y sits off the true eye midpoint and the
                // estimate can drift over the first ~0.5 s — adopting it
                // directly pins pitch up/down at corner holds (the +17 mm Y
                // step that climbed pitch to the ceiling). So on the first n=1
                // frame we anchor the single-eye Y to the last n=2 midpoint,
                // HOLD pitch through a short settle window, then track Y
                // changes from the anchored baseline — a genuine head-pitch
                // move still registers, the transition bias does not.
                if (!self.n1_y_anchor_set) {
                    // v0.2.7: do NOT pin the anchor to the single-eye Y at the
                    // transition INSTANT — if the jaw is mid-wobble the anchor
                    // lands on a phase value and settle-end is left with a
                    // fixed DC pitch step that saturates the pitch One-Euro
                    // (fc max for ~1 s → the 2-5 Hz jaw wobble passes at
                    // near-full gain). Accumulate the single-eye Y over the
                    // settle window and anchor to the window MEAN (finalized
                    // on the first post-settle frame below).
                    self.n1_y_anchor_sum = center[1];
                    self.n1_y_anchor_cnt = 1;
                    self.n1_anchor_finalized = false;
                    self.n1_y_base = self.last_good_y;
                    self.n1_settle = 0;
                    self.n1_y_anchor_set = true;
                    self.n1_y_lp = center[1];
                    self.n1_y_lp_set = true;
                }
                self.n1_settle += dt;
                // Accumulate the single-eye Y across the settle window so the
                // anchor can be the MEAN (kills the transition-phase DC step).
                if (self.n1_y_anchor_set and !self.n1_anchor_finalized) {
                    self.n1_y_anchor_sum += center[1];
                    self.n1_y_anchor_cnt += 1;
                }
                // v0.2.7: low-pass the raw single-eye Y during the n=1 episode —
                // the far eye's raw Y carries mm-scale jaw/cheek wobble at
                // corners that otherwise lands straight in the pitch output.
                // The settle window already holds n1_y_base; this LP cleans the
                // post-settle tracking path. alpha 0.06 (NOT the draft's 0.3):
                // at 90 Hz an EWMA with alpha 0.3 has a ~5.1 Hz cutoff — gain
                // 0.86 at 3 Hz, so the 2-5 Hz jaw band passed through almost
                // unchanged (measured output spread 4.6°). alpha 0.06 gives a
                // ~1.2 Hz cutoff (~28% of a 3 Hz wobble leaks) while keeping
                // ~180 ms response for genuine pitch moves. Measured: the ±3 mm
                // @ 3 Hz synthetic wobble now yields 1.7° output pitch spread
                // (passes the 2° invariant) — and sweeping alpha 0.03→0.10
                // changes that spread by <0.01°, because the residual rides a
                // SECONDARY path: the wobble's head_pitch deltas toggle the
                // VOR direction gate (dot = dPitch·gaze_pitch < 0 half the
                // phase), which modulates the constant gaze tug through
                // eye_ratio — BATCH_4's n=1 pitch-velocity clamp kills it at
                // the source. BATCH_4 adds the data-derived velocity clamp.
                if (!self.n1_y_lp_set) {
                    self.n1_y_lp = center[1];
                    self.n1_y_lp_set = true;
                } else {
                    self.n1_y_lp += 0.06 * (center[1] - self.n1_y_lp);
                }
                // Settle window ended: finalize the anchor as the window MEAN
                // and re-seed the LP to it, so the effective Y starts at ~0 DC
                // (base) instead of stepping by (transition_phase - mean) —
                // the step is what used to saturate the pitch One-Euro.
                if (self.n1_settle >= n1_y_settle_s and !self.n1_anchor_finalized) {
                    const n1_y_mean = self.n1_y_anchor_sum / @as(f64, @floatFromInt(self.n1_y_anchor_cnt));
                    self.n1_y_anchor = n1_y_mean;
                    self.n1_anchor_finalized = true;
                    self.n1_y_lp = n1_y_mean;
                }
                const n1_y_eff = if (self.n1_settle < n1_y_settle_s)
                    self.n1_y_base // hold during the settle: no bias, no drift
                else
                    self.n1_y_lp - (self.n1_y_anchor - self.n1_y_base);
                const n1_pitch = std.math.atan((n1_y_eff - self.ref_mid[1]) / neck_mm) * 180.0 / std.math.pi;
                // Y-sanity on the EFFECTIVE Y: even anchored, a single-eye Y
                // can't jump ~25 mm from the last midpoint (eyes are level;
                // even a 20° head roll is only ~23 mm). A jump beyond that is
                // a tracker artifact (the f3640-style eye-Y glitch) — hold the
                // last sane pitch instead of letting it pin the view.
                var n1_pitch_out = n1_pitch;
                if (@abs(n1_y_eff - self.last_good_y) > n1_y_sanity_mm) {
                    n1_pitch_out = self.last_good_pitch;
                } else {
                    self.last_good_pitch = n1_pitch;
                    self.last_good_y = n1_y_eff;
                }
                // Corner continuation: at far turns the NEAR eye is occluded
                // by the nose and n stays 1 for a long stretch — a pure
                // freeze makes the view "stop at halfway". The remaining eye
                // still tracks the head's lateral translation, which
                // correlates with the turn: yaw1e = atan(dx / neck) is
                // calibrated to the interocular scale. Ease the held pose
                // toward it — but ONLY once the GAZE is pinned toward the
                // screen edge: the interocular yaw estimate itself COLLAPSES
                // just before the near eye is occluded (the atan2 saturates
                // at the tracking edge), so |last_good_yaw| is small right
                // when the user is staring at the screen edge and the drift
                // would otherwise never engage. The pinned gaze is the
                // reliable "at the corner" witness. Near center the single-eye
                // dx is dominated by lean/translation, so we stay frozen there.
                // BATCH_2 (FIXED in build): the drift target must live in
                // last_good_yaw (raw pre-flip, pre-gain) units and continue the
                // turn TOWARD the screen edge. The original formula
                // n1_target = authority * yaw1e / (head_gain * flip_sign) was
                // sign-inverted AND mis-scaled: for a neck-pivot turn the head
                // center translates the OPPOSITE way in x from the raw-yaw sign
                // (pivotTurn(+25°) -> inter_yaw −25 while center[0]−ref[0] =
                // +55 mm), so yaw1e was positive while last_good_yaw was −25 —
                // the drift eased the held pose BACK toward center (dbg6
                // measured the n=1 continuation SAG 132° -> 69° vs the 153°
                // full-turn reference). The single-eye lateral translation IS
                // the full-turn estimate, just sign-inverted relative to the
                // yaw convention, so turn_est = −asin(dx/neck) recovers the
                // geometric angle (asin is the exact inverse of the pivot
                // translation dx = neck·sin(turn); atan under-reads by ~13% at
                // 25°). authority (0.70) is the per-frame PROPORTIONAL gain
                // chasing the LIVE estimate (rate-limited 15 deg/s pre-gain),
                // and the drift is bounded on THREE sides (BATCH_2 REWORK
                // after the user gate FAILED on the real device):
                //   1) OUTWARD-ONLY on the GAZE side — the pose may only extend
                //      deeper into the turn the user is looking at, never back
                //      toward center (kills the 5-10% inward jump; also blocks
                //      a device eye-origin reversal mid-hold).
                //   2) ANCHOR BOUND — the pose may never extend more than
                //      n1_extra_max_deg (15°) raw past the n=2 occlusion turn
                //      (n1_anchor_yaw). On the real device the single-eye
                //      origin CREEPS outward while the user holds the corner,
                //      so turn_est grows and the OLD drift chased it to the
                //      output ceiling (~90° view swing) — the anchor bound is
                //      the hard stop.
                //   3) VELOCITY GATE — the drift only runs while turn_est is
                //      genuinely MOVING (> n1_est_move_deg over the ~0.5 s
                //      filter window ≈ 2 deg/s). A held corner has a
                //      static/wobbling eye origin, so once the user stops
                //      turning the drift freezes at the current pose instead
                //      of following the device's slow origin drift.
                // Engagement is HYSTERETIC and RADIAL: engage when the 2D gaze
                // deviation (yaw AND pitch) exceeds corner_engage_deg (10°),
                // disengage below corner_disengage_deg (6°). The radial gate is
                // what lets upper-left/right corners engage — a diagonal look
                // has a small horizontal gaze component that never crossed the
                // old yaw-only 10° threshold ("upper corners still not
                // recognized").
                // BATCH_2 REWORK v2 (user gate FAILED twice): the drift target
                // is GAZE-ANCHORED, not the live translation. The old target
                // chased turn_est = −asin(dx/neck) of the REMAINING eye, which
                // CREEPS outward on the real device while the user holds a
                // corner — the RD trace showed gaze pinned gy 13-19 (stable)
                // while the translation carried lg −4.07 → −18.12 to the
                // anchor+15 bound = the 90° view swing the user rejected. The
                // GAZE is STABLE while holding, so a gaze-anchored target is
                // stable: the drift converges to the corner the user looks at
                // and STOPS (no creep). Engagement is a GAZE-DWELL (radial >
                // corner_engage_deg AND |gaze_yaw| > 2 sustained
                // n1_gaze_dwell_s) — the old translation-velocity gate froze
                // the drift at upper corners (eyes-only look, head still →
                // est_motion 0 → "upper corners never engage"). Radial gate
                // covers diagonal upper-corner looks. The pitch gets the same
                // gaze-anchored treatment so lower corners stop diving toward
                // 90° and upper corners follow the up-look.
                // Anchor: the n=2 raw yaw/pitch at the moment the eye was lost.
                // This is the TRUE pose the interocular measured before
                // occlusion — the drift's excursions are measured from it.
                if (!self.has_n1_anchor and self.has_last_good) {
                    self.n1_anchor_yaw = self.last_good_yaw;
                    self.has_n1_anchor = true;
                    self.n1_pitch_anchor = self.last_good_pitch;
                    self.has_n1_pitch_anchor = true;
                }
                const gaze_radial = @sqrt(gaze_yaw * gaze_yaw + gaze_pitch * gaze_pitch);
                const at_corner = gaze_radial > corner_engage_deg and @abs(gaze_yaw) > 2.0;
                const left_corner = gaze_radial < corner_disengage_deg or @abs(gaze_yaw) < 2.0;
                if (at_corner) {
                    self.n1_gaze_dwell += dt;
                    if (self.n1_gaze_dwell >= n1_gaze_dwell_s) self.n1_drift_active = true;
                } else if (left_corner) {
                    self.n1_gaze_dwell = 0;
                    self.n1_drift_active = false;
                }
                if (self.n1_drift_active) {
                    // v4.4: the drift step is shared between the genuine n=1
                    // branch and the n=1 debounce hold (see runCornerDrift for
                    // the v2/v3/v4 design: gaze-anchored target, OUTPUT-space
                    // cap via invertCurve, live lg clamp at the edge).
                    n1_pitch_out = self.runCornerDrift(gaze_yaw, gaze_pitch, dt, p);
                }
                // v4.3: non-corner n=1 follow. The corner drift above only
                // runs when the gaze is pinned at the edge. During a FAST turn
                // the gaze often is NOT pinned (the user is sweeping through
                // the game), yet one eye is occluded — the old code froze the
                // view entirely, so when both eyes returned the re-arm snapped
                // the whole accumulated turn (trace 2026-08-30: 206 jumps
                // >10°, all n1→n2 re-acquisitions). The center TRANSLATION is
                // live during n=1 and equals the geometric turn: turn_est =
                // −asin(dx/neck) (the exact inverse of the pivot translation,
                // same convention as the corner drift). Ease last_good_yaw
                // toward it at n1_follow_rate, gated on genuine motion (a
                // held corner has a static dx — no creep; a lean is slow).
                // Skipped while the corner drift owns last_good_yaw.
                if (!self.n1_drift_active) {
                    const dx_center = center[0] - self.ref_mid[0];
                    const turn_est = -std.math.asin(std.math.clamp(dx_center / neck_mm, -1.0, 1.0)) * 180.0 / std.math.pi;
                    const est_dv = @abs(turn_est - self.n1_last_turn_est) / @max(dt, 1e-6);
                    self.n1_last_turn_est = turn_est;
                    if (est_dv > n1_est_move_deg_s and @abs(turn_est - self.last_good_yaw) > n1_turn_min_deg) {
                        const follow = n1_follow_rate * dt;
                        self.last_good_yaw += std.math.clamp(turn_est - self.last_good_yaw, -follow, follow);
                    }
                } else {
                    self.n1_last_turn_est = -std.math.asin(std.math.clamp((center[0] - self.ref_mid[0]) / neck_mm, -1.0, 1.0)) * 180.0 / std.math.pi;
                }
                head_yaw = self.last_good_yaw;
                head_roll = self.last_good_roll;
                head_pitch = n1_pitch_out;
                self.was_n1 = true;
            }
            if (p.flip_yaw) head_yaw = -head_yaw;
            if (p.flip_pitch) head_pitch = -head_pitch;
            head_yaw *= p.head_gain;
            head_pitch *= p.head_gain;
        }

        // 3. blend (OEM 85/15) + pitch boost + smoothing. Rotation smoothing follows
//    the selected SmoothMode (One Euro by default); the reject-and-hold
//    spike rejection now lives at the interocular clamp above.
//
//    The gaze share is gated by head yaw speed: while the head is rotating,
//    the eyes counter-rotate (VOR), so adding the fast gaze signal would fire
//    a short spike OPPOSITE to the turn. At rest (or slow aiming), gaze blends
//    fully as the fine-aim "tug". Gate eases 8 → 25 °/s, 1 → 0.
        const mode: SmoothMode = @enumFromInt(@min(p.smooth_mode, @intFromEnum(SmoothMode.none)));
        const head_dv_yaw = if (self.has_last_head_yaw and dt > 0)
            head_yaw - self.last_head_yaw
        else
            0.0;
        const head_dv_pitch = if (self.has_last_head_pitch and dt > 0)
            head_pitch - self.last_head_pitch
        else
            0.0;
        const head_speed = @sqrt(head_dv_yaw * head_dv_yaw + head_dv_pitch * head_dv_pitch) / @max(dt, 1e-6);
        self.last_head_yaw = head_yaw;
        self.last_head_pitch = head_pitch;
        self.has_last_head_yaw = true;
        self.has_last_head_pitch = true;
        // Gaze is the fine-aim "tug" — but only when it AGREES with the head's
        // turn direction. The VOR reflex counter-rotates the eyes during a head
        // turn, so an opposing gaze is exactly the artifact that fired the
        // "counter-move right when turning left fast" spike (and worse on one
        // side where the eye-loss fallback + gate timing align). Direction-aware
        // on the FULL velocity vector (yaw AND pitch): an opposing glance on
        // either axis is dropped (this also kills the phantom pitch when the
        // head nods but the eyes glance vertically).
        //   gate = 0 if head moving AND gaze opposes head velocity (drop VOR)
        //           else speed-based 8..25 deg/s taper (aiming while still)
        const dot = head_dv_yaw * gaze_yaw + head_dv_pitch * gaze_pitch;
        const dir_gate: f64 = if (head_speed > 5.0 and dot < 0.0) 0.0 else 1.0;
        const speed_gate = if (head_speed <= 8.0)
            1.0
        else if (head_speed >= 25.0)
            0.0
        else
            1.0 - (head_speed - 8.0) / 17.0;
        const gate = dir_gate * speed_gate;
        // Ease the gate so the gaze tug fades in/out instead of stepping
        // (a 1↔0 snap moves the output by ±gaze·ratio in one frame).
        const gate_react: f64 = 8.0; // 1/s — ~120 ms to re-arm the tug
        self.gate_smooth += (gate - self.gate_smooth) * @min(1.0, dt * gate_react);
        const gate_eff = self.gate_smooth;

        // Head-only rotation smoothing. The gaze is added AFTER the response
        // curve (below) as a small absolute-degree offset, so the steep head
        // curve can no longer amplify a glance into a fake ~25° turn. Gaze
        // stays a subtle fine-aim tug. pitch_gain is applied pre-curve exactly
        // as before so the head pitch boost is unchanged.
        var yaw = self.rot_yaw.update(head_yaw, dt, mode, p.smoothing, 10.0);
        const pitch = self.rot_pitch.update(head_pitch * p.pitch_gain, dt, mode, p.smoothing, 10.0);
        const roll = self.roll_s.update(head_roll, dt, mode, p.smoothing, 10.0);

        // 3c. Gaze-witnessed corner hold. At the far corner the interocular
        //     yaw estimate saturates/reverses (the eyes approach the tracking
        //     edge while both stay "seen"), so the view collapses back toward
        //     center despite the user still staring at the screen edge. The
        //     pinned gaze is the witness: while |gaze| stays beyond
        //     corner_pin_deg on one side, feed the last reliable peak back
        //     into the pipeline so the view WAITS at the corner. The smoother
        //     state converges to the peak, so when the gaze unpins the view
        //     sweeps back naturally at the smoothing rate — no pop.
        //     BATCH_2 REWORK: the witness gate is RADIAL (yaw AND pitch) with a
        //     minimum |gaze_yaw| — a diagonal upper-corner look engages the
        //     hold even though its horizontal gaze component alone is small,
        //     while a pure top/bottom-center look (|gaze_yaw| ≈ 0) does not.
        const gaze_side = std.math.sign(gaze_yaw);
        // v4.2: head-return witness. The hold may only pin the peak while the
        // user is still displaced toward the corner they look at. Measure the
        // return from the ENGAGE position toward the ref (self-anchoring — no
        // reliance on the ref being exact): back_mm > 0 when the center moved
        // back toward the ref, growing as the head returns. The head rotation
        // signal is frozen during n=1, but the IPD-compensated center
        // translation is live in BOTH n=1 and n=2 — trace 2026-08-30 proved
        // the user's head can sweep back (center X -63 -> +29 mm) while the
        // interocular/rotation holds still AND the gaze stays pinned; without
        // this witness the view stayed at the corner peak the whole way and
        // popped +182° in one frame when the gaze finally unpinned. Once the
        // witness fires, LATCH the release (corner_release_latch) so the hold
        // can't re-pin at the new position while the gaze is still at the edge;
        // the latch clears when the gaze unpins.
        const cenx_engage_off = self.corner_hold_cenx - self.ref_mid[0];
        const back_mm = (self.corner_hold_cenx - center[0]) * std.math.sign(cenx_engage_off);
        const head_returned = self.corner_hold and back_mm > corner_hold_release_mm;
        const gaze_pinned = gaze_radial_eff > corner_pin_deg and @abs(gaze_yaw) > 3.0;
        if (head_returned) {
            self.corner_hold = false;
            self.corner_side = 0;
            self.corner_hold_cenx = 0;
            self.corner_release_latch = true;
            // Start easing the held view back from the value the output
            // ACTUALLY held: the pinned peak if the pin was active last frame,
            // else the live yaw (deep turns past the capped peak never pin —
            // starting from the capped witness when the output never sat there
            // would snap the return, BATCH_2i). v4.5: the peak is also the
            // held value when the estimate sits EXACTLY on it (pin only engages
            // after the sag exceeds the hysteresis) — see cornerReleaseStart.
            self.corner_release_ease = self.cornerReleaseStart(yaw, gaze_side);
            self.corner_pin_active = false;
            self.corner_peak = 0;
            self.corner_held_yaw = 0;
        } else if (gaze_pinned and !self.corner_release_latch) {
            // v4.4: the hold peak is capped at the OUTPUT edge (post-gain
            // pre-curve units — the corner_peak is fed straight into the
            // curve, so cap the peak at the input that maps to
            // n1_drift_max_out_deg output). Without this a deep n=2 turn
            // (124° output on the rig) was pinned for the whole occluded
            // hold — the user's "creep" (trace 2026-08-30: holds at 104-124°).
            const hold_edge_in = invertCurve(
                @enumFromInt(p.curve_mode),
                n1_drift_max_out_deg,
                p.max_yaw,
                p.curve_exp,
                false,
            );
            if (!self.corner_hold or self.corner_side != gaze_side) {
                self.corner_hold = true;
                self.corner_side = gaze_side;
                self.corner_peak = std.math.clamp(yaw, -hold_edge_in, hold_edge_in);
                self.corner_hold_cenx = center[0];
                self.corner_pin_active = false;
                self.corner_held_yaw = 0;
            } else if (yaw * gaze_side > self.corner_peak * gaze_side) {
                self.corner_peak = std.math.clamp(yaw, -hold_edge_in, hold_edge_in); // turning deeper — track the new peak
            }
            // v4.6: n=2 corner REACH — the "upper-left rarely works" gap (user
            // gate v4.5, trace @2858-2866: hp only -7.4..-9.8, rw -54, fy -57 —
            // the view never got past ~57° of the natural ~95° edge). With BOTH
            // eyes tracked the interocular estimate still saturates/reverses at
            // the tracking edge, and the n=1 path had the only gaze-anchored
            // reach mechanism. Mirror it here: extend corner_peak toward
            // corner_peak + side·|gaze_yaw|·n1_gaze_gain·head_gain at
            // n1_drift_rate·head_gain, outward-only, capped at the natural edge
            // (hold_edge_in — the same OUTPUT-space cap that ended the 90°
            // creep). The pin below then holds yaw at the extended peak: the
            // view glides to the edge and stops (a held corner gaze is stable,
            // so the target stops moving — no creep).
            if (self.n_eff == 2) {
                const ext_out = @abs(gaze_yaw) * n1_gaze_gain * p.head_gain;
                const reach_target = std.math.clamp(self.corner_peak + gaze_side * ext_out, -hold_edge_in, hold_edge_in);
                if ((reach_target - self.corner_peak) * gaze_side > 0) {
                    const reach_step = n1_drift_rate * p.head_gain * dt;
                    self.corner_peak += std.math.clamp(reach_target - self.corner_peak, -reach_step, reach_step);
                }
            }
            // v4.4: the pin is capped (peak already clamped to the edge) AND
            // same-side-only: the yaw must be on the GAZE side of center before
            // the peak can hold it. A deep turn with the gaze pinned to the
            // OPPOSITE side (synthetic n=1 collapse tests) must never be
            // yanked to the (capped) peak — the view simply follows the live
            // signal there. corner_pin_active records whether the output is
            // actually pinned, so the release ease starts from the right value.
            if (yaw * gaze_side > 0 and (yaw - self.corner_peak) * gaze_side < -corner_hyst_deg) {
                yaw = self.corner_peak; // estimate sagging — hold the peak
                self.corner_pin_active = true;
            } else {
                self.corner_pin_active = false;
                // v4.6: rotation-cross release (@449 pop). The same-side pin
                // guard above hard-fails when the head-rotation estimate
                // crosses CENTER while the gaze is still pinned (trace @449:
                // yaw +6.76 -> -0.54, hp -1.93 -> -2.51, gy +15) — the
                // translation witness (back_mm) lags this fast return, so
                // without this branch yaw reverted to the live signal in ONE
                // frame (fy 44.52 -> -1.67). Release like head_returned:
                // ease from the value the output actually held.
                if (self.corner_hold and yaw * gaze_side <= 0 and self.corner_release_ease == 0) {
                    self.corner_hold = false;
                    self.corner_side = 0;
                    self.corner_hold_cenx = 0;
                    self.corner_release_latch = true;
                    self.corner_release_ease = self.cornerReleaseStart(yaw, gaze_side);
                    self.corner_pin_active = false;
                    self.corner_peak = 0;
                    self.corner_held_yaw = 0;
                }
            }
            // v4.6: record the value the output actually held this frame while
            // a hold is active (post-pin yaw). Consumed by cornerReleaseStart's
            // crossed-yaw release. Skipped when the cross-release above fired
            // (corner_hold cleared — the recorded value must stay the LAST
            // frame's held value, which cornerReleaseStart just read).
            if (self.corner_hold) self.corner_held_yaw = yaw;
        } else if (!gaze_pinned) {
            // Gaze unpinned: full reset AND clear the release latch — the next
            // genuine corner can engage fresh. If the hold was still active,
            // start the release ease from the value the output actually held
            // (pinned peak or live yaw — same reasoning as the head-return
            // release; the head may be anywhere and the view must not snap).
            // (When gaze_pinned AND latched, the hold stays released — do
            // nothing this frame.)
            if (self.corner_hold) self.corner_release_ease = self.cornerReleaseStart(yaw, gaze_side);
            self.corner_hold = false;
            self.corner_side = 0;
            self.corner_peak = 0;
            self.corner_hold_cenx = 0;
            self.corner_release_latch = false;
            self.corner_pin_active = false;
            self.corner_held_yaw = 0;
        }
        // Release ease: sweep the held view back toward the live signal at a
        // bounded rate — no one-frame pop, but fast enough to follow a real
        // head return. Runs while corner_release_ease != 0.
        // v4.5: the step is scaled by the local curve slope so the OUTPUT
        // moves at corner_release_rate_deg_s everywhere (near the corner the
        // spline edge is ~4x — a flat pre-curve step was 225°/s of output),
        // and the catch-up check is in OUTPUT space (a 0.5° pre-curve gap at
        // the edge is ~2° of output — the old check cleared the ease early
        // and let the last bit pop).
        if (self.corner_release_ease != 0) {
            const target = yaw;
            const step_out = corner_release_rate_deg_s * dt;
            const step = step_out / yawCurveSlope(p, self.corner_release_ease);
            const eased = self.corner_release_ease + std.math.clamp(target - self.corner_release_ease, -step, step);
            const gap_out = @abs(applyCurve(@enumFromInt(p.curve_mode), target, p.max_yaw, p.curve_exp, false) -
                applyCurve(@enumFromInt(p.curve_mode), eased, p.max_yaw, p.curve_exp, false));
            if (gap_out < 0.5) {
                self.corner_release_ease = 0; // caught up — back to live
            } else {
                self.corner_release_ease = eased;
            }
            yaw = eased;
        }

        // 3d. Rest-follow ref (gentle). The ref is captured once at startup
        //     or on Recenter, but seat drift / tracker baseline leaves the
        //     eye-Y offset stuck — with no auto-recenter that pins pitch at
        //     the 90° ceiling for the whole session. When the head is
        //     genuinely at rest AND the gaze sits near SCREEN CENTER (both
        //     axes) AND the output pose is near center, very slowly nudge the
        //     ref toward the current pose. The gaze-center requirement is what
        //     makes this safe: looking anywhere else (reading, a held
        //     down-look) must never re-zero, or the view wanders off while
        //     the user holds still. Corners are refused via corner_hold and
        //     the pinned-gaze check.
        const dt_r = @min(dt, 0.1);
        const rest_speed = (@abs(yaw - self.last_rest_yaw) + @abs(pitch - self.last_rest_pitch)) / @max(dt_r, 1e-6);
        self.last_rest_yaw = yaw;
        self.last_rest_pitch = pitch;
        if (rest_speed < rest_vel_deg_s) {
            self.rest_time += dt_r;
        } else {
            self.rest_time = 0;
        }
        const rest_engaged = self.rest_time >= rest_follow_s and
            !self.corner_hold and
            @abs(gaze_yaw) <= rest_gaze_deg and @abs(gaze_pitch) <= rest_gaze_deg and
            @abs(yaw) <= rest_center_deg and @abs(pitch) <= rest_center_deg;
        if (rest_engaged) {
            const r = rest_follow_rate * dt / 0.0111; // normalized to ~90fps
            for (0..3) |i| self.ref_mid[i] += r * (center[i] - self.ref_mid[i]);
            if (rot_both) {
                self.yaw_ref += r * (inter_yaw - self.yaw_ref);
                self.roll_ref += r * (inter_roll - self.roll_ref);
            }
            // The ref just moved: the interocular rel_yaw changed, so re-arm
            // last-good to avoid tripping the glitch clamp against the old
            // pose (which would freeze yaw at the pre-follow offset).
            self.has_last_good = false;
        }

        // 3e. B3 safety net: pitch pinned at the ceiling with centered gaze.
        //     The v0.2.1 diagnosis: the raw gaze-y bias (center reads 0.245,
        //     not 0.5) made gaze_pitch sit outside rest-follow's ±4° window,
        //     so the eye-Y baseline never decayed and pitch pinned at ±90°
        //     all session. The 2A correction fixes the cause; this net covers
        //     residual baseline errors that still leave |pitch| stuck ≥19° for
        //     >2 s while the (corrected) gaze is at screen center. Nudge the
        //     ref baseline toward the current pose at a bounded rate — fast
        //     enough to unbind a stuck session, slow enough that a genuinely
        //     held high-look or a corner stare (corner_hold) is never dragged.
        if (@abs(pitch) >= pitch_pin_deg) {
            self.pitch_pin_time += dt_r;
        } else {
            self.pitch_pin_time = 0;
        }
        if (self.pitch_pin_time >= pitch_pin_s and !self.corner_hold and
            @abs(gaze_yaw) <= rest_gaze_deg and @abs(gaze_pitch) <= rest_gaze_deg)
        {
            const r = pitch_pin_rate * dt / 0.0111; // normalized to ~90fps
            self.ref_mid[1] += r * (center[1] - self.ref_mid[1]);
            // The ref moved: re-arm last-good like rest-follow does.
            self.has_last_good = false;
        }

        // 3b. Pre-curve deadzone: zero the smoother output before the
        //     Catmull-Rom curve if below threshold. Kills 0.01° smoother noise
        //     before the 5-7.5× curve slope amplifies it.
        var yaw_pre = yaw;
        var pitch_pre = pitch;
        if (@abs(yaw) < p.pre_curve_dz) yaw_pre = 0;
        if (@abs(pitch) < p.pre_curve_dz) pitch_pre = 0;

        // 3c. Adaptive eye ratio — 3 zones based on gaze distance from center.
        //     Core (< core_zone_radius): eyes dominate (eye_ratio_core).
        //     Middle (core_zone_radius – 4×): linear ramp core→edge.
        //     Edge (> 4×): head dominates (eye_ratio).
        const gx = g[0] - 0.5;
        const gy = g[1] - 0.5;
        const gaze_dev = @sqrt(gx * gx + gy * gy);
        const core_r = p.core_zone_radius;
        const mid_outer = core_r * 4.0;
        const ratio_live = if (gaze_dev < core_r)
            p.eye_ratio_core
        else if (gaze_dev < mid_outer)
            p.eye_ratio_core + (p.eye_ratio - p.eye_ratio_core) * (gaze_dev - core_r) / (mid_outer - core_r)
        else
            p.eye_ratio;
        // BATCH_2: corner eye-ratio FLOOR. The edge ramp drops the ratio to 0.15
        // at the screen edge, but at a corner the user is staring at the very
        // edge — the gaze tug should keep PULLING there (the ±3° at 0.15 was
        // why the view sagged inward ~5-10%). While the gaze is pinned toward
        // the edge (beyond the drift-engage threshold, RADIAL so upper corners
        // count), never let the ratio fall below corner_ratio_floor (0.35):
        // the gaze keeps contributing ±7° of fine-aim at the corner. (The n=1
        // freeze below still holds the last n=2 value during one-eye episodes.)
        const ratio_effective = if (gaze_radial_eff > corner_engage_deg and @abs(gaze_yaw) > 2.0 and ratio_live < corner_ratio_floor)
            corner_ratio_floor
        else
            ratio_live;
        // v0.2.7 BATCH_1: during n=1 the combined gaze collapses toward center,
        // so a LIVE ratio would jump to eye_ratio_core (0.80) mid-hold — on a
        // pose that is otherwise held. Hold the last n=2 ratio for the n=1
        // episode so the tug term (frozen above) keeps its corner strength.
        const effective_eye_ratio = if (n == 1 and self.has_last_ratio_n2)
            self.last_ratio_n2
        else blk: {
            if (n == 2) self.last_ratio_n2 = ratio_effective;
            self.has_last_ratio_n2 = true;
            break :blk ratio_effective;
        };
        self.last_ratio = effective_eye_ratio;

        // 4. Response curve + cap + deadzone on the HEAD signal, then add the
        //    gated gaze as a small absolute-degree fine-aim offset in OUTPUT
        //    space (post-curve). This keeps the gaze a subtle tug regardless of
        //    how steep the head curve is. The flip applies to the head signal
        //    above (line ~722) AND to the gaze offset here, so they always
        //    point the same way.
        const fy_head = deadzone(applyCurve(
            @enumFromInt(p.curve_mode),
            yaw_pre,
            p.max_yaw,
            p.curve_exp,
            false,
        ), p.deadzone);
        const fp_head = deadzone(applyCurve(
            @enumFromInt(p.curve_mode),
            pitch_pre,
            p.max_pitch,
            p.curve_exp,
            true,
        ), p.deadzone);
        // Gaze tug direction: gaze screen coords (right/up = +) already match
        // the X4 output convention, so the flip must apply to the HEAD signal
        // only. Flipping the gaze too (old code) inverted the tug: glance
        // right → view yanked left, and with the binary gate snapping 1↔0 it
        // stepped ±(gaze·ratio) in one frame (up to ~10° at 0.47 ratio).
        // BATCH_2 v4.1: eased output-space cap on the gaze TUG contribution (OUTPUT deg).
        // The v3 cap holds the DRIFT at the natural edge (95°), but the tug is
        // added AFTER that cap (fy = fy_head + tug·er·ge) and was pushing the
        // final output to ~102.7° while the user HELD a corner — the corner
        // ratio floor (0.35) × gate_eff→1.0 ramped a +7.7° tug on top of the
        // already-capped 95°. Target = the headroom below the edge, eased fast
        // (~25 ms) so the tug fades as fy_head crosses the band without
        // snapping (a hard clamp stepped ~7° in one frame).
        //   v4 (banded, upper bound 95+12=107) killed the creep at the natural
        //   edge but NOT at deep corner holds: the real-rig user holds corners
        //   at rw 107-130° (head_gain 2.0 + Tobii spline edge), past the band
        //   the tug re-enabled +4.5-5° and the user still saw expansion
        //   ("still creeping, not so extreme"). v4.1 makes the band ONE-SIDED:
        //   it tightens for EVERY |fy_head| at/past the edge (>= 83), so the
        //   tug fades to zero at any depth. BATCH_1e (n=1 frozen-tug hold at
        //   fy=-160) is protected by the n==1 rule: never RELAX the clamp
        //   during an n=1 episode — a frozen tug must not be re-injected into
        //   a held pose (relaxation only happens live in n=2, where the tug is
        //   a real fine-aim signal).
        const afh = @abs(fy_head);
        const tug_target: f64 = if (afh >= n1_drift_max_out_deg - tug_edge_band)
            @max(n1_drift_max_out_deg - afh, 0.0)
        else if (n == 1)
            self.tug_out_clamp // n=1: hold — never relax a tightened clamp mid-episode
        else
            n1_drift_max_out_deg;
        self.tug_out_clamp += (tug_target - self.tug_out_clamp) * @min(1.0, dt * 40.0);
        const tug_out = std.math.clamp(tug_yaw * effective_eye_ratio * gate_eff, -self.tug_out_clamp, self.tug_out_clamp);
        const fy = fy_head + tug_out;
        const fp = fp_head + tug_pitch * effective_eye_ratio * gate_eff;

        if (std.posix.getenv("TOBII_TRACE") != null) {
            var buf2: [96]u8 = undefined;
            const both = if (sample.validity_L == 0 and sample.validity_R == 0) blk: {
                const ex = sample.eye_origin_R_mm[0] - sample.eye_origin_L_mm[0];
                const ey = sample.eye_origin_R_mm[1] - sample.eye_origin_L_mm[1];
                const ez = sample.eye_origin_R_mm[2] - sample.eye_origin_L_mm[2];
                break :blk std.fmt.bufPrint(&buf2, "ex={d:.1} ey={d:.1} ez={d:.1} roll={d:.2}", .{ ex, ey, ez, roll }) catch "";
            } else "";
            std.debug.print("hp={d:.2} gy={d:.2} rw={d:.2} hpd={d:.2} gpd={d:.2} rp={d:.2} yaw={d:.2} pitch={d:.2} {s} fy={d:.2} fp={d:.2} er={d:.2} cen=({d:.1},{d:.1},{d:.1}) ref=({d:.1},{d:.1},{d:.1}) yref={d:.2} rref={d:.2} fb={d:.2} gt={d:.2} ge={d:.2} ch={d} n={d} lg={d:.2} fc={d:.2} fya={d} fyp={d} mode={s} cp={d:.2} chy={d:.2}\n", .{
                head_yaw, gaze_yaw, fy_head, head_pitch, gaze_pitch, fp_head, yaw, pitch, both, fy, fp, effective_eye_ratio,
                center[0], center[1], center[2], self.ref_mid[0], self.ref_mid[1], self.ref_mid[2], self.yaw_ref, self.roll_ref, if (rot_both) @as(f64, 0.0) else @as(f64, 1.0), gate, gate_eff, @intFromBool(self.corner_hold), n, self.last_good_yaw,
                self.rot_yaw.cutoff(), @intFromBool(p.flip_yaw), @intFromBool(p.flip_pitch), smoothModeName(mode),
                self.corner_peak, self.corner_held_yaw,
            });
        }

        // 5. translation (ref-relative mm → cm) with heavier smoothing.
        //    Same anti-latch as rotation: the raw n=1 center differs by half-IPD
        //    from the n=2 midpoint, so a long one-eye stretch would freeze the
        //    position (reject threshold) or, worse, hold a wrong offset. The
        //    IPD-compensated center makes the n=1 target correct, so after the
        //    hold window we blend pos_hold toward it and unstick smoothly.
        var px: f64 = 0;
        var py: f64 = 0;
        var pz: f64 = 0;
        if (p.send_position and has_origins and self.ref_set) {
            var pos_target: [3]f64 = center;
            if (n == 1) {
                if (!self.has_pos_hold) {
                    self.pos_hold = center;
                    self.has_pos_hold = true;
                }
                if (self.n1_timer > n1_hold_s) {
                    const t = @min(1.0, dt * unstick_rate);
                    for (0..3) |i| self.pos_hold[i] += t * (center[i] - self.pos_hold[i]);
                }
                pos_target = self.pos_hold;
            } else {
                self.pos_hold = center;
            }
            px = self.pos_x.update((pos_target[0] - self.ref_mid[0]) * 0.1 * p.pos_gain, dt, p.pos_smoothing, 1.0);
            py = self.pos_y.update((pos_target[1] - self.ref_mid[1]) * 0.1 * p.pos_gain, dt, p.pos_smoothing, 1.0);
            pz = self.pos_z.update((pos_target[2] - self.ref_mid[2]) * 0.1 * p.pos_gain, dt, p.pos_smoothing, 1.0);
        }

        self.last_out = .{ px, py, pz, fy, fp, roll };
        return self.last_out;
    }
};
