const std = @import("std");
const proto = @import("daemon_protocol");

const log = std.log.scoped(.calibration);

pub const CalState = enum {
    idle,
    showing_point,
    capturing,
    waiting_response,
    done,
    error_state,
};

pub const CalPoint = struct {
    x: f64, // normalized [0,1] screen position
    y: f64,
    label: []const u8,
};

pub const CALIBRATION_POINTS = [_]CalPoint{
    .{ .x = 0.5, .y = 0.5, .label = "Center" },
    .{ .x = 0.15, .y = 0.15, .label = "Top-Left" },
    .{ .x = 0.85, .y = 0.15, .label = "Top-Right" },
    .{ .x = 0.05, .y = 0.95, .label = "Bottom-Left" },
    .{ .x = 0.95, .y = 0.95, .label = "Bottom-Right" },
};

pub const NUM_CAL_POINTS = CALIBRATION_POINTS.len;
pub const SAMPLES_PER_POINT = 180; // ~3 seconds at 60Hz — longer window for corner re-acquire

/// Capture quality gates: below this many valid frames the attempt is thrown
/// away and the SAME point is retried (eyes often clip out of tracking range
/// at extreme corners). After MAX_POINT_RETRIES weak attempts the run fails.
pub const MIN_VALID_PER_POINT = 15;
pub const MAX_POINT_RETRIES = 3;

pub const Calibrator = struct {
    state: CalState = .idle,
    current_point: usize = 0,
    sample_count: usize = 0,

    // Accumulated gaze samples for current point.
    gaze_x_sum: f64 = 0,
    gaze_y_sum: f64 = 0,
    eye_x_sum: f64 = 0,
    eye_y_sum: f64 = 0,
    eye_z_sum: f64 = 0,
    valid_count: usize = 0,

    // Results: averaged gaze at each calibration point.
    result_gaze: [NUM_CAL_POINTS][2]f64 = undefined,
    result_eye: [NUM_CAL_POINTS][3]f64 = undefined,

    // Pending response callback state.
    pending_cmd: ?u8 = null,

    /// Weak-capture retry counter for the CURRENT point (reset on success).
    retries: usize = 0,

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
    }

    pub fn cancel(self: *Calibrator) void {
        self.state = .idle;
        self.current_point = 0;
        log.info("calibration cancelled", .{});
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

/// Returns true if the per-eye 2D gaze coordinates are plausible (not the
/// device's −1.0/−1.0 no-tracking sentinel, not the zero-vector (0,0) used
/// when validity=4). The device emits −1.0/−1.0 for untracked eyes and (0,0)
/// when validity=4. At screen edges coords legitimately exceed [0,1] (looking
/// above/below screen), so we only reject sentinel/zero and accept any finite.
fn eye2dPlausible(px: f64, py: f64) bool {
    return !(px == -1.0 and py == -1.0) and !(px == 0.0 and py == 0.0) and std.math.isFinite(px) and std.math.isFinite(py);
}

/// Feed a gaze sample during capturing. One valid eye is enough for
/// calibration (clip-mounted trackers frequently lose one eye at extreme
/// angles). Returns true once SAMPLES_PER_POINT frames have arrived.
pub fn feedSample(self: *Calibrator, sample: *const proto.GazeSample) bool {
    if (self.state != .capturing) return false;

    // Accept any sample where at least ONE eye is tracked (by validity flag
    // or by plausible per-eye 2D coords — fixes corner false-negatives).
    const l_plausible = eye2dPlausible(sample.gaze_point_2d_L_norm[0], sample.gaze_point_2d_L_norm[1]);
    const r_plausible = eye2dPlausible(sample.gaze_point_2d_R_norm[0], sample.gaze_point_2d_R_norm[1]);
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
            } else if (l_ok) {
                self.gaze_x_sum += sample.gaze_point_2d_L_norm[0];
                self.gaze_y_sum += sample.gaze_point_2d_L_norm[1];
                self.eye_x_sum += sample.eye_origin_L_mm[0];
                self.eye_y_sum += sample.eye_origin_L_mm[1];
                self.eye_z_sum += sample.eye_origin_L_mm[2];
            } else {
                self.gaze_x_sum += sample.gaze_point_2d_R_norm[0];
                self.gaze_y_sum += sample.gaze_point_2d_R_norm[1];
                self.eye_x_sum += sample.eye_origin_R_mm[0];
                self.eye_y_sum += sample.eye_origin_R_mm[1];
                self.eye_z_sum += sample.eye_origin_R_mm[2];
            }
            self.valid_count += 1;
        }
        self.sample_count += 1;

        return self.sample_count >= SAMPLES_PER_POINT;
    }

    pub const PointOutcome = enum { next_point, retry, finished, failed };

    /// Finalize capture for current point. Weak attempts (too few valid
    /// frames) stay on the SAME point for a retry instead of poisoning the
    /// result; only exhausting all retries fails the run.
    pub fn finalizePoint(self: *Calibrator) PointOutcome {
        const idx = self.current_point;
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
        const n = @as(f64, @floatFromInt(self.valid_count));
        self.result_gaze[idx] = .{ self.gaze_x_sum / n, self.gaze_y_sum / n };
        self.result_eye[idx] = .{ self.eye_x_sum / n, self.eye_y_sum / n, self.eye_z_sum / n };
        self.retries = 0;
        log.info("point {d}: gaze=({d:.3},{d:.3}) eye=({d:.1},{d:.1},{d:.1}) [{d}/{d} valid]", .{
            idx, self.result_gaze[idx][0], self.result_gaze[idx][1],
            self.result_eye[idx][0], self.result_eye[idx][1], self.result_eye[idx][2],
            self.valid_count, self.sample_count,
        });

        self.current_point += 1;
        self.sample_count = 0;
        self.gaze_x_sum = 0;
        self.gaze_y_sum = 0;
        self.eye_x_sum = 0;
        self.eye_y_sum = 0;
        self.eye_z_sum = 0;
        self.valid_count = 0;

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
