// bridge_tests.zig — v0.2.7 BATCH_1 unit tests for the bridge filtering
// pipeline (tobii_filter.zig) and calibration (calibration.zig).
//
// The driver test target only covers tobiifree_core.zig protocol/parsing;
// this is the FIRST bridge test target and it covers what the driver tests
// cannot: the TobiiPipeline validity gate, the n=1↔n=2 debounce, and the n=1
// pitch stability under mm-scale single-eye Y wobble.
//
// Run with:  cd applications/tobiifree-opentrack && zig build test
// (or via just check, which runs both driver + bridge tests)

const std = @import("std");
const core = @import("tobiifree_core");
const filter = @import("tobii_filter");
const calibration = @import("calibration");

/// Build a synthetic gaze sample at the default centered pose (both eyes
/// level, IPD 65 mm, viewing distance 700 mm, gaze at screen center).
fn makeSample() core.GazeSample {
    return .{
        .present_mask = 0,
        .frame_counter = 0,
        .validity_L = 0,
        .validity_R = 0,
        .timestamp_us = 0,
        .pupil_L_mm = -1,
        .pupil_R_mm = -1,
        .gaze_point_2d_norm = .{ 0.5, 0.5 },
        .gaze_point_2d_L_norm = .{ 0.5, 0.5 },
        .gaze_point_2d_R_norm = .{ 0.5, 0.5 },
        .eye_origin_L_mm = .{ -32.5, 0, 700 },
        .eye_origin_R_mm = .{ 32.5, 0, 700 },
        .trackbox_eye_pos_L = .{ 0, 0, 0 },
        .trackbox_eye_pos_R = .{ 0, 0, 0 },
        .gaze_point_3d_L_mm = .{ 0, 0, 0 },
        .gaze_point_3d_R_mm = .{ 0, 0, 0 },
        .eye_origin_L_display_mm = .{ 0, 0, 0 },
        .eye_origin_R_display_mm = .{ 0, 0, 0 },
        .trackbox_eye_pos_L_display = .{ 0, 0, 0 },
        .trackbox_eye_pos_R_display = .{ 0, 0, 0 },
        .eye_origin_raw_L_mm = .{ 0, 0, 0 },
        .eye_origin_raw_R_mm = .{ 0, 0, 0 },
        .gaze_point_2d_unfiltered = .{ 0.5, 0.5 },
    };
}

const dt_90: f64 = 1.0 / 90.0;
const ts_step: i64 = @intFromFloat(dt_90 * 1e6);

/// Rotate both eyes around a neck pivot at (0,0,570) by `deg` yaw. Keeps the
/// interocular distance ~65 mm (a REAL head turn) so the pipeline's IPD gate
/// (45-80 mm) passes and rot_both stays engaged — unlike a naive lateral+depth
/// shift that blows the IPD up to 100 mm and drops into the n=1 fallback.
fn pivotTurn(s: *core.GazeSample, deg: f64) void {
    const r = deg * std.math.pi / 180.0;
    const c = @cos(r);
    const si = @sin(r);
    s.eye_origin_L_mm = .{ -32.5 * c + 130.0 * si, 0, 570.0 + (32.5 * si + 130.0 * c) };
    s.eye_origin_R_mm = .{ 32.5 * c + 130.0 * si, 0, 570.0 + (-32.5 * si + 130.0 * c) };
}

/// Drive `frames` samples through the pipeline at ~90 Hz, mutating `s`
/// between frames via `mut`. Returns the last output pose.
fn drive(
    pipe: *filter.TobiiPipeline,
    s: *core.GazeSample,
    p: *const filter.Preset,
    frames: usize,
    mut: *const fn (*core.GazeSample, usize) void,
) [6]f64 {
    var out: [6]f64 = .{ 0, 0, 0, 0, 0, 0 };
    for (0..frames) |i| {
        mut(s, i);
        s.timestamp_us += ts_step;
        out = pipe.process(s, p, dt_90);
    }
    return out;
}

fn noop(_: *core.GazeSample, _: usize) void {}

test "BATCH_1a: validity gate holds n=2 while per-eye 2D is plausible" {
    // Root cause: the pipeline gated rotation on the 3D origin validity flag
    // only (tobii_filter.zig:672-673), so an origin-validity FLICKER dropped
    // the eye to n=1 even though the tracker still saw it (per-eye 2D
    // plausible, GUI dots still visible). The gate now accepts
    // "validity==0 OR eye2dPlausible(per-eye 2D)" (shared core helper), so
    // n=2 / rot_both is held and the turn keeps tracking.
    var pipe = filter.TobiiPipeline{};
    // Linear curve + head_gain 1.0: the output yaw tracks the interocular
    // angle 1:1, so the discriminator can't be saturated by the spline.
    const p = filter.Preset{ .curve_mode = 0, .head_gain = 1.0 };
    var s = makeSample();

    // Establish the reference at center (n=2, both eyes level).
    _ = drive(&pipe, &s, &p, 100, noop);

    // Ramp the head turn 0 → 25° over 40 frames (both eyes valid), then hold
    // 100 frames so the output converges on the turned pose.
    for (0..40) |i| {
        pivotTurn(&s, 25.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 100, noop); // converged at 25°

    // NOW continue the turn 25 → 40° while the LEFT eye's origin validity
    // flickers to 4 but its per-eye 2D projection stays plausible (origin
    // kept non-zero — the tracker still sees the eye). With the gate fix the
    // interocular keeps tracking and the yaw grows past 30°; without it the
    // eye would be n=1 and the view would stay frozen at the last-good ~25°
    // (gaze at center ⇒ no n=1 drift).
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ 0.6, 0.5 };
    var out: [6]f64 = undefined;
    var max_mag: f64 = 0;
    for (0..100) |i| {
        const deg = 25.0 + 15.0 * @as(f64, @floatFromInt(i)) / 100.0;
        pivotTurn(&s, deg);
        s.timestamp_us += ts_step;
        out = pipe.process(&s, &p, dt_90);
        if (@abs(out[3]) > max_mag) max_mag = @abs(out[3]);
    }
    try std.testing.expect(max_mag > 30.0);
}

test "BATCH_1b: debounce smooths 5 Hz n-flap at the corner" {
    // Synthetic alternating n=2/n=1 at 5 Hz (9 frames each at 90 Hz). Before
    // BATCH_1 every excursion re-armed last_good, re-captured the single-eye
    // anchor and — with the gaze pinned — ran the n=1 corner drift, so the
    // output wobbled with the flap. The debounce holds the debounced n=2 path
    // (pure pose hold) for < 6-frame excursions, so the UDP output stays put.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{};
    var s = makeSample();

    // Establish ref at center.
    _ = drive(&pipe, &s, &p, 100, noop);

    // Settle at the corner in full n=2: pivot turn to 25° + gaze pinned past
    // the corner threshold (device x=0.7 → physical 1.0 → 20° gaze yaw).
    for (0..40) |i| {
        pivotTurn(&s, 25.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 200, noop); // corner pose converged

    // 5 Hz alternation: 9 frames both eyes, 9 frames left eye genuinely lost.
    var last: [6]f64 = undefined;
    last = pipe.process(&s, &p, dt_90);
    s.timestamp_us += ts_step;
    var max_step_yaw: f64 = 0;
    var max_step_pitch: f64 = 0;
    for (0..400) |i| {
        var s2 = s;
        if ((i % 18) >= 9) {
            s2.validity_L = 4;
            s2.gaze_point_2d_L_norm = .{ -1, -1 }; // genuine loss sentinel
            s2.eye_origin_L_mm = .{ 0, 0, 0 };
        }
        s2.timestamp_us += ts_step;
        const out = pipe.process(&s2, &p, dt_90);
        const dy = @abs(out[3] - last[3]);
        const dp = @abs(out[4] - last[4]);
        if (dy > max_step_yaw) max_step_yaw = dy;
        if (dp > max_step_pitch) max_step_pitch = dp;
        last = out;
    }

    // Plan invariant: output yaw step <= 1 deg/frame during the flap. Pitch
    // must hold too (the n=1 anchor/settle churn used to bump it).
    try std.testing.expect(max_step_yaw <= 1.0);
    try std.testing.expect(max_step_pitch <= 1.0);
}

test "BATCH_1c: n=1 pitch stable under mm-scale single-eye Y wobble" {
    // During a genuine n=1 episode the remaining (far) eye's raw Y carries
    // mm-scale jaw/cheek wobble at corners. BATCH_1 low-passes the single-eye
    // Y (alpha 0.06 — at 90 Hz the draft's 0.3 was measured useless for the
    // 2-5 Hz jaw band: EWMA cutoff ~5.1 Hz, gain 0.86 at 3 Hz), anchors the
    // settle window to the wobble MEAN (no DC step at settle-end), and keeps
    // the 1.0 s settle hold, so the pitch oscillation stays under the 2°
    // invariant even when the raw Y oscillates ±3 mm at 3 Hz.
    // The single-eye Y baseline is offset so n1_pitch sits in the response
    // curve's linear region (~5° input) — where a 3 mm wobble would otherwise
    // be amplified into a visible pitch bounce.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{};
    var s = makeSample();

    // Establish ref at center (n=2).
    _ = drive(&pipe, &s, &p, 100, noop);

    // Genuine n=1: left eye lost, right eye keeps tracking with a Y baseline
    // offset of +11.4 mm (→ atan(11.4/130) ≈ 5° pitch input) plus ±3 mm at 3 Hz.
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ -1, -1 };
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    s.eye_origin_R_mm = .{ 32.5, 11.4, 700 };

    var out: [6]f64 = undefined;
    for (0..180) |i| {
        const t = @as(f64, @floatFromInt(i)) * dt_90;
        s.eye_origin_R_mm[1] = 11.4 + 3.0 * @sin(2.0 * std.math.pi * 3.0 * t);
        s.timestamp_us += ts_step;
        out = pipe.process(&s, &p, dt_90);
    }
    // Past the 1.0 s settle hold: measure pitch variation over the last second.
    var min_pitch: f64 = 1e9;
    var max_pitch: f64 = -1e9;
    for (0..90) |i| {
        const t = @as(f64, @floatFromInt(i)) * dt_90;
        s.eye_origin_R_mm[1] = 11.4 + 3.0 * @sin(2.0 * std.math.pi * 3.0 * t);
        s.timestamp_us += ts_step;
        out = pipe.process(&s, &p, dt_90);
        if (out[4] < min_pitch) min_pitch = out[4];
        if (out[4] > max_pitch) max_pitch = out[4];
    }
    const spread = max_pitch - min_pitch;
    try std.testing.expect(spread <= 2.0);
}

test "BATCH_1d: calibration accepts a flickering-validity eye via 2D plausibility" {
    // Regression guard for the shared predicate: calibration.feedSample must
    // still accept a corner sample where the origin-validity flag says 4 but
    // the per-eye 2D projection is plausible (corner false-negative fix that
    // BATCH_1 lifted into the shared core helper must not regress).
    var cal = calibration.Calibrator{};
    cal.state = .capturing;
    var s = makeSample();
    s.validity_L = 4;
    s.validity_R = 0;
    s.gaze_point_2d_L_norm = .{ -1, -1 }; // left truly lost
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    s.gaze_point_2d_R_norm = .{ 0.85, 0.85 }; // right eye at BL corner
    const done = cal.feedSample(&s);
    try std.testing.expect(cal.valid_count == 1);
    try std.testing.expect(!done);
}

test "BATCH_1e: n=1 gaze collapse must not move the held pose" {
    // v0.2.7 real-device regression: at the corner, when one eye is lost, the
    // device's COMBINED gaze_point_2d_norm collapses toward screen center even
    // though the user still stares at the corner (measured live: gaze_yaw
    // swings -1 -> +6 deg mid-hold). The eye-ratio ramp reads that collapse as
    // "core zone" (ratio jumps to eye_ratio_core=0.80) and the gaze tug chases
    // the collapsing signal -> +/-5 deg output swings on a pose that is
    // otherwise HELD. Fix: freeze the FILTERED gaze at the last n=2 value for
    // the n=1 episode, so the ratio AND the tug both hold still.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{};
    var s = makeSample();

    // Establish ref at center (n=2).
    _ = drive(&pipe, &s, &p, 100, noop);

    // Settle at the corner in n=2: pivot turn to 25°, gaze pinned at the
    // screen edge (device x=0.7 -> physical ~1.0 -> large gaze_dev).
    for (0..40) |i| {
        pivotTurn(&s, 25.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 200, noop); // corner pose + gaze EWMA converged

    // n=1 episode with the GAZE COLLAPSING to center (the device behavior):
    // left eye genuinely lost, combined gaze slides 0.7 -> 0.5 over 30 frames
    // and stays there. The pose must not move: yaw AND pitch stay within the
    // invariant even though the raw gaze wanders through the whole screen.
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ -1, -1 };
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    var last: [6]f64 = pipe.process(&s, &p, dt_90);
    s.timestamp_us += ts_step;
    var max_step_yaw: f64 = 0;
    var max_step_pitch: f64 = 0;
    for (0..200) |i| {
        // Collapse the combined gaze toward center over the first 30 frames.
        const gx = 0.7 - 0.2 * @min(@as(f64, @floatFromInt(i)) / 30.0, 1.0);
        s.gaze_point_2d_norm = .{ gx, 0.5 };
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        const dy = @abs(out[3] - last[3]);
        const dp = @abs(out[4] - last[4]);
        if (dy > max_step_yaw) max_step_yaw = dy;
        if (dp > max_step_pitch) max_step_pitch = dp;
        last = out;
    }
    try std.testing.expect(max_step_yaw <= 1.0);
    try std.testing.expect(max_step_pitch <= 1.0);
}

/// Rotate ONLY the right eye around the neck pivot (left eye already lost —
/// keep the REMAINING eye at its turned pose / keep translating during n=1).
fn pivotTurnR(s: *core.GazeSample, deg: f64) void {
    const r = deg * std.math.pi / 180.0;
    const c = @cos(r);
    const si = @sin(r);
    s.eye_origin_R_mm = .{ 32.5 * c + 130.0 * si, 0, 570.0 + (-32.5 * si + 130.0 * c) };
}

test "BATCH_2a: n=1 corner drift recovers >= 85% of the equivalent turn" {
    // BATCH_2 invariant: the n=1 corner drift must CONTINUE the turn toward
    // the screen edge while the remaining eye keeps translating (the head is
    // still turning; the near eye is occluded). dbg6 (tobii preset) measured
    // the OLD sign-inverted drift SAGGING 132° -> 69°; the corrected
    // outward-only drift must reach >= 85% of the equivalent full interocular
    // turn within 2s.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{ .curve_mode = 0, .head_gain = 1.0 };
    var s = makeSample();

    _ = drive(&pipe, &s, &p, 100, noop); // ref at center

    // Full-turn reference (n=2, both eyes, 0 -> 25°). Gaze at CENTER so the
    // corner hold does NOT engage: with v4.6's n=2 corner reach, a pinned
    // gaze would extend the held peak past the pure interocular turn and
    // inflate the reference (the reach is a corner-EDGE behavior; the drift
    // comparison below is against the equivalent HEAD turn).
    for (0..40) |i| {
        pivotTurn(&s, 25.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.5, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.5, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.5, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 200, noop);
    const full_turn = @abs(pipe.last_out[3]);

    // Fresh pipeline for the one-eye scenario: re-settle at center so the
    // n=1 episode starts from a MID-turn pose (not the already-converged 25°).
    pipe.reset();
    s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // n=2 pivot to 15° (the pre-occlusion turn), gaze pinned at the edge.
    for (0..40) |i| {
        pivotTurn(&s, 15.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.3, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.3, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.3, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 100, noop); // converged at 15°

    // One-eye: left genuinely lost, RIGHT eye keeps translating 15° -> 25° over
    // ~2 s (the head keeps turning into the corner while the near eye stays
    // occluded). Gaze stays pinned at the edge so the drift stays engaged and
    // the corner-hold witness tracks the deepening peak instead of fighting it.
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ -1, -1 };
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    for (0..180) |i| {
        const deg = 15.0 + 10.0 * @as(f64, @floatFromInt(i)) / 180.0;
        pivotTurnR(&s, deg);
        s.gaze_point_2d_norm = .{ 0.3, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    const n1_yaw = @abs(pipe.last_out[3]);
    try std.testing.expect(n1_yaw >= 0.85 * full_turn);
}

test "BATCH_2b: corner eye-ratio floor keeps the gaze tug at the edge" {
    // BATCH_2: at the corner the edge ramp would drop effective_eye_ratio to
    // 0.15 (the ±3° tug that let the view sag inward ~5-10%). With the
    // pinned-gaze floor the ratio must stay >= 0.35 so the tug keeps pulling.
    // The pipeline exposes the last effective ratio via `last_ratio`.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{};
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // Gaze pinned at the edge (device x=0.7 -> physical ~1.0 -> large gaze_dev
    // AND |gaze_yaw| > corner_engage_deg). n=2 throughout.
    for (0..40) |i| {
        pivotTurn(&s, 25.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 200, noop);
    try std.testing.expect(pipe.last_ratio >= 0.35);
}

test "BATCH_2c: near-center n=1 stays frozen (no drift, no tug)" {
    // BATCH_2 regression: the corner drift must NOT engage near center — a
    // single-eye lean/translation there would read as a fake turn (the
    // lean-crosstalk guard). With gaze at center (|gaze_yaw| < 6° disengage
    // threshold) and the left eye lost, the output yaw must stay put.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{ .curve_mode = 0, .head_gain = 1.0 };
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop); // center, n=2

    // One-eye at CENTER: left lost, right eye translates laterally 10mm
    // (a lean — would fake a turn if the drift wrongly engaged).
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ -1, -1 };
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    s.eye_origin_R_mm = .{ 32.5 + 10.0, 0, 700 };
    var last: [6]f64 = pipe.process(&s, &p, dt_90);
    s.timestamp_us += ts_step;
    var max_step: f64 = 0;
    for (0..100) |_| {
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        const d = @abs(out[3] - last[3]);
        if (d > max_step) max_step = d;
        last = out;
    }
    try std.testing.expect(max_step <= 0.5);
}

test "BATCH_2d: n=1 drift bounded at the n=2 occlusion turn + extra (no 90° creep)" {
    // BATCH_2 REWORK (user gate FAILED on the real device): while the user
    // HOLDS at the corner, the single-eye origin creeps outward and turn_est
    // grows — the old drift chased it to the output ceiling (~90° view swing
    // past the normal head/eye range). The anchor bound caps the drift at the
    // n=2 occlusion turn + n1_extra_max_deg (15° raw): even a RUNAWAY eye
    // origin (12° -> 45°, far past any real turn) must not push the pose past
    // the bound.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{ .curve_mode = 0, .head_gain = 1.0 };
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // n=2 pivot to 12° (the occlusion turn), gaze pinned at the edge.
    for (0..40) |i| {
        pivotTurn(&s, 12.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.3, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.3, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.3, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 100, noop);
    const anchor_raw = @abs(pipe.last_good_yaw); // ≈ 12

    // n=1 with a RUNAWAY eye origin: right eye keeps translating 12° -> 45°
    // over 3s (turn_est -12 -> -45) while the gaze stays pinned. The drift
    // must STOP at anchor - 15 (the bound), not chase to the ceiling.
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ -1, -1 };
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    for (0..270) |i| {
        pivotTurnR(&s, 12.0 + 33.0 * @as(f64, @floatFromInt(i)) / 270.0);
        s.gaze_point_2d_norm = .{ 0.3, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    const final_raw = @abs(pipe.last_good_yaw);
    // Bound: occlusion turn + 15° raw, small tolerance. NOT chased to the
    // runaway 45° target.
    try std.testing.expect(final_raw <= anchor_raw + 15.0 + 0.5);
    // Range recovery still works (the drift did extend the turn).
    try std.testing.expect(final_raw >= anchor_raw + 6.0);
    // The output pose is bounded too (monotonic raw -> output, linear curve).
    try std.testing.expect(@abs(pipe.last_out[3]) <= anchor_raw + 15.0 + 9.0);
}

test "BATCH_2e: upper-corner diagonal gaze engages the drift (radial gate)" {
    // BATCH_2 REWORK: the OLD yaw-only engage gate (|gaze_yaw| > 10°) never
    // fired at upper corners — a diagonal look has a small horizontal gaze
    // component (yaw ≈ -8°) even though the user is staring at the screen
    // corner ("upper left/right still not recognized"). The RADIAL gate (yaw
    // AND pitch) must engage and the drift must recover the range.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{ .curve_mode = 0, .head_gain = 1.0 };
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // n=2 pivot to 10° with the gaze at the UPPER-LEFT corner (diagonal).
    // Default Preset + track_box_factor 2.5: device 0.42/0.18 -> physical
    // 0.30/-0.30 -> gaze_yaw ≈ -8° (< the old 10° gate) but gaze_pitch ≈ +13°,
    // radial ≈ 15° (> 10°) — the radial gate is the deciding factor.
    for (0..40) |i| {
        pivotTurn(&s, 10.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.42, 0.18 };
        s.gaze_point_2d_L_norm = .{ 0.42, 0.18 };
        s.gaze_point_2d_R_norm = .{ 0.42, 0.18 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 100, noop);
    const anchor = @abs(pipe.last_good_yaw); // ≈ 10

    // n=1: left lost, right eye keeps translating 10° -> 22° (the head pushes
    // deeper into the upper corner). Gaze stays at the diagonal corner.
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ -1, -1 };
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    for (0..135) |i| {
        const deg = 10.0 + 12.0 * @as(f64, @floatFromInt(i)) / 135.0;
        pivotTurnR(&s, deg);
        s.gaze_point_2d_norm = .{ 0.42, 0.18 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    // The radial gate + gaze-dwell engaged: the drift extended the pose toward
    // the GAZE-ANCHORED target. v2 target = anchor + clamp(|gaze_yaw|*0.7,0,15);
    // gaze_yaw ≈ -8 (upper-left diagonal) -> extra ≈ 5.6 -> |yaw| ≈ anchor+5.6.
    // The drift engages (extends past the anchor) but the target is gaze-bounded
    // (STABLE while holding -> no creep), NOT the runaway translation.
    try std.testing.expect(@abs(pipe.last_good_yaw) >= anchor + 3.0);

    // Control: the SAME one-eye continuation but with the gaze at TOP-CENTER
    // (x=0.5, y=0.18 -> yaw 0, radial ≈ 13°) — |gaze_yaw| < 2 means the corner
    // gates must NOT engage (a pure up-look is not a corner), so the pose
    // stays frozen at the anchor despite the translating eye.
    var pipe2 = filter.TobiiPipeline{};
    var s2 = makeSample();
    _ = drive(&pipe2, &s2, &p, 100, noop);
    for (0..40) |i| {
        pivotTurn(&s2, 10.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s2.gaze_point_2d_norm = .{ 0.5, 0.18 };
        s2.gaze_point_2d_L_norm = .{ 0.5, 0.18 };
        s2.gaze_point_2d_R_norm = .{ 0.5, 0.18 };
        s2.timestamp_us += ts_step;
        _ = pipe2.process(&s2, &p, dt_90);
    }
    _ = drive(&pipe2, &s2, &p, 100, noop);
    s2.validity_L = 4;
    s2.gaze_point_2d_L_norm = .{ -1, -1 };
    s2.eye_origin_L_mm = .{ 0, 0, 0 };
    const ctrl_anchor = @abs(pipe2.last_good_yaw);
    for (0..135) |i| {
        const deg = 10.0 + 12.0 * @as(f64, @floatFromInt(i)) / 135.0;
        pivotTurnR(&s2, deg);
        s2.gaze_point_2d_norm = .{ 0.5, 0.18 };
        s2.timestamp_us += ts_step;
        _ = pipe2.process(&s2, &p, dt_90);
    }
    try std.testing.expect(@abs(pipe2.last_good_yaw) <= ctrl_anchor + 0.5);
}

test "BATCH_2f: flip_yaw=true (real rig) drift recovers AND stays bounded" {
    // BATCH_2 REWORK regression: the user's rig runs the tobii-official preset
    // (flip_yaw=true), where the raw-yaw side is the OPPOSITE of the gaze side.
    // dbg7 caught a flip-blind `side` that made the drift DEAD on flip=true
    // (output frozen at the n=2 anchor through a full 15->40 deg creep). This
    // test locks in the flip-aware direction: with flip=true + right-turn
    // geometry (raw negative, gaze 0.7 positive) the drift must (a) recover the
    // 15 -> 25 deg continuation AND (b) stop at the anchor bound when the eye
    // origin runs away to 45 deg.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{ .curve_mode = 0, .head_gain = 1.0, .flip_yaw = true };
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // Full-turn reference (n=2, both eyes, 0 -> 25°). Gaze at CENTER so the
    // corner hold does NOT engage — with v4.6's n=2 corner reach a pinned
    // gaze would extend the held peak past the pure interocular turn and
    // inflate the reference.
    for (0..40) |i| {
        pivotTurn(&s, 25.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.5, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.5, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.5, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 200, noop);
    const full_turn = @abs(pipe.last_out[3]); // ≈ 25 (flip mirrors, |out| same)

    // Fresh pipeline: n=2 to 15° (occlusion anchor), gaze pinned RIGHT.
    pipe.reset();
    s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);
    for (0..40) |i| {
        pivotTurn(&s, 15.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 100, noop);
    const anchor_raw = @abs(pipe.last_good_yaw); // ≈ 14.6

    // n=1: left lost, right eye translates 15 -> 25° (genuine continuation).
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ -1, -1 };
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    for (0..180) |i| {
        pivotTurnR(&s, 15.0 + 10.0 * @as(f64, @floatFromInt(i)) / 180.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    // (a) the flip-aware drift recovered >= 85% of the full turn.
    try std.testing.expect(@abs(pipe.last_out[3]) >= 0.85 * full_turn);

    // (b) then the eye origin RUNS AWAY 25 -> 45° over 2s (device drift while
    // the user holds): the anchor bound (anchor + 15 raw) must stop the pose.
    for (0..180) |i| {
        pivotTurnR(&s, 25.0 + 20.0 * @as(f64, @floatFromInt(i)) / 180.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    const final_raw = @abs(pipe.last_good_yaw);
    try std.testing.expect(final_raw <= anchor_raw + 15.0 + 0.5);
}

test "BATCH_2g: real-rig output-space drift cap (no 90+ deg overshoot at corners)" {
    // BATCH_2 REWORK v3 regression (user gate FAILED twice on the real rig):
    // the earlier raw-degree drift bound was tuned with head_gain=1.0 + linear
    // curve, but the user's tobii-official preset (head_gain=2.0 + Tobii spline
    // edge ~4x) amplified a raw ~8.5->13-15 drift into OUTPUT 124-145 deg
    // ("still have 90 deg overshoot on left/right"). This test runs the REAL
    // preset geometry and locks in the OUTPUT-space cap: the n=1 drift output
    // must stay at/under the natural corner edge (n1_drift_max_out_deg=95) even
    // with a deep pinned gaze, while still recovering range past the anchor.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{ .curve_mode = 2, .head_gain = 2.0, .flip_yaw = true, .max_yaw = 180.0 };
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // n=2 to 5° (occlusion anchor, output ~70° — well under the edge), gaze
    // pinned at the far edge (0.7 -> gaze_yaw ~20°, a realistic corner look).
    // flip=true: raw negative, gaze positive.
    for (0..40) |i| {
        pivotTurn(&s, 5.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 100, noop);

    // n=1: left lost, right eye keeps translating (the device creep) while the
    // gaze stays pinned hard at the corner — this was the exact real-device
    // condition that blew the output to 124-145 deg under the raw-only bound.
    // The raw gaze target wants lg -> anchor-15 (raw), which on this rig maps
    // to >130 deg output; the OUTPUT-space cap on the drift target must stop it
    // at the natural edge (~95 deg).
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ -1, -1 };
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    var max_fy: f64 = 0;
    for (0..270) |i| {
        pivotTurnR(&s, 5.0 + 20.0 * @as(f64, @floatFromInt(i)) / 270.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        if (@abs(out[3]) > max_fy) max_fy = @abs(out[3]);
    }
    // The OUTPUT must stay at/under the natural corner edge. The drift target
    // is capped at n1_drift_max_out_deg=95 (post-curve). BATCH_2 v4 (trace
    // 2026-08-30, 380 frames >95°): the residual creep to ~102° was the GAZE
    // TUG added post-cap (fy = fy_head + tug·er·ge; er pinned at the 0.35
    // corner floor, gate_eff ramps to 1.0 while holding) — v4 caps the tug to
    // the headroom below the edge, so the final output holds at ~95.
    // WITHOUT the output-space cap this reaches 124-145°; with v3 it was
    // ~100-102°; with v4 it is ~95.
    try std.testing.expect(max_fy <= 96.0);
    // But the drift still recovered range past the n=2 anchor (not frozen).
    try std.testing.expect(max_fy >= 80.0);
}

test "BATCH_2h: gaze-tug creep past the output edge is capped (v4)" {
    // BATCH_2 v4 regression (user gate "goes to normal, then expands again",
    // trace 2026-08-30): with the v3 output-space cap the DRIFT holds at 95°,
    // but the gaze TUG (corner ratio floor 0.35 × gate_eff→1.0 while holding)
    // added +7.7° post-cap → fy crept to 102.7° over ~0.5 s. This test pins
    // that exact condition: n=1 corner drift saturated at the output cap,
    // gaze still pinned hard, gate_eff fully armed — the final fy must not
    // exceed the natural edge (n1_drift_max_out_deg=95) by more than slack.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{ .curve_mode = 2, .head_gain = 2.0, .flip_yaw = true, .max_yaw = 180.0 };
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // n=2 to 5° anchor, gaze pinned at the edge.
    for (0..40) |i| {
        pivotTurn(&s, 5.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 100, noop);

    // n=1, right eye translating outward (device creep), gaze STAYS pinned.
    // Let the drift saturate to the output cap (95°), then keep holding the
    // corner for 3 more seconds so the tug gate fully re-arms — the v4 tug
    // cap must hold the output at the edge the whole time.
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ -1, -1 };
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    var max_fy: f64 = 0;
    var late_max: f64 = 0;
    for (0..450) |i| {
        pivotTurnR(&s, 5.0 + 20.0 * @as(f64, @floatFromInt(i)) / 270.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        if (@abs(out[3]) > max_fy) max_fy = @abs(out[3]);
        if (i >= 320 and @abs(out[3]) > late_max) late_max = @abs(out[3]); // fully held + gate armed
    }
    try std.testing.expect(max_fy <= 96.0);
    try std.testing.expect(late_max <= 96.0); // no creep once saturated + holding
    try std.testing.expect(max_fy >= 80.0); // still recovered the edge
}
test "BATCH_2g-x4: output-space drift cap stays exact on x4 preset (max_yaw=120)" {
    // BATCH_2.5 regression (plan-agent review 2026-08-30): invertCurve() was
    // only exact at cap=180 (tobii-official). The tobii branch compared the
    // output target DIRECTLY against the catmull pts table, but applyCurve
    // computes out = catmull(x)*cap/180 — so on x4/x4-smooth (max_yaw=120)
    // invertCurve(95) returned raw 18.67 whose REAL output is 95*120/180 =
    // 63.3 deg. The n=1 drift would UNDER-CAP and the view stops short of the
    // screen edge (~63° instead of the natural ~95° edge). With the cap-scale
    // fix (BATCH_2.5) invertCurve(95, cap=120) = raw 30.6 -> output 95.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{ .curve_mode = 2, .head_gain = 2.0, .flip_yaw = true, .max_yaw = 120.0 };
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // n=2 to 5° anchor (output ~40° at cap=120 — well under the edge), gaze
    // pinned at the far edge (realistic 0.7 corner look). flip=true: raw
    // negative, gaze positive.
    for (0..40) |i| {
        pivotTurn(&s, 5.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 100, noop);

    // n=1: left lost, right eye keeps translating (device creep) while gaze
    // stays pinned — the raw gaze target wants lg -> anchor-15 (raw), which at
    // cap=120 maps to >120 output; the OUTPUT-space cap must stop it at the
    // natural edge (~95°).
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ -1, -1 };
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    var max_fy: f64 = 0;
    for (0..270) |i| {
        pivotTurnR(&s, 5.0 + 20.0 * @as(f64, @floatFromInt(i)) / 270.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        if (@abs(out[3]) > max_fy) max_fy = @abs(out[3]);
    }
    // Fixed: drift caps at 95 (post-curve) + residual gaze tug -> ~100.
    // Buggy (BATCH_2.5 pre-fix): under-caps at ~63 -> max_fy <= ~70.
    try std.testing.expect(max_fy >= 88.0);
    try std.testing.expect(max_fy <= 105.0);
}

test "BATCH_2i: corner hold releases when the head returns (no release pop)" {
    // v4.2 regression (user gate 2026-08-30 + trace): the corner hold pinned
    // the view at the corner peak while the user's head swept back to center
    // (center X -63 -> +29 mm in the real trace; the interocular/rotation
    // signal is FROZEN during n=1 so it cannot witness the return, and the
    // gaze STAYED pinned at the edge the whole way). When the gaze finally
    // unpinned the hold released the stale peak in ONE frame -> up to +182°
    // output pop. Fix: the IPD-compensated center TRANSLATION is live in both
    // n=1 and n=2 — release (and latch) the hold when the center returns toward
    // the ref by corner_hold_release_mm from the engage position.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{};
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // Turn to the corner (25°, inter_yaw -25) with the gaze pinned at the left
    // edge -> the corner hold engages (gaze radial well past corner_pin_deg).
    for (0..40) |i| {
        pivotTurn(&s, 25.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.2, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.2, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.2, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 100, noop);
    try std.testing.expect(pipe.corner_hold);

    // Head returns to center over 60 frames BUT the gaze stays pinned at the
    // edge. The head-return witness (center translation back toward the ref)
    // must release the hold — the view sweeps back smoothly, no stale peak.
    var last: [6]f64 = pipe.last_out;
    var max_step: f64 = 0;
    for (0..60) |i| {
        pivotTurn(&s, 25.0 * (1.0 - @as(f64, @floatFromInt(i)) / 60.0));
        s.gaze_point_2d_norm = .{ 0.2, 0.5 }; // gaze STAYS at the edge
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        const dy = @abs(out[3] - last[3]);
        if (dy > max_step) max_step = dy;
        last = out;
    }
    try std.testing.expect(!pipe.corner_hold); // released while gaze still pinned
    try std.testing.expect(max_step <= 6.0); // swept back smoothly, no pop

    // NOW the gaze unpins (user stops staring at the edge) — still no pop.
    for (0..30) |_| {
        s.gaze_point_2d_norm = .{ 0.5, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.5, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.5, 0.5 };
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        const dy = @abs(out[3] - last[3]);
        if (dy > max_step) max_step = dy;
        last = out;
    }
    try std.testing.expect(max_step <= 6.0);
}

test "BATCH_2j: n1->n2 re-acquisition eases (no output pop)" {
    // v4.3 regression (trace 2026-08-30): 206 jumps >10° in a 3-min session,
    // ALL of them n1→n2 re-acquisitions. During n=1 the rotation freezes
    // while the head keeps turning; when both eyes return, the old re-arm
    // adopted the new interocular pose INSTANTLY, and the curve amplified the
    // raw step (up to 25° raw = 60-80° output in ONE frame). Fix: the re-arm
    // eases last_good_yaw toward the new pose at n1_catch_rate (35 °/s raw),
    // and the n=1 path follows the live center translation so the gap never
    // accumulates. This test locks in: a 15° raw re-acquisition must NOT pop
    // the output by more than a bounded per-frame step.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{ .curve_mode = 2, .head_gain = 2.0, .flip_yaw = true, .max_yaw = 180.0 };
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // n=2 at 0°, gaze center — settled.
    _ = drive(&pipe, &s, &p, 100, noop);

    // n=1: left eye lost, head holds still (gaze center, NOT a corner → the
    // corner drift does not run, so the view freezes).
    s.validity_L = 4;
    s.gaze_point_2d_L_norm = .{ -1, -1 };
    s.eye_origin_L_mm = .{ 0, 0, 0 };
    for (0..30) |_| {
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }

    // BOTH eyes return BUT the interocular pose has moved 15° raw (the head
    // genuinely turned during the occlusion — the re-acquisition pose). The
    // output must ease, not pop.
    s.validity_L = 0;
    s.gaze_point_2d_L_norm = .{ 0.5, 0.5 };
    s.eye_origin_L_mm = .{ -32.5, 0, 700 };
    const target_raw: f64 = 15.0;
    var last: [6]f64 = pipe.last_out;
    var max_step: f64 = 0;
    for (0..60) |i| {
        // Ramp the right eye (and later both) toward the turned pose so the
        // interocular delivers the new position gradually — but the FIRST
        // n=2 frame after the n=1 freeze delivers the full 15° at once.
        if (i == 0) {
            pivotTurn(&s, target_raw);
        } else {
            pivotTurn(&s, target_raw);
        }
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        const dy = @abs(out[3] - last[3]);
        if (dy > max_step) max_step = dy;
        last = out;
    }
    // The re-arm ease must prevent a single-frame pop: 15° raw with gain 2.0
    // + Tobii spline would be ~60-80° output in one frame without the fix.
    // With the catch-up (35°/s raw at 90Hz ≈ 0.39°/frame) the first step is
    // small. Allow 8°/frame output — the curve amplifies but the raw eases.
    try std.testing.expect(max_step <= 8.0);
    // And the view did eventually reach the new pose (caught up).
    try std.testing.expect(@abs(pipe.last_out[3]) > 20.0);
}

test "invertCurve: round-trips applyCurve for all curve modes and caps" {
    // BATCH_2.5 regression: invertCurve(out) must return the raw input that
    // applyCurve maps to `out` — for ANY cap, not just 180/90. Before the fix
    // the tobii branch compared the output target directly against the catmull
    // pts table (only exact at cap=180 yaw / 90 pitch); on x4 (max_yaw=120)
    // invertCurve(95) returned 18.67 raw whose real output is only 63.3 deg.
    const modes = [_]filter.CurveMode{ .linear, .power, .tobii };
    // Probe outputs must be REACHABLE: the tobii YAW table tops at 160 catmull
    // units -> max output = 160*cap/180 (~0.889*cap); probing out near cap on
    // a small cap would be unrepresentable and is not a real drift target.
    const caps = [_]f64{ 180.0, 120.0, 95.0 };
    const outs = [_]f64{ 20.0, 45.0, 70.0 };
    for (modes) |m| {
        for (caps) |cap| {
            for (outs) |out| {
                if (out > cap) continue;
                if (m == .tobii and out > 0.88 * cap) continue;
                const raw = filter.invertCurve(m, out, cap, 0.5, false);
                const back = @abs(filter.applyCurve(m, raw, cap, 0.5, false));
                // Catmull lerp of a convex segment is exact on the knots and
                // within ~1-2 deg in between; spline mid-segment curvature is
                // small on these point sets, so 2 deg slack is safe.
                try std.testing.expectApproxEqAbs(out, back, 2.0);
            }
        }
    }
}

test "invertCurve: monotonic increasing for tobii yaw (x4 max_yaw=120)" {
    // The x4 preset (cap=120) must NOT under-cap the drift: invertCurve(95)
    // must be the raw input whose real output is 95 (not 63.3 as before the
    // BATCH_2.5 fix). 95 output on YAW_PTS {0,0},{4,30},{12,70},{20,100},
    // {35,160}: catmull_target = 95*180/120 = 142.5, bracketed by 100@20 and
    // 160@35 -> raw ≈ 20 + (142.5-100)*(35-20)/60 = 30.6. head_gain not
    // involved here (raw pre-gain).
    const raw = filter.invertCurve(.tobii, 95.0, 120.0, 0.5, false);
    try std.testing.expect(raw > 28.0 and raw < 33.0);
    const back = @abs(filter.applyCurve(.tobii, raw, 120.0, 0.5, false));
    try std.testing.expectApproxEqAbs(95.0, back, 1.0);
}

test "invertCurve: pitch branch scales by cap/90" {
    // PITCH_UP_PTS {0,0},{2,0},{10,25},{20,50}; applyCurve pitch = catmull*cap/90.
    // At cap=90: invert(25) -> 10 raw. At cap=45: catmull_target=25*90/45=50
    // -> last knot 50@20 -> 20 raw, whose real output = 50*45/90 = 25. Before
    // the fix cap=45 gave catmull_target=25 (between 0@2 and 25@10) -> ~9 raw
    // -> real output 4.5 deg (under-cap).
    const raw45 = filter.invertCurve(.tobii, 25.0, 45.0, 0.5, true);
    try std.testing.expectApproxEqAbs(20.0, raw45, 0.5);
    const back45 = @abs(filter.applyCurve(.tobii, raw45, 45.0, 0.5, true));
    try std.testing.expectApproxEqAbs(25.0, back45, 1.0);
    const raw90 = filter.invertCurve(.tobii, 25.0, 90.0, 0.5, true);
    try std.testing.expectApproxEqAbs(10.0, raw90, 0.5);
}

test "BATCH_2k: upper-corner hold survives a horizontal gaze dip (no release pop)" {
    // v4.5 regression (real-rig trace 2026-08-30 i=915-919): the corner-hold
    // WITNESS keyed the horizontal gaze guard at |gaze_yaw| > 4.0 while the
    // corner-ness is decided by the RADIAL gate (corner_pin_deg 12°). At a held
    // diagonal corner the horizontal gaze component is SMALL (gy -5.3 -> -3.4
    // while the user kept staring at the corner — the horizontal estimate
    // collapses toward center at the vertical extreme) and the guard dropped
    // below 4.0 -> the hold released and the view POPPED +6.75° in one frame.
    // v4.5 lowers the horizontal guard to 3.0: a held diagonal corner stays
    // held while the radial witness is still strong. A pure top-center look
    // (gy ≈ 0) must STILL not engage.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{};
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // Settle at the LEFT corner in n=2 with the gaze at the DIAGONAL corner
    // (device 0.42/0.18 -> phys 0.30/-0.30 -> gy ≈ -8°, gp ≈ +24°, radial ≈ 25).
    for (0..40) |i| {
        pivotTurn(&s, 15.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.42, 0.18 };
        s.gaze_point_2d_L_norm = .{ 0.42, 0.18 };
        s.gaze_point_2d_R_norm = .{ 0.42, 0.18 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 200, noop);
    try std.testing.expect(pipe.corner_hold);

    // Ramp the horizontal gaze from gy -8° toward -3.2° (device x 0.42 ->
    // 0.468; radial stays ~24° via the strong vertical gaze) and HOLD it long
    // enough for the gaze state filter (heavy fixation lock) to fully converge
    // past the old 4.0 guard. |gy| settles at ~3.2 — the hold must NOT release.
    // Head stays put at 15°.
    var last: [6]f64 = pipe.last_out;
    var max_step: f64 = 0;
    for (0..60) |i| {
        const gx = 0.42 + (0.468 - 0.42) * @as(f64, @floatFromInt(i)) / 60.0;
        s.gaze_point_2d_norm = .{ gx, 0.18 };
        s.gaze_point_2d_L_norm = .{ gx, 0.18 };
        s.gaze_point_2d_R_norm = .{ gx, 0.18 };
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        const dy = @abs(out[3] - last[3]);
        if (dy > max_step) max_step = dy;
        last = out;
    }
    for (0..200) |_| {
        s.gaze_point_2d_norm = .{ 0.468, 0.18 };
        s.gaze_point_2d_L_norm = .{ 0.468, 0.18 };
        s.gaze_point_2d_R_norm = .{ 0.468, 0.18 };
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        const dy = @abs(out[3] - last[3]);
        if (dy > max_step) max_step = dy;
        last = out;
    }
    try std.testing.expect(pipe.corner_hold); // held through the gy dip
    try std.testing.expect(max_step <= 1.0); // no release pop

    // Control: a TOP-CENTER look (device 0.5/0.18 -> gy 0, gp 24, radial 24)
    // is NOT a corner — the horizontal guard must keep the hold off.
    var pipe2 = filter.TobiiPipeline{};
    var s2 = makeSample();
    _ = drive(&pipe2, &s2, &p, 100, noop);
    for (0..40) |i| {
        pivotTurn(&s2, 15.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s2.gaze_point_2d_norm = .{ 0.5, 0.18 };
        s2.gaze_point_2d_L_norm = .{ 0.5, 0.18 };
        s2.gaze_point_2d_R_norm = .{ 0.5, 0.18 };
        s2.timestamp_us += ts_step;
        _ = pipe2.process(&s2, &p, dt_90);
    }
    _ = drive(&pipe2, &s2, &p, 200, noop);
    try std.testing.expect(!pipe2.corner_hold);
}

test "BATCH_2l: corner release eases from the HELD peak (sudden sag + head return, no pop)" {
    // v4.5 regression (real-rig trace 2026-08-30 i=236-243): the corner hold
    // froze the view at corner_peak while the interocular estimate sat EXACTLY
    // on the peak (yaw == peak, pin inactive — the pin only engages after the
    // sag EXCEEDS corner_hyst_deg). When the head then returned in ONE frame
    // (center -86 -> -79 mm) the old release started the ease from THIS
    // frame's already-sagged live yaw (ease = yaw = -10.79 vs the held -13.81)
    // and the output POPPED +12.6° in one frame. v4.5 starts the ease from
    // corner_peak whenever the live yaw is at-or-below the peak on the gaze
    // side (the value the output ACTUALLY held).
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{};
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // Turn to 6° with the gaze at CENTER (no hold) and settle, so the corner
    // hold engages AT the corner position (corner_hold_cenx = center X at 6° =
    // 130*sin(6°) ≈ 13.6 mm). At 6° the post-gain yaw is -12 (within the peak
    // cap) — the view is held AT the pinned peak, not in a deep past-cap turn.
    for (0..40) |i| {
        pivotTurn(&s, 6.0 * @as(f64, @floatFromInt(i)) / 40.0);
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 100, noop);

    // Gaze to the LEFT corner (device 0.2 -> gy ≈ -30°, radial ≈ 30) -> the
    // hold engages. Drive so yaw == corner_peak == -12 and the tug settles.
    for (0..120) |_| {
        s.gaze_point_2d_norm = .{ 0.2, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.2, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.2, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    try std.testing.expect(pipe.corner_hold);

    // ONE frame: the head sweeps 6° -> 0° (a 6° raw sag, center X returns
    // 13.6 mm -> head_returned fires) while the gaze STAYS pinned at the
    // corner. The release must ease from the held peak, not the sagged live.
    var last: [6]f64 = pipe.last_out;
    pivotTurn(&s, 0.0);
    s.timestamp_us += ts_step;
    const out = pipe.process(&s, &p, dt_90);
    const dy = @abs(out[3] - last[3]);
    // Output eases at ~60°/s from the peak (slope-scaled pre-curve step) plus
    // the gate fading the gaze tug (~1°/frame here) — bounded. The buggy
    // start-from-live-yaw popped ~12-14° in one frame (curve-amplified).
    try std.testing.expect(dy <= 3.0);
    try std.testing.expect(!pipe.corner_hold);

    // And the view keeps sweeping back smoothly over the following frames.
    var max_step: f64 = dy;
    for (0..30) |_| {
        s.timestamp_us += ts_step;
        const o2 = pipe.process(&s, &p, dt_90);
        const d2 = @abs(o2[3] - last[3]);
        if (d2 > max_step) max_step = d2;
        last = o2;
    }
    try std.testing.expect(max_step <= 3.0);
}

test "BATCH_2m: rotation-cross while gaze pinned releases with ease (no @449 pop)" {
    // v4.6 regression (real-rig trace @449): while the corner hold pins the
    // view at the peak (rw 43.45), the head-rotation ESTIMATE collapses toward
    // center at the tracking edge (hp sags +6.8 -> -1.93 -> -2.51 with the
    // gaze STILL pinned, gy +15). The same-side pin guard (yaw*gaze_side > 0)
    // hard-fails the moment the smoothed estimate crosses CENTER and the view
    // reverted to the live signal in ONE frame (fy 44.52 -> -1.67 = the
    // 46°/frame pop); the translation witness (back_mm) lags this fast return
    // so head_returned never fired. v4.6 releases like head_returned from
    // corner_held_yaw (the value the output actually held) — the view sweeps
    // back at the bounded rate instead of popping.
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{ .curve_mode = 2, .head_gain = 2.0, .flip_yaw = true, .max_yaw = 180.0 };
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // Turn to ~3.4° (post-gain +6.8, rw ~43 — the @449 hold position) with the
    // gaze pinned hard RIGHT (0.7 -> gy +20). The hold engages and the v4.6
    // reach glides corner_peak out to the natural edge.
    for (0..40) |i| {
        pivotTurn(&s, 3.4 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_L_norm = .{ 0.7, 0.5 };
        s.gaze_point_2d_R_norm = .{ 0.7, 0.5 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 200, noop);
    try std.testing.expect(pipe.corner_hold);
    try std.testing.expect(pipe.corner_held_yaw * pipe.corner_side > 0); // held on the gaze side

    // NOW the estimate COLLAPSES: the head sweeps back 3.4° -> -0.5° over 60
    // frames while the gaze STAYS pinned right. The smoothed yaw sinks through
    // center (the One-Euro lags the raw by ~15-20 frames, so the crossing lands
    // a few frames after the ramp); when it crosses <= 0 the same-side pin
    // guard hard-fails. Center-X return here is only ~8.8 mm (< the 12 mm
    // head-return witness) so head_returned does NOT fire — the rotation-cross
    // release must. Without it the held peak would pop to the live signal in
    // one frame.
    var last: [6]f64 = pipe.last_out;
    var max_step: f64 = 0;
    for (0..60) |i| {
        pivotTurn(&s, 3.4 * (1.0 - (3.9 / 3.4) * @as(f64, @floatFromInt(i)) / 60.0));
        s.gaze_point_2d_norm = .{ 0.7, 0.5 }; // gaze STAYS at the right edge
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        const dy = @abs(out[3] - last[3]);
        if (dy > max_step) max_step = dy;
        last = out;
    }
    // Hold the sagged pose: the smoothed yaw finishes crossing center and the
    // rotation-cross release fires + eases.
    for (0..60) |_| {
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        const dy = @abs(out[3] - last[3]);
        if (dy > max_step) max_step = dy;
        last = out;
    }
    // The cross happened (smoothed yaw crossed <= 0) and the hold released.
    try std.testing.expect(!pipe.corner_hold);
    // Buggy (v4.5): the pin hard-fails -> yaw reverts to live in ONE frame ->
    // fy pops ~90-98°. Fixed: ease from the held peak at 60°/s output.
    try std.testing.expect(max_step <= 3.0);

    // The sweep back stays smooth for the whole release.
    for (0..30) |_| {
        s.timestamp_us += ts_step;
        const o2 = pipe.process(&s, &p, dt_90);
        const d2 = @abs(o2[3] - last[3]);
        if (d2 > max_step) max_step = d2;
        last = o2;
    }
    try std.testing.expect(max_step <= 3.0);
}

test "BATCH_2n: n=2 eyes-only upper-corner look reaches the edge (UL reach gap)" {
    // v4.6 regression (user gate v4.5: "left upper rarely works", trace
    // @2858-2866): an eyes-only look at the upper-left corner with a SHALLOW
    // head turn (hp only -7.4..-9.8 post-gain) pinned the n=2 corner hold at a
    // mid-range peak — rw -54, fy -57, the view never got past ~60% of the
    // natural ~95° edge (right side reached fy 95 because the user turned the
    // head further there). The n=1 drift was the only gaze-anchored reach
    // mechanism; n=2 had none. v4.6 extends corner_peak toward the
    // gaze-anchored edge target (capped at the natural edge) so the view
    // glides to the edge and STOPS (no creep).
    var pipe = filter.TobiiPipeline{};
    const p = filter.Preset{ .curve_mode = 2, .head_gain = 2.0, .flip_yaw = true, .max_yaw = 180.0 };
    var s = makeSample();
    _ = drive(&pipe, &s, &p, 100, noop);

    // Shallow UL turn (raw -3.8 -> post-gain -7.6, rw ~48) + diagonal UL gaze
    // (device 0.35/0.18 -> gy -15, gp ~13, radial ~20) -> the hold engages
    // with both eyes tracked (n_eff==2 -> the n=2 reach must run).
    for (0..40) |i| {
        pivotTurn(&s, -3.8 * @as(f64, @floatFromInt(i)) / 40.0);
        s.gaze_point_2d_norm = .{ 0.35, 0.18 };
        s.gaze_point_2d_L_norm = .{ 0.35, 0.18 };
        s.gaze_point_2d_R_norm = .{ 0.35, 0.18 };
        s.timestamp_us += ts_step;
        _ = pipe.process(&s, &p, dt_90);
    }
    _ = drive(&pipe, &s, &p, 100, noop);
    try std.testing.expect(pipe.corner_hold);

    // Hold the eyes-only look ~3 s: the reach must glide the peak to the
    // natural edge (corner_peak -> -18.67) and the pin holds the output there.
    var max_fy: f64 = 0;
    for (0..270) |_| {
        s.timestamp_us += ts_step;
        const out = pipe.process(&s, &p, dt_90);
        if (@abs(out[3]) > max_fy) max_fy = @abs(out[3]);
    }
    // Buggy (v4.5): output froze at ~48-57 (no reach). Fixed: reaches the edge.
    try std.testing.expect(@abs(pipe.last_out[3]) >= 88.0);
    // And it STOPS at the natural edge — the same OUTPUT-space cap that ended
    // the 90° creep (a held gaze is stable, so the reach target stops moving).
    try std.testing.expect(max_fy <= 100.0);
    try std.testing.expect(pipe.corner_peak * -1.0 >= 17.0); // peak glided near the edge
}
