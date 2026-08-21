// tobiifree-opentrack — bridge that streams ET5 gaze/head pose to X4: Foundations
// over the OpenTrack UDP protocol. Depends on the shared driver modules.
// Mirrors the module graph of the other native apps (tobiifreed / tobiifree-overlay).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared tobiifree_core module.
    const tobiifree_core = b.createModule(.{
        .root_source_file = b.path("../../driver/src/tobiifree_core.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tracker module (transport-agnostic, no libusb dependency).
    const tracker = b.createModule(.{
        .root_source_file = b.path("../../driver/src/tracker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tobiifree_core", .module = tobiifree_core },
        },
    });

    // Libusb transport.
    const libusb_transport = b.createModule(.{
        .root_source_file = b.path("../../driver/src/libusb_transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    libusb_transport.linkSystemLibrary("libusb-1.0", .{});
    libusb_transport.link_libc = true;

    // Daemon protocol (wire format for tobiifreed IPC).
    const daemon_protocol = b.createModule(.{
        .root_source_file = b.path("../../driver/src/daemon_protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tobiifree_core", .module = tobiifree_core },
        },
    });

    // USB source (LibusbTransport + Tracker) — pulled in transitively via
    // gaze_source; the bridge itself only talks to the daemon over the socket.
    const usb_source = b.createModule(.{
        .root_source_file = b.path("../../driver/src/usb_source.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tracker", .module = tracker },
            .{ .name = "libusb_transport", .module = libusb_transport },
            .{ .name = "gaze_source", .module = undefined }, // forward ref
        },
    });

    // Socket source (unix socket client to tobiifreed).
    const socket_source = b.createModule(.{
        .root_source_file = b.path("../../driver/src/socket_source.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "daemon_protocol", .module = daemon_protocol },
            .{ .name = "gaze_source", .module = undefined }, // forward ref
        },
    });

    // GazeSource (tagged union over usb/socket).
    const gaze_source = b.createModule(.{
        .root_source_file = b.path("../../driver/src/gaze_source.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tobiifree_core", .module = tobiifree_core },
            .{ .name = "usb_source", .module = usb_source },
            .{ .name = "socket_source", .module = socket_source },
        },
    });

    // Resolve forward references.
    usb_source.addImport("gaze_source", gaze_source);
    socket_source.addImport("gaze_source", gaze_source);

    // Tobii-feel filtering pipeline (gaze filter, head pose, curve, presets).
    const tobii_filter = b.createModule(.{
        .root_source_file = b.path("src/tobii_filter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tobiifree_core", .module = tobiifree_core },
        },
    });

    // Display area config (shared EDID + config loading).
    const display_area_config = b.createModule(.{
        .root_source_file = b.path("../../driver/src/display_area_config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Calibration wizard state machine.
    const calibration = b.createModule(.{
        .root_source_file = b.path("src/calibration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "daemon_protocol", .module = daemon_protocol },
        },
    });

    const exe = b.addExecutable(.{
        .name = "tobiifree-opentrack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tobiifree_core", .module = tobiifree_core },
                .{ .name = "daemon_protocol", .module = daemon_protocol },
                .{ .name = "socket_source", .module = socket_source },
                .{ .name = "tobii_filter", .module = tobii_filter },
                .{ .name = "display_area_config", .module = display_area_config },
                .{ .name = "calibration", .module = calibration },
            },
        }),
    });

    exe.linkSystemLibrary("libusb-1.0");
    exe.linkSystemLibrary("gtk4");
    exe.linkLibC();

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run tobiifree-opentrack");
    run_step.dependOn(&run.step);
}
