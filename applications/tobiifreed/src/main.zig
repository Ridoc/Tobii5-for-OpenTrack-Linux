// tobiifreedot (TobiiFreedOT) — eye tracker daemon.
//
/// Owns the USB connection to the Tobii ET5 and exposes gaze data
/// over a unix socket. Multiple clients can connect simultaneously.
///
/// Usage:
///   tobiifreedot                  # run with defaults or ~/.config/tobii.json
///   tobiifreedot --init-config    # create default config file
///   tobiifreedot --track-box-factor=2.5  # override track box expansion factor
///
/// Upstream: Aetherall/tobiifree (https://github.com/Aetherall/tobiifree)
/// by Aetherall — GPL-3.0. This is a renamed fork of the upstream
/// `tobiifreed` daemon; see LICENSE and README for credits.

const std = @import("std");
const core = @import("tobiifree_core");
const Tracker = @import("tracker").Tracker;
const proto = @import("daemon_protocol");
const Server = @import("server").Server;
const WsServer = @import("ws_server").WsServer;
const da_config = @import("display_area_config");
const LibusbTransport = @import("libusb_transport").LibusbTransport;

const log = std.log.scoped(.tobiifreedot);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const CONFIG_PATH = ".config/tobii.json";

// ── State ───────────────────────────────────────────────────────────

var transport: LibusbTransport = undefined;
var tracker: Tracker = undefined;
var server: Server = undefined;
var ws: ?WsServer = null;
var quit: bool = false;

// Full config loaded at startup (for extended get_display_area response).
var full_cfg: da_config.FullConfig = undefined;

// ── Gaze ring buffer: USB thread → main thread ─────────────────────
//
// The USB thread calls onGaze which stores samples in a ring buffer.
// The main thread drains the ring and broadcasts to clients.
// A pipe notifies the main thread that new data is available so it
// can block on poll() instead of busy-spinning.

const GAZE_RING_SIZE = 64;
var gaze_ring: [GAZE_RING_SIZE]core.GazeSample = undefined;
var gaze_write: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var gaze_read: u32 = 0; // only touched by main thread
var gaze_count: u64 = 0;
var notify_pipe: [2]std.posix.fd_t = .{ -1, -1 };

fn onGaze(sample: *const core.GazeSample) void {
    // Called from USB thread. Store sample in ring, notify main thread.
    const w = gaze_write.load(.monotonic);
    gaze_ring[w % GAZE_RING_SIZE] = sample.*;
    gaze_write.store(w +% 1, .release);
    // Wake main thread (non-blocking write, ok if pipe buffer is full).
    _ = std.posix.write(notify_pipe[1], &.{1}) catch {};
}

/// Drain the ring buffer and broadcast (called from main thread).
fn drainGaze() void {
    // Drain notification pipe.
    var drain_buf: [64]u8 = undefined;
    _ = std.posix.read(notify_pipe[0], &drain_buf) catch {};

    const w = gaze_write.load(.acquire);
    while (gaze_read != w) {
        const sample = &gaze_ring[gaze_read % GAZE_RING_SIZE];
        gaze_count += 1;
        if (gaze_count <= 3 or gaze_count % 500 == 0) {
            log.debug("gaze #{d}: vL={d} vR={d} x={d:.3} y={d:.3}", .{
                gaze_count, sample.validity_L, sample.validity_R,
                sample.gaze_point_2d_norm[0], sample.gaze_point_2d_norm[1],
            });
        }
        server.broadcastGaze(sample);
        if (ws) |*w_| w_.broadcastGaze(sample);
        gaze_read +%= 1;
    }
}

// ── Command forwarding: client → USB tracker ────────────────────────
//
// When a client (socket or WS) sends a command that needs to go to the
// tracker, we build the TTP frame via tobiifree_core, send it over USB,
// and register a pending entry so the response hook can route the
// reply back to the right client fd.

const MAX_PENDING = 64;

const PendingEntry = struct {
    request_id: u32,
    client_fd: std.posix.fd_t,
    cmd_type: u8,
    is_ws: bool,
};

var pending: [MAX_PENDING]?PendingEntry = [_]?PendingEntry{null} ** MAX_PENDING;

fn addPending(request_id: u32, client_fd: std.posix.fd_t, cmd_type: u8, is_ws: bool) void {
    for (&pending) |*slot| {
        if (slot.* == null) {
            slot.* = .{
                .request_id = request_id,
                .client_fd = client_fd,
                .cmd_type = cmd_type,
                .is_ws = is_ws,
            };
            return;
        }
    }
    log.warn("pending table full, dropping request_id={}", .{request_id});
}

fn takePending(request_id: u32) ?PendingEntry {
    for (&pending) |*slot| {
        if (slot.*) |entry| {
            if (entry.request_id == request_id) {
                const result = entry;
                slot.* = null;
                return result;
            }
        }
    }
    return null;
}

/// Response hook: called by tobiifree_core when a TTP response arrives.
/// Routes the response payload back to the client that sent the command.
fn onResponse(request_id: u32, payload_ptr: [*]const u8, payload_len: u32) void {
    const entry = takePending(request_id) orelse {
        log.debug("response for unknown request_id={}, ignoring", .{request_id});
        return;
    };

    // For get_display_area, extend the 9-corner response with physical_screen dims.
    var extended_payload: [88]u8 = undefined;
    var payload_to_send: []const u8 = payload_ptr[0..payload_len];
    if (entry.cmd_type == @intFromEnum(proto.Cmd.get_display_area) and payload_len == 72) {
        @memcpy(extended_payload[0..72], payload_ptr[0..72]);
        const phys_w = full_cfg.physical_screen.w_mm;
        const phys_h = full_cfg.physical_screen.h_mm;
        @memcpy(extended_payload[72..80], std.mem.asBytes(&phys_w));
        @memcpy(extended_payload[80..88], std.mem.asBytes(&phys_h));
        payload_to_send = extended_payload[0..88];
    }

    var buf: [proto.HEADER_SIZE + 1 + 8192]u8 = undefined;
    const msg_len = proto.encodeResponse(&buf, entry.cmd_type, payload_to_send);

    if (entry.is_ws) {
        if (ws) |*w| {
            w.sendToClient(entry.client_fd, buf[0..msg_len]);
        }
    } else {
        _ = std.posix.write(entry.client_fd, buf[0..msg_len]) catch {};
    }

    log.debug("routed response for cmd=0x{x:0>2} to fd={}", .{ entry.cmd_type, entry.client_fd });
}

/// Forward a daemon-protocol command to the USB tracker.
/// Called by server.zig and ws_server.zig when they receive a forwardable command.
fn forwardCommand(client_fd: std.posix.fd_t, cmd_type: u8, payload: []const u8, is_ws: bool) void {
    const cmd = std.meta.intToEnum(proto.Cmd, cmd_type) catch {
        log.warn("unknown cmd 0x{x:0>2} from fd={}", .{ cmd_type, client_fd });
        return;
    };

    switch (cmd) {
        .subscribe, .disconnect => return, // handled locally, not forwarded

        // State machine commands — driven synchronously, response sent when done.
        .start_calibration => {
            const ok = tracker.startCalibration();
            sendResult(client_fd, cmd_type, is_ws, ok, &.{});
        },
        .finish_calibration => {
            const ok = tracker.finishCalibration();
            if (ok) {
                const blob_ptr = core.cal_finish_blob_ptr();
                const blob_len = core.cal_finish_blob_len();
                sendResult(client_fd, cmd_type, is_ws, true, blob_ptr[0..blob_len]);
            } else {
                sendResult(client_fd, cmd_type, is_ws, false, &.{});
            }
        },
        .cal_apply => {
            if (payload.len == 0) {
                sendResult(client_fd, cmd_type, is_ws, false, &.{});
                return;
            }
            const ok = tracker.calApply(payload);
            sendResult(client_fd, cmd_type, is_ws, ok, &.{});
        },

        // Single request/response commands — forwarded to USB, response routed back.
        .get_display_area, .set_display_area, .set_display_area_corners,
        .add_calibration_point => {
            const request_id = buildRequest(cmd, payload) orelse {
                log.warn("failed to build request for cmd=0x{x:0>2} (bad payload len={})", .{ cmd_type, payload.len });
                return;
            };
            const out_len = core.session_out_len_();
            if (out_len > 0) {
                if (transport.send(core.session_out_ptr()[0..out_len])) {
                    if (request_id != 0) {
                        addPending(request_id, client_fd, cmd_type, is_ws);
                        log.debug("forwarded cmd=0x{x:0>2} request_id={} for fd={}", .{ cmd_type, request_id, client_fd });
                    } else {
                        log.debug("sent fire-and-forget cmd=0x{x:0>2} for fd={}", .{ cmd_type, client_fd });
                    }
                } else {
                    log.err("USB send failed for cmd=0x{x:0>2}", .{cmd_type});
                }
            }
        },
    }
}

fn buildRequest(cmd: proto.Cmd, payload: []const u8) ?u32 {
    return switch (cmd) {
        .get_display_area => core.request_get_display_area(),
        .set_display_area => blk: {
            if (payload.len < 40) break :blk null;
            var f: [5]f64 = undefined;
            @memcpy(std.mem.asBytes(&f), payload[0..40]);
            break :blk core.request_set_display_area(f[0], f[1], f[2], f[3], f[4]);
        },
        .set_display_area_corners => blk: {
            if (payload.len < 72) break :blk null;
            var f: [9]f64 = undefined;
            @memcpy(std.mem.asBytes(&f), payload[0..72]);
            break :blk core.request_set_display_area_corners(f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8]);
        },
        .add_calibration_point => blk: {
            if (payload.len < 16) break :blk null; // x(f64) + y(f64) = 16
            var f: [2]f64 = undefined;
            @memcpy(std.mem.asBytes(&f), payload[0..16]);
            break :blk core.request_cal_add_point(f[0], f[1], 0);
        },
        .subscribe, .disconnect, .start_calibration, .finish_calibration, .cal_apply => null,
    };
}

fn sendResult(client_fd: std.posix.fd_t, cmd_type: u8, is_ws: bool, ok: bool, payload: []const u8) void {
    if (!ok) {
        var err_buf: [proto.HEADER_SIZE + 4]u8 = undefined;
        proto.encodeError(&err_buf, 0x01);
        if (is_ws) {
            if (ws) |*w| w.sendToClient(client_fd, &err_buf);
        } else {
            _ = std.posix.write(client_fd, &err_buf) catch {};
        }
        return;
    }
    var buf: [proto.HEADER_SIZE + 1 + 8192]u8 = undefined;
    const msg_len = proto.encodeResponse(&buf, cmd_type, payload);
    if (is_ws) {
        if (ws) |*w| w.sendToClient(client_fd, buf[0..msg_len]);
    } else {
        _ = std.posix.write(client_fd, buf[0..msg_len]) catch {};
    }
}

// ── Config loading (via shared display_area_config module) ──────────

fn loadFullConfig() da_config.FullConfig {
    const home = std.posix.getenv("HOME") orelse return da_config.defaultFullConfig();
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, CONFIG_PATH }) catch return da_config.defaultFullConfig();
    return da_config.loadFromFile(path, std.heap.page_allocator) catch da_config.defaultFullConfig();
}

// ── --init-config ──────────────────────────────────────────────────

fn initConfig(factor: f64) void {
    const home = std.posix.getenv("HOME") orelse {
        log.err("$HOME not set", .{});
        return;
    };
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, CONFIG_PATH }) catch return;
    if (std.fs.cwd().access(path, .{})) |_| {
        log.info("{s} already exists", .{path});
        return;
    } else |_| {
        // Detect screen dimensions from EDID.
        const edid = da_config.detectEdid();
        const cfg = if (edid) |e| blk: {
            log.info("EDID detected: {s} {d:.0}×{d:.0}mm", .{ e.connected_name orelse "unknown", e.width_mm, e.height_mm });
            break :blk da_config.defaultFromEdid(e, factor);
        } else blk: {
            log.warn("no EDID detected, using fallback dimensions", .{});
            break :blk da_config.defaultFullConfig();
        };

        var dir_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config", .{home}) catch return;
        std.fs.cwd().makePath(dir_path) catch {};
        const file = std.fs.cwd().createFile(path, .{}) catch |err| {
            log.err("create config: {}", .{err});
            return;
        };
        defer file.close();

        var json_buf: [2048]u8 = undefined;
        const json = da_config.toJsonString(cfg, &json_buf) orelse return;
        file.writeAll(json) catch |err| {
            log.err("write config: {}", .{err});
            return;
        };
        log.info("created {s}: physical {d:.0}×{d:.0}mm, device {d:.0}×{d:.0}mm z={d:.0}mm tilt={d:.1}° factor={d:.1}",
            .{ path, cfg.physical_screen.w_mm, cfg.physical_screen.h_mm,
               cfg.device_display_area.w_mm, cfg.device_display_area.h_mm,
               cfg.device_display_area.z_mm, cfg.device_display_area.tilt_deg,
               cfg.device_display_area.track_box_factor });
    }
}

fn parseWsArg(arg: []const u8, addr: *u32, port: *u16) void {
    if (std.mem.lastIndexOfScalar(u8, arg, ':')) |colon| {
        if (parseIpv4(arg[0..colon])) |a| addr.* = a;
        if (std.fmt.parseInt(u16, arg[colon + 1 ..], 10)) |p| port.* = p else |_| {}
    } else {
        if (std.fmt.parseInt(u16, arg, 10)) |p| port.* = p else |_| {}
    }
}

fn parseIpv4(s: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (count >= 3) return null;
            octets[count] = std.fmt.parseInt(u8, s[start..i], 0) catch return null;
            count += 1;
            start = i + 1;
        }
    }
    if (count != 3) return null;
    octets[3] = std.fmt.parseInt(u8, s[start..], 0) catch return null;
    return @bitCast(octets);
}

// ── Signal handling ─────────────────────────────────────────────────

fn handleSignal(_: c_int) callconv(.c) void {
    quit = true;
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

// ── Main ────────────────────────────────────────────────────────────

pub fn main() void {
    // Parse arguments.
    var ws_addr: u32 = std.mem.nativeToBig(u32, 0x7f000001); // 127.0.0.1
    var ws_port: u16 = 7081;
    var ws_enabled: bool = false;
    var force_display_area: bool = false;
    var track_box_factor: f64 = 2.5;

    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--init-config")) {
            initConfig(2.5);
            return;
        } else if (std.mem.eql(u8, arg, "--force-display-area")) {
            force_display_area = true;
        } else if (std.mem.eql(u8, arg, "--ws")) {
            ws_enabled = true;
            // Peek at next arg for optional address.
            if (args.next()) |ws_arg| {
                if (ws_arg.len > 0 and ws_arg[0] == '-') {
                    continue;
                }
                parseWsArg(ws_arg, &ws_addr, &ws_port);
            }
        } else if (std.mem.eql(u8, arg, "--track-box-factor")) {
            if (args.next()) |factor_arg| {
                if (std.fmt.parseFloat(f64, factor_arg)) |f| {
                    track_box_factor = f;
                } else |_| {}
            }
        }
    }

    // Load config.
    full_cfg = loadFullConfig();
    // Override track_box_factor from CLI if provided
    full_cfg.device_display_area.track_box_factor = track_box_factor;

    // Recompute device display area with the (possibly overridden) factor
    const factor = track_box_factor;
    const dev_w = full_cfg.physical_screen.w_mm * factor;
    const dev_h = full_cfg.physical_screen.h_mm * factor;
    const half_dev_w = dev_w / 2.0;
    const half_dev_h = dev_h / 2.0;
    const cy = -half_dev_h + 10.0;

    full_cfg.device_display_area = .{
        .w_mm = dev_w,
        .h_mm = dev_h,
        .z_mm = 65,
        .tilt_deg = 12,
        .ox_mm = -half_dev_w,
        .oy_mm = -cy - half_dev_h,
        .track_box_factor = factor,
    };

    log.info("display_area {d:.0}x{d:.0}mm  origin=({d:.0},{d:.0})  z={d:.0}  tilt={d:.2}  factor={d:.1}",
        .{ full_cfg.device_display_area.w_mm, full_cfg.device_display_area.h_mm,
           full_cfg.device_display_area.ox_mm, full_cfg.device_display_area.oy_mm,
           full_cfg.device_display_area.z_mm, full_cfg.device_display_area.tilt_deg,
           factor });

    // Open USB transport.
    transport = LibusbTransport.init() catch |err| {
        log.err("failed to open USB: {}", .{err});
        return;
    };
    defer transport.deinit();

    // Connect tracker via transport.
    tracker = Tracker.init(.{
        .send_fn = &transportSend,
        .recv_fn = &transportRecv,
        .try_recv_fn = &transportTryRecv,
    }) catch |err| {
        log.err("failed to connect: {}", .{err});
        return;
    };
    defer tracker.deinit();

    // Apply display area from config (expanded device display area).
    if (force_display_area or tracker.display.isReset()) {
        if (force_display_area) {
            log.info("force-applying display area from config", .{});
        } else {
            log.info("device display area looks reset, applying config", .{});
        }
        const da = da_config.toTrackerDisplayArea(full_cfg.device_display_area, Tracker.DeviceDisplayArea);
        if (!tracker.setDisplayArea(da)) {
            log.warn("failed to set display area from config", .{});
        }
    } else {
        log.info("device display area preserved from previous session", .{});
    }
    tracker.onGaze(onGaze);

    // Install response hook for command forwarding.
    core.set_hooks(null, null, onResponse, null, null);

    // Start socket server.
    server = Server.init(&forwardCommand) catch |err| {
        log.err("failed to start server: {}", .{err});
        return;
    };
    defer server.deinit();

    // Start WebSocket server (if enabled).
    if (ws_enabled) {
        ws = WsServer.init(ws_addr, ws_port, &forwardCommand) catch |err| {
            log.err("failed to start WebSocket server: {}", .{err});
            return;
        };
    }
    defer if (ws) |*w| w.deinit();

    // Set up notification pipe (non-blocking read end).
    notify_pipe = std.posix.pipe2(.{ .NONBLOCK = true }) catch |err| {
        log.err("failed to create pipe: {}", .{err});
        return;
    };
    defer {
        std.posix.close(notify_pipe[0]);
        std.posix.close(notify_pipe[1]);
    }

    installSignalHandlers();

    // Spawn USB thread — blocks on recv(), device-paced.
    const usb_thread = std.Thread.spawn(.{}, usbThreadFn, .{}) catch |err| {
        log.err("failed to spawn USB thread: {}", .{err});
        return;
    };

    log.info("running", .{});

    // Main loop — poll on notification pipe + short timeout for socket I/O.
    while (!quit) {
        // Check for gaze data from USB thread.
        drainGaze();
        // Service client connections.
        server.acceptClients();
        server.readCommands();
        if (ws) |*w| {
            w.acceptClients();
            w.readClients();
        }
        // Sleep briefly to avoid busy-spinning on socket I/O.
        // The pipe notification + this short sleep gives ~1ms latency.
        std.Thread.sleep(1_000_000); // 1ms
    }

    log.info("shutting down", .{});
    usb_thread.join();
}

// ── USB thread ─────────────────────────────────────────────────────

fn usbThreadFn() void {
    log.info("USB thread started", .{});
    while (!quit) {
        tracker.poll();
    }
    log.info("USB thread stopped", .{});
}

// ── Transport bridge ────────────────────────────────────────────────

fn transportSend(data: []const u8) bool {
    return transport.send(data);
}

fn transportRecv(buf: []u8) ?usize {
    return transport.recv(buf);
}

fn transportTryRecv(buf: []u8) ?usize {
    return transport.tryRecv(buf);
}