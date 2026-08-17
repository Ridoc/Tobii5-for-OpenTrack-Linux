# Tobii Eye Tracker 5 → X4: Foundations (native Linux)

Make a **Tobii Eye Tracker 5** work with **X4: Foundations** on its **native
Linux build** — the cockpit camera follows where you look, powered by the
tracker's gaze + eye-origin data.

```
Tobii ET5 (USB)
  → tobiifreed          daemon (owns USB + calibration, streams gaze)
  → unix socket gaze    $XDG_RUNTIME_DIR/tobiifreed/gaze.sock
  → tobiifree-opentrack  this bridge (gaze → head pose, EMA + deadzone)
  → UDP 127.0.0.1:4242  48 B: X,Y,Z,Yaw,Pitch,Roll as little-endian doubles
  → X4: Foundations     native Linux, built-in OpenTrack Support (7.50 beta+)
```

No Windows driver, no Wine, no OpenTrack GUI, no DLL injection. X4 recenters
itself (Scroll Lock); head tracking toggles with Ctrl+T.

## Requirements

- Tobii Eye Tracker 5 + [udev rules](assets/99-tobii.rules)
- X4: Foundations, native Linux (Steam), **7.50 public beta or newer**
- Zig 0.14+ (`nix develop`), `libusb-1.0`, `pkg-config`

## Quick start

```sh
# 1. USB permissions (once)
sudo cp assets/99-tobii.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger

# 2. daemon — owns the USB device
nix develop -c bash -c "cd applications/tobiifreed && zig build run"

# 3. bridge — streams to X4's OpenTrack UDP port
nix develop -c bash -c "cd applications/tobiifree-opentrack && zig build run"
```

(or `just tobiifreed` then `just opentrack` inside the dev shell.)

You should see the bridge log its first sample quickly:

```
info(opentrack): head reference captured: (-18, 13, 572) mm
info(opentrack): x=   0.0 y=   0.0 z=   0.0  yaw=   1.7° pitch=  -7.2°  (sample 1)
```

### In X4: Foundations

1. Options → **Controls** → enable **OpenTrack Support** → "Connected".
2. In the cockpit press **Ctrl+T** to engage head tracking.
3. **Scroll Lock** recenters (handled by X4).

## Tuning

All tunables are CLI flags on the bridge (`tobiifree-opentrack --help`):

| Flag | Default | Meaning |
|---|---|---|
| `--yaw-gain` | `37.5` | degrees of yaw at the screen edges |
| `--pitch-gain` | `22.5` | degrees of pitch at the screen edges |
| `--smoothing` | `0.3` | EMA alpha — higher = more responsive |
| `--deadzone` | `0.2` | degrees of yaw/pitch deadzone near center |
| `--no-position` | — | rotation-only (zeros for head X/Y/Z) |

Full docs: [`docs/x4-foundations-opentrack.md`](docs/x4-foundations-opentrack.md).

## What's here

- **`applications/tobiifree-opentrack/`** — the X4 bridge (Zig).
- **`driver/`** — TTP/TLV protocol engine for the ET5 (from upstream tobiifree).
- **`applications/tobiifreed/`** — Linux daemon; owns the USB device, exposes
  gaze over a Unix socket.
- **`applications/tobiifree-overlay/`** — GTK4 gaze-dot overlay.
- **`sdk/` + `applications/tobiifree-demo/`** — browser demo (calibration, display
  area), hosts on GitHub Pages.

## Scope

This delivers the primary X4 Tobii experience: **the cockpit camera follows
where you look / where your head is**. X4's eye-tracking extras (gaze
target-lock, gaze-driven menus) need the Windows-only Tobii Game Integration
API and are not reachable over the OpenTrack head-pose protocol.

## License & credits

[GPL-3.0](LICENSE). This is a fork of
[Aetherall/tobiifree](https://github.com/Aetherall/tobiifree) — the ET5 driver,
daemon, and protocol work is theirs; this repo adds the X4/OpenTrack bridge.
