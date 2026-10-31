# Report plan 9c-2 — dots, the strip, and travel to a cell — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A cell with an open note shows a dot on the Mac card, in the grid and on the phone card. Selecting a marked cell in the grid shows its notes in a strip above the grid with Accept (or Got it) and Reject. The queue's Accept on a figure suggestion, a queue row click and an inspector note click travel to the figure and select the cell.

**Architecture:** One judged read of a figure's open cell notes moves into Core beside `FigureCache`'s state, feeding the Mac card fill, the Mac walk and the phone (tripwire 19). Card dots ride `FigureCardModel` (no height change, so no re-layout). The grid gets an observed `openCellNotes` on `FigureDocument` through `FigureGridHost`. The strip is a fourth panel part whose room is reserved only while the figure has an open live cell note: presence is a `FigureCardModel` flag, so it changes through the existing card-version → `refreshFigureRooms` path, never per selection (risk §11.1). The strip calls plan 9c-1's `FigureDocument` verbs with the grid's undo manager.

**Tech Stack:** Swift 6, MaughamCore `Table/`, Maugham `Editor/` (grid, panel, card drawing), `OpLog/FigureDocument`, `Views/Review`, `Views/FigureInspector`, MaughamPhone `Read/`.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §6.1 ("suggestion dots"), §6.5, §11.1. Built plan this extends: `docs/superpowers/plans/2026-10-31-report-plan9c1-cell-anchors.md` (its verbs and rulings). Survey with file:line for every name here: `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan9c2-survey.md` (§9 has each task's files).

## Global Constraints

- "An assistant suggestion or note anchored to a cell shows a dot on that cell, both on the card and in the grid. Selecting the cell shows the suggestion in a strip above the grid, with Accept and Reject. Accepting writes the cell as the author, with the suggestion's attribution recorded." (§6.5)
- "Room is made with the figure line's `paragraphSpacing` … It changes only when the row count changes or the editor expands or folds, and then only that paragraph re-lays out." (§6.1) This plan adds one more edge — open cell notes appearing or all being answered — and nothing per keystroke or per selection.
- No new `EditorControl` counter; no heavy work in a binding setter (tripwires 3, 6). No per-row or per-draw note derivation (`FigureDocument.annotations()` re-derives every call — never call it per draw or per arrow key).
- Tests never press a mounted control and then wait for its effect (tripwire 33): call controller verbs and await settles. Prompts (changed-since, reject reason) are value seams in tests.
- A new caller of a `FigureDocument` verb gets its `manuscriptWriterCallSites` row (tripwire 52). Mac and phone share Core for anchors, notes and marks (tripwire 19).
- Views, OpLog and Stores AREA are at their word cap: new rules go in Editor AREA; trim before adding elsewhere.
- Help describes only what ships (rule 7).

## Rulings made while writing this plan

- **The strip row is given back** when the figure's last open live cell note is answered (same edge as its arrival). The rows part stays grow-only (R7c-2).
- **Presence and dots count live anchors only.** An orphaned note stays in the queue (it can't be accepted in the grid) and reserves no strip room.
- **A range note's dot sits on its top-left cell**; the strip shows every open note whose range contains the active cell.
- **Strip verbs:** a suggestion gets Accept and Reject; a comment or query gets Got it (`acceptNote`) and Reject. Reply stays in the queue.
- **A strip Reject after an in-place fold** is reversed by Reopen in the queue, not ⌘Z (an Accept joins the visit, as 9c-1 pinned).
- **A queue click on a figure a grid already holds** selects the cell in that grid without travelling.
- **The reject-reason prompt** is an AppKit sheet on the grid's window.

## Review Focus

1. Arrow keys across marked and unmarked cells in an expanded in-place grid: zero room refreshes, zero paragraph-style edits. Pin in Task 1.
2. An MCP note landing while the grid is open marks its cell and, if it is the figure's first live note, opens the strip room once after the settle — the caret and typing are undisturbed. Pin in Tasks 1 and 4.
3. Accept from the strip, fold, ⌘Z in the window: the cell reverts and the note reopens in one step. Pin in Task 6.
4. A suggestion whose cell changed since it was made: Accept asks; declining writes nothing. Pin in Task 6.
5. Queue Accept on a figure suggestion when no grid is open: the figure opens in the centre with the cell selected and the strip showing that note. Pin in Task 7.

---

### Task 1: The strip's room, proven first

**Files:** `Maugham/Editor/FigureGridPanel.swift`, `Maugham/Editor/EditorCoordinator+FigureGrid.swift`, Core `Table/FigureCardModel.swift` (add `hasOpenCellNotes: Bool`, default false), tests `MaughamTests/Editor/FigureGridStripRoomTests.swift` (mounted via `TestWindow`, `FontWarmup.ensure()` in class setUp), updates to `FigureGridExpandTests.swift`.

**Interfaces:**
- Produces: `FigureGridPanel.room(rows:strip:typography:)`, `parts(in:strip:)` with a `strip` part between formula bar and grid, `FigureGridPanel.stripHeight`; `FigureGridExpansion` keeps a grow-only rows room and a two-way strip flag; expand, mount and `figureGridCardsChanged` read the card's `hasOpenCellNotes`. The figure window and Research-table grid pass `strip: false` until Task 5 (Research tables never show one).
- [ ] Step 1: failing tests: (a) a card version flipping the flag re-lays out exactly the expanded line once (count `refreshFigureRooms`) and moves the text below by `stripHeight`; mid-burst it waits for the settle; (b) many arrow-key selections across marked/unmarked cells cause zero room refreshes and zero `.paragraphStyle` edits; (c) the flag going false gives the room back; (d) parts stack in order.
- [ ] Step 2: implement. Disable experiment: derive the strip from the selection → (b) fails; record it.
- [ ] Step 3: `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 2: One judged read of open cell notes (Core)

**Files:** new Core `Table/FigureCellNotes.swift`; `Table/FigureCache.swift`, `Table/FigureCardModel.swift`, `Table/FigureCardBook.swift`; Mac `Stores/ProjectStore+Annotations.swift` (`figureNotesAndTable` delegates); Core AREA; Core tests.

**Interfaces:**
- Produces: `public struct FigureCellNotes: Equatable, Sendable` — open notes keyed by anchor (top-left) cell for marks, `notes(containing: CellKey) -> [Annotation]`, `hasLive: Bool`; built from a judged annotation projection (the same `amendmentPermits:` judging the Mac walk uses) against the figure's table. `FigureCache` caches it beside the state (one read). `FigureCardModel.markedCells` (shown positions) and the real `hasOpenCellNotes`; `FigureCardBook.build(…, openCellNotes: [String: FigureCellNotes])`.
- [ ] Step 1: failing Core tests: a range marks only its top-left; orphaned → no mark, no presence; resolved/withdrawn notes don't count; a cached second read derives nothing; `notes(containing:)` finds a range note from an inner cell.
- [ ] Step 2: implement; the Mac walk delegates (behaviour unchanged, its tests green); commit after `./scripts/test.sh core` and `./scripts/test.sh`.

### Task 3: Dots on the Mac card

**Files:** `Maugham/Stores/DocumentStore+Figures.swift` (`FigureCardInputs.openCellNotes`, filled from an open host's projection first, else the cache), `Maugham/Views/FigureCardCache.swift`, `Maugham/Editor/FigureCardDrawing.swift` (`Plan.marks`, `draw`), tests in `FigureCardDrawingTests.swift` and `FigureRoomRefreshTests.swift`.
- [ ] Step 1: failing tests: a marked shown cell gets a mark rect in its top-right corner clear of the Research corner; a note's arrival bumps the card version and repaints with no re-layout (room refresh count unchanged when the strip flag doesn't flip — the card is folded).
- [ ] Step 2: implement; commit after `./scripts/test.sh`.

### Task 4: The host's notes and dots in the grid

**Files:** `Maugham/OpLog/FigureDocument.swift`, `FigureDocument+Annotations.swift`, `Maugham/Editor/FigureGridHost.swift`, `ResearchTableHost.swift`, `FigureGridController.swift`, `FigureGridView.swift`, `FigureGridLayout.swift`.

**Interfaces:**
- Produces: observed `FigureDocument.openCellNotes: FigureCellNotes`, recomputed once at `notesChanged`, `reload`, note-carrying compensations and restore (never per draw); `FigureGridHost.openCellNotes` (`ResearchTableHost` answers empty); the controller caches it; `FigureGridDataSource.figureGridIsMarked(_:)`; `FigureGridPlan.marks` for visible cells only.
- [ ] Step 1: failing tests: an MCP note landing on an open host marks its cell with no table-state change; a reject unmarks; marks computed for visible cells only; Research-table grids never mark.
- [ ] Step 2: implement; commit after `./scripts/test.sh`.

### Task 5: The strip's content (plan and view)

**Files:** new `Maugham/Editor/FigureGridStrip.swift`; `FigureGridController.swift` (`refreshBars` feeds it), panel users (in-place, figure window/centre) pass the real strip flag; Editor AREA.

**Interfaces:**
- Produces: `FigureGridStrip.Plan.make(notes:active:table:names:locale:mayAccept:mayReject:readOnly:)` → kind, address, body, before → after (Core `SuggestionDisplay` figure arm), "1 of 2" paging, buttons per the rulings, or the empty line "No notes on this cell"; read-only or refused posture hides or disables the buttons with the reason; the controller observes `.acceptOrReject` posture.
- [ ] Step 1: failing tests on the plan's truth table (suggestion / comment / query / none / two notes / read-only / refused).
- [ ] Step 2: implement the view (AppKit, the bars' style); commit after `./scripts/test.sh`.

### Task 6: The strip acts

**Files:** `FigureGridController.swift` (`stripAccept(_:)`, `stripGotIt(_:)`, `stripReject(_:reason:)` through `enqueue` with `gridUndo`, committing an open cell edit first), `FigureGridStrip.swift`, the reject-reason sheet, `MaughamTests/TripwireGrepTests.swift` (row `"acceptSuggestion(": 1` for `FigureGridController.swift`, plus any others the census names), new `MaughamTests/Editor/FigureGridStripTests.swift`.
- [ ] Step 1: failing tests through the controller verbs (no press-then-wait): accept writes the cell and resolves; ⌘Z in the grid restores and reopens; in place, fold then the window's ⌘Z undoes the visit including the accept; changed-since asks, then writes on yes and nothing on no; reject keeps its reason; Got it resolves a comment; refused posture says why.
- [ ] Step 2: implement; commit after `./scripts/test.sh full`.

### Task 7: Travel to a cell

**Files:** `FigureGridController.swift` (`select(_:)`), `Maugham/Editor/FigureWindow.swift` (`FigureWindows.reveal(_:cell:)`, pending cell consumed at mount), `FigureCentreGrid.swift`, `EditorCoordinator+FigureGrid.swift` (`openFigureGrid` consumes a pending cell), `Views/Review/AnnotationScope.swift` (the figure suggestion's Accept travels instead of "Accept it in the table"; orphaned → disabled with its reason), `AnnotationsPane.swift`, `AnnotationListView.swift`, `FigureInspector.swift` (notes become buttons), the wiring files the survey names.
- [ ] Step 1: failing tests: a centre mount selects the pending cell and the strip shows that note; a grid already holding the figure is focused and selected without travel; the row gate truth table (`FigureAnnotationRowTests`) updated.
- [ ] Step 2: implement; commit after `./scripts/test.sh`.

### Task 8: Dots on the phone card

**Files:** `MaughamPhone/Read/PhoneFigureBook.swift` (pass the Core read's notes to `FigureCardBook.build`), `MaughamPhone/Read/FigureCardView.swift` (`FigureTablePlan` mark arrays, `rowView` draws), phone tests.
- [ ] Step 1: failing plan tests: a marked cell plans a dot; no strip, no buttons.
- [ ] Step 2: implement; commit after `./scripts/test.sh phone`.

### Task 9: Docs, register and gates

**Files:** `docs/guide/annotations-and-suggestions.md` (Accept in the table, the strip, travel; drop "not available yet"), `docs/guide/editor-and-focus.md`, `docs/superpowers/notes/cross-surface-contracts.md`, Editor/Phone/Core AREA lines, register claim M5-AN-064 (a UI now offers Accept) and any new claim for the strip, DocBudget numbers.
- [ ] Step 1: docs; `./scripts/test.sh core`, `full`, `phone`; Release build (`ProjectWindow.swift` wiring is touched).
- [ ] Step 2: commit.
