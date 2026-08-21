# Session Continuation — Tobii Head Tracking for X4 (OpenTrack bridge)

**Project**: `Ridoc/Tobii5-for-OpenTrack-Linux` (git remote: https://github.com/Ridoc/Tobii5-for-OpenTrack-Linux)
**Last commit**: `5a4053f` "No auto-center, instant re-acquisition, pitch glitch clamp, corner drift rework" (pushed to main)
**Latest build**: gui17 at `/tmp/zig-out-opentrack-gui17/bin/tobiifree-opentrack`
**Testing daemon**: STOPPED (was pid 24350). Tracker daemon `tobiifreedot` still runs (pid 8744, socket `/run/user/1000/tobiifreedot/gaze.sock`).

---

## 1. System architecture

```
Tobii 5 camera → tobiifreedot (tracker daemon, /tmp/zig-out-tobiifreed3/bin/tobiifreedot)
              → unix socket /run/user/1000/tobiifreedot/gaze.sock
              → tobiifree-opentrack (GUI bridge, app dir: applications/tobiifree-opentrack)
              → UDP 127.0.0.1:4242  (OpenTrack/X4 consumes this)
```

- `applications/tobiifree-opentrack/src/tobii_filter.zig` — the WHOLE tracking pipeline (presets, curves, smoothers, corner hold, n=1 handling, glitch clamps, recenter). ~1080 lines.
- `applications/tobiifree-opentrack/src/main.zig` — GTK GUI + UDP output + preset persistence.
- `driver/src/…` — tracker daemon core (tobiifreedot), libusb transport. NOT touched recently.

## 2. Build & run

```bash
# Build (from the app dir; nix flake is searched upward, "Git tree dirty" warning is normal)
cd /mnt/NAS-Zeno/OpenCode/TobiiForX4Linux/applications/tobiifree-opentrack
nix develop . --command zig build -Doptimize=ReleaseSafe \
  --cache-dir /tmp/zig-cache-opentrack-guiNN -p /tmp/zig-out-opentrack-guiNN

# Run the TESTING daemon (TOBII_TRACE=1 prints the per-frame trace line)
DISPLAY=:0 TOBII_TRACE=1 /tmp/zig-out-opentrack-guiNN/bin/tobiifree-opentrack --preset x4-smooth \
  > /tmp/gui-trace-testing.log 2>&1 &
```

GUI sliders/dropdowns live-update the running pipeline. Presets switch live from the dropdown. Trace log grows fast (~11k frames in 2 min).

## 3. Presets (BUILTIN_PRESETS, 6 total)

All share: gaze_scale 40, gaze_scale_pitch 30, smoothing 0.90, pos_smoothing 0.95, deadzone 0.15, eye_ratio 0.15, pitch_gain 1.0, pos_gain 2.0, neck 13, curve_mode 2 (tobii), curve_exp 0.5, **flip_yaw=true** (required for X4 — see sign conventions).

| Preset | max_yaw | max_pitch | head_gain |
|---|---|---|---|
| `tobii-official` | 180 | 90 | 2.0 |
| `x4` | 120 | 90 | 2.0 |
| `x4-smooth` | 120 | 90 | 2.4 (user's +20% test boost, KEEP) |
| `tobii-official (old)` / `x4 (old)` / `x4-smooth (old)` | — | — | pre-rework snapshots, identical params to current (kept for one-click A/B) |

User presets file: `~/.config/tobiifree-opentrack/presets.json` (currently deleted/empty — built-ins only).

## 4. CRITICAL sign conventions (verified in traces, do not "fix" these)

- Interocular `atan2(ez, ex)` is **POSITIVE on head-LEFT** — opposite to X4's expectation → `flip_yaw=true` on ALL presets. `hp`/`yaw` in the trace are post-flip (head-right = +).
- **Gaze screen coords (right/up = +) already match X4 — the gaze tug must NEVER be flipped** (flipping it inverted the tug: glance right → yank left; fixed in d297253).
- Pitch: head up = positive pitch. Eye-Y in Tobii coords: +Y is down-ish, handled by ref-relative `atan(dy/neck)`.
- `yaw` and `gaze_yaw` share sign in the trace (verified at corners: yaw +12.1 with gy +18.8 on the right corner).

## 5. Pipeline order (process() in tobii_filter.zig)

1. Validity gate + zero-vector shield; `center` = eye midpoint with half-IPD compensation for n=1 (X only).
2. `rot_both` = IPD in [45,80]mm AND ex>0 (eye-swap shield). inter_yaw = atan2(ez,ex), inter_roll = atan2(ey,ex).
3. n=0 → **hold last_out** (`was_lost=true` set here for instant re-acquisition).
4. Ref settle (90-frame average at startup) / manual recenter (instant capture).
5. Gaze filtering (GazeStateFilter dynamic EWMA) → gaze_yaw/gaze_pitch (scaled).
6. Head rotation:
   - n=2: interocular yaw/roll authoritative. **Glitch clamp**: |rel_yaw−last_good|>10°/frame OR |pitch_est−last_good_pitch|>5°/frame → hold last-good pose (pitch_glitch_deg=5, pitch can never pin to the ceiling from a tracker eye-Y jump).
   - n=1→n=2 re-acquisition (was_n1/was_lost) → re-arm last_good to the REAL pose + `rot_yaw/rot_pitch/roll_s.resetTo()` the smoothers (instant adopt, no easing lag). Pitch re-arm refuses estimates >5°/frame from last good.
   - n=1: yaw/roll hold, drift toward `yaw1e = atan((center[0]−ref_mid[0])/neck)` **only when |last_good_yaw| > n1_drift_gate_deg (6°)** at 10°/frame pre-gain (~24°/s final); pitch live with Y-sanity (|center[1]−last_good_y|>25mm → hold).
7. flip_yaw/flip_pitch → head_gain multiplier.
8. VOR gate (dir_gate × speed_gate) eased at gate_react=8/s (~120ms) → gate_eff. Gaze tug = gaze·eye_ratio·gate_eff added **post-curve**.
9. **Corner hold** (gaze-witnessed peak-hold): |gy|>12° arms it; tracks peak pre-curve yaw; if the estimate sags >0.5° below peak → feed peak back into the curve (view waits at the corner). Releases when |gy|<12°; sweeps back at smoothing rate (no pop). Cleared on reset().
10. Response curve (catmull-rom spline, tobii mode) + cap (max_yaw/max_pitch) + deadzone.
11. Translation (pos_x/y/z, ref-relative, pos_gain 2.0, heavier smoothing; n=1 holds then blends at unstick_rate 2/s after n1_hold_s 0.5s).

**NO auto-recenter exists anymore** (removed per user directive "never auto center"). Only the startup settle and the GUI **Recenter button** (instant capture) reset the ref. Re-acquisition holds last pose then jumps to the new one — that is the intended behavior.

## 6. Curves

- `YAW_PTS`: (0,0),(4,30),(12,70),(20,100),(35,160) — proportional ramp; middle boosted +20% this session.
- `PITCH_UP_PTS` = `PITCH_DOWN_PTS` = (0,0),(2,0),(10,25),(20,90) — **symmetric** since this session (up was (10,20),(20,50),(30,90) = "up weaker than down").
- applyCurve: catmullRom normalized (yaw/180, pitch/90) × cap, clamp.

## 7. Trace line format (TOBII_TRACE=1)

```
hp gy rw hpd gpd rp yaw pitch [ex ey ez roll] fy fp cen=(x,y,z) ref=(x,y,z) yref rref fb gt ge ch n n1t lg fc fya fyp mode
```
- hp=head_yaw(post-flip,post-gain), gy=gaze yaw, rw=fy_head (yaw output pre-gaze), hpd=head pitch, gpd=gaze pitch, rp=fp_head, yaw=smoothed yaw (post-corner-hold), pitch=smoothed pitch, ex/ey/ez/roll only when both eyes valid, fy/fp=final output, cen/ref=eye center / reference, yref/rref=interocular refs, fb=1 when NOT both-eyes, gt/ge=raw/eased gate, **ch=corner-hold active**, n=eye count, n1t=n=1 timer, lg=last_good_yaw, fc=one-euro cutoff, fya/fyp=flip flags, mode=smoother name.

## 8. Session findings (evidence in /tmp/gui-trace-testing.log and earlier live25..29 logs)

- **Corner "reset to center"** = interocular yaw estimate saturates/reverses at the tracking edge (eyes stay "seen", n=2, but atan2 collapses; e.g. f5748: yaw +12.1→+1.9 in 6 frames while gaze pinned +18.8). NOT eye loss. → corner hold (ch=1).
- **Pitch pinned +90°** = tracker eye-Y jump (+40mm at frame ~3500, hpd went +30° and stayed; fp pegged at cap for 12k frames). A re-acquisition Y-glitch that was adopted as a "new pose". → pitch_glitch_deg=5 hold + n=1 Y-sanity (25mm) + re-arm pitch sanity.
- **Re-acquisition lag** (up to 31 frames, catchup) = glitch clamp latched the OLD pose after the eyes returned (has_last_good never re-armed after n=0) + one-euro state stale. → was_lost + resetTo().
- **n=1 near-center drift overshoot** (761-813: hp frozen +3.8, yaw drifted to +8.9) = single-eye dx is lean translation near center. → drift gated at |yaw|>6°.
- **Jitter** was gate 1↔0 snapping the gaze tug (fixed with eased gate) and a flipped gaze tug (fixed). Head-still output jitter now p50 0.19°, max 0.27°.
- Left-side lag complaint: left corners reached further (-17.8° vs +12.1° right) in user tests — partially user behavior, partially n=1 stretches; verify with corner drift fix.
- yaw1e calibration: post-gain hp ≈ 0.36·yaw1e (median 0.36, verified RIGHT +15.5°/LEFT −18.8°).
- Preset switching mid-test works; the startup log line shows the initial preset only.

## 9. Open items / next session

1. **User test gui17**: corners (hold at corner, one-eye continuation past halfway), re-acquisition (turn out of range, come back — must snap, not lag), pitch up=down, center feel, jitter. User switches to tobii preset + 160° yaw cap in the GUI during tests.
2. Known open: the corner drift gate (6°) means n=1 near center HOLDS yaw — verify no dead zone on fast center crossings with one eye.
3. If pitch still weak overall: consider raising pitch cap (user previously chose "keep 90°").
4. Recenter button: implemented instant capture + has_last_good re-arm; user hasn't confirmed it works in-game yet.
5. Release binary + GitHub release if user asks (v0.3.0 exists at release tag; next release candidate = gui17).

## 10. Commands cheat sheet

```bash
# Restart testing daemon (gui17):
DISPLAY=:0 TOBII_TRACE=1 /tmp/zig-out-opentrack-gui17/bin/tobiifree-opentrack --preset x4-smooth > /tmp/gui-trace-testing.log 2>&1 &

# Stop bridge (keep tracker daemon):
pkill -f 'tobiifree-opentrack'   # NOTE: never pkill -f 'tobiifree' (kills tobiifreedot + self)

# Commit/push:
git add -A && git commit -m "..." && git push origin main
```