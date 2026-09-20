const std = @import("std");
const proto = @import("daemon_protocol");
const core = @import("tobiifree_core");
const accuracy_diag = @import("accuracy_diag");

const log = std.log.scoped(.calibration);

pub const CalState = enum {
    idle,
    showing_point,
    capturing,
    waiting_response,
    done,
    error_state,
    accuracy_check,     // BATCH_4: 39-target accuracy sweep
    show_accuracy_results, // BATCH_4: heatmap results display
};

pub const CalPoint = struct {
    x: f64, // normalized [0,1] screen position
    y: f64,
    label: []const u8,
};

pub const CALIBRATION_POINTS = [_]CalPoint{
    .{ .x = 0.5,  .y = 0.5,  .label = "Center" },
    // Near corners (both eyes typically visible)
    .{ .x = 0.15, .y = 0.15, .label = "Near Top-Left" },
    .{ .x = 0.85, .y = 0.15, .label = "Near Top-Right" },
    .{ .x = 0.05, .y = 0.95, .label = "Near Bottom-Left" },
    .{ .x = 0.95, .y = 0.95, .label = "Near Bottom-Right" },
    // True edge corners (single eye, nose-occluded)
    .{ .x = 0.02, .y = 0.02, .label = "Edge Top-Left" },
    .{ .x = 0.98, .y = 0.02, .label = "Edge Top-Right" },
    .{ .x = 0.02, .y = 0.98, .label = "Edge Bottom-Left" },
    .{ .x = 0.98, .y = 0.98, .label = "Edge Bottom-Right" },
};

pub const NUM_CAL_POINTS = CALIBRATION_POINTS.len;

/// Per-point capture sample counts (center ~3s, near-corners ~5s, true-corners ~10s @ 60 Hz).
pub fn samplesForPoint(idx: usize) usize {
    return if (idx == 0) 180
    else if (idx >= 1 and idx <= 4) 300
    else 600;
}

/// Capture quality gates: below this many valid frames the attempt is thrown
/// away and the SAME point is retried (eyes often clip out of tracking range
/// at extreme corners). After MAX_POINT_RETRIES weak attempts the run fails.
pub const MIN_VALID_PER_POINT = 30; // BATCH_4: was 15
pub const MAX_POINT_RETRIES = 4; // BATCH_4: was 3

pub const Calibrator = struct {
    state: CalState = .idle,
    current_point: usize = 0,
    sample_count: usize = 0,
    // BATCH_2: settle frames between wizard points (discard first ~30 frames for gaze transition).
    settle_remaining: usize = 0,
    // BATCH_3: HOLD-SPACE release flag — set by key-release handler, checked in feed path.
    hold_released: bool = false,

    // Accumulated gaze samples for current point.
    gaze_x_sum: f64 = 0,
    gaze_y_sum: f64 = 0,
    eye_x_sum: f64 = 0,
    eye_y_sum: f64 = 0,
    eye_z_sum: f64 = 0,
    valid_count: usize = 0,
    // BATCH_2: per-eye frame counters (for single-eye corner offset logging).
    left_eye_frames: usize = 0,
    right_eye_frames: usize = 0,
    // v0.3 BATCH_1: per-point quality log accumulators (additive, log-only).
    jaw_diff_sum: f64 = 0, // |L_y - R_y| summed over BOTH-eye-valid frames
    jaw_diff_cnt: usize = 0,

    // Results: averaged gaze at each calibration point.
    result_gaze: [NUM_CAL_POINTS][2]f64 = undefined,
    result_eye: [NUM_CAL_POINTS][3]f64 = undefined,

    // Pending response callback state.
    pending_cmd: ?u8 = null,

    /// Weak-capture retry counter for the CURRENT point (reset on success).
    retries: usize = 0,

    // ── BATCH_4: accuracy diagnostic ─────────────────────────────────
    /// Accuracy results (39 targets). Stored separately from wizard results.
    acc_results: [accuracy_diag.NUM_ACC_POINTS]accuracy_diag.AccPointResult = undefined,
    /// Current accuracy target index (0..NUM_ACC_POINTS-1).
    acc_target_idx: usize = 0,
    /// Brake counter: frames of transition gap between targets.
    acc_brake_remaining: usize = 0,
    /// Screen dimensions in mm (from physical config) for error computation.
    screen_w_mm: f64 = 0,
    screen_h_mm: f64 = 0,
    /// Track box factor for deviceToGui (applied before fit in error computation).
    acc_factor: f64 = 2.5,
    /// Current gaze calibration fit (applied after deviceToGui in error computation).
    acc_fit: AffineFit = .{},
    /// Per-band aggregate errors (filled at finalize).
    acc_center_err: f64 = 0, // targets in center 1/3 zone
    acc_mid_err: f64 = 0, // targets in middle ring
    acc_edge_err: f64 = 0, // targets at outer edge

    pub fn start(self: *Calibrator) void {
        self.* = .{};
        self.state = .showing_point;
        log.info("calibration started — look at {s}", .{CALIBRATION_POINTS[0].label});
    }

    /// Begin sampling for the current point. Owns all accumulator resets so
    /// external code never pokes state machine internals directly.
    pub fn beginCapture(self: *Calibrator) void {
        self.state = .capturing;
        self.sample_count = 0;
        self.gaze_x_sum = 0;
        self.gaze_y_sum = 0;
        self.eye_x_sum = 0;
        self.eye_y_sum = 0;
        self.eye_z_sum = 0;
        self.valid_count = 0;
        self.jaw_diff_sum = 0;
        self.jaw_diff_cnt = 0;
        self.left_eye_frames = 0;
        self.right_eye_frames = 0;
        self.settle_remaining = accuracy_diag.ACC_BRAKE_FRAMES;
        self.hold_released = false;
    }

    pub fn cancel(self: *Calibrator) void {
        self.state = .idle;
        self.current_point = 0;
        self.acc_target_idx = 0;
        log.info("calibration cancelled", .{});
    }

    // ── BATCH_4: accuracy diagnostic ─────────────────────────────────

    /// Start accuracy check. Reuses the calibrator's accumulators but targets
    /// are from the 39-point grid. Sets state to .accuracy_check.
    pub fn startAccuracy(self: *Calibrator, screen_w: f64, screen_h: f64, factor: f64, fit: AffineFit) void {
        self.state = .accuracy_check;
        self.acc_target_idx = 0;
        self.acc_brake_remaining = 0;
        self.sample_count = 0;
        self.gaze_x_sum = 0;
        self.gaze_y_sum = 0;
        self.valid_count = 0;
        self.acc_factor = factor;
        self.acc_fit = fit;
        self.acc_results = [_]accuracy_diag.AccPointResult{.{}} ** accuracy_diag.NUM_ACC_POINTS;
        self.screen_w_mm = screen_w;
        self.screen_h_mm = screen_h;
        self.acc_center_err = 0;
        self.acc_mid_err = 0;
        self.acc_edge_err = 0;
        log.info("accuracy check started — 39 targets (factor {d:.2}, fit x=({d:.3}/{d:.3}) y=({d:.3}/{d:.3}))", .{
            factor, fit.gaze_x_offset, fit.gaze_x_scale, fit.gaze_y_offset, fit.gaze_y_scale,
        });
    }

    /// Feed a sample into the accuracy capture. Reuses existing feed logic
    /// (same accumulator/validity rules). Returns true when enough frames for
    /// current target have arrived. Handles brake frames between targets.
    pub fn feedAccuracy(self: *Calibrator, sample: *const proto.GazeSample) bool {
        if (self.state != .accuracy_check) return false;
        if (self.acc_target_idx >= accuracy_diag.NUM_ACC_POINTS) return false;

        // Brake period: count down, no capture.
        if (self.acc_brake_remaining > 0) {
            self.acc_brake_remaining -= 1;
            return false;
        }

        // Use same validity logic as wizard.
        const l_plausible = core.eye2dPlausible(sample.gaze_point_2d_L_norm[0], sample.gaze_point_2d_L_norm[1]);
        const r_plausible = core.eye2dPlausible(sample.gaze_point_2d_R_norm[0], sample.gaze_point_2d_R_norm[1]);
        const l_ok = sample.validity_L == 0 or l_plausible;
        const r_ok = sample.validity_R == 0 or r_plausible;
        const any_valid = l_ok or r_ok;
        if (any_valid) {
            if (l_ok and r_ok) {
                self.gaze_x_sum += sample.gaze_point_2d_norm[0];
                self.gaze_y_sum += sample.gaze_point_2d_norm[1];
            } else if (l_ok) {
                self.gaze_x_sum += sample.gaze_point_2d_L_norm[0];
                self.gaze_y_sum += sample.gaze_point_2d_L_norm[1];
            } else {
                self.gaze_x_sum += sample.gaze_point_2d_R_norm[0];
                self.gaze_y_sum += sample.gaze_point_2d_R_norm[1];
            }
            self.valid_count += 1;
        }
        self.sample_count += 1;

        return self.sample_count >= accuracy_diag.ACC_SAMPLES_PER_TARGET;
    }

    /// Finalize current accuracy target and advance to next. Returns false when
    /// all targets are done (caller should transition to results display).
    pub fn finalizeAccTarget(self: *Calibrator) bool {
        const idx = self.acc_target_idx;
        const n = @as(f64, @floatFromInt(@max(self.valid_count, 1)));
        const gaze_x_avg = self.gaze_x_sum / n;
        const gaze_y_avg = self.gaze_y_sum / n;

        self.acc_results[idx] = .{
            .gaze_x = gaze_x_avg,
            .gaze_y = gaze_y_avg,
            .valid_count = self.valid_count,
            .total_count = self.sample_count,
            .error_mm = 0, // filled below
            .eye_loss_rate = 1.0 - @as(f64, @floatFromInt(self.valid_count)) / @max(@as(f64, @floatFromInt(self.sample_count)), 1.0),
        };

        // Compute screen-space error for this target.
        const target = accuracy_diag.accTarget(idx);

        // Apply current calibration fit: deviceToGui(raw, factor) → (pre + offset)/scale → corrected.
        const pre = core.deviceToGui(.{ gaze_x_avg, gaze_y_avg }, self.acc_factor);
        const corr_x = (pre[0] + self.acc_fit.gaze_x_offset) / self.acc_fit.gaze_x_scale;
        const corr_y = (pre[1] + self.acc_fit.gaze_y_offset) / self.acc_fit.gaze_y_scale;
        const dx_norm = corr_x - target.x;
        const dy_norm = corr_y - target.y;
        const err_mm = @sqrt(dx_norm * dx_norm * self.screen_w_mm * self.screen_w_mm + dy_norm * dy_norm * self.screen_h_mm * self.screen_h_mm);
        self.acc_results[idx].error_mm = err_mm;

        // Band of this target (center/mid/edge).
        const from_center = @sqrt((target.x - 0.5) * (target.x - 0.5) + (target.y - 0.5) * (target.y - 0.5));
        if (from_center < 0.2) {
            self.acc_center_err = @max(self.acc_center_err, err_mm);
        } else if (from_center < 0.4) {
            self.acc_mid_err = @max(self.acc_mid_err, err_mm);
        } else {
            self.acc_edge_err = @max(self.acc_edge_err, err_mm);
        }

        log.info("acc point {} ({d:.2},{d:.2}): raw=({d:.4},{d:.4}) corr=({d:.4},{d:.4}) err={d:.1}mm ({d}/{d} valid)", .{
            idx, target.x, target.y, gaze_x_avg, gaze_y_avg, corr_x, corr_y, err_mm,
            self.valid_count, self.sample_count,
        });

        // Reset accumulators and add brake before next target.
        self.sample_count = 0;
        self.gaze_x_sum = 0;
        self.gaze_y_sum = 0;
        self.valid_count = 0;
        self.acc_brake_remaining = accuracy_diag.ACC_BRAKE_FRAMES;

        self.acc_target_idx += 1;
        if (self.acc_target_idx >= accuracy_diag.NUM_ACC_POINTS) {
            log.info("accuracy check complete — center_err={d:.1}mm mid_err={d:.1}mm edge_err={d:.1}mm", .{
                self.acc_center_err, self.acc_mid_err, self.acc_edge_err,
            });
            return false; // all done
        }
        return true; // more targets remain
    }

    pub fn currentPoint(self: *const Calibrator) CalPoint {
        if (self.current_point < NUM_CAL_POINTS) {
            return CALIBRATION_POINTS[self.current_point];
        }
        return CALIBRATION_POINTS[NUM_CAL_POINTS - 1];
    }

    pub fn progress(self: *const Calibrator) f64 {
        return @as(f64, @floatFromInt(self.current_point)) / @as(f64, @floatFromInt(NUM_CAL_POINTS));
    }

/// Per-eye 2D plausibility now lives in the shared helper core.eye2dPlausible
/// (driver/src/tobiifree_core.zig) so the calibration loop, the bridge GUI and
/// the pipeline validity gate all agree on what counts as "tracked".

/// Feed a gaze sample during capturing. One valid eye is enough for
/// calibration (clip-mounted trackers frequently lose one eye at extreme
/// angles). Returns true once the per-point sample count has been reached.
pub fn feedSample(self: *Calibrator, sample: *const proto.GazeSample) bool {
    if (self.state != .capturing) return false;

    // BATCH_2: settle frames — discard initial samples for gaze transition.
    if (self.settle_remaining > 0) {
        self.settle_remaining -= 1;
        self.sample_count += 1; // still count sample so total_count reflects elapsed time
        return false;
    }

    // Accept any sample where at least ONE eye is tracked (by validity flag
    // or by plausible per-eye 2D coords — fixes corner false-negatives).
    const l_plausible = core.eye2dPlausible(sample.gaze_point_2d_L_norm[0], sample.gaze_point_2d_L_norm[1]);
    const r_plausible = core.eye2dPlausible(sample.gaze_point_2d_R_norm[0], sample.gaze_point_2d_R_norm[1]);
    const l_ok = sample.validity_L == 0 or l_plausible;
    const r_ok = sample.validity_R == 0 or r_plausible;
    const any_valid = l_ok or r_ok;
    if (any_valid) {
        if (l_ok and r_ok) {
            self.gaze_x_sum += sample.gaze_point_2d_norm[0];
            self.gaze_y_sum += sample.gaze_point_2d_norm[1];
            self.eye_x_sum += (sample.eye_origin_L_mm[0] + sample.eye_origin_R_mm[0]) / 2.0;
            self.eye_y_sum += (sample.eye_origin_L_mm[1] + sample.eye_origin_R_mm[1]) / 2.0;
            self.eye_z_sum += (sample.eye_origin_L_mm[2] + sample.eye_origin_R_mm[2]) / 2.0;
            // v0.3 BATCH_1: jaw/cheek wobble witness — |L_y - R_y| on
            // normalized per-eye 2D. High mean = jaw artifacts at this point.
            self.jaw_diff_sum += @abs(sample.gaze_point_2d_L_norm[1] - sample.gaze_point_2d_R_norm[1]);
            self.jaw_diff_cnt += 1;
            self.left_eye_frames += 1;
            self.right_eye_frames += 1;
        } else if (l_ok) {
            self.gaze_x_sum += sample.gaze_point_2d_L_norm[0];
            self.gaze_y_sum += sample.gaze_point_2d_L_norm[1];
            self.eye_x_sum += sample.eye_origin_L_mm[0];
            self.eye_y_sum += sample.eye_origin_L_mm[1];
            self.eye_z_sum += sample.eye_origin_L_mm[2];
            self.left_eye_frames += 1;
        } else {
            self.gaze_x_sum += sample.gaze_point_2d_R_norm[0];
            self.gaze_y_sum += sample.gaze_point_2d_R_norm[1];
            self.eye_x_sum += sample.eye_origin_R_mm[0];
            self.eye_y_sum += sample.eye_origin_R_mm[1];
            self.eye_z_sum += sample.eye_origin_R_mm[2];
            self.right_eye_frames += 1;
        }
        self.valid_count += 1;
    }
    self.sample_count += 1;

    return self.sample_count >= samplesForPoint(self.current_point);
}

    pub const PointOutcome = enum { next_point, retry, finished, failed };

    /// Finalize capture for current point. Weak attempts (too few valid
    /// frames) stay on the SAME point for a retry instead of poisoning the
    /// result; only exhausting all retries fails the run.
    pub fn finalizePoint(self: *Calibrator) PointOutcome {
        const idx = self.current_point;
        const n = @as(f64, @floatFromInt(self.valid_count));
        const loss_rate = 1.0 - n / @as(f64, @floatFromInt(@max(self.sample_count, 1)));

        // BATCH_4: if eye_loss_rate > 30% on non-center points, RETRY.
        // All non-center points (1-8: near-corners + true edges) can have high eye loss.
        const is_corner = idx >= 1 and idx < NUM_CAL_POINTS;
        if (is_corner and loss_rate > 0.30) {
            self.retries += 1;
            if (self.retries >= MAX_POINT_RETRIES) {
                log.err("point {d}: eye_loss_rate {d:.1}%% >30%% — still failing after {d} attempts, aborting", .{
                idx, loss_rate * 100.0, MAX_POINT_RETRIES,
            });
            self.state = .error_state;
            return .failed;
        }
        log.warn("point {d}: eye_loss_rate {d:.1}%% >30%% — retry {d}/{d}", .{
                idx, loss_rate, self.retries + 1, MAX_POINT_RETRIES,
            });
            self.state = .showing_point;
            return .retry;
        }

        if (self.valid_count < MIN_VALID_PER_POINT) {
            self.retries += 1;
            if (self.retries >= MAX_POINT_RETRIES) {
                log.err("point {d}: still no usable capture after {d} attempts ({d}/{d} valid) — aborting", .{
                    idx, MAX_POINT_RETRIES, self.valid_count, self.sample_count,
                });
                self.state = .error_state;
                return .failed;
            }
            log.warn("point {d}: weak capture ({d}/{d} valid) — SPACE to retry, attempt {d}/{d}", .{
                idx, self.valid_count, self.sample_count, self.retries + 1, MAX_POINT_RETRIES,
            });
            self.state = .showing_point;
            return .retry;
        }
        self.result_gaze[idx] = .{ self.gaze_x_sum / n, self.gaze_y_sum / n };
        self.result_eye[idx] = .{ self.eye_x_sum / n, self.eye_y_sum / n, self.eye_z_sum / n };
        self.retries = 0;
        // v0.3 BATCH_1: per-point calibration quality log (additive, log-only).
        // eye_loss_rate = 1 - valid/sample (corner points that clip out of the
        // track box); avg_jaw_diff = mean |L_y-R_y| over both-valid frames
        // (jaw/cheek wobble). Data for BATCH_4 jaw-filter thresholds.
        const avg_jaw = if (self.jaw_diff_cnt > 0) self.jaw_diff_sum / @as(f64, @floatFromInt(self.jaw_diff_cnt)) else 0.0;
        log.info("point {d}: cal quality valid={d}/{d} eye_loss_rate={d:.3} avg_jaw_diff={d:.4}", .{
            idx, self.valid_count, self.sample_count, loss_rate, avg_jaw,
        });
        log.info("point {d}: gaze=({d:.3},{d:.3}) eye=({d:.1},{d:.1},{d:.1}) [{d}/{d} valid]", .{
            idx, self.result_gaze[idx][0], self.result_gaze[idx][1],
            self.result_eye[idx][0], self.result_eye[idx][1], self.result_eye[idx][2],
            self.valid_count, self.sample_count,
        });
        // BATCH_2: per-eye ratio log — single-eye points flagged for offset analysis.
        const total_eye_frames = self.left_eye_frames + self.right_eye_frames;
        if (total_eye_frames > 0) {
            const l_ratio = @as(f64, @floatFromInt(self.left_eye_frames)) / @as(f64, @floatFromInt(total_eye_frames));
            log.info("point {d}: left_ratio={d:.3} (L={d} R={d})", .{
                idx, l_ratio, self.left_eye_frames, self.right_eye_frames,
            });
        }

        self.current_point += 1;
        self.sample_count = 0;
        self.gaze_x_sum = 0;
        self.gaze_y_sum = 0;
        self.eye_x_sum = 0;
        self.eye_y_sum = 0;
        self.eye_z_sum = 0;
        self.valid_count = 0;
        self.jaw_diff_sum = 0;
        self.jaw_diff_cnt = 0;
        self.left_eye_frames = 0;
        self.right_eye_frames = 0;
        self.settle_remaining = 0;

        if (self.current_point >= NUM_CAL_POINTS) {
            return .finished; // all points done
        }

        self.state = .showing_point;
        log.info("look at {s}", .{CALIBRATION_POINTS[self.current_point].label});
        return .next_point;
    }

    /// Compute the display area from calibration results.
    /// Uses the eye positions at each calibration point to estimate screen geometry.
    pub fn computeDisplayArea(self: *const Calibrator, screen_w_mm: f64, screen_h_mm: f64) DisplayAreaResult {
        // Simple approach: use the average eye position as the sensor location,
        // and compute the display area offsets from the calibration points.
        //
        // For each point we have:
        //   - screen position (normalized [0,1])
        //   - average eye position in tracker space (3D mm)
        //
        // The display area is defined by:
        //   - w_mm, h_mm (from EDID)
        //   - ox_mm, oy_mm (bottom-left corner in tracker coords)
        //   - z_mm (perpendicular distance from sensor to display plane)

        // Average eye position across all calibration points → sensor location estimate.
        var eye_avg: [3]f64 = .{ 0, 0, 0 };
        for (self.result_eye) |e| {
            eye_avg[0] += e[0];
            eye_avg[1] += e[1];
            eye_avg[2] += e[2];
        }
        const n_points = @as(f64, @floatFromInt(NUM_CAL_POINTS));
        eye_avg[0] /= n_points;
        eye_avg[1] /= n_points;
        eye_avg[2] /= n_points;

        // The display area center should be at (0, 0, z_mm) in tracker coords
        // relative to the sensor. The sensor is below the screen center.
        // z_mm is the average Z distance from eye to screen plane.
        const z_mm = eye_avg[2]; // average eye z ≈ distance to screen

        // Origin: bottom-left corner of the display area.
        // For a centered sensor: ox = -w/2, oy = -(h/2 + offset)
        const half_w = screen_w_mm / 2.0;
        const half_h = screen_h_mm / 2.0;

        // NOTE: eye-origin z is tracker-space (~400–900 mm viewing distance),
        // NOT sensor→screen-plane distance. v0.2.1 tested the "plane geometry
        // mismatch" hypothesis against the 11-point error map and FALSIFIED it:
        // no eye position + plane (z0, tilt) explains the device readings
        // (concurrency fit residual 44–85 mm on the reliable points; the
        // only y-consistent solutions put the eye at z≈90 mm). The device's
        // gaze-y estimation itself is biased (grows with elevation; top 31%
        // of the screen unreadable). The fitted correction lives in the
        // bridge preset (gaze_y_offset / gaze_y_scale) — the plane stays at
        // the verified clip-mount default. Keep z_used's band guard below.
        const z_used = if (z_mm > 10 and z_mm < 200) z_mm else 65;
        if (z_used != z_mm) {
            log.info("eye z {d:.0}mm outside display-plane band — using clip-mount default 65mm", .{z_mm});
        }

        return .{
            .w_mm = screen_w_mm,
            .h_mm = screen_h_mm,
            .ox_mm = -half_w,
            .oy_mm = -half_h - 10, // sensor ~10mm below bottom edge
            .z_mm = z_used,
            .tilt_deg = 12, // typical for clip-mount
        };
    }
};

pub const DisplayAreaResult = struct {
    w_mm: f64,
    h_mm: f64,
    ox_mm: f64,
    oy_mm: f64,
    z_mm: f64,
    tilt_deg: f64,
};

// ─── v0.2.6: affine auto-fit from calibration results ────────────────

/// Fitted gaze correction: physical = (device + offset) / scale, per axis.
/// Persisted to ~/.config/tobiifree-opentrack/calibration.json and overlaid
/// onto whichever preset is active (see main.zig applyCalFit).
pub const AffineFit = struct {
    gaze_x_offset: f64 = 0.0,
    gaze_x_scale: f64 = 1.0,
    gaze_y_offset: f64 = 0.0,
    gaze_y_scale: f64 = 1.0,
};

/// Least-squares linear fit of device reading vs known physical position for
/// one axis: device ≈ a·physical + b  →  physical = (device − b)/a.
fn fitAxis(points: []const [2]f64) ?struct { scale: f64, offset: f64 } {
    const n: f64 = @floatFromInt(points.len);
    if (points.len < 2) return null;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    for (points) |pt| {
        sx += pt[0];
        sy += pt[1];
        sxx += pt[0] * pt[0];
        sxy += pt[0] * pt[1];
    }
    const denom = n * sxx - sx * sx;
    if (!std.math.isFinite(denom) or @abs(denom) < 1e-9) return null;
    const a = (n * sxy - sx * sy) / denom; // scale
    const b = (sy - a * sx) / n; // intercept
    // Guards: degenerate fits keep identity so the pipeline never divides by
    // ~0 or flips an axis from garbage data. A NEGATIVE scale would flip the
    // axis (top↔bottom / left↔right), which is never correct for a gaze map.
    if (!std.math.isFinite(a) or !std.math.isFinite(b)) return null;
    if (a <= 0.1 or a > 100.0) return null;
    return .{ .scale = a, .offset = -b };
}

/// Fit the affine correction that maps averaged device gaze coords (captured
/// at the 5 wizard points) to physical screen coords.
///
/// Fit the affine correction that maps averaged device gaze coords (captured
/// at the 5 wizard points) to physical screen coords.
///
/// The pipeline/bridge compute, per axis (single shared helper core.deviceToGui):
///   pre = transform(raw_device)          (== GUI coord when device is perfect)
///     X: pre_x = (raw_x − (0.5 − 0.5/f)) · f
///     Y: pre_y = (raw_y − (0.5 − 0.5/f)) · f   (screen CENTERED in box; NOT inverted)
///   gui = (pre + offset) / scale         ← what we fit here
///
/// So each calibration point contributes the pair {known_gui, pre}, and the
/// least-squares line pre ≈ a·gui + b gives scale=a, offset=−b. Perfect data
/// yields a=1, b=0 (identity). Returns null (keep identity) on degenerate data.
pub fn fitAffine(result_gaze: [NUM_CAL_POINTS][2]f64, factor: f64) ?AffineFit {
    const f = if (factor >= 1.0) factor else return null;
    var xs: [NUM_CAL_POINTS][2]f64 = undefined; // {gui_x, pre_x}
    var ys: [NUM_CAL_POINTS][2]f64 = undefined; // {gui_y, pre_y}
    for (CALIBRATION_POINTS, result_gaze, 0..) |cp, gz, i| {
        if (!std.math.isFinite(gz[0]) or !std.math.isFinite(gz[1])) return null;
        const pre = core.deviceToGui(gz, f);
        xs[i] = .{ cp.x, pre[0] };
        ys[i] = .{ cp.y, pre[1] };
    }
    const fx = fitAxis(&xs) orelse return null;
    const fy = fitAxis(&ys) orelse return null;
    return .{
        .gaze_x_offset = fx.offset,
        .gaze_x_scale = fx.scale,
        .gaze_y_offset = fy.offset,
        .gaze_y_scale = fy.scale,
    };
}
