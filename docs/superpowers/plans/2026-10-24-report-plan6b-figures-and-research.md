# Report plan 6b — figures move between Research and the document Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** figures gain their lifecycle. A row or column comes back on undo, a figure can be renamed or removed, a Research table or picture becomes a figure, and a figure can go to Research and return — parked, never converted — with research pins that notice when Research changes. First, every path that arrives from synced data reaches the disk only through one checker.

**Architecture:**
- **One path checker in Core** (`SafeRelativePath`, extended) owns every rule about a project-relative path or file name that came from another device. A census fails on any new raw join.
- **Figures and research items are referenced by id, shown by name.** Formulas store `RefTarget.figure(id:)` and `RefTarget.research(id:)`; the parser resolves a typed name to an id at entry, and the renderer shows the current name. A rename is then one registry change.
- **Parking keeps the op log.** Send to Research appends `figureParked` and writes a working copy (CSV + sidecar keyed by the research item's id). While parked the figure folds no content ops. Coming back appends `figureResumed`, plus the difference if the copy changed.
- **Pins are per home figure.** A figure that reads a Research table, or a figure now parked in Research, keeps the values it last read and says when the source has changed. Refresh writes pins into the reading figure only.

**Tech Stack:** Swift 5.10, MaughamCore, SwiftUI/AppKit (Mac stores only — no new UI in this plan), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md`, §3.3–3.5, §4.1–4.3, §5, §11.5. Survey of the built code (main @ 570d724a): `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan6b-survey.md`, sections A–J. Every file, line and signature below comes from it; read the named section before each task and re-verify lines against the code (they drift).

## Global Constraints

- **Hard invariants** (CLAUDE.md): op log is truth; `figures/*.csv` and Research working copies are never read as figure truth except by the one explicit return path (Task 8); plain text on disk; every manuscript edit in this plan goes through the existing door-checked manuscript route (`ProjectStore+Search.replaceInManuscript`'s pattern: `settledPosture(forPath:).allows(.writeText)` before any load, live `Document` if open, else transient load, signed as the author).
- **Denver's rulings, 2026-10-24** (record each in the ledger as given):
  - **R-D1 refs by id:** formulas reference other figures and Research items by hidden id and show the current name.
  - **R-D2 follow the Research copy:** while a figure is parked, figures reading it keep its last values (its parked state). When the working copy's content hash differs from `parkedHash`, they say "Research has changed — refresh?". Refresh writes pins into the reading figure only, and needs that figure's `.editFigure` posture. Nobody writes another person's figure at send time.
  - **R-D3 whole-app path check:** every path or file name that comes from synced data (manifest, op payload, registry, sidecar, `.trash` meta, inbox) reaches a write, move, copy or delete only through `SafeRelativePath`. The older unchecked sites are fixed in this plan, not listed as debt.
  - **R-D4 unclaimed piece:** a figure follows its piece's posture exactly, starter yield included (closes R-6a-10).
  - **Figure ownership (unchanged):** a figure belongs to its piece; that piece's author and whole-book authors may edit it.
- **Rulings made writing this plan** (ledger them; carry forward):
  - **P-1 revive words:** new `FigureStructureChange` words `revive_row` / `revive_column`. They ride schema 10 (unreleased). An insert of a tombstoned id stays refused.
  - **P-2 deletes carry what they removed:** the delete payload gains an optional `removed` slice (the row's or column's cells, pins and width). The host fills it at delete time, so `FigureInverse` stays payload-only: inverse(delete) = revive carrying the slice, inverse(revive) = delete carrying it, inverse(insert) = delete with an empty slice.
  - **P-3 rename relabels the text, all or nothing:** rename checks the write door on every manuscript that holds the figure's line or a cross-reference to its label first. If any one refuses, the whole rename is refused, naming the pieces. Then it changes the registry, moves the file (images: a `figureImageSet` with the same hash and new file name) and relabels the text.
  - **P-4 research tables are an `AssetKind`:** a new `.table` case for `.csv` / `.tsv` (older builds decode it as `.document`, tolerantly). Research sidecars live at `.maugham/research-tables/<ResearchItem.id>.json`, so the typed mover's renames and moves never stale them.
  - **P-5 parked folds nothing:** content ops ordered after `figureParked` and before `figureResumed` are dropped with a diagnostic (kept in history, like a delete beating an edit). The host refuses edits to a parked figure with the notice "This table is in Research."
  - **P-6 content hash in Core:** `ContentHash.ofFile(_:)` (SHA-256, first 16 hex, the existing algorithm) moves to Core; `FigureImageResolver.contentHash` delegates (tripwire 19).
  - **P-7 the return reason:** a new `SynthesisSource.broughtBackFromResearch`; `FigureDocument.commit` gains a `provenance:` parameter so the returning ops carry it.
  - **P-8 undo:** a pin refresh is undoable (its payload carries the prior pin); park and resume are not ("undone by the opposite verb").
  - **P-9 no new UI:** every verb here is a store/host API with tests. Plans 7–8 give them surfaces; this joins R-6a-14's release gate.
- **Schema:** every new wire word, payload field and enum case rides schema 10, with a line in `ProjectManifest.swift`'s history paragraph. Plan 5's golden wire file (`TableWireFormatTests`) is updated deliberately in Task 3, never loosened.
- **Census rule:** extend tripwires (14, 19, 20, 44, 52) to new code with planted offenders and controls; never exempt. New figure mutators use the `requireWritable("…")` spelling.
- **Gates:** `./scripts/test.sh core` after Core changes; `./scripts/test.sh` after Mac changes; `./gen.sh` after adding any file; `./scripts/test.sh full` and `./scripts/test.sh phone` at the whole-branch review. A run ending only in "Test Case … started." was killed by another session's `xcodebuild`: re-run.
- **Area guides:** read Core `AREA.md`, `Maugham/OpLog/AREA.md`, `Maugham/Stores/AREA.md` before editing there. New Core files go on the Core Map; every added guide word raises that guide's `DocBudgetTests` ceiling by the exact count with a `+N report plan 6b Task K:` comment.
- Never qualify `Document` in test files. `TestTemp` is the one temp root. Paragraph-id literals in tests use the valid alphabet (tripwire 8).

## Review Focus

1. **A synced manifest names a path like `../../Documents/x.md`** for a structure item, research item or statement: the write, move or delete is refused with a logged diagnostic, no file outside the project is touched, and the project still opens. Task 2.
2. **Two Macs: one sends a table to Research while the other edits a cell.** The edit ordered after the park is dropped from the view and kept in history; the working copy holds the parker's state; nothing crashes. Tasks 7 and 8.
3. **A working copy edited in Excel and re-saved** — CRLF, a BOM, `;` separators, a row inserted, one moved, one deleted — comes back with matched rows keeping their ids, only the deleted row's anchors orphaned. Task 8.
4. **Rename to a name that differs only in case from another figure, or that is already taken, or of a figure referenced in a piece the renamer may not write**: refused, nothing changed (registry, files, text and formulas all as before). Task 5.
5. **Undo of a row delete after another device inserted a neighbouring row and set a column width**: the row returns in its own slot with its cells, and formulas that showed `#REF!` show values again. Task 4.

---

### Task 1: The path checker (Core)

**Files:** Core `SafeRelativePath.swift` (extend), new Core `ContentHash.swift`; Core `Table/FigureOp.swift` (`isAPlainFileName` delegates); Core `OpLogFiles.swift` (doc id); `Maugham/OpLog/FigureRender.swift` (`renderPath` delegates); `Maugham/Publish/FigureImageResolver.swift` (`contentHash` delegates); `Maugham/MCP/Tools/PublishFileTools.swift` (`PublishPath` delegates where its rule is the same). Core `AREA.md`. Tests: Core `SafeRelativePathTests.swift`, new Core `ContentHashTests.swift`, `MaughamTests/SafeRelativePathSecurityTests.swift`.

**Interfaces — Produces** (verify names don't collide; survey G):
- `SafeRelativePath.resolve(_:under:)` — existing, unchanged.
- `SafeRelativePath.isPlainFileName(_ name: String) -> Bool` — non-empty, no `/`, `\`, NUL, not dot-leading.
- `SafeRelativePath.resolveFile(named: String, in folder: String, under root: URL) throws -> URL` — one plain file name inside one project-relative folder; symlink-resolved containment as `resolve` does.
- `SafeRelativePath.requireDocId(_ id: String) throws -> String` — same character rule as a plain file name, used wherever a doc id becomes part of a file name.
- `ContentHash.ofFile(_ url: URL) throws -> String` — byte-identical output to today's `FigureImageResolver.contentHash` (pin it with a fixture).

**Contract:**
- `FigureImageRef.isAPlainFileName`, `FigureRender.renderPath` and `PublishPath.validateAndResolve` keep their current answers (their existing tests stay green unchanged) but spell no rule of their own.
- `OpLogFiles.opLogFileURL`, `segmentFileURL` and `IntegrityQuarantine.record` refuse a doc id that fails `requireDocId` (throw; the caller's existing error path reports it). Replace the "Deliberately NOT format-validated" comment with the new rule. Check every existing doc-id shape first (`d_…`, `fig-…`, statement ids, `__project__`): all must pass. If one doesn't, stop and report — don't widen the rule silently.

- [ ] Write failing tests: each new function against good and bad inputs (`..`, `.`, `a/../..`, absolute, NUL, `\`, empty, dot-leading, a symlinked folder escaping the root); `ContentHash` fixture equals the old function's output; a log file URL for `../x` throws.
- [ ] Run red; implement; delegate the three old validators; run `./scripts/test.sh core` and `./scripts/test.sh`; commit.

### Task 2: Every synced path goes through the checker, and a census keeps it so (Mac, phone, tests)

**Files:** the NO rows of survey G's site table — `Document.swift` autosave, `DocumentStore.performFileSave`, `Document+ExternalChange.writeConflictBackup`, `ProjectStore+Structure` rename/duplicate, `ProjectStore+Research` rename/duplicate/rewrite, `ProjectStore+ResearchMove`, `ProjectStore+Search` research replace, `ProjectStore+Statements` delete, `ProjectStore+CollectionPieces` move/rename/research note/asset, `DocumentStore.replaceFigureImage` (assert its URL is inside `figures/`). `MaughamTests/TripwireGrepTests.swift`, `TripwirePhoneGrepTest`. `docs/tripwires.md` — **a new row: ask maugham-issues for the next free tripwire number first** (row 57 is theirs). Do not edit CLAUDE.md; report the one-line row text for Denver to add.

**Contract:**
- Each site resolves its synced string through `SafeRelativePath` before touching the disk. A refusal is not a crash: the operation throws its existing error type (or a new `UnsafeProjectPath` error carrying the path), and the UI's existing error notice says it. Autosave of a document whose manifest path is unsafe refuses the write and logs once, not on every keystroke.
- **The census:** every `appendingPathComponent(` / `appending(path:` in production files under `Maugham/`, `MaughamPhone/` and Core whose argument derives from a synced field (`.path`, `.filename`, `.relativePath`, `docId`, `sourceFilename`, `originalRelativePath`, `parkedPath`) is an offender unless the line goes through `SafeRelativePath`. Population derived by grep, not a hand list. Allowed lines carry a `// local-path:` comment naming why the string is not synced (a locally minted name). Planted offender + control in `TestTemp.root`, following the mover census pattern (`TripwireGrepTests` :588, control :2031).
- Before writing the census, **run it against the tree and read every hit**; each hit is either fixed here or marked `// local-path:` with a true reason. No `countedLists` debt entries.

- [ ] Write the Review Focus 1 test: a project whose manifest gives a structure item, a research note and a statement the path `../outside.md`; autosave, rename, duplicate, research replace and statement delete each leave `outside.md` absent/untouched, and the project opens.
- [ ] Write the census and its control; run red; fix each site; run green.
- [ ] `./scripts/test.sh`, `./scripts/test.sh phone`; commit.

### Task 3: Figures and Research items are referenced by id (Core)

**Files:** Core `Table/Formula.swift`, `FormulaParser.swift`, `FormulaEvaluator.swift`, `Workbook.swift`, `TableCSV.swift`, `FigureCache.swift` (`FigureWorkbook.assemble`); `Maugham/OpLog/FigureRender.swift`, `Maugham/Stores/DocumentStore+Figures.swift` (assemble caller). Tests: Core `FormulaParserTests`, `WorkbookTests`, `TableCSVTests`, `TableWireFormatTests` (golden), `FigureCacheTests`.

**Contract** (survey B):
- `RefTarget.figure(id: String)` and `RefTarget.research(id: String)` replace the name cases. The wire key changes accordingly; update the golden JSON on purpose and note it in the schema history paragraph.
- Parsing takes a **name directory**: figure name → (id, table) and research name → (id) — `FigureNames` or similar, built from the registry and the research tree. A research item's name is its `ResearchItem.title`. Two Research items with the same title (case-insensitive) → the parse error "Two Research items are called <title>; rename one." Unknown names keep today's errors.
- Rendering takes the same directory in reverse (id → current name); an id it cannot name renders `#REF!` as a missing table does today. Bare-vs-quoted name rules unchanged.
- `Workbook` keys tables by figure id. `ResearchPinSource` becomes per home table: `pinnedValue(home: String, research: String, row: Int, column: Int) -> CellValue?` (home = the reading figure's id). `pinsChanged` and `researchReaders` follow.
- `TableCSV.read` resolves names to ids through the directory; `renderResearch` writes names.
- `FigureWorkbook.assemble` keys by id. A parked figure is still assembled from its parked state (Task 7 depends on this; today it is skipped → `#REF!`). Mark it parked in the result so Task 9 can flag readers.

- [ ] Write failing tests: a formula typed with a figure name stores its id and renders the new name after the registry name changes (no op appended); a research title collision is refused with the message above; the golden wire file shows `id`; two figures pinned at different times to the same research cell keep their own values.
- [ ] Run red; implement; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 4: Rows and columns come back (Core + Mac)

**Files:** Core `Table/FigureOp.swift` (words, `removed` slice), `FigureTable.swift` (revive), `FigureDeriver.swift`, `FigureInverse.swift`; `Maugham/OpLog/FigureDocument.swift` (delete undo, insert redo); `MaughamTests/OpLog/OpKindUndoExhaustivenessTests.swift` (mechanism string). Tests: Core `FigureDeriverTests`, `FigureInverseTests`, `FigureTableTests`; `MaughamTests/OpLog/FigureDocumentTests`.

**Contract** (survey A; rulings P-1, P-2):
- `FigureTable.reviveRow(_:)` / `reviveColumn(_:)` clear a tombstone in place (same slot ⇒ same position). Reviving a live or never-seen id is refused.
- `removed` slice: the row's (or column's) cells keyed by the other axis's id, its pins and, for a column, its width. On revive the deriver restores cells only where the other axis is still live (a cell whose column was deleted meanwhile drops, with a diagnostic) and restores pins and width.
- Undo of a delete = revive carrying the slice, drift-guarded (the slot is still tombstoned). Redo of an insert = revive with an empty slice. Remove `.insertNotRedoable` and its sentence; R-6a-13's "untouched" guard on insert undo stays.
- `deleteRow`/`deleteColumn` on `FigureDocument` take an `undoManager:` and register undo like the others.
- The exhaustiveness mechanism string names `FigureInverse.inverse` and the revive path; drop the R-6a-5 wording.

- [ ] Write failing tests: Review Focus 5; delete a row holding a formula another cell references → `#REF!`; undo → the value returns; redo of an undone insert; a revive from another device whose column was deleted meanwhile keeps the other cells.
- [ ] Run red; implement; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 5: Renaming and removing a figure (Mac stores)

**Files:** `Maugham/Stores/ProjectStore+Figures.swift`; `Maugham/Stores/DocumentStore+Figures.swift` (`renderFigures`, its shared-path refusal); `Maugham/OpLog/FigureDocument.swift` (image file rename via `figureImageSet`); the text relabel helper beside `ProjectStore+Search.replaceInManuscript` (reuse its door-and-transient-load route; do not copy it). `OpKindUndoExhaustivenessTests` (`.figureCreate` reason). Tests: new `MaughamTests/Stores/FigureRenameTests.swift`.

**Interfaces — Produces:** `ProjectStore.renameFigure(id: String, to name: String) async throws -> FigureRecord`; `ProjectStore.removeFigure(id: String) async throws`; error `FigureRenameRefused` naming the blocking piece titles or the clashing name.

**Contract** (ruling P-3):
- Rename: refuse an empty name, one taken case-insensitively, and one whose `figurePath` collides; then check the `.editFigure` posture on the figure and the `.writeText` door on every manuscript that holds its line (`{#tbl:old}` / `{#fig:old}`) or a cross-reference to that label; any refusal → nothing changes. Then: registry name + path (`saveManifest`), the old render file removed through the typed mover and the new one rendered, an image's file moved through the typed mover plus a `figureImageSet` with the same hash and the new file name, and the text relabelled. Formulas need nothing (Task 3).
- Remove: a structural verb with the same door; the record leaves the registry, the render file goes to the project Trash through the typed mover (so it can come back), and the op stream stays (append-only). Its line and references in the text are left; they show as broken references (plan 7 draws them). `figureCreate`'s exhaustiveness reason becomes "a created figure is removed by ProjectStore.removeFigure".
- `renderFigures`' "two records share a path" refusal now names rename as the way out; a rename that separates them renders both.

- [ ] Write failing tests: Review Focus 4; a rename relabels the figure line and a cross-reference in a second document, and a formula in another figure renders the new name; the old CSV is gone and the new one exists; an image rename moves the file and the next `setImage` writes the new name; remove sends the CSV to Trash.
- [ ] Run red; implement; `./scripts/test.sh`; commit.

### Task 6: Research tables, and Use in document (Core + Mac stores)

**Files:** Core `ResearchItem.swift` (`AssetKind.table`), Core `Table/FigureOp.swift` (create's source fields), new Core `Table/ResearchTableSidecar.swift`; `Maugham/Stores/ResearchKindInference.swift`, `ProjectStore+Research.swift` (`addResearchAsset` accepts tables), `MaughamSidecarPath.swift` (the new folder), `ProjectStore+Figures.swift` (`useInDocument`). Tests: Core `ResearchTableSidecarTests`, `SchemaEvolutionToleranceTests` row; `MaughamTests/Stores/UseInDocumentTests.swift`.

**Interfaces — Produces:**
- `AssetKind.table`; `ResearchTableSidecar { figureId: String?, name, caption, headerRows, totalRow, formats, columnWidths }` (Codable, tolerant), stored at `.maugham/research-tables/<item id>.json` via `SafeRelativePath.resolveFile`.
- `figureCreate` payload optional `source: FigureSource { researchItemId, path, contentHash }`.
- `ProjectStore.useInDocument(researchItemId: String, piece: String?) async throws -> FigureRecord`.

**Contract** (spec §4.1; P-4, P-6):
- A `.csv`/`.tsv` added to Research becomes a `.table` item.
- Use in document on a table item: read through `TableCSV.read` (with the name directory) into a new figure — `=` cells become formulas, unparseable ones stay text holding `=…` and come back as problems; record the source. On an image or PDF item: the existing `createImageFigure` path, with the source recorded. The name comes from the item's title, de-duplicated (`vacantFigureName`). No text line is placed (plans 7–8 ask where).
- An item carrying a sidecar whose `figureId` names a parked figure is **not** handled here: it routes to Task 8's return. Leave a clear seam (`useInDocument` calls `bringBack` when the sidecar names a parked figure) and test the routing once Task 8 exists.

- [ ] Write failing tests: a research CSV with `=SUM(B2:B3)`, `=NOPE(1)` (`#NAME?`) and `=1+` (text + problem) becomes a figure; a picture item becomes an image figure with its source hash; an older build's manifest decoding `.table` as `.document` (tolerance row).
- [ ] Run red; implement; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 7: Send to Research (Core + Mac)

**Files:** Core `Table/FigureDeriver.swift` (P-5), `Table/FigureOp.swift` (`figureParked` gains `parkedItemId`); `Maugham/OpLog/FigureDocument.swift` (`requireWritable` consults parked; the park mutator); `Maugham/Stores/ProjectStore+Figures.swift` (`sendToResearch`); research creation through the typed creator route (`addResearchAsset`'s copy discipline, written via `coordinatedWrite` inside `relocateUserContent` as the mover header requires). Tests: Core `FigureDeriverTests`; `MaughamTests/Stores/SendToResearchTests.swift`.

**Interfaces — Produces:** `ProjectStore.sendToResearch(figureId: String, scope: ResearchScope) async throws -> ResearchItem`.

**Contract** (spec §4.2; P-5):
- Doors first: `.editFigure` on the figure and `.writeText` on the manuscript holding its line. Any refusal → nothing changes.
- Writes the working copy: a table → CSV via `TableCSV.renderResearch` (formulas as `=` cells) + the sidecar (figure id, name, caption, formats, header/total, widths); an image → a copy of the file. Then appends `figureParked { parkedPath, parkedHash, parkedItemId }`, removes the figure's line from its manuscript (an ordinary op-logged edit, undoable in that document), and stops rendering `figures/<name>.csv` (the stale render goes to Trash through the typed mover).
- The figure stays in the registry, marked parked by its stream (plans 7–8 list it as "in Research"). Figures that read it keep its parked values (Task 3's assemble).
- A content op ordered after the park folds to nothing, with a diagnostic; the host refuses edits with "This table is in Research."

- [ ] Write failing tests: Review Focus 2 (two hosts, the edit ordered after the park); a send writes the CSV and sidecar, removes the line, keeps the stream, and a reading figure still shows the values; a send refused by the text door changes nothing.
- [ ] Run red; implement; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 8: Coming back from Research (Core + Mac)

**Files:** new Core `Table/FigureReturnDiff.swift`; Core `SynthesisSource.swift` (P-7); `Maugham/OpLog/FigureDocument.swift` (`commit(provenance:)`, the resume mutator); `ProjectStore+Figures.swift` (`bringBack`, wired from `useInDocument`). Tests: Core `FigureReturnDiffTests`; `MaughamTests/Stores/BringBackTests.swift`.

**Interfaces — Produces:**
- `FigureReturnDiff.ops(from parked: FigureState, to copy: FigureTable, sidecar: ResearchTableSidecar?, mintRow: () -> RowID, mintColumn: () -> ColumnID) -> [(OpKind, FigureOpPayload)]` — pure.
- `ProjectStore.bringBack(researchItemId: String, piece: String?) async throws -> FigureRecord`.

**Contract** (spec §4.2 "Coming back"):
- Matched by the sidecar's figure id only; a different file never attaches to a parked log.
- Unchanged copy (hash equals `parkedHash`): append `figureResumed`; history, ids and anchors return as they were.
- Changed copy: rows matched by longest common subsequence over row values, columns by header text (then position for headerless tables); matched ids kept; unmatched old rows/columns deleted (anchors orphaned), new ones inserted with fresh ids; changed cells set; formats from the sidecar. Then `figureResumed`. Every appended op carries `SynthesisSource.broughtBackFromResearch` and is signed by the actor bringing it back (the opening window's actor).
- An image compares by hash; a changed one is one `figureImageSet`.
- The figure keeps its name, so references by id reconnect with no op.
- Doors: `.editFigure` on the figure. The working copy stays in Research (the writer removes it if they wish).

- [ ] Write failing tests: Review Focus 3 as a `FigureReturnDiff` fixture (CRLF, BOM, `;`, insert/move/delete) plus a store-level round trip; an unchanged round trip keeps an annotation's row anchor; the appended ops carry the reason.
- [ ] Run red; implement; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 9: Research pins — read, notice, compare, refresh (Core + Mac)

**Files:** Core `Table/FigureCache.swift` / `Workbook.swift` (the per-home pin source), new Core `Table/PinStatus.swift`; Core `Table/FigureOp.swift` (`figurePinSet` carries `priorPin`; inverse in `FigureInverse.swift`); `Maugham/OpLog/FigureDocument.swift` (`refreshPins`); `Maugham/OpLog/FigureRender.swift` (replace `NoResearchPins`); `OpKindUndoExhaustivenessTests`. Tests: Core `PinStatusTests`; `MaughamTests/OpLog/FigurePinTests.swift`.

**Interfaces — Produces:**
- `PinStatus` per home figure: for each source (a Research item id, or a parked figure's id) — `current | sourceChanged(old: hash, new: hash) | sourceMissing`.
- `FigureDocument.comparePins() async -> [PinComparison]` (cell, old value, new value) and `refreshPins(undoManager:) async throws` (one undoable visit of `figurePinSet` ops).

**Contract** (spec §4.3; R-D2; P-8):
- A Research ref reads the home figure's pin; with no pin yet, entering the formula takes one (the value read, the source hash, now).
- A ref to a parked figure reads the home figure's pin for that figure if it has one, else the parked state. "Changed" = the working copy's `ContentHash` ≠ the pin's `sourceHash` (or ≠ `parkedHash` when unpinned). "Missing" = the research item or working copy is gone: the kept value stays, status `sourceMissing`.
- Refresh re-reads every source of that home figure: a Research table at the pinned position; a parked figure's working copy at the cell's position in the parked table. Needs the home figure's `.editFigure`. When the parked figure comes back, live values win and its pins in other figures go inert (no op).
- Status is exposed for plans 7–9 (markers, publish notes); no UI here.

- [ ] Write failing tests: a research CSV edited on disk → `sourceChanged`, compare lists old/new, refresh updates values and ⌘Z restores the old pins; a parked figure's copy edited → its reader says changed and refresh reads the copy; a deleted copy → `sourceMissing` with the value kept; a reader whose figure the actor may not edit → refresh refused.
- [ ] Run red; implement; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 10: A figure in an unclaimed piece follows the starter (Core) + docs

**Files:** Core `LocalWritePermitBuilder.swift` (unsettled-starter arm for `.figure(piece:)`), Core `Permit.swift` if the read side needs the same arm; `PostureTests`, `PermitTableTests`; AREA guides (Core, OpLog, Stores) for everything this plan added, with `DocBudgetTests` ceilings.

**Contract** (R-D4): a figure's posture in a piece nobody has claimed equals its piece's text posture in every case the grid covers, starter yield included; read side and write side agree (tripwires 44, 47, 49 hold). Update the R-6a-10 note in code comments.

- [ ] Write failing posture/permit rows; run red; implement; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

## After the last task

- Whole-branch review (give it the ledger; name the seams: Task 3 × Tasks 5/7/9 ids; Task 2's census × every new file this plan writes; Task 7 × Task 8 parked state; Task 4 × Task 8 tombstones in a return diff).
- `./scripts/test.sh full`, `./scripts/test.sh phone`.
- Report to Denver: rulings P-1…P-9 with costs, the tripwire row text for CLAUDE.md, the release gate (no UI for these verbs until plans 7–8).
- Then write plan 6c against the built code: text-cell translations, research version history, checkpoint restore of figures (survey J), collection→project promotion carrying figures and their streams (survey I).
