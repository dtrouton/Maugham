# Batch J: two test-flake fixes (#99, #97) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Two test-only fixes. Production code is unchanged unless a `…ForTesting` seam needs a per-folder counter (the #94 shape). Read each issue (`gh issue view <n>`) first.

**Spec:** issues #99, #97.

## Rulings (controller)
- **#99:** follow the issue's fix shape exactly. Wait on `onMetricsChanged` through an expectation with a generous timeout (5 s). After a short settle, assert the count is still 1. Replace every `deliveries[0]` with `XCTUnwrap(deliveries.first)`. Convert every `awaitDebounce` user in `MaughamTests/Editor/CoordinatorMetricsTests.swift`; a test that asserts NO delivery keeps a bounded sleep, with a comment saying why. Tripwire 33 applies only to mounted press-then-wait; this suite is unmounted.
- **#97:** option (a). Make SegmentSealTriggerTests' exact verify count per project folder: filter the observer's reports by this test's root, or add a folder-scoped counter in the established `…ForTesting` style. Grep `MaughamTests/` for other exact-count assertions on process-wide `…ForTesting`/`…ObserverForTesting` seams around a `DocumentStore`. Convert any that share the hazard and list them in the report. Leave (b) and (c) out.

## Global Constraints
- Fixtures under `TestTemp.root`. `./gen.sh` after adding files. Run `./scripts/test.sh`, plus `./scripts/test.sh core` if you touch Core. Never raw xcodebuild test, never `pgrep -f xcodebuild`. A Core run ending with only a "started." line is the known flake: re-run.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage by path.

## Review Focus
1. Neither fix weakens what the tests prove: exactly-once still holds, and the verify count still catches a second verify of THIS book.
2. No new fixed sleeps on a positive path.

### Task 1: CoordinatorMetricsTests waits on the delivery (#99)
Commit: `test(editor): metrics tests wait on the delivery, not a clock (#99)`
### Task 2: Exact seam counts are per folder (#97)
Commit: `test(oplog): the seal-trigger verify count is this book's only (#97)`
