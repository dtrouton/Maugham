# Report plan 9b — figures on the phone, and the AI reads them — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone's Read tab shows each figure line as a read-only card computed by the shared Core engine (or the picture, for an image figure), and Claude gets two read-only MCP tools: `list_figures` and `read_figure`.

**Architecture:** The engine is already in Core (`FigureCache`, `FigureWorkbook.assemble`, `FigureCardModel.build`, `FigureLineResolution`, `FigureTableLayout`). This plan moves the last three pieces both surfaces need into Core: building every card from one fill's inputs (today a private loop in the Mac's `FigureCardCache.apply`), the card's words (today in AppKit `FigureCardDrawing`), and reading the book's language (today only via the Mac's `PublishConfigStore`). The phone then loads figures through Core and draws cards in SwiftUI. MCP reads the book headlessly through `ProjectStore.publishFigures()` (plan 9a; it works with no window) and a headless `ReferenceIndex` for number, caption, used-in and unused.

**Tech Stack:** Swift 6, MaughamCore `Table/`, MaughamPhone (SwiftUI, iCloud downloads), Maugham `MCP/`.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §10.1 (the `list_figures` and `read_figure` bullets; "Figures are read-only to the AI"), §10.2, §10.3. Survey of the built code: `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan9b-survey.md` (file:line for every type named here).

## Global Constraints

- "The phone renders figure cards read-only, computed through the shared Core engine. Image figures display. There is no editing." (§10.2)
- "Figures are read-only to the AI." `list_figures`: "name, kind, number, caption, used-in, pins, 'changed', 'unused'." `read_figure`: "for a table: cells as A1 with value, formula and format, plus a rendered text table; for an image: a crop on demand under the 1 MB response cap (tripwire 10)." (§10.1)
- Anything both Mac and phone do goes through one Core implementation (tripwire 19). A second copy of the card loop, the card words or the language read is a defect.
- `figures/<name>.csv` is written, never read (tripwire 20). Values come from op logs through `FigureCache`/`Workbook`. On the phone, every op-log file `FigureCache` will read is `ensureDownloaded` first, because `FigureCache` reads uncoordinated and an evicted file reads empty (tripwire 18).
- Every path from synced data to the disk goes through `SafeRelativePath` (tripwire 58): a record's `path`, an image `filename`.
- The phone never spells `loadSyncMerged(`/`loadDiagnosed(` outside `AnnotationLoading.swift` (`test_everyAnnotationReadOnThePhoneIsJudged`); call Core's `FigureCache`/`FigureWorkbook`.
- MCP text responses go through `MCPResponseBudget.enforce(_:hint:)`; images through `ImageResponseBuilder` only (tripwire 10). Tool counts in docs derive from `MCPToolCatalog.all` (`DocSyncTests`).
- Help describes only what ships (rule 7).

## Rulings made while writing this plan

- **The phone card has no number.** "Table 3." comes from `ReferenceIndex`/`FigureListing`, which sit on Mac-only publish code (`ElementWords`, `publishablePieces`); moving them is a plan of its own. The phone card shows the caption and the table. Cost if wrong: one later task moving numbering to Core.
- **The phone shows no "Research has changed" banner.** That needs Research CSV reads and hashing, which exist only on the Mac. Pinned values still compute, because pins are stored in the op log. The phone passes `pinChanged: false, sourceChanged: false`. Cost if wrong: one later task moving the source read to Core.
- **The phone formats like the Mac's source body.** `TableLocale(languageTag: <book language>)` borrows the device's region exactly as the Mac card borrows the Mac's.
- **`list_figures` lists parked figures** with `"status": "in_research"`, because Claude reasoning about a `@tbl:` reference needs to know a figure went to Research. The Mac tree hides them; the tool is not the tree.
- **`read_figure` returns display strings and raw values.** Each cell carries `value` (the formatted display string, book locale), `raw` (the typed `CellValue`), `formula` (rendered by current names, or absent) and `format` (the Codable `CellFormat`). A `range` parameter (A1 range) limits a large table; past the budget, `enforce` truncates with a hint naming `range`.
- **Figure anchors on annotations (`tbl:x!C3`) are plan 9c**, which owns the cell-anchor model.

## Review Focus

1. A phone opening a book whose figure op logs are evicted (not yet downloaded): cards appear once the downloads land; nothing shows an empty table as if it were real. Pin: a loader test with an evicting fake `downloads` asserting `ensureDownloaded` precedes every read.
2. A Spanish book (`metadata.language` = `es`) on a US-region phone: the card shows `1.234,5`, matching the Mac.
3. A figure line whose path names no figure, two figures, or a figure in Research shows "Figure removed" / "Two figures share this path" / "In Research", in the same words as the Mac (one Core source).
4. `read_figure` on a 2,000-row table returns under 1 MB with a hint naming `range`, and `range: "A1:C10"` returns exactly those cells.
5. A heading `# Results {#sec:results}` and a figure line `![Cash](figures/cash.csv){#tbl:cash}` on the phone: no `{#…}` text shows, and the figure line is a card, not a paragraph (audit E1/F17).

---

### Task 1: The book's language and the card's words, in Core

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/Table/BookLanguage.swift`, `Packages/MaughamCore/Sources/MaughamCore/Table/FigureCardText.swift`
- Modify: `Maugham/Stores/ProjectStore+FigureResearch.swift` (`bookLanguageTag()`), `Maugham/Editor/FigureCardDrawing.swift` (labels at :17-31), Core `AREA.md` (map)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/BookLanguageTests.swift`, `.../FigureCardTextTests.swift`

**Interfaces:**
- Produces:
  - `public enum BookLanguage { public static func configURL(in projectURL: URL) -> URL; public static func tag(fromConfigData: Data) -> String? }`. It decodes only `metadata.language` from `.maugham/publish/config.json`, tolerating every other key, and normalises through `TableLocale.languageTag(fromStored:)`. The path must be the one `PublishConfigStore.fileURL(in:)` uses: make `PublishConfigStore` call `BookLanguage.configURL` so the path is spelled once. The reading of bytes stays with each caller (Mac: plain read as today; phone: coordinated read after `ensureDownloaded`).
  - `public enum FigureCardText { removed, ambiguous, parked, empty, pinChanged: String; static func more(_ n: Int) -> String }` holding exactly today's Mac strings. `FigureCardDrawing` reads them; no string literal stays there.
- [ ] Step 1: failing tests: a config JSON with `"metadata": {"language": "es"}` plus unknown keys → `"es"`; missing metadata / blank language → nil; `" en-GB "` normalises as `languageTag(fromStored:)` does. `FigureCardText.more(3) == "+ 3 more rows"`, and each label equals the string the Mac drew before (copy the literals into the test).
- [ ] Step 2: implement; switch `bookLanguageTag()` and `FigureCardDrawing` over. Run `./scripts/test.sh core` and `./scripts/test.sh`.
- [ ] Step 3: commit.

### Task 2: One card loop for both surfaces (Core)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/Table/FigureCardBook.swift`
- Modify: `Maugham/Views/FigureCardCache.swift` (`apply(_:)`)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/FigureCardBookTests.swift`

**Interfaces:**
- Produces: `public struct FigureCardBook: Equatable, Sendable { public let models: [String: FigureCardModel]; public let researchReaders: Set<String>; public let parkedLabels: Set<ManuscriptLabel>; public static func build(records: [FigureRecord], states: [String: FigureState], workbook: Workbook?, locale: TableLocale, pinChanged: Set<String>, sourceChanged: Set<String>) -> FigureCardBook }` — exactly the loop at `FigureCardCache.apply` (first record per id wins; a record with no state gets no card; readers = unparked table figures whose formulas read Research or a parked figure, via `FigurePins.reads`; parkedLabels = parked records' `referenceLabel`). Plus `public func model(forLinePath:documentPath:index: FigureLineResolution.Index) -> FigureCardModel?` holding the line rule now in `FigureCardCache.model(forLinePath:documentPath:)` (figure → its model, nil when it has none, as today; ambiguous → `.placeholder(.ambiguous)`; none inside `figures/` → `.removed`; else `.image`). `FigureCardCache` keeps its own memory (departed, version, generation) and calls both.
- [ ] Step 1: failing tests: a book with one table, one image, one parked and one Research-reading figure → models of kinds `.table/.image/.parked`, readers = the reader's id, parkedLabels = `tbl:<parked>`; line lookups for a figure, a missing path in `figures/`, an ambiguous path and a Research picture give `.table`, `.removed`, `.ambiguous`, `.image`.
- [ ] Step 2: implement; `FigureCardCache` delegates. Existing `FigureCardCacheTests` stay green unchanged (they are the disable experiment for the Mac side).
- [ ] Step 3: `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 3: The phone reader recognises figure lines and labels (audit E1, F17)

**Files:**
- Modify: `MaughamPhone/Read/MarkdownBlocks.swift`, `MaughamPhone/Read/DocumentReaderView.swift`
- Test: `MaughamPhoneTests/MarkdownBlocksTests.swift`

**Interfaces:**
- Produces: a `MarkdownBlocks.Block.figure(caption: String, path: String, label: ManuscriptLabel?)` case and label-free headings and table captions, derived from Core's `ManuscriptBlocks.parse` (`Core/ManuscriptBlocks.swift:30`), the recogniser Publish and the Mac use — not a phone regex. Until Task 5 the view draws `.figure` as its caption in secondary style.
- [ ] Step 1: failing tests (F17): `![Cash](figures/cash.csv){#tbl:cash}` → `.figure(caption: "Cash", path: "figures/cash.csv", label: tbl:cash)`; `# Results {#sec:results}` → heading text `"Results"`; a pipe table with a `Table: Totals {#tbl:totals}` caption keeps its rows and drops the label; a plain table still parses as before.
- [ ] Step 2: implement; reconcile ADR 0033 §5's phone sentence with what now ships.
- [ ] Step 3: `./scripts/test.sh phone`; commit.

### Task 4: The phone loads a book's figures

**Files:**
- Create: `MaughamPhone/Read/PhoneFigureBook.swift`
- Modify: `MaughamPhone/Read/DocumentReaderView.swift` and its construction sites (`MaughamPhone/Binder/BinderView.swift:158,194`) to pass the project URL, manifest and the document's project-relative path
- Test: `MaughamPhoneTests/PhoneFigureBookTests.swift`

**Interfaces:**
- Consumes: Task 1 `BookLanguage`, Task 2 `FigureCardBook`; Core `FigureCache`, `FigureWorkbook.assemble(for:cache:projectURL:trust:)`, `TrustResolution.resolve(projectURL:identities:presenter:cache:)`, `OpLogStore.opLogFileURLs(forDocId:in:)`, `DocumentClass.Facts`.
- Produces: `@MainActor final class PhoneFigureBook { func load(manifest: ProjectManifest, projectURL: URL) async -> FigureCardBook?; func card(forLinePath: String, documentPath: String) -> FigureCardModel?; func imageURL(forLinePath: String, documentPath: String) -> URL? }`. `load`: nothing when the manifest has no figures; `ensureDownloaded` the publish config and every `fig-` stream file (pattern `AnnotationsStore.swift:76-100`); resolve trust once and pass that table to every read; assemble; build with `pinChanged: [], sourceChanged: []`. A figure whose stream will not read is left out, never shown empty. `imageURL` resolves through `SafeRelativePath.resolve`.
- [ ] Step 1: failing tests over a fixture project (built with Core writers, no Mac): a table figure with `=SUM(B2:B3)` → card's body shows the sum; a Spanish book shows `1.234,5` with the region forced to US; an evicting fake download double sees `ensureDownloaded` before each read; trust resolves once per load (count it).
- [ ] Step 2: implement. Phone AREA: one sentence that calling the resolver is not a trust decision.
- [ ] Step 3: `./scripts/test.sh phone`; commit.

### Task 5: The phone draws figure cards

**Files:**
- Create: `MaughamPhone/Read/FigureCardView.swift`
- Modify: `MaughamPhone/Read/DocumentReaderView.swift`
- Test: `MaughamPhoneTests/FigureCardViewTests.swift`

**Interfaces:**
- Consumes: Task 4 `PhoneFigureBook`, Task 1 `FigureCardText`, Core `FigureCardModel`.
- Produces: a SwiftUI card for `.figure` blocks: the caption; the header row (bold); body rows with each column's alignment; the total row ruled above; "+ N more rows"; placeholders in `FigureCardText`'s words; an image figure loads through `PhoneImageLoader.load(_:downloads:io:)` with its placeholder on failure. Cards are computed once per load in `.task` and looked up per block (tripwire 4); wide tables scroll horizontally inside the card, never the page. No tap does anything that edits.
- [ ] Step 1: failing tests on the view's pure plan (rows/alignments/labels the view will draw, from a `FigureCardModel`), not on pixels: a 15-row table plans 12 rows + "+ 3 more rows" + the total row; `.parked` plans `FigureCardText.parked`.
- [ ] Step 2: implement; Dynamic Type and dark mode use system styles.
- [ ] Step 3: `./scripts/test.sh phone`; commit.

### Task 6: A headless figure listing for MCP

**Files:**
- Create: `Maugham/MCP/FigureListingSource.swift`
- Modify: `Maugham/Views/ReferenceIndexHost.swift` only if it must expose its built index
- Test: `MaughamTests/MCP/FigureListingSourceTests.swift`

**Interfaces:**
- Produces: `@MainActor enum FigureListingSource { static func rows(store: ProjectStore) async -> [FigureListing.Row] }`. It builds the index through `ReferenceIndexHost` attached to `ReferenceIndexHost.Project.window(store:documentStore:)` and awaits `idle()`, so the text sources (open `Document`, else the derived cache, tripwire 20) and the element words are spelled once, then runs `FigureListing.build`. No window is required; with no `documentStore` it returns `[]` and logs.
- [ ] Step 1: failing tests: a closed project (no window) with two pieces, one figure used twice and one unused → rows with `number == "Table 1"`, the first use's caption, two `usedIn` entries, and the unused row `isUnused` with number `"—"`; text typed into an open, unsaved `Document` changes the caption.
- [ ] Step 2: implement; commit.

### Task 7: `list_figures`

**Files:**
- Create: `Maugham/MCP/Tools/FigureTools.swift`
- Modify: `Maugham/MCP/MCPTool.swift` (catalogue), `MaughamTests/MCP/MCPProtocolHandlersTests.swift` (expected list)
- Test: `MaughamTests/MCP/Tools/ListFiguresToolTests.swift`

**Interfaces:**
- Consumes: Task 6 rows; `ProjectStore.publishFigures()` (`Maugham/Publish/PublishFigures.swift`) for `pinStatus`, `sourceChanged`, `parked`, states.
- Produces: `list_figures { project, kind?: "table"|"image" }` → `{ figures: [{ id, name, kind, number, caption, status: "used"|"unused"|"in_research", used_in: [{ document, line }], reads_research: Bool, pins: [{ source, status: "current"|"source_changed"|"source_missing"|"unpinned" }], changed: Bool }] }`. `changed` = any `.sourceChanged` pin or `sourceChanged` contains it (the card's rule, `FigureCardModel.changed`). `document` is the piece's title-path as other tools name documents. Through `enforce` with a hint naming `kind`.
- [ ] Step 1: failing tests: a book with a used table, an unused image and a parked table → three entries with the right statuses; a pinned figure whose Research CSV changed reports `changed: true` and its pin `source_changed`; the tool makes no write (the op-log directory is byte-identical after the call).
- [ ] Step 2: implement and register; `MCPCatalogConsistencyTests` green; commit.

### Task 8: `read_figure`

**Files:**
- Modify: `Maugham/MCP/Tools/FigureTools.swift`, `Maugham/MCP/MCPTool.swift`, `MaughamTests/MCP/MCPProtocolHandlersTests.swift`
- Test: `MaughamTests/MCP/Tools/ReadFigureToolTests.swift`

**Interfaces:**
- Consumes: `publishFigures()`; Core `FigureGridAddress.string(for:in:)`, `FormulaParser.render(_:in:names:)` with `FormulaNames(records:tables:research:)`, `CellDisplay.string(for:format:locale:)`, `FigureTableLayout.make` + `TableText.formatted()` for the text table; `ImageResponseBuilder.encodeEnvelope(at:region:maxDimension:quality:)` with the schema fragment from `DocumentTools.swift:44`.
- Produces: `read_figure { project, name, range?, region?, max_dimension?, quality? }`. `name` matches a record's `name` (or its `tbl:`/`fig:` label). For a table: `{ name, kind, rows, columns, cells: [{ a1, value, raw, formula?, format }], text }`, where `text` is the rendered pipe table of the cells returned. The locale is `TableLocale(languageTag: bookLanguageTag())`. For an image: the image envelope at `figures/<filename>` via `SafeRelativePath.resolve`, the crop pattern of `ReadDocumentTool.emitImageResearchItem` (`DocumentTools.swift:189-220`). A parked figure reads its parked state (the AI may look at what went to Research). An unknown name returns an error that lists the nearest names.
- [ ] Step 1: failing tests: `=SUM(B2:B3)` cell → `formula == "=SUM(B2:B3)"`, `value` formatted, `raw` the number; `range: "A1:B2"` → exactly 4 cells; a 2,000-row table without `range` stays under the budget and its hint names `range`; an image figure returns an image envelope under 1 MB and `region` crops; reading touches no `figures/*.csv` (the test deletes the render first and still gets values).
- [ ] Step 2: implement and register; commit.

### Task 9: Docs, help, and the gates

**Files:**
- Modify: `Maugham/MCP/AREA.md` (catalogue heading and group, tool contracts), `MaughamPhone/AREA.md` (map, Reading rules), Core `AREA.md` (map), `docs/guide/claude-desktop.md` ("What Claude can do"), the phone guide page that describes reading (find it; if none describes the Read tab, add the sentence where the phone is described), `docs/skills/maugham-bootstrap/SKILL.md` (name the two tools where Claude should reach for them), `docs/superpowers/notes/cross-surface-contracts.md` (rows for manuscript read source and block segmentation), DocBudget ceilings (numbers only, re-measured)
- [ ] Step 1: docs describe only what ships: no phone numbering, no phone "changed" banner, no editing, no AI figure writes or anchors.
- [ ] Step 2: `./scripts/test.sh core`, `./scripts/test.sh full`, `./scripts/test.sh phone`; Release build (`xcodebuild … -configuration Release build CODE_SIGNING_ALLOWED=NO`).
- [ ] Step 3: commit.
