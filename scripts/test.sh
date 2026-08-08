#!/bin/bash
# test.sh — one command for the test loops everyone retypes.
#
#   ./scripts/test.sh          # fast: core package + Mac scheme minus the two slow suites
#   ./scripts/test.sh full     # core package + full Mac scheme (pre-merge/tag gate)
#   ./scripts/test.sh phone    # the iOS simulator run (slow; CI runs it on every push)
#
# fast skips exactly two things, both documented in CLAUDE.md's build-flow notes:
#   - MCPServerLifecycleTests: three wall-clock-dependent tests that fail under a
#     loaded suite and pass in isolation (docs/superpowers/notes/2026-07-29-…).
#     full skips them too — that IS the documented complete local run.
#   - the CanvasViewMounting* family (Surface/Editing/Region — three subclasses
#     of CanvasViewMountingCase): ~70 s of per-test window mounts; NOT optional
#     before merge/tag, which is why full includes it. Skipping the base class
#     name does nothing — XCTest schedules the concrete subclasses.
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
    echo "▸ Mac scheme (skipping MCPServerLifecycleTests + the CanvasViewMounting* family)"
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
      CODE_SIGNING_ALLOWED=NO \
      -skip-testing:MaughamTests/MCPServerLifecycleTests \
      -skip-testing:MaughamTests/CanvasViewMountingSurfaceTests \
      -skip-testing:MaughamTests/CanvasViewMountingEditingTests \
      -skip-testing:MaughamTests/CanvasViewMountingRegionTests
    ;;
  full)
    run_core
    echo "▸ Mac scheme, full (skipping only MCPServerLifecycleTests)"
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test \
      CODE_SIGNING_ALLOWED=NO \
      -skip-testing:MaughamTests/MCPServerLifecycleTests
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
