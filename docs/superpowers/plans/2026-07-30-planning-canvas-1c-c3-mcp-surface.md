# M1C-c3 — the MCP canvas surface

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:subagent-driven-development` to implement this task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Claude can read the canvas and add what it read off a photographed page to it — as scraps in a region beside the photograph, visibly marked as Claude's, placed by the canvas rather than by Claude.

**Architecture:** Two tools over one pure placement planner and one live-or-disk applier. `list_canvas` reads the attached `CanvasModel` when the writer has the canvas open and the sidecar otherwise — the canvas's own version of tripwire 20's open-doc/closed-doc discriminator. `add_canvas_scraps` runs the planner (pure, mutates nothing) and hands the result to the applier, which mutates the live model through `mutateFromInspector` or a transient `CanvasStore` — one definition of *where Claude puts things*, shared by both routes (spec §8A.2's corollary). Provenance is one optional field on the node and the line, reusing `AnnotationAuthor.SourceKind`, drawn as cooler paper and a cooler stroke.

**Tech stack:** Swift 6, SwiftUI + AppKit, `Maugham` app target throughout. No MaughamCore change, no phone change (spec §9).

---

## How to read this plan

**It deliberately contains almost no code.** In the three slices behind this one, *the plan's own draft code was the single largest source of defects* — a preview contradicting its own mode picker, a `?? ""` turning a read failure into a truncating write on three append paths, a missing `flushPendingSave`, and four assertions that passed for the wrong reason. Not one was the implementer's error. So each task states **the requirement, the symptom it must not have, and the signatures verified against the real file** — and the implementer writes the code against that file. Where a signature is given, the file and line it was read from on 2026-07-30 is given with it.

This overrides the writing-plans skill's "code blocks required for code steps". Recorded so the deviation is visible rather than silent.

**Every negative assertion needs its disable experiment**: remove the guard, watch the named test fail, restore it, and report the output in the task's completion note. Six assertions across the previous slices passed for the wrong reason until this was done, and two were caught only because an implementer ran the experiment on a test it had merely transcribed.

**Never run two implementers at once** — they share the working tree. `xcodebuild` in the foreground, one at a time.

---

## Global constraints

- **Read `Maugham/Canvas/AREA.md` and `Maugham/MCP/AREA.md` before touching either directory.** Both are long and both are load-bearing.
- **Tripwire 32:** anything outside `CanvasView.swift` that changes the scene uses `CanvasModel.mutateFromInspector`, never `mutate`/`beginGesture`/`endGesture`, **and joins `TripwireGrepTests.test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly`'s expectation by name in the same commit.** The census today expects exactly four files (`TripwireGrepTests.swift:1699-1702`). **Count that array, not any prose.**
- **Tripwire 31:** no `region.frame.contains(…)` in anything that could be a move or a resize. Task 3 reads geometry at *creation*, which is legitimate, and records membership through `CanvasMembership` — deciding and recording stay separate.
- **Tripwire 30:** nothing scene-proportional may key off `revision`. The structural counter is `sceneRevision`, and every writer of it calls `model.bumpSceneRevision()` — the view has no bump of its own.
- **Tripwire 23:** no bare id mint. Ids get the uniqueness loop `CanvasInteraction.createScrap` uses (`CanvasInteraction.swift:425-434`).
- **Tripwire 21:** a new `maugham.*` notification is declared in `MaughamEvent` with a scope; a raw `NotificationCenter.default.post(` under `Maugham/Canvas/` or its tests needs `// adr-0021-ok:` on the call's first line.
- **ADR 0018/0019:** a raw read of a manuscript `.md` needs `// adr-0018-ok:`. `canvas.md` and `canvas.json` already carry theirs in `CanvasStore.load` and are the *only* exempt pair, for the reason ADR 0026 gives (no second source of truth to drift against).
- **Every `ScrapLayout` construction under `Maugham/Canvas/` must name `textColor: CanvasRenderer.cardInk`** — grep-enforced, and taking the default gives the same colour today so nothing would break if you forgot.
- **`CanvasView.swift` has five source-layout contracts** in its header comment, enforced by tests that slice the file as text. Contract 1 *crashes* rather than fails; contract 5 fails if certain accessibility modifiers are merely *named in a comment*. Read that header before editing the file.
- **`ProjectWindow.body` has a zero expression budget.** Window-level behaviour goes in an extracted `ViewModifier` applied in one line.
- **A `store` is never read from a view `body` or anything `body` calls.** Deferred closures (`artifactTitle`, `pieceTitle`, `paletteSwatchHexes`) are the pattern.
- **`./gen.sh` after adding any file.** Never commit anything under `Maugham.xcodeproj/`.
- **Build/test:**
  - `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -skip-testing:MaughamTests/MCPServerLifecycleTests`
  - `-only-testing` takes `MaughamTests/<ClassName>` — **never a folder path** (a folder path runs zero tests and reports success).
  - **Do not chase the three clock-dependent MCP failures.** `MCPServerLifecycleTests` is skipped above; `MCPBinaryIntegrationTests.test_binary_exitsCleanly_onStdinClose` and `MCPColdStartTests.test_firstCallAfterLaunch_pollsUntilServerBinds` fail in a full suite and pass in isolation. Apply the fails-in-suite/passes-alone discriminator before believing a red run is yours. See `docs/superpowers/notes/2026-07-29-mcp-clock-dependent-tests.md`.
  - Phone scheme must stay green: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`. A "Busy / failed preflight" is a flake — re-run.
  - **Release build before the branch is called done:** `-configuration Release build CODE_SIGNING_ALLOWED=NO`. The Release type-check budget is stricter than Debug and `ProjectWindow.body` is touched here.

## The five rulings this plan is built on

Denver, 2026-07-29/30, re-deriving c3 against the built canvas. **Do not re-open these; they are the design.**

1. **Two tools, and no id or position on the wire.** `list_canvas` and `add_canvas_scraps`. Claude cannot name a node id, a region id or a coordinate — roadmap line 64's structural guarantee, kept. Lines are drawn by `connect`, which indexes the call's **own** `scraps` array, so Claude can draw the arrows it read off a page and can touch nothing the writer made.
2. **`connect` carries no label.** A label from Claude on an edge is the nearest thing to the typed edge §5 spends its length rejecting; an unlabelled untyped line is §5's floor, and the writer names it in the inspector in a second.
3. **Claude's cards are papered a cooler value; Claude's lines are stroked one.** One visual language, reused rather than a second invented. §8A.2 constraint 1 asks for "visibly marked" and this is the answer.
4. **The mark stays when the writer edits the card.** Provenance records an act, exactly as a promotion mark does (ADR 0026 §9). Structural consequence: **`CanvasScene` gets no verb for clearing an author** — nothing to write, so nothing to get wrong.
5. **Every add lands in a region; a source is optional.** With a `source_item_id` the region also holds an item node for it and takes its title. Without one, the region is still there and still labelled — nothing is ever loose (§8A.2 constraint 2).

**Deliberately NOT in this slice:** the writer's own `inbox → canvas` route. That is spec **§8A.4**, added 2026-07-30, and it is **1C-d's** — the photograph half *is* the image work (the ingestion pair, the owned-asset store, the path-referenced node, the thumbnail and the path-keyed cache), and an action live for text captures and absent on photos would ship a seam that teaches the writer it is broken. Read §8A.4 and §3.1's amendment before Task 3, because they are why c3's source is a *research item id* and not a capture.

## The honest limit, and it must reach ADR 0026

**In c3 the photograph draws as `Item · res-notebook-p3`** — a dashed placeholder (`CanvasRenderer.swift:995,1066`). So c3 makes §8A.2's corollary **structural** (source and derived scraps in one region, provenance recorded, origin recoverable) and **not yet checkable by looking**: the writer cannot compare the scraps against the page without clicking through to research. 1C-d's thumbnail is what closes that, and neither slice ships alone (M1 needs 1A, 1B and the whole of 1C). **Decision 10 must say "structural here, visible at 1C-d" and not "corollary satisfied"**, or it is recorded as done and never revisited.

## File map

| File | Responsibility | Task |
|---|---|---|
| `Maugham/Canvas/CanvasNode.swift` | `author` on the node; `CanvasCardMetrics.itemPlaceholderHeight` | 1, 2 |
| `Maugham/Canvas/CanvasLine.swift` | `author` on the line | 1 |
| `Maugham/Canvas/CanvasSceneCodec.swift` | schema 7, additive-optional both ways | 1 |
| `Maugham/Canvas/CanvasScrapMeasure.swift` *(new)* | the ONE spelling of "how tall is this scrap" | 2 |
| `Maugham/Canvas/CanvasView.swift` | reads the lifted measure; binds the external-change hook | 2, 4 |
| `Maugham/Canvas/CanvasClaudePlacement.swift` *(new)* | pure: where Claude's nodes go | 3 |
| `Maugham/Canvas/CanvasModel.swift` | `isAttached`, `onSceneChangedExternally` | 4 |
| `Maugham/Stores/ProjectStore.swift` | `liveCanvas` weak back-reference | 4 |
| `Maugham/Views/ProjectWindow.swift` | wires `liveCanvas`; the banner's Show | 4, 9 |
| `Maugham/Canvas/CanvasClaudeWrite.swift` *(new)* | live-or-transient applier — **tripwire 32's fifth census entry** | 5 |
| `Maugham/MCP/Tools/CanvasTools.swift` *(new)* | both tools, one file (they share a scene-reading helper) | 6, 7 |
| `Maugham/MCP/MCPTool.swift` | catalog entries — the only registration step | 6, 7 |
| `Maugham/Models/MaughamNotifications.swift` | the added-nodes notification | 7 |
| `Maugham/Canvas/CanvasMaterial.swift` | the two cooler values, light + dark | 8 |
| `Maugham/Canvas/CanvasRenderer.swift` | cooler paper, cooler stroke, item-node exemption; `lineLabelBox` widening | 8, 10 |
| `Maugham/Canvas/CanvasAccessibility.swift` | "from Claude" in the label and the connection phrase | 8 |
| `Maugham/Canvas/ScrapInspector.swift` | the provenance line | 9 |
| `docs/guide/`, both `AREA.md`s, `CLAUDE.md`, ADR 0026, spec §10, roadmap | the sweep | 10 |

---

## Task 1 — `author` on the node and the line; sidecar schema 7

**Files:** modify `Maugham/Canvas/CanvasNode.swift`, `Maugham/Canvas/CanvasLine.swift`, `Maugham/Canvas/CanvasSceneCodec.swift`; modify `MaughamTests/Canvas/CanvasLineCodecTests.swift`; create `MaughamTests/Canvas/CanvasAuthorCodecTests.swift`.

**Interfaces — produces:**
- `CanvasNode.author: AnnotationAuthor.SourceKind?` and `CanvasLine.author: AnnotationAuthor.SourceKind?`. **nil means the writer.**
- `CanvasNode.init(…, author: AnnotationAuthor.SourceKind? = nil)` — last parameter, defaulted, so no existing construction site changes.
- `CanvasLine.init(id:from:to:label:author:)` with `author` defaulted last, same reason.
- `CanvasSceneDTO.currentSchemaVersion == 7`; `NodeDTO.author: String?` and `LineDTO.author: String?`.

**Verified signatures (read 2026-07-30):**
- `AnnotationAuthor.SourceKind` is a `String`-raw `Codable` enum with cases `claude` and `human`, in MaughamCore at `Packages/MaughamCore/Sources/MaughamCore/SpanAnchor.swift:23-26`. **Reuse it — §8A.2 constraint 1 asks for the annotation layer's provenance shape by name.** Do not mint a second enum.
- `CanvasSceneDTO.currentSchemaVersion = 6` today (`CanvasSceneCodec.swift:10`). `NodeDTO` already carries `promotedItemID`, `boundPieceID`, `contributedToItemID` as optionals; `LineDTO` is `var id, from, to: String` + `var label: String?`.
- `CanvasNode`'s existing optional fields are all trailing defaulted init params (`CanvasNode.swift:92-110`) — follow that shape exactly.

**Requirements**

- [ ] **Step 1 — the four failing tests, in `CanvasAuthorCodecTests`.** Names are contracts; write the assertions against the real types:
  - `test_anAuthoredNodeAndLineSurviveARoundTrip` — a scene with one `.claude` node and one `.claude` line encodes and decodes with both authors intact.
  - `test_aSchemaSixSidecarDecodesWithNoAuthor` — a hand-written schema-6 JSON payload with no `author` key anywhere decodes, and every node's and line's `author` is nil. **This is the additive-optional guarantee**; 4, 5 and 6 are the shape being copied, not 2 and 3.
  - `test_theWritersOwnCardsWriteNoAuthorKey` — encoding a scene of nil-author nodes produces JSON containing no `author` key at all, so an unchanged canvas's sidecar does not grow. Assert on the encoded bytes, not on a re-decoded value.
  - `test_anUnrecognisedAuthorIsNotReadAsTheWriters` — a payload with `"author":"collaborator"` decodes to `.claude`, **not** nil. **The ruling and its reason:** the tint means *not your words*, so the safe failure direction is to over-mark rather than to tell the writer they wrote something they did not. A genuine third author kind wants its own case rather than this fallback — say so in the decoder's comment.
- [ ] **Step 2 — run them, confirm they fail** for the right reason (`author` does not exist), not a compile error in the test itself.
- [ ] **Step 3 — implement.** Field on both types, optional on both DTOs, `currentSchemaVersion = 7`, and the version comment extended in the house style (`// was 6 (contributedToItemID, 1C-c2b)`).
- [ ] **Step 4 — add NO clearing verb.** `CanvasScene` has `setPromotedItem`, `setBoundPiece`, `setContributedItem`; **it must not gain `setAuthor`.** Ruling 4 means the field is written once, at creation, by Task 3's planner. Leave a one-line comment on `author` saying so, or the next author adds the setter for symmetry.
- [ ] **Step 5 — rebump the from-the-future fixture.** `CanvasLineCodecTests.test_aSchemaSevenSidecarLosesTheArrangementAndKeepsTheWords` (`:101-115`) writes `"schemaVersion":7` and asserts the arrangement is lost and the words survive. At schema 7 that fixture **is no longer from the future and stops testing anything.** Rename the test to `…aSchemaEightSidecar…`, change the payload to 8, and update its docstring's "past this build's schema-6". This has needed doing at every bump so far.
- [ ] **Step 6 — run `MaughamTests/CanvasAuthorCodecTests`, `MaughamTests/CanvasLineCodecTests`, `MaughamTests/CanvasRegionCodecTests`, `MaughamTests/CanvasPromotionCodecTests`, `MaughamTests/CanvasStoreTests`, `MaughamTests/PromotionContributionTests`, `MaughamTests/PromotionPieceTests`.** All green. Those last four carry schema literals (4, 5, 6) that must keep decoding unchanged — that *is* the additive-optional proof at the suite level.
- [ ] **Step 7 — commit.**

---

## Task 2 — one spelling of "how tall is this scrap", and an item node that can be drawn

**Files:** create `Maugham/Canvas/CanvasScrapMeasure.swift`; modify `Maugham/Canvas/CanvasView.swift` (`rebuildLayouts`, `:553-587`; `remeasure` single-node path, `:589+`), `Maugham/Canvas/CanvasNode.swift` (`CanvasCardMetrics`); create `MaughamTests/Canvas/CanvasScrapMeasureTests.swift`.

**Interfaces — produces:**
- `CanvasScrapMeasure.height(text: String, cardWidth: CGFloat) -> CGFloat` — the card height for a scrap, i.e. the `ScrapLayout(...).measuredHeight` → `CanvasCardMetrics.cardHeight(forTextHeight:)` pair, in one place. Task 3 calls this and nothing else.
- `CanvasScrapMeasure.scrapFont: NSFont` — the canvas scrap font, lifted from `CanvasView` so a non-view caller can reach it.
- `CanvasCardMetrics.itemPlaceholderHeight: CGFloat` — the card height of an item node's dashed placeholder.

**Why this task exists, and the symptom if it is skipped**

`CanvasNode.frame` is nil unless `cachedHeight` is set (`CanvasNode.swift:118-121`), and `CanvasScene.nodes(intersecting:)` and `.topmostNode(at:)` both drop a node with no frame. So **a node created with no height is not drawn and not clickable.** Two consequences:

1. Task 3 must set real heights at creation, or Claude's scraps are invisible until something happens to re-measure — and on the sidecar route nothing does until the writer next opens the canvas.
2. **`rebuildLayouts` measures `.scrap` only** (`guard case .scrap = node.kind` at `CanvasView.swift:559`), and nothing anywhere measures an item node. Since nothing in production creates one, `CanvasRenderer`'s dashed placeholder (`:995`, `:1066`) **has never been drawable in production** — this area's fifth built-and-unreachable half, and c3 is its first producer. Without `itemPlaceholderHeight` the photograph's node is silently absent and the region holds derived scraps with no visible source, which is §8A.2's corollary failing while every test passes.

**Requirements**

- [ ] **Step 1 — failing tests in `CanvasScrapMeasureTests`:**
  - `test_theMeasureAgreesWithTheViewsOwnLayout` — `CanvasScrapMeasure.height(text:cardWidth:)` equals `CanvasCardMetrics.cardHeight(forTextHeight:)` of a `ScrapLayout` built with the same text, `CanvasCardMetrics.textWidth(forCardWidth:)` and `CanvasScrapMeasure.scrapFont`. This is the anti-drift assertion: **a second spelling of the measurement is §7A.2's "text jumps on focus" arriving by the back door** (`Maugham/Canvas/AREA.md`, "Card metrics live in `CanvasCardMetrics`").
  - `test_tallerTextMeasuresTaller` — a paragraph measures strictly greater than a word at the same width. Guards against a constant being returned.
  - `test_anEmptyScrapStillGetsALinesHeight` — an empty string measures at least the height of one line, because `ScrapLayout.measuredHeight` floors at `emptyLineHeight` (18, `ScrapLayout.swift:82`) precisely so a fresh scrap is hit-testable.
  - `test_anItemPlaceholderIsTallEnoughForItsOwnLabel` — `CanvasCardMetrics.itemPlaceholderHeight` leaves room for the label the renderer actually draws: an 11 pt system-font line at `CanvasCardMetrics.textOrigin(inCard:)` (`CanvasRenderer.swift:1066-1071`), inside a box inset `CanvasCardMetrics.inset` (10) top and bottom. Derive the expectation from those, not from a literal.
- [ ] **Step 2 — run, confirm failure.**
- [ ] **Step 3 — implement.** `CanvasScrapMeasure` names `textColor: CanvasRenderer.cardInk` (grep-enforced across this directory). Pick `itemPlaceholderHeight` from the drawn label rather than by eye.
- [ ] **Step 4 — repoint `CanvasView`.** `rebuildLayouts`'s creation branch and the single-node `remeasure` path both go through the new function. **`rebuildLayouts` must keep building and caching the `ScrapLayout` objects themselves** — the mounted editor and the draw pass share them (tripwire 26, ADR 0026 §2); this task lifts *the height calculation*, not the layout cache. If you find yourself deleting `layouts`, stop.
- [ ] **Step 5 — read `CanvasView.swift`'s five source-layout contracts** in its header before saving, then run `MaughamTests/CanvasCompositionTests` and `MaughamTests/CanvasAccessibilityTests`. A reformat here fails one of those with a message pointing somewhere else entirely, and contract 1 crashes rather than fails.
- [ ] **Step 6 — run `MaughamTests/CanvasScrapMeasureTests`, `MaughamTests/ScrapLayoutTests`, `MaughamTests/CanvasViewMountingTests`, `MaughamTests/CanvasRendererTests`.** Green.
- [ ] **Step 7 — record the scoped gap in `CanvasScrapMeasure`'s doc comment:** `rebuildLayouts` still skips item nodes, so an item node authored by a hand-edited sidecar has no height and is not drawn. Sufficient for c3 because c3's planner is the only producer and sets it at creation; a measurement pass for item nodes belongs to **1C-d**, whose thumbnails make an item's height depend on its image. Say it here so 1C-d meets a decision rather than a bug.
- [ ] **Step 8 — commit.**

---

## Task 3 — `CanvasClaudePlacement`: where Claude's nodes go

**Files:** create `Maugham/Canvas/CanvasClaudePlacement.swift`, `MaughamTests/Canvas/CanvasClaudePlacementTests.swift`.

**Interfaces — consumes:** Task 1's `author`; Task 2's `CanvasScrapMeasure.height(text:cardWidth:)` and `CanvasCardMetrics.itemPlaceholderHeight`.

**Interfaces — produces:**
- `CanvasClaudePlacement.Request` — value type: `scraps: [String]`, `sourceReferenceID: String?`, `regionLabel: String?`, `connections: [(Int, Int)]`.
- `CanvasClaudePlacement.Plan` — value type describing everything to be written: the region (id, label, frame), the ordered scrap nodes **each paired with its text**, the source item node **and whether it is new or already in the scene**, and the lines. Carries no `CanvasScene`. It carries the text because the applier must write `canvas.md` and the sidecar from one value — a second parameter alongside the plan is a second chance for the nodes and the words to disagree about which scrap is which.
- `CanvasClaudePlacement.plan(_ request: Request, in scene: CanvasScene) -> Plan` — **pure.**
- `CanvasClaudePlacement.apply(_ plan: Plan, to scene: inout CanvasScene)` — the only writer of a `Plan`, so both routes in Task 5 produce identical scenes.

**Why pure, and why the split:** `Promotion` never mutates and `PromotionPerformer` does, and AREA.md calls the line between them load-bearing — it is what makes a preview honest and a plan testable. Same here: `plan` is a function of its inputs, so a test can assert placement without a scene to mutate, and `test_planningNeverMutatesTheScene` is the precedent to copy by name.

**Placement rules — all of these are requirements**

- **Right of what is already there.** The region's frame goes to the right of the bounding box of every measured node and every region, plus a gutter. An empty canvas gets a fixed origin. Deterministic: the same request against the same scene gives the same frame.
- **One column** of cards at `CanvasInteraction.defaultScrapWidth` (240, `CanvasInteraction.swift:10`), heights from Task 2, a fixed vertical gap. The region encloses them with padding, and is at least `CanvasRegionMetrics.minimumSide` on both axes (`CanvasInteraction.createRegion` refuses smaller, `:625-627` — a region the writer could not have swept is a region the canvas should not mint either).
- **The source item node goes at the top of the column** when `sourceReferenceID` is set, so reading order puts the page above what was read off it.
- **Ids get the uniqueness loop**, never a bare mint (tripwire 23). `CanvasInteraction.createScrap` (`:425-434`) and `newLineID(in:)` (`:442-448`) are the shape; the region's is `createRegion`'s (`:624-631`).
- **`author = .claude` on every node and line this creates — except the source item node.** **Ruling, and it is the one most likely to be argued with:** the tint means *these words came off a machine*, and the photograph is the writer's. Tinting its node would say Claude took the photograph. It also echoes the existing rule that an item node never gets a promoted stripe because *it already exists as itself* (`Maugham/Canvas/AREA.md`, "The drawn mark is PERMANENT chrome"). So the source item node carries **no author**.
- **A source item node that is already in the scene is reused, never duplicated and never moved.** `CanvasNodeID.item(_:)` derives the id from the reference precisely so "two adds of the same research item resolve to one node" (`CanvasNode.swift:14-19`). If it exists **and already has a home region**, the new region takes it as an **appearance** (`CanvasMembership.addAppearance`) rather than as a home — one home, many appearances (§4.3), and moving the writer's card would be a transition, which membership never is (tripwire 31). If it exists with no home, or is new, it joins the new region as a home member.
- **Membership is recorded through `CanvasMembership`, and no function in that type takes a point, a rect or an overlap.** Deciding is this file's job at *creation*; recording is `CanvasMembership`'s. Do not write `region.frame.contains(…)` — the scraps join because this call created them inside, which is a fact about the request, not a geometric test.
- **`connections` index the request's own `scraps`.** An index out of range and a self-pair are Task 7's refusals, not this file's — `plan` may assume a validated request, and its doc comment must say so.
- **Whitespace-only scraps never reach here** — also Task 7's refusal.

**Requirements**

- [ ] **Step 1 — failing tests in `CanvasClaudePlacementTests`:**
  - `test_planningNeverMutatesTheScene` — take a copy, plan, assert the scene is `==` its copy. `CanvasScene` is `Equatable` (`CanvasScene.swift:9`).
  - `test_theRegionLandsClearOfEverythingAlreadyOnTheCanvas` — with existing measured nodes and a region, the planned region's frame intersects none of them. **Then the disable experiment:** remove the gutter term, watch it fail, restore it, report.
  - `test_theCardsDoNotOverlapEachOther` — every planned scrap frame is disjoint from every other. This is what Task 2's real heights buy; with an estimate it fails on a long scrap.
  - `test_theSourcePageIsAboveWhatWasReadOffIt` — the item node's `origin.y` is less than every scrap's.
  - `test_theSourcePageCarriesNoAuthorAndTheScrapsDo` — the two assertions in one test, so neither can be quietly dropped.
  - `test_addingTheSamePageTwiceMakesOneNode` — plan twice with the same `sourceReferenceID`, apply both, assert `scene.count` grew by scraps-only on the second, and the second region **cites** the node while the first still **homes** it. Assert on `homeMembers` and `appearances` explicitly; a count alone passes if the node were duplicated under a different id.
  - `test_theSameRequestPlacesIdenticallyTwice` — determinism, ids excluded.
  - `test_aRegionIsNeverSmallerThanOneTheWriterCouldSweep` — both axes ≥ `CanvasRegionMetrics.minimumSide`, checked with a single very short scrap.
- [ ] **Step 2 — run, confirm failure.**
- [ ] **Step 3 — implement `Request`, `Plan`, `plan`, `apply`.**
- [ ] **Step 4 — `./gen.sh`**, then run `MaughamTests/CanvasClaudePlacementTests`, `MaughamTests/CanvasMembershipTests`, `MaughamTests/CanvasRegionInteractionTests`. Green.
- [ ] **Step 5 — grep your own new file for `frame.contains`** and for a bare `UUID()` outside a uniqueness loop. Both should return nothing.
- [ ] **Step 6 — commit.**

---

## Task 4 — the live seam: reaching an attached canvas from outside the window

**Files:** modify `Maugham/Stores/ProjectStore.swift`, `Maugham/Canvas/CanvasModel.swift`, `Maugham/Canvas/CanvasView.swift`, `Maugham/Views/ProjectWindow.swift`; create `MaughamTests/Canvas/CanvasLiveSeamTests.swift`.

**Interfaces — produces:**
- `ProjectStore.liveCanvas` — a **weak** reference to this project's `CanvasModel`, set by `ProjectWindow` at open time.
- `CanvasModel.isAttached: Bool` — true between `attach(projectRoot:)` and `detach()`.
- `CanvasModel.onSceneChangedExternally: (() -> Void)?` — the view's chance to re-derive after something outside the canvas changed the scene.

**The problem this solves, stated exactly.** `CanvasModel` is `@State` on `ProjectWindow` (`ProjectWindow.swift:76`), so no store owns it and an MCP tool — which gets only `ProjectRegistry.Entry` (id, url, store; `ProjectRegistry.swift:7-11`) — cannot reach it. **The precedent is `ProjectStore.documentStore`**, a `public weak var` "Set by ProjectWindow at open time" (`ProjectStore.swift:70-76`), assigned at `ProjectWindow.swift:1296`, and it is exactly how the translation tools reach a live `Document` instead of the on-disk `.md` (`TranslationTools.swift:14-33`, tripwire 20). Take that shape.

**Why `isAttached` and not "does a window exist".** The model is created eagerly with the window but `attach` runs from `CanvasView.onAppear` (`:315`, `load()` at `:448-451`) and `detach()` from `.onDisappear` (`:330-344`). A **detached** model has `store == nil`, so `scheduleSave` is a silent no-op (`CanvasModel.swift`, `store?.scheduleSave`), and its `scene` is whatever was last loaded — which the next `attach()` overwrites wholesale. **Symptom if the discriminator is window-existence:** Claude's scraps are accepted, reported with real ids, and vanish the next time the writer opens the Plan persona. Nothing goes red.

**Why the hook.** With the canvas on screen, adding nodes to the live model updates the scene but `layouts` has no entry for them, so `drawCard` receives `layout: nil`. **Symptom:** Claude's cards draw as empty rectangles until the writer happens to click something. `CanvasView` must rebuild layouts on an external change.

**Requirements**

- [ ] **Step 1 — failing tests in `CanvasLiveSeamTests`:**
  - `test_aFreshModelIsNotAttached` and `test_attachThenDetachFlipsIt` — `isAttached` false, true, false.
  - `test_theHookRunsWhenSomethingOutsideTheCanvasChangesTheScene` — set `onSceneChangedExternally`, drive Task 5's applier against the live model, assert it fired once.
  - `test_theHookIsNotCalledByAnOrdinaryCanvasEdit` — a `mutate` from the canvas's own path does not fire it. The canvas rebuilds its own layouts already; a second rebuild per gesture is work on the gesture path.
  - `test_detachClearsTheHook` — `detach()` nils it, alongside `beforeFlush` and `onSceneReplacedByUndo`. **`detach`'s doc comment spells out the retain cycle** (`CanvasView` is a struct captured by value into each closure and holds `let model`); a new closure that is not cleared keeps a closed window's whole canvas alive, its `CanvasStore` never deinits, and app quit writes the closed window's stale scene over whatever replaced it.
- [ ] **Step 2 — run, confirm failure.**
- [ ] **Step 3 — implement `isAttached` and `onSceneChangedExternally` on `CanvasModel`.** Both `@ObservationIgnored` where the existing callbacks are.
- [ ] **Step 4 — add `liveCanvas` to `ProjectStore`,** weak, doc-commented in the style of `documentStore` two properties up, naming *this* reason (an MCP tool must distinguish an attached canvas from the sidecar).
- [ ] **Step 5 — wire it in `ProjectWindow.load()`,** one line beside `s.documentStore = ds` (`:1296`). **No expression may be added to `ProjectWindow.body`** — this is in `load()`, which is not `body`.
- [ ] **Step 6 — bind the hook in `CanvasView.load()`** (`:448+`, beside `model.beforeFlush` and `model.onSceneReplacedByUndo`) to a layout rebuild that **does not** bump the structural counter — Task 5 bumps on its own line, and a double bump rebuilds the accessibility tree and the region inspector's cached lists twice for one change. `rebuildLayouts(bumpsStructuralCounter: false)` exists for exactly this and has two callers already (the undo apply and `deleteSelection`).
- [ ] **Step 7 — a caller census.** Add `test_theExternalChangeHookHasAProductionCaller` asserting by name that `CanvasView.swift` binds `onSceneChangedExternally` and `ProjectWindow.swift` assigns `liveCanvas`. **This area has produced five built-and-unreachable halves and every one was found by counting callers, never by a test** (1C-a's ⌘Z, `CanvasScene.remove`, `CanvasMembership.addAppearance`, `CanvasScene.lines(touching:)`, and the item placeholder Task 2 names). A census over a *required* token is the shape that passes while blind, so **give it a planted-offender companion** that deletes the token from a copy of the source and proves the assertion goes red.
- [ ] **Step 8 — run `MaughamTests/CanvasLiveSeamTests`, `MaughamTests/CanvasModelTests`, `MaughamTests/CanvasViewMountingTests`, `MaughamTests/CanvasUndoTests`.** Green. Then `-configuration Release build` — `ProjectWindow` was touched.
- [ ] **Step 9 — commit.**

---

## Task 5 — the applier: one definition, two routes

**Files:** create `Maugham/Canvas/CanvasClaudeWrite.swift`, `MaughamTests/Canvas/CanvasClaudeWriteTests.swift`; modify `MaughamTests/TripwireGrepTests.swift`.

**Interfaces — consumes:** Task 3's `Plan`/`apply`; Task 4's `liveCanvas`, `isAttached`, `onSceneChangedExternally`.

**Interfaces — produces:**
- `CanvasClaudeWrite.readScene(store:projectRoot:) -> (scene: CanvasScene, scraps: [CanvasNodeID: String], fromOpenCanvas: Bool)` — the attached-or-sidecar read, used by **both** tools.
- `CanvasClaudeWrite.apply(_ plan: CanvasClaudePlacement.Plan, store: ProjectStore, projectRoot: URL) throws` — the attached-or-sidecar write. **The plan is the whole payload**: it carries each scrap's text (Task 3), so there is no second parameter that could pair the wrong words with the wrong card.

**The two routes**

| | attached (`liveCanvas?.isAttached == true`) | otherwise |
|---|---|---|
| read | the model's `scene` and `scraps` | `CanvasStore(projectRoot:).load()` |
| write | `mutateFromInspector` → `setScrapText` per node → `bumpSceneRevision()` → `onSceneChangedExternally?()` → `flush()` | `CanvasStore.load()` → `CanvasClaudePlacement.apply` → `save(scene:scraps:)` |

**This is tripwire 32's fifth census entry, and its repro is the sharpest in the tripwire's history.** An MCP call can arrive while the writer holds "Edit Scrap" open — no gesture of the caller's own to protect, and *nothing on the far side of the window closes the writer's*. Through `mutate` the write nests: `beginGesture` takes no snapshot at depth 2, `endGesture` registers nothing above depth 0, so **Claude's nodes reach no undo step of their own and ride into the writer's next sentence** — a ⌘Z aimed at a sentence takes Claude's whole batch with it, and a quit before returning to the canvas drops the lot. `mutateFromInspector` is `CanvasUndo.mutateFromOutsideTheCanvas`: close, run, reopen — the same thing `CanvasUndo.undo()` already does.

**Ordering requirements, each with its symptom**

- **One bracket for the whole batch.** Region, source node, every scrap and every line in a single `mutateFromInspector`, so one ⌘Z takes back the whole add. This is §6.3's one-gesture-one-step rule, and the previous slice proved it by opening a second bracket and watching the one-⌘Z test go red.
- **Scrap text inside that bracket, before it closes.** A snapshot carries the scene *and* the scrap text together (`CanvasUndo`'s snapshot is `(scene, scraps)`), and text written after the close cannot be restored in step with its cards.
- **`bumpSceneRevision()` on its own line after the bracket**, exactly as `PromotionPerformer.mark` does. The accessibility tree and the region inspector's cached lists are keyed on it.
- **The hook after the bump, `flush()` last.** `flush()` writes whatever was queued; the hook re-measures. Reversed, the write lands before the heights do — and on this path the heights come from Task 3, so the visible failure is subtler: correct on disk, unmeasured in the layouts cache.
- **`flush()` rather than leaving the debounce.** A tool that returns "added" with the words still only in memory is a lie if the app is quit in the next 750 ms, and the crash floor here is real: the canvas has no op log behind it (`Maugham/Canvas/AREA.md`, "The crash floor").

**Requirements**

- [ ] **Step 1 — failing tests in `CanvasClaudeWriteTests`:**
  - `test_anAttachedCanvasIsWrittenThroughTheModel` — attach a model, apply, assert the model's scene has the nodes **and** that the sidecar on disk does too (the `flush`).
  - `test_aClosedCanvasIsWrittenToTheSidecar` — no attached model; apply; a fresh `CanvasStore(projectRoot:).load()` sees the nodes.
  - `test_bothRoutesProduceTheSameScene` — the same `Plan` through each route yields `==` scenes. This is what "one definition of where Claude puts things" means as an assertion.
  - `test_aDetachedModelDoesNotSwallowTheWrite` — a model that has been attached and then detached, still referenced by `liveCanvas`; apply; the sidecar has the nodes and a subsequent `attach()` reads them back. **The named symptom:** written into the detached model instead, the ids are reported, the tool succeeds, and the scraps are gone the next time the Plan persona opens.
  - `test_theWholeBatchIsOneUndoStep` — apply a plan of several scraps and a line, one ⌘Z, assert the scene is back to its prior value **and** that `CanvasUndo.undoMenuItemTitle` names one step. **The step name is the discriminator, not the scene:** an undo test whose only observable is the post-⌘Z scene cannot tell "its own step" from "folded into the neighbouring step", and that has produced a false green twice in this area on exactly this bug. Set `groupsByEvent = false` in the test; production must not.
  - `test_aWriteArrivingMidVisitDoesNotJoinTheWritersSentence` — open a gesture ("Edit Scrap"), apply, close the gesture; assert Claude's batch and the writer's typing are **two** steps with their own names. **Disable experiment:** swap `mutateFromInspector` for `mutate`, watch this go red, restore, report.
  - `test_theReadPrefersTheOpenCanvas` — attached model whose in-memory scene differs from the sidecar; `readScene` returns the model's and reports `fromOpenCanvas == true`.
- [ ] **Step 2 — run, confirm failure.**
- [ ] **Step 3 — implement.** No `inout` across an `await`; this file need not be `async` at all, and if it becomes so, remember an `inout CanvasScene` cannot cross a suspension point (that is a fact about Swift 6, not a style choice — `PromotionPerformer`'s whole shape follows from it).
- [ ] **Step 4 — join tripwire 32's census.** Add `"CanvasClaudeWrite.swift": [Self.canvasOutsideVerb]` to the expectation in `test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly` (`TripwireGrepTests.swift:1697-1718`) — the census walks every file under `Maugham/` containing `CanvasModel` (`:1596-1618`), so it will fail until this is done. Extend the failure message so it names the MCP arrival as a repro alongside the chrome-bar double-click.
- [ ] **Step 5 — run `MaughamTests/CanvasClaudeWriteTests`, `MaughamTests/TripwireGrepTests`, `MaughamTests/CanvasUndoTests`.** Green.
- [ ] **Step 6 — commit.**

---

## Task 6 — `list_canvas`

**Files:** create `Maugham/MCP/Tools/CanvasTools.swift`, `MaughamTests/MCP/Tools/CanvasToolsTests.swift`; modify `Maugham/MCP/MCPTool.swift`.

**Interfaces — consumes:** Task 5's `CanvasClaudeWrite.readScene`.

**Verified `MCPTool` shape (read 2026-07-30, `MCPTool.swift:11-31`):** `static var method: String`, `static var description: String`, `static var inputSchemaJSON: String`, and `@MainActor static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data`. **There is no `name` and no `run(projectRoot:)`.** `decodeParams(_:from:)` and `resolveProject(_:in:)` are protocol-extension helpers (`MCPToolHelpers.swift`); an unknown project id throws `MCPError.unknownProjectID`, not `invalidArgument`.

**Requirements**

- [ ] **Step 1 — failing tests:**
  - `test_itReportsEveryNodeRegionAndLine` — a scene with two scraps, an item node, a region with a home and an appearance, and a line; every one appears with its fields.
  - `test_itSaysWhereItRead` — `read_from` is `"open_canvas"` for an attached model and `"sidecar"` otherwise. **The reason it is in the payload:** `read_preview_page` puts `preview_filename`/`preview_mtime` in its response so staleness is self-evident rather than inferred; same discipline.
  - `test_itNamesTheAuthorOfClaudesNodesAndLines`.
  - `test_itSurfacesTheMarksTheInspectorShows` — `promoted_item_id`, `contributed_to_item_id`, `bound_piece_id` are all reported. Claude must not have to guess whether a card has already produced an artifact, and re-promoting a **contributing** card offers only a new artifact (spec §6.3) — so the two fields are distinguishable in the payload as they are in the model. **They must not be merged into one field.**
  - `test_itReportsWhichRegionEachCardLivesIn`, distinguishing home from appearance.
  - `test_anUnknownProjectFailsLoudly` — `MCPError.unknownProjectID`, via `resolveProject`.
  - `test_anEmptyCanvasIsNotAnError` — empty collections, not a throw. (`read_craft_intent`'s `exists: false` is the precedent: absence is a fact, not a failure.)
  - `test_aHugeCanvasFailsWithABudgetError` — build past the budget and assert a structured `payload_too_large`. `MCPResponseBudget.enforce(_:hint:)` caps text at 900 KB; scrap text is unbounded, so this tool **must** call `enforce` directly rather than lean on `MCPToolsCallHandler`'s backstop — the backstop only covers the `tools/call` path and every tool method is *also* registered as a top-level JSON-RPC method (`MaughamApp.registerTools`), which bypasses it. The hint must name a narrower alternative rather than dead-end the caller.
- [ ] **Step 2 — run, confirm failure.**
- [ ] **Step 3 — implement.** Snake_case keys throughout, matching every existing tool.
- [ ] **Step 4 — add `ListCanvasTool.self` to `MCPToolCatalog.all`** (`MCPTool.swift:37-92`). **That is the only registration step** — `MCPToolsListHandler` and `MaughamApp.registerTools` both derive from the catalog. If you are editing `MCPToolsListHandler`, stop.
- [ ] **Step 5 — bump the two counted doc literals to 53 in this commit**, so the suite never sits red: `CLAUDE.md`'s `**52 tools**` and `Maugham/MCP/AREA.md`'s `## Tool catalogue (52)` heading. Those two are the only ones `DocSyncTests` can see (it matches on `firstMatch`); **the three prose hits in `Maugham/MCP/AREA.md` are Task 10's** and no test guards them. Add this tool's catalogue entry to `AREA.md` while you are in it.
- [ ] **Step 6 — `./gen.sh`**, then run `MaughamTests/CanvasToolsTests`, `MaughamTests/MCPCatalogConsistencyTests`, `MaughamTests/MCPProtocolHandlersTests`, `MaughamTests/MCPToolsListSmokeTest`, `MaughamTests/ListMaughamToolsToolTests`, `MaughamTests/DocSyncTests`. All green — including `DocSyncTests`, because of Step 5.
- [ ] **Step 7 — commit.**

---

## Task 7 — `add_canvas_scraps`

**Files:** modify `Maugham/MCP/Tools/CanvasTools.swift`, `Maugham/MCP/MCPTool.swift`, `Maugham/Models/MaughamNotifications.swift`; modify `MaughamTests/MCP/Tools/CanvasToolsTests.swift`.

**Interfaces — consumes:** Task 3's `Request`/`plan`; Task 5's `apply`.

**Interfaces — produces:**
- Params: `project_id: String`, `scraps: [String]`, `source_item_id: String?`, `region_label: String?`, `connect: [[Int]]?`.
- Result: `region_id: String`, `node_ids: [String]`, `source_node_id: String?`, `line_ids: [String]`.
- `Notification.Name.maughamCanvasNodesAdded`, posted to `.project(id:)`.

**The signature is the guarantee.** Roadmap line 64: the write tool "can express no position, no node id and no region id, so where Claude's scraps land is the canvas's decision and not Claude's." **`connect` indexes this call's own `scraps` array**, so Claude can draw the arrows it read off a page and can reach nothing the writer made. **Do not add a `region_id`, a `node_id`, an `x`/`y` or a `width`** — any one of them breaks the guarantee, and a reviewer should reject the task for it.

**Refusals — every one fails loudly, and the sentence teaches**

- Empty `scraps`, or any entry that is whitespace-only. A blank card is indistinguishable from a rendering bug, and `Promotion` already treats emptiness as a real condition rather than a targets question.
- `source_item_id` not found in `store.manifest.research` via `TreeWalk.find(id:in:)`. **The sentence must teach the order**, because the likeliest wrong id is an *inbox entry* id: a capture is not a research item until it is promoted, and `add_canvas_scraps` takes a research item id. Name `promote_inbox_entry` in the message. (Spec §8A.4 records why this asymmetry exists and that the writer's own route does not have it.)
- A `connect` pair that is not exactly two elements, is out of range, or names the same index twice. **Fail rather than drop:** `CanvasScene.insertLine` silently refuses a self-line at the model boundary (`CanvasScene.swift:159`), which is right for the model and wrong for a tool — MCP tools fail loudly on bad ids, and a silently-dropped line is a caller believing something exists that does not.
- **All-or-nothing.** Validate everything before applying anything; a half-applied batch on a surface whose whole promise is predictability is worse than a refusal. `PromotionPerformer`'s validate-first rule, same reason.

**Requirements**

- [ ] **Step 1 — failing tests:**
  - `test_itAddsTheScrapsInARegionOfTheirOwn` — ids returned, scene and `canvas.md` both hold the words.
  - `test_theScrapsAreMarkedAsClaudes` — every created node's `author == .claude`.
  - `test_aNamedSourcePutsThePageInTheRegionWithThem` — `source_node_id` returned, the item node is in the region, and it carries **no** author.
  - `test_itRefusesAnInboxEntryIdAndSaysWhatToDo` — assert the message names `promote_inbox_entry`. A refusal that does not teach is the "Promote both cards first" failure recurring (it told a writer who had already promoted one card to do the thing they had done).
  - `test_connectDrawsLinesAmongTheNewScraps` — `connect: [[0,2]]` produces one line between the right two nodes, authored `.claude`.
  - `test_itRefusesAConnectionToNowhere` and `test_itRefusesASelfConnection` — both throw; assert **nothing at all** was written (all-or-nothing), not merely that the line is absent.
  - `test_itRefusesAnEmptyOrBlankScrap` — `[]` and `["   "]`.
  - `test_theSignatureCannotExpressAPositionOrAnId` — decode the tool's own `inputSchemaJSON` and assert its `properties` keys are exactly the five above. **This is the guarantee as a test rather than as a comment**, and it is the assertion that will still be here when someone adds `region_id` for convenience.
  - `test_itPostsForTheBanner` — the notification arrives, project-scoped, carrying the count and the region id.
- [ ] **Step 2 — run, confirm failure.**
- [ ] **Step 3 — implement,** validating fully before calling `plan`/`apply`.
- [ ] **Step 4 — declare the notification in `MaughamEvent`** with its scope (tripwire 21, ADR 0021): every post declares scope, and the receive helper owns the filter and the closed-window liveness guard. `.project(id:)` is the scope — `AddNoteTool` (`:63-71`) is the model.
- [ ] **Step 5 — add `AddCanvasScrapsTool.self` to `MCPToolCatalog.all`.**
- [ ] **Step 6 — the membrane check, and write the answer into the ADR in Task 10.** MCP tripwire 6: a write tool needs ADR-level justification. It is justified — the canvas is a planning surface in the parallel plane where Claude already writes annotations and translations, nothing here is manuscript, and nothing reaches the manuscript except through promotion, which is a writer act (§8A.2's own constitutional reasoning). **It writes `canvas.md` and `canvas.json` and nothing else** — assert that: `test_itNeverTouchesAManuscriptOrAResearchFile`, comparing a directory snapshot before and after.
- [ ] **Step 7 — bump the same two counted literals to 54** (`CLAUDE.md`, `Maugham/MCP/AREA.md`'s heading) and add this tool's catalogue entry, for the reason Task 6 Step 5 gives: the suite never sits red, and the three unguarded prose hits stay Task 10's.
- [ ] **Step 8 — `./gen.sh`**, run `MaughamTests/CanvasToolsTests`, `MaughamTests/MCPCatalogConsistencyTests`, `MaughamTests/MCPProtocolHandlersTests`, `MaughamTests/MCPToolsListSmokeTest`, `MaughamTests/ListMaughamToolsToolTests`, `MaughamTests/DocSyncTests`. All green.
- [ ] **Step 9 — commit.**

---

## Task 8 — the mark, drawn and announced

**Files:** modify `Maugham/Canvas/CanvasMaterial.swift`, `Maugham/Canvas/CanvasRenderer.swift`, `Maugham/Canvas/CanvasAccessibility.swift`; modify `MaughamTests/Canvas/CanvasMaterialTests.swift` (or the file holding `test_theCardIsLighterThanTheGroundInBothAppearances`), `MaughamTests/Canvas/CanvasRendererTests.swift`, `MaughamTests/Canvas/CanvasAccessibilityTests.swift`.

**Interfaces — produces:** a light/dark pair for Claude's card paper and one for Claude's line stroke, in `CanvasMaterial`.

**The look:** a Claude card's paper is a slightly cooler, slightly darker value than the writer's; a Claude line strokes in a correspondingly cooler value. Same ink, same shape, same hairline weight — one visual language, so "Claude's" is one thing to learn rather than three.

**Constraints, all of them already scarred into this area**

- **Every number the canvas's look is calibrated with lives in `CanvasMaterial.swift` and nowhere else.** Denver tunes these by eye against the running app; a constant he cannot find is a constant he cannot change.
- **Light and dark are two materials, not one texture inverted.** Every knob that differs is a *pair*. `cardPaper` is `textBackgroundColor` in light only and a dedicated 0.235 in dark, because the system colour is 0.118 there — *below* the raised ground, which turns a card into a hole cut out of the surface.
- **The card must stay lighter than the ground in both appearances, including at peak grain.** A card darker than its surface reads as a hole, not an object resting on it (§7.2) — as fatal as unreadable text. **Extend `test_theCardIsLighterThanTheGroundInBothAppearances` to cover the Claude paper**; it reads the grain amplitude, so this is a real ceiling and the test names it.
- **Author colours in sRGB.** `NSColor(calibratedRed:)` with the same digits resolves ~30% lighter and the lift is invisible in the source.
- **The ink must still contrast with the new paper in both appearances** — `test_theCardsInkContrastsWithItsPaperInBothAppearances`'s companion.
- **No new stripe.** `drawCard`'s adjacency warning already covers three marks; the promoted stripe and the resize triangle are unconditional and the connect dot lives inside the `isSelected` block. Moving any across that line is a design change, and a *fourth* mark of the same family is what §6.3 spent its length arguing against.
- **An item node is never tinted** — Task 3 gives it no author, and the renderer must not infer one. A hand-edited sidecar can put an author on an item node; refuse it in the renderer for the same reason the promoted stripe is refused there (it already exists as itself).
- **Raster fixtures run under DarkAqua.** Resolving a dynamic `NSColor` without `performAsCurrentDrawingAppearance` gives the dark value under a light-mode render — that is how a white-bitmap ink test came to measure zero ink and pass everywhere except a dark-mode Mac.

**Requirements**

- [ ] **Step 1 — failing tests:**
  - `test_claudesPaperIsCoolerThanTheWritersInBothAppearances` — compare resolved sRGB components under each appearance explicitly.
  - `test_theCardIsLighterThanTheGroundInBothAppearances` extended to the Claude paper at peak grain.
  - `test_theInkContrastsWithClaudesPaperInBothAppearances`.
  - `test_aClaudeCardDrawsDifferentlyFromTheWritersOwn` — the house raster instrument: two scenes differing in **exactly one model fact** (`author`), rendered through `ImageRenderer`, changed pixels counted and required to be non-trivial. Five such fixtures already exist to copy.
  - `test_aClaudeLineDrawsDifferentlyFromTheWritersOwn` — same shape. **This is the one to watch at smoke:** a 1.5 pt hairline at `lineOpacity` may be too quiet for a cooler value to read, and if so the answer is a recalibration in `CanvasMaterial`, not a second mark.
  - `test_anItemNodeIsNeverTinted` — an item node **with** `author == .claude` in the scene renders identically to one without. This is the ruling as an assertion, and it is the one a tidy-up would break.
  - `test_aScrapFromClaudeSaysSoWithTheKindStillFirst` — the label reads kind, then provenance, then the durable facts in the order they were added ("Scrap, from Claude, promoted, 1 line: …"). `CanvasAXRole` never reaches an assistive client, which is why the kind is in the *label*; hold the new term as a constant so the test asserts what ships, as `promotedTerm` and `regionKind` already do.
  - `test_aLineFromClaudeIsNamedAsSuchAtBothItsEnds` — `connectionPhrase` says it. **This is what carries a Claude line's provenance if the cooler hairline turns out too quiet to see**, so it is not optional politeness.
  - **Disable experiment** on the item-node exemption and on the accessibility term: remove each, watch the named test fail, restore, report.
- [ ] **Step 2 — run, confirm failure.**
- [ ] **Step 3 — implement.** Add the pairs to the `CanvasMaterial` table in `Maugham/Canvas/AREA.md` ("To change / Edit") in the same commit — that table is how Denver finds a knob.
- [ ] **Step 4 — the accessibility layer rides the existing `sceneRevision` rebuild** and adds no new frame path (tripwire 30). Do not key anything on `revision`.
- [ ] **Step 5 — run `MaughamTests/CanvasMaterialTests`, `MaughamTests/CanvasGroundTests`, `MaughamTests/CanvasRendererTests`, `MaughamTests/CanvasRegionRenderTests`, `MaughamTests/CanvasAccessibilityTests`.** Green.
- [ ] **Step 6 — commit.**

---

## Task 9 — what the writer sees

**Files:** modify `Maugham/Views/ProjectWindow.swift`, `Maugham/Canvas/ScrapInspector.swift`, `Maugham/Canvas/PromotedArtifactSection.swift` (if the provenance line lands there); modify `MaughamTests/Canvas/ScrapInspectorTests.swift`; create `MaughamTests/Canvas/CanvasClaudeBannerTests.swift`.

**Interfaces — consumes:** Task 7's `maughamCanvasNodesAdded`; Task 1's `author`.

**Why this task is not optional.** CLAUDE.md rule 8: every new data type needs a UI surface for inspection and action; MCP access alone is not enough. And the previous slice's Critical was precisely an asymmetry of this kind — a region drew the mark, carried the field and was announced, while its pane said nothing, so the writer could not learn what it had produced.

**Requirements**

- [ ] **Step 1 — failing tests:**
  - `test_theBannerNamesWhatClaudeAdded` — on the notification, the banner shows a count and the region's label.
  - `test_showTakesTheWriterToTheRegion` — the Show action switches to the Plan persona and the canvas segment and selects the region. `handleShowLatestMCPNote` (`ProjectWindow.swift:1289-1294`) is the precedent: it sets the binder segment and the selection, then dismisses.
  - `test_aClaudeCardSaysSoInItsInspector` — the scrap arm carries a provenance line.
  - `test_aCardWhoseSourceIsKnownNamesIt` — when the card's home region holds a source item node, the line reads "Read from “<title>”", resolved through the **deferred** `artifactTitle` closure `ScrapInspector` already holds. **A `store` is never read from a `body` or anything a `body` calls** — the deferred-closure pattern is the rule here, and `pieceTitle`/`artifactTitle`/`paletteSwatchHexes` are its three existing instances.
  - `test_theWritersOwnCardsSayNothingNew` — a nil-author card's inspector is unchanged. Guards against a line that reads "Added by you", which is chrome stating the default.
  - `test_theProvenanceLineIsNotTheMarkOrTheContribution` — a card that is authored **and** promoted **and** contributing shows three distinct sentences. §6.3's rule: one sentence for two records is the pane inviting the rewrite it forbids, and `Provenance` is a value on the model rather than an `if` in `body` because `_ConditionalContent` is branch-invariant and a `Form`'s contents are not inspectable.
- [ ] **Step 2 — run, confirm failure.**
- [ ] **Step 3 — implement.** Reuse `MCPNoteBanner` — the house pattern, as promotion did, rather than a second banner. Window-level behaviour goes in an **extracted `ViewModifier`** applied to `ProjectWindow.body` in one line (zero expression budget), and the subscription belongs in that modifier with the mount line censused, because the previous slice found that deleting a mount line leaves the subscription's text present in the same file and every test green while the feature is unreachable.
- [ ] **Step 4 — a `.keyWindow` post is dropped from inside a sheet or a dialog** (the v0.24.0 bug, recorded in `TranslationReviewModifier`). Nothing here should need one — the notification is `.project`-scoped — but if you reach for `.keyWindow`, that is the trap.
- [ ] **Step 5 — run `MaughamTests/ScrapInspectorTests`, `MaughamTests/CanvasClaudeBannerTests`, `MaughamTests/PromotionCommandTests`, `MaughamTests/TripwireGrepTests`.** Then `-configuration Release build` — `ProjectWindow.body` was touched, and the Release type-check budget is stricter than Debug.
- [ ] **Step 6 — commit.**

---

## Task 10 — the sweep, the counts, and the owed widening

**Files:** modify `CLAUDE.md`, `Maugham/MCP/AREA.md`, `Maugham/Canvas/AREA.md`, `docs/adr/0026-planning-canvas-rendering.md`, `docs/superpowers/specs/2026-07-25-planning-canvas-design.md`, `docs/roadmap.md`, `docs/guide/getting-started.md` (the canvas sections live there — `### The planning canvas` at `:26` through the promotion section at `:71-75`; there is no separate personas topic), `docs/skills/maugham-bootstrap/SKILL.md`, `Maugham/Canvas/CanvasRenderer.swift`; modify `MaughamTests/Canvas/CanvasRendererTests.swift`.

**Requirements**

- [ ] **Step 1 — the three UNGUARDED count literals.** Tasks 6 and 7 already moved the two `DocSyncTests` can see. The rest are prose no test reads, because that test matches on `firstMatch`: **`grep -n "52" Maugham/MCP/AREA.md` and fix every remaining hit** — lines 91-92 ("not part of the production 52-tool count above", "the 'Tool catalogue (52)' heading is unaffected") and line 153 ("the tool catalogue count stays 52"). Then re-grep to confirm nothing is left.
- [ ] **Step 2 — check both catalogue entries** Tasks 6 and 7 added to `Maugham/MCP/AREA.md` say what matters: that `list_canvas` reads the open canvas when there is one and the sidecar otherwise (the canvas's version of tripwire 20), and that `add_canvas_scraps`'s signature can express no position and no id, and why.
- [ ] **Step 3 — `CLAUDE.md`.** The tool count; the canvas row gaining the MCP surface; **and tripwire 32's cell, which must now say the census expects FIVE entries and repeat the instruction to count the array rather than the cell.** The cell already carries that instruction because the last slice shipped a "four files" claim over a five-entry array one directory over and it survived three review passes.
- [ ] **Step 4 — `Maugham/Canvas/AREA.md`.** A section for the MCP surface: the two routes and why `isAttached` is the discriminator, the applier as tripwire 32's fifth entry with its repro, the placement rules, the untinted item node, and Task 2's finding that nothing measures an item node. **And correct two sentences this slice makes false:**
  - the claim that **"1C-c3 is the slice that makes this reachable"** for `lineLabelBox` — `connect` carries no label (ruling 2), so c3 writes no label at all and does not make it reachable;
  - the claim that widening `lineLabelBox` **"wants a raster fixture rather than a one-word edit"** — it is a `static func` returning a `CGRect` from a value (`CanvasRenderer.swift:517-527`), so a unit assertion covers it.
  **Nothing guards this file. Every count in it is prose, and a wrong one has survived three review passes twice. Count the array, not the sentence.**
- [ ] **Step 5 — take the owed widening.** `CanvasRenderer.lineLabelBox` trims `.whitespaces` where `LineInspector.normalise` and `CanvasAccessibility.connectionPhrase` trim `.whitespacesAndNewlines`, so a `"\n"` label draws an **empty pill** and is not announced. AREA.md names the renderer as the one to widen. Still worth taking though c3 no longer makes it reachable: `CanvasSceneCodec` does not normalise labels on load, so a hand-edited sidecar remains a live route. Add `test_aWhitespaceOnlyLabelDrawsNoPill` asserting `.null` for `"\n"`, `"\t"` and `" "`, and **run the disable experiment** — restore `.whitespaces`, watch the `"\n"` case fail.
- [ ] **Step 6 — ADR 0026 gains decision 10.** The membrane justification Task 7 established; the two routes and the `isAttached` discriminator; provenance reusing `SourceKind` rather than a second enum; the mark surviving the writer's edit and the absent setter that follows; the untinted item node; schema 7 additive-optional on `NodeDTO`/`LineDTO`; tripwire 32's fifth entry; and **the honest limit — "structural here, visible at 1C-d"**, never "the corollary is satisfied". Close with the constitution principles it answers to, as decision 9 does.
- [ ] **Step 7 — the spec.** Close §10's "**The shape of the MCP canvas write surface** — one tool or several, and how a region is addressed when Claude groups a photo with what it read" with the strikethrough-plus-resolution form §10's first bullet already uses: **two tools, and a region is addressed not at all — the write signature can express no id, so the canvas decides.** Add a §8A.2 amendment recording the five rulings and the promote-first precondition on Claude's source (§8A.4 already records that the writer's route does not have it).
- [ ] **Step 8 — the roadmap.** Flip 1C-c3 from • to ✓ with the house-style entry, and **correct line 64's tool list** — it says `list_canvas` and `add_canvas_scraps`, which is right, but its guarantee sentence should now cite `connect` as how lines are drawn without ids.
- [ ] **Step 9 — the guide and the bootstrap skill.** Help surfaces describe what **ships**. `docs/guide/getting-started.md`'s canvas sections gain: what Claude may put on the canvas, that it is visibly marked, that ⌘Z takes back a whole batch, and that promotion is how any of it becomes durable. The bootstrap skill gains the **order** for a photographed page — `list_inbox` → `promote_inbox_entry` → `read_document` → `add_canvas_scraps(source_item_id:)` — because that order is not guessable and `read_inbox_entry` returns no image (text, transcript, kind and asset *filename* only). Intent over procedure: give the deliverable and what matters, not a script (`memory/feedback_skill_authoring_intent.md`).
- [ ] **Step 10 — full suite, both schemes, Release.** Mac with `-skip-testing:MaughamTests/MCPServerLifecycleTests`; phone; `-configuration Release build`. `DocSyncTests` must now be green.
- [ ] **Step 11 — commit.**

---

## After the tasks

- [ ] **Whole-branch review, and give it this plan plus the task ledger.** It has found a Critical or a cross-surface contradiction in **every** slice of 1C-c2 — an untyped mark that let a second promotion destroy a palette card, a region told "Became the palette card" when it became a note, a confirmation banner contradicting its own preview one second earlier. None was visible to a per-task reviewer. Budget for it.
- [ ] **Read the working tree after any abnormally-ended subagent run.** Two agents were cut off during the previous slice and one left a **planted defect** in the tree — the exact fallback that would have let a contributor rewrite a joint note — with its own comment admitting it. Uncommitted, and nothing would have failed.
- [ ] **Count tripwire 32's census array** and check it against every prose claim about it in `CLAUDE.md` and both `AREA.md`s.
- [ ] **Grep for production callers of everything this slice added** — one command per new function. Five built-and-unreachable halves in this area, every one found this way and none by a test.
- [ ] **Smoke, by Denver**, on the dev build with `mcp__maugham_test__*` available. Worth watching: whether the cooler paper reads at a glance and at a zoomed-out camera; whether the cooler **hairline** reads at all; whether a batch arriving while a scrap is focused leaves the writer's sentence intact and takes one ⌘Z of its own; and whether the placeholder source card is enough to make the region legible before 1C-d's thumbnail.
- [ ] **Do not push or tag.** M1 ships when 1A, 1B and the whole of 1C are in. Slicing the implementation is fine; slicing the release is not.
