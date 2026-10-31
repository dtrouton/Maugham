# Report plan 9d — Claude writes Research tables; every save keeps a version — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude can create, write and read Research tables over MCP. Every save of a Research table — the writer's or the assistant's — keeps the previous version under `.maugham/research-versions/`. The table's inspector lists the versions, marks the assistant's, and offers "Restore previous version". A figure pinned to a table goes "changed" after a write, as it does today after any change.

**Architecture:** One Core `ResearchVersionStore` (write-once, per-device files, pruned per device). One door: `ResearchTableHost.write(_:)` is the only code that overwrites a Research CSV, so it keeps the on-disk bytes and sidecar first — a census pins that nothing else overwrites one and nothing else calls the store's `keep`. MCP writes and Restore go through the same host (`DocumentStore.openResearchTable`), so they are versioned by construction. The sidecar gains a tolerant `writtenBy`, so a version knows who wrote the bytes it replaced.

**Tech Stack:** Swift 6, MaughamCore, Maugham `Editor/ResearchTableHost`, `Stores/`, `MCP/`, `Views/` inspector.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §10.1 ("Research tables are writable by the AI", "Version history", "Effect on figures"), RULING-56 (`register/01-claims-ledger.json`). Survey with file:line for every name here: `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan9d-survey.md`.

## Global Constraints

- "Every save of a Research table, the writer's or the assistant's, keeps the previous version under `.maugham/research-versions/`; an assistant write is marked 'written by assistant'. The Research table's inspector lists the versions and offers 'Restore previous version'. Research notes are versioned later (RULING-56); files and images never are." (§10.1)
- "A write that changes a snapshotted source triggers the figure's 'changed' note. Nothing more." (§10.1)
- No file shared across devices through iCloud (tripwire 17): version files carry the writing device's slug and each device prunes only its own.
- Every synced path or name reaches the disk through `SafeRelativePath` (tripwire 58); directory listings use `DotfileScan` (hidden-flag safety).
- Moves and deletes of user content go through the typed mover (tripwire 14). Events through `MaughamEvent` (tripwire 21).
- MCP text through `MCPResponseBudget.enforce`; the tool list derives from `MCPToolCatalog.all`.
- Research is unsigned: "assistant" is a label, never a signature.
- Help describes only what ships (rule 7).

## Rulings made while writing this plan

- **The canvas Rewrite's Trash `.priorVersion` route stays as it is.** It covers research notes and palette cards, never tables; RULING-56 (Denver, 2026-10-30, later than the spec's §12 line) says notes are versioned later. Replacing it waits for note versioning. Cost if wrong: one task in a later plan. (Flagged to Denver.)
- **What a "save" is:** a writer's consecutive grid saves within one editing run (no gap over 10 minutes, same grid session) keep one version — the state before the run began. Every assistant write, every Restore, and the first save of each run keep one. Cost if wrong: a constant.
- **Retention:** the last 50 versions per table per device; each device prunes only its own files.
- **Versions follow the item id:** kept while the item is in the Trash (restoring brings them back), removed by an orphan sweep when the item is deleted for good, moved with the item on promote-to-project, not copied on duplicate.
- **Restore's undo is the version list** (Restore is itself versioned); it is not on the grid's ⌘Z.
- **`write_research_cells` may grow the table** (cells past the edge add rows/columns) and set header and total rows; it never deletes rows or columns.
- **`research:` references inside a Research table** compute only through pins, so they read empty or `#REF!` there; `read_research_table` says so.
- **The version store keeps whatever is on disk before each save**, outside edits included; the conflict notice and `.maugham/conflicts/` stay as they are.
- `read_research_table` is not added to `CompilerAllowlist` in this plan.

## Review Focus

1. A writer types in the Research grid for twenty minutes, then Claude writes cells: the version list shows one writer version (before the run) and one marked "before Claude's write" — not hundreds. Pin in Task 2.
2. A save that fails (disk full, permission) leaves no version that claims a state the table never reached. Pin in Task 2.
3. Two Macs editing the same table: each keeps its own version files; neither prunes the other's. Pin in Task 1.
4. Restore with the grid open on another window: the grid shows the restored table; the figure pinned to it shows "changed". Pin in Task 3.
5. Claude writes `=SUM(B2:B3)` into a new row past the edge: the table grows, the formula computes in `read_research_table`, and the grid shows it. Pin in Tasks 4–5.

---

### Task 1: The version store (Core)

**Files:** new Core `ResearchVersionStore.swift`; Core `ResearchTableSidecar` (tolerant `writtenBy: ResearchWriter?` with `.writer`, `.assistant`); `MaughamSidecarPath` (a `researchVersion` case); Stores AREA layout row (trim first — near cap); Core tests.

**Interfaces:**
- Produces: `ResearchVersionStore.keep(priorBytes: Data, priorSidecar: ResearchTableSidecar?, writtenBy: ResearchWriter?, itemId: String, device: DeviceSlug, at: Date) throws -> ResearchVersion`; `versions(itemId:) -> [ResearchVersion]` (newest first, all devices); `read(_ version:) throws -> (Data, ResearchTableSidecar?)`; `prune(itemId:device:keep: Int)` (own device only); `sweepOrphans(liveItemIds:device:)`. Files at `.maugham/research-versions/<itemId>/<stamp>-<deviceSlug>[-n].csv` + `.json`, written once (staged then moved), names via `SafeRelativePath`, listing via `DotfileScan`.
- [ ] Step 1: failing tests: keep/read round-trips bytes and sidecar; two devices' files coexist and `prune` touches only its own; a hostile item id is refused; a dot-hidden file is listed; duplicate stamps get `-n`.
- [ ] Step 2: implement; `./scripts/test.sh core`, `./scripts/test.sh`, `./scripts/test.sh phone`; commit.

### Task 2: The one door

**Files:** `Maugham/Editor/ResearchTableHost.swift` (keep before `performFileSave`; carry the author per save; the run rule), `Maugham/Stores/DocumentStore+…` as needed, `MaughamTests/TripwireGrepTests.swift` (census: one caller of `keep`, no other overwrite of a Research CSV; planted offender + control), tests.

**Interfaces:**
- Produces: `ResearchTableHost.write(_:by: ResearchWriter)` (the writer default); an assistant edit first flushes writer-dirty state so the two never share a save; the run rule per the ruling; the sidecar's `writtenBy` stamped on every save.
- [ ] Step 1: failing tests: Review Focus 1 (a run keeps one version; an assistant write keeps one marked by the prior author); a failed write keeps no misleading version (stage the version, commit it only after the file save succeeds — or keep the prior bytes, which are true, and say which); an outside change on disk is the version kept.
- [ ] Step 2: implement; commit after `./scripts/test.sh full`.

### Task 3: Restore

**Files:** `ResearchTableHost.swift` (`restore(_ version:)` — a whole-table replace as one edit with its sidecar, stamped `.writer`, itself versioned), `DocumentStore` entry that works with the grid open or closed, tests.
- [ ] Step 1: failing tests: restore with no grid open; restore with the grid open shows the restored cells; a pinned figure reads `sourceChanged` after restore; restoring keeps the replaced state as a version.
- [ ] Step 2: implement; commit after `./scripts/test.sh`.

### Task 4: MCP `write_research_cells`

**Files:** new `Maugham/MCP/Tools/ResearchTableTools.swift`; `MCPTool.swift` catalogue; `MCPProtocolHandlersTests` expected list; MCP AREA heading/contracts; tests.

**Interfaces:**
- Produces: `write_research_cells { project_id, item_id, cells: [{ a1, value?, format? }], header_rows?, total_row? }` — `value` in the machine form (`FigureAnnotationOps.suggestedCell`, the same as `add_suggested_change`; empty string clears), `format` the `CellFormat` JSON `read_figure` emits; cells past the edge grow the table; through `openResearchTable` → settle → set → flush `by: .assistant` → release. Unknown item, a non-table item, an unparsable value or an invalid A1 refuse with a clear message.
- [ ] Step 1: failing tests: values, formulas and formats land; growth past the edge; the version is marked assistant-written; a pinned figure goes "changed"; refusals.
- [ ] Step 2: implement; commit.

### Task 5: MCP `create_research_table` and `read_research_table`

**Files:** `ResearchTableTools.swift`, `MCPTool.swift`, tests; `FigureTools.swift` (generalise `ReadFigureTool.table` into a shared renderer both tools use).

**Interfaces:**
- Produces: `create_research_table { project_id, title, scope?, cells?, header_rows? }` (creates with initial content, no blank first version); `read_research_table { project_id, item_id, range? }` returning `read_figure`'s cell shapes with computed values (via `assembledFigures()` + `FigureWorkbook.overlay`), the text table, the budget with a `range` hint, and a note when a cell reads `research:` (computes only through pins).
- [ ] Step 1: failing tests: create then read round-trip; computed formula values; range; the research-reference note.
- [ ] Step 2: implement; commit after `./scripts/test.sh`.

### Task 6: The inspector's versions

**Files:** `Maugham/Views/InspectorResearchPanel.swift` (a table section: versions newest first with "written by assistant", "Restore previous version" and per-row Restore; hidden for view-only shares; listing off the main actor; refreshes on an observable revision), tests on the pure model.
- [ ] Step 1: failing tests: rows and labels from a version list; restore disabled for a view-only share; the list refreshes after a save.
- [ ] Step 2: implement; commit after `./scripts/test.sh`.

### Task 7: Versions follow the item

**Files:** Trash/restore, permanent delete (orphan sweep), promote-to-project (move the folder beside the promoted sidecars), duplicate (nothing copied) — the store paths the survey names; tests per edge.
- [ ] Step 1: failing tests for each edge.
- [ ] Step 2: implement through the typed mover where content moves; commit after `./scripts/test.sh full`.

### Task 8: Docs, register and gates

**Files:** `docs/guide/research.md`, `docs/guide/claude-desktop.md`, `docs/skills/maugham-bootstrap/SKILL.md`, MCP/Stores/Editor AREA lines (trim before adding where near the cap), register: a claim for versioning (naming its tests), RULING-56's note that tables are versioned in code; DocBudget numbers.
- [ ] Step 1: docs; `./scripts/test.sh core`, `full`, `phone`; Release build.
- [ ] Step 2: commit.
