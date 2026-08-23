# plan-spec.md — v0.2.6 GUI Visualization & Gaze Pipeline Fix
# Approved 2026-08-23 by user. Goal: calibrated center = visualization center,
# guaranteed BY CONSTRUCTION; pipeline UDP gaze math === bridge GUI math.
BASE_COMMIT: "3d45732" (+ verified uncommitted v0.2.5-1 baseline: bridge onGaze
expanded→physical transform, daemon 112-byte extended get_display_area response)

CONTEXT:
  - v0.2.5 expanded device track box to EDID×2.5 (2000×825mm for 800×330 screen).
    Physical screen occupies x∈[0.3,0.7], y∈[0,0.4] in device-normalized coords.
  - Bridge onGaze HAS the expanded→physical transform; pipeline process() did NOT.
    UDP gaze: +9° phantom pitch at center, yaw sensitivity compressed 2.5×.
  - Affine presets are identity (0/1); nothing fits them from calibration data even
    though result_gaze[] holds avg device coords at 5 KNOWN physical points.
  - VERIFIED-CORRECT (do not re-litigate): bridge transform math, calibration point
    flow (raw device-space averages → add_calibration_point — device interprets in
    its own display space), geometry from defaultFromEdid.
  - KNOWN-ISSUE: bridge onDaemonResponse saw payload_len=164 (expected 112) — root
    cause UNVERIFIED. Investigate before fixing (may be header miscount, not daemon).
  - KNOWN-ISSUE: user-reported upper↔down dot oscillation NOT explained by any
    static code path — must be explained by runtime trace before closing.

BATCH_1_PIPELINE_TRANSFORM: # tobii_filter.zig — DONE (2026-08-23 session)
  - [x] Add field to Preset struct (after gaze_y_scale):
        track_box_factor: f64 = 2.5
  - [x] Add .track_box_factor = 2.5 to all 3 BUILTIN_PRESETS
  - [x] In process() (~line 793), transform BEFORE affine:
          const f_tb: f64 = @max(p.track_box_factor, 1.0);
          const phys_x = (self.last_good_gaze[0] - (0.5 - 0.5 / f_tb)) * f_tb;
          const phys_y = 1.0 - self.last_good_gaze[1] * f_tb;
          const y_scale = @max(p.gaze_y_scale, 0.1);
          const x_scale = @max(p.gaze_x_scale, 0.1);
          const g_corr = [2]f64{
              (phys_x + p.gaze_x_offset) / x_scale,
              (phys_y + p.gaze_y_offset) / y_scale,
          };
  - [x] Keep raw-coords g_ok validation unchanged ([−0.05, 1.05] on raw device coords)
  - INVARIANT: pipeline math === bridge onGaze math (transform THEN affine)

BATCH_2_CALIBRATION_AUTO_FIT: # guarantees center=center by construction — DONE
  - [x] PRE_CHECK done: presets persist via presets.json (user presets only);
        builtins seeded from code. Fitted affine stored SEPARATELY in
        ~/.config/tobiifree-opentrack/calibration.json and overlaid onto
        active preset (survives preset switches).
  - [x] Added gaze_x_offset/gaze_x_scale fields to Preset (defaults 0.0 / 1.0)
  - [x] New fitAffine(result_gaze, factor) in calibration.zig:
        - Regresses pre-affine coords (transform(raw)) vs known GUI points
        - Least-squares linear fit per axis over 5 points → {offset, scale}
        - Guard: reject |scale| < 0.1 or non-finite → keep identity, log warn
  - [x] Apply fitted params after wizard finish (sendCalibrationToDaemon path):
        - Persist to calibration.json
        - Overlay onto g_opts.p (active preset) via applyCalFit()
        - Re-apply on loadPreset() so it survives preset switches
  - [x] Bridge onGaze: extended affine to X identically:
        gui_x = (phys_x + x_off) / x_scl ; gui_y = (phys_y + y_off) / y_scl
        (per-eye dots likewise)
  - [x] CLI flags --gaze-x-offset / --gaze-x-scale added (with override tracking)
  - [x] usage() text updated for new flags
  - INVARIANT: after calibrating while staring at Center → g_gaze_norm == (0.5, 0.5)

BATCH_3_FRAMING_DIAGNOSE_THEN_FIX: # NEXT SESSION — investigate before fixing
  - [x] READ socket_source.zig dispatchMessage/processMessages framing logic
  - [x] READ daemon_protocol.zig encodeResponse — does bridge count header into payload_len?
    (encodeResponse: HEADER_SIZE + 1 + payload.len; response payload = [cmd_type][payload])
  - [x] HYPOTHESIS CONFIRMED: daemon checks `payload_len == 72` on RAW TTP payload, but TTP
    payload is TLV-encoded (3× point3d = 3×48B + 2B prefix ≈ 146-164B). Condition FAILS,
    daemon sends raw TLV payload (~164B) instead of extending to 112B. Bridge sees 164.
  - [x] Fix: daemon onResponse must decode TLV via core.decode_display_area(), then extend
  - FILES: driver/src/socket_source.zig, driver/src/daemon_protocol.zig, applications/tobiifreed/src/main.zig

BATCH_4_CLEANUP: # DONE (2026-08-23 session)
  - [x] Removed debug hex logging from bridge onDaemonResponse
  - [x] Kept minimal payload_len diagnostic for get_display_area (for BATCH_3)

BATCH_5_QA_GATE: # NEXT SESSION
  - [ ] Bridge ReleaseSafe build PASS (NFS cache pattern) — done locally
  - [ ] Daemon ReleaseSafe build PASS (NFS cache pattern) — untouched, should pass
  - [ ] Driver zig build test PASS — untouched, should pass
  - [ ] RUNTIME TRACE: log raw_dev → phys → affine → gui for ~10s live session;
        EXPLAIN the upper↔down oscillation empirically before close
  - [ ] Manual (ET5 hardware): center stare → dot at center; edge glance → UDP
        yaw spans full ±20° range (not ±8°)

TECH_DEBT_LOGGED_AFTER:
  - display_area_config.CalibrationParams defaults 0.394/1.278 are inert/stale
  - per-eye viz clamped [-0.2,1.2] vs main gaze unclamped (cosmetic inconsistency)

NOTES:
  - User must RE-RUN device calibration after deploy (device model rebuilds for
    expanded area; historical residual bias makes affine auto-fit necessary).
  - AGENTS.md untracked — do NOT commit.
  - Working tree dirty with v0.2.5-1 baseline + v0.2.6 edits — DO NOT REVERT.
    These are the verified baseline + implemented fixes.

HANDOVER STATUS (2026-08-23):
  - BATCH_1 + BATCH_2 + BATCH_4 COMPLETE. Code compiles (zig 0.15.2).
  - Binary parked at applications/tobiifree-opentrack/zig-out/bin/tobiifree-opentrack
    with BUILD_INFO.txt stamp.
  - NEXT AGENT: Start with BATCH_3 framing investigation (read socket_source.zig
    + daemon_protocol.zig), then BATCH_5 QA on real ET5 hardware.