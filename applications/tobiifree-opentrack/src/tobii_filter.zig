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
};

pub const BUILTIN_PRESETS = [_]Preset{
    .{
        .name = "tobii-official (old)",
        // Snapshot of the previous tobii-official before the corner-hold /
        // pitch-symmetry rework. Kept so the old feel is one click away.
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
    },
    .{
        .name = "x4 (old)",
        // Snapshot of the previous x4 before the rework.
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
    },
    .{
        .name = "x4-smooth (old)",
        // Snapshot of the previous x4-smooth (head 2.4x) before the rework.
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
    },
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

fn deadzone(v: f64, dz: f64) f64 {
    return if (@abs(v) < dz) 0 else v;
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
    // B3: pitch-pin safety net. If the OUTPUT pitch is stuck at ≥19° for >2 s
    // while the corrected gaze is at screen center, the eye-Y baseline is
    // pinned (the old rest-follow never engaged because the biased gaze sat
    // outside its ±4° window). Nudge the ref baseline toward the current pose
    // at a bounded rate so the view unbinds without dragging a held pose.
    pitch_pin_time: f64 = 0,

    const settle_target: u32 = 90; // ~1 s of samples to average the ref
    const half_ipd_mm: f64 = 32.5; // average eye-to-head-center offset
    const corner_pin_deg: f64 = 12.0; // |gaze yaw| beyond this = pinned at the screen edge
    const corner_hyst_deg: f64 = 0.5; // estimate must sag this far below the peak to engage
    const pitch_glitch_deg: f64 = 5.0; // max genuine pitch change per frame (~450°/s)
    const n1_y_sanity_mm: f64 = 25.0; // single-eye Y can't be this far from the midpoint
    const n1_y_settle_s: f64 = 0.5; // hold pitch while the single-eye Y estimate settles
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
    const tug_smoothing: f64 = 0.85; // tug low-pass: fc_min 1.2 Hz, saccade-front ~60 ms
    const min_ipd_mm: f64 = 45.0; // biological lower bound on interocular distance
    const max_ipd_mm: f64 = 80.0; // biological upper bound (glitch detector)
    const zero_eps: f64 = 1e-3; // treat (x,z)≈(0,0) as a dropped eye
    const glitch_deg: f64 = 10.0; // max genuine interocular yaw change per frame
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
        self.rest_time = 0;
    }

    /// Process one gaze sample into a 6-DOF pose
    /// (X, Y, Z in cm; Yaw, Pitch, Roll in degrees).
    /// Re-acquisition re-centering is triggered by the caller via `reset()`
    /// (based on eye validity over time), not by dt.
    pub fn process(self: *TobiiPipeline, sample: *const core.GazeSample, p: *const Preset, dt: f64) [6]f64 {
        // Gatekeeper: eye validity + zero-vector shield (a dropped eye is
        // sometimes defaulted to (0,0,0); feeding that to atan2 explodes), then
        // a biological IPD clamp for the rotation path.
        const lx = sample.eye_origin_L_mm[0];
        const lz = sample.eye_origin_L_mm[2];
        const rx = sample.eye_origin_R_mm[0];
        const rz = sample.eye_origin_R_mm[2];
        const left_valid = sample.validity_L == 0 and (@abs(lx) > zero_eps or @abs(lz) > zero_eps);
        const right_valid = sample.validity_R == 0 and (@abs(rx) > zero_eps or @abs(rz) > zero_eps);

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
        //    Phase 2A: error-map-derived correction (see Preset fields).
        const y_scale = @max(p.gaze_y_scale, 0.1);
        const g_corr = [2]f64{ self.last_good_gaze[0], (self.last_good_gaze[1] + p.gaze_y_offset) / y_scale };
        const g = self.gaze.filter(g_corr, dt);
        const gaze_yaw = (g[0] - 0.5) * p.gaze_scale;
        const gaze_pitch = (0.5 - g[1]) * p.gaze_scale_pitch;
        // Tug-only low-pass: the state filter's pursuit band (α up to 0.25)
        // still passes ±2-3°/frame fixation flicker, which the fine-aim term
        // would render as jitter while the head rests. Corner/gate logic
        // below keeps the raw values.
        const tug_yaw = self.tug_yaw_f.update(gaze_yaw, dt, tug_smoothing);
        const tug_pitch = self.tug_pitch_f.update(gaze_pitch, dt, tug_smoothing);

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
                var rel_yaw = inter_yaw - self.yaw_ref;
                const rel_roll = inter_roll - self.roll_ref;
                if (!self.has_last_good or self.was_n1 or self.was_lost) {
                    // Fresh n=1→n=2 re-acquisition (or first sample, or the
                    // eyes just came back from a full loss): the n=1 drift may
                    // have left last_good off the real pose by more than
                    // glitch_deg, which the clamp would latch forever. Re-arm
                    // so the REAL interocular pose is adopted immediately
                    // instead of being rejected as a "glitch".
                    self.last_good_yaw = rel_yaw;
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
                        // Eyes just came back: adopt the real pose INSTANTLY.
                        // The smoothers' internal state is stale from before
                        // the loss, and easing from it reads as "lag when
                        // returning into the tracking range".
                        self.rot_yaw.resetTo(rel_yaw);
                        self.rot_pitch.resetTo(self.last_good_pitch * p.pitch_gain);
                        self.roll_s.resetTo(rel_roll);
                        self.tug_yaw_f.resetTo(gaze_yaw);
                        self.tug_pitch_f.resetTo(gaze_pitch);
                        self.was_lost = false;
                    }
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
                    // Y is a no-op this episode.
                    self.n1_y_anchor = center[1];
                    self.n1_y_base = center[1];
                    self.n1_y_anchor_set = true;
                    self.n1_settle = 0;
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
                    self.n1_y_anchor = center[1];
                    self.n1_y_base = self.last_good_y;
                    self.n1_settle = 0;
                    self.n1_y_anchor_set = true;
                }
                self.n1_settle += dt;
                const n1_y_eff = if (self.n1_settle < n1_y_settle_s)
                    self.n1_y_base // hold during the settle: no bias, no drift
                else
                    center[1] - (self.n1_y_anchor - self.n1_y_base);
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
                // calibrated to the interocular scale (post-gain hp ≈
                // 0.36·yaw1e on this rig). Ease the held pose toward it —
                // but ONLY once the GAZE is pinned beyond corner_pin_deg:
                // the interocular yaw estimate itself COLLAPSES just before
                // the near eye is occluded (the atan2 saturates at the
                // tracking edge), so |last_good_yaw| is small right when the
                // user is staring at the screen edge and the drift would
                // otherwise never engage. The pinned gaze is the reliable
                // "at the corner" witness. Near center the single-eye dx is
                // dominated by lean/translation, so we stay frozen there.
                // Drift rate is 10°/frame pre-gain (~24°/s final) so one-eye
                // tracking keeps pace with a real turn.
                const yaw1e = std.math.atan((center[0] - self.ref_mid[0]) / neck_mm) * 180.0 / std.math.pi;
                if (@abs(gaze_yaw) > corner_pin_deg) {
                    const flip_sign: f64 = if (p.flip_yaw) -1.0 else 1.0;
                    const n1_target = 0.36 * yaw1e / (p.head_gain * flip_sign);
                    const n1_drift = 10.0 * dt; // °/frame pre-gain (≈24 °/s final)
                    self.last_good_yaw += std.math.clamp(n1_target - self.last_good_yaw, -n1_drift, n1_drift);
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
        const gaze_side = std.math.sign(gaze_yaw);
        if (@abs(gaze_yaw) > corner_pin_deg) {
            if (!self.corner_hold or self.corner_side != gaze_side) {
                self.corner_hold = true;
                self.corner_side = gaze_side;
                self.corner_peak = yaw;
            } else if (yaw * gaze_side > self.corner_peak * gaze_side) {
                self.corner_peak = yaw; // turning deeper — track the new peak
            }
            if ((yaw - self.corner_peak) * gaze_side < -corner_hyst_deg) {
                yaw = self.corner_peak; // estimate sagging — hold the peak
            }
        } else {
            self.corner_hold = false;
            self.corner_side = 0;
            self.corner_peak = 0;
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
        const effective_eye_ratio = if (gaze_dev < core_r)
            p.eye_ratio_core
        else if (gaze_dev < mid_outer)
            p.eye_ratio_core + (p.eye_ratio - p.eye_ratio_core) * (gaze_dev - core_r) / (mid_outer - core_r)
        else
            p.eye_ratio;

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
        const fy = fy_head + tug_yaw * effective_eye_ratio * gate_eff;
        const fp = fp_head + tug_pitch * effective_eye_ratio * gate_eff;

        if (std.posix.getenv("TOBII_TRACE") != null) {
            var buf2: [96]u8 = undefined;
            const both = if (sample.validity_L == 0 and sample.validity_R == 0) blk: {
                const ex = sample.eye_origin_R_mm[0] - sample.eye_origin_L_mm[0];
                const ey = sample.eye_origin_R_mm[1] - sample.eye_origin_L_mm[1];
                const ez = sample.eye_origin_R_mm[2] - sample.eye_origin_L_mm[2];
                break :blk std.fmt.bufPrint(&buf2, "ex={d:.1} ey={d:.1} ez={d:.1} roll={d:.2}", .{ ex, ey, ez, roll }) catch "";
            } else "";
            std.debug.print("hp={d:.2} gy={d:.2} rw={d:.2} hpd={d:.2} gpd={d:.2} rp={d:.2} yaw={d:.2} pitch={d:.2} {s} fy={d:.2} fp={d:.2} er={d:.2} cen=({d:.1},{d:.1},{d:.1}) ref=({d:.1},{d:.1},{d:.1}) yref={d:.2} rref={d:.2} fb={d:.2} gt={d:.2} ge={d:.2} ch={d} n={d} n1t={d:.2} lg={d:.2} fc={d:.2} fya={d} fyp={d} mode={s}\n", .{
                head_yaw, gaze_yaw, fy_head, head_pitch, gaze_pitch, fp_head, yaw, pitch, both, fy, fp, effective_eye_ratio,
                center[0], center[1], center[2], self.ref_mid[0], self.ref_mid[1], self.ref_mid[2], self.yaw_ref, self.roll_ref, if (rot_both) @as(f64, 0.0) else @as(f64, 1.0), gate, gate_eff, @intFromBool(self.corner_hold), n, self.n1_timer, self.last_good_yaw,
                self.rot_yaw.cutoff(), @intFromBool(p.flip_yaw), @intFromBool(p.flip_pitch), smoothModeName(mode),
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