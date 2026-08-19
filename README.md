# Tobii Eye Tracker 5 → OpenTrack for Linux games (X4: Foundations, flight sims, racing & more)

Make a **Tobii Eye Tracker 5** drive head-look camera in **any game with
OpenTrack/FreeTrack support** on Linux — **X4: Foundations** (native Linux build)
included. The cockpit camera follows where you look, powered by the tracker's
gaze + eye-origin data, streamed over the standard OpenTrack UDP protocol.

```
Tobii ET5 (USB)
  → tobiifreed          daemon (owns USB + calibration, streams gaze)
  → unix socket gaze    $XDG_RUNTIME_DIR/tobiifreed/gaze.sock
  → tobiifree-opentrack  this bridge (gaze → head pose, EMA + deadzone)
  → UDP 127.0.0.1:4242  48 B: X,Y,Z,Yaw,Pitch,Roll as little-endian doubles
  → any OpenTrack-capable game   (e.g. X4: Foundations, built-in support, 7.50 beta+)
```

No Windows driver, no Wine, no OpenTrack GUI, no DLL injection.

## Compatibility

OpenTrack supports **800+ games and simulators** through its FreeTrack
interface, and **350+ titles** are officially supported by the Tobii Eye
Tracker 5 following the GameHub 4.0 update. This bridge is a generic OpenTrack
source — if a game can read OpenTrack UDP on `127.0.0.1:4242`, it works.

Primarily flight, racing, and space simulators (many commercial titles need
third-party plugins or the **TrackIRFixer** tool to bypass encrypted interfaces):

- **Flight & space sims:** Microsoft Flight Simulator 2020/2024, X-Plane 10/12,
  Prepar3D (SimConnect), DCS World (incl. A-10C, Black Shark), Elite: Dangerous,
  Star Citizen, Star Wars: Squadrons, EVE: Valkyrie, IL-2 Sturmovik series,
  War Thunder.
- **Racing & truck sims:** Assetto Corsa / Competizione, iRacing, rFactor 2,
  Automobilista 2, Project CARS 2, Euro Truck Simulator 2, American Truck
  Simulator, Farming Simulator 25, BeamNG.drive, DiRT Rally series, F1 series.
- **Military & other:** Arma 3, Arma Reforger, DayZ, Escape from Tarkov, Squad,
  Insurgency: Sandstorm, Microsoft Train Simulator, Need for Speed (e.g. Hot
  Pursuit, Shift), Grand Theft Auto / Battlefield 2 (mods like BF2FreeLook).

For the full, up-to-date list, see the [OpenTrack supported games database](
https://github.com/opentrack/opentrack/wiki) or the `supported games.csv`
shipped with OpenTrack/facetracknoir.

## Requirements

- Tobii Eye Tracker 5 + [udev rules](assets/99-tobii.rules)
- An OpenTrack-capable game. For **X4: Foundations** (native Linux, Steam):
  **7.50 public beta or newer**
- Zig 0.14+ (`nix develop`), `libusb-1.0`, `pkg-config`, `gtk4` (status window)

## Quick start

```sh
# 1. USB permissions (once)
sudo cp assets/99-tobii.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger

# 2. daemon — owns the USB device
nix develop -c bash -c "cd applications/tobiifreed && zig build run"

# 3. bridge — streams to the game's OpenTrack UDP port (default 127.0.0.1:4242)
nix develop -c bash -c "cd applications/tobiifree-opentrack && zig build run"
```

(or `just tobiifreed` then `just opentrack` inside the dev shell.)

You should see the bridge log its first sample quickly:

```
info(opentrack): head reference captured: (-18, 13, 572) mm
info(opentrack): x=   0.0 y=   0.0 z=   0.0  yaw=   1.7° pitch=  -7.2°  (sample 1)
```

The bridge opens a small **GTK4 status window** showing the live pose values
(X/Y/Z, Yaw/Pitch/Roll) with **sensitivity sliders** and manual text overrides
for the yaw/pitch gains — both apply to the stream live, no restart needed.
Pass `--headless` for console-only operation.

### In-game setup

Example — **X4: Foundations**:

1. Options → **Controls** → enable **OpenTrack Support** → "Connected".
2. In the cockpit press **Ctrl+T** to engage head tracking.
3. **Scroll Lock** recenters (handled by X4).

Other OpenTrack games expose the same listener via their own settings — point
them at UDP `127.0.0.1:4242` and set up recenter/hotkeys per the game.

## Tuning

All tunables are CLI flags on the bridge (`tobiifree-opentrack --help`):

| Flag | Default | Meaning |
|---|---|---|
| `--yaw-gain` | `37.5` | degrees of yaw at the screen edges |
| `--pitch-gain` | `22.5` | degrees of pitch at the screen edges |
| `--smoothing` | `0.3` | EMA alpha — higher = more responsive |
| `--deadzone` | `0.2` | degrees of yaw/pitch deadzone near center |
| `--no-position` | — | rotation-only (zeros for head X/Y/Z) |
| `--headless` | — | no GUI window, console logging only |

In the GUI, the yaw/pitch gains (`--yaw-gain`/`--pitch-gain`) can also be tuned
live with the sensitivity sliders or a typed value + Enter.

Full docs: [`docs/x4-foundations-opentrack.md`](docs/x4-foundations-opentrack.md).

## What's here

- **`applications/tobiifree-opentrack/`** — the OpenTrack bridge with a GTK4
  status window (live pose + sensitivity sliders; `--headless` for console-only).
- **`driver/`** — TTP/TLV protocol engine for the ET5 (from upstream tobiifree).
- **`applications/tobiifreed/`** — Linux daemon; owns the USB device, exposes
  gaze over a Unix socket.
- **`applications/tobiifree-overlay/`** — GTK4 gaze-dot overlay.
- **`sdk/` + `applications/tobiifree-demo/`** — browser demo (calibration, display
  area).

## Scope

This delivers the core Tobii experience: **the camera follows where you look /
where your head is**. Per-game eye-tracking extras (e.g. X4's gaze target-lock
and gaze-driven menus, or Tobii's gaze-based UI in some titles) need the
Windows-only Tobii Game Integration API and are not reachable over the
OpenTrack head-pose protocol.

## License & credits

[GPL-3.0](LICENSE). This is a fork of
[Aetherall/tobiifree](https://github.com/Aetherall/tobiifree) — the ET5 driver,
daemon, and protocol work is theirs; this repo adds the OpenTrack bridge.