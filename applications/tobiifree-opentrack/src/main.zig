// tobiifree-opentrack — Tobii ET5 → X4: Foundations bridge.
//
// Connects to the tobiifreed daemon over its unix socket, subscribes to the
// gaze stream, converts each GazeSample into a head pose (gaze → yaw/pitch,
// eye-origin midpoint → head position), and streams it to X4 via the OpenTrack
// UDP protocol: 48 bytes = 6 little-endian doubles (X, Y, Z, Yaw, Pitch, Roll),
// translation in cm, rotation in degrees, to 127.0.0.1:4242.
//
// X4: Foundations (7.50 public beta, native Linux) has a built-in OpenTrack
// UDP listener. Enable *Options → Controls → OpenTrack Support*, toggle head
// tracking with Ctrl+T, recenter with Scroll Lock (handled by X4 itself).

const std = @import("std");
const core = @import("tobiifree_core");
const proto = @import("daemon_protocol");
const SocketSource = @import("socket_source").SocketSource;

const log = std.log.scoped(.opentrack);

const DEFAULT_MAX_YAW: f64 = 25.0; // ° at screen edge (Tobii Game Hub default ~25°)
const DEFAULT_MAX_PITCH: f64 = 15.0; // ° at screen top/bottom edge
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
    verbose: bool = false,
};

var g_opts: Options = .{};
var g_udp_fd: std.posix.socket_t = undefined;
var g_dst: std.net.Address = undefined;

// Head reference (mm) — captured once on the first valid sample. Recentering
// is X4's job (Scroll Lock); the bridge just mirrors the initial position.
var g_ref_set: bool = false;
var g_ref_xyz: [3]f64 = .{ 0, 0, 0 };

// EMA state (x, y, z, yaw, pitch, roll).
var g_ema: [6]f64 = .{ 0, 0, 0, 0, 0, 0 };
var g_ema_init: bool = false;

var g_quit: bool = false;
var g_frame_count: u64 = 0;

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
    if (sample.validity_L != 0 and sample.validity_R != 0) {
        if (g_opts.verbose and g_frame_count <= 5) log.warn("no eyes detected, holding last pose", .{});
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

    sendPacket(out);

    if (g_opts.verbose or g_frame_count <= 5) {
        log.info("x={d:6.1} y={d:6.1} z={d:6.1}  yaw={d:6.1}° pitch={d:6.1}°  (sample {d})", .{
            out[0], out[1], out[2], out[3], out[4], g_frame_count,
        });
    }
}

fn usage() void {
    std.debug.print(
        \\tobiifree-opentrack — Tobii ET5 → X4: Foundations (OpenTrack UDP)
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
        \\  -v, --verbose        verbose per-sample logging
        \\  -h, --help           show this help
        \\
        \\Run order: tobiifreed → tobiifree-opentrack → X4 (OpenTrack Support on).
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

    var socket = SocketSource.init() catch |err| {
        log.err("cannot connect to tobiifreed: {s}", .{@errorName(err)});
        log.err("start tobiifreed first (it owns the USB device)", .{});
        std.process.exit(1);
    };
    defer socket.deinit();

    socket.onGaze(onGaze);
    installSignalHandlers();

    log.info("streaming gaze → udp {s}:{d}", .{ g_opts.host, g_opts.port });
    log.info("gains yaw={d:.1}° pitch={d:.1}°  smoothing={d:.2}  deadzone={d:.1}°", .{
        g_opts.max_yaw, g_opts.max_pitch, g_opts.smoothing, g_opts.deadzone,
    });

    while (!g_quit) {
        socket.poll();
        std.Thread.sleep(std.time.ns_per_ms);
    }
    log.info("bye", .{});
}
