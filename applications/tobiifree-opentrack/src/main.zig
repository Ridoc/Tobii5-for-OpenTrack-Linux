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

const log = std.log.scoped(.opentrack);

const c = @cImport({
    @cInclude("gtk/gtk.h");
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

// Tobii-feel pipeline + preset storage (arena-backed, lives for app lifetime).
var g_pipeline: tobii.TobiiPipeline = .{};
var g_presets_arena: std.heap.ArenaAllocator = undefined;
var g_preset_list: std.array_list.Managed(tobii.Preset) = undefined;
var g_cur_preset_idx: usize = 0;
var g_save_preset_name: ?[]const u8 = null;
var g_last_ts: i64 = 0;

var g_quit: bool = false;
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
var g_check_flip_yaw: ?*c.GtkCheckButton = null;
var g_check_flip_pitch: ?*c.GtkCheckButton = null;
var g_btn_save: ?*c.GtkButton = null;
var g_btn_save_as: ?*c.GtkButton = null;
var g_btn_delete: ?*c.GtkButton = null;
var g_saveas_entry: ?*c.GtkEntry = null;

var g_srcbuf: [192]u8 = undefined;
var g_tick: u32 = 0;

const SensAxis = enum {
    yaw,
    pitch,
    deadzone,
    smoothing,
    pos_smoothing,
    head_gain,
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
        .smoothing, .pos_smoothing, .eye_ratio, .curve_exp => std.fmt.bufPrint(buf, "{d:.2}", .{v}),
    } catch return null;
    return s;
}

fn sensClamp(axis: SensAxis, v: f64) f64 {
    const d = axisDef(axis);
    return std.math.clamp(v, d.min, d.max);
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

fn onGaze(sample: *const core.GazeSample) void {
    g_frame_count += 1;

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

    // Frame-independent dt from the device clock.
    var dt: f64 = 0.0111;
    if (g_last_ts != 0) {
        const d = @as(f64, @floatFromInt(sample.timestamp_us - g_last_ts)) / 1e6;
        if (d > 0 and d < 0.5) dt = d;
    }
    g_last_ts = sample.timestamp_us;

    const out = g_pipeline.process(sample, &g_opts.p, dt);
    g_last_out = out;
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
    setText(g_label_source, &g_srcbuf, "Preset: {s}  ·  {s}:{d}  ·  head {d:.1}×  eye {d:.2}", .{
        g_opts.p.name, g_opts.host, g_opts.port, g_opts.p.head_gain, g_opts.p.eye_ratio,
    });
}

fn onScaleChanged(range: [*c]c.GtkRange, data: ?*anyopaque) callconv(.c) void {
    const axis: SensAxis = @enumFromInt(@intFromPtr(data orelse return));
    const v = c.gtk_range_get_value(range);
    sensField(axis).* = v;
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
    sensField(axis).* = sensClamp(axis, v);
    if (sensScale(axis).*) |sc| c.gtk_range_set_value(@ptrCast(@alignCast(sc)), sensField(axis).*);
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

    const scale = c.gtk_scale_new_with_range(c.GTK_ORIENTATION_HORIZONTAL, def.min, def.max, def.step);
    c.gtk_scale_set_digits(@ptrCast(scale), def.digits);
    c.gtk_range_set_value(@ptrCast(scale), sensField(axis).*);
    c.gtk_widget_set_hexpand(scale, 1);
    c.gtk_grid_attach(@ptrCast(grid), scale, 1, row, 1, 1);
    sensScale(axis).* = @ptrCast(scale);

    const entry = c.gtk_entry_new();
    var buf: [16]u8 = undefined;
    if (sensFormat(axis, sensField(axis).*, &buf)) |s| {
        buf[s.len] = 0;
        c.gtk_editable_set_text(@ptrCast(entry), buf[0 .. s.len :0]);
    }
    c.gtk_widget_set_size_request(@ptrCast(entry), 64, -1);
    c.gtk_grid_attach(@ptrCast(grid), entry, 2, row, 1, 1);
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

    var status: []const u8 = undefined;
    if (!g_got_sample) {
        status = "Waiting for gaze…";
    } else if (g_eyes_valid) {
        status = "Eyes: tracked";
    } else {
        status = "Eyes: lost — holding last pose";
    }
    setText(g_label_status, &buf, "{s}", .{status});

    setText(g_label_x, &buf, "{d:7.2}", .{g_last_out[0]});
    setText(g_label_y, &buf, "{d:7.2}", .{g_last_out[1]});
    setText(g_label_z, &buf, "{d:7.2}", .{g_last_out[2]});
    setText(g_label_yaw, &buf, "{d:7.2}°", .{g_last_out[3]});
    setText(g_label_pitch, &buf, "{d:7.2}°", .{g_last_out[4]});
    setText(g_label_roll, &buf, "{d:7.2}°", .{g_last_out[5]});
}

fn onTick(_: ?*anyopaque) callconv(.c) c_int {
    if (g_quit) {
        if (g_app) |app| c.g_application_quit(@ptrCast(app));
        return 0;
    }
    g_socket.poll(); // 125 Hz stream poll — steady sample delivery to the game
    g_tick +%= 1;
    if (g_tick % 4 == 0) updateLabels(); // ~30 Hz label refresh
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
        .pos_smoothing, .head_gain, .eye_ratio,     .pos_gain,
        .neck,    .gaze_scale, .gaze_scale_pitch, .curve_exp,
    };
    for (axes) |axis| {
        if (sensScale(axis).*) |sc| c.gtk_range_set_value(@ptrCast(@alignCast(sc)), sensField(axis).*);
    }
    if (g_dropdown_curve) |dd| c.gtk_drop_down_set_selected(@ptrCast(dd), g_opts.p.curve_mode);
    if (g_check_flip_yaw) |cb| c.gtk_check_button_set_active(@ptrCast(cb), @intFromBool(g_opts.p.flip_yaw));
    if (g_check_flip_pitch) |cb| c.gtk_check_button_set_active(@ptrCast(cb), @intFromBool(g_opts.p.flip_pitch));
    updateSourceLabel();
}

fn loadPreset(idx: usize) void {
    if (idx >= g_preset_list.items.len) return;
    g_opts.p = g_preset_list.items[idx];
    g_cur_preset_idx = idx;
    syncSliders();
    const is_builtin = idx < tobii.BUILTIN_PRESETS.len;
    if (g_btn_save) |b| c.gtk_widget_set_sensitive(wptr(b), @intFromBool(!is_builtin));
    if (g_btn_delete) |b| c.gtk_widget_set_sensitive(wptr(b), @intFromBool(!is_builtin));
}

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
        c.gtk_drop_down_set_model(@ptrCast(dd), @ptrCast(sl));
        c.gtk_drop_down_set_selected(@ptrCast(dd), @intCast(g_cur_preset_idx));
    }
    if (g_strings_preset) |old| c.g_object_unref(@ptrCast(old));
    g_strings_preset = sl;
}

fn onPresetChanged(obj: ?*c.GObject, _: ?*c.GParamSpec, _: ?*anyopaque) callconv(.c) void {
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
    g_opts.p.curve_mode = @intCast(idx);
    updateSourceLabel();
}

fn onFlipToggled(btn: [*c]c.GtkToggleButton, data: ?*anyopaque) callconv(.c) void {
    const active = c.gtk_toggle_button_get_active(btn) != 0;
    const is_pitch = data != null;
    const cur = if (is_pitch) g_opts.p.flip_pitch else g_opts.p.flip_yaw;
    if (active == cur) return;
    if (is_pitch) g_opts.p.flip_pitch = active else g_opts.p.flip_yaw = active;
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
    var copy = g_opts.p;
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
    c.gtk_window_set_title(@ptrCast(window), "Tobii → OpenTrack");
    c.gtk_window_set_default_size(@ptrCast(window), 440, 940);

    // CSS: monospace values.
    const css = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(
        css,
        ".value { font-family: monospace; font-size: 17px; }" ++
            ".status { font-weight: bold; }" ++
            ".hint { font-size: 11px; opacity: 0.75; }",
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

    // Value grid.
    const grid = c.gtk_grid_new();
    c.gtk_grid_set_column_spacing(@ptrCast(grid), 16);
    c.gtk_grid_set_row_spacing(@ptrCast(grid), 2);
    c.gtk_box_append(@ptrCast(box), @ptrCast(grid));

    addValueRow(grid, 0, "X (cm)", &g_label_x);
    addValueRow(grid, 1, "Y (cm)", &g_label_y);
    addValueRow(grid, 2, "Z (cm)", &g_label_z);
    addValueRow(grid, 3, "Yaw", &g_label_yaw);
    addValueRow(grid, 4, "Pitch", &g_label_pitch);
    addValueRow(grid, 5, "Roll", &g_label_roll);

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
    addSensRow(feel_grid, 1, "Eye ratio", .eye_ratio);
    addSensRow(feel_grid, 2, "Pos gain", .pos_gain);
    addSensRow(feel_grid, 3, "Neck (cm)", .neck);
    addSensRow(feel_grid, 4, "Gaze yaw scale", .gaze_scale);
    addSensRow(feel_grid, 5, "Gaze pitch scale", .gaze_scale_pitch);
    addSensRow(feel_grid, 6, "Curve exp", .curve_exp);

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

    const flip_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    const flip_yaw = c.gtk_check_button_new_with_label("Flip yaw");
    c.gtk_box_append(@ptrCast(flip_row), @ptrCast(flip_yaw));
    g_check_flip_yaw = @ptrCast(flip_yaw);
    _ = c.g_signal_connect_data(@ptrCast(flip_yaw), "toggled", @ptrCast(&onFlipToggled), null, null, 0);
    const flip_pitch = c.gtk_check_button_new_with_label("Flip pitch");
    c.gtk_box_append(@ptrCast(flip_row), @ptrCast(flip_pitch));
    g_check_flip_pitch = @ptrCast(flip_pitch);
    _ = c.g_signal_connect_data(@ptrCast(flip_pitch), "toggled", @ptrCast(&onFlipToggled), @ptrFromInt(1), null, 0);
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
        \\  --eye-ratio <0..1>   gaze contribution to rotation (default {d:.2})
        \\  --pos-gain <0..5>    translation multiplier (default {d:.1})
        \\  --neck <cm>          neck-pivot distance (default {d:.0})
        \\  --gaze-scale <deg>   gaze → yaw at screen edge (default {d:.0})
        \\  --gaze-scale-pitch <deg> gaze → pitch at screen edge (default {d:.0})
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
        tobii.BUILTIN_PRESETS[0].eye_ratio,
        tobii.BUILTIN_PRESETS[0].pos_gain,
        tobii.BUILTIN_PRESETS[0].neck,
        tobii.BUILTIN_PRESETS[0].gaze_scale,
        tobii.BUILTIN_PRESETS[0].gaze_scale_pitch,
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
    g_quit = true;
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
    installSignalHandlers();

    log.info("streaming gaze → udp {s}:{d}  (preset {s})", .{ g_opts.host, g_opts.port, g_opts.p.name });
    log.info("head {d:.1}× eye {d:.2}  curve {s}  cap {d:.0}/{d:.0}°  smoothing {d:.2}  deadzone {d:.1}°", .{
        g_opts.p.head_gain, g_opts.p.eye_ratio,
        tobii.curveModeName(@enumFromInt(g_opts.p.curve_mode)),
        g_opts.p.max_yaw, g_opts.p.max_pitch,
        g_opts.p.smoothing, g_opts.p.deadzone,
    });

    if (g_opts.headless) {
        while (!g_quit) {
            g_socket.poll();
            std.Thread.sleep(std.time.ns_per_ms);
        }
    } else {
        const app = c.gtk_application_new("dev.tobiifree.opentrack", c.G_APPLICATION_NON_UNIQUE);
        g_app = @ptrCast(app);
        _ = c.g_signal_connect_data(@ptrCast(app), "activate", @ptrCast(&activate), null, null, 0);
        _ = c.g_application_run(@ptrCast(app), 0, null);
        c.g_object_unref(@ptrCast(app));
    }
    log.info("bye", .{});
}