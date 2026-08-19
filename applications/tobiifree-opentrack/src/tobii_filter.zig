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
    pos_gain: f64 = 2.0, // translation multiplier
    neck: f64 = 13.0, // cm from neck pivot to eye plane
    curve_mode: u8 = 2, // CurveMode.tobii
    curve_exp: f64 = 0.5, // power-mode exponent (<1 expands edges)
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
        .head_gain = 1.0,
        .pos_gain = 1.2, // slight boost for leaning in the cockpit
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

    /// Update with a per-frame delta clamp (`max_step`) to reject glitch
    /// spikes (e.g. a one-eye drop shifting the eye-origin midpoint) before
    /// the velocity-adaptive smoothing can propagate them.
    pub fn update(self: *AdaptiveSmoother, value: f64, dt: f64, rest_smoothing: f64, max_step: f64) f64 {
        if (!self.init) {
            self.state = value;
            self.last_raw = value;
            self.init = true;
            return value;
        }
        var v = value;
        const delta = value - self.last_raw;
        if (@abs(delta) > max_step) {
            v = self.last_raw + std.math.sign(delta) * max_step;
        }
        const dt_safe = @max(dt, 1e-6);
        const vel = @abs(v - self.last_raw) / dt_safe;
        self.last_raw = v;
        const retention = retentionForVelocity(vel, rest_smoothing);
        const retention_dt = std.math.pow(f64, retention, dt_safe / target_dt);
        const ewma = 1.0 - retention_dt;
        self.state += ewma * (v - self.state);
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

// ─── Response curve ──────────────────────────────────────────────────

const YAW_PTS = [_][2]f64{
    .{ 0, 0 }, .{ 2, 0 }, .{ 10, 20 }, .{ 20, 75 }, .{ 35, 180 },
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

pub const TobiiPipeline = struct {
    gaze: GazeStateFilter = .{},
    rot_yaw: AdaptiveSmoother = .{},
    rot_pitch: AdaptiveSmoother = .{},
    pos_x: AdaptiveSmoother = .{},
    pos_y: AdaptiveSmoother = .{},
    pos_z: AdaptiveSmoother = .{},
    ref_set: bool = false,
    ref_mid: [3]f64 = .{ 0, 0, 0 },

    pub fn reset(self: *TobiiPipeline) void {
        self.* = .{};
    }

    /// Process one gaze sample into a 6-DOF pose
    /// (X, Y, Z in cm; Yaw, Pitch, Roll in degrees).
    pub fn process(self: *TobiiPipeline, sample: *const core.GazeSample, p: *const Preset, dt: f64) [6]f64 {
        // Eye-origin midpoint from VALID eyes only (a dropped eye otherwise
        // shifts the midpoint toward the remaining eye → camera yanks).
        var mid: [3]f64 = .{ 0, 0, 0 };
        var n: usize = 0;
        if (sample.validity_L == 0) {
            for (0..3) |i| mid[i] += sample.eye_origin_L_mm[i];
            n += 1;
        }
        if (sample.validity_R == 0) {
            for (0..3) |i| mid[i] += sample.eye_origin_R_mm[i];
            n += 1;
        }
        const has_origins = n > 0;
        if (has_origins) {
            for (0..3) |i| mid[i] /= @as(f64, @floatFromInt(n));
            if (!self.ref_set) {
                self.ref_mid = mid;
                self.ref_set = true;
            }
        }

        // 1. gaze → angles, heavily filtered.
        const g = self.gaze.filter(sample.gaze_point_2d_norm, dt);
        const gaze_yaw = (g[0] - 0.5) * p.gaze_scale;
        const gaze_pitch = (0.5 - g[1]) * p.gaze_scale_pitch;

        // 2. head rotation from the neck-pivot model (eye-origin midpoint).
        var head_yaw: f64 = 0;
        var head_pitch: f64 = 0;
        if (has_origins and self.ref_set) {
            const dx = mid[0] - self.ref_mid[0];
            const dy = mid[1] - self.ref_mid[1];
            const dz = mid[2] - self.ref_mid[2];
            const neck_mm = p.neck * 10.0;
            head_yaw = std.math.atan2(dx, neck_mm - dz) * 180.0 / std.math.pi;
            head_pitch = std.math.atan2(dy, neck_mm) * 180.0 / std.math.pi;
            if (p.flip_yaw) head_yaw = -head_yaw;
            if (p.flip_pitch) head_pitch = -head_pitch;
            head_yaw *= p.head_gain;
            head_pitch *= p.head_gain;
        }

        // 3. blend (OEM 85/15) + velocity-adaptive smoothing with spike clamp.
        const raw_yaw = head_yaw + gaze_yaw * p.eye_ratio;
        const raw_pitch = head_pitch + gaze_pitch * p.eye_ratio;
        const yaw = self.rot_yaw.update(raw_yaw, dt, p.smoothing, 3.0);
        const pitch = self.rot_pitch.update(raw_pitch, dt, p.smoothing, 3.0);

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
        var px: f64 = 0;
        var py: f64 = 0;
        var pz: f64 = 0;
        if (p.send_position and has_origins and self.ref_set) {
            px = self.pos_x.update((mid[0] - self.ref_mid[0]) * 0.1 * p.pos_gain, dt, p.pos_smoothing, 0.5);
            py = self.pos_y.update((mid[1] - self.ref_mid[1]) * 0.1 * p.pos_gain, dt, p.pos_smoothing, 0.5);
            pz = self.pos_z.update((mid[2] - self.ref_mid[2]) * 0.1 * p.pos_gain, dt, p.pos_smoothing, 0.5);
        }

        return .{ px, py, pz, fy, fp, 0 };
    }
};