# Batch G: Run names a run on another piece; the merge repair never claims an unclaimed piece (#83, #84) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a loop runs on another piece, Run says so and refuses up front, with no idle-looking dead button. A merge-time repair never writes into a piece nobody has claimed yet.

**Architecture:** Both fixes sit on seams that already exist. **Read `docs/superpowers/notes/2026-10-19-batch-g-research.md` first**: it has every file:line, the tests that flip, and the census facts.

**Tech Stack:** Swift, SwiftUI, XCTest.

**Spec:** issues #83 and #84, plus Denver's ruling (2026-10-19).

## Rulings

- **Denver (#84):** the repair is skipped (option a) while the piece is unsettled (`localWritePermit.unsettledStarter` is non-nil). The splice stays visible and is logged. It repairs itself at a later merge once the piece is claimed. Never write in the author's name into an unclaimed piece.
- **Controller (#83):**
  - Review's copy is *"A round is running on “<title>” — Run waits until it finishes."* Author's copy is *"A check is running on “<title>” — ⌘R waits until it finishes."* With no title, use *another piece*, never the raw id.
  - Run is refused. Cancel is offered, as on F7's line, and stops that run (one session per window).
  - The title comes from a pure lookup in the store's manifest structure that the view already has. No new observable state.
  - The cold-start Read button the research found (`DiagnosticsPane`) is also disabled while any run is in flight, because it is the same kind of dead control.

## Global Constraints

- Tripwires 6, 33 (no press-then-wait, no synthesized clicks), 34, 46/47/49/51/52. Read `docs/tripwires.md` for any row you touch. The research says #84's spelling is already admitted by the tripwire-51 allow-list for `Document+Annotations.swift`. Verify that; if a census test reds, fix the code, not the census, unless the census row is clearly the documented home.
- Tests are windowless and pure-state. Fixtures go under `TestTemp.root`. Paragraph ids use the valid 4-char alphabet (tripwire 8).
- AREA.md files are under `DocBudgetTests`, with a hard cap of 8,000 words. Ceilings ratchet: raise one only with a reason beside it. Any file you ADD must be named in its folder's AREA Map. Backticked names in a guide must be real repo paths.
- `./gen.sh` after adding a file. Iterate with `./scripts/test.sh`. Never `pgrep -f xcodebuild`, and never run raw xcodebuild test. If Core fails with only a `started.` line, re-run.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Stage by path.

## Review Focus

1. A run on piece A never leaves piece B's Run enabled-and-refusing, in either loop, including the cold-start Read.
2. Cancel on the line stops exactly the one running session.
3. The line never shows a raw document id.
4. The #84 skip happens only while the piece is unsettled. A settled piece still repairs exactly as today (control test).
5. A skipped repair loses nothing: the paragraph text and the annotation state are unchanged, and a later merge after the claim repairs it.

---

### Task 1: Run names a run on another piece (#83)
Research §#83:
- Add a phase/header state for "this loop is running on another document" in `ReviewRoundCockpit.phase` and `DiagnosticsPane`'s header state (the F7 seams). It shows the Rulings copy with Cancel, and Run is disabled.
- Disable the cold-start Read while a run is in flight.
- Flip the three assertions the research names. Add pure-state tests for both loops, the no-title fallback, and same-document still showing running.
- Add one sentence each to `docs/guide/right-pane.md` and `docs/guide/review-passes.md`, at the spots the research names.
- Commit: `fix(runs): a run on another piece is named, and Run waits instead of refusing on press (#83)`

### Task 2: The merge repair waits for a claimed piece (#84)
Research §#84:
- In `repairRejectedButSplicedAnnotations`, return early with a log line when the document's `localWritePermit.unsettledStarter` is non-nil.
- Tests, modelled on the research's named `DocumentWaitingTests` shape:
  - unsettled: no write, text and annotations unchanged;
  - settled control: repairs as today;
  - after the permit settles, the next merge repairs.
- If an OpLog claims file covers this, update it (`register/`).
- Commit: `fix(oplog): the merge repair never writes into a piece nobody has claimed (#84)`

### Finish
- [ ] `./scripts/test.sh full` green.
- [ ] Whole-branch review (opus), told not to build.
- [ ] PR closing #83 and #84, with Denver's smoke steps.
