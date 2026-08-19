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

The primary Tobii experience in X4: **the cockpit camera follows where you
look** (eye-aim-driven head-look), plus small head-position movement from the
tracker's eye-origin triangulation:

- **Yaw/Pitch** from binocular 2D gaze — default ±37.5°/±22.5° at screen edges
  (tuned +50% over Tobii Game Hub's default "Maximal Gaze Angle" ≈ 25°).
- **X/Y/Z head position** from the midpoint of the calibrated eye origins
  (mm → cm), referenced once at startup.
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

By default the bridge opens a small GTK4 window showing the live pose values
(X/Y/Z in cm, Yaw/Pitch/Roll in degrees) plus a status line ("Eyes: tracked" /
"Eyes: lost") and two **sensitivity sliders**:

- **Yaw / Pitch** sliders adjust `--yaw-gain` / `--pitch-gain` live (0–90°).
- The **text entry** next to each slider is a manual override — type a value
  and press Enter to set it precisely (clamped to 0–90°).

Everything applies immediately to the outgoing stream, no restart needed. Pass
`--headless` to run console-only (e.g. inside X4's built-in OpenTrack Support,
or on a system without a display).

## In-game setup (X4: Foundations, native Linux)

1. Options → **Controls** → enable **OpenTrack Support**.
   X4 should report "OpenTrack Support: connected".
2. While in the cockpit, press **Ctrl+T** to engage head tracking.
3. **Scroll Lock** recenters (handled by X4 — the bridge never recenters).

## Tuning

All tunables are CLI flags on the bridge:

| Flag | Default | Meaning |
|---|---|---|
| `--host` | `127.0.0.1` | UDP target host |
| `--port` | `4242` | UDP target port (X4's listener) |
| `--yaw-gain` | `37.5` | degrees of yaw at the left/right screen edge |
| `--pitch-gain` | `22.5` | degrees of pitch at the top/bottom screen edge |
| `--smoothing` | `0.3` | EMA alpha (0..1]; higher = more responsive, lower = smoother |
| `--deadzone` | `0.2` | degrees of yaw/pitch deadzone near center |
| `--no-position` | — | send zeros for head X/Y/Z (rotation-only mode) |
| `-v` / `--verbose` | — | per-sample logging |

X4 applies angles and position 1:1 (`opentrackanglefactor`/`opentrackpositionfactor`
are 1.0 by default, and OpenTrack's own filters aren't in the path), so the bridge
is the only place to tune. Defaults are tuned +50% over Tobii's 25°/15° for more
rotation: yaw 37.5°, pitch 22.5°, smoothing 0.3, deadzone 0.2°. If the camera feels
sluggish, raise smoothing; if it feels twitchy, lower it and raise the deadzone.
In the GUI the Yaw/Pitch gains can also be adjusted live with the sensitivity
sliders (or typed into the entry and confirmed with Enter).

## Troubleshooting

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
  src/main.zig       # socket client → gaze→pose → UDP; CLI tunables
docs/x4-foundations-opentrack.md   # this file
```

Reuses `driver/src/daemon_protocol.zig` (framing), `driver/src/socket_source.zig`
(daemon client), and the `core.GazeSample` decoder — no protocol logic is duplicated.
