#!/bin/bash
# test.sh — one command for the test loops everyone retypes.
#
#   ./scripts/test.sh          # fast: core package + Mac scheme minus the two slow suites
#   ./scripts/test.sh full     # core package + full Mac scheme (pre-merge/tag gate)
#   ./scripts/test.sh phone    # the iOS simulator run (slow; CI runs it on every push)
#   ./scripts/test.sh core     # MaughamCore's package tests alone, behind the same lock
#
# RUN CORE THROUGH `core`, NOT A BARE `swift test`, WHILE ANY OTHER GATE MAY
# BE UP (2026-09-25, P3c plan 2 Task 9). Every `xcodebuild test` — Mac or
# phone scheme, any session's — SIGKILLs every process on the machine NAMED
# `xctest` as it starts testing, and `swift test --parallel` runs each Core
# test in its own `xctest` process. The victim is whichever Core test happened
# to be alive: the run exits 1, `Note: Some test targets reported failures`,
# and the only output is that test's `Test Case '…' started.` with nothing
# after it — no assertion, no crash report, a different test each time, green
# alone and on a re-run. Measured with a decoy: a copy of /bin/sleep named
# `xctest` was killed (status 137) ~2 s before an unrelated `xcodebuild test`
# printed "Testing started", while the same binary under another name lived.
# The `core` mode takes the gate lock, so it queues behind this script's gates
# (and they behind it); a RAW `xcodebuild test` from another session bypasses
# the lock and can still kill it — re-run before believing a red Core test
# that matches that signature.
#
# fast skips exactly one thing, documented in CLAUDE.md's build-flow notes:
#   - the CanvasViewMounting* family (Surface/Editing/Region — three subclasses
#     of CanvasViewMountingCase): ~70 s of per-test window mounts; NOT optional
#     before merge/tag, which is why full includes it. Skipping the base class
#     name does nothing — XCTest schedules the concrete subclasses.
#
# full skips NOTHING. The old MCPServerLifecycleTests skip was retired
# 2026-08-08: those three wall-clock MCP tests failed only under a saturated
# single-process serial suite, and per-class parallel workers removed the
# trigger — burn-in evidence in docs/superpowers/notes/2026-07-29-mcp-clock-
# dependent-tests.md's resolution section. If they ever flake again, check for
# OTHER sessions' xcodebuild first (CLAUDE.md's third confounder).
#
# The Mac scheme runs its test classes in parallel worker processes
# (parallelizable: true in project.yml, 2026-08-08): full suite 7.6 min →
# 2.75 min on the first parallel run, → ~90s after the canvas-mounting class
# split. MaughamCore's 465 package tests are hosted by no scheme, so both
# modes run them explicitly via swift test (~6 s).
#
# THE GATE IS HEADLESS (2026-08-27). Every worker is an `.accessory` app
# (`TestHost`, no Dock tile, no ⌘-tab entry) and every mounted-view test
# builds its window through `TestWindow` (MaughamTests/TestSupport) — real,
# on screen for SwiftUI's purposes, drawn at alpha 0 and deaf to the mouse.
# Nothing here should be visible while it runs, and nothing takes your
# keyboard: the host never activates itself unless the run opts in with
# MAUGHAM_ALLOW_ACTIVATION=1 (CI does; the runner has nobody to interrupt).
# Measured 2026-08-27: the click-driving suites (TreeTravelTests) land their
# clicks on the inactive accessory host anyway, so a plain local gate runs
# them too; they skip BY NAME only where the click measurably fails (a locked
# screen). To force activation here regardless:
#
#   TEST_RUNNER_MAUGHAM_ALLOW_ACTIVATION=1 ./scripts/test.sh full

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-fast}"

if [[ ! -d Maugham.xcodeproj ]]; then
  echo "Maugham.xcodeproj missing — running ./gen.sh first"
  ./gen.sh
fi

# ---- cross-session gate lock -------------------------------------------------
# Several Claude sessions share this Mac, and two overlapping full gates host
# 14+ app processes: starvation-shaped failures land on a DIFFERENT victim each
# run (measured 2026-08-08 — CLAUDE.md's third confounder). Queueing gates
# behind a machine-global lock turns that documented hazard into a non-event.
# mkdir is atomic and macOS ships no flock(1); the pid file lets a crashed
# holder's lock be reclaimed instead of wedging every later run.
GATE_LOCK="${TMPDIR:-/tmp}/maugham-test-gate.lock"
acquire_gate_lock() {
  local waited=0
  while ! mkdir "$GATE_LOCK" 2>/dev/null; do
    local holder
    holder=$(cat "$GATE_LOCK/pid" 2>/dev/null || echo "")
    if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
      echo "gate lock held by dead pid $holder — reclaiming"
      rm -rf "$GATE_LOCK"
      continue
    fi
    if [[ "$waited" -eq 0 ]]; then
      echo "another test gate is running (pid ${holder:-unknown}) — queueing behind it"
    fi
    sleep 5; waited=$((waited + 5))
  done
  echo $$ > "$GATE_LOCK/pid"
  trap 'rm -rf "$GATE_LOCK"' EXIT
}
acquire_gate_lock

run_core() {
  echo "▸ MaughamCore package tests (swift test --parallel)"
  swift test --parallel --package-path Packages/MaughamCore
}

# A PARKED TEST MUST BE KILLED AND NAMED, not left to eat the gate.
#
# CI has passed these two since it was written; local runs did not, and the
# difference cost three whole local gates on 2026-08-14/15. A single test in
# `MCPServerLifecycleTests` parked forever with no deadline, no output and no
# test name — under CI's allowance it would have died at 120s carrying its own
# name, which is the entire difference between a diagnosable failure and a dead
# afternoon. 120s matches CI exactly; the slowest honest test in the suite is
# well under a tenth of it (the mounted-canvas family, ~9s).
TIMEOUTS="-test-timeouts-enabled YES -default-test-execution-time-allowance 120"

case "$MODE" in
  fast)
    run_core
    echo "▸ Mac scheme (skipping the CanvasViewMounting* family)"
    # shellcheck disable=SC2086
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
      CODE_SIGNING_ALLOWED=NO $TIMEOUTS \
      -skip-testing:MaughamTests/CanvasViewMountingSurfaceTests \
      -skip-testing:MaughamTests/CanvasViewMountingEditingTests \
      -skip-testing:MaughamTests/CanvasViewMountingRegionTests
    ;;
  full)
    run_core
    # Keep an xcresult: parallel-mode stdout does NOT carry assertion messages,
    # so without the bundle an in-suite flake leaves nothing to diagnose (the
    # 2026-08-08 WindowedTypographyEquivalenceTests one-off failed at 0.000s
    # with no recoverable detail — never again).
    BUNDLE="${TMPDIR:-/tmp}/maugham-full-$(date +%Y%m%d-%H%M%S).xcresult"
    echo "▸ Mac scheme, full — no skips (result bundle: $BUNDLE)"
    # shellcheck disable=SC2086
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
      CODE_SIGNING_ALLOWED=NO $TIMEOUTS \
      -resultBundlePath "$BUNDLE"
    ;;
  core)
    run_core
    ;;
  phone)
    echo "▸ Phone scheme (iOS Simulator)"
    xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
      -destination 'platform=iOS Simulator,name=iPhone 17' test \
      CODE_SIGNING_ALLOWED=NO
    ;;
  *)
    echo "usage: $0 [fast|full|phone|core]" >&2
    exit 64
    ;;
esac
