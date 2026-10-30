# Report plan 9a — publishing table figures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A table figure publishes as a real table — its computed, formatted cells — in PDF, EPUB and Word, with the problems and notes spec §9 names.

**Architecture:** Each publish takes one Sendable snapshot of the book's figures (records, states, a computed `Workbook`, pin and source status) on the main actor, carried to resolution in `PublishContext`. Resolution turns each table-figure line into a `FigureTableLayout` (Core, pure: strings per cell in the body's `TableLocale`, header/body/total rows, alignments) and raises the new problems; the three emitters draw the layout where they print the literal source line today.

**Tech Stack:** Swift 6, MaughamCore (`Table/`), Maugham `Publish/`, LaTeX (tectonic), XHTML/EPUB, OOXML.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §9 (also §3, §4.2, §5, §8 for what a body shows). Report house style: `docs/superpowers/specs/2026-10-19-report-foundations-design.md` §5.3, §6.2.

## Global Constraints

- "PDF, EPUB and Word emit tables from the figure model's computed values with formats applied. Separators and month names follow each body's language. The header row repeats and the total row is ruled." (§9)
- Problems, "with the Report profile red and others amber": an error cell; a missing Research source; a reference to a figure in Research. (§9)
- "Amber everywhere: 'uses numbers from Research', 'Research changed since refresh', and the `NPV` first-flow note." (§9)
- "Unused figures are not published." "Hand-typed pipe tables publish exactly as before." (§9)
- `figures/<name>.csv` is written, never read (tripwire 20): values come from the op log through `FigureCache`/`Workbook`, never from the CSV.
- A book without report syntax emits byte-identical bodies (`NovelBodyGoldenTests`).
- Edit `EmissionContract.swift`, never `EMISSION.md`; regenerate it and update the golden SHA in `ReportProjectCreationTests`.
- Text cells print their source text in every body; translated labels are plan 9e (§8). Do not add a translation hook here beyond what `FigureCardModel` already has.
- Help describes only what ships (rule 7).

## Rulings made while writing this plan

- **Locale:** a body's cells format with `TableLocale(languageTag: body.config.metadata.language)` — the same constructor the editor card uses, so the PDF matches the card (a bare `en` borrows the Mac's region, as the card does). Cost if wrong: a later change to region policy touches one constructor call.
- **Parked figures:** Send to Research removes the figure's line (`ProjectStore.sendToResearch` → `.removeLine`), so the usual case is a `@tbl:name` with no line. An unresolved table reference whose name is a parked figure's raises the new `figureInResearch` problem *instead of* `unresolvedCrossRef`. A line that still resolves to a parked figure (synced from another device), and a legacy line into a Research folder (`FigureLineResolution.Status.outsideFigures`), raise the same kind and print the literal fallback.
- **`figureNotFound` for a `.csv` line becomes red in a Report**: publishing now checks the line against the registry, so the exemption at `PublishProblem.isError` (`!isTableFigurePath`) goes.
- **Column widths are not published in 9a**: columns size as pipe tables do (LaTeX `l/c/r`, DOCX equal widths, EPUB auto). Cost if wrong: one follow-up task.
- **Header styling follows pipe tables** (bold in DOCX only). The total row is ruled above in all three formats.

## Review Focus

1. A text cell holding `&`, `%`, `$`, `#`, `_`, `{`, `\`, `<`, or starting with `[` or `*` — it prints literally in all three formats (LaTeX `rowStart` `\relax` guard, XML escaping).
2. A Spanish body of an English book: `1234.5` prints `1.234,5` and a date cell shows a Spanish month in the `es` body while the source body shows `1,234.5`.
3. A publish with no project window (MCP `compile`, the design gate) still emits cells — the snapshot must not depend on a presenter (`figureCardInputs()` returns nil without one).
4. A table with no header row, a one-row table, and a table whose only row is its total row — each emits valid output (no empty `\endhead`, no empty `<thead>`, no `<w:tblHeader/>` on a body row).
5. A figure open in the grid with an unfolded edit when Publish is pressed publishes the edit (the snapshot overlays an open host's state, as the card does).

---

### Task 1: The figure snapshot reaches every publish

**Files:**
- Create: `Maugham/Publish/PublishFigures.swift`
- Modify: `Maugham/Publish/PublishContext.swift`, `Maugham/Publish/ProjectStoreASTSource.swift`, every `ProjectStoreASTSource(` site (MCP `PublicationTools`, `PublishConfigTools`, `CompileTools`; `BodyPlan`; `DesignGateView`; `DepartmentDesignRow`; `DeskCompileRunner`; `DesignerEnvironment+Project`), `Maugham/Stores/DocumentStore+Figures.swift`
- Test: `MaughamTests/Publish/PublishFiguresTests.swift`

**Interfaces:**
- Produces:
  - `struct PublishFigures: Sendable { records: [FigureRecord]; states: [String: FigureState]; workbook: Workbook?; pinStatus: [String: [String: PinStatus]]; sourceChanged: Set<String>; parked: Set<String>; static let none }` — keyed by figure id; `parked` lists parked figure ids; `pinStatus[figureId]` is `FigurePins.status(of:sources:)`.
  - `DocumentStore.publishFigures() async -> PublishFigures` — works with no presenter; overlays an open `FigureDocument`'s state the way `figureCardInputs()` does (DocumentStore+Figures.swift ~553-562); `.none` when the manifest has no figures. Unreadable figures are absent from `states`.
  - `PublishContext.figures: PublishFigures` (default `.none`; `PublishContext.empty` keeps `.none`).
  - `ProjectStoreASTSource.init(projectStore:figures:language:)` — `figures` is required (no default), so the compiler finds every site; `publishContext()` passes it through; `rebound(toLanguage:)` keeps it.

- [ ] **Step 1: Write the failing tests** in `PublishFiguresTests`:
  - `test_aClosedWindowStillSnapshotsTheFigures` — a store with no presenter and one table figure: `publishFigures().states[id]?.table` is non-nil and `workbook?.value(at:)` returns the formula's computed value.
  - `test_anOpenGridsUnfoldedEditIsWhatPublishes` — open the figure, write a cell through the host without folding; the snapshot's value is the new one.
  - `test_aParkedFigureIsListedParked` and `test_aMissingPinSourceIsSourceMissing` (`pinStatus[id]?[source] == .sourceMissing`).
  - `test_theSourceCarriesTheSnapshotThroughALanguageRebind` — `ProjectStoreASTSource(projectStore:figures:)`, `rebound(toLanguage: "es").publishContext().figures.records == figures.records`.
- [ ] **Step 2: Run** `./scripts/test.sh` (after `./gen.sh`) — FAIL: `PublishFigures` undefined.
- [ ] **Step 3: Implement.** Gather pin sources with the existing `pinSources(for:)`; snapshot-source change with the existing memoized `snapshotSourcesChanged`. Each construction site awaits `documentStore.publishFigures()` once before building its source (a site that is synchronous today becomes `async` or moves the await to its caller — the compiler lists them). Extend the `PublishContextTests` forwarding checks to `figures`.
- [ ] **Step 4: Run** `./scripts/test.sh` — PASS, and the existing publish suites stay green.
- [ ] **Step 5: Commit** `mac: report plan 9a Task 1 — one figure snapshot per publish, carried in PublishContext`.

### Task 2: `FigureTableLayout` — a table's printed cells (Core)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/Table/FigureTableLayout.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/Table/FigureTableLayoutTests.swift`

**Interfaces:**
- Produces: `public struct FigureTableLayout: Sendable, Equatable { header: [String]?; body: [[String]]; total: [String]?; alignments: [CellAlignment] /* resolved: never .automatic */; errorCells: [String] /* A1 names, reading order */ }` and `public static func make(table: FigureTable, value: (CellKey) -> CellValue, locale: TableLocale) -> FigureTableLayout`.
  - Every live row and column, in order (no 12-row cap — that is the card's).
  - `header` = the first row when `table.headerRows == 1`; `total` = the last live row when `hasTotalRow` and it is not the header; a table whose only row is the header has `body == []`.
  - Text via `CellDisplay.string(for:format:locale:)`; alignment resolved per column exactly as `FigureCardModel` resolves it (FigureCardModel.swift ~98-107 — extract that rule into one shared function both call, do not copy it).
  - A1 names use the live column/row position (`A1` = first live column, first live row).

- [ ] **Step 1: Write the failing tests:** `test_everyRowPrintsWithItsFormat` (40 rows, a `currency(symbol:"$",decimals:2)` column → `"$1,234.50"` under `TableLocale(languageTag: "en-US")`); `test_spanishSeparatorsAndMonths` (`es-ES`: `1234.5` with `number(decimals:1,grouping:true)` → `"1.234,5"`; a `date(.month)` cell → a Spanish month name); `test_headerAndTotalRows` (no header; header only; total only; header+body+total); `test_errorCellsAreNamedA1` (`=1/0` at B3 → `errorCells == ["B3"]`, text `"#DIV/0!"`); `test_alignmentMatchesTheCard` (same alignments `FigureCardModel.build` reports for the same table).
- [ ] **Step 2: Run** `./scripts/test.sh core` — FAIL.
- [ ] **Step 3: Implement** `make`, moving the alignment rule into one function `FigureCardModel` now calls.
- [ ] **Step 4: Run** `./scripts/test.sh core` and `./scripts/test.sh` — PASS (card tests unchanged).
- [ ] **Step 5: Commit** `core: report plan 9a Task 2 — FigureTableLayout, a table's printed cells`.

### Task 3: Resolution lays out each table-figure line

**Files:**
- Modify: `Maugham/Publish/PublishResolution.swift` (`Pass.collect` ~258-292, `judgeTableFigurePath` ~327-335), `Maugham/Publish/PublishProblem.swift` (`PublishProblemGate.resolve` ~246)
- Test: `MaughamTests/Publish/PublishResolutionTableFigureTests.swift`

**Interfaces:**
- Consumes: `PublishContext.figures` (Task 1), `FigureTableLayout.make` (Task 2), `FigureLineResolution.Index`/`.status(linePath:documentPath:index:)`.
- Produces:
  - `PublishResolution.tableFigures: [String: [Int: FigureTableLayout]]` — piece id → node index → layout, set only for a line resolving (`.figure(record)`) to an unparked table figure with a readable state.
  - `PublishResolution.forCompile(…, tableLocale: TableLocale = TableLocale(languageTag: nil))` and `resolve(…, tableLocale:)`; `PublishProblemGate.resolve` passes `TableLocale(languageTag: body.config.metadata.language)` (blank → nil).
  - The line's number, list-of-tables entry and label registration are unchanged whether or not a layout exists, so a reference always lands.

- [ ] **Step 1: Write the failing tests** (a `PublishContext` built with a hand-made `PublishFigures`; the AST from `SinglePieceSource`): `test_aTableFigureLineGetsItsLayout`; `test_twoBodiesFormatInTheirOwnLanguages` (resolve twice, `en-US` and `es-ES`, compare a cell); `test_anUnusedFigureIsNotPublished` (a figure with no line → no layout, no number); `test_aPipeTableIsUntouched` (pipe-table resolution identical to before: `tableNumbers`, `listOfTables`, no `tableFigures` entry); `test_aLineToAParkedFigureGetsNoLayoutButKeepsItsNumber`.
- [ ] **Step 2: Run** `./scripts/test.sh` — FAIL.
- [ ] **Step 3: Implement** in `collect`; `judgeTableFigurePath` keeps its lexical check and then resolves against the registry.
- [ ] **Step 4: Run** `./scripts/test.sh` — PASS.
- [ ] **Step 5: Commit** `mac: report plan 9a Task 3 — resolution lays out each table-figure line in the body's language`.

### Task 4: The problems and notes

**Files:**
- Modify: `Maugham/Publish/PublishProblem.swift` (`Kind`, `isError`, `sentence(for:)`), `Maugham/Publish/PublishResolution.swift`, `Maugham/Editor/ManuscriptChecks.swift` (only the exhaustive switches the compiler names)
- Test: `MaughamTests/Publish/PublishProblemTableFigureTests.swift`

**Interfaces:**
- Produces new `PublishProblem.Kind` cases (red in a Report unless marked amber; every other profile amber, as today):
  - `tableFigureErrorCell(name: String, cell: String)` — one per figure, naming the first error cell: "Table “cashflow” has an error in B3 (#DIV/0!)." — the sentence carries the error text.
  - `tableFigureSourceMissing(name: String)` — any pin `.sourceMissing`.
  - `figureInResearch(ManuscriptLabel)` — per the parked ruling above; replaces `unresolvedCrossRef` for a parked figure's label.
  - amber everywhere: `tableFigureReadsResearch(name:)` (any pin), `tableFigureResearchChanged(name:)` (any pin `.sourceChanged`, or `sourceChanged` contains the id), `tableFigureNPVNote(name:cell:)` (from `Workbook.notes` addresses in that figure).
  - `figureNotFound` for a `.csv` path: red in a Report (drop the exemption).
- Copy is the implementer's in the house voice of `sentence(for:)`, each naming the figure by name and saying what to do (e.g. "Refresh it in the Figures area.").

- [ ] **Step 1: Write the failing tests:** one per kind asserting it is raised once per figure (not per cell, not per body twice), its `isError` under `.report` and under `nil`, and that `PublishProblemGate.judge` refuses a Report with an error cell but passes a novel profile with a warning; `test_aReferenceToAParkedTableSaysItIsInResearch` (and does not also raise `unresolvedCrossRef`); `test_aLegacyResearchLineIsInResearch`; `test_aCsvLineWithNoFigureRefusesAReport`.
- [ ] **Step 2: Run** `./scripts/test.sh` — FAIL.
- [ ] **Step 3: Implement.** Raise through `Pass.report`/`reportOnce` only (emitters never raise).
- [ ] **Step 4: Run** `./scripts/test.sh` — PASS.
- [ ] **Step 5: Commit** `mac: report plan 9a Task 4 — table-figure problems and Research notes`.

### Task 5: PDF draws the table

**Files:**
- Modify: `Maugham/Publish/LaTeXBodyEmitter.swift` (`isTable` :94, `tableEnvironments` :168-177, `emitTableFigure` :563-580)
- Test: `MaughamTests/Publish/LaTeXTableFigureTests.swift`; extend `MaughamTests/Publish/ReportPDFCompileTests.swift` (real tectonic compile; `try await TectonicProbe.requireReady()`)

**Interfaces:**
- Consumes: `resolution.tableFigures` (Task 3).
- Produces: `emitTableFigure` draws `MaughamTable` like `emitTable` (anchor, `\setcounter{table}`, unlisted handling, `rowStart` guard, `LaTeXEscape.escape` per cell), with `\hline` above the total row; with no header it emits a form with no repeated head (the implementer chooses the macro shape; it must stay inside the `\ifdefined` degradation guards). No layout → today's literal float, anchor kept.
- `isTable` also matches a table-figure line, so a book whose only tables are figures defines `MaughamTable`.

- [ ] **Step 1: Write the failing tests:** emitted text contains each formatted cell, `\endhead` with a header, `\hline` immediately before the total row, no `\endhead` without a header, escaped specials (Review Focus 1), and `\begin{MaughamTable}` in a figures-only book; `NovelBodyGoldenTests` still byte-identical. In `ReportPDFCompileTests`: a 60-row table figure with a header and total compiles and the PDF text has the header on page 2.
- [ ] **Step 2: Run** `./scripts/test.sh` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `./scripts/test.sh` — PASS.
- [ ] **Step 5: Commit** `mac: report plan 9a Task 5 — the PDF draws a table figure's cells`.

### Task 6: EPUB draws the table

**Files:**
- Modify: `Maugham/Publish/XHTMLBodyEmitter.swift` (table-figure branch :365-377), `Maugham/Resources/PublishStarter/styles.css` (a `tr.total` rule)
- Test: `MaughamTests/Publish/XHTMLTableFigureTests.swift`

**Interfaces:**
- Consumes: `resolution.tableFigures`.
- Produces: the same `<table>`/`<caption>`/`<thead>`/`<tbody>` shape `emitTable` writes, the caption id from `scope.address(.tbl, …)`, the total row as `<tr class="total">`, `text-align` per resolved alignment. No `<thead>` without a header. No layout → today's literal paragraph with its id.
- A new starter CSS rule reaches only new projects; an old project's stylesheet without it still shows the table (the rule is decoration).

- [ ] **Step 1: Write the failing tests:** cells present and XML-escaped, `<thead>` iff header, `class="total"` on the last row iff total, the caption carries the address id so `@tbl:x` links land.
- [ ] **Step 2: Run** `./scripts/test.sh` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `./scripts/test.sh` — PASS.
- [ ] **Step 5: Commit** `mac: report plan 9a Task 6 — EPUB draws a table figure's cells`.

### Task 7: Word draws the table

**Files:**
- Modify: `Maugham/Publish/DOCXBodyEmitter.swift` (table-figure branch ~365-375; reuse `table(header:alignments:rows:scope:)` ~412-430)
- Test: `MaughamTests/Publish/DOCXTableFigureTests.swift`; update `DOCXBodyEmitterTests.swift:401-408` (pins today's literal paragraph)

**Interfaces:**
- Consumes: `resolution.tableFigures`.
- Produces: caption paragraph as today, then a native `<w:tbl>` with `<w:tblHeader/>` on the header row only, header bold, `w:jc` per alignment, and a top border (`w:tcBorders/w:top`, `w:sz="8"`) on each total-row cell. No layout → today's literal paragraph after the caption.

- [ ] **Step 1: Write the failing tests:** cell text present and escaped, `tblHeader` count == 1 with a header and 0 without, the total row's cells carry the top border, the caption bookmark is unchanged.
- [ ] **Step 2: Run** `./scripts/test.sh` — FAIL.
- [ ] **Step 3: Implement**, generalising `table(...)` to take string cells and an optional total row rather than writing a second table writer.
- [ ] **Step 4: Run** `./scripts/test.sh` — PASS.
- [ ] **Step 5: Commit** `mac: report plan 9a Task 7 — Word draws a table figure's cells`.

### Task 8: Contract, guide and area docs

**Files:**
- Modify: `Maugham/Publish/EmissionContract.swift` (`reportExamples`, `reportContext`, `reportContract` ~249-254), `Maugham/Resources/PublishStarter/EMISSION.md` (regenerated), `MaughamTests/ReportProjectCreationTests.swift:241` (golden SHA + comment), `Maugham/Publish/AREA.md:91`, `docs/guide/publishing.md`, the guide page describing figures (find it from `docs/INDEX.md`)

- [ ] **Step 1:** Add a table-figure `ReportExample` (a three-row figure with a header and total, supplied through `reportContext.figures`); rewrite the "cells are not emitted yet" prose to say what ships: computed values, formats in the body's language, repeated header, ruled total, unused figures absent, pipe tables unchanged, and the degradation without longtable.
- [ ] **Step 2:** Regenerate `EMISSION.md` (delete it, run `EmissionContractTests`, which writes it and fails once; rerun → PASS); update the golden SHA.
- [ ] **Step 3:** Guide: what a published table shows, the new problems (which refuse a Report, which only warn) and what to do about each. AREA: the snapshot (`PublishFigures`) and `tableFigures`. Re-measure any DocBudget ceiling the edit moves (numbers only).
- [ ] **Step 4: Run** `./scripts/test.sh full` — PASS, then a Release build (`xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO`).
- [ ] **Step 5: Commit** `docs: report plan 9a Task 8 — emission contract, guide and area docs for published tables`.
