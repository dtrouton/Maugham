# The references shelf and the study column — design

**Date:** 2026-08-25 · **Status:** approved by Denver in conversation ("go"); built on branch `claude/references-shelf-2026-08-25` — all four findings fixed, docs moved with the code. See `docs/roadmap.md`'s dated entry for what shipped and `docs/guide/right-pane.md` (§References mode) / `docs/guide/compiler.md` (§"References, and what you can study") for the writer-facing surface.
**Amends:** `2026-07-25-mode-based-ux-redesign-design.md` §"Referencing — pinned, promotable"; `2026-08-04-m2-author-compiler-design.md` §6.2; `2026-07-25-planning-canvas-design.md` §8A.3 (the canvas collapse — not `2026-08-01-persona-shell-workflow-design.md`, which cites §8A.3 but does not contain it)
**Constitution:** *the words are safe* is untouched; this is about the writer being able to SEE what they pinned and still have a column to write in.

## 1. What Denver saw

Writing a Collection in Author with a chapter whose material was clustered in a region on the canvas and promoted to one research note:

1. The References shelf (⌘⌥E) showed every scrap of the region as a flat, alphabetised list — no region name, no order — and **did not show the note the region had become**.
2. Clicking a pin opened it in a **fourth column between binder and prose**, leaving almost nothing to write in.
3. The studied note had **no line breaks**: the lines the writer had typed in each scrap ran together.
4. On the canvas, ⌘\ hid the binder but the right column went **blank and roughly doubled in width**, squeezing the canvas.

Four findings, one milestone. Each is traced below to the line that produces it; none is a design the code failed to implement — two are designs that were wrong, two are gaps nothing measured.

## 2. The pinned projection is incomplete and structureless

`PinnedReferences.pinned(forDocId:links:scene:scraps:items:)` (`Maugham/Compiler/PinnedReferences.swift`) unions **`linkedResearchIds`** with **`RegionBinding.references(forPiece:in:)`** (residents of every region bound to the piece, plus self-bound cards), sorts the canvas half by title, and returns a flat `[PinnedReference]`.

**2.1 The missing source.** `linkedResearchIds` is the research record of a *Novel* chapter only. In a Collection, `ResearchScope` routes a loose piece's research by **containment** (`.pieceFolder` — the note lives under the piece's own `research/`), and in a single-document project by derivation (`.sharedOnly` — every asset is the document's). Neither writes a link. `ProjectStore.derivedResearchItems(forDocumentId:)` (`Maugham/Stores/ResearchScope.swift`) already answers all three project types with the flattened asset list; the pinned projection never asks it. So the shelf, the study column and **the compiler's briefing** — three readers of one projection — are complete for Novels and silently short for everything else.

**2.2 The missing structure.** The canvas half discards which region a card came from and sorts alphabetically. A writer who arranged six cards in reading order under a titled region gets six titles in dictionary order with nothing saying they belong together.

**2.3 The promotion is not consulted.** A region that has been promoted carries `CanvasRegion.promotedItemID` — the note it became. The projection keeps pinning its cards; the note arrives only if something linked it (a Novel) — and then *beside* the cards, as a seventh row.

### The new contract

`PinnedReferences.pinned` returns a **`PinnedShelf`**: an ordered list of **sections**, each with an optional title and its references in a stated order. `PinnedShelf.references` is the flat, deduplicated projection in section order, for readers that want a list. Deduplication is unchanged: on the pin's id, first occurrence wins.

Sections, in this order:

1. **Linked** (untitled) — `linkedResearchIds`, manifest order. Unchanged.
2. **Contained** (untitled, merged into section 1's list — the writer sees one untitled run of research at the top) — `derivedResearchItems(forDocumentId:)`'s asset ids, manifest order. New input: `derived: [String]`. Passed by the one assembler, `PinnedReferenceResolver` (the census `ReferencesPaneTests.test_thePinnedProjectionIsAssembledInExactlyOneProductionFile` holds).
3. **One section per region bound to the piece**, titled with the region's label (empty label → `Promotion.regionTitle`'s fallback, made reachable rather than restated), regions ordered by label then id (the `RegionInspector.rows` discipline). Contents:
   - **If the region has been promoted and `promotedItemID` resolves in the manifest** — the section holds **that one pin** (research note or palette card) and **not** the cards. The region *became* that note; pinning both is the seventh-row defect above.
   - **Otherwise** — the region's residents in **reading order** (`Promotion.readingOrder`: top-to-bottom, left-to-right, id), each resolved as today (scrap / owned photo / project item; unresolvable dropped).
   - A promoted region whose note was deleted falls back to its cards — the fact is stale and the writer still has the material.
4. **Cards** (titled "Cards" — one fixed string, `PinnedShelf.looseCardsTitle`) — nodes with `boundPieceID == piece` that no section above already took, reading order. Only present when non-empty.

A single card's own `promotedItemID` does **not** supersede the card. The writer pinned the card; a region is different because its promotion is what the region is *for*.

### Readers

- **`ReferencesPane`** draws section headers (a caption row, the same weight as the tree's section headers) above each titled section; untitled sections draw no header. `Row` gains nothing — the section carries the structure.
- **`AssistantColumn`** is unaffected: it studies one `PinnedReference`.
- **`CompilerEnvironment.pinnedListing`** emits one line per pin as today, preceded by a `## <section title>` line for each titled section, so a run is briefed on the same grouping the writer sees. `CompilerPrompt`'s listing section already takes lines.

### Tests (contracts, not code)

- `PinnedReferencesTests`: a Collection piece with a contained note and no link pins the note; a single-doc project pins every asset; a bound region yields a section titled with its label, residents in reading order; a promoted region yields its note alone; a promoted region whose note is gone yields its cards; a card in two bound regions lands once, in the first; a self-bound card outside any bound region lands under "Cards"; the flat `references` equals the concatenation minus duplicates.
- `ReferencesPaneTests`: the pane draws one header per titled section and none for untitled; the assembly census still names one file.
- `CompilerEnvironment` listing: section titles appear as `##` lines in order.

## 3. The study column takes the right column

**3.1 What is wrong.** `AssistantColumnModifier` (`Maugham/Views/AssistantColumn.swift`) wraps the centre column in an `HStack` and inserts `AssistantColumn` at `assistant.width` (260–620pt) to the LEFT of the prose. With binder + study column + prose + inspector, a 1470pt display leaves the prose a margin. The 2026-07-25 spec chose this deliberately ("only squeezes the centred writing column when asked"); Denver has now asked for the opposite, having used it.

**3.2 The new shape.** A studied pin is shown **in the right column, in place of the pane picker and the pane**, at the right column's own width. No fourth column exists.

- `ProjectWindow.detailColumn` gains one arm above `inspectorPane`: when `AssistantColumn.isPresented(studied:persona:isNoChromeOn:)` is true, the column renders `AssistantColumn` (header with title + close, the same content arms) instead of `DetailPaneToggle`. `isPresented`'s three inputs are unchanged (Author/Review via `Persona.studiesPinnedReferences`; ⌘\ vetoes).
- **Studying reveals the column.** `AssistantColumnModel.study` on a pin that was not studied sets `showInspector = true` through the window — the same shape `revealResearchColumn` uses for a research subject in Plan. Closing (✕, Escape via `AssistantColumnEscape`, clicking the studied row again) leaves the column visible showing whatever `detailSegment` still holds. No stash/restore of `showInspector` — a stash is tripwire 2's shape, and the inspector is one ⌘⌥I away.
- **The newest act wins.** A `detailSegment` change (a ⌘⌥-letter, or the picker — though the picker is not on screen while studying) dismisses the study. A `selectedSubject` change dismisses it (today only `activeDocId` does; a research-row click in the tree leaves `activeDocId` alone and must still win). A persona change to a non-studying persona hides it and keeps it, as today.
- **Width.** The studied column uses `detailColumnWidth` — the right column's persisted, clamped, affordance-reduced width (`DetailColumnWidthTests`). `UIState.assistantColumnWidth`, `defaultAssistantColumnWidth`, `assistantColumnWidthRange`, `AssistantColumnModel.width`, the modifier's drag handle and `dragStartWidth` are **deleted**. `UIState` decodes a file that still carries the key (Codable ignores unknown keys; `UserPreferencesTests`/`UIState` tests pin that an old file opens).
- `AssistantColumnModifier` survives only as the owner of the Escape arbiter and the dismiss-on-change chain (`studied`, `window`, `isNoChromeOn`, `persona`, `activeDocId`, + `selectedSubject`, + `detailSegment`). It inserts no view. If that leaves it a modifier with an empty `body`, fold the chain into `detailColumn`'s host and delete the type — the plan decides against the built code, not here.
- The centre column's comment at `ProjectWindow.swift` ~1310 ("the column SQUEEZES the centred writing column") is now false and goes with the code.

**3.3 Tests.**
- A mounted test: study a pin in Author → the editor's width is unchanged and the right column shows the reference's title; close → the right column shows the pane picker again. (Mounted tests read their premise off the window they got — CI's display is 1024pt.)
- `AssistantColumnTests`: the `HStack` composition, width and drag tests are deleted with the code; the Escape and persona-veto tests survive unchanged.
- The census in `AssistantColumnTests` ("deleting the one line that applies this leaves … nothing on screen") is re-pointed at the new arm.

## 4. Soft breaks render as line breaks

`ResearchNotePreviewPane.expandParagraph` (`Maugham/Views/ResearchNotePreviewPane.swift`) joins a paragraph's lines with `" "` before `AttributedString(markdown:)` — so every single newline the writer typed inside a scrap (and inside any research note) collapses to a space. A promoted region's note keeps its paragraph breaks (`\n\n`, joined by `Promotion`) and loses every line break inside a card.

**Contract.** Within a paragraph block, a line break in the source renders as a line break: lines join with `"\n"` and parse with `AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)`. Headings, lists, quotes, tables and solo images are unchanged. This is the ONE research-note renderer (the tree's preview, the study column, Review's read-only centre all reach it), so it fixes all three.

**Test.** `parsedBlocks` over `"first line\nsecond line"` yields one paragraph whose string contains a newline between the two; over `"a\n\nb"` yields two paragraphs. Inline emphasis across the break still resolves (`*a\nb*`).

## 5. The canvas collapse must actually give the canvas the window

`ProjectWindow.canvasCollapse` (`~2722`) answers ⌘\ on the canvas with `columnVisibility = .doubleColumn` + `showInspector = false`, and `detailColumn` renders **nothing** in that state. Under `.all` with the inspector hidden the right column vanishes as intended (⌘⌥I in Author has always worked). Under `.doubleColumn` it does not: the detail column is a three-column `NavigationSplitView`'s flexible trailing column, and with no view and no `navigationSplitViewColumnWidth` in it, the split gives the CONTENT column its `ideal` (720) and hands the rest to an empty detail — which is exactly Denver's "blank and twice as big". `CanvasCollapseTests` covers the pure decision; nothing measures the layout it produces.

**Contract.** With the collapse applied, the canvas's frame width equals the window's content width (minus nothing but the split's own divider). The hidden-inspector arm of `detailColumn` must hold under `.doubleColumn` as well as `.all`.

**Candidate fixes for the plan to try, in order, each with the disable experiment (revert it, watch the measurement go red):**
1. In `detailColumn`'s hidden arm, render an empty view with `.navigationSplitViewColumnWidth(0)` rather than no view.
2. If (1) does not hold, keep `columnVisibility == .all` for the collapse and hide the binder by driving its `navigationSplitViewColumnWidth` to 0 while collapsed (its `min` is `binderColumnFloor`, so this is a state-dependent range), leaving `.doubleColumn` unused. `canvasCollapse`'s pure decision changes shape accordingly and `CanvasCollapseTests` moves with it.

**Test.** A mounted test on the canvas route: apply the collapse, poll until settled, assert the canvas view's width against the window's content-layout width; release, assert the three columns are back. Skip by name where the display cannot afford the window it asks for.

## 6. Out of scope

- An MCP read tool for an owned photograph's pixels (the standing gap; unchanged).
- Grouping the *linked* research by anything — it is the writer's manifest order.
- Any change to what promotion writes.

## 7. Docs to move in the same branch

`docs/guide/right-pane.md` (References, the study column), `docs/guide/compiler.md` if it names the column's placement, `docs/roadmap.md` (this entry, and the M2/M3 entries' "between binder and editor" claims get a dated strike), `CLAUDE.md`'s `Maugham/Compiler/` and `Maugham/Views/` cells (assistant column placement; collapse), `Maugham/Views/AREA.md`, the two amended specs get a one-line pointer here at the amended section.
