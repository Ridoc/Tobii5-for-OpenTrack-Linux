// tobiifree-opentrack — Tobii ET5 → OpenTrack bridge for Linux games.
//
// Connects to the tobiifreed daemon over its unix socket, subscribes to the
// gaze stream, converts each GazeSample into a head pose (gaze → yaw/pitch,
// eye-origin midpoint → head position), and streams it over the OpenTrack
// UDP protocol: 48 bytes = 6 little-endian doubles (X, Y, Z, Yaw, Pitch, Roll),
// translation in cm, rotation in degrees, to 127.0.0.1:4242.
//
// Ships with a small GTK4 status window showing the live pose values; pass
// --headless to run console-only (e.g. under X4's built-in OpenTrack Support).
//
// Driver/protocol modules imported from Aetherall/tobiifree (GPL-3.0) by
// Aetherall — see LICENSE and README for credits.

const std = @import("std");
const core = @import("tobiifree_core");
const proto = @import("daemon_protocol");
const SocketSource = @import("socket_source").SocketSource;

const log = std.log.scoped(.opentrack);

const c = @cImport({
    @cInclude("gtk/gtk.h");
});

const DEFAULT_MAX_YAW: f64 = 37.5; // ° at screen edge (tuned +50% over Tobii's ~25° default)
const DEFAULT_MAX_PITCH: f64 = 22.5; // ° at screen top/bottom edge
const DEFAULT_SMOOTHING: f64 = 0.3; // EMA alpha — higher = more responsive
const DEFAULT_DEADZONE: f64 = 0.2; // ° yaw/pitch deadzone

const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 4242,
    max_yaw: f64 = DEFAULT_MAX_YAW,
    max_pitch: f64 = DEFAULT_MAX_PITCH,
    smoothing: f64 = DEFAULT_SMOOTHING,
    deadzone: f64 = DEFAULT_DEADZONE,
    send_position: bool = true,
    headless: bool = false,
    verbose: bool = false,
};

var g_opts: Options = .{};
var g_udp_fd: std.posix.socket_t = undefined;
var g_dst: std.net.Address = undefined;

// Head reference (mm) — captured once on the first valid sample. Recentering
// is the game's job (e.g. X4's Scroll Lock); the bridge mirrors the initial position.
var g_ref_set: bool = false;
var g_ref_xyz: [3]f64 = .{ 0, 0, 0 };

// EMA state (x, y, z, yaw, pitch, roll).
var g_ema: [6]f64 = .{ 0, 0, 0, 0, 0, 0 };
var g_ema_init: bool = false;

var g_quit: bool = false;
var g_frame_count: u64 = 0;
var g_eyes_valid: bool = false;
var g_got_sample: bool = false;

// Gaze source + last output pose (read by the GUI tick).
var g_socket: SocketSource = undefined;
var g_last_out: [6]f64 = .{ 0, 0, 0, 0, 0, 0 };

// ─── GTK widgets ─────────────────────────────────────────────────────

var g_app: ?*c.GtkApplication = null;
var g_label_status: ?*c.GtkLabel = null;
var g_label_source: ?*c.GtkLabel = null;
var g_label_x: ?*c.GtkLabel = null;
var g_label_y: ?*c.GtkLabel = null;
var g_label_z: ?*c.GtkLabel = null;
var g_label_yaw: ?*c.GtkLabel = null;
var g_label_pitch: ?*c.GtkLabel = null;
var g_label_roll: ?*c.GtkLabel = null;

// Sensitivity controls (Yaw/Pitch gains).
var g_srcbuf: [128]u8 = undefined;
var g_scale_yaw: ?*c.GtkScale = null;
var g_entry_yaw: ?*c.GtkEntry = null;
var g_scale_pitch: ?*c.GtkScale = null;
var g_entry_pitch: ?*c.GtkEntry = null;

const SensAxis = enum { yaw, pitch };

/// C-pointer view of an opaque widget pointer (alignment-safe, like the overlay).
fn wptr(x: anytype) [*c]c.GtkWidget {
    return @ptrCast(@alignCast(x));
}

fn applyDeadzone(v: f64, dz: f64) f64 {
    if (@abs(v) < dz) return 0;
    return v;
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

    // Gaze → rotation (degrees). Up = positive pitch.
    const gx = sample.gaze_point_2d_norm[0];
    const gy = sample.gaze_point_2d_norm[1];
    var yaw = (gx - 0.5) * 2.0 * g_opts.max_yaw;
    var pitch = (0.5 - gy) * 2.0 * g_opts.max_pitch;
    yaw = applyDeadzone(yaw, g_opts.deadzone);
    pitch = applyDeadzone(pitch, g_opts.deadzone);
    const roll: f64 = 0.0;

    // Eye-origin midpoint → head translation (mm → cm).
    var px: f64 = 0;
    var py: f64 = 0;
    var pz: f64 = 0;
    const has_origins = (sample.present_mask &
        (core.GAZE_BIT_EYE_ORIGIN_L | core.GAZE_BIT_EYE_ORIGIN_R)) != 0;
    if (g_opts.send_position and has_origins) {
        const mid_x = (sample.eye_origin_L_mm[0] + sample.eye_origin_R_mm[0]) * 0.5;
        const mid_y = (sample.eye_origin_L_mm[1] + sample.eye_origin_R_mm[1]) * 0.5;
        const mid_z = (sample.eye_origin_L_mm[2] + sample.eye_origin_R_mm[2]) * 0.5;
        if (!g_ref_set) {
            g_ref_xyz = .{ mid_x, mid_y, mid_z };
            g_ref_set = true;
            log.info("head reference captured: ({d:.0}, {d:.0}, {d:.0}) mm", .{ mid_x, mid_y, mid_z });
        }
        px = (mid_x - g_ref_xyz[0]) * 0.1;
        py = (mid_y - g_ref_xyz[1]) * 0.1;
        pz = (mid_z - g_ref_xyz[2]) * 0.1;
    }

    // EMA smoothing across all channels (replaces OpenTrack's absent filters).
    const raw = [6]f64{ px, py, pz, yaw, pitch, roll };
    var out = raw;
    if (g_ema_init) {
        const a = g_opts.smoothing;
        for (&out, 0..) |*o, i| {
            o.* = a * raw[i] + (1.0 - a) * g_ema[i];
        }
    }
    g_ema = out;
    g_ema_init = true;
    g_last_out = out;

    sendPacket(out);

    // Console logging only when asked (GUI shows the live values instead).
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
    setText(g_label_source, &g_srcbuf, "Streaming to {s}:{d}  ·  yaw ±{d:.1}° pitch ±{d:.1}°", .{
        g_opts.host, g_opts.port, g_opts.max_yaw, g_opts.max_pitch,
    });
}

fn onScaleChanged(range: [*c]c.GtkRange, data: ?*anyopaque) callconv(.c) void {
    const axis: SensAxis = @enumFromInt(@intFromPtr(data orelse return));
    const v = c.gtk_range_get_value(range);
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.1}", .{v}) catch return;
    buf[s.len] = 0;
    switch (axis) {
        .yaw => {
            g_opts.max_yaw = v;
            if (g_entry_yaw) |e| c.gtk_editable_set_text(@ptrCast(e), buf[0 .. s.len :0]);
        },
        .pitch => {
            g_opts.max_pitch = v;
            if (g_entry_pitch) |e| c.gtk_editable_set_text(@ptrCast(e), buf[0 .. s.len :0]);
        },
    }
    updateSourceLabel();
}

fn onEntryActivated(entry: [*c]c.GtkEntry, data: ?*anyopaque) callconv(.c) void {
    const axis: SensAxis = @enumFromInt(@intFromPtr(data orelse return));
    const text = std.mem.span(c.gtk_editable_get_text(@ptrCast(entry)));
    if (text.len == 0) return;
    const v = std.fmt.parseFloat(f64, text) catch return;
    const clamped = std.math.clamp(v, 0.0, 90.0);
    switch (axis) {
        .yaw => {
            g_opts.max_yaw = clamped;
            if (g_scale_yaw) |sc| c.gtk_range_set_value(@ptrCast(@alignCast(sc)), clamped);
        },
        .pitch => {
            g_opts.max_pitch = clamped;
            if (g_scale_pitch) |sc| c.gtk_range_set_value(@ptrCast(@alignCast(sc)), clamped);
        },
    }
    updateSourceLabel();
}

fn addSensRow(
    grid: [*c]c.GtkWidget,
    row: c_int,
    name: [*:0]const u8,
    scale_out: *?*c.GtkScale,
    entry_out: *?*c.GtkEntry,
    initial: f64,
    axis: SensAxis,
) void {
    const name_label = c.gtk_label_new(name);
    c.gtk_widget_set_halign(name_label, c.GTK_ALIGN_START);
    c.gtk_grid_attach(@ptrCast(grid), name_label, 0, row, 1, 1);

    const scale = c.gtk_scale_new_with_range(c.GTK_ORIENTATION_HORIZONTAL, 0, 90, 0.5);
    c.gtk_scale_set_digits(@ptrCast(scale), 1);
    c.gtk_range_set_value(@ptrCast(scale), initial);
    c.gtk_widget_set_hexpand(scale, 1);
    c.gtk_grid_attach(@ptrCast(grid), scale, 1, row, 1, 1);
    scale_out.* = @ptrCast(scale);

    const entry = c.gtk_entry_new();
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.1}", .{initial}) catch return;
    buf[s.len] = 0;
    c.gtk_editable_set_text(@ptrCast(entry), buf[0 .. s.len :0]);
    c.gtk_widget_set_size_request(@ptrCast(entry), 64, -1);
    c.gtk_grid_attach(@ptrCast(grid), entry, 2, row, 1, 1);
    entry_out.* = @ptrCast(entry);

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
    g_socket.poll();
    updateLabels();
    return 1; // keep source
}

fn activate(_: *c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    const app = @as(*c.GtkApplication, @ptrCast(@alignCast(c.g_application_get_default())));
    g_app = @ptrCast(app);

    const window = c.gtk_application_window_new(@ptrCast(app));
    c.gtk_window_set_title(@ptrCast(window), "Tobii → OpenTrack");
    c.gtk_window_set_default_size(@ptrCast(window), 380, 520);

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

    const hint = c.gtk_label_new(
        "Engage head-look in game (X4: Ctrl+T). Recenter is the game's key (X4: Scroll Lock).",
    );

    // Sensitivity controls.
    const sens_title = c.gtk_label_new("Sensitivity");
    c.gtk_widget_set_halign(sens_title, c.GTK_ALIGN_START);
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(sens_title), "status");
    c.gtk_box_append(@ptrCast(box), @ptrCast(sens_title));

    const sens_grid = c.gtk_grid_new();
    c.gtk_grid_set_column_spacing(@ptrCast(sens_grid), 10);
    c.gtk_grid_set_row_spacing(@ptrCast(sens_grid), 4);
    c.gtk_box_append(@ptrCast(box), @ptrCast(sens_grid));

    addSensRow(sens_grid, 0, "Yaw", &g_scale_yaw, &g_entry_yaw, g_opts.max_yaw, .yaw);
    addSensRow(sens_grid, 1, "Pitch", &g_scale_pitch, &g_entry_pitch, g_opts.max_pitch, .pitch);

    c.gtk_widget_set_halign(hint, c.GTK_ALIGN_START);
    c.gtk_label_set_wrap(@ptrCast(hint), 1);
    c.gtk_label_set_xalign(@ptrCast(hint), 0);
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(hint), "hint");
    c.gtk_box_append(@ptrCast(box), @ptrCast(hint));

    c.gtk_window_set_child(@ptrCast(window), @ptrCast(box));
    c.gtk_window_present(@ptrCast(window));

    _ = c.g_timeout_add(33, @ptrCast(&onTick), null); // ~30 Hz UI refresh
}

// ─── CLI / lifecycle ─────────────────────────────────────────────────

fn usage() void {
    std.debug.print(
        \\tobiifree-opentrack — Tobii ET5 → OpenTrack bridge for Linux games
        \\
        \\Usage: tobiifree-opentrack [options]
        \\
        \\Options:
        \\  --host <ip>          UDP target host (default 127.0.0.1)
        \\  --port <n>           UDP target port (default 4242)
        \\  --yaw-gain <deg>     max yaw at screen edge (default {d:.1})
        \\  --pitch-gain <deg>   max pitch at screen edge (default {d:.1})
        \\  --smoothing <0..1>   EMA alpha, higher = more responsive (default {d:.1})
        \\  --deadzone <deg>     yaw/pitch deadzone (default {d:.1})
        \\  --no-position        send zeros for head position
        \\  --headless           no GUI window, console logging only
        \\  -v, --verbose        verbose per-sample logging
        \\  -h, --help           show this help
        \\
        \\Run order: tobiifreed → tobiifree-opentrack → game (OpenTrack on).
        \\
    , .{ DEFAULT_MAX_YAW, DEFAULT_MAX_PITCH, DEFAULT_SMOOTHING, DEFAULT_DEADZONE });
}

fn parseArgs() void {
    var args = std.process.args();
    _ = args.next(); // argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            g_opts.host = args.next() orelse {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            g_opts.port = std.fmt.parseInt(u16, args.next() orelse {
                usage();
                std.process.exit(2);
            }, 10) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--yaw-gain")) {
            g_opts.max_yaw = std.fmt.parseFloat(f64, args.next() orelse {
                usage();
                std.process.exit(2);
            }) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--pitch-gain")) {
            g_opts.max_pitch = std.fmt.parseFloat(f64, args.next() orelse {
                usage();
                std.process.exit(2);
            }) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--smoothing")) {
            g_opts.smoothing = std.fmt.parseFloat(f64, args.next() orelse {
                usage();
                std.process.exit(2);
            }) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--deadzone")) {
            g_opts.deadzone = std.fmt.parseFloat(f64, args.next() orelse {
                usage();
                std.process.exit(2);
            }) catch {
                usage();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--no-position")) {
            g_opts.send_position = false;
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
    parseArgs();

    g_dst = std.net.Address.parseIp(g_opts.host, g_opts.port) catch |err| {
        log.err("cannot resolve {s}:{d}: {s}", .{ g_opts.host, g_opts.port, @errorName(err) });
        std.process.exit(1);
    };
    g_udp_fd = std.posix.socket(g_dst.any.family, std.posix.SOCK.DGRAM, 0) catch |err| {
        log.err("cannot create udp socket: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    g_socket = SocketSource.init() catch |err| {
        log.err("cannot connect to tobiifreed: {s}", .{@errorName(err)});
        log.err("start tobiifreed first (it owns the USB device)", .{});
        std.process.exit(1);
    };
    defer g_socket.deinit();

    g_socket.onGaze(onGaze);
    installSignalHandlers();

    log.info("streaming gaze → udp {s}:{d}", .{ g_opts.host, g_opts.port });
    log.info("gains yaw={d:.1}° pitch={d:.1}°  smoothing={d:.2}  deadzone={d:.1}°", .{
        g_opts.max_yaw, g_opts.max_pitch, g_opts.smoothing, g_opts.deadzone,
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
