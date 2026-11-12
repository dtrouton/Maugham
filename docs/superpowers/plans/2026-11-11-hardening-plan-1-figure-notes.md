# Hardening 11-11, plan 1: figure notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No figure suggestion is left open over a cell that already holds its value, Accept never records a `prior` equal to its `next`, and the checkpoint revert sheet counts figure notes before and after. Closes #136 and checks `FigureDocument.swift` off #106.

**Architecture:** The walk that decides what a checkpoint restore does to a figure's notes becomes one pure MaughamCore function. The restore acts on its answer and the revert sheet counts from it, so BEFORE and AFTER cannot disagree. The restore itself moves out of `FigureDocument` into a child type first, in a commit that changes no behaviour. Accept gains a status-only arm for a cell that already holds the suggestion.

**Tech Stack:** Swift, SwiftUI + AppKit, the local `MaughamCore` package, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-11-hardening-open-issues-design.md` (§1–§4, §7). Read it before any task; its rulings R-A and R-B are Denver's and are not reopened here.

Plan 2 (Research tables, updates, doc truth; spec §5–§7) is written after this plan is built.

Branch `claude/hardening-2026-11-11`. Sources: `gh issue view 136`, `gh issue view 106`. **Line numbers in the issues have drifted: find code by symbol.**

## Global Constraints

- Read the area guide `CLAUDE.md` names for each path before editing it (`Maugham/OpLog/AREA.md`, `Maugham/Views/AREA.md`, `Maugham/MCP/AREA.md`, `Maugham/Stores/AREA.md`, `Packages/MaughamCore/Sources/MaughamCore/AREA.md`), and the tripwire rows in `docs/tripwires.md` your change rhymes with (19, 33, 47, 51, 52 most of all).
- Test first: write the failing test, watch it fail for the stated reason, then fix.
- **Disable experiment on every negative assertion** ("stays accepted", "writes no cell", "is not stopped"): remove the guard, watch the test fail, restore it, and put the output in your report.
- Run `./gen.sh` after adding any file. Gate with `./scripts/test.sh`; when `Packages/MaughamCore` changes, also `./scripts/test.sh core` and `./scripts/test.sh phone`. Never raw `swift test` or `xcodebuild test`. Check for other builds with `pgrep -x xcodebuild`.
- Tests are windowless where possible; no press-then-wait (tripwire 33); temp roots through `TestTemp`; cell and paragraph id literals from the valid alphabet (tripwire 8).
- Annotation and Rewind behaviour has register files (`register/reconciliation/Annotations.*`, `Rewind.*`). Read the filings before changing behaviour. Claims and filings are updated in Task 7, not piecemeal, except where a task says otherwise.
- One commit per task, message `hardening 11-11 task N — …`, ending with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Don't push.
- Report: files changed, tests added with their disable-experiment output, the gate result, and anything you judged that the coordinator should check.

## Review Focus

Conditions the spec implies that are most likely to bite, each pinned in the task named:

1. **A restore stopped part way** (`.partlyRestored`, another device's reload) after a returning accept's op has landed: restoring again finishes the rest and does not accept the note twice. → Task 2.
2. **A cell that holds the suggested content under a different format or alignment**: the Accept guard compares content, as the changed-since question already does, and still writes nothing. → Task 4.
3. **Two suggestions anchored on the same cell**, one stranded and one returning, or two stranded: each cell change answers at most one note, and the other is not left contradicting the cell. → Task 2.
4. **A Mac that may not answer notes** (`mayHere(.acceptOrReject)` false) facing a returning accept: the whole figure is refused, as for a stranded one, and the sheet's BEFORE count leaves that figure out. → Tasks 2 and 3.
5. **⇧⌘Z of a guarded accept after the cell has since been edited away from the suggestion**: it declines as drifted; it does not fall through to a cell-writing accept the writer never confirmed. → Task 4.

---

### Task 1 — the split: the note walk to Core, the restore to a child type [opus]

No behaviour change. This is #106's ruling (split in the branch, first, foundations plan 4 style).

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/Table/FigureRestoreNotePlan.swift`
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/…/FigureRestoreNotePlanTests.swift` (beside the existing `FigureRestoreDiff` tests)
- Create: `Maugham/OpLog/FigureCheckpointRestore.swift`
- Modify: `Maugham/OpLog/FigureDocument.swift` (the `// MARK: - Checkpoint restore` section and `noteLifecycleKinds`)

**Interfaces — Produces:**

```swift
// MaughamCore
public struct FigureRestoreNotes: Equatable, Sendable   // moved from FigureDocument.swift, unchanged this task
public enum FigureNoteLifecycle { public static let kinds: Set<OpKind> }   // was FigureDocument.noteLifecycleKinds

public struct FigureRestoreNotePlan: Equatable, Sendable {
    /// The restore's table changes, with each cell change that answers a note
    /// rewritten to that note's lifecycle kind and carrying its id.
    public var changes: [FigureReturnDiff.Change]
    /// Status-only note lines, written after the changes.
    public var statusLines: [StatusLine]            // StatusLine { kind: OpKind; annotationId: String }
    /// What acting on this plan will have done, by note id (RULING-28).
    public var notes: FigureRestoreNotes

    public static func plan(
        changes: [FigureReturnDiff.Change],
        ops: [Op], amendments: <the type of FigureDocument.annotationAmendments>,
        table: <the type of FigureState.table>,     // the figure as it stands now
        target: FigureState, above pointer: String,
        mayDispose: Bool
    ) -> FigureRestoreNotePlan
}
```

`mayDispose: false` turns an archive into a status-only `claudeAcceptRevert`, which is the swap `restoreToCheckpoint` does inline today.

- [ ] Write Core tests that pin today's behaviour of `answeringStrandedAccepts` through `FigureRestoreNotePlan.plan`: a stranded accept whose cell the restore writes (the change becomes `claudeAcceptRevert` with the id); one whose cell it does not write (status-only revert); one whose row is gone (archive; with `mayDispose: false`, status-only revert); an unhonoured reopen does not hide the accept; a status-only re-accept is judged against the newest cell-carrying accept. They fail to compile.
- [ ] Move the walk to Core as `plan(…)`, body unchanged in meaning. Move `FigureRestoreNotes` and the lifecycle-kind set to Core; `FigureDocument` uses them from there.
- [ ] Move `restoreToCheckpoint`, its picture and park helpers, `lastRestoreNotes` and `betweenRestoreOpsForTesting` into `FigureCheckpointRestore`, a type the host owns and calls. It reaches the host only through the verbs it uses today (`requireWritable`, `mayHere`, `commit`, `reloadGeneration`, `holdOpenCellNotes`/`releaseOpenCellNotes`, `state`, `_ops`). Not an extension of `FigureDocument`. `FigureDocument.restoreToCheckpoint`, `lastRestoreNotes` and the test seam keep their names and signatures as one-line forwards, so no caller or test changes.
- [ ] `./gen.sh`; `./scripts/test.sh core`; `./scripts/test.sh`; `./scripts/test.sh phone`. `FigureRestoreTests`, `FigureAnnotationDispositionTests` and `CheckpointSubjectRecordTests` pass with no edit to their bodies. Where a census tripwire names a moved symbol by file, move its entry (they key by type) and say so in the report.
- [ ] Report `wc -l Maugham/OpLog/FigureDocument.swift` before and after. Commit.

### Task 2 — a checkpoint revert's three note classes (#136 W1, W4; ruling R-A) [opus]

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Table/FigureRestoreNotePlan.swift`, its Core tests
- Modify: `Maugham/OpLog/FigureCheckpointRestore.swift`
- Test: `MaughamTests/OpLog/FigureAnnotationDispositionTests.swift`; create `MaughamTests/OpLog/FigureReturningAcceptTests.swift`

**Interfaces — Consumes:** Task 1's `FigureRestoreNotePlan.plan`. **Produces:** `FigureRestoreNotes.reaccepted: [String]` (and `isEmpty` counting it); `FigureCheckpointRestore` records a carried `claudeAccept` under `reaccepted`.

The rule, from spec §2 (X is the cell before the suggestion, Y the suggested value):

| Class | Condition | Written |
|---|---|---|
| Stranded | accepted now, not accepted at the pointer, the restore writes its cell | that cell change as `claudeAcceptRevert` with the id |
| Returning | open now, its latest honoured line a revert newer than the pointer, accepted at the pointer, the restore writes its cell back to the accepted value | that cell change as `claudeAccept` with the id, checkpoint-stamped like the revert |
| Gone | accepted now, row or column absent at the pointer | status-only `claudeArchive` (or status-only revert when `mayDispose` is false) |

Everything else is untouched. "Accepted at the pointer" is the note's status folded over honoured lifecycle lines with `opId <= pointer`; mirror `RewindImpact.travelStatusChanges`'s `acceptedAtTarget` and name it in a comment so the two rules point at each other.

- [ ] Tests first (Core for the walk, Mac for the op lines and the cell):
  - `test_aRevertedAcceptReturnsToAccepted_whenTheRestoreWritesItsValueBack`: suggest X→Y, accept, checkpoint, ⌘Z, restore. Cell is Y; the note is `.accepted`; exactly one new op, a `claudeAccept` carrying the cell and `sourceAnnotationId`; `lastRestoreNotes.reaccepted == [id]`. Then `rejectAnnotation` throws `notOpen`.
  - `test_acceptedAtTheCheckpointAndNow_isNotStranded`: accept, checkpoint, ⌘Z, ⇧⌘Z, restore: no note line, status `.accepted`, cell Y. Same with a hand edit to Z after the re-accept: the restore writes Y as a plain `figureCellSet`, status `.accepted`.
  - `test_aCellTheRestoreDoesNotWrite_keepsItsNote`: type Y by hand, checkpoint, accept (X→Y suggestion), restore: zero ops, status `.accepted`.
  - Re-pin `test_aRestoreReopensWhereTheCellStands_andArchivesWhereItIsGone`: its "reopens where the cell stands" half becomes "stays accepted" (checkpoint, accept X→Y, type X back, restore: no note line, `.accepted`), by R-A; rename the test to say so. The archive half is unchanged.
  - Review Focus 1: with `betweenRestoreOpsForTesting`, a reload after the returning accept's op lands gives `.partlyRestored`; restoring again finishes, and the log holds one checkpoint-stamped `claudeAccept` for the note, not two.
  - Review Focus 3: two suggestions on one cell, both accepted in turn after the checkpoint; the restore's one cell change answers one, and the other gets a status-only revert **only because its cell was written** — state in the test which note the change carries (the newest cell-carrying accept) and that neither ends accepted over a value it did not suggest.
  - Review Focus 4: `mayHere(.acceptOrReject)` false with a returning accept throws `FigureEditRefused` before any op.
- [ ] Implement the classes in `plan(…)`; remove the status-only reopen for a live, unwritten cell; keep the Gone list. `FigureCheckpointRestore` records `reaccepted`.
- [ ] Disable experiments: drop the `acceptedAtTarget` guard (the second test fails); restore the unwritten-cell reopen (the third fails).
- [ ] Gates: core, Mac, phone. Commit.

### Task 3 — the revert sheet counts figure notes, before and after (#136 W3; RULING-28) [opus]

**Files:**
- Modify: `Maugham/OpLog/FigureCheckpointRestore.swift`, `Maugham/OpLog/FigureDocument.swift` (one forward)
- Modify: `Maugham/Views/PartialRestorePicker.swift` (`revertNotes(for:)`, `RevertNotes`, the confirm sentence, `figureSentence`)
- Test: `MaughamTests/Views/PartialRestoreStrandedAcceptTests.swift` or a figure sibling beside it; `MaughamTests/OpLog/FigureRestoreTests.swift`

**Interfaces — Consumes:** Task 2's plan and `FigureRestoreNotes.reaccepted`. **Produces:**

```swift
extension FigureDocument {
    /// What `restoreToCheckpoint(_:through:)` would do to this figure's notes,
    /// writing nothing. Nil where the restore would skip the figure, refuse it,
    /// or throw before its first op.
    func restoreNotesPreview(through pointer: String) async -> FigureRestoreNotes?
}
```

- [ ] `FigureCheckpointRestore` gets one private preparation step that both the preview and the restore run: the door, the two skips, the park reads, the diff, `everyChangeApplies`, both `mayHere` answers, then `FigureRestoreNotePlan.plan`. The restore continues from its answer; the preview returns `plan.notes`. No second copy of the preparation.
- [ ] Test: for a figure with one stranded, one returning and one gone note, `restoreNotesPreview` equals the `lastRestoreNotes` a restore then leaves. For a parked figure, a figure that went to Research since, and a Mac that may not answer notes, it is nil and appends nothing (op count unchanged).
- [ ] `revertNotes(for:)` adds an entry per figure in scope (the same `figuresInScope` the revert acts on, through the store's existing figure-host door), counting reopened, reaccepted and archived; a nil preview adds none. The confirm sentence names figure counts in the words it uses for documents, adding the archive count ("archived") that only figures have.
- [ ] `figureSentence` reports `reaccepted` AFTER, in `RewindImpact.toast`'s words ("restored to accepted").
- [ ] Test at the sheet's value level (`RevertNotes` and the two sentences as strings; no mounted control): a mixed revert's BEFORE counts equal its AFTER report. A sheet that asks `Posture` keeps asking it through the existing door (tripwires 47, 51).
- [ ] Gates: Mac. Commit.

### Task 4 — Accept writes nothing over a cell that already holds the suggestion (#136 W2; ruling R-B) [opus]

**Files:**
- Modify: `Maugham/OpLog/FigureDocument+Annotations.swift` (`acceptSuggestion`), and `FigureDocument`'s visit record where the fold needs it
- Test: `MaughamTests/OpLog/FigureAnnotationDispositionTests.swift`, `MaughamTests/OpLog/FigureVisitTests.swift`

Today, over a cell that already holds the suggestion, `acceptSuggestion` commits `FigureAnnotationOps.accept(… next: suggested, prior: replaced …)` with `prior == next`. That op is the corruption.

- [ ] Tests first:
  - `test_acceptingOverACellThatAlreadyHoldsTheSuggestion_writesNoCell`: type Y by hand over a X→Y suggestion, accept. One new op: a `claudeAccept` with `figure == nil` and the note's id. Status `.accepted`. ⌘Z: one status-only `claudeAcceptRevert`, the cell still Y, status `.open`. ⇧⌘Z: accepted again, still no cell op.
  - `test_theRaceThatLeftANoteOpenOverItsOwnValue_cannotCorruptUndo`: accept X→Y (cell-writing), append a newer reject as another device (`AnnotationWriter.makeReject`), reopen, accept again: the second accept has no `figure`; no op in the log has a `claudeAccept` whose `figure.prior?.content == figure.next?.content`.
  - Review Focus 2: the cell holds Y's content under a different format; the guard still fires and the format is untouched.
  - Review Focus 5: guarded accept, ⌘Z, edit the cell to Z, ⇧⌘Z: declines (`.drifted`), no op.
  - In an open grid visit (`FigureVisitTests`): a guarded accept, then the visit ends and its one ⌘Z runs: the note is open again and no cell moved.
  - A note accepted status-only with no cell-carrying accept is never stranded by a restore (pin against Task 2's plan).
- [ ] Implement: when `replaced?.content == suggested?.content`, commit `FigureAnnotationOps.statusOnlyAccept` and register the undo the way `acceptNote` does (`OpUndoRegistrar`, a status-only revert), skipping the Research pin read. `unacceptNote`'s refusal of a suggestion is relaxed only for this arm; keep it refusing where the newest accept carries a cell. Make the visit's undo include the reopen. Update `acceptSuggestion`'s doc comment: its last sentence ("has nothing to lose, and is not asked about") now ends in "and is accepted without writing the cell".
- [ ] Disable experiment: remove the guard; the first two tests fail on `figure != nil`.
- [ ] Gates: Mac (and core/phone if `FigureAnnotationOps` changed). Commit.

### Task 5 — the same race in the manuscript: reproduce, then guard or file (ruling R-B) [opus]

**Files:**
- Test: create `MaughamTests/Integration/AcceptOverAppliedTextTests.swift`
- Modify, only if it reproduces: `Maugham/OpLog/Document+Annotations.swift` (the suggested-change accept)
- Read first: `register/reconciliation/Annotations.claims.json` (M5-AN-034 and its neighbours), `Annotations.filings.json`

- [ ] Write the reproduction through `Document.load` (never another constructor): a suggested change is accepted; a newer `claudeReject` or `claudeArchive` for the same note arrives as another device's line; `reopenAnnotation`; accept again. Record what happens to the paragraph text, to the accept op's changes, and to ⌘Z / the pane's Revert.
- [ ] If the second accept writes a change whose before-text equals its after-text, or Revert can no longer reach the original text: add the guard (text already applied → status-only accept, exactly RULING-26's instrument), pin it with the test, and note for Task 7 the claim to add and the filing to flip.
- [ ] If it refuses or does nothing harmful: keep the test as the pin of that, change no production code, and write up for Task 7 a filing on M5-AN-034's reachability ("UNTRACED" today) saying what was traced.
- [ ] Either way the report states plainly which branch was taken and quotes the op lines observed. Gates: Mac. Commit.

### Task 6 — MCP and figure notes (#136 W5, W6, W7) [sonnet]

**Files:**
- Modify: `Maugham/Stores/DocumentStore+FigureAnnotations.swift` (`addFigureAnnotation`), `Maugham/MCP/Tools/AnnotationToolHelpers.swift`, `Maugham/MCP/Tools/AnnotationReadTools.swift`
- Test: the existing MCP annotation tool tests and `MaughamTests/OpLog/FigureRestoreTests.swift`

- [ ] **W5.** Test: with a figure open, build the tool's anchor, delete the anchored row through the host, then call `addFigureAnnotation`: it refuses with the tool's existing orphaned-anchor error and appends nothing. Fix: the open-host branch re-resolves the anchor against `host.state` before appending. If the tool can use `translationFigures()` in place of `publishFigures()` with no change in what it reads, switch and say so; otherwise leave it.
- [ ] **W6.** Tests with `betweenRestoreOpsForTesting`: a note added through `addFigureAnnotation` between two restore ops lets the restore finish (`.restored`); the existing `test_aReloadMidRestoreStopsIt_andARetryFinishes` still passes unchanged. Fix: the open-host branch adopts the op it wrote into the host without bumping `reloadGeneration`. The restore's generation check is not loosened. MCP still writes no cell and no manuscript text.
- [ ] **W7.** `get_annotation` on a figure takes status and history from one `FigureNotesRead.read`; history stays raw. Test: the tool's two fields come from one read (count the reads through the existing seam, or assert on a store double), not that they merely agree.
- [ ] Response size is unchanged (tripwire 10). Gates: Mac (core/phone if `FigureNotesRead` changed). Commit.

### Task 7 — the register, the docs and #106 [sonnet]

**Files:** `register/RULINGS.md`, `register/reconciliation/Annotations.claims.json`, `Annotations.filings.json`, `ruling-hashes.json`, `register/START-HERE.md`, `Maugham/OpLog/AREA.md`, `Maugham/MCP/AREA.md`, `docs/tripwires.md` if a row moved, the user guide where it describes reverting figures. Follow `register/reconciliation/PROTOCOL.md` and use the register's scripts; never hand-adjust `_summary` or the hashes.

- [ ] Rulings, next free numbers, `RATIFIED_FROM_OPTIONS`, with the basis and the example put, verbatim from the spec's "Rulings taken in this sitting": R-A (RULING-57's family) and R-B. R-C waits for plan 2. Record the provenance note the way RULING-57 does: option text and rationale are the agent's, ratified by Denver.
- [ ] Claims, each naming its pinning test: the three revert classes and the untouched-cell rule; the sheet's BEFORE equals AFTER for figures; the Accept guard and its ⌘Z; the outcome of Task 5 (a claim and a flipped filing, or a new filing).
- [ ] `register/START-HERE.md`: recount the Annotations row, the app-layer subtotal, the totals and the complies figure from the claims files (#139 D1 is closed here because this task moves the count), and add a test in the register's test package that reads the claims files and fails when the table's numbers differ.
- [ ] Sweep `Maugham/OpLog/AREA.md` and the guide for sentences Tasks 2–4 made false (a restore "reopens" a note over a cell it did not write; accept always writes the cell). Add `FigureCheckpointRestore` and `FigureRestoreNotePlan` to the area guide's pointers.
- [ ] Report `FigureDocument.swift`'s new line count for #106. Post nothing to GitHub and close no issue; the coordinator does that at merge.
- [ ] Gates: `./scripts/test.sh` and `./scripts/test.sh core` (the claims package runs in CI's `behavioural-claims` job; run it locally the way `register/README.md` says). Commit.
