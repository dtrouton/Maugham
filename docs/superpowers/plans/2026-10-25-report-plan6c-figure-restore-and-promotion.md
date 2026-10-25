# Report plan 6c — figures in checkpoint restore and promotion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the last of plan 6. Restoring a checkpoint winds a figure's contents back with the text, and making a collection piece its own project brings its figures along instead of dropping them.

**Architecture:**
- **Restore is ordinary figure ops.** A pure Core diff (`FigureRestoreDiff`) compares a figure's state at the checkpoint with its state now, by id, and yields figure ops (revive, delete with its removed slice, cell sets, moves, settings, pins). The figure host appends them with `provenance.sourceCheckpoint`. No new op kind and no new `SynthesisSource`.
- **Promotion re-creates.** Each carried figure is rebuilt in the staged project from its current derived state by this device's author, keeping its figure, row and column ids, so formulas, sidecars and research references still resolve. Its history stays in the Collection, as the manuscript's does.

**Tech Stack:** Swift 5.10, MaughamCore, SwiftUI/AppKit (Mac stores and the existing restore picker; no new screens), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §12 item 6 (amended 2026-10-25: translations and Research versions moved to plan 9). Survey of the built code (main @ 4658fff4): `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan6c-survey.md`, sections C (checkpoints), D (promotion), E (cross-cutting). Re-verify every line number against the code.

## Global Constraints

- **Hard invariants** (CLAUDE.md): the op log is truth; a figure's state comes from `FigureCache` / the open host, never `figures/*.csv` (tripwire 20); plain text on disk.
- **Denver, 2026-10-25:** 6c is checkpoint restore and promotion only; text-cell translations and Research version history move to plan 9; promotion re-creates figures and leaves their history in the Collection (my recommendation, accepted with "ok go").
- **Rulings made writing this plan** (ledger them):
  - **Q-1 restore reach:** a checkpoint holds one op id per figure, so restore reaches contents only — cells, rows, columns, settings, pins. It leaves alone: figures created after the checkpoint (no pointer), figures whose record is gone (removed or promoted), renames. A parked figure is skipped and named in the result ("in Research — bring it back first"). A picture whose checkpoint bytes are no longer on disk is skipped and named; one whose bytes are present (same content hash in `figures/` or the host's undo folder) is restored.
  - **Q-2 restore door and undo:** each figure asks `.editFigure` through `settledPosture(forDocId:)`; a refused figure is named and skipped, like a refused document in `splitByTheDoor`. No ⌘Z, matching today's partial restore.
  - **Q-3 restore scope:** whole-project scope covers every registered figure; document scope covers that document's figures (`FigureRecord.piece == docId`).
  - **Q-4 promotion carries:** the piece's own figures (`piece == pieceId`), plus any figure its text or its carried figures' formulas reference (whole-book or another piece's, transitively). A carried figure that belonged to the piece leaves the Collection through the 6b removal route (a restorable Trash entry); a referenced figure that belongs elsewhere is copied and stays.
  - **Q-5 promotion keeps ids:** figure ids, row and column ids and research item ids are kept, so formulas by id, Research-table sidecars and pins resolve. A formula or pin reading Research that stays behind is listed in the promotion's result as a problem (it renders `#REF!` in the new project).
  - **Q-6 parked at promotion:** a parked figure of the piece is re-created and then parked again (`figureParked` naming its carried working copy), so it stays "in Research" in the new project.
- **Census rule:** new figure mutators use `requireWritable("…")` and join tripwire 52's writer census; new file writes go through `SafeRelativePath` change forms (tripwire 58); promotion's staging moves are raw with `// internal-move: staging` and return a `PromotionStagedMove` for rollback (tripwire 14's census). Extend censuses with planted offenders; never exempt.
- **Schema:** no new wire word is expected. If one proves necessary, it rides schema 10 with a sentence in `ProjectManifest.swift`'s history paragraph.
- **Gates:** `./scripts/test.sh core` after Core changes; `./scripts/test.sh` after Mac changes; `./gen.sh` after adding a file; `./scripts/test.sh full` and `./scripts/test.sh phone` at the whole-branch review. A run ending only in "Test Case … started." was killed by another session's `xcodebuild`: re-run.
- **Area guides:** OpLog (7,999), Stores (7,997) and Views (7,995) are at the 8,000-word cap: make room by moving why-clauses to `docs/history/<area>.md` first. Every guide word change adjusts its `DocBudgetTests` ceiling by the exact count with a `+N report plan 6c Task K:` comment.
- Never qualify `Document` in test files. `TestTemp` is the one temp root. Paragraph-id literals in tests use the valid alphabet (tripwire 8).

## Review Focus

1. **Restore a checkpoint taken before a row was deleted and a column added, after another device edited a cell in the added column**: the row returns in its slot with its cells, the column goes (its cells in the removed slice), and the restored figure equals the checkpoint state cell for cell. Tasks 1–2.
2. **Whole-project restore with one figure parked and one created after the checkpoint**: the parked one is skipped and named, the new one is untouched, the rest restore, and the text restores as before. Task 3.
3. **Promote a piece whose text cites a whole-book figure whose formula reads a second whole-book figure and a Research table that stays in the Collection**: both figures arrive with their ids, the formula computes in the new project, the Research read is listed as a problem, and the Collection keeps both whole-book figures. Tasks 4–5.
4. **Promotion fails after the figures are written into staging** (seam): the staging folder is rolled back, the Collection is unchanged, and no figure record has left it. Task 5.
5. **Promote a piece with a parked figure**: the new project shows it in Research with its working copy and sidecar, and bringing it back there works. Task 5.

---

### Task 1: The restore diff (Core)

**Files:** new Core `Table/FigureRestoreDiff.swift`; Core `AREA.md` Map row. Tests: new Core `FigureRestoreDiffTests.swift`.

**Interfaces — Produces:**
- `FigureRestoreDiff.target(of ops: [Op], through pointer: String) -> FigureState` — the fold of the stream's ops with `opId <= pointer` (the same approximation `PartialRestorePicker` uses for text).
- `FigureRestoreDiff.changes(from current: FigureState, to target: FigureState) -> [FigureReturnDiff.Change]` — pure, by id. Reuse `FigureReturnDiff.Change`, `everyChangeApplies(_:onto:)` and its simulation (make them internal-shared if private); do not reuse the CSV matcher.

**Contract** (survey C "What a figure restore needs"):
- Row or column live in target and tombstoned now → `revive_row`/`revive_column` carrying the target's slice. Live now and absent or tombstoned in target → delete carrying `removedSlice`. Inserted since (unknown to target) → delete. Order differs → moves. Cells differ → cell sets with `prior`. Header rows, total row, widths, formats → settings. Pins differ → pin set/clear. Picture hash differs → one image change (the caller decides whether bytes exist, Task 2).
- Applying the changes to `current` yields a state whose table equals `target`'s (cells, order, settings, pins). Pin it with a property-style test over several hand-built histories.
- A target or current that is parked is the caller's concern; the diff is pure.

- [ ] Write failing tests: Review Focus 1 as a pure fixture; an empty diff when nothing changed; revive carries the slice; a row inserted since is deleted with its slice; the round-trip equality check over five histories.
- [ ] Run red; implement; `./scripts/test.sh core`; commit.

### Task 2: The host restores a figure (Mac)

**Files:** `Maugham/OpLog/FigureDocument.swift` (new mutator); `MaughamTests/TripwireGrepTests.swift` (tripwire 52 lists); tests in `MaughamTests/OpLog/FigureDocumentTests.swift` or a new `FigureRestoreTests.swift`.

**Interfaces — Produces:** `FigureDocument.restoreToCheckpoint(_ checkpointId: String, target: FigureState) async throws -> FigureRestoreOutcome` where `FigureRestoreOutcome` is `.restored(opCount:)`, `.unchanged`, `.skippedParked`, `.skippedPicture(hash:)`.

**Contract** (pattern: `resumeFromResearch(changes:picture:expecting:)`; rulings Q-1, Q-2):
- `requireWritable("restoreToCheckpoint")`; a parked figure returns `.skippedParked` without appending.
- Compute changes with Task 1 against the host's current state; validate with `everyChangeApplies` before appending anything; append each with `provenance.sourceCheckpoint = checkpointId`, signed by the host's actor; one render after the last.
- A picture change applies only when the target hash's bytes exist (in `figures/` or the host's undo folder); otherwise the rest restores and the outcome names the picture.
- No undo registration (Q-2).

- [ ] Write failing tests: a host restores Review Focus 1 and every appended op carries the checkpoint id; a parked figure is skipped; a refused posture throws before any op; a picture with missing bytes restores the cells and reports the picture.
- [ ] Run red; implement; `./scripts/test.sh`; commit.

### Task 3: Checkpoint restore includes figures (Mac)

**Files:** `Maugham/Views/PartialRestorePicker.swift` (`performRestore`, `splitByTheDoor`, its inputs); its presenter in `HistoryPane.swift` (pass the figure ids); `DocumentStore+Figures.swift` if a helper is needed to open a host or load a closed figure's ops. Tests: `MaughamTests/…/PartialRestoreScopeTests.swift` (extend).

**Contract** (rulings Q-1, Q-2, Q-3):
- Whole-project scope restores every registered figure that has a pointer in the checkpoint; document scope restores that document's figures (`piece == docId`). A figure with no pointer, or a pointer whose figure is no longer registered, is left alone.
- Each figure asks `.editFigure` (`settledPosture(forDocId:)`); refused figures are named in the picker's existing refusal list beside refused documents.
- An open figure restores through its host; a closed one through a transiently opened host (the same route Task 5 of plan 6b uses for text: open, act, release).
- The picker's result names skipped figures (parked, picture unavailable, refused) in its existing message surface. No new screen.
- Text restore is unchanged.

- [ ] Write failing tests: Review Focus 2; document scope touches only that document's figures; a refused figure is named and the rest restore.
- [ ] Run red; implement; `./scripts/test.sh`; commit.

### Task 4: What a promotion carries, and the re-created streams (Core + Mac stores)

**Files:** new Core `Table/FigureCarry.swift` (pure: which figures, and the opening ops for each); `Maugham/Stores/ProjectStore+Figures.swift` (`createFigureStream` reuse or a sibling that takes a target root). Tests: Core `FigureCarryTests.swift`; `MaughamTests/Collection/PromoteFigureCarryTests.swift`.

**Interfaces — Produces:**
- `FigureCarry.figures(forPiece: String, records: [FigureRecord], referencedLabels: Set<String>, states: [String: FigureState]) -> (moved: [FigureRecord], copied: [FigureRecord])` — the piece's own figures move; figures its text labels or carried formulas reference (transitively) are copied (Q-4).
- `FigureCarry.openingOps(for record: FigureRecord, state: FigureState) -> [(OpKind, FigureOpPayload)]` — figureCreate + inserts with the state's own row and column ids + cell sets + settings + pins, ending with `figureParked` when the state is parked (Q-5, Q-6). Pure.
- `FigureCarry.leftBehindReads(...) -> [FigureCarryProblem]` — formulas or pins reading a Research item that is not carried.

**Contract:**
- The re-created stream folds (FigureDeriver) to a table equal to the source state's — pin it per kind (table with formulas and formats, image, parked table).
- Writing the streams into a staged project root signs them as this device's author through the ordinary op-log append route for that root (verify how `createFigureStream` signs and reuse it with the staged root; do not write raw JSONL). Pictures are copied into the staged `figures/` through `SafeRelativePath` change forms.
- Referenced labels come from the piece's text (`{#tbl:…}`/`{#fig:…}` lines and cross-references), read from the op log, never the `.md`.

- [ ] Write failing tests: carry selection with a whole-book figure referenced only by a carried figure's formula; opening ops fold to equal state for each kind; left-behind Research reads are listed.
- [ ] Run red; implement; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 5: Promotion brings the figures (Mac stores)

**Files:** `Maugham/Stores/ProjectStore+CollectionPieces.swift` (`promotePieceToProject` staging steps, `writePromotedManifest` `figures:`, `convertPromotedPieceToReference`); the promotion's result type (add the problems list). Tests: `MaughamTests/Collection/PromotePieceTests.swift` (extend).

**Contract** (rulings Q-4…Q-6):
- Before staging, close open figure hosts (verify `docStore.close()` covers them; else `DocumentStore.closeFigures()`).
- Staging writes the carried figures (Task 4), their pictures, and the Research-table sidecars of carried research items (`.maugham/research-tables/<item id>.json`, ids kept). Each staged write returns a `PromotionStagedMove` (or equivalent) so `rollbackPromotionStaging` undoes it.
- `writePromotedManifest` writes `figures:` with each carried record re-pointed: `piece` = the new main document's id for moved figures; copied figures keep `piece: nil` or become the new doc's if they were another piece's (they now live in a one-piece project).
- After the atomic replace, the Collection side removes the moved figures through 6b's `removeFigure` route (restorable Trash entries); copied figures stay.
- The promotion result lists `FigureCarryProblem`s for the caller's existing message surface.
- Review Focus 3, 4 and 5 are this task's tests, plus: a promoted figure opens and edits in the new project; the new project's first checkpoint includes it.

- [ ] Write failing tests as above; run red; implement; `./scripts/test.sh`; commit.

### Task 6: Area guides and the plan-6 roadmap line (docs)

**Files:** Core `AREA.md`, `Maugham/OpLog/AREA.md`, `Maugham/Stores/AREA.md`, `Maugham/Views/AREA.md` as needed; `docs/history/*.md` for moved why-clauses; `DocBudgetTests` ceilings; any roadmap/INDEX line that lists plan 6's state.

**Contract:** the guides describe the restore diff, the host's restore, the picker's figure scope, promotion's carry and re-creation, and the rulings Q-1…Q-6 in one or two lines each; nothing load-bearing is deleted to make room; ceilings move by exact counts. Sweep for now-false claims (for example, "promotion drops figures", "restore ignores figures").

- [ ] Edit; `./scripts/test.sh core` (DocBudget); commit.

## After the last task

- Whole-branch review (give it the ledger; name the seams: Task 1 × 6b's revive and removed slices; Task 2 × P-5 parked and the HLC minting rule; Task 3 × the picker's text restore and door split; Task 4 × refs by id and research ids; Task 5 × rollback, the typed mover, tripwire 58 and 6b's removal route).
- `./scripts/test.sh full`, `./scripts/test.sh phone`.
- Report to Denver: rulings Q-1…Q-6 with costs. Plan 6 is then complete; plan 7 (the card and in-place grid) is next, written against the built code.
