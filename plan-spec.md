# plan-spec.md — v0.2.5 TobiiArgus Display Area Refactor
# Approved 2026-08-23 by user. Scope: Decouple device track box from physical screen.
# Track box = expanded 2.5× EDID (matches original tobiifree 1500×1000mm equivalent).
# Physical screen = EDID auto-detect for GUI/affine/calibration.
# Calibration only adjusts gaze offset/scale params — NEVER touches device display area.
BASE_COMMIT: "68b9f8f"

BATCH_1_DISPLAY_AREA_CONFIG:
  - [x] New types in driver/src/display_area_config.zig:
      - PhysicalScreen { w_mm, h_mm }
      - DeviceDisplayArea { w_mm, h_mm, z_mm=65, tilt_deg=12, ox_mm, oy_mm, track_box_factor=2.5 }
      - CalibrationParams { gaze_y_offset=0.394, gaze_y_scale=1.278, gaze_x_offset=0, gaze_x_scale=1 }
      - FullConfig { physical_screen, device_display_area, calibration, track_box_factor }
  - [x] defaultFromEdid(edid, factor=2.5) -> FullConfig:
      - physical_screen = EDID size
      - device_display_area = EDID × factor (expanded for track box)
      - calibration = defaults
  - [x] toJsonString(FullConfig): serializes ONLY physical_screen + calibration + track_box_factor
  - [x] loadFromFile(path): loads physical_screen + calibration + factor, recomputes device area
  - [x] Migration: auto-convert old format (root w_mm/h_mm/z_mm/tilt/cx/cy) to new FullConfig
  - [x] Driver tests PASS (zig build test in driver/)

BATCH_2_DAEMON_INTEGRATION:
  - [x] applications/tobiifreed/src/main.zig:
      - loadFullConfig(): replaces loadDisplayArea(), returns FullConfig
      - tracker.setDisplayArea(device_display_area): sends EXPANDED area to ET5
      - get_display_area response extended: 9xf64 corners + 2xf64 physical_screen (w_mm, h_mm)
      - initConfig(): writes new JSON format to ~/.config/tobii.json
      - --force-display-area: re-sends expanded device area
      - --track-box-factor=2.5 CLI flag: overrides factor at startup
  - [x] driver/src/daemon_protocol.zig: extend SRV display_area (0x03) payload to 11xf64
  - [x] Daemon ReleaseSafe build PASS (NFS pattern)

BATCH_3_BRIDGE_INTEGRATION:
  - [x] applications/tobiifree-opentrack/src/main.zig:
      - On startup: send get_display_area (0x02), parse extended 11xf64 response
      - g_stream_preset (affine correction): uses physical_screen for mapping
      - GUI visualization: maps gaze to physical_screen rect
      - eye2dPlausible(): accepts any finite coords (no [0,1] clamp)
      - --track-box-factor=2.5 CLI flag: forwards to daemon via new command
  - [x] Bridge ReleaseSafe build PASS (NFS pattern)

BATCH_4_CALIBRATION_WIZARD:
  - [x] applications/tobiifree-opentrack/src/calibration.zig:
      - calAddPoint(): sends points normalized to physical_screen [0,1]
      - calCompute()/calApply(): ONLY bakes gaze_x/y_offset/scale into Preset
      - REMOVE any set_display_area calls or device area modifications
      - Config persistence: updates calibration params in JSON only
  - [x] Wizard UI unchanged (progress ring, counter below dot)

BATCH_5_MIGRATION_QA:
  - [x] ~/.config/tobii.json auto-migration on first run:
      - Detect old format → extract physical_screen (w_mm/h_mm) + calibration (from preset defaults)
      - Write new format with track_box_factor=2.5
  - [x] QA Gate:
      - [x] Driver zig build test PASS
      - [x] Daemon + Bridge ReleaseSafe builds PASS
      - [x] Runtime: daemon logs "display_area 2000x825mm origin=(-1000,-10) z=65 tilt=12 factor=2.5"
      - [x] Runtime: device reports updated corners after force-apply
      - [x] Runtime: both eyes tracked at upper 10-15% (no single-eye loss)
      - [x] Runtime: GUI dot correctly maps to physical screen
      - [x] Runtime: UDP packets sane
      - [x] Calibration: 5-point completes, only calibration params updated in JSON
      - [x] Edge cases: missing config, different EDID sizes, factor override

FIXES_APPLIED_THIS_SESSION:
  - track-box-expansion: device_display_area = EDID × 2.5 (2000×825mm for 800×330 screen) restores original tobiifree track box size (~1500×1000mm equivalent)
  - physical-screen-separation: GUI/affine/calibration use actual EDID size (800×330mm)
  - calibration-no-display-area: calibration only adjusts offset/scale, never overwrites device track box
  - configurable-factor: track_box_factor in JSON + --track-box-factor CLI (default 2.5)
  - protocol-extension: get_display_area returns device corners + physical_screen dims
  - config-migration: auto-convert old tobii.json format

NOTES:
  - Original tobiifree (Aetherall + all forks) uses 1500×1000mm z=0 tilt=0 defaults for huge track box
  - Our v0.1.1 EDID detection shrank it to physical screen → single-eye loss at edges
  - This refactor restores large track box while keeping correct clip-mount geometry
  - Affine correction (gaze_y_offset=0.394, gaze_y_scale=1.278) calibrated on physical screen
  - Bridge sends NO UDP when no eyes tracked (unchanged)
  - AGENTS.md untracked — do NOT commit