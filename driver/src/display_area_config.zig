const std = @import("std");

/// Physical screen dimensions from EDID auto-detection.
/// Used for GUI rendering, affine correction, and calibration mapping.
pub const PhysicalScreen = struct {
    w_mm: f64,
    h_mm: f64,
};

/// Device display area (track box) sent to the ET5 via set_display_area.
/// Expanded beyond physical screen to give a large track box matching
/// the original tobiifree defaults (1500×1000mm equivalent).
pub const DeviceDisplayArea = struct {
    w_mm: f64,
    h_mm: f64,
    z_mm: f64 = 65,
    tilt_deg: f64 = 12,
    ox_mm: f64,
    oy_mm: f64,
    track_box_factor: f64 = 2.5,
};

/// Calibration parameters (affine correction for gaze mapping).
/// Adjusted by calibration wizard; NEVER includes display area.
pub const CalibrationParams = struct {
    gaze_y_offset: f64 = 0.394,
    gaze_y_scale: f64 = 1.278,
    gaze_x_offset: f64 = 0.0,
    gaze_x_scale: f64 = 1.0,
};

/// Complete configuration loaded from ~/.config/tobii.json.
/// Device display area is always recomputed from physical_screen × factor.
pub const FullConfig = struct {
    physical_screen: PhysicalScreen,
    device_display_area: DeviceDisplayArea,
    calibration: CalibrationParams,
};

/// EDID physical dimensions detected from the primary display.
pub const EdidInfo = struct {
    width_mm: f64,
    height_mm: f64,
    connected_name: ?[]const u8 = null,
};

/// Try to read EDID bytes from sysfs and extract physical dimensions.
/// Falls back to returning null if no valid EDID is found.
pub fn detectEdid() ?EdidInfo {
    var dir = std.fs.openDirAbsolute("/sys/class/drm", .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (!std.mem.startsWith(u8, entry.name, "card")) continue;
        if (std.mem.indexOf(u8, entry.name, "-") == null) continue;

        var path_buf: [256]u8 = undefined;
        const edid_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/edid", .{entry.name}) catch continue;

        const file = std.fs.openFileAbsolute(edid_path, .{}) catch continue;
        defer file.close();

        var buf: [512]u8 = undefined;
        const n = file.readAll(&buf) catch continue;
        if (n < 128) continue;

        const h_cm = buf[21];
        const v_cm = buf[22];
        if (h_cm == 0 or v_cm == 0) continue;

        return .{
            .width_mm = @as(f64, @floatFromInt(h_cm)) * 10.0,
            .height_mm = @as(f64, @floatFromInt(v_cm)) * 10.0,
            .connected_name = entry.name,
        };
    }
    return null;
}

/// Generate a default FullConfig from detected EDID info.
/// Device display area = physical_screen × track_box_factor (default 2.5).
/// This restores the original tobiifree's large track box (~1500×1000mm equivalent)
/// while keeping correct clip-mount geometry (z=65, tilt=12) for gaze mapping.
pub fn defaultFromEdid(edid: EdidInfo, factor: f64) FullConfig {
    const phys_w = edid.width_mm;
    const phys_h = edid.height_mm;
    const dev_w = phys_w * factor;
    const dev_h = phys_h * factor;

    const half_dev_w = dev_w / 2.0;
    const half_dev_h = dev_h / 2.0;

    // Sensor at bottom-center. cy = "b - 10" means 10mm below bottom edge.
    const cy = -half_dev_h + 10.0;

    return FullConfig{
        .physical_screen = .{ .w_mm = phys_w, .h_mm = phys_h },
        .device_display_area = .{
            .w_mm = dev_w,
            .h_mm = dev_h,
            .z_mm = 65,
            .tilt_deg = 12,
            .ox_mm = -half_dev_w,
            .oy_mm = -cy - half_dev_h,
            .track_box_factor = factor,
        },
        .calibration = .{},
    };
}

/// Generate the JSON config string for writing to ~/.config/tobii.json.
/// Serializes ONLY physical_screen + calibration + track_box_factor.
/// Device display area is always recomputed on load.
pub fn toJsonString(cfg: FullConfig, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf,
        \\{{
        \\  "physical_screen": {{
        \\    "w_mm": {d:.0},
        \\    "h_mm": {d:.0}
        \\  }},
        \\  "calibration": {{
        \\    "gaze_y_offset": {d:.3},
        \\    "gaze_y_scale": {d:.3},
        \\    "gaze_x_offset": {d:.3},
        \\    "gaze_x_scale": {d:.3}
        \\  }},
        \\  "track_box_factor": {d:.1}
        \\}}
        \\
    , .{
        cfg.physical_screen.w_mm, cfg.physical_screen.h_mm,
        cfg.calibration.gaze_y_offset, cfg.calibration.gaze_y_scale,
        cfg.calibration.gaze_x_offset, cfg.calibration.gaze_x_scale,
        cfg.device_display_area.track_box_factor,
    }) catch null;
}

/// Load FullConfig from JSON file at path.
/// Returns a default config if file doesn't exist or is invalid.
/// Auto-migrates old format (root display_area with w_mm/h_mm/z_mm/tilt/cx/cy).
pub fn loadFromFile(path: []const u8, allocator: std.mem.Allocator) !FullConfig {
    const file = std.fs.cwd().openFile(path, .{}) catch return defaultFullConfig();
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return defaultFullConfig();

    const OldConfig = struct { display_area: ?std.json.Value = null };
    const parsed = std.json.parseFromSlice(OldConfig, allocator, buf[0..n], .{
        .ignore_unknown_fields = true,
    }) catch return defaultFullConfig();

    const da_val = parsed.value.display_area orelse return defaultFullConfig();

    const obj = switch (da_val) {
        .object => |o| o,
        else => return defaultFullConfig(),
    };

    // Check for new format (has physical_screen + calibration + track_box_factor)
    if (obj.get("physical_screen")) |_| {
        return loadNewFormat(obj);
    }

    // Old format: migrate
    return migrateOldFormat(obj);
}

/// Default FullConfig when no file exists or parsing fails.
pub fn defaultFullConfig() FullConfig {
    return FullConfig{
        .physical_screen = .{ .w_mm = 800, .h_mm = 330 },
        .device_display_area = .{
            .w_mm = 2000,
            .h_mm = 825,
            .z_mm = 65,
            .tilt_deg = 12,
            .ox_mm = -1000,
            .oy_mm = -10,
            .track_box_factor = 2.5,
        },
        .calibration = .{},
    };
}

/// Load new format (physical_screen + calibration + track_box_factor).
fn loadNewFormat(obj: std.json.ObjectMap) !FullConfig {
    var cfg = defaultFullConfig();

    // physical_screen
    if (obj.get("physical_screen")) |ps_val| {
        const ps_obj = switch (ps_val) { .object => |o| o, else => return defaultFullConfig() };
        if (getFloat(ps_obj, "w_mm")) |v| cfg.physical_screen.w_mm = v;
        if (getFloat(ps_obj, "h_mm")) |v| cfg.physical_screen.h_mm = v;
    }

    // calibration
    if (obj.get("calibration")) |cal_val| {
        const cal_obj = switch (cal_val) { .object => |o| o, else => return defaultFullConfig() };
        if (getFloat(cal_obj, "gaze_y_offset")) |v| cfg.calibration.gaze_y_offset = v;
        if (getFloat(cal_obj, "gaze_y_scale")) |v| cfg.calibration.gaze_y_scale = v;
        if (getFloat(cal_obj, "gaze_x_offset")) |v| cfg.calibration.gaze_x_offset = v;
        if (getFloat(cal_obj, "gaze_x_scale")) |v| cfg.calibration.gaze_x_scale = v;
    }

    // track_box_factor
    if (getFloat(obj, "track_box_factor")) |v| {
        cfg.device_display_area.track_box_factor = v;
    }

    // Recompute device display area from physical_screen × factor
    const factor = cfg.device_display_area.track_box_factor;
    const dev_w = cfg.physical_screen.w_mm * factor;
    const dev_h = cfg.physical_screen.h_mm * factor;
    const half_dev_w = dev_w / 2.0;
    const half_dev_h = dev_h / 2.0;
    const cy = -half_dev_h + 10.0;

    cfg.device_display_area = .{
        .w_mm = dev_w,
        .h_mm = dev_h,
        .z_mm = 65,
        .tilt_deg = 12,
        .ox_mm = -half_dev_w,
        .oy_mm = -cy - half_dev_h,
        .track_box_factor = factor,
    };

    return cfg;
}

/// Migrate old format (root display_area with w_mm/h_mm/z_mm/tilt/cx/cy).
fn migrateOldFormat(obj: std.json.ObjectMap) !FullConfig {
    var phys_w: f64 = 800;
    var phys_h: f64 = 330;
    const factor: f64 = 2.5;

    // Extract physical screen from old w_mm/h_mm (these were the device area before)
    if (getFloat(obj, "w_mm")) |v| phys_w = v;
    if (getFloat(obj, "h_mm")) |v| phys_h = v;

    // If old config had factor-like values, try to infer (fallback to 2.5)
    // For safety, assume old config was physical screen size.

    // Load calibration from old preset defaults
    const cal = CalibrationParams{};

    // Recompute device display area with factor
    const dev_w = phys_w * factor;
    const dev_h = phys_h * factor;
    const half_dev_w = dev_w / 2.0;
    const half_dev_h = dev_h / 2.0;
    const cy = -half_dev_h + 10.0;

    return FullConfig{
        .physical_screen = .{ .w_mm = phys_w, .h_mm = phys_h },
        .device_display_area = .{
            .w_mm = dev_w,
            .h_mm = dev_h,
            .z_mm = 65,
            .tilt_deg = 12,
            .ox_mm = -half_dev_w,
            .oy_mm = -cy - half_dev_h,
            .track_box_factor = factor,
        },
        .calibration = cal,
    };
}

/// Convert DeviceDisplayArea to Tracker.DisplayArea struct.
/// Caller passes in the Tracker type to avoid circular module dependency.
pub fn toTrackerDisplayArea(d: DeviceDisplayArea, comptime DA: type) DA {
    return .{
        .w_mm = d.w_mm,
        .h_mm = d.h_mm,
        .ox_mm = d.ox_mm,
        .oy_mm = d.oy_mm,
        .z_mm = d.z_mm,
        .tilt_deg = d.tilt_deg,
    };
}

/// Save FullConfig to ~/.config/tobii.json.
pub fn saveToFile(cfg: FullConfig, allocator: std.mem.Allocator) !void {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const path = try std.fmt.allocPrint(allocator, "{s}/.config/tobii.json", .{home});
    defer allocator.free(path);

    const dir_path = try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
    defer allocator.free(dir_path);
    std.fs.makeDirAbsolute(dir_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var json_buf: [2048]u8 = undefined;
    const json_str = toJsonString(cfg, &json_buf) orelse return error.JsonFormat;

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(json_str);
}

// ── JSON helpers ─────────────────────────────────────────────────────

fn getFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => null,
    };
}

fn parsePositionExpr(val: std.json.Value, half: f64, is_vertical: bool) ?f64 {
    switch (val) {
        .float => |f| return f,
        .integer => |i| return @floatFromInt(i),
        .string => |s| return evalAnchorExpr(s, half, is_vertical),
        else => return null,
    }
}

fn evalAnchorExpr(expr: []const u8, half: f64, is_vertical: bool) ?f64 {
    var pos: usize = 0;
    while (pos < expr.len and expr[pos] == ' ') pos += 1;
    if (pos >= expr.len) return null;

    const anchor: f64 = switch (expr[pos]) {
        't' => if (is_vertical) half else return null,
        'b' => if (is_vertical) -half else return null,
        'l' => if (!is_vertical) -half else return null,
        'r' => if (!is_vertical) half else return null,
        'c' => 0,
        else => return null,
    };
    pos += 1;

    while (pos < expr.len and expr[pos] == ' ') pos += 1;
    if (pos >= expr.len) return anchor;

    const sign: f64 = switch (expr[pos]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    pos += 1;

    while (pos < expr.len and expr[pos] == ' ') pos += 1;
    if (pos >= expr.len) return null;

    const num = std.fmt.parseFloat(f64, expr[pos..]) catch return null;
    return anchor + sign * num;
}