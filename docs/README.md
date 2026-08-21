# Project Documentation

Index of the human-readable documentation for
**Tobii ET5 → OpenTrack for Linux** (repo `Ridoc/Tobii5-for-OpenTrack-Linux`).

## Top-level

| Doc | What it covers |
|---|---|
| [README.md](../README.md) | What the project is, compatibility, quick start, CLI flags, tuning |
| [CHANGELOG.md](../CHANGELOG.md) | Version history (v0.1.0, v0.1.1, unreleased v0.2.0) |
| [PLAN.md](../PLAN.md) | Original plan: goals, key facts, architecture sketch, scope |
| [ARCHITECTURE.md](../ARCHITECTURE.md) | Consumer API (`Source`), Tracker, daemon protocol, implementation status |

## In-depth

| File | What it covers |
|---|---|
| [x4-foundations-opentrack.md](x4-foundations-opentrack.md) | **Main deep-dive**: pipeline stages (gaze filter, head pose, validation, recenter, blend, smoothing, curve), tuning table, troubleshooting, file layout |
| [session-continuation.md](session-continuation.md) | Session notes / development log with key decisions |

## Internal machine-readable memory (`.docs/`)

Not human-facing prose; a YAML tree consumed by the agent workflow
(`.docs/index.yaml` is the L0 router):

| Leaf | Domain |
|---|---|
| `.docs/architecture.yaml` | System architecture snapshot |
| `.docs/protocol.yaml` | Daemon framing/commands + OpenTrack UDP wire format |
| `.docs/bridge-pipeline.yaml` | Filter pipeline, presets, defaults, UX constraints |
| `.docs/calibration-wizard.yaml` | v0.2.0 wizard state machine, gates, fixes, status |
| `.docs/release.yaml` | Tag/release ledger + pending v0.2.0 pipeline |
| `.docs/tech-debt.yaml` | Known issues / accepted workarounds |
| `.docs/session.yaml` | Current session state |

## Quick pointers

- **Run order**: daemon (`tobiifreedot`) → bridge (`tobiifree-opentrack`) →
  game. See README "Quick start".
- **X4 native setup**: Options → Controls → OpenTrack Support; Ctrl+T engages,
  Scroll Lock recenters (X4 handles it).
- **Post-hibernation**: unplug/replug the ET5 USB cable, then restart daemon
  *and* bridge.
- **Build on NFS**: use `--cache-dir` on local storage (see
  `x4-foundations-opentrack.md`).