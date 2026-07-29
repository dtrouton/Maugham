# M1C-c2a — the piece association

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promotion lands where the writer's own association says it should — a scrap's piece, else its home region's — and the piece binding stops pretending to be a promotion.

**Architecture:** Three small moves on top of 1C-c2. A scrap gains the optional `boundPieceID` a region already has (sidecar schema 4 → 5). A pure resolver answers "which piece does this promotion belong to" by precedence, overwriting nothing. The performer then hands that piece to `ProjectStore.createResearchNote(scope:)`, whose routing — containment for a Collection loose piece, shared + a link for a novel, shared alone for a single-document project — **already ships and is not reimplemented here**.

**Tech Stack:** Swift 6, SwiftUI + AppKit, XCTest. Mac only; `Packages/MaughamCore` and `MaughamPhone` are untouched.

## Global Constraints

- **Spec §6's 2026-07-29 amendment and the new §6.2** (`docs/superpowers/specs/2026-07-25-planning-canvas-design.md`) are the authority. Read both before starting.
- **Nothing is overwritten.** Setting a region's piece must never write to its members. The scrap's own setting is the override; the resolution is by precedence.
- **Only the HOME region is inherited from.** A citation is not luggage — §4.3's rule for dragging, applied to destination.
- **The routing is not ours.** `ResearchScope.route(_:shared:piece:)` (`Maugham/Stores/ResearchScope.swift:66-86`) already decides containment vs shared-plus-link vs shared-only. Call it; do not restate its rule in a second place, and do not add a fallback of your own.
- **Tripwire 32:** a file holding a `CanvasModel` that is not `CanvasView.swift` changes the scene through `mutateFromInspector` only, and must be named in the census in `MaughamTests/TripwireGrepTests.swift`. **`ScrapInspector.swift` starts mutating in this plan and must join that census.**
- **`ProjectWindow.body` has a zero expression budget.**
- Every new guard is proven by the **disable experiment** — remove it, watch the test fail, restore it. Four of 1C-c2's assertions passed for the wrong reason until this was done.
- `./gen.sh` after adding a file. **Never commit anything under `Maugham.xcodeproj/`.** `xcodebuild` in the foreground, one at a time. `-only-testing MaughamTests/<ClassName>`, never a folder path.
- **Do not run the MCP suites.** `MCPServerLifecycleTests` now fails with a named 10s timeout instead of hanging (`5fe107b`), but the underlying main-actor stall at suite scale is unresolved.
- SourceKit's `No such module` / `Cannot find type … in scope` is stale-index noise. The real one is "unable to type-check this expression in reasonable time".

## Verified against the code, on this branch at `66d5933`

| Fact | Where |
|---|---|
| `ResearchScope` is `.shared` / `.document(String)` | `Maugham/Stores/ResearchScope.swift:10-13` |
| `researchRouting(forDocumentId:)` → `.pieceFolder` / `.sharedPlusLink` / `.sharedOnly`, throwing for a reference piece, a group, an unknown id, an unknown project type. **`internal`** — same module, callable | `ResearchScope.swift:26-51` |
| `route` performs the link itself on `.sharedPlusLink` | `ResearchScope.swift:78-81` |
| `createResearchNote(scope:title:) async throws -> ResearchItem` | `ResearchScope.swift:88-95` |
| `isResearchScopeTarget(_:) -> Bool`, `researchScopeTargets() -> [StructureItem]` — the latter's doc says it drives the promote-target picker | `ResearchScope.swift:54-62` |
| `linkResearch(researchId:toDocumentId:) async throws` | `ProjectStore+Structure.swift:667` |
| `createCraftIntent(forPieceId:)`; `craftIntentItem(forPieceId:)` finds by the piece's research **prefix**, which is nil for a non-loose piece | `ProjectStore+CraftIntent.swift:19-50`; `ResearchScope.swift:120-123` |
| `CanvasMembership.homeRegion(of:in:) -> CanvasRegionID?`, walking id-ordered `scene.regions` | `Maugham/Canvas/CanvasMembership.swift:52-55` |
| `CanvasRegion.boundPieceID`; `CanvasNode` has **no** such field yet | `CanvasRegion.swift`; `CanvasNode.swift` |
| Sidecar is at schema **4** | `CanvasSceneCodec.swift:16` |
| `ProjectWindow.pieceChoices(in:)` collects **every** `.document` — including reference pieces the router throws on | `ProjectWindow.swift:1155-1158` |
| `PromotionTarget` still has `.pieceBinding`; `PromotionResult.boundPieceID`; `PromotionFailure.missingPiece`; `PromotionRequest.piece`; `PromotionPlan.pieceID` | `Promotion.swift`, `PromotionPerformer.swift` |

---

### Task 1: A scrap carries a piece, and the resolver decides by precedence

**Files:** modify `Maugham/Canvas/CanvasNode.swift`, `CanvasScene.swift`, `CanvasSceneCodec.swift`, `Promotion.swift`; test `MaughamTests/Canvas/PromotionPieceTests.swift` (new)

**Produces:** `CanvasNode.boundPieceID: String?` (last init parameter, `nil` default); `CanvasScene.setBoundPiece(_ pieceID: String?, for id: CanvasNodeID)`; `CanvasSceneDTO.currentSchemaVersion == 5` with `NodeDTO.boundPieceID`; and

```swift
extension Promotion {
    /// Which piece a promotion belongs to — **by precedence, never by
    /// overwriting.** The scrap's own association wins; failing that it
    /// inherits from the region it LIVES in; failing that there is none and the
    /// artifact is the project's.
    ///
    /// Home only, deliberately: a citation is not luggage (§4.3's rule for
    /// dragging, applied to destination), and a card cited in two regions bound
    /// to different pieces must not take whichever the writer touched last —
    /// that is §4.2's rejected bug class wearing a new hat.
    ///
    /// A region answers with its own and nothing else: it has no home to
    /// inherit from. A line answers nil — its artifact is text inside somebody
    /// else's note.
    static func piece(for source: PromotionSource, in scene: CanvasScene) -> String?
}
```

- [ ] **Step 1: Write the failing test** — `PromotionPieceTests`, covering at minimum: a scrap with its own piece wins over a differing home-region piece; a scrap with none inherits its home region's; a scrap whose only association is an **appearance** in a bound region inherits **nothing**; a loose scrap answers nil; a region answers its own; a region with none answers nil; a line answers nil; an unknown id answers nil. Plus the round-trip and schema tests: a mark survives save/load, a **schema-4** sidecar literal decodes with `boundPieceID` nil and loses nothing else, and an unassociated canvas's JSON contains no `boundPieceID` key at all (measured, not reasoned from Codable's synthesis).
- [ ] **Step 2: Run it, watch it fail** for `cannot find 'setBoundPiece'` / `piece(for:in:)`.
- [ ] **Step 3: Add the field, the mutator and the schema bump**, following exactly the shape `promotedItemID` took in 1C-c2 — last parameter, `nil` default, additive-optional both ways. If an existing test asserts the literal `4`, that assertion is doing its job; move it to 5 and say which in the report.
- [ ] **Step 4: Write `Promotion.piece(for:in:)`** using `CanvasMembership.homeRegion(of:in:)`.
- [ ] **Step 5: Run the tests**, then the **disable experiment** on the home-only rule: make it read appearances too and confirm the appearance test goes red.
- [ ] **Step 6: Commit.**

---

### Task 2: A piece binding is not a promotion

**Files:** modify `Promotion.swift`, `PromotionPerformer.swift`, `PromotionSheet.swift`, and the tests that name them

**Removes:** `PromotionTarget.pieceBinding`, `Promotion`'s `.pieceBinding` arms, `PromotionRequest.piece`, `PromotionPlan.pieceID`, `PromotionPerformer.performPieceBinding`, `PromotionResult.boundPieceID`, `PromotionFailure.missingPiece`, and the sheet's piece `Picker` + `selectedPieceID`.
**Adds:** `.researchNote` to a region's targets, so `Promotion.targets(for: .region…)` returns `[.researchNote, .paletteCard]`.

**Keep `RegionInspector.PieceChoice` and `RegionBinding`** — the inspector's picker still sets the association, which is now §6.2's, and Task 4 rewires its source.

The compiler will find most of this: removing an enum case makes every `switch` over `PromotionTarget` enumerate what is missing. That is the point of the case being an enum, and it is the cheapest census available.

- [ ] **Step 1: Delete the case and let the build fail**, then work the errors. Record in the report every site the compiler found — that list is the evidence the removal is complete.
- [ ] **Step 2: Update the tests** that assert a region's targets, that build a `.pieceBinding` plan, or that assert `boundPieceID` on a result. **Do not delete a test that still has a subject** — `test_bindingSharesTheInspectorsUndoName` covered the undo name of an act that no longer exists here; the region inspector's own binding test keeps that name honest, so check it exists before dropping this one.
- [ ] **Step 3: Add the region's `.researchNote` target and its plan.** A region's note body is the existing joined member text in reading order; its discards stay `[.lines, .layout]`; its link offer is unchanged.
- [ ] **Step 4: Run** `PromotionTests`, `PromotionPerformerTests`, `PromotionSheetTests`, `RegionBindingTests`, `PromotionCommandTests`, `ScrapInspectorTests`, `LineInspectorTests`, `TripwireGrepTests`.
- [ ] **Step 5: Commit.**

---

### Task 3: The performer hands the piece to the routing that already exists

**Files:** modify `PromotionPerformer.swift`; test `MaughamTests/Canvas/PromotionPieceRoutingTests.swift` (new)

**The whole change is which scope is passed.** `performResearchNote`'s `.new` branch becomes `store.createResearchNote(scope: scope, title: plan.title)` where `scope` is `Promotion.piece(for: plan.source, in: model.scene).map(ResearchScope.document) ?? .shared`. **Do not** branch on project type here; `route` does that, and a second copy of the rule is how the two drift.

Two cases that are not the general one, and both need saying in the code:

- **Craft intent takes the piece only when the routing is `.pieceFolder`.** `craftIntentItem(forPieceId:)` finds an existing intent doc by the piece's research *prefix*, which is nil for anything that is not a Collection loose piece — so a shared-plus-linked intent doc could never be found again, and the next promotion would mint a second one. Ask `researchRouting(forDocumentId:)`, use the piece on `.pieceFolder`, project scope otherwise.
- **A palette card is never routed** — the wall is project-level and `addPaletteCard` must place the card under the palette group. It takes a `linkResearch` **only** where the routing would have been `.sharedPlusLink`, read from the same function, so the decision has one source.

An `.update` promotion changes nothing here: the artifact already exists where it exists.

- [ ] **Step 1: Write the failing test** across all four project shapes, asserting **where the file landed** and **whether a link record exists**, not merely that a call was made: a Collection loose piece → the note is under that piece's folder and there is no link; a novel chapter → the note is under `research/` **and** `linkedResearchIds(forDocumentId:)` contains it; a short story → under `research/` with **no** link; a scrap with no association → `research/`, no link. Plus: promoting to craft intent from a novel-chapter-associated scrap creates **one** intent doc and a second promotion finds the same one rather than minting another.
- [ ] **Step 2: Run it, watch it fail** — today every promotion lands in shared research with no link.
- [ ] **Step 3: Implement**, then **Step 4: run**, then the disable experiment on the craft-intent guard: pass the piece unconditionally and confirm the two-intent-docs test goes red.
- [ ] **Step 5: Commit.**

---

### Task 4: The surfaces — set it, see it, and only offer what can be routed

**Files:** modify `ScrapInspector.swift`, `RegionInspector.swift`, `PromotionSheet.swift`, `ProjectWindow.swift`, `MaughamTests/TripwireGrepTests.swift`; tests alongside

1. **`ScrapInspector` gains a Piece picker.** It mutates the scene, so it goes through `CanvasModel.mutateFromInspector` and **`ScrapInspector.swift` joins tripwire 32's census in this commit** — the failure is silent otherwise: nested inside an open "Edit Scrap" gesture the edit registers no undo step and rides into the writer's next sentence. Undo name: `"Associate Card with Piece"` / `"Clear Card's Piece"`, following `LineInspector`'s Bind/Unbind precedent that clearing reaches a genuinely different state.
2. **Both pickers offer `store.researchScopeTargets()`**, not every `.document`. `ProjectWindow.pieceChoices(in:)` currently offers reference pieces the router throws on; change its source and keep its signature if that reads better, but a piece the writer can choose must be one a promotion can route.
3. **The region inspector's footer** currently describes only 1A's reference rail. It now also decides where promotions from this region land — say both, briefly.
4. **The sheet's "Goes to" names the piece and the route**: a piece that keeps its own research reads differently from one whose note lands in shared research with a link, and a writer in a novel — not thinking in pieces at all — must not read that as an error.
5. **The scrap inspector shows an inherited association as inherited** — "Chapter Three (from its region)" versus "Chapter Three" — so the precedence is visible rather than mysterious, and the writer can see why an override would matter.

- [ ] **Step 1: Write the failing tests** — the census row for `ScrapInspector.swift` (with its planted-offender companion, this directory's instrument); a test that the pickers' source excludes a Collection reference piece; and tests for the destination copy in both routes and for the inherited-versus-own distinction, as values on the model rather than as rendered views.
- [ ] **Steps 2-4: fail, implement, run** — including `TripwireGrepTests` and `RegionBindingTests`.
- [ ] **Step 5: Commit.**

---

### Task 5: The record

**Files:** `docs/adr/0026-planning-canvas-rendering.md`, `Maugham/Canvas/AREA.md`, `CLAUDE.md`, `docs/roadmap.md`, `docs/guide/getting-started.md`, `docs/guide/right-pane.md`, and this plan's smoke list

The spec is already amended (§6, §6.2, §4.4 — commits `b952d45`, `66d5933`); this task makes everything else agree with it. What must reach the record:

- **ADR 0026 §9 gains the ruling**: a piece binding is not a promotion (it produces no artifact and duplicates a picker), a region produces a research note, and the association resolves by precedence and never overwrites — with the reason, which is §4.2's bug class arriving through a card cited in two bound regions.
- **The routing is adopted, not invented** — name `ResearchScope` so the next author does not add a second copy of the rule.
- **AREA.md**: schema 5; the new field; the precedence rule; `ScrapInspector` in the tripwire-32 list; and the note that `craftIntentItem` finds by prefix, which is why craft intent takes the piece only for a loose piece.
- **CLAUDE.md**: the canvas row's schema number, and tripwire 32's census count.
- **Roadmap**: fold this into 1C-c2's entry rather than minting a new one — it is the same slice, corrected after its smoke.
- **The guide**: what the Piece picker does in both inspectors, and that promotion follows it. `right-pane.md` describes all three arms already; the scrap arm gains a control.
- **Smoke list**: associate a region with a piece and promote a member scrap; give that scrap its own different piece and confirm it wins; do both in a novel and in a Collection and confirm the destination copy tells the truth in each.

- [ ] **Steps: write, then run the doc-guarding suites** (`DocSyncTests`, `GuideDocsDriftTests`, `GuideMarkdownViewTests`, `GuideCorpusRenderabilityTest`, `HelpTopicIndexTests`), then commit.

---

## Whole-slice verification

```
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -skip-testing:MaughamTests/MCPServerLifecycleTests
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
  -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO
```

The Mac suite runs ~5 minutes (measured 2026-07-29: 295.95 s, 3,399 tests). Then the caller census — `grep -rn "boundPieceID\|setBoundPiece\|Promotion.piece" Maugham/ --include=*.swift | grep -v Tests` — and a whole-branch review over `66d5933..HEAD`, whose question is: **does every surface that can set an association agree with every surface that reads one?**

## Smoke — the writer's own pass

The suite cannot see a destination sentence that is true and unhelpful, and it cannot see a picker offering a piece the writer does not recognise. **The subject of every step below is the sentence in the sheet**, not whether a file appeared.

- [ ] **Precedence, in a novel.** Draw a region around three cards, associate it with a chapter, select a member card and Promote… → *Research note*. The destination should name **research/, linked to that chapter**. Commit, then check the note is in the project's research and the chapter carries the link.
- [ ] **The card's own wins.** Give that same card its own, *different* chapter in the scrap arm's **Piece** picker. The card's Inspector should stop saying *(from its region)*. Promote again → the destination names the **new** chapter, and the region's cards that you did not touch are unchanged.
- [ ] **Setting the region's piece does not reach inside it.** Change the region's Piece afterwards and confirm the overridden card still names its own, and a sibling card with no association of its own follows the new one.
- [ ] **A visitor inherits nothing.** Cite a card into a bound region (it should still *live* elsewhere). Its Inspector should show the piece of the region it **lives** in, or none — never the citing region's.
- [ ] **Precedence, in a Collection.** Same two steps on a loose piece. The destination should name **that piece's own research/**, and the note should land inside the piece's folder rather than in shared research.
- [ ] **The route is legible in each.** Read both destination sentences back to back: a novel's names the chapter *and* the link, a Collection loose piece's names containment, a short story's says the shared research is already that document's. If any two read the same, the copy has failed its job.
- [ ] **Craft intent.** Promote a card to *Craft intent* in a Collection with a loose-piece association — the destination should name the **piece's** craft intent. Do it again from a novel chapter and the destination should name the **project's**, deliberately.
- [ ] **A palette card is never filed under a piece.** Promote a region to *Palette card* with a novel chapter associated — the destination names the palette wall, linked to the chapter. In a Collection it names the wall alone.
- [ ] **A stale association refuses.** Associate a card with a piece, delete the piece, and Promote… → the sheet refuses before Commit and the sentence is about the writer's situation. Repeat with the association on the *region* instead and confirm the refusal points at the region rather than at the card's own picker.
- [ ] **The picker offers nothing that can fail.** In a Collection holding a reference piece, confirm neither Piece picker lists it.
- [ ] **The undo step is named for what you promoted.** Promote a *region* to a research note, open the Edit menu, and read the Undo item — it should say Region, not Scrap.
- [ ] **Tripwire 32, through the new picker — and this arm's repro is a card, not a chrome bar.** Double-click a **card** (click 1 selects it, so the card arm is on screen; click 2 opens "Edit Scrap" without moving the selection, so the pane stays), set its **Piece** in the Inspector while the caret is still in the card, then type a sentence. One ⌘Z should take back the sentence and leave the association standing; a second should take back the association under its own name.
- [ ] **Quit and reopen.** The associations survive on both the card and the region, and an older sidecar (schema 4) still opens with its scraps intact.
