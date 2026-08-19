# Tobii ET5 → X4: Foundations via OpenTrack

Bridge that makes a **Tobii Eye Tracker 5** drive the cockpit camera in the
**native Linux build of X4: Foundations** through X4's built-in **OpenTrack
UDP listener**. No OpenTrack GUI, no Wine, no DLL injection.

> The bridge is a **generic OpenTrack source** — it streams to
> `127.0.0.1:4242` and works with *any* OpenTrack/FreeTrack-capable game
> (flight/racing/space sims, etc., see the README for the compatibility list).
> X4: Foundations is the primary, fully-native example used throughout this doc.

```
Tobii ET5 (USB)
  → tobiifreedot         (daemon "TobiiFreedOT"; owns USB + calibration, exposes gaze)
  → unix socket gaze      ($XDG_RUNTIME_DIR/tobiifreedot/gaze.sock)
  → tobiifree-opentrack   (this bridge)
  → UDP 127.0.0.1:4242    (48 B = X,Y,Z,Yaw,Pitch,Roll as little-endian doubles)
  → X4: Foundations       (native Linux, OpenTrack Support)
```

## What you get

The Tobii "Extended View" experience in X4: rotation driven mostly by your
**head** (approximated from the eye-origin midpoint around a neck pivot) with a
gentle **gaze lead** (OEM 85/15 blend), plus head-position movement from the
tracker's eye-origin triangulation:

- **Yaw/Pitch** — head-rotation estimate + 15% smoothed-gaze lead, mapped
  through a Tobii response curve (default `tobii` spline: 2° deadzone,
  10°→20°, 20°→75°, 35°→180°).
- **X/Y/Z head position** from the midpoint of the calibrated eye origins
  (mm → cm, ×2 default), referenced once at startup.
- **Roll = 0** (real head roll needs the IR-frame pipeline of Phase 3).

Scope limitation: the OpenTrack protocol carries head pose only. X4's
eye-tracking extras (gaze target-lock, gaze-driven menus) need the Windows-only
Tobii Game Integration API and are **not** reachable via OpenTrack.

## Requirements

- Tobii Eye Tracker 5 connected (udev rules installed, see below).
- X4: Foundations native Linux (Steam), **7.50 public beta or newer**
  (the beta added the OpenTrack listener).
- `zig` 0.14+ (dev shell: `nix develop`), `libusb-1.0`, `pkg-config`,
  and `gtk4` dev headers for the status window (`--headless` skips it).

## Build

```sh
nix develop                          # provides zig, libusb, pkg-config

# daemon
cd applications/tobiifreed && zig build

# bridge
cd applications/tobiifree-opentrack && zig build
```

Binaries land in `applications/*/zig-out/bin/`. If your workspace lives on a
filesystem that doesn't support Zig's cache renames (e.g. a CIFS/SMB share),
point the caches at local storage:

```sh
zig build --cache-dir "$HOME/.cache/zig-opentrack" -p "$HOME/zig-out-opentrack"
```

## Run order

```sh
# 1. USB permissions (once)
sudo cp assets/99-tobii.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger

# 2. daemon — owns the USB device
applications/tobiifreed/zig-out/bin/tobiifreedot

# 3. bridge — streams to X4's OpenTrack UDP port
applications/tobiifree-opentrack/zig-out/bin/tobiifree-opentrack
```

You should see the bridge log its first sample quickly:

```
info(opentrack): head reference captured: (-18, 13, 572) mm
info(opentrack): x=   0.0 y=   0.0 z=   0.0  yaw=   1.7° pitch=  -7.2°  (sample 1)
```

## Status window (GTK4)

By default the bridge opens a GTK4 window showing the live pose values (X/Y/Z
in cm, Yaw/Pitch/Roll in degrees), a status line ("Eyes: tracked" / "Eyes:
lost"), a **preset dropdown** (Save / Save as… / Delete), and live **tuning
sliders** grouped into **Sensitivity** and **Tobii feel** sections:

- **Yaw cap / Pitch cap** — output caps in degrees (the official `tobii` curve
  reaches 180°/90°; X4 usually wants 60°/40° or less).
- **Smoothing / Pos smoothing** — Accela-style **velocity-adaptive** retention
  (defaults 0.90 / 0.95 at rest, dropping toward 0.05 at 180°/s flicks). Lower
  = more responsive, higher = smoother. If the view is wobbly, raise it.
- **Deadzone** — center stabilization, 0–3°.
- **Head gain** — head-sensitivity multiplier (2.0 = 10° head → 20° cam).
- **Eye ratio** — the gaze lead blended into rotation (OEM 0.15 = 85/15).
- **Pos gain** — translation multiplier (default 2.0, so you don't lean out of
  your chair).
- **Neck (cm)** — neck-pivot distance used to derive head yaw/pitch from the
  eye-origin midpoint (default 13).
- **Gaze yaw/pitch scale** — gaze → angle at the screen edge (40°/30°).
- **Curve** — `Linear` / `Power` / `Tobii` response-curve modes.
- **Curve exp** — power-curve exponent (default 0.5 expands the edges).
- **Flip yaw / Flip pitch** — invert head-rotation direction if it feels wrong.

The **text entry** next to each slider is a manual override — type a value and
press Enter. Everything applies immediately to the outgoing stream, no restart
needed. The socket is polled at 125 Hz so the game receives a steady stream,
while the labels refresh at ~30 Hz. Pass `--headless` to run console-only (e.g.
inside X4's built-in OpenTrack Support, or on a system without a display).

## In-game setup (X4: Foundations, native Linux)

1. Options → **Controls** → enable **OpenTrack Support**.
   X4 should report "OpenTrack Support: connected".
2. While in the cockpit, press **Ctrl+T** to engage head tracking.
3. **Scroll Lock** recenters (handled by X4 — the bridge never recenters).

## Tuning

All tunables are CLI flags on the bridge (`tobiifree-opentrack --help`) and
live sliders in the GUI. Settings live in **presets** — built-ins seeded from
code, user presets persisted to `$XDG_CONFIG_HOME/tobiifree-opentrack/presets.json`:

| Flag | Default (`tobii-official`) | Meaning |
|---|---|---|
| `--host` | `127.0.0.1` | UDP target host |
| `--port` | `4242` | UDP target port (X4's listener) |
| `--preset <name>` | `tobii-official` | load a preset |
| `--list-presets` | — | list presets and exit |
| `--save-preset <name>` | — | save current settings as a preset and exit |
| `--yaw-gain` | `180` | yaw output cap (degrees) |
| `--pitch-gain` | `90` | pitch output cap (degrees) |
| `--smoothing` | `0.90` | rotation rest retention (velocity-adaptive) |
| `--pos-smoothing` | `0.95` | translation rest retention (heavier) |
| `--deadzone` | `0.15` | degrees of yaw/pitch deadzone near center |
| `--head-gain` | `2.0` | head-sensitivity multiplier |
| `--eye-ratio` | `0.15` | gaze lead (OEM 85/15) |
| `--pos-gain` | `2.0` | translation multiplier |
| `--neck` | `13` | neck-pivot distance (cm) |
| `--gaze-scale` | `40` | gaze → yaw at screen edge (degrees) |
| `--gaze-scale-pitch` | `30` | gaze → pitch at screen edge (degrees) |
| `--curve` | `tobii` | response curve: `linear` / `power` / `tobii` |
| `--curve-exp` | `0.5` | power-curve exponent |
| `--flip-yaw` / `--flip-pitch` | — | invert head rotation direction |
| `--no-position` | — | send zeros for head X/Y/Z (rotation-only mode) |
| `-v` / `--verbose` | — | per-sample logging |

X4 applies angles and position 1:1 (`opentrackanglefactor`/`opentrackpositionfactor`
are 1.0 by default, and OpenTrack's own filters aren't in the path), so the bridge
is the only place to tune. The pipeline replicates the OEM Tobii feel:

1. **Gaze** — 3-state dynamic EWMA (fixation 0.03 / pursuit 0.25 / saccade 0.015,
   time-corrected) so saccades never whip the camera.
2. **Head** — yaw/pitch derived from the eye-origin midpoint around a neck pivot
   (`atan2(Δx, neck−Δz)`), ×`head_gain`.
3. **Blend** — `head + smoothed_gaze × eye_ratio` (OEM 85/15).
4. **Smoothing** — velocity-adaptive retention (0.90 at rest → 0.05 at 180°/s),
   time-corrected per frame; translation uses the heavier `pos_smoothing`.
5. **Curve** — `tobii` spline (2→0, 10→20, 20→75, 35→180 for yaw; asymmetric
   pitch) or `power`/`linear`, capped by the yaw/pitch gains, then the deadzone.

**Built-in presets**: `tobii-official` (OEM curve + 180/90 caps),
`tobii-official-safe` (same, 60/40 caps), **`x4-tuned`** (recommended X4
starting point — the Tobii spline does all the acceleration: head gain **1.0×**
(never pre-multiply the head angle into the spline), 25% gaze lead, 180°/90°
caps so the spline can breathe, smoothing 0.93, pos smoothing 0.96),
`x4-legacy` (previous linear gaze-only behavior). Save your tuned setup with
`--save-preset <name>` or the GUI's **Save as…**.

> **Why the old `x4-tuned` was wrong**: `head_gain 1.8` pre-multiplied the head
> angle *before* the spline, so a physical 10° turn became 15° of input, which
> the spline (10→20, 20→75) mapped to ~45° — an accidental ~4.5× gain. And a
> power curve with `curve_exp < 1.0` has an **infinite slope at zero**, so any
> micro-movement leaving the deadzone caused a violent snap (the "jumps up").
> The fix: let the spline own the acceleration (`head_gain 1.0`, `curve_mode 2`)
> and keep caps at 180/90 so the curve isn't slammed into a brick wall.
>
> The Catmull-Rom evaluator clamps input to the last control point, so there's
> no extrapolation past 35° yaw (which would otherwise shoot toward infinity).
>
> Camera jumps are suppressed three ways: the eye-origin midpoint only
> averages **valid** eyes (a dropped eye otherwise shifts the reference);
> every filter **rejects** samples that jump more than a plausible per-frame
> limit (10°/frame, 1cm/frame) instead of following them, so a glitch can
> never sweep the view; and the head reference is captured as the **average
> over a ~1 s settle window** after acquisition — then **re-centered** after
> a sustained eye loss (re-acquisition), because each re-lock lands on
> slightly different absolute origins (this was the source of the random
> -60° yaw jumps).
>
> A constant offset (e.g. -105° yaw) means the reference was captured off to
> one side. The pipeline **auto-recenters**: if you hold your head roughly
> centered (±30° yaw / ±20° pitch) and still for ~1.2 s, the reference
> re-assimilates to your current position. Parking to aim at a side view
> (large angle) never triggers it. Let go of the controls for a moment and
> the view centers itself.

## Troubleshooting

- **Inputs freeze then "reset to zero"** — older builds polled the daemon
  socket from the GTK UI thread, so any UI/compositor stall stalled the game
  feed and the dt gap tripped a re-center. The stream now runs on its own
  thread; the GUI only reads a snapshot. Re-centering is triggered only by
  real eye re-acquisition (sustained full eye loss), never by delivery stalls.

- **"cannot connect to tobiifreedot"** — start the daemon first; it must own the
  USB device. `$XDG_RUNTIME_DIR` must be set (it is on normal desktop sessions).
- **No samples, "no eyes detected"** — tracker isn't seeing you (range/angle),
  or calibration is off. Run the browser demo (`just demo`) to check raw gaze.
- **X4 doesn't report "connected"** — confirm you're on 7.50 public beta+, the
  listener is `127.0.0.1:4242`, and nothing else occupies the port.
- **Sanity-check packets** without X4:

  ```sh
  # listen on the OpenTrack port and print the 6 doubles
  python3 -c "import socket,struct; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('127.0.0.1',4242));
  [print('%.1f %.1f %.1f %.1f %.1f %.1f'%struct.unpack('<6d',s.recvfrom(64)[0])) for _ in range(10)]"
  ```

## File layout

```
applications/tobiifree-opentrack/
  build.zig          # module graph mirrors the other native apps; links driver
  src/main.zig       # socket client → Tobii-feel pipeline → UDP; CLI + GTK4 GUI
  src/tobii_filter.zig # gaze state filter, head pose, adaptive smoothing,
                       # response curve, preset persistence (JSON)
docs/x4-foundations-opentrack.md   # this file
```

Reuses `driver/src/daemon_protocol.zig` (framing), `driver/src/socket_source.zig`
(daemon client), and the `core.GazeSample` decoder — no protocol logic is duplicated.
