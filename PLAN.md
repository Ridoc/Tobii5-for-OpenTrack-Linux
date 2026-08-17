# PLAN.md — Tobii Eye Tracker → X4: Foundations via OpenTrack

## Goal

Make a Tobii Eye Tracker work with **X4: Foundations** on its **native Linux build** by
forking [`Aetherall/tobiifree`](https://github.com/Aetherall/tobiifree) and adding a
standalone bridge that delivers tracking data to X4 through the **OpenTrack UDP protocol**
that X4 natively listens to. Target is a **near-like Tobii experience** (head-look driven
camera) using **gaze + eye-origin derived pose** as the signal source.

## Background & Key Facts

- X4: Foundations has a **native Linux build** (Steam). Since the **7.50 public beta** it
  includes a built-in **OpenTrack UDP listener on `127.0.0.1:4242`**. Enable it in-game
  under *Options → Controls → OpenTrack Support*; head tracking is toggled with **Ctrl+T**
  and **recenter is already handled by X4 (Scroll Lock)** — no bridge-side recenter needed.
- The **OpenTrack UDP wire protocol** is a 48-byte packet of **6 little-endian doubles**:
  `X, Y, Z, Yaw, Pitch, Roll` — translation in **cm**, rotation in **degrees**. Confirmed
  against `ltr_udp.c` (a bridge written specifically for X4) and opentrack's own
  `proto-udp/ftnoir_protocol_ftn.cpp`.
- **tobiifree** (the fork base):
  - Zig protocol driver (`driver/`) decoding the Tobii ET5's native TTP stream, plus a
    daemon **`tobiifreed`** that owns the USB device and exposes gaze over a Unix socket
    (`$XDG_RUNTIME_DIR/tobiifreed/gaze.sock`).
  - Daemon protocol: `[u8 msg_type][u32 LE payload_len][payload]`. Client sends `subscribe`
    (0x01); daemon streams `gaze` (0x01) messages whose payload is the full raw
    `core.GazeSample` struct, including:
    - `gaze_point_2d_norm[2]` — binocular 2D gaze, `[0,1]²`
    - `eye_origin_L_mm[3]` / `eye_origin_R_mm[3]` — calibrated 3D eye positions (tracker
      space, mm; z≈510 mm)
    - `validity_L`, `validity_R` (0 = valid), `frame_counter`, `timestamp_us`
  - `driver/src/socket_source.zig` already provides a client-side `SocketSource`.
- **Tobii reference values** (used for default gains, target behavior):
  - Tobii Game Hub "Maximal Gaze Angle" default ≈ **25°** (common range 8–45°).
  - Tobii head tracking 6DoF specs: Yaw ±65°, Pitch ±45°, Roll ±25°; position
    X ±20 cm, Y ±15 cm, Z +30/−20 cm.
  - X4's OpenTrack multipliers (from X4's config): `opentrackanglefactor` 1.0,
    `opentrackpositionfactor` 1.0, `opentrackfilterstrength` 5 — i.e. X4 applies our
    angles/position **1:1**.
- **Scope limitation:** the OpenTrack protocol carries head pose only. X4's eye-tracking
  extras (gaze target-lock, gaze-driven HUD/menu navigation) require the Windows-only Tobii
  Game Integration API and are **not reachable via OpenTrack**. This project delivers the
  primary X4 Tobii experience: **the cockpit camera follows where you look / where your
  head is** (eye-aim-driven head-look).

## Architecture

```
Tobii ET5 (USB)
  → tobiifreed  (existing tobiifree daemon; owns USB + calibration)
  → Unix socket gaze stream (full GazeSample)
  → tobiifree-opentrack  (NEW app in the fork; the bridge)
      • subscribe to daemon gaze
      • gaze → yaw/pitch (Tobii-default gains)
      • eye-origin midpoint → head X/Y/Z (cm)
      • EMA smoothing + deadzone (replaces OpenTrack's missing filters)
  → UDP 127.0.0.1:4242  (48 B: X,Y,Z,yaw,pitch,roll as LE doubles)
  → X4: Foundations  (native Linux, OpenTrack Support enabled)
```

No OpenTrack GUI, no Wine, no DLL injection required. Recenter is handled by X4 itself.

## Implementation Phases

### Phase 1 — Fork + bridge app (core)

1. Fork `Aetherall/tobiifree` (keep GPL-3.0).
2. Add new app `applications/tobiifree-opentrack/` (Zig, mirrors `tobiifreed` build layout;
   stdlib + libc only):
   - `build.zig` — depends on `driver`, exposes the executable.
   - `src/main.zig`:
     - Connect to `$XDG_RUNTIME_DIR/tobiifreed/gaze.sock`, send `subscribe`, decode
       `GazeSample` (reuse `daemon_protocol.zig` framing).
     - **Gaze → rotation** (defaults from Tobii; all CLI-configurable):
       - `yaw   = (gaze_x − 0.5) × 2 × MAX_YAW`   (default MAX_YAW = 25°, → ±25° at screen edge)
       - `pitch = (0.5 − gaze_y) × 2 × MAX_PITCH` (default MAX_PITCH = 15°, up = positive)
       - `roll  = 0` (Phase 3 may add roll from the eye baseline)
       - Optional curvature (exponent) later to mirror Tobii's "sensitivity gradient".
     - **Eye-origin → translation**:
       - `mid = (eye_origin_L + eye_origin_R) / 2` (mm)
       - `X = (mid.x − ref.x)/10`, `Y = (mid.y − ref.y)/10`, `Z = (mid.z − ref.z)/10` (cm)
       - `ref` captured once at startup (no runtime recenter — X4's Scroll Lock handles it).
     - **Filtering**: configurable EMA (alpha) + deadzone, since OpenTrack's filters are
       not in the path.
     - Send 48-byte little-endian UDP datagrams to `127.0.0.1:4242` at device rate (~60 Hz).
     - CLI flags: `--host`, `--port`, `--yaw-gain`, `--pitch-gain`, `--smoothing`,
       `--deadzone`.
3. Docs: build (`zig build`), run order (`tobiifreed` → `tobiifree-opentrack` → X4), in-game
   setup.

### Phase 2 — Validation & tuning

- Verify end-to-end: daemon reports gaze, bridge sends packets, X4 shows "OpenTrack
  Support: connected", Ctrl+T engages tracking, Scroll Lock recenters.
- Tune gains/deadzone/EMA to match Tobii's feel (start: max gaze angle 25°, pitch 15°,
  EMA ~0.3).

### Phase 3 — True head pose (optional follow-up)

- Add IR-frame streaming (subscribe stream `0x050e`) to the driver and port the MediaPipe
  head-pose pipeline from `njmill/tobii-linux` for real yaw/pitch/roll and roll from the
  eye baseline. Larger effort; deferred.

## File Layout (within the fork)

```
applications/tobiifree-opentrack/
  build.zig
  src/main.zig
docs/x4-foundations-opentrack.md
```

## Verification Checklist

- [x] `zig build` for `tobiifree-opentrack` succeeds. *(verified: Debug + `-Doptimize=ReleaseSafe` + `nix build .#tobiifree-opentrack`)*
- [x] `tobiifreed` streaming (gaze logs visible), socket exists. *(verified on live ET5: `2104:0313`, socket at `$XDG_RUNTIME_DIR/tobiifreed/gaze.sock`)*
- [x] Bridge connects, subscribes, and decodes `GazeSample`. *(verified live; log shows head reference + yaw/pitch from real gaze)*
- [x] UDP packets captured on `127.0.0.1:4242` (48 B, 6 doubles, ~60 Hz). *(verified live: 48 B LE doubles; observed ~33 Hz at the device/daemon rate — actual rate tracks the device, not the bridge)*
- [ ] X4 (native Linux): *Options → Controls → OpenTrack Support* → "Connected". *(needs game running)*
- [ ] Ctrl+T engages; camera follows gaze; X4 recenter (Scroll Lock) centers without jumps. *(needs game running)*
- [ ] Tuning feels near-like Tobii in cockpit (gains/deadzone/EMA). *(needs human tuning on hardware)*

> Note: on CIFS/SMB workspaces, Zig's cache renames fail. Build with
> `--cache-dir <local>` and `-p <local>` (see `docs/x4-foundations-opentrack.md`).

## Open Questions

- Exact default MAX_PITCH (15° proposed; Tobii Game Hub examples vary 0.1–1.0 pitch
  multipliers — tune on hardware).
- ~~Whether to send head position (X/Y/Z) in v1 or leave zero and add later.~~
  **Resolved:** v1 sends head X/Y/Z from the eye-origin midpoint (mm → cm), captured
  once at startup; `--no-position` disables it.
