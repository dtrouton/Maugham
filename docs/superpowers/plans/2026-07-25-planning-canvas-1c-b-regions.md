# Planning canvas 1C-b — regions and membership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add labelled regions — the canvas's only grouping primitive — with membership that is stored rather than computed, one home region per node plus any number of appearances, and an optional binding from a region to a piece.

**Architecture:** Membership is an explicit set on the region, mutated only by deliberate acts. Geometry never adds or removes a member. A node has exactly one *home* region (or none) and may *appear in* any number of others; only the home region moves it. Regions draw in the same pass as nodes, off the same model.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, XCTest. Builds directly on 1C-a.

## Global Constraints

Everything in 1C-a's Global Constraints still applies. In addition:

- **Membership is stored, never recomputed from coordinates at read time** (spec §4.2, §8). This is the whole point of the design and it eliminates a bug class every surveyed tool has.
- **A node lives in exactly one region and may appear in any number** (spec §4.3). Appearances are references, never copies — "copies are rejected outright".
- **An appearance must not render identically to the thing itself** (spec §4.3), or the copy problem returns visually.
- **Only nodes that *live* in a region are bound to its piece** (spec §4.4). Visitors are not, or two regions sharing a card would each claim it.
- **Nested regions are out of scope** (spec §9).
- Run `./gen.sh` after adding files; `xcodebuild` in the **foreground**; Release build for anything touching views.

## Why membership is explicit — read this before touching `CanvasRegion`

Spec §4.2 is not a preference, it is a bug-class elimination, and every surveyed tool got it wrong:

- **Obsidian** leaves a card poking one pixel outside a group.
- **tldraw** ejects children when a frame is resized — *despite* storing membership explicitly ([issue #6017](https://github.com/tldraw/tldraw/issues/6017)) — because the hazard is the geometry→membership *transition rule*, independent of storage.
- **Scapple** recomputes from live geometry and has an unfixed bug where a note shared by two overlapping shapes moves with whichever shape you happen to grab.

The accepted cost is that a node can sit visually outside the region that owns it. That is a **rendering** problem — draw the relationship — not a correctness one.

So: if you find yourself writing `if region.frame.contains(node.origin)` anywhere near membership, stop. Task 2's tests exist to catch exactly that.

## File Structure

| File | Responsibility |
|---|---|
| `Maugham/Canvas/CanvasRegion.swift` | `CanvasRegion` — id, label, frame, membership sets, optional piece binding |
| `Maugham/Canvas/CanvasMembership.swift` | The membership rules: home vs appearance, the invariants, the mutations |
| `Maugham/Canvas/CanvasScene.swift` | *Modify* — regions join the scene |
| `Maugham/Canvas/CanvasSceneCodec.swift` | *Modify* — schema 1 → 2 |
| `Maugham/Canvas/CanvasRenderer.swift` | *Modify* — draw regions beneath nodes; draw appearances as chips |
| `Maugham/Canvas/CanvasInteraction.swift` | *Modify* — region drag carries members; drop-onto-region joins |
| `Maugham/Canvas/RegionInspector.swift` | Label editing and the piece binding control |

---

### Task 1: The region model

**Files:**
- Create: `Maugham/Canvas/CanvasRegion.swift`
- Test: `MaughamTests/Canvas/CanvasRegionTests.swift`

**Interfaces:**
- Consumes: `CanvasNodeID` (1C-a Task 1).
- Produces: `CanvasRegionID`, `CanvasRegion` (`id`, `label: String`, `frame: CGRect`, `homeMembers: Set<CanvasNodeID>`, `appearances: Set<CanvasNodeID>`, `boundPieceID: String?`, `isCollapsed: Bool`).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasRegionTests: XCTestCase {

    private func region(_ id: String = "r1") -> CanvasRegion {
        CanvasRegion(id: CanvasRegionID(id), label: "Act II fog",
                     frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    }

    func test_aFreshRegionHasNoMembersAndNoBinding() {
        let r = region()
        XCTAssertTrue(r.homeMembers.isEmpty)
        XCTAssertTrue(r.appearances.isEmpty)
        XCTAssertNil(r.boundPieceID)
        XCTAssertFalse(r.isCollapsed)
    }

    func test_containsDistinguishesHomeFromAppearance() {
        var r = region()
        r.homeMembers.insert(CanvasNodeID("a"))
        r.appearances.insert(CanvasNodeID("b"))
        XCTAssertTrue(r.livesHere(CanvasNodeID("a")))
        XCTAssertFalse(r.livesHere(CanvasNodeID("b")))
        XCTAssertTrue(r.appearsHere(CanvasNodeID("b")))
        XCTAssertTrue(r.hasAnyRelationshipTo(CanvasNodeID("a")))
        XCTAssertTrue(r.hasAnyRelationshipTo(CanvasNodeID("b")))
        XCTAssertFalse(r.hasAnyRelationshipTo(CanvasNodeID("c")))
    }

    /// §4.4: only nodes that LIVE in the region are bound to its piece.
    /// Visitors are not, or two regions sharing a card would each claim it.
    func test_boundNodesAreHomeMembersOnly() {
        var r = region()
        r.homeMembers.insert(CanvasNodeID("a"))
        r.appearances.insert(CanvasNodeID("b"))
        r.boundPieceID = "piece-1"
        XCTAssertEqual(r.boundNodes, [CanvasNodeID("a")])
    }

    func test_anUnboundRegionBindsNothingEvenWithMembers() {
        var r = region()
        r.homeMembers.insert(CanvasNodeID("a"))
        XCTAssertTrue(r.boundNodes.isEmpty)
    }

    func test_labelSurvivesBeingEmpty() {
        var r = region()
        r.label = ""
        XCTAssertEqual(r.displayLabel, "Untitled region",
                       "an unlabelled region must still be nameable on screen")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasRegion' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public struct CanvasRegionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// A labelled area drawn on the canvas. Regions are the canvas's ONLY grouping
/// primitive (spec §4).
///
/// Membership is two sets, not one, and the distinction is load-bearing
/// (spec §4.3). A node *lives in* exactly one region — that is the tiebreak
/// that makes region-drag work, because only a node's home region moves it.
/// A node may *appear in* any number of others: planning is associative, the
/// street photo belongs to *Good Luck Babe* and to the book's visual language,
/// and a strict ownership tree would force duplication or a premature choice.
///
/// An appearance is a REFERENCE, never a copy. Copies are rejected outright —
/// Maugham is single-source-plus-derivation everywhere, and two editable copies
/// of one note is precisely the failure the architecture exists to prevent.
public struct CanvasRegion: Equatable, Sendable {
    public let id: CanvasRegionID
    public var label: String
    public var frame: CGRect

    /// Nodes that live here. Drag this region and these travel.
    public var homeMembers: Set<CanvasNodeID>

    /// Nodes cited by this region but living elsewhere. Drag this region and
    /// these stay put — a visitor is not luggage.
    public var appearances: Set<CanvasNodeID>

    /// Optional binding to a piece. This is the bridge from umbrella §8: the
    /// nodes that live in a piece's region become the pinned references beside
    /// the editor when you write it, and the context the authoring compiler
    /// reads. The clustering done while planning pays off twice, with no
    /// separate curation step.
    public var boundPieceID: String?

    /// Collapsing answers crowding at collection scale (spec §7, §10).
    public var isCollapsed: Bool

    public init(id: CanvasRegionID,
                label: String,
                frame: CGRect,
                homeMembers: Set<CanvasNodeID> = [],
                appearances: Set<CanvasNodeID> = [],
                boundPieceID: String? = nil,
                isCollapsed: Bool = false) {
        self.id = id
        self.label = label
        self.frame = frame
        self.homeMembers = homeMembers
        self.appearances = appearances
        self.boundPieceID = boundPieceID
        self.isCollapsed = isCollapsed
    }

    public var displayLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled region" : label
    }

    public func livesHere(_ id: CanvasNodeID) -> Bool { homeMembers.contains(id) }
    public func appearsHere(_ id: CanvasNodeID) -> Bool { appearances.contains(id) }
    public func hasAnyRelationshipTo(_ id: CanvasNodeID) -> Bool {
        livesHere(id) || appearsHere(id)
    }

    /// What this region contributes to its bound piece. HOME MEMBERS ONLY
    /// (spec §4.4) — a visitor being cited by a cluster must not make it that
    /// piece's reference too.
    public var boundNodes: Set<CanvasNodeID> {
        boundPieceID == nil ? [] : homeMembers
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasRegion.swift MaughamTests/Canvas/CanvasRegionTests.swift project.yml
git commit -m "feat(canvas): region model — home members, appearances, optional piece binding"
```

---

### Task 2: Membership rules — and the geometry firewall

**Files:**
- Create: `Maugham/Canvas/CanvasMembership.swift`
- Modify: `Maugham/Canvas/CanvasScene.swift` (regions join the scene)
- Test: `MaughamTests/Canvas/CanvasMembershipTests.swift`

**Interfaces:**
- Consumes: `CanvasRegion`, `CanvasScene`.
- Produces: `enum CanvasMembership` with `static func join(_ node:home:in:)`, `static func addAppearance(_ node:to:in:)`, `static func leave(_ node:from:in:)`, `static func homeRegion(of:in:) -> CanvasRegionID?`, `static func nodesTravelling(withRegion:in:) -> Set<CanvasNodeID>`; and `CanvasScene.regions`, `region(_:)`, `insertRegion(_:)`, `removeRegion(_:)`.

- [ ] **Step 1: Write the failing test**

The first four tests are the geometry firewall. They are the reason this task exists.

```swift
import XCTest
@testable import Maugham

final class CanvasMembershipTests: XCTestCase {

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for (i, id) in ["a", "b", "c"].enumerated() {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i) * 50, y: 0), width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r2"), label: "Falls",
                                    frame: CGRect(x: 800, y: 0, width: 600, height: 400)))
        return s
    }

    /// §4.2: coordinates never add a member. This is the bug class every
    /// surveyed tool has.
    func test_movingANodeIntoARegionsRectDoesNotJoinIt() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        // 'b' sits geometrically inside r1 already and was never joined.
        XCTAssertFalse(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("b")))
        s.move(CanvasNodeID("b"), to: CGPoint(x: 100, y: 100))
        XCTAssertFalse(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("b")),
                       "geometry must never add a member")
    }

    func test_movingAMemberOutsideTheRegionDoesNotRemoveIt() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        s.move(CanvasNodeID("a"), to: CGPoint(x: 5000, y: 5000))
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")),
                      "a node may sit visually outside the region that owns it — "
                      + "that is a rendering problem, not a correctness one")
    }

    func test_resizingARegionNeverEjectsMembers() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        s.setRegionFrame(CGRect(x: 0, y: 0, width: 10, height: 10), for: CanvasRegionID("r1"))
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")),
                      "tldraw ejects children on resize DESPITE storing membership "
                      + "explicitly — the transition rule is the hazard")
    }

    func test_shrinkingARegionToNothingKeepsItsMembership() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        s.setRegionFrame(.zero, for: CanvasRegionID("r1"))
        XCTAssertEqual(s.region(CanvasRegionID("r1"))!.homeMembers, [CanvasNodeID("a")])
    }

    /// §4.3: one home, many appearances.
    func test_joiningASecondRegionMovesTheHomeRatherThanDuplicatingIt() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r2"), in: &s)
        XCTAssertFalse(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")))
        XCTAssertTrue(s.region(CanvasRegionID("r2"))!.livesHere(CanvasNodeID("a")))
        XCTAssertEqual(CanvasMembership.homeRegion(of: CanvasNodeID("a"), in: s),
                       CanvasRegionID("r2"))
    }

    func test_aNodeCanAppearInManyRegionsAtOnce() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        CanvasMembership.addAppearance(CanvasNodeID("a"), to: CanvasRegionID("r2"), in: &s)
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")))
        XCTAssertTrue(s.region(CanvasRegionID("r2"))!.appearsHere(CanvasNodeID("a")))
        XCTAssertFalse(s.region(CanvasRegionID("r2"))!.livesHere(CanvasNodeID("a")))
    }

    func test_appearanceInTheHomeRegionIsRejectedAsMeaningless() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        CanvasMembership.addAppearance(CanvasNodeID("a"), to: CanvasRegionID("r1"), in: &s)
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.appearances.isEmpty)
    }

    func test_becomingHomeSomewhereClearsAnAppearanceThere() {
        var s = scene()
        CanvasMembership.addAppearance(CanvasNodeID("a"), to: CanvasRegionID("r2"), in: &s)
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r2"), in: &s)
        XCTAssertTrue(s.region(CanvasRegionID("r2"))!.livesHere(CanvasNodeID("a")))
        XCTAssertFalse(s.region(CanvasRegionID("r2"))!.appearsHere(CanvasNodeID("a")),
                       "a node must never be both resident and visitor in one region")
    }

    /// §4.1 and §4.3: drag a region and its residents travel; visitors do not.
    func test_onlyHomeMembersTravelWithTheRegion() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        CanvasMembership.addAppearance(CanvasNodeID("b"), to: CanvasRegionID("r1"), in: &s)
        XCTAssertEqual(CanvasMembership.nodesTravelling(withRegion: CanvasRegionID("r1"), in: s),
                       [CanvasNodeID("a")])
    }

    func test_leaveRemovesBothHomeAndAppearance() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        CanvasMembership.addAppearance(CanvasNodeID("a"), to: CanvasRegionID("r2"), in: &s)
        CanvasMembership.leave(CanvasNodeID("a"), from: CanvasRegionID("r1"), in: &s)
        CanvasMembership.leave(CanvasNodeID("a"), from: CanvasRegionID("r2"), in: &s)
        XCTAssertNil(CanvasMembership.homeRegion(of: CanvasNodeID("a"), in: s))
        XCTAssertFalse(s.region(CanvasRegionID("r2"))!.appearsHere(CanvasNodeID("a")))
    }

    func test_deletingARegionOrphansItsMembersRatherThanDeletingThem() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        s.removeRegion(CanvasRegionID("r1"))
        XCTAssertNotNil(s.node(CanvasNodeID("a")), "deleting a region must never delete nodes")
        XCTAssertNil(CanvasMembership.homeRegion(of: CanvasNodeID("a"), in: s))
    }

    func test_deletingANodeClearsItFromEveryRegion() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        CanvasMembership.addAppearance(CanvasNodeID("a"), to: CanvasRegionID("r2"), in: &s)
        s.remove(CanvasNodeID("a"))
        XCTAssertFalse(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")))
        XCTAssertFalse(s.region(CanvasRegionID("r2"))!.appearsHere(CanvasNodeID("a")),
                       "a dangling membership would render a chip for a node that is gone")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasMembershipTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasMembership' in scope`.

- [ ] **Step 3: Extend `CanvasScene` with regions**

Add to `Maugham/Canvas/CanvasScene.swift`:

```swift
    private var regionsByID: [CanvasRegionID: CanvasRegion] = [:]

    /// Regions in a stable order. Drawn BENEATH nodes, so a region never
    /// occludes the cards it holds.
    public var regions: [CanvasRegion] {
        regionsByID.values.sorted { $0.id.raw < $1.id.raw }
    }

    public func region(_ id: CanvasRegionID) -> CanvasRegion? { regionsByID[id] }

    public mutating func insertRegion(_ region: CanvasRegion) {
        regionsByID[region.id] = region
    }

    /// Removing a region ORPHANS its members — it never deletes nodes. A region
    /// is a way of grouping thoughts, not a container that owns their existence.
    public mutating func removeRegion(_ id: CanvasRegionID) { regionsByID[id] = nil }

    public mutating func updateRegion(_ id: CanvasRegionID,
                                      _ mutate: (inout CanvasRegion) -> Void) {
        guard var r = regionsByID[id] else { return }
        mutate(&r)
        regionsByID[id] = r
    }

    /// Geometry only. Deliberately does NOT touch membership — see
    /// `CanvasMembership` and spec §4.2.
    public mutating func setRegionFrame(_ frame: CGRect, for id: CanvasRegionID) {
        regionsByID[id]?.frame = frame
    }

    /// Topmost region whose frame contains `point`, for drop targeting.
    public func region(at point: CGPoint) -> CanvasRegion? {
        regions.reversed().first { $0.frame.contains(point) }
    }
```

and extend `remove(_ id: CanvasNodeID)` so a deleted node cannot leave a dangling membership:

```swift
    public mutating func remove(_ id: CanvasNodeID) {
        byID[id] = nil
        // A membership pointing at a node that no longer exists would render a
        // chip for nothing and would be bound to a piece as a phantom reference.
        for regionID in regionsByID.keys {
            regionsByID[regionID]?.homeMembers.remove(id)
            regionsByID[regionID]?.appearances.remove(id)
        }
    }
```

Update `Equatable` conformance to include `regionsByID` (synthesised, but confirm the stored property is included — `CanvasScene`'s conformance is synthesised from all stored properties, so adding one is enough).

- [ ] **Step 4: Write the membership rules**

```swift
import Foundation

/// The membership rules, in one place.
///
/// **Membership changes ONLY by deliberate act.** Dropping a node onto a region
/// adds it; an explicit remove takes it out. Coordinates never add or remove a
/// member (spec §4.2). Nothing in this file reads a node's origin, and nothing
/// anywhere else may derive membership from geometry.
///
/// This eliminates a bug class every surveyed tool has. Obsidian leaves a card
/// poking one pixel outside a group. tldraw ejects children when a frame is
/// resized *despite* storing membership explicitly (issue #6017) — the
/// geometry→membership transition rule is the hazard, independent of storage.
/// Scapple recomputes from live geometry and has an unfixed bug where a note
/// shared by two overlapping shapes moves with whichever shape you grab.
///
/// The accepted cost is that a node can sit visually outside the region that
/// owns it. That is a rendering problem — draw the relationship — and it is the
/// better trade.
enum CanvasMembership {

    /// Make `region` the node's HOME. A node lives in exactly one region, so
    /// this clears any previous home. Idempotent.
    static func join(_ node: CanvasNodeID,
                     home region: CanvasRegionID,
                     in scene: inout CanvasScene) {
        for r in scene.regions where r.id != region {
            scene.updateRegion(r.id) { $0.homeMembers.remove(node) }
        }
        scene.updateRegion(region) {
            $0.homeMembers.insert(node)
            // A node must never be both resident and visitor in one region.
            $0.appearances.remove(node)
        }
    }

    /// Cite a node from a region it does not live in. A reference, not a copy.
    static func addAppearance(_ node: CanvasNodeID,
                              to region: CanvasRegionID,
                              in scene: inout CanvasScene) {
        // An appearance in the node's own home is meaningless — it would render
        // a reference chip beside the thing itself.
        guard scene.region(region)?.livesHere(node) != true else { return }
        scene.updateRegion(region) { $0.appearances.insert(node) }
    }

    /// Remove every relationship between a node and one region.
    static func leave(_ node: CanvasNodeID,
                      from region: CanvasRegionID,
                      in scene: inout CanvasScene) {
        scene.updateRegion(region) {
            $0.homeMembers.remove(node)
            $0.appearances.remove(node)
        }
    }

    static func homeRegion(of node: CanvasNodeID, in scene: CanvasScene) -> CanvasRegionID? {
        scene.regions.first { $0.livesHere(node) }?.id
    }

    static func appearanceRegions(of node: CanvasNodeID, in scene: CanvasScene) -> [CanvasRegionID] {
        scene.regions.filter { $0.appearsHere(node) }.map(\.id)
    }

    /// What travels when the writer drags this region.
    ///
    /// Residents only (spec §4.1, §4.3). Drag a region a node merely appears in
    /// and it stays put — a visitor is not luggage, and being cited by a cluster
    /// should not let that cluster drag you around the canvas.
    static func nodesTravelling(withRegion region: CanvasRegionID,
                                in scene: CanvasScene) -> Set<CanvasNodeID> {
        scene.region(region)?.homeMembers ?? []
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasMembershipTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 12 tests.

- [ ] **Step 6: Falsify the firewall**

Temporarily make `setRegionFrame` prune members outside the new frame — the tldraw bug, deliberately introduced. Re-run and confirm `test_resizingARegionNeverEjectsMembers` and `test_shrinkingARegionToNothingKeepsItsMembership` both fail by name. Then revert and re-run to green. Record the observed failures in the task report.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasMembership.swift Maugham/Canvas/CanvasScene.swift MaughamTests/Canvas/CanvasMembershipTests.swift project.yml
git commit -m "feat(canvas): explicit membership — geometry never adds or removes a member

One home region per node plus any number of appearances. Region resize
and node movement cannot change membership; the firewall was falsified
by introducing the tldraw ejection bug and watching the tests name it."
```

---

### Task 3: Persist regions — schema 1 → 2

**Files:**
- Modify: `Maugham/Canvas/CanvasSceneCodec.swift`
- Test: `MaughamTests/Canvas/CanvasRegionCodecTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasRegionCodecTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-region-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func test_regionsRoundTripThroughDisk() {
        var scene = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero, width: 240)
        n.cachedHeight = 80
        scene.insert(n)
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 10, y: 20, width: 300, height: 200),
                                        homeMembers: [CanvasNodeID("a")],
                                        appearances: [],
                                        boundPieceID: "piece-3",
                                        isCollapsed: true))
        CanvasStore(projectRoot: root).save(scene: scene, scraps: [:])

        let loaded = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(loaded.regions.count, 1)
        let r = loaded.region(CanvasRegionID("r1"))
        XCTAssertEqual(r?.label, "Act II fog")
        XCTAssertEqual(r?.frame, CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(r?.homeMembers, [CanvasNodeID("a")])
        XCTAssertEqual(r?.boundPieceID, "piece-3")
        XCTAssertEqual(r?.isCollapsed, true)
    }

    /// A v1 sidecar written by 1C-a has no `regions` key at all.
    func test_aSchemaV1SidecarLoadsWithNoRegions() throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"schemaVersion":1,"nodes":[
          {"id":"a","kind":"scrap","x":1,"y":2,"width":240,"z":0}
        ]}
        """
        try json.write(to: dir.appendingPathComponent("canvas.json"),
                       atomically: true, encoding: .utf8)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertNotNil(scene.node(CanvasNodeID("a")))
        XCTAssertTrue(scene.regions.isEmpty)
    }

    /// A membership naming a node that is not in the file must not survive —
    /// it would render a chip for nothing.
    func test_membershipReferencingAMissingNodeIsDropped() throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"schemaVersion":2,"nodes":[],"regions":[
          {"id":"r1","label":"x","x":0,"y":0,"width":10,"height":10,
           "homeMembers":["ghost"],"appearances":["also-ghost"],"isCollapsed":false}
        ]}
        """
        try json.write(to: dir.appendingPathComponent("canvas.json"),
                       atomically: true, encoding: .utf8)
        let r = CanvasStore(projectRoot: root).load().scene.region(CanvasRegionID("r1"))
        XCTAssertEqual(r?.homeMembers, [])
        XCTAssertEqual(r?.appearances, [])
    }

    func test_aNodeClaimedAsHomeByTwoRegionsResolvesToOne() throws {
        let dir = root.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"schemaVersion":2,"nodes":[
          {"id":"a","kind":"scrap","x":0,"y":0,"width":240,"z":0,"cachedHeight":80}
        ],"regions":[
          {"id":"r1","label":"x","x":0,"y":0,"width":10,"height":10,
           "homeMembers":["a"],"appearances":[],"isCollapsed":false},
          {"id":"r2","label":"y","x":0,"y":0,"width":10,"height":10,
           "homeMembers":["a"],"appearances":[],"isCollapsed":false}
        ]}
        """
        try json.write(to: dir.appendingPathComponent("canvas.json"),
                       atomically: true, encoding: .utf8)
        let scene = CanvasStore(projectRoot: root).load().scene
        let homes = scene.regions.filter { $0.livesHere(CanvasNodeID("a")) }
        XCTAssertEqual(homes.count, 1, "one home is an invariant, so the loader must enforce it")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionCodecTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — no `regions` on the DTO.

- [ ] **Step 3: Extend the codec**

In `CanvasSceneCodec.swift`:

```swift
    static let currentSchemaVersion = 2

    /// Absent in a v1 sidecar, so it decodes to empty rather than throwing.
    var regions: [RegionDTO]?

    struct RegionDTO: Codable {
        var id: String
        var label: String
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var homeMembers: [String]
        var appearances: [String]
        var boundPieceID: String?
        var isCollapsed: Bool
    }
```

In the `scene` computed property, after nodes are built:

```swift
        // Memberships are validated against the nodes actually present. A
        // membership naming a node that is not in the file would render a chip
        // for nothing and, if the region is bound, hand the compiler a phantom
        // reference.
        let present = Set(s.nodes.map(\.id))
        var claimedHomes: Set<CanvasNodeID> = []

        for dto in regions ?? [] {
            var home = Set(dto.homeMembers.map(CanvasNodeID.init).filter { present.contains($0) })
            // One home per node is an invariant. A hand-edited or
            // concurrently-written sidecar could break it, so the loader
            // resolves rather than trusting: first region wins, in file order.
            home.subtract(claimedHomes)
            claimedHomes.formUnion(home)

            let visiting = Set(dto.appearances.map(CanvasNodeID.init)
                .filter { present.contains($0) })
                .subtracting(home)

            s.insertRegion(CanvasRegion(
                id: CanvasRegionID(dto.id),
                label: dto.label,
                frame: CGRect(x: dto.x, y: dto.y, width: dto.width, height: dto.height),
                homeMembers: home,
                appearances: visiting,
                boundPieceID: dto.boundPieceID,
                isCollapsed: dto.isCollapsed))
        }
```

and mirror it in `init(scene:)`.

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionCodecTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 4 tests. Also re-run `MaughamTests/CanvasStoreTests` — the v1 tests must still pass.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasSceneCodec.swift MaughamTests/Canvas/CanvasRegionCodecTests.swift
git commit -m "feat(canvas): persist regions, sidecar schema 1→2, loader enforces one-home invariant"
```

---

### Task 4: Draw regions and appearance chips

**Files:**
- Modify: `Maugham/Canvas/CanvasRenderer.swift`
- Test: `MaughamTests/Canvas/CanvasRegionRenderTests.swift`

**Spec §4.3 is a rendering requirement here:** *"An appearance must not render identically to the thing itself — otherwise the copy problem returns visually and you cannot tell which is real. An appearance reads as a reference: smaller, or a chip carrying the title with a hairline to its home. Any region should answer 'which of these live here and which are visiting' at a glance."*

And §4.2's accepted cost has to be paid here: *"a node can sit visually outside the region that owns it. That is a rendering problem (draw the relationship)."*

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
@testable import Maugham

final class CanvasRegionRenderTests: XCTestCase {

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap,
                           origin: CGPoint(x: 50, y: 50), width: 240)
        n.cachedHeight = 80
        s.insert(n)
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        return s
    }

    func test_regionsDrawBeneathNodes() {
        XCTAssertLessThan(CanvasRenderer.regionLayerDepth, CanvasRenderer.nodeLayerDepth,
                          "a region must never occlude the cards it holds")
    }

    func test_visibleRegionsAreCulledToTheViewport() {
        var s = scene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("far"), label: "Far",
                                    frame: CGRect(x: 90_000, y: 0, width: 100, height: 100)))
        let visible = CanvasRenderer.visibleRegions(in: s, camera: CanvasCamera(),
                                                    viewSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(visible.map(\.id), [CanvasRegionID("r1")])
    }

    /// §4.2's accepted cost, paid in the renderer.
    func test_aMemberOutsideItsRegionGetsATether() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        s.move(CanvasNodeID("a"), to: CGPoint(x: 5000, y: 5000))
        let tethers = CanvasRenderer.tethers(in: s)
        XCTAssertEqual(tethers.count, 1,
                       "a node sitting outside the region that owns it must be "
                       + "drawn as related, or the writer cannot see why it moves")
        XCTAssertEqual(tethers.first?.node, CanvasNodeID("a"))
    }

    func test_aMemberInsideItsRegionGetsNoTether() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        XCTAssertTrue(CanvasRenderer.tethers(in: s).isEmpty)
    }

    /// §4.3: an appearance must NOT render identically to the thing itself.
    func test_appearancesRenderAsChipsNotAsCards() {
        var s = scene()
        CanvasMembership.addAppearance(CanvasNodeID("a"), to: CanvasRegionID("r1"), in: &s)
        let chips = CanvasRenderer.appearanceChips(in: s)
        XCTAssertEqual(chips.count, 1)
        XCTAssertEqual(chips.first?.node, CanvasNodeID("a"))
        XCTAssertEqual(chips.first?.region, CanvasRegionID("r1"))
        XCTAssertLessThan(chips.first!.frame.height, s.node(CanvasNodeID("a"))!.frame!.height,
                          "a chip must be visibly smaller than the card it references")
    }

    func test_aHomeMemberProducesNoChip() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        XCTAssertTrue(CanvasRenderer.appearanceChips(in: s).isEmpty)
    }

    func test_collapsedRegionHidesItsResidentsButKeepsThem() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        s.updateRegion(CanvasRegionID("r1")) { $0.isCollapsed = true }
        let drawn = CanvasRenderer.visibleNodes(in: s, camera: CanvasCamera(),
                                                viewSize: CGSize(width: 800, height: 600),
                                                hidingCollapsedResidentsOf: s)
        XCTAssertFalse(drawn.contains { $0.id == CanvasNodeID("a") })
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")),
                      "collapsing is a view state, never a membership change")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionRenderTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `type 'CanvasRenderer' has no member 'visibleRegions'`.

- [ ] **Step 3: Write the implementation**

Add to `CanvasRenderer`:

```swift
    /// Regions draw beneath nodes so a region never occludes the cards it holds.
    /// Expressed as constants rather than as draw order alone so the ordering is
    /// assertable.
    static let regionLayerDepth = 0
    static let nodeLayerDepth = 1

    static func visibleRegions(in scene: CanvasScene,
                               camera: CanvasCamera,
                               viewSize: CGSize) -> [CanvasRegion] {
        let viewport = camera.visibleContentRect(viewSize: viewSize)
        return scene.regions.filter { $0.frame.intersects(viewport) }
    }

    /// A resident that sits outside its own region's frame.
    ///
    /// This is §4.2's accepted cost, paid: membership is explicit, so a node CAN
    /// sit visually outside the region that owns it. The spec's answer is to
    /// draw the relationship rather than to correct the membership — without the
    /// tether, dragging the region would move a distant card for no visible
    /// reason.
    struct Tether: Equatable {
        let node: CanvasNodeID
        let region: CanvasRegionID
        let from: CGPoint
        let to: CGPoint
    }

    static func tethers(in scene: CanvasScene) -> [Tether] {
        scene.regions.flatMap { region -> [Tether] in
            region.homeMembers.compactMap { nodeID in
                guard let frame = scene.node(nodeID)?.frame,
                      !region.frame.contains(frame) else { return nil }
                return Tether(node: nodeID, region: region.id,
                              from: CGPoint(x: frame.midX, y: frame.midY),
                              to: CGPoint(x: region.frame.midX, y: region.frame.midY))
            }
        }
    }

    /// §4.3: an appearance must NOT render identically to the thing itself, or
    /// the copy problem returns visually and you cannot tell which is real. A
    /// chip carries the title at a fraction of the card's height, with a
    /// hairline to its home — so any region answers "which of these live here
    /// and which are visiting" at a glance.
    struct AppearanceChip: Equatable {
        let node: CanvasNodeID
        let region: CanvasRegionID
        let frame: CGRect
    }

    static let chipHeight: CGFloat = 22

    static func appearanceChips(in scene: CanvasScene) -> [AppearanceChip] {
        scene.regions.flatMap { region -> [AppearanceChip] in
            region.appearances.sorted { $0.raw < $1.raw }.enumerated().map { index, nodeID in
                AppearanceChip(
                    node: nodeID, region: region.id,
                    frame: CGRect(x: region.frame.minX + 10,
                                  y: region.frame.maxY - CGFloat(index + 1) * (chipHeight + 4) - 6,
                                  width: min(180, region.frame.width - 20),
                                  height: chipHeight))
            }
        }
    }

    /// Collapsing is a VIEW state (spec §7, §10). It hides residents; it never
    /// touches membership.
    static func visibleNodes(in scene: CanvasScene,
                             camera: CanvasCamera,
                             viewSize: CGSize,
                             hidingCollapsedResidentsOf collapseSource: CanvasScene) -> [CanvasNode] {
        let hidden = collapseSource.regions
            .filter(\.isCollapsed)
            .reduce(into: Set<CanvasNodeID>()) { $0.formUnion($1.homeMembers) }
        return visibleNodes(in: scene, camera: camera, viewSize: viewSize)
            .filter { !hidden.contains($0.id) }
    }
```

Then extend `draw(...)` to render, in order: regions (rounded rect, 8% fill of the region's own tint, 1pt stroke, label top-left), tethers (0.5pt hairline, 30% opacity), nodes, appearance chips.

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionRenderTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 7 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasRenderer.swift MaughamTests/Canvas/CanvasRegionRenderTests.swift
git commit -m "feat(canvas): draw regions, tethers for outside residents, chips for appearances"
```

---

### Task 5: Region gestures — draw, drag, drop-to-join

**Files:**
- Modify: `Maugham/Canvas/CanvasInteraction.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasRegionInteractionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasRegionInteractionTests: XCTestCase {

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for (i, id) in ["a", "b"].enumerated() {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                               origin: CGPoint(x: 100 + CGFloat(i) * 300, y: 100), width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        return s
    }

    /// §4.1: drag a region and its members travel. This is what makes
    /// reorganising one gesture rather than a marquee-select.
    func test_draggingARegionCarriesItsResidents() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        var i = CanvasInteraction()
        i.beginRegionDrag(CanvasRegionID("r1"), at: CGPoint(x: 300, y: 200), in: s)
        i.update(to: CGPoint(x: 400, y: 250), in: &s)

        XCTAssertEqual(s.region(CanvasRegionID("r1"))?.frame.origin, CGPoint(x: 100, y: 50))
        XCTAssertEqual(s.node(CanvasNodeID("a"))?.origin, CGPoint(x: 200, y: 150))
    }

    func test_draggingARegionLeavesVisitorsWhereTheyAre() {
        var s = scene()
        CanvasMembership.addAppearance(CanvasNodeID("b"), to: CanvasRegionID("r1"), in: &s)
        var i = CanvasInteraction()
        i.beginRegionDrag(CanvasRegionID("r1"), at: CGPoint(x: 300, y: 200), in: s)
        i.update(to: CGPoint(x: 400, y: 250), in: &s)
        XCTAssertEqual(s.node(CanvasNodeID("b"))?.origin, CGPoint(x: 400, y: 100),
                       "a visitor is not luggage")
    }

    func test_draggingARegionDoesNotChangeMembership() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        var i = CanvasInteraction()
        i.beginRegionDrag(CanvasRegionID("r1"), at: CGPoint(x: 300, y: 200), in: s)
        i.update(to: CGPoint(x: 4000, y: 4000), in: &s)
        i.end()
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")))
        XCTAssertFalse(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("b")))
    }

    /// The ONE gesture that changes membership: an explicit drop.
    func test_droppingANodeOntoARegionJoinsIt() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: s)          // grab node 'a'
        i.update(to: CGPoint(x: 310, y: 210), in: &s)        // drag inside r1
        i.endDrag(in: &s)                                    // explicit drop
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")))
    }

    func test_droppingANodeOnEmptyCanvasLeavesItsHomeAlone() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: s)
        i.update(to: CGPoint(x: 5000, y: 5000), in: &s)
        i.endDrag(in: &s)
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")),
                      "dragging a node out of a region's rect is NOT a remove — "
                      + "removal is its own explicit act (§4.2)")
    }

    func test_drawingARegionCreatesItWithNoMembers() {
        var s = scene()
        let id = CanvasInteraction.createRegion(
            from: CGPoint(x: 700, y: 500), to: CGPoint(x: 1000, y: 700), in: &s)
        let r = s.region(id)
        XCTAssertEqual(r?.frame, CGRect(x: 700, y: 500, width: 300, height: 200))
        XCTAssertTrue(r!.homeMembers.isEmpty,
                      "drawing a region over existing cards must not absorb them")
    }

    func test_drawingARegionNormalisesABackwardsDrag() {
        var s = scene()
        let id = CanvasInteraction.createRegion(
            from: CGPoint(x: 1000, y: 700), to: CGPoint(x: 700, y: 500), in: &s)
        XCTAssertEqual(s.region(id)?.frame, CGRect(x: 700, y: 500, width: 300, height: 200))
    }

    func test_aTinyRegionDragIsIgnoredRatherThanCreatingAConfetti() {
        var s = scene()
        let before = s.regions.count
        _ = CanvasInteraction.createRegion(from: CGPoint(x: 700, y: 500),
                                           to: CGPoint(x: 703, y: 502), in: &s)
        XCTAssertEqual(s.regions.count, before)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionInteractionTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — no `beginRegionDrag`.

- [ ] **Step 3: Write the implementation**

Extend `CanvasInteraction`:

```swift
    /// Smaller than this and the writer flicked rather than drew.
    static let minimumRegionSide: CGFloat = 40

    private enum Mode: Equatable {
        case idle
        case moving(CanvasNodeID, grabOffset: CGSize)
        case resizing(CanvasNodeID, startWidth: CGFloat, startX: CGFloat)
        /// Dragging a region carries its residents, so the start positions of
        /// everything travelling are captured up front — deriving them per
        /// frame from the region's current origin accumulates rounding.
        case movingRegion(CanvasRegionID,
                          grabOffset: CGSize,
                          travellers: [CanvasNodeID: CGPoint],
                          regionOrigin: CGPoint)
    }

    mutating func beginRegionDrag(_ id: CanvasRegionID,
                                  at contentPoint: CGPoint,
                                  in scene: CanvasScene) {
        guard let region = scene.region(id) else { mode = .idle; return }
        // Residents only (§4.1, §4.3).
        let travelling = CanvasMembership.nodesTravelling(withRegion: id, in: scene)
        let starts = travelling.reduce(into: [CanvasNodeID: CGPoint]()) { acc, nodeID in
            if let origin = scene.node(nodeID)?.origin { acc[nodeID] = origin }
        }
        mode = .movingRegion(id,
                             grabOffset: CGSize(width: contentPoint.x - region.frame.minX,
                                                height: contentPoint.y - region.frame.minY),
                             travellers: starts,
                             regionOrigin: region.frame.origin)
    }
```

In `update(to:in:)` add:

```swift
        case .movingRegion(let id, let grab, let travellers, let startOrigin):
            let newOrigin = CGPoint(x: contentPoint.x - grab.width,
                                    y: contentPoint.y - grab.height)
            let delta = CGSize(width: newOrigin.x - startOrigin.x,
                               height: newOrigin.y - startOrigin.y)
            guard var frame = scene.region(id)?.frame else { return }
            frame.origin = newOrigin
            // Geometry only. `setRegionFrame` deliberately does not touch
            // membership (§4.2).
            scene.setRegionFrame(frame, for: id)
            for (nodeID, start) in travellers {
                scene.move(nodeID, to: CGPoint(x: start.x + delta.width,
                                               y: start.y + delta.height))
            }
```

Add the drop:

```swift
    /// End a NODE drag. This is the one gesture that changes membership, and it
    /// is an explicit act by the writer: dropping a node onto a region adds it
    /// (§4.2). Dropping on empty canvas does NOT remove it from anywhere —
    /// removal is its own command, because a writer nudging a card should never
    /// silently lose a grouping.
    mutating func endDrag(in scene: inout CanvasScene) {
        defer { mode = .idle }
        guard case .moving(let nodeID, _) = mode,
              let origin = scene.node(nodeID)?.origin,
              let target = scene.region(at: origin) else { return }
        CanvasMembership.join(nodeID, home: target.id, in: &scene)
    }

    /// Draw a new region. It starts EMPTY even if it is drawn over existing
    /// cards: absorbing whatever happens to be underneath is the geometric
    /// membership rule §4.2 forbids, just spelled differently.
    @discardableResult
    static func createRegion(from a: CGPoint, to b: CGPoint,
                             in scene: inout CanvasScene) -> CanvasRegionID {
        let frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y))
        guard frame.width >= minimumRegionSide, frame.height >= minimumRegionSide else {
            return CanvasRegionID("")
        }
        var id = CanvasRegionID(UUID().uuidString.prefix(8).lowercased())
        while scene.region(id) != nil {
            id = CanvasRegionID(UUID().uuidString.prefix(8).lowercased())
        }
        scene.insertRegion(CanvasRegion(id: id, label: "", frame: frame))
        return id
    }
```

Note `createRegion` returns an empty id when the drag was too small; `test_aTinyRegionDragIsIgnored` asserts on the region count rather than the id, so this is fine, but `CanvasView` must not insert on an empty id.

Wire into `CanvasView`: a modifier-held drag on empty canvas draws a region; a plain drag on a region's chrome (its label bar) moves it; `endDrag` runs on mouse-up.

- [ ] **Step 4: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionInteractionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 8 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas MaughamTests/Canvas/CanvasRegionInteractionTests.swift
git commit -m "feat(canvas): region gestures — draw, drag-with-residents, explicit drop-to-join"
```

---

### Task 6: Region label and piece binding

**Files:**
- Create: `Maugham/Canvas/RegionInspector.swift`
- Modify: `Maugham/Views/ProjectWindow.swift` (`existingInspectorSwitch`'s `.canvas` arm)
- Test: `MaughamTests/Canvas/RegionBindingTests.swift`

CLAUDE.md rule 8: every new data type needs a UI surface for inspection and action. The region binding is the bridge from umbrella §8 and it must be visible and changeable, not MCP-only.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class RegionBindingTests: XCTestCase {

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for id in ["a", "b"] {
            var n = CanvasNode(id: CanvasNodeID(id), kind: .scrap, origin: .zero, width: 240)
            n.cachedHeight = 80
            s.insert(n)
        }
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        return s
    }

    func test_bindingARegionToAPieceExposesItsResidentsAsReferences() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        CanvasMembership.addAppearance(CanvasNodeID("b"), to: CanvasRegionID("r1"), in: &s)
        RegionBinding.bind(CanvasRegionID("r1"), toPiece: "piece-3", in: &s)

        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: s), [CanvasNodeID("a")],
                       "§4.4: only nodes that LIVE in the region are bound")
    }

    func test_unbindingKeepsMembershipIntact() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        RegionBinding.bind(CanvasRegionID("r1"), toPiece: "piece-3", in: &s)
        RegionBinding.unbind(CanvasRegionID("r1"), in: &s)
        XCTAssertNil(s.region(CanvasRegionID("r1"))?.boundPieceID)
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")))
        XCTAssertTrue(RegionBinding.references(forPiece: "piece-3", in: s).isEmpty)
    }

    func test_onePieceMayBeBoundByOnlyOneRegion() {
        var s = scene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r2"), label: "Other",
                                    frame: CGRect(x: 800, y: 0, width: 300, height: 200)))
        RegionBinding.bind(CanvasRegionID("r1"), toPiece: "piece-3", in: &s)
        RegionBinding.bind(CanvasRegionID("r2"), toPiece: "piece-3", in: &s)
        let bound = s.regions.filter { $0.boundPieceID == "piece-3" }
        XCTAssertEqual(bound.count, 1,
                       "two regions claiming one piece would give the compiler two "
                       + "different context sets for the same text")
        XCTAssertEqual(bound.first?.id, CanvasRegionID("r2"))
    }

    func test_aRegionBindsAtMostOnePiece() {
        var s = scene()
        RegionBinding.bind(CanvasRegionID("r1"), toPiece: "piece-3", in: &s)
        RegionBinding.bind(CanvasRegionID("r1"), toPiece: "piece-9", in: &s)
        XCTAssertEqual(s.region(CanvasRegionID("r1"))?.boundPieceID, "piece-9")
    }

    func test_deletingABoundRegionDropsTheBindingNotThePiece() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        RegionBinding.bind(CanvasRegionID("r1"), toPiece: "piece-3", in: &s)
        s.removeRegion(CanvasRegionID("r1"))
        XCTAssertTrue(RegionBinding.references(forPiece: "piece-3", in: s).isEmpty)
        XCTAssertNotNil(s.node(CanvasNodeID("a")))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/RegionBindingTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'RegionBinding' in scope`.

- [ ] **Step 3: Write the binding rules**

```swift
import Foundation

/// Region → piece binding. This is the bridge from umbrella §8: what you
/// cluster around a piece on the canvas becomes what is pinned beside you when
/// you write it, and what the compiler reads as context. No separate curation
/// step — the spatial work done in planning pays off directly.
enum RegionBinding {

    /// Bind a region to a piece.
    ///
    /// A piece may be claimed by at most ONE region. Two regions claiming one
    /// piece would hand the authoring compiler two different context sets for
    /// the same text, and there would be no principled way to choose. Last
    /// binding wins, and the previous claimant is released.
    static func bind(_ region: CanvasRegionID, toPiece piece: String, in scene: inout CanvasScene) {
        for r in scene.regions where r.id != region && r.boundPieceID == piece {
            scene.updateRegion(r.id) { $0.boundPieceID = nil }
        }
        scene.updateRegion(region) { $0.boundPieceID = piece }
    }

    static func unbind(_ region: CanvasRegionID, in scene: inout CanvasScene) {
        scene.updateRegion(region) { $0.boundPieceID = nil }
    }

    /// What a piece's region contributes as pinned references.
    ///
    /// HOME MEMBERS ONLY (spec §4.4). Visitors are not bound, or two regions
    /// sharing a card would each claim it.
    static func references(forPiece piece: String, in scene: CanvasScene) -> Set<CanvasNodeID> {
        scene.regions.first { $0.boundPieceID == piece }?.boundNodes ?? []
    }

    static func boundPiece(of region: CanvasRegionID, in scene: CanvasScene) -> String? {
        scene.region(region)?.boundPieceID
    }
}
```

- [ ] **Step 4: Write the inspector surface**

`Maugham/Canvas/RegionInspector.swift` — a `View` showing, for the selected region: an editable label `TextField`, a picker binding it to a piece (populated from the project's manifest, with a "None" entry), and two lists — *Lives here* and *Appears here* — each row with a remove button. The two lists are the UI answer to §4.3's "any region should answer 'which of these live here and which are visiting' at a glance", and the remove buttons are the explicit removal act §4.2 requires.

Inline rename follows tripwire 16: `Task.sleep(30ms)` deferral plus **both** `.onAppear` and `.onChange(of:)` triggers. `BinderRow.claimFocus()` is the canonical implementation — mirror it, do not invent a new one.

Wire into `ProjectWindow.existingInspectorSwitch`'s `.canvas` arm, replacing 1C-a's placeholder. Keep the full-frame chain on any `ContentUnavailableView` (tripwire 15):

```swift
        case .canvas:
            if let region = selectedCanvasRegion {
                RegionInspector(region: region, store: store)
            } else {
                ContentUnavailableView("Select a region", systemImage: "square.on.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
```

- [ ] **Step 5: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/RegionBindingTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 5 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/RegionInspector.swift Maugham/Views/ProjectWindow.swift MaughamTests/Canvas/RegionBindingTests.swift project.yml
git commit -m "feat(canvas): region label, piece binding, and a lives-here/visiting inspector"
```

---

### Task 7: Docs

**Files:**
- Modify: `Maugham/Canvas/AREA.md`
- Modify: `docs/adr/0026-planning-canvas-rendering.md` (or a new ADR if the reviewer prefers one per concern)
- Modify: `docs/guide/`, `docs/roadmap.md`, `docs/problem-map.md`

- [ ] **Step 1: Extend AREA.md**

Add a "Membership" section covering: explicit-only, the three tools that got it wrong and how, the one-home invariant and where it is enforced (both `CanvasMembership.join` and the codec's loader), what travels on a region drag, and the rule that removal is always its own act.

State plainly: **if you are about to write `region.frame.contains(node.origin)` near membership, you are reintroducing the bug class this design exists to eliminate.**

- [ ] **Step 2: Add the tripwire**

| # | Rule | Why | Enforced |
|---|---|---|---|
| 27 | Canvas membership is never derived from geometry — not on move, not on resize, not on region creation | Obsidian, tldraw (#6017) and Scapple each ship a distinct bug from the geometry→membership transition rule; tldraw's persists *despite* explicit storage | `CanvasMembershipTests` (firewall tests were falsified by introducing the tldraw ejection bug) |

- [ ] **Step 3: Sweep the guide**

The guide's persona section now needs regions. Describe only what ships (rule 7): drawing a region, dropping a node in, the difference between living in and appearing in, and binding a region to a piece. Do not describe promotion — that is 1C-c.

- [ ] **Step 4: Full verification**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: full Mac suite green.

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: green.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/AREA.md docs/
git commit -m "docs(canvas): membership rules, geometry tripwire, guide sweep for regions"
```

---

## Whole-slice verification

- [ ] Full Mac suite, full phone suite, Release build — all green
- [ ] **Whole-branch review** of the 1C-b diff
- [ ] Smoke: draw a region over two existing cards → confirm it absorbed neither → drag one in → drag the region → the resident travels, the other card does not → resize the region to nothing → the resident is still a member → drag the resident far outside → a tether draws → cite a second card as an appearance → it renders as a chip, visibly not a card → bind the region to a piece → quit and reopen → everything survives

**Do not push or tag.**
