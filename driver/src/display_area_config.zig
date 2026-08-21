const std = @import("std");

/// Display area config as stored in JSON files.
pub const DisplayAreaConfig = struct {
    w_mm: f64 = 0,
    h_mm: f64 = 0,
    z_mm: f64 = 65,
    tilt_deg: f64 = 12,
    ox_mm: f64 = -400,
    oy_mm: f64 = -165,
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
    // Walk /sys/class/drm/card*-DP-*/edid or card*-HDMI-*/edid
    var dir = std.fs.openDirAbsolute("/sys/class/drm", .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        // Look for cardN-outputN patterns (e.g. card2-DP-2).
        if (!std.mem.startsWith(u8, entry.name, "card")) continue;
        if (std.mem.indexOf(u8, entry.name, "-") == null) continue;

        var path_buf: [256]u8 = undefined;
        const edid_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/edid", .{entry.name}) catch continue;

        const file = std.fs.openFileAbsolute(edid_path, .{}) catch continue;
        defer file.close();

        var buf: [512]u8 = undefined;
        const n = file.readAll(&buf) catch continue;
        if (n < 128) continue; // EDID block 0 is 128 bytes minimum.

        // Parse EDID block 0, bytes 21-22: max horizontal/vertical size in cm.
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

/// Generate a sensible default DisplayAreaConfig from detected EDID info.
/// Uses typical ET5 clip-mount geometry: sensor at bottom center, ~65mm z distance.
pub fn defaultFromEdid(edid: EdidInfo) DisplayAreaConfig {
    const w = edid.width_mm;
    const h = edid.height_mm;
    const half_w = w / 2.0;
    const half_h = h / 2.0;
    // Sensor is at bottom-center of screen. cy = "b - 10" means 10mm below
    // bottom edge of display area (in tracker coords, b = -half_h).
    const cy = -half_h + 10.0; // anchor 'b' + 10mm offset
    return .{
        .w_mm = w,
        .h_mm = h,
        .z_mm = 65, // perpendicular distance from sensor to display plane (clip-mount estimate)
        .tilt_deg = 12, // screen tilted away from sensor (typical for clip mount)
        .ox_mm = -half_w, // cx=0 → ox = 0 - half_w
        .oy_mm = -cy - half_h, // oy = -cy - half_h
    };
}

/// Generate the JSON config string for writing to ~/.config/tobii.json.
pub fn toJsonString(cfg: DisplayAreaConfig, buf: []u8) ?[]const u8 {
    // Reconstruct cx/cy from ox/oy for human-readable config.
    const half_w = cfg.w_mm / 2.0;
    const half_h = cfg.h_mm / 2.0;
    const cx = -cfg.ox_mm - half_w;
    const cy = -cfg.oy_mm - half_h;
    return std.fmt.bufPrint(buf,
        \\{{
        \\  "display_area": {{
        \\    "w_mm": {d:.0},
        \\    "h_mm": {d:.0},
        \\    "z_mm": {d:.0},
        \\    "tilt": {d:.1},
        \\    "cx": {d:.1},
        \\    "cy": {d:.1}
        \\  }}
        \\}}
        \\
    , .{ cfg.w_mm, cfg.h_mm, cfg.z_mm, cfg.tilt_deg, cx, cy }) catch null;
}

/// Load display area config from a JSON file at the given path.
/// Returns a default config if the file doesn't exist or is invalid.
pub fn loadFromFile(path: []const u8) DisplayAreaConfig {
    const file = std.fs.cwd().openFile(path, .{}) catch return .{};
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return .{};

    const Config = struct { display_area: ?std.json.Value = null };
    const parsed = std.json.parseFromSlice(Config, std.heap.page_allocator, buf[0..n], .{
        .ignore_unknown_fields = true,
    }) catch return .{};

    const da_val = parsed.value.display_area orelse return .{};
    const obj = switch (da_val) {
        .object => |o| o,
        else => return .{},
    };

    var cfg = DisplayAreaConfig{};
    if (getFloat(obj, "w_mm")) |v| cfg.w_mm = v;
    if (getFloat(obj, "h_mm")) |v| cfg.h_mm = v;
    if (getFloat(obj, "z_mm")) |v| cfg.z_mm = v;
    if (getFloat(obj, "tilt")) |v| cfg.tilt_deg = v;

    const half_w = cfg.w_mm / 2.0;
    const half_h = cfg.h_mm / 2.0;

    if (obj.get("cx")) |cx_val| {
        if (parsePositionExpr(cx_val, half_w, false)) |cx| {
            cfg.ox_mm = -cx - half_w;
        }
    }
    if (obj.get("cy")) |cy_val| {
        if (parsePositionExpr(cy_val, half_h, true)) |cy| {
            cfg.oy_mm = -cy - half_h;
        }
    }
    return cfg;
}

/// Convert DisplayAreaConfig to a Tracker.DisplayArea struct.
/// Caller passes in the Tracker type to avoid circular module dependency.
pub fn toTrackerDisplayArea(cfg: DisplayAreaConfig, comptime DA: type) DA {
    return .{
        .w_mm = cfg.w_mm,
        .h_mm = cfg.h_mm,
        .ox_mm = cfg.ox_mm,
        .oy_mm = cfg.oy_mm,
        .z_mm = cfg.z_mm,
        .tilt_deg = cfg.tilt_deg,
    };
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
