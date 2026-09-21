// accuracy_diag.zig — 39-target accuracy diagnostic constants + types.
//
// Pure data module (NO cairo, NO @cImport): defines grid constants,
// target positioning, result storage, and the serpentine ordering.
// Cairo drawing lives in main.zig (where the C import works).
//
// Extracted v0.3.1 BATCH_0 from calibration.zig so the accuracy tool
// stays reusable for future regression checks.
//
// BATCH_3: cairo draw functions moved to main.zig (sub-module @cImport
// failed in ReleaseSafe on zig 0.15). This module is data-only.

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