# Batch H: a flaky posture test made deterministic, a canvas-closure tripwire, a live since-line (#94, #59, #53) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three low-severity board items. Each is its own task, with its own tests. Read the issue (`gh issue view <n>`) first: each one carries its fix shape and references.

**Tech Stack:** Swift, SwiftUI, XCTest.

**Spec:** issues #94, #59, #53.

## Rulings (controller)

- **#94 evidence:** CI run 39154714131's xcresult, artifact `TestResults-Mac` id 12147290580, downloaded under the session scratchpad. Its failing assertion was `XCTAssertEqual failed: ("1") is not equal to ("0") - no registry was resolved, anywhere`. So the RegistryCache resolve counter saw one resolve that this test did not cause. The likeliest cause is a process-wide counter or a static shared with another test in the same parallel worker, or a late async resolve from an earlier test.
  - Fix the TEST's isolation, not production behaviour: scope the counter to this test's book or cache instance, or reset-and-await properly.
  - If a production static is the shared seam, give it a test-scoped instance in the established `…ForTesting` style.
  - Prove the fix: name the racing path in the commit message, and show a deterministic reproduction if one is feasible (e.g. a forced interleaving).
- **#59:** a source census in `TripwireGrepTests`, in the shape the issue names, with a planted-offender self-check. Add one sentence to `Maugham/Canvas/AREA.md` ## Rules. Canvas AREA is at its ceiling (7,982 of a hard cap of 8,000), so trim or raise the ceiling with a reason. Add a row to `docs/tripwires.md` and to the CLAUDE.md tripwire table as row 57, matching the existing row style. CLAUDE.md is ceiling-budgeted too: raise the ceiling with a reason.
- **#53:**
  - Store the matched notes' identities on `CompilerRun` as an additive-optional field, with a hand-written decoder. An old run with only the count still renders today's past-tense sentence.
  - At render, filter to those still open and name the pass(es). Copy: *"· 1 still open in <Pass>"*, *"· N still open in <Pass>"*, and for several passes *"· N still open in <Pass A> and <Pass B>"* (three or more: *"<A>, <B> and <C>"*). It shows nothing when none are still open.
  - Keep the per-finding rule (two open notes with one fingerprint count once). The seal arm and `freshEyesHeader` read the same projection.
  - The issue's "mark two rows as the same finding" question is OUT of scope: leave it as is and note it in the report.
  - Update `docs/guide/` wherever the since-line's clause is described, and the Compiler AREA's two-open-notes paragraph. Compiler AREA's ceiling is 7,891 and ratchets.

## Global Constraints

- `CLAUDE.md` tripwires. Tripwire 33 (no press-then-wait). Tripwire 34 (a run never resolves its reader from the other loop's memory). Tripwire 8 (4-char paragraph ids). Read `docs/tripwires.md` for rows you touch.
- Fixtures go under `TestTemp.root`. Add no new test window except through `TestWindow`.
- AREA guides and CLAUDE.md are under `DocBudgetTests`. Ceilings ratchet: raise one only with a reason beside it. A new file must be named in its folder's AREA Map. Backticked names must be real repo paths.
- `./gen.sh` after adding a file. Use `./scripts/test.sh`, plus `./scripts/test.sh core` if you touch `Packages/MaughamCore`. Never raw xcodebuild test, never `pgrep -f xcodebuild`. If Core fails with only a `started.` line, re-run.
- Another session (nonfic) is working on the Core AREA, docs/adr 0033, possibly `docs/tripwires.md`, and DocBudgetTests ceilings. Keep edits to those small and line-local.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage by path.

## Review Focus

1. #94: the fix removes the race rather than hiding it (no retry, no sleep, no weakened assertion).
2. #59: the census catches a planted offender. It does not false-positive on `model`/`projectRoot`/`thumbnails` or `@State` reads, and it fails loudly if it can't find `load()`.
3. #53: an old `CompilerRun` with only the count decodes and renders the old sentence. A new one renders live. Settling the other-lane note between renders drops the clause. Per-finding dedupe holds.
4. #53: no raw ids or fingerprints are ever shown. Pass names come from the same source the rest of Review uses.
5. #53: the seal and fresh-eyes header agree with the since-line.

---

### Task 1: The posture test can't see another test's registry resolve (#94)
See Rulings. Commit: `test(posture): the no-registry test counts only its own resolves (#94)`

### Task 2: A canvas closure never reads a frozen view property (#59)
See Rulings and the issue's fix shape. Commit: `test(tripwire): load()'s closures read no changing view value (#59)`

### Task 3: The since-line's other-lane clause is live and names the pass (#53)
See Rulings and the issue's fix shape. Commit: `fix(review): the since-line names which pass still holds a finding, live (#53)`

### Finish
- [ ] `./scripts/test.sh full` green.
- [ ] Whole-branch review (opus), told not to build.
- [ ] Ping nonfic before merge.
- [ ] PR closing #94, #59 and #53.
