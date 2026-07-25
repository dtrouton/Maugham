# Planning canvas 1C-c — lines and promotion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add untyped lines with optional labels, and **promotion** — the single explicit seam by which canvas scratch becomes a durable artifact.

**Architecture:** Lines are freeform, untyped, optionally labelled, stored in the sidecar, and assert nothing. Promotion is one verb with a preview: the writer sees exactly what will be produced and where, before committing. Nothing promotes because it sat somewhere long enough or looked like something.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, XCTest. Builds on 1C-a and 1C-b.

## Global Constraints

Everything in 1C-a's and 1C-b's Global Constraints still applies. In addition:

- **The governing rule of the whole milestone** (spec §1): *nothing on the canvas becomes durable except by an explicit act the writer performs and can predict the outcome of.*
- **No typed edge vocabulary in v1** (spec §5, §9). Kinopio built exactly that, shipped it for years, and removed it in April 2026 for costing more than it returned.
- **No automatic linking** (spec §6.1, §9). Promotion may *suggest* and must never impose.
- **Promotion is never required.** The canvas must be completely usable by a writer who never promotes anything. Readiness counts promoted artifacts and stays silent about the canvas (spec §6.1, umbrella §7 and §9).
- **Promotion is allowed to be lossy, and that is a feature** (spec §6.1). Promoting a region need not preserve its lines or its layout.
- **Precedence must be stated in the UI, once, plainly** (spec §5): wiki-links are durable, canvas lines are scratch.
- Run `./gen.sh` after adding files; `xcodebuild` in the **foreground**; Release build for anything touching views.

## Why untyped, and why previewed

Both constraints are empirical, not aesthetic:

- **Untyped edges.** Kinopio deleted author-typed connections in April 2026 after years in production, because "connection types were confusing for people I observed using the tool for the first time." Untyped edges with an optional free-text label is the empirically supported floor.
- **Previewed promotion.** Scrivener's freeform corkboard is the cleanest precedent in writing software: cards move in 2D without touching the binder, then an explicit **Commit** reorders it by a stated rule. Named, predictable, previewable, single-purpose. Match that shape.
- **Suggest, never impose.** Shipman & Marshall's licence for machine inference is conditional: inference is safe **iff the writer sees it and can reject it cheaply.** The same inference applied silently is forbidden — membership is n-ary and vague, wiki-links are binary and specific, and a silent conversion manufactures precision the writer never claimed, into a layer with backlinks and rename propagation where it is expensive to undo.

## File Structure

| File | Responsibility |
|---|---|
| `Maugham/Canvas/CanvasLine.swift` | `CanvasLine` — two endpoints, an optional label. No type. |
| `Maugham/Canvas/CanvasScene.swift` | *Modify* — lines join the scene |
| `Maugham/Canvas/CanvasSceneCodec.swift` | *Modify* — schema 2 → 3 |
| `Maugham/Canvas/CanvasRenderer.swift` | *Modify* — draw lines and their labels |
| `Maugham/Canvas/Promotion.swift` | The promotion verb: what each source can produce, and the preview |
| `Maugham/Canvas/PromotionSheet.swift` | The preview UI — what will be produced, and where |
| `Maugham/Canvas/PromotionPerformer.swift` | Executes an approved promotion against the project stores |

---

### Task 1: Lines

**Files:**
- Create: `Maugham/Canvas/CanvasLine.swift`
- Modify: `Maugham/Canvas/CanvasScene.swift`
- Test: `MaughamTests/Canvas/CanvasLineTests.swift`

**Interfaces:**
- Consumes: `CanvasNodeID`, `CanvasScene`.
- Produces: `CanvasLineID`, `CanvasLine` (`id`, `from: CanvasNodeID`, `to: CanvasNodeID`, `label: String?`), and `CanvasScene.lines`, `insertLine(_:)`, `removeLine(_:)`, `updateLine(_:_:)`, `lines(touching:)`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasLineTests: XCTestCase {

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for id in ["a", "b", "c"] {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap, origin: .zero, width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        return s
    }

    func test_aLineCarriesNoTypeOnlyAnOptionalLabel() {
        let l = CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b"))
        XCTAssertNil(l.label)
        // The absence of a `kind`/`type` property is the point (spec §5, §9).
        // Kinopio shipped typed connections for years and removed them in
        // April 2026. If this assertion ever needs changing, re-read §5 first.
        XCTAssertEqual(Mirror(reflecting: l).children.compactMap(\.label).sorted(),
                       ["from", "id", "label", "to"])
    }

    func test_linesTouchingFindsBothDirections() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        s.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("c"), to: CanvasNodeID("a")))
        XCTAssertEqual(Set(s.lines(touching: CanvasNodeID("a")).map(\.id)),
                       [CanvasLineID("l1"), CanvasLineID("l2")])
    }

    func test_deletingANodeDeletesItsLines() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        s.remove(CanvasNodeID("a"))
        XCTAssertTrue(s.lines.isEmpty, "a line to a node that is gone would draw into nowhere")
    }

    func test_aSelfLineIsRejected() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("a")))
        XCTAssertTrue(s.lines.isEmpty)
    }

    func test_duplicateLinesBetweenTheSamePairAreAllowed() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        s.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b"), label: "but only at night"))
        XCTAssertEqual(s.lines.count, 2,
                       "a line costs nothing to draw and nothing to be wrong about — "
                       + "two differently-labelled thoughts about one pair are legitimate")
    }

    func test_labelCanBeSetAndCleared() {
        var s = scene()
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        s.updateLine(CanvasLineID("l1")) { $0.label = "because of the ponchos" }
        XCTAssertEqual(s.lines.first?.label, "because of the ponchos")
        s.updateLine(CanvasLineID("l1")) { $0.label = nil }
        XCTAssertNil(s.lines.first?.label)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLineTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasLine' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public struct CanvasLineID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// A freeform line between two nodes.
///
/// **Untyped, deliberately.** There is no `kind` here and there must not be one
/// (spec §5, §9). Kinopio built author-typed connections, shipped them for
/// years, and removed them in April 2026 because "connection types were
/// confusing for people I observed using the tool for the first time." Untyped
/// edges with an optional free-text label is the empirically supported floor.
///
/// A line carries no semantics and asserts nothing. It costs nothing to draw and
/// nothing to be wrong about, which is what thinking needs. `[[wiki-links]]`
/// remain the durable relationship layer, reached deliberately through
/// promotion — and that precedence is stated in the UI, once, plainly, because
/// Obsidian's three-year confusion is entirely a consequence of never answering
/// "which of these is the real relationship?"
public struct CanvasLine: Equatable, Sendable {
    public let id: CanvasLineID
    public var from: CanvasNodeID
    public var to: CanvasNodeID
    /// Optional free text. Not a type, not a vocabulary, not validated.
    public var label: String?

    public init(id: CanvasLineID, from: CanvasNodeID, to: CanvasNodeID, label: String? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
    }

    public func touches(_ node: CanvasNodeID) -> Bool { from == node || to == node }
}
```

Add to `CanvasScene`:

```swift
    private var linesByID: [CanvasLineID: CanvasLine] = [:]

    public var lines: [CanvasLine] { linesByID.values.sorted { $0.id.raw < $1.id.raw } }

    public mutating func insertLine(_ line: CanvasLine) {
        // A line from a node to itself has nothing to say and draws as a blob.
        guard line.from != line.to else { return }
        linesByID[line.id] = line
    }

    public mutating func removeLine(_ id: CanvasLineID) { linesByID[id] = nil }

    public mutating func updateLine(_ id: CanvasLineID, _ mutate: (inout CanvasLine) -> Void) {
        guard var l = linesByID[id] else { return }
        mutate(&l)
        linesByID[id] = l
    }

    public func lines(touching node: CanvasNodeID) -> [CanvasLine] {
        lines.filter { $0.touches(node) }
    }
```

and extend `remove(_ id: CanvasNodeID)` — it already clears memberships from 1C-b; add:

```swift
        // A line to a node that is gone would draw into nowhere.
        for lineID in linesByID.keys where linesByID[lineID]?.touches(id) == true {
            linesByID[lineID] = nil
        }
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLineTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasLine.swift Maugham/Canvas/CanvasScene.swift MaughamTests/Canvas/CanvasLineTests.swift project.yml
git commit -m "feat(canvas): untyped lines with optional labels"
```

---

### Task 2: Persist and draw lines — schema 2 → 3

**Files:**
- Modify: `Maugham/Canvas/CanvasSceneCodec.swift`
- Modify: `Maugham/Canvas/CanvasRenderer.swift`
- Test: `MaughamTests/Canvas/CanvasLinePersistenceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasLinePersistenceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-lines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func sceneWithALine() -> CanvasScene {
        var s = CanvasScene()
        for id in ["a", "b"] {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                               origin: CGPoint(x: id == "a" ? 0 : 400, y: 0), width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b"), label: "because of the ponchos"))
        return s
    }

    func test_linesRoundTripThroughDisk() {
        CanvasStore(projectRoot: root).save(scene: sceneWithALine(), scraps: [:])
        let loaded = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(loaded.lines.count, 1)
        XCTAssertEqual(loaded.lines.first?.label, "because of the ponchos")
        XCTAssertEqual(loaded.lines.first?.from, CanvasNodeID("a"))
    }

    func test_aSchemaV2SidecarLoadsWithNoLines() throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"schemaVersion":2,"nodes":[],"regions":[]}"#
            .write(to: dir.appendingPathComponent("canvas.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(CanvasStore(projectRoot: root).load().scene.lines.isEmpty)
    }

    func test_aLineNamingAMissingNodeIsDropped() throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"schemaVersion":3,"nodes":[],"regions":[],"lines":[{"id":"l1","from":"ghost","to":"also"}]}"#
            .write(to: dir.appendingPathComponent("canvas.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(CanvasStore(projectRoot: root).load().scene.lines.isEmpty)
    }

    func test_lineEndpointsResolveToNodeCentres() {
        let s = sceneWithALine()
        let geometry = CanvasRenderer.lineGeometry(in: s)
        XCTAssertEqual(geometry.count, 1)
        XCTAssertEqual(geometry.first?.from, CGPoint(x: 120, y: 40))
        XCTAssertEqual(geometry.first?.to, CGPoint(x: 520, y: 40))
    }

    func test_linesToUnmeasuredNodesAreNotDrawn() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240))
        s.insert(CanvasNode(id: CanvasNodeID("b"), kind: .scrap, origin: .zero, width: 240))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        XCTAssertTrue(CanvasRenderer.lineGeometry(in: s).isEmpty)
    }

    func test_linesDrawBeneathNodesAndAboveRegions() {
        XCTAssertLessThan(CanvasRenderer.regionLayerDepth, CanvasRenderer.lineLayerDepth)
        XCTAssertLessThan(CanvasRenderer.lineLayerDepth, CanvasRenderer.nodeLayerDepth)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLinePersistenceTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — no `lines` on the DTO.

- [ ] **Step 3: Extend the codec and the renderer**

Codec: bump `currentSchemaVersion` to 3, add `var lines: [LineDTO]?` with `id`/`from`/`to`/`label`, and in the `scene` builder drop any line whose endpoints are not both present — the same validation regions already do for memberships.

Renderer:

```swift
    static let lineLayerDepth = 1
    static let nodeLayerDepth = 2   // was 1; regions stay 0

    struct LineGeometry: Equatable {
        let id: CanvasLineID
        let from: CGPoint
        let to: CGPoint
        let label: String?
    }

    /// Endpoints resolve to node centres. Nodes that have never been measured
    /// have no frame, so their lines are not drawn — drawing to a guessed
    /// position would twitch as soon as the real measurement arrived.
    static func lineGeometry(in scene: CanvasScene) -> [LineGeometry] {
        scene.lines.compactMap { line in
            guard let a = scene.node(line.from)?.frame,
                  let b = scene.node(line.to)?.frame else { return nil }
            return LineGeometry(id: line.id,
                                from: CGPoint(x: a.midX, y: a.midY),
                                to: CGPoint(x: b.midX, y: b.midY),
                                label: line.label)
        }
    }
```

Draw lines between regions and nodes: a 1.5pt stroke at 45% opacity, label centred on the line in a small pill so it stays legible over the ground.

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasLinePersistenceTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 6 tests. Re-run `CanvasRegionRenderTests` — the layer-depth constants moved.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas MaughamTests/Canvas/CanvasLinePersistenceTests.swift
git commit -m "feat(canvas): persist lines (schema 2→3) and draw them beneath nodes"
```

---

### Task 3: The promotion model

**Files:**
- Create: `Maugham/Canvas/Promotion.swift`
- Test: `MaughamTests/Canvas/PromotionTests.swift`

**Interfaces:**
- Consumes: `CanvasScene`, `CanvasNode`, `CanvasRegion`, `CanvasLine`.
- Produces: `enum PromotionSource`, `enum PromotionTarget`, `enum PromotionDiscard`, `struct PromotionLinkOffer`, `struct PromotionPlan`, `enum Promotion` with `static func targets(for source: PromotionSource, in scene: CanvasScene) -> [PromotionTarget]` and `static func plan(source: PromotionSource, target: PromotionTarget, scraps: [CanvasNodeID: String], in scene: inout CanvasScene) -> PromotionPlan?`.

Spec §6's table is the whole contract:

| Promote | Produces |
|---|---|
| A scrap | a research note, a palette card, or an intent statement |
| A region | a palette card, or a piece binding |
| A line | a `[[wiki-link]]`, when both ends are text |

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class PromotionTests: XCTestCase {

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        var a = CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240)
        a.cachedHeight = 80
        s.insert(a)
        var b = CanvasNode(id: CanvasNodeID("b"), kind: .scrap,
                           origin: CGPoint(x: 400, y: 0), width: 240)
        b.cachedHeight = 80
        s.insert(b)
        var img = CanvasNode(id: CanvasNodeID.item("img-1"), kind: .item(referenceId: "img-1"),
                             origin: CGPoint(x: 800, y: 0), width: 180)
        img.cachedHeight = 120
        s.insert(img)
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [CanvasNodeID("a"), CanvasNodeID("b")]))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        s.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("a"),
                                to: CanvasNodeID.item("img-1")))
        return s
    }

    // ── the §6 table, exactly

    func test_aScrapCanBecomeANoteAPaletteCardOrAnIntent() {
        let targets = Promotion.targets(for: .scrap(CanvasNodeID("a")), in: scene())
        XCTAssertEqual(Set(targets), [.researchNote, .paletteCard, .intentStatement])
    }

    func test_aRegionCanBecomeAPaletteCardOrAPieceBinding() {
        let targets = Promotion.targets(for: .region(CanvasRegionID("r1")), in: scene())
        XCTAssertEqual(Set(targets), [.paletteCard, .pieceBinding])
    }

    func test_aLineBetweenTwoScrapsCanBecomeAWikiLink() {
        XCTAssertEqual(Promotion.targets(for: .line(CanvasLineID("l1")), in: scene()),
                       [.wikiLink])
    }

    /// §6: a line promotes "when both ends are text". An image end is not text.
    func test_aLineTouchingANonTextNodeOffersNothing() {
        XCTAssertTrue(Promotion.targets(for: .line(CanvasLineID("l2")), in: scene()).isEmpty)
    }

    func test_anItemNodeOffersNothing() {
        XCTAssertTrue(Promotion.targets(for: .scrap(CanvasNodeID.item("img-1")), in: scene()).isEmpty,
                      "an item already exists — promoting it would duplicate it")
    }

    // ── the plan is a PREVIEW: what will be produced, and where

    func test_planNamesWhatWillBeProducedAndWhere() {
        var s = scene()
        let plan = Promotion.plan(source: .scrap(CanvasNodeID("a")),
                                  target: .researchNote,
                                  scraps: [CanvasNodeID("a"): "The falls at night.\n\nSodium light."],
                                  in: &s)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.producedKind, .researchNote)
        XCTAssertEqual(plan?.body, "The falls at night.\n\nSodium light.")
        XCTAssertFalse(plan!.destinationDescription.isEmpty,
                       "the writer must see WHERE before committing (§6.1)")
    }

    func test_aNoteTitleComesFromTheFirstLine() {
        var s = scene()
        let plan = Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .researchNote,
                                  scraps: [CanvasNodeID("a"): "The falls at night.\n\nSodium light."],
                                  in: &s)
        XCTAssertEqual(plan?.title, "The falls at night.")
    }

    func test_anEmptyScrapProducesNoPlan() {
        var s = scene()
        XCTAssertNil(Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .researchNote,
                                    scraps: [CanvasNodeID("a"): "   \n  "], in: &s))
    }

    /// §6.1: promoting a region MAY OFFER to link its text members, and the
    /// offer must be declinable. It is an offer in the plan, never an action.
    func test_regionPromotionOffersLinkingWithoutPerformingIt() {
        var s = scene()
        let plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                                  scraps: [CanvasNodeID("a"): "one", CanvasNodeID("b"): "two"],
                                  in: &s)
        XCTAssertEqual(plan?.offeredLinks.count, 2)
        XCTAssertFalse(plan!.linksAccepted,
                       "the offer must default to DECLINED — a silent conversion "
                       + "manufactures precision the writer never claimed (§6.1)")
    }

    /// §6.1: promotion is allowed to be lossy, and that is a feature.
    func test_regionPromotionDiscardsLinesAndLayoutAndSaysSo() {
        var s = scene()
        let plan = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                                  scraps: [CanvasNodeID("a"): "one", CanvasNodeID("b"): "two"],
                                  in: &s)
        XCTAssertTrue(plan!.discards.contains(.lines))
        XCTAssertTrue(plan!.discards.contains(.layout))
    }

    /// §6.1: nothing promotes because it sat somewhere long enough or looked
    /// like something. Planning must never mutate.
    func test_planningNeverMutatesTheScene() {
        var s = scene()
        let before = s
        _ = Promotion.plan(source: .scrap(CanvasNodeID("a")), target: .researchNote,
                           scraps: [CanvasNodeID("a"): "text"], in: &s)
        _ = Promotion.plan(source: .region(CanvasRegionID("r1")), target: .paletteCard,
                           scraps: [CanvasNodeID("a"): "text"], in: &s)
        XCTAssertEqual(s, before)
    }

    func test_wikiLinkPlanNamesBothEnds() {
        var s = scene()
        let plan = Promotion.plan(source: .line(CanvasLineID("l1")), target: .wikiLink,
                                  scraps: [CanvasNodeID("a"): "The falls",
                                           CanvasNodeID("b"): "October's doctor"], in: &s)
        XCTAssertEqual(plan?.title, "The falls")
        XCTAssertTrue(plan!.body.contains("[[October's doctor]]"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'Promotion' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// What is being promoted.
enum PromotionSource: Equatable {
    case scrap(CanvasNodeID)
    case region(CanvasRegionID)
    case line(CanvasLineID)
}

/// What it becomes. This list IS spec §6's table and must not grow without
/// amending the spec — every entry here is a new durable artifact the writer
/// can accidentally create.
enum PromotionTarget: Equatable, Hashable {
    case researchNote
    case paletteCard
    case intentStatement
    case pieceBinding
    case wikiLink
}

/// What promoting will throw away. Promotion is ALLOWED to be lossy and that is
/// a feature (spec §6.1) — the spatial work was thinking; it earned its keep by
/// producing the artifact. Scapple → Scrivener keeps nodes and drops
/// connections, deliberately. The writer is told which, in the preview.
enum PromotionDiscard: Equatable, Hashable {
    case lines
    case layout
}

/// An offer to link a scrap to the artifact being produced. An OFFER — see
/// `PromotionPlan.linksAccepted`.
struct PromotionLinkOffer: Equatable {
    let node: CanvasNodeID
    let title: String
}

/// The preview. The writer sees what will be produced, and where, before
/// committing — Scrivener's Commit is the model: a named command with a stated
/// rule and a predictable outcome (spec §6.1).
///
/// Building a plan NEVER mutates anything. That is what makes the preview
/// honest.
struct PromotionPlan: Equatable {
    let source: PromotionSource
    let producedKind: PromotionTarget
    var title: String
    var body: String
    /// Human-readable, shown verbatim in the sheet: "research/notes/…".
    let destinationDescription: String
    let discards: Set<PromotionDiscard>

    /// §6.1's "may suggest, must never impose". Promoting a region may *offer*
    /// to link its text members to the artifact it produced. That sits inside
    /// Shipman & Marshall's licence for machine inference precisely BECAUSE the
    /// writer sees it and can decline it cheaply.
    let offeredLinks: [PromotionLinkOffer]

    /// Defaults to FALSE, always. The same inference applied silently is
    /// forbidden: membership is n-ary and vague, wiki-links are binary and
    /// specific, and the silent conversion manufactures precision the writer
    /// never claimed — into a layer with backlinks and rename propagation,
    /// where it is expensive to undo.
    var linksAccepted: Bool = false
}

enum Promotion {

    /// Spec §6's table, executable.
    static func targets(for source: PromotionSource, in scene: CanvasScene) -> [PromotionTarget] {
        switch source {
        case .scrap(let id):
            // Only scraps promote. An item already exists as itself; promoting
            // it would duplicate it, and duplication is what §4.3 rejects.
            guard case .scrap = scene.node(id)?.kind else { return [] }
            return [.researchNote, .paletteCard, .intentStatement]

        case .region(let id):
            guard scene.region(id) != nil else { return [] }
            return [.paletteCard, .pieceBinding]

        case .line(let id):
            guard let line = scene.lines.first(where: { $0.id == id }),
                  isText(line.from, in: scene), isText(line.to, in: scene) else { return [] }
            // §6: a line becomes a wiki-link WHEN BOTH ENDS ARE TEXT.
            return [.wikiLink]
        }
    }

    private static func isText(_ id: CanvasNodeID, in scene: CanvasScene) -> Bool {
        if case .scrap = scene.node(id)?.kind { return true }
        return false
    }

    private static func title(from body: String) -> String {
        body.split(separator: "\n").first.map {
            String($0).trimmingCharacters(in: .whitespaces)
        } ?? ""
    }

    /// Build the preview. `scene` is `inout` only so callers cannot accidentally
    /// hold a stale copy; this function does not write to it, and
    /// `test_planningNeverMutatesTheScene` pins that.
    static func plan(source: PromotionSource,
                     target: PromotionTarget,
                     scraps: [CanvasNodeID: String],
                     in scene: inout CanvasScene) -> PromotionPlan? {
        guard targets(for: source, in: scene).contains(target) else { return nil }

        switch source {
        case .scrap(let id):
            let body = (scraps[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return PromotionPlan(
                source: source, producedKind: target,
                title: title(from: body), body: body,
                destinationDescription: destination(for: target),
                discards: [], offeredLinks: [])

        case .region(let id):
            guard let region = scene.region(id) else { return nil }
            let members = region.homeMembers.sorted { $0.raw < $1.raw }
            let texts = members.compactMap { nodeID -> (CanvasNodeID, String)? in
                let t = (scraps[nodeID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : (nodeID, t)
            }
            return PromotionPlan(
                source: source, producedKind: target,
                title: region.displayLabel,
                body: texts.map(\.1).joined(separator: "\n\n"),
                destinationDescription: destination(for: target),
                // The spatial work is not carried across, and the writer is told.
                discards: [.lines, .layout],
                offeredLinks: texts.map { PromotionLinkOffer(node: $0.0, title: title(from: $0.1)) })

        case .line(let id):
            guard let line = scene.lines.first(where: { $0.id == id }) else { return nil }
            let a = title(from: scraps[line.from] ?? "")
            let b = title(from: scraps[line.to] ?? "")
            guard !a.isEmpty, !b.isEmpty else { return nil }
            let note = line.label.map { " — \($0)" } ?? ""
            return PromotionPlan(
                source: source, producedKind: target,
                title: a, body: "[[\(b)]]\(note)",
                destinationDescription: destination(for: target),
                discards: [], offeredLinks: [])
        }
    }

    private static func destination(for target: PromotionTarget) -> String {
        switch target {
        case .researchNote: return "research/"
        case .paletteCard: return "research/palette/"
        case .intentStatement: return "the project's craft intent"
        case .pieceBinding: return "this region's bound piece"
        case .wikiLink: return "the source scrap's text"
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/Promotion.swift MaughamTests/Canvas/PromotionTests.swift project.yml
git commit -m "feat(canvas): promotion model — §6's table, previews that never mutate

Link offers default to DECLINED: promotion may suggest and must never
impose (§6.1)."
```

---

### Task 4: Performing a promotion

**Files:**
- Create: `Maugham/Canvas/PromotionPerformer.swift`
- Test: `MaughamTests/Canvas/PromotionPerformerTests.swift`

**Interfaces:**
- Consumes: `PromotionPlan`, `ProjectStore`, `DocumentStore`.
- Produces: `struct PromotionPerformer` with `func perform(_ plan: PromotionPlan, in scene: inout CanvasScene) throws -> PromotionResult`.

**Tripwire 14:** any move or delete of user-editable content must go through the typed `DocumentStore` mover. Promotion *creates* rather than moves, so it does not hit that path — but it must create through `ProjectStore`'s existing research/palette creation APIs, not by writing files directly.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class PromotionPerformerTests: XCTestCase {

    // Use the project's existing test-project fixture helper rather than
    // hand-rolling a ProjectStore — see other store tests for the pattern.
    private var fixture: TestProjectFixture!

    override func setUpWithError() throws { fixture = try TestProjectFixture.make() }
    override func tearDownWithError() throws { try fixture.tearDown() }

    private func plan(_ target: PromotionTarget = .researchNote) -> PromotionPlan {
        PromotionPlan(source: .scrap(CanvasNodeID("a")), producedKind: target,
                      title: "The falls at night",
                      body: "The falls at night\n\nSodium light on the spray.",
                      destinationDescription: "research/", discards: [], offeredLinks: [])
    }

    func test_promotingAScrapCreatesARealResearchNote() throws {
        var scene = CanvasScene()
        let result = try PromotionPerformer(store: fixture.store,
                                            documentStore: fixture.documentStore)
            .perform(plan(), in: &scene)
        XCTAssertNotNil(result.createdItemID)
        let created = fixture.store.manifest.research.first { $0.title == "The falls at night" }
        XCTAssertNotNil(created, "the note must actually exist in the project")
    }

    /// §3.1 and §6: promoting does not remove the scrap. The canvas is scratch
    /// and stays scratch.
    func test_promotingAScrapLeavesItOnTheCanvas() throws {
        var scene = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240)
        n.cachedHeight = 80
        scene.insert(n)
        _ = try PromotionPerformer(store: fixture.store, documentStore: fixture.documentStore)
            .perform(plan(), in: &scene)
        XCTAssertNotNil(scene.node(CanvasNodeID("a")),
                        "promotion is a seam, not a move — the scratch stays scratch")
    }

    /// §6.1's offer, declined — the default. No links may be written.
    func test_declinedLinkOffersWriteNoLinks() throws {
        var scene = CanvasScene()
        var p = plan(.paletteCard)
        p = PromotionPlan(source: p.source, producedKind: p.producedKind, title: p.title,
                          body: p.body, destinationDescription: p.destinationDescription,
                          discards: p.discards,
                          offeredLinks: [PromotionLinkOffer(node: CanvasNodeID("a"), title: "x")],
                          linksAccepted: false)
        let result = try PromotionPerformer(store: fixture.store,
                                            documentStore: fixture.documentStore)
            .perform(p, in: &scene)
        XCTAssertTrue(result.writtenLinks.isEmpty)
    }

    func test_acceptedLinkOffersWriteExactlyTheOfferedLinks() throws {
        var scene = CanvasScene()
        var p = plan(.paletteCard)
        p = PromotionPlan(source: p.source, producedKind: p.producedKind, title: p.title,
                          body: p.body, destinationDescription: p.destinationDescription,
                          discards: p.discards,
                          offeredLinks: [PromotionLinkOffer(node: CanvasNodeID("a"), title: "x"),
                                         PromotionLinkOffer(node: CanvasNodeID("b"), title: "y")],
                          linksAccepted: true)
        let result = try PromotionPerformer(store: fixture.store,
                                            documentStore: fixture.documentStore)
            .perform(p, in: &scene)
        XCTAssertEqual(result.writtenLinks.count, 2)
    }

    func test_promotingARegionToAPieceBindingSetsTheBinding() throws {
        var scene = CanvasScene()
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let p = PromotionPlan(source: .region(CanvasRegionID("r1")), producedKind: .pieceBinding,
                              title: "Act II fog", body: "",
                              destinationDescription: "this region's bound piece",
                              discards: [], offeredLinks: [])
        _ = try PromotionPerformer(store: fixture.store, documentStore: fixture.documentStore,
                                   pieceID: "piece-3").perform(p, in: &scene)
        XCTAssertEqual(scene.region(CanvasRegionID("r1"))?.boundPieceID, "piece-3")
    }

    func test_aFailedPromotionLeavesNoHalfCreatedArtifact() throws {
        var scene = CanvasScene()
        let p = PromotionPlan(source: .scrap(CanvasNodeID("a")), producedKind: .researchNote,
                              title: "", body: "",
                              destinationDescription: "research/", discards: [], offeredLinks: [])
        XCTAssertThrowsError(
            try PromotionPerformer(store: fixture.store, documentStore: fixture.documentStore)
                .perform(p, in: &scene))
        XCTAssertTrue(fixture.store.manifest.research.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionPerformerTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'PromotionPerformer' in scope`.

Before implementing, check what the project's existing test fixture for a real `ProjectStore` is called and mirror it — several store test files already build one. Do not add a second fixture helper.

- [ ] **Step 3: Write the implementation**

`PromotionPerformer` takes the `ProjectStore` and `DocumentStore`, and for each `producedKind` calls the **existing** creation API:

- `.researchNote` → the same path the research tree's "New note" uses.
- `.paletteCard` → the existing palette-card creation path, so the card is a real palette card and appears on the wall.
- `.intentStatement` → the existing craft-intent write path.
- `.pieceBinding` → `RegionBinding.bind` (1C-b Task 6), no file I/O.
- `.wikiLink` → append the `[[link]]` to the source scrap's text via the canvas's own scrap map, not by writing a manuscript file.

Rules to encode:

```swift
    /// Promotion CREATES; it never moves or deletes user content, so tripwire 14's
    /// typed mover is not on this path. It must still create through
    /// `ProjectStore`'s existing APIs rather than writing files directly, or the
    /// manifest and the disk diverge.
    ///
    /// A promotion either fully succeeds or leaves nothing behind: the artifact
    /// is created first and the links are written second, and a failure at
    /// either step throws before the scene is touched. A half-created artifact
    /// on a surface whose whole promise is predictability would be worse than a
    /// refusal.
```

`PromotionResult` carries `createdItemID: String?` and `writtenLinks: [CanvasNodeID]`.

Validate up front — an empty title or body throws before anything is created.

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionPerformerTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 6 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/PromotionPerformer.swift MaughamTests/Canvas/PromotionPerformerTests.swift project.yml
git commit -m "feat(canvas): perform promotions through the existing store APIs, all-or-nothing"
```

---

### Task 5: The promotion sheet

**Files:**
- Create: `Maugham/Canvas/PromotionSheet.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/PromotionSheetTests.swift`

**Open question §10 resolved here:** *"The promotion gesture — drag onto an artifact rail, a context action, or a keystroke. Deliberately unresolved — it wants trying in the app rather than deciding on paper."*

**Decision: a context action plus ⌘⇧P**, for two reasons. A context menu on the node is discoverable without new chrome, which matters on a surface that is otherwise chrome-free; and a keystroke serves the writer who already knows. An artifact rail is rejected for v1 — it is permanent chrome on a surface whose whole feel is open space, and §7 spends its budget on the ground and the cards. **Flag this for the smoke**: if the context action feels buried, the rail is the fallback, and that is a UI change, not a model change.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class PromotionSheetTests: XCTestCase {

    func test_sheetOffersExactlyTheTargetsTheModelAllows() {
        var s = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240)
        n.cachedHeight = 80
        s.insert(n)
        let model = PromotionSheetModel(source: .scrap(CanvasNodeID("a")), scene: s,
                                        scraps: [CanvasNodeID("a"): "The falls"])
        XCTAssertEqual(Set(model.availableTargets), [.researchNote, .paletteCard, .intentStatement])
    }

    func test_sheetStartsWithNothingSelectedSoNothingCanBeCommittedByAccident() {
        var s = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240)
        n.cachedHeight = 80
        s.insert(n)
        let model = PromotionSheetModel(source: .scrap(CanvasNodeID("a")), scene: s,
                                        scraps: [CanvasNodeID("a"): "The falls"])
        XCTAssertNil(model.selectedTarget)
        XCTAssertFalse(model.canCommit)
    }

    func test_choosingATargetProducesAPreviewBeforeAnythingIsWritten() {
        var s = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240)
        n.cachedHeight = 80
        s.insert(n)
        let model = PromotionSheetModel(source: .scrap(CanvasNodeID("a")), scene: s,
                                        scraps: [CanvasNodeID("a"): "The falls\n\nbody"])
        model.select(.researchNote)
        XCTAssertEqual(model.preview?.title, "The falls")
        XCTAssertEqual(model.preview?.destinationDescription, "research/")
        XCTAssertTrue(model.canCommit)
    }

    func test_theWriterCanEditTheTitleBeforeCommitting() {
        var s = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240)
        n.cachedHeight = 80
        s.insert(n)
        let model = PromotionSheetModel(source: .scrap(CanvasNodeID("a")), scene: s,
                                        scraps: [CanvasNodeID("a"): "The falls\n\nbody"])
        model.select(.researchNote)
        model.editedTitle = "Niagara, 3am"
        XCTAssertEqual(model.resolvedPlan?.title, "Niagara, 3am")
    }

    /// §6.1: the link offer must be visible AND declinable, and declined by
    /// default.
    func test_linkOfferIsShownUncheckedForARegion() {
        var s = CanvasScene()
        for id in ["a", "b"] {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap, origin: .zero, width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                    homeMembers: [CanvasNodeID("a"), CanvasNodeID("b")]))
        let model = PromotionSheetModel(source: .region(CanvasRegionID("r1")), scene: s,
                                        scraps: [CanvasNodeID("a"): "one", CanvasNodeID("b"): "two"])
        model.select(.paletteCard)
        XCTAssertEqual(model.preview?.offeredLinks.count, 2)
        XCTAssertFalse(model.linksAccepted)
        XCTAssertFalse(model.resolvedPlan!.linksAccepted)
    }

    func test_theDiscardNoticeIsSurfacedForARegion() {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        let model = PromotionSheetModel(source: .region(CanvasRegionID("r1")), scene: s, scraps: [:])
        model.select(.paletteCard)
        XCTAssertFalse(model.discardNotice.isEmpty,
                       "the writer must be told the lines and layout are not carried across")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionSheetTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'PromotionSheetModel' in scope`.

- [ ] **Step 3: Write the model and the sheet**

`PromotionSheetModel` is an `@Observable` class holding the source, the scene snapshot, the scraps, `selectedTarget`, `editedTitle`, `linksAccepted`, and computing `preview` / `resolvedPlan` / `canCommit` / `discardNotice`.

Two rules to encode in comments at the top:

```swift
/// The promotion preview.
///
/// §6.1: the writer sees what will be produced, and where, before committing.
/// Scrivener's Commit is the model — a named command with a stated rule and a
/// predictable outcome.
///
/// Two defaults are deliberate and must not be "improved":
///
/// * `selectedTarget` starts nil. Nothing can be committed by pressing return
///   on a sheet that just appeared.
/// * `linksAccepted` starts false. Promotion may suggest and must never impose;
///   an offer that arrives pre-accepted is an imposition with a checkbox.
```

The sheet renders: the source's text, a target picker, a preview panel showing title (editable), body and destination, the discard notice when non-empty, the link offer as an unchecked list, and Cancel / **Promote** buttons.

**And the precedence line, stated once, plainly** (spec §5). Put it in the sheet's footer, where a writer meets it exactly when the distinction matters:

> Wiki-links are durable and travel with your project. Canvas lines are scratch — they stay on the canvas.

Wire the gesture into `CanvasView`: a `.contextMenu` on a node/region/line with a "Promote…" item, plus a ⌘⇧P command targeting the current selection.

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/PromotionSheetTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 6 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas MaughamTests/Canvas/PromotionSheetTests.swift project.yml
git commit -m "feat(canvas): promotion sheet — preview, editable title, declined-by-default links

Resolves spec §10's open gesture question: context action + ⌘⇧P, no
artifact rail in v1. Flagged for smoke."
```

---

### Task 6: Readiness stays silent about the canvas

**Files:**
- Test: `MaughamTests/Canvas/CanvasReadinessTests.swift`
- Modify: whatever surfaces metrics, only if the test finds a leak

Spec §6.1 and umbrella §7/§9: *"Readiness counts promoted artifacts and stays silent about the canvas."* The canvas is unmeasurable by construction, and counting it would turn a thinking surface into a scoreboard. This task is a **guard**, and it may well be all-green with no production change — that is a fine outcome, and the test is the deliverable.

- [ ] **Step 1: Write the test**

```swift
import XCTest
@testable import Maugham

final class CanvasReadinessTests: XCTestCase {

    /// The canvas must not contribute to any counted metric. Most of what is on
    /// it is not anything yet and never will be; counting it would make a mess
    /// look like a deficit.
    func test_scrapsDoNotCountTowardProjectWordCount() throws {
        let fixture = try TestProjectFixture.make()
        defer { try? fixture.tearDown() }
        let before = fixture.store.manifest.totalWordCount

        CanvasStore(projectRoot: fixture.rootURL).save(
            scene: CanvasScene(),
            scraps: [CanvasNodeID("a"): String(repeating: "word ", count: 500)])
        fixture.store.reload()

        XCTAssertEqual(fixture.store.manifest.totalWordCount, before,
                       "canvas.md must not be counted as manuscript")
    }

    func test_canvasMdIsNotTreatedAsAProjectDocument() throws {
        let fixture = try TestProjectFixture.make()
        defer { try? fixture.tearDown() }
        CanvasStore(projectRoot: fixture.rootURL).save(
            scene: CanvasScene(), scraps: [CanvasNodeID("a"): "The falls"])
        fixture.store.reload()
        XCTAssertFalse(fixture.store.manifest.allDocumentPaths.contains("canvas.md"),
                       "canvas.md is scrap content, not a binder document")
    }

    func test_theStatusFooterIsHiddenOnTheCanvasSegment() {
        // Mirrors ProjectWindow.shouldShowStatusFooter's guard.
        XCTAssertFalse([BinderSegment.manuscript, .scenes].contains(.canvas))
    }
}
```

Check the real property names on `manifest` before running — `totalWordCount` and `allDocumentPaths` are illustrative; use whatever the codebase actually exposes, and if no equivalent exists, assert against the metrics type the footer consumes.

- [ ] **Step 2: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasReadinessTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS. **If any fail, that is a real leak** — `canvas.md` at project root is being swept up by a glob that assumes every root-level `.md` is a manuscript. Fix by excluding it explicitly where the glob lives, and note it in the task report.

- [ ] **Step 3: Commit**

```bash
git add MaughamTests/Canvas/CanvasReadinessTests.swift
git commit -m "test(canvas): readiness and word count stay silent about the canvas"
```

---

### Task 7: MCP surface

**Files:**
- Modify: `Maugham/MCP/MCPToolCatalog.swift`
- Create: `Maugham/MCP/Tools/ListCanvasTool.swift`
- Test: `MaughamTests/MCP/CanvasToolTests.swift`

CLAUDE.md rule 8: every new data type needs a surface. The canvas has its UI; this gives Claude **read-only** access, matching the inbox's read-plus-promote shape.

**Read-only, deliberately.** The canvas is the one surface where nothing has to resolve (spec §1), and a tool that writes to it would let Claude create durable-ish artifacts on the writer's thinking surface without the explicit act §1 requires. Promotion stays a human verb.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasToolTests: XCTestCase {

    func test_theCatalogIncludesTheCanvasTool() {
        XCTAssertTrue(MCPToolCatalog.all.contains { $0.name == "list_canvas" })
    }

    /// The tool count literal must derive from the catalog, never be hardcoded —
    /// the publish-pipeline milestone found four separate hardcoded copies.
    func test_toolCountIsDerivedFromTheCatalog() {
        XCTAssertEqual(MCPToolCatalog.all.count, Set(MCPToolCatalog.all.map(\.name)).count,
                       "duplicate tool names in the catalog")
    }

    func test_thereIsNoCanvasWriteTool() {
        let writers = MCPToolCatalog.all.map(\.name).filter {
            $0.contains("canvas") && ($0.hasPrefix("add_") || $0.hasPrefix("write_")
                                      || $0.hasPrefix("promote_") || $0.hasPrefix("set_"))
        }
        XCTAssertTrue(writers.isEmpty,
                      "the canvas is the surface where nothing has to resolve — "
                      + "promotion is an explicit human act (§1, §6.1)")
    }

    func test_listCanvasReportsScrapsRegionsAndLines() throws {
        let fixture = try TestProjectFixture.make()
        defer { try? fixture.tearDown() }
        var scene = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240)
        n.cachedHeight = 80
        scene.insert(n)
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                        homeMembers: [CanvasNodeID("a")]))
        CanvasStore(projectRoot: fixture.rootURL).save(
            scene: scene, scraps: [CanvasNodeID("a"): "The falls at night."])

        let out = try ListCanvasTool().run(projectRoot: fixture.rootURL)
        XCTAssertTrue(out.contains("The falls at night."))
        XCTAssertTrue(out.contains("Act II fog"))
    }

    func test_listCanvasDistinguishesResidentsFromVisitors() throws {
        let fixture = try TestProjectFixture.make()
        defer { try? fixture.tearDown() }
        var scene = CanvasScene()
        for id in ["a", "b"] {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap, origin: .zero, width: 240)
            n.cachedHeight = 80
            scene.insert(n)
        }
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                        homeMembers: [CanvasNodeID("a")],
                                        appearances: [CanvasNodeID("b")]))
        CanvasStore(projectRoot: fixture.rootURL).save(
            scene: scene, scraps: [CanvasNodeID("a"): "one", CanvasNodeID("b"): "two"])

        let out = try ListCanvasTool().run(projectRoot: fixture.rootURL)
        XCTAssertTrue(out.lowercased().contains("lives"))
        XCTAssertTrue(out.lowercased().contains("appears"))
    }

    func test_anEmptyCanvasSaysSoRatherThanFailing() throws {
        let fixture = try TestProjectFixture.make()
        defer { try? fixture.tearDown() }
        XCTAssertNoThrow(try ListCanvasTool().run(projectRoot: fixture.rootURL))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasToolTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'ListCanvasTool' in scope`.

- [ ] **Step 3: Implement**

Follow `Maugham/MCP/AREA.md`: implement `MCPTool`, add to `MCPToolCatalog.all`. Both `MCPToolsListHandler` and `MaughamApp.registerTools` derive from the catalog, so no third registration site exists.

**A new MCP tool breaks at least three tools-list tests** (onboarding milestone lesson). Expect and fix, in the same commit: the tools-list count assertions, `MCPToolsListSmokeTest`, and `docs/product.md` if it names a count. Any count literal must derive from `MCPToolCatalog.all.count`.

Output shape: scraps with their text, regions with label, bound piece and both membership lists clearly distinguished, and lines with their labels.

- [ ] **Step 4: Run the full suite**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: full Mac suite green. A filtered run will not surface the tools-list breakage.

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP MaughamTests/MCP/CanvasToolTests.swift docs/ project.yml
git commit -m "feat(mcp): list_canvas, read-only

The canvas is the surface where nothing has to resolve; promotion stays
an explicit human act, so there is deliberately no canvas write tool."
```

---

### Task 8: Docs and the milestone sweep

**Files:**
- Modify: `Maugham/Canvas/AREA.md`, `Maugham/MCP/AREA.md`
- Modify: `docs/adr/0026-planning-canvas-rendering.md` (or a new ADR for promotion)
- Modify: `docs/guide/`, `docs/roadmap.md`, `docs/problem-map.md`, `docs/constitution.md`, `CLAUDE.md`

- [ ] **Step 1: AREA.md**

Add a "Lines and promotion" section: untyped and why (Kinopio), the §6 table, the two deliberate defaults (nothing selected, links declined), what promotion discards and why that is a feature, and that promotion never removes the scrap.

- [ ] **Step 2: The ADR**

Record the promotion design with its evidence — Shipman & Marshall's conditional licence, Scrivener's Commit as the precedent, Kinopio's removal of typed edges — and the resolution of §10's gesture question with the fallback named.

- [ ] **Step 3: The guide**

Describe what ships: drawing a line, labelling it, promoting a scrap/region/line, and — plainly, once — that wiki-links are durable and canvas lines are scratch. Rule 7: describe what ships, not what is planned.

- [ ] **Step 4: Sweep the milestone**

M1C is now complete across 1C-a/b/c. Sweep for now-false claims (rule 10):

```bash
grep -rn "M1C\|canvas" docs/roadmap.md docs/problem-map.md docs/constitution.md CLAUDE.md docs/adr/0025-persona-shell.md | grep -iv corkboard
```

Flip the roadmap's canvas item •→✓. Check `docs/problem-map.md`'s writer-jobs rows for planning — several were `•` pending this milestone.

- [ ] **Step 5: Update the MCP tool list**

`Maugham/MCP/AREA.md` carries the full tool list. Add `list_canvas`. CLAUDE.md deliberately no longer carries a count — leave it that way.

- [ ] **Step 6: Full verification**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/DocSyncTests CODE_SIGNING_ALLOWED=NO`
Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add docs/ Maugham/Canvas/AREA.md Maugham/MCP/AREA.md CLAUDE.md
git commit -m "docs(canvas): lines and promotion; M1C roadmap and problem-map sweep"
```

---

## Whole-slice verification

- [ ] Full Mac suite, full phone suite, Release build — all green
- [ ] **Whole-branch review** of the 1C-c diff
- [ ] **Whole-milestone review** of 1C-a + 1C-b + 1C-c together. Per-slice reviews cannot see interactions across slices, and this milestone's model grew through three schema versions.
- [ ] MCP dev-app smoke via the raw socket: `list_canvas` on a real project with scraps, a region with both residents and visitors, and a labelled line. This has caught defects after all tests were green (the commonmark-fountain milestone's E1).
- [ ] Smoke, by hand: draw a line between two scraps → label it → promote a scrap to a research note → confirm the note exists in the tree AND the scrap is still on the canvas → promote a region to a palette card → confirm the link offer arrives unchecked → decline it → confirm no links were written → promote the same region again and accept → confirm exactly the offered links appear → check the precedence line reads plainly → quit and reopen → lines, labels and regions all survive

## M1 completion

1C-c is the last slice of M1C. **M1 is complete only when 1A (the spine) is also in.** 1B is merged and unpushed; 1C-a/b/c land on the same branch line.

**Do not push or tag until all three of 1A, 1B and 1C are in.** Slicing the implementation is fine; slicing the release is not.
