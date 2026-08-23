// tobiifree-opentrack — Tobii ET5 → OpenTrack bridge for Linux games.
//
// Connects to the tobiifreedot daemon over its unix socket, subscribes to the
// gaze stream, and pipes each GazeSample through a Tobii "Extended View" style
// pipeline (tobii_filter.zig): a 3-state dynamic EWMA gaze filter, a neck-pivot
// head-rotation approximation from the eye-origin midpoint, velocity-adaptive
// Accela-style smoothing, the OEM 85/15 head/eye blend, and a non-linear
// response curve. The resulting 6-DOF pose is streamed over the OpenTrack UDP
// protocol: 48 bytes = 6 little-endian doubles (X, Y, Z, Yaw, Pitch, Roll),
// translation in cm, rotation in degrees, to 127.0.0.1:4242.
//
// Ships with a GTK4 status window showing the live pose values and live tuning
// sliders plus a preset (profile) system; pass --headless for console-only
// operation (e.g. under X4's built-in OpenTrack Support).
//
// Driver/protocol modules imported from Aetherall/tobiifree (GPL-3.0) by
// Aetherall — see LICENSE and README for credits.

const std = @import("std");
const core = @import("tobiifree_core");
const proto = @import("daemon_protocol");
const SocketSource = @import("socket_source").SocketSource;
const tobii = @import("tobii_filter");
const calibration = @import("calibration");
const da_config = @import("display_area_config");

const log = std.log.scoped(.opentrack);

const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("cairo.h");
});

const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 4242,
    p: tobii.Preset = tobii.BUILTIN_PRESETS[0],
    headless: bool = false,
    verbose: bool = false,
};

var g_opts: Options = .{};
var g_udp_fd: std.posix.socket_t = undefined;
var g_dst: std.net.Address = undefined;

/// Physical screen dimensions from daemon (for affine correction and GUI).
/// Populated by get_display_area response after connecting to daemon.
var g_physical_screen: ?da_config.PhysicalScreen = null;

/// Track box factor override from CLI (forwarded to daemon).
var g_track_box_factor: f64 = 2.5;

// Tobii-feel pipeline + preset storage (arena-backed, lives for app lifetime).
var g_pipeline: tobii.TobiiPipeline = .{};
var g_presets_arena: std.heap.ArenaAllocator = undefined;
var g_preset_list: std.array_list.Managed(tobii.Preset) = undefined;
var g_cur_preset_idx: usize = 0;
var g_save_preset_name: ?[]const u8 = null;
var g_last_ts: i64 = 0;

// Stream runs on its own thread so GTK stalls can't stall the game feed.
// The UI mutates g_opts.p under g_lock; the stream thread snapshots it
// into g_stream_preset each loop. g_last_out/g_eyes_valid/etc. are written
// only by the stream thread and read by the UI under g_lock.
var g_lock: std.Thread.Mutex = .{};
var g_stream_preset: tobii.Preset = undefined;
var g_quit: std.atomic.Value(bool) = .init(false);
var g_frame_count: u64 = 0;
var g_eyes_valid: bool = false;
var g_got_sample: bool = false;

// Gaze source + last output pose (read by the GUI tick).
var g_socket: SocketSource = undefined;
var g_last_out: [6]f64 = .{ 0, 0, 0, 0, 0, 0 };

// ─── GTK widgets ─────────────────────────────────────────────────────

var g_app: ?*c.GtkApplication = null;
var g_window: ?*c.GtkWindow = null;
var g_label_status: ?*c.GtkLabel = null;
var g_label_source: ?*c.GtkLabel = null;
var g_label_x: ?*c.GtkLabel = null;
var g_label_y: ?*c.GtkLabel = null;
var g_label_z: ?*c.GtkLabel = null;
var g_label_yaw: ?*c.GtkLabel = null;
var g_label_pitch: ?*c.GtkLabel = null;
var g_label_roll: ?*c.GtkLabel = null;
var g_draw: ?*c.GtkDrawingArea = null;

// Gaze/head visualization state (stream thread writes, UI thread draws).
const TRAIL_LEN: usize = 24;
var g_gaze_norm: [2]f64 = .{ 0.5, 0.5 };
var g_gaze_ref: [2]f64 = .{ 0.5, 0.5 };
var g_gaze_ref_set: bool = false;
var g_trail: [TRAIL_LEN][2]f64 = .{.{ 0.5, 0.5 }} ** TRAIL_LEN;
var g_trail_head: usize = 0;
var g_eye_l_norm: [2]f64 = .{ 0.5, 0.5 };
var g_eye_r_norm: [2]f64 = .{ 0.5, 0.5 };
var g_eye_l_valid: bool = false;
var g_eye_r_valid: bool = false;

var g_scale_yaw: ?*c.GtkScale = null;
var g_entry_yaw: ?*c.GtkEntry = null;
var g_scale_pitch: ?*c.GtkScale = null;
var g_entry_pitch: ?*c.GtkEntry = null;
var g_scale_deadzone: ?*c.GtkScale = null;
var g_entry_deadzone: ?*c.GtkEntry = null;
var g_scale_smoothing: ?*c.GtkScale = null;
var g_entry_smoothing: ?*c.GtkEntry = null;
var g_scale_pos_smoothing: ?*c.GtkScale = null;
var g_entry_pos_smoothing: ?*c.GtkEntry = null;
var g_scale_head_gain: ?*c.GtkScale = null;
var g_entry_head_gain: ?*c.GtkEntry = null;
var g_scale_pitch_gain: ?*c.GtkScale = null;
var g_entry_pitch_gain: ?*c.GtkEntry = null;
var g_scale_eye_ratio: ?*c.GtkScale = null;
var g_entry_eye_ratio: ?*c.GtkEntry = null;
var g_scale_pos_gain: ?*c.GtkScale = null;
var g_entry_pos_gain: ?*c.GtkEntry = null;
var g_scale_neck: ?*c.GtkScale = null;
var g_entry_neck: ?*c.GtkEntry = null;
var g_scale_gaze_scale: ?*c.GtkScale = null;
var g_entry_gaze_scale: ?*c.GtkEntry = null;
var g_scale_gaze_scale_pitch: ?*c.GtkScale = null;
var g_entry_gaze_scale_pitch: ?*c.GtkEntry = null;
var g_scale_curve_exp: ?*c.GtkScale = null;
var g_entry_curve_exp: ?*c.GtkEntry = null;

var g_dropdown_preset: ?*c.GtkDropDown = null;
var g_strings_preset: ?*c.GtkStringList = null;
var g_dropdown_curve: ?*c.GtkDropDown = null;
var g_strings_curve: ?*c.GtkStringList = null;
var g_dropdown_smooth: ?*c.GtkDropDown = null;
var g_strings_smooth: ?*c.GtkStringList = null;
var g_check_flip_yaw: ?*c.GtkCheckButton = null;
var g_check_flip_pitch: ?*c.GtkCheckButton = null;
var g_btn_save: ?*c.GtkButton = null;
var g_btn_save_as: ?*c.GtkButton = null;
var g_btn_delete: ?*c.GtkButton = null;
var g_saveas_entry: ?*c.GtkEntry = null;

var g_srcbuf: [192]u8 = undefined;
var g_tick: u32 = 0;

// Calibration wizard state.
var g_calibrator: calibration.Calibrator = .{};
var g_cal_window: ?*c.GtkWindow = null;
var g_cal_da: ?*c.GtkDrawingArea = null;
var g_cal_socket: ?*SocketSource = null;
// g_calibrator is touched from the stream thread (samples) and the UI thread
// (keys/draw) — serialize all access.
var g_cal_mutex: std.Thread.Mutex = .{};
// Calibration blob returned by the daemon's finish_calibration reply, applied
// via a follow-up cal_apply command.
var g_cal_blob: [8192]u8 = undefined;
var g_cal_blob_len: usize = 0;
// UI → stream-thread request to re-settle the reference (recenters yaw/roll).
var g_recenter_request: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const SensAxis = enum {
    yaw,
    pitch,
    deadzone,
    smoothing,
    pos_smoothing,
    head_gain,
    pitch_gain,
    eye_ratio,
    pos_gain,
    neck,
    gaze_scale,
    gaze_scale_pitch,
    curve_exp,
};

const AxisDef = struct {
    min: f64,
    max: f64,
    step: f64,
    digits: c_int,
};

fn axisDef(axis: SensAxis) AxisDef {
    return switch (axis) {
        .yaw => .{ .min = 0, .max = 180, .step = 1, .digits = 1 },
        .pitch => .{ .min = 0, .max = 90, .step = 0.5, .digits = 1 },
        .deadzone => .{ .min = 0, .max = 3, .step = 0.1, .digits = 1 },
        .smoothing => .{ .min = 0.30, .max = 0.98, .step = 0.01, .digits = 2 },
        .pos_smoothing => .{ .min = 0.30, .max = 0.99, .step = 0.01, .digits = 2 },
        .head_gain => .{ .min = 0, .max = 5, .step = 0.1, .digits = 1 },
        .pitch_gain => .{ .min = 0.5, .max = 3, .step = 0.05, .digits = 2 },
        .eye_ratio => .{ .min = 0, .max = 1, .step = 0.01, .digits = 2 },
        .pos_gain => .{ .min = 0, .max = 5, .step = 0.1, .digits = 1 },
        .neck => .{ .min = 5, .max = 20, .step = 0.5, .digits = 1 },
        .gaze_scale => .{ .min = 10, .max = 90, .step = 1, .digits = 1 },
        .gaze_scale_pitch => .{ .min = 10, .max = 60, .step = 1, .digits = 1 },
        .curve_exp => .{ .min = 0.2, .max = 3, .step = 0.05, .digits = 2 },
    };
}

fn sensField(axis: SensAxis) *f64 {
    return switch (axis) {
        .yaw => &g_opts.p.max_yaw,
        .pitch => &g_opts.p.max_pitch,
        .deadzone => &g_opts.p.deadzone,
        .smoothing => &g_opts.p.smoothing,
        .pos_smoothing => &g_opts.p.pos_smoothing,
        .head_gain => &g_opts.p.head_gain,
        .pitch_gain => &g_opts.p.pitch_gain,
        .eye_ratio => &g_opts.p.eye_ratio,
        .pos_gain => &g_opts.p.pos_gain,
        .neck => &g_opts.p.neck,
        .gaze_scale => &g_opts.p.gaze_scale,
        .gaze_scale_pitch => &g_opts.p.gaze_scale_pitch,
        .curve_exp => &g_opts.p.curve_exp,
    };
}

fn sensScale(axis: SensAxis) *?*c.GtkScale {
    return switch (axis) {
        .yaw => &g_scale_yaw,
        .pitch => &g_scale_pitch,
        .deadzone => &g_scale_deadzone,
        .smoothing => &g_scale_smoothing,
        .pos_smoothing => &g_scale_pos_smoothing,
        .head_gain => &g_scale_head_gain,
        .pitch_gain => &g_scale_pitch_gain,
        .eye_ratio => &g_scale_eye_ratio,
        .pos_gain => &g_scale_pos_gain,
        .neck => &g_scale_neck,
        .gaze_scale => &g_scale_gaze_scale,
        .gaze_scale_pitch => &g_scale_gaze_scale_pitch,
        .curve_exp => &g_scale_curve_exp,
    };
}

fn sensEntry(axis: SensAxis) *?*c.GtkEntry {
    return switch (axis) {
        .yaw => &g_entry_yaw,
        .pitch => &g_entry_pitch,
        .deadzone => &g_entry_deadzone,
        .smoothing => &g_entry_smoothing,
        .pos_smoothing => &g_entry_pos_smoothing,
        .head_gain => &g_entry_head_gain,
        .pitch_gain => &g_entry_pitch_gain,
        .eye_ratio => &g_entry_eye_ratio,
        .pos_gain => &g_entry_pos_gain,
        .neck => &g_entry_neck,
        .gaze_scale => &g_entry_gaze_scale,
        .gaze_scale_pitch => &g_entry_gaze_scale_pitch,
        .curve_exp => &g_entry_curve_exp,
    };
}

fn sensFormat(axis: SensAxis, v: f64, buf: []u8) ?[]const u8 {
    const s = switch (axis) {
        .yaw, .gaze_scale, .gaze_scale_pitch => std.fmt.bufPrint(buf, "{d:.1}", .{v}),
        .pitch, .deadzone, .head_gain, .pos_gain, .neck => std.fmt.bufPrint(buf, "{d:.1}", .{v}),
        .smoothing, .pos_smoothing, .pitch_gain, .eye_ratio, .curve_exp => std.fmt.bufPrint(buf, "{d:.2}", .{v}),
    } catch return null;
    return s;
}

fn sensClamp(axis: SensAxis, v: f64) f64 {
    const d = axisDef(axis);
    return std.math.clamp(v, d.min, d.max);
}

/// Short purpose hint shown under each slider (3-5 words).
fn axisPurpose(axis: SensAxis) [:0]const u8 {
    return switch (axis) {
        .yaw => "max output turn angle",
        .pitch => "max output tilt angle",
        .deadzone => "ignore small center jitter",
        .smoothing => "rotation smoothing strength",
        .pos_smoothing => "translation smoothing strength",
        .head_gain => "scales head turn input",
        .pitch_gain => "boosts up/down response",
        .eye_ratio => "gaze lead vs head",
        .pos_gain => "amplifies lean translation",
        .neck => "pivot distance, pitch scale",
        .gaze_scale => "gaze edge-turn degrees",
        .gaze_scale_pitch => "gaze edge-tilt degrees",
        .curve_exp => "power-curve curvature",
    };
}

/// Threshold values rendered as tick marks under the slider.
fn axisMarks(axis: SensAxis) []const f64 {
    return switch (axis) {
        .yaw => &.{ 35, 60, 90, 180 },
        .pitch => &.{ 20, 30, 90 },
        .deadzone => &.{ 0.1, 0.2 },
        .smoothing => &.{ 0.90, 0.93, 0.98 },
        .pos_smoothing => &.{ 0.90, 0.96, 0.99 },
        .head_gain => &.{ 1, 2, 5 },
        .pitch_gain => &.{ 1, 1.5, 2, 3 },
        .eye_ratio => &.{ 0.25, 0.5, 1 },
        .pos_gain => &.{ 1, 2, 5 },
        .neck => &.{ 12, 13, 20 },
        .gaze_scale => &.{ 35, 40, 90 },
        .gaze_scale_pitch => &.{ 25, 30, 60 },
        .curve_exp => &.{ 1 },
    };
}

/// Values that the slider "magnetically" grabs when released near them.
fn axisSnaps(axis: SensAxis) []const f64 {
    return switch (axis) {
        .yaw => &.{ 35, 60, 90, 180 },
        .pitch => &.{ 20, 30, 90 },
        .deadzone => &.{ 0.1, 0.2 },
        .smoothing => &.{ 0.90, 0.93 },
        .pos_smoothing => &.{ 0.90, 0.96 },
        .head_gain => &.{ 1, 2 },
        .pitch_gain => &.{ 1, 1.5, 2 },
        .eye_ratio => &.{ 0.25, 0.5, 1 },
        .pos_gain => &.{ 1, 2 },
        .neck => &.{ 12, 13 },
        .gaze_scale => &.{ 35, 40 },
        .gaze_scale_pitch => &.{ 25, 30 },
        .curve_exp => &.{ 1 },
    };
}

/// Snap `v` to the nearest axisSnap value within `def.step * 1.5`; else v.
fn magneticSnap(axis: SensAxis, v: f64) f64 {
    const d = axisDef(axis);
    const radius = d.step * 1.5;
    var best: ?f64 = null;
    for (axisSnaps(axis)) |s| {
        if (@abs(v - s) <= radius) {
            if (best == null or @abs(v - s) < @abs(v - best.?)) best = s;
        }
    }
    if (best) |s| return s;
    return v;
}

/// C-pointer view of an opaque widget pointer (alignment-safe).
fn wptr(x: anytype) [*c]c.GtkWidget {
    return @ptrCast(@alignCast(x));
}

fn sendPacket(v: [6]f64) void {
    var buf: [48]u8 = undefined;
    for (v, 0..) |val, i| {
        std.mem.writeInt(u64, buf[i * 8 ..][0..8], @bitCast(val), .little);
    }
    _ = std.posix.sendto(g_udp_fd, &buf, 0, &g_dst.any, g_dst.getOsSockLen()) catch |err| {
        if (g_opts.verbose) log.debug("udp send failed: {s}", .{@errorName(err)});
    };
}

/// Returns true if the per-eye 2D gaze coordinates are plausible (not the
/// device's −1.0/−1.0 no-tracking sentinel, not the zero-vector (0,0) used
/// when validity=4). The device emits −1.0/−1.0 for untracked eyes and (0,0)
/// when validity=4. At screen edges coords legitimately exceed [0,1] (looking
/// above/below screen), so we only reject sentinel/zero and accept any finite.
fn eye2dPlausible(px: f64, py: f64) bool {
    return !(px == -1.0 and py == -1.0) and !(px == 0.0 and py == 0.0) and std.math.isFinite(px) and std.math.isFinite(py);
}

fn onGaze(sample: *const core.GazeSample) void {
    g_frame_count += 1;

    // Calibration wizard receives ALL samples (even eye-loss frames): at
    // extreme corners both eyes can leave tracked FOV, and capture would
    // otherwise freeze forever waiting for samples that never come.
    calFeedGaze(sample);

    // 0 = valid, 4 = not detected. Proceed if at least one eye is tracked.
    const valid = sample.validity_L == 0 or sample.validity_R == 0;
    g_eyes_valid = valid;
    g_got_sample = true;
    if (!valid) {
        if (g_opts.verbose or g_opts.headless and g_frame_count <= 5) {
            log.warn("no eyes detected, holding last pose", .{});
        }
        return;
    }
    // Manual recenter (GUI button): re-settle so dead-center head → 0°/0°.
    // The re-settle tracks through (no freeze) and only re-captures the ref
    // after ~1s. NOTE: no automatic reset on sustained eye loss — a reset
    // here would freeze the view for a full settle window right at the
    // moment you're turning back from a corner.
    if (g_recenter_request.swap(false, .acq_rel)) g_pipeline.reset();

    // Frame-independent dt from the device clock, capped so a delivery gap
    // can't cause a snap (re-centering is handled by eye validity above).
    var dt: f64 = 0.0111;
    if (g_last_ts != 0) {
        const d = @as(f64, @floatFromInt(sample.timestamp_us - g_last_ts)) / 1e6;
        if (d > 0) dt = @min(d, 0.25);
    }
    g_last_ts = sample.timestamp_us;

    const out = g_pipeline.process(sample, &g_stream_preset, dt);
    g_lock.lock();
    g_last_out = out;
    // Apply affine gaze correction (same formula as pipeline) so the
    // visualization matches the UDP output.  Raw device gaze is biased
    // low (center y ≈ 0.245); the offset/scale brings it to ≈ 0.5.
    const y_off = g_stream_preset.gaze_y_offset;
    const y_scl = @max(g_stream_preset.gaze_y_scale, 0.1);
    g_gaze_norm = .{ sample.gaze_point_2d_norm[0], (sample.gaze_point_2d_norm[1] + y_off) / y_scl };
    // Only update per-eye viz coords when eye is plausible (not lost).
    // When eye is lost (validity=4), device sends raw=(0,0) which would
    // place the dot at left edge after correction. Keep last known position.
    const l_plausible = eye2dPlausible(sample.gaze_point_2d_L_norm[0], sample.gaze_point_2d_L_norm[1]);
    const r_plausible = eye2dPlausible(sample.gaze_point_2d_R_norm[0], sample.gaze_point_2d_R_norm[1]);
    if (l_plausible) {
        g_eye_l_norm = .{
            sample.gaze_point_2d_L_norm[0],
            @min(@max((sample.gaze_point_2d_L_norm[1] + y_off) / y_scl, -0.2), 1.2)
        };
    }
    if (r_plausible) {
        g_eye_r_norm = .{
            sample.gaze_point_2d_R_norm[0],
            @min(@max((sample.gaze_point_2d_R_norm[1] + y_off) / y_scl, -0.2), 1.2)
        };
    }
    g_eye_l_valid = sample.validity_L == 0 or l_plausible;
    g_eye_r_valid = sample.validity_R == 0 or r_plausible;
    g_trail[g_trail_head] = g_gaze_norm;
    g_trail_head = (g_trail_head + 1) % TRAIL_LEN;
    g_lock.unlock();
    sendPacket(out);

    if (g_opts.verbose or g_opts.headless and g_frame_count <= 5) {
        log.info("x={d:6.1} y={d:6.1} z={d:6.1}  yaw={d:6.1}° pitch={d:6.1}°  (sample {d})", .{
            out[0], out[1], out[2], out[3], out[4], g_frame_count,
        });
    }
}

// ─── GTK UI ──────────────────────────────────────────────────────────

fn setText(label: ?*c.GtkLabel, buf: []u8, comptime fmt: []const u8, args: anytype) void {
    if (label) |l| {
        const s = std.fmt.bufPrint(buf, fmt, args) catch return;
        buf[s.len] = 0;
        c.gtk_label_set_text(l, buf[0 .. s.len :0]);
    }
}

fn addValueRow(grid: [*c]c.GtkWidget, row: c_int, name: [*:0]const u8, out: *?*c.GtkLabel) void {
    const name_label = c.gtk_label_new(name);
    c.gtk_widget_set_halign(name_label, c.GTK_ALIGN_START);
    c.gtk_grid_attach(@ptrCast(grid), name_label, 0, row, 1, 1);

    const val_label = c.gtk_label_new(null);
    c.gtk_widget_set_halign(val_label, c.GTK_ALIGN_END);
    c.gtk_style_context_add_class(
        c.gtk_widget_get_style_context(val_label),
        "value",
    );
    c.gtk_grid_attach(@ptrCast(grid), val_label, 1, row, 1, 1);
    out.* = @ptrCast(@alignCast(val_label));
}

fn updateSourceLabel() void {
    setText(g_label_source, &g_srcbuf, "Preset: {s}  ·  {s}:{d}  ·  head {d:.1}×  eye {d:.2}  pitch {d:.2}×", .{
        g_opts.p.name, g_opts.host, g_opts.port, g_opts.p.head_gain, g_opts.p.eye_ratio, g_opts.p.pitch_gain,
    });
}

fn onScaleChanged(range: [*c]c.GtkRange, data: ?*anyopaque) callconv(.c) void {
    const axis: SensAxis = @enumFromInt(@intFromPtr(data orelse return));
    var v = c.gtk_range_get_value(range);
    // Magnetic catch: with a small capture radius (step·1.5), the value only
    // sticks when the thumb is already right on a marked threshold (e.g. 1.0).
    const snapped = magneticSnap(axis, v);
    if (snapped != v) {
        c.gtk_range_set_value(range, snapped);
        v = snapped;
    }
    g_lock.lock();
    sensField(axis).* = v;
    g_lock.unlock();
    var buf: [16]u8 = undefined;
    if (sensFormat(axis, v, &buf)) |s| {
        buf[s.len] = 0;
        if (sensEntry(axis).*) |e| c.gtk_editable_set_text(@ptrCast(e), buf[0 .. s.len :0]);
    }
    updateSourceLabel();
}

fn onEntryActivated(entry: [*c]c.GtkEntry, data: ?*anyopaque) callconv(.c) void {
    const axis: SensAxis = @enumFromInt(@intFromPtr(data orelse return));
    const text = std.mem.span(c.gtk_editable_get_text(@ptrCast(entry)));
    if (text.len == 0) return;
    const v = std.fmt.parseFloat(f64, text) catch return;
    g_lock.lock();
    sensField(axis).* = magneticSnap(axis, sensClamp(axis, v));
    const clamped = sensField(axis).*;
    g_lock.unlock();
    if (sensScale(axis).*) |sc| c.gtk_range_set_value(@ptrCast(@alignCast(sc)), clamped);
    updateSourceLabel();
}

fn addSensRow(
    grid: [*c]c.GtkWidget,
    row: c_int,
    name: [*:0]const u8,
    axis: SensAxis,
) void {
    const def = axisDef(axis);
    const name_label = c.gtk_label_new(name);
    c.gtk_widget_set_halign(name_label, c.GTK_ALIGN_START);
    c.gtk_grid_attach(@ptrCast(grid), name_label, 0, row, 1, 1);

    const purpose = c.gtk_label_new(axisPurpose(axis));
    c.gtk_widget_set_halign(purpose, c.GTK_ALIGN_START);
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(purpose), "dim");
    c.gtk_grid_attach(@ptrCast(grid), purpose, 1, row, 1, 1);

    const scale = c.gtk_scale_new_with_range(c.GTK_ORIENTATION_HORIZONTAL, def.min, def.max, def.step);
    c.gtk_scale_set_digits(@ptrCast(scale), def.digits);
    c.gtk_range_set_value(@ptrCast(scale), sensField(axis).*);
    c.gtk_widget_set_hexpand(scale, 1);
    c.gtk_grid_attach(@ptrCast(grid), scale, 2, row, 1, 1);
    sensScale(axis).* = @ptrCast(scale);
    for (axisMarks(axis)) |m| {
        c.gtk_scale_add_mark(@ptrCast(scale), m, c.GTK_POS_BOTTOM, null);
    }

    const entry = c.gtk_entry_new();
    var buf: [16]u8 = undefined;
    if (sensFormat(axis, sensField(axis).*, &buf)) |s| {
        buf[s.len] = 0;
        c.gtk_editable_set_text(@ptrCast(entry), buf[0 .. s.len :0]);
    }
    c.gtk_widget_set_size_request(@ptrCast(entry), 64, -1);
    c.gtk_grid_attach(@ptrCast(grid), entry, 3, row, 1, 1);
    sensEntry(axis).* = @ptrCast(entry);

    _ = c.g_signal_connect_data(
        @ptrCast(scale),
        "value-changed",
        @ptrCast(&onScaleChanged),
        @ptrFromInt(@intFromEnum(axis)),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @ptrCast(entry),
        "activate",
        @ptrCast(&onEntryActivated),
        @ptrFromInt(@intFromEnum(axis)),
        null,
        0,
    );
}

fn addSectionTitle(box: [*c]c.GtkWidget, text: [*:0]const u8) void {
    const lbl = c.gtk_label_new(text);
    c.gtk_widget_set_halign(lbl, c.GTK_ALIGN_START);
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(lbl), "status");
    c.gtk_box_append(@ptrCast(box), lbl);
}

fn updateLabels() void {
    var buf: [64]u8 = undefined;

    g_lock.lock();
    const status: []const u8 = if (!g_got_sample)
        "Waiting for gaze…"
    else if (g_eyes_valid)
        "Eyes: tracked"
    else
        "Eyes: lost — holding last pose";
    const x = g_last_out[0];
    const y = g_last_out[1];
    const z = g_last_out[2];
    const yaw = g_last_out[3];
    const pitch = g_last_out[4];
    const roll = g_last_out[5];
    g_lock.unlock();

    setText(g_label_status, &buf, "{s}", .{status});

    setText(g_label_x, &buf, "{d:7.2}", .{x});
    setText(g_label_y, &buf, "{d:7.2}", .{y});
    setText(g_label_z, &buf, "{d:7.2}", .{z});
    setText(g_label_yaw, &buf, "{d:7.2}°", .{yaw});
    setText(g_label_pitch, &buf, "{d:7.2}°", .{pitch});
    setText(g_label_roll, &buf, "{d:7.2}°", .{roll});
}

fn cairoRoundedRect(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    const rad = @min(r, @min(w, h) * 0.5);
    c.cairo_move_to(cr, x + rad, y);
    c.cairo_line_to(cr, x + w - rad, y);
    c.cairo_arc(cr, x + w - rad, y + rad, rad, -std.math.pi * 0.5, 0);
    c.cairo_line_to(cr, x + w, y + h - rad);
    c.cairo_arc(cr, x + w - rad, y + h - rad, rad, 0, std.math.pi * 0.5);
    c.cairo_line_to(cr, x + rad, y + h);
    c.cairo_arc(cr, x + rad, y + h - rad, rad, std.math.pi * 0.5, std.math.pi);
    c.cairo_line_to(cr, x, y + rad);
    c.cairo_arc(cr, x + rad, y + rad, rad, std.math.pi, std.math.pi * 1.5);
    c.cairo_close_path(cr);
}

fn drawViz(_: [*c]c.GtkDrawingArea, cr: *c.cairo_t, width: c_int, height: c_int, _: ?*anyopaque) callconv(.c) void {
    g_lock.lock();
    const yaw = g_last_out[3];
    const pitch = g_last_out[4];
    const elx = g_eye_l_norm[0];
    const ely = g_eye_l_norm[1];
    const elv = g_eye_l_valid;
    const erx = g_eye_r_norm[0];
    const ery = g_eye_r_norm[1];
    const erv = g_eye_r_valid;
    var trail: [TRAIL_LEN][2]f64 = undefined;
    const head_i = g_trail_head;
    for (0..TRAIL_LEN) |i| trail[i] = g_trail[(head_i + i) % TRAIL_LEN];
    g_lock.unlock();

    const W = @as(f64, @floatFromInt(width));
    const H = @as(f64, @floatFromInt(height));

    c.cairo_set_source_rgb(cr, 0.09, 0.10, 0.12);
    c.cairo_paint(cr);

    // ── EYE: monitor + gaze point ────────────────────────────────────
    const sx: f64 = 12;
    const sy: f64 = 14;
    const sw = W - 24;
    const sh = (H - 44) * 0.58;

    c.cairo_set_source_rgb(cr, 0.16, 0.18, 0.22);
    cairoRoundedRect(cr, sx, sy, sw, sh, 6);
    c.cairo_fill(cr);
    c.cairo_set_source_rgb(cr, 0.32, 0.35, 0.40);
    c.cairo_set_line_width(cr, 1);
    cairoRoundedRect(cr, sx, sy, sw, sh, 6);
    c.cairo_stroke(cr);

    const cx = sx + sw * 0.5;
    const cy = sy + sh * 0.5;
    c.cairo_set_source_rgb(cr, 0.35, 0.38, 0.42);
    c.cairo_move_to(cr, cx - 10, cy);
    c.cairo_line_to(cr, cx + 10, cy);
    c.cairo_stroke(cr);
    c.cairo_move_to(cr, cx, cy - 10);
    c.cairo_line_to(cr, cx, cy + 10);
    c.cairo_stroke(cr);

    for (0..TRAIL_LEN) |i| {
        const alpha = 0.12 + 0.55 * (@as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(TRAIL_LEN - 1)));
        c.cairo_set_source_rgba(cr, 0.4, 0.9, 0.55, alpha);
        c.cairo_arc(cr, sx + trail[i][0] * sw, sy + trail[i][1] * sh, 2.0, 0, 2 * std.math.pi);
        c.cairo_fill(cr);
    }

    // Per-eye dots (left/right), color-coded by validity: yellow = tracked,
    // red = lost. The pupil shifts independently, so two dots make eye-swap
    // or loss visible at a glance.
    const drawEye = struct {
        fn f(cr2: *c.cairo_t, x: f64, y: f64, valid: bool, ox: f64, oy: f64, ow: f64, oh: f64) void {
            const px = ox + x * ow;
            const py = oy + y * oh;
            if (valid) {
                c.cairo_set_source_rgb(cr2, 0.98, 0.92, 0.25);
            } else {
                c.cairo_set_source_rgb(cr2, 0.85, 0.25, 0.25);
            }
            c.cairo_arc(cr2, px, py, 4.5, 0, 2 * std.math.pi);
            c.cairo_fill(cr2);
            c.cairo_set_source_rgb(cr2, 0, 0, 0);
            c.cairo_arc(cr2, px, py, 1.8, 0, 2 * std.math.pi);
            c.cairo_fill(cr2);
        }
    }.f;
    drawEye(cr, elx, ely, elv, sx, sy, sw, sh);
    drawEye(cr, erx, ery, erv, sx, sy, sw, sh);

    c.cairo_set_source_rgb(cr, 0.62, 0.67, 0.72);
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
    c.cairo_set_font_size(cr, 11);
    c.cairo_move_to(cr, sx + 4, sy + 11);
    c.cairo_show_text(cr, "EYE");

    // ── HEAD: front view, nose shows yaw/pitch estimation ────────────
    const hy = sy + sh + 10;
    const hc_x = W * 0.5;
    const hc_y = hy + (H - 26 - hy) * 0.5;
    const hr: f64 = 26;

    c.cairo_set_source_rgb(cr, 0.22, 0.25, 0.30);
    c.cairo_arc(cr, hc_x, hc_y, hr, 0, 2 * std.math.pi);
    c.cairo_fill(cr);
    c.cairo_set_source_rgb(cr, 0.55, 0.6, 0.65);
    c.cairo_set_line_width(cr, 1.5);
    c.cairo_arc(cr, hc_x, hc_y, hr, 0, 2 * std.math.pi);
    c.cairo_stroke(cr);

    const disp_yaw = std.math.clamp(yaw, -45, 45);
    const disp_pitch = std.math.clamp(pitch, -30, 30);
    const nx = hc_x + disp_yaw * 1.1;
    const ny = hc_y - disp_pitch * 1.1;
    c.cairo_set_source_rgb(cr, 0.95, 0.5, 0.2);
    c.cairo_set_line_width(cr, 2.5);
    c.cairo_move_to(cr, hc_x, hc_y);
    c.cairo_line_to(cr, nx, ny);
    c.cairo_stroke(cr);
    c.cairo_arc(cr, nx, ny, 3.5, 0, 2 * std.math.pi);
    c.cairo_fill(cr);

    c.cairo_set_source_rgb(cr, 0.62, 0.67, 0.72);
    c.cairo_move_to(cr, hc_x - 20, hy + 12);
    c.cairo_show_text(cr, "HEAD");
}

fn onTick(_: ?*anyopaque) callconv(.c) c_int {
    if (g_quit.load(.acquire)) {
        if (g_app) |app| c.g_application_quit(@ptrCast(app));
        return 0;
    }
    g_tick +%= 1;
    if (g_tick % 125 == 0) updateLabels(); // numbers at 1 Hz (UI thread)
    if (g_tick % 12 == 0) {
        if (g_draw) |d| c.gtk_widget_queue_draw(@ptrCast(d)); // viz at ~10 Hz
        // Calibration window repaints (stream thread never touches GTK).
        if (g_cal_da) |da| c.gtk_widget_queue_draw(@ptrCast(da));
    }
    return 1; // keep source
}

// ─── Preset handlers ─────────────────────────────────────────────────

fn savePresetsToDisk() void {
    tobii.saveUserPresets(g_presets_arena.allocator(), g_preset_list.items) catch |e| {
        log.err("cannot save presets: {s}", .{@errorName(e)});
    };
}

fn syncSliders() void {
    const axes = [_]SensAxis{
        .yaw,     .pitch,  .deadzone,      .smoothing,
        .pos_smoothing, .head_gain, .pitch_gain, .eye_ratio, .pos_gain,
        .neck,    .gaze_scale, .gaze_scale_pitch, .curve_exp,
    };
    for (axes) |axis| {
        if (sensScale(axis).*) |sc| c.gtk_range_set_value(@ptrCast(@alignCast(sc)), sensField(axis).*);
    }
    if (g_dropdown_curve) |dd| c.gtk_drop_down_set_selected(@ptrCast(dd), g_opts.p.curve_mode);
    if (g_dropdown_smooth) |dd| c.gtk_drop_down_set_selected(@ptrCast(dd), g_opts.p.smooth_mode);
    if (g_check_flip_yaw) |cb| c.gtk_toggle_button_set_active(@ptrCast(cb), @intFromBool(g_opts.p.flip_yaw));
    if (g_check_flip_pitch) |cb| c.gtk_check_button_set_active(@ptrCast(cb), @intFromBool(g_opts.p.flip_pitch));
    updateSourceLabel();
}

fn loadPreset(idx: usize) void {
    if (idx >= g_preset_list.items.len) return;
    g_lock.lock();
    g_opts.p = g_preset_list.items[idx];
    g_lock.unlock();
    g_cur_preset_idx = idx;
    syncSliders();
    const is_builtin = idx < tobii.BUILTIN_PRESETS.len;
    if (g_btn_save) |b| c.gtk_widget_set_sensitive(wptr(b), @intFromBool(!is_builtin));
    if (g_btn_delete) |b| c.gtk_widget_set_sensitive(wptr(b), @intFromBool(!is_builtin));
}

var g_syncing_preset_ui: bool = false;

fn refreshPresetStrings() void {
    const sl = c.gtk_string_list_new(null);
    for (g_preset_list.items) |p| {
        var zbuf: [256]u8 = undefined;
        const name = p.name;
        if (name.len >= zbuf.len) continue;
        @memcpy(zbuf[0..name.len], name);
        zbuf[name.len] = 0;
        c.gtk_string_list_append(sl, zbuf[0..name.len :0].ptr);
    }
    if (g_dropdown_preset) |dd| {
        g_syncing_preset_ui = true;
        c.gtk_drop_down_set_model(@ptrCast(dd), @ptrCast(sl));
        c.gtk_drop_down_set_selected(@ptrCast(dd), @intCast(g_cur_preset_idx));
        g_syncing_preset_ui = false;
    }
    if (g_strings_preset) |old| c.g_object_unref(@ptrCast(old));
    g_strings_preset = sl;
}

fn onPresetChanged(obj: ?*c.GObject, _: ?*c.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    if (g_syncing_preset_ui) return;
    const dd: *c.GtkDropDown = @ptrCast(@alignCast(obj));
    const idx = c.gtk_drop_down_get_selected(dd);
    if (idx >= g_preset_list.items.len) return;
    if (idx == g_cur_preset_idx) return;
    loadPreset(idx);
}

fn onCurveChanged(obj: ?*c.GObject, _: ?*c.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const dd: *c.GtkDropDown = @ptrCast(@alignCast(obj));
    const idx = c.gtk_drop_down_get_selected(dd);
    if (idx == g_opts.p.curve_mode) return;
    g_lock.lock();
    g_opts.p.curve_mode = @intCast(idx);
    g_lock.unlock();
    updateSourceLabel();
}

fn onSmoothChanged(obj: ?*c.GObject, _: ?*c.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const dd: *c.GtkDropDown = @ptrCast(@alignCast(obj));
    const idx = c.gtk_drop_down_get_selected(dd);
    if (idx == g_opts.p.smooth_mode) return;
    g_lock.lock();
    g_opts.p.smooth_mode = @intCast(@min(idx, @intFromEnum(tobii.SmoothMode.none)));
    g_lock.unlock();
    updateSourceLabel();
}

fn onFlipToggled(btn: [*c]c.GtkToggleButton, data: ?*anyopaque) callconv(.c) void {
    const active = c.gtk_toggle_button_get_active(btn) != 0;
    const is_pitch = data != null;
    const cur = if (is_pitch) g_opts.p.flip_pitch else g_opts.p.flip_yaw;
    if (active == cur) return;
    g_lock.lock();
    if (is_pitch) g_opts.p.flip_pitch = active else g_opts.p.flip_yaw = active;
    g_lock.unlock();
}

fn onRecenterClicked(_: [*c]c.GtkButton, _: ?*anyopaque) callconv(.c) void {
    g_recenter_request.store(true, .release);
}

// ─── Calibration wizard ──────────────────────────────────────────────

fn onCalibrateClicked(_: [*c]c.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (g_cal_window != null) return; // already open
    g_calibrator.start();
    openCalWindow();
    log.info("calibration wizard started", .{});
}

fn openCalWindow() void {
    const win = c.gtk_window_new();
    g_cal_window = @ptrCast(win);
    c.gtk_window_set_title(@ptrCast(win), "Calibration — TobiiArgus");
    c.gtk_window_set_icon_name(@ptrCast(win), "tobiiargus");
    c.gtk_window_set_default_size(@ptrCast(win), 1920, 1080);
    c.gtk_window_fullscreen(@ptrCast(win));

    const da = c.gtk_drawing_area_new();
    g_cal_da = @ptrCast(da);
    c.gtk_drawing_area_set_draw_func(@ptrCast(da), @ptrCast(&calDrawFunc), null, null);
    c.gtk_widget_set_vexpand(@ptrCast(da), 1);
    c.gtk_widget_set_hexpand(@ptrCast(da), 1);
    c.gtk_window_set_child(@ptrCast(win), @ptrCast(da));

    // Key event controller must live on the TOPLEVEL WINDOW: a GtkDrawingArea
    // is not focusable by default, so it would never receive key events.
    const key_ctrl = c.gtk_event_controller_key_new();
    _ = c.g_signal_connect_data(@ptrCast(key_ctrl), "key-pressed", @ptrCast(&calKeyPressed), null, null, 0);
    c.gtk_widget_add_controller(@ptrCast(win), @ptrCast(key_ctrl));

    c.gtk_window_present(@ptrCast(win));
}

fn calDrawFunc(da: [*c]c.GtkDrawingArea, cr: *c.cairo_t, width: c_int, height: c_int, _: ?*anyopaque) callconv(.c) void {
    _ = da;
    // Snapshot wizard state under the lock (stream thread mutates it).
    g_cal_mutex.lock();
    const st = g_calibrator.state;
    const prog = g_calibrator.progress();
    const cap_n = g_calibrator.sample_count;
    const cur_pt = g_calibrator.current_point + 1;
    const retries = g_calibrator.retries;
    const pt = g_calibrator.currentPoint();
    g_cal_mutex.unlock();

    // Dark background.
    c.cairo_set_source_rgb(cr, 0.1, 0.1, 0.1);
    c.cairo_paint(cr);

    const dot_r: f64 = 12;

    // Map normalized [0,1] to pixel coords.
    const px = pt.x * @as(f64, @floatFromInt(width));
    const py = pt.y * @as(f64, @floatFromInt(height));

    // White dot.
    c.cairo_set_source_rgb(cr, 1, 1, 1);
    c.cairo_arc(cr, px, py, dot_r, 0, 2.0 * 3.14159265);
    c.cairo_fill(cr);

    // Green progress ring around the dot during capturing.
    if (st == .capturing) {
        const sweep = 2.0 * 3.14159265 * (@as(f64, @floatFromInt(cap_n)) / @as(f64, @floatFromInt(calibration.SAMPLES_PER_POINT)));
        c.cairo_set_source_rgb(cr, 0.2, 1.0, 0.4);
        c.cairo_set_line_width(cr, 4);
        c.cairo_arc(cr, px, py, dot_r + 6, -3.14159265 * 0.5, -3.14159265 * 0.5 + sweep);
        c.cairo_stroke(cr);
    }

    // Progress bar at bottom.
    const bar_h: f64 = 4;
    const w_f = @as(f64, @floatFromInt(width));
    const h_f = @as(f64, @floatFromInt(height));
    c.cairo_set_source_rgb(cr, 0.3, 0.3, 0.3);
    c.cairo_rectangle(cr, 0, h_f - bar_h, w_f, bar_h);
    c.cairo_fill(cr);
    c.cairo_set_source_rgb(cr, 0.2, 0.8, 0.4);
    c.cairo_rectangle(cr, 0, h_f - bar_h, w_f * prog, bar_h);
    c.cairo_fill(cr);

    // Instruction BELOW the dot — bold yellow, centered, high contrast.
    var status_buf: [96]u8 = undefined;
    // Point counter in the top-left corner.
    if (std.fmt.bufPrint(&status_buf, "Point {d}/{}", .{ cur_pt, calibration.NUM_CAL_POINTS })) |ptext| {
        c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
        c.cairo_set_font_size(cr, 16);
        c.cairo_move_to(cr, 16, 30);
        c.cairo_set_source_rgb(cr, 0.6, 0.6, 0.6);
        calShowText(cr, ptext);
    } else |_| {}
    // "press SPACE" centered directly below the dot.
    if (st == .showing_point) {
        c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
        c.cairo_set_font_size(cr, 26);
        var ext: c.cairo_text_extents_t = undefined;
        calMeasureText(cr, "press SPACE", &ext);
        c.cairo_move_to(cr, (w_f - ext.width) / 2.0, py + 60);
        c.cairo_set_source_rgb(cr, 1.0, 0.85, 0.1); // bright yellow on dark bg
        calShowText(cr, "press SPACE");
    }
    // Small capturing counter below the dot (slot free during .capturing).
    if (st == .capturing) {
        var cap_buf: [48]u8 = undefined;
        if (std.fmt.bufPrint(&cap_buf, "{d}/{}", .{
            cap_n, calibration.SAMPLES_PER_POINT,
        })) |cap| {
            c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
            c.cairo_set_font_size(cr, 14);
            var ext2: c.cairo_text_extents_t = undefined;
            calMeasureText(cr, cap, &ext2);
            c.cairo_move_to(cr, (w_f - ext2.width) / 2.0, py + 60);
            c.cairo_set_source_rgba(cr, 0.5, 0.9, 0.5, 0.7); // subtle green
            calShowText(cr, cap);
        } else |_| {}
    }

    // Retry hint after a weak/eye-loss capture.
    if (st == .showing_point and retries > 0) {
        var retry_buf: [96]u8 = undefined;
        if (std.fmt.bufPrint(&retry_buf, "Eyes lost - sit back a little, SPACE to retry ({d}/{d})", .{
            retries + 1, calibration.MAX_POINT_RETRIES,
        })) |hint| {
            c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
            c.cairo_set_font_size(cr, 20);
            var ext: c.cairo_text_extents_t = undefined;
            calMeasureText(cr, hint, &ext);
            c.cairo_move_to(cr, (w_f - ext.width) / 2.0, h_f / 2.0 + 90);
            c.cairo_set_source_rgb(cr, 1.0, 0.35, 0.25); // red-orange alert
            calShowText(cr, hint);
        } else |_| {}
    }

    // Abort message — shown for 3 seconds before the window closes.
    if (st == .error_state) {
        c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
        c.cairo_set_font_size(cr, 28);
        var ext: c.cairo_text_extents_t = undefined;
        calMeasureText(cr, "Calibration aborted", &ext);
        c.cairo_move_to(cr, (w_f - ext.width) / 2.0, h_f / 2.0 - 20);
        c.cairo_set_source_rgb(cr, 1.0, 0.2, 0.2); // bright red
        calShowText(cr, "Calibration aborted");

        c.cairo_set_font_size(cr, 18);
        calMeasureText(cr, "Failed to capture enough eye data at this corner.", &ext);
        c.cairo_move_to(cr, (w_f - ext.width) / 2.0, h_f / 2.0 + 30);
        c.cairo_set_source_rgb(cr, 0.9, 0.5, 0.5);
        calShowText(cr, "Failed to capture enough eye data at this corner.");

        calMeasureText(cr, "Move head closer to center, then try again.", &ext);
        c.cairo_move_to(cr, (w_f - ext.width) / 2.0, h_f / 2.0 + 60);
        calShowText(cr, "Move head closer to center, then try again.");
    }

    // Waiting for the daemon's calibration blob reply.
    if (st == .waiting_response or st == .done) {
        c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
        c.cairo_set_font_size(cr, 24);
        var ext: c.cairo_text_extents_t = undefined;
        calMeasureText(cr, "Applying calibration...", &ext);
        c.cairo_move_to(cr, (w_f - ext.width) / 2.0, h_f / 2.0 + 90);
        c.cairo_set_source_rgb(cr, 1, 1, 1);
        calShowText(cr, "Applying calibration...");
    }

    // Small cancel hint, bottom-left.
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, 13);
    c.cairo_move_to(cr, 16, h_f - 16);
    c.cairo_set_source_rgb(cr, 0.55, 0.55, 0.55);
    calShowText(cr, "ESC = cancel");
}

/// Draw a Zig slice via cairo_show_text by copying into a NUL-terminated
/// scratch buffer (bufPrint results are not NUL-terminated; cairo needs C strings).
var g_cairo_text_scratch: [256]u8 = undefined;
fn calShowText(cr: *c.cairo_t, s: []const u8) void {
    if (s.len >= g_cairo_text_scratch.len) return;
    @memcpy(g_cairo_text_scratch[0..s.len], s);
    g_cairo_text_scratch[s.len] = 0;
    c.cairo_show_text(cr, @ptrCast(g_cairo_text_scratch[0..s.len :0].ptr));
}

/// Measure text extents with a NUL-terminated copy.
fn calMeasureText(cr: *c.cairo_t, s: []const u8, ext: *c.cairo_text_extents_t) void {
    ext.* = std.mem.zeroes(c.cairo_text_extents_t);
    if (s.len >= g_cairo_text_scratch.len) return;
    @memcpy(g_cairo_text_scratch[0..s.len], s);
    g_cairo_text_scratch[s.len] = 0;
    c.cairo_text_extents(cr, @ptrCast(g_cairo_text_scratch[0..s.len :0].ptr), ext);
}

fn closeCalWindow() void {
    if (g_cal_window) |w| {
        c.gtk_window_destroy(@ptrCast(w));
        g_cal_window = null;
        g_cal_da = null;
    }
}

/// Marshal window teardown onto the GTK main loop — GTK4 objects must only be
/// touched from the main thread, and this runs via g_idle_add from any thread.
fn idleCloseCalWindow(_: ?*anyopaque) callconv(.c) c_int {
    g_cal_mutex.lock();
    g_calibrator.state = .idle;
    g_cal_mutex.unlock();
    closeCalWindow();
    return 0; // one-shot: remove source
}

/// Safety net: if the daemon's finish_calibration reply never arrives,
/// stop waiting and close the wizard (display-area JSON was already saved).
fn calWaitTimeout(_: ?*anyopaque) callconv(.c) c_int {
    g_cal_mutex.lock();
    const waiting = g_calibrator.state == .waiting_response;
    if (waiting) g_calibrator.state = .idle;
    g_cal_mutex.unlock();
    if (waiting) {
        log.warn("no calibration blob reply from daemon — display area saved, device cal skipped", .{});
        _ = idleCloseCalWindow(null);
    }
    return 0; // one-shot: remove source
}

/// After a failed calibration run, show the abort message for a few seconds
/// then close the window so the user can read it.
fn calAbortTimeout(_: ?*anyopaque) callconv(.c) c_int {
    g_cal_mutex.lock();
    g_calibrator.state = .idle;
    g_cal_mutex.unlock();
    closeCalWindow();
    return 0; // one-shot: remove source
}

fn calKeyPressed(_: *c.GtkEventControllerKey, keyval: c_uint, _: c_uint, _: c_uint, _: ?*anyopaque) callconv(.c) c_int {
    const GDK_KEY_space: c_uint = 0x020; // XK_space
    const GDK_KEY_Escape: c_uint = 0xff1b;

    if (keyval == GDK_KEY_Escape) {
        g_cal_mutex.lock();
        g_calibrator.cancel();
        g_cal_mutex.unlock();
        closeCalWindow(); // already on the GTK main thread here
        return 1; // handled
    }

    if (keyval == GDK_KEY_space) {
        g_cal_mutex.lock();
        defer g_cal_mutex.unlock();
        if (g_calibrator.state == .showing_point) {
            g_calibrator.beginCapture();
            if (g_cal_da) |da| c.gtk_widget_queue_draw(@ptrCast(da)); // main thread OK
            return 1;
        }
    }

    return 0; // not handled
}

/// Stream-thread side: feed samples into the wizard. Never touches GTK here —
/// redraws are driven by onTick on the main thread.
fn calFeedGaze(sample: *const proto.GazeSample) void {
    g_cal_mutex.lock();
    const done = g_calibrator.feedSample(sample);
    var outcome: ?calibration.Calibrator.PointOutcome = null;
    if (done) outcome = g_calibrator.finalizePoint();
    g_cal_mutex.unlock();

    switch (outcome orelse return) {
        .next_point => {},
        .retry => {}, // same dot stays up; hint drawn from state snapshot
        .finished => sendCalibrationToDaemon(), // socket + file IO only
        .failed => {
            // Show the abort message for 3 seconds before closing.
            _ = c.g_timeout_add(3000, @ptrCast(&calAbortTimeout), null);
        },
    }
}

/// Stream-thread side: runs once all points are captured. Sends the device
/// calibration sequence, then waits for the daemon's finish_calibration blob
/// reply (see onDaemonResponse).
fn sendCalibrationToDaemon() void {
    g_cal_mutex.lock();
    g_calibrator.state = .waiting_response;
    var results: [calibration.NUM_CAL_POINTS][2]f64 = undefined;
    for (0..calibration.NUM_CAL_POINTS) |i| results[i] = g_calibrator.result_gaze[i];
    g_cal_mutex.unlock();

    const sock = g_cal_socket orelse {
        log.err("no daemon connection — cannot run device-side calibration", .{});
        _ = c.g_idle_add(@ptrCast(&idleCloseCalWindow), null);
        return;
    };

    // Device-side sequence. add_calibration_point takes two f64s (x, y) per
    // point — see tobiifreed buildRequest().
    sock.sendCommand(.start_calibration, &.{});
    for (results) |r| {
        var pt_payload: [16]u8 = undefined;
        std.mem.bytesAsValue(f64, pt_payload[0..8]).* = r[0];
        std.mem.bytesAsValue(f64, pt_payload[8..16]).* = r[1];
        sock.sendCommand(.add_calibration_point, &pt_payload);
    }
    sock.sendCommand(.finish_calibration, &.{});

    // NOTE: With the new architecture (v0.2.5), the device display area is
    // recomputed from physical_screen × track_box_factor on every daemon start.
    // Calibration only adjusts the device's internal gaze estimation (via the
    // calibration blob). The bridge's affine correction (gaze_y_offset/scale)
    // is a preset parameter, not a calibration result. Nothing to persist here.
    log.info("calibration sent to device; awaiting blob reply", .{});

    // Window stays open ("Applying…") until the blob reply arrives; if it
    // never does, calWaitTimeout closes after 4 s.
    _ = c.g_timeout_add(4000, @ptrCast(&calWaitTimeout), null);
}

/// Stream-thread side (called during socket poll): daemon replied to our
/// finish_calibration — stash the blob, send it back as cal_apply, close.
/// Also handles get_display_area to get physical_screen dimensions.
fn onDaemonResponse(cmd_type: u8, payload: []const u8) void {
    if (cmd_type == @intFromEnum(proto.Cmd.get_display_area)) {
        // Extended response: 11 f64 = 88 bytes (9 corners + physical_screen w_mm, h_mm)
        if (payload.len == 88) {
            var phys_w_bits: u64 = 0;
            var phys_h_bits: u64 = 0;
            @memcpy(std.mem.asBytes(&phys_w_bits), payload[72..80]);
            @memcpy(std.mem.asBytes(&phys_h_bits), payload[80..88]);
            const phys_w: f64 = @bitCast(phys_w_bits);
            const phys_h: f64 = @bitCast(phys_h_bits);
            g_physical_screen = da_config.PhysicalScreen{ .w_mm = phys_w, .h_mm = phys_h };
            log.info("received physical screen: {d:.0}×{d:.0}mm", .{ phys_w, phys_h });
        }
        return;
    }

    if (cmd_type != @intFromEnum(proto.Cmd.finish_calibration)) return;

    g_cal_mutex.lock();
    const waiting = g_calibrator.state == .waiting_response;
    if (waiting) {
        if (payload.len > 0 and payload.len <= g_cal_blob.len) {
            @memcpy(g_cal_blob[0..payload.len], payload);
            g_cal_blob_len = payload.len;
            g_calibrator.state = .done;
        } else {
            g_cal_blob_len = 0;
            g_calibrator.state = .error_state;
        }
    }
    g_cal_mutex.unlock();

    if (!waiting) return;

    if (g_cal_blob_len > 0) {
        if (g_cal_socket) |sock| sock.sendCommand(.cal_apply, g_cal_blob[0..g_cal_blob_len]);
        log.info("device calibration applied ({d} B blob)", .{g_cal_blob_len});
    } else {
        log.err("daemon returned empty calibration blob — skipping cal_apply", .{});
    }
    _ = c.g_idle_add(@ptrCast(&idleCloseCalWindow), null);
}

fn onSaveClicked(_: [*c]c.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (g_cur_preset_idx < tobii.BUILTIN_PRESETS.len) return;
    g_preset_list.items[g_cur_preset_idx] = g_opts.p;
    savePresetsToDisk();
}

fn onSaveAsResponse(dialog: [*c]c.GtkDialog, resp: c_int, _: ?*anyopaque) callconv(.c) void {
    defer c.gtk_window_destroy(@ptrCast(dialog));
    if (resp != c.GTK_RESPONSE_OK) return;
    if (g_saveas_entry == null) return;
    const text = std.mem.span(c.gtk_editable_get_text(@ptrCast(g_saveas_entry.?)));
    const name = std.mem.trim(u8, text, " \t");
    if (name.len == 0) return;
    if (tobii.findPreset(g_preset_list.items, name) != null) {
        log.err("preset '{s}' already exists", .{name});
        return;
    }
    const alloc = g_presets_arena.allocator();
    const nm = alloc.dupe(u8, name) catch return;
    g_lock.lock();
    var copy = g_opts.p;
    g_lock.unlock();
    copy.name = nm;
    g_preset_list.append(copy) catch return;
    g_cur_preset_idx = g_preset_list.items.len - 1;
    refreshPresetStrings();
    savePresetsToDisk();
}

fn onSaveAsClicked(_: [*c]c.GtkButton, _: ?*anyopaque) callconv(.c) void {
    const dialog = c.gtk_dialog_new_with_buttons(
        "Save preset as…",
        g_window orelse null,
        c.GTK_DIALOG_MODAL,
        "Cancel", c.GTK_RESPONSE_CANCEL,
        "Save", c.GTK_RESPONSE_OK,
        @as(?[*:0]const u8, null),
    );
    const content = c.gtk_dialog_get_content_area(@ptrCast(dialog));
    const entry = c.gtk_entry_new();
    g_saveas_entry = @ptrCast(entry);
    c.gtk_entry_set_placeholder_text(@ptrCast(entry), "Preset name");
    c.gtk_widget_set_margin_start(wptr(entry), 10);
    c.gtk_widget_set_margin_end(wptr(entry), 10);
    c.gtk_widget_set_margin_top(wptr(entry), 10);
    c.gtk_widget_set_margin_bottom(wptr(entry), 10);
    c.gtk_box_append(@ptrCast(content), wptr(entry));
    _ = c.g_signal_connect_data(@ptrCast(dialog), "response", @ptrCast(&onSaveAsResponse), null, null, 0);
    c.gtk_window_present(@ptrCast(dialog));
}

fn onDeleteClicked(_: [*c]c.GtkButton, _: ?*anyopaque) callconv(.c) void {
    if (g_cur_preset_idx < tobii.BUILTIN_PRESETS.len) return;
    _ = g_preset_list.orderedRemove(g_cur_preset_idx);
    g_cur_preset_idx = 0;
    loadPreset(0);
    refreshPresetStrings();
    savePresetsToDisk();
}

fn addPresetRow(box: [*c]c.GtkWidget) void {
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);

    const dd = c.gtk_drop_down_new(null, null);
    c.gtk_widget_set_hexpand(dd, 1);
    c.gtk_box_append(@ptrCast(row), dd);
    g_dropdown_preset = @ptrCast(dd);
    _ = c.g_signal_connect_data(@ptrCast(dd), "notify::selected", @ptrCast(&onPresetChanged), null, null, 0);

    const btn_save = c.gtk_button_new_with_label("Save");
    c.gtk_box_append(@ptrCast(row), btn_save);
    g_btn_save = @ptrCast(btn_save);
    _ = c.g_signal_connect_data(@ptrCast(btn_save), "clicked", @ptrCast(&onSaveClicked), null, null, 0);

    const btn_save_as = c.gtk_button_new_with_label("Save as…");
    c.gtk_box_append(@ptrCast(row), btn_save_as);
    g_btn_save_as = @ptrCast(btn_save_as);
    _ = c.g_signal_connect_data(@ptrCast(btn_save_as), "clicked", @ptrCast(&onSaveAsClicked), null, null, 0);

    const btn_delete = c.gtk_button_new_with_label("Delete");
    c.gtk_box_append(@ptrCast(row), btn_delete);
    g_btn_delete = @ptrCast(btn_delete);
    _ = c.g_signal_connect_data(@ptrCast(btn_delete), "clicked", @ptrCast(&onDeleteClicked), null, null, 0);

    c.gtk_box_append(@ptrCast(box), row);
}

fn activate(_: *c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    const app = @as(*c.GtkApplication, @ptrCast(@alignCast(c.g_application_get_default())));
    g_app = @ptrCast(app);

    const window = c.gtk_application_window_new(@ptrCast(app));
    g_window = @ptrCast(window);
    c.gtk_window_set_title(@ptrCast(window), "TobiiArgus — Tobii → OpenTrack");
    c.gtk_window_set_icon_name(@ptrCast(window), "tobiiargus");
    c.gtk_window_set_default_size(@ptrCast(window), 1024, 780);

    // CSS: monospace values.
    const css = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(
        css,
        ".value { font-family: monospace; font-size: 17px; }" ++
            ".status { font-weight: bold; }" ++
            ".hint { font-size: 11px; opacity: 0.75; }" ++
            ".dim { font-size: 11px; opacity: 0.55; }",
    );
    c.gtk_style_context_add_provider_for_display(
        c.gdk_display_get_default(),
        @ptrCast(css),
        c.GTK_STYLE_PROVIDER_PRIORITY_USER,
    );

    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8);
    c.gtk_widget_set_margin_start(box, 14);
    c.gtk_widget_set_margin_end(box, 14);
    c.gtk_widget_set_margin_top(box, 10);
    c.gtk_widget_set_margin_bottom(box, 10);

    // Status + source line.
    g_label_status = @ptrCast(c.gtk_label_new(null));
    c.gtk_widget_set_halign(wptr(g_label_status), c.GTK_ALIGN_START);
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(wptr(g_label_status)), "status");
    c.gtk_box_append(@ptrCast(box), wptr(g_label_status));

    g_label_source = @ptrCast(c.gtk_label_new(null));
    c.gtk_widget_set_halign(wptr(g_label_source), c.GTK_ALIGN_START);
    c.gtk_label_set_xalign(@ptrCast(g_label_source), 0);
    c.gtk_box_append(@ptrCast(box), wptr(g_label_source));
    updateSourceLabel();

    // Note: this is emulated headtracking (eye→head via OpenTrack), not
    // native Tobii game integration (Windows-only API).
    const note_label = c.gtk_label_new("Emulated Headtracking via OpenTrack Protocol  ·  Not native Tobii game integration");
    c.gtk_widget_set_halign(wptr(note_label), c.GTK_ALIGN_START);
    c.gtk_label_set_xalign(@ptrCast(note_label), 0);
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(wptr(note_label)), "dim");
    c.gtk_box_append(@ptrCast(box), wptr(note_label));

    // Input mappings (left) + live eye/head visualization (right), above the
    // setting sliders.
    const top_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 16);
    c.gtk_box_append(@ptrCast(box), @ptrCast(top_row));

    const val_col = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    c.gtk_box_append(@ptrCast(top_row), @ptrCast(val_col));

    const grid = c.gtk_grid_new();
    c.gtk_grid_set_column_spacing(@ptrCast(grid), 16);
    c.gtk_grid_set_row_spacing(@ptrCast(grid), 2);
    c.gtk_box_append(@ptrCast(val_col), @ptrCast(grid));

    addValueRow(grid, 0, "X (cm)", &g_label_x);
    addValueRow(grid, 1, "Y (cm)", &g_label_y);
    addValueRow(grid, 2, "Z (cm)", &g_label_z);
    addValueRow(grid, 3, "Yaw", &g_label_yaw);
    addValueRow(grid, 4, "Pitch", &g_label_pitch);
    addValueRow(grid, 5, "Roll", &g_label_roll);

    const da = c.gtk_drawing_area_new();
    c.gtk_widget_set_size_request(da, 300, 220);
    c.gtk_drawing_area_set_draw_func(@ptrCast(da), @ptrCast(&drawViz), null, null);
    g_draw = @ptrCast(da);
    c.gtk_box_append(@ptrCast(top_row), da);

    addSectionTitle(box, "Presets");
    addPresetRow(box);

    // Sensitivity section.
    addSectionTitle(box, "Sensitivity");
    const sens_grid = c.gtk_grid_new();
    c.gtk_grid_set_column_spacing(@ptrCast(sens_grid), 10);
    c.gtk_grid_set_row_spacing(@ptrCast(sens_grid), 4);
    c.gtk_box_append(@ptrCast(box), @ptrCast(sens_grid));
    addSensRow(sens_grid, 0, "Yaw cap (°)", .yaw);
    addSensRow(sens_grid, 1, "Pitch cap (°)", .pitch);
    addSensRow(sens_grid, 2, "Deadzone (°)", .deadzone);
    addSensRow(sens_grid, 3, "Smoothing (rest)", .smoothing);
    addSensRow(sens_grid, 4, "Pos smoothing (rest)", .pos_smoothing);

    // Tobii-feel section.
    addSectionTitle(box, "Tobii feel");
    const feel_grid = c.gtk_grid_new();
    c.gtk_grid_set_column_spacing(@ptrCast(feel_grid), 10);
    c.gtk_grid_set_row_spacing(@ptrCast(feel_grid), 4);
    c.gtk_box_append(@ptrCast(box), @ptrCast(feel_grid));
    addSensRow(feel_grid, 0, "Head gain", .head_gain);
    addSensRow(feel_grid, 1, "Pitch gain", .pitch_gain);
    addSensRow(feel_grid, 2, "Eye ratio", .eye_ratio);
    addSensRow(feel_grid, 3, "Pos gain", .pos_gain);
    addSensRow(feel_grid, 4, "Neck (cm)", .neck);
    addSensRow(feel_grid, 5, "Gaze yaw scale", .gaze_scale);
    addSensRow(feel_grid, 6, "Gaze pitch scale", .gaze_scale_pitch);
    addSensRow(feel_grid, 7, "Curve exp", .curve_exp);

    // Curve mode dropdown + flips.
    const mode_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    const mode_lbl = c.gtk_label_new("Curve:");
    c.gtk_box_append(@ptrCast(mode_row), @ptrCast(mode_lbl));
    const curve_dd = c.gtk_drop_down_new(null, null);
    c.gtk_widget_set_hexpand(curve_dd, 1);
    c.gtk_box_append(@ptrCast(mode_row), curve_dd);
    g_dropdown_curve = @ptrCast(curve_dd);
    const curve_sl = c.gtk_string_list_new(null);
    c.gtk_string_list_append(curve_sl, "Linear");
    c.gtk_string_list_append(curve_sl, "Power");
    c.gtk_string_list_append(curve_sl, "Tobii");
    g_strings_curve = curve_sl;
    c.gtk_drop_down_set_model(@ptrCast(curve_dd), @ptrCast(curve_sl));
    c.gtk_drop_down_set_selected(@ptrCast(curve_dd), g_opts.p.curve_mode);
    _ = c.g_signal_connect_data(@ptrCast(curve_dd), "notify::selected", @ptrCast(&onCurveChanged), null, null, 0);
    c.gtk_box_append(@ptrCast(box), @ptrCast(mode_row));

    // Smoothing-mode dropdown.
    const smooth_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    const smooth_lbl = c.gtk_label_new("Smoothing:");
    c.gtk_box_append(@ptrCast(smooth_row), @ptrCast(smooth_lbl));
    const smooth_dd = c.gtk_drop_down_new(null, null);
    c.gtk_widget_set_hexpand(smooth_dd, 1);
    c.gtk_box_append(@ptrCast(smooth_row), smooth_dd);
    g_dropdown_smooth = @ptrCast(smooth_dd);
    const smooth_sl = c.gtk_string_list_new(null);
    c.gtk_string_list_append(smooth_sl, "One Euro");
    c.gtk_string_list_append(smooth_sl, "Accela");
    c.gtk_string_list_append(smooth_sl, "None");
    g_strings_smooth = smooth_sl;
    c.gtk_drop_down_set_model(@ptrCast(smooth_dd), @ptrCast(smooth_sl));
    c.gtk_drop_down_set_selected(@ptrCast(smooth_dd), g_opts.p.smooth_mode);
    _ = c.g_signal_connect_data(@ptrCast(smooth_dd), "notify::selected", @ptrCast(&onSmoothChanged), null, null, 0);
    c.gtk_box_append(@ptrCast(box), @ptrCast(smooth_row));

    const flip_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    const flip_yaw = c.gtk_check_button_new_with_label("Flip yaw");
    c.gtk_box_append(@ptrCast(flip_row), @ptrCast(flip_yaw));
    g_check_flip_yaw = @ptrCast(flip_yaw);
    _ = c.g_signal_connect_data(@ptrCast(flip_yaw), "toggled", @ptrCast(&onFlipToggled), null, null, 0);
    const flip_pitch = c.gtk_check_button_new_with_label("Flip pitch");
    c.gtk_box_append(@ptrCast(flip_row), @ptrCast(flip_pitch));
    g_check_flip_pitch = @ptrCast(flip_pitch);
    _ = c.g_signal_connect_data(@ptrCast(flip_pitch), "toggled", @ptrCast(&onFlipToggled), @ptrFromInt(1), null, 0);
    const btn_recenter = c.gtk_button_new_with_label("Recenter");
    c.gtk_box_append(@ptrCast(flip_row), @ptrCast(btn_recenter));
    _ = c.g_signal_connect_data(@ptrCast(btn_recenter), "clicked", @ptrCast(&onRecenterClicked), null, null, 0);
    const btn_calibrate = c.gtk_button_new_with_label("Calibrate");
    c.gtk_box_append(@ptrCast(flip_row), @ptrCast(btn_calibrate));
    _ = c.g_signal_connect_data(@ptrCast(btn_calibrate), "clicked", @ptrCast(&onCalibrateClicked), null, null, 0);
    c.gtk_box_append(@ptrCast(box), @ptrCast(flip_row));

    const hint = c.gtk_label_new(
        "Engage head-look in game (X4: Ctrl+T). Recenter is the game's key (X4: Scroll Lock).",
    );
    c.gtk_widget_set_halign(hint, c.GTK_ALIGN_START);
    c.gtk_label_set_wrap(@ptrCast(hint), 1);
    c.gtk_label_set_xalign(@ptrCast(hint), 0);
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(hint), "hint");
    c.gtk_box_append(@ptrCast(box), @ptrCast(hint));

    c.gtk_window_set_child(@ptrCast(window), @ptrCast(box));
    c.gtk_window_present(@ptrCast(window));

    refreshPresetStrings();
    syncSliders();

    _ = c.g_timeout_add(8, @ptrCast(&onTick), null); // 125 Hz poll, ~30 Hz label refresh
}

// ─── CLI / lifecycle ─────────────────────────────────────────────────

fn usage() void {
    std.debug.print(
        \\tobiifree-opentrack — Tobii ET5 → OpenTrack bridge for Linux games
        \\
        \\Usage: tobiifree-opentrack [options]
        \\
        \\Options:
        \\  --preset <name>      load a preset (built-in or user-saved)
        \\  --list-presets       list available presets and exit
        \\  --save-preset <name> save current settings as a preset and exit
        \\  --host <ip>          UDP target host (default 127.0.0.1)
        \\  --port <n>           UDP target port (default 4242)
        \\  --yaw-gain <deg>     yaw output cap (default {d:.0})
        \\  --pitch-gain <deg>   pitch output cap (default {d:.0})
        \\  --smoothing <0..1>   rotation rest retention, heavy=responsive (default {d:.2})
        \\  --pos-smoothing <0..1> translation rest retention (default {d:.2})
        \\  --deadzone <deg>     yaw/pitch deadzone (default {d:.2})
        \\  --head-gain <0..5>   head-sensitivity multiplier (default {d:.1})
        \\  --pitch-boost <0.5..3> pitch input multiplier (default {d:.2})
        \\  --eye-ratio <0..1>   gaze contribution to rotation (default {d:.2})
        \\  --pos-gain <0..5>    translation multiplier (default {d:.1})
        \\  --neck <cm>          neck-pivot distance (default {d:.0})
        \\  --gaze-scale <deg>   gaze → yaw at screen edge (default {d:.0})
        \\  --gaze-scale-pitch <deg> gaze → pitch at screen edge (default {d:.0})
        \\  --gaze-y-offset <n>   error-map gaze-y offset, y=(raw+off)/scale (default {d:.3})
        \\  --gaze-y-scale <n>    error-map gaze-y scale, >=0.1 (default {d:.3})
        \\  --curve <linear|power|tobii> response curve (default tobii)
        \\  --curve-exp <0.2..3> power-curve exponent (default {d:.2})
        \\  --flip-yaw           invert head yaw direction
        \\  --flip-pitch         invert head pitch direction
        \\  --no-position        send zeros for head position
        \\  --headless           no GUI window, console logging only
        \\  -v, --verbose        verbose per-sample logging
        \\  -h, --help           show this help
        \\
        \\Run order: tobiifreedot → tobiifree-opentrack → game (OpenTrack on).
        \\Presets are stored in $XDG_CONFIG_HOME/tobiifree-opentrack/presets.json.
        \\
    , .{
        tobii.BUILTIN_PRESETS[0].max_yaw,
        tobii.BUILTIN_PRESETS[0].max_pitch,
        tobii.BUILTIN_PRESETS[0].smoothing,
        tobii.BUILTIN_PRESETS[0].pos_smoothing,
        tobii.BUILTIN_PRESETS[0].deadzone,
        tobii.BUILTIN_PRESETS[0].head_gain,
        tobii.BUILTIN_PRESETS[0].pitch_gain,
        tobii.BUILTIN_PRESETS[0].eye_ratio,
        tobii.BUILTIN_PRESETS[0].pos_gain,
        tobii.BUILTIN_PRESETS[0].neck,
        tobii.BUILTIN_PRESETS[0].gaze_scale,
        tobii.BUILTIN_PRESETS[0].gaze_scale_pitch,
        tobii.BUILTIN_PRESETS[0].gaze_y_offset,
        tobii.BUILTIN_PRESETS[0].gaze_y_scale,
        tobii.BUILTIN_PRESETS[0].curve_exp,
    });
}

fn needArg(args: *std.process.ArgIterator, _: []const u8) []const u8 {
    return args.next() orelse {
        usage();
        std.process.exit(2);
    };
}

fn parseArgs() void {
    var args = std.process.args();
    _ = args.next(); // argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            g_opts.host = needArg(&args, arg);
        } else if (std.mem.eql(u8, arg, "--port")) {
            g_opts.port = std.fmt.parseInt(u16, needArg(&args, arg), 10) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--preset")) {
            const name = needArg(&args, arg);
            if (tobii.findPreset(g_preset_list.items, name)) |idx| {
                loadPreset(idx);
            } else {
                log.err("preset '{s}' not found", .{name});
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, arg, "--list-presets")) {
            for (g_preset_list.items) |p| {
                std.debug.print("{s}\n", .{p.name});
            }
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--save-preset")) {
            g_save_preset_name = needArg(&args, arg);
        } else if (std.mem.eql(u8, arg, "--yaw-gain")) {
            g_opts.p.max_yaw = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--pitch-gain")) {
            g_opts.p.max_pitch = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--smoothing")) {
            g_opts.p.smoothing = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--pos-smoothing")) {
            g_opts.p.pos_smoothing = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--deadzone")) {
            g_opts.p.deadzone = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--head-gain")) {
            g_opts.p.head_gain = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--pitch-boost")) {
            g_opts.p.pitch_gain = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--eye-ratio")) {
            g_opts.p.eye_ratio = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--pos-gain")) {
            g_opts.p.pos_gain = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--neck")) {
            g_opts.p.neck = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--gaze-scale")) {
            g_opts.p.gaze_scale = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--gaze-scale-pitch")) {
            g_opts.p.gaze_scale_pitch = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--gaze-y-offset")) {
            g_opts.p.gaze_y_offset = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--gaze-y-scale")) {
            g_opts.p.gaze_y_scale = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--curve")) {
            const name = needArg(&args, arg);
            g_opts.p.curve_mode = if (std.mem.eql(u8, name, "linear")) 0 else if (std.mem.eql(u8, name, "power")) 1 else if (std.mem.eql(u8, name, "tobii")) 2 else {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--curve-exp")) {
            g_opts.p.curve_exp = std.fmt.parseFloat(f64, needArg(&args, arg)) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--flip-yaw")) {
            g_opts.p.flip_yaw = true;
        } else if (std.mem.eql(u8, arg, "--flip-pitch")) {
            g_opts.p.flip_pitch = true;
        } else if (std.mem.eql(u8, arg, "--track-box-factor")) {
            const factor_arg = needArg(&args, arg);
            if (std.fmt.parseFloat(f64, factor_arg)) |f| {
                g_track_box_factor = f;
            } else |_| {
                usage();
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, arg, "--no-position")) {
            g_opts.p.send_position = false;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            g_opts.headless = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            g_opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage();
            std.process.exit(0);
        } else {
            usage();
            std.process.exit(2);
        }
    }
}

fn handleSignal(_: c_int) callconv(.c) void {
    g_quit.store(true, .release);
}

/// Dedicated stream thread: snapshot the preset under the lock, then poll
/// the daemon socket (non-blocking) which drives onGaze → pipeline → UDP.
/// The GUI never touches the socket, so UI stalls can't stall the game feed.
fn streamThread() void {
    while (!g_quit.load(.acquire)) {
        g_lock.lock();
        g_stream_preset = g_opts.p;
        g_lock.unlock();
        g_socket.poll();
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

fn installSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

pub fn main() void {
    g_presets_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const loaded = tobii.loadAllPresets(g_presets_arena.allocator()) catch |e| {
        log.err("cannot load presets: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
    g_preset_list = std.array_list.Managed(tobii.Preset).init(g_presets_arena.allocator());
    g_preset_list.appendSlice(loaded) catch |e| {
        log.err("cannot init presets: {s}", .{@errorName(e)});
        std.process.exit(1);
    };
    g_cur_preset_idx = 0;

    parseArgs();

    if (g_save_preset_name) |name| {
        if (tobii.findPreset(g_preset_list.items, name) == null) {
            const alloc = g_presets_arena.allocator();
            const nm = alloc.dupe(u8, name) catch {
                std.process.exit(1);
            };
            var copy = g_opts.p;
            copy.name = nm;
            g_preset_list.append(copy) catch {
                std.process.exit(1);
            };
        } else {
            g_preset_list.items[tobii.findPreset(g_preset_list.items, name).?] = g_opts.p;
        }
        savePresetsToDisk();
        log.info("saved preset '{s}'", .{name});
        return;
    }

    g_dst = std.net.Address.parseIp(g_opts.host, g_opts.port) catch |err| {
        log.err("cannot resolve {s}:{d}: {s}", .{ g_opts.host, g_opts.port, @errorName(err) });
        std.process.exit(1);
    };
    g_udp_fd = std.posix.socket(g_dst.any.family, std.posix.SOCK.DGRAM, 0) catch |err| {
        log.err("cannot create udp socket: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    g_socket = SocketSource.init() catch |err| {
        log.err("cannot connect to tobiifreedot: {s}", .{@errorName(err)});
        log.err("start tobiifreedot first (it owns the USB device)", .{});
        std.process.exit(1);
    };
    defer g_socket.deinit();

g_socket.onGaze(onGaze);
    g_socket.onResponse(onDaemonResponse); // calibration blob replies + get_display_area
    g_cal_socket = &g_socket; // expose socket for calibration wizard

    // Request physical screen dimensions from daemon (extended get_display_area response).
    g_socket.sendCommand(proto.Cmd.get_display_area, &[_]u8{});

    installSignalHandlers();

    log.info("streaming gaze → udp {s}:{d}  (preset {s})", .{ g_opts.host, g_opts.port, g_opts.p.name });
    log.info("head {d:.1}× eye {d:.2}  pitch {d:.2}×  curve {s}  cap {d:.0}/{d:.0}°  smoothing {d:.2}  deadzone {d:.1}°", .{
        g_opts.p.head_gain, g_opts.p.eye_ratio, g_opts.p.pitch_gain,
        tobii.curveModeName(@enumFromInt(g_opts.p.curve_mode)),
        g_opts.p.max_yaw, g_opts.p.max_pitch,
        g_opts.p.smoothing, g_opts.p.deadzone,
    });

    g_stream_preset = g_opts.p;
    const stream_thread = std.Thread.spawn(.{}, streamThread, .{}) catch |e| {
        log.err("cannot start stream thread: {s}", .{@errorName(e)});
        std.process.exit(1);
    };

    if (g_opts.headless) {
        while (!g_quit.load(.acquire)) {
            std.Thread.sleep(std.time.ns_per_ms);
        }
    } else {
        const app = c.gtk_application_new("dev.tobiifree.opentrack", c.G_APPLICATION_NON_UNIQUE);
        g_app = @ptrCast(app);
        _ = c.g_signal_connect_data(@ptrCast(app), "activate", @ptrCast(&activate), null, null, 0);
        _ = c.g_application_run(@ptrCast(app), 0, null);
        c.g_object_unref(@ptrCast(app));
    }
    g_quit.store(true, .release);
    stream_thread.join();
    log.info("bye", .{});
}