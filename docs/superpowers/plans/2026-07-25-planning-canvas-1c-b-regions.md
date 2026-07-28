# Planning canvas 1C-b — regions and membership Implementation Plan

> # ⛔ SUPERSEDED — DO NOT EXECUTE
>
> **Replaced 2026-07-27 by [`2026-07-27-planning-canvas-1c-b-regions.md`](2026-07-27-planning-canvas-1c-b-regions.md).**
>
> This draft was written against 1C-a *before 1C-a existed*. Roughly half of it restates signatures that are now greppable, and several of them are wrong — 1C-a went through three fix rounds and one interaction change after this was written. Kept for its design reasoning only; every API spelling in it is unverified. Read the built code, or the re-derived plan.

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
- **Every Step 2 begins with `./gen.sh &&`**, including the RED runs. Each task in this slice adds a brand-new test file, and until `./gen.sh` has run that file is not in the project at all — `-only-testing MaughamTests/<Class>` then runs **zero** tests and reports **success**. A green RED step is worse than no RED step, because it tells you the test failed for the reason you expected when in fact it never ran.
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

`Maugham/Canvas/CanvasInteraction.swift` is a real file containing `struct CanvasInteraction` (1C-a **Task 13** commits to the peer file, and says so because two plans list it). `Maugham/Canvas/CanvasEventView.swift` contains `struct CanvasEventView` and `final class CanvasEventNSView`. `Maugham/Canvas/CanvasView.swift` contains `struct CanvasView`. `Maugham/Canvas/CanvasUndo.swift` contains `final class CanvasUndo` and `enum ScrapUndoBeat` (1C-a **Task 15**). `Maugham/Canvas/CanvasRenderer.swift` contains `enum CanvasRenderer` and `struct CanvasFocusStraighten` (1C-a Task 7). If any is missing, 1C-a is not merged and this slice cannot start.

### The 1C-a spellings this plan builds on — reconcile against 1C-a, not against memory

This plan was first drafted against an earlier 1C-a. 1C-a has since been through three fix rounds and one interaction change, and the list below is the result of sweeping this plan against **1C-a as committed**. It is repeated here in one block because every one of these has a tempting wrong spelling, and because 1C-a's own "Cross-plan contract" section names only the first three.

| symbol | 1C-a ships | the wrong spelling to watch for |
|---|---|---|
| `CanvasStore.flush()` | **no arguments** — writes whatever `scheduleSave` last queued, and covers ⌘Q via `NSApplication.willTerminateNotification` | `flush(scene:scraps:)`. Use `save(scene:scraps:)` when you have a payload in hand and want it written now. |
| `CanvasStore.beforeFlush: (() -> Void)?` | the owner's last synchronous chance to fold the live editor's text into the payload. 1C-a's `CanvasView.load()` sets it to `syncActiveEdit` | dropping it. Task 4 moves the store into `CanvasModel`, so the model must forward this or ⌘Q loses the sentence in flight. |
| `CanvasView.paletteSwatchHexes` | `() -> [String]` — a **closure**, deferred on purpose because `ProjectStore.paletteSwatchHexes()` reads every palette card off disk and `ProjectWindow.body` must not do file I/O per render | `[String]`, or `paletteSwatchColors: [Color]`. |
| `ProjectStore.paletteSwatchHexes() -> [String]` | added by 1C-a **Task 11** | Task 10; `[Color]`. |
| `CanvasEventView` | `@Binding var camera`, `onClick: (CGPoint, Int) -> Void` (view point, **click count**), `onDrag: (CGPoint, CanvasDragPhase) -> Void` (view point, **phase — one point, not two**), `undoManager: UndoManager?` | `onClick: (CGPoint) -> Void`; a three-argument `onDrag`; the type name `DragPhase`. 1C-a says outright: "This is the only drag vocabulary in the plan… there is no `DragPhase`." Dropping `undoManager:` kills ⌘Z from the responder chain. |
| `CanvasRenderer.draw` | `draw(scene:camera:viewSize:layouts:visibleEditorNodeID:straighten:into:)` | `editingNodeID:`; an inline `seededRotation`; omitting `straighten:`. See Task 5. |
| `CanvasUndo` (1C-a **Task 15**) | snapshot-based; state reached through `readSnapshot`/`applySnapshot` closures **precisely so 1C-b can move ownership to `CanvasModel` without touching the class** | Task 13; re-implementing snapshots inside `CanvasModel`. See Task 4. |
| `CanvasScene` | `nodes` (sorted, allocates), `unorderedNodes`, `count`; `topmostNode(at:)` and `nodes(intersecting:)` **filter first and order the survivors** | calling `nodes` on a per-frame or per-`body` path. |
| `CanvasView` counters | `revision` (redraw, ticks every animation frame) **and** `sceneRevision` (structural; the accessibility tree is keyed on it and `CanvasAccessibilityTests` greps the source for `.onChange(of: sceneRevision`) | one counter; keying anything scene-proportional on `revision`. |
| the editor's three states | `editingNodeID` (the writer is editing it), `mountedEditorNodeID` (its editor **exists** and takes keystrokes, from the click), `visibleEditorNodeID` (its editor **is the visible text**, from `straighten.isLevel`) | merging any two of them. 1C-a records that this failed twice, in opposite directions. |
| card rotation | `CanvasRenderer.drawnAngle(for:straighten:)` → `CanvasRenderer.cardTransform(inCard:angle:)`, concatenated onto a **copy** of the context inside `drawCard`. A grep test forbids `rotate(by:)`/`rotationEffect` anywhere in `Maugham/Canvas/` | `cx.rotate(by: seededRotation(for:))` inline in `draw`. |

**Tests in this slice that call `undoManager.undo()` must set `groupsByEvent = false` first.** `UndoManager` defaults it to `true`, which installs a run-loop observer that opens an implicit top-level group per event; calling `undo()` synchronously outside a run loop while that group is open raises `NSInternalInconsistencyException`. 1C-a's `CanvasUndoTests` does this in every test and production keeps the default. Three test classes here need it: `CanvasModelTests`, `CanvasRegionInteractionTests`, `RegionBindingTests`.

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
| `Maugham/Canvas/CanvasModel.swift` | The one owner of scene + scraps + selection + the store, and the host of 1C-a's `CanvasUndo` (rebound, not reimplemented). The seam between `CanvasView` and `RegionInspector`. |
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

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionTests CODE_SIGNING_ALLOWED=NO`
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
- Produces: `enum CanvasMembership` with `static func join(_ node:home:in:)`, `static func addAppearance(_ node:to:in:)`, `static func leave(_ node:from:in:)`, `static func homeRegion(of:in:) -> CanvasRegionID?`, `static func appearanceRegions(of:in:) -> [CanvasRegionID]`, `static func nodesTravelling(withRegion:in:) -> Set<CanvasNodeID>`; and `CanvasScene.regions`, `unorderedRegions`, `region(_:)`, `region(at:)`, `insertRegion(_:)`, `removeRegion(_:)`, `updateRegion(_:_:)`, `setRegionFrame(_:for:)`.

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

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasMembershipTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `cannot find 'CanvasMembership' in scope`.

- [ ] **Step 3: Extend `CanvasScene` with regions**

Add to `Maugham/Canvas/CanvasScene.swift`:

```swift
    private var regionsByID: [CanvasRegionID: CanvasRegion] = [:]

    /// Regions in a stable order. Drawn BENEATH nodes, so a region never
    /// occludes the cards it holds.
    ///
    /// **This sorts on every access**, exactly as `nodes` does. Use it where the
    /// order is load-bearing — the sidecar's on-disk order, appearance-chip
    /// stacking, `joinTarget`'s tie-break — and `unorderedRegions` everywhere
    /// else. Scenes hold far fewer regions than nodes, so this is a convention
    /// kept for the same reason 1C-a keeps it, not a measured hot spot.
    public var regions: [CanvasRegion] {
        regionsByID.values.sorted { $0.id.raw < $1.id.raw }
    }

    /// Every region, no defined order — the sibling of `unorderedNodes`. For
    /// membership lookups and per-frame culling, where the answer is a set or a
    /// filter and the sort would be pure waste.
    public var unorderedRegions: [CanvasRegion] { Array(regionsByID.values) }

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

and **extend** 1C-a's `remove(_ id: CanvasNodeID)` — do not replace its body, append to it — so a deleted node cannot leave a dangling membership. 1C-a's body is `byID[id] = nil`; the method becomes:

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
        // `unorderedRegions`, not `regions` — this is a sweep over all of them
        // and the sort would buy nothing.
        for r in scene.unorderedRegions where r.id != region {
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

    /// A node lives in at most one region, so the first match IS the answer and
    /// the order it was found in cannot matter — `unorderedRegions`.
    static func homeRegion(of node: CanvasNodeID, in scene: CanvasScene) -> CanvasRegionID? {
        scene.unorderedRegions.first { $0.livesHere(node) }?.id
    }

    /// Sorted, because this one is read straight into the inspector's list and a
    /// list that reshuffles between reads is a list a writer cannot use.
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

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionCodecTests CODE_SIGNING_ALLOWED=NO`
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
        let present = Set(s.unorderedNodes.map(\.id))
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
- Consumes: `CanvasScene`, `CanvasRegion`, `CanvasRegionID`, `CanvasNodeID`, `CanvasMembership` (Tasks 1–2); `CanvasStore` (1C-a Task 5) with `init(projectRoot: URL)`, `load() -> (scene: CanvasScene, scraps: [CanvasNodeID: String])`, `save(scene:scraps:)`, `scheduleSave(scene:scraps:)`, **`flush()` — no arguments**, `var beforeFlush: (() -> Void)?`; `CanvasCamera`, `ScrapLayout`, `CanvasRenderer`, `CanvasFocusStraighten`, `CanvasEventView`, `ScrapEditorHost`, `CanvasGround`, `CanvasGroundPalette`, `CanvasInteraction`, `CanvasMomentum` (1C-a); `CanvasUndo` (1C-a **Task 15**) with `typealias Snapshot = (scene: CanvasScene, scraps: [CanvasNodeID: String])`, `init(undoManager: UndoManager)`, `var readSnapshot: (() -> Snapshot)?`, `var applySnapshot: ((Snapshot) -> Void)?`, `beginGesture(_:)`, `endGesture()`, `breakGesture()`, `mutate(_:_:)`, `noteCameraChanged()`, `var isInGesture: Bool`; `ProjectStore.url` (the project root — `Maugham/Stores/ProjectStore.swift:68`) and `ProjectStore.paletteSwatchHexes() -> [String]` (added by 1C-a **Task 11**).
- Produces: `@Observable final class CanvasModel` with `private(set) var scene: CanvasScene`, `private(set) var scraps: [CanvasNodeID: String]`, `var selectedRegionID: CanvasRegionID?`, `var selectedRegion: CanvasRegion?`, `let undoManager: UndoManager`, `let undo: CanvasUndo`, `private(set) var sceneRevision: Int`, `var beforeFlush: (() -> Void)?`, `func load(projectRoot: URL)`, `func flush()`, `func withScene(persist:_:)`, `func setScrapText(_:for:)`, `func rewriteScraps(_:)`, `func beginGesture(_:)`, `func endGesture()`, `func breakGesture()`, `func mutate(_:_:)`, `func deleteSelectedRegion()`.
- Changes `CanvasView`'s initialiser to `CanvasView(model: CanvasModel, projectRoot: URL, paletteSwatchHexes: () -> [String])` — **the hex closure, kept exactly as 1C-a spells it**: `ProjectStore.paletteSwatchHexes()` reads every palette card off disk, and calling it eagerly inside `ProjectWindow.body` would do file I/O per render.

**Why this task exists.** Three surfaces need the same scene: the drawn canvas, the region gestures, and the inspector in the right-hand column. In 1C-a the scene is `@State` inside `CanvasView`, which means nothing outside that view can see it or change it — an inspector handed a `ProjectStore` could not edit a region label, because region labels do not live in the manifest. So the scene, the scrap text, the selection, the sidecar store and the undo recorder move to **one reference type owned by `ProjectWindow`** and passed to both views. Camera, layouts, `editingNodeID`, `caretIndex`, `straighten`, `interaction`, `momentum`, `wash` and both revision counters stay in `CanvasView`: they are properties of one view of the canvas, and the inspector has no business with them.

**`CanvasModel` does not reimplement undo — it rebinds `CanvasUndo`.** This is the single most important thing to get right in this task, and it is the thing an earlier draft of this plan got wrong. 1C-a Task 15 builds `CanvasUndo` snapshot-based *and reaches its state through two closures — `readSnapshot` and `applySnapshot` — for exactly this reason*: "in 1C-a the owner is `CanvasView`'s `@State`, in 1C-b it is `CanvasModel`. Only the closures get rebound." So `CanvasModel` **owns a `CanvasUndo`, points its two closures at itself, and forwards `beginGesture`/`endGesture`/`breakGesture`/`mutate`.** It writes no `registerUndo` of its own.

Four behaviours come free that a hand-rolled duplicate would have to re-earn, and three of them are subtle enough that a duplicate would ship without them:

- **`beginGesture` opens no `UndoManager` group.** A group cannot span an event boundary, and an "Edit Scrap" gesture spans as many events as the writer types keystrokes; `endGesture` opens, registers, names and closes synchronously in one event. A `registerUndo` at mutation time — which is what the duplicate did — also pushes a step for a gesture that changed nothing.
- **`breakGesture()`** is what gives a long visit to a scrap more than one ⌘Z (a finished sentence, or `ScrapUndoBeat.idleSeconds` of stillness). A duplicate without it silently coarsens undo inside every scrap.
- **Nesting is absorbed** via a depth counter, so a gesture arriving mid-gesture cannot leave the manager unbalanced. Task 6 relies on this.
- **An undo serviced while a gesture is open re-baselines that gesture.** Without it: type in A, click into B, ⌘Z, type in B, click out — and the next ⌘Z resurrects A's discarded text.

**Why snapshots at all**, restated because it is 1C-b's requirement that drove 1C-a's choice: a region drag mutates a region frame *and* every resident's origin, and recording per-property inverses for that is how you get a half-undone drag. One snapshot per gesture is exactly correct and cheap — `CanvasScene` is a value type and the scenes in play are hundreds of nodes, not millions.

**`sceneRevision` lives in both places, and that is deliberate.** 1C-a keys the accessibility tree on `CanvasView`'s `@State sceneRevision`, and `CanvasAccessibilityTests` greps the source for the literal `.onChange(of: sceneRevision` — so that property must keep its name and its home. But the inspector mutates the scene from the *other* column and cannot reach a view's `@State`. So the model carries its own structural counter and `CanvasView` mirrors it in one line (Step 4). Renaming either counter breaks a source-grep test in 1C-a.

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
        // `groupsByEvent` defaults to TRUE, which installs a run-loop observer
        // that opens an implicit top-level group per event. Calling `undo()`
        // synchronously outside a run loop while that group is open raises
        // NSInternalInconsistencyException. 1C-a's CanvasUndoTests does the same
        // in every test; production keeps the default, safely, because every
        // gesture registers inside one event.
        model.undoManager.groupsByEvent = false
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

    /// The model FORWARDS to `CanvasUndo` rather than re-implementing it, so
    /// `breakGesture` has to reach the writer through the model. Without this,
    /// 1C-a's per-sentence granularity inside a scrap is silently lost the
    /// moment ownership moves here.
    func test_breakingAGestureSplitsItIntoTwoUndoSteps() {
        let model = loadedModel()
        model.beginGesture("Move Region")
        model.withScene { $0.setRegionFrame(CGRect(x: 100, y: 0, width: 600, height: 400),
                                            for: CanvasRegionID("r1")) }
        model.breakGesture()
        model.withScene { $0.setRegionFrame(CGRect(x: 200, y: 0, width: 600, height: 400),
                                            for: CanvasRegionID("r1")) }
        model.endGesture()

        model.undoManager.undo()
        XCTAssertEqual(model.scene.region(CanvasRegionID("r1"))?.frame.origin,
                       CGPoint(x: 100, y: 0), "one ⌘Z goes back to the break, not to the start")
        model.undoManager.undo()
        XCTAssertEqual(model.scene.region(CanvasRegionID("r1"))?.frame.origin, .zero)
    }

    /// A gesture opened inside a gesture must not unbalance the recorder —
    /// Task 6 leans on this when a region drag is bracketed around an
    /// interaction that brackets itself.
    func test_nestedGesturesCollapseIntoOneStep() {
        let model = loadedModel()
        model.beginGesture("Move Region")
        model.beginGesture("Move Region")
        model.withScene { $0.setRegionFrame(CGRect(x: 50, y: 0, width: 600, height: 400),
                                            for: CanvasRegionID("r1")) }
        model.endGesture()
        XCTAssertTrue(model.undo.isInGesture, "the outer bracket is still open")
        model.endGesture()

        model.undoManager.undo()
        XCTAssertEqual(model.scene.region(CanvasRegionID("r1"))?.frame.origin, .zero)
        XCTAssertFalse(model.undoManager.canUndo)
    }

    /// The store's quit hook is the only thing that runs on ⌘Q — `.onDisappear`
    /// does not fire. `CanvasView` sets this to `syncActiveEdit`, so a model
    /// that swallowed it would lose the sentence the writer is halfway through.
    func test_beforeFlushReachesTheStore() {
        let model = loadedModel()
        var called = false
        model.beforeFlush = { called = true }
        model.flush()
        XCTAssertTrue(called)
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

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasModelTests CODE_SIGNING_ALLOWED=NO`
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
/// selection, the sidecar store, and the undo recorder. What deliberately does
/// NOT: the camera, the `ScrapLayout` cache, `editingNodeID`, `caretIndex`,
/// `straighten`, `interaction`, `momentum`, `wash` and the redraw counter —
/// those are properties of ONE view of the canvas, and the inspector has no
/// business with them.
///
/// Mutation goes through exactly one door (`withScene`), so persistence and
/// undo cannot be forgotten at a call site. `scene` is `private(set)` to keep
/// that door the only one.
///
/// **Undo is `CanvasUndo` (1C-a Task 15), rebound — not reimplemented.** That
/// class already reaches its state through `readSnapshot`/`applySnapshot`
/// closures precisely so ownership could move here; 1C-a says so at Task 15.
/// This type points those closures at itself and forwards the four gesture
/// methods. Writing a second snapshot mechanism here would lose `breakGesture`
/// (per-sentence granularity inside a scrap), the deferred `beginUndoGrouping`
/// (a group cannot span an event boundary), the nesting depth counter, and the
/// re-baseline of an open gesture when a ⌘Z is serviced mid-visit.
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

    /// The STRUCTURAL counter, mirroring 1C-a's `CanvasView.sceneRevision`.
    /// Bumped by every persisting mutation and by every snapshot application.
    /// `CanvasView` mirrors it into its own `@State sceneRevision` in one line,
    /// so the accessibility tree also tracks edits made from the inspector —
    /// which is in the other column and cannot reach a view's `@State`. The
    /// view's property keeps its name because `CanvasAccessibilityTests` greps
    /// the source for `.onChange(of: sceneRevision`.
    private(set) var sceneRevision = 0

    /// ONE manager for the whole canvas, so ⌘Z walks scrap text, scrap geometry
    /// and region edits in the order they actually happened. Two managers would
    /// give the writer two half-histories.
    let undoManager = UndoManager()

    /// 1C-a's recorder, owned here and wired to this object in `init`.
    let undo: CanvasUndo

    /// Forwarded to `CanvasStore.beforeFlush`. `CanvasView` sets it to
    /// `syncActiveEdit` so the words in the mounted editor reach the payload
    /// before it is written — the only hook that covers ⌘Q, because
    /// `.onDisappear` does not fire on quit. Held here rather than set on the
    /// store directly because the store is created in `load`, which may run
    /// after the view has appeared.
    var beforeFlush: (() -> Void)?

    private var store: CanvasStore?
    /// Keyed on the project PATH, not on an id — tripwire 22's shape: an
    /// id-keyed reload survives a rename and shows stale content.
    private var loadedRoot: URL?

    init() {
        undo = CanvasUndo(undoManager: undoManager)
        undo.readSnapshot = { [unowned self] in (self.scene, self.scraps) }
        undo.applySnapshot = { [unowned self] snapshot in
            self.scene = snapshot.scene
            self.scraps = snapshot.scraps
            self.sceneRevision += 1
            self.store?.scheduleSave(scene: self.scene, scraps: self.scraps)
        }
    }

    // MARK: - Lifecycle

    /// Load once per project root. `.onAppear` fires again every time the
    /// writer re-enters the Plan persona, and reloading there would discard
    /// whatever the 750 ms debounce has not yet written.
    func load(projectRoot: URL) {
        guard loadedRoot != projectRoot else { return }
        let s = CanvasStore(projectRoot: projectRoot)
        s.beforeFlush = { [weak self] in self?.beforeFlush?() }
        let loaded = s.load()
        store = s
        loadedRoot = projectRoot
        scene = loaded.scene
        scraps = loaded.scraps
        sceneRevision += 1
    }

    /// Write any debounced save now. `CanvasView.onDisappear` calls this — the
    /// canvas cleans up after itself rather than adding a line to
    /// `ProjectWindow.body`'s scorch block, which has no expression budget.
    ///
    /// **`CanvasStore.flush()` takes no arguments** (1C-a Task 5): the store
    /// keeps the last debounced payload so it can also flush from its own
    /// `NSApplication.willTerminateNotification` observer, where there is no
    /// caller left holding one. Passing a payload here would not compile.
    func flush() { store?.flush() }

    // MARK: - Mutation

    /// The one door. `persist: false` is for derived bookkeeping — measured
    /// heights — which must neither hit the disk, enter the undo stack, nor
    /// stale the accessibility tree.
    func withScene(persist: Bool = true, _ mutate: (inout CanvasScene) -> Void) {
        mutate(&scene)
        guard persist else { return }
        sceneRevision += 1
        store?.scheduleSave(scene: scene, scraps: scraps)
    }

    func setScrapText(_ text: String, for id: CanvasNodeID) {
        scraps[id] = text
        store?.scheduleSave(scene: scene, scraps: scraps)
    }

    /// Replace the whole scrap map — the shape `CanvasView.rebuildLayouts` needs
    /// after it prunes layouts for nodes that no longer exist. Deliberately not
    /// a `private(set)` bypass: it goes through the same save path.
    func rewriteScraps(_ scraps: [CanvasNodeID: String]) {
        self.scraps = scraps
        store?.scheduleSave(scene: scene, scraps: scraps)
    }

    // MARK: - Undo (forwarded to CanvasUndo — see the type doc)

    func beginGesture(_ name: String) { undo.beginGesture(name) }
    func endGesture() { undo.endGesture() }
    func breakGesture() { undo.breakGesture() }

    /// One-shot edit: a gesture with no dragging in the middle.
    func mutate(_ name: String, _ body: (inout CanvasScene) -> Void) {
        undo.mutate(name) { withScene(body) }
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

**On `[unowned self]` in the two closures.** `CanvasModel` owns `undo`, and `undo` holds the closures — a reference cycle either way round. `unowned` is correct rather than `weak` because the recorder cannot outlive the model that owns it, and 1C-a's `CanvasUndo` treats a nil `readSnapshot` as "record nothing" rather than as an error, which would silently disable undo if this were `weak` and the optional chain ever short-circuited.

- [ ] **Step 4: Move `CanvasView` onto the model**

**This is a delta, not a rewrite.** 1C-a's `CanvasView` is the product of seventeen tasks — the straighten clock, the mount/visibility split, momentum, the two counters, the three commit points, the undo brackets. Re-typing the file from the fragments below would silently delete most of it. Change only what the list names; leave every other line of 1C-a's `CanvasView` exactly as it stands.

**(a) The property block.** Six properties move to the model; everything else stays. Delete `@State private var scene`, `@State private var scraps`, `@State private var store`, `@State private var undoManager`, `@State private var undo`; **keep** `camera`, `layouts`, `editingNodeID`, `caretIndex`, `wash`, `straighten`, `revision`, `sceneRevision`, `lastKeystrokeAt`, `interaction`, `momentum` and `scrapFont`.

```swift
struct CanvasView: View {
    /// Owned by `ProjectWindow` and shared with `RegionInspector` — see
    /// `CanvasModel`. Not `@State`: this view is one of two readers, and
    /// `@Observable` gives it the redraws for free.
    let model: CanvasModel
    let projectRoot: URL
    /// Still the deferred closure 1C-a ships — `ProjectStore.paletteSwatchHexes()`
    /// reads every palette card off disk and must not run per render.
    let paletteSwatchHexes: () -> [String]
```

**(b) Every read of the moved state gains a `model.` prefix**, mechanically: `scene` → `model.scene`, `scraps` → `model.scraps`, `store?.scheduleSave(scene: scene, scraps: scraps)` → `model.withScene { }`'s own save or `model.setScrapText(_:for:)`, `store?.flush()` → `model.flush()`, `undoManager` → `model.undoManager`, `undo?.x()` → `model.x()` (the optional goes away — the recorder is built in `CanvasModel.init`, so there is no window in which it is nil). **Every mutation of `scene` moves inside a `model.withScene { }` closure**, because `model.scene` is `private(set)`.

**(c) `load()` shrinks to the two things the view still owns**, and the `beforeFlush` hook is re-pointed at the model:

```swift
    private func load() {
        // The store lives in the model now, and it is the model that holds the
        // quit hook — `.onDisappear` does not fire on ⌘Q, and the sentence the
        // writer is halfway through lives in the editor's NSTextStorage until
        // `syncActiveEdit` folds it in.
        model.beforeFlush = { syncActiveEdit() }
        model.load(projectRoot: projectRoot)
        wash = CanvasGroundPalette.wash(fromHex: paletteSwatchHexes())
        rebuildLayouts()
    }
```

`.onAppear { load() }` and `.onDisappear { syncActiveEdit(); model.flush() }` keep 1C-a's shape.

**(d) `rebuildLayouts` keeps all of 1C-a's behaviour** — reusing an existing layout when the text is unchanged (replacing it would tear the mounted editor's `NSTextStorage` out from under the writer, Task 9's rebinding path), `CanvasCardMetrics.textWidth(forCardWidth:)` for the text box, `CanvasCardMetrics.cardHeight(forTextHeight:)` for the card, the orphan prune, and both counter bumps. Only the state reads change, and the height write goes through `persist: false` because measuring is bookkeeping:

```swift
    private func rebuildLayouts() {
        var measured: [CanvasNodeID: CGFloat] = [:]
        for node in model.scene.unorderedNodes {
            guard case .scrap = node.kind else { continue }
            let text = model.scraps[node.id] ?? ""
            let textWidth = CanvasCardMetrics.textWidth(forCardWidth: node.width)
            let layout: ScrapLayout
            if let existing = layouts[node.id], existing.text == text {
                existing.setWidth(textWidth)
                layout = existing
            } else {
                layout = ScrapLayout(text: text, width: textWidth, font: scrapFont)
                layouts[node.id] = layout
            }
            measured[node.id] = CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight)
        }
        layouts = layouts.filter { model.scene.node($0.key) != nil }
        // Measured heights are DERIVED — they must not schedule a write and must
        // not land on the undo stack.
        model.withScene(persist: false) { scene in
            for (id, height) in measured { scene.setCachedHeight(height, for: id) }
        }
        revision += 1
        sceneRevision += 1
    }
```

**(e) `handleClick(at:clickCount:)` keeps its whole 1C-a body** — the `commitActiveEdit()` first line, the `clickCount >= 2` gate, the caret resolved in the card's unrotated space via `drawnAngle`/`localPoint`, `straighten.focus(_:)`, the double-click-on-empty create path, and both `beginGesture("Edit Scrap")` brackets. **One line is added**, in the single-click arm:

```swift
        guard clickCount >= 2 else {
            editingNodeID = nil
            caretIndex = nil
            straighten.focus(nil)
            // A click on empty canvas clears the region selection; a click on a
            // region's chrome sets it (Task 6, on drag-began).
            model.selectedRegionID = nil
            return
        }
```

**(f) Mirror the model's structural counter**, so the accessibility tree also tracks edits made from the inspector in the other column. One modifier beside the existing lifecycle hooks:

```swift
            // The inspector mutates the scene from the detail column and cannot
            // reach this view's @State. `sceneRevision` keeps its name here
            // because `CanvasAccessibilityTests` greps the source for it.
            .onChange(of: model.sceneRevision) { _, _ in sceneRevision += 1 }
```

**Do not** leave a second `UndoManager` or a second `CanvasUndo` anywhere in the canvas. In particular, **`CanvasUndo` must not be a computed property** — `var undo: CanvasUndo { CanvasUndo(undoManager: model.undoManager) }` mints a fresh recorder on every access, so `beginGesture` and `endGesture` land on different objects and every gesture's snapshot is thrown away. The one instance is `model.undo`, built in `CanvasModel.init`, and the view reaches it only through the four forwarding methods.

- [ ] **Step 5: Give `ProjectWindow` the model**

One stored property beside the existing `@State` block (a stored property is not a body expression — see Global Constraints):

```swift
    /// The Plan persona's canvas state. Owned here because two columns read it:
    /// `CanvasView` in the centre and `RegionInspector` in the detail column.
    @State private var canvas = CanvasModel()
```

And the `.canvas` arm of `existingEditorSwitch` — still one expression — gains `model:` and **keeps 1C-a's closure spelling of the palette argument**:

```swift
        case .canvas:
            CanvasView(model: canvas,
                       projectRoot: store.url,
                       paletteSwatchHexes: { store.paletteSwatchHexes() })
```

The braces are not decoration: `paletteSwatchHexes` is `() -> [String]`, and calling it eagerly here would read every palette card off disk on every `ProjectWindow` render. `ProjectStore.url` is the project root (`ProjectStore.swift:68`). Leave the `.canvas` inspector arm as 1C-a's placeholder for now — Task 7 replaces it.

- [ ] **Step 6: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasModelTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 14 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasUndoTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS — 1C-a's undo tests exercise `CanvasUndo` directly and must survive the rebinding untouched. **If any of them fails, `CanvasModel` has changed the class rather than rebinding it** — that is the failure this task is most likely to produce, so read the failure rather than adjusting the test.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasCompositionTests -only-testing MaughamTests/CanvasAccessibilityTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS. Both are **source-grep** tests over `CanvasView.swift` — layer order, and `.onChange(of: sceneRevision` keyed on the structural counter rather than the redraw one. A refactor that renames either counter or reorders the ZStack fails here and nowhere else.

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
- Consumes: `CanvasScene`, `CanvasRegion`, `CanvasRegionID`, `CanvasMembership` (Tasks 1–2); `CanvasModel` (Task 4); `CanvasCamera` (1C-a Task 4) with `pan: CGPoint`, `zoom: CGFloat`, `visibleContentRect(viewSize:) -> CGRect`; `ScrapLayout` (1C-a Task 3); `CanvasFocusStraighten` (1C-a Task 7); `CanvasRenderer` (1C-a Task 7) — an `enum` with `static func seededRotation(for:) -> Angle`, `static func drawnAngle(for:straighten:) -> Angle`, `static func cardTransform(inCard:angle:) -> CGAffineTransform`, `static func localPoint(_:inCard:angle:) -> CGPoint`, `static func visibleNodes(in:camera:viewSize:) -> [CanvasNode]`, `static func placeholderLabel(forReference:) -> String`, `static func drawsOwnText(_:visibleEditorNodeID:) -> Bool`, `static func draw(scene:camera:viewSize:layouts:visibleEditorNodeID:straighten:into:)`, and `private static func drawCard(_:frame:layout:angle:into:)`.
- Produces on `CanvasRenderer`: `static let regionLayerDepth/nodeLayerDepth`, `static func visibleRegions(in:camera:viewSize:)`, `struct Tether`, `static func tethers(in:)`, `struct AppearanceChip` (`node`, `region`, `homeRegion`, `frame`), `static let chipHeight`, `static func appearanceChips(in:)`, `static func homeAnchor(of:in:)`, `static func chipTitle(for:in:scraps:)`, `static func regionStroke(isSelected:)`, and `static func visibleNodes(in:camera:viewSize:hidingCollapsedResidents:)`.
- Amends `CanvasRenderer.draw` to `draw(scene:camera:viewSize:layouts:scraps:selectedRegionID:visibleEditorNodeID:straighten:into:)` — **two parameters added to 1C-a's five; none renamed, none removed.**

**Three things about 1C-a's `draw` that this task must not undo.** Its signature went through a fix round after this plan's first draft, and each change was made for a named defect:

1. **The suppression parameter is `visibleEditorNodeID:`, not `editingNodeID:`.** 1C-a keeps three states apart — `editingNodeID` (the writer is editing it), `mountedEditorNodeID` (its editor exists and takes keystrokes, from the click), `visibleEditorNodeID` (its editor *is* the visible text, from `straighten.isLevel`). For the ~120 ms of the straighten the editor exists and is invisible, and the renderer must **keep drawing that card's text** — it is live text, off the same `NSTextStorage` the invisible editor is mutating. 1C-a records that the `editingNodeID:` spelling blanked it from frame one, so the glyphs vanished and reappeared straight. That is the §7A.2 jump arriving by §7A.5's own route.
2. **The parameter suppresses the node's TEXT, never its CARD.** 1C-a's loop calls `drawCard` unconditionally and passes `layout: nil` when `drawsOwnText` is false. A `continue` would make the focused card disappear the moment it is clicked — and §7A.5's whole affordance is that the focused card is the only square one on the canvas, which needs a card to be square.
3. **The card's rotation comes from `drawnAngle(for:straighten:)` through `cardTransform(inCard:angle:)`,** applied to a *copy* of the context inside `drawCard`. There is no inline `cx.rotate(by: seededRotation(...))` in `draw` any more, and a grep test in 1C-a forbids `rotate(by:)` and `rotationEffect` anywhere in `Maugham/Canvas/` — one definition of the rotation, used forwards by the draw pass and inverted by the caret hit test, because a flipped convention doubles the caret error rather than removing it and a round-trip test passes either way.

**Regions, tethers and chips draw in canvas space, outside the card transform — and that is exactly right, not a shortcut.** `cardTransform` is concatenated onto a *local copy* of the context inside `drawCard`, so it never leaks into the passes around it. A region is not a card and has no seeded angle: it is a wash with a label, drawn under the camera CTM alone. The two places this could have gone wrong are the two anchors, and both are safe **because the card's rotation fixes its own centre**: `cardTransform` translates to `(midX, midY)`, rotates, and translates back, so a card's midpoint maps to itself at any angle. `tethers(in:)` and `homeAnchor(of:in:)` both anchor on `frame.midX/midY`, so a tether meets a tilted card at precisely the point it meets an untilted one, and no straighten value can make the line drift off its card. Anchoring on a corner instead would need the transform applied and would visibly slide during the 120 ms straighten. **Do not anchor a tether or a hairline on anything but a midpoint without also applying `cardTransform`.**

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

    /// A collapsed region hides its residents, so a tether to one would be a
    /// line running to a card that is not drawn.
    func test_aCollapsedRegionDrawsNoTethers() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        s.move(CanvasNodeID("a"), to: CGPoint(x: 5000, y: 5000))
        XCTAssertEqual(CanvasRenderer.tethers(in: s).count, 1)
        s.updateRegion(CanvasRegionID("r1")) { $0.isCollapsed = true }
        XCTAssertTrue(CanvasRenderer.tethers(in: s).isEmpty,
                      "a tether to a hidden card is a line to nowhere")
    }

    /// The tether anchors on the card's CENTRE, which is the fixed point of
    /// `cardTransform` — so §7A.5's straighten cannot slide the line off its
    /// card during the 120ms animation.
    func test_aTetherAnchorsOnTheRotationFixedPoint() {
        var s = scene()
        CanvasMembership.join(CanvasNodeID("a"), home: CanvasRegionID("r1"), in: &s)
        s.move(CanvasNodeID("a"), to: CGPoint(x: 5000, y: 5000))
        let tether = CanvasRenderer.tethers(in: s).first!
        let frame = s.node(CanvasNodeID("a"))!.frame!
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(tether.from, centre)
        let tilted = CanvasRenderer.cardTransform(
            inCard: frame, angle: CanvasRenderer.seededRotation(for: CanvasNodeID("a")))
        XCTAssertEqual(centre.applying(tilted).x, centre.x, accuracy: 0.0001)
        XCTAssertEqual(centre.applying(tilted).y, centre.y, accuracy: 0.0001)
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
            for: CanvasNodeID("a"), in: scene(),
            scraps: [CanvasNodeID("a"): "The falls at night.\nSodium light on the spray."])
        XCTAssertEqual(title, "The falls at night.")
    }

    func test_anEmptyScrapStillGetsAReadableChipTitle() {
        XCTAssertEqual(CanvasRenderer.chipTitle(for: CanvasNodeID("a"), in: scene(),
                                                scraps: [CanvasNodeID("a"): "   "]),
                       "Untitled")
    }

    /// An item node's chip reads the SAME placeholder its card reads, so a chip
    /// and its card can never disagree about what the thing is called. 1C-a
    /// draws item cards as `Item · <referenceId>`; when 1C-d resolves real
    /// titles it changes `placeholderLabel` and both surfaces follow.
    func test_aChipTitleForAnItemMatchesTheLabelItsCardDraws() {
        var s = scene()
        var item = CanvasNode(id: CanvasNodeID.item("r-9"), kind: .item(referenceId: "r-9"),
                              origin: CGPoint(x: 300, y: 50), width: 240)
        item.cachedHeight = 60
        s.insert(item)
        XCTAssertEqual(CanvasRenderer.chipTitle(for: CanvasNodeID.item("r-9"), in: s, scraps: [:]),
                       CanvasRenderer.placeholderLabel(forReference: "r-9"))
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

**There is no `CanvasItemPresentation` in this slice, and that is a constraint, not an oversight.** An earlier draft of this plan had `chipTitle` take a `presentations: [CanvasNodeID: CanvasItemPresentation]` map and cited 1C-a Task 12 as its source. 1C-a's Global Constraints forbid building that type outright — "**Do not build:** a drop target, `CanvasItemPresentation` or any title/thumbnail resolution… If a task seems to need one of these, it belongs to **1C-d**" — so the citation named a type 1C-a never ships.

Regions do not genuinely need it, which is why this task drops the dependency rather than deferring to 1C-d. A chip names a node that is already on the canvas, and 1C-a gives every node kind a name: a scrap's is its first line, an item's is `CanvasRenderer.placeholderLabel(forReference:)`, which is the same string that node's *card* draws. So `chipTitle(for:in:scraps:)` takes the scene, switches on the node's kind, and needs nothing from the project store. That also means 1C-b can be executed against 1C-a alone, with 1C-d in either order — and when 1C-d resolves real titles it changes one function and both the card and the chip follow, which is a stronger guarantee than passing the same map to two call sites.

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionRenderTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `type 'CanvasRenderer' has no member 'visibleRegions'`.

- [ ] **Step 3: Add the region-drawing surface to `CanvasRenderer`**

```swift
    /// Regions draw beneath nodes so a region never occludes the cards it holds.
    /// Expressed as constants rather than as draw order alone so the ordering is
    /// assertable.
    static let regionLayerDepth = 0
    static let nodeLayerDepth = 1

    /// `unorderedRegions`, not `regions` — this runs once per frame and the
    /// survivors all get drawn, so the sort would buy nothing. Same reasoning as
    /// 1C-a's `visibleNodes`.
    static func visibleRegions(in scene: CanvasScene,
                               camera: CanvasCamera,
                               viewSize: CGSize) -> [CanvasRegion] {
        let viewport = camera.visibleContentRect(viewSize: viewSize)
        return scene.unorderedRegions.filter { $0.frame.intersects(viewport) }
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
    ///
    /// Both endpoints are MIDPOINTS, and that is load-bearing rather than
    /// convenient: a card's midpoint is the fixed point of
    /// `cardTransform(inCard:angle:)`, so the line meets a tilted card at
    /// exactly the point it meets an untilted one and §7A.5's straighten cannot
    /// slide it. A corner anchor would need the transform applied here and would
    /// drift visibly through the 120 ms animation.
    static func tethers(in scene: CanvasScene) -> [Tether] {
        scene.unorderedRegions.flatMap { region -> [Tether] in
            // A collapsed region's residents are not drawn, so a tether to one
            // would be a line running to nothing.
            guard !region.isCollapsed else { return [] }
            return region.homeMembers.sorted { $0.raw < $1.raw }.compactMap { nodeID in
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
    ///
    /// An item node's chip reads `placeholderLabel(forReference:)` — the SAME
    /// function its card reads — so a chip and its card cannot disagree about
    /// what the thing is called. This is deliberately not a
    /// `[CanvasNodeID: CanvasItemPresentation]` map: that type belongs to 1C-d,
    /// 1C-a's Global Constraints forbid building it, and routing both surfaces
    /// through one function is the stronger guarantee anyway. When 1C-d resolves
    /// real titles it replaces `placeholderLabel` and both follow.
    static func chipTitle(for id: CanvasNodeID,
                          in scene: CanvasScene,
                          scraps: [CanvasNodeID: String]) -> String {
        if case .item(let referenceId)? = scene.node(id)?.kind {
            return placeholderLabel(forReference: referenceId)
        }
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
        let hidden = scene.unorderedRegions
            .filter(\.isCollapsed)
            .reduce(into: Set<CanvasNodeID>()) { $0.formUnion($1.homeMembers) }
        return visible.filter { !hidden.contains($0.id) }
    }
```

- [ ] **Step 4: Amend `draw` — two new parameters, and the node pass left alone**

1C-a's `draw` takes `scene:camera:viewSize:layouts:visibleEditorNodeID:straighten:into:`. **Two arguments join them and none are renamed or removed:** `scraps:`, because a chip shows its subject's first line, and `selectedRegionID:`, because the selection ring is drawn rather than being a view overlay. They go in the positions below.

The **node pass is 1C-a's, unchanged in every respect but one** — the loop is now fed by the collapse-aware overload. Do not reintroduce the inline rotation or the `continue`: `drawCard` is called for every visible node and receives `angle:` from `drawnAngle(for:straighten:)`, and a suppressed node gets `layout: nil` rather than being skipped. Both were fixed in 1C-a for named defects (see the Interfaces block above); re-typing the older shape here would undo both.

```swift
    /// Draw the whole scene under the camera's CTM, in four passes:
    /// regions, tethers, nodes, chips. The order is the design: a region must
    /// never occlude the cards it holds (`regionLayerDepth < nodeLayerDepth`),
    /// and a chip must never be hidden behind the card it references.
    ///
    /// Regions, tethers and chips are drawn in CANVAS space, under the camera
    /// CTM alone. The card rotation lives on a local copy of the context inside
    /// `drawCard` and never leaks out here — a region is not a card and carries
    /// no seeded angle. Every anchor a tether or hairline lands on is a card
    /// MIDPOINT, which is `cardTransform`'s fixed point, so none of them move
    /// as a card straightens.
    ///
    /// `visibleEditorNodeID` suppresses that node's TEXT only — its card is
    /// still drawn. See `drawsOwnText`, and 1C-a Task 7 for why this is neither
    /// `editingNodeID` nor `mountedEditorNodeID`.
    static func draw(scene: CanvasScene,
                     camera: CanvasCamera,
                     viewSize: CGSize,
                     layouts: [CanvasNodeID: ScrapLayout],
                     scraps: [CanvasNodeID: String],
                     selectedRegionID: CanvasRegionID?,
                     visibleEditorNodeID: CanvasNodeID?,
                     straighten: CanvasFocusStraighten,
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

        // 3. Nodes — 1C-a's pass, with the collapse-aware culling overload.
        //    Residents of a collapsed region are hidden: a view state, never a
        //    membership change.
        for node in visibleNodes(in: scene, camera: camera, viewSize: viewSize,
                                 hidingCollapsedResidents: true) {
            guard let frame = node.frame else { continue }
            let ownText = drawsOwnText(node.id, visibleEditorNodeID: visibleEditorNodeID)
            drawCard(node, frame: frame,
                     layout: ownText ? layouts[node.id] : nil,
                     angle: drawnAngle(for: node.id, straighten: straighten),
                     into: &cx)
        }

        // 4. Chips last, on top of the region they annotate.
        for chip in appearanceChips(in: scene) {
            drawChip(chip,
                     title: chipTitle(for: chip.node, in: scene, scraps: scraps),
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

Inside the `TimelineView(.animation(paused:))` block in `CanvasView.body` — the clock 1C-a Task 10 built and Task 13 widened. The `_ = drawRevision` line and the `.onChange(of: context.date)` stepping stay exactly as they are; only the argument list grows:

```swift
                Canvas { cx, size in
                    _ = drawRevision
                    CanvasRenderer.draw(scene: model.scene, camera: camera, viewSize: size,
                                        layouts: layouts,
                                        scraps: model.scraps,
                                        selectedRegionID: model.selectedRegionID,
                                        visibleEditorNodeID: visibleEditorNodeID,
                                        straighten: straighten,
                                        into: &cx)
                }
```

`visibleEditorNodeID` is 1C-a's computed property (`editingNodeID` **and** `straighten.isLevel(id)`) — the same one property that gates `ScrapEditorHost`'s visibility, so the drawn text and the editor cannot flip on different frames. Do not substitute `editingNodeID` or `mountedEditorNodeID` here.

- [ ] **Step 6: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionRenderTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 15 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRendererTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 21 tests — 1C-a's renderer tests must survive the signature change untouched. They cover the straighten, `drawsOwnText`, `cardTransform` against literal trigonometry, and the grep that forbids a second rotation or a hand-derived raster scale anywhere in `Maugham/Canvas/`. **If the grep test fails, this task reintroduced `rotate(by:)` in `draw`** — fix the draw pass, not the test.

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
- Consumes: `CanvasScene`, `CanvasRegion`, `CanvasRegionID`, `CanvasMembership` (Tasks 1–2); `CanvasModel` with `withScene(persist:_:)`, `beginGesture(_:)`, `endGesture()`, `deleteSelectedRegion()`, `selectedRegionID` (Task 4); `CanvasInteraction` (1C-a **Task 13**) — a `struct` with `private enum Mode`, `private var mode: Mode`, `static let minimumScrapWidth/defaultScrapWidth`, `var isActive: Bool`, `var activeNodeID: CanvasNodeID?`, `var isResizing: Bool`, `mutating func begin(at:in:)`, `beginResize(_:at:in:)`, `update(to:in:)`, `@discardableResult mutating func end() -> (id: CanvasNodeID, velocity: CGSize)?`, `static func createScrap(at:in:) -> CanvasNodeID`; `CanvasMomentum` (1C-a Task 13); `CanvasDragPhase` (1C-a Task 6) — `case began/changed/ended`, **the only drag vocabulary in the slice**; `CanvasEventView` (1C-a Task 6) taking `camera: Binding<CanvasCamera>`, `onClick: (CGPoint, Int) -> Void`, `onDrag: (CGPoint, CanvasDragPhase) -> Void`, `undoManager: UndoManager?`.
- Produces on `CanvasInteraction`: `static let minimumRegionSide/regionChromeHeight/regionResizeHandleSide`, `enum RegionHit`, `static func regionHit(at:in:)`, `static func joinTarget(for:in:)`, `mutating func beginRegionDrag(_:at:in:)`, `mutating func beginRegionResize(_:at:in:)`, `mutating func endDrag(in:)`, `static func createRegion(from:to:in:) -> CanvasRegionID?`.
- Produces on `CanvasEventNSView`/`CanvasEventView`: `onDeleteKey: (() -> Void)?`.
- Produces on `CanvasView`: `@State private var regionDrawStart: CGPoint?`.

**`CanvasEventView`'s callbacks are 1C-a's, and one of them forces a new piece of view state.** `onDrag` is `(CGPoint, CanvasDragPhase) -> Void` — **one** point and a phase, not a start-and-current pair, and the phase type is `CanvasDragPhase`; 1C-a states flatly that "there is no `DragPhase`". So a ⌥-drag that draws a region cannot read its start point out of the `.ended` callback: the view has to remember where the press landed. That is `regionDrawStart`, set at `.began` and consumed at `.ended`. And `undoManager:` must keep being passed — it is what vends the canvas undo stack to the responder chain, so ⌘Z works with nothing focused.

**Undo is not optional here.** This task adds three mutating gestures and one destructive one. 1C-a **Task 15** established that every gesture is bracketed; a region drag that moved eleven cards and cannot be taken back is exactly how a spatial surface loses a writer's trust, and a ⌘Z that instead undoes the *previous* scrap edit is worse than none.

**There is exactly one undo mechanism, and `model.beginGesture` *is* `CanvasUndo.beginGesture`.** Task 4 makes `CanvasModel` a forwarder onto 1C-a's recorder rather than a second implementation, so the two are the same call and there is nothing to nest by accident. Region gestures therefore **extend 1C-a's existing brackets in `handleDrag`** rather than adding a parallel set: `.began` opens one gesture with the right name, `.ended` closes it, and `CanvasUndo`'s depth counter absorbs any re-entry. Do not open a second bracket around an interaction that is already inside one, and do not reach past the model to `model.undo` — the four forwarding methods are the whole surface.

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

    /// `endDrag` must leave the mode alone so the `end()` that follows still
    /// reports the flick §7.3's momentum is launched from. Clearing it here
    /// kills momentum on every card, silently, with no other test noticing.
    func test_theJoinDoesNotConsumeTheDragThatMomentumNeeds() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 110, y: 110), in: s)
        i.update(to: CGPoint(x: 310, y: 210), in: &s)
        i.endDrag(in: &s)
        XCTAssertTrue(i.isActive, "endDrag reports the join; end() ends the drag")
        XCTAssertNotNil(i.end(), "the flick must survive the join")
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

    /// `groupsByEvent` must be off in any test that calls `undo()` synchronously
    /// — see 1C-a's CanvasUndoTests and this plan's Global Constraints.
    private func undoableModel() -> CanvasModel {
        let model = CanvasModel()
        model.undoManager.groupsByEvent = false
        model.withScene { $0 = self.scene() }
        return model
    }

    func test_aRegionDragIsOneUndoStepAndRestoresItsResidents() {
        let model = undoableModel()
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
        let model = undoableModel()
        var i = CanvasInteraction()
        model.beginGesture("Move Scrap")
        i.begin(at: CGPoint(x: 110, y: 110), in: model.scene)
        model.withScene { i.update(to: CGPoint(x: 310, y: 210), in: &$0) }
        model.withScene { i.endDrag(in: &$0) }
        i.end()
        model.endGesture()
        XCTAssertTrue(model.scene.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")))

        model.undoManager.undo()
        XCTAssertFalse(model.scene.region(CanvasRegionID("r1"))!.livesHere(CanvasNodeID("a")),
                       "one ⌘Z takes back the move AND the join it caused")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionInteractionTests CODE_SIGNING_ALLOWED=NO`
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
    ///
    /// **This does NOT reset `mode`, and must be called BEFORE `end()`.**
    /// 1C-a's `end()` is what clears the mode, and it returns the flick velocity
    /// §7.3's momentum is launched from. An earlier draft cleared the mode here
    /// with a `defer`, so the `end()` that followed saw `.idle`, returned nil,
    /// and every card stopped dead where the writer released it — momentum
    /// silently gone, with no test failing.
    mutating func endDrag(in scene: inout CanvasScene) {
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

In `Maugham/Canvas/CanvasEventView.swift`, on `CanvasEventNSView`. **1C-a already declares `override var acceptsFirstResponder: Bool { true }` — do not add a second one**, the file will not compile:

```swift
    /// ⌫ deletes the selected REGION, and nothing else. **1C-a ships no node
    /// delete path at all** — a scrap is removed by emptying it, and there is no
    /// key handler for nodes to collide with. Deleting item nodes belongs to
    /// 1C-d. This callback is a no-op unless a region is selected, which
    /// `CanvasView` decides via `deleteSelectedRegion()`.
    ///
    /// A focused scrap's editor is frontmost and first responder, so a ⌫ typed
    /// inside a scrap never reaches this view.
    var onDeleteKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 51 = delete, 117 = forward delete.
        guard event.keyCode == 51 || event.keyCode == 117 else {
            super.keyDown(with: event)
            return
        }
        onDeleteKey?()
    }
```

and pass it through `CanvasEventView` alongside `onClick`/`onDrag`/`undoManager`, wiring it in `wire(_:)` exactly as those are wired.

- [ ] **Step 5: Route the gestures in `CanvasView`**

This **extends 1C-a's `handleDrag(at:phase:)`** — one method, one `switch` over `CanvasDragPhase`. Do not split it into three; the event view has one callback and the existing brackets, guards, momentum and counter bumps all live in this switch.

Hit order is **resize handle → card → region chrome → empty canvas**, and it is a decision, not an accident: a card lying under a region's label bar must still be pickable, because the card is the thing the writer is looking at.

```swift
    /// ⌥-drag on empty canvas draws a region. Read from `NSEvent` rather than
    /// threaded through the event view's callbacks: modifier state at press
    /// time is exactly what `NSEvent.modifierFlags` reports, and widening
    /// `onDrag` would break 1C-a's "one drag vocabulary" for one Bool.
    private var isDrawingRegionGesture: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    private func handleDrag(at contentPoint: CGPoint, phase: CanvasDragPhase) {
        switch phase {
        case .began:
            // 1C-a's guard: a focused scrap owns its own mouse, because the
            // editor is in front of the event view.
            guard editingNodeID == nil else { return }
            momentum.stop()

            if case .resizeHandle(let id)? = CanvasInteraction.regionHit(at: contentPoint,
                                                                        in: model.scene) {
                model.selectedRegionID = id
                model.beginGesture("Resize Region")
                interaction.beginRegionResize(id, at: contentPoint, in: model.scene)
            } else if model.scene.topmostNode(at: contentPoint) != nil {
                interaction.begin(at: contentPoint, in: model.scene)
                if interaction.isActive {
                    model.beginGesture(interaction.isResizing ? "Resize Scrap" : "Move Scrap")
                }
            } else if case .chrome(let id)? = CanvasInteraction.regionHit(at: contentPoint,
                                                                         in: model.scene) {
                model.selectedRegionID = id
                model.beginGesture("Move Region")
                interaction.beginRegionDrag(id, at: contentPoint, in: model.scene)
            } else if isDrawingRegionGesture {
                // `onDrag` reports ONE point per call, so the press point has to
                // be remembered here — `createRegion` needs both corners.
                regionDrawStart = contentPoint
                model.beginGesture("Draw Region")
            }
            // A plain drag on empty canvas does nothing; panning is the scroll
            // wheel, which the event view handles without reaching this method.

        case .changed:
            guard interaction.isActive else { return }
            model.withScene { interaction.update(to: contentPoint, in: &$0) }
            revision += 1

        case .ended:
            if interaction.isActive {
                let wasResizing = interaction.isResizing
                // The one membership-changing gesture, and only for node drags —
                // `endDrag` ignores region modes. It runs BEFORE `end()`, which
                // is what clears the mode and returns the flick.
                model.withScene { interaction.endDrag(in: &$0) }
                let flick = interaction.end()
                if wasResizing {
                    rebuildLayouts()          // bumps sceneRevision itself
                } else if let flick {
                    momentum.launch(flick.id, velocity: flick.velocity)
                }
            } else if let start = regionDrawStart {
                model.withScene { scene in
                    if let id = CanvasInteraction.createRegion(from: start, to: contentPoint,
                                                               in: &scene) {
                        model.selectedRegionID = id
                    }
                }
                interaction.end()
            } else {
                interaction.end()
            }
            regionDrawStart = nil
            // A gesture that changed nothing registers no step — CanvasUndo
            // diffs the snapshot before it registers.
            model.endGesture()
            sceneRevision += 1
            revision += 1
        }
    }
```

Note that the region-draw branch is gated on `regionDrawStart` rather than on re-reading `isDrawingRegionGesture`: the modifier is sampled once at press time, so releasing ⌥ mid-drag cannot abandon a region the writer is halfway through drawing.

The event view keeps 1C-a's argument list and gains the delete hook:

```swift
                CanvasEventView(
                    camera: $camera,
                    onClick: { viewPoint, clickCount in
                        handleClick(at: camera.contentPoint(fromView: viewPoint),
                                    clickCount: clickCount)
                    },
                    onDrag: { viewPoint, phase in
                        handleDrag(at: camera.contentPoint(fromView: viewPoint), phase: phase)
                    },
                    // Task 15 of 1C-a filled this in; it vends the canvas undo
                    // stack to the responder chain so ⌘Z works with nothing
                    // focused. Dropping it here would silently kill that.
                    undoManager: model.undoManager,
                    onDeleteKey: { model.deleteSelectedRegion() })
```

Selecting a region on a chrome press (above) and clearing it on a single click (Task 4's one added line in `handleClick`) are the whole selection model. There is no marquee.

- [ ] **Step 6: Run the tests and a Release build**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionInteractionTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 17 tests.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasInteractionTests -only-testing MaughamTests/CanvasMomentumTests -only-testing MaughamTests/CanvasEventViewTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS, 13 + 7 + 10 tests — 1C-a's scrap gestures, its momentum decay and its input vocabulary are all unchanged by the new `Mode` cases and the new callback. **`CanvasMomentumTests` passing is not enough on its own**: it exercises `CanvasMomentum` directly, and the way this task can kill momentum is by consuming the drag before `interaction.end()` sees it. `test_theJoinDoesNotConsumeTheDragThatMomentumNeeds` is the one that catches that.

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
- Consumes: `CanvasRegion`, `CanvasRegionID`, `CanvasScene.updateRegion(_:_:)`, `CanvasMembership.leave(_:from:in:)` (Tasks 1–2); `CanvasModel` with `scene`, `scraps`, `selectedRegion`, `selectedRegionID`, `mutate(_:_:)`, `deleteSelectedRegion()`, `flush()` (Task 4); `CanvasRenderer.chipTitle(for:in:scraps:)` (Task 5); `ProjectStore.manifest.structure: [StructureItem]` (`id`, `title`, `type == .document`) and `MaughamCore`'s `TreeWalk.collect(in:where:)`.
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
        // Required by any test that calls `undo()` synchronously — see the
        // Global Constraints and 1C-a's CanvasUndoTests.
        model.undoManager.groupsByEvent = false
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

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/RegionBindingTests CODE_SIGNING_ALLOWED=NO`
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
                Text(CanvasRenderer.chipTitle(for: id, in: model.scene,
                                              scraps: model.scraps))
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
- Modify: `Maugham/Canvas/AREA.md` (created by 1C-a **Task 17**)
- Modify: `docs/adr/0026-planning-canvas-rendering.md` (created by 1C-a **Task 17**)
- Modify: `CLAUDE.md` (tripwire table)
- Modify: `docs/guide/` (the topic covering personas), `docs/roadmap.md`, `docs/problem-map.md`

**Interfaces:**
- Consumes: everything Tasks 1–7 shipped, plus `Maugham/Canvas/AREA.md` and `docs/adr/0026-planning-canvas-rendering.md` from 1C-a **Task 17**.
- Produces: no code. Doc-sync tests must stay green.

**ADR decision, made here so no one has to relitigate it:** this slice **amends ADR 0026** with a "Membership" section. It does **not** mint a new ADR number. Membership is part of the same canvas-architecture decision the ADR already records, and 1C-c is being written in parallel — an unplanned number in this slice would collide with it. If 1C-c wants its own ADR for promotion, it takes the next free number; this slice takes none.

- [ ] **Step 1: Extend AREA.md**

Add a "Membership" section covering: explicit-only; the three tools that got it wrong and how; the one-home invariant and both places it is enforced (`CanvasMembership.join` and `CanvasSceneDTO`'s loader); what travels on a region drag (residents, never visitors); that removal is always its own act; and that drop targeting is **greatest overlap**, never the node's corner.

State plainly: **if you are about to write `region.frame.contains(node.origin)` near membership, you are reintroducing the bug class this design exists to eliminate.**

Add a "Who owns what" paragraph, because it is the question the next reader will have: `CanvasModel` owns scene, scraps, selection, the store and the undo stack, and is owned by `ProjectWindow` because two columns read it; `CanvasView` owns camera, layouts, editing focus, the straighten, momentum and both revision counters, because those belong to one *view* of the canvas.

Two sentences of that paragraph are load-bearing and should be written as rules, not as description:

- **`CanvasModel` hosts `CanvasUndo`; it does not reimplement it.** 1C-a built the recorder to reach its state through `readSnapshot`/`applySnapshot` closures *specifically* so ownership could move here, and the model's gesture methods are four forwards. A second snapshot mechanism silently loses `breakGesture` (per-sentence ⌘Z inside a scrap), the deferred `beginUndoGrouping` (a group cannot span an event boundary), the nesting depth counter, and the mid-gesture re-baseline. **Named symptom for the last one:** type in A, click into B, ⌘Z, type in B, click out — and the next ⌘Z resurrects A's discarded text.
- **`sceneRevision` exists in two places on purpose.** `CanvasView`'s `@State` copy keeps its name because `CanvasAccessibilityTests` greps the source for `.onChange(of: sceneRevision`; the model's copy exists because the inspector mutates the scene from the other column and cannot reach a view's `@State`. The view mirrors the model's in one `.onChange`. Neither may be keyed on `revision`, which ticks at 60–120 Hz through every drag, coast and straighten.

- [ ] **Step 2: Amend ADR 0026**

Add a section recording: membership is stored and geometry never changes it (with the Obsidian/tldraw #6017/Scapple evidence); one home plus many appearances, and why copies were rejected; that the accepted cost — a resident sitting outside its region — is paid in the renderer as a tether; and that region state persists in the canvas sidecar at schema 2, not in the manifest, which is why the inspector takes a `CanvasModel` rather than a `ProjectStore`. Cite the constitution principles by name, per CLAUDE.md.

- [ ] **Step 3: Add the tripwire**

Add to CLAUDE.md's tripwire table. **1C-a Task 17 adds three — 25, 26 and 27 — so this slice's is 28.** Check the table before writing the row rather than trusting this number: if 1C-c merged first it may have taken 28, and a duplicate tripwire number is worse than a gap.

| # | Rule | Why | Enforced |
|---|---|---|---|
| 31 | Canvas membership is never derived from geometry — not on move, not on resize, not on region creation. Drop-to-join targets by greatest overlap and is the ONLY gesture that changes it | Obsidian, tldraw (#6017) and Scapple each ship a distinct bug from the geometry→membership transition rule; tldraw's persists *despite* explicit storage | `CanvasMembershipTests` (the firewall tests were falsified by introducing the tldraw ejection bug); `CanvasRegionInteractionTests` |

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
git commit -m "docs(canvas): membership rules, geometry tripwire 31, ADR 0026 amendment, guide sweep"
```

---

## Whole-slice verification

- [ ] Full Mac suite, full phone suite, Release build — all green
- [ ] **Whole-branch review** of the 1C-b diff. Per-task reviews cannot see emergent interactions; the T5×T6 precedent on the unified-undo milestone is why this is not optional. Look especially at the Task 4 refactor's blast radius across 1C-a's `CanvasView` — read the `CanvasView.swift` diff line by line and confirm that **nothing 1C-a shipped was deleted**: the straighten clock and its timeline, `mountedEditorNodeID`/`visibleEditorNodeID`, momentum, `revision` and `sceneRevision`, `lastKeystrokeAt`, all three commit points (`onTextChanged`, `.onDisappear`, `beforeFlush`), and every `beginGesture`/`endGesture`/`breakGesture` bracket. Tasks 4 and 6 both rewrite parts of that file and each can plausibly land green while having quietly dropped one of them.
- [ ] `git diff --stat` on `Maugham/Canvas/CanvasView.swift` is a *small* number. A large one means the file was retyped rather than edited.
- [ ] `git status` shows nothing under `Maugham.xcodeproj/`
- [ ] Smoke: draw a region with ⌥-drag over two existing cards → confirm it absorbed neither → drag one card in → drag the region by its label bar → the resident travels, the other card does not → **⌘Z once puts the whole drag back** → resize the region from its corner until it is tiny → the resident is still a member → drag the resident far outside → a tether draws → cite a second card as an appearance → it renders as a chip, visibly not a card, hairlined to its home → select the region → rename it in the inspector → collapse it → its residents vanish and the label says how many → bind it to a piece → press ⌫ → the region goes, the cards stay → ⌘Z → it comes back with its membership → quit and reopen → everything survives
- [ ] Smoke: **the 1C-a behaviours Task 4 and Task 6 could have broken, none of which a region test would notice** — flick a card and let go: it coasts and comes to rest rather than stopping dead (momentum survived the drop-to-join) → double-click a scrap: it straightens over a beat and the text does not blink or jump as the editor takes over → double-click empty canvas and type immediately: the first characters are all there → type two sentences into a scrap, then ⌘Z twice: it takes back a sentence at a time, not the whole visit → type a sentence and ⌘Q without clicking away, then reopen: the sentence is there

**Do not push or tag.**




