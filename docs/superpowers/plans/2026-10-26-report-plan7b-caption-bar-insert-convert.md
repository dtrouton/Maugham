# Report plan 7b — caption bar, figure diagnostics, Insert Table and Convert Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a figure line reads as a caption bar (its syntax faded until the caret enters, "Table 2." / "Figure 3." drawn beside it); broken or mislabelled figure lines are diagnosed; ⌘⇧T inserts a 3×3 table figure and ⌘⌥⇧T (or right-click) converts a pipe table into one, each undone by one ⌘Z that also sends the new figure to the Trash; the old grid sheet is retired.

**Architecture:**
- **The fade is paint, the un-fade is a temporary.** ProseMode paints figure-line syntax in a blended faint colour as a pure function of tokens (window ≡ whole-document). On selection change the coordinator puts a layout-manager temporary foreground over at most two lines' syntax ranges (the line the caret left and the one it entered) — no storage edit, no re-layout. The number is drawn by `ReferenceLabelOverlay`, never text.
- **Diagnostics are lexical plus registry.** A pure Core `FigureLineResolution.Status` (built on 7a's `FigurePathRule` and `FigureLineResolution.Index`) answered from the window's `FigureCardCache` through a provider; `ManuscriptChecks` reports; refresh rides `figureCardVersion` at the settle edge. No disk probe.
- **One ⌘Z for text and figure.** `applyCommandEdit` gains an `alongside:` registration made inside its undo group; a self-re-registering `FigureBirthUndo` removes the figure to the Trash on undo and restores the same id on redo.

**Tech Stack:** Swift 5.10, AppKit (TextKit 1), SwiftUI host, MaughamCore, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §3.2, §3.3, §6.4, §12 item 7 (Denver 2026-10-25: ⌘Z after Convert or Insert Table removes the figure it made, to the Trash, with the text). Audit items F9 and E2 (`docs/superpowers/notes/2026-10-25-maintainability-review.md`). Survey of the built 7a code: `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan7b-survey.md` — every file:line there was taken at 7a head 3eca0fb1 BEFORE 7a's final fix wave; re-verify.

## Global Constraints

- **Hard invariants** (CLAUDE.md): text changes through Route A only (tripwire 7, no `applyExternalText`); figure state from the op log, never `figures/*.csv` (tripwire 20); every manuscript writer asks posture first (tripwire 52 — a new production `createFigure(` call gets its census row; never call the internal `createFigureStream(` from new code).
- **Editor area rules** (`Maugham/Editor/AREA.md`): no storage restyle on a caret move; a new counter moves at a settle edge (D1); no NSTextAttachment; `paragraphSpacing` is written only in `ProseMode.figureLineStyle` (7a Task 8 census).
- **Tests:** no test synthesises a click, right-click or double-click, and none presses a control then waits (tripwire 33) — test the pure offer functions and the coordinator verbs. A suite styling through production typography calls `FontWarmup.ensure()`. Windows through `TestWindow`.
- **Rulings made writing this plan** (ledger them; Denver may overturn):
  - **R7b-1 number placement:** "Table 2." is drawn in the left margin, right-aligned to the text column, by `ReferenceLabelOverlay`; when the inset is too narrow it falls back to the overlay's existing tag-above-the-line layout. Card heights unchanged.
  - **R7b-2 fade colour:** syntax punctuation blended toward the background (not alpha — focus dim's absolute alpha would brighten it). Image and table figure lines alike.
  - **R7b-3 kind mismatch:** a `.csv` line labelled `fig:` is an amber editor warning (new kind); Publish keeps numbering it as a figure until plan 9. An image line labelled `tbl:` gets the existing `.labelOnWrongElement`.
  - **R7b-4 F9 scope:** lexical + registry only; a missing image file stays Publish's `.imageUnreadable` and the thumbnail's "missing".
  - **R7b-5 redo:** restores the same figure from the Trash (id kept). A refused removal or restore still moves the text, with a notice naming why.
  - **R7b-6 refused line write after the figure exists:** the figure goes to the Trash, with a notice.
  - **R7b-7 no pipe-table insert command:** ⌘⇧T makes a figure; hand-typed pipe tables keep Tab/Return/tidy. `ReportInsert.table` and friends go.
  - **R7b-8 after retirement:** a delimiter-row double-click is plain word selection; ⌘⌥⇧T outside a pipe table does nothing.
  - **R7b-9 names and labels:** Insert names the figure `table` (`table_2`, …) with label `tbl:<name>`; Convert keeps the pipe table's label (minting one if none) and names the figure after it, else after the caption; the name may take a suffix, the label never changes.
  - **R7b-10 pipe cells:** read exactly as CSV import reads cells (typed numbers/dates, `=` formulas, an unparseable formula kept as text); inline Markdown stays literal.
  - **R7b-11 posture:** menu gate unchanged (`InsertMenuGate`, `.writeText`); the store's `.editFigure` door refuses with a notice and writes nothing; no new Posture door (tripwires 47/51 untouched).
- **Census rule:** new censuses get a planted offender and a control; existing tripwires extend, never exempt; no rewording code to dodge a census.
- **Gates:** `./scripts/test.sh core` after Core changes; `./scripts/test.sh` after Mac changes; `./gen.sh` after adding or deleting a file; `full` and `phone` at the whole-branch review. A run ending only in "Test Case … started." was killed by another session's xcodebuild: re-run. Never kill a gate or xcodebuild process.
- **Area guides:** OpLog and Views AREA are at the 8,000-word cap — pay for any added line by moving why-clauses to `docs/history/<area>.md`. DocBudget ceilings by exact counts.

## Review Focus

1. **Insert Table, type in the caption, ⌘Z, ⇧⌘Z, ⌘Z**: the first ⌘Z takes back the typing only; the second removes line and figure (figure in the Trash); redo brings the same figure id back with its line; a second undo removes it again. Tasks 3, 4.
2. **Convert a pipe table with `{#tbl:cash}` that `@tbl:cash` cites elsewhere**: the reference still resolves to the same number, the caption survives, `=` cells become formulas, and if another device edits the table text while the figure is being made, the conversion refuses and the new figure goes to the Trash. Tasks 1, 5.
3. **Arrow the caret through a document with 20 figure lines**: each line un-fades only while the caret is on it; no storage edit, no re-layout, no scroll; entering translation review leaves no stray temporary colour and the dimming clears exactly. Task 8.
4. **A figure line `../notes/x.png`, one into `figures/` naming a removed figure, one ambiguous, one `.csv` labelled `fig:`**: each gets its own diagnostic sentence; the diagnostics update when a remote change restores the removed figure, at the settle edge. Task 7.
5. **The grid sheet is gone**: ⌘⌥⇧T in a pipe table converts, a delimiter-row double-click selects a word, no reference to the sheet survives in code, tests or docs. Task 6.

---

### Task 1: Core — pipe table to figure table, and a figure line's status

**Files:** Core `Table/TableCSV.swift` (extract the per-field reader), Core `Table/FigureTable.swift` or a sibling (`FigureTable(pipe:locale:names:)`), Core `Table/FigureLineResolution.swift` (`Status`), Core AREA Map rows. Tests: Core.

**Interfaces — Produces:** `TableCSV.read(rows: [[String]], locale:, names:)` shared by CSV and pipe import; `FigureTable(pipe: TableText, locale:, names:) throws` (header rows = 1, alignments mapped to cells, `TableCSV.figureCellLimit` guarded); `FigureLineResolution.Status` (`.notLocal`, `.outsideFigures`, `.figure(FigureRecord)`, `.missing`, `.ambiguous([FigureRecord])`) and `status(linePath:documentPath:index:)`.

**Contract:** R7b-10. CSV import's behaviour unchanged (its tests stay green untouched). Status uses the same lexical rule as Publish.

- [ ] Failing tests: escaped pipes, `=` cells, an unparseable formula kept as text, alignments, caption/label ignored by the table, cell limit; every Status arm incl. `../notes/x.png` (`.notLocal`).
- [ ] Red; implement; `./scripts/test.sh core`; commit.

### Task 2: Store seams

**Files:** `Maugham/Stores/ProjectStore+Figures.swift`, `ProjectStore+CollectionPieces.swift` (the one `removeFigure` caller), `Maugham/Views/FigureCardCache.swift`. Tests: store + cache tests.

**Interfaces — Produces:** `createFigure(kind:name:piece:rows:columns:table: FigureTable? = nil)` (public spelling kept so the tripwire-52 census sees callers); `removeFigure(id:)` → `@discardableResult TrashEntry`; a book-locale + `FormulaNames` helper the editor can call; `FigureCardCache.status(forLinePath:documentPath:) -> FigureLineResolution.Status?` (nil before the first fill; memory only).

**Contract:** R7b-11. A refused door writes nothing (no stream, no record, no render).

- [ ] Failing tests: create with a table (header row kept, values computed); refusal writes nothing; removal returns the Trash entry that `restoreTrashEntry` brings back with the same id; cache status nil before fill, correct after.
- [ ] Red; implement; `./scripts/test.sh`; commit.

### Task 3: One ⌘Z for the line and the figure

**Files:** `Maugham/Editor/EditorCoordinator+Insert.swift` (`applyCommandEdit(... alongside:)`), new `Maugham/Editor/FigureBirthUndo.swift` (or beside `OpUndoRegistrar`). Tests: new suite on a real store.

**Contract:** the registration is made inside `applyCommandEdit`'s own undo group (after `replaceCharacters`, before `setActionName`) so text and figure are one step. `FigureBirthUndo` re-registers itself both ways (OpUndoRegistrar's redo does not — don't reuse it as is); undo synchronously registers redo then runs `removeFigure`; redo registers undo then `restoreTrashEntry`; tasks chain (a redo awaits a pending removal); `[weak]` captures per OpUndoRegistrar's notes; the existing `workTaskSink` seam makes tests deterministic. R7b-5.

- [ ] Failing tests: Review Focus 1 at the coordinator level (no UI); refused removal → text undo lands + notice; refused restore (name taken meanwhile) → text redo lands, line shows the removed card, notice; typing either side stays its own step.
- [ ] Red; implement; `./scripts/test.sh`; commit.

### Task 4: Insert ▸ Table makes a table figure

**Files:** `EditorCoordinator+Insert.swift` (`insertTableFigure()` replacing `insertTable()`), `EditorSurface.swift` ParagraphProviders + `EditorHost.swift` (`tableFigureMaker` provider: makes the figure in the document's piece, returns id + line path), `FigureIngest.swift` (`figureLine` takes a label kind), `ReportInsert.swift` (delete `table`/`nextTableLabelNumber`/`tableEdit`; inline literals in their tests), `TripwireGrepTests` census row, `InsertCommandTests` retargeted.

**Contract:** follows image ingest's landing (`beginFigureIngest`: anchor tracker, composition wait, deferred landing). Writes `![Caption](figures/table.csv){#tbl:table}` (R7b-9) with "Caption" selected; always a `tbl:` label; R7b-6 on a refused line write; one ⌘Z via Task 3. ⌘⇧T unchanged as a shortcut.

- [ ] Failing tests: the line, label, selection and a 3×3 header-row figure; R7b-6; Review Focus 1 through the real command path (notification → coordinator), not a click; census row counted.
- [ ] Red; implement; `./gen.sh` if files change; `./scripts/test.sh`; commit.

### Task 5: Convert to Table Figure

**Files:** `EditorCoordinator+Tables.swift` (`convertTableToFigure(at:)`, pure `convertOffer(atCharacterIndex:)`; keep `TableAnchorTracker`), `EditorSurface.swift` (`MaughamTextView.menu(for:)` adds the item when the offer says so), `MaughamApp.swift` (⌘⌥⇧T + an Insert-menu item), `MaughamNotifications.swift` (`maughamEditTable` → `maughamConvertTable`), `KeyboardShortcuts.swift`.

**Contract:** record the block text and an anchor; await creation with `FigureTable(pipe:)`; re-verify the text at the anchor; replace the table block (rows + its `Table:` caption line) with one figure line keeping caption and label (R7b-9); refuse and Trash the figure if the text changed (Review Focus 2); one ⌘Z via Task 3.

- [ ] Failing tests: Review Focus 2; `@tbl:` resolves to the same number after conversion (ReferenceIndex); offer true inside a pipe table, false outside; the menu item appears only when offered (pure function + `menu(for:)` called directly with a constructed event is a synthesised click — test the offer and the item builder only).
- [ ] Red; implement; `./scripts/test.sh`; commit.

### Task 6: Retire the grid sheet

**Files:** delete `Maugham/Views/TableGridEditor.swift`, `MaughamTests/Views/TableGridModelTests.swift`, `MaughamTests/Editor/TableGridCommandTests.swift`; edit every reference in survey §7 (coordinator arms, EditorSurface provider + double-click arm, EditorHost state/modifier/provider, `answersTableGrid`, TripwireGrepTests helper list + the delimiter-row double-click census section, Editor/Views AREA, guide pages, `TableClipboard` doc comment). `./gen.sh` after deleting.

**Contract:** R7b-8. Nothing that only served the sheet survives; `TableAnchorTracker` and `mouseDownBody` stay. A grep for `TableGrid`, `editTable`, `maughamEditTable`, "Edit Table" returns nothing in code, tests or docs (outside `docs/history/` and plans/specs).

- [ ] Write the grep check into the task report; run `./gen.sh`, `./scripts/test.sh`; commit.

### Task 7: Figure-line diagnostics

**Files:** `Maugham/Publish/PublishProblem.swift` (new kinds `.figureNotFound(path)`, `.figureAmbiguous(path)`, `.tableFigureLabelledFig(label)`; `.figurePathNotLocal` sentence generalised from "figure image" to "figure"), `Maugham/Editor/ManuscriptChecks.swift` (`analyse(... figureLineStatus:)`), ParagraphProviders + EditorHost (`figureLineStatus` provider bound with the document path), `EditorCoordinator.setFigureCardVersion` (request a problem refresh at the settle; Editor AREA D1 names it).

**Contract:** R7b-3, R7b-4. One diagnostic per figure line, underlined on the `](path)` range; nil provider skips registry checks like `index == nil` does. Severity by profile as existing checks.

- Also (7a carry): an uncaptioned table figure emits `\caption[{}]{}` (an empty list-of-tables entry) in LaTeX — match the uncaptioned pipe table's `\relax` form, in `Maugham/Publish/` beside the 7a table-figure arm; pin it.
- [ ] Failing tests: Review Focus 4 row by row; a remote restore clears `.figureNotFound` at the settle edge, not mid-burst; F9's `../notes/x.png`.
- [ ] Red; implement; `./scripts/test.sh`; commit.

### Task 8: The caption bar

**Files:** `Maugham/Editor/ProseMode.swift` (faint blended colour for figure-line syntax), `EditorCoordinator.swift` / `+Typography.swift` (caret-line temporary un-fade in `textViewDidChangeSelection`, re-asserted at the settle), `EditorCoordinator+TranslationBadges.swift` (no un-fade in translation review; comment updated), `ReferenceIndex.swift` (per-document `(tablesBefore, figuresBefore)` offsets), `ReferenceLabelOverlay.swift` (the "Table N." / "Figure N." label per R7b-1).

**Contract:** R7b-1, R7b-2. A caret move does no storage edit and no re-layout (counter-pinned); windowed ≡ whole-document (equivalence case); focus dim on a faded line never brightens it; numbers match ReferenceIndex for labelled and unlabelled lines (an unlabelled `.csv` line numbers as a Table — 7a final fix I4).

- [ ] Failing tests: Review Focus 3; equivalence case; the label's number for mixed documents across two chapters.
- [ ] Red; implement; `./scripts/test.sh`; commit.

### Task 9: Docs and audit closure

**Files:** Editor/Views/OpLog AREA (within caps), ADR 0033 §4 (E2: a pipe table merges whole-table across devices; table figures are the cell-granular answer and Convert is the route), `docs/guide/editor-and-focus.md`, `docs/guide/reference.md` (⌘⇧T, ⌘⌥⇧T rows rewritten), DocBudget ceilings.

**Contract:** rule 7 — describe what ships. DocSync tests green.

- [ ] Edit; `./scripts/test.sh core`, `./scripts/test.sh`; commit. (PR #111's F9/E2 comment is posted by the controller after merge, with Denver's push.)

## After the last task

- Whole-branch review (ledger; seams: Task 3 × Tasks 4/5 and window undo/document switch; Task 7 × 7a's cache refresh; Task 8 × focus dim, translation dimming and the card overlay; Task 6 × every census).
- `./scripts/test.sh full`, `./scripts/test.sh phone`.
- Then write 7c against the built 7b.
