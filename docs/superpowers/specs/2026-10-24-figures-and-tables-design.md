# Figures and tables — design

Status: agreed in conversation with Denver, 2026-10-24. Part of the Report foundations milestone (M1), before its release. It supersedes spec `2026-10-19-report-foundations-design.md` §4.2 (tables as tidy text plus a grid sheet) and decision D5 (linked research spreadsheets in milestone 3) where they conflict. Pipe tables typed by hand keep working as that spec describes.

## 1. Purpose

Editing tables as Markdown pipe text "sucks" (Denver). The grid sheet works but feels like Word, not a spreadsheet, and the result is still text the writer can break. A table should be an object in the document that feels like Sheets or Excel, with nothing in the text to break.

At the same time, figures and tables are part of the document, not scratch material. Today a figure's image is filed under Research, which mixes the workbench with what the reader sees.

**Success:** a writer builds a business case in a Report. They have a cash-flow table with an `NPV` and `IRR` summary that reads from it, a chart image, and a model they are still experimenting with in Research. They edit the tables in place with spreadsheet keys and paste from Excel. They pin one table's inputs from the Research model, see "Research has changed" when the model moves, and refresh deliberately. They send an unused table back to Research and bring it back later with its references intact. The PDF and Word file show correctly numbered, formatted tables. A Spanish edition shows translated row labels and `1.234,5`. Two Macs editing the same table merge cell by cell.

## 2. Decisions (Denver, 2026-10-24)

| # | Decision |
|---|---|
| F1 | A table is an object, like a figure. Its data lives in its own file; the text holds one line that points at it. |
| F2 | A new **Figures** area, separate from Research. Research is the workbench and is never published. Figures holds what is in the document. |
| F3 | Moving Research → Figures ("Use in document") takes a **snapshot**, with a visible "Research has changed — refresh?" note. Never a live link. |
| F4 | Figures → Research ("Send to Research") is supported. The line leaves the text, and references to it show a warning. Using it again restores the same name, so references reconnect. |
| F5 | Formulas: a set kept explicit and small (§5). Excel-compatible, including its quirks. |
| F6 | Formulas may reference other tables in the document (live), and cells in Research (pinned, with a visible warning). |
| F7 | The table editor **expands in place** in the text column, with a ⤢ pop-out to a window. |
| F8 | Sheets-style keyboard (§6.3). A slim toolbar plus right-click and Format ▸ Table menus. |
| F9 | Dates in cells, with display formats and a financial-year start. Date formulas: date subtraction, `YEAR`, `MONTH`, `EDATE`, `XNPV`, `XIRR`. No `TODAY()`. |
| F10 | MCP: figures are read-only to the AI, which can annotate and suggest. Research is writable by the AI. |
| F11 | Figures go through the op log, like manuscript text: signed, attributed, merged per cell, permit-checked. |
| F12 | The Figures area is a tree section between the manuscript and Research, as mocked up (§7). |

Calls I made inside those rulings, which Denver did not overrule:

- Captions stay in the text line.
- Text cells are translated per language.
- Cell formatting is about meaning only (header, total, number format, alignment); fonts, colours and borders come from the house style.

## 3. The model

### 3.1 A figure

A figure is one concept with kinds: **table** and **image** in this milestone. Chart and diagram come later and reuse the table's data. Every figure has:

- a **name**, unique per project, which is the label (`cashflow` → `tbl:cashflow`, `sites` → `fig:sites`);
- a **kind**;
- its **content**: cells for a table, an image file for an image;
- optional **research pins** (§4.3).

The number ("Table 2") is never stored. It comes from the order of first use in the text, as numbering already works (report spec §5.2).

### 3.2 In the text

A figure appears in the text as the existing figure line, extended to tables:

```
![Programme cash flows](figures/cashflow.csv){#tbl:cashflow}
![Savings by site](figures/sites.png){#fig:sites}
```

- The path is project-relative under `figures/` (written relative to the document, as `FigureIngest.relativePath` already does).
- The caption is the line's text, so translation, history and the op log cover it unchanged.
- A table's label takes `tbl:` and an image's takes `fig:`. That prefix decides which list it numbers in.

**What the writer sees.** The line is drawn as a caption bar: "Table 2. Programme cash flows". The `![`, `](…)` and `{#…}` syntax is faded until the caret enters the line, as Denver chose for citation chips ("styled raw + label"). The card is drawn beneath.

### 3.3 A table's content

- **Rows and columns have stable ids,** minted from the `¶id` alphabet but 8 characters long, because devices mint them concurrently without a shared view (plan 5 ruling). A cell is (row id, column id). Two devices inserting rows concurrently merge without clobbering each other.
- **Formulas store references by id** — rows, columns, other figures and Research items alike (Denver, 2026-10-24: a rename is then one registry change) — and display them as A1 and current names (`B3`, `$B$2`, `B2:B9`, `revenue!B9`, `research:model-v3!B9`). Inserting or deleting a row then adjusts every formula for free, as Excel does. A deleted referenced cell shows `#REF!`.
- **Each cell holds:**
  - a value (number, text, date, empty) or a formula;
  - a number or date format;
  - an alignment.
- **Each table holds:** a header-row count (0 or 1), a total-row flag (the last row), and column widths for the editor.

### 3.4 On disk

- **`figures/<name>.csv` is a clean render of computed values,** with no formulas and no formats. Any app opens it and sees what the reader sees, the way the `.md` is a clean render of the manuscript (ADR 0019). Edits made to it outside Maugham are discarded. "Import from CSV…" on a table replaces its contents deliberately.
- **`figures/<name>.<ext>` for an image** is the file itself. The op log records its content hash and filename, so a replaced image is a recorded, attributed change.
- **Formulas, formats, ids and pins live only in the figure's op log** under `.maugham/ops/`, as for a manuscript document.

### 3.5 The op log

Each figure is its own op-log document: a per-device JSONL stream, chained and sealed by actor exactly like a manuscript (ADR 0012, ADR 0032). Op kinds:

- **cell:** set value or formula; set format; set alignment;
- **structure:** insert, delete or move a row or column (by id);
- **table settings:** header row, total row, column width;
- **image:** set file (hash, filename);
- **pins:** set or refresh a research pin; clear one;
- **figure:** create, rename (relabels the text lines through the editor as one undo group), send to Research, use in document.

Concurrent edits to the same cell resolve last-writer-wins by the existing op-log ordering. Different cells never conflict.

Figures join **schema 10**. It is on origin but unreleased, so there is no migration and no extra paired release (rule 11).

**Permits.** The permit and posture layers classify a figure document as manuscript content (tripwire 44: one classifier, named callers). Someone whose permit allows only suggestions can suggest a cell change but not make one. Load emissions follow the same rules as `Document.load`. Plan 6 decides whether figures load through `Document.load` itself or a sibling with the same bootstrap guarantees. It must keep tripwires 20 and 38 enforced for figure files, extending their censuses rather than exempting figures.

**Undo.** Inside the in-place editor, ⌘Z undoes cell by cell. Folding the editor away closes the visit, after which one ⌘Z in the text undoes the whole visit as a single step. This uses compensating ops across documents (ADR 0023).

## 4. Moving between Research and Figures

### 4.1 Use in document

- **From a Research item** (CSV, image or PDF): a context-menu verb, or a drag onto the Figures section.
- **What it does:**
  - copies the item into `figures/` under a name derived from its title and de-duplicated, as an op-logged figure create;
  - records where it came from (source path and content hash at snapshot time).
- **Placement:** it then asks where in the text to put the line, at the caret or "leave unused". An unused figure is listed, numbered "—", and not published.
- **Research CSVs:** cells beginning `=` are parsed as formulas (§5). A CSV holds no computed value to fall back on, so an unsupported function stays a formula and shows `#NAME?`, as in Excel, and a formula that cannot be parsed becomes text holding its `=…` and is reported (plan 5 ruling). Images and PDFs follow the existing `FigureIngest` path (HEIC → PNG; PDF and SVG rasterised at publish).

### 4.2 Send to Research: the op log is parked, not converted (Denver, 2026-10-24)

- **The verb:** on a figure, in the tree, inspector or card menu, or by dragging onto Research.
- **The figure's op log is parked.**
  - It stays under `.maugham/ops/`, marked "parked in Research" by a `figure: send to Research` op, which records the working copy's research path and content hash.
  - Nothing is appended to it while parked, and nothing is deleted (per-device streams are append-only, tripwire 17).
- **Research gets a working copy,** written through the typed mover (tripwire 14):
  - a table becomes a CSV with formulas as `=` cells, plus a research-side sidecar under `.maugham/` holding its formats, header/total rows, name and caption, so the Research grid shows it formatted;
  - an image becomes the image file.
- **From then on the copy follows Research rules:** plain file, last writer wins, unsigned. The AI may write to it, with versions kept (§10.1).
- **Its line leaves the text** as an ordinary, undoable edit.
- **Figures that referenced it** keep their last values (the parked state) instead of breaking. When the working copy changes they say "Research has changed — refresh?", and Refresh writes pins into the reading figure only, by someone who may edit it (§4.3). Nobody writes another person's figure at send time (Denver, 2026-10-24).
- **Text that referenced it** ("see Table 3") gets the amber underline "This table is in Research now". A Report refuses to publish with it, as with any broken cross-reference.

**Coming back** ("Use in document" on that working copy):

- **Recognising the copy.** The working copy is matched to its parked log by the sidecar's figure id, which follows the typed mover's renames and moves. A different Research file never attaches to a parked log.
- **Unchanged in Research** (hash equals the parked hash): the log resumes with a `figure: use in document` op. History, formats, row/column ids, notes and suggestions return exactly as they were.
- **Changed in Research:** the difference between the copy and the parked log's last state is appended to the same log as ordinary ops.
  - Rows and columns are matched by content, using a longest-common-subsequence over row values (and column headers), so moved or surrounded rows keep their ids and their anchors.
  - Formats come from the sidecar.
  - Cells whose row or column has no match are deleted, and anchors on them are orphaned (§11.5).
- **Who signs the changes.** The appended ops are signed by the actor bringing the figure back, and carry the reason "brought back from Research". Bringing it back is the author's acceptance of what happened on the workbench, including AI-written values. Research's version history still records who wrote each version.
- **References reconnect.** The figure returns under its old name, so both kinds of reference reconnect. Pins that other figures took on it in §4.2 become live references again.
- **Deleted copy.** If the working copy is deleted, the log stays parked indefinitely. It appears nowhere in the interface and costs only its disk space.
- **Images** compare by hash only. A changed image comes back as one `image: set file` op.

### 4.3 Research pins

- **What a pin is:** a formula may reference a Research table, `research:model-v3!B9`. The reference stores the value it read, the source's content hash and the time.
- **When the source changes:** the figure shows "Research has changed — refresh?" with Compare (old and new values side by side) and Refresh (re-reads every pin in that figure as one op).
- **Visible warnings:**
  - a marker on pinned cells in the editor;
  - a tinted corner on the card;
  - "reads from Research" in the tree and inspector;
  - an amber publish note "Table 4 uses numbers from Research", with a second line when the source changed since the last refresh.
- **Source missing** (deleted or renamed): the pinned value is kept, with a red note, and a Report refuses to publish.
- **Snapshots from Research** (§4.1) show the same "changed" note when their source item changes.

### 4.4 Figures already in Research

Figure lines written by plans 3a and 3b point into `research/` (`../research/x.png`). They keep working, and they appear in the Figures area tagged "in Research", with a "Move into Figures" action. Nothing moves automatically.

## 5. Formulas

The engine lives in MaughamCore (tripwire 19). The Mac editor, the publisher, the phone renderer and MCP all compute through it. Results match Excel exactly; the test suite checks each function against values computed in Excel.

**Syntax:**
- numbers, text in `"…"`, dates (§5.2);
- `+ - * / ^`, unary minus, `%` as a suffix (`12%` = 0.12);
- comparisons `= <> < > <= >=` (inside `IF` and the `…IF` criteria);
- references: `B3`, `$B$2`, `B$2`, `B2:B9`, `revenue!B9` (another table in the document, live), `research:model-v3!B9` (pinned, §4.3).

**Functions (the complete set):**

| Group | Functions |
|---|---|
| Totals | `SUM`, `AVERAGE`, `MIN`, `MAX`, `COUNT`, `MEDIAN` |
| Rounding | `ROUND`, `ROUNDUP`, `ROUNDDOWN`, `ABS` |
| Logic | `IF`, `IFERROR` |
| Conditional totals | `SUMIF`, `COUNTIF`, `AVERAGEIF` (Excel criteria strings: `">100"`, `"North"`) |
| Growth | `CAGR(start, end, years)` = `(end/start)^(1/years) − 1` (Maugham's own; Excel has none) |
| Cash flows | `NPV`, `IRR`, `MIRR`, `XNPV`, `XIRR` |
| Annuities | `PV`, `FV`, `PMT`, `RATE`, `NPER`, with Excel's optional `type` and `guess` |
| Dates | date − date (days), `YEAR`, `MONTH`, `EDATE` |

**Behaviour:**
- **Excel's quirks are kept.** `NPV` discounts its first value one period, and money going out is negative. An `NPV` whose range starts with a negative value gets an amber note: "first flow is discounted — did you mean to add it outside?". The help explains both quirks.
- **`IRR`, `RATE`, `XIRR`** solve iteratively, to Excel's tolerance and iteration limit. They show `#NUM!` when there's no answer.
- **Errors:** `#DIV/0!`, `#REF!`, `#NAME?` (an unknown function), `#VALUE!`, `#NUM!`, `#CIRC!` (a reference cycle, across tables too).
- **Nothing volatile:** no `TODAY`, `NOW` or `RAND`. A publish must give the same numbers every time.
- **Recalculation:** a dependency graph across the document's tables recalculates only what changed.
- **Not included:** text functions, lookups (`VLOOKUP`/`XLOOKUP`), arrays, `&`, references to whole columns (`B:B`).

### 5.1 Number formats

- General.
- `1,234` and `1,234.56`, with a decimals −/+ control.
- `12%`.
- Currency `£1,234`. The symbol comes from the book's language region, and it can be changed per cell.
- Compact `1.2k` / `1.2m`.
- A negatives choice: `−1,200` or `(1,200)`.
- "Show zero and empty as —".

Separators follow each body's language at publish and display time: `1,234.5` in English, `1.234,5` in Spanish.

### 5.2 Dates

- **Entering a date.** Typing or pasting a date recognises it, using the book's language for day/month order: `24/10/2026`, `24 Oct 2026`, `Oct 2026`, `Q4 2026`, `2026-10-24`. It is stored as an ISO date.
- **Display formats:**

  | Format | Example |
  |---|---|
  | Day | 24 Oct 2026 |
  | Month | Oct 2026 |
  | Quarter | Q4 2026 |
  | Year | 2026 |
  | ISO | 2026-10-24 |

  Month names follow each body's language.
- **Financial year.** A project setting gives the month the financial year starts (default January). With it set, the quarter and year formats show `Q1 FY27` and `FY2027`.

## 6. The editor

### 6.1 The card

- **Shape.** Beneath each figure line the editor draws a card: the rendered table, with header, total row and formats applied, or the image.
- **Like today's thumbnail.** It is a decoration, never an attachment (tripwires 1, 26), and it follows the `FigureThumbnailOverlay` pattern.
- **Room in the layout.** Room is made with the figure line's `paragraphSpacing`. For a table, that spacing is derived from the figure's row count, read synchronously from the in-memory figure model. It changes only when the row count changes or the editor expands or folds, and then only that paragraph re-lays out. A long table's card shows its first 12 rows and "+ N more rows".
- **What it shows:** the tinted Research corner, the amber "changed" banner, and suggestion dots.
- **Gestures:** double-click (or Return with the caret on the caption line) expands the card in place.
- **This is the milestone's largest risk** (§11). The first editor task builds the reserved-space mechanism and its harness tests before anything else depends on it.

### 6.2 Expanded in place

The card becomes a live grid in the text column. The text above and below stays visible, dimmed. It has:

- **a slim toolbar:** number format menu, decimals −/+, align left/centre/right, Header row, Total row, Σ (inserts `SUM` over the column above), and ⤢;
- **a formula bar:** the cell reference or range, and the cell's formula or value;
- **the grid:** column letters and row numbers, with selection, ranges and resizable columns;
- **a bottom bar:** "Table 2 · caption · name", where the caption and name are editable, and Done.

**Menus.** The right-click menu and Format ▸ Table carry everything:

- the toolbar's actions;
- insert/delete row or column, and move row or column;
- sort by column;
- number format details;
- Import from CSV…;
- Send to Research.

**Focus.** Esc, Done, or clicking in the text folds the editor back. While it is expanded, the text editor gives up focus. Typing goes to the grid, and the text undo stack is not touched until the fold.

**⤢ Open in window.** Opens the same editor component in its own window, which is non-modal and can be one of several. The in-place card shows "Editing in window" and updates live.

### 6.3 Keys

| Key | Action |
|---|---|
| ← → ↑ ↓ | move between cells |
| Tab / ⇧Tab | right / left; Tab in the last column wraps to the next row's first cell |
| Return / ⇧Return | down / up |
| typing | replaces the cell |
| F2, Return on a selected cell, double-click | edit inside the cell |
| Esc | cancel the cell edit; a second Esc folds the editor |
| ⇧ + arrows, drag | extend the selection |
| ⌘A | select the whole table |
| `=` | starts a formula; arrows or clicks while composing insert references |
| ⌘C / ⌘V | copy and paste cells; TSV and HTML tables from Excel, Sheets and Numbers |
| ⌘D / ⌘R | fill down / right, shifting relative references |
| ⌫ | clear the selected cells |
| ⌘⌥↑ ↓ ← → | insert a row above/below, or a column left/right |
| ⌘Z / ⌘⇧Z | undo / redo within the grid |

### 6.4 Commands in the text

- **Insert ▸ Table (⌘⇧T)** creates a 3×3 table figure with a header row, inserts its line at the caret, and expands it in place.
- **"Convert to Table Figure"**, on a hand-typed pipe table (from its context menu or the Insert menu), creates a figure from the pipe text and replaces the text with the figure line. It is one undo step.
- **The grid sheet** from plan 3b (⌘⌥⇧T, and double-click on the delimiter row) is retired. On a pipe table, that shortcut now offers Convert.
- **Kept for hand-typed pipe tables:** Tab/Return/tidy-on-leave, from plan 3a.
- **Image figures:** Insert ▸ Figure (⌘⇧I) and dropping or pasting an image now create the image in `figures/`, not in Research.

### 6.5 Suggestions on cells

An assistant suggestion or note anchored to a cell shows a dot on that cell, both on the card and in the grid. Selecting the cell shows the suggestion in a strip above the grid, with Accept and Reject. Accepting writes the cell as the author, with the suggestion's attribution recorded.

## 7. The Figures area

Denver, 2026-10-28:
- **The middle path:** the section shows only when the project has a figure. Piece folds do not list figures. Instead a piece row shows a count of the figures its text uses, and clicking it filters the section to that piece.
- **Drag to Research confirms:** dropping a figure on Research asks once, because Send to Research is not undoable.
- **Use in document leaves the figure unused (2026-10-29):** from the tree or a menu it makes a figure marked "—". Insert ▸ Existing Figure… places any figure's line at the caret.
- **New Table in Research (2026-10-30):** Research offers New Table beside New Note, making a blank table that opens in the grid.
- **Research CSVs edit in the grid in plan 8:** undo works while the grid is open, and the guide says saved changes are not versioned until plan 9.

- **Tree section.** A new section between the manuscript and Research, in every project kind that has a manuscript (a capability query, tripwire 55). Each row shows the number ("Table 2", "Fig 1", or "—" when unused), the name or caption, and tags:
  - **Research:** has pins;
  - **changed:** a pin or snapshot source moved on;
  - **unused;**
  - **in Research:** a legacy figure (§4.4).
- **Per-piece folds.** Each piece row folds open onto the figures it uses, as it folds onto its own research today.
- **Selecting a figure** shows it large in the centre, using the same editor component, plus an inspector with:
  - name;
  - number and section;
  - "Used in" (links to the line and to each cross-reference);
  - "Reads from Research" (sources, ranges, pin dates);
  - notes and suggestions;
  - actions: Send to Research, Open in window, Import from CSV.
- **Drag.** Research item → Figures = Use in document. Figure → Research = Send to Research. Dragging within the Figures list does not renumber; moving the text does.
- **Research tables** (a CSV in Research) open in the same grid editor in the centre. Editing saves to the file, with formulas as `=` cells. There is no op log for Research.

## 8. Translation

- **Shared across languages:** numbers, dates and formulas.
- **Translated per language:** text cells, such as row and column labels. The paragraph-aligned translation layer gains figure-cell entries keyed by (figure, row id, column id, language).
- **Who may write:** a translator actor's permit allows writing those entries only.
- **What a body shows:** a language body shows its translations, and falls back to the source text with the usual missing-translation warning.
- **Captions** translate with their line, as today.

## 9. Publishing

- **Content.** PDF, EPUB and Word emit tables from the figure model's computed values with formats applied. Separators and month names follow each body's language. The header row repeats and the total row is ruled, as the house style already specifies (report spec §5.3, §6.2). Images publish as figures do today.
- **Problems** (`PublishProblem`), with the Report profile red and others amber:
  - an error cell;
  - a missing Research source;
  - a reference to a figure in Research.
- **Amber everywhere:** "uses numbers from Research", "Research changed since refresh", and the `NPV` first-flow note.
- **Unused figures** are not published.
- **Hand-typed pipe tables** publish exactly as before.

## 10. MCP, phone, help

### 10.1 MCP

Figures are read-only to the AI.

- **`list_figures`:** name, kind, number, caption, used-in, pins, "changed", "unused".
- **`read_figure`:**
  - for a table: cells as A1 with value, formula and format, plus a rendered text table;
  - for an image: a crop on demand under the 1 MB response cap (tripwire 10).
- **Figure anchors.** `add_note`, `add_comment`, `add_query` and `add_suggested_change` accept a figure anchor: `tbl:cashflow`, `tbl:cashflow!C3`, `tbl:cashflow!C3:E3`. Anchors are stored by row and column id, so they follow inserts, and they are orphaned when their cells are deleted. A suggested change carries a new value or formula, and the author accepts it in the grid (§6.5).
- **Use and send-back** reach the author only as suggestions. The AI never moves figures itself.

Research tables are writable by the AI.

- **`create_research_table`**, **`write_research_cells`** (values, formulas, formats) and **`read_research_table`**, which returns computed values.
- **Version history.** Each AI write keeps the previous version under `.maugham/research-versions/` and is marked "written by assistant". The Research table's inspector offers "Restore previous version".
- **Effect on figures.** A write that changes a snapshotted source triggers the figure's "changed" note. Nothing more.

The tools list is derived from `MCPToolCatalog.all`, so counts in docs come from the catalogue.

### 10.2 Phone

The phone renders figure cards read-only, computed through the shared Core engine. Image figures display. There is no editing.

### 10.3 Help

The Markdown help and the guide describe figures, the Figures area, the formula set (with the `NPV` quirk), formats, Use in document / Send to Research, and pins. Help describes only what ships (rule 7).

## 11. Risks

1. **Reserved space in the text layout** (§6.1). The card's height comes from figure data, not the text. If row-count changes re-lay out more than their paragraph, or arrive mid-keystroke, the editor's fragile binding is at risk (tripwires 2, 3, 6). The first editor task proves the mechanism behind `EditorIntegrationHarnessTests` and a typing-performance budget.
2. **Focus handover** between the text view and the grid, and the undo hand-off at fold. Test these with the real key path, not hand-driven signals (feedback: one test models the real delivery path).
3. **Excel parity** for the iterative finance functions. Fixtures are computed in Excel, including edge cases (no sign change, a huge guess, dates out of order).
4. **A second op-log document class.** Every census that assumes "op-logged = manuscript text" (tripwires 20, 38, 44, 48, 52) must be extended deliberately, never exempted.
5. **Concurrent structure edits:** deleting a column while another device edits a cell in it. Rule: the delete wins, and the orphaned edit is kept in history and dropped from the view.

## 12. Plan split

Five plans, each capped at about 10 tasks. Following rule 11, build plan 5 before writing plans 6–9.

5. **Core: the table and the engine.**
   - Table model with row and column ids.
   - Formula parser, references by id, evaluator, dependency graph and cycles.
   - The function set with Excel fixtures.
   - Number and date formats with localisation.
   - CSV render and import, with research CSVs' `=` cells.
6. **Storage: figures in the op log.** Split by its surveys into 6a (the figure document: payload, class, deriver, cache, host, render, censuses, image figures), 6b (the whole-app synced-path checker and census, references by id, revive, rename/remove, Use in document, Send to Research and back, pins) and 6c (checkpoint restore of figures; promotion re-creating figures). Denver, 2026-10-25: text-cell translations and Research version history move to plan 9, beside the publishing bodies, MCP tools and AI Research writes that use them; plan 7's card shows a body's label translations once they exist. Denver, 2026-10-24: every path from synced data reaches the disk through one checker; a figure in an unclaimed piece follows its piece's text posture exactly. Denver, 2026-10-24: a figure belongs to the piece it was created in — that piece's author and whole-book authors may edit it.
   - Figure document class, op kinds, schema 10, permits and censuses.
   - The `figures/` render.
   - Use in document / Send to Research through the typed mover.
   - Research pins, refresh and compare.
   - Checkpoint restore of figures (contents only; parked figures skipped; renames, removals, figures created since and replaced pictures are out of reach of a checkpoint pointer).
   - Promotion re-creates the piece's figures in the new project from their current state (ids kept, history stays in the Collection, as the manuscript's does).
7. **Editor: card and in-place grid.** Split into 7a (card + reserved space, built first), 7b (caption bar, diagnostics, Insert Table / Convert, grid-sheet retirement), 7c (the in-place grid), 7d (clipboard, undo hand-off, pop-out). Denver, 2026-10-25: ⌘Z after Convert or Insert Table removes the figure it made (to the Trash) with the text; the expanded grid is a fixed-height scrolling viewport (about 15 rows); a pop-out figure window closes with its project window; cell suggestions move whole to plan 9.
   - Reserved space first.
   - Caption-bar styling.
   - The grid: keys, formula bar, toolbar, menus, paste.
   - The pop-out window.
   - Undo hand-off.
   - Insert Table / Convert, grid-sheet retirement.
   - The card shows a body's text-cell translations once plan 9 stores them.
8. **The Figures area.**
   - Tree section and folds.
   - Centre editor and inspector.
   - Drag verbs.
   - Research tables in the grid.
   - Legacy research figures.
9. **Out to the world.**
   - Publishing (PDF, EPUB, Word) from figures, with localised formats and problems.
   - MCP tools and figure anchors.
   - Cell suggestions (§6.5) end to end: the cell-anchor annotation model, MCP creation, dots on card and grid, the strip with Accept/Reject (Denver, 2026-10-25).
   - Text-cell translations (§8): the store and derivation keyed by (figure, row id, column id, language), a figure-aware translation permit class carrying the figure's piece, who writes them (translator and `write_translation`), coverage-gate membership, a body's emission, and the orphaned translations a removed figure leaves.
   - Research version history (§10.1) with the AI Research-table tools — needs Denver's ruling against RULING-24 (research is recoverable but not versioned) and replaces the canvas Rewrite's Trash `.priorVersion` route.
   - Phone rendering.
   - Help and docs.

## 13. Testing

- **Core:** each function against Excel-computed fixtures; formats per language; references surviving inserts and deletes; cycles across tables; CSV round trips, including `=` cells and unsupported functions.
- **Op log:** concurrent cell edits merge per cell; concurrent row inserts both survive; delete-versus-edit follows §11.5; signatures and permits (a suggest-only collaborator is refused a cell write); send to Research and back keeps the name and reconnects references; an unchanged round trip resumes the parked log with anchors intact; a copy edited in Research (rows inserted, moved, deleted) comes back as appended ops that keep matched row ids and orphan only unmatched anchors, signed by the returning actor.
- **Editor:** the card's reserved space under typing (harness and budget); expand and fold focus; ⌘Z inside the grid, and one ⌘Z for the visit after the fold; paste from Excel's TSV and HTML; Convert is one undo step.
- **Publishing:** PDF, EPUB and Word tables carry formats and the language's separators; an error cell refuses a Report; a pin note stays amber.
- **MCP:** a figure is read-only (no tool writes one); anchors follow inserts; Research writes keep a version; tool counts come from the catalogue.
- **Smoke (Denver):** build the §1 success scenario by hand.
