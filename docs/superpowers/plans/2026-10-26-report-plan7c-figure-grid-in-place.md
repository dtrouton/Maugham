# Report plan 7c — the table figure's grid, in place Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** double-click a table figure's card (or Return on its line, or right after Insert ▸ Table) and it opens in place into an editable grid — formula bar, slim toolbar, bottom bar, Sheets/Excel keys — in a fixed-height scrolling viewport inside the text column; Esc, Done or a click in the text folds it back into its card. Read-only where the figure's posture says so. A Format ▸ Table menu and a right-click menu carry the table commands.

**Architecture:**
- **One controller owns the visit.** `FigureGridController` holds the figure host, the pure `FigureGridModel` (selection, edit state, keys), and a `FigureGridValues` holder (computed values, advanced incrementally per host change). It is the only file that calls figure mutators from the grid (one tripwire-52 census row). The coordinator never observes `host.state` (tripwire 6).
- **The grid is the one hit-taking subview in a card's room.** The room still comes through `ProseMode.figureLineStyle` (7a decoration census), widened to key by line as well as path so only the expanded line grows; expand/fold re-lay out only that paragraph via `refreshFigureRooms`.
- **Batch verbs on the host.** `setCells` and `sortRows` make one ⌘Z, one render, one door check out of many cells.
- **Undo in 7c:** grid mutators register on the window's `UndoManager`, cell by cell. 7d replaces this with the private manager and the one-step collapse at fold (ADR 0023 amendment). The milestone ships whole, so the interim never ships.

**Tech Stack:** Swift 5.10, AppKit (TextKit 1), SwiftUI host, MaughamCore, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §3.4–3.6, §6 (keys table §6.3, §6.4), §11, §12 item 7 (Denver 2026-10-25: the expanded grid is a fixed-height scrolling viewport of about 15 rows; ⌘Z after Convert/Insert removes the figure; pop-out closes with its project — 7d; cell suggestions → plan 9). Survey of the built 7a+7b code: `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan7c-survey.md` (taken at 7b head 19ec43fa, before 7b's final fix wave; re-verify every line).

## Global Constraints

- **Hard invariants** (CLAUDE.md): Route A only for text (tripwire 7); figure state from the op log through the host (tripwire 20); every writer asks posture (tripwire 52 — new mutators classified in all three lists; production callers counted); no new observable state on `EditorHost` (tripwire 6); no heavy work in a binding setter (3); draw only visible rows from cached strings (4).
- **Editor rules:** no `NSTextAttachment`/U+FFFC under `Maugham/Editor/`; `paragraphSpacing` written only in `ProseMode.figureLineStyle` — cell text styles use alignment only; the cell editor is a field editor, never an `EditorSurface`; no `NSPopover` for any completion (tripwire 5; the spec names no formula autocomplete — don't add one).
- **Posture:** ask the door (`posture(forDocId:)` to draw, `settledPosture` to act); `.allows(.editFigure)` / `.isSettling` only; never build a `Posture(`, never compare a rung (tripwires 47, 51).
- **Tests:** keys on the real path (`NSEvent.keyEvent` → `keyDown`/`performKeyEquivalent`/`window.sendEvent`, `firstResponder ===` asserted synchronously); no synthesised clicks outside `clickRepresentatives` (at most one named, synchronous click representative for double-click-to-expand); no press-then-wait (tripwire 33) — test controller verbs. `TestWindow` only; `FontWarmup.ensure()`.
- **Rulings made writing this plan** (ledger them; Denver may overturn):
  - **R7c-1 interim undo:** window `UndoManager`, cell by cell, until 7d.
  - **R7c-2 viewport height:** min(rows, 15) rows (plus bars), growing to 15 at a commit edge; constant from 15 rows up.
  - **R7c-3 Return:** Return inside a figure line expands; Return at the line's end inserts a newline as today.
  - **R7c-4 same figure twice in a document:** only the clicked/caret line expands; the other keeps its live card.
  - **R7c-5 modes:** review mode expands read-only (select, scroll); translation review does not expand; a read-only share is read-only.
  - **R7c-6 two postures:** cells, structure and name follow the figure's `.editFigure`; the caption follows the text's `.writeText` membrane — each field disables on its own.
  - **R7c-7 sort:** stable; numbers < dates < text < booleans < empty (ascending); header and total rows stay put; formulas move with their rows (references are by id); one ⌘Z.
  - **R7c-8 fold with an open edit:** Done / click-away / text focus commit it; Esc discards; a formula that won't parse keeps the grid open with the error shown.
  - **R7c-9 code home:** `Maugham/Editor/FigureGrid*.swift` (so the decoration census covers it); pure model/entry/sort in Core `Table/`.
  - **R7c-10 Format ▸ Table enablement:** a window-scoped `@Observable FigureGridPresence` set one-way by the coordinator at expand/fold/selection-kind change; menu items post typed `MaughamEvent`s to `.keyWindow`; ⌘⌥↑↓←→ live on the menu items only (one delivery path).
- **Census rule:** planted offender + control for new censuses; extend, never exempt; never reword code to dodge a census.
- **Gates:** `./scripts/test.sh core` after Core; `./scripts/test.sh` after Mac; `./gen.sh` after adding files; `full` + `phone` at the whole-branch review. Never kill a gate or xcodebuild.
- **Area guides:** document the grid in Editor AREA (Views is at its cap). DocBudget by exact counts.

## Review Focus

1. **Double-click a 40-row table's card, arrow to row 30, type `=SUM(B2:B29)`, Return, Esc, Esc**: the viewport scrolls, the value computes, the card shows the new total, only that paragraph re-laid out at expand and fold, caret returns to the end of the figure line, no `applyExternalText`. Tasks 3–7.
2. **Expanded grid, then ⌘F (find) or a task-list jump moves focus to the text**: the grid folds (its open edit committed), never left expanded without focus. Task 7.
3. **A figure owned by another piece's author (read-only posture) or parked**: the grid expands read-only (select, scroll), the bars disabled, typing answered with the reason line; a posture change mid-visit (trust arrives) re-asks at the next `figureCardVersion` edge. Task 8.
4. **Select B2:D9, change format to currency, then ⌘Z**: one undo step restores all 24 cells, one render. Tasks 1, 5.
5. **Rename the figure from the bottom bar while expanded**: the line relabels (via `applyExternalText`), the grid stays open on the same figure; delete the line in another window → the grid folds. Tasks 5, 6.

---

### Task 1: Host batch verbs (FigureDocument + Core sort)

**Files:** `Maugham/OpLog/FigureDocument.swift` (`setCells`, `sortRows`), Core `Table/FigureSort.swift`, `TripwireGrepTests` (three tripwire-52 lists), OpLog AREA (paid for — at cap).

**Interfaces — Produces:** `setCells(_ edits: [CellKey: Cell?], actionName: String, undoManager: UndoManager?) async throws`; `sortRows(by column: ColumnID, ascending: Bool, values: (CellKey) -> CellValue, actionName:, undoManager:) async throws`; Core `FigureSort.order(table:values:column:ascending:) -> [RowID]` (pure, R7c-7).

**Contract:** one door check; entry pins for all formula cells via one `entryPins(for:cells:)`; commits with `render: false` then one render; ONE `registerFigureUndo` for the visit; the drift guard covers every cell; a refusal writes nothing. Built from the existing private `commit(render:)` and `registerFigureUndo`.

- [ ] Failing tests: one ⌘Z restores all cells; one render; refusal writes nothing; sort order per R7c-7 incl. header/total fixed and stability; census lists updated (planted offender proves the classification test bites).
- [ ] Red; implement; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 2: The grid model (Core, pure)

**Files:** Core `Table/FigureGridModel.swift`, `Table/FigureGridAddress.swift`. Tests: Core, table-driven.

**Interfaces — Produces:** `FigureGridModel` (selection by ids: anchor/focus `CellKey`, ranges, select-all; edit state: idle / editing(text) / composing formula with a reference cursor) and `reduce(_ key: FigureGridKey) -> [FigureGridEffect]` implementing spec §6.3 (arrows, Tab wrap, Return/⇧Return, typing replaces, F2/Return edit, Esc cancels then folds, ⇧arrows extend, ⌫ clears, ⌘⌥arrows insert row/column, `=` + arrows insert/move a reference). Excludes ⌘C/V/D/R (7d). `FigureGridAddress` renders/parses "B3", "B2:D9".

- [ ] Failing table-driven tests for every §6.3 row and edge (first/last row, header row, total row, empty table).
- [ ] Red; implement; `./scripts/test.sh core`; commit.

### Task 3: Values and entry

**Files:** Core `Table/FigureCellEntry.swift`; `Maugham/Editor/FigureGridValues.swift`.

**Interfaces — Produces:** `FigureCellEntry.cell(from text:, prior: Cell?, table:, names:, locale:) -> Result<Cell?, FormulaParseError>` (keeps prior format/alignment; a `suggested` format applies only over `.general`; `'` forces text); `formulaBarText(for:)`; `FigureGridValues` seeded from `assembledFigures()` at expand, advanced by `Workbook.setTable(state.table, id:)` per host state change (repaints only changed visible addresses), re-seeded on a `figureCardVersion` edge.

- [ ] Failing tests: entry for numbers/dates/percent/currency/text/formula/parse error with offset; prior format kept; incremental advance changes only dependents; re-seed on another figure's change.
- [ ] Red; implement; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 4: The grid view (AppKit)

**Files:** `Maugham/Editor/FigureGridView.swift`, `FigureGridLayout.swift` (pure). Host-agnostic (7d's window reuses it).

**Contract:** column letters, row numbers, visible rows only from cached strings; header bold, total ruled, alignments like the card (`FigureCardMetrics` typography); selection drawing; fixed-height scrolling viewport (R7c-2); in-cell field editor; column resize via a pure boundary hit function, `setColumnWidth` on mouse-up. No `paragraphSpacing` anywhere.

- [ ] Failing tests: pure layout (cell at point, frames, visible range for a scroll offset, resize boundary); drawing plan as values; mounted view through `TestWindow` draws only visible rows.
- [ ] Red; implement; `./gen.sh`; `./scripts/test.sh`; commit.

### Task 5: Bars and the controller

**Files:** `Maugham/Editor/FigureGridController.swift` (the only grid file calling figure mutators), `FigureGridBars.swift`; `TripwireGrepTests` census rows (`setCell(`, `setCells(`, `insertRow(`, … and `renameFigure(` from this one file).

**Contract:** formula bar (address + text; editing there = editing the cell; parse error shown at its offset, nothing written); toolbar (format `NSPopUpButton`, decimals −/+, align, Header row, Total row, Σ = SUM over the column above the selection; no ⤢ until 7d); bottom bar ("Table N · caption · name", Done). Caption commit = coordinator Route A on the caption range (`applyCommandEdit`, membrane-gated); name commit = `ProjectStore.renameFigure` (refusal → notice, field reverts). Range edits go through `setCells`.

- [ ] Failing tests: Review Focus 4 through controller verbs; formula-bar edit; Σ; caption edit through Route A; name refusal reverts.
- [ ] Red; implement; `./gen.sh`; `./scripts/test.sh`; commit.

### Task 6: Expand in place

**Files:** new `Maugham/Editor/EditorCoordinator+FigureGrid.swift`; `ProseMode.swift` (room closure keyed by path + line location); `FigureThumbnailOverlay.swift` (skip the expanded card); `EditorSurface.swift` (`clickCount == 2` arm over a pure `FigureCardHit.line(at:…)`); `doCommandBy` Return arm (R7c-3); `insertTableFigure` expands after landing.

**Contract:** expansion keyed by figure id + a line anchor tracker; expanded room = bars + viewport, constant while expanded; `refreshFigureRooms` at expand/fold re-lays out only that paragraph (counter-pinned; caret and scroll still); grid subview framed at the line's bottom, re-framed on resize and after `applyExternalText` (re-found by figure id; folds if the line is gone); surrounding text dimmed by a click-through view, no storage edit. R7c-4.

- [ ] Failing tests: pure hit function (card area vs text vs next line); expand/fold counter test; Review Focus 5; one named click representative for the double-click (synchronous); Insert Table lands expanded.
- [ ] Red; implement; `./gen.sh`; `./scripts/test.sh`; commit.

### Task 7: Focus handover and fold

**Files:** `EditorCoordinator+FigureGrid.swift`, `EditorSurface.swift` (`MaughamTextView.becomeFirstResponder` folds an expanded grid), `EditorCoordinator.swift` (`detach` folds first).

**Contract:** the grid takes first responder on expand; fold on Esc×2, Done, a click in the text, the text view becoming first responder (covers every `makeFirstResponder(textView)` caller), detach / document switch / window close, the line leaving; R7c-8; caret returns to the end of the figure line.

- [ ] Failing tests on the real key path (keyEvent → keyDown/sendEvent, `firstResponder ===` synchronously); Review Focus 2; `EditorIntegrationHarnessTests`: expand/fold fires no `applyExternalText`, no burst.
- [ ] Red; implement; `./scripts/test.sh`; commit.

### Task 8: Read-only states

**Files:** `Maugham/Editor/FigureGridGate.swift` (pure), controller + bars.

**Interfaces — Produces:** `FigureGridGate.mode(figureMayEdit:parked:hostClosed:shareIsReadOnly:isReviewMode:isTranslationReview:) -> .editable | .readOnly(reason) | .noExpand` (inputs gathered from the posture door — `.allows(.editFigure)` — never a rung).

**Contract:** R7c-5, R7c-6; re-asked at expand and each `figureCardVersion` edge; read-only grid selects and scrolls, bars disabled, typing answered with the reason line; a host refusal mid-visit (`FigureEditRefused`/`FigureParkedRefused`) → notice, cell reverts.

- [ ] Failing tests: every gate row; Review Focus 3; refusal mid-visit reverts.
- [ ] Red; implement; `./scripts/test.sh`; commit.

### Task 9: Menus

**Files:** grid right-click `NSMenu` (validated by the gate); `MaughamApp.swift` `CommandMenu("Format")` ▸ Table; `FigureGridPresence` (window-scoped observable) + `focusedSceneValue`; `MaughamNotifications.swift` (typed events with `/// Scope:`); `KeyboardShortcuts.swift`; `docs/guide/reference.md` rows; DocSync arrow glyphs if the extractor needs them.

**Contract:** R7c-10. Items: format details, insert/delete/move row/column, sort ascending/descending by column, header/total row. One delivery path for ⌘⌥ arrows (menu items). Format-menu order pinned.

- [ ] Failing tests: item validation by gate/selection; each item's event reaches the controller verb (posted, not clicked); DocSync rows; shortcut bound once.
- [ ] Red; implement; `./scripts/test.sh`; commit.

### Task 10: Docs and censuses

**Files:** Editor AREA (the grid is the one hit-taking subview in a card's room; room keyed by line; focus rule; controller is the one grid writer), `docs/guide/editor-and-focus.md` (what ships), `docs/tripwires.md` row 52's writer list if it names writers, DocBudget ceilings.

- [ ] Edit; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

## After the last task

- Whole-branch review (seams: Task 6 × 7a's room refresh and trailing-room memo; Task 7 × find/navigation/detach; Task 5 × Route A caption edits and rename via `applyExternalText`; Task 8 × posture epoch; Task 1 × tripwire 52 counts).
- `./scripts/test.sh full`, `./scripts/test.sh phone`.
- Then write 7d against the built 7c.
