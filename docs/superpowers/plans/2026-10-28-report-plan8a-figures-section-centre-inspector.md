# Report plan 8a — the Figures section, the centre figure view and the figure inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a project's tables and figures get one place in the tree. A Figures section lists every figure numbered in reading order with its warnings; selecting one shows it large in the centre with an inspector that carries the verbs that have no button today (pins Compare/Refresh, Send to Research, Open in window, Import from CSV, rename).

**Architecture:**
- **One window-level reading of the book's figures.** The reference index moves from `EditorHost` to the project window (session), and learns each figure line's path and the cross-references in each piece, so "Table 3", "Used in" and "unused" are answered from one cached index — by the tree, the inspector and the editor alike. The tree's figure tags come from a tree-owned `FigureCardCache` (memory only, filled off the main actor), as the figure window's are.
- **A figure is a subject.** `BinderSubject.figure(id)` joins `.item` and `.research`: persisted in `UIState`, validated when the figure goes, placed by persona exactly as a research subject is (centre; beside the canvas in Plan; nothing moves in Publish).
- **The centre figure view is the figure window's grid in the centre frame.** It mounts `FigureWindowGrid`'s machinery (one grid per host, review mode, Format ▸ Table routing), with the caption read-only (the caption is manuscript text, R7d-6).

**Tech Stack:** Swift 5.10, SwiftUI + AppKit, MaughamCore, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §7 (the Figures area), §4.3 (pins), §12 item 8. Survey of the built code at eee4ddf8: `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan8-survey.md` (re-verify each signature before relying on it). Plan 8b (written after 8a is built, rule 11): drag verbs, Use in document with placement, bring back, Research tables in the grid, legacy research figures and "Move into Figures", snapshot-source "changed".

## Global Constraints

- **Denver's rulings (2026-10-28):**
  - **D8-1 the middle path.** The Figures section shows only when the project has at least one figure record that is not parked. Piece folds do NOT list figures; a piece row shows a small count ("3 tables" / "1 figure" / "2 tables, 1 figure") of the figures whose lines are in that piece, and clicking the count filters the Figures section to that piece (a filter chip in the section header clears it).
  - **D8-2** dropping a figure on Research confirms once (plan 8b; noted here so 8a's row is `.draggable`).
  - **D8-3** Research CSVs open in the grid in plan 8 (8b), undo while open, the guide says saved changes are not versioned yet.
- **Spec §7, verbatim intent:** the section sits between the manuscript and Research; a row shows the number ("Table 2", "Fig 1", or "—" when unused), the name or caption, and tags **Research** (has pins), **changed** (a pin's source moved on), **unused**; dragging within the list does not renumber. The inspector shows name; number and section; "Used in" (links to the line and to each cross-reference); "Reads from Research" (sources, ranges, pin dates); notes and suggestions; actions Send to Research, Open in window, Import from CSV.
- **Hard invariants / tripwires:**
  - rows are `.tag` + `.treeTravelOnDoubleClick` on the label leaf, never a tap gesture (9); rename rows follow 16;
  - tree rows read a cached value array built on a version change, never disk, never `figureCardInputs()` in a body (4);
  - no new observable state on `EditorHost` (6) — the reference index leaves it, it does not grow;
  - the project kind that shows the section is asked by a capability with an exhaustive switch (55) — add `ProjectType.holdsFigures` (true for every kind with a prose manuscript; a screenplay's manuscript holds none; `.unknown` false);
  - figures are read from the op log / registry, never `figures/<name>.csv` (20); synced paths through `SafeRelativePath` (58);
  - posture through the one door (47, 51): a figure the Mac may not edit shows read-only and hides Send to Research, rename and Import;
  - every figure write from the grid still goes through `FigureGridController` (52 census rows), pins Refresh through `FigureDocument.refreshPins`.
- **Tests:** real delivery paths (a click is selection through `List(selection:)`; a menu is its action); no press-then-wait, no synthesised clicks (33); `TestWindow`/`TestTemp`; `./gen.sh` after adding files; `ProjectWindow.body` changes → local Release build before tagging (put new modifiers in their own `ViewModifier`).
- **Docs:** `Maugham/Views/AREA.md` is at its cap (7,971/8,000). Task 1 moves why-clauses from it into a new `docs/history/views.md` (the `docs/history/stores.md` precedent) to make room for the new files' Map lines; DocBudget ceilings numbers only. Help describes only what ships (rule 7).
- **Census rule:** a new shape that recurs gets a census + planted offender + control, not a comment.

## Review Focus

1. **A figure removed or sent to Research while it is the selected subject** (here or on another Mac): the subject repairs to the project row, the centre unmounts the grid without a write, the section hides if it was the last figure. Tasks 3, 6.
2. **The same figure expanded in a document and selected in the tree:** one grid per host — the second surface says "Editing in another window" and focuses the first; no two writers. Task 6.
3. **Numbers follow the text, not the list:** move a paragraph holding "Table 3" above "Table 1" in another piece, and the section re-numbers on the next settle with no editor open; an unlabelled figure line numbers too; a figure with no line reads "—" and "unused". Task 2.
4. **Plan persona:** selecting a figure keeps the canvas in the centre and shows the figure beside it; Publish: nothing moves; Review: the grid is read-only. Task 5.
5. **A read-only share or a figure owned by another person's piece:** the row and inspector show it, the actions that write are absent, the grid opens read-only. Tasks 6, 7.

---

### Task 1: Room in the Views guide, and the capability
**Files:** `Maugham/Views/AREA.md` (move rationale clauses — the "why" halves of the Rules sections "The subject and the tree", "Tree furniture", "Research subjects and the palette wall" — into new `docs/history/views.md`, keeping each rule's one-line statement and a pointer); `docs/INDEX.md` line for the history file; `DocBudgetTests` (Views ceiling down to the new actual); Core `ProjectType+Capabilities.swift` `holdsFigures` (exhaustive switch incl. `.unknown`), Core `ProjectTypeCapabilityTests`, `MaughamTests/ProjectKindSitePinsTests.swift` table for the new capability.
- [ ] Failing tests: `holdsFigures` per kind (novel, short story, collection, report true; screenplay, unknown false); `./scripts/test.sh core`.
- [ ] Move the clauses (no rule is deleted — each keeps its statement; aim ≥ 400 words freed); DocBudget numbers only; DocSync green.
- [ ] Gates; commit.

### Task 2: The book's figure index (window level)
**Files:** `Maugham/Editor/ReferenceIndex.swift` (`PieceSummary.Element.table/.figure` gain the line's `path` and line index; `PieceSummary` gains `referencedLabels` from `ManuscriptInlineScanner.scan`), new `Maugham/Editor/FigureListing.swift` (pure: `FigureListing.build(index:records:documentPathOf:) -> [FigureListing.Row]`, Row = `{ figureId, kind, name, caption, number: String /* "Table 2", "Fig 1", "—" */, usedIn: [Use(docId, lineIndex)], referencedFrom: [Use], pieceOfLine: String? }`; a line's figure is found by `FigureLineResolution.Index` on its path; unlabelled lines number too; order = reading order of publishable pieces, then unused by name), `Maugham/Views/ReferenceIndexHost.swift` ownership moves from `EditorHost` to the project window session (one per window; `EditorHost` takes it as a `let` from its parent — no new `@State` on `EditorHost`; update `TripwireGrepTests+EditorHost` `editorHostWrappedMembers` and `WiringCensusTests` entries to the new spelling); its invalidation edges move with it (research change, structure change, piece switch, sync of a closed piece).
**Contract:** the editor's existing consumers (caption bar numbers, label completion, cross-reference resolution, `projectLabelsElsewhere`) read the same index and keep their behaviour (their tests stay green unchanged); a build happens off the main actor, token-gated, as today.
- [ ] Failing tests (pure): numbering across two pieces, an unlabelled line, a figure with no line ("—"), a line whose path names no record (not listed), two lines naming one figure (one row, two uses), cross-references collected; ordering.
- [ ] Failing test (wiring): with no editor mounted (Plan persona), a structure change re-numbers the listing.
- [ ] Gates; commit.

### Task 3: The figure subject
**Files:** `Maugham/Models/BinderSubject.swift` (`case figure(String)`, `figureID`), `Maugham/Stores/UIState.swift` (`selectedFigureId` key; old files decode), `ProjectWindow.validSubject` (+ figures argument) and `SubjectValidationModifier.fingerprint` (figure ids included), `BinderTreeSelection` (`subject`, `shown`, `resolved`, `ordered`, `binding`), every exhaustive site the compiler names (survey §1.2 lists them: CanvasSubject, CanvasHighlight, AssistantColumn, SceneNavigatorPane, ReferencesPane, TreeTravel, findMatchScrollTarget), `Maugham/Views/Review/AnnotationScope.swift` (a figure note's click travels to `.figure(id)` instead of `.stay`).
**Contract:** a figure subject whose record is gone or parked repairs to `.project`; the subject round-trips through `UIState`; every site decides deliberately (no `default:` added to dodge exhaustiveness).
- [ ] Failing tests: UIState round-trip + old-file decode; validSubject repair on removal and on park; annotation click travel.
- [ ] Gates; commit.

### Task 4: The Figures section and the piece count
**Files:** new `Maugham/Views/FigureSection.swift` (the section builder, mounted FIRST in `BinderTreeSections.body` so all three hosts get it, shown iff `holdsFigures` and the listing has a non-parked row), new `Maugham/Views/FigureRow.swift` (number, name or caption, tags; `.tag(.figure(id))`, `.treeTravelOnDoubleClick`, `.draggable(id)`, context menu = the inspector's actions minus Import), `BinderTreeSectionsState` (`figuresSectionExpanded`, `BinderTreeSection.figures`, `TreeScrollTarget.figuresHeader`, the cached `figureRows: [FigureListing.Row]` and a tree-owned `FigureCardCache` attached as `FigureWindowGrid.watchTheBook()` does, `pieceFilter: String?`), the piece row (`BinderRow`/`PieceRow`: the count text and its click setting `pieceFilter`; the count is a `Button(.plain)` inside the row, which selects nothing — tripwire 9's Button rule — and reveals the section), the header's filter chip ("Chapter 3 ×").
**Tags:** Research = the card model's `readsResearch`; changed = `pinChanged`; unused = number "—". (The "in Research" legacy tag and snapshot "changed" are 8b.)
- [ ] Failing tests: section absent with no figures / with only parked figures / in a screenplay; rows in reading order with numbers and tags (driven by a planted index + card models, no disk in body — assert the row source is the cached array); the count's text per piece and that it filters and clears; tripwire 9 census still green with the new row type.
- [ ] Gates; commit.

### Task 5: Placement and the centre route
**Files:** `Maugham/Views/CentreRoute.swift` (`.figure(id:)` beside `.research`, before `.canvas`), `ResearchSubjectColumns.swift`'s placement generalised or mirrored (`figureSubjectPlacement(persona:subject:)` → `.takesTheCentre` / `.besideTheCanvas` / `.nothingMoves`), the reveal modifier for the right column in Plan, the `Views/AREA.md` recipes "Add a centre route" / "Add a right-column inspector" updated in place.
- [ ] Failing tests: route per persona (Author, Review, Plan, Publish) for a figure subject; the canvas stays the single mount in Plan (existing census); the right column reveals in Plan.
- [ ] Gates; commit.

### Task 6: The centre figure view
**Files:** new `Maugham/Editor/FigureCentreGrid.swift` (reuses `FigureWindowGrid`'s open/mount/watch/refreshAccess/finish — extract the shared core rather than copy: one type mounts in a window or a SwiftUI frame; `FigureWindowGridHost` made non-private), `CentreColumn` `.figure(id:)` arm, `FigureWindows` holds (a centre grid takes the in-place hold for its figure; a second surface on the same figure says "Editing in another window" and focuses the holder; leaving the subject releases it after its last write settles), Format ▸ Table routing (the centre consumes `.maughamFigureTableCommand` when it holds the keys), the bottom bar's number/caption from the Task 2 listing (caption read-only, R7d-6; an unused figure shows its name and "—").
**Contract:** posture through the gate (`FigureGridGate.mode`): read-only share, review mode, another person's piece, parked → read-only with the reason; leaving the subject or closing the window settles writes like the figure window; Esc does nothing with nothing to cancel; ⌘Z/⇧⌘Z reach the grid's stack while it has the keys (ADR 0023 decision 6: the centre keeps its own stack like the figure window; nothing collapses into a text step).
- [ ] Failing tests: Review Focus 1 and 2; mount and type a cell through the real key path, `firstResponder ===` asserted; leaving the subject mid-edit commits; read-only reasons; Format ▸ Table reaches the centre grid.
- [ ] Gates; commit.

### Task 7: The figure inspector
**Files:** new `Maugham/Views/FigureInspector.swift`, `RightColumn.researchOrSubject` (a figure subject first), pins Compare sheet (new `Maugham/Views/FigurePinsCompare.swift`: old and new values side by side per pinned cell, Refresh = `FigureDocument.refreshPins` as one op).
**Shows:** name (rename field → `renameFigure`, refusal said, field reverts); number and section; Used in (each line — a link that selects the piece and moves the caret to the line — and each cross-reference); Reads from Research (each source, range and pin date from `pinStatus`, loaded off the main actor on appear and on the card cache's version change, never in body); notes and suggestions on the figure stream (the existing annotation list filtered to it); actions Send to Research (piece's Research / Shared, as the grid menu: folds any open grid first, not undoable), Open in window (`MaughamEvent.postOpenFigureWindow` with a hand-off from the listing), Import from CSV (opens the centre grid's import).
- [ ] Failing tests: each field's source; rename refusal; Used-in travel lands the caret on the line; Compare shows old/new and Refresh writes one op (one ⌘Z in the grid stack); actions hidden when posture forbids (Review Focus 5); Send to Research removes the line and repairs the subject.
- [ ] Gates; commit.

### Task 8: Docs and the guide
**Files:** `Maugham/Views/AREA.md` Map lines for the new files and the rules (figure subject, middle path, tree-owned card cache, listing lives at window level); `Maugham/Editor/AREA.md` (the reference index's new owner, FigureListing, FigureCentreGrid); `docs/guide/structure-and-binder.md` and `docs/guide/editor-and-focus.md` (the Figures section, the count filter, the inspector, Compare/Refresh); `docs/tripwires.md` if a census grew; DocBudget numbers only.
- [ ] Edit; gates; commit.

## After the last task
- Whole-branch review. Seams: Task 2's index move × the editor's numbers, completion and `projectLabelsElsewhere` (an editor mounted vs not); Task 6's hold × 7d's in-place grid and figure window (three surfaces, one figure); Task 3's subject repair × Send to Research from the grid, the inspector and another Mac; Task 4's count × the piece row's existing drop targets and rename row.
- `./scripts/test.sh full`, `./scripts/test.sh phone`, local Release build (ProjectWindow changed).
- Then write plan 8b against the built code.
