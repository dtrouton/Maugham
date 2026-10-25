# Report plan 6a — figure documents in the op log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a figure (table or image) is its own op-logged, signed, permit-checked document. It is created, edited cell by cell, merged across devices, undone, rendered to `figures/<name>.csv` and listed in the manifest. Plan 6b then adds Use in document / Send to Research, pins, translations and research versions on top.

**Architecture:**
- **Op envelope.** Figure ops keep the existing `Op` envelope, so chain, seal, trust, partition, backup signature and integrity work unchanged. They carry one new optional `figure` payload field; `changes` stays empty and `sequence` stays nil.
- **Identity and content.** A manifest `figures` registry holds identity: id, name, kind, piece and path. The figure's own stream holds content. That mirrors statements.
- **Folding.** A Core `FigureDeriver` folds ops onto plan 5's `FigureTable`, so the Mac and the phone derive the same table.
- **Host.** A Mac `FigureDocument` hosts the open figure: load, mutate, undo and render. It is a sibling of `Document`, never a `Document`.

**Tech Stack:** Swift 5.10, SwiftUI/AppKit (Mac host only), MaughamCore, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md`, §3.1–3.5 and §7's registry facts. Survey of the built code: `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan6-survey.md`. Every file, line and signature cited below comes from it, so read the relevant section before each task.

## Global Constraints

- **Hard invariants** (CLAUDE.md):
  - The op log is the source of truth, and `figures/<name>.csv` is a derived render that is **never read as truth** (tripwire 20).
  - Plain text on disk.
  - Every manuscript load goes through `Document.load`. A figure is not a manuscript, and loads through `FigureDocument.load`, which must keep the same guarantees: `OpLogStore.loadDiagnosed`, quarantine of skipped lines, and no device string (tripwire 38).
- **Denver's ruling, 2026-10-24:** a figure belongs to the piece it was created in. That piece's author may edit it, and so may anyone who may write the whole book. A reviewer may only annotate or suggest; a translator may only write translation records; the assistant gets the reviewer row. A figure created with no piece (`piece == nil`) is editable only by whole-book authors.
- **Rulings made writing this plan** (D-a…D-h from the survey; record them in the ledger and carry them forward):
  - **D-a:** figure content rides in a new optional top-level `Op.figure: FigureOpPayload?`, JSON key `"figure"`. It is threaded through `withReplacedOpId`, and is never smuggled through `changes`.
  - **D-b:** a new case `DocumentClass.figure(id: String, piece: String?)`. It resolves from the manifest `figures` registry, so an id with the `fig-` prefix but missing from the registry resolves to `.figure(id:, piece: nil)`, never to `.piece`.
  - **D-c:** figure kinds return `.manuscriptText` from `Permit.group`'s switch, while `Deriver.appliesToManuscript` returns `false` for them, keeping tripwire 44+1's named caller set unchanged. A new `RefusedWhat.figure` gives refusals their own noun.
  - **D-d:** the host is `FigureDocument` (Mac) over a Core `FigureDeriver`.
  - **D-e:** the manifest `figures` registry (`FigureRecord { id, name, kind, piece, path }`) is the truth for name, kind, piece and path. The stream is the truth for content and lifecycle (create, parked, resumed). There is no rename op kind: a rename is a registry change, built in 6b.
  - **D-g:** ⌘S checkpoints record figure streams' pointers, so 6b can restore them. Restoring a figure to a checkpoint is 6b's work.
  - **The cell-anchor wire shape**, fixed here for plans 7 and 9: flat optional `Provenance` scalars `figure_row_id`, `figure_row_end_id`, `figure_col_id`, `figure_col_end_id`. The figure id is the stream's `docId`. This needs no schema bump.
- **Schema.** The new `OpKind` cases go under schema 10, with a doc paragraph at `ProjectManifest.swift`'s history. `contentSchemaFloor` returns 10 whenever the manifest has any figure record.
- **Census rule.** Tripwires 20, 38, 44, 46, 47, 48 and 52 are **extended** to figures with planted offenders and controls, never exempted. Figure mutators use the `requireWritable("…")` guard spelling, so tripwire 52's derived population catches them.
- **Gates:**
  - `./scripts/test.sh core` after Core changes;
  - `./scripts/test.sh` after Mac changes;
  - `./gen.sh` after adding any file;
  - `./scripts/test.sh full` and `./scripts/test.sh phone` at the whole-branch review.
  - A run ending in only "Test Case … started." was killed by another session's `xcodebuild`, so re-run it.
- **Area guides.** Read `Maugham/OpLog/AREA.md`, `Maugham/Stores/AREA.md` and the Core `AREA.md` before editing in their areas. Every new Core file goes on the Core Map, and every word added to a guide raises that guide's `DocBudgetTests` ceiling by the exact count, with a `+N report plan 6a Task K:` comment. Map rows carry no milestone tags.
- Never qualify `Document` in test files. `TestTemp` is the one temp root.

## Review Focus

These are the inputs most likely to bite. Each one has its test in the owning task.

1. **A narrowed collaborator.** An author of piece A edits a figure created in piece A: allowed, and kept on every device. The same author edits a figure created in piece B: refused at write, and set aside on read. Tasks 2 and 6.
2. **Two Macs edit the same table at once.** Different cells both survive. The same cell resolves last-writer-wins by op order. Concurrent row inserts both survive. A column deleted on one Mac while the other edits a cell in it: the delete wins, and the edit stays in history. Task 3.
3. **A v0.42 Mac (schema 9) opening a book that now has figures** is refused with the "made by a newer Maugham" message, not a silent invisible figure. Task 5.
4. **Someone edits `figures/x.csv` in Excel.** The next render overwrites it, and nothing ever reads it as the table. Tasks 7 and 8.
5. **⌘Z after a cell edit** appends a compensating op restoring the prior cell (formula and format included), and redo re-applies it. A figure edited on another device in between is not clobbered. Tasks 3 and 6.

---

### Task 1: The figure op payload and kinds (Core)

**Files:** Core `Op.swift`, `OpKind.swift`, `Deriver.swift` (`appliesToManuscript`), `Permit.swift` (`group(of:)`, `isALoadEmission`), new `Table/FigureOp.swift`; the Mac `RewindWindow.swift` (`color(for:)`) and `HistoryPane.swift` (5 switches); `ProjectManifest.swift` (history doc); Core `AREA.md`. Tests: `FigureOpTests.swift` (Core).

**Interfaces — Produces:**
- **New `OpKind` cases:** `figureCreate`, `figureParked`, `figureResumed`, `figureCellSet`, `figureStructure`, `figureSettings`, `figureImageSet`, `figurePinSet`, `figurePinClear`. Their raw values are the snake_case of each name (e.g. `figure_cell_set`), following the existing convention. Check `OpKind`'s raw-value style and match it.
- **`public struct FigureOpPayload: Codable, Equatable, Sendable`.** Fields:
  - `kind: FigureKind` (`table` / `image`) on create;
  - `cell: CellKey?`, `next: Cell?`, `prior: Cell?` (nil = cleared);
  - `structure: FigureStructureChange?` = `.insertRow(RowID, after: RowID?)`, `.insertColumn(ColumnID, after: ColumnID?)`, `.deleteRow(RowID)`, `.deleteColumn(ColumnID)`, `.moveRow(RowID, after: RowID?, priorAfter: RowID?)`, `.moveColumn(...)`;
  - `settings: FigureSettingsChange?` = `.headerRows(Int, prior: Int)`, `.totalRow(Bool, prior: Bool)`, `.columnWidth(ColumnID, Double?, prior: Double?)`;
  - `image: FigureImageRef?` = `{ filename, contentHash }` plus `priorImage`;
  - `pin: FigureResearchPin?` (Task 1 defines the type; 6b uses it) = `{ research: String /* research item id */, row: Int, column: Int, value: CellValue, sourceHash: String, at: Date }`;
  - `parkedPath: String?`, `parkedHash: String?`.

  Every field is optional. Each kind's required fields are listed in a doc comment, and a static `validate(kind:payload:) -> Bool` enforces them.
- **`Op.figure: FigureOpPayload?`**, JSON key `figure`, threaded through `withReplacedOpId`, absent for every non-figure op. The bytes of existing ops stay identical: pin that with a golden line.
- **New `Provenance` fields:** `figureRowId`, `figureRowEndId`, `figureColId`, `figureColEndId` (snake_case keys as above).
- **Exhaustive switches:**
  - `appliesToManuscript` → `false` for all nine;
  - `Permit.group` → `.manuscriptText`;
  - `isALoadEmission` → `false`;
  - History and Rewind get labels "Figure created / Cell edited / Rows or columns changed / Table settings / Image replaced / Research pin set / Research pin cleared / Sent to Research / Back from Research", plus an icon and colour per kind.

- [ ] **Step 1:** Write the failing tests:
  - a round trip of every payload shape;
  - an unknown future kind still decodes `.unknown` (existing tolerance);
  - a pre-existing op's JSON bytes are unchanged (golden);
  - `IntegrityChecks.invalidParagraphIds` passes a stream of figure ops;
  - `BackupSignature.compute` counts their op ids;
  - `validate` rejects a `figureCellSet` with no `cell`.
- [ ] **Step 2:** Run `./scripts/test.sh core` → FAIL.
- [ ] **Step 3:** Implement. Add the schema paragraph "10 also covers the nine figure op kinds (report plan 6a)" at the 9 → 10 history.
- [ ] **Step 4:** Run `./scripts/test.sh core` and `./gen.sh && ./scripts/test.sh` → PASS. Add the Map row and raise the ceiling.
- [ ] **Step 5:** Commit: `core: figure op kinds and payload on the shared envelope (report plan 6a Task 1)`.

### Task 2: The figure document class, the registry and the permit rows (Core)

**Files:** Core `DocumentClass.swift`, `ProjectManifest.swift` (`figures: [FigureRecord]?`), new `Table/FigureRecord.swift`, `Permit.swift` (`refused`, `row`, `authors`, `maySignTasks`, `RefusedWhat.figure` + phrasebook), `OpLogPermitContext.swift` (both `resolve` callers + `ManifestPlacement`), `Posture.swift` (`Verb.editFigure`, `probe` arm), the Mac `DocumentStore+Posture.swift` and `ProjectStore+Annotations.swift` callers. Tests: `PermitTableTests` (extend) and `FigureClassTests.swift`.

**Interfaces — Produces:**
- **`public struct FigureRecord: Codable, Equatable, Sendable { id, name, kind: FigureKind, piece: String?, path: String }`**, where `path` is project-relative (`figures/<name>.csv` or `figures/<file>`).
- **`ProjectManifest.figures: [FigureRecord]?`**, nil when empty and encoded only when non-empty, so a manifest with no figures keeps its bytes.
- **`DocumentClass.figure(id: String, piece: String?)`** and `DocumentClass.figureDocIdPrefix = "fig"`. Resolution:
  - a registry hit → `.figure(id, piece: record.piece)`;
  - a `fig-` id missing from the registry → `.figure(id, piece: nil)`;
  - `.piece` stays for everything else.
- **`Permit.authors(.figure(_, piece: p))`:**
  - a book author → true;
  - a piece author → `p ∈ mine` (nil → false);
  - a reviewer → false.
- **`RefusedWhat.figure`**, with the phrasebook line "Somebody changed a table or figure they may not edit".
- **`Verb.editFigure`** probes `.op(.figureCellSet)`.

- [ ] **Step 1:** Write the failing `PermitTableTests` rows:
  - book author: every figure kind allowed;
  - piece author of A: allowed on `.figure(id, piece: "A")`, refused on `piece: "B"` and on `piece: nil`;
  - reviewer: figure kinds refused, while annotation creation is allowed on a figure stream;
  - assistant: the reviewer row;
  - translator: figure kinds refused, `translationRecord` allowed.

  Plus `FigureClassTests`: resolution for a registry hit, a `fig-` id with no record, and a non-figure id; a manifest without figures encodes byte-identically.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement, growing every exhaustive `DocumentClass` and `RefusedWhat` switch. Grep `case .projectStream` and `case .statement` to find them all.
- [ ] **Step 4:** Run core and Mac → PASS. Add the Map row and raise the ceiling.
- [ ] **Step 5:** Commit: `core: figure document class from the manifest registry; figures belong to their piece (report plan 6a Task 2)`.

### Task 3: FigureDeriver and FigureInverse (Core)

**Files:** new `Table/FigureDeriver.swift` and `Table/FigureInverse.swift`. Tests: `FigureDeriverTests.swift` and `FigureInverseTests.swift`.

**Interfaces — Produces:**
- **`public struct FigureState: Equatable, Sendable`:** `kind: FigureKind?`, `table: FigureTable`, `image: FigureImageRef?`, `pins: [CellKey: [FigureResearchPin]]`, `parked: (path: String, hash: String)?` (as a small struct), `createdBy: String?` (device), `diagnostics: [String]` (ops that could not apply).
- **`public enum FigureDeriver { public static func derive(_ ops: [Op]) -> FigureState }`.** It is pure and folds in `OpLogStore`'s merged order (the order `loadDiagnosed`/`loadSyncMerged` return). Rules:
  - The first `figureCreate` sets the kind, and later creates are ignored, with a diagnostic.
  - A cell set on a deleted or unknown row or column is dropped from the view, kept in the ops, and gets a diagnostic. This is spec §11.5: delete beats edit.
  - Last-writer-wins per cell is the fold order.
  - Inserts replay through `FigureTable.insertRow(_:after:)`, so concurrent inserts both survive.
  - Moves and settings apply in order.
  - `figureParked` sets `parked`, and `figureResumed` clears it. Content ops while parked still fold, which can't happen through the UI but must not crash.
- **`public enum FigureInverse`:**
  - `inverse(of payload: FigureOpPayload, kind: OpKind) -> (OpKind, FigureOpPayload)?`. A cell set swaps `next` and `prior`; an insert becomes a delete; a delete has no inverse (nil) in 6a, because reviving a tombstone needs plan 6b's revive API, so the UI must not offer undo for a delete until then; a move becomes a move back via `priorAfter`; settings swap; an image swaps to `priorImage`.
  - `compensating(visit: [(OpKind, FigureOpPayload)]) -> [(OpKind, FigureOpPayload)]`: the reversed inverses, for plan 7's one-⌘Z visit.

- [ ] **Step 1:** Write the failing tests:
  - single-device folds of every kind;
  - two-device fixtures, built as two op arrays merged in a fixed order: different cells both survive; the same cell's later op wins; concurrent inserts after the same row both survive, in a stable order; delete column versus an edit in it means the column is gone and a diagnostic is recorded;
  - a create seen twice;
  - an inverse round trip for each invertible kind (apply then inverse = the original table);
  - `compensating` over a 5-op visit restores the table.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run core → PASS; add the Map rows and raise the ceiling.
- [ ] **Step 5:** Commit: `core: figure deriver folds ops onto the table — per-cell last writer, delete beats edit, concurrent inserts survive; figure inverses (report plan 6a Task 3)`.

### Task 4: FigureCache and the document workbook (Core)

**Files:** new `Table/FigureCache.swift`. Test: `FigureCacheTests.swift`.

**Interfaces — Produces:**
- **`@MainActor public final class FigureCache`**, on `DerivedManuscriptCache`'s token pattern: a sorted `(path, mtime, size)` over `opLogFileURLs(forDocId:in:)`.
  - `state(forFigureId:in projectURL:trust:) throws -> FigureState`;
  - `invalidate(figureId:)`.

  It reads through `OpLogStore.loadSyncMerged` exactly as `DerivedManuscript` does. It does not hand-roll a partition call (tripwire 45).
- **`public func workbook(for manifest: ProjectManifest, cache: FigureCache, projectURL: URL, trust: …, pins: ResearchPinSource) -> Workbook`.** It builds a `Workbook` keyed by each record's **name**, holding every table figure whose state is not parked. Plan 6b's rename keeps names and formulas in step.

- [ ] **Step 1:** Write the failing tests:
  - a second read with the files unchanged hits the cache (count loads through a seam);
  - appending an op invalidates it by token;
  - the workbook evaluates a cross-figure reference by name;
  - a parked figure is absent, and a reference to it is `#REF!`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS; add the Map row and raise the ceiling.
- [ ] **Step 5:** Commit: `core: figure cache and the document workbook by figure name (report plan 6a Task 4)`.

### Task 5: The schema floor learns figures (Core)

**Files:** Core `ProjectProfile.swift` (`contentSchemaFloor`) and `ProjectManifest.swift` docs. Tests: extend the schema tests (`grep -rn contentSchemaFloor Packages/MaughamCore/Tests`).

**Contract:**
- `contentSchemaFloor` returns 10 when `figures` is non-empty.
- A schema-9 book that gains a figure record encodes as 10.
- A schema-10 book with figures decoded by a decoder whose `currentSchemaVersion` is 9 throws `SchemaTooNewError`. Simulate it through the existing test seam the schema tests use; Review Focus 3.

- [ ] **Steps 1–5:** failing tests, implement, core and phone gates, commit `core: a book with figures needs schema 10 (report plan 6a Task 5)`.

### Task 6: The FigureDocument host and creating a figure (Mac)

**Files:** new `Maugham/OpLog/FigureDocument.swift` and `Maugham/Stores/ProjectStore+Figures.swift`; `Maugham/OpLog/AREA.md` and `Maugham/Stores/AREA.md` rows. Tests: `FigureDocumentTests.swift` (Mac).

**Interfaces — Produces:**
- **`@MainActor final class FigureDocument`:**
  - `static func load(figureId: String, projectURL: URL, actor: DeviceActor, session: String, presenter: NSFilePresenter?) async throws -> FigureDocument`. It goes through `OpLogStore.loadDiagnosed` with `IntegrityQuarantine` for skipped lines, then `FigureDeriver.derive`, and **emits no op**.
  - `state: FigureState` (observable).
  - Mutators, each guarded by `requireWritable("setCell")` (and so on) through the store's `localWritePermit` / `PostureDoor` (`Verb.editFigure`). Each appends one op with `prior` filled from the current state, registers undo through `OpUndoRegistrar` (target `self`, inverse from `FigureInverse`), and updates `state`:
    - `setCell(_ cell: Cell?, at: CellKey, undoManager: UndoManager?)`
    - `insertRow(after:)` / `insertColumn(after:)`
    - `deleteRow(_:)` / `deleteColumn(_:)` (no undo registration, per Task 3)
    - `moveRow(_:after:)` / `moveColumn(_:after:)`
    - `setHeaderRows(_:)` / `setTotalRow(_:)` / `setColumnWidth(_:_:)`
  - A refused mutation throws the store's existing refusal error, naming `RefusedWhat.figure`.
- **`ProjectStore.createFigure(kind: FigureKind, name: String, piece: String?, rows: Int = 3, columns: Int = 3) async throws -> FigureRecord`:**
  - asks posture for the target class;
  - mints `fig-xxxxxxxx` via `newId(prefix: "fig")`;
  - de-duplicates the name against the registry;
  - writes the record through the manifest door;
  - appends `figureCreate` plus the initial structure ops (inserting each row and column with its minted ids) as the acting actor.

  Names follow plan 5's bare figure-name rule where possible: a slug of letters, digits and `_`, and otherwise the name is stored as given; formulas quote it.

- [ ] **Step 1:** Write the failing tests (Mac, with `TestTemp`):
  - create, then load: the derived table is 3×3 with a header row of 0;
  - `setCell` appends one op whose `prior` is the old cell;
  - undo appends the inverse and restores it; redo re-applies;
  - an author of piece A loading a figure created in B: the mutators throw, and no op is appended;
  - a figure op from a piece-B-only device, read on a book-author device, is set aside (seed the stream as the narrowed actor and assert it is not in `state`), proving the partition sees `.figure`;
  - load emits zero ops.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run `./gen.sh && ./scripts/test.sh` → PASS; add the AREA rows and raise the ceilings.
- [ ] **Step 5:** Commit: `mac: figure documents — load without emitting, guarded cell and structure edits with undo, create a figure (report plan 6a Task 6)`.

### Task 7: The CSV render, the presenter route and the second-class sweep (Mac and phone)

**Files:** new `Maugham/OpLog/FigureRender.swift`; `DocumentStore.presenterDidChangeSubitem` (`.opLog` figure arm), `RemovedElsewhere.swift` (subtract figure ids), `CheckpointCapture.swift` (figure pointers, D-g), the `docIds(` callers in survey §12 that mean "manuscripts" (filter figure ids); `MaughamPhone/Annotations/AnnotationsStore.swift` (group figure notes under the figure's name). Tests: Mac `FigureRenderTests`; extend the `RemovedElsewhere` and checkpoint tests; a phone grouping test.

**Contract:**
- **`FigureRender.render(record:state:workbook:)`** writes `figures/<name>.csv` = `TableCSV.render` of the computed values, through `DocumentStore.coordinatedWrite`.
  - It runs on every figure op the open host appends, on host load, and on a presenter-reported change to the figure's stream.
  - It is **never read back**, so an Excel edit to the CSV is overwritten by the next render (Review Focus 4).
  - Image figures render nothing.
- **The presenter arm:** a change to `.maugham/ops/fig-*` invalidates `FigureCache`, reloads an open `FigureDocument`, and re-renders that figure plus every figure whose formulas name it (by workbook dependency).
- **`RemovedElsewhere`** never lists a figure id.
- **Checkpoints** record figure streams' pointers in `docPointers`.
- **Callers that walk "all manuscripts"** (search, word counts, `LoadBurstCensus`, and the others in survey §12) skip `fig-` ids.
- **The phone** groups figure-stream annotations under "Table: <name>" or "Figure: <name>" from the registry.

- [ ] **Steps 1–5:** failing tests (including "an edited CSV is overwritten and the table is unchanged"), implement, Mac and phone gates, commit `mac: figures render to figures/<name>.csv and follow edits from other devices; figures leave the manuscript sweeps (report plan 6a Task 7)`.

### Task 8: Censuses (tests only, plus AREA prose)

**Files:** `MaughamTests/TripwireGrepTests.swift` and the phone `TripwirePhoneGrepTest`; `docs/tripwires.md` rows 20, 38 and 52 (each gains one sentence naming figures); AREA guides.

**Contract:**
- **Tripwire 38:** `deviceArgumentsAtDocumentLoad` also parses `FigureDocument.load(`. Add a planted offender with a `device:` label, which fires, and a control.
- **Tripwire 52:** every `FigureDocument` mutator guard spelling is in `manuscriptWriterPatterns`, and every production caller (Task 6's `createFigure`; later plans add theirs) is in `manuscriptWriterCallSites` with "asks posture". The derived population must classify them all, and the test fails on an unclassified figure mutator. Prove it with a planted one.
- **Tripwire 20:** add a planted control: a production-shaped read of `figures/x.csv` with no `adr-0018-ok:` reason fires on Mac and on phone.
- **Tripwire 44+1:** assert `FigureDeriver.swift` never calls `Deriver.appliesToManuscript(`. This is already enforced by the named set; add a control.

- [ ] **Steps 1–5:** tests first (each planted offender fails the census, then passes when removed), the prose, Mac and phone gates, commit `tests: tripwires 20, 38 and 52 reach figure documents (report plan 6a Task 8)`.

### Task 9: Image figures (Mac)

**Files:** `FigureDocument` (`setImage`), `ProjectStore+Figures` (`createImageFigure(fromURL:name:piece:)`), `Maugham/Publish/FigureImageResolver.swift` (allow `figures/`), `Maugham/Editor/FigureIngest.swift` (target `figures/`). Tests: extend `FigureIngestTests` and `FigureImageResolverTests`, plus a `FigureDocument` image test.

**Contract:**
- **`createImageFigure`** copies the file into `figures/` through `DocumentStore.executeCopy` under a de-duplicated name, applying HEIC → PNG as `FigureIngest` does today. It writes the record and appends `figureCreate(kind: .image)` plus `figureImageSet { filename, contentHash: FigureImageResolver.contentHash }`.
- **`setImage(fromURL:)`** replaces the file and appends `figureImageSet` with `priorImage`, which is undoable.
- **`FigureImageResolver`** accepts `figures/` paths alongside research.
- **Drop, paste or Insert ▸ Figure** in the editor now creates an image figure in `figures/` and writes `![caption](figures/<file>){#fig:<name>}`. Existing research-backed figure lines keep resolving (spec §4.4).

- [ ] **Steps 1–5:** failing tests (including that a dropped PNG lands in `figures/`, its line points there, and the thumbnail resolves; and that an old `../research/x.png` line still resolves), implement, Mac gate, commit `mac: image figures live in figures/ with their file's hash in the op log (report plan 6a Task 9)`.

---

## After the last task

- Run `./gen.sh`, `./scripts/test.sh full` and `./scripts/test.sh phone`.
- The whole-branch review gets the ledger. Name these seams:
  - class resolution (Task 2) × partition on read (Task 6's set-aside test) × the phone grouping (Task 7);
  - deriver order (Task 3) × the cache token (Task 4) × the presenter reload (Task 7);
  - `requireWritable` spellings (Task 6) × tripwire 52 (Task 8);
  - the schema floor (Task 5) × the registry encoding (Task 2), where a book without figures must keep its bytes.
- Then write plan 6b against the built code (rule 11): Use in document, Send to Research with parked logs, figure rename, research pins, text-cell translations, research versions, checkpoint restore of figures, and the tombstone-revive API that undo of a delete needs.
