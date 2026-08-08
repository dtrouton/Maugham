#!/bin/bash
# test.sh — one command for the test loops everyone retypes.
#
#   ./scripts/test.sh          # fast: core package + Mac scheme minus the two slow suites
#   ./scripts/test.sh full     # core package + full Mac scheme (pre-merge/tag gate)
#   ./scripts/test.sh phone    # the iOS simulator run (slow; CI runs it on every push)
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
# (parallelizable: true in project.yml, 2026-08-08): full suite measured
# 7.6 → 2.75 min. MaughamCore's 465 package tests are hosted by no scheme,
# so both modes run them explicitly via swift test (~6 s).

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-fast}"

if [[ ! -d Maugham.xcodeproj ]]; then
  echo "Maugham.xcodeproj missing — running ./gen.sh first"
  ./gen.sh
fi

run_core() {
  echo "▸ MaughamCore package tests (swift test --parallel)"
  swift test --parallel --package-path Packages/MaughamCore
}

case "$MODE" in
  fast)
    run_core
    echo "▸ Mac scheme (skipping the CanvasViewMounting* family)"
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
      CODE_SIGNING_ALLOWED=NO \
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
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
      CODE_SIGNING_ALLOWED=NO \
      -resultBundlePath "$BUNDLE"
    ;;
  phone)
    echo "▸ Phone scheme (iOS Simulator)"
    xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
      -destination 'platform=iOS Simulator,name=iPhone 17' test \
      CODE_SIGNING_ALLOWED=NO
    ;;
  *)
    echo "usage: $0 [fast|full|phone]" >&2
    exit 64
    ;;
esac
