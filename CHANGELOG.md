# Changelog

All notable changes to **Tobii ET5 → OpenTrack for Linux** (TobiiForX4Linux /
`Ridoc/Tobii5-for-OpenTrack-Linux`). Versions correspond to git tags; the
unreleased section tracks the working tree.

## [Unreleased] — v0.2.0 (calibration wizard)

On-screen calibration wizard, built into the bridge GUI.

### Added
- **Calibration wizard** (`applications/tobiifree-opentrack/src/calibration.zig`):
  - 5-point calibration with a fullscreen Cairo window (green capture counter,
    bold-yellow instruction text flipping at corners, progress bar,
    "ESC = cancel" hint).
  - `Calibrate` button in the main GTK window.
- **Per-point retry with quality gates** — a corner capture below
  `MIN_VALID_PER_POINT` (15/60) or zero-valid is re-captured on the **same
  point** up to `MAX_POINT_RETRIES` (3) with an on-screen hint, instead of a
  hard abort. (Fixes the v0.2.0-dev regression where the wizard hard-aborted
  after 2–3 dots.)
- **Calibration blob round-trip** — `finish_calibration` replies with the blob
  over the daemon's `Srv.response`; the bridge routes it through
  `onDaemonResponse` → `cal_apply` so the daemon's calibration state matches
  the device.

### Fixed
- **Correct point payload size** — `add_calibration_point` payload is now the
  correct **16 bytes = two f64 (x,y)** (was 12 B + dead buffer), and the
  `eye_choice` word is no longer sent (daemon default used).
- **Threading safety** — calibration state is mutex-guarded; all redraws happen
  on the main thread via `onTick`; teardown is deferred via `g_idle_add` with a
  4 s `calWaitTimeout` fallback so the wizard can never deadlock the UI.
- **Crash bugs** — NUL-terminated Cairo strings (was segfaulting
  `cairo_show_text`), Space keysym `0xff80` → `0x20`, key controller moved from
  the drawing area to the toplevel window, and `calFeedGaze` moved before the
  eye-validity gate (corner eye-loss freeze).
- **`save_to_file` `PathAlreadyExists`** in `display_area_config.zig` — save is
  now idempotent-safe.
- **`SocketSource.sendCommand`** — buffer widened to 8 KiB payload + header and
  write failures are now logged instead of silently dropped.

### Docs
- README.md updated with wizard usage + tested behavior + blob round-trip note.

### Pending
- QA gate (`zig build test`), wizard manual re-test, commit/tag/push, GitHub
  release.

## [v0.1.1] — 2026-08-21

EDID auto-detect display area, pre-curve deadzone, adaptive eye ratio.

### Added
- **Daemon EDID auto-detect** — `driver/src/display_area_config.zig` walks
  `/sys/class/drm/card*-*/edid` (bytes 21–22 = physical size in cm) and derives
  the display area automatically; `--force-display-area` overrides; a
  `z_mm = 0` warning is logged when the EDID reports no physical size.
- **Pre-curve deadzone** — deadzone is applied *before* the response curve, so
  micro-jitter can't trip the power-curve's infinite slope near zero.
- **Adaptive eye ratio** — the gaze-lead blend (`eye_ratio`) adapts with head
  motion for a more OEM-like feel.

### Fixed
- Bridge window size 1024×780 (was cut off).
- Gaze drift reduction (gpd 7.78° → ~1°).

### Docs
- Hibernation troubleshooting: USB unplug/replug required; daemon restart alone
  is insufficient (documented in `docs/x4-foundations-opentrack.md`).

## [v0.1.0] — 2026-08-21

First tagged release: the complete ET5 → X4 native OpenTrack bridge.

### Added
- **Tobii ET5 USB driver** (fork of
  [`Aetherall/tobiifree`](https://github.com/Aetherall/tobiifree), GPL-3.0):
  TTP handshake, `Tracker` protocol engine, USB transport (`libusb`),
  `tobiifreedot` daemon owning USB + calibration, Unix socket
  (`$XDG_RUNTIME_DIR/tobiifreedot/gaze.sock`) + optional WebSocket.
- **`tobiifree-opentrack` bridge** — subscribes to daemon gaze, runs the
  Tobii-feel pipeline (gaze filter, head pose, 85/15 blend, adaptive smoothing,
  response curves, presets), and streams **48-byte OpenTrack UDP packets**
  (`X,Y,Z,Yaw,Pitch,Roll` as little-endian doubles) to `127.0.0.1:4242` for
  **X4: Foundations** native Linux (OpenTrack support, 7.50 public beta+).
- **GTK4 status window** with live pose readout, eye/head visualization, tuning
  sliders, and a **preset system** (`tobii-official`, `x4`, `x4-smooth`) with
  JSON persistence.
- **Preset + tuning flags** — yaw/pitch caps, smoothing, pos-smoothing,
  deadzone, head gain, eye ratio, pos gain, neck, gaze scales, curve/exp,
  flip axes, `--no-position`, `--headless`.
- udev rules (`assets/99-tobii.rules`), calibration browser demo, TS SDK.
- `just` commands + flake/nix dev shell for `zig`, `libusb`, `gtk4`.

### Changed (major tuning arc, in order)
- Head rotation rework: **interocular yaw/roll** (the eye line vs. the sensor)
  with IPD validation (45–80 mm, right-eye-on-right) and glitch rejection —
  lean-forward can no longer flip yaw to ±180°.
- Rotation **holds on single eye** (one-eye occlusion), no snap-back.
- Absolute-interocular **recenter** (settle-window reference + GUI button +
  auto-recenter), killing persistent offsets.
- VOR/direction-aware gaze gating; gaze blend gated by head speed; yaw curve
  proportional ramp; `x4-tuned` preset let the Tobii spline own the
  acceleration.
- **No auto-center**; keep last position until a new one can be calculated;
  instant re-acquisition when the eye returns.
- Validation gate, One Euro smoothing (adaptive cutoff), dedicated stream
  thread (125 Hz poll / ~30 Hz GUI).

### Known issues at release
- Real head roll (IR-frame pipeline) is Phase 3 — OpenTrack carries no eye
  tracking, only head pose.
- Post-hibernation USB endpoint requires unplug/replug (documented).