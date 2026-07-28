# M1C-c2 — promotion

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:subagent-driven-development` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One previewable verb turns a scrap, a region or a line into a durable artifact — a research note, a palette card, a craft-intent statement, a piece binding, or a `[[wiki-link]]` — and the canvas records what it produced.

**Architecture:** Four objects with a sharp pure/impure line. `Promotion` is a pure function of `(source, target, scene, scraps, artifact index)` producing a `PromotionPlan` that *never* mutates anything — that is what makes the preview honest. `PromotionPerformer` is `@MainActor async throws`, validates the whole plan before it writes a byte, and reaches the artifacts only through `ProjectStore`'s existing APIs. `PromotionSheet` is a view over a plan. The mark is two optional fields on the scene (sidecar schema 3 → 4). One command — `Promote…`, ⌘⇧↩ — acts on `CanvasModel.selection`, and every inspector button posts that same command, so the button and the keystroke cannot drift.

**Tech Stack:** Swift 6, SwiftUI + AppKit, XCTest. Mac target only — `Packages/MaughamCore` and `MaughamPhone` are untouched, exactly as 1C-a, 1C-b and 1C-c1 were.

---

## Global Constraints

- **Spec §6 and §6.1** (`docs/superpowers/specs/2026-07-25-planning-canvas-design.md`), including the **2026-07-28 amendment** carrying this slice's four rulings. Quote §6.1; **do not write "deviation" anywhere, least of all in an ADR** — an earlier §6.1 draft read "when both ends are text" and was corrected on 2026-07-25, and an ADR is permanent.
- **A promotion is a SNAPSHOT and never syncs.** The mark is provenance, not a live link. Nothing reconciles because nothing is promised.
- **Re-promoting offers Update or New and neither is the default** — for `.researchNote` and `.paletteCard` only. `.intentStatement` always appends; `.pieceBinding` and `.wikiLink` have no update.
- **Tripwire 32.** `PromotionPerformer.swift` is not `CanvasView.swift`, so every scene change it makes uses `CanvasModel.mutateFromInspector` and it **joins the census expectation by name in the same commit** (`MaughamTests/TripwireGrepTests.swift:1694`). `beginPromotion` runs while "Edit Scrap" may be open, so this is not a formality.
- **`flushPendingSave()` before every body write** (`DocumentStore.swift:259`; the reasoning is at `AddNoteTool.swift:48-55`) — a queued 750 ms `scheduleFileSave` otherwise fires after the write and blanks it.
- **Validate first, write second.** A refused promotion leaves nothing behind.
- **`ProjectWindow.body` has a zero expression budget.** New window-level behaviour goes in an extracted `ViewModifier` (the house pattern: `PersonaModifier`, `PaletteSegmentModifier`, `TranslationReviewModifier`) applied in **one** line.
- **A `store` on a canvas view may never be read from `body`, or anything `body` calls.** `ProjectStore` is `@Observable`; one read in a body tree re-evaluates that tree on every manifest mutation, including the `modified` bump an autosave in another pane produces. `paletteSwatchHexes` is a deferred closure for exactly this reason.
- **`CanvasView.swift` has five source-layout contracts** in its header, enforced by tests that slice the file as *text*. Contract 1 *crashes* rather than fails; contract 5 fails if certain accessibility modifiers are named **in a comment**. This plan does not need to touch that file — if a task finds it must, read the header first.
- **Every look constant lives in `CanvasMaterial.swift`** and nowhere else. Light and dark are two materials, not one inverted; a knob that differs is a *pair*.
- Run `xcodebuild` in the **foreground**, one at a time — two invocations contend for one DerivedData. **Never dispatch two implementers at once**; they share the working tree.
- `-only-testing` takes `MaughamTests/<ClassName>`, **never a folder path** (runs zero tests, reports success).
- `./gen.sh` after adding any file; `project.yml` uses folder globs, so no manifest edit. **Never commit anything under `Maugham.xcodeproj/`.**
- SourceKit's `No such module` / `Cannot find type … in scope` is stale-index noise. The one real diagnostic is *"unable to type-check this expression in reasonable time"*.
- **Do not assert platform behaviour from this plan.** Where a step says "measure", measure. Five of 1C-c1's plan premises were false and every one was caught by measurement rather than by argument.

---

## Cross-plan API verification — read before Task 1

Every fact below was checked against the file named, on `main` at `566b34d`. If one is false, **stop and re-derive** rather than working around it.

| Fact | Where |
|---|---|
| `CanvasNode.init(id:kind:origin:width:cachedHeight:z:)` — no promoted field yet | `Maugham/Canvas/CanvasNode.swift:50` |
| `CanvasRegion.init(id:label:frame:homeMembers:appearances:boundPieceID:isCollapsed:)` | `Maugham/Canvas/CanvasRegion.swift:67` |
| `CanvasSceneDTO.currentSchemaVersion = 3`; `regions`/`lines` optional | `Maugham/Canvas/CanvasSceneCodec.swift:10-19` |
| `CanvasStore.load()` returns an **empty layout with the scraps intact** for a schema above its own | `Maugham/Canvas/CanvasStore.swift:74-78` |
| `CanvasScene.node/region/line`, `updateRegion`, `setCachedHeight` | `Maugham/Canvas/CanvasScene.swift:61,145,215,164,95` |
| `CanvasModel.mutateFromInspector(_:_:)`, `bumpSceneRevision()`, `selection`, `selectedRegion`, `selectedLine` | `Maugham/Canvas/CanvasModel.swift:275,231,26,28,40` |
| `RegionInspector.PieceChoice(id:title:)` — nested in the SwiftUI view | `Maugham/Canvas/RegionInspector.swift:74` |
| `ProjectWindow.pieceChoices(in:) -> [RegionInspector.PieceChoice]` already exists | `Maugham/Views/ProjectWindow.swift:1149` |
| `CanvasRegion.displayLabel` / `untitledLabel` already exist | `Maugham/Canvas/CanvasRegion.swift:85,51` |
| `CanvasRenderer.chipTitle(for:in:scraps:)` | `Maugham/Canvas/CanvasRenderer.swift:574` |
| `store.addResearchTextNote(parentId:title:) async throws -> ResearchItem` — creates an **empty** file; dedupes the title | `Maugham/Stores/ProjectStore+Research.swift:120` |
| `store.updateResearchItem(id:title:…) async throws` — renames the backing file through the typed mover | `Maugham/Stores/ProjectStore+Research.swift:572` |
| `store.addPaletteCard(title:kind:) async throws -> ResearchItem` — writes the template, not a body | `Maugham/Stores/ProjectStore+Palette.swift:51` |
| `store.updatePaletteCard(_ card: PaletteCard) async throws` | `Maugham/Stores/ProjectStore+Palette.swift:102` |
| `store.loadPaletteCards() -> [PaletteCard]` | `Maugham/Stores/ProjectStore+Palette.swift:82` |
| `PaletteCard(researchItemId:title:kind:swatches:notes:imagePaths:body:)`; `Kind` = `location, character, motif, other` | `Packages/MaughamCore/Sources/MaughamCore/PaletteCard.swift:58` |
| `store.createCraftIntent(forPieceId:) async throws -> ResearchItem` — find-or-create, idempotent | `Maugham/Stores/ProjectStore+CraftIntent.swift:33` |
| `store.craftIntentItem(forPieceId:) -> ResearchItem?` | `Maugham/Stores/ProjectStore+CraftIntent.swift:19` |
| `DocumentStore.flushPendingSave() async throws`; `performFileSave(path:text:) async throws` (`internal`) | `Maugham/Stores/DocumentStore.swift:259,268` |
| `RegionBinding.bind(_:toPiece:in:)` / `.unbind` | `Maugham/Canvas/RegionBinding.swift:14,19` |
| `MaughamEvent.post(_:to:object:payload:)`; `View.onKeyWindowCommand(_:window:perform:)` | `Maugham/Events/MaughamEvent.swift:64`; `Maugham/Events/MaughamEvent+Receive.swift:18` |
| `.maughamPromotePiece` **already exists** for collection pieces — a canvas one needs a distinct name | `Maugham/Models/MaughamNotifications.swift:126` |
| `⌘⇧P` is taken ("Toggle Research Preview"); `⌘⇧↩` is free | `Maugham/MaughamApp.swift:205-208` |
| `FocusedProjectURLKey` + `.focusedSceneValue(\.projectURL, …)` is the established focused-value idiom | `Maugham/MaughamApp.swift:393`; `Maugham/Views/ProjectWindow.swift:440` |
| **A `.keyWindow` post from inside a sheet/dialog is DROPPED** — the dialog's window holds key status (the v0.24.0 enter-does-nothing bug) | `Maugham/Views/ProjectWindow.swift:1750-1755` |
| Tripwire 32 census expectation is `{LineInspector.swift, RegionInspector.swift} → mutateFromInspector`; keys on files containing the string `CanvasModel` | `MaughamTests/TripwireGrepTests.swift:1596-1616,1694` |
| `ListAllLinksTool` scans `[[…]]` in **manuscript documents only** (its title index does cover research) | `Maugham/MCP/Tools/ListAllLinksTool.swift:43-49,93` |
| `find_references` scans **manuscript documents only** | `Maugham/MCP/Tools/ReferenceTools.swift:180` |
| `render(scene:size:selection:scraps:…)` + `CanvasPage.differingPixels(from:in:)` are the raster harness | `MaughamTests/Canvas/CanvasRasterPage.swift:112,88` |
| The MCP test project helper pattern (per-file, no shared fixture) | `MaughamTests/MCP/Tools/ListAllLinksToolTests.swift:7-51` |

**One naming note that is deliberate, not an oversight:** `Promotion.swift` references `RegionInspector.PieceChoice`, a type nested inside a SwiftUI view. Minting a second piece-choice type so the pure model could avoid it would leave two spellings of the same thing one file apart, which is worse. It stays.

---

## File Structure

| File | Responsibility |
|---|---|
| `Maugham/Canvas/CanvasNode.swift` *(modify)* | `promotedItemID` on the node |
| `Maugham/Canvas/CanvasRegion.swift` *(modify)* | `promotedItemID` on the region |
| `Maugham/Canvas/CanvasScene.swift` *(modify)* | `setPromotedItem(_:for:)` |
| `Maugham/Canvas/CanvasSceneCodec.swift` *(modify)* | schema 4, additive-optional both ways |
| `Maugham/Canvas/Promotion.swift` *(new)* | §6's table executable. Pure; never mutates |
| `Maugham/Canvas/PromotionPerformer.swift` *(new)* | The writes. `@MainActor async throws`, no `inout` |
| `Maugham/Canvas/PromotionSheet.swift` *(new)* | `PromotionSheetModel` + the sheet view |
| `Maugham/Canvas/ScrapInspector.swift` *(new)* | The third inspector arm: what a card became |
| `Maugham/Canvas/RegionInspector.swift` *(modify)* | Third arm in the pane; `Promote…` button |
| `Maugham/Canvas/LineInspector.swift` *(modify)* | `Promote…` button |
| `Maugham/Canvas/CanvasModel.swift` *(modify)* | `selectedNode` resolver |
| `Maugham/Canvas/CanvasMaterial.swift` *(modify)* | The promoted mark's numbers |
| `Maugham/Canvas/CanvasRenderer.swift` *(modify)* | Draw the mark |
| `Maugham/Canvas/CanvasAccessibility.swift` *(modify)* | Announce it |
| `Maugham/Models/MaughamNotifications.swift` *(modify)* | `.maughamPromoteCanvasSelection` |
| `Maugham/MaughamApp.swift` *(modify)* | The menu item, ⌘⇧↩, the focused value |
| `Maugham/Views/ProjectWindow.swift` *(modify)* | `CanvasPromotionModifier` + one `.modifier` line + the inspector's two new arguments |
| `Maugham/MCP/Tools/ListAllLinksTool.swift` *(modify)* | Research bodies join the wiki scan |
| `Maugham/MCP/Tools/ReferenceTools.swift` *(modify)* | Same, for `find_references` |

Tests land in `MaughamTests/Canvas/` beside their subject, except the two MCP suites, which extend `MaughamTests/MCP/Tools/`.

---

### Task 1: The mark, and sidecar schema 3 → 4

**Files:**
- Modify: `Maugham/Canvas/CanvasNode.swift`, `Maugham/Canvas/CanvasRegion.swift`, `Maugham/Canvas/CanvasScene.swift`, `Maugham/Canvas/CanvasSceneCodec.swift`
- Test: `MaughamTests/Canvas/CanvasPromotionCodecTests.swift`

**Interfaces:**
- **Consumes:** `CanvasNode`, `CanvasRegion`, `CanvasScene`, `CanvasSceneDTO` as they stand today.
- **Produces:** `CanvasNode.promotedItemID: String?`; `CanvasRegion.promotedItemID: String?`; `CanvasScene.setPromotedItem(_ itemID: String?, for id: CanvasNodeID)`; `CanvasSceneDTO.currentSchemaVersion == 4` with `NodeDTO.promotedItemID: String?` and `RegionDTO.promotedItemID: String?`.

**Both new parameters go LAST in their initialisers, with a `nil` default**, so every existing construction — production and test — keeps compiling. A region's mark has no dedicated mutator: `updateRegion(_:_:)` already exists and adding a second spelling would be two ways to write one field.

**A promoted id is not validated here and cannot be.** The scene has never seen the manifest. A writer who deletes the note leaves a dangling mark, and the answer is at the *readers* (Task 2's artifact index), not at the disk boundary.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/CanvasPromotionCodecTests.swift`:

```swift
import XCTest
@testable import Maugham

/// The promoted mark, across the disk boundary. Schema 4 is additive-optional
/// in BOTH directions, which is the pattern every canvas bump has kept: an
/// older sidecar decodes unchanged, and a newer one costs an older build the
/// arrangement and never the words (`CanvasStore.load`).
final class CanvasPromotionCodecTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let r1 = CanvasRegionID("r1")

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 10, y: 20),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [a]))
        return s
    }

    private func roundTrip(_ s: CanvasScene) throws -> CanvasScene {
        let data = try JSONEncoder().encode(CanvasSceneDTO(scene: s))
        return try JSONDecoder().decode(CanvasSceneDTO.self, from: data).scene
    }

    func test_theSchemaIsFourBecauseThisSliceAddedAField() {
        XCTAssertEqual(CanvasSceneDTO.currentSchemaVersion, 4)
    }

    func test_aPromotedScrapKeepsItsArtifactAcrossASaveAndLoad() throws {
        var s = scene()
        s.setPromotedItem("res-9", for: a)
        XCTAssertEqual(try roundTrip(s).node(a)?.promotedItemID, "res-9")
    }

    func test_aPromotedRegionKeepsItsArtifactAcrossASaveAndLoad() throws {
        var s = scene()
        s.updateRegion(r1) { $0.promotedItemID = "res-fog" }
        XCTAssertEqual(try roundTrip(s).region(r1)?.promotedItemID, "res-fog")
    }

    func test_theMarkCanBeTakenOffAgain() throws {
        var s = scene()
        s.setPromotedItem("res-9", for: a)
        s.setPromotedItem(nil, for: a)
        XCTAssertNil(try roundTrip(s).node(a)?.promotedItemID)
    }

    /// A schema-3 sidecar — every canvas 1C-c1 wrote — decodes unchanged rather
    /// than throwing on a missing key. The fixture is a LITERAL, not a re-encode
    /// of today's DTO: a test that writes its own input cannot see a key that
    /// stopped being optional.
    func test_aSchemaThreeSidecarDecodesWithNoMarksAndLosesNothingElse() throws {
        let json = """
        {"schemaVersion":3,
         "nodes":[{"id":"a","kind":"scrap","x":10,"y":20,"width":240,
                   "cachedHeight":80,"z":0}],
         "regions":[{"id":"r1","label":"Act II fog","x":0,"y":0,"width":600,
                     "height":400,"homeMembers":["a"],"appearances":[],
                     "isCollapsed":false}],
         "lines":[]}
        """
        let decoded = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8))
        let s = decoded.scene
        XCTAssertNil(s.node(a)?.promotedItemID)
        XCTAssertNil(s.region(r1)?.promotedItemID)
        XCTAssertEqual(s.node(a)?.width, 240, "the rest of the file must survive the bump")
        XCTAssertEqual(s.region(r1)?.homeMembers, [a])
    }

    /// An unpromoted canvas's sidecar must not gain a key. MEASURED rather than
    /// asserted from Codable's synthesis rules: if this ever starts writing
    /// `"promotedItemID":null` on every node, every writer's next save is a
    /// whole-file diff for a feature they have not used.
    func test_anUnpromotedCanvasWritesNoPromotedKeyAtAll() throws {
        let data = try JSONEncoder().encode(CanvasSceneDTO(scene: scene()))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("promotedItemID"), "found it in: \(text)")
    }

    /// The loader drops a node of an unknown kind (a canvas from a newer build).
    /// Its mark goes with it — there is nothing left for the mark to be about.
    func test_aMarkOnADroppedNodeGoesWithTheNode() throws {
        let json = """
        {"schemaVersion":4,
         "nodes":[{"id":"ghost","kind":"hologram","x":0,"y":0,"width":100,"z":0,
                   "promotedItemID":"res-ghost"}],
         "regions":[],"lines":[]}
        """
        let s = try JSONDecoder().decode(CanvasSceneDTO.self, from: Data(json.utf8)).scene
        XCTAssertTrue(s.isEmpty)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasPromotionCodecTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `value of type 'CanvasNode' has no member 'promotedItemID'`.

- [ ] **Step 3: Add the field to `CanvasNode`**

In `Maugham/Canvas/CanvasNode.swift`, inside `struct CanvasNode`, after `public var z: Int`:

```swift
    /// The durable artifact this scrap has been promoted into, if any (spec §6).
    ///
    /// **Provenance, not a live link.** A promotion is a SNAPSHOT taken by an
    /// explicit act and it never syncs — edit the card afterwards and the note
    /// does not change, edit the note and the card does not. Spec §6.1's
    /// 2026-07-28 amendment records why: the region row already works that way
    /// (promoting a region joins six cards' text while all six stay), so a
    /// scrap that behaved differently would give one verb two rules.
    ///
    /// **Nothing here validates it against the manifest, and nothing can** —
    /// the scene has never seen one. A writer who deletes the note leaves an id
    /// that resolves to nothing, and every reader resolves it through
    /// `ArtifactIndex` rather than trusting it.
    public var promotedItemID: String?
```

Add the parameter to the initialiser, **last**, with a default:

```swift
    public init(id: CanvasNodeID,
                kind: CanvasNodeKind,
                origin: CGPoint,
                width: CGFloat,
                cachedHeight: CGFloat? = nil,
                z: Int = 0,
                promotedItemID: String? = nil) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.width = width
        self.cachedHeight = cachedHeight
        self.z = z
        self.promotedItemID = promotedItemID
    }
```

- [ ] **Step 4: Add the field to `CanvasRegion`**

In `Maugham/Canvas/CanvasRegion.swift`, after `public var isCollapsed: Bool`:

```swift
    /// The palette card this region has been promoted into, if any (spec §6).
    /// Same provenance-not-a-link rule as `CanvasNode.promotedItemID`, and the
    /// same absence of validation — see there.
    ///
    /// Deliberately NOT `boundPieceID`'s sibling in meaning: a binding is a live
    /// relationship 1A's reference rail reads every time it draws, and this is a
    /// record of something that happened once.
    public var promotedItemID: String?
```

and the initialiser gains `promotedItemID: String? = nil` **after** `isCollapsed`, assigned in the body.

- [ ] **Step 5: Add the scene mutator**

In `Maugham/Canvas/CanvasScene.swift`, after `setCachedHeight(_:for:)`:

```swift
    /// Record (or clear) the artifact a scrap was promoted into.
    ///
    /// A region's mark goes through `updateRegion(_:_:)`, which already exists —
    /// a second spelling would be two ways to write one field.
    public mutating func setPromotedItem(_ itemID: String?, for id: CanvasNodeID) {
        byID[id]?.promotedItemID = itemID
    }
```

- [ ] **Step 6: Bump the codec**

In `Maugham/Canvas/CanvasSceneCodec.swift`:

```swift
    static let currentSchemaVersion = 4   // was 3 (lines, 1C-c1)
```

Add `var promotedItemID: String?` as the **last** property of both `NodeDTO` and `RegionDTO`, populate it in `init(scene:)` (`promotedItemID: n.promotedItemID` and `promotedItemID: r.promotedItemID`), and pass it through in `var scene` — `CanvasNode(…, z: dto.z, promotedItemID: dto.promotedItemID)` and `CanvasRegion(…, isCollapsed: dto.isCollapsed, promotedItemID: dto.promotedItemID)`.

Update the doc comment on `lines` — the "schema-2 sidecar" note — by adding beside it:

```swift
    /// Optional so a schema-3 sidecar — every canvas 1C-c1 wrote — decodes
    /// unchanged. **1C-c2 added `promotedItemID` to nodes and regions rather
    /// than a key of its own here**, which is why this bump has no new
    /// top-level collection: the mark belongs to the thing it marks.
```

- [ ] **Step 7: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasPromotionCodecTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 7 tests.

Then the two suites that own the sidecar, because a schema bump reaches them:

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasStoreTests -only-testing MaughamTests/CanvasRegionCodecTests -only-testing MaughamTests/CanvasLineCodecTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS. **If one of them asserts the literal `3`, that is the bump doing its job** — update it to 4 and say in the commit which assertion moved.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Canvas/CanvasNode.swift Maugham/Canvas/CanvasRegion.swift \
        Maugham/Canvas/CanvasScene.swift Maugham/Canvas/CanvasSceneCodec.swift \
        MaughamTests/Canvas/CanvasPromotionCodecTests.swift
git commit -m "feat(canvas): a card and a region remember what they became

Sidecar schema 3 -> 4, additive-optional both ways. The mark is provenance,
not a live link: a promotion is a snapshot and never syncs (spec 6.1's
2026-07-28 amendment). Nothing validates the id against the manifest because
the scene has never seen one - the readers resolve it instead.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeXFCPAiAdnJ2mMCdRLvH8"
```

---

### Task 2: `Promotion` — §6's table executable, and a preview that never mutates

**Files:**
- Create: `Maugham/Canvas/Promotion.swift`
- Test: `MaughamTests/Canvas/PromotionTests.swift`

**Interfaces:**
- **Consumes:** `CanvasScene` (`node(_:)`, `region(_:)`, `line(_:)`, `lines`), `CanvasNode` (`kind`, `origin`, `promotedItemID` — Task 1), `CanvasRegion` (`label`, `homeMembers`, `promotedItemID` — Task 1), `CanvasLine` (`from`, `to`, `label`); `RegionInspector.PieceChoice` (`id`, `title`); `PaletteCard.Kind` and `ResearchItem` from `MaughamCore`; `TreeWalk.collect(in:where:)`.
- **Produces:** `PromotionSource`, `PromotionTarget`, `PromotionMode`, `PromotionDiscard`, `PromotionLinkOffer`, `WikiLinkWrite`, `ArtifactIndex`, `PromotionRequest`, `PromotionPlan`, and `enum Promotion` with `targets(for:in:artifacts:)`, `blockedReason(for:in:artifacts:)`, `existingArtifact(for:target:in:artifacts:)`, `modes(for:existing:)`, `plan(_:in:)`, `title(from:)`, `linkText(to:label:)`.

**`plan` takes `scene: CanvasScene`, not `inout`.** Building a preview never mutates anything, and that is what makes the preview honest. It is also the shape that survives contact with the performer, which is `async` — an `inout CanvasScene` cannot cross an `await` in Swift 6.

**Why a line's ends must already be promoted, quoted from spec §6.1:** *"`[[X]]` resolves against the manifest — documents and research items — and a scrap is in neither, so promoting a line between two unpromoted scraps would write a link that resolves to nothing."* `blockedReason` exists so the sheet teaches the precedence at the moment it costs the writer something, instead of showing an empty list.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/PromotionTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

/// Spec §6's table, executable — and §6.1's rules, including the one that
/// refuses. Every function here is pure: `test_planningNeverMutatesTheScene`
/// is what keeps the preview honest.
final class PromotionTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let img = CanvasNodeID.item("r-9")
    private let r1 = CanvasRegionID("r1")
    private let l1 = CanvasLineID("l1")
    private let l2 = CanvasLineID("l2")

    /// `a` sits above `b`, so the region body's reading order is testable.
    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 0, y: 0),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 0, y: 200),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: img, kind: .item(referenceId: "r-9"),
                            origin: CGPoint(x: 800, y: 0), width: 180, cachedHeight: 120))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [a, b]))
        s.insertLine(CanvasLine(id: l1, from: a, to: b))
        s.insertLine(CanvasLine(id: l2, from: a, to: img))
        return s
    }

    private let texts: [CanvasNodeID: String] = [
        CanvasNodeID("a"): "The falls at night.\n\nSodium light on the spray.",
        CanvasNodeID("b"): "October's doctor was kind about it.",
    ]

    private let piece = RegionInspector.PieceChoice(id: "piece-3", title: "Chapter Three")

    private func index(_ pairs: [String: String] = [:]) -> ArtifactIndex {
        ArtifactIndex(titlesByID: pairs)
    }

    private func request(_ source: PromotionSource,
                         _ target: PromotionTarget,
                         scene: CanvasScene? = nil,
                         mode: PromotionMode = .new,
                         piece: RegionInspector.PieceChoice? = nil,
                         kind: PaletteCard.Kind = .other,
                         artifacts: ArtifactIndex? = nil,
                         destinationBody: String? = nil) -> PromotionRequest {
        PromotionRequest(source: source, target: target, mode: mode, scraps: texts,
                         piece: piece, paletteKind: kind,
                         artifacts: artifacts ?? index(), destinationBody: destinationBody)
    }

    // MARK: - §6's table, exactly

    func test_aScrapCanBecomeANoteAPaletteCardOrAnIntent() {
        XCTAssertEqual(Set(Promotion.targets(for: .scrap(a), in: scene(), artifacts: index())),
                       [.researchNote, .paletteCard, .intentStatement])
    }

    func test_aRegionCanBecomeAPaletteCardOrAPieceBinding() {
        XCTAssertEqual(Set(Promotion.targets(for: .region(r1), in: scene(), artifacts: index())),
                       [.paletteCard, .pieceBinding])
    }

    func test_anItemNodeOffersNothingBecauseItAlreadyExists() {
        XCTAssertTrue(Promotion.targets(for: .scrap(img), in: scene(),
                                        artifacts: index()).isEmpty)
    }

    func test_anUnknownSourceOffersNothing() {
        let s = scene()
        XCTAssertTrue(Promotion.targets(for: .scrap(CanvasNodeID("ghost")), in: s,
                                        artifacts: index()).isEmpty)
        XCTAssertTrue(Promotion.targets(for: .region(CanvasRegionID("ghost")), in: s,
                                        artifacts: index()).isEmpty)
        XCTAssertTrue(Promotion.targets(for: .line(CanvasLineID("ghost")), in: s,
                                        artifacts: index()).isEmpty)
    }

    // MARK: - A line links two DURABLE things or nothing (§6.1)

    func test_aLineBetweenTwoUnpromotedScrapsOffersNothingAndSaysWhy() {
        let s = scene()
        XCTAssertTrue(Promotion.targets(for: .line(l1), in: s, artifacts: index()).isEmpty)
        let reason = Promotion.blockedReason(for: .line(l1), in: s, artifacts: index())
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("promote"),
                      "the refusal has to teach the precedence at the moment it "
                      + "bites, not show an empty list")
    }

    func test_aLineBetweenTwoPromotedScrapsBecomesAWikiLink() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-b", for: b)
        let idx = index(["res-a": "The falls at night.", "res-b": "October's doctor"])
        XCTAssertEqual(Promotion.targets(for: .line(l1), in: s, artifacts: idx), [.wikiLink])
        XCTAssertNil(Promotion.blockedReason(for: .line(l1), in: s, artifacts: idx))
    }

    func test_aLineWithOnlyOneEndPromotedOffersNothing() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        XCTAssertTrue(Promotion.targets(for: .line(l1), in: s,
                                        artifacts: index(["res-a": "The falls"])).isEmpty)
    }

    /// The dangling mark, which is the case only the index can see: the scrap
    /// still says it was promoted and the note has been deleted since.
    func test_aLineWhosePromotedNoteIsGoneOffersNothing() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-b", for: b)
        let stale = index(["res-a": "The falls at night."])   // res-b deleted
        XCTAssertTrue(Promotion.targets(for: .line(l1), in: s, artifacts: stale).isEmpty)
        XCTAssertNotNil(Promotion.blockedReason(for: .line(l1), in: s, artifacts: stale))
    }

    func test_aLineTouchingANonTextNodeOffersNothing() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        XCTAssertTrue(Promotion.targets(for: .line(l2), in: s,
                                        artifacts: index(["res-a": "The falls"])).isEmpty)
    }

    // MARK: - The plan is a PREVIEW

    func test_planNamesWhatWillBeProducedAndWhere() {
        let plan = Promotion.plan(request(.scrap(a), .researchNote), in: scene())
        XCTAssertEqual(plan?.producedKind, .researchNote)
        XCTAssertEqual(plan?.title, "The falls at night.")
        XCTAssertEqual(plan?.body, "The falls at night.\n\nSodium light on the spray.")
        XCTAssertEqual(plan?.destinationDescription, "research/")
    }

    func test_aTitleComesFromTheFirstLine() {
        XCTAssertEqual(Promotion.title(from: "  The falls at night.  \n\nSodium light."),
                       "The falls at night.")
    }

    func test_anEmptyScrapProducesNoPlan() {
        var r = request(.scrap(a), .researchNote)
        r.scraps = [a: "   \n  "]
        XCTAssertNil(Promotion.plan(r, in: scene()))
    }

    func test_aTargetTheSourceDoesNotOfferProducesNoPlan() {
        XCTAssertNil(Promotion.plan(request(.scrap(a), .pieceBinding, piece: piece),
                                    in: scene()))
    }

    func test_planningNeverMutatesTheScene() {
        let before = scene()
        let s = before
        _ = Promotion.plan(request(.scrap(a), .researchNote), in: s)
        _ = Promotion.plan(request(.region(r1), .paletteCard), in: s)
        _ = Promotion.plan(request(.region(r1), .pieceBinding, piece: piece), in: s)
        XCTAssertEqual(s, before,
                       "nothing promotes because it sat somewhere long enough or "
                       + "looked like something (§6.1)")
    }

    // MARK: - Regions

    func test_regionPromotionJoinsItsResidentsInReadingOrder() {
        let plan = Promotion.plan(request(.region(r1), .paletteCard), in: scene())
        XCTAssertEqual(plan?.title, "Act II fog")
        XCTAssertEqual(plan?.body,
                       "The falls at night.\n\nSodium light on the spray."
                       + "\n\nOctober's doctor was kind about it.",
                       "top card first — the writer's own arrangement, not id order")
    }

    func test_theReadingOrderIsSpatialAndNotTheIdOrder() {
        var s = scene()
        s.move(a, to: CGPoint(x: 0, y: 900))    // "a" now sits BELOW "b"
        let plan = Promotion.plan(request(.region(r1), .paletteCard), in: s)
        XCTAssertEqual(plan?.body,
                       "October's doctor was kind about it."
                       + "\n\nThe falls at night.\n\nSodium light on the spray.")
    }

    func test_anUnlabelledRegionGetsAWriterFacingFallbackTitle() {
        var s = scene()
        s.updateRegion(r1) { $0.label = "" }
        XCTAssertEqual(Promotion.plan(request(.region(r1), .paletteCard), in: s)?.title,
                       CanvasRegion.untitledLabel,
                       "regions are created unlabelled; an untitled palette card "
                       + "is unfindable on the wall")
    }

    /// §6.1: promotion is ALLOWED to be lossy and that is a feature — but the
    /// writer is told which parts are dropped.
    func test_regionPromotionDiscardsLinesAndLayoutAndSaysSo() {
        XCTAssertEqual(Promotion.plan(request(.region(r1), .paletteCard), in: scene())?.discards,
                       [.lines, .layout])
    }

    func test_scrapPromotionDiscardsNothing() {
        XCTAssertTrue(Promotion.plan(request(.scrap(a), .researchNote), in: scene())!
                        .discards.isEmpty)
    }

    // MARK: - The offer (§6.1: may suggest, must never impose)

    func test_regionPromotionOffersLinkingOnlyForAlreadyPromotedMembers() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let plan = Promotion.plan(
            request(.region(r1), .paletteCard,
                    artifacts: index(["res-a": "The falls at night."])), in: s)
        XCTAssertEqual(plan?.offeredLinks.map(\.node), [a])
        XCTAssertEqual(plan?.offeredLinks.first?.itemID, "res-a")
    }

    func test_theOfferDefaultsToDeclined() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let plan = Promotion.plan(
            request(.region(r1), .paletteCard,
                    artifacts: index(["res-a": "The falls at night."])), in: s)
        XCTAssertFalse(plan!.linksAccepted,
                       "an offer that arrives pre-accepted is an imposition with a "
                       + "checkbox; the silent conversion is what §6.1 forbids outright")
    }

    func test_thereIsNoOfferWhenNoMemberIsPromoted() {
        XCTAssertTrue(Promotion.plan(request(.region(r1), .paletteCard), in: scene())!
                        .offeredLinks.isEmpty)
    }

    // MARK: - Update or New (spec §6.1, 2026-07-28 amendment)

    func test_anUnpromotedCardOffersOnlyANewArtifact() {
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: scene(), artifacts: index()))
        XCTAssertEqual(Promotion.modes(for: .researchNote, existing: nil), [.new])
    }

    func test_aPromotedCardOffersUpdateAndNewNamingTheArtifact() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let existing = Promotion.existingArtifact(
            for: .scrap(a), target: .researchNote, in: s,
            artifacts: index(["res-a": "The falls at night."]))
        XCTAssertEqual(existing, .update(itemID: "res-a", title: "The falls at night."))
        XCTAssertEqual(Promotion.modes(for: .researchNote, existing: existing),
                       [.new, .update(itemID: "res-a", title: "The falls at night.")])
    }

    func test_aMarkThatNoLongerResolvesOffersNoUpdate() {
        var s = scene()
        s.setPromotedItem("res-gone", for: a)
        XCTAssertNil(Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                in: s, artifacts: index()),
                     "you cannot update a note that is not in the project any more")
    }

    /// The craft-intent doc ACCUMULATES — one doc per scope, appended to. There
    /// is no "update" that would not mean "replace the writer's whole intent",
    /// so the choice is not offered at all.
    func test_anIntentStatementIsNeverAnUpdate() {
        var s = scene()
        s.setPromotedItem("res-intent", for: a)
        XCTAssertNil(Promotion.existingArtifact(
            for: .scrap(a), target: .intentStatement, in: s,
            artifacts: index(["res-intent": "Craft Intent"])))
    }

    func test_updatingCarriesTheArtifactIntoThePlan() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let plan = Promotion.plan(
            request(.scrap(a), .researchNote,
                    mode: .update(itemID: "res-a", title: "The falls at night."),
                    artifacts: index(["res-a": "The falls at night."])), in: s)
        XCTAssertEqual(plan?.mode, .update(itemID: "res-a", title: "The falls at night."))
        XCTAssertTrue(plan!.destinationDescription.contains("The falls at night."),
                      "the writer must see WHICH note is about to be rewritten")
    }

    // MARK: - Wiki-links and bindings carry their execution path

    private func promotedScene() -> CanvasScene {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-b", for: b)
        return s
    }

    private var bothPromoted: ArtifactIndex {
        index(["res-a": "The falls at night.", "res-b": "October's doctor"])
    }

    func test_theWikiLinkPlanNamesBothEndsAndWhereTheTextGoes() {
        var s = promotedScene()
        s.updateLine(l1) { $0.label = "because of the ponchos" }
        let plan = Promotion.plan(
            request(.line(l1), .wikiLink, artifacts: bothPromoted), in: s)
        XCTAssertEqual(plan?.wikiLinkWrite?.intoNode, a)
        XCTAssertEqual(plan?.wikiLinkWrite?.intoItemID, "res-a")
        XCTAssertEqual(plan?.wikiLinkWrite?.linkText,
                       "[[October's doctor]] — because of the ponchos")
        XCTAssertEqual(plan?.wikiLinkWrite?.appendedText,
                       "\n\n[[October's doctor]] — because of the ponchos\n")
    }

    /// The link names the ARTIFACT, not the scrap. A `[[…]]` naming the card's
    /// first line would resolve to nothing — which is the failure §6.1 forbids,
    /// arriving one step later than the rule that guards against it.
    func test_theLinkNamesTheArtifactAndNotTheCardsFirstLine() {
        let plan = Promotion.plan(request(.line(l1), .wikiLink, artifacts: bothPromoted),
                                  in: promotedScene())
        XCTAssertEqual(plan?.wikiLinkWrite?.linkText, "[[October's doctor]]")
        XCTAssertFalse(plan!.wikiLinkWrite!.linkText.contains("was kind about it"))
    }

    func test_aLinkAlreadyInTheDestinationIsRefusedRatherThanAppendedTwice() {
        let plan = Promotion.plan(
            request(.line(l1), .wikiLink, artifacts: bothPromoted,
                    destinationBody: "The falls.\n\n[[October's doctor]]\n"),
            in: promotedScene())
        XCTAssertTrue(plan!.linkAlreadyPresent)
    }

    func test_aDestinationWithoutTheLinkIsNotRefused() {
        let plan = Promotion.plan(
            request(.line(l1), .wikiLink, artifacts: bothPromoted,
                    destinationBody: "The falls.\n\n[[Something else]]\n"),
            in: promotedScene())
        XCTAssertFalse(plan!.linkAlreadyPresent)
    }

    func test_thePieceBindingPlanCarriesThePieceAndNamesItInTheDestination() {
        let plan = Promotion.plan(request(.region(r1), .pieceBinding, piece: piece),
                                  in: scene())
        XCTAssertEqual(plan?.pieceID, "piece-3")
        XCTAssertTrue(plan!.destinationDescription.contains("Chapter Three"))
        XCTAssertTrue(plan!.discards.isEmpty,
                      "binding drops nothing — the region stays exactly as it is")
    }

    func test_aPieceBindingWithNoPieceChosenProducesNoPlan() {
        XCTAssertNil(Promotion.plan(request(.region(r1), .pieceBinding), in: scene()))
    }

    func test_thePaletteKindRidesThePlan() {
        let plan = Promotion.plan(request(.scrap(a), .paletteCard, kind: .location),
                                  in: scene())
        XCTAssertEqual(plan?.paletteKind, .location)
    }

    // MARK: - The index

    func test_theIndexIsBuiltFromTheWholeResearchTreeIncludingChildren() {
        let child = ResearchItem(id: "res-child", title: "Child", type: .asset,
                                 kind: .document, path: "research/g/child.md", addedAt: Date())
        let group = ResearchItem(id: "res-grp", title: "Group", type: .group,
                                 path: "research/g", addedAt: Date(), children: [child])
        let idx = ArtifactIndex.over(research: [group])
        XCTAssertEqual(idx.title(of: "res-child"), "Child")
        XCTAssertEqual(idx.title(of: "res-grp"), "Group")
        XCTAssertNil(idx.title(of: "res-nope"))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'Promotion' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/Promotion.swift`**

```swift
import Foundation
import MaughamCore

/// What is being promoted.
enum PromotionSource: Equatable, Hashable {
    case scrap(CanvasNodeID)
    case region(CanvasRegionID)
    case line(CanvasLineID)
}

/// What it becomes. **This list IS spec §6's table** and must not grow without
/// amending the spec — every entry is a new durable artifact the writer can
/// create, and the whole design rests on that set being small and predictable.
enum PromotionTarget: String, Equatable, Hashable, CaseIterable, Identifiable {
    case researchNote
    case paletteCard
    case intentStatement
    case pieceBinding
    case wikiLink

    var id: String { rawValue }

    var writerFacingName: String {
        switch self {
        case .researchNote: return "Research note"
        case .paletteCard: return "Palette card"
        case .intentStatement: return "Craft intent"
        case .pieceBinding: return "Piece binding"
        case .wikiLink: return "Wiki-link"
        }
    }
}

/// New artifact, or rewrite the one this source produced last time.
///
/// **Neither is a default, and that is the ruling** (spec §6.1, 2026-07-28).
/// "Always update" eats edits the writer made in `research/`; "always new"
/// leaves `The falls at night 2`, `… 3` and two orphans nobody asked for. The
/// choice is one sentence of preview, which is what §6.1 already requires of
/// everything else here.
enum PromotionMode: Equatable, Hashable, Identifiable {
    case new
    case update(itemID: String, title: String)

    var id: String {
        switch self {
        case .new: return "new"
        case .update(let itemID, _): return "update:\(itemID)"
        }
    }
}

/// What promoting will throw away. Promotion is ALLOWED to be lossy and that is
/// a feature (§6.1) — the spatial work was thinking; it earned its keep by
/// producing the artifact. Scapple → Scrivener keeps notes and drops
/// connections, deliberately. The writer is told which, in the preview.
enum PromotionDiscard: Equatable, Hashable {
    case lines
    case layout
}

/// An offer to link an already-promoted member to the artifact being produced.
/// An OFFER — see `PromotionPlan.linksAccepted`.
struct PromotionLinkOffer: Equatable, Hashable, Identifiable {
    let node: CanvasNodeID
    /// The member's own artifact. Only promoted members can be offered: a link
    /// into a scrap has nowhere to be written.
    let itemID: String
    let title: String
    var id: CanvasNodeID { node }
}

/// The one durable write a line promotion makes.
struct WikiLinkWrite: Equatable {
    let intoNode: CanvasNodeID
    let intoItemID: String
    /// `[[Artifact title]] — the line's name`. The link names the ARTIFACT and
    /// never the card's first line: `[[X]]` resolves against the manifest, and a
    /// scrap is not in it.
    let linkText: String

    /// A blank line before, a newline after — so appending twice never runs two
    /// links together, and a note that did not end in a newline still parses.
    var appendedText: String { "\n\n" + linkText + "\n" }
}

/// Item id → title, for every research item in the project.
///
/// **This exists because the sidecar cannot validate a mark and never could.**
/// `CanvasNode.promotedItemID` is written by a promotion and read much later; a
/// writer who deletes the note leaves an id that resolves to nothing. Passing an
/// index rather than a `ProjectStore` keeps this whole file pure and testable,
/// and means the manifest is walked ONCE, when the sheet opens, rather than per
/// query.
struct ArtifactIndex: Equatable {
    private let titlesByID: [String: String]

    init(titlesByID: [String: String]) { self.titlesByID = titlesByID }

    static func over(research: [ResearchItem]) -> ArtifactIndex {
        ArtifactIndex(titlesByID: Dictionary(
            TreeWalk.collect(in: research, where: { _ in true }).map { ($0.id, $0.title) },
            uniquingKeysWith: { _, later in later }))
    }

    func title(of itemID: String) -> String? { titlesByID[itemID] }
}

/// Everything `Promotion.plan` needs. A struct rather than eight parameters,
/// because the sheet builds one and mutates two fields on it as the writer
/// works.
struct PromotionRequest {
    let source: PromotionSource
    let target: PromotionTarget
    var mode: PromotionMode = .new
    var scraps: [CanvasNodeID: String]
    var piece: RegionInspector.PieceChoice?
    var paletteKind: PaletteCard.Kind = .other
    var artifacts: ArtifactIndex
    /// The destination artifact's body as read from disk when the target was
    /// chosen, for the wiki-link duplicate check. `nil` when not applicable or
    /// not read. **A snapshot** — the performer checks again against the live
    /// file, because this one can be stale by the time the writer commits.
    var destinationBody: String?

    init(source: PromotionSource,
         target: PromotionTarget,
         mode: PromotionMode = .new,
         scraps: [CanvasNodeID: String],
         piece: RegionInspector.PieceChoice? = nil,
         paletteKind: PaletteCard.Kind = .other,
         artifacts: ArtifactIndex,
         destinationBody: String? = nil) {
        self.source = source
        self.target = target
        self.mode = mode
        self.scraps = scraps
        self.piece = piece
        self.paletteKind = paletteKind
        self.artifacts = artifacts
        self.destinationBody = destinationBody
    }
}

/// The preview. The writer sees what will be produced, and where, before
/// committing — Scrivener's Commit is the model: a named command with a stated
/// rule and a predictable outcome (§6.1).
///
/// Building a plan NEVER mutates anything. That is what makes the preview
/// honest, and `test_planningNeverMutatesTheScene` pins it.
struct PromotionPlan: Equatable {
    let source: PromotionSource
    let producedKind: PromotionTarget
    /// The writer may edit this in the sheet before committing.
    var title: String
    let body: String
    /// Human-readable, shown verbatim: "research/", "the palette wall",
    /// "the note “The falls at night.”".
    let destinationDescription: String
    let discards: Set<PromotionDiscard>

    /// §6.1's "may suggest, must never impose". Promoting a region may *offer*
    /// to link its already-promoted members to the artifact it produced. That
    /// sits inside Shipman & Marshall's licence precisely BECAUSE the writer
    /// sees it and can decline it cheaply.
    let offeredLinks: [PromotionLinkOffer]

    /// Defaults to FALSE, always. The same inference applied silently is
    /// forbidden: membership is n-ary and vague, wiki-links are binary and
    /// specific, and a silent conversion manufactures precision the writer never
    /// claimed — into a layer with backlinks and rename propagation, where it is
    /// expensive to undo.
    var linksAccepted = false

    let wikiLinkWrite: WikiLinkWrite?
    let pieceID: String?
    let mode: PromotionMode
    let paletteKind: PaletteCard.Kind

    /// True when the link this plan would write is already in the destination.
    /// The sheet says so and refuses; the performer refuses too, against the
    /// live file.
    let linkAlreadyPresent: Bool
}

enum Promotion {

    /// The targets whose artifact is a single rewritable document. The craft
    /// intent is deliberately absent: it ACCUMULATES — one doc per scope — so an
    /// "update" would mean replacing the writer's whole intent statement.
    static let updatableTargets: Set<PromotionTarget> = [.researchNote, .paletteCard]

    // MARK: - §6's table

    static func targets(for source: PromotionSource,
                        in scene: CanvasScene,
                        artifacts: ArtifactIndex) -> [PromotionTarget] {
        switch source {
        case .scrap(let id):
            // Only scraps promote. An item already exists as itself; promoting
            // it would duplicate it, and two editable copies of one note is
            // exactly what §4.3 rejects.
            guard case .scrap = scene.node(id)?.kind else { return [] }
            return [.researchNote, .paletteCard, .intentStatement]

        case .region(let id):
            guard scene.region(id) != nil else { return [] }
            return [.paletteCard, .pieceBinding]

        case .line(let id):
            guard let line = scene.line(id),
                  resolvedArtifact(of: line.from, in: scene, artifacts: artifacts) != nil,
                  resolvedArtifact(of: line.to, in: scene, artifacts: artifacts) != nil
            else { return [] }
            return [.wikiLink]
        }
    }

    /// Why a source offers nothing, in words a writer can act on. Only lines
    /// have an interesting answer; everything else returns nil and the sheet
    /// simply shows the targets.
    static func blockedReason(for source: PromotionSource,
                              in scene: CanvasScene,
                              artifacts: ArtifactIndex) -> String? {
        guard case .line(let id) = source, let line = scene.line(id),
              targets(for: source, in: scene, artifacts: artifacts).isEmpty else { return nil }
        guard isScrap(line.from, in: scene) && isScrap(line.to, in: scene) else {
            return "A line becomes a wiki-link only between two cards of text."
        }
        // The precedence rule, taught at the moment it costs something: the
        // durable layer is reached by promoting the things first.
        return "Promote both cards first. A wiki-link has to point at something "
            + "that exists outside the canvas — a canvas line is scratch."
    }

    // MARK: - Update or New

    /// The artifact this source produced last time, when it still exists AND the
    /// target is one that can be rewritten.
    static func existingArtifact(for source: PromotionSource,
                                 target: PromotionTarget,
                                 in scene: CanvasScene,
                                 artifacts: ArtifactIndex) -> PromotionMode? {
        guard updatableTargets.contains(target) else { return nil }
        let markedID: String?
        switch source {
        case .scrap(let id): markedID = scene.node(id)?.promotedItemID
        case .region(let id): markedID = scene.region(id)?.promotedItemID
        case .line: markedID = nil
        }
        guard let markedID, let title = artifacts.title(of: markedID) else { return nil }
        return .update(itemID: markedID, title: title)
    }

    /// `.new` first, always — so a sheet that renders these in order cannot make
    /// "rewrite the writer's note" the thing sitting under the cursor.
    static func modes(for target: PromotionTarget, existing: PromotionMode?) -> [PromotionMode] {
        guard let existing, updatableTargets.contains(target) else { return [.new] }
        return [.new, existing]
    }

    // MARK: - The plan

    static func plan(_ request: PromotionRequest, in scene: CanvasScene) -> PromotionPlan? {
        guard targets(for: request.source, in: scene, artifacts: request.artifacts)
                .contains(request.target) else { return nil }

        switch request.source {
        case .scrap(let id):
            let body = text(of: id, in: request.scraps)
            guard !body.isEmpty else { return nil }
            return PromotionPlan(
                source: request.source, producedKind: request.target,
                title: title(from: body), body: body,
                destinationDescription: destination(request),
                discards: [], offeredLinks: [], wikiLinkWrite: nil, pieceID: nil,
                mode: request.mode, paletteKind: request.paletteKind,
                linkAlreadyPresent: false)

        case .region(let id):
            guard let region = scene.region(id) else { return nil }
            if request.target == .pieceBinding {
                guard let piece = request.piece else { return nil }
                return PromotionPlan(
                    source: request.source, producedKind: request.target,
                    title: regionTitle(region), body: "",
                    destinationDescription: destination(request),
                    // Binding drops nothing: the region stays exactly as it is.
                    discards: [], offeredLinks: [], wikiLinkWrite: nil,
                    pieceID: piece.id, mode: .new, paletteKind: request.paletteKind,
                    linkAlreadyPresent: false)
            }
            let members = readingOrder(region.homeMembers, in: scene)
            let bodies = members.compactMap { nodeID -> (CanvasNodeID, String)? in
                let t = text(of: nodeID, in: request.scraps)
                return t.isEmpty ? nil : (nodeID, t)
            }
            return PromotionPlan(
                source: request.source, producedKind: request.target,
                title: regionTitle(region),
                body: bodies.map(\.1).joined(separator: "\n\n"),
                destinationDescription: destination(request),
                // The spatial work is not carried across, and the writer is told.
                discards: [.lines, .layout],
                offeredLinks: bodies.compactMap { nodeID, _ in
                    guard let itemID = resolvedArtifact(of: nodeID, in: scene,
                                                        artifacts: request.artifacts),
                          let title = request.artifacts.title(of: itemID) else { return nil }
                    return PromotionLinkOffer(node: nodeID, itemID: itemID, title: title)
                },
                wikiLinkWrite: nil, pieceID: nil, mode: request.mode,
                paletteKind: request.paletteKind, linkAlreadyPresent: false)

        case .line(let id):
            guard let line = scene.line(id),
                  let fromItem = resolvedArtifact(of: line.from, in: scene,
                                                  artifacts: request.artifacts),
                  let toItem = resolvedArtifact(of: line.to, in: scene,
                                                artifacts: request.artifacts),
                  let fromTitle = request.artifacts.title(of: fromItem),
                  let toTitle = request.artifacts.title(of: toItem) else { return nil }
            let write = WikiLinkWrite(intoNode: line.from, intoItemID: fromItem,
                                      linkText: linkText(to: toTitle, label: line.label))
            return PromotionPlan(
                source: request.source, producedKind: request.target,
                title: fromTitle, body: write.linkText,
                destinationDescription: "the note “\(fromTitle)”",
                discards: [], offeredLinks: [], wikiLinkWrite: write, pieceID: nil,
                mode: .new, paletteKind: request.paletteKind,
                linkAlreadyPresent: request.destinationBody?.contains(write.linkText) ?? false)
        }
    }

    // MARK: - Pieces

    static func title(from body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// `[[Title]]`, plus the line's own name when it has one. An em dash rather
    /// than a colon, matching the guide's prose voice.
    static func linkText(to title: String, label: String?) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "[[\(title)]]" }
        return "[[\(title)]] — \(trimmed)"
    }

    private static func isScrap(_ id: CanvasNodeID, in scene: CanvasScene) -> Bool {
        if case .scrap = scene.node(id)?.kind { return true }
        return false
    }

    /// The node's artifact, when it is a scrap, HAS a mark, and that mark still
    /// names something in the project. All three conditions matter — the third
    /// is the dangling mark, and it is the only one the scene cannot see.
    private static func resolvedArtifact(of id: CanvasNodeID,
                                         in scene: CanvasScene,
                                         artifacts: ArtifactIndex) -> String? {
        guard let node = scene.node(id), case .scrap = node.kind,
              let itemID = node.promotedItemID,
              artifacts.title(of: itemID) != nil else { return nil }
        return itemID
    }

    private static func text(of id: CanvasNodeID, in scraps: [CanvasNodeID: String]) -> String {
        (scraps[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Regions are created unlabelled and named in the inspector, so this is the
    /// common case for the first minute of a region's life. An untitled palette
    /// card is unfindable on the wall.
    private static func regionTitle(_ region: CanvasRegion) -> String {
        let trimmed = region.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? CanvasRegion.untitledLabel : trimmed
    }

    /// Top to bottom, then left to right, then by id.
    ///
    /// **Spatial and not id order**, because the writer arranged these cards and
    /// the joined text should read the way the region reads. The id tiebreak is
    /// not decoration: two cards at the same origin would otherwise let a `Set`'s
    /// iteration order decide, and that differs between runs of the same binary.
    private static func readingOrder(_ ids: Set<CanvasNodeID>,
                                     in scene: CanvasScene) -> [CanvasNodeID] {
        ids.compactMap { scene.node($0) }
            .sorted { a, b in
                if a.origin.y != b.origin.y { return a.origin.y < b.origin.y }
                if a.origin.x != b.origin.x { return a.origin.x < b.origin.x }
                return a.id.raw < b.id.raw
            }
            .map(\.id)
    }

    private static func destination(_ request: PromotionRequest) -> String {
        if case .update(_, let title) = request.mode,
           updatableTargets.contains(request.target) {
            return "the existing “\(title)”"
        }
        switch request.target {
        case .researchNote: return "research/"
        case .paletteCard: return "the palette wall"
        case .intentStatement: return "the project's craft intent"
        case .pieceBinding: return "the piece “\(request.piece?.title ?? "")”"
        case .wikiLink: return ""   // replaced per-plan above
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 31 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/Promotion.swift MaughamTests/Canvas/PromotionTests.swift
git commit -m "feat(canvas): the promotion model - spec 6's table, executable

Pure: a plan is a preview and building one mutates nothing. A line offers a
wiki-link only when both ends carry a mark that still RESOLVES - the dangling
case is the one the scene cannot see, which is why every query takes an
artifact index rather than trusting the sidecar.

Re-promoting offers Update or New, and neither is a default. Craft intent is
absent from that list on purpose: it accumulates, so an update would mean
replacing the writer's whole intent statement.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeXFCPAiAdnJ2mMCdRLvH8"
```

---

### Task 3: `PromotionPerformer` — the writes, through the real store APIs

**Files:**
- Create: `Maugham/Canvas/PromotionPerformer.swift`
- Modify: `MaughamTests/TripwireGrepTests.swift` (the tripwire-32 census expectation — **same commit**)
- Test: `MaughamTests/Canvas/PromotionPerformerTests.swift`

**Interfaces:**
- **Consumes:** `PromotionPlan`, `PromotionTarget`, `PromotionSource`, `PromotionMode`, `WikiLinkWrite`, `PromotionLinkOffer` (Task 2); `CanvasScene.setPromotedItem(_:for:)` and `CanvasRegion.promotedItemID` (Task 1); `CanvasModel.mutateFromInspector(_:_:)` + `bumpSceneRevision()`; `RegionBinding.bind(_:toPiece:in:)`; `ProjectStore` — `url`, `manifest`, `documentStore`, `addResearchTextNote(parentId:title:)`, `updateResearchItem(id:title:)`, `addPaletteCard(title:kind:)`, `updatePaletteCard(_:)`, `loadPaletteCards()`, `createCraftIntent(forPieceId:)`; `DocumentStore.flushPendingSave()`, `performFileSave(path:text:)`; `TreeWalk.find(id:in:)`; `PaletteCard` from `MaughamCore`.
- **Produces:** `@MainActor struct PromotionPerformer` — `init(store:model:)`, `func perform(_ plan: PromotionPlan) async throws -> PromotionResult`; `struct PromotionResult: Equatable` — `createdItemID: String?`, `title: String`, `writtenLinks: [CanvasNodeID]`, `boundPieceID: String?`; `enum PromotionFailure: LocalizedError`.

**`@MainActor`, `async throws`, and no `inout` anywhere on this path.** `ProjectStore` is `@MainActor` and every API above is `async throws`; an `inout CanvasScene` cannot cross an `await` in Swift 6. Scene changes go through `CanvasModel`, synchronously, **after** the awaits.

**Tripwire 32.** This file holds a `CanvasModel`, so the census sees it. Every scene change here is `mutateFromInspector` — `beginPromotion` can run while "Edit Scrap" is open, and nested, the mark would register no undo step and ride into the writer's next sentence. **Add `"PromotionPerformer.swift": [Self.canvasOutsideVerb]` to the expectation at `TripwireGrepTests.swift:1694` in this commit**, or the suite goes red with a message about undo brackets.

**What ⌘Z takes back, stated because a writer will try it.** The undo step covers the CANVAS's change — the mark — and not the artifact. The note is a real file with its own lifecycle (the research tree's Delete, and ⌘⌥Z to restore). The guide says so in Task 9; do not name the undo step anything that promises otherwise.

**Tripwire 14 does not apply.** Promotion **creates**; it never moves or trashes user content, so the typed `DocumentStore` mover is not on this path and no `moveItem`/`moveToTrash` appears in this file. It must still create through `ProjectStore`'s APIs rather than writing files directly, or the manifest and the disk diverge. The one exception is the *body* write, which the store has no API for — that goes through `documentStore.performFileSave`, the same coordinated path `ProjectStore+Palette.paletteCoordinatedWrite` uses, with a direct write as the no-`DocumentStore` fallback.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/PromotionPerformerTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

/// Promotion, performed against a real `ProjectStore` on a real temp project.
///
/// The house pattern (`MaughamTests/MCP/Tools/ListAllLinksToolTests.swift:7`):
/// a per-file helper, not a shared fixture. There is no `TestProjectFixture` in
/// this codebase.
@MainActor
final class PromotionPerformerTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let r1 = CanvasRegionID("r1")
    private let l1 = CanvasLineID("l1")

    private func makeProject() async throws -> (URL, ProjectStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PP-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for sub in ["manuscript", "research"] {
            try FileManager.default.createDirectory(
                at: tmp.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, try await ProjectStore.load(from: tmp))
    }

    private func makeModel(at root: URL) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.withScene { s in
            s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
            s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 0, y: 200),
                                width: 240, cachedHeight: 80))
            s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                        homeMembers: [a, b]))
            s.insertLine(CanvasLine(id: l1, from: a, to: b))
        }
        model.setScrapText("The falls at night\n\nSodium light on the spray.", for: a)
        model.setScrapText("October's doctor", for: b)
        return model
    }

    private func index(_ store: ProjectStore) -> ArtifactIndex {
        ArtifactIndex.over(research: store.manifest.research)
    }

    private func plan(_ source: PromotionSource, _ target: PromotionTarget,
                      store: ProjectStore, model: CanvasModel,
                      mode: PromotionMode = .new,
                      piece: RegionInspector.PieceChoice? = nil,
                      kind: PaletteCard.Kind = .other) -> PromotionPlan {
        Promotion.plan(
            PromotionRequest(source: source, target: target, mode: mode,
                             scraps: model.scraps, piece: piece, paletteKind: kind,
                             artifacts: index(store)),
            in: model.scene)!
    }

    private func body(of item: ResearchItem, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(item.path ?? ""), encoding: .utf8)
    }

    private func item(_ title: String, in store: ProjectStore) throws -> ResearchItem {
        try XCTUnwrap(TreeWalk.first(in: store.manifest.research, where: { $0.title == title }))
    }

    // MARK: - Scrap → research note

    func test_promotingAScrapCreatesARealNoteWithItsBody() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        let created = try item("The falls at night", in: store)
        XCTAssertEqual(result.createdItemID, created.id)
        XCTAssertTrue(try body(of: created, in: root).contains("Sodium light on the spray."))
    }

    /// §1 and §6: promotion is a seam, not a move. The canvas is scratch and
    /// stays scratch — the card keeps its words and gains a mark.
    func test_promotingAScrapLeavesItOnTheCanvasAndMarksIt() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        XCTAssertNotNil(model.scene.node(a))
        XCTAssertEqual(model.scraps[a], "The falls at night\n\nSodium light on the spray.")
        XCTAssertEqual(model.scene.node(a)?.promotedItemID, result.createdItemID)
        XCTAssertNil(model.scene.node(b)?.promotedItemID, "and only the one promoted")
    }

    /// The mark is a scene change made from OUTSIDE `CanvasView`, so it has to
    /// arrive as its own undo step — see tripwire 32. An assertion on the scene
    /// alone cannot tell "its own step" from "folded into the open one"; the
    /// discriminator is the step's NAME, which is also what the writer reads in
    /// the Edit menu.
    func test_theMarkIsItsOwnUndoStepEvenWithAScrapGestureOpen() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        model.beginGesture("Edit Scrap")          // the writer is typing in a card
        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promote Scrap"),
                      "found: \(model.undoManager.undoMenuItemTitle)")
        model.endGesture()
    }

    func test_undoTakesBackTheMarkAndLeavesTheNote() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        model.undo.undo()
        XCTAssertNil(model.scene.node(a)?.promotedItemID)
        XCTAssertNotNil(TreeWalk.first(in: store.manifest.research,
                                       where: { $0.title == "The falls at night" }),
                        "the canvas's undo is scene-scoped; the note is a real file "
                        + "with its own lifecycle, and the guide says so")
    }

    // MARK: - Update or New

    func test_promotingAgainAsNewProducesASecondArtifact() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model))
        let second = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model))

        XCTAssertNotEqual(first.createdItemID, second.createdItemID)
        XCTAssertEqual(TreeWalk.collect(in: store.manifest.research,
                                        where: { $0.type == .asset }).count, 2)
        XCTAssertEqual(model.scene.node(a)?.promotedItemID, second.createdItemID,
                       "the mark names the most recent")
    }

    func test_updatingRewritesTheSameNoteAndMintsNothing() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model))

        model.setScrapText("The falls at night\n\nAnd the ponchos.", for: a)
        let existing = Promotion.existingArtifact(for: .scrap(a), target: .researchNote,
                                                  in: model.scene, artifacts: index(store))
        XCTAssertEqual(existing, .update(itemID: first.createdItemID!,
                                         title: "The falls at night"))
        let second = try await performer.perform(
            plan(.scrap(a), .researchNote, store: store, model: model, mode: existing!))

        XCTAssertEqual(second.createdItemID, first.createdItemID)
        XCTAssertEqual(TreeWalk.collect(in: store.manifest.research,
                                        where: { $0.type == .asset }).count, 1)
        let note = try item("The falls at night", in: store)
        let text = try body(of: note, in: root)
        XCTAssertTrue(text.contains("And the ponchos."))
        XCTAssertFalse(text.contains("Sodium light on the spray."),
                       "an update REWRITES the body — that is what the preview says "
                       + "it will do")
    }

    func test_updatingAnArtifactThatHasSinceBeenDeletedRefusesRatherThanCreating() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let stale = PromotionPlan(
            source: .scrap(a), producedKind: .researchNote, title: "T", body: "B",
            destinationDescription: "the existing “T”", discards: [], offeredLinks: [],
            wikiLinkWrite: nil, pieceID: nil,
            mode: .update(itemID: "res-gone", title: "T"), paletteKind: .other,
            linkAlreadyPresent: false)
        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(stale)
            XCTFail("expected a refusal")
        } catch PromotionFailure.artifactMissing {
            XCTAssertTrue(store.manifest.research.isEmpty, "and nothing was created instead")
        }
        _ = root
    }

    // MARK: - Scrap → palette card

    func test_promotingAScrapToAPaletteCardPutsItOnTheWallWithItsKind() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .paletteCard, store: store, model: model, kind: .location))

        let card = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.title == "The falls at night" })
        XCTAssertEqual(card.kind, .location)
        XCTAssertTrue(card.body.contains("Sodium light on the spray."),
                      "a palette card whose prose was dropped is not the scrap promoted")
        _ = root
    }

    /// A card the writer has since given swatches and images must not lose them
    /// to an update that was only ever about the prose.
    func test_updatingAPaletteCardKeepsItsSwatchesAndImages() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.scrap(a), .paletteCard, store: store, model: model))

        let original = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == first.createdItemID })
        try await store.updatePaletteCard(PaletteCard(
            researchItemId: original.researchItemId, title: original.title,
            kind: original.kind, swatches: ["#112233"],
            notes: [PaletteCard.SensoryNote(sense: .sound, text: "the roar")],
            imagePaths: original.imagePaths, body: original.body))

        model.setScrapText("The falls at night\n\nAnd the ponchos.", for: a)
        let existing = Promotion.existingArtifact(for: .scrap(a), target: .paletteCard,
                                                  in: model.scene, artifacts: index(store))
        _ = try await performer.perform(
            plan(.scrap(a), .paletteCard, store: store, model: model, mode: existing!))

        let updated = try XCTUnwrap(store.loadPaletteCards()
            .first { $0.researchItemId == first.createdItemID })
        XCTAssertEqual(updated.swatches, ["#112233"])
        XCTAssertEqual(updated.notes.first?.text, "the roar")
        XCTAssertTrue(updated.body.contains("And the ponchos."))
        _ = root
    }

    // MARK: - Scrap → craft intent

    func test_promotingToAnIntentAppendsRatherThanReplacing() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        _ = try await performer.perform(
            plan(.scrap(a), .intentStatement, store: store, model: model))
        _ = try await performer.perform(
            plan(.scrap(b), .intentStatement, store: store, model: model))

        let intent = try XCTUnwrap(store.craftIntentItem(forPieceId: nil))
        let text = try body(of: intent, in: root)
        XCTAssertTrue(text.contains("Sodium light on the spray."))
        XCTAssertTrue(text.contains("October's doctor"),
                      "an intent doc accumulates; the second statement must not "
                      + "replace the first")
        XCTAssertEqual(TreeWalk.collect(in: store.manifest.research,
                                        where: { $0.role == .craftIntent }).count, 1)
    }

    // MARK: - Region → piece binding

    func test_bindingSetsTheBindingAndCreatesNoFiles() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let piece = RegionInspector.PieceChoice(id: "piece-3", title: "Chapter Three")
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .pieceBinding, store: store, model: model, piece: piece))

        XCTAssertEqual(result.boundPieceID, "piece-3")
        XCTAssertEqual(model.scene.region(r1)?.boundPieceID, "piece-3")
        XCTAssertTrue(store.manifest.research.isEmpty, "binding creates nothing")
        XCTAssertNil(model.scene.region(r1)?.promotedItemID,
                     "and it is not an artifact, so it leaves no mark")
        _ = root
    }

    /// One name for one act: the inspector's Picker and this route both read
    /// "Bind Region" in the Edit menu.
    func test_bindingSharesTheInspectorsUndoName() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        _ = try await PromotionPerformer(store: store, model: model).perform(
            plan(.region(r1), .pieceBinding, store: store, model: model,
                 piece: RegionInspector.PieceChoice(id: "piece-3", title: "Chapter Three")))
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Bind Region"),
                      "found: \(model.undoManager.undoMenuItemTitle)")
        _ = root
    }

    // MARK: - Region → palette card, and the offer (§6.1)

    private func promoteBothScraps(_ store: ProjectStore, _ model: CanvasModel) async throws {
        let performer = PromotionPerformer(store: store, model: model)
        for id in [a, b] {
            _ = try await performer.perform(
                plan(.scrap(id), .researchNote, store: store, model: model))
        }
    }

    func test_aDeclinedOfferWritesNoLinksAtAll() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let p = plan(.region(r1), .paletteCard, store: store, model: model)
        XCTAssertEqual(p.offeredLinks.count, 2)
        XCTAssertFalse(p.linksAccepted)

        let result = try await PromotionPerformer(store: store, model: model).perform(p)
        XCTAssertTrue(result.writtenLinks.isEmpty)
        for item in TreeWalk.collect(in: store.manifest.research, where: { $0.type == .asset })
        where item.path?.hasSuffix(".md") == true {
            XCTAssertFalse(try body(of: item, in: root).contains("[["),
                           "a declined offer must write nothing at all")
        }
    }

    func test_anAcceptedOfferWritesExactlyTheOfferedLinks() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        var p = plan(.region(r1), .paletteCard, store: store, model: model)
        p.linksAccepted = true

        let result = try await PromotionPerformer(store: store, model: model).perform(p)
        XCTAssertEqual(Set(result.writtenLinks), [a, b])
        XCTAssertTrue(try body(of: item("The falls at night", in: store), in: root)
                        .contains("[[Act II fog]]"),
                      "the member's own note points AT the artifact the region produced")
    }

    func test_promotingARegionMarksTheRegion() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .paletteCard, store: store, model: model))
        XCTAssertEqual(model.scene.region(r1)?.promotedItemID, result.createdItemID)
        _ = root
    }

    // MARK: - Line → wiki-link

    func test_promotingALineAppendsOneLinkToTheFromEndsNote() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        model.mutate("Label Line") {
            $0.updateLine(l1) { $0.label = "because of the ponchos" }
        }
        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.line(l1), .wikiLink, store: store, model: model))

        let textA = try body(of: item("The falls at night", in: store), in: root)
        XCTAssertTrue(textA.contains("[[October's doctor]] — because of the ponchos"))
        XCTAssertTrue(textA.contains("Sodium light on the spray."),
                      "appending must not replace the note")
        XCTAssertFalse(try body(of: item("October's doctor", in: store), in: root)
                        .contains("[["),
                       "a line writes ONE link, into the from end — not both ways")
    }

    /// The plan's `destinationBody` is a snapshot taken when the sheet opened.
    /// The performer checks the LIVE file, because the writer may have promoted
    /// the same line from another window in between.
    func test_aSecondPromotionOfTheSameLineIsRefusedAgainstTheLiveFile() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let performer = PromotionPerformer(store: store, model: model)
        let p = plan(.line(l1), .wikiLink, store: store, model: model)
        _ = try await performer.perform(p)
        do {
            _ = try await performer.perform(p)     // the same stale plan
            XCTFail("expected a refusal")
        } catch PromotionFailure.linkAlreadyPresent {
            let text = try body(of: item("The falls at night", in: store), in: root)
            XCTAssertEqual(text.components(separatedBy: "[[October's doctor]]").count - 1, 1)
        }
    }

    func test_aLinePromotionLeavesNoMarkOnEitherCard() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        try await promoteBothScraps(store, model)
        let before = (model.scene.node(a)?.promotedItemID, model.scene.node(b)?.promotedItemID)
        _ = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.line(l1), .wikiLink, store: store, model: model))
        XCTAssertEqual(model.scene.node(a)?.promotedItemID, before.0,
                       "a line's artifact is text inside somebody else's note; there "
                       + "is nothing on the line to mark")
        XCTAssertEqual(model.scene.node(b)?.promotedItemID, before.1)
        _ = root
    }

    // MARK: - Failure leaves nothing behind

    func test_anEmptyTitleThrowsAndCreatesNothing() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let blank = PromotionPlan(
            source: .scrap(a), producedKind: .researchNote, title: "  ", body: "something",
            destinationDescription: "research/", discards: [], offeredLinks: [],
            wikiLinkWrite: nil, pieceID: nil, mode: .new, paletteKind: .other,
            linkAlreadyPresent: false)
        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(blank)
            XCTFail("expected a refusal")
        } catch PromotionFailure.emptyTitle {
            XCTAssertTrue(store.manifest.research.isEmpty)
            XCTAssertNil(model.scene.node(a)?.promotedItemID, "and no mark either")
        }
        _ = root
    }

    func test_aPlanRefusedByTheSheetIsRefusedHereToo() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let already = PromotionPlan(
            source: .line(l1), producedKind: .wikiLink, title: "T", body: "[[X]]",
            destinationDescription: "the note “T”", discards: [], offeredLinks: [],
            wikiLinkWrite: WikiLinkWrite(intoNode: a, intoItemID: "res-x", linkText: "[[X]]"),
            pieceID: nil, mode: .new, paletteKind: .other, linkAlreadyPresent: true)
        do {
            _ = try await PromotionPerformer(store: store, model: model).perform(already)
            XCTFail("expected a refusal")
        } catch PromotionFailure.linkAlreadyPresent {}
        _ = root
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionPerformerTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'PromotionPerformer' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/PromotionPerformer.swift`**

```swift
import Foundation
import MaughamCore

/// What a promotion produced.
struct PromotionResult: Equatable {
    /// The artifact's research-item id. Nil only for a piece binding, which
    /// creates no file.
    let createdItemID: String?
    /// The artifact's title AS CREATED — `addResearchTextNote` dedupes, so this
    /// is not always the title the writer typed.
    let title: String
    /// The members whose own notes gained a link, when the offer was accepted.
    let writtenLinks: [CanvasNodeID]
    let boundPieceID: String?
}

enum PromotionFailure: LocalizedError, Equatable {
    case emptyTitle
    case emptyBody
    case missingPiece
    case missingWikiLinkWrite
    case linkAlreadyPresent
    case artifactMissing(String)
    case itemHasNoFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyTitle: return "This needs a name before it can be promoted."
        case .emptyBody: return "There is nothing in this card to promote."
        case .missingPiece: return "Choose a piece to bind this region to."
        case .missingWikiLinkWrite: return "This line has nothing to link."
        case .linkAlreadyPresent: return "That link is already in the note."
        case .artifactMissing(let id):
            return "The artifact this card produced is no longer in the project (\(id))."
        case .itemHasNoFile(let id): return "That artifact has no file on disk (\(id))."
        }
    }
}

/// Performs a `PromotionPlan`.
///
/// **`@MainActor`, `async throws`, and no `inout` on this path.** `ProjectStore`
/// is `@MainActor` and every creation API is `async throws`; an
/// `inout CanvasScene` cannot cross an `await` in Swift 6. Scene changes go
/// through `CanvasModel`, synchronously, after the awaits.
///
/// **Tripwire 32: every scene change here is `mutateFromInspector`.** This is
/// not `CanvasView`, and `beginPromotion` can run while a focused scrap holds
/// "Edit Scrap" open — nested, the mark would register no undo step of its own
/// and would ride into the writer's next sentence, where a ⌘Z aimed at a
/// sentence takes the mark with it. `TripwireGrepTests` names this file.
///
/// **Validate first, write second.** A refused promotion leaves nothing behind;
/// a half-created artifact on a surface whose whole promise is predictability is
/// worse than a refusal.
///
/// **What ⌘Z takes back is the MARK, not the artifact.** The canvas's undo is
/// scene-scoped by design (ADR 0026 §5); the note it produced is a real file
/// with the research tree's own lifecycle. The guide says so, because a writer
/// will try it.
@MainActor
struct PromotionPerformer {

    let store: ProjectStore
    let model: CanvasModel

    func perform(_ plan: PromotionPlan) async throws -> PromotionResult {
        try validate(plan)
        switch plan.producedKind {
        case .researchNote: return try await performResearchNote(plan)
        case .paletteCard: return try await performPaletteCard(plan)
        case .intentStatement: return try await performCraftIntent(plan)
        case .pieceBinding: return performPieceBinding(plan)
        case .wikiLink: return try await performWikiLink(plan)
        }
    }

    // MARK: - Validation

    private func validate(_ plan: PromotionPlan) throws {
        switch plan.producedKind {
        case .researchNote, .paletteCard, .intentStatement:
            guard !plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PromotionFailure.emptyTitle }
            guard !plan.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw PromotionFailure.emptyBody }
        case .pieceBinding:
            guard plan.pieceID != nil else { throw PromotionFailure.missingPiece }
        case .wikiLink:
            guard plan.wikiLinkWrite != nil else { throw PromotionFailure.missingWikiLinkWrite }
            guard !plan.linkAlreadyPresent else { throw PromotionFailure.linkAlreadyPresent }
        }
        if case .update(let itemID, _) = plan.mode,
           TreeWalk.find(id: itemID, in: store.manifest.research) == nil {
            throw PromotionFailure.artifactMissing(itemID)
        }
    }

    // MARK: - The five targets

    private func performResearchNote(_ plan: PromotionPlan) async throws -> PromotionResult {
        let itemID: String
        switch plan.mode {
        case .new:
            itemID = try await store.addResearchTextNote(parentId: nil, title: plan.title).id
        case .update(let existing, _):
            // Renames the backing file through the typed mover when the title
            // moved (tripwire 14 is satisfied by using this API rather than a
            // raw move of our own).
            try await store.updateResearchItem(id: existing, title: plan.title)
            itemID = existing
        }
        try await writeBody(plan.body, toItem: itemID)
        let title = TreeWalk.find(id: itemID, in: store.manifest.research)?.title ?? plan.title
        try await writeOfferedLinks(plan, artifactTitle: title)
        mark(itemID, for: plan.source, named: "Promote Scrap")
        return PromotionResult(createdItemID: itemID, title: title,
                               writtenLinks: writtenLinks(plan), boundPieceID: nil)
    }

    private func performPaletteCard(_ plan: PromotionPlan) async throws -> PromotionResult {
        let itemID: String
        switch plan.mode {
        case .new:
            itemID = try await store.addPaletteCard(title: plan.title,
                                                    kind: plan.paletteKind).id
        case .update(let existing, _):
            itemID = existing
        }
        // Read the card back and replace ONLY the title, kind and body. A card
        // the writer has since given swatches, sensory notes or images must not
        // lose them to an update that was always about the prose.
        guard let current = store.loadPaletteCards().first(where: { $0.researchItemId == itemID })
        else { throw PromotionFailure.artifactMissing(itemID) }
        try await store.updatePaletteCard(PaletteCard(
            researchItemId: itemID, title: plan.title, kind: plan.paletteKind,
            swatches: current.swatches, notes: current.notes,
            imagePaths: current.imagePaths, body: plan.body))

        let title = TreeWalk.find(id: itemID, in: store.manifest.research)?.title ?? plan.title
        try await writeOfferedLinks(plan, artifactTitle: title)
        mark(itemID, for: plan.source,
             named: isRegion(plan.source) ? "Promote Region" : "Promote Scrap")
        return PromotionResult(createdItemID: itemID, title: title,
                               writtenLinks: writtenLinks(plan), boundPieceID: nil)
    }

    private func performCraftIntent(_ plan: PromotionPlan) async throws -> PromotionResult {
        // Find-or-create, idempotent: one intent doc per scope. Project scope —
        // a scrap belongs to the canvas, and the canvas belongs to the project.
        let item = try await store.createCraftIntent(forPieceId: nil)
        guard let path = item.path else { throw PromotionFailure.itemHasNoFile(item.id) }
        // AFTER the flush, so what we append to is what is on disk.
        try? await store.documentStore?.flushPendingSave()
        let existing = readBody(atPath: path)
        let joined = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? plan.body
            : existing + "\n\n" + plan.body
        try await write(joined, toPath: path)
        mark(item.id, for: plan.source, named: "Promote Scrap")
        return PromotionResult(createdItemID: item.id, title: item.title,
                               writtenLinks: [], boundPieceID: nil)
    }

    private func performPieceBinding(_ plan: PromotionPlan) -> PromotionResult {
        guard let pieceID = plan.pieceID, case .region(let regionID) = plan.source else {
            return PromotionResult(createdItemID: nil, title: plan.title,
                                   writtenLinks: [], boundPieceID: nil)
        }
        // The SAME undo name the region inspector's Picker uses, so one act
        // reads one way in the Edit menu however the writer reached it.
        model.mutateFromInspector("Bind Region") { scene in
            RegionBinding.bind(regionID, toPiece: pieceID, in: &scene)
        }
        model.bumpSceneRevision()
        return PromotionResult(createdItemID: nil, title: plan.title,
                               writtenLinks: [], boundPieceID: pieceID)
    }

    private func performWikiLink(_ plan: PromotionPlan) async throws -> PromotionResult {
        guard let write = plan.wikiLinkWrite else { throw PromotionFailure.missingWikiLinkWrite }
        guard let item = TreeWalk.find(id: write.intoItemID, in: store.manifest.research),
              let path = item.path else {
            throw PromotionFailure.artifactMissing(write.intoItemID)
        }
        try? await store.documentStore?.flushPendingSave()
        let body = readBody(atPath: path)
        // The plan's own check was against a SNAPSHOT taken when the sheet
        // opened. This one is against the file.
        guard !body.contains(write.linkText) else { throw PromotionFailure.linkAlreadyPresent }
        try await write(body + write.appendedText, toPath: path)
        // No mark: a line's artifact is text inside somebody else's note, and a
        // flag on the line could disagree with the file.
        return PromotionResult(createdItemID: write.intoItemID, title: item.title,
                               writtenLinks: [], boundPieceID: nil)
    }

    // MARK: - The offer (§6.1: may suggest, must never impose)

    private func writtenLinks(_ plan: PromotionPlan) -> [CanvasNodeID] {
        plan.linksAccepted ? plan.offeredLinks.map(\.node) : []
    }

    /// Append `[[artifact]]` to each offered member's OWN note — the member
    /// pointing at what the region produced. Runs only when the writer accepted.
    private func writeOfferedLinks(_ plan: PromotionPlan, artifactTitle: String) async throws {
        guard plan.linksAccepted, !plan.offeredLinks.isEmpty else { return }
        let link = Promotion.linkText(to: artifactTitle, label: nil)
        try? await store.documentStore?.flushPendingSave()
        for offer in plan.offeredLinks {
            guard let item = TreeWalk.find(id: offer.itemID, in: store.manifest.research),
                  let path = item.path else { continue }
            let body = readBody(atPath: path)
            guard !body.contains(link) else { continue }
            try await write(body + "\n\n" + link + "\n", toPath: path)
        }
    }

    // MARK: - Disk

    /// Write a body to a research item's file.
    ///
    /// **The flush is not optional** (`AddNoteTool.swift:48-55`): a queued 750 ms
    /// `scheduleFileSave` for this path otherwise fires AFTER the write and
    /// overwrites it with stale content.
    private func writeBody(_ text: String, toItem id: String) async throws {
        guard let item = TreeWalk.find(id: id, in: store.manifest.research),
              let path = item.path else { throw PromotionFailure.itemHasNoFile(id) }
        try? await store.documentStore?.flushPendingSave()
        try await write(text, toPath: path)
    }

    /// Through the same `NSFileCoordinator` path research-note saves use, so a
    /// promotion into a cloud-synced project does not race iCloud. The direct
    /// write is the no-`DocumentStore` fallback (load-only contexts), mirroring
    /// `ProjectStore+Palette.paletteCoordinatedWrite`.
    private func write(_ text: String, toPath path: String) async throws {
        if let ds = store.documentStore {
            try await ds.performFileSave(path: path, text: text)
            return
        }
        try text.write(to: store.url.appendingPathComponent(path),
                       atomically: true, encoding: .utf8)
    }

    private func readBody(atPath path: String) -> String {
        (try? String(contentsOf: store.url.appendingPathComponent(path), encoding: .utf8)) ?? ""
        // adr-0018-ok: a research note is not manuscript — it has no op log and
        // no second representation to drift from.
    }

    // MARK: - The mark

    private func isRegion(_ source: PromotionSource) -> Bool {
        if case .region = source { return true }
        return false
    }

    /// The one scene change a promotion makes, through the outside verb.
    private func mark(_ itemID: String, for source: PromotionSource, named: String) {
        switch source {
        case .scrap(let node):
            model.mutateFromInspector(named) { $0.setPromotedItem(itemID, for: node) }
        case .region(let region):
            model.mutateFromInspector(named) {
                $0.updateRegion(region) { $0.promotedItemID = itemID }
            }
        case .line:
            return   // nothing on a line to mark; no undo step either
        }
        model.bumpSceneRevision()
    }
}
```

**One thing to get right while writing this:** `readBody`'s `// adr-0018-ok:` marker must be on the line the read STARTS on. Run the annotation guard early (Step 4) rather than discovering it at the end.

- [ ] **Step 4: Add this file to the tripwire-32 census**

In `MaughamTests/TripwireGrepTests.swift`, in `test_theCanvasUndoBracketIsReachedFromAnotherColumnByOneVerbOnly`, the expectation becomes:

```swift
            ["LineInspector.swift": [Self.canvasOutsideVerb],
             "PromotionPerformer.swift": [Self.canvasOutsideVerb],
             "RegionInspector.swift": [Self.canvasOutsideVerb]],
```

and add one line to that test's doc comment above it:

```swift
    /// 1C-c2 added the third: `PromotionPerformer` writes the promoted mark from
    /// outside the canvas, and `beginPromotion` can run while a focused scrap
    /// holds "Edit Scrap" open.
```

- [ ] **Step 5: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionPerformerTests -only-testing MaughamTests/TripwireGrepTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — 20 performer tests, and the whole tripwire suite green including the planted-offender companion.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/PromotionPerformer.swift \
        MaughamTests/Canvas/PromotionPerformerTests.swift \
        MaughamTests/TripwireGrepTests.swift
git commit -m "feat(canvas): performing a promotion, through the real store APIs

@MainActor and async throws with no inout on the path - ProjectStore is
@MainActor and an inout CanvasScene cannot cross an await in Swift 6. Validate
first, write second, so a refusal leaves nothing behind; flushPendingSave
before every body write, or a queued 750ms save blanks it.

Tripwire 32's census gains a third entry by name. An update rewrites the
prose and keeps a palette card's swatches, notes and images.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeXFCPAiAdnJ2mMCdRLvH8"
```

---

### Task 4: The sheet — the writer sees what will be produced, and where

**Files:**
- Create: `Maugham/Canvas/PromotionSheet.swift`
- Test: `MaughamTests/Canvas/PromotionSheetTests.swift`

**Interfaces:**
- **Consumes:** everything Task 2 produces; `PaletteCard.Kind`; `RegionInspector.PieceChoice`; `CanvasRenderer.chipTitle(for:in:scraps:)`.
- **Produces:** `@Observable @MainActor final class PromotionSheetModel: Identifiable` — `init(source:scene:scraps:pieces:artifacts:readBody:)`, `let source`, `var availableTargets: [PromotionTarget]`, `var blockedReason: String?`, `private(set) var selectedTarget: PromotionTarget?`, `func select(_:)`, `var editedTitle: String`, `var linksAccepted: Bool`, `var selectedPieceID: String?`, `var paletteKind: PaletteCard.Kind`, `var mode: PromotionMode`, `var availableModes: [PromotionMode]`, `var preview: PromotionPlan?`, `var resolvedPlan: PromotionPlan?`, `var canCommit: Bool`, `var refusal: String?`, `var discardNotice: String?`, `static let precedenceNote: String`, `var sourceDescription: String`; `struct PromotionSheet: View` — `init(model:onCommit:onCancel:)`.

**Three defaults are deliberate and must not be "improved":**
1. `selectedTarget` starts **nil**, so nothing can be committed by pressing return on a sheet that has just appeared.
2. `linksAccepted` starts **false** — an offer that arrives pre-accepted is an imposition with a checkbox, and the silent conversion is what §6.1 forbids outright.
3. `mode` starts **`.new`** even when an artifact exists, so "rewrite the writer's note" is never the thing under the cursor.

**`readBody` is a closure, called once per target selection.** The wiki-link duplicate check needs the destination note's text, which is disk I/O — and this class must stay testable without a `ProjectStore`. The modifier supplies the real one in Task 5.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/PromotionSheetTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

/// The sheet's model — §6.1's "previewable", made a value a test can drive.
/// Which SwiftUI arm renders cannot be asserted (`_ConditionalContent`'s type is
/// branch-invariant), so everything the view branches on lives here instead.
@MainActor
final class PromotionSheetTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let r1 = CanvasRegionID("r1")
    private let l1 = CanvasLineID("l1")

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero, width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 0, y: 200),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [a, b]))
        s.insertLine(CanvasLine(id: l1, from: a, to: b))
        return s
    }

    private let texts: [CanvasNodeID: String] = [
        CanvasNodeID("a"): "The falls\n\nbody",
        CanvasNodeID("b"): "October's doctor",
    ]

    private let pieces = [RegionInspector.PieceChoice(id: "piece-3", title: "Chapter Three")]

    private func model(_ source: PromotionSource,
                       scene: CanvasScene? = nil,
                       artifacts: [String: String] = [:],
                       body: @escaping (String) -> String? = { _ in nil }) -> PromotionSheetModel {
        PromotionSheetModel(source: source, scene: scene ?? self.scene(), scraps: texts,
                            pieces: pieces, artifacts: ArtifactIndex(titlesByID: artifacts),
                            readBody: body)
    }

    // MARK: - Opening

    func test_theSheetOffersExactlyTheTargetsTheModelAllows() {
        XCTAssertEqual(Set(model(.scrap(a)).availableTargets),
                       [.researchNote, .paletteCard, .intentStatement])
        XCTAssertEqual(Set(model(.region(r1)).availableTargets),
                       [.paletteCard, .pieceBinding])
    }

    func test_itStartsWithNothingSelectedSoNothingCommitsByAccident() {
        let m = model(.scrap(a))
        XCTAssertNil(m.selectedTarget)
        XCTAssertNil(m.preview)
        XCTAssertFalse(m.canCommit)
    }

    func test_aBlockedSourceSaysWhyInsteadOfShowingAnEmptyList() {
        let m = model(.line(l1))
        XCTAssertTrue(m.availableTargets.isEmpty)
        XCTAssertNotNil(m.blockedReason)
        XCTAssertFalse(m.canCommit)
    }

    func test_theSourceIsNamedSoTheWriterKnowsWhatTheyInvokedItOn() {
        XCTAssertTrue(model(.scrap(a)).sourceDescription.contains("The falls"))
        XCTAssertTrue(model(.region(r1)).sourceDescription.contains("Act II fog"))
    }

    // MARK: - Choosing a target

    func test_choosingATargetProducesAPreviewBeforeAnythingIsWritten() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        XCTAssertEqual(m.preview?.title, "The falls")
        XCTAssertEqual(m.preview?.destinationDescription, "research/")
        XCTAssertTrue(m.canCommit)
    }

    func test_choosingATargetSeedsTheEditableTitle() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        XCTAssertEqual(m.editedTitle, "The falls")
    }

    func test_theWriterCanEditTheTitleBeforeCommitting() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        m.editedTitle = "Niagara, 3am"
        XCTAssertEqual(m.resolvedPlan?.title, "Niagara, 3am")
        XCTAssertEqual(m.resolvedPlan?.body, "The falls\n\nbody",
                       "editing the title must not touch the body")
    }

    func test_anEmptyEditedTitleBlocksCommit() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        m.editedTitle = "   "
        XCTAssertFalse(m.canCommit, "the performer would refuse it; the sheet says so first")
    }

    func test_switchingTargetsReseedsTheTitleRatherThanKeepingAnEdit() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        m.editedTitle = "Niagara, 3am"
        m.select(.paletteCard)
        XCTAssertEqual(m.editedTitle, "The falls")
    }

    // MARK: - Update or New

    func test_anUnpromotedSourceOffersOnlyNew() {
        let m = model(.scrap(a))
        m.select(.researchNote)
        XCTAssertEqual(m.availableModes, [.new])
    }

    func test_aPromotedSourceOffersBothAndStartsOnNew() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.scrap(a), scene: s, artifacts: ["res-a": "The falls"])
        m.select(.researchNote)
        XCTAssertEqual(m.availableModes, [.new, .update(itemID: "res-a", title: "The falls")])
        XCTAssertEqual(m.mode, .new,
                       "rewriting the writer's note must never be the thing under "
                       + "the cursor")
    }

    func test_choosingUpdateNamesTheNoteThatWillBeRewritten() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.scrap(a), scene: s, artifacts: ["res-a": "The falls"])
        m.select(.researchNote)
        m.mode = .update(itemID: "res-a", title: "The falls")
        XCTAssertTrue(m.resolvedPlan!.destinationDescription.contains("The falls"))
    }

    func test_switchingToATargetThatCannotUpdateResetsTheMode() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.scrap(a), scene: s, artifacts: ["res-a": "The falls"])
        m.select(.researchNote)
        m.mode = .update(itemID: "res-a", title: "The falls")
        m.select(.intentStatement)
        XCTAssertEqual(m.mode, .new)
        XCTAssertEqual(m.availableModes, [.new], "an intent doc accumulates")
    }

    // MARK: - The offer, the discards, the piece, the kind

    func test_theLinkOfferArrivesUncheckedForARegion() {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        let m = model(.region(r1), scene: s, artifacts: ["res-a": "The falls"])
        m.select(.paletteCard)
        XCTAssertEqual(m.preview?.offeredLinks.count, 1)
        XCTAssertFalse(m.linksAccepted)
        XCTAssertFalse(m.resolvedPlan!.linksAccepted)
        m.linksAccepted = true
        XCTAssertTrue(m.resolvedPlan!.linksAccepted)
    }

    func test_theDiscardsAreSpelledOutForARegionAndAbsentForAScrap() {
        let region = model(.region(r1))
        region.select(.paletteCard)
        let notice = try? XCTUnwrap(region.discardNotice)
        XCTAssertTrue(notice?.lowercased().contains("line") == true)
        XCTAssertTrue(notice?.lowercased().contains("layout") == true)

        let scrap = model(.scrap(a))
        scrap.select(.researchNote)
        XCTAssertNil(scrap.discardNotice)
    }

    func test_aPieceBindingCannotCommitUntilAPieceIsChosen() {
        let m = model(.region(r1))
        m.select(.pieceBinding)
        XCTAssertFalse(m.canCommit)
        m.selectedPieceID = "piece-3"
        XCTAssertTrue(m.canCommit)
        XCTAssertEqual(m.resolvedPlan?.pieceID, "piece-3")
    }

    func test_thePaletteKindRidesTheResolvedPlan() {
        let m = model(.scrap(a))
        m.select(.paletteCard)
        m.paletteKind = .motif
        XCTAssertEqual(m.resolvedPlan?.paletteKind, .motif)
    }

    // MARK: - Wiki-links

    private func promotedScene() -> CanvasScene {
        var s = scene()
        s.setPromotedItem("res-a", for: a)
        s.setPromotedItem("res-b", for: b)
        return s
    }

    func test_aLineWithBothEndsPromotedPreviewsTheExactTextItWillAppend() {
        let m = model(.line(l1), scene: promotedScene(),
                      artifacts: ["res-a": "The falls", "res-b": "October's doctor"])
        XCTAssertEqual(m.availableTargets, [.wikiLink])
        m.select(.wikiLink)
        XCTAssertEqual(m.preview?.wikiLinkWrite?.linkText, "[[October's doctor]]")
        XCTAssertTrue(m.canCommit)
    }

    /// The destination is read ONCE, when the target is chosen — not per body
    /// evaluation, and not per keystroke in the title field.
    func test_theDestinationIsReadOnceAndARepeatedLinkRefusesCommit() {
        var reads = 0
        let m = model(.line(l1), scene: promotedScene(),
                      artifacts: ["res-a": "The falls", "res-b": "October's doctor"],
                      body: { _ in reads += 1; return "The falls.\n\n[[October's doctor]]\n" })
        m.select(.wikiLink)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(m.preview!.linkAlreadyPresent)
        XCTAssertFalse(m.canCommit)
        XCTAssertNotNil(m.refusal)
        _ = m.resolvedPlan
        XCTAssertEqual(reads, 1, "resolving a plan must not go back to disk")
    }

    func test_thePrecedenceNoteSaysWhichLayerIsDurable() {
        XCTAssertTrue(PromotionSheetModel.precedenceNote.lowercased().contains("scratch"))
        XCTAssertTrue(PromotionSheetModel.precedenceNote.contains("[["))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionSheetTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'PromotionSheetModel' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/PromotionSheet.swift`**

```swift
import SwiftUI
import MaughamCore

/// The promotion sheet's state, lifted out of the view so every branch it makes
/// is reachable from a test that hosts no SwiftUI — the same discipline
/// `RegionInspector.citeAffordance` follows, and for the same reason.
///
/// `Identifiable` because `.sheet(item:)` presents it; the id is per-invocation,
/// so invoking the command twice presents two sheets rather than reusing one
/// whose state belongs to the previous selection.
@Observable
@MainActor
final class PromotionSheetModel: Identifiable {

    /// Spec §5's precedence, stated once, plainly, where it costs the writer
    /// something — which is the only place a rule like this is read.
    static let precedenceNote =
        "Canvas lines are scratch — they cost nothing to be wrong about. "
        + "[[Wiki-links]] are the durable layer, which is why a line can only "
        + "become one once both of its cards have been promoted."

    let id = UUID()
    let source: PromotionSource

    private let scene: CanvasScene
    private let scraps: [CanvasNodeID: String]
    private let artifacts: ArtifactIndex
    /// itemID → the artifact's body on disk. Called once per target selection.
    private let readBody: (String) -> String?

    let pieces: [RegionInspector.PieceChoice]
    let availableTargets: [PromotionTarget]
    let blockedReason: String?

    private(set) var selectedTarget: PromotionTarget?
    private(set) var availableModes: [PromotionMode] = [.new]
    private(set) var preview: PromotionPlan?

    var editedTitle = ""
    var linksAccepted = false
    var selectedPieceID: String?
    var paletteKind: PaletteCard.Kind = .other
    var mode: PromotionMode = .new

    /// The destination's body as of the last `select(_:)`. A SNAPSHOT — the
    /// performer checks the live file again before it writes.
    private var destinationBody: String?

    init(source: PromotionSource,
         scene: CanvasScene,
         scraps: [CanvasNodeID: String],
         pieces: [RegionInspector.PieceChoice],
         artifacts: ArtifactIndex,
         readBody: @escaping (String) -> String?) {
        self.source = source
        self.scene = scene
        self.scraps = scraps
        self.pieces = pieces
        self.artifacts = artifacts
        self.readBody = readBody
        self.availableTargets = Promotion.targets(for: source, in: scene, artifacts: artifacts)
        self.blockedReason = Promotion.blockedReason(for: source, in: scene, artifacts: artifacts)
    }

    /// What the writer invoked this on, in their own words.
    var sourceDescription: String {
        switch source {
        case .scrap(let id):
            return "The card “\(CanvasRenderer.chipTitle(for: id, in: scene, scraps: scraps))”"
        case .region(let id):
            return "The region “\(scene.region(id)?.displayLabel ?? CanvasRegion.untitledLabel)”"
        case .line:
            return "This line"
        }
    }

    /// Choosing a target is the one place work happens: the mode list is
    /// rebuilt, the title is re-seeded, and the destination is read from disk
    /// exactly once.
    func select(_ target: PromotionTarget) {
        selectedTarget = target
        let existing = Promotion.existingArtifact(for: source, target: target,
                                                  in: scene, artifacts: artifacts)
        availableModes = Promotion.modes(for: target, existing: existing)
        // Never carried over: an update chosen for one target must not survive
        // into a target that cannot update.
        mode = .new
        destinationBody = nil
        if target == .wikiLink, case .line(let id) = source, let line = scene.line(id),
           let itemID = scene.node(line.from)?.promotedItemID {
            destinationBody = readBody(itemID)
        }
        preview = Promotion.plan(request(applyingEdits: false), in: scene)
        editedTitle = preview?.title ?? ""
    }

    /// The plan as it stands with the writer's edits applied — what Commit sends.
    var resolvedPlan: PromotionPlan? {
        guard var plan = Promotion.plan(request(applyingEdits: true), in: scene) else { return nil }
        plan.title = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.linksAccepted = linksAccepted
        return plan
    }

    var canCommit: Bool {
        guard let plan = resolvedPlan else { return false }
        // A binding produces no artifact, so it needs a piece and not a name;
        // everything else needs a name and must not be a link already written.
        if plan.producedKind == .pieceBinding { return plan.pieceID != nil }
        return !plan.title.isEmpty && !plan.linkAlreadyPresent
    }

    /// Why Commit is off, when the reason is not simply "choose a target".
    var refusal: String? {
        guard let plan = resolvedPlan else { return nil }
        if plan.linkAlreadyPresent {
            return "That link is already in “\(plan.title)”."
        }
        if plan.producedKind == .pieceBinding && plan.pieceID == nil {
            return "Choose a piece."
        }
        if plan.producedKind != .pieceBinding
            && editedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "This needs a name."
        }
        return nil
    }

    /// §6.1: promotion is allowed to be lossy — and the writer is told which
    /// parts are dropped, before committing rather than after.
    var discardNotice: String? {
        guard let discards = preview?.discards, !discards.isEmpty else { return nil }
        var parts: [String] = []
        if discards.contains(.lines) { parts.append("the lines between these cards") }
        if discards.contains(.layout) { parts.append("their layout") }
        return "Not carried across: " + parts.joined(separator: " and ")
            + ". The canvas keeps them."
    }

    private func request(applyingEdits: Bool) -> PromotionRequest {
        PromotionRequest(
            source: source,
            target: selectedTarget ?? .researchNote,
            mode: applyingEdits ? mode : .new,
            scraps: scraps,
            piece: pieces.first { $0.id == selectedPieceID },
            paletteKind: paletteKind,
            artifacts: artifacts,
            destinationBody: destinationBody)
    }
}

/// One verb, previewed. Scrivener's Commit is the model: a named command with a
/// stated rule and a predictable outcome (§6.1).
struct PromotionSheet: View {

    @Bindable var model: PromotionSheetModel
    let onCommit: (PromotionPlan) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Promote").font(.headline).padding([.top, .horizontal], 20)
            Text(model.sourceDescription)
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 2)

            Form {
                if let why = model.blockedReason {
                    Section {
                        Text(why)
                        Text(PromotionSheetModel.precedenceNote)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    targetSection
                    if model.selectedTarget != nil { previewSection }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Promote") {
                    if let plan = model.resolvedPlan { onCommit(plan) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canCommit)
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    @ViewBuilder
    private var targetSection: some View {
        Section("Produce") {
            ForEach(model.availableTargets) { target in
                Button {
                    model.select(target)
                } label: {
                    HStack {
                        Text(target.writerFacingName)
                        Spacer()
                        if model.selectedTarget == target {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section("Preview") {
            if model.selectedTarget != .pieceBinding {
                TextField("Name", text: $model.editedTitle)
            }
            if let plan = model.preview {
                LabeledContent("Goes to", value: plan.destinationDescription)
                if !plan.body.isEmpty {
                    Text(plan.body)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
            if model.availableModes.count > 1 {
                Picker("When it exists", selection: $model.mode) {
                    ForEach(model.availableModes) { mode in
                        switch mode {
                        case .new: Text("Make a new one").tag(mode)
                        case .update(_, let title): Text("Rewrite “\(title)”").tag(mode)
                        }
                    }
                }
            }
            if model.selectedTarget == .paletteCard {
                Picker("Kind", selection: $model.paletteKind) {
                    ForEach(PaletteCard.Kind.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
            }
            if model.selectedTarget == .pieceBinding {
                Picker("Piece", selection: $model.selectedPieceID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(model.pieces) { Text($0.title).tag(String?.some($0.id)) }
                }
            }
            if let offers = model.preview?.offeredLinks, !offers.isEmpty {
                Toggle(isOn: $model.linksAccepted) {
                    Text("Also link \(offers.count) promoted card\(offers.count == 1 ? "" : "s") to it")
                    Text("A suggestion, not a rule — membership is loose and a "
                         + "wiki-link is specific.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let notice = model.discardNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if let refusal = model.refusal {
                Text(refusal).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
```

**If the Release type-checker complains about `previewSection`** — it is a long `@ViewBuilder` chain — split it in two (`previewSection` + `optionsSection`) rather than simplifying what it says. That is the same ceiling `ProjectWindow` extracts modifiers for.

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionSheetTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 18 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/PromotionSheet.swift MaughamTests/Canvas/PromotionSheetTests.swift
git commit -m "feat(canvas): the promotion sheet - see it before it happens

Three defaults are the design and not conveniences: nothing is selected when
the sheet opens, the link offer arrives unchecked, and Update is never the
mode under the cursor. The destination note is read once per target choice,
not per keystroke.

Every branch the view makes lives on the model, because which SwiftUI arm
renders cannot be asserted.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeXFCPAiAdnJ2mMCdRLvH8"
```

---

### Task 5: The gesture — one command, three buttons and a keystroke

**Files:**
- Modify: `Maugham/Models/MaughamNotifications.swift`, `Maugham/MaughamApp.swift`, `Maugham/Views/ProjectWindow.swift`, `Maugham/Canvas/RegionInspector.swift`, `Maugham/Canvas/LineInspector.swift`
- Test: `MaughamTests/Canvas/PromotionCommandTests.swift`

**Interfaces:**
- **Consumes:** `PromotionSheetModel`, `PromotionSheet` (Task 4); `PromotionPerformer` (Task 3); `ArtifactIndex.over(research:)` (Task 2); `ProjectWindow.pieceChoices(in:)`; `MaughamEvent.post(_:to:)`; `View.onKeyWindowCommand(_:window:perform:)`.
- **Produces:** `Notification.Name.maughamPromoteCanvasSelection`; `FocusedCanvasPromotionKey` + `FocusedValues.canvasPromotable: Bool?`; `private struct CanvasPromotionModifier: ViewModifier` in `ProjectWindow.swift`; a `Promote…` button in `RegionInspector` and `LineInspector`.

**Spec §10's first open question closes here: a menu command on the current selection, ⌘⇧↩.** ⌘⇧P is taken by "Toggle Research Preview" (`MaughamApp.swift:208`). The artifact rail lost because the canvas has no rail and adding persistent chrome to hold one is a bigger change than the verb it would serve. **Every inspector button posts the same command the menu posts** — one presentation site, so the button and the keystroke cannot drift into behaving differently.

**The hazard this design walks past, and why the buttons are still safe.** `TranslationReviewModifier` (`ProjectWindow.swift:1750-1755`) records the v0.24.0 "enter does nothing" bug: **a `.keyWindow` post from inside a sheet or confirmation dialog is dropped**, because that dialog's own window holds key status while its action runs. The inspector buttons are in the project window's detail column, so the project window *is* key when they are clicked — but this is exactly the assumption that shipped a defect once, so **Step 5 proves it through a real key window rather than asserting it.** If a `Promote…` button ever moves inside a sheet, it must call a closure instead of posting.

**The modifier reads `model.selection` and must never read `model.scene`.** Requirement and symptom: `CanvasModel` is `@Observable` with the whole scene in one stored property that every drag frame and every coast frame writes — a read of `scene` anywhere on this path puts the window's body on the drag loop at 60–120 Hz. `selection` is a separate stored property that moves on a click. **Measure it** (Step 6) rather than trusting the tracking granularity.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/PromotionCommandTests.swift`:

```swift
import XCTest
import AppKit
import SwiftUI
@testable import Maugham

/// The command that reaches the sheet. **The delivery path is the subject**:
/// this area has shipped a whole feature nothing could reach (1C-a's ⌘Z, built
/// and twenty-two tests deep, greyed out in the Edit menu), and the lesson from
/// the mode-UX milestone is that anything with a menu item or a key equivalent
/// needs one test that models the real path.
@MainActor
final class PromotionCommandTests: XCTestCase {

    private let a = CanvasNodeID("a")

    // MARK: - Enablement

    func test_theCommandIsOfferedOnlyOnTheCanvasWithSomethingSelected() {
        let model = CanvasModel()
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(binderSegment: .canvas,
                                                            selection: model.selection))
        XCTAssertTrue(CanvasPromotionModifier.isPromotable(binderSegment: .canvas,
                                                           selection: .node(a)))
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(binderSegment: .manuscript,
                                                            selection: .node(a)),
                       "the manuscript editor has no canvas selection to promote")
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(binderSegment: .research,
                                                            selection: .region(CanvasRegionID("r"))))
    }

    func test_everySelectionKindIsPromotable() {
        // A caller census in enum form: adding a `CanvasSelection` case makes
        // this fail to compile rather than silently shipping a fourth primitive
        // the command ignores.
        for selection: CanvasSelection in [.node(a), .region(CanvasRegionID("r")),
                                           .line(CanvasLineID("l"))] {
            XCTAssertTrue(CanvasPromotionModifier.isPromotable(binderSegment: .canvas,
                                                               selection: selection),
                          "\(selection)")
        }
    }

    // MARK: - The real delivery path

    /// A `.keyWindow` post is delivered to the key window's receivers and to no
    /// others. Driven through a REAL `NSWindow` because the drop rule is about
    /// key status — the v0.24.0 bug was a post made while a dialog held it.
    func test_theCommandReachesTheKeyWindowAndOnlyTheKeyWindow() {
        let key = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        key.makeKeyAndOrderFront(nil)
        defer { key.close(); other.close() }

        var keyGot = 0, otherGot = 0
        let token = NotificationCenter.default.addObserver(   // adr-0021-ok: test observer
            forName: .maughamPromoteCanvasSelection, object: nil, queue: nil) { note in
            if MaughamEvent.shouldDeliver(note, to: .forWindow(key, kind: .keyWindow)) {
                keyGot += 1
            }
            if MaughamEvent.shouldDeliver(note, to: .forWindow(other, kind: .keyWindow)) {
                otherGot += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
        XCTAssertEqual(keyGot, 1)
        XCTAssertEqual(otherGot, 0)
    }
    // NOTE for the implementer: `EventReceiverContext.forWindow(_:kind:)` reads
    // `NSWindow.isKeyWindow` and is main-actor work, while the observer closure
    // is not isolated. If Swift 6 rejects the call inside the closure, record
    // the notifications in the closure and evaluate `shouldDeliver` after the
    // post, on the test's own actor — **do not** drop to comparing `userInfo`
    // by hand, which is the guard `MaughamEvent.shouldDeliver` exists to own.

    /// The inspector buttons post the SAME command the menu posts, so a writer
    /// who clicks and a writer who presses ⌘⇧↩ take the same path.
    func test_theInspectorButtonsPostTheSameCommandAsTheMenu() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Canvas
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham/Canvas")
        for file in ["RegionInspector.swift", "LineInspector.swift", "ScrapInspector.swift"] {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains(".maughamPromoteCanvasSelection"),
                          "\(file) must reach promotion through the one command. A "
                          + "closure of its own would be a second path that can "
                          + "drift from the keystroke.")
        }
    }

    /// The name must not collide with the collection-piece promotion that
    /// already exists (`MaughamNotifications.swift:126`).
    func test_theCanvasCommandIsNotThePiecePromotionCommand() {
        XCTAssertNotEqual(Notification.Name.maughamPromoteCanvasSelection,
                          Notification.Name.maughamPromotePiece)
    }
}
```

**`ScrapInspector.swift` does not exist until Task 6.** Write that third filename into the census now anyway: the test goes red, Task 6 makes it green, and the alternative — remembering to add it later — is how a surface ships with two ways to promote.

- [ ] **Step 2: Run it and watch it fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionCommandTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — no `maughamPromoteCanvasSelection`, no `CanvasPromotionModifier`.

- [ ] **Step 3: Add the notification name**

In `Maugham/Models/MaughamNotifications.swift`, beside `maughamPromotePiece`:

```swift
    /// Scope: .keyWindow — "Promote…" (⌘⇧↩) acting on the canvas's current
    /// selection. **Distinct from `maughamPromotePiece`**, which promotes a
    /// collection piece to its own project: two different verbs that happen to
    /// share a word.
    public static let maughamPromoteCanvasSelection =
        Notification.Name("maugham.promote.canvas")
```

- [ ] **Step 4: Add the menu item and the focused value**

In `Maugham/MaughamApp.swift`, beside `FocusedProjectURLKey`:

```swift
/// Whether the focused window's canvas has something to promote. Published by
/// `CanvasPromotionModifier`; read only by the File-menu item, so a `Promote…`
/// that could do nothing is disabled rather than silently no-op.
struct FocusedCanvasPromotionKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var canvasPromotable: Bool? {
        get { self[FocusedCanvasPromotionKey.self] }
        set { self[FocusedCanvasPromotionKey.self] = newValue }
    }
}

/// File → "Promote…". Acts on the canvas's current selection; the focused
/// window resolves what that is, exactly as the Share and Translation items do.
private struct FocusedPromoteButton: View {
    @FocusedValue(\.canvasPromotable) private var promotable
    var body: some View {
        Button("Promote…") {
            MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .disabled(promotable != true)
    }
}
```

and place it in the File group, immediately after the `Button("Add Research File…")` block (`MaughamApp.swift:150-153`):

```swift
                FocusedPromoteButton()
```

- [ ] **Step 5: Add the modifier to `ProjectWindow.swift`**

At the bottom of the file, beside `TranslationReviewModifier`:

```swift
/// The canvas's `Promote…` command: enablement, presentation and performance,
/// all in one place so `ProjectWindow.body` gains a single line.
///
/// **`internal`, not `private`, and that is required rather than a style
/// choice**: `@testable import` reaches `internal` and cannot see `private`, and
/// `isPromotable` below is the enablement rule a test drives. `PersonaModifier`
/// in this same file is non-private for exactly that reason; the ones that are
/// private have nothing a test needs.
///
/// **It reads `model.selection` and must NEVER read `model.scene`.**
/// `CanvasModel` is `@Observable` with the whole scene in one stored property,
/// and every drag frame and every coast frame writes it — a read here would put
/// the window's body on the drag loop at 60–120 Hz. `selection` moves on a
/// click. The same rule keeps `store` off this path except inside the two
/// actions below, which run from a user gesture: `begin()` snapshots the
/// manifest once, and `commit(_:)` performs.
struct CanvasPromotionModifier: ViewModifier {
    let window: NSWindow?
    let store: ProjectStore?
    let model: CanvasModel
    let binderSegment: BinderSegment

    @State private var sheet: PromotionSheetModel?
    @State private var failure: String?

    /// Pure and static so the enablement rule is reachable from a test that
    /// hosts no SwiftUI — and so adding a `CanvasSelection` case makes the
    /// compiler enumerate this decision with everything else.
    static func isPromotable(binderSegment: BinderSegment,
                             selection: CanvasSelection?) -> Bool {
        guard binderSegment == .canvas else { return false }
        switch selection {
        case .node, .region, .line: return true
        case nil: return false
        }
    }

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.canvasPromotable,
                               Self.isPromotable(binderSegment: binderSegment,
                                                 selection: model.selection))
            .onKeyWindowCommand(.maughamPromoteCanvasSelection, window: window) { _ in begin() }
            .sheet(item: $sheet) { model in
                PromotionSheet(model: model,
                               onCommit: { commit($0) },
                               onCancel: { sheet = nil })
            }
            .alert("Promotion failed",
                   isPresented: Binding(get: { failure != nil },
                                        set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
    }

    /// The manifest is read ONCE, here, and handed to the sheet as plain values.
    private func begin() {
        guard let store, let selection = model.selection,
              Self.isPromotable(binderSegment: binderSegment, selection: selection) else { return }
        let source: PromotionSource
        switch selection {
        case .node(let id): source = .scrap(id)
        case .region(let id): source = .region(id)
        case .line(let id): source = .line(id)
        }
        let root = store.url
        sheet = PromotionSheetModel(
            source: source, scene: model.scene, scraps: model.scraps,
            pieces: ProjectWindow.pieceChoices(in: store.manifest.structure),
            artifacts: ArtifactIndex.over(research: store.manifest.research),
            readBody: { itemID in
                guard let item = TreeWalk.find(id: itemID, in: store.manifest.research),
                      let path = item.path else { return nil }
                return try? String(contentsOf: root.appendingPathComponent(path),
                                   encoding: .utf8)
                // adr-0018-ok: a research note is not manuscript.
            })
    }

    private func commit(_ plan: PromotionPlan) {
        guard let store else { return }
        sheet = nil
        Task { @MainActor in
            do {
                _ = try await PromotionPerformer(store: store, model: model).perform(plan)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
```

and apply it in `body`, beside the other modifiers (after `PaletteSegmentModifier`, `ProjectWindow.swift:326`) — **one line**:

```swift
        .modifier(CanvasPromotionModifier(window: window, store: store,
                                          model: canvasModel, binderSegment: binderSegment))
```

- [ ] **Step 6: Add the two inspector buttons**

In `RegionInspector.swift`, in the last `Section` (the one holding **Delete Region**), *above* the delete button:

```swift
            Section {
                Button("Promote…") {
                    // The SAME command the menu item and ⌘⇧↩ post, so the
                    // button and the keystroke cannot drift into behaving
                    // differently. A closure of our own would be a second path.
                    //
                    // Safe from this column, and the reason is worth knowing:
                    // a `.keyWindow` post made from inside a SHEET is dropped,
                    // because the sheet's own window holds key status (the
                    // v0.24.0 "enter does nothing" bug, `TranslationReviewModifier`).
                    // This button is in the project window itself.
                    MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
                }
                Text("Make a palette card from what lives here, or bind this "
                     + "region to a piece.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

In `LineInspector.swift`, the same button above **Delete Line**, with:

```swift
                Text("A line becomes a [[wiki-link]] once both of its cards have "
                     + "been promoted.")
```

- [ ] **Step 7: Run the tests, then measure the drag**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionCommandTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS except `test_theInspectorButtonsPostTheSameCommandAsTheMenu`, which stays red until Task 6 adds `ScrapInspector.swift`. **Say so in the commit** rather than deleting the third filename.

Then **measure the claim in the modifier's doc comment**, because this plan will not assert it: add a temporary `print` (or a `@State` counter) in `ProjectWindow.body`, run the app, drag a card across the canvas for two seconds, and confirm the body does **not** evaluate per frame. Remove the instrumentation before committing and put the result in the commit message. If it *does* evaluate per frame, the fix is to pass `model.selection != nil` in as a plain `Bool` computed one level down — do not ship the read.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Models/MaughamNotifications.swift Maugham/MaughamApp.swift \
        Maugham/Views/ProjectWindow.swift Maugham/Canvas/RegionInspector.swift \
        Maugham/Canvas/LineInspector.swift MaughamTests/Canvas/PromotionCommandTests.swift
git commit -m "feat(canvas): Promote... on the current selection, cmd-shift-return

Spec 10's first open question, closed: a menu command plus a button in each
inspector arm, every one of them posting the SAME keyWindow command. The
artifact rail lost because the canvas has no rail.

The buttons post rather than calling a closure so the click and the keystroke
cannot drift - safe here because the project window holds key status, which is
NOT true inside a sheet (the v0.24.0 bug, and the test drives a real window).

One line in ProjectWindow.body; the modifier reads selection and never scene.
The scrap arm's census entry stays red until the next task adds it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeXFCPAiAdnJ2mMCdRLvH8"
```

---

### Task 6: The scrap inspector arm — what a card became

**Files:**
- Create: `Maugham/Canvas/ScrapInspector.swift`
- Modify: `Maugham/Canvas/CanvasModel.swift` (a `selectedNode` resolver), `Maugham/Canvas/RegionInspector.swift` (the pane's third arm and two new arguments), `Maugham/Views/ProjectWindow.swift` (supply them; rename `openCraftIntent` to `openResearchItem`)
- Test: `MaughamTests/Canvas/ScrapInspectorTests.swift`

**Interfaces:**
- **Consumes:** `CanvasModel` (`scene`, `scraps`, `selection`), `CanvasNode.promotedItemID` (Task 1), `CanvasRenderer.chipTitle(for:in:scraps:)`, `.maughamPromoteCanvasSelection` (Task 5).
- **Produces:** `CanvasModel.selectedNode: CanvasNode?`; `struct ScrapInspector: View` — `init(model:nodeID:artifactTitle:onOpenResearchItem:)` and `static func artifactState(promotedItemID:title:) -> ScrapInspector.ArtifactState`; `RegionInspectorPane` gains `artifactTitle: (String) -> String?` and `onOpenResearchItem: (String) -> Void`.

**Why a card gets a pane at all, when 1C-c1 deliberately left it without one.** The field this slice added is invisible otherwise: a drawn mark says *that* a card was promoted and can never say *what it became*, and CLAUDE.md rule 8 asks every new data type for a surface that can inspect and act on it. It is also where the dangling case becomes legible — the note deleted out from under a mark.

**No Delete button** (Denver's ruling: the minimal arm). ⌫ stays the only route to deleting a scrap, and ADR 0026's consequence saying so stays true. **Do not add one on the grounds of symmetry with the other two arms** — that is a design change and it belongs to whoever opens it deliberately.

**`artifactTitle` is a deferred closure, and that is the same rule `paletteSwatchHexes` follows.** It walks the manifest, and it is called only when a promoted card is actually selected — never eagerly, and never for an unpromoted one.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/ScrapInspectorTests.swift`:

```swift
import XCTest
@testable import Maugham

/// The third arm of the canvas inspector. Which SwiftUI arm renders cannot be
/// asserted (`_ConditionalContent` is branch-invariant), so the decision the
/// view makes is lifted into `artifactState` and pinned here — the same shape
/// `RegionInspector.citeAffordance` uses.
@MainActor
final class ScrapInspectorTests: XCTestCase {

    private let a = CanvasNodeID("a")

    private func model(promoted: String? = nil) -> CanvasModel {
        let m = CanvasModel()
        m.withScene { s in
            s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80,
                                promotedItemID: promoted))
        }
        m.setScrapText("The falls at night\n\nSodium light.", for: a)
        return m
    }

    func test_theSelectedNodeResolvesThroughTheSceneAndNotTheRawId() {
        let m = model()
        XCTAssertNil(m.selectedNode, "no selection")
        m.selection = .node(a)
        XCTAssertEqual(m.selectedNode?.id, a)
        m.withScene { $0.remove(a) }
        XCTAssertNil(m.selectedNode,
                     "a stale id left by an undo answers nil rather than being "
                     + "handed out as a card that no longer exists")
    }

    func test_aRegionSelectionIsNotANodeSelection() {
        let m = model()
        m.selection = .region(CanvasRegionID("r1"))
        XCTAssertNil(m.selectedNode)
    }

    // MARK: - What the pane says

    func test_anUnpromotedCardSaysSoRatherThanShowingNothing() {
        XCTAssertEqual(ScrapInspector.artifactState(promotedItemID: nil, title: nil),
                       .notPromoted)
    }

    func test_aPromotedCardNamesWhatItBecame() {
        XCTAssertEqual(
            ScrapInspector.artifactState(promotedItemID: "res-a", title: "The falls at night"),
            .promoted(itemID: "res-a", title: "The falls at night"))
    }

    /// The dangling mark: the note was deleted after the promotion. The pane has
    /// to say so — silently showing "not promoted" would be a lie the writer
    /// cannot check, and showing a raw id would be one they cannot read.
    func test_aMarkWhoseArtifactIsGoneSaysThatRatherThanPretendingItIsUnpromoted() {
        XCTAssertEqual(ScrapInspector.artifactState(promotedItemID: "res-gone", title: nil),
                       .artifactMissing(itemID: "res-gone"))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapInspectorTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — no `selectedNode`, no `ScrapInspector`.

- [ ] **Step 3: Add the resolver to `CanvasModel`**

Beside `selectedRegion` and `selectedLine`:

```swift
    /// The selected card, RESOLVED through the scene — the same discipline
    /// `selectedLine` follows, and for the same reason: a stale id left behind
    /// by an undo answers nil here rather than being handed out as a card that
    /// is no longer in the scene.
    var selectedNode: CanvasNode? {
        guard case .node(let id) = selection else { return nil }
        return scene.node(id)
    }
```

- [ ] **Step 4: Write `Maugham/Canvas/ScrapInspector.swift`**

```swift
import SwiftUI

/// One card, in the inspector: what it says, what it became, and the way to
/// promote it.
///
/// **A card had no pane at all until 1C-c2, and this exists because of the
/// field that slice added.** A drawn mark can say *that* a card was promoted
/// and can never say *what it became*; CLAUDE.md rule 8 asks every new data
/// type for a surface that can inspect and act on it. It is also the only place
/// the dangling case is legible — the note deleted out from under a mark.
///
/// **There is no Delete button, deliberately.** ⌫ remains the only route to
/// deleting a scrap (ADR 0026's standing consequence). Adding one here for
/// symmetry with the region and line arms would be a design change wearing a
/// tidy-up's clothes.
///
/// **Promotion goes through the one command** — the same `.keyWindow` post the
/// File-menu item and ⌘⇧↩ make. A closure of its own would be a second path
/// that can drift from the keystroke.
struct ScrapInspector: View {

    /// What this card has produced, if anything. Lifted out of the view so the
    /// three-way decision is reachable from a test that hosts no SwiftUI.
    enum ArtifactState: Equatable {
        case notPromoted
        case promoted(itemID: String, title: String)
        /// A mark whose artifact is no longer in the project.
        case artifactMissing(itemID: String)
    }

    let model: CanvasModel
    let nodeID: CanvasNodeID
    /// Deferred: it walks the manifest, and it is called only when a promoted
    /// card is selected. Same rule as `CanvasView.paletteSwatchHexes`.
    let artifactTitle: (String) -> String?
    let onOpenResearchItem: (String) -> Void

    private var node: CanvasNode? { model.scene.node(nodeID) }

    static func artifactState(promotedItemID: String?, title: String?) -> ArtifactState {
        guard let itemID = promotedItemID else { return .notPromoted }
        guard let title else { return .artifactMissing(itemID: itemID) }
        return .promoted(itemID: itemID, title: title)
    }

    private var state: ArtifactState {
        let mark = node?.promotedItemID
        return Self.artifactState(promotedItemID: mark, title: mark.flatMap(artifactTitle))
    }

    var body: some View {
        Form {
            Section {
                Text(CanvasRenderer.chipTitle(for: nodeID, in: model.scene,
                                              scraps: model.scraps))
                    .lineLimit(2)
            } header: {
                Text("Card")
            } footer: {
                Text("The words live on the card. Editing them here isn't a thing "
                     + "— click into it on the canvas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Promoted") {
                switch state {
                case .notPromoted:
                    Text("Not promoted yet.").font(.caption).foregroundStyle(.secondary)
                case .promoted(let itemID, let title):
                    HStack(spacing: 6) {
                        Text("Became “\(title)”").lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Button("Open") { onOpenResearchItem(itemID) }
                            .buttonStyle(.borderless)
                    }
                case .artifactMissing:
                    Text("This card was promoted, and what it produced is no longer "
                         + "in the project.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Promote…") {
                    // The SAME command the menu item and ⌘⇧↩ post — see
                    // `RegionInspector` for why a closure of our own would be
                    // a second path, and why posting is safe from this column.
                    MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
                }
                Text("Promoting takes a copy. The card stays here with its words, "
                     + "and changing it afterwards doesn't change what it made.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 5: Add the third arm to the pane**

In `RegionInspector.swift`, `RegionInspectorPane` gains two stored properties and one arm. The `ContentUnavailableView`'s copy changes, and its comment about a selected card landing there is now false — **replace it rather than leaving it**:

```swift
struct RegionInspectorPane: View {

    let model: CanvasModel
    let pieces: [RegionInspector.PieceChoice]
    /// Deferred manifest lookups for the scrap arm — see `ScrapInspector`.
    let artifactTitle: (String) -> String?
    let onOpenResearchItem: (String) -> Void

    var body: some View {
        if let region = model.selectedRegion {
            RegionInspector(model: model, regionID: region.id, pieces: pieces)
        } else if let line = model.selectedLine {
            LineInspector(model: model, lineID: line.id)
        } else if let node = model.selectedNode {
            // 1C-c2's arm. A card used to land in the empty state below, which
            // was right while a scrap had nothing to say about itself — the
            // promoted mark is what changed that.
            ScrapInspector(model: model, nodeID: node.id,
                           artifactTitle: artifactTitle,
                           onOpenResearchItem: onOpenResearchItem)
        } else {
            // Tripwire 15: the full-frame chain is required, and so is the
            // enclosing stack's top alignment — `DetailPaneToggle` supplies the
            // second half. Without both, SwiftUI sizes to intrinsic content, the
            // stack collapses, and the segment picker floats to the middle of
            // the window. `HistoryPane` is the canonical example.
            ContentUnavailableView("Select something on the canvas",
                                   systemImage: "square.dashed")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
```

- [ ] **Step 6: Supply the two arguments, and rename the navigator**

In `ProjectWindow.swift`, `openCraftIntent` already does exactly what the Open button needs. Rename it and its one existing call site (`inspectorPane`'s `onOpenCraftIntent:` argument, `ProjectWindow.swift:1102`) — the name was always about the *destination*, not the caller:

```swift
    /// Navigate to a research item in the right pane: switch to Research and
    /// select it, which the existing click-to-edit flow opens.
    ///
    /// Reached from the craft-intent inspector affordance and, since 1C-c2, from
    /// a promoted card's **Open** button.
    private func openResearchItem(_ itemId: String) {
        binderSegment = .research
        selectedResearchId = itemId
    }
```

and `canvasInspector(store:)` becomes:

```swift
    private func canvasInspector(store: ProjectStore) -> some View {
        RegionInspectorPane(
            model: canvasModel,
            pieces: Self.pieceChoices(in: store.manifest.structure),
            // Deferred — walked only when a promoted card is selected.
            artifactTitle: { TreeWalk.find(id: $0, in: store.manifest.research)?.title },
            onOpenResearchItem: openResearchItem)
    }
```

- [ ] **Step 7: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ScrapInspectorTests -only-testing MaughamTests/PromotionCommandTests -only-testing MaughamTests/RegionBindingTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — including `test_theInspectorButtonsPostTheSameCommandAsTheMenu`, which Task 5 left red on purpose. `RegionBindingTests` is here because it constructs `RegionInspectorPane`; **if it fails to compile, add the two new arguments there rather than giving them defaults** — a default would let a future caller forget the scrap arm's lookups and ship a pane that says a promoted card is not promoted.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Canvas/ScrapInspector.swift Maugham/Canvas/CanvasModel.swift \
        Maugham/Canvas/RegionInspector.swift Maugham/Views/ProjectWindow.swift \
        MaughamTests/Canvas/ScrapInspectorTests.swift MaughamTests/Canvas/RegionBindingTests.swift
git commit -m "feat(canvas): a card's inspector says what it became

The mark this slice added is invisible without it: a drawn mark says THAT a
card was promoted and can never say what it became, and the dangling case -
the note deleted out from under a mark - is legible nowhere else.

No Delete button: backspace stays the only route to deleting a scrap, which is
a standing ADR 0026 consequence and not an oversight to tidy up.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeXFCPAiAdnJ2mMCdRLvH8"
```

---

### Task 7: The mark on the canvas, and in the accessibility tree

**Files:**
- Modify: `Maugham/Canvas/CanvasMaterial.swift`, `Maugham/Canvas/CanvasRenderer.swift`, `Maugham/Canvas/CanvasAccessibility.swift`
- Test: `MaughamTests/Canvas/PromotionRenderTests.swift`, `MaughamTests/Canvas/CanvasAccessibilityTests.swift` (extend)

**Interfaces:**
- **Consumes:** `CanvasNode.promotedItemID`, `CanvasRegion.promotedItemID` (Task 1); the raster harness `render(scene:size:…)` and `CanvasPage.differingPixels(from:in:)` (`MaughamTests/Canvas/CanvasRasterPage.swift:112,88`).
- **Produces:** `CanvasMaterial.promotedMarkWidth`, `.promotedMarkOpacity`; `CanvasRenderer.promotedMarkRect(inCard:)` and `.promotedMarkRect(inRegionChrome:)`; `CanvasAccessibility.promotedTerm`.

**A stripe along the card's left edge, not a dot.** Three positions are already spoken for and the fourth is not free either: the resize triangle owns the bottom-right corner, the connect dot owns the right edge vertically centred, and the text box starts 10 pt in from the top-left — so a corner dot would either collide with the first line of the writer's words or sit where an existing mark already means something. The left edge is outside the text inset at every card width, and it survives being zoomed out, which a 6 pt dot does not.

**It is PERMANENT chrome, like the resize triangle, and not selection chrome like the connect dot.** It states a durable fact about the card. `drawCard`'s comment already warns that the two adjacent marks mean opposite things and that moving either across that line is a design change — this one goes *outside* the `isSelected` block, and the comment gains a third entry.

**Both numbers live in `CanvasMaterial`.** The colour is `cardInk` at an opacity rather than a light/dark pair: `cardInk` is already appearance-dynamic, so one constant gives the right ink in both. Denver calibrates this by eye on the smoke — it is on the smoke list.

- [ ] **Step 1: Write the failing test**

`MaughamTests/Canvas/PromotionRenderTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import Maugham

/// The promoted mark, drawn. Every assertion is a two-render diff over scenes
/// that differ in exactly one model fact, with a control that must measure
/// zero — the 1C-b raster pattern, because "some pixels changed" proves nothing
/// without one.
@MainActor
final class PromotionRenderTests: XCTestCase {

    private let a = CanvasNodeID("a")
    private let r1 = CanvasRegionID("r1")
    private let size = CGSize(width: 800, height: 600)

    private func scene(promotedNode: Bool = false, promotedRegion: Bool = false) -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 100, y: 100),
                            width: 240, cachedHeight: 80,
                            promotedItemID: promotedNode ? "res-a" : nil))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 40, y: 40, width: 500, height: 300),
                                    promotedItemID: promotedRegion ? "res-fog" : nil))
        return s
    }

    func test_theControlMeasuresZeroSoAChangedCountMeansSomething() throws {
        let one = try render(scene: scene(), size: size)
        let two = try render(scene: scene(), size: size)
        XCTAssertEqual(one.differingPixels(from: two,
                                           in: CGRect(origin: .zero, size: size)), 0)
    }

    func test_aPromotedCardIsDrawnDifferentlyFromAnUnpromotedOne() throws {
        let plain = try render(scene: scene(), size: size)
        let marked = try render(scene: scene(promotedNode: true), size: size)
        XCTAssertGreaterThan(
            marked.differingPixels(from: plain, in: CGRect(x: 90, y: 90, width: 40, height: 100)),
            0,
            "a writer must be able to see which cards have produced something")
    }

    /// The mark is on the card's own left edge — not out on the ground, and not
    /// over where the text starts.
    func test_theMarkSitsInsideTheCardAndClearOfItsText() throws {
        let plain = try render(scene: scene(), size: size)
        let marked = try render(scene: scene(promotedNode: true), size: size)
        XCTAssertEqual(
            marked.differingPixels(from: plain,
                                   in: CGRect(x: 60, y: 100, width: 35, height: 80)), 0,
            "nothing changes on the ground to the left of the card")
        XCTAssertEqual(
            marked.differingPixels(from: plain,
                                   in: CGRect(x: 115, y: 100, width: 200, height: 80)), 0,
            "and nothing changes where the writer's words are")
    }

    /// Permanent chrome, not selection chrome: the mark is there whether or not
    /// the card is selected. Selecting an unpromoted card must not produce it,
    /// and deselecting a promoted one must not take it away.
    func test_theMarkIsPermanentChromeAndNotSelectionChrome() throws {
        let box = CGRect(x: 95, y: 95, width: 30, height: 90)
        let unselectedMarked = try render(scene: scene(promotedNode: true), size: size)
        let selectedMarked = try render(scene: scene(promotedNode: true), size: size,
                                        selection: .node(a))
        let selectedPlain = try render(scene: scene(), size: size, selection: .node(a))

        XCTAssertGreaterThan(unselectedMarked.differingPixels(from: try render(scene: scene(),
                                                                              size: size),
                                                              in: box), 0,
                             "drawn with nothing selected at all")
        XCTAssertGreaterThan(selectedMarked.differingPixels(from: selectedPlain, in: box), 0,
                             "and still drawn when the card IS selected")
    }

    func test_aPromotedRegionIsDrawnDifferentlyInItsChromeBar() throws {
        let plain = try render(scene: scene(), size: size)
        let marked = try render(scene: scene(promotedRegion: true), size: size)
        XCTAssertGreaterThan(
            marked.differingPixels(from: plain, in: CGRect(x: 35, y: 35, width: 30, height: 30)),
            0)
    }

    func test_anItemNodeGetsNoMarkBecauseItCannotBePromoted() throws {
        var withItem = CanvasScene()
        withItem.insert(CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                                   origin: CGPoint(x: 100, y: 100), width: 180,
                                   cachedHeight: 120, promotedItemID: "res-nonsense"))
        var withoutMark = CanvasScene()
        withoutMark.insert(CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                                      origin: CGPoint(x: 100, y: 100), width: 180,
                                      cachedHeight: 120))
        XCTAssertEqual(
            try render(scene: withItem, size: size)
                .differingPixels(from: try render(scene: withoutMark, size: size),
                                 in: CGRect(origin: .zero, size: size)), 0,
            "an item already exists as itself; a mark on one is meaningless and a "
            + "hand-edited sidecar can put one there")
    }
}
```

Extend `MaughamTests/Canvas/CanvasAccessibilityTests.swift` with:

```swift
    func test_aPromotedCardSaysSoAndTheKindStillComesFirst() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80, promotedItemID: "res-a"))
        let label = CanvasAccessibility.elements(scene: s, scraps: [:]).first?.label
        XCTAssertEqual(label, "Scrap, promoted",
                       "the kind stays FIRST because CanvasAXRole never reaches an "
                       + "assistive client")
    }

    func test_anUnpromotedCardSaysNothingExtra() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80))
        XCTAssertEqual(CanvasAccessibility.elements(scene: s, scraps: [:]).first?.label,
                       "Scrap")
    }

    func test_aPromotedCardWithConnectionsNamesBoth() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80, promotedItemID: "res-a"))
        s.insert(CanvasNode(id: CanvasNodeID("b"), kind: .scrap, origin: CGPoint(x: 0, y: 200),
                            width: 240, cachedHeight: 80))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b"), label: "because"))
        let label = try? XCTUnwrap(CanvasAccessibility.elements(scene: s, scraps: [:])
            .first { $0.id == .node(CanvasNodeID("a")) }?.label)
        XCTAssertTrue(label?.hasPrefix("Scrap, promoted,") == true, "found: \(label ?? "nil")")
    }

    func test_aPromotedRegionSaysSoAfterItsName() {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                    promotedItemID: "res-fog"))
        XCTAssertEqual(CanvasAccessibility.elements(scene: s, scraps: [:]).first?.label,
                       "Region, Act II fog, promoted")
    }
```

- [ ] **Step 2: Run them and watch them fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionRenderTests -only-testing MaughamTests/CanvasAccessibilityTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — the render diffs measure 0 and the labels lack "promoted".

- [ ] **Step 3: Add the material constants**

In `CanvasMaterial.swift`, beside `connectMarkDiameter` (with the same comment density as its neighbours):

```swift
    /// The stripe down the left edge of a card that has produced a durable
    /// artifact (spec §6).
    ///
    /// **A stripe rather than a corner dot**, because the other three positions
    /// are spoken for and the fourth is not free: the resize triangle owns the
    /// bottom-right, the connect dot owns the right edge vertically centred, and
    /// the text box starts `CanvasCardMetrics.inset` in from the top-left — so a
    /// corner mark would either land on the writer's first line or where an
    /// existing mark already means something. The left edge is outside the text
    /// inset at every card width, and it survives being zoomed out, which a few
    /// points of dot does not.
    static let promotedMarkWidth: CGFloat = 3

    /// Drawn in `cardInk`, which is already appearance-dynamic — so this is one
    /// constant rather than a light/dark pair. It is deliberately quieter than
    /// the selection stroke: a promoted card is a *fact* about the card, and a
    /// canvas where half the cards have been promoted must not read as a canvas
    /// where half the cards are selected.
    static let promotedMarkOpacity: CGFloat = 0.45
```

- [ ] **Step 4: Draw it**

In `CanvasRenderer.swift`, add beside `connectMarkRect(inCard:)`:

```swift
    /// The promoted stripe's rect, inside the card's own rounded rect. Clipped
    /// to the card by the caller, so the rounded corners cut it rather than the
    /// stripe squaring them off.
    static func promotedMarkRect(inCard frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY,
               width: CanvasMaterial.promotedMarkWidth, height: frame.height)
    }

    /// The same stripe on a region's chrome bar — the only part of a region that
    /// is reliably on screen when it is collapsed.
    static func promotedMarkRect(inRegionChrome frame: CGRect) -> CGRect {
        let chrome = CanvasRegionMetrics.chromeRect(in: frame)
        return CGRect(x: chrome.minX, y: chrome.minY,
                      width: CanvasMaterial.promotedMarkWidth, height: chrome.height)
    }
```

In `drawCard`, **outside** the `if isSelected` block and directly above the unconditional `resizeHandle` fill:

```swift
        // PERMANENT chrome, like the resize triangle below and unlike the connect
        // dot above — it states a durable fact about the card rather than a
        // passing one about the selection. An item node never gets one: it
        // already exists as itself, so a mark on one is meaningless, and a
        // hand-edited sidecar can put the field there.
        if node.promotedItemID != nil, case .scrap = node.kind {
            card.drawLayer { inner in
                inner.clip(to: shape)
                inner.fill(Path(promotedMarkRect(inCard: frame)),
                           with: .color(Color(nsColor: cardInk)
                                            .opacity(CanvasMaterial.promotedMarkOpacity)))
            }
        }
```

and the equivalent in `drawRegion`, after the chrome bar is filled and before its label is drawn:

```swift
        if region.promotedItemID != nil {
            cx.fill(Path(promotedMarkRect(inRegionChrome: region.frame)),
                    with: .color(Color(nsColor: cardInk)
                                     .opacity(CanvasMaterial.promotedMarkOpacity)))
        }
```

**Read `drawRegion` before writing that in** — this plan does not name its local variable for the context, and the region pass is where the collapsed count and the resize triangle are also inked. Match what is there.

Update `drawCard`'s existing "the two marks below sit adjacent and mean OPPOSITE things" comment to say *three*, and name which is which.

- [ ] **Step 5: Announce it**

In `CanvasAccessibility.swift`, the shared label builder gains a term:

```swift
    /// The word a promoted node or region carries in its label. A constant so
    /// the tests assert against what ships, exactly as `regionKind` is.
    static let promotedTerm = "promoted"

    /// The kind, then whether it has produced something, then what it is
    /// connected to. The kind stays FIRST because `CanvasAXRole` never reaches
    /// an assistive client — see `elements`.
    private static func label(_ kind: String,
                              promoted: Bool,
                              connectedBy lines: [CanvasLine]?) -> String {
        var parts = [kind]
        if promoted { parts.append(promotedTerm) }
        if let phrase = connectionPhrase(for: lines ?? []) { parts.append(phrase) }
        return parts.joined(separator: ", ")
    }
```

Update the three call sites: the scrap case passes `promoted: node.promotedItemID != nil`, the item case passes `promoted: false` (an item cannot be promoted), and the region label appends the term after `displayLabel` and before `collapsed`:

```swift
                label: [regionKind, region.displayLabel,
                        region.promotedItemID != nil ? promotedTerm : nil,
                        region.isCollapsed ? "collapsed" : nil]
                    .compactMap { $0 }.joined(separator: ", "),
```

- [ ] **Step 6: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionRenderTests -only-testing MaughamTests/CanvasAccessibilityTests -only-testing MaughamTests/CanvasRendererTests -only-testing MaughamTests/CanvasRegionRenderTests -only-testing MaughamTests/CanvasLineRenderTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS. The three existing raster suites are here because a new unconditional draw can move pixels they measure — **if one goes red, read what it measures before changing a number**; the mark may genuinely be in its box.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasMaterial.swift Maugham/Canvas/CanvasRenderer.swift \
        Maugham/Canvas/CanvasAccessibility.swift \
        MaughamTests/Canvas/PromotionRenderTests.swift \
        MaughamTests/Canvas/CanvasAccessibilityTests.swift
git commit -m "feat(canvas): a promoted card wears it, and says it

A stripe down the card's left edge: the other three positions are taken and
the fourth would land on the writer's first line. Permanent chrome like the
resize triangle, not selection chrome like the connect dot - it states a
durable fact about the card.

Both numbers in CanvasMaterial, ink at an opacity rather than a light/dark
pair because cardInk is already appearance-dynamic. VoiceOver hears it with
the kind still first.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeXFCPAiAdnJ2mMCdRLvH8"
```

---

### Task 8: Research bodies join the link layer

**Files:**
- Modify: `Maugham/MCP/Tools/ListAllLinksTool.swift`, `Maugham/MCP/Tools/ReferenceTools.swift`
- Test: `MaughamTests/MCP/Tools/ListAllLinksToolTests.swift` (extend), `MaughamTests/MCP/Tools/ReferenceToolsTests.swift` (extend)

**Interfaces:**
- **Consumes:** `ProjectStore.manifest.research`, `TreeWalk.collect(in:where:)`, `ListAllLinksTool.wikiTokens(in:)` (already private and already correct), `ResearchItem.kind == .document`.
- **Produces:** no new types and **no new tool** — the count stays 52, so no tools-list test moves.

**Why this is in a canvas slice, stated so it is not mistaken for scope creep.** Spec §6.1's amendment carries the measurement: `ListAllLinksTool.swift:93` and `ReferenceTools.swift:180` scan `[[…]]` in **manuscript documents only**, and promotion never produces a manuscript document — every link it can write lands in a research note. Without this task the line row ships a feature nothing in the app can see, which is this area's fifth built-and-unreachable half; the previous four were each found by counting callers rather than by a test.

**Scope discipline:** this task teaches the two link *readers* about research bodies. It does **not** add wiki-link rendering or click-to-navigate to `ResearchNoteEditor`, and it does **not** extend rename propagation (`ProjectStore+Structure.swift:400`) to rewrite links inside research notes. Both are real gaps and both are recorded in Task 9's roadmap entry — a promoted link whose target research item is later renamed goes stale, exactly as it would in any plain-text note.

**Self-edges are dropped.** A note whose body contains its own title would otherwise report a link to itself, which is noise in every consumer.

- [ ] **Step 1: Write the failing tests**

Append to `MaughamTests/MCP/Tools/ListAllLinksToolTests.swift` (a **second** helper, so the existing fixture's edge counts do not move):

```swift
    /// A project whose links live in RESEARCH notes rather than in the
    /// manuscript — which is the only shape canvas promotion can produce.
    private func makeResearchLinkedProject() async throws -> (URL, ProjectRegistry) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LALR-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("research"), withIntermediateDirectories: true)
        try "The falls at night.\n\n[[October's doctor]] — because of the ponchos\n".write(
            to: tmp.appendingPathComponent("research/falls.md"),
            atomically: true, encoding: .utf8)
        try "October's doctor was kind about it.\n\n[[Nobody]]\n".write(
            to: tmp.appendingPathComponent("research/doctor.md"),
            atomically: true, encoding: .utf8)
        let falls = ResearchItem(id: "res-falls", title: "The falls at night", type: .asset,
                                 kind: .document, path: "research/falls.md", addedAt: Date())
        let doctor = ResearchItem(id: "res-doctor", title: "October's doctor", type: .asset,
                                  kind: .document, path: "research/doctor.md", addedAt: Date())
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [], research: [falls, doctor])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: try await ProjectStore.load(from: tmp))
        return (tmp, reg)
    }

    private func edges(_ url: URL, _ reg: ProjectRegistry) async throws -> [ListAllLinksTool.Edge] {
        let req = "{\"project_id\":\"\(ProjectIdentifier.id(for: url))\"}"
        return try JSONDecoder().decode(
            [ListAllLinksTool.Edge].self,
            from: try await ListAllLinksTool.handle(paramsJSON: Data(req.utf8), registry: reg))
    }

    /// The whole reason this exists: canvas promotion writes `[[…]]` into a
    /// research note and never into a manuscript document, so a scan that only
    /// reads documents cannot see a single link it produces.
    func test_aWikiLinkInsideAResearchNoteIsAnEdge() async throws {
        let (url, reg) = try await makeResearchLinkedProject()
        XCTAssertTrue(try await edges(url, reg).contains {
            $0.from_id == "res-falls" && $0.to_id == "res-doctor" && $0.kind == "wiki"
        })
    }

    func test_anUnresolvedLinkInsideAResearchNoteIsStillReported() async throws {
        let (url, reg) = try await makeResearchLinkedProject()
        XCTAssertTrue(try await edges(url, reg).contains {
            $0.from_id == "res-doctor" && $0.to_id == nil
                && $0.to_title == "Nobody" && $0.kind == "wiki_unresolved"
        })
    }

    func test_aNoteThatNamesItselfIsNotAnEdgeToItself() async throws {
        let (url, reg) = try await makeResearchLinkedProject()
        let all = try await edges(url, reg)
        XCTAssertFalse(all.contains { $0.from_id == $0.to_id })
    }

    /// The existing fixture's research note has no links in it, so the new loop
    /// must add nothing there — a control, so "it found something" means
    /// something.
    func test_aResearchNoteWithNoLinksAddsNoEdges() async throws {
        let (url, _, reg) = try await makeProject()
        let all = try await edges(url, reg)
        XCTAssertFalse(all.contains { $0.from_id == "res-sarah" })
    }
```

Append to `MaughamTests/MCP/Tools/ReferenceToolsTests.swift` the same fixture (a `makeResearchLinkedProject` of its own — per-file helpers are the house pattern) plus:

```swift
    func test_findReferencesSeesALinkMadeFromAResearchNote() async throws {
        let (url, reg) = try await makeResearchLinkedProject()
        let req = "{\"project_id\":\"\(ProjectIdentifier.id(for: url))\","
            + "\"target\":\"October's doctor\"}"
        let refs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self,
            from: try await FindReferencesTool.handle(paramsJSON: Data(req.utf8), registry: reg))
        XCTAssertTrue(refs.contains { $0.from_id == "res-falls" && $0.kind == "wiki" },
                      "a promoted line's link is a reference, and this is the tool "
                      + "a writer asks 'what points at this'")
    }

    func test_findReferencesDoesNotReportANoteAsAReferenceToItself() async throws {
        let (url, reg) = try await makeResearchLinkedProject()
        let req = "{\"project_id\":\"\(ProjectIdentifier.id(for: url))\","
            + "\"target\":\"The falls at night\"}"
        let refs = try JSONDecoder().decode(
            [FindReferencesTool.Reference].self,
            from: try await FindReferencesTool.handle(paramsJSON: Data(req.utf8), registry: reg))
        XCTAssertFalse(refs.contains { $0.from_id == "res-falls" })
    }
```

**Check the real type names before running** — `FindReferencesTool` is the enum in `ReferenceTools.swift`; use whatever that file declares, and match how the existing tests in that suite decode a result.

- [ ] **Step 2: Run them and watch them fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ListAllLinksToolTests -only-testing MaughamTests/ReferenceToolsTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL on the four new positives; the two controls pass already, which is what makes them controls.

- [ ] **Step 3: Scan research bodies in `list_all_links`**

In `ListAllLinksTool.handle`, after the existing `for doc in docs` wiki loop:

```swift
        // Wiki edges FROM research notes. **Canvas promotion (1C-c2) writes
        // `[[…]]` into a research note and never into a manuscript document**,
        // so without this loop every link it produces is invisible here — the
        // measurement is in spec §6.1's 2026-07-28 amendment.
        //
        // Read directly rather than through the op log: a research note is not
        // manuscript. It has no op log and no second representation to drift
        // from, which is exactly what ADR 0018 exists to prevent.
        for item in allResearch where item.kind == .document {
            guard let path = item.path,
                  let text = try? String(
                      contentsOf: entry.url.appendingPathComponent(path),
                      encoding: .utf8),  // adr-0018-ok: research note, not manuscript
                  !text.isEmpty else { continue }
            for token in Self.wikiTokens(in: text) {
                let hit = titleIndex[token.lowercased()]
                // A note whose body contains its own title is not a link to
                // itself; that is noise in every consumer.
                if let hit, hit.id == item.id { continue }
                edges.append(Edge(
                    from_id: item.id,
                    from_title: item.title,
                    to_id: hit?.id,
                    to_title: hit?.title ?? token,
                    kind: hit == nil ? "wiki_unresolved" : "wiki"))
            }
        }
```

- [ ] **Step 4: Scan research bodies in `find_references`**

In the wiki-reference section, after the existing `for doc in …` loop:

```swift
            // The same widening `list_all_links` takes, and for the same
            // reason: a promoted line's link lives in a research note, and this
            // is the tool a writer asks "what points at this".
            for item in TreeWalk.collect(in: store.manifest.research,
                                         where: { $0.kind == .document }) {
                guard item.id != resolvedId,          // not a reference to itself
                      let path = item.path,
                      let text = try? String(
                          contentsOf: entry.url.appendingPathComponent(path),
                          encoding: .utf8),  // adr-0018-ok: research note, not manuscript
                      !text.isEmpty else { continue }
                for title in titles where text.contains("[[\(title)]]") {
                    if seenFromIds.insert(item.id).inserted {
                        refs.append(Reference(from_id: item.id, from_title: item.title,
                                              kind: "wiki"))
                    }
                    break
                }
            }
```

- [ ] **Step 5: Fix every description that has just become false**

Both tools' `description` strings are Claude-facing and are part of what ships. Run:

```bash
grep -rn "wiki" Maugham/MCP/Tools/ListAllLinksTool.swift Maugham/MCP/Tools/ReferenceTools.swift Maugham/MCP/AREA.md | grep -i "document\|manuscript\|not scan"
```

and rewrite any clause that says or implies documents-only. At minimum `ListAllLinksTool.description` (`:12-15`) should name research notes as sources. **`grep -rn "52" Maugham/MCP/AREA.md` is not needed here** — this task adds no tool, so no count moves and no tools-list test changes.

- [ ] **Step 6: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/ListAllLinksToolTests -only-testing MaughamTests/ReferenceToolsTests -only-testing MaughamTests/DocSyncTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS. `DocSyncTests` is here because it checks documentation against the tool catalogue.

- [ ] **Step 7: Commit**

```bash
git add Maugham/MCP/Tools/ListAllLinksTool.swift Maugham/MCP/Tools/ReferenceTools.swift \
        Maugham/MCP/AREA.md \
        MaughamTests/MCP/Tools/ListAllLinksToolTests.swift \
        MaughamTests/MCP/Tools/ReferenceToolsTests.swift
git commit -m "feat(mcp): the link layer reads research notes, not only the manuscript

Measured, not assumed: both link readers scanned [[...]] in manuscript
documents ONLY, and promotion never produces a manuscript document - so every
link the canvas can write was invisible to both. The title index already
covered research items; only the source side was narrow.

No new tool, so the count stays 52. Self-edges dropped. Still out of scope
and recorded in the roadmap: rendering wiki-links inside the research note
editor, and rename propagation into research bodies.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeXFCPAiAdnJ2mMCdRLvH8"
```

---

### Task 9: The record — ADR, AREA, CLAUDE.md, roadmap, guide

**Files:**
- Modify: `docs/adr/0026-planning-canvas-rendering.md`, `Maugham/Canvas/AREA.md`, `CLAUDE.md`, `docs/roadmap.md`, `docs/guide/getting-started.md`, `docs/guide/right-pane.md`

**Interfaces:** none — this task ships no code. It is a task rather than a step in another because CLAUDE.md rule 10 makes the sweep a deliverable a reviewer can reject on its own, and because 1C-c1's docs sweep is where two of its sharpest findings were made.

**Help and docs describe what *ships*, not what is planned** (CLAUDE.md rule 7).

- [ ] **Step 1: ADR 0026 gains decision 9**

Add after §8, in the ADR's voice (present tense, the decision then the evidence):

- **The decision:** promotion is one explicit verb producing a snapshot; the mark is provenance and never syncs; re-promoting offers Update or New with neither defaulted; the gesture is a menu command on the current selection (⌘⇧↩) plus a button in each inspector arm, all posting one command.
- **Why the snapshot, in one move:** the region row forces it — promoting a region joins six cards' text while all six stay on the canvas — so a scrap that moved its words out would give one verb two rules and would pull 1C-d's item rendering forward.
- **What ⌘Z takes back:** the mark, not the artifact. Canvas undo is scene-scoped (decision 5); the note is a real file with the research tree's own lifecycle.
- **The line row and its reader**, quoting spec §6.1 and naming the two files and lines that were measured. **Do not write "deviation" anywhere.**
- Add to **Consequences**: tripwire 32's census is now three entries; the promoted link is not rename-propagated and is not rendered as a link in the research note editor (both recorded, neither fixed); and update the "Left to later slices" bullet — promotion is no longer on it.

- [ ] **Step 2: `Maugham/Canvas/AREA.md` gains a Promotion section**

Placed after "Lines" and before "Who owns what", covering:

- The snapshot rule and the one-sentence reason (the region row).
- **The pure/impure line**: `Promotion` never mutates; `PromotionPerformer` is `@MainActor async throws` with no `inout`, because an `inout CanvasScene` cannot cross an `await`.
- **Tripwire 32's third entry**, and the fact that `beginPromotion` can run with "Edit Scrap" open.
- **The artifact index**, and why a mark cannot be validated at the disk boundary.
- **`.keyWindow` posts from a button are safe from the inspector column and are NOT safe from inside a sheet** — the v0.24.0 bug, named, so nobody moves a `Promote…` button into a modal and quietly breaks it.
- The promoted mark is **permanent** chrome, unlike the connect dot — three marks now, and the adjacency warning in `drawCard` covers all three.
- Update the **two-counters table**: a promotion bumps `sceneRevision` (it is a structural change made from the other column).
- Update **"What the canvas does not do yet"**: strike 1C-c2, record what it built, and keep the two gaps it did not close (rename propagation into research bodies; wiki-links unrendered in the research note editor).

- [ ] **Step 3: `CLAUDE.md`**

- The `Maugham/Canvas/` row gains promotion in one clause, and names `⌘⇧↩`.
- Tripwire 32's row: "the census now expects three entries" — name `PromotionPerformer.swift`.
- The `Maugham/MCP/` row: the link tools read research bodies (tool count unchanged at 52).

- [ ] **Step 4: `docs/roadmap.md`**

Flip **1C-c2** from `•` to `✓` with the milestone's own paragraph in the house voice, and — following 1C-c1's precedent — record what is left open *on the record*: the promoted `[[…]]` is not rename-propagated and not rendered as a link in the research note editor; and a promoted card and its note can drift, which is the design and not a defect.

- [ ] **Step 5: The guide**

`docs/guide/getting-started.md`:
- **Replace line 69's promise** — *"Dragging research onto the canvas, and turning a scrap into a real chapter or note, are still to come"* — with the truth: dragging research in is still to come; promotion ships.
- Add a **"Promoting"** subsection after "Lines" covering: what each thing can become; ⌘⇧↩ and the Inspector button; that the sheet previews before anything is written; that promoting takes a **copy** and the card keeps its words; that promoting again asks whether to rewrite or make a new one; that a line needs both cards promoted first, and *why* (wiki-links are the durable layer, canvas lines are scratch — spec §5 requires this precedence be stated in the UI, once, plainly); and **what ⌘Z does**: takes back the mark, not the note.

`docs/guide/right-pane.md:20` is **stale as of 1C-c1** — it still says the canvas Inspector shows "the selected **region**" only, with no mention of the line inspector that shipped on 2026-07-28. Rewrite it for all three arms.

- [ ] **Step 6: Verify the docs against what ships**

```bash
grep -rn "still to come\|coming soon" docs/guide/getting-started.md
xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/DocSyncTests -only-testing MaughamTests/HelpTopicIndexTests CODE_SIGNING_ALLOWED=NO
```

Expected: no false promise left about promotion; both suites green. **Check the actual test class names in `MaughamTests/` before running** — if `HelpTopicIndexTests` is spelled differently, run the suite that owns `docs/guide/`.

- [ ] **Step 7: Commit**

```bash
git add docs/adr/0026-planning-canvas-rendering.md Maugham/Canvas/AREA.md CLAUDE.md \
        docs/roadmap.md docs/guide/getting-started.md docs/guide/right-pane.md
git commit -m "docs: promotion, and what it does not promise

ADR 0026 decision 9 closes spec 10's promotion-gesture question. The record
keeps three things that will otherwise be rediscovered: a promotion is a
snapshot and cmd-Z takes back the mark rather than the note, a keyWindow post
from inside a sheet is dropped, and the promoted link is neither
rename-propagated nor rendered in the research note editor.

Also fixes right-pane.md, which has described the canvas inspector as
region-only since 1C-c1 shipped the line arm.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DeXFCPAiAdnJ2mMCdRLvH8"
```

---

## Whole-slice verification

Run **after every task**, before the whole-branch review. Foreground, one at a time.

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
  -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build \
  CODE_SIGNING_ALLOWED=NO
```

The phone suite is not decoration: `Packages/MaughamCore` and `MaughamPhone` are untouched by this slice, and running it is how that claim stops being an assumption. The Release build is required because `ProjectWindow.body` changed (one `.modifier` line) and the Release type-check budget is stricter than Debug.

**Then the caller census, which is what has found every unreachable half in this area — four times, never once by a test:**

```bash
grep -rn "setPromotedItem\|promotedItemID" Maugham/ --include=*.swift | grep -v Tests
grep -rn "PromotionPerformer\|PromotionSheetModel\|ScrapInspector\|ArtifactIndex" Maugham/ --include=*.swift
grep -rn "maughamPromoteCanvasSelection" Maugham/ --include=*.swift
```

Every symbol this slice adds must have a production caller that a writer can reach with a mouse or a key. **A function with none is either wired up or deleted** — `CanvasScene.lines(touching:)` was deleted in 1C-c1 for exactly this, and deletion is a legitimate answer.

**Then the whole-branch review** (CLAUDE.md rule 9). It earns its keep every time: 1C-c1's found that `LineInspector` had no Delete button while `RegionInspector`, in the same pane and the same slice, did — invisible to seven per-task reviewers because each saw one inspector. The equivalent question here: **do all three inspector arms offer the same acts for the same reasons, and does every path that can produce an artifact go through one performer?**

Reviewer subagents on this harness go idle without reporting. Send a message asking for the verdict; budget one extra round-trip per review.

---

## The smoke list

Denver runs these by hand. Everything before this point is a green suite, which is not the same thing.

1. Plan persona (⌘1), double-click bare canvas, type a sentence. Select the card — **the Inspector now shows a card arm** saying it is not promoted.
2. ⌘⇧↩ → the sheet opens naming the card. Nothing is selected in it, and **Promote is disabled** until a target is chosen.
3. Choose **Research note** → the preview names the title, the body and `research/`. Edit the title. Promote.
4. The card gains a **stripe down its left edge**; the Inspector says what it became; **Open** takes you to the note, which contains the words.
   — **Calibration:** is the stripe too loud, too quiet, the wrong width? It is two numbers in `CanvasMaterial` (`promotedMarkWidth`, `promotedMarkOpacity`). Check it in **both appearances**.
5. Edit the card. ⌘⇧↩ again → the sheet says it became "…" and offers **Rewrite** or **Make a new one**, with New selected. Try both, on two different cards.
6. ⌘Z after a promotion → the **stripe goes and the note stays**. This is the design; the guide says so. Does it read as broken?
7. Promote a second card. Draw a line between the two. Select the line, ⌘⇧↩ → **Wiki-link** is offered; the preview shows the exact text. Promote, and read the first note: the link is at the bottom, with the line's name after an em dash if it had one.
8. Select an *unpromoted* card's line → the sheet **refuses and teaches the rule** rather than showing an empty list.
9. Promote the same line twice → the second time says the link is already there and will not commit.
10. Draw a region around both cards, name it, ⌘⇧↩ → **Palette card** joins their text **top card first**; the discard notice names the lines and the layout; the link offer is **unchecked**. Accept it once and check the members' notes.
11. Region → **Piece binding** — the Picker in the region inspector and this route agree, and the Edit menu says "Undo Bind Region" either way.
12. **Promote while typing in a scrap** (the tripwire-32 repro): double-click a region's *chrome bar* so a scrap is minted and "Edit Scrap" is open, then promote from the Inspector button. The Edit menu must read **"Undo Promote Scrap"** — not "Undo Edit Scrap".
13. Delete the note in the research tree, then select the card again → the Inspector says **what it produced is no longer in the project**, and the line that pointed at it stops offering a wiki-link.
14. Ask Claude `find_references` for a promoted note's title → the promoting note is listed. This is the reader Task 8 built; if it is empty, the line row is inert again.
15. Quit mid-sheet (⌘Q with the sheet open) and reopen → no crash, nothing half-written, the canvas as it was.
16. **The menu item is disabled** outside the canvas segment and with nothing selected, and enabled with a card, a region or a line selected.

---

## After 1C-c2

Build it, then **re-derive 1C-c3 against *that*** — the MCP canvas surface (spec §8A.2), which this slice changes the ground under exactly as 1C-c1 changed it under this one. Two things 1C-c3 inherits and should not rediscover:

- **`CanvasRenderer.lineLabelBox` trims `.whitespaces`** where everything else trims `.whitespacesAndNewlines`, so a `"\n"` label draws an empty pill. 1C-c3 is the first slice that could write a label without passing `LineInspector.normalise`, since the codec does not normalise on load. It normalises at its own boundary or widens the renderer first.
- **`CanvasInteraction.regionHit` is still the projection to lift onto `CanvasScene`.** Until it moves, `CanvasScene` cannot go to MaughamCore.

Then **1C-d**. Then **1A**, the spine — which forces a paired Mac + phone release, because adding an `OpKind` bumps the manifest schema and an older phone build refuses to open the project at all.

**M1 is complete only when 1A, 1B and the whole of 1C are in. Do not push or tag before then.** Slicing the implementation is fine; slicing the release is not.
