# Report plan 7a — the figure card and its reserved space Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a table figure's line in the text shows a read-only card beneath it — the rendered table (first 12 rows, header, total, formats) — in room the editor reserves from the figure's row count, without disturbing typing. Image figures keep today's thumbnail. A table line numbers as a Table, in the editor and in Publish alike.

**Architecture:**
- **A card model and a card cache, never a disk read on the typing path.** A pure `FigureCardModel` is built from a figure's state and computed values. A main-actor `FigureCardCache` on the window holds one per registered table figure, filled off the typing path (on attach, when a figure host appends, when remote figure changes land, when the registry changes). The styler only ever reads the cache; a miss reserves a fixed placeholder height and settles when the fill lands.
- **One version counter through the control plane.** The cache bumps `EditorControl.figureCardVersion` (recipe "Add a control-plane input"); the coordinator re-applies `.paragraphStyle` with `addAttribute` to only the changed figures' lines. Whole-document and windowed paints read the same pure function of (line path → cached model), so they stay equivalent.
- **The card is a decoration, never an attachment.** A click-through overlay draws it in the line's reserved paragraph spacing (the `FigureThumbnailOverlay` pattern). The editor is TextKit 1 (`EditorSurface.swift`'s load-bearing `layoutManager` touch); all layout vocabulary here is NSLayoutManager line fragments.

**Tech Stack:** Swift 5.10, AppKit (TextKit 1), SwiftUI host, MaughamCore, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-24-figures-and-tables-design.md` §3.2, §6.1, §11 risk 1, §12 item 7. Survey of the built code (main @ 44b284f9): `/private/tmp/claude-501/-Users-denver-src-Maugham/8c05dd93-47a2-47c3-ad7c-76c4ec1f3832/scratchpad/plan7-survey.md`, sections A, C, D, H, I and "Misfits". Re-verify every line number.

## Global Constraints

- **Hard invariants** (CLAUDE.md): the card never writes the text binding (tripwires 3, 6, 7); a figure's state comes from the op log through `FigureCache` / open hosts, never `figures/*.csv` (tripwire 20).
- **Editor area rules** (`Maugham/Editor/AREA.md`): read before editing. A local `addAttribute` on one line never snaps scroll; a whole-document `setAttributes` does. No NSTextAttachment. The coordinator never observes `FigureDocument.state` on the typing path.
- **Rulings made writing this plan** (ledger them):
  - **R7a-1 numbering (survey M1):** a figure line whose label is `tbl:` numbers in the Tables list and is a valid `@tbl:` target — in `ReferenceIndex` AND `PublishResolution` (or one shared Core summary both use) in the same task, so `test_figureAndTableNumbersMatchPublishing` stays the parity pin. An image figure line with `tbl:` (or a table figure line with `fig:`) is a kind-mismatch, diagnosed in plan 7b; here it keeps today's behaviour.
  - **R7a-2 placeholder then settle (survey M5):** a figure not yet in the cache reserves a fixed placeholder height (today's thumbnail height) and its line re-lays out once when the fill lands. No disk read on the typing path, ever.
  - **R7a-3 broken cards (survey M14):** a figure line naming no registered figure (removed, unknown), two records sharing a path (ambiguous), or a parked figure draws a small labelled card ("Figure removed", "Two figures share this path", "In Research") at the placeholder height. Diagnostics for these come in 7b.
  - **R7a-4 the language seam (survey M15):** `FigureCardModel` takes a `language` and a `(figureId, rowId, columnId) -> String?` label lookup, unused (always nil) until plan 9 stores translations.
  - **R7a-5 measure, don't assume:** "only that paragraph re-lays out" is pinned by a counter on the layout manager (invalidated glyph ranges), not asserted from reasoning; TextKit 1 without non-contiguous layout repositions later fragments lazily — the test pins what the editor actually does and the budget it costs.
- **Census rule:** new censuses get a planted offender and a control; existing tripwires extend, never exempt.
- **Gates:** `./scripts/test.sh core` after Core changes; `./scripts/test.sh` after Mac changes; `./gen.sh` after adding a file; `./scripts/test.sh full` and `./scripts/test.sh phone` at the whole-branch review. A run ending only in "Test Case … started." was killed by another session's `xcodebuild`: re-run. A new suite styling through production typography calls `FontWarmup.ensure()` in `class setUp`. Windows only through `TestWindow`.
- **Area guides:** Editor AREA.md (room — check), Views/OpLog/Stores at the 8,000-word cap (move why-clauses to `docs/history/<area>.md` first). DocBudget ceilings by exact counts with `+N report plan 7a Task K:`.

## Review Focus

1. **Typing a burst in a long document with 30 table cards while a remote figure change lands mid-burst**: no `applyExternalText`, no caret or scroll jump, the per-keystroke path never fills the cache or re-applies a figure line's style, and the changed figure's line re-lays out once after the burst settles. Tasks 3–5, 7.
2. **A table grows from 3 to 40 rows on another device**: its card shows 12 rows and "+ 28 more rows", its reserved room grows, text below moves down once, and the windowed and whole-document paints agree. Tasks 1, 4, 5, 7.
3. **A document whose lines are written `../../figures/x.csv` from `pieces/<id>/`**: the line resolves to its record (same rule as Publish's figure-path check, lexical half), case-insensitively; two records on one path draw the ambiguous card. Task 2.
4. **A table figure line `{#tbl:cash}` and `@tbl:cash` in the text**: the editor numbers it "Table 1", the cross-reference resolves, and Publish numbers it the same with no `labelOnWrongElement`. Task 9.
5. **Open a project, then close it while fills are in flight**: no crash, no fill landing on a detached coordinator, no leaked figure hosts. Tasks 3, 4.

---

### Task 1: The card model (Core)

**Files:** new Core `Table/FigureCardModel.swift`; Core `AREA.md` Map row. Tests: new Core `FigureCardModelTests.swift`.

**Interfaces — Produces:** `FigureCardModel` (Equatable, Sendable): `kind` (`.table`, `.image`, `.removed`, `.ambiguous`, `.parked`), `headerRows: [[String]]`, `bodyRows: [[String]]` (≤ 12 total rows shown), `moreRows: Int`, `hasTotalRow`, `columnAlignments`, flags `readsResearch`, `pinChanged`, `fromResearchSource`. `FigureCardModel.build(state:values:locale:language:labelLookup:) -> FigureCardModel` (pure). `FigureCardLayout.height(for model:, columnWidth:, font metrics) -> CGFloat` (pure; placeholder height for non-table kinds and the cache-miss case = today's `FigureThumbnailLayout.reservedHeight`).

**Contract:** values come from the computed workbook (`Workbook.value(at:)`) formatted with `CellDisplay.string(for:format:locale:)`; error cells show their error text; R7a-4's label lookup is applied to text cells when non-nil. Height is a pure function of the model and column width.

- [ ] Write failing tests: 3-row table; 40-row table → 12 shown + "+ 28 more rows"; header and total rows; an error cell; formats (currency, percent, date) under en-GB and de-DE; height monotonic in shown rows and constant past 12.
- [ ] Run red; implement; `./scripts/test.sh core`; commit.

### Task 2: A figure line finds its figure (Core + Mac Publish split)

**Files:** `Maugham/Publish/FigureImageResolver.swift` (split out the lexical half as a public entry, unchanged behaviour); new resolution helper (Core if pure, else Editor); tests in `FigureImageResolverTests` and a new `FigureLineResolutionTests`.

**Interfaces — Produces:** `FigureImageResolver.lexical(_ path: String, piecePath: String) -> LexicalOutcome` (string-only, no disk); `FigureLineResolution.record(forLinePath:documentPath:records:) -> Resolution` with `.figure(FigureRecord)`, `.none`, `.ambiguous([FigureRecord])` — standardised against the document's folder, matched case-insensitively to `FigureRecord.path`.

**Contract:** the same lexical rule Publish uses (so 7b's F9 diagnostic shares it); never the weaker dead `ManuscriptIndex` rule (audit E3). Publish's existing resolver tests stay green unchanged.

- [ ] Write failing tests: Review Focus 3; a root-level document; `./figures/x.csv`; percent-encoded names; a path escaping the project → `.none`.
- [ ] Run red; implement; `./scripts/test.sh core`, `./scripts/test.sh`; commit.

### Task 3: The card cache (Mac)

**Files:** new `Maugham/Editor/FigureCardCache.swift` (or Views beside `ReferenceIndexHost` — follow where the window's providers live); `Maugham/Stores/DocumentStore+Figures.swift` (fill triggers: `figureHostAppended`, `applyPendingFigureChanges`, registry change); tests `FigureCardCacheTests`.

**Interfaces — Produces:** `@MainActor final class FigureCardCache` with `model(forFigureId:) -> FigureCardModel?` (sync, memory only), `version: Int` (bumps once per fill batch), `changedSinceLastRead: Set<String>` or equivalent so the coordinator knows which lines to touch, `fill(…) async` (off the typing path: assembles values via `DocumentStore.assembledFigures()` or cheaper incremental reads, builds models).

**Contract:** never reads disk from `model(forFigureId:)`; fills coalesce (a burst of remote changes → one fill, one version bump); a fill that lands after detach/close is dropped; tracks parked/removed/ambiguous per R7a-3.

- [ ] Write failing tests: a fill bumps version once for several changes; a miss returns nil without I/O (assert via a counting seam); a late fill after close is dropped; a removed figure becomes `.removed`.
- [ ] Run red; implement; `./scripts/test.sh`; commit.

### Task 4: The control-plane input and the styler (Mac Editor)

**Files:** `Maugham/Editor/EditorControl.swift` (`figureCardVersion`), the three hosts that write `EditorControl` (`EditorControlMirror.swift`, `ResearchNoteEditor.swift`, `StatementEditorHost.swift`) per the recipe; `EditorCoordinator` (provider closure + `applyControl` guard); `ProseMode.reserveFigureThumbnailSpace` takes `figureRoom: (String) -> CGFloat`. Tests: `WindowedTypographyEquivalenceTests` (data-derived height cases), `FigureThumbnailTests` (image room unchanged).

**Contract:** follow the Editor AREA recipe "Add a control-plane input" exactly (D1: the counter moves at a settle edge; values stay behind a provider). Image figures keep `reservedHeight`; table figures take `FigureCardLayout.height` from the cached model; a miss takes the placeholder (R7a-2). Both paints read the same closure.

- [ ] Write failing tests: windowed ≡ whole-document with three table lines of different row counts; an image line's room unchanged; a cache miss reserves the placeholder.
- [ ] Run red; implement; `./scripts/test.sh`; commit.

### Task 5: Re-lay out only the changed lines (Mac Editor)

**Files:** `EditorCoordinator` (new `setFigureCardVersion(_:)` modelled on `setReferenceIndexVersion(_:)`); storage-edit observers (`observeStorageEdits`, `TableAnchorTracker`, `FigureAnchorTracker`) verified to ignore attribute-only edits; trailing-figure room (`holdTrailingFigureRoom`) re-asserted. Tests: harness tests.

**Contract:** on a version change, `addAttribute(.paragraphStyle…)` inside `beginEditing/endEditing` on only the changed figures' line ranges (no `setAttributes`); never during a typing burst — defer to the settle edge the deferred restyle already uses; no scroll snap; no caret move; observers gated on `.editedCharacters` do nothing.

- [ ] Write failing tests: Review Focus 1 and 2 at the coordinator level; a layout-manager delegate counter shows invalidation limited per R7a-5 (pin the measured behaviour); the trailing figure keeps its room when it grows.
- [ ] Run red; implement; `./scripts/test.sh`; commit.

### Task 6: Drawing the card (Mac Editor)

**Files:** `Maugham/Editor/FigureThumbnailOverlay.swift` (table cards beside image thumbnails, or a sibling click-through `FigureCardOverlay`); `FigureThumbnailStore` stops treating `.csv` as a missing image. Tests: `FigureThumbnailTests` mounted cases (through `TestWindow`), a pure drawing-plan test.

**Contract:** click-through (`hitTest` → nil); draws at the line's last fragment bottom like thumbnails; header row bold, total row ruled, alignments honoured, "+ N more rows"; flags drawn as a tinted corner (Research source), an amber banner (pin changed), and the R7a-3 labelled cards; alpha follows the focus dim as thumbnails do. Gestures (expand) are plan 7c — none here.

- [ ] Write failing tests: a pure drawing plan for a model (rows, rules, banner) and a mounted test that a table line no longer shows "Image not found".
- [ ] Run red; implement; `./scripts/test.sh`; commit.

### Task 7: Harness and the typing budget (Mac tests)

**Files:** `MaughamTests/Editor/EditorIntegrationHarnessTests.swift` (new cases), `MaughamTests/Performance/` (new fixture-free figure-heavy budget). 

**Contract** (R7a-5): a counter-based budget — during a burst of N keystrokes in a document with 30 table cards, the card cache's fill count and figure-line style re-applications are zero until the settle edge; plus a ratio test (figure-heavy vs plain corpus tokenize/style) with a generous ceiling. Review Focus 1 end to end with the real `EditorIntegrationHarness`.

- [ ] Write the tests; run them (they should pass against Tasks 3–5 — if one fails, fix the code, not the test); `./scripts/test.sh`; commit.

### Task 8: The decoration census (Mac tests)

**Files:** `MaughamTests/TripwireGrepTests.swift`; `docs/tripwires.md` only if a new row is warranted (ask maugham-issues for the number first); Editor AREA.md rule text.

**Contract:** a derived census over `Maugham/Editor/`: no `NSTextAttachment` and no U+FFFC; `paragraphSpacing +=` (or any `paragraphSpacing` write) only in `ProseMode.reserveFigureThumbnailSpace`. Planted offender + control in `TestTemp.root`, following the existing census pattern.

- [ ] Write the census and its control; run red with a planted offender; green; `./scripts/test.sh`; commit.

### Task 9: A table line numbers as a Table (Mac Editor + Publish)

**Files:** `Maugham/Editor/ReferenceIndex.swift` (`build`), `Maugham/Publish/PublishResolution.swift`, `Maugham/Editor/ManuscriptChecks.swift` (`elementKind(ofLineAt:in:)`), or a shared Core summary both consume. Tests: `ReferenceIndexTests`, `PublishResolutionTests`.

**Contract** (R7a-1): a figure line with a `tbl:` label registers as a table (numbered in the Tables list, a valid `@tbl:` target); with `fig:` as today. Editor and Publish agree (`test_figureAndTableNumbersMatchPublishing`). No other publishing change (emitting figure tables is plan 9).

- [ ] Write failing tests: Review Focus 4; a mixed document (pipe table, table figure, image figure) numbers Table 1, Table 2, Figure 1 in both.
- [ ] Run red; implement; `./scripts/test.sh`; commit.

## After the last task

- Whole-branch review (give it the ledger; name the seams: Task 3 × DocumentStore's figure change paths and window/project close; Task 4 × the three EditorControl hosts; Task 5 × the deferred restyle and scroll rules; Task 6 × focus dim and translation dimming temporaries; Task 9 × Publish parity).
- `./scripts/test.sh full`, `./scripts/test.sh phone`.
- Report to Denver with the smoke item (open a report with table figures, type around them, edit a figure on another Mac). Then write 7b–7e against the built 7a, with Denver's rulings on the open questions (Convert's undo, cell suggestions' home, expanded-grid height, the shortcuts, the pop-out window's lifetime).
