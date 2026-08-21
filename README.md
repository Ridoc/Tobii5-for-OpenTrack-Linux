# Tobii Eye Tracker 5 → OpenTrack for Linux games (X4: Foundations, flight sims, racing & more)

Make a **Tobii Eye Tracker 5** drive head-look camera in **any game with
OpenTrack/FreeTrack support** on Linux — **X4: Foundations** (native Linux build)
included. The cockpit camera follows where you look, powered by the tracker's
gaze + eye-origin data, streamed over the standard OpenTrack UDP protocol.

```
Tobii ET5 (USB)
  → tobiifreedot        daemon (TobiiFreedOT; owns USB + calibration, streams gaze)
  → unix socket gaze    $XDG_RUNTIME_DIR/tobiifreedot/gaze.sock
  → tobiifree-opentrack  this bridge (Tobii-feel pipeline: gaze filter, head pose,
                          adaptive smoothing, 85/15 blend, response curve, presets)
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

(or `just tobiifreedot` then `just opentrack` inside the dev shell.)

You should see the bridge log its first sample quickly:

```
info(opentrack): head reference captured: (-18, 13, 572) mm
info(opentrack): x=   0.0 y=   0.0 z=   0.0  yaw=   1.7° pitch=  -7.2°  (sample 1)
```

The bridge opens a small **GTK4 status window** showing the live pose values
(X/Y/Z, Yaw/Pitch/Roll) with a **live eye/head visualization** (gaze point on
a mini screen + a head figure showing the yaw/pitch estimation), **live tuning
sliders** and a **preset system** —
switch between built-in profiles (`tobii-official`, `x4`, `x4-smooth`) or
save your own. All changes apply to the stream
immediately, no restart needed. Pass `--headless` for console-only operation.

### In-game setup

Example — **X4: Foundations**:

1. Options → **Controls** → enable **OpenTrack Support** → "Connected".
2. In the cockpit press **Ctrl+T** to engage head tracking.
3. **Scroll Lock** recenters (handled by X4).

Other OpenTrack games expose the same listener via their own settings — point
them at UDP `127.0.0.1:4242` and set up recenter/hotkeys per the game.

## Tuning

All tunables are CLI flags on the bridge (`tobiifree-opentrack --help`) and
live sliders in the GUI. Settings are grouped into **presets** stored in
`$XDG_CONFIG_HOME/tobiifree-opentrack/presets.json` (built-ins are seeded from
code). Key parameters:

| Flag | Default (`tobii-official`) | Meaning |
|---|---|---|
| `--preset <name>` | `tobii-official` | load a preset (built-in or saved) |
| `--save-preset <name>` | — | save current settings as a preset and exit |
| `--yaw-gain` | `180` | yaw output cap (degrees) |
| `--pitch-gain` | `90` | pitch output cap (degrees) |
| `--head-gain` | `2.0` | head-sensitivity multiplier (10° head → 20° cam) |
| `--eye-ratio` | `0.15` | gaze contribution to rotation (OEM 85/15) |
| `--curve` | `tobii` | response curve: `linear` / `power` / `tobii` |
| `--smoothing` | `0.90` | rotation rest retention (Accela-style, velocity-adaptive) |
| `--pos-smoothing` | `0.95` | translation rest retention (heavier) |
| `--deadzone` | `0.15` | degrees of yaw/pitch deadzone near center |
| `--neck` | `13` | neck-pivot distance (cm) used for head-rotation derivation |
| `--flip-yaw` / `--flip-pitch` | — | invert head rotation direction |
| `--no-position` | — | rotation-only (zeros for head X/Y/Z) |
| `--headless` | — | no GUI window, console logging only |

**Built-in presets**: `tobii-official` (clean OEM-style defaults: Tobii spline
curve, 180°/90° caps, 2× head gain, 15% gaze lead), `x4` (same OEM spline feel
with a 120° yaw cap so the screen edge doesn't blow out), `x4-smooth`
(buttery-smooth setup with 2.4× head gain, +20% stronger than `x4`). The
pre-rework snapshots are kept as `tobii-official (old)`, `x4 (old)`,
`x4-smooth (old)` so the previous feel is one click away.

In the GUI, every slider has a text override (type + Enter) and the preset
dropdown has **Save** / **Save as…** / **Delete** buttons.

Full docs: [`docs/x4-foundations-opentrack.md`](docs/x4-foundations-opentrack.md).

## Troubleshooting

- **Tracker LED flashing but no eyes detected after suspend/hibernation** —
  restart the daemon (it re-opens the USB link and re-applies the display
  area): `killall tobiifreedot`, then `nix develop -c bash -c "cd
  applications/tobiifreed && zig build run"`. Restart the bridge too if it
  doesn't reconnect. See the full docs for details.

## What's here

- **`applications/tobiifree-opentrack/`** — the OpenTrack bridge with a GTK4
  status window (live pose + tuning sliders + presets; `--headless` for
  console-only).
- **`driver/`** — TTP/TLV protocol engine for the ET5 (from upstream tobiifree).
- **`applications/tobiifreed/`** — Linux daemon **`tobiifreedot`** (TobiiFreedOT);
  owns the USB device, exposes gaze over a Unix socket.
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
**[Aetherall/tobiifree](https://github.com/Aetherall/tobiifree)** by
**[Aetherall](https://github.com/Aetherall)**, licensed under the GNU General
Public License v3.0. Under GPLv3's strong copyleft, this project is also
distributed under GPL-3.0: the ET5 driver, daemon, and protocol work is theirs;
this repo adds the OpenTrack bridge and renames the daemon to **TobiifreedOT**
(`tobiifreedot`). If you modify or redistribute this code, your changes must
stay GPL-3.0 and credit the upstream work above.