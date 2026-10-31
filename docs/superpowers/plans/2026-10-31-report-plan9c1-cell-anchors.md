# Report plan 9c-1 — notes and suggestions anchored to figure cells — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude can anchor a comment, query, craft note or suggested change to a figure, a cell or a range (`tbl:cashflow`, `tbl:cashflow!C3`, `tbl:cashflow!C3:E3`); the anchor follows inserts and orphans when its cells are deleted; the author can accept a cell suggestion (writing the cell as the author, attribution recorded), reject, stet, archive or reopen it; every annotation surface shows the anchor honestly. Dots, the strip in the grid and travel-to-cell are plan 9c-2.

**Architecture:** The wire shape exists since plan 6a: a figure note lives in the figure's own op-log stream (docId = figure id), and `Op.Provenance` carries `figureRowId`, `figureRowEndId`, `figureColId`, `figureColEndId`. This plan projects them: a Core `FigureCellAnchor` on `Annotation`, resolved against the figure's `FigureTable` (A1 address, or orphaned → `isStale`), and a suggested cell carried as `Op.figure` (`FigureOpPayload`, a typed `Cell` by ids) on the `claudeSuggestion` op. Accept is one `claudeAccept` op carrying the cell, which both `FigureDeriver` (cell) and `AnnotationDeriver` (status) fold — atomic, like a manuscript accept. No new `OpKind`, no schema bump.

**Tech Stack:** Swift 6, MaughamCore (`Annotation*`, `Table/`), Maugham `OpLog/FigureDocument`, `Stores/`, `MCP/`, `Views/Review`, MaughamPhone `Annotations/`.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §6.5, §10.1 ("Figure anchors", "Use and send-back"), §12 item 9. Survey with file:line for everything named here: `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan9c-survey.md`.

## Global Constraints

- "Anchors are stored by row and column id, so they follow inserts, and they are orphaned when their cells are deleted. A suggested change carries a new value or formula, and the author accepts it in the grid." (§10.1)
- "Accepting writes the cell as the author, with the suggestion's attribution recorded." (§6.5)
- "MCP never mutates manuscript text directly": Claude only creates annotations; every disposition and every cell write is the author's (CLAUDE.md hard invariant; spec "Figures are read-only to the AI").
- Annotation behaviour is filed in `register/reconciliation/Annotations.claims.json` / `.filings.json`: read the filings before changing `AnnotationDeriver`. RULING-5 (refuse an AI change whose anchor is gone), RULING-22 (withdrawn guard), RULING-31 (rejection reason kept) hold for figure notes.
- Undo follows ADR 0023 (append-only compensation).
- Anchor resolution, suggestion display and op builders live once in Core (tripwire 19). Read cells from op logs only (tripwire 20). Events via `MaughamEvent.postAnnotationsChanged` (tripwire 21). MCP responses via `MCPResponseBudget.enforce` (tripwire 10).
- A new guarded `FigureDocument` verb is classified in `guardedDocumentMutators` and `figureMutatorSpellings`, its callers in `manuscriptWriterCallSites` (tripwire 52). No new `Deriver.appliesToManuscript` caller (tripwire 44); `FigureDeriver` keeps never asking it.
- Help describes only what ships (rule 7): no dots, strip or travel-to-cell until 9c-2.

## Rulings made while writing this plan

- **`add_note` is a Research tool**, a slip in spec §10.1's list. The anchored tools are `add_comment`, `add_query`, `add_suggested_change`, and `add_craft_note` (whole figure only).
- **Accept is one op** (survey §1.6 option B): `claudeAccept` with `Op.figure` = the cell set (`next`, `prior`) and `provenance.sourceAnnotationId`; its undo is `claudeAcceptRevert` carrying the inverse cell. Cost if wrong: two filters in figure derivation.
- **A suggested change anchors one cell.** Comments and queries may anchor a range or the whole figure.
- **A range stays by its corner ids** and is orphaned when any corner's row or column is deleted. It does not follow sorts or moves (annotations are notes, not formulas). Cost if wrong: one resolver change.
- **Claude writes a suggested value in machine form:** numbers with `.` decimal and no grouping; a formula starts with `=` and uses A1 references by current positions (converted to ids at creation, as the grid does). Parsed with `FigureCellEntry` under a fixed POSIX-style `TableLocale`. `read_figure`'s `raw` uses the same number form.
- **Figure notes count on the review board against their figure's piece** (`FigureRecord.piece`); a whole-book figure's notes count nowhere new (they stay in the project queue).
- **Queue verbs on a figure row:** Reject, Stet, Archive, Reopen and Reply work from the queue (no grid needed). Accept is grid-only (9c-2 adds the strip); in 9c-1 the queue's Accept on a figure suggestion is disabled with the reason "Accept it in the table". The phone never offers Accept on a figure suggestion.
- **MCP figure notes get no review-pass stamp** (a figure has no open `Document`); unstamped notes appear in every pass's queue, as other unstamped notes do.
- **"Use and send-back reach the author only as suggestions"** is met by a whole-figure comment: no tool moves figures, and no new suggestion shape is added.
- **Promotion does not carry figure notes** (figure history stays in the Collection, as the manuscript's does). The AREA says so.

## Review Focus

1. A suggestion anchored to C3, then a row inserted above row 3: the anchor reads C4 and Accept writes C4. Pin in Task 1 (resolver) and Task 5 (accept).
2. The anchored row deleted, then the delete undone: orphaned, then live again (revive keeps the id). Pin in Task 1.
3. Accept when the cell has changed since the suggestion (its `prior` differs): the author is asked to confirm, never silently overwritten; accept on an orphaned anchor is refused (RULING-5); accept on a parked figure is refused. Pin in Task 5.
4. Undo of an accept restores the old cell AND reopens the suggestion, in one step, including when the accept happened inside an open grid visit. Pin in Task 5.
5. An MCP note created while the figure is open in the grid on that Mac reaches the open host (no lost write, no stale fold). Pin in Task 3.

---

### Task 1: The anchor and the suggested cell, projected (Core)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/Table/FigureCellAnchor.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Annotation.swift`, `AnnotationDeriver.swift`, `AnnotationAggregation.swift`; Mac `Maugham/Stores/ProjectStore+Annotations.swift` (`figureAnnotations`); phone `MaughamPhone/Annotations/AnnotationLoading.swift`; Core `AREA.md`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/FigureCellAnchorTests.swift`

**Interfaces:**
- Produces:
  - `public struct FigureCellAnchor: Equatable, Sendable { row: RowID; rowEnd: RowID?; column: ColumnID; columnEnd: ColumnID? }` with `public enum Resolution: Equatable { case live(a1: String), orphaned }` and `public func resolve(in table: FigureTable) -> Resolution` ("C3" or "C3:E4"; orphaned when any named row or column is deleted or unknown).
  - `Annotation.figureAnchor: FigureCellAnchor?` (nil = whole figure, or not a figure note), `Annotation.suggestedCell: Cell?`, `Annotation.figureAddress: String?` (the live A1, nil when orphaned or whole-figure). Orphaned sets the existing `isStale`. All defaulted init parameters.
  - `AnnotationAggregation.allAnnotations(ops:paragraphs:amendments:figureTable: FigureTable?)` — the figure table is derived by the caller from the same stream (`FigureDeriver.derive` over the figure kinds); the Mac walk and the phone loader pass it.
- [ ] Step 1: failing tests: an op with the four scalars derives `figureAnchor`; `resolve` gives "C3", then "C4" after a row insert above, `.orphaned` after the row's delete, "C3" again after its revive; a range is orphaned when one corner column is deleted; a `claudeSuggestion` carrying `Op.figure.next` derives `suggestedCell`; a figure note with no scalars has `figureAnchor == nil`.
- [ ] Step 2: implement; read the Annotations filings first and note in the report which claims the change touches.
- [ ] Step 3: `./scripts/test.sh core`, `./scripts/test.sh`, `./scripts/test.sh phone`; commit.

### Task 2: Figure annotation op builders and the anchor parser (Core)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/Table/FigureAnnotationOps.swift`, `.../Table/FigureAnchorAddress.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/FigureAnnotationOpsTests.swift`

**Interfaces:**
- Consumes: Task 1 types; `FigureGridAddress.cell(_:in:)` / `.range(_:in:)`; `FigureCellEntry.cell(from:prior:table:names:locale:)`.
- Produces:
  - `public enum FigureAnchorAddress { public static func parse(_ text: String) -> (label: String, cells: String?)?; public static func anchor(_ cells: String, in table: FigureTable) -> Result<FigureCellAnchor, Error> }` — `tbl:cashflow!C3:E3` → (`tbl:cashflow`, `C3:E3`); A1 by current positions → ids.
  - `public enum FigureAnnotationOps` builders returning `Op` for: creation (`kind`, `figureId`, `anchor: FigureCellAnchor?`, `body`, `suggestedCell: Cell?` with `prior: Cell?`, `author`, `device`, `language`), accept (`annotationId`, `cell: CellKey`, `next: Cell?`, `prior: Cell?` — a `claudeAccept` with `Op.figure` and `sourceAnnotationId`), accept-revert (the inverse), reject (with reason), stet, archive, reopen. One implementation for Mac and phone.
  - The suggestion's machine-form value parser: `public static func suggestedCell(from text: String, at key: CellKey, table: FigureTable, names: FormulaNames) -> Result<Cell?, FormulaParseError>` using a fixed POSIX `TableLocale`.
- [ ] Step 1: failing tests: parse forms (`tbl:x`, `tbl:x!C3`, `tbl:x!c3:e3`, junk → nil); anchor of an out-of-range cell → error; `"1234.5"` → number, `"=SUM(B2:B3)"` → formula by ids; each builder's op round-trips through `AnnotationDeriver` to the right status.
- [ ] Step 2: implement; commit after `./scripts/test.sh core`.

### Task 3: The store writes a figure note

**Files:**
- Modify: `Maugham/Stores/DocumentStore+Figures.swift` (or a new `DocumentStore+FigureAnnotations.swift`), `Maugham/Stores/AREA.md`
- Test: `MaughamTests/Stores/FigureAnnotationWriteTests.swift`

**Interfaces:**
- Consumes: Task 2 builders.
- Produces: `DocumentStore.addFigureAnnotation(_ op: Op) async throws` — appends on the figure stream signed by the op's device (the assistant's for MCP); through the open `FigureDocument` when one is held so its fold sees it, else a windowless `OpLogStore` append; posts `MaughamEvent.postAnnotationsChanged(docId: figureId, projectURL:)`; invalidates the figure cache and cards (`figureHostAppended`'s path). Refuses a parked figure.
- [ ] Step 1: failing tests: windowless write appears in `ProjectStore.figureNotes`; with the figure open in a host, the host's state and the note both see it and a later host write doesn't drop it; the event fires once with the figure id; the assistant device signs it (the file is the `.assistant-` stream).
- [ ] Step 2: implement; commit after `./scripts/test.sh`.

### Task 4: MCP creates figure-anchored notes

**Files:**
- Modify: `Maugham/MCP/Tools/AnnotationCreationTools.swift`, `Maugham/MCP/Tools/AnnotationToolHelpers.swift`, `Maugham/MCP/AREA.md`
- Test: `MaughamTests/MCP/Tools/FigureAnnotationCreationTests.swift`

**Interfaces:**
- Consumes: Task 2 parser/builders, Task 3 writer; `ReadFigureTool.find(_:in:)` and `publishFigures()` for the figure (windowless).
- Produces: `add_comment`, `add_query`, `add_suggested_change` take optional `figure` (`tbl:x`, `tbl:x!C3`, `tbl:x!C3:E3`); when given, `document_id`/`paragraph_id` are not required (drop them from `required`; the handler requires one anchor form). `add_suggested_change` with `figure` requires a single cell and takes `suggested_value` (machine form) instead of `suggested_text`. `add_craft_note` takes `figure` with no cells. Errors: unknown figure (nearest names), kind mismatch (`fig:` on a table), cell out of range, orphaned/deleted cell, a range on a suggestion, a parked figure, an unparsable value (the parser's message).
- [ ] Step 1: failing tests per form and per error; a created suggestion derives `suggestedCell` and the right anchor; nothing writes `figures/*.csv`; the paragraph forms behave exactly as before (existing tests green).
- [ ] Step 2: implement; update the tool descriptions and AREA contracts; commit after `./scripts/test.sh`.

### Task 5: The author disposes of a figure note (`FigureDocument`)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Table/FigureDeriver.swift` (fold `claudeAccept`/`claudeAcceptRevert` that carry `Op.figure`), `FigureInverse.swift`, `Maugham/OpLog/FigureDocument.swift` (+ split file if it grows), `FigureReturnDiff`/`FigureVisit` as needed, `MaughamTests/TripwireGrepTests.swift` (census rows only), `Maugham/OpLog/AREA.md`
- Test: `MaughamTests/OpLog/FigureAnnotationDispositionTests.swift`

**Interfaces:**
- Consumes: Task 2 builders; posture `.acceptOrReject` and `.editFigure`; `requireDispositionPermitted`-equivalent for the figure class.
- Produces: `FigureDocument.acceptSuggestion(id: String, confirmChanged: Bool, undoManager: UndoManager?) async throws`, `rejectAnnotation(id:reason:undoManager:)`, `stetAnnotation(id:undoManager:)`, `archiveAnnotation(id:undoManager:)`, `reopenAnnotation(id:undoManager:)`. Accept: refuses orphaned (RULING-5), withdrawn (RULING-22), parked, or not permitted; throws a typed `cellChangedSinceSuggestion` unless `confirmChanged` when the cell's current content differs from the suggestion's `prior`; writes one `claudeAccept` (cell + status), signed by the author. Undo appends the inverse `claudeAcceptRevert` (cell back, note reopened) as one step — including inside an open grid visit (the visit's fold-time undo must compensate both). Reject/stet/archive/reopen ask the disposition posture, not `.editFigure`.
- [ ] Step 1: failing tests: accept writes the cell, resolves the note, and the op carries `sourceAnnotationId`; accept after an insert writes the shifted cell; changed-since → throws, then `confirmChanged: true` writes; orphaned/parked/withdrawn refused; undo restores cell and reopens; undo inside a visit then fold leaves both consistent; reject keeps its reason; a reviewer (no author permit) is refused. Census rows for the new verbs and callers.
- [ ] Step 2: implement; commit after `./scripts/test.sh full`.

### Task 6: MCP reads figure-anchored notes

**Files:**
- Modify: `Maugham/MCP/Tools/AnnotationReadTools.swift`, `Maugham/MCP/AREA.md`
- Test: `MaughamTests/MCP/Tools/FigureAnnotationReadTests.swift`

**Interfaces:**
- Produces: `list_annotations` and `get_annotation` accept a figure (`figure: "tbl:x"`, or the figure id as `document_id`) and return, for a figure note, `figure_anchor` (`tbl:x!C4` by current positions, or the label alone), `orphaned`, and for a suggestion `suggested_cell` (`{ value, formula?, raw }` in `read_figure`'s shapes). `list_annotations` for a document also lists notes on the figures its text uses (marked with `figure_anchor`).
- [ ] Step 1: failing tests: a suggestion on C3 reads `tbl:x!C3`, and `tbl:x!C4` after an insert; an orphaned one reads `orphaned: true`; status after accept is `accepted`.
- [ ] Step 2: implement; commit.

### Task 7: The queue, the board, the inspector and the phone tell the truth

**Files:**
- Modify: `Maugham/Views/Review/AnnotationRow.swift`, `AnnotationListView.swift`, `AnnotationScope.swift` (verbs and reasons for figure rows), `Maugham/Stores/ProjectStore+Annotations.swift` (`openNotesSummaries`: figure notes count against `FigureRecord.piece`), `Maugham/Views/FigureInspector.swift` (notes show their address), `Packages/MaughamCore/Sources/MaughamCore/SuggestionDisplay.swift` (figure arm), `MaughamPhone/Annotations/AnnotationDetailView.swift`, `PhonePosture.swift`/`AnnotationWriter.swift` (no Accept on a figure suggestion; Reject/Archive through Task 2's builders)
- Test: `MaughamTests/Views/FigureAnnotationRowTests.swift`, `MaughamTests/Stores/OpenNotesFigureCountTests.swift`, `MaughamPhoneTests/FigureAnnotationDetailTests.swift`, Core `SuggestionDisplayTests` additions

**Interfaces:**
- Produces: a figure row shows "C3 · Table: name" (or "cells deleted" when orphaned) and the suggested cell's display text; Reject/Stet/Archive/Reopen/Reply route to Task 5's verbs through a transient host (`DocumentStore.withFigureHost`); Accept on a figure suggestion is disabled with "Accept it in the table". `SuggestionDisplay` gives before/after cell text for a figure suggestion. The board counts a piece-owned figure's open notes on that piece.
- [ ] Step 1: failing tests for each surface (pure row/plan models, not pixels); the phone's Accept is absent for a figure suggestion and present for a paragraph one; the phone's Reject writes a valid op on the figure stream.
- [ ] Step 2: implement; commit after `./scripts/test.sh` and `./scripts/test.sh phone`.

### Task 8: Docs and the gates

**Files:**
- Modify: `Maugham/MCP/AREA.md` (contracts), `docs/guide/claude-desktop.md`, `docs/guide/annotations-and-suggestions.md` (figure notes: what Claude can anchor, what the author can do from the queue; Accept from the table arrives with 9c-2 — say only what ships), `docs/skills/maugham-bootstrap/SKILL.md`, `docs/superpowers/notes/cross-surface-contracts.md`, Stores/OpLog AREA (promotion does not carry figure notes), register claims touched by Task 1/5 (claims updated, filings flipped if a filed defect is fixed), DocBudget ceilings (numbers only)
- [ ] Step 1: docs; `./scripts/test.sh core`, `./scripts/test.sh full`, `./scripts/test.sh phone`; Release build.
- [ ] Step 2: commit.
