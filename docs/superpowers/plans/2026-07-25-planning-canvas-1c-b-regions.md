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

### What this slice does NOT do

- **§4.4's binding is produced here and consumed in 1A.** `RegionBinding.references(forPiece:)` feeds the pinned references beside the editor in the Author persona (umbrella §8). The Author persona's reference rail is **1A's** work and 1A is unwritten. Producing a value nothing reads yet is deliberate, not an oversight: the binding is the durable half of the bridge and it has to exist before the consumer can be built. Task 7 gives it a UI surface, so it is inspectable and changeable today — CLAUDE.md rule 8 is satisfied by the inspector, not by a consumer.
- **No MCP surface.** Spec §8A.2's Claude-writes-to-canvas route is not in this slice.
- **No promotion.** Promoting a region to a palette card is 1C-c.

### Build and process constraints

- `./gen.sh` after adding ANY new file — `Maugham.xcodeproj/` is generated from `project.yml`. **Never commit anything under `Maugham.xcodeproj/`**; a `project.pbxproj` in a diff is a red flag.
- Run `xcodebuild` in the **foreground**.
- `-only-testing` takes `MaughamTests/<ClassName>` — **never a folder path**. A folder path silently runs zero tests (translation-layer milestone lesson).
- **Release build after anything touching a view.** The Release type-check budget is stricter than Debug; v0.8.0 shipped a Release-only failure that passed Debug.
- **No raw `NotificationCenter` post or subscription** — every `maugham.*` event goes through `MaughamEvent` with a declared scope (tripwire 21, ADR 0021). This slice adds no events; do not add one.
- Tests that cross the `.md` ↔ op-log boundary need alphabet-restricted paragraph ids (tripwire 8). This slice touches neither, so it does not apply — noted so you don't go looking.

### `ProjectWindow.body` has a ZERO expression budget

`ProjectWindow.body` is at 28 chained expressions. Eleven extracted `ViewModifier`s exist **solely** to buy expressions back, and the ceiling has been hit twice — once passing Debug and failing Release CI.

So, precisely:

- **Adding a `@State` property is free** — a stored property is not a body expression. Task 4 adds exactly one.
- **`existingEditorSwitch(store:documentStore:)` and `existingInspectorSwitch(store:)` are separate `@ViewBuilder` methods** and are type-checked separately from `body`. Their `.canvas` arms may grow, within reason: keep each arm to a **single expression**, extracting a helper method if it needs more (Task 7 does exactly this).
- **Do not add a line to `body` itself**, and that includes `body`'s `.onDisappear` scorch block. The canvas flushes and empties itself in `CanvasView.onDisappear`.
- Every task that touches `Maugham/Views/ProjectWindow.swift` runs a **Release build** before it commits.

### Peer files from 1C-a you may assume exist

`Maugham/Canvas/CanvasInteraction.swift` is a real file containing `struct CanvasInteraction` (1C-a Task 11 commits to the peer file). `Maugham/Canvas/CanvasEventView.swift` contains `struct CanvasEventView` and `final class CanvasEventNSView`. `Maugham/Canvas/CanvasView.swift` contains `struct CanvasView`. If any is missing, 1C-a is not merged and this slice cannot start.

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
| `Maugham/Canvas/CanvasModel.swift` | The one owner of scene + scraps + selection + undo + the store. The seam between `CanvasView` and `RegionInspector`. |
| `Maugham/Canvas/RegionBinding.swift` | Region → piece binding rules |
| `Maugham/Canvas/RegionInspector.swift` | Label, collapse, piece binding, lives-here/appears-here lists |
| `Maugham/Canvas/CanvasScene.swift` | *Modify* — regions join the scene |
| `Maugham/Canvas/CanvasSceneCodec.swift` | *Modify* — `CanvasSceneDTO` schema 1 → 2 |
| `Maugham/Canvas/CanvasRenderer.swift` | *Modify* — draw regions beneath nodes; tethers; appearance chips |
| `Maugham/Canvas/CanvasInteraction.swift` | *Modify* — region drag carries residents; resize; drop-onto-region joins |
| `Maugham/Canvas/CanvasEventView.swift` | *Modify* — a delete-key callback |
| `Maugham/Canvas/CanvasView.swift` | *Modify* — reads the model instead of owning the scene; routes region gestures |
| `Maugham/Views/ProjectWindow.swift` | *Modify* — owns the `CanvasModel`; the `.canvas` inspector arm |

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
- Produces: `enum CanvasMembership` with `static func join(_ node:home:in:)`, `static func addAppearance(_ node:to:in:)`, `static func leave(_ node:from:in:)`, `static func homeRegion(of:in:) -> CanvasRegionID?`, `static func appearanceRegions(of:in:) -> [CanvasRegionID]`, `static func nodesTravelling(withRegion:in:) -> Set<CanvasNodeID>`; and `CanvasScene.regions`, `region(_:)`, `region(at:)`, `insertRegion(_:)`, `removeRegion(_:)`, `updateRegion(_:_:)`, `setRegionFrame(_:for:)`.

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

    /// Topmost region whose frame contains `point`. Used for region CHROME
    /// hit-testing only (the label bar and the resize handle) — never for
    /// membership.
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

`CanvasScene`'s `Equatable` conformance is synthesised over all stored properties, so adding `regionsByID` extends it with no further work.

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

**Interfaces:**
- Consumes: `CanvasRegion`, `CanvasRegionID`, `CanvasScene.insertRegion(_:)` (Tasks 1–2); `CanvasStore` (1C-a Task 5) with `init(projectRoot: URL)`, `func load() -> (scene: CanvasScene, scraps: [CanvasNodeID: String])`, `func save(scene:scraps:)`.
- Modifies: `struct CanvasSceneDTO` in `Maugham/Canvas/CanvasSceneCodec.swift` — `static let currentSchemaVersion` 1 → 2, a new optional `regions: [RegionDTO]?` property, a nested `RegionDTO`, region encoding in `init(scene:)` and region decoding in `var scene: CanvasScene`.
- Produces: no new top-level types. `CanvasSceneDTO.RegionDTO` is nested inside `CanvasSceneDTO`.

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

In `Maugham/Canvas/CanvasSceneCodec.swift`, inside `struct CanvasSceneDTO` (the file's only top-level type):

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

In `CanvasSceneDTO`'s `scene` computed property, after nodes are built:

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

and mirror it in `CanvasSceneDTO.init(scene:)`.

- [ ] **Step 4: Run the tests**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionCodecTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 4 tests. Also re-run `MaughamTests/CanvasStoreTests` — the v1 tests must still pass.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Canvas/CanvasSceneCodec.swift MaughamTests/Canvas/CanvasRegionCodecTests.swift
git commit -m "feat(canvas): persist regions, sidecar schema 1→2, loader enforces one-home invariant"
```

---

### Task 4: `CanvasModel` — the one owner of scene, selection and undo

**Files:**
- Create: `Maugham/Canvas/CanvasModel.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`
- Test: `MaughamTests/Canvas/CanvasModelTests.swift`

**Interfaces:**
- Consumes: `CanvasScene`, `CanvasRegion`, `CanvasRegionID`, `CanvasNodeID`, `CanvasMembership` (Tasks 1–2); `CanvasStore` (1C-a Task 5) with `init(projectRoot: URL)`, `load() -> (scene: CanvasScene, scraps: [CanvasNodeID: String])`, `scheduleSave(scene:scraps:)`, `flush()`; `CanvasCamera`, `ScrapLayout`, `CanvasRenderer`, `CanvasEventView`, `ScrapEditorHost`, `CanvasGround`, `CanvasGroundPalette` (1C-a); `CanvasUndo` (1C-a Task 13) with `init(undoManager: UndoManager)`, `beginGesture(_:)`, `endGesture()`; `ProjectStore.url` (the project root — `Maugham/Stores/ProjectStore.swift:68`) and `ProjectStore.paletteSwatchHexes() -> [String]` (added by 1C-a Task 10).
- Produces: `@Observable final class CanvasModel` with `private(set) var scene: CanvasScene`, `private(set) var scraps: [CanvasNodeID: String]`, `var selectedRegionID: CanvasRegionID?`, `let undoManager: UndoManager`, `func load(projectRoot: URL)`, `func flush()`, `func withScene(persist:_:)`, `func setScrapText(_:for:)`, `func beginGesture(_:)`, `func endGesture()`, `func mutate(_:_:)`, `func deleteSelectedRegion()`.
- Changes `CanvasView`'s initialiser to `CanvasView(model: CanvasModel, projectRoot: URL, paletteSwatchHexes: [String])`.

**Why this task exists.** Three surfaces need the same scene: the drawn canvas, the region gestures, and the inspector in the right-hand column. In 1C-a the scene is `@State` inside `CanvasView`, which means nothing outside that view can see it or change it — an inspector handed a `ProjectStore` could not edit a region label, because region labels do not live in the manifest. So the scene, the scrap text, the selection, the sidecar store and the undo manager move to **one reference type owned by `ProjectWindow`** and passed to both views. Camera, layouts, `editingNodeID` and `caretIndex` stay in `CanvasView`: they are properties of one view of the canvas, and the inspector has no business with them.

**Undo is snapshot-based here**, and shares `CanvasUndo`'s `UndoManager` instance so ⌘Z runs in chronological order across scrap text, scrap geometry and regions. A region drag mutates a region frame *and* every resident's origin; recording per-property inverses for that is how you get a half-undone drag. One snapshot per gesture is smaller, exactly correct, and cheap — `CanvasScene` is a value type and the scenes in play are hundreds of nodes, not millions.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasModelTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func loadedModel() -> CanvasModel {
        let model = CanvasModel()
        model.load(projectRoot: root)
        model.withScene { s in
            var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap,
                               origin: CGPoint(x: 100, y: 100), width: 240)
            n.cachedHeight = 80
            s.insert(n)
            s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        }
        return model
    }

    /// The seam, asserted end to end: an edit made through the model — which is
    /// the ONLY thing the inspector holds — lands in the sidecar on disk.
    func test_aRegionEditThroughTheModelReachesDisk() {
        let model = loadedModel()
        model.mutate("Rename Region") {
            $0.updateRegion(CanvasRegionID("r1")) { $0.label = "Falls" }
        }
        model.flush()

        let onDisk = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(onDisk.region(CanvasRegionID("r1"))?.label, "Falls",
                       "the inspector holds only the model, so the model must be "
                       + "the whole path from an edit to the sidecar")
    }

    /// Selection is model state, not view state — that is what lets the canvas
    /// and the inspector agree about which region is selected.
    func test_selectionIsModelStateSoTwoReadersSeeOneValue() {
        let model = loadedModel()
        model.selectedRegionID = CanvasRegionID("r1")
        XCTAssertEqual(model.selectedRegionID, CanvasRegionID("r1"))
        XCTAssertEqual(model.selectedRegion?.displayLabel, "Act II fog")
    }

    func test_undoRestoresTheSceneAfterAModelMutation() {
        let model = loadedModel()
        model.mutate("Rename Region") {
            $0.updateRegion(CanvasRegionID("r1")) { $0.label = "Falls" }
        }
        model.undoManager.undo()
        XCTAssertEqual(model.scene.region(CanvasRegionID("r1"))?.label, "Act II fog")
    }

    func test_redoReappliesTheMutation() {
        let model = loadedModel()
        model.mutate("Rename Region") {
            $0.updateRegion(CanvasRegionID("r1")) { $0.label = "Falls" }
        }
        model.undoManager.undo()
        model.undoManager.redo()
        XCTAssertEqual(model.scene.region(CanvasRegionID("r1"))?.label, "Falls")
    }

    /// A drag emits a frame per tick. One ⌘Z must undo the whole gesture.
    func test_oneGestureIsOneUndoStep() {
        let model = loadedModel()
        model.beginGesture("Move Region")
        for x in stride(from: CGFloat(0), through: 500, by: 10) {
            model.withScene { $0.setRegionFrame(CGRect(x: x, y: 0, width: 600, height: 400),
                                                for: CanvasRegionID("r1")) }
        }
        model.endGesture()

        model.undoManager.undo()
        XCTAssertEqual(model.scene.region(CanvasRegionID("r1"))?.frame.origin, .zero)
        XCTAssertFalse(model.undoManager.canUndo, "the whole gesture collapses into one step")
    }

    func test_undoActionNamesAreWriterFacing() {
        let model = loadedModel()
        model.mutate("Move Region") {
            $0.setRegionFrame(CGRect(x: 5, y: 5, width: 10, height: 10), for: CanvasRegionID("r1"))
        }
        XCTAssertEqual(model.undoManager.undoActionName, "Move Region")
    }

    /// A drag that starts and ends on the same pixel must not leave a step
    /// behind — otherwise ⌘Z after a stray click undoes the writer's last
    /// REAL edit while appearing to do nothing.
    func test_aGestureThatChangesNothingPushesNoUndoStep() {
        let model = loadedModel()
        model.beginGesture("Move Region")
        model.endGesture()
        XCTAssertFalse(model.undoManager.canUndo)
    }

    /// Measuring a scrap's height is bookkeeping, not an edit.
    func test_nonPersistingSceneWorkStaysOffTheUndoStack() {
        let model = loadedModel()
        model.withScene(persist: false) { $0.setCachedHeight(140, for: CanvasNodeID("a")) }
        XCTAssertFalse(model.undoManager.canUndo)
        XCTAssertEqual(model.scene.node(CanvasNodeID("a"))?.cachedHeight, 140)
    }

    func test_deletingTheSelectedRegionClearsTheSelectionKeepsTheNodesAndUndoes() {
        let model = loadedModel()
        model.mutate("Join Region") {
            CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &$0)
        }
        model.selectedRegionID = CanvasRegionID("r1")
        model.deleteSelectedRegion()

        XCTAssertNil(model.selectedRegionID)
        XCTAssertTrue(model.scene.regions.isEmpty)
        XCTAssertNotNil(model.scene.node(CanvasNodeID("a")),
                        "deleting a region must never delete nodes (§4.2)")

        model.undoManager.undo()
        XCTAssertEqual(model.scene.regions.count, 1)
        XCTAssertTrue(model.scene.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")),
                      "undo restores the membership, not just the rectangle")
    }

    /// Re-entering the Plan persona re-runs `.onAppear`. Reloading from disk
    /// there would throw away anything the debounce has not written yet.
    func test_loadingTheSameRootTwiceDoesNotClobberLiveState() {
        let model = loadedModel()
        model.load(projectRoot: root)
        XCTAssertEqual(model.scene.regions.count, 1)
        XCTAssertNotNil(model.scene.node(CanvasNodeID("a")))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasModelTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasModel' in scope`.

- [ ] **Step 3: Write the model**

`Maugham/Canvas/CanvasModel.swift`:

```swift
import Foundation
import Observation

/// The canvas's single owner of mutable state.
///
/// `CanvasView` draws it and `RegionInspector` edits it, and they are in
/// different columns of `ProjectWindow` — so the state cannot live in either
/// one's `@State`. `ProjectWindow` owns exactly one of these and hands the same
/// reference to both.
///
/// What lives here: the scene (nodes AND regions), the scrap text, the region
/// selection, the sidecar store, and the undo stack. What deliberately does
/// NOT: the camera, the `ScrapLayout` cache, `editingNodeID` and `caretIndex` —
/// those are properties of ONE view of the canvas, and the inspector has no
/// business with them.
///
/// Mutation goes through exactly one door (`withScene`), so persistence and
/// undo cannot be forgotten at a call site. `scene` is `private(set)` to keep
/// that door the only one.
@Observable
final class CanvasModel {

    private(set) var scene = CanvasScene()
    private(set) var scraps: [CanvasNodeID: String] = [:]

    /// The selected region, or nil. Model state rather than view state because
    /// the canvas draws the selection ring and the inspector edits the thing
    /// selected — two readers, one value.
    var selectedRegionID: CanvasRegionID?

    var selectedRegion: CanvasRegion? {
        selectedRegionID.flatMap { scene.region($0) }
    }

    /// ONE manager for the whole canvas. `CanvasView` builds its `CanvasUndo`
    /// (1C-a Task 13) over this same instance, so ⌘Z walks scrap text, scrap
    /// geometry and region edits in the order they actually happened. Two
    /// managers would give the writer two half-histories.
    let undoManager = UndoManager()

    private var store: CanvasStore?
    /// Keyed on the project PATH, not on an id — tripwire 22's shape: an
    /// id-keyed reload survives a rename and shows stale content.
    private var loadedRoot: URL?
    private var gestureSnapshot: Snapshot?
    private var gestureName: String?

    private struct Snapshot: Equatable {
        var scene: CanvasScene
        var scraps: [CanvasNodeID: String]
    }

    // MARK: - Lifecycle

    /// Load once per project root. `.onAppear` fires again every time the
    /// writer re-enters the Plan persona, and reloading there would discard
    /// whatever the 750 ms debounce has not yet written.
    func load(projectRoot: URL) {
        guard loadedRoot != projectRoot else { return }
        let s = CanvasStore(projectRoot: projectRoot)
        let loaded = s.load()
        store = s
        loadedRoot = projectRoot
        scene = loaded.scene
        scraps = loaded.scraps
    }

    /// Write any debounced save now. `CanvasView.onDisappear` calls this — the
    /// canvas cleans up after itself rather than adding a line to
    /// `ProjectWindow.body`'s scorch block, which has no expression budget.
    func flush() { store?.flush(scene: scene, scraps: scraps) }

    // MARK: - Mutation

    /// The one door. `persist: false` is for derived bookkeeping — measured
    /// heights — which must neither hit the disk nor enter the undo stack.
    func withScene(persist: Bool = true, _ mutate: (inout CanvasScene) -> Void) {
        mutate(&scene)
        if persist { store?.scheduleSave(scene: scene, scraps: scraps) }
    }

    func setScrapText(_ text: String, for id: CanvasNodeID) {
        scraps[id] = text
        store?.scheduleSave(scene: scene, scraps: scraps)
    }

    // MARK: - Undo

    /// Open a gesture. A drag emits a frame per tick; the snapshot is taken
    /// once here and the inverse registered once in `endGesture`, so ⌘Z undoes
    /// the gesture rather than one tick of it.
    func beginGesture(_ name: String) {
        guard gestureSnapshot == nil else { return }
        gestureSnapshot = Snapshot(scene: scene, scraps: scraps)
        gestureName = name
    }

    func endGesture() {
        guard let before = gestureSnapshot, let name = gestureName else { return }
        gestureSnapshot = nil
        gestureName = nil
        // A click that moved nothing must not push a step: ⌘Z after a stray
        // click would otherwise appear to do nothing while eating the writer's
        // previous real edit.
        guard before != Snapshot(scene: scene, scraps: scraps) else { return }
        register(undoTo: before, name: name)
        store?.scheduleSave(scene: scene, scraps: scraps)
    }

    /// One-shot edit: a gesture with no dragging in the middle.
    func mutate(_ name: String, _ body: (inout CanvasScene) -> Void) {
        beginGesture(name)
        withScene(body)
        endGesture()
    }

    private func register(undoTo snapshot: Snapshot, name: String) {
        undoManager.registerUndo(withTarget: self) { model in
            model.restore(snapshot, name: name)
        }
        undoManager.setActionName(name)
    }

    /// Applying a snapshot registers its own inverse, which is what makes redo
    /// fall out for free: `UndoManager` routes a registration made while
    /// undoing onto the redo stack.
    private func restore(_ snapshot: Snapshot, name: String) {
        let inverse = Snapshot(scene: scene, scraps: scraps)
        scene = snapshot.scene
        scraps = snapshot.scraps
        register(undoTo: inverse, name: name)
        store?.scheduleSave(scene: scene, scraps: scraps)
    }

    // MARK: - Region commands

    /// Delete the selected region. Its members are ORPHANED, never deleted
    /// (§4.2) — `CanvasScene.removeRegion` is where that is enforced.
    func deleteSelectedRegion() {
        guard let id = selectedRegionID else { return }
        mutate("Delete Region") { $0.removeRegion(id) }
        selectedRegionID = nil
    }
}
```

- [ ] **Step 4: Move `CanvasView` onto the model**

`CanvasView` keeps the camera, the layout cache and the editing focus; it gives up the scene, the scraps and the store. Apply exactly this rule to the file 1C-a left behind: **`scene`, `scraps` and `store` stop being `@State` and become reads of `model`; `camera`, `layouts`, `editingNodeID` and `caretIndex` stay `@State`.**

Replace the property block and the three methods that touched the moved state:

```swift
struct CanvasView: View {
    /// Owned by `ProjectWindow` and shared with `RegionInspector` — see
    /// `CanvasModel`. Not `@State`: this view is one of two readers.
    let model: CanvasModel
    let projectRoot: URL
    let paletteSwatchHexes: [String]

    @State private var camera = CanvasCamera()
    @State private var layouts: [CanvasNodeID: ScrapLayout] = [:]
    @State private var editingNodeID: CanvasNodeID?
    @State private var caretIndex: Int?
    @State private var interaction = CanvasInteraction()

    private let scrapFont = NSFont(name: "Iowan Old Style", size: 13)
        ?? .systemFont(ofSize: 13)
```

In `body`, the `Canvas` draw call reads the model (Task 5 amends its argument list), the editor host reads `model.scene`, and the lifecycle hooks become:

```swift
            .onAppear { model.load(projectRoot: projectRoot) ; rebuildLayouts() }
            .onDisappear { model.flush() }
```

`load(viewSize:)` from 1C-a is replaced by that one line — the store lives in the model now. `rebuildLayouts` and `handleClick` become:

```swift
    /// Build a layout per scrap and fill in the derived heights the model needs
    /// for hit testing and culling. Measurement is bookkeeping, so it goes
    /// through `persist: false` — it must not schedule a write or land on the
    /// undo stack.
    private func rebuildLayouts() {
        var built: [CanvasNodeID: ScrapLayout] = [:]
        for node in model.scene.nodes {
            guard case .scrap = node.kind else { continue }
            built[node.id] = ScrapLayout(text: model.scraps[node.id] ?? "",
                                         width: node.width, font: scrapFont)
        }
        layouts = built
        model.withScene(persist: false) { scene in
            for (id, layout) in built { scene.setCachedHeight(layout.measuredHeight, for: id) }
        }
    }

    private func handleClick(at contentPoint: CGPoint) {
        // Commit any in-flight edit before moving focus, so the drawn text the
        // renderer picks up is current.
        if let editing = editingNodeID, let layout = layouts[editing] {
            model.setScrapText(layout.text, for: editing)
            model.withScene(persist: false) {
                $0.setCachedHeight(layout.measuredHeight, for: editing)
            }
        }

        guard let node = model.scene.topmostNode(at: contentPoint),
              case .scrap = node.kind,
              let layout = layouts[node.id],
              let frame = node.frame else {
            editingNodeID = nil
            caretIndex = nil
            // A click on empty canvas clears the region selection; a click on
            // a region's chrome sets it (Task 6).
            model.selectedRegionID = nil
            return
        }

        editingNodeID = node.id
        caretIndex = layout.characterIndex(
            at: CGPoint(x: contentPoint.x - frame.minX, y: contentPoint.y - frame.minY))
    }
```

Finally, `CanvasUndo` must be built over the model's manager, not a private one:

```swift
    private var undo: CanvasUndo { CanvasUndo(undoManager: model.undoManager) }
```

**Do not** leave a second `UndoManager` anywhere in the canvas. Two stacks means ⌘Z shows the writer two half-histories.

- [ ] **Step 5: Give `ProjectWindow` the model**

One stored property beside the existing `@State` block (a stored property is not a body expression — see Global Constraints):

```swift
    /// The Plan persona's canvas state. Owned here because two columns read it:
    /// `CanvasView` in the centre and `RegionInspector` in the detail column.
    @State private var canvas = CanvasModel()
```

And the `.canvas` arm of `existingEditorSwitch` — still one expression — becomes:

```swift
        case .canvas:
            CanvasView(model: canvas,
                       projectRoot: store.url,
                       paletteSwatchHexes: store.paletteSwatchHexes())
```

`ProjectStore.url` is the project root (`ProjectStore.swift:68`). Leave the `.canvas` inspector arm as 1C-a's placeholder for now — Task 7 replaces it.

- [ ] **Step 6: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasModelTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 10 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasUndoTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — 1C-a's undo tests are untouched by this refactor.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. **A Debug pass is not evidence** — this task touches `ProjectWindow.swift`.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasModel.swift Maugham/Canvas/CanvasView.swift Maugham/Views/ProjectWindow.swift MaughamTests/Canvas/CanvasModelTests.swift project.yml
git commit -m "feat(canvas): CanvasModel owns scene, selection and undo

The canvas is drawn in the centre column and edited in the detail
column, so its state cannot live in either view's @State. ProjectWindow
owns one CanvasModel and hands the same reference to both. Undo is
snapshot-per-gesture over the same UndoManager CanvasUndo uses."
```

---

### Task 5: Draw regions, tethers and appearance chips

**Files:**
- Modify: `Maugham/Canvas/CanvasRenderer.swift`
- Modify: `Maugham/Canvas/CanvasView.swift` (the one `CanvasRenderer.draw` call site)
- Test: `MaughamTests/Canvas/CanvasRegionRenderTests.swift`

**Interfaces:**
- Consumes: `CanvasScene`, `CanvasRegion`, `CanvasRegionID`, `CanvasMembership` (Tasks 1–2); `CanvasModel` (Task 4); `CanvasCamera` (1C-a Task 4) with `pan: CGPoint`, `zoom: CGFloat`, `visibleContentRect(viewSize:) -> CGRect`; `CanvasRenderer` (1C-a Task 7) — an `enum` with `static func seededRotation(for:) -> Angle`, `static func visibleNodes(in:camera:viewSize:) -> [CanvasNode]`, `static func draw(scene:camera:viewSize:layouts:editingNodeID:into:)` and `private static func drawCard(...)`; `ScrapLayout` (1C-a Task 3); `CanvasItemPresentation` (1C-a Task 12 — the per-item title/glyph the view resolves from the project store; it carries a `title`).
- Produces on `CanvasRenderer`: `static let regionLayerDepth/nodeLayerDepth`, `static func visibleRegions(in:camera:viewSize:)`, `struct Tether`, `static func tethers(in:)`, `struct AppearanceChip` (`node`, `region`, `homeRegion`, `frame`), `static let chipHeight`, `static func appearanceChips(in:)`, `static func homeAnchor(of:in:)`, `static func chipTitle(for:scraps:presentations:)`, `static func regionStroke(isSelected:)`, and `static func visibleNodes(in:camera:viewSize:hidingCollapsedResidents:)`.
- Amends `CanvasRenderer.draw` to `draw(scene:camera:viewSize:layouts:presentations:scraps:selectedRegionID:editingNodeID:into:)`.

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

    /// A card straddling the boundary is still visibly IN the region. Tethering
    /// on non-containment would fire a full line to the region's centre for one
    /// pixel of overhang — the same one-pixel absurdity the design cites against
    /// Obsidian, inverted. Tether only when the frames do not meet at all.
    func test_aMemberStraddlingTheEdgeGetsNoTether() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        s.move(CanvasNodeID("a"), to: CGPoint(x: 599, y: 100))
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

    /// §4.3's "a hairline to its home". The chip has to know where home IS.
    func test_aChipKnowsTheRegionItsSubjectLivesIn() {
        var s = scene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r2"), label: "Falls",
                                    frame: CGRect(x: 800, y: 0, width: 400, height: 300)))
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r2"), in: &s)
        CanvasMembership.addAppearance(CanvasNodeID("a"), to: CanvasRegionID("r1"), in: &s)
        let chip = CanvasRenderer.appearanceChips(in: s).first { $0.region == CanvasRegionID("r1") }
        XCTAssertEqual(chip?.homeRegion, CanvasRegionID("r2"))
        XCTAssertEqual(CanvasRenderer.homeAnchor(of: chip!, in: s), CGPoint(x: 1000, y: 150))
    }

    /// A loose node — cited by a region, living nowhere — has no home region,
    /// so the hairline goes to the card itself.
    func test_aChipForALooseNodeAnchorsOnTheCard() {
        var s = scene()
        CanvasMembership.addAppearance(CanvasNodeID("a"), to: CanvasRegionID("r1"), in: &s)
        let chip = CanvasRenderer.appearanceChips(in: s).first!
        XCTAssertNil(chip.homeRegion)
        XCTAssertEqual(CanvasRenderer.homeAnchor(of: chip, in: s), CGPoint(x: 170, y: 90))
    }

    func test_aHomeMemberProducesNoChip() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        XCTAssertTrue(CanvasRenderer.appearanceChips(in: s).isEmpty)
    }

    func test_aChipTitleForAScrapIsItsFirstLine() {
        let title = CanvasRenderer.chipTitle(
            for: CanvasNodeID("a"),
            scraps: [CanvasNodeID("a"): "The falls at night.\nSodium light on the spray."],
            presentations: [:])
        XCTAssertEqual(title, "The falls at night.")
    }

    func test_anEmptyScrapStillGetsAReadableChipTitle() {
        XCTAssertEqual(CanvasRenderer.chipTitle(for: CanvasNodeID("a"),
                                                scraps: [CanvasNodeID("a"): "   "],
                                                presentations: [:]),
                       "Untitled")
    }

    func test_aChipTitleForAnItemComesFromItsPresentation() {
        let id = CanvasNodeID.item("r-9")
        let title = CanvasRenderer.chipTitle(
            for: id, scraps: [:],
            presentations: [id: CanvasItemPresentation(title: "Street photo",
                                                       symbolName: "photo")])
        XCTAssertEqual(title, "Street photo")
    }

    func test_collapsedRegionHidesItsResidentsButKeepsThem() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        s.updateRegion(CanvasRegionID("r1")) { $0.isCollapsed = true }
        let drawn = CanvasRenderer.visibleNodes(in: s, camera: CanvasCamera(),
                                                viewSize: CGSize(width: 800, height: 600),
                                                hidingCollapsedResidents: true)
        XCTAssertFalse(drawn.contains { $0.id == CanvasNodeID("a") })
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")),
                      "collapsing is a view state, never a membership change")
    }

    func test_aSelectedRegionStrokesHeavierThanAnUnselectedOne() {
        XCTAssertGreaterThan(CanvasRenderer.regionStroke(isSelected: true).width,
                             CanvasRenderer.regionStroke(isSelected: false).width)
    }
}
```

`CanvasItemPresentation` comes from 1C-a Task 12 and carries a `title`. If its memberwise initialiser takes fields beyond `title` and `symbolName`, fill them in — the assertion is about the title.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionRenderTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `type 'CanvasRenderer' has no member 'visibleRegions'`.

- [ ] **Step 3: Add the region-drawing surface to `CanvasRenderer`**

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

    static func regionStroke(isSelected: Bool) -> (width: CGFloat, opacity: Double) {
        isSelected ? (width: 2, opacity: 1) : (width: 1, opacity: 0.6)
    }

    /// A resident that sits clear of its own region's frame.
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

    /// NON-INTERSECTION, not non-containment. A card overhanging the boundary
    /// by a pixel still reads as being in the region; drawing it a full line to
    /// the region's centre would be the same one-pixel nonsense the design
    /// cites against Obsidian, inverted.
    static func tethers(in scene: CanvasScene) -> [Tether] {
        scene.regions.flatMap { region -> [Tether] in
            region.homeMembers.sorted { $0.raw < $1.raw }.compactMap { nodeID in
                guard let frame = scene.node(nodeID)?.frame,
                      !region.frame.intersects(frame) else { return nil }
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
        /// The region doing the citing — where the chip is drawn.
        let region: CanvasRegionID
        /// Where the thing itself lives, or nil if it lives nowhere. This is
        /// the far end of §4.3's hairline, and the chip carries it so the draw
        /// pass never has to re-derive membership.
        let homeRegion: CanvasRegionID?
        let frame: CGRect
    }

    static let chipHeight: CGFloat = 22

    static func appearanceChips(in scene: CanvasScene) -> [AppearanceChip] {
        scene.regions.flatMap { region -> [AppearanceChip] in
            region.appearances.sorted { $0.raw < $1.raw }.enumerated().map { index, nodeID in
                AppearanceChip(
                    node: nodeID,
                    region: region.id,
                    homeRegion: CanvasMembership.homeRegion(of: nodeID, in: scene),
                    frame: CGRect(x: region.frame.minX + 10,
                                  y: region.frame.maxY - CGFloat(index + 1) * (chipHeight + 4) - 6,
                                  width: min(180, region.frame.width - 20),
                                  height: chipHeight))
            }
        }
    }

    /// The far end of the hairline: the home region's centre, or — for a node
    /// that lives nowhere — the card itself.
    static func homeAnchor(of chip: AppearanceChip, in scene: CanvasScene) -> CGPoint? {
        if let home = chip.homeRegion, let frame = scene.region(home)?.frame {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        guard let frame = scene.node(chip.node)?.frame else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// What a chip says. Pure, so the "which of these are visiting" reading is
    /// testable without a window.
    static func chipTitle(for id: CanvasNodeID,
                          scraps: [CanvasNodeID: String],
                          presentations: [CanvasNodeID: CanvasItemPresentation]) -> String {
        if let presentation = presentations[id] { return presentation.title }
        let firstLine = (scraps[id] ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(48))
    }

    /// Collapsing is a VIEW state (spec §7, §10). It hides residents; it never
    /// touches membership.
    static func visibleNodes(in scene: CanvasScene,
                             camera: CanvasCamera,
                             viewSize: CGSize,
                             hidingCollapsedResidents: Bool) -> [CanvasNode] {
        let visible = visibleNodes(in: scene, camera: camera, viewSize: viewSize)
        guard hidingCollapsedResidents else { return visible }
        let hidden = scene.regions
            .filter(\.isCollapsed)
            .reduce(into: Set<CanvasNodeID>()) { $0.formUnion($1.homeMembers) }
        return visible.filter { !hidden.contains($0.id) }
    }
```

- [ ] **Step 4: Amend `draw` — the signature and the whole body**

1C-a's `draw` takes `layouts:` and `editingNodeID:`, and its Task 12 adds `presentations:` for item titles. Two arguments join them: `scraps:`, because a chip shows its subject's first line, and `selectedRegionID:`, because the selection ring is drawn, not a view overlay. Keep the parameter order below; if the merged 1C-a signature spells `presentations:` differently, keep the merged spelling and add the two new parameters in the same positions.

```swift
    /// Draw the whole scene under the camera's CTM, in four passes:
    /// regions, tethers, nodes, chips. The order is the design: a region must
    /// never occlude the cards it holds (`regionLayerDepth < nodeLayerDepth`),
    /// and a chip must never be hidden behind the card it references.
    ///
    /// `editingNodeID` is skipped: while a scrap's editor is live, the editor IS
    /// the visible text, so drawing it too would double-draw (spec §7A.2, the
    /// rule borrowed from Excalidraw).
    static func draw(scene: CanvasScene,
                     camera: CanvasCamera,
                     viewSize: CGSize,
                     layouts: [CanvasNodeID: ScrapLayout],
                     presentations: [CanvasNodeID: CanvasItemPresentation],
                     scraps: [CanvasNodeID: String],
                     selectedRegionID: CanvasRegionID?,
                     editingNodeID: CanvasNodeID?,
                     into cx: inout GraphicsContext) {
        cx.translateBy(x: camera.pan.x, y: camera.pan.y)
        cx.scaleBy(x: camera.zoom, y: camera.zoom)

        // 1. Regions, beneath everything.
        for region in visibleRegions(in: scene, camera: camera, viewSize: viewSize) {
            drawRegion(region, isSelected: region.id == selectedRegionID, into: &cx)
        }

        // 2. Tethers, above the region fill and below the cards, so the line
        //    reads as belonging to the region rather than to the card.
        for tether in tethers(in: scene) {
            var line = Path()
            line.move(to: tether.from)
            line.addLine(to: tether.to)
            cx.stroke(line,
                      with: .color(Color(nsColor: .labelColor).opacity(0.3)),
                      lineWidth: 0.5)
        }

        // 3. Nodes. Residents of a collapsed region are hidden — a view state,
        //    never a membership change.
        for node in visibleNodes(in: scene, camera: camera, viewSize: viewSize,
                                 hidingCollapsedResidents: true) {
            guard node.id != editingNodeID, let frame = node.frame else { continue }

            var layer = cx
            // Rotate about the card's own centre, not the canvas origin.
            layer.translateBy(x: frame.midX, y: frame.midY)
            layer.rotate(by: seededRotation(for: node.id))
            layer.translateBy(x: -frame.midX, y: -frame.midY)

            drawCard(node, frame: frame, layout: layouts[node.id],
                     presentation: presentations[node.id], into: &layer)
        }

        // 4. Chips last, on top of the region they annotate.
        for chip in appearanceChips(in: scene) {
            drawChip(chip,
                     title: chipTitle(for: chip.node, scraps: scraps,
                                      presentations: presentations),
                     anchor: homeAnchor(of: chip, in: scene),
                     into: &cx)
        }
    }

    /// A region is a wash and a hairline with its name in the top-left. It is
    /// deliberately quiet: the ground already carries the project's palette
    /// (spec §7.1) and a strongly tinted region would fight it.
    private static func drawRegion(_ region: CanvasRegion,
                                   isSelected: Bool,
                                   into cx: inout GraphicsContext) {
        let shape = Path(roundedRect: region.frame, cornerRadius: 10)
        cx.fill(shape, with: .color(Color(nsColor: .labelColor).opacity(0.04)))

        let stroke = regionStroke(isSelected: isSelected)
        cx.stroke(shape,
                  with: .color(Color(nsColor: .separatorColor).opacity(stroke.opacity)),
                  lineWidth: stroke.width)

        var label = Text(region.displayLabel).font(.system(size: 11, weight: .medium))
        if region.isCollapsed {
            // A collapsed region must say what it is hiding, or its residents
            // have simply vanished.
            label = label + Text("  ·  \(region.homeMembers.count) hidden")
                .font(.system(size: 11))
        }
        cx.draw(label.foregroundStyle(Color(nsColor: .secondaryLabelColor)),
                at: CGPoint(x: region.frame.minX + 10, y: region.frame.minY + 6),
                anchor: .topLeading)
    }

    /// §4.3: a reference, visibly not the thing. Pill-shaped rather than
    /// card-shaped, a fraction of the height, and hairlined to its home.
    private static func drawChip(_ chip: AppearanceChip,
                                 title: String,
                                 anchor: CGPoint?,
                                 into cx: inout GraphicsContext) {
        if let anchor {
            var hairline = Path()
            hairline.move(to: CGPoint(x: chip.frame.maxX, y: chip.frame.midY))
            hairline.addLine(to: anchor)
            cx.stroke(hairline,
                      with: .color(Color(nsColor: .labelColor).opacity(0.25)),
                      lineWidth: 0.5)
        }

        let shape = Path(roundedRect: chip.frame, cornerRadius: chipHeight / 2)
        cx.fill(shape, with: .color(Color(nsColor: .controlAccentColor).opacity(0.12)))
        cx.stroke(shape, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)
        cx.draw(Text(title).font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor)),
                at: CGPoint(x: chip.frame.minX + 8, y: chip.frame.midY),
                anchor: .leading)
    }
```

- [ ] **Step 5: Update the one call site**

In `CanvasView.body`:

```swift
                Canvas { cx, size in
                    CanvasRenderer.draw(scene: model.scene, camera: camera, viewSize: size,
                                        layouts: layouts, presentations: presentations,
                                        scraps: model.scraps,
                                        selectedRegionID: model.selectedRegionID,
                                        editingNodeID: editingNodeID,
                                        into: &cx)
                }
```

`presentations` is the `[CanvasNodeID: CanvasItemPresentation]` map `CanvasView` already resolves for item nodes (1C-a Task 12). No new resolution work: the chip reads the same map the card does, which is why a chip and its card can never disagree about a title.

- [ ] **Step 6: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionRenderTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 13 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRendererTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — 1C-a's renderer tests must survive the signature change.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasRenderer.swift Maugham/Canvas/CanvasView.swift MaughamTests/Canvas/CanvasRegionRenderTests.swift
git commit -m "feat(canvas): draw regions, tethers for outside residents, chips for appearances

Four passes in one draw call: regions, tethers, nodes, chips. Tethers
fire on non-intersection rather than non-containment, so a card
overhanging the boundary is not lassoed to the region centre."
```

---

### Task 6: Region gestures — draw, drag, resize, drop-to-join, delete

**Files:**
- Modify: `Maugham/Canvas/CanvasInteraction.swift`
- Modify: `Maugham/Canvas/CanvasEventView.swift` (a delete-key callback)
- Modify: `Maugham/Canvas/CanvasView.swift` (gesture routing + undo brackets)
- Test: `MaughamTests/Canvas/CanvasRegionInteractionTests.swift`

**Interfaces:**
- Consumes: `CanvasScene`, `CanvasRegion`, `CanvasRegionID`, `CanvasMembership` (Tasks 1–2); `CanvasModel` with `withScene(persist:_:)`, `beginGesture(_:)`, `endGesture()`, `deleteSelectedRegion()`, `selectedRegionID` (Task 4); `CanvasInteraction` (1C-a Task 11) — a `struct` with `private enum Mode`, `private var mode: Mode`, `static let minimumScrapWidth/defaultScrapWidth`, `mutating func begin(at:in:)`, `beginResize(_:at:in:)`, `update(to:in:)`, `end()`, `static func createScrap(at:in:)`; `CanvasEventView` (1C-a Task 6) taking `camera: Binding<CanvasCamera>`, `onClick: (CGPoint) -> Void`, `onDrag: (CGPoint, CGPoint, DragPhase) -> Void`.
- Produces on `CanvasInteraction`: `static let minimumRegionSide/regionChromeHeight/regionResizeHandleSide`, `enum RegionHit`, `static func regionHit(at:in:)`, `static func joinTarget(for:in:)`, `mutating func beginRegionDrag(_:at:in:)`, `mutating func beginRegionResize(_:at:in:)`, `mutating func endDrag(in:)`, `static func createRegion(from:to:in:) -> CanvasRegionID?`.
- Produces on `CanvasEventNSView`/`CanvasEventView`: `onDeleteKey: (() -> Void)?`.

**Undo is not optional here.** This task adds three mutating gestures and one destructive one. 1C-a Task 13 established that every gesture is bracketed; a region drag that moved eleven cards and cannot be taken back is exactly how a spatial surface loses a writer's trust, and a ⌘Z that instead undoes the *previous* scrap edit is worse than none. Every gesture in Step 5 is wrapped in `model.beginGesture`/`model.endGesture`, which is the snapshot mechanism from Task 4 — **do not also wrap it in `CanvasUndo.beginGesture`.** One gesture, one mechanism; nesting the two produces a group containing a snapshot and gives you two ⌘Z presses for one drag.

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

    // MARK: - Dragging a region

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

    // MARK: - Resizing a region

    func test_resizingARegionMovesOnlyItsFrame() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        var i = CanvasInteraction()
        i.beginRegionResize(CanvasRegionID("r1"), at: CGPoint(x: 600, y: 400), in: s)
        i.update(to: CGPoint(x: 300, y: 250), in: &s)

        XCTAssertEqual(s.region(CanvasRegionID("r1"))?.frame,
                       CGRect(x: 0, y: 0, width: 300, height: 250))
        XCTAssertEqual(s.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100),
                       "resizing a region must not drag its residents")
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")),
                      "and it must never eject one — that is tldraw #6017")
    }

    func test_resizeIsClampedToAWorkableMinimum() {
        var s = scene()
        var i = CanvasInteraction()
        i.beginRegionResize(CanvasRegionID("r1"), at: CGPoint(x: 600, y: 400), in: s)
        i.update(to: CGPoint(x: -900, y: -900), in: &s)
        let frame = s.region(CanvasRegionID("r1"))!.frame
        XCTAssertEqual(frame.width, CanvasInteraction.minimumRegionSide)
        XCTAssertEqual(frame.height, CanvasInteraction.minimumRegionSide)
    }

    // MARK: - Where a region can be grabbed

    /// A region's interior belongs to the cards in it. Grabbing anywhere inside
    /// would make it impossible to pick up a card that sits in a region — which
    /// is most of them.
    func test_theInteriorOfARegionIsNotAGrabHandle() {
        XCTAssertNil(CanvasInteraction.regionHit(at: CGPoint(x: 300, y: 200), in: scene()))
    }

    func test_theLabelBarGrabsTheRegion() {
        XCTAssertEqual(CanvasInteraction.regionHit(at: CGPoint(x: 300, y: 10), in: scene()),
                       .chrome(CanvasRegionID("r1")))
    }

    func test_theBottomRightCornerGrabsTheResizeHandle() {
        XCTAssertEqual(CanvasInteraction.regionHit(at: CGPoint(x: 595, y: 395), in: scene()),
                       .resizeHandle(CanvasRegionID("r1")))
    }

    // MARK: - The one gesture that changes membership

    /// Targeting by the node's top-left CORNER is the Obsidian one-pixel bug
    /// inverted: a card whose body sits squarely in a region but whose corner
    /// pokes out would refuse to join. Target by overlap.
    func test_aCardWhoseCornerPokesOutStillJoinsTheRegionItSitsIn() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: s)      // grab node 'a'
        i.update(to: CGPoint(x: 5, y: 365), in: &s)      // origin (-5, 355): corner outside
        i.endDrag(in: &s)
        XCTAssertEqual(s.node(CanvasNodeID("a"))?.origin, CGPoint(x: -5, y: 355))
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")))
    }

    func test_aCardOverTwoRegionsJoinsTheOneItOverlapsMost() {
        var s = scene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r2"), label: "Falls",
                                    frame: CGRect(x: 500, y: 0, width: 600, height: 400)))
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: s)
        i.update(to: CGPoint(x: 460, y: 110), in: &s)    // origin (450,100), width 240
        i.endDrag(in: &s)
        XCTAssertTrue(s.region(CanvasRegionID("r2"))!.livesHere(CanvasNodeID("a")),
                      "150pt of overlap with r1 against 190pt with r2")
        XCTAssertFalse(s.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")))
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

    func test_endingARegionDragNeverJoinsAnything() {
        var s = scene()
        var i = CanvasInteraction()
        i.beginRegionDrag(CanvasRegionID("r1"), at: CGPoint(x: 300, y: 10), in: s)
        i.update(to: CGPoint(x: 310, y: 20), in: &s)
        i.endDrag(in: &s)
        XCTAssertTrue(s.region(CanvasRegionID("r1"))!.homeMembers.isEmpty,
                      "moving a region must not absorb whatever it lands on")
    }

    // MARK: - Drawing a region

    func test_drawingARegionCreatesItWithNoMembers() {
        var s = scene()
        let id = CanvasInteraction.createRegion(
            from: CGPoint(x: 700, y: 500), to: CGPoint(x: 1000, y: 700), in: &s)
        let r = s.region(id!)
        XCTAssertEqual(r?.frame, CGRect(x: 700, y: 500, width: 300, height: 200))
        XCTAssertTrue(r!.homeMembers.isEmpty,
                      "drawing a region over existing cards must not absorb them")
    }

    func test_drawingARegionNormalisesABackwardsDrag() {
        var s = scene()
        let id = CanvasInteraction.createRegion(
            from: CGPoint(x: 1000, y: 700), to: CGPoint(x: 700, y: 500), in: &s)
        XCTAssertEqual(s.region(id!)?.frame, CGRect(x: 700, y: 500, width: 300, height: 200))
    }

    func test_aTinyRegionDragReturnsNilRatherThanCreatingConfetti() {
        var s = scene()
        let before = s.regions.count
        let id = CanvasInteraction.createRegion(from: CGPoint(x: 700, y: 500),
                                                to: CGPoint(x: 703, y: 502), in: &s)
        XCTAssertNil(id, "an ignored draw returns no id — never an empty-string one")
        XCTAssertEqual(s.regions.count, before)
    }

    // MARK: - Undo

    func test_aRegionDragIsOneUndoStepAndRestoresItsResidents() {
        let model = CanvasModel()
        model.withScene { $0 = self.scene() }
        model.mutate("Join Region") {
            CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &$0)
        }

        var i = CanvasInteraction()
        model.beginGesture("Move Region")
        i.beginRegionDrag(CanvasRegionID("r1"), at: CGPoint(x: 300, y: 10), in: model.scene)
        for x in stride(from: CGFloat(310), through: 800, by: 10) {
            model.withScene { i.update(to: CGPoint(x: x, y: 10), in: &$0) }
        }
        model.endGesture()

        XCTAssertEqual(model.undoManager.undoActionName, "Move Region")
        model.undoManager.undo()
        XCTAssertEqual(model.scene.region(CanvasRegionID("r1"))?.frame.origin, .zero)
        XCTAssertEqual(model.scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 100, y: 100))
        XCTAssertTrue(model.undoManager.canUndo, "the join before the drag is still undoable")
    }

    func test_undoingADropToJoinTakesTheMembershipBackToo() {
        let model = CanvasModel()
        model.withScene { $0 = self.scene() }
        var i = CanvasInteraction()
        model.beginGesture("Move Scrap")
        i.begin(at: CGPoint(x: 110, y: 110), in: model.scene)
        model.withScene { i.update(to: CGPoint(x: 310, y: 210), in: &$0) }
        model.withScene { i.endDrag(in: &$0) }
        model.endGesture()
        XCTAssertTrue(model.scene.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")))

        model.undoManager.undo()
        XCTAssertFalse(model.scene.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")),
                       "one ⌘Z takes back the move AND the join it caused")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionInteractionTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — no `beginRegionDrag`.

- [ ] **Step 3: Extend `CanvasInteraction`**

Replace the private `Mode` enum with the four-case version and add the region members:

```swift
    /// Smaller than this and the writer flicked rather than drew. Also the
    /// resize clamp — a region you cannot see is a region you cannot get back.
    static let minimumRegionSide: CGFloat = 40

    /// The strip along a region's top edge that grabs it. The interior belongs
    /// to the cards inside; grabbing anywhere would make a card in a region
    /// unpickable, and most cards are in a region.
    static let regionChromeHeight: CGFloat = 22
    static let regionResizeHandleSide: CGFloat = 14

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
        case resizingRegion(CanvasRegionID, origin: CGPoint, grabOffset: CGSize)
    }

    enum RegionHit: Equatable {
        case chrome(CanvasRegionID)
        case resizeHandle(CanvasRegionID)
    }

    /// Where on a region the writer pressed, if anywhere that grabs it.
    /// Geometry in, geometry out — this NEVER consults or changes membership.
    static func regionHit(at point: CGPoint, in scene: CanvasScene) -> RegionHit? {
        guard let region = scene.region(at: point) else { return nil }
        let handle = CGRect(x: region.frame.maxX - regionResizeHandleSide,
                            y: region.frame.maxY - regionResizeHandleSide,
                            width: regionResizeHandleSide, height: regionResizeHandleSide)
        if handle.contains(point) { return .resizeHandle(region.id) }
        let chrome = CGRect(x: region.frame.minX, y: region.frame.minY,
                            width: region.frame.width, height: regionChromeHeight)
        if chrome.contains(point) { return .chrome(region.id) }
        return nil
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

    /// Resize from the bottom-right handle. The origin is pinned, so a resize
    /// never doubles as a move.
    mutating func beginRegionResize(_ id: CanvasRegionID,
                                    at contentPoint: CGPoint,
                                    in scene: CanvasScene) {
        guard let region = scene.region(id) else { mode = .idle; return }
        mode = .resizingRegion(id,
                               origin: region.frame.origin,
                               grabOffset: CGSize(width: contentPoint.x - region.frame.maxX,
                                                  height: contentPoint.y - region.frame.maxY))
    }
```

In `update(to:in:)` add two cases:

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

        case .resizingRegion(let id, let origin, let grab):
            let corner = CGPoint(x: contentPoint.x - grab.width,
                                 y: contentPoint.y - grab.height)
            // Clamped, and STILL only geometry: resizing a region to nothing
            // keeps every member (§4.2 — this is tldraw #6017, which ships that
            // bug despite storing membership explicitly).
            scene.setRegionFrame(
                CGRect(x: origin.x, y: origin.y,
                       width: max(Self.minimumRegionSide, corner.x - origin.x),
                       height: max(Self.minimumRegionSide, corner.y - origin.y)),
                for: id)
```

Add the drop and the create:

```swift
    /// Which region a dropped card joins: the one it OVERLAPS MOST.
    ///
    /// Not the region under its top-left corner. A card whose body sits
    /// squarely inside a region but whose corner is one pixel outside would
    /// refuse to join — the same one-pixel class the design cites against
    /// Obsidian, inverted. Ties break on `scene.regions` order, which is sorted
    /// by id and therefore stable.
    static func joinTarget(for frame: CGRect, in scene: CanvasScene) -> CanvasRegion? {
        var best: (region: CanvasRegion, area: CGFloat)?
        for region in scene.regions {
            let overlap = region.frame.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            guard area > 0 else { continue }
            if best == nil || area > best!.area { best = (region, area) }
        }
        return best?.region
    }

    /// End a NODE drag. This is the one gesture that changes membership, and it
    /// is an explicit act by the writer: dropping a node onto a region adds it
    /// (§4.2). Dropping on empty canvas does NOT remove it from anywhere —
    /// removal is its own command, because a writer nudging a card should never
    /// silently lose a grouping.
    ///
    /// Region drags fall through untouched: moving a region must not absorb
    /// whatever it happens to land on.
    mutating func endDrag(in scene: inout CanvasScene) {
        defer { mode = .idle }
        guard case .moving(let nodeID, _) = mode,
              let frame = scene.node(nodeID)?.frame,
              let target = joinTarget(for: frame, in: scene) else { return }
        CanvasMembership.join(nodeID, home: target.id, in: &scene)
    }

    /// Draw a new region. It starts EMPTY even if it is drawn over existing
    /// cards: absorbing whatever happens to be underneath is the geometric
    /// membership rule §4.2 forbids, just spelled differently.
    ///
    /// Returns nil when the drag was too small to be a deliberate draw. An
    /// optional rather than an empty-string id: an in-band sentinel is one
    /// missed check away from a region with no id in the sidecar.
    static func createRegion(from a: CGPoint, to b: CGPoint,
                             in scene: inout CanvasScene) -> CanvasRegionID? {
        let frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                           width: abs(b.x - a.x), height: abs(b.y - a.y))
        guard frame.width >= minimumRegionSide, frame.height >= minimumRegionSide else {
            return nil
        }
        var id = CanvasRegionID(UUID().uuidString.prefix(8).lowercased())
        while scene.region(id) != nil {
            id = CanvasRegionID(UUID().uuidString.prefix(8).lowercased())
        }
        scene.insertRegion(CanvasRegion(id: id, label: "", frame: frame))
        return id
    }
```

- [ ] **Step 4: Add the delete key to `CanvasEventView`**

In `Maugham/Canvas/CanvasEventView.swift`, on `CanvasEventNSView`:

```swift
    /// ⌫ deletes the selected REGION. Nodes have their own delete path
    /// (1C-a Task 12) — this callback only fires when the canvas has a region
    /// selected, which `CanvasView` decides.
    var onDeleteKey: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // 51 = delete, 117 = forward delete.
        guard event.keyCode == 51 || event.keyCode == 117 else {
            super.keyDown(with: event)
            return
        }
        onDeleteKey?()
    }
```

and pass it through `CanvasEventView` alongside `onClick`/`onDrag`, wiring it in `makeNSView`/`updateNSView` exactly as those two are wired.

- [ ] **Step 5: Route the gestures in `CanvasView`**

Hit order is **resize handle → card → region chrome → empty canvas**, and it is a decision, not an accident: a card lying under a region's label bar must still be pickable, because the card is the thing the writer is looking at.

```swift
    /// ⌥-drag on empty canvas draws a region. Read from `NSEvent` rather than
    /// threaded through the event view's callbacks: modifier state at press
    /// time is exactly what `NSEvent.modifierFlags` reports, and widening the
    /// callback signature would touch every call site for one Bool.
    private var isDrawingRegionGesture: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    private func handleDragBegan(from contentPoint: CGPoint) {
        if case .resizeHandle(let id)? = CanvasInteraction.regionHit(at: contentPoint,
                                                                    in: model.scene) {
            model.selectedRegionID = id
            model.beginGesture("Resize Region")
            interaction.beginRegionResize(id, at: contentPoint, in: model.scene)
        } else if model.scene.topmostNode(at: contentPoint) != nil {
            model.beginGesture("Move Scrap")
            interaction.begin(at: contentPoint, in: model.scene)
        } else if case .chrome(let id)? = CanvasInteraction.regionHit(at: contentPoint,
                                                                     in: model.scene) {
            model.selectedRegionID = id
            model.beginGesture("Move Region")
            interaction.beginRegionDrag(id, at: contentPoint, in: model.scene)
        } else if isDrawingRegionGesture {
            model.beginGesture("Draw Region")
        }
        // A plain drag on empty canvas is a pan, which the event view handles.
    }

    private func handleDragChanged(to contentPoint: CGPoint) {
        model.withScene { interaction.update(to: contentPoint, in: &$0) }
    }

    private func handleDragEnded(from start: CGPoint, to end: CGPoint) {
        if interaction.isActive {
            // The one membership-changing gesture, and only for node drags —
            // `endDrag` ignores region modes.
            model.withScene { interaction.endDrag(in: &$0) }
        } else if isDrawingRegionGesture {
            model.withScene { scene in
                if let id = CanvasInteraction.createRegion(from: start, to: end, in: &scene) {
                    model.selectedRegionID = id
                }
            }
        }
        interaction.end()
        model.endGesture()   // a gesture that changed nothing pushes no undo step
    }
```

and the event view gains the delete hook:

```swift
                CanvasEventView(
                    camera: $camera,
                    onClick: { handleClick(at: camera.contentPoint(fromView: $0)) },
                    onDrag: { start, current, phase in
                        let from = camera.contentPoint(fromView: start)
                        let to = camera.contentPoint(fromView: current)
                        switch phase {
                        case .began: handleDragBegan(from: from)
                        case .changed: handleDragChanged(to: to)
                        case .ended: handleDragEnded(from: from, to: to)
                        }
                    },
                    onDeleteKey: { model.deleteSelectedRegion() })
```

Selecting a region on a chrome press (above) and clearing it on an empty click (Task 4's `handleClick`) are the whole selection model. There is no marquee.

- [ ] **Step 6: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionInteractionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 16 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasInteractionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — 1C-a's scrap gestures are unchanged by the new `Mode` cases.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas MaughamTests/Canvas/CanvasRegionInteractionTests.swift
git commit -m "feat(canvas): region gestures — draw, drag-with-residents, resize, drop-to-join, delete

Drop targeting is greatest-overlap, not the node's top-left corner: a
card whose body sits inside a region but whose corner pokes out must
still join. Every gesture is bracketed by CanvasModel's snapshot undo."
```

---

### Task 7: The region inspector — label, collapse, piece binding, membership

**Files:**
- Create: `Maugham/Canvas/RegionBinding.swift`
- Create: `Maugham/Canvas/RegionInspector.swift`
- Modify: `Maugham/Views/ProjectWindow.swift` (`existingInspectorSwitch`'s `.canvas` arm)
- Test: `MaughamTests/Canvas/RegionBindingTests.swift`

**Interfaces:**
- Consumes: `CanvasRegion`, `CanvasRegionID`, `CanvasScene.updateRegion(_:_:)`, `CanvasMembership.leave(_:from:in:)` (Tasks 1–2); `CanvasModel` with `scene`, `scraps`, `selectedRegion`, `selectedRegionID`, `mutate(_:_:)`, `deleteSelectedRegion()`, `flush()` (Task 4); `CanvasRenderer.chipTitle(for:scraps:presentations:)` (Task 5); `ProjectStore.manifest.structure: [StructureItem]` (`id`, `title`, `type == .document`) and `TreeWalk.collect(in:where:)`.
- Produces: `enum RegionBinding` with `static func bind(_:toPiece:in:)`, `unbind(_:in:)`, `references(forPiece:in:) -> Set<CanvasNodeID>`, `boundPiece(of:in:) -> String?`; `struct RegionInspector: View` with `init(model: CanvasModel, regionID: CanvasRegionID, pieces: [PieceChoice])`, nested `struct PieceChoice: Identifiable, Hashable` (`id: String`, `title: String`), and the commit methods `commitLabel(_:)`, `commitBinding(_:)`, `commitCollapsed(_:)`, `remove(_:)`, `deleteRegion()`.

CLAUDE.md rule 8: every new data type needs a UI surface for inspection and action. Two types land here — the binding and `isCollapsed` — and **both get a control in this inspector**. `isCollapsed` was the one at risk: Task 5 renders it and the codec round-trips it, but nothing except a test could ever set it. A schema field only a test can reach is a field that rots, so it gets a disclosure toggle rather than being dropped; the spec asks for collapsing twice (§7, §10) and the render work is already done.

**Tripwire 16 does not apply here.** That rule is about an inline rename `TextField` that *appears* inside a `List(selection:)` row and has to steal focus from the list's own focus pass. This label field is always present in a static inspector form, so there is no focus race to lose — do not copy `BinderRow.claimFocus()` into it. Commit on `.onSubmit` and on focus loss, so one rename is one undo step rather than one per keystroke.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class RegionBindingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("region-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

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

    private func inspector() -> (CanvasModel, RegionInspector) {
        let model = CanvasModel()
        model.load(projectRoot: root)
        model.withScene { $0 = self.scene() }
        model.selectedRegionID = CanvasRegionID("r1")
        return (model, RegionInspector(
            model: model,
            regionID: CanvasRegionID("r1"),
            pieces: [RegionInspector.PieceChoice(id: "piece-3", title: "October")]))
    }

    // MARK: - The binding rules

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

    // MARK: - The inspector seam

    /// The whole point of `CanvasModel`: an edit made in the DETAIL column
    /// reaches the sidecar. The inspector is constructed from the model alone —
    /// it is handed no `ProjectStore` — and its label commit is the same method
    /// the `TextField` calls.
    func test_aLabelEditFromTheInspectorReachesDisk() {
        let (model, inspector) = self.inspector()
        inspector.commitLabel("Falls")
        model.flush()

        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene
                        .region(CanvasRegionID("r1"))?.label,
                       "Falls")
    }

    func test_aBindingChosenInTheInspectorReachesDisk() {
        let (model, inspector) = self.inspector()
        inspector.commitBinding("piece-3")
        model.flush()

        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene
                        .region(CanvasRegionID("r1"))?.boundPieceID,
                       "piece-3")
    }

    func test_collapsingFromTheInspectorSetsTheFlagAndIsUndoable() {
        let (model, inspector) = self.inspector()
        inspector.commitCollapsed(true)
        XCTAssertEqual(model.scene.region(CanvasRegionID("r1"))?.isCollapsed, true)
        model.undoManager.undo()
        XCTAssertEqual(model.scene.region(CanvasRegionID("r1"))?.isCollapsed, false)
    }

    /// §4.2's explicit removal act, given a button. Removing a resident from
    /// the list must not remove the card from the canvas.
    func test_removingAResidentFromTheInspectorKeepsTheNode() {
        let (model, inspector) = self.inspector()
        model.mutate("Join Region") {
            CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &$0)
        }
        inspector.remove(CanvasNodeID("a"))
        XCTAssertFalse(model.scene.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")))
        XCTAssertNotNil(model.scene.node(CanvasNodeID("a")),
                        "leaving a region is not leaving the canvas")
    }

    func test_theInspectorsDeleteRemovesTheRegionAndClearsTheSelection() {
        let (model, inspector) = self.inspector()
        inspector.deleteRegion()
        XCTAssertTrue(model.scene.regions.isEmpty)
        XCTAssertNil(model.selectedRegionID)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/RegionBindingTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'RegionBinding' in scope`.

- [ ] **Step 3: Write the binding rules**

`Maugham/Canvas/RegionBinding.swift`:

```swift
import Foundation

/// Region → piece binding. This is the bridge from umbrella §8: what you
/// cluster around a piece on the canvas becomes what is pinned beside you when
/// you write it, and what the compiler reads as context. No separate curation
/// step — the spatial work done in planning pays off directly.
///
/// The CONSUMER of `references(forPiece:)` is the Author persona's reference
/// rail, which belongs to plan 1A. Producing it here without a reader is
/// deliberate: the binding is the durable half of the bridge, and `RegionInspector`
/// makes it visible and changeable today.
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

- [ ] **Step 4: Write the inspector**

`Maugham/Canvas/RegionInspector.swift`. Every mutation goes through `model`; the view holds no copy of the scene, and the commit methods are `internal` so the tests drive the same code path the controls do.

```swift
import SwiftUI

/// The detail-column surface for the selected region (CLAUDE.md rule 8).
///
/// It is handed a `CanvasModel` and nothing else — no `ProjectStore`. Region
/// labels, bindings and membership live in the canvas sidecar, not the
/// manifest, so a store could not write any of them. The list of pieces to bind
/// TO comes in as plain `PieceChoice` values, resolved by `ProjectWindow`, so
/// this view never learns the manifest's shape.
///
/// The two lists are §4.3's requirement in UI form — "any region should answer
/// 'which of these live here and which are visiting' at a glance" — and the
/// remove buttons are §4.2's explicit removal act, which is the ONLY way a node
/// leaves a region.
struct RegionInspector: View {

    struct PieceChoice: Identifiable, Hashable {
        let id: String
        let title: String
    }

    let model: CanvasModel
    let regionID: CanvasRegionID
    let pieces: [PieceChoice]

    @State private var draftLabel: String = ""
    @FocusState private var labelFocused: Bool

    private var region: CanvasRegion? { model.scene.region(regionID) }

    var body: some View {
        Form {
            Section("Region") {
                TextField("Label", text: $draftLabel)
                    .focused($labelFocused)
                    .onSubmit { commitLabel(draftLabel) }
                Toggle("Collapsed", isOn: Binding(
                    get: { region?.isCollapsed ?? false },
                    set: { commitCollapsed($0) }))
                Picker("Piece", selection: Binding(
                    get: { region?.boundPieceID ?? "" },
                    set: { commitBinding($0.isEmpty ? nil : $0) })) {
                        Text("None").tag("")
                        ForEach(pieces) { Text($0.title).tag($0.id) }
                    }
            }

            Section("Lives here") {
                membershipRows(region?.homeMembers ?? [])
            }
            Section("Appears here") {
                membershipRows(region?.appearances ?? [])
            }

            Section {
                Button("Delete Region", role: .destructive) { deleteRegion() }
            } footer: {
                Text("Deleting a region never deletes its cards.")
            }
        }
        .formStyle(.grouped)
        .onAppear { draftLabel = region?.label ?? "" }
        .onChange(of: regionID) { _, _ in draftLabel = region?.label ?? "" }
        // Commit on blur as well as on ⏎, so a rename is one undo step rather
        // than one per keystroke.
        .onChange(of: labelFocused) { _, focused in
            if !focused { commitLabel(draftLabel) }
        }
    }

    @ViewBuilder
    private func membershipRows(_ ids: Set<CanvasNodeID>) -> some View {
        ForEach(ids.sorted { $0.raw < $1.raw }, id: \.raw) { id in
            HStack {
                Text(CanvasRenderer.chipTitle(for: id, scraps: model.scraps,
                                              presentations: [:]))
                    .lineLimit(1)
                Spacer()
                Button {
                    remove(id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove from this region — the card stays on the canvas")
            }
        }
    }

    // MARK: - Commits (the controls and the tests call these same methods)

    func commitLabel(_ text: String) {
        guard region?.label != text else { return }
        model.mutate("Rename Region") {
            $0.updateRegion(regionID) { $0.label = text }
        }
    }

    func commitCollapsed(_ collapsed: Bool) {
        model.mutate(collapsed ? "Collapse Region" : "Expand Region") {
            $0.updateRegion(regionID) { $0.isCollapsed = collapsed }
        }
    }

    func commitBinding(_ piece: String?) {
        model.mutate("Bind Region") { scene in
            if let piece {
                RegionBinding.bind(regionID, toPiece: piece, in: &scene)
            } else {
                RegionBinding.unbind(regionID, in: &scene)
            }
        }
    }

    /// §4.2's explicit removal act. Leaving a region is not leaving the canvas.
    func remove(_ node: CanvasNodeID) {
        model.mutate("Remove From Region") {
            CanvasMembership.leave(node, from: regionID, in: &$0)
        }
    }

    func deleteRegion() {
        model.selectedRegionID = regionID
        model.deleteSelectedRegion()
    }
}
```

- [ ] **Step 5: Wire it into `ProjectWindow`**

The `.canvas` arm of `existingInspectorSwitch` stays **one expression**, and the branching lives in its own method — the extraction pattern that exists to protect the type-checker budget:

```swift
        case .canvas:
            canvasInspector(store: store)
```

```swift
    @ViewBuilder
    private func canvasInspector(store: ProjectStore) -> some View {
        if let region = canvas.selectedRegion {
            RegionInspector(model: canvas,
                            regionID: region.id,
                            pieces: Self.canvasPieceChoices(store: store))
        } else {
            // Tripwire 15: the full-frame chain is not optional — without it
            // SwiftUI sizes to intrinsic content and the toolbar floats to the
            // window's centre. This has recurred four or more times.
            ContentUnavailableView("Select a region", systemImage: "square.on.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Pieces a region may bind to. Resolved here so `RegionInspector` never
    /// learns the manifest's shape.
    static func canvasPieceChoices(store: ProjectStore) -> [RegionInspector.PieceChoice] {
        TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document })
            .map { RegionInspector.PieceChoice(id: $0.id, title: $0.title) }
    }
```

- [ ] **Step 6: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/RegionBindingTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 10 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED. **Mandatory** — this task adds a method and a switch arm to `ProjectWindow.swift`, whose body ceiling has been hit twice, once passing Debug and failing Release CI.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/RegionBinding.swift Maugham/Canvas/RegionInspector.swift Maugham/Views/ProjectWindow.swift MaughamTests/Canvas/RegionBindingTests.swift project.yml
git commit -m "feat(canvas): region label, collapse, piece binding, lives-here/visiting inspector

The inspector holds only the CanvasModel — region state lives in the
canvas sidecar, not the manifest — and its commit methods are the same
ones the tests drive, so the detail-column-to-disk path is pinned."
```

---

### Task 8: Docs

**Files:**
- Modify: `Maugham/Canvas/AREA.md` (created by 1C-a Task 15)
- Modify: `docs/adr/0026-planning-canvas-rendering.md` (created by 1C-a Task 15)
- Modify: `CLAUDE.md` (tripwire table)
- Modify: `docs/guide/` (the topic covering personas), `docs/roadmap.md`, `docs/problem-map.md`

**Interfaces:**
- Consumes: everything Tasks 1–7 shipped, plus `Maugham/Canvas/AREA.md` and `docs/adr/0026-planning-canvas-rendering.md` from 1C-a Task 15.
- Produces: no code. Doc-sync tests must stay green.

**ADR decision, made here so no one has to relitigate it:** this slice **amends ADR 0026** with a "Membership" section. It does **not** mint a new ADR number. Membership is part of the same canvas-architecture decision the ADR already records, and 1C-c is being written in parallel — an unplanned number in this slice would collide with it. If 1C-c wants its own ADR for promotion, it takes the next free number; this slice takes none.

- [ ] **Step 1: Extend AREA.md**

Add a "Membership" section covering: explicit-only; the three tools that got it wrong and how; the one-home invariant and both places it is enforced (`CanvasMembership.join` and `CanvasSceneDTO`'s loader); what travels on a region drag (residents, never visitors); that removal is always its own act; and that drop targeting is **greatest overlap**, never the node's corner.

State plainly: **if you are about to write `region.frame.contains(node.origin)` near membership, you are reintroducing the bug class this design exists to eliminate.**

Add a "Who owns what" paragraph, because it is the question the next reader will have: `CanvasModel` owns scene, scraps, selection, the store and the undo stack, and is owned by `ProjectWindow` because two columns read it; `CanvasView` owns camera, layouts and editing focus, because those belong to one view of the canvas.

- [ ] **Step 2: Amend ADR 0026**

Add a section recording: membership is stored and geometry never changes it (with the Obsidian/tldraw #6017/Scapple evidence); one home plus many appearances, and why copies were rejected; that the accepted cost — a resident sitting outside its region — is paid in the renderer as a tether; and that region state persists in the canvas sidecar at schema 2, not in the manifest, which is why the inspector takes a `CanvasModel` rather than a `ProjectStore`. Cite the constitution principles by name, per CLAUDE.md.

- [ ] **Step 3: Add the tripwire**

Add to CLAUDE.md's tripwire table (1C-a Task 15 adds 25 and 26; this is 27):

| # | Rule | Why | Enforced |
|---|---|---|---|
| 27 | Canvas membership is never derived from geometry — not on move, not on resize, not on region creation. Drop-to-join targets by greatest overlap and is the ONLY gesture that changes it | Obsidian, tldraw (#6017) and Scapple each ship a distinct bug from the geometry→membership transition rule; tldraw's persists *despite* explicit storage | `CanvasMembershipTests` (the firewall tests were falsified by introducing the tldraw ejection bug); `CanvasRegionInteractionTests` |

- [ ] **Step 4: Sweep the guide**

The guide's persona section now needs regions. Describe only what ships (rule 7): drawing a region with ⌥-drag, dropping a card in, the difference between living in and appearing in, collapsing, binding a region to a piece, and that deleting a region never deletes cards. Do **not** describe promotion — that is 1C-c — and do not claim the binding yet feeds the editor's reference rail; that consumer is 1A.

```bash
grep -rn "region\|canvas" docs/roadmap.md docs/problem-map.md docs/guide/ CLAUDE.md | grep -iv corkboard
```

- [ ] **Step 5: Full verification**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/DocSyncTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: full Mac suite green. Integration failures only surface in the FULL suite — do not call this done off a filtered run.

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: green — confirms nothing leaked into MaughamCore, since M1C is Mac-only by design.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/AREA.md docs/adr/0026-planning-canvas-rendering.md CLAUDE.md docs/guide docs/roadmap.md docs/problem-map.md
git commit -m "docs(canvas): membership rules, geometry tripwire 27, ADR 0026 amendment, guide sweep"
```

---

## Whole-slice verification

- [ ] Full Mac suite, full phone suite, Release build — all green
- [ ] **Whole-branch review** of the 1C-b diff. Per-task reviews cannot see emergent interactions; the T5×T6 precedent on the unified-undo milestone is why this is not optional. Look especially at the Task 4 refactor's blast radius across 1C-a's `CanvasView`.
- [ ] `git status` shows nothing under `Maugham.xcodeproj/`
- [ ] Smoke: draw a region with ⌥-drag over two existing cards → confirm it absorbed neither → drag one card in → drag the region by its label bar → the resident travels, the other card does not → **⌘Z once puts the whole drag back** → resize the region from its corner until it is tiny → the resident is still a member → drag the resident far outside → a tether draws → cite a second card as an appearance → it renders as a chip, visibly not a card, hairlined to its home → select the region → rename it in the inspector → collapse it → its residents vanish and the label says how many → bind it to a piece → press ⌫ → the region goes, the cards stay → ⌘Z → it comes back with its membership → quit and reopen → everything survives

**Do not push or tag.**




