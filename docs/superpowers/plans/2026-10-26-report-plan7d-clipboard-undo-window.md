# Report plan 7d — clipboard, fill, import, one-step undo, and the figure window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the table grid behaves like Sheets/Excel for data movement — copy and paste with other apps (TSV + HTML), fill down/right, Import from CSV… — and its edits collapse into one undo step in the manuscript when it folds. A table can also pop out into its own window (closing with its project), and be sent to Research from the grid. Plan 7 is then complete.

**Architecture:**
- **One new batch verb carries every multi-cell change.** `FigureDocument.applyChanges(_:expecting:actionName:undoManager:)` applies `FigureReturnDiff.Change`s (inserts, deletes, cell sets) as one visit: one door check, one render, one ⌘Z. Paste-with-growth, Import (via `FigureReturnDiff.changes`, which keeps ids where headers/values match) and multi-row delete all use it.
- **A private grid undo manager while expanded; one window step at fold.** The host records the visit (in `commit`); at fold the coordinator registers ONE window-level step whose undo is `FigureInverse.compensating(visit:)` (declines whole on drift). This amends ADR 0023 (one stack per window) the way ADR 0026 did for the canvas.
- **The figure window is the same grid in a different frame.** A `WindowGroup(id: "figure", for: FigureWindowKey)` mounts the host-agnostic grid panel against the project window's `DocumentStore` host; it closes with its project and never restores on relaunch.

**Tech Stack:** Swift 5.10, AppKit, SwiftUI scenes, MaughamCore, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §3.5, §3.6, §6, §12 item 7 (Denver 2026-10-25: pop-out closes with its project; cell suggestions → plan 9). ADR 0023, ADR 0026. Survey of the built 7a–7c code: `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan7d-survey.md` (taken at 7c head 7eca1c20 before 7c's final fix wave; re-verify). 7c ledger carries "to 7d" (read-only gate refuses undo/redo; multi-row delete as one step).

## Global Constraints

- **Hard invariants:** figure state through the host (tripwire 20); every grid write from `FigureGridController` (one census row per spelling — tripwire 52; `applyChanges` classified in all three lists, `sendToResearch` gets its call-site row); no new observable state on `EditorHost` (6); typed `MaughamEvent`s with `/// Scope:` (21); no `"maugham"` literal outside `BuildVariant.swift` — a custom pasteboard type is spelled there (13); posture through the door only (47, 51).
- **Editor rules:** decoration census holds; no `NSPopover` for completion (5); Core stays platform-free (the HTML reader is a hand-written scanner, not `NSAttributedString`/`XMLParser`).
- **Tests:** keys on the real path, `firstResponder ===` asserted synchronously; no synthesised clicks / press-then-wait (33); an `NSOpenPanel` configuration is asserted as a value struct; inject the pasteboard (no global pasteboard in tests).
- **Rulings made writing this plan** (ledger them; Denver may overturn):
  - **R7d-1 ⌘R:** while the grid has the keys, ⌘R is Fill Right (the grid claims it); everywhere else it stays Check Writing. ⌘D is Fill Down. Pin the precedence with one real-key test; if a view cannot claim ⌘R before the menu, Fill Right ships without a shortcut and the plan says so.
  - **R7d-2 paste past the edge:** the table grows (rows/columns inserted; one ⌘Z); refused past `TableCSV.figureCellLimit` with a notice.
  - **R7d-3 what Copy carries:** display text as TSV + HTML for other apps; formulas only in Maugham's own pasteboard type, translated relative to the paste target (Excel).
  - **R7d-4 ⌘Z during an open cell edit:** cancels the edit (Esc); the field editor keeps no undo history of its own.
  - **R7d-5 pop-out undo:** the window keeps its own private stack for its life; closing it adds no text-side step. The in-place collapse applies only to in-place visits.
  - **R7d-6 pop-out caption:** read-only (caption is manuscript text — Route A needs the editor); name editable; bottom bar "Table N · caption".
  - **R7d-7 Send to Research:** from the grid menu; default scope the piece's Research, a submenu offers Shared; folds first; not undoable (as 6b); no alert.
  - **R7d-8 import matching:** `FigureReturnDiff` matching (ids kept where headers/values match) so other figures' references survive; header row from `TableCSV`'s detection.
  - **R7d-9 one grid per host:** a figure open in a window is never also expanded in place; its card reads "Editing in window" and a double-click focuses the window.
  - **R7d-10 drifted visit:** the collapsed undo declines whole with the existing "changed elsewhere" sentence.
  - **R7d-11 read-only:** undo/redo inside a read-only grid are refused (7c carry).
- **Census rule; gates; area guides** as plans 7a–7c (Views AREA at cap — docs in Editor AREA; DocBudget exact; `ProjectWindow.body` change → local Release build before tagging).

## Review Focus

1. **Copy B2:D9 in the grid, paste into Numbers; copy a 3×4 block from Excel and paste at C8 of a 10-row table**: Numbers gets the displayed values; Maugham grows the table to fit, one ⌘Z removes the growth and the values. Tasks 1–3.
2. **Expand, type in five cells, sort, fold, type a sentence, ⌘Z, ⌘Z**: the first ⌘Z takes back the sentence, the second the whole grid visit (cells and sort) in one step; ⇧⌘Z redoes it; if another device edited the table meanwhile, the undo declines with a sentence. Tasks 5–7.
3. **Open the table in a window, close the project window**: the figure window closes too; relaunch restores no figure window; the card shows "Editing in window" while it is open and double-click focuses it. Tasks 8–9.
4. **⌘R with the grid focused fills right; ⌘R in the text runs Check Writing.** Task 4.
5. **Import a CSV with reordered columns into a table another figure references**: the reference survives (ids kept by header match), one ⌘Z restores the old contents. Tasks 2, 4.

---

### Task 1: Core — clipboard, HTML tables, fill, paste plan, pin-clear inverse
**Files:** Core `TableClipboard.swift` (TSV out/in), new `Table/TableHTML.swift` (hand-written scanner: `rows(fromHTML:)`, `html(rows:)`), new `Table/FigureFill.swift` (`edits` via `FormulaParser.translate`), new `Table/FigurePaste.swift` (`changes(state:anchor:block:)` → inserts for growth + cell sets as `FigureReturnDiff.Change`s, honouring R7d-2's limit), `FigureInverse` (a pin clear that carries its pin inverts to a pin set).
- [ ] Failing tests incl. Excel/Sheets/Numbers/web HTML fixtures (colspan, entities, `<br>`, nested tags), translate on fill, growth, limit refusal, pin-clear round trip; `./scripts/test.sh core`; commit.

### Task 2: Host batch verb `applyChanges`
**Files:** `FigureDocument.swift`; `TripwireGrepTests` (three lists + planted offender); the controller's multi-row/column delete moves onto it (7c carry).
**Contract:** one door check, one visit, one render, one ⌘Z; `expecting:` drift guard; refusal writes nothing.
- [ ] Failing tests: one ⌘Z, one render, refusal, multi-row delete as one step; gates; commit.

### Task 3: Copy, cut, paste in the grid
**Files:** `FigureGridView` actions (enable copy/cut/paste), `FigureGridController`, `BuildVariant.swift` (pasteboard type), injected pasteboard seam.
**Contract:** R7d-2, R7d-3; read-only grid copies but refuses cut/paste with the reason; paste reads Maugham type → HTML → TSV → plain text.
- [ ] Failing tests: Review Focus 1 through controller verbs and the responder-chain action path; gates; commit.

### Task 4: Fill ⌘D/⌘R and Import from CSV…
**Files:** controller + menus (Format ▸ Table items, ⌘D binding, ⌘R precedence per R7d-1), `NSOpenPanel` configuration as a value struct, import via `FigureReturnDiff.changes` + `applyChanges`, KeyboardShortcuts/reference.md/DocSync.
- [ ] Failing tests: Review Focus 4 (real key path) and 5; panel struct; gates; commit.

### Task 5: The visit recorder
**Files:** `FigureDocument.swift` (`commit` seam records the visit incl. the grid's own undos/redos; `beginVisit`/`endVisit`; `undoVisit`/`redoVisit` reusing `registerFigureUndo`'s inner path).
- [ ] Failing tests: a visit's projection after edits, inner undo/redo, drift detection; gates; commit.

### Task 6: Private grid undo and the collapse at fold
**Files:** `FigureGridController`, `FigureGridView`/panel undo routing (`undoManager` override), `EditorCoordinator+FigureGrid.swift` (`closeFigureGrid` registers the ONE window step at the moment of folding; its undo awaits pending writes), read-only refusal (R7d-11), forced/teardown folds (detach clears the stack — nothing to register), Send-to-Research fold (no step), R7d-4, R7d-10.
- [ ] Failing tests: Review Focus 2 on the real key path; measure and pin that the cell/formula/caption/name fields leave no typing undo on the window stack; gates; commit.

### Task 7: ADR 0023 amendment and undo pins
**Files:** `docs/adr/0023-*.md` (amendment: the grid's private stack collapses into one window step at fold, ADR 0026 precedent), real-key-path pins of ⌘Z in the grid vs in the text after fold, disable experiments recorded.
- [ ] Write; gates; commit.

### Task 8: The figure window scene
**Files:** `FigureWindowKey`; `WindowGroup(id: "figure", for:)` in `MaughamApp.swift` with state restoration off; `FigureWindows` registry on the project session (no session lease); closes with its project; open event + modifier; a window-scoped `FigureGridPresence` so Format ▸ Table reaches it.
- [ ] Failing tests: open/close-with-project, no restoration, menus reach the window's grid; `ProjectWindow.body` change → note the Release build; gates; commit.

### Task 9: The window's surface, the card label, ⤢, Send to Research
**Files:** host-agnostic panel mounted in the window with the gate; R7d-6; R7d-9 ("Editing in window" on the card, double-click focuses the window, never expanded twice); ⤢ toolbar button; Send to Research command (R7d-7; census row).
- [ ] Failing tests: Review Focus 3; R7d-9; Send to Research folds and removes the line as 6b does; gates; commit.

### Task 10: Docs
**Files:** Editor AREA, `docs/guide/editor-and-focus.md` (clipboard, fill, import, one-step undo, the window, Send to Research), reference.md/KeyboardShortcuts, DocBudget, tripwires.md if a census grew.
- [ ] Edit; gates; commit.

## After the last task
- Whole-branch review (seams: Task 6 × 7c focus/forced folds × text undo; Task 8/9 × posture/gate and project close; Task 3 × read-only and BuildVariant).
- `./scripts/test.sh full`, `./scripts/test.sh phone`, local Release build.
- Plan 7 complete: report to Denver with the smoke list for 7a–7d.
