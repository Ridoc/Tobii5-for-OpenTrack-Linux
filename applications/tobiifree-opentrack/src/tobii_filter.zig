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
};

pub const BUILTIN_PRESETS = [_]Preset{
    .{
        .name = "tobii-official",
        .max_yaw = 180.0,
        .max_pitch = 90.0,
        .gaze_scale = 40.0,
        .gaze_scale_pitch = 30.0,
        .smoothing = 0.90,
        .pos_smoothing = 0.95,
        .deadzone = 0.15,
        .head_gain = 2.0,
        .eye_ratio = 0.15,
        .pos_gain = 2.0,
        .neck = 13.0,
        .curve_mode = 2,
        .curve_exp = 0.5,
    },
    .{
        .name = "tobii-official-safe",
        .max_yaw = 60.0,
        .max_pitch = 40.0,
        .gaze_scale = 40.0,
        .gaze_scale_pitch = 30.0,
        .smoothing = 0.90,
        .pos_smoothing = 0.95,
        .deadzone = 0.15,
        .head_gain = 2.0,
        .eye_ratio = 0.15,
        .pos_gain = 2.0,
        .neck = 13.0,
        .curve_mode = 2,
        .curve_exp = 0.5,
    },
    .{
        .name = "x4-tuned",
        // 1. Let the Tobii spline output its full range; do not clamp it early.
        .max_yaw = 180.0,
        .max_pitch = 90.0,

        // 2. Gaze tracking (Eye input)
        .gaze_scale = 35.0,
        .gaze_scale_pitch = 25.0,
        .eye_ratio = 0.25, // noticeable but smooth OEM "tug"

        // 3. Smoothers
        .smoothing = 0.93,     // high retention at rest to kill jitter
        .pos_smoothing = 0.96, // keep translation buttery smooth
        .deadzone = 0.2,       // micro-deadzone (blends into spline's native 2° flatline)

        // 4. Gain (do NOT pre-multiply head angle into the spline)
        .head_gain = 2.0, // head turns reach the spline boost region
        .pos_gain = 1.2, // slight boost for leaning in the cockpit
        .pitch_gain = 1.5, // +50% pitch for testing (up/down is weak)
        .neck = 12.0,

        // 5. Curve
        .curve_mode = 2,  // Tobii Catmull-Rom spline
        .curve_exp = 1.0, // unused by mode 2; kept at 1.0 to prevent math errors
    },
    .{
        .name = "x4-legacy",
        .max_yaw = 37.5,
        .max_pitch = 22.5,
        .gaze_scale = 75.0,
        .gaze_scale_pitch = 45.0,
        .smoothing = 0.30,
        .pos_smoothing = 0.30,
        .deadzone = 0.2,
        .head_gain = 0.0,
        .eye_ratio = 1.0,
        .pos_gain = 1.0,
        .neck = 13.0,
        .curve_mode = 0,
        .curve_exp = 1.0,
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
};

// ─── Response curve ──────────────────────────────────────────────────

const YAW_PTS = [_][2]f64{
    // Steep at the low end: the raw interocular head yaw is geometrically
    // small (+/-8 deg pre-gain at 600mm), so a gentle curve leaves a full head
    // turn at only ~48 deg. 8 deg input -> 40, 16 -> 110, so small turns sweep
    // the cockpit. Pitch has its own (flatter) curves.
    .{ 0, 0 }, .{ 2, 0 }, .{ 8, 40 }, .{ 16, 110 }, .{ 35, 180 },
};
const PITCH_UP_PTS = [_][2]f64{
    .{ 0, 0 }, .{ 2, 0 }, .{ 10, 20 }, .{ 20, 50 }, .{ 30, 90 },
};
const PITCH_DOWN_PTS = [_][2]f64{
    .{ 0, 0 }, .{ 2, 0 }, .{ 10, 25 }, .{ 20, 90 },
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
    // Gentle auto-recenter: while the head sits near center AND still, slowly
    // blend the reference toward the current pose so position/vertical/yaw
    // offsets (seat drift, a stale startup settle) decay smoothly — no freeze
    // and no pop, unlike the old hard reset.
    rest_time: f64 = 0,
    last_yaw: f64 = 0,
    last_pitch: f64 = 0,
    // Head yaw speed (deg/s), used to gate the gaze blend: when the head is
    // actively rotating, the vestibular-ocular reflex counter-rotates the
    // eyes, so adding the fast-flying gaze signal shoves the output opposite
    // to the turn (the "spike to the upper-left when turning right").
    last_head_yaw: f64 = 0,
    has_last_head_yaw: bool = false,
    // Anti-latch state: a pre-occlusion glitch frame can spike the
    // interocular depth, and a subsequent n=1 frame would then latch that
    // spike forever (the one-eye fallback never gets within the reject
    // threshold). n1_timer/last_good* let us hold through short drops and
    // gently unstick toward the real pose on long ones.
    n1_timer: f64 = 0,
    last_good_yaw: f64 = 0,
    last_good_pitch: f64 = 0,
    last_good_roll: f64 = 0,
    has_last_good: bool = false,
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
    // Crossfade between interocular yaw (both eyes, accurate) and the
    // position-based fallback (one eye, continuous). 0 = interocular,
    // 1 = head-center lateral angle. Ramped so occlusion transitions don't pop.
    fb_blend: f64 = 0,
    // Debounce: how many consecutive rot_both frames must pass before easing
    // back off the fallback. Prevents a one-eye flash from yanking the pose.
    both_frames: u32 = 0,
    // Smoothed center-x used for the position-yaw fallback. A tracker eye-swap
    // (which single eye it reports) can move the IPD-compensated center by a
    // full IPD in one frame; without low-passing, that reads as a ~5° yaw pop.
    fb_cx: f64 = 0,
    fb_cz: f64 = 0,
    fb_last_n: usize = 0,
    fb_init: bool = false,

    const settle_target: u32 = 90; // ~1 s of samples to average the ref
    const half_ipd_mm: f64 = 32.5; // average eye-to-head-center offset
    const rest_recenter_s: f64 = 1.5; // hold still near center → blend ref toward pose
    const rest_yaw_deg: f64 = 30.0; // only recenter when roughly facing center
    const rest_pitch_deg: f64 = 20.0;
    const rest_vel_deg_s: f64 = 5.0;
    const recenter_rate: f64 = 0.02; // ref blend per frame once at rest
    const min_ipd_mm: f64 = 45.0; // biological lower bound on interocular distance
    const max_ipd_mm: f64 = 80.0; // biological upper bound (glitch detector)
    const zero_eps: f64 = 1e-3; // treat (x,z)≈(0,0) as a dropped eye
    const glitch_deg: f64 = 10.0; // max genuine interocular yaw change per frame
    const n1_hold_s: f64 = 0.5; // hold through n=1 (blinks/glances) this long
    const unstick_rate: f64 = 2.0; // lerp rate toward the fallback once stuck
    const crossfade_s: f64 = 0.2; // ramp occlusion yaw fallback in/out

    /// Full reset (fresh acquisition / long reacquisition). Keeps `had_ref`
    /// and `last_out` so the view holds instead of zeroing during a re-settle.
    pub fn reset(self: *TobiiPipeline) void {
        const keep_had = self.had_ref;
        const keep_out = self.last_out;
        self.* = .{};
        self.had_ref = keep_had;
        self.last_out = keep_out;
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
                // Re-settle (had_ref, manual recenter): fall through and keep
                // tracking with the OLD refs. No freeze, no pop — the refs
                // atomically swap when the new settle completes.
            }
        } else {
            // No valid eye at all (zero-vector shield caught both, or origins
            // are gone). Hold the last full pose instead of snapping to 0.
            return self.last_out;
        }

        // 1. gaze → angles, heavily filtered.
        const g = self.gaze.filter(sample.gaze_point_2d_norm, dt);
        const gaze_yaw = (g[0] - 0.5) * p.gaze_scale;
        const gaze_pitch = (0.5 - g[1]) * p.gaze_scale_pitch;

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
            // Position-based yaw fallback: the head center's lateral angle vs
            // the ref, atan2(dx, z) ≈ the true turn angle. Works with ONE eye
            // (the center is IPD-compensated), so a turn never freezes at the
            // point one eye leaves the trackbox. Crossfaded against the
            // interocular measurement so transitions don't pop.
            //
            // SIGN: interocular yaw = atan2(ez, ex) (left turn → negative).
            // But the center x, in camera space, moves OPPOSITE the head:
            // turn LEFT → center x goes POSITIVE. So we negate the atan2 so
            // the fallback shares the interocular sign convention.
            //
            // The center is EWMA-smoothed per eye-count so a tracker eye-swap
            // (which single eye it reports) can't inject a full-IPD step into
            // pos_yaw. A genuine lateral lean is slow and passes through.
            const fb_alpha: f64 = if (n == self.fb_last_n) 0.10 else 0.02;
            if (!self.fb_init) {
                self.fb_cx = center[0];
                self.fb_cz = center[2];
                self.fb_init = true;
            } else {
                self.fb_cx += fb_alpha * (center[0] - self.fb_cx);
                self.fb_cz += fb_alpha * (center[2] - self.fb_cz);
            }
            self.fb_last_n = n;
            const pos_yaw = std.math.atan2(
                self.ref_mid[0] - self.fb_cx,
                @max(self.fb_cz, 50.0),
            ) * 180.0 / std.math.pi;
            if (rot_both) {
                self.n1_timer = 0;
                var rel_yaw = inter_yaw - self.yaw_ref;
                const rel_roll = inter_roll - self.roll_ref;
                if (!self.has_last_good) {
                    self.last_good_yaw = rel_yaw;
                    self.last_good_roll = rel_roll;
                    self.last_good_pitch = pitch_est;
                    self.has_last_good = true;
                } else if (self.fb_blend < 0.3 and @abs(rel_yaw - self.last_good_yaw) > glitch_deg) {
                    // Pre-occlusion hardware spike (impossible depth):
                    // drop the frame, hold the last known good pose. Only
                    // enforced in pure interocular mode — right after a
                    // one-eye stretch the fallback's pose differs by design,
                    // so the blend handles the handoff instead.
                    rel_yaw = self.last_good_yaw;
                } else {
                    self.last_good_yaw = rel_yaw;
                    self.last_good_roll = rel_roll;
                    self.last_good_pitch = pitch_est;
                }
                // Both eyes again: only ease off the position fallback after
                // the pair has been steady for a few frames, so a one-eye
                // blink can't yank the pose toward center mid-turn.
                self.both_frames +|= 1;
                if (self.both_frames >= 6) {
                    self.fb_blend = @max(0.0, self.fb_blend - dt / crossfade_s);
                }
                head_yaw = self.last_good_yaw * (1.0 - self.fb_blend) + pos_yaw * self.fb_blend;
                head_roll = self.last_good_roll;
                head_pitch = self.last_good_pitch;
            } else {
                // One eye (or a glitched pair): yaw falls back to the head
                // center's lateral angle (continuous, no freeze); roll can't be
                // measured with one eye → holds; pitch stays live from center.
                self.n1_timer += dt;
                self.both_frames = 0;
                if (!self.has_last_good) {
                    self.last_good_yaw = pos_yaw;
                    self.last_good_roll = 0;
                    self.last_good_pitch = pitch_est;
                    self.has_last_good = true;
                }
                self.fb_blend = @min(1.0, self.fb_blend + dt / crossfade_s);
                head_yaw = self.last_good_yaw * (1.0 - self.fb_blend) + pos_yaw * self.fb_blend;
                self.last_good_yaw = head_yaw; // keep the clamp baseline current
                head_roll = self.last_good_roll;
                head_pitch = pitch_est;
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
        const head_speed = if (self.has_last_head_yaw and dt > 0)
            @abs(head_yaw - self.last_head_yaw) / dt
        else
            0.0;
        self.last_head_yaw = head_yaw;
        self.has_last_head_yaw = true;
        const gate = if (head_speed <= 8.0)
            1.0
        else if (head_speed >= 25.0)
            0.0
        else
            1.0 - (head_speed - 8.0) / 17.0;
        const raw_yaw = head_yaw + gaze_yaw * p.eye_ratio * gate;
        const raw_pitch = (head_pitch + gaze_pitch * p.eye_ratio * gate) * p.pitch_gain;
        const yaw = self.rot_yaw.update(raw_yaw, dt, mode, p.smoothing, 10.0);
        const pitch = self.rot_pitch.update(raw_pitch, dt, mode, p.smoothing, 10.0);
        const roll = self.roll_s.update(head_roll, dt, mode, p.smoothing, 10.0);

        // 3b. Gentle auto-recenter: while the head sits near center AND still,
        //     slowly blend the reference toward the current pose. This makes
        //     seat drift / a stale startup settle decay smoothly over a couple
        //     of seconds instead of holding a constant offset forever — and,
        //     unlike the old hard reset, there is NO freeze and NO pop mid-turn.
        const dt_rest = @min(dt, 0.1);
        const yaw_vel = @abs(yaw - self.last_yaw) / @max(dt_rest, 1e-6);
        const pitch_vel = @abs(pitch - self.last_pitch) / @max(dt_rest, 1e-6);
        if (@abs(yaw) < rest_yaw_deg and @abs(pitch) < rest_pitch_deg and
            yaw_vel + pitch_vel < rest_vel_deg_s)
        {
            self.rest_time += dt_rest;
        } else {
            self.rest_time = 0;
        }
        self.last_yaw = yaw;
        self.last_pitch = pitch;
        if (self.rest_time >= rest_recenter_s and has_origins) {
            // Blend ref_mid toward the current center, and the yaw/roll refs
            // toward the current interocular pose, at a slow per-frame rate.
            const r = recenter_rate * dt / 0.0111;
            for (0..3) |i| self.ref_mid[i] += r * (center[i] - self.ref_mid[i]);
            if (rot_both) {
                self.yaw_ref += r * (inter_yaw - self.yaw_ref);
                self.roll_ref += r * (inter_roll - self.roll_ref);
            }
        }
        if (std.posix.getenv("TOBII_TRACE") != null) {
            var buf2: [96]u8 = undefined;
            const both = if (sample.validity_L == 0 and sample.validity_R == 0) blk: {
                const ex = sample.eye_origin_R_mm[0] - sample.eye_origin_L_mm[0];
                const ey = sample.eye_origin_R_mm[1] - sample.eye_origin_L_mm[1];
                const ez = sample.eye_origin_R_mm[2] - sample.eye_origin_L_mm[2];
                break :blk std.fmt.bufPrint(&buf2, "ex={d:.1} ey={d:.1} ez={d:.1} roll={d:.2}", .{ ex, ey, ez, roll }) catch "";
            } else "";
            std.debug.print("hp={d:.2} gy={d:.2} rw={d:.2} hpd={d:.2} gpd={d:.2} rp={d:.2} yaw={d:.2} pitch={d:.2} {s} cen=({d:.1},{d:.1},{d:.1}) ref=({d:.1},{d:.1},{d:.1}) yref={d:.2} rref={d:.2} fb={d:.2} gt={d:.2} n={d} n1t={d:.2} lg={d:.2} fc={d:.2} mode={s}\n", .{
                head_yaw, gaze_yaw, raw_yaw, head_pitch, gaze_pitch, raw_pitch, yaw, pitch, both,
                center[0], center[1], center[2], self.ref_mid[0], self.ref_mid[1], self.ref_mid[2], self.yaw_ref, self.roll_ref, self.fb_blend, gate, n, self.n1_timer, self.last_good_yaw,
                self.rot_yaw.cutoff(), smoothModeName(mode),
            });
        }

        // 4. response curve + cap + deadzone.
        const fy = deadzone(applyCurve(
            @enumFromInt(p.curve_mode),
            yaw,
            p.max_yaw,
            p.curve_exp,
            false,
        ), p.deadzone);
        const fp = deadzone(applyCurve(
            @enumFromInt(p.curve_mode),
            pitch,
            p.max_pitch,
            p.curve_exp,
            true,
        ), p.deadzone);

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