// accuracy_diag.zig — 39-target accuracy diagnostic UI + constants.
//
// Pure module: defines the 13×3 serpentine grid, per-point result storage,
// and cairo drawing functions for both the live-capture check phase and
// the post-sweep heatmap display.
//
// Calibrator state machine lives in calibration.zig — this module only
// provides types + drawing, never owns mutable capture state.
//
// Extracted v0.3.1 BATCH_0 from calibration.zig (types + constants) and
// main.zig (cairo draw branches) so the accuracy tool survives the fit
// rewrite and stays reusable for future regression checks.

const std = @import("std");

// ── Grid constants ────────────────────────────────────────────────────
pub const ACCURACY_COLS: usize = 13;
pub const ACCURACY_ROWS: usize = 3;
pub const NUM_ACC_POINTS = ACCURACY_COLS * ACCURACY_ROWS; // 39
pub const ACC_SAMPLES_PER_TARGET = 150; // ~1.7 s hold per target at 90 Hz
pub const ACC_BRAKE_FRAMES = 30; // ~330 ms brake between targets for gaze transition

// ── Types ─────────────────────────────────────────────────────────────

/// Accuracy grid target definition (position only — label derived from index).
pub const AccTarget = struct {
    x: f64, // normalized [0,1]
    y: f64,
};

/// Serpentine order: even rows L→R, odd rows R→L (no screen-spanning jump).
pub fn accTarget(idx: usize) AccTarget {
    const col_raw = idx % ACCURACY_COLS;
    const row = idx / ACCURACY_COLS;
    const col = if (row % 2 == 0) col_raw else (ACCURACY_COLS - 1 - col_raw);
    return .{
        .x = (@as(f64, @floatFromInt(col)) + 0.5) / @as(f64, @floatFromInt(ACCURACY_COLS)),
        .y = (@as(f64, @floatFromInt(row)) + 0.5) / @as(f64, @floatFromInt(ACCURACY_ROWS)),
    };
}

/// Per-target accuracy result stored for display. Calculated AFTER capture.
pub const AccPointResult = struct {
    gaze_x: f64 = 0, // averaged device gaze x (0-1)
    gaze_y: f64 = 0,
    valid_count: usize = 0,
    total_count: usize = 0,
    // Computed after all targets done: radial error in mm at the screen.
    error_mm: f64 = 0,
    eye_loss_rate: f64 = 0,
};

// ── Cairo helpers (own scratch, no dep on main.zig globals) ───────────

const c = @cImport({
    @cInclude("cairo.h");
});

var text_scratch: [256]u8 = undefined;

fn drawText(cr: *c.cairo_t, s: []const u8) void {
    if (s.len >= text_scratch.len) return;
    @memcpy(text_scratch[0..s.len], s);
    text_scratch[s.len] = 0;
    c.cairo_show_text(cr, @ptrCast(text_scratch[0..s.len :0].ptr));
}

fn measureText(cr: *c.cairo_t, s: []const u8, ext: *c.cairo_text_extents_t) void {
    ext.* = std.mem.zeroes(c.cairo_text_extents_t);
    if (s.len >= text_scratch.len) return;
    @memcpy(text_scratch[0..s.len], s);
    text_scratch[s.len] = 0;
    c.cairo_text_extents(cr, @ptrCast(text_scratch[0..s.len :0].ptr), ext);
}

// ── Drawing: live accuracy check (blue ring + progress) ───────────────

pub fn drawAccuracyCheck(
    cr: *c.cairo_t,
    w: f64,
    h: f64,
    acc_target_idx: usize,
    target: AccTarget,
    cap_n: usize,
) void {
    const px = target.x * w;
    const py = target.y * h;

    // White target dot.
    const dot_r: f64 = 12;
    c.cairo_set_source_rgb(cr, 1, 1, 1);
    c.cairo_arc(cr, px, py, dot_r, 0, 2.0 * 3.14159265);
    c.cairo_fill(cr);

    // Blue auto-advance progress ring (distinct from wizard green).
    const sweep = 2.0 * 3.14159265 * (@as(f64, @floatFromInt(cap_n)) / @as(f64, @floatFromInt(ACC_SAMPLES_PER_TARGET)));
    c.cairo_set_source_rgb(cr, 0.3, 0.6, 1.0);
    c.cairo_set_line_width(cr, 4);
    c.cairo_arc(cr, px, py, dot_r + 6, -3.14159265 * 0.5, -3.14159265 * 0.5 + sweep);
    c.cairo_stroke(cr);

    // Accuracy progress bar at bottom.
    const bar_h: f64 = 4;
    const acc_progress = @as(f64, @floatFromInt(acc_target_idx)) / @as(f64, @floatFromInt(NUM_ACC_POINTS));
    c.cairo_set_source_rgb(cr, 0.3, 0.3, 0.3);
    c.cairo_rectangle(cr, 0, h - bar_h, w, bar_h);
    c.cairo_fill(cr);
    c.cairo_set_source_rgb(cr, 0.3, 0.6, 1.0);
    c.cairo_rectangle(cr, 0, h - bar_h, w * acc_progress, bar_h);
    c.cairo_fill(cr);

    // Target counter + instructions.
    var status_buf: [96]u8 = undefined;
    if (std.fmt.bufPrint(&status_buf, "Target {d}/39  —  Accuracy Check", .{acc_target_idx + 1})) |ptext| {
        c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
        c.cairo_set_font_size(cr, 16);
        c.cairo_move_to(cr, 16, 30);
        c.cairo_set_source_rgb(cr, 0.6, 0.6, 0.6);
        drawText(cr, ptext);
    } else |_| {}

    // "Hold still" instruction
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
    c.cairo_set_font_size(cr, 20);
    var ext: c.cairo_text_extents_t = undefined;
    measureText(cr, "Hold still...", &ext);
    c.cairo_move_to(cr, (w - ext.width) / 2.0, py + 50);
    c.cairo_set_source_rgb(cr, 0.3, 0.6, 1.0);
    drawText(cr, "Hold still...");

    // Cancel hint.
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, 13);
    c.cairo_move_to(cr, 16, h - 16);
    c.cairo_set_source_rgb(cr, 0.55, 0.55, 0.55);
    drawText(cr, "ESC = cancel");
}

// ── Drawing: post-sweep heatmap (39-dot color + radius) ───────────────

pub fn drawAccuracyResults(
    cr: *c.cairo_t,
    w: f64,
    h: f64,
    results: []const AccPointResult,
    center_err: f64,
    mid_err: f64,
    edge_err: f64,
) void {
    // Title.
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
    c.cairo_set_font_size(cr, 22);
    c.cairo_set_source_rgb(cr, 1, 1, 1);
    c.cairo_move_to(cr, 30, 40);
    drawText(cr, "Accuracy Results");
    c.cairo_set_font_size(cr, 14);
    c.cairo_move_to(cr, 30, 65);
    c.cairo_set_source_rgb(cr, 0.6, 0.6, 0.6);
    drawText(cr, "Per-target radial error (color: green <20  yellow 20-50  orange 50-100  red >100 mm)");

    // Draw 39 target dots.
    const margin: f64 = 60;
    const dot_r: f64 = 7;
    const n = @min(results.len, NUM_ACC_POINTS);
    for (0..n) |i| {
        const target = accTarget(i);
        const px = margin + target.x * (w - 2.0 * margin);
        const py = margin + target.y * (h - 2.0 * margin);
        const err = results[i].error_mm;

        // Color code based on error.
        if (err < 20.0) {
            c.cairo_set_source_rgb(cr, 0.2, 0.9, 0.3); // green
        } else if (err < 50.0) {
            c.cairo_set_source_rgb(cr, 1.0, 0.85, 0.0); // yellow
        } else if (err < 100.0) {
            c.cairo_set_source_rgb(cr, 1.0, 0.55, 0.0); // orange
        } else {
            c.cairo_set_source_rgb(cr, 1.0, 0.2, 0.2); // red
        }

        // Dot radius = base + error/20, cap at 18.
        const radius = @min(dot_r + err / 20.0, 18.0);
        c.cairo_arc(cr, px, py, radius, 0, 2.0 * 3.14159265);
        c.cairo_fill(cr);

        // Error label on each dot (small).
        var err_buf: [16]u8 = undefined;
        if (std.fmt.bufPrint(&err_buf, "{d:.0}", .{err})) |el| {
            c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
            c.cairo_set_font_size(cr, 10);
            c.cairo_set_source_rgb(cr, 1, 1, 1);
            var ext: c.cairo_text_extents_t = undefined;
            measureText(cr, el, &ext);
            c.cairo_move_to(cr, px - ext.width / 2.0, py + 3.5);
            drawText(cr, el);
        } else |_| {}
    }

    // Band summary at bottom-left.
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
    c.cairo_set_font_size(cr, 14);
    const band_y = h - 50;
    c.cairo_set_source_rgb(cr, 0.8, 0.8, 0.8);

    // Center band.
    c.cairo_set_source_rgb(cr, 0.2, 0.9, 0.3);
    c.cairo_arc(cr, 30, band_y - 3, 5, 0, 2.0 * 3.14159265);
    c.cairo_fill(cr);
    c.cairo_set_source_rgb(cr, 0.8, 0.8, 0.8);
    c.cairo_move_to(cr, 45, band_y);
    var band_buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&band_buf, "Center p95: {d:.0} mm", .{center_err})) |b| {
        drawText(cr, b);
    } else |_| {}

    // Mid band.
    c.cairo_set_source_rgb(cr, 1.0, 0.85, 0.0);
    c.cairo_arc(cr, 210, band_y - 3, 5, 0, 2.0 * 3.14159265);
    c.cairo_fill(cr);
    c.cairo_set_source_rgb(cr, 0.8, 0.8, 0.8);
    c.cairo_move_to(cr, 225, band_y);
    if (std.fmt.bufPrint(&band_buf, "Mid p95: {d:.0} mm", .{mid_err})) |b| {
        drawText(cr, b);
    } else |_| {}

    // Edge band.
    c.cairo_set_source_rgb(cr, 1.0, 0.55, 0.0);
    c.cairo_arc(cr, 390, band_y - 3, 5, 0, 2.0 * 3.14159265);
    c.cairo_fill(cr);
    c.cairo_set_source_rgb(cr, 0.8, 0.8, 0.8);
    c.cairo_move_to(cr, 405, band_y);
    if (std.fmt.bufPrint(&band_buf, "Edge p95: {d:.0} mm", .{edge_err})) |b| {
        drawText(cr, b);
    } else |_| {}

    // Guidance CTA.
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
    c.cairo_set_font_size(cr, 18);
    c.cairo_set_source_rgb(cr, 0.3, 0.8, 0.4);
    if (edge_err > 100) {
        c.cairo_move_to(cr, 30, band_y + 35);
        c.cairo_set_source_rgb(cr, 1.0, 0.5, 0.3);
        drawText(cr, "Corner accuracy poor — press R to re-run the calibration wizard");
    } else {
        c.cairo_move_to(cr, 30, band_y + 35);
        c.cairo_set_source_rgb(cr, 0.3, 0.8, 0.4);
        drawText(cr, "Accuracy OK — press ESC to close");
    }

    // Footer hint.
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, 13);
    c.cairo_move_to(cr, 16, h - 16);
    c.cairo_set_source_rgb(cr, 0.55, 0.55, 0.55);
    drawText(cr, "ESC = close   R = re-calibrate");
}