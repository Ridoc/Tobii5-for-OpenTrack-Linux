# AGENTS.md — TobiiArgus
META:
  FIRST: "FOLLOW ~/.config/opencode/AGENTS.md; STATE_STORE=.docs/; ROUTER=.docs/index.yaml"
  GLOBAL: "~/.config/opencode/AGENTS.md auto-injected every session via config instructions — generic orchestration fallback"
  LOCAL_IS: "project-specific complement (commands, paths, subagent wiring) — materialized by architect at init; do NOT duplicate global here"
  PROJECT: "TobiiArgus = Tobii ET5 → OpenTrack UDP bridge for Linux games (X4: Foundations)"
  LICENSE: GPL-3.0 fork Aetherall/tobiifree
  NAMING: brand=TobiiArgus; bins/packages=tobiifree* (DO NOT RENAME)
CMDS:
  SHELL: "nix develop (.envrc direnv); runner=just"
  check: typecheck-sdk + test-zig
  test-zig: cd driver && zig build test
  bundle: wasm rebuild → base64 embed sdk/src/wasm-bundle.ts [GENERATED; REQUIRED after driver/src edit]
  RUN_ORDER: just tobiifreedot → just opentrack (daemon owns USB); bridge=GUI+--headless
  SMOKE: try-daemon|try-overlay-usb|try-overlay-daemon (3s timeout)
  GAPS: NO CI/NO linters; daemon/bridge/overlay NO unit tests → manual ET5 verification
ARCH:
  DRIVER: TTP/TLV "Tracker"; 3 builds: wasm32(ReleaseSmall),native-linked,tests
  NO_REG: apps/*/build.zig imports ../../driver/src/*.zig via RELATIVE → driver edits hit ALL
  DAEMON: tobiifreedot OWNS USB; sock $XDG_RUNTIME_DIR/tobiifreedot/gaze.sock (+--ws)
  BRIDGE: gaze→head-pose → UDP 127.0.0.1:4242 (48B LE doubles) for OpenTrack
  SPECS: [.docs/protocol.yaml, .docs/bridge-pipeline.yaml, ARCHITECTURE.md, docs/x4-foundations-opentrack.md]
NFS_BUILD:
  PATTERN: cd applications/<app> && zig build -Doptimize=ReleaseSafe --cache-dir /tmp/zig-local-cache-<tag>
  PARK: zig-out/bin/ (gitignored)
  DAEMON: applications/tobiifreed/zig-out/bin/tobiifreedot
  BRIDGE: applications/tobiifree-opentrack/zig-out/bin/tobiifree-opentrack
  STAMP: BUILD_INFO.txt per zig-out/
ENV:
  USB: ONE process claims ET5 → killall tobiifreedot before restart
  HIBERNATE: unplug/replug USB cable; daemon alone does NOT recover; restart bridge too
  EYES_OFF: no eyes ⇒ NO UDP (BY DESIGN); calibrate REQUIRES human at screen
  STALE_CAL: stale ~/.config/tobiifree-opentrack/calibration.json (e.g. negative gaze_y_scale from an old transform) SILENTLY flips Y → after ANY geometry/transform change, delete it + rerun wizard; verify gaze_y_scale is positive
  AXIS_ASSUME: NEVER assume the device coordinate origin/direction (v0.2.x repeatedly guessed bottom-anchored/GUI-style). Confirm empirically (raw_y range + glance direction) before writing any transform
  LIBS: gtk4/libusb from nix shell; outside needs LD_LIBRARY_PATH→nix store
WORKFLOW:
  SUBAGENTS:  # DEFAULT pipeline — spawn automatically, NEVER wait for request
    qa-tester: "task(qa-tester, cmd='just check' OR 'cd driver && zig build test') — ALWAYS after code changes; FAIL→fix→resp×3→HALT"
    security-reviewer: "task(security-reviewer, diff=git.diff()) — ALWAYS when diff touches USB|socket|network|file-io|auth|package.json"
    ux-reviewer: "task(ux-reviewer) — ALWAYS for user-facing features (bridge GUI, calibration wizard, overlay, CLI flags)"
    librarian: "task(librarian) — ALWAYS at session end + post-commit: sync .docs/*.yaml (dev-env, resolved, session, tech-debt OPEN-only) + commit"
  SYNC: bugs→.docs/tech-debt.yaml (OPEN only; confirmed→.docs/resolved.yaml); session→.docs/session.yaml; release→.docs/release.yaml
  RELEASE: qa gate(just check) → commit → tag vX.Y.Z → push → gh release; keep CHANGELOG.md current
