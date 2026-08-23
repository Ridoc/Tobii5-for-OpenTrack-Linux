# plan-spec.md — v0.2.2 TobiiArgus E2E test session (daemon & bridge / GUI)
# Approved 2026-08-22 by user. Scope: full E2E with user at screen,
# install-icons first, wizard round-trip included (cal overwrite approved),
# UDP-listener target (X4 closed during capture).
BASE_COMMIT: "53342db"

BATCH_1_BUILD:
  - [x] QA gate: driver `zig build test` via test-scrubber.sh (must PASS)
  - [x] Build daemon ReleaseSafe -> applications/tobiifreed/zig-out/bin/tobiifreedot (+ BUILD_INFO.txt)
  - [x] Build bridge ReleaseSafe -> applications/tobiifree-opentrack/zig-out/bin/tobiifree-opentrack (+ BUILD_INFO.txt)
  NOTES: NFS quirk -> --cache-dir /tmp/zig-local-cache-v022-*; zig at /nix/store/9ljn49hx3a2lhha1anl3agivwb3z0ga1-zig-0.15.2/bin/zig; plain cp onto NAS is safe.

BATCH_2_ICONS:
  - [x] just install-icons; verify ~/.local/share/icons/hicolor/*/apps/tobiiargus.png + tobiiargus.desktop

BATCH_3_DAEMON:
  - [x] Clear stale daemon/socket (/run/user/1000/tobiifreedot/gaze.sock)
  - [x] Launch project-local tobiifreedot --force-display-area -> /tmp/opencode/daemon-v022.log
  - [x] Verify USB claim OK, plane corners TL(-400,313,134) TR(400,313,134) BL(-400,-10,65), socket up

BATCH_4_GUI:
  - [x] Launch bridge --port 4242 --verbose (rpath-resolved, no LD_LIBRARY_PATH needed)
  USER_CHECKLIST:
    - [x] Title "TobiiArgus — Tobii → OpenTrack"
    - [x] Argus icon in title bar + taskbar
    - [x] Pose readout live-updates; viz tracks user
    - [x] Sliders/presets respond + persist
    - [x] Calibrate button present

BATCH_5_UDP:
  - [x] Listener on 127.0.0.1:4242 (reuse /tmp/opencode/udp_listen.py), X4 CLOSED
  - [x] Eyes tracked -> packets flow; each exactly 48 B; sane yaw/pitch ranges
  - [x] Gaze spot-checks: center ~ (0.5,0.5) post-affine; bottom-edge corrected y

BATCH_6_WIZARD:
  - [x] Record md5 ~/.config/tobii.json (baseline 771f74bc78f424a327b7480df0dff7fee)
  - [x] Calibrate -> window "Calibration — TobiiArgus" + icon; 5-point pass w/ retry
  - [x] Clean teardown; blob onDaemonResponse -> cal_apply; tobii.json md5 updated (expected — new display area config)
  - [x] Post-cal UDP sanity, no pitch-pin regression
  NOTE: device calibration overwrite approved by user.
  FIXES_APPLIED: SAMPLES_PER_POINT 60->180 (longer capture window); cal points inset from 5% to 15% (top corners).

BATCH_7_LEDGER:
  - [x] .docs/tech-debt.yaml: close cal-apply-verify / wizard-qa-gate; log launcher PATH + cal-point-inset + viz-affine fixes
  - [x] .docs/release.yaml + session.yaml updated
  FOLLOWUP_SUGGESTION: "just install-local recipe automating build->copy->stamp"

FIXES_APPLIED_THIS_SESSION:
  - gaze-viz-affine-fix: visualization now applies y=(raw+0.394)/1.278 correction matching UDP output
  - emulated-note: GUI subtitle + README scope section clarifies headtracking is emulated via OpenTrack
  - cal-window-180: SAMPLES_PER_POINT 60->180 for corner re-acquire
  - cal-points-inset: top corners moved from 5% to 15% from edges
  - old-presets-deleted: ~/.config/tobiifree-opentrack/presets.json removed

# =====================================================================
# v0.2.4 — eye-viz validity fix + calibration progress UI + track-box investigation
# Approved 2026-08-23 by user (questions answered via /ask).
BASE_COMMIT: "75ce1a4"

BATCH_1_EYE_VALIDITY_GATE:
  - [x] eye2dPlausible helper (rejects −1.0/−1.0 sentinel AND (0,0) zero-vector; accepts finite) in main.zig + calibration.zig
  - [x] onGaze: g_eye_l_valid/R_valid = validity==0 OR per-eye 2D plausible; only update per-eye viz coords when plausible (keep last position when lost -> no jump to left edge)
  - [x] Calibrator.feedSample: combined per-eye plausibility gate (validity==0 OR plausible 2D)
  - [x] Bridge ReleaseSafe build PASS (NFS pattern); driver zig build test PASS

BATCH_2_CAL_PROGRESS_UI:
  - [x] Removed centered 'Capturing: n/180' above dot
  - [x] Green progress ring around dot (dot_r+6, lw 4, sweep=cap_n/SAMPLES_PER_POINT)
  - [x] Small counter at py+60 (14px, semi-transparent green)

BATCH_3_TRACK_BOX_INVESTIGATION:
  - [x] Daemon debug capture of 0x1d/0x1e/0x1f per-output 2D validity
  - [x] CONFIRMED: lost eye sends 2D=(0,0) AND per-output validity=0 (0x1e for R, 0x1d for L) — NO valid data for lost eye
  - [x] CONFIRMED: track box correctly configured (EDID 800x330mm == config); device tracks both eyes at y=1.39 some frames
  - [x] CONCLUSION: one-eye loss at edges = genuine ET5 FOV/track-box hardware limit; original 'jumps to left edge' code bug FIXED
  - [x] Driver debug logging removed (tobiifree_core.zig clean); daemon rebuilt ReleaseSafe

BATCH_4_LEDGER:
  - [x] .docs/tech-debt.yaml: cal-point-inset + viz-eye-validity-false-positive + cal-progress-ui resolved-v0.2.4; tracking-box conclusion logged
  - [x] .docs/session.yaml: goals/completed + RUNTIME_STATE + NEXT_STEPS updated
  - [x] .docs/release.yaml: v0.2.4 tagged + pushed
  - [x] Driver zig build test PASS; bridge + daemon ReleaseSafe builds PASS
