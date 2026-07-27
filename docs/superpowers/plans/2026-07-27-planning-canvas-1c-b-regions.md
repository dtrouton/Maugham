# Planning canvas 1C-b — regions and membership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

*Re-derived 2026-07-27 against 1C-a **as built** (branch `feat/planning-canvas-1c-a-2026-07-25`, HEAD `dfde12e`, 2953 tests green). Supersedes `2026-07-25-planning-canvas-1c-b-regions.md`, which was written against an API that did not exist yet. Roughly half its bulk was restating 1C-a's signatures; that half is gone, because `grep` is now authoritative and the compiler rejects a wrong symbol on sight.*

**Goal:** Add labelled regions — the canvas's only grouping primitive — with membership that is stored rather than computed, one home region per node plus any number of appearances, an optional binding from a region to a piece, and the delete path 1C-a left without a caller.

**Architecture:** A region is a value in `CanvasScene` beside the nodes, so region edits ride 1C-a's existing snapshot undo for free. Membership is an explicit set on the region, mutated only by a drop or an explicit remove; geometry never adds or removes a member. A node *lives in* one region and may *appear in* any number; only its home region moves it. Scene, scrap text, selection and the undo recorder move out of `CanvasView`'s `@State` onto an `@Observable CanvasModel` that `ProjectWindow` owns, because two columns now read the same canvas.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, XCTest. Mac target only — `Packages/MaughamCore` and `MaughamPhone` are untouched (spec §9).

---

## Global Constraints

**Read `Maugham/Canvas/AREA.md` before touching anything in that directory.** It is 1C-a's own account of what it built and why, it is current as of `dfde12e`, and it is shorter than this plan.

- **Membership is stored, never recomputed from coordinates at read time** (spec §4.2, §8). If you find yourself writing `region.frame.contains(node.origin)` anywhere near membership, stop — Task 1's tests exist to catch exactly that.
- **A node lives in exactly one region and may appear in any number** (spec §4.3). Appearances are references, never copies: "copies are rejected outright".
- **An appearance must not render identically to the thing itself** (spec §4.3), or the copy problem returns visually.
- **Only nodes that *live* in a region are bound to its piece** (spec §4.4). Visitors are not, or two regions sharing a card would each claim it.
- **Nested regions are out of scope** (spec §9). A drag that starts inside an existing region's interior draws nothing.
- **No `Packages/MaughamCore` or `MaughamPhone` changes.** If you touch MaughamCore, `swift test --package-path Packages/MaughamCore` is the only thing that runs its tests — not the `Maugham` scheme, not CI.

### Build and process

- `./gen.sh` after adding ANY new file. **Every Step 2 in this plan begins with `./gen.sh &&`, including the RED runs** — until `gen.sh` has run, a brand-new test file is not in the project, `-only-testing MaughamTests/<Class>` runs **zero** tests, and reports **success**. A green RED step is worse than no RED step.
- `-only-testing` takes `MaughamTests/<ClassName>` — **never a folder path** (a folder path runs zero tests and reports success).
- Run `xcodebuild` in the **foreground**, one at a time; two invocations contend for one DerivedData.
- **Release build after anything touching a view.** The Release type-check budget is stricter than Debug; v0.8.0 shipped a Release-only failure that passed Debug.
- **Never commit anything under `Maugham.xcodeproj/`.** A `project.pbxproj` in a diff is a red flag.
- No raw `NotificationCenter` post or subscription (tripwire 21). This slice adds no events; do not add one.

### `ProjectWindow.body` has a ZERO expression budget

`ProjectWindow.body` is at 28 chained expressions with eleven extracted `ViewModifier`s existing solely to buy expressions back. The ceiling has been hit twice, once passing Debug and failing Release CI.

- **Adding a `@State` property is free** — a stored property is not a body expression. Task 3 adds exactly one.
- `existingEditorSwitch(store:documentStore:)` and `existingInspectorSwitch(store:)` are separate `@ViewBuilder` methods, type-checked separately from `body`. Their `.canvas` arms may grow, but **keep each arm to a single expression** — extract a helper method if it needs more. Task 7 does exactly that.
- **Do not add a line to `body` itself.**

### Five source-layout contracts in `CanvasView.swift`

Read that file's header comment before editing it. Three grep tests slice it as **text**, and a reformat breaks one of them with a failure message pointing somewhere else entirely. Tasks 3, 5 and 6 all edit this file. The contracts cover: the order of `body` / `mountedEditorNodeID` / `visibleEditorNodeID` / `mountedEditor` / `load()`, the blank lines between two of those declarations, and two modifier names that must not appear **even in a comment**. The header states all five precisely; this plan does not restate them, because a second copy is a copy that drifts.

### The three editor states are three things

`editingNodeID` (the writer is editing it), `mountedEditorNodeID` (its editor exists and takes keystrokes, from the click), `visibleEditorNodeID` (its editor *is* the visible text, from `straighten.isLevel`). **These have been merged four times, in both directions**, producing jumping text and lost keystrokes. A census test guards them. Do not globally substitute.

Likewise `revision` (redraw, ticks every animation frame) and `sceneRevision` (structural). **Nothing scene-proportional may key off `revision`** — tripwire 30.

### Tests that call `undo()` synchronously must set `groupsByEvent = false` first

`UndoManager` defaults it to `true`, which installs a run-loop observer that opens an implicit top-level group per event; calling `undo()` synchronously outside a run loop while that group is open raises `NSInternalInconsistencyException`. Production *also* sets it false (see `CanvasView.undoManager` for the long reason), so a test that sets it is exercising the shipping configuration, not a test-only one. `CanvasModel` creates its manager the same way; a test that constructs its own manager sets it itself.

### The five lessons 1C-a paid for, in priority order

1. **For anything with a menu item, a key equivalent or a gesture, ONE test must model the real delivery path end to end.** Both of 1C-a's smoke bugs were the same shape: the tests drove the *mechanism* and never the path the writer takes. Twenty-two undo tests passed on a feature ⌘Z could not reach; every resize test asserted after `.ended`, so nobody saw the card vanish mid-drag. In this slice that binds **Task 5** (region gestures, driven through `CanvasEventNSView`, not through `CanvasInteraction` alone) and **Task 6** (⌫, driven as a real key event through the responder chain).
2. **Seventeen assertions across 1C-a's plans could not fail for the reason they existed** — one asserted two `NSTextView` states that cannot coexist, one leaned on `sorted(by:>)` being stable, one demanded a rewrap its own fixture could not produce, one compared `[]` to `[].sorted()`. Assume the same density here and hunt for it deliberately. Every task below ends with a step that asks it.
3. **A pre-flight-verified number is verified against the tree as it was.** Re-derive arithmetic against built code at the moment you use it.
4. **Comments that predict behaviour age badly; measurements do not.** Three 1C-a implementers refused a reviewer's prescription *with a measurement* and were upheld. If you disagree with this plan, measure and say so in the report.
5. **`pump()` in `CanvasViewMountingTests` does not wait for its argument** — `RunLoop.run(until:)` returns as soon as it has nothing left to service. That is *fine* for asserting on disk, because the 750 ms save debounce is itself a scheduled source and `pump(1.0)` waits for it; it is **wrong** for anything that needs time to pass with nothing scheduled, above all `ScrapUndoBeat.idleSeconds`. Use `waitOut(_:)` there, and only there.

---

## File Structure

| File | Responsibility |
|---|---|
| `Maugham/Canvas/CanvasRegion.swift` | *Create* — `CanvasRegionID`, `CanvasRegion`, `CanvasRegionMetrics`, `CanvasSelection` |
| `Maugham/Canvas/CanvasMembership.swift` | *Create* — the membership rules: home vs appearance, the invariants, the mutations |
| `Maugham/Canvas/CanvasModel.swift` | *Create* — the one owner of scene, scraps, selection, the store and the undo recorder |
| `Maugham/Canvas/RegionBinding.swift` | *Create* — region → piece binding, and the references it exposes |
| `Maugham/Canvas/RegionInspector.swift` | *Create* — label, collapse, piece binding, membership lists, delete |
| `Maugham/Canvas/CanvasScene.swift` | *Modify* — regions join the scene; hidden nodes; `remove` scrubs membership |
| `Maugham/Canvas/CanvasSceneCodec.swift` | *Modify* — schema 1 → 2 |
| `Maugham/Canvas/CanvasMaterial.swift` | *Modify* — region wash, stroke and tether tunables (light/dark pairs) |
| `Maugham/Canvas/CanvasRenderer.swift` | *Modify* — regions beneath nodes; tethers; appearance chips; collapsed tiles |
| `Maugham/Canvas/CanvasAccessibility.swift` | *Modify* — regions join the AX tree; hidden residents leave it |
| `Maugham/Canvas/CanvasInteraction.swift` | *Modify* — region draw, drag-with-residents, resize, drop-to-join |
| `Maugham/Canvas/CanvasEventView.swift` | *Modify* — a delete-key path |
| `Maugham/Canvas/CanvasView.swift` | *Modify* — reads the model; routes region gestures; the ⌫ handler |
| `Maugham/Views/ProjectWindow.swift` | *Modify* — owns the `CanvasModel`; the `.canvas` inspector arm |

---

### Task 1: The region model and the geometry firewall

**Files:**
- Create: `Maugham/Canvas/CanvasRegion.swift`
- Create: `Maugham/Canvas/CanvasMembership.swift`
- Modify: `Maugham/Canvas/CanvasScene.swift`
- Test: `MaughamTests/Canvas/CanvasRegionTests.swift`
- Test: `MaughamTests/Canvas/CanvasMembershipTests.swift`

**Interfaces:**
- Consumes: `CanvasNodeID`, `CanvasNode`, `CanvasScene` — `Maugham/Canvas/CanvasNode.swift` and `CanvasScene.swift`. Read them; they are 100 lines each.
- Produces: `CanvasRegionID`, `CanvasRegion`, `CanvasRegionMetrics`, `CanvasSelection`, `enum CanvasMembership`, and on `CanvasScene`: `regions`, `unorderedRegions`, `regionCount`, `region(_:)`, `insertRegion(_:)`, `removeRegion(_:)`, `updateRegion(_:_:)`, `setRegionFrame(_:for:)`, `isHidden(_:)`.

**Why this is one task and not two.** A `CanvasRegion` with no membership rules is a struct nobody can review: the whole judgement is whether coordinates can reach the membership sets, and that judgement needs both halves in front of it.

**Why membership is explicit — the evidence, once.** Spec §4.2 is a bug-class elimination, not a preference. **Obsidian** leaves a card poking one pixel outside a group. **tldraw** ejects children when a frame is resized — *despite storing membership explicitly* ([#6017](https://github.com/tldraw/tldraw/issues/6017)) — because the hazard is the geometry→membership *transition rule*, independent of storage. **Scapple** recomputes from live geometry and has an unfixed bug where a note shared by two overlapping shapes moves with whichever shape you grab. The accepted cost is that a node can sit visually outside the region that owns it; that is a **rendering** problem, paid in Task 4 as a tether.

**Two model decisions that are load-bearing further down:**

- **`CanvasScene.remove(_:)` must scrub the node from every region.** It has no production caller today (1C-a shipped no delete path); Task 6 gives it one, and a deleted scrap that leaves a ghost member behind would resurrect as a phantom in the inspector's "lives here" list and in `RegionBinding.references(forPiece:)`.
- **Collapse hides residents in the SCENE, not in the renderer.** `topmostNode(at:)` and `nodes(intersecting:)` both skip hidden nodes, so hit testing, dragging, culling and drawing agree by construction and no `hidingCollapsedResidents:` parameter has to be threaded to four callers. `unorderedNodes` deliberately still returns everything, because `CanvasView.rebuildLayouts()` must keep measuring a hidden scrap or expanding a region would show unmeasured, unclickable cards.

- [ ] **Step 1: Write the failing tests**

`MaughamTests/Canvas/CanvasRegionTests.swift`:

```swift
import XCTest
@testable import Maugham

final class CanvasRegionTests: XCTestCase {

    private func region(_ raw: String = "r1") -> CanvasRegion {
        CanvasRegion(id: CanvasRegionID(raw), label: "Act II fog",
                     frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    }

    func test_anUnlabelledRegionStillHasSomethingToShow() {
        var r = region()
        r.label = ""
        XCTAssertEqual(r.displayLabel, CanvasRegion.untitledLabel)
        r.label = "Falls"
        XCTAssertEqual(r.displayLabel, "Falls")
    }

    func test_aFreshRegionOwnsNothing() {
        let r = region()
        XCTAssertTrue(r.homeMembers.isEmpty)
        XCTAssertTrue(r.appearances.isEmpty)
        XCTAssertNil(r.boundPieceID)
        XCTAssertFalse(r.isCollapsed)
    }

    /// The chrome bar is the only part of a region a writer can grab, so its
    /// geometry is read by BOTH the renderer and the hit test. One spelling.
    func test_theChromeBarSitsAtTheTopOfTheRegionAndInsideIt() {
        let f = CGRect(x: 10, y: 20, width: 600, height: 400)
        let chrome = CanvasRegionMetrics.chromeRect(in: f)
        XCTAssertEqual(chrome.minY, f.minY)
        XCTAssertEqual(chrome.height, CanvasRegionMetrics.chromeHeight)
        XCTAssertEqual(chrome.width, f.width)
        XCTAssertTrue(f.contains(chrome))
    }

    func test_theResizeHandleSitsInTheBottomRightCornerAndInsideIt() {
        let f = CGRect(x: 10, y: 20, width: 600, height: 400)
        let handle = CanvasRegionMetrics.resizeHandleRect(in: f)
        XCTAssertEqual(handle.maxX, f.maxX)
        XCTAssertEqual(handle.maxY, f.maxY)
        XCTAssertEqual(handle.width, CanvasRegionMetrics.resizeHandleSide)
        XCTAssertTrue(f.contains(handle))
    }

    /// The two targets must not overlap, or a corner press on a short region is
    /// a coin flip between resizing it and dragging it.
    func test_theChromeBarAndTheResizeHandleNeverOverlap() {
        let f = CGRect(x: 0, y: 0, width: CanvasRegionMetrics.minimumSide,
                       height: CanvasRegionMetrics.minimumSide)
        XCTAssertFalse(CanvasRegionMetrics.chromeRect(in: f)
            .intersects(CanvasRegionMetrics.resizeHandleRect(in: f)),
            "at the SMALLEST region a writer can make — larger ones only "
            + "separate them further")
    }

    func test_regionsAreOrderedDeterministicallyByID() {
        var s = CanvasScene()
        for raw in ["r3", "r1", "r2"] {
            s.insertRegion(CanvasRegion(id: CanvasRegionID(raw), label: raw, frame: .zero))
        }
        XCTAssertEqual(s.regions.map(\.id.raw), ["r1", "r2", "r3"])
    }
}
```

`MaughamTests/Canvas/CanvasMembershipTests.swift` — the first four are the firewall, and they are why this task exists:

```swift
import XCTest
@testable import Maugham

final class CanvasMembershipTests: XCTestCase {

    private let r1 = CanvasRegionID("r1")
    private let r2 = CanvasRegionID("r2")
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for (i, id) in [a, b].enumerated() {
            s.insert(CanvasNode(id: id, kind: .scrap,
                                origin: CGPoint(x: CGFloat(i) * 50, y: 0),
                                width: 240, cachedHeight: 80))
        }
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        s.insertRegion(CanvasRegion(id: r2, label: "Falls",
                                    frame: CGRect(x: 800, y: 0, width: 600, height: 400)))
        return s
    }

    // MARK: - The geometry firewall

    /// §4.2: coordinates never ADD a member.
    func test_movingANodeIntoARegionsRectDoesNotJoinIt() {
        var s = scene()
        XCTAssertFalse(s.region(r1)!.livesHere(b),
                       "precondition: 'b' already sits geometrically inside r1 and "
                       + "was never joined — so the assertion below is about the "
                       + "MOVE and not about the starting state")
        s.move(b, to: CGPoint(x: 100, y: 100))
        XCTAssertFalse(s.region(r1)!.livesHere(b), "geometry must never add a member")
    }

    /// §4.2: coordinates never REMOVE one. This is the tether's whole reason.
    func test_movingAMemberOutsideItsRegionDoesNotRemoveIt() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.move(a, to: CGPoint(x: 5_000, y: 5_000))
        XCTAssertTrue(s.region(r1)!.livesHere(a))
    }

    /// tldraw #6017, which ships this bug *despite* storing membership.
    func test_resizingARegionNeverEjectsMembers() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.setRegionFrame(CGRect(x: 0, y: 0, width: CanvasRegionMetrics.minimumSide,
                                height: CanvasRegionMetrics.minimumSide), for: r1)
        XCTAssertTrue(s.region(r1)!.livesHere(a))
    }

    func test_movingARegionAwayFromItsMembersKeepsThem() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.setRegionFrame(CGRect(x: 9_000, y: 9_000, width: 600, height: 400), for: r1)
        XCTAssertTrue(s.region(r1)!.livesHere(a))
    }

    // MARK: - One home, many appearances

    func test_joiningASecondRegionMovesTheHomeRatherThanAddingOne() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.join(a, home: r2, in: &s)
        XCTAssertFalse(s.region(r1)!.livesHere(a))
        XCTAssertTrue(s.region(r2)!.livesHere(a))
        XCTAssertEqual(CanvasMembership.homeRegion(of: a, in: s), r2)
    }

    func test_aNodeMayAppearInAnyNumberOfRegions() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(a, to: r2, in: &s)
        XCTAssertEqual(CanvasMembership.homeRegion(of: a, in: s), r1)
        XCTAssertEqual(CanvasMembership.appearanceRegions(of: a, in: s), [r2])
    }

    /// A node cannot be both resident and visitor in ONE region — the renderer
    /// would draw it as a card and as a chip at once, and §4.3 says an
    /// appearance must not render identically to the thing itself.
    func test_aNodeIsNeverBothAResidentAndAVisitorInTheSameRegion() {
        var s = scene()
        CanvasMembership.addAppearance(a, to: r1, in: &s)
        CanvasMembership.join(a, home: r1, in: &s)
        XCTAssertTrue(s.region(r1)!.livesHere(a))
        XCTAssertFalse(s.region(r1)!.appearsHere(a))

        CanvasMembership.addAppearance(a, to: r1, in: &s)
        XCTAssertTrue(s.region(r1)!.livesHere(a),
                      "citing the region a node already lives in is a no-op, not a demotion")
        XCTAssertFalse(s.region(r1)!.appearsHere(a))
    }

    func test_leavingClearsBothKindsOfMembershipInThatRegionOnly() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(a, to: r2, in: &s)
        CanvasMembership.leave(a, from: r1, in: &s)
        XCTAssertNil(CanvasMembership.homeRegion(of: a, in: s))
        XCTAssertEqual(CanvasMembership.appearanceRegions(of: a, in: s), [r2],
                       "leaving one region must not touch another")
    }

    // MARK: - What travels

    func test_onlyResidentsTravelWithTheirRegion() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        XCTAssertEqual(CanvasMembership.residents(of: r1, in: s), [a],
                       "a visitor is not luggage (§4.3)")
    }

    func test_aResidentWhoseNodeIsGoneDoesNotTravel() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.updateRegion(r1) { $0.addHome(CanvasNodeID("ghost")) }
        XCTAssertEqual(CanvasMembership.residents(of: r1, in: s), [a],
                       "residents() answers about NODES, so a stale id cannot make "
                       + "the drag loop reach for a node that is not there")
    }

    // MARK: - Deleting a node

    func test_removingANodeScrubsItFromEveryRegion() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(a, to: r2, in: &s)
        s.remove(a)
        XCTAssertFalse(s.region(r1)!.livesHere(a))
        XCTAssertFalse(s.region(r2)!.appearsHere(a),
                       "a ghost member would resurface in the inspector's list and "
                       + "in RegionBinding.references(forPiece:)")
    }

    func test_removingARegionLeavesItsCardsOnTheCanvas() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.removeRegion(r1)
        XCTAssertNotNil(s.node(a), "deleting a region never deletes cards")
        XCTAssertNil(CanvasMembership.homeRegion(of: a, in: s))
    }

    // MARK: - Collapse hides residents, in the scene

    func test_aResidentOfACollapsedRegionIsNotHitTestable() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        let inside = CGPoint(x: 10, y: 10)
        XCTAssertEqual(s.topmostNode(at: inside)?.id, a, "precondition: it is hit-testable now")
        s.updateRegion(r1) { $0.isCollapsed = true }
        XCTAssertNil(s.topmostNode(at: inside))
        XCTAssertTrue(s.isHidden(a))
    }

    func test_aVisitorToACollapsedRegionIsStillOnTheCanvas() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        s.updateRegion(r1) { $0.isCollapsed = true }
        XCTAssertFalse(s.isHidden(b),
                       "a visitor's card lives somewhere else — collapsing the "
                       + "region that cites it must not make the real thing vanish")
    }

    func test_aHiddenResidentIsNotDrawnAndIsStillMeasured() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.updateRegion(r1) { $0.isCollapsed = true }
        let everywhere = CGRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000)
        XCTAssertFalse(s.nodes(intersecting: everywhere).contains { $0.id == a })
        XCTAssertTrue(s.unorderedNodes.contains { $0.id == a },
                      "rebuildLayouts() walks unorderedNodes — stop measuring a "
                      + "hidden scrap and expanding the region shows unmeasured, "
                      + "unclickable cards")
    }

    func test_expandingARegionBringsItsResidentsBack() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.updateRegion(r1) { $0.isCollapsed = true }
        s.updateRegion(r1) { $0.isCollapsed = false }
        XCTAssertFalse(s.isHidden(a))
        XCTAssertEqual(s.topmostNode(at: CGPoint(x: 10, y: 10))?.id, a)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionTests -only-testing MaughamTests/CanvasMembershipTests CODE_SIGNING_ALLOWED=NO`
Expected: compile failure — `cannot find 'CanvasRegion' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/CanvasRegion.swift`**

```swift
import Foundation

/// Stable identity for a region. Minted by `CanvasInteraction.createRegion`
/// with a uniqueness loop against the scene — never by a bare random call
/// (tripwire 23's lesson, applied to a second id space).
public struct CanvasRegionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// What the canvas has selected. ONE selection covers both primitives, so ⌫
/// has a single meaning and the inspector has a single thing to read.
public enum CanvasSelection: Equatable, Sendable {
    case node(CanvasNodeID)
    case region(CanvasRegionID)
}

/// A labelled area drawn on the canvas — the canvas's only grouping primitive
/// (spec §4).
///
/// **Membership is stored here and is changed only by a deliberate act.**
/// Coordinates never add or remove a member: not on move, not on resize, not on
/// creation. See `CanvasMembership` for the mutations and `AREA.md` for the
/// three shipping tools that each get this wrong differently.
///
/// The two sets are disjoint by construction — `addHome` drops the node from
/// `appearances` and `addAppearance` declines when the node already lives here.
/// A node in both would draw as a card and as a reference chip at once, which is
/// exactly the "you cannot tell which is real" failure §4.3 forbids.
public struct CanvasRegion: Equatable, Sendable {

    /// Shown wherever the label would be blank. A region drawn by a drag starts
    /// unlabelled and is named in the inspector, so this is the common case for
    /// the first few seconds of every region's life — it must not read as empty
    /// chrome.
    public static let untitledLabel = "Untitled region"

    public let id: CanvasRegionID
    public var label: String
    public var frame: CGRect
    /// Nodes that LIVE here. Only these travel when the region is dragged, and
    /// only these are bound to the region's piece (§4.4).
    public private(set) var homeMembers: Set<CanvasNodeID>
    /// Nodes that merely APPEAR here — references, never copies (§4.3).
    public private(set) var appearances: Set<CanvasNodeID>
    /// §4.4's bridge. Produced here, consumed by 1A's reference rail.
    public var boundPieceID: String?
    /// §7/§10: crowding at Playlist scale is answered by collapsing, not by
    /// minting more canvases.
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
        // Enforced at the initialiser too, because the codec builds regions
        // through it and a hand-edited sidecar is not obliged to be coherent.
        self.appearances = appearances.subtracting(homeMembers)
        self.boundPieceID = boundPieceID
        self.isCollapsed = isCollapsed
    }

    public var displayLabel: String { label.isEmpty ? Self.untitledLabel : label }

    public func livesHere(_ id: CanvasNodeID) -> Bool { homeMembers.contains(id) }
    public func appearsHere(_ id: CanvasNodeID) -> Bool { appearances.contains(id) }
    public func mentions(_ id: CanvasNodeID) -> Bool { livesHere(id) || appearsHere(id) }

    public mutating func addHome(_ id: CanvasNodeID) {
        appearances.remove(id)
        homeMembers.insert(id)
    }

    public mutating func addAppearance(_ id: CanvasNodeID) {
        guard !homeMembers.contains(id) else { return }
        appearances.insert(id)
    }

    public mutating func forget(_ id: CanvasNodeID) {
        homeMembers.remove(id)
        appearances.remove(id)
    }
}

/// Region geometry, in ONE place — the same discipline `CanvasCardMetrics`
/// applies to cards, and for the same reason: `CanvasRenderer` draws the chrome
/// bar and the resize corner, `CanvasInteraction` hit-tests them, and a second
/// spelling puts the mark and the target on different rects.
public enum CanvasRegionMetrics {
    /// The label bar along the top — the only part of a region a writer can
    /// grab. The interior belongs to the cards in it: grabbing anywhere inside
    /// would make it impossible to pick up a card that sits in a region, which
    /// is most of them.
    public static let chromeHeight: CGFloat = 24
    /// Matches `CanvasRenderer.resizeHandleSize` in intent, not by reference:
    /// the two targets are on different objects and either may be tuned without
    /// the other.
    public static let resizeHandleSide: CGFloat = 14
    /// Below this a region has no interior left to hold anything, and its two
    /// grab targets would meet.
    public static let minimumSide: CGFloat = 80
    /// Breathing room for the label inside the chrome bar. Same 10pt
    /// `CanvasCardMetrics` gives a card's text.
    public static let labelInset: CGFloat = 10

    public static func chromeRect(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY,
               width: frame.width, height: min(chromeHeight, frame.height))
    }

    public static func resizeHandleRect(in frame: CGRect) -> CGRect {
        CGRect(x: frame.maxX - resizeHandleSide, y: frame.maxY - resizeHandleSide,
               width: resizeHandleSide, height: resizeHandleSide)
    }

    public static func labelOrigin(in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + labelInset, y: frame.minY + labelInset / 2)
    }
}
```

- [ ] **Step 4: Write `Maugham/Canvas/CanvasMembership.swift`**

```swift
import Foundation

/// The membership rules (spec §4.2–§4.4), as free functions over the scene.
///
/// **Every mutation here is a deliberate act.** There is no entry point that
/// takes a point, a rect or an overlap — the drop gesture in
/// `CanvasInteraction` decides *which* region a drop meant and then calls
/// `join`; deciding is the gesture's job and recording is this file's, and
/// keeping the two apart is what stops geometry leaking into membership.
public enum CanvasMembership {

    /// Make `region` the node's home, taking it out of whatever region it lived
    /// in before. One home, always (§4.3).
    public static func join(_ node: CanvasNodeID,
                            home region: CanvasRegionID,
                            in scene: inout CanvasScene) {
        for other in scene.unorderedRegions where other.id != region && other.livesHere(node) {
            scene.updateRegion(other.id) { $0.forget(node) }
        }
        scene.updateRegion(region) { $0.addHome(node) }
    }

    /// Cite the node in `region` without moving it there. A reference, not a
    /// copy — "copies are rejected outright" (§4.3).
    public static func addAppearance(_ node: CanvasNodeID,
                                     to region: CanvasRegionID,
                                     in scene: inout CanvasScene) {
        scene.updateRegion(region) { $0.addAppearance(node) }
    }

    /// Take the node out of `region` entirely, whichever way it was in.
    /// Removal is always its own act; nothing about a coordinate reaches here.
    public static func leave(_ node: CanvasNodeID,
                             from region: CanvasRegionID,
                             in scene: inout CanvasScene) {
        scene.updateRegion(region) { $0.forget(node) }
    }

    public static func homeRegion(of node: CanvasNodeID,
                                  in scene: CanvasScene) -> CanvasRegionID? {
        scene.unorderedRegions.first { $0.livesHere(node) }?.id
    }

    /// In `regions` order, so the inspector and the renderer list a node's
    /// appearances the same way twice running.
    public static func appearanceRegions(of node: CanvasNodeID,
                                         in scene: CanvasScene) -> [CanvasRegionID] {
        scene.regions.filter { $0.appearsHere(node) }.map(\.id)
    }

    /// What travels when the region is dragged: its residents, and only those
    /// that are still real nodes. Filtering on the scene here is what stops a
    /// stale id — from a hand-edited sidecar, or from a node deleted in a
    /// snapshot the undo has not yet caught up with — reaching the drag loop.
    public static func residents(of region: CanvasRegionID,
                                 in scene: CanvasScene) -> Set<CanvasNodeID> {
        guard let r = scene.region(region) else { return [] }
        return r.homeMembers.filter { scene.node($0) != nil }
    }
}
```

- [ ] **Step 5: Add regions to `CanvasScene`**

Add to `Maugham/Canvas/CanvasScene.swift`, keeping every existing declaration and doc comment intact:

```swift
    private var regionsByID: [CanvasRegionID: CanvasRegion] = [:]

    /// Residents of collapsed regions, precomputed.
    ///
    /// Hit testing and culling both consult this, and both run at pointer rate
    /// over the whole scene — asking each node "is any collapsed region my home"
    /// inside those loops is `O(nodes × regions)` per click and per frame. It is
    /// refreshed only when a region changes, which is a gesture, not a frame.
    private var hiddenNodes: Set<CanvasNodeID> = []

    public init(nodes: [CanvasNode] = [], regions: [CanvasRegion] = []) {
        byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        regionsByID = Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        refreshHiddenNodes()
    }

    /// Regions in a total, stable order. There is no z among regions — they all
    /// draw beneath every card — so id order is enough, and it is what makes the
    /// sidecar byte-identical across a save of an unchanged canvas.
    public var regions: [CanvasRegion] {
        regionsByID.values.sorted { $0.id.raw < $1.id.raw }
    }

    public var unorderedRegions: [CanvasRegion] { Array(regionsByID.values) }
    public var regionCount: Int { regionsByID.count }

    public func region(_ id: CanvasRegionID) -> CanvasRegion? { regionsByID[id] }

    /// Whether this node is a resident of a collapsed region, and therefore not
    /// on screen, not clickable and not in the accessibility tree.
    public func isHidden(_ id: CanvasNodeID) -> Bool { hiddenNodes.contains(id) }

    public mutating func insertRegion(_ region: CanvasRegion) {
        regionsByID[region.id] = region
        refreshHiddenNodes()
    }

    /// Removes the region and nothing else. **Its cards stay on the canvas** —
    /// spec §3.1's rule for items generalised: the canvas owns arrangement, not
    /// existence.
    public mutating func removeRegion(_ id: CanvasRegionID) {
        regionsByID[id] = nil
        refreshHiddenNodes()
    }

    public mutating func updateRegion(_ id: CanvasRegionID,
                                      _ body: (inout CanvasRegion) -> Void) {
        guard regionsByID[id] != nil else { return }
        body(&regionsByID[id]!)
        refreshHiddenNodes()
    }

    public mutating func setRegionFrame(_ frame: CGRect, for id: CanvasRegionID) {
        regionsByID[id]?.frame = frame
        // Deliberately no `refreshHiddenNodes()`: a frame change cannot alter
        // membership, which is the whole of §4.2. Calling it here would be
        // harmless and would still be the wrong shape — the next reader would
        // read it as geometry feeding membership.
    }

    private mutating func refreshHiddenNodes() {
        guard regionsByID.values.contains(where: \.isCollapsed) else {
            hiddenNodes = []
            return
        }
        hiddenNodes = regionsByID.values
            .filter(\.isCollapsed)
            .reduce(into: Set<CanvasNodeID>()) { $0.formUnion($1.homeMembers) }
    }
```

Amend `remove(_:)` — it currently reads `byID[id] = nil`:

```swift
    /// Removes the node, and every region's record of it. A ghost member would
    /// resurface in the inspector's "lives here" list and in
    /// `RegionBinding.references(forPiece:)` long after the card was gone.
    public mutating func remove(_ id: CanvasNodeID) {
        byID[id] = nil
        for region in regionsByID.values where region.mentions(id) {
            regionsByID[region.id]?.forget(id)
        }
        refreshHiddenNodes()
    }
```

Amend the two query methods to skip hidden nodes, keeping their existing doc comments and adding a sentence to each:

```swift
    public func topmostNode(at point: CGPoint) -> CanvasNode? {
        byID.values
            .filter { !hiddenNodes.contains($0.id) && $0.frame?.contains(point) == true }
            .max(by: Self.isBehind)
    }

    public func nodes(intersecting rect: CGRect) -> [CanvasNode] {
        byID.values
            .filter { !hiddenNodes.contains($0.id) && $0.frame?.intersects(rect) == true }
            .sorted(by: Self.isBehind)
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionTests -only-testing MaughamTests/CanvasMembershipTests -only-testing MaughamTests/CanvasSceneTests -only-testing MaughamTests/CanvasPerformanceProbeTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS. `CanvasSceneTests` and the performance probe are in the run because this task changed `topmostNode(at:)`, `nodes(intersecting:)`, `remove(_:)` and the initialiser under them.

- [ ] **Step 7: Falsify two of the firewall tests**

Not optional, and it is the step that makes the rest of this task worth anything. **Temporarily** introduce the tldraw bug — make `setRegionFrame` drop members that fall outside the new frame — and confirm `test_resizingARegionNeverEjectsMembers` goes red. Then **temporarily** make `move(_:to:)` join whatever region now contains the node, and confirm `test_movingANodeIntoARegionsRectDoesNotJoinIt` goes red. Revert both.

Record both results in the task report. A firewall test that stays green while the bug is present is worse than no test, because it certifies the thing it is not checking.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Canvas/CanvasRegion.swift Maugham/Canvas/CanvasMembership.swift \
        Maugham/Canvas/CanvasScene.swift MaughamTests/Canvas/CanvasRegionTests.swift \
        MaughamTests/Canvas/CanvasMembershipTests.swift
git commit -m "feat(canvas): regions, and membership that geometry cannot reach"
```

---

### Task 2: Persist regions — sidecar schema 1 → 2

**Files:**
- Modify: `Maugham/Canvas/CanvasSceneCodec.swift`
- Test: `MaughamTests/Canvas/CanvasRegionCodecTests.swift`

**Interfaces:**
- Consumes: Task 1's types; `CanvasStore` (`Maugham/Canvas/CanvasStore.swift`, 124 lines — read it).
- Produces: `CanvasSceneDTO.currentSchemaVersion == 2`, a nested `CanvasSceneDTO.RegionDTO`, and an optional `regions` key. No new top-level type.

**What the version bump costs and why it is right.** `CanvasStore.load()` refuses any sidecar whose `schemaVersion` exceeds the current one and returns an empty layout with the words intact. So a canvas written by this build opens on a 1C-a build as an **empty canvas with every scrap's text still in `canvas.md`** — layout lost, words safe. That is the correct failure and it is the one the split between the two files exists to produce (§8). M1 is unreleased, so no writer is exposed to it.

**The loader repairs, it does not trust.** A sidecar is a file on disk a writer may have edited. Two repairs, both silent and both lossless in the direction that matters:

- **Two regions claiming the same node as home** — first in id order keeps it, the others demote it to an appearance. Demoting rather than dropping preserves the true fact (that region cited this node) instead of inventing or discarding one.
- **Membership naming a node that is not in the scene** — dropped. A node whose `kind` this build does not understand is already dropped by 1C-a's loader, so this case arrives for free from a future build and is not hypothetical.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Maugham

final class CanvasRegionCodecTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-region-codec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func sidecarURL() -> URL {
        root.appendingPathComponent(CanvasStore.sidecarRelativePath)
    }

    private func writeSidecar(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: sidecarURL().deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: sidecarURL(), atomically: true, encoding: .utf8)
    }

    private func sceneWithOneOfEverything() -> CanvasScene {
        var s = CanvasScene()
        for id in ["a", "b"] {
            s.insert(CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                                origin: CGPoint(x: 10, y: 20), width: 240, cachedHeight: 80))
        }
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 10, y: 20, width: 300, height: 200),
                                    homeMembers: [CanvasNodeID("a")],
                                    appearances: [CanvasNodeID("b")],
                                    boundPieceID: "piece-3",
                                    isCollapsed: true))
        return s
    }

    func test_everyFieldOfARegionSurvivesADiskRoundTrip() {
        CanvasStore(projectRoot: root).save(scene: sceneWithOneOfEverything(), scraps: [:])
        let r = CanvasStore(projectRoot: root).load().scene.region(CanvasRegionID("r1"))
        XCTAssertEqual(r?.label, "Act II fog")
        XCTAssertEqual(r?.frame, CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(r?.homeMembers, [CanvasNodeID("a")])
        XCTAssertEqual(r?.appearances, [CanvasNodeID("b")])
        XCTAssertEqual(r?.boundPieceID, "piece-3")
        XCTAssertEqual(r?.isCollapsed, true)
    }

    func test_theSidecarIsByteIdenticalAcrossTwoSavesOfOneScene() throws {
        let scene = sceneWithOneOfEverything()
        CanvasStore(projectRoot: root).save(scene: scene, scraps: [:])
        let first = try Data(contentsOf: sidecarURL())
        CanvasStore(projectRoot: root).save(scene: scene, scraps: [:])
        XCTAssertEqual(first, try Data(contentsOf: sidecarURL()),
                       "membership is held in Sets, whose iteration order is not "
                       + "stable across runs — the encoder must sort")
    }

    /// A sidecar written by 1C-a has no `regions` key at all.
    func test_aSchemaV1SidecarLoadsItsNodesAndNoRegions() throws {
        try writeSidecar("""
        {"schemaVersion":1,"nodes":[{"id":"a","kind":"scrap","x":5,"y":6,\
        "width":240,"cachedHeight":80,"z":1}]}
        """)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(scene.count, 1)
        XCTAssertEqual(scene.node(CanvasNodeID("a"))?.origin, CGPoint(x: 5, y: 6))
        XCTAssertEqual(scene.regionCount, 0)
    }

    func test_theSchemaVersionIsActuallyBumped() {
        XCTAssertEqual(CanvasSceneDTO.currentSchemaVersion, 2)
    }

    /// The repair, not the crash. Both regions claim 'a' as home.
    func test_twoRegionsClaimingOneHomeAreRepairedRatherThanTrusted() throws {
        try writeSidecar("""
        {"schemaVersion":2,"nodes":[{"id":"a","kind":"scrap","x":0,"y":0,\
        "width":240,"cachedHeight":80,"z":1}],"regions":[\
        {"id":"r2","label":"B","x":0,"y":0,"width":100,"height":100,\
        "homeMembers":["a"],"appearances":[],"isCollapsed":false},\
        {"id":"r1","label":"A","x":0,"y":0,"width":100,"height":100,\
        "homeMembers":["a"],"appearances":[],"isCollapsed":false}]}
        """)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(CanvasMembership.homeRegion(of: CanvasNodeID("a"), in: scene),
                       CanvasRegionID("r1"),
                       "first in id order keeps the home — and note the file lists "
                       + "r2 first, so a loader that merely took the first ENTRY "
                       + "would pass this by accident")
        XCTAssertEqual(CanvasMembership.appearanceRegions(of: CanvasNodeID("a"), in: scene),
                       [CanvasRegionID("r2")],
                       "demoted, not dropped: that region really did cite the node")
    }

    func test_membershipNamingANodeThatIsNotThereIsDropped() throws {
        try writeSidecar("""
        {"schemaVersion":2,"nodes":[],"regions":[\
        {"id":"r1","label":"A","x":0,"y":0,"width":100,"height":100,\
        "homeMembers":["ghost"],"appearances":["spectre"],"isCollapsed":false}]}
        """)
        let r = CanvasStore(projectRoot: root).load().scene.region(CanvasRegionID("r1"))
        XCTAssertEqual(r?.homeMembers, [])
        XCTAssertEqual(r?.appearances, [])
    }

    /// 1C-a's rule, restated because this task rewrites the loader around it: a
    /// node of an unknown kind is dropped and the rest of the canvas opens.
    func test_aNodeFromTheFutureIsDroppedAndTheRegionStillLoads() throws {
        try writeSidecar("""
        {"schemaVersion":2,"nodes":[{"id":"x","kind":"hologram","x":0,"y":0,\
        "width":240,"z":1}],"regions":[\
        {"id":"r1","label":"A","x":0,"y":0,"width":100,"height":100,\
        "homeMembers":["x"],"appearances":[],"isCollapsed":false}]}
        """)
        let scene = CanvasStore(projectRoot: root).load().scene
        XCTAssertEqual(scene.count, 0)
        XCTAssertEqual(scene.regionCount, 1)
        XCTAssertEqual(scene.region(CanvasRegionID("r1"))?.homeMembers, [],
                       "the scrub has to run AFTER the nodes are decoded, or a "
                       + "dropped node leaves a member behind")
    }

    /// The forward-compat failure, stated so it is a decision and not a surprise.
    func test_aSidecarFromTheFutureCostsTheLayoutAndNotTheWords() throws {
        try writeSidecar("""
        {"schemaVersion":99,"nodes":[{"id":"a","kind":"scrap","x":5,"y":6,\
        "width":240,"cachedHeight":80,"z":1}]}
        """)
        try "\(ScrapText.banner)\n\n## a\n\nthe falls at night\n"
            .write(to: root.appendingPathComponent(CanvasStore.scrapsRelativePath),
                   atomically: true, encoding: .utf8)
        let loaded = CanvasStore(projectRoot: root).load()
        XCTAssertEqual(loaded.scene.count, 0)
        XCTAssertEqual(loaded.scraps[CanvasNodeID("a")], "the falls at night")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionCodecTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL — `currentSchemaVersion` is 1 and `CanvasRegion` does not round-trip.

- [ ] **Step 3: Amend `CanvasSceneCodec.swift`**

Bump the version, add the DTO, encode sorted, and decode into a repair pass:

```swift
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var nodes: [NodeDTO]
    /// Optional so a schema-1 sidecar — every canvas 1C-a wrote — decodes
    /// unchanged rather than throwing on a missing key.
    var regions: [RegionDTO]?

    struct RegionDTO: Codable {
        var id: String
        var label: String
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        /// Sorted on the way out. `Set` iteration order is not stable across
        /// runs, and an unsorted array here makes saving an unchanged canvas
        /// produce a different file every time.
        var homeMembers: [String]
        var appearances: [String]
        var boundPieceID: String?
        var isCollapsed: Bool
    }
```

In `init(scene:)`, after the existing `nodes` mapping:

```swift
        regions = scene.regions.map { r in
            RegionDTO(id: r.id.raw, label: r.label,
                      x: r.frame.minX, y: r.frame.minY,
                      width: r.frame.width, height: r.frame.height,
                      homeMembers: r.homeMembers.map(\.raw).sorted(),
                      appearances: r.appearances.map(\.raw).sorted(),
                      boundPieceID: r.boundPieceID,
                      isCollapsed: r.isCollapsed)
        }
```

In `var scene: CanvasScene`, after the node loop:

```swift
        // AFTER the nodes, and the order is the whole of the scrub: a node of an
        // unknown kind has already been dropped by the loop above, so a region
        // naming it must lose that member too. Ordered by id so the one-home
        // repair below is deterministic rather than dependent on how the file
        // happened to be written.
        var claimedHomes: Set<CanvasNodeID> = []
        for dto in (regions ?? []).sorted(by: { $0.id < $1.id }) {
            let real = { (raws: [String]) -> Set<CanvasNodeID> in
                Set(raws.map(CanvasNodeID.init).filter { s.node($0) != nil })
            }
            var homes = real(dto.homeMembers)
            // One home per node (§4.3). A node already claimed by an earlier
            // region is demoted here rather than dropped — that region really
            // did cite it, and inventing or discarding a relationship are both
            // worse than recording the weaker true one.
            let contested = homes.intersection(claimedHomes)
            homes.subtract(contested)
            claimedHomes.formUnion(homes)

            s.insertRegion(CanvasRegion(
                id: CanvasRegionID(dto.id), label: dto.label,
                frame: CGRect(x: dto.x, y: dto.y, width: dto.width, height: dto.height),
                homeMembers: homes,
                appearances: real(dto.appearances).union(contested),
                boundPieceID: dto.boundPieceID,
                isCollapsed: dto.isCollapsed))
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionCodecTests -only-testing MaughamTests/CanvasStoreTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

- [ ] **Step 5: Check every assertion could fail**

Re-read the seven tests above and answer, in the report, for each: *what implementation bug would turn this red?* `test_twoRegionsClaimingOneHomeAreRepairedRatherThanTrusted` has its answer written into the fixture (r2 is listed first, so first-entry-wins fails it). Do the same for the others; if one has no answer, say so and fix the test.

- [ ] **Step 6: Commit**

```bash
git add Maugham/Canvas/CanvasSceneCodec.swift MaughamTests/Canvas/CanvasRegionCodecTests.swift
git commit -m "feat(canvas): sidecar schema 2 — regions, with a loader that repairs"
```

---

### Task 3: `CanvasModel` — one owner for scene, scraps, selection and undo

**Files:**
- Create: `Maugham/Canvas/CanvasModel.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`
- Test: `MaughamTests/Canvas/CanvasModelTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2; `CanvasStore`, `CanvasUndo`, `CanvasScene` — read each file.
- Produces: `@Observable final class CanvasModel` with `private(set) var scene`, `private(set) var scraps`, `var selection: CanvasSelection?`, `var selectedRegion: CanvasRegion?`, `private(set) var sceneRevision: Int`, `let undoManager: UndoManager`, `let undo: CanvasUndo`, `var onSceneReplacedByUndo: (() -> Void)?`, `var beforeFlush: (() -> Void)?`, `func attach(projectRoot:)`, `func detach()`, `func withScene(persist:_:)`, `func setScrapText(_:for:)`, `func removeScrapText(_:)`, `func scheduleSave()`, `func flush()`, `func bumpSceneRevision()`, and the four undo forwards `beginGesture(_:)` / `endGesture()` / `breakGesture()` / `mutate(_:_:)`.
- Changes `CanvasView`'s initialiser to `CanvasView(model:projectRoot:paletteSwatchHexes:)`.

**Why this task exists.** Three surfaces need the same scene: the drawn canvas, the region gestures, and the inspector in the right-hand column. In 1C-a the scene is `@State` inside `CanvasView`, so nothing outside that view can read or change it — and an inspector handed a `ProjectStore` could not edit a region label, because region labels do not live in the manifest. So scene, scrap text, selection, the sidecar store and the undo recorder move to one reference type that `ProjectWindow` owns and passes to both views.

**What stays in `CanvasView`, and it is not a detail.** `camera`, `layouts`, `editingNodeID`, `caretIndex`, `straighten`, `interaction`, `momentum`, `wash`, `lastKeystrokeAt`, `revision` and `sceneRevision` all stay. They are properties of one *view* of the canvas; the inspector has no business with any of them, and moving them is how a refactor of this size turns into a rewrite.

**`CanvasModel` hosts `CanvasUndo`; it does not reimplement it.** This is the single most important thing in this task. 1C-a built the recorder to reach its state through `readSnapshot`/`applySnapshot` closures *specifically* so ownership could move here — its own doc comment says so. The model owns a `CanvasUndo`, points the two closures at itself, and forwards four methods. It writes no `registerUndo` of its own. Four behaviours come free that a duplicate would have to re-earn, three of them subtle enough that a duplicate would ship without them:

- **`beginGesture` opens no `UndoManager` group.** A group cannot span an event boundary and an "Edit Scrap" gesture spans as many events as the writer types keystrokes; `endGesture` opens, registers, names and closes in one event, and registers *nothing* when the state did not move.
- **`breakGesture()`** is what gives a long visit to a scrap more than one ⌘Z.
- **Nesting is absorbed** by a depth counter, so a gesture arriving mid-gesture cannot unbalance the manager. Task 5 relies on it.
- **An undo serviced while a gesture is open re-baselines that gesture.** Without it: type in A, click into B, ⌘Z, type in B, click out — and the next ⌘Z resurrects A's discarded text.

**`sceneRevision` exists in two places on purpose.** `CanvasAccessibilityTests` greps `CanvasView.swift` for the literal `.onChange(of: sceneRevision`, so that `@State` keeps its name and its home. The model needs its own because the inspector mutates the scene from the other column and cannot reach a view's `@State`. The view mirrors the model's in one line. Neither may be keyed on `revision`, which ticks at 60–120 Hz through every drag, coast and straighten (tripwire 30).

**`attach`/`detach` preserve 1C-a's lifecycle exactly.** `attach` builds a fresh `CanvasStore`, reads both files, wires `beforeFlush` and the two undo closures. `detach` folds the live edit in, flushes, drops `beforeFlush` and calls `undo.release()`. That is what `CanvasView.load()` and `.onDisappear` do today, moved one object outwards and not otherwise changed — so a persona switch costs the undo stack exactly as it already does, and the retain cycle 1C-a documents is broken in exactly the same place.

**The ordering inside the undo apply, restated because this task moves it.** 1C-a's `applySnapshot` stops the momentum *before* replacing the scene, on the reasoning that a live coast would skate the card away from the restored position. What actually matters is that the coast is stopped **before the next timeline tick**, and the model's apply → `onSceneReplacedByUndo` → `momentum.stop()` chain is entirely synchronous within one call. `test_undoDuringACoastLeavesTheCardWhereTheWriterPickedItUp` in `CanvasViewMountingTests` is the pin, and it must stay green through this task without being edited. If it goes red, the reasoning above is wrong and the fix is to give the model a `willReplace` callback — say so in the report rather than weakening the test.

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

    private let r1 = CanvasRegionID("r1")
    private let a = CanvasNodeID("a")

    private func loadedModel() -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.withScene { s in
            s.insert(CanvasNode(id: self.a, kind: .scrap,
                                origin: CGPoint(x: 100, y: 100), width: 240, cachedHeight: 80))
            s.insertRegion(CanvasRegion(id: self.r1, label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        }
        return model
    }

    /// The seam, end to end: an edit made through the model — which is the ONLY
    /// thing the inspector holds — lands in the sidecar on disk.
    func test_aRegionEditThroughTheModelReachesDisk() {
        let model = loadedModel()
        model.mutate("Rename Region") { $0.updateRegion(self.r1) { $0.label = "Falls" } }
        model.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.region(r1)?.label, "Falls")
    }

    func test_selectionIsModelStateSoTwoReadersSeeOneValue() {
        let model = loadedModel()
        model.selection = .region(r1)
        XCTAssertEqual(model.selectedRegion?.displayLabel, "Act II fog")
        model.selection = .node(a)
        XCTAssertNil(model.selectedRegion, "a selected NODE is not a selected region")
    }

    func test_theModelUsesTheRecorderRatherThanASecondUndoStack() {
        let model = loadedModel()
        model.mutate("Rename Region") { $0.updateRegion(self.r1) { $0.label = "Falls" } }
        XCTAssertTrue(model.undo.canUndo)
        model.undo.undo()
        XCTAssertEqual(model.scene.region(r1)?.label, "Act II fog")
    }

    /// `endGesture` registers nothing when the state did not move — the property
    /// that stops a stray click leaving a ⌘Z that appears to do nothing.
    func test_aGestureThatChangedNothingLeavesNothingToUndo() {
        let model = loadedModel()
        model.mutate("Rename Region") { _ in }
        XCTAssertFalse(model.undo.canUndo)
    }

    /// `breakGesture` is what gives a long visit more than one ⌘Z. A hand-rolled
    /// duplicate loses it silently, so this asks for it directly.
    func test_aBrokenGestureIsTwoStepsRatherThanOne() {
        let model = loadedModel()
        model.beginGesture("Edit Scrap")
        model.setScrapText("one.", for: a)
        model.breakGesture()
        model.setScrapText("one. two.", for: a)
        model.endGesture()

        model.undo.undo()
        XCTAssertEqual(model.scraps[a], "one.")
        model.undo.undo()
        XCTAssertEqual(model.scraps[a] ?? "", "")
    }

    func test_aNestedGestureIsAbsorbedRatherThanUnbalancingTheManager() {
        let model = loadedModel()
        model.beginGesture("Move Region")
        model.beginGesture("Move Scrap")
        model.withScene { $0.move(self.a, to: CGPoint(x: 500, y: 500)) }
        model.endGesture()
        XCTAssertFalse(model.undo.canUndo, "the inner close must not register a step")
        model.endGesture()
        XCTAssertTrue(model.undo.canUndo)

        model.undo.undo()
        XCTAssertEqual(model.scene.node(a)?.origin, CGPoint(x: 100, y: 100),
                       "one ⌘Z, one gesture — the whole outer bracket")
    }

    func test_theStructuralCounterMovesOnAStructuralChangeAndNotOnASave() {
        let model = loadedModel()
        let before = model.sceneRevision
        model.withScene { $0.move(self.a, to: CGPoint(x: 1, y: 1)) }
        XCTAssertEqual(model.sceneRevision, before,
                       "a move is not structural until its gesture ends — the view "
                       + "bumps it there, exactly as 1C-a does")
        model.bumpSceneRevision()
        XCTAssertEqual(model.sceneRevision, before + 1)
    }

    func test_detachFoldsTheLiveEditInBeforeItWrites() {
        let model = loadedModel()
        model.beforeFlush = { model.setScrapText("the sentence in flight", for: self.a) }
        model.withScene { $0.move(self.a, to: CGPoint(x: 7, y: 7)) }  // queues a save
        model.detach()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scraps[a],
                       "the sentence in flight",
                       "⌘Q mid-sentence must write the sentence")
    }

    func test_reattachingReadsWhatDetachWrote() {
        let model = loadedModel()
        model.mutate("Rename Region") { $0.updateRegion(self.r1) { $0.label = "Falls" } }
        model.detach()
        model.attach(projectRoot: root)
        XCTAssertEqual(model.scene.region(r1)?.label, "Falls")
    }

    /// **A probe, not a bound on the machine.** `@Observable` generates a
    /// `_modify` accessor, so `withScene` should mutate the stored scene in
    /// place; if it ever compiles down to get-modify-set instead, every drag
    /// frame copies the whole node dictionary. At 2,000 nodes that is ~2,000
    /// element copies per frame, so the two timings below diverge by orders of
    /// magnitude rather than by a few percent — which is why the bound can be
    /// generous and still catch it.
    func test_aSceneMutationThroughTheModelDoesNotCopyTheWholeScene() {
        let count = CanvasPerformanceProbeTests.supportedNodeCount
        let target = CanvasNodeID("n\(count / 2)")
        var bare = CanvasScene()
        for i in 0..<count {
            bare.insert(CanvasNode(id: CanvasNodeID("n\(i)"), kind: .scrap,
                                   origin: .zero, width: 240, cachedHeight: 40))
        }
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.withScene(persist: false) { $0 = bare }

        func seconds(_ body: () -> Void) -> TimeInterval {
            let start = Date(); body(); return -start.timeIntervalSinceNow
        }
        let iterations = 10_000
        let bareTime = seconds {
            for i in 0..<iterations { bare.move(target, to: CGPoint(x: CGFloat(i), y: 0)) }
        }
        let modelTime = seconds {
            for i in 0..<iterations {
                model.withScene(persist: false) { $0.move(target, to: CGPoint(x: CGFloat(i), y: 0)) }
            }
        }
        print("[probe] \(iterations) moves over \(count) nodes — "
              + "bare \(String(format: "%.1f", bareTime * 1000)) ms, "
              + "through the model \(String(format: "%.1f", modelTime * 1000)) ms")
        XCTAssertLessThan(modelTime, max(bareTime * 20, 0.1),
                          "withScene is copying the scene per mutation")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasModelTests CODE_SIGNING_ALLOWED=NO`
Expected: compile failure — `cannot find 'CanvasModel' in scope`.

- [ ] **Step 3: Write `Maugham/Canvas/CanvasModel.swift`**

```swift
import AppKit
import Observation

/// The canvas's state, owned by `ProjectWindow` because two columns read it.
///
/// **What lives here:** the scene, the scrap text, the selection, the sidecar
/// store and the undo recorder. **What deliberately does not:** camera, layouts,
/// editing focus, the straighten, momentum and the redraw counters — those are
/// properties of one *view* of the canvas and stay in `CanvasView`.
///
/// **This class hosts `CanvasUndo`; it does not reimplement it.** 1C-a built the
/// recorder to reach its state through two closures precisely so ownership could
/// move here. A second snapshot mechanism silently loses `breakGesture`
/// (per-sentence ⌘Z inside a scrap), the deferred `beginUndoGrouping` (a group
/// cannot span an event boundary), the nesting depth counter, and the
/// mid-gesture re-baseline. Named symptom for the last: type in A, click into B,
/// ⌘Z, type in B, click out — and the next ⌘Z resurrects A's discarded text.
@Observable
final class CanvasModel {

    private(set) var scene = CanvasScene()
    private(set) var scraps: [CanvasNodeID: String] = [:]

    /// One selection for both primitives, so ⌫ has a single meaning and the
    /// inspector has a single thing to read.
    var selection: CanvasSelection?

    var selectedRegion: CanvasRegion? {
        guard case .region(let id) = selection else { return nil }
        return scene.region(id)
    }

    /// The STRUCTURAL counter. `CanvasView` keeps its own `@State` copy — that
    /// name is grepped by `CanvasAccessibilityTests` — and mirrors this one.
    /// Never bumped per frame (tripwire 30).
    private(set) var sceneRevision = 0

    /// The canvas's own stack. `groupsByEvent` is off for the reasons written
    /// out at length on `CanvasView.undoManager`; `levelsOfUndo` is capped
    /// because every step retains a whole scene and every scrap's text.
    @ObservationIgnored let undoManager: UndoManager
    @ObservationIgnored let undo: CanvasUndo

    /// Written out rather than using property initialisers, because `undo`
    /// needs `undoManager` and a property initialiser cannot see a sibling.
    init() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 200
        undoManager = manager
        undo = CanvasUndo(undoManager: manager)
    }

    /// The view's chance to re-derive its own state after an undo has replaced
    /// the scene underneath it: stop a coast, leave a scrap that no longer
    /// exists, re-measure. Called synchronously, inside the apply.
    @ObservationIgnored var onSceneReplacedByUndo: (() -> Void)?

    /// The owner's last synchronous chance to fold the live editor's text into
    /// the payload before it is written. Forwarded to `CanvasStore.beforeFlush`
    /// — drop it and ⌘Q loses the sentence in flight.
    @ObservationIgnored var beforeFlush: (() -> Void)?

    @ObservationIgnored private var store: CanvasStore?

    // MARK: - Lifecycle

    /// Build a store, read both files, wire the recorder. This is 1C-a's
    /// `CanvasView.load()` moved one object outwards and otherwise unchanged.
    func attach(projectRoot: URL) {
        let s = CanvasStore(projectRoot: projectRoot)
        s.beforeFlush = { [weak self] in self?.beforeFlush?() }
        store = s
        let loaded = s.load()
        scene = loaded.scene
        scraps = loaded.scraps

        undo.readSnapshot = { [unowned self] in (scene, scraps) }
        undo.applySnapshot = { [unowned self] snapshot in
            scene = snapshot.scene
            scraps = snapshot.scraps
            // Synchronous, and before any timeline tick can run: the view stops
            // its coast, drops focus on a scrap the undo took away, and
            // re-measures every card. Heights are DERIVED, so a restored scene
            // is re-measured rather than trusted.
            onSceneReplacedByUndo?()
            sceneRevision += 1
            scheduleSave()
        }
    }

    /// Fold the live edit in, write, and let go of the cycle. `CanvasView`
    /// calls this from `.onDisappear`, which is where 1C-a does the same work.
    func detach() {
        beforeFlush?()
        store?.flush()
        store?.beforeFlush = nil
        undo.release()
    }

    // MARK: - Mutation

    /// The one way the scene changes.
    ///
    /// `persist: false` is for the frames of a live gesture, which queue their
    /// own save at `.ended` — a drag emits a position per frame and must not
    /// emit a write per frame.
    func withScene(persist: Bool = true, _ body: (inout CanvasScene) -> Void) {
        body(&scene)
        if persist { scheduleSave() }
    }

    func setScrapText(_ text: String, for id: CanvasNodeID) {
        scraps[id] = text
        scheduleSave()
    }

    func removeScrapText(_ id: CanvasNodeID) {
        scraps[id] = nil
        scheduleSave()
    }

    func scheduleSave() { store?.scheduleSave(scene: scene, scraps: scraps) }

    func flush() { store?.flush() }

    /// Bumped by whoever finished a structural change — the end of a gesture,
    /// the end of a coast, a create, a delete. Never per frame.
    func bumpSceneRevision() { sceneRevision += 1 }

    // MARK: - Undo, forwarded

    func beginGesture(_ name: String) { undo.beginGesture(name) }
    func endGesture() { undo.endGesture() }
    func breakGesture() { undo.breakGesture() }
    func mutate(_ name: String, _ body: (inout CanvasScene) -> Void) {
        undo.beginGesture(name)
        withScene(body)
        undo.endGesture()
    }
}
```

- [ ] **Step 4: Rewire `CanvasView` — edit, do not retype**

`git diff --stat` on this file is checked at the end of the slice; a large number means it was retyped rather than edited. The changes are mechanical:

1. Add `let model: CanvasModel` as the first stored property. **Delete** `@State private var scene`, `@State private var scraps` and `@State private var store`.
2. Replace every read of `scene` with `model.scene` and every read of `scraps` with `model.scraps`.
3. Replace every in-place mutation with a `withScene`. The gesture paths pass `persist: false` and keep their existing `.ended` save:
   - `interaction.update(to: contentPoint, in: &scene)` → `model.withScene(persist: false) { interaction.update(to: contentPoint, in: &$0) }`
   - `momentum.step(&scene)` → `model.withScene(persist: false) { moved = momentum.step(&$0) }`
   - `scene.setCachedHeight(…)` inside `rebuildLayouts`/`remeasure` → wrap the loop in one `model.withScene(persist: false) { … }` rather than one call per node.
   - `CanvasInteraction.createScrap(at:in:&scene)` → inside a `withScene`.
4. `store?.scheduleSave(scene: scene, scraps: scraps)` → `model.scheduleSave()`. `store?.flush()` → `model.flush()`.
5. `sceneRevision += 1` stays exactly as it is — it is the view's `@State` and the AX tree keys on it. Add one line beside the existing `.onChange(of: sceneRevision, initial: true)`:

```swift
        .onChange(of: model.sceneRevision) { _, _ in sceneRevision += 1 }
```

   Mirroring rather than replacing, because the model's copy is bumped by the inspector from the other column and the view's copy is what the grep-pinned AX rebuild watches.

6. `load()` becomes:

```swift
    private func load() {
        model.attach(projectRoot: projectRoot)
        model.beforeFlush = { syncActiveEdit() }
        model.onSceneReplacedByUndo = {
            // FIRST. A coast steps the scene directly from the timeline, outside
            // any gesture and after the drag's own snapshot was taken — leave it
            // running and a ⌘Z within the ~1 s after a flick puts the card back
            // at the pick-up point and the momentum then skates it away.
            momentum.stop()
            // The undo may have taken away the scrap the writer is standing in.
            if let id = editingNodeID, model.scene.node(id) == nil { leaveTheOpenScrap() }
            rebuildLayouts()
        }
        wash = CanvasGroundPalette.wash(fromHex: paletteSwatchHexes())
        rebuildLayouts()
    }
```

7. `.onDisappear` becomes `syncActiveEdit(); model.detach()`. **Do not delete the `syncActiveEdit()`** — it is one of the three commit points for the writer's words.
8. Every `undo?.beginGesture(…)` / `endGesture()` / `breakGesture()` becomes `model.beginGesture(…)` etc. **Delete** `@State private var undo` and `@State private var undoManager`; `CanvasEventView(undoManager:)` takes `model.undoManager` and `ScrapEditorHost(canvasUndo:)` takes `model.undo`.

**Do not touch** the straighten clock or its `TimelineView`, `mountedEditorNodeID`, `visibleEditorNodeID`, `revision`, `lastKeystrokeAt`, `layouts`, `camera`, `caretIndex`, the `maximumFrameStep` clamp, or any of the five source-layout contracts.

- [ ] **Step 5: Own the model in `ProjectWindow`**

Add one stored property (free — not a body expression):

```swift
    @State private var canvasModel = CanvasModel()
```

and amend the `.canvas` arm of `existingEditorSwitch` — still one expression:

```swift
        case .canvas:
            CanvasView(model: canvasModel, projectRoot: store.url,
                       paletteSwatchHexes: { store.paletteSwatchHexes() })
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasModelTests -only-testing MaughamTests/CanvasViewMountingTests -only-testing MaughamTests/CanvasCompositionTests -only-testing MaughamTests/CanvasAccessibilityTests -only-testing MaughamTests/CanvasUndoTests -only-testing MaughamTests/ScrapEditorHostTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS. The mounting, composition and accessibility suites are the ones this refactor can break silently; they construct `CanvasView` directly and will need the new `model:` argument.

Then the full suite: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: green.

Then Release, because this touched two views: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Confirm nothing was dropped**

Read the `CanvasView.swift` diff line by line and confirm each of these survived, by name, in the report: the straighten clock and its `TimelineView(paused:)` predicate; `mountedEditorNodeID` and `visibleEditorNodeID` as two separate properties; `momentum` and its rest-branch `sceneRevision` bump; `revision` and `sceneRevision` as two counters; `lastKeystrokeAt`; all three commit points for the writer's words (`onTextChanged`, `.onDisappear`, `beforeFlush`); every `beginGesture`/`endGesture`/`breakGesture` bracket in `handleClick` and `handleDrag`; and the `.ended` ordering where `rebuildLayouts()` precedes `endGesture()` on the resize branch.

- [ ] **Step 8: Commit**

```bash
git add Maugham/Canvas/CanvasModel.swift Maugham/Canvas/CanvasView.swift \
        Maugham/Views/ProjectWindow.swift MaughamTests/Canvas/
git commit -m "refactor(canvas): CanvasModel owns the scene, so two columns can read it"
```

---

### Task 4: Draw regions, tethers and appearance chips

**Files:**
- Modify: `Maugham/Canvas/CanvasMaterial.swift`
- Modify: `Maugham/Canvas/CanvasRenderer.swift`
- Modify: `Maugham/Canvas/CanvasAccessibility.swift`
- Modify: `Maugham/Canvas/CanvasView.swift` (the one `CanvasRenderer.draw` call site)
- Test: `MaughamTests/Canvas/CanvasRegionRenderTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces on `CanvasRenderer`: `visibleRegions(in:camera:viewSize:)`, `struct Tether`, `tethers(in:)`, `struct AppearanceChip`, `appearanceChips(in:)`, `chipTitle(for:in:scraps:)`, `collapsedSummary(for:in:)`. Amends `draw` to `draw(scene:camera:viewSize:layouts:scraps:selection:visibleEditorNodeID:straighten:into:)` — **two parameters added to the existing seven; none renamed, none removed.**
- Produces on `CanvasMaterial`: `lightRegionWash`/`darkRegionWash`, `lightRegionStroke`/`darkRegionStroke`, `regionSelectedStroke`, `tetherOpacity`, `chipOpacity`.
- Produces on `CanvasAccessibility`: `CanvasAXRole.region`, and region elements in `elements(scene:scraps:)`.

**Three things about 1C-a's `draw` this task must not undo:**

1. **The suppression parameter is `visibleEditorNodeID:`, not `editingNodeID:`.** For the ~120 ms of the straighten the editor exists and is invisible, and the renderer must **keep drawing that card's text** — it is live text off the same `NSTextStorage` the invisible editor is mutating. The `editingNodeID:` spelling blanked it from frame one.
2. **It suppresses a node's TEXT, never its CARD.** The loop calls `drawCard` unconditionally with `layout: nil`. A `continue` makes the focused card disappear the moment it is clicked, and §7A.5's whole affordance is that the focused card is the only square one.
3. **The rotation comes from `drawnAngle(for:straighten:)` through `cardTransform(inCard:angle:)`, applied to a copy of the context inside `drawCard`.** A grep test forbids `rotate(by:)` and `rotationEffect` anywhere in `Maugham/Canvas/`.

**Regions draw in canvas space, outside the card transform, and that is exactly right.** `cardTransform` is concatenated onto a *local copy* of the context inside `drawCard`, so it never leaks. A region is not a card and has no seeded angle: it is a wash with a label, drawn under the camera CTM alone.

**Anchor tethers and hairlines on MIDPOINTS.** `cardTransform` translates to `(midX, midY)`, rotates, and translates back — so a card's midpoint maps to itself at any angle, and a tether meets a tilted card at precisely the point it meets an untilted one. Anchor on a corner instead and the line visibly slides during the 120 ms straighten. **Do not anchor a tether or a hairline on anything but a midpoint without also applying `cardTransform`.**

**All colour and dosage constants go in `CanvasMaterial`, in light/dark pairs.** The look is calibrated by eye against the running app by the writer, so a constant he will want to move must be findable without reading the renderer. `CanvasMaterial`'s own header states the rule; `CanvasGroundTests.test_theTwoAppearancesAreCalibratedSeparately` exists to stop a tidy-up collapsing a pair.

**Two rendering requirements from the spec, quoted because they are the acceptance criteria:**

- §4.3: *"An appearance must not render identically to the thing itself… An appearance reads as a reference: smaller, or a chip carrying the title with a hairline to its home. Any region should answer 'which of these live here and which are visiting' at a glance."*
- §4.2: *"a node can sit visually outside the region that owns it. That is a rendering problem (draw the relationship), not a correctness one."*

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
@testable import Maugham

final class CanvasRegionRenderTests: XCTestCase {

    private let r1 = CanvasRegionID("r1")
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 50, y: 50),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 900, y: 50),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        return s
    }

    // MARK: - Culling

    func test_visibleRegionsAreCulledToTheViewport() {
        var s = scene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("far"), label: "Far",
                                    frame: CGRect(x: 90_000, y: 0, width: 100, height: 100)))
        XCTAssertEqual(CanvasRenderer.visibleRegions(in: s, camera: CanvasCamera(),
                                                     viewSize: CGSize(width: 800, height: 600))
                        .map(\.id),
                       [r1],
                       "and note the far region is genuinely in the scene, so an "
                       + "implementation that returned everything would fail here")
    }

    // MARK: - Tethers (§4.2's accepted cost, paid)

    func test_aResidentOutsideItsRegionGetsATetherToIt() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.move(a, to: CGPoint(x: 5_000, y: 5_000))
        let tethers = CanvasRenderer.tethers(in: s)
        XCTAssertEqual(tethers.map(\.node), [a])
        XCTAssertEqual(tethers.first?.from, CGPoint(x: 5_120, y: 5_040),
                       "anchored on the card's MIDPOINT, which cardTransform maps "
                       + "to itself at any tilt")
        XCTAssertEqual(tethers.first?.to, CGPoint(x: 300, y: 200))
    }

    func test_aResidentInsideItsRegionGetsNoTether() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        XCTAssertTrue(CanvasRenderer.tethers(in: s).isEmpty)
    }

    /// A card straddling the boundary is still visibly IN the region. Tethering
    /// on non-containment would fire a line to the centre for one pixel of
    /// overhang — the same one-pixel absurdity the design cites against
    /// Obsidian, inverted. Tether only when the frames do not meet at all.
    func test_aResidentStraddlingTheEdgeGetsNoTether() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.move(a, to: CGPoint(x: 599, y: 100))
        XCTAssertTrue(CanvasRenderer.tethers(in: s).isEmpty)
    }

    func test_aVisitorOutsideARegionGetsNoTether() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        XCTAssertTrue(CanvasRenderer.tethers(in: s).isEmpty,
                      "a visitor is not owned, so there is no 'it moves with that' "
                      + "relationship for a tether to explain")
    }

    func test_aCollapsedRegionTethersNothing() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.move(a, to: CGPoint(x: 5_000, y: 5_000))
        s.updateRegion(r1) { $0.isCollapsed = true }
        XCTAssertTrue(CanvasRenderer.tethers(in: s).isEmpty,
                      "the resident is not drawn, so a line to it lands on nothing")
    }

    // MARK: - Appearance chips (§4.3)

    func test_aVisitorGetsAChipInsideTheRegionAndKeepsItsOwnCard() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        let chips = CanvasRenderer.appearanceChips(in: s)
        XCTAssertEqual(chips.map(\.node), [b])
        XCTAssertTrue(s.region(r1)!.frame.contains(chips[0].frame))
        XCTAssertLessThan(chips[0].frame.height, s.node(b)!.frame!.height,
                          "§4.3: an appearance must not render identically to the "
                          + "thing itself")
        XCTAssertEqual(CanvasRenderer.visibleNodes(in: s, camera: CanvasCamera(),
                                                   viewSize: CGSize(width: 2_000, height: 2_000))
                        .map(\.id).sorted { $0.raw < $1.raw },
                       [a, b],
                       "the real card is still drawn where it actually is — a chip "
                       + "is a reference, never a copy")
    }

    func test_aChipsHairlineRunsToTheRealCard() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        let chip = CanvasRenderer.appearanceChips(in: s)[0]
        XCTAssertEqual(chip.homeAnchor, CGPoint(x: 1_020, y: 90),
                       "the midpoint of b's own card — 'where is the real one'")
    }

    func test_chipsStackRatherThanOverlapping() {
        var s = scene()
        s.insert(CanvasNode(id: CanvasNodeID("c"), kind: .scrap,
                            origin: CGPoint(x: 900, y: 400), width: 240, cachedHeight: 80))
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        CanvasMembership.addAppearance(CanvasNodeID("c"), to: r1, in: &s)
        let chips = CanvasRenderer.appearanceChips(in: s)
        XCTAssertEqual(chips.count, 2)
        XCTAssertFalse(chips[0].frame.intersects(chips[1].frame))
    }

    func test_aChipCarriesTheFirstLineOfTheScrapItStandsFor() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        let title = CanvasRenderer.chipTitle(for: b, in: s,
                                             scraps: [b: "the falls at night\nand the lit bridge"])
        XCTAssertEqual(title, "the falls at night")
        XCTAssertEqual(CanvasRenderer.chipTitle(for: b, in: s, scraps: [:]),
                       CanvasAccessibility.emptyScrapValue,
                       "a blank chip is indistinguishable from a rendering bug")
    }

    // MARK: - Collapse

    func test_aCollapsedRegionSaysHowManyCardsItIsHiding() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.updateRegion(r1) { $0.isCollapsed = true }
        XCTAssertEqual(CanvasRenderer.collapsedSummary(for: r1, in: s), "1 card")
        s.insert(CanvasNode(id: CanvasNodeID("c"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80))
        CanvasMembership.join(CanvasNodeID("c"), home: r1, in: &s)
        XCTAssertEqual(CanvasRenderer.collapsedSummary(for: r1, in: s), "2 cards")
    }

    // MARK: - The draw pass, rasterised

    /// **A region must never occlude the cards it holds.** Asserted by drawing
    /// and reading pixels rather than by comparing two layer-depth constants to
    /// each other, which is a test that cannot fail for the reason it exists.
    func test_aRegionDoesNotPaintOverTheCardsInsideIt() throws {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        let page = try render(scene: s, size: CGSize(width: 700, height: 500))
        let cardCentre = page.color(at: CGPoint(x: 170, y: 90))
        let bareRegion = page.color(at: CGPoint(x: 450, y: 300))
        XCTAssertNotEqual(cardCentre, bareRegion,
                          "the card's paper must survive at its own centre")
        XCTAssertEqual(cardCentre, page.color(at: CGPoint(x: 170, y: 95)),
                       "sanity: the sample is inside a flat area of the card")
    }

    func test_theRegionWashIsFeltRatherThanSeen() throws {
        let plain = try render(scene: CanvasScene(), size: CGSize(width: 700, height: 500))
        let washed = try render(scene: scene(), size: CGSize(width: 700, height: 500))
        let bare = CGPoint(x: 450, y: 300)
        XCTAssertNotEqual(plain.color(at: bare), washed.color(at: bare),
                          "the region has to be visible at all")
        XCTAssertLessThan(plain.distance(to: washed, at: bare), CanvasMaterial.regionWashCeiling,
                          "and it must not read as a filled panel — the cards are "
                          + "the objects; the region is where they are")
    }

    func test_theSelectedRegionIsDrawnDifferentlyFromAnUnselectedOne() throws {
        let s = scene()
        let unselected = try render(scene: s, size: CGSize(width: 700, height: 500))
        let selected = try render(scene: s, size: CGSize(width: 700, height: 500),
                                  selection: .region(r1))
        let onTheStroke = CGPoint(x: 0.5, y: 200)
        XCTAssertNotEqual(unselected.color(at: onTheStroke), selected.color(at: onTheStroke))
    }
}
```

The raster helper mirrors the one already in `CanvasRendererTests` — read that file's `render(size:_:)` and its `Page` type and copy the shape rather than inventing a second one, keeping its `.aqua` appearance pin so this does not become a dark-mode test by accident. The local wrapper is:

```swift
    private func render(scene: CanvasScene,
                        size: CGSize,
                        selection: CanvasSelection? = nil,
                        scraps: [CanvasNodeID: String] = [:]) throws -> Page {
        try Self.render(size: size) { cx in
            CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: size,
                                layouts: [:], scraps: scraps, selection: selection,
                                visibleEditorNodeID: nil,
                                straighten: CanvasFocusStraighten(), into: &cx)
        }
    }
```

`Page` needs `color(at:)` and a `distance(to:at:)` returning the largest per-channel difference in 0–1; add whichever it does not already have.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionRenderTests CODE_SIGNING_ALLOWED=NO`
Expected: compile failure — `visibleRegions` and friends do not exist.

- [ ] **Step 3: Add the tunables to `CanvasMaterial`**

Light/dark pairs, each with a one-line "raise this to…" note in the house style of the file:

```swift
    // MARK: - Regions

    /// The region wash. §4 makes a region *where the cards are*, not a panel
    /// they sit on: at a dosage anyone would call "a filled box" the cards stop
    /// reading as the objects. Raise to make regions more legible; the ceiling
    /// is pinned by `test_theRegionWashIsFeltRatherThanSeen`.
    static let lightRegionWash = NSColor(srgbRed: 0.55, green: 0.52, blue: 0.44, alpha: 0.07)
    static let darkRegionWash = NSColor(srgbRed: 0.72, green: 0.62, blue: 0.48, alpha: 0.09)
    /// How far, in 0–1 channel distance, the wash may move a pixel off the bare
    /// ground. The felt-not-seen bound, made falsifiable.
    static let regionWashCeiling: Double = 0.10

    static let lightRegionStroke = NSColor(srgbRed: 0.45, green: 0.42, blue: 0.35, alpha: 0.35)
    static let darkRegionStroke = NSColor(srgbRed: 0.78, green: 0.72, blue: 0.62, alpha: 0.30)
    /// Selection is the one place on this surface that may shout a little.
    static let regionSelectedStroke: NSColor = .controlAccentColor

    /// A tether explains a relationship the writer already knows about; it must
    /// not compete with the cards.
    static let tetherOpacity: Double = 0.30
    /// A chip is a reference. It reads as lighter than the thing it stands for.
    static let chipOpacity: Double = 0.75
```

- [ ] **Step 4: Implement in `CanvasRenderer`**

Add the types and helpers, then amend `draw`. The region pass runs **before** the node loop, so cards land on top; the chip and tether passes run **after**, so a reference is never buried under a card it points at.

```swift
    static func visibleRegions(in scene: CanvasScene,
                               camera: CanvasCamera,
                               viewSize: CGSize) -> [CanvasRegion] {
        let viewport = camera.visibleContentRect(viewSize: viewSize)
            .insetBy(dx: -cullingBleed, dy: -cullingBleed)
        return scene.regions.filter { $0.frame.intersects(viewport) }
    }

    /// The line drawn from a resident that has wandered out of the region that
    /// owns it, to that region (§4.2's accepted cost).
    ///
    /// Both ends are MIDPOINTS. `cardTransform` fixes a card's midpoint at any
    /// angle, so a tether meets a tilted card exactly where it meets a level
    /// one and no straighten value can make it drift.
    struct Tether: Equatable {
        let node: CanvasNodeID
        let region: CanvasRegionID
        let from: CGPoint
        let to: CGPoint
    }

    static func tethers(in scene: CanvasScene) -> [Tether] {
        scene.regions.filter { !$0.isCollapsed }.flatMap { region -> [Tether] in
            region.homeMembers.sorted { $0.raw < $1.raw }.compactMap { id in
                guard let frame = scene.node(id)?.frame,
                      // Only when the frames do not meet AT ALL. Tethering on
                      // non-containment fires a full line for one pixel of
                      // overhang.
                      !frame.intersects(region.frame) else { return nil }
                return Tether(node: id, region: region.id,
                              from: CGPoint(x: frame.midX, y: frame.midY),
                              to: CGPoint(x: region.frame.midX, y: region.frame.midY))
            }
        }
    }

    /// §4.3: an appearance reads as a reference — a chip carrying the title,
    /// hairlined to the real thing.
    struct AppearanceChip: Equatable {
        let node: CanvasNodeID
        let region: CanvasRegionID
        let frame: CGRect
        /// The midpoint of the node's own card — "where is the real one".
        let homeAnchor: CGPoint
    }

    static let chipHeight: CGFloat = 18
    static let chipWidth: CGFloat = 150

    static func appearanceChips(in scene: CanvasScene) -> [AppearanceChip] {
        scene.regions.filter { !$0.isCollapsed }.flatMap { region -> [AppearanceChip] in
            region.appearances.sorted { $0.raw < $1.raw }.enumerated().compactMap { index, id in
                guard let card = scene.node(id)?.frame else { return nil }
                let top = region.frame.minY + CanvasRegionMetrics.chromeHeight
                    + CGFloat(index) * (chipHeight + 4)
                // Chips stack down the region's inside edge and stop at its
                // bottom; a region too short to hold them all shows what fits.
                guard top + chipHeight <= region.frame.maxY else { return nil }
                return AppearanceChip(
                    node: id, region: region.id,
                    frame: CGRect(x: region.frame.minX + CanvasRegionMetrics.labelInset,
                                  y: top, width: chipWidth, height: chipHeight),
                    homeAnchor: CGPoint(x: card.midX, y: card.midY))
            }
        }
    }

    /// The first non-empty line of the scrap, so a chip says which card it is.
    static func chipTitle(for id: CanvasNodeID,
                          in scene: CanvasScene,
                          scraps: [CanvasNodeID: String]) -> String {
        if case .item(let reference)? = scene.node(id)?.kind {
            return placeholderLabel(forReference: reference)
        }
        let line = (scraps[id] ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? CanvasAccessibility.emptyScrapValue : line
    }

    static func collapsedSummary(for id: CanvasRegionID, in scene: CanvasScene) -> String {
        let n = CanvasMembership.residents(of: id, in: scene).count
        return n == 1 ? "1 card" : "\(n) cards"
    }
```

`draw` gains `scraps:` and `selection:` and three passes:

```swift
    static func draw(scene: CanvasScene,
                     camera: CanvasCamera,
                     viewSize: CGSize,
                     layouts: [CanvasNodeID: ScrapLayout],
                     scraps: [CanvasNodeID: String],
                     selection: CanvasSelection?,
                     visibleEditorNodeID: CanvasNodeID?,
                     straighten: CanvasFocusStraighten,
                     into cx: inout GraphicsContext) {
        cx.translateBy(x: camera.pan.x, y: camera.pan.y)
        cx.scaleBy(x: camera.zoom, y: camera.zoom)

        // BENEATH the cards. A region is where the cards are, not a panel they
        // sit on.
        for region in visibleRegions(in: scene, camera: camera, viewSize: viewSize) {
            drawRegion(region, in: scene, isSelected: selection == .region(region.id), on: cx)
        }

        for node in visibleNodes(in: scene, camera: camera, viewSize: viewSize) {
            guard let frame = node.frame else { continue }
            let ownText = drawsOwnText(node.id, visibleEditorNodeID: visibleEditorNodeID)
            drawCard(node, frame: frame,
                     layout: ownText ? layouts[node.id] : nil,
                     angle: drawnAngle(for: node.id, straighten: straighten),
                     isSelected: selection == .node(node.id),
                     on: cx)
        }

        // ABOVE the cards: a reference the writer cannot see is not a reference.
        for tether in tethers(in: scene) { drawTether(tether, on: cx) }
        for chip in appearanceChips(in: scene) {
            drawChip(chip, title: chipTitle(for: chip.node, in: scene, scraps: scraps), on: cx)
        }
    }
```

`drawRegion` fills the wash, strokes the frame (accent when selected), draws the chrome bar with `region.displayLabel`, draws the resize corner mark, and — when `isCollapsed` — draws `collapsedSummary` beside the label instead of leaving the interior empty. `drawCard` gains an `isSelected` parameter and strokes the accent colour when set; **keep every existing line of it**, including the shadow layer whose caster is filled with the card's own paper.

- [ ] **Step 5: Put regions in the accessibility tree**

Drawn content has no AX tree and this task adds a whole visible primitive to it (§7A.6, "not optional in a writing tool"). In `CanvasAccessibility`:

- add `case region` to `CanvasAXRole`;
- emit one element per region in `elements(scene:scraps:)`, labelled with `displayLabel` and valued with `collapsedSummary` when collapsed, or the resident count when not;
- **skip hidden nodes** — `scene.isHidden(id)` — because a VoiceOver user should not walk into cards that are not on screen;
- keep using `unorderedNodes` and the existing row-band ordering. Regions read **before** the nodes inside them, which is the reading order a sighted writer gets.

Add these to `CanvasAccessibilityTests` — a primitive the writer can see and the VoiceOver user cannot is the failure §7A.6 exists to prevent:

```swift
    func test_aRegionIsAnAccessibilityElementAndReadsBeforeItsCards() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: CGPoint(x: 50, y: 50),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        let elements = CanvasAccessibility.elements(scene: s, scraps: [:])
        XCTAssertEqual(elements.first?.role, .region)
        XCTAssertEqual(elements.first?.label, "Act II fog")
        XCTAssertEqual(elements.count, 2)
    }

    func test_anUnlabelledRegionAnnouncesItselfRatherThanReadingAsBlank() {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        XCTAssertEqual(CanvasAccessibility.elements(scene: s, scraps: [:]).first?.label,
                       CanvasRegion.untitledLabel)
    }

    func test_theResidentsOfACollapsedRegionLeaveTheTree() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: CGPoint(x: 50, y: 50),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: [CanvasNodeID("a")],
                                    isCollapsed: true))
        let elements = CanvasAccessibility.elements(scene: s, scraps: [:])
        XCTAssertEqual(elements.map(\.role), [.region],
                       "a VoiceOver user must not walk into cards that are not "
                       + "on screen")
        XCTAssertEqual(elements.first?.value,
                       CanvasRenderer.collapsedSummary(for: CanvasRegionID("r1"), in: s),
                       "and the region has to say what it is hiding")
    }
```

- [ ] **Step 6: Update the one call site in `CanvasView`**

```swift
                    CanvasRenderer.draw(scene: model.scene, camera: camera, viewSize: size,
                                        layouts: layouts,
                                        scraps: model.scraps,
                                        selection: model.selection,
                                        visibleEditorNodeID: visibleEditorNodeID,
                                        straighten: straighten, into: &cx)
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionRenderTests -only-testing MaughamTests/CanvasRendererTests -only-testing MaughamTests/CanvasAccessibilityTests -only-testing MaughamTests/CanvasGroundTests -only-testing MaughamTests/CanvasPerformanceProbeTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

Release build (this touched a view): `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`

- [ ] **Step 8: Look at it in dark mode, and say what you see**

The raster fixtures pin `.aqua`, exactly as 1C-a's did — and 1C-a shipped a flat-black dark canvas with the whole suite green because of it. Add one dark-appearance assertion mirroring `CanvasGroundTests.test_theDarkGroundIsAMaterialRatherThanABlackFill`: the region wash must clear the dark ground by a measurable margin **and** stay under the ceiling. Report the measured numbers, not "it looks fine".

- [ ] **Step 9: Commit**

```bash
git add Maugham/Canvas/ MaughamTests/Canvas/CanvasRegionRenderTests.swift
git commit -m "feat(canvas): regions draw beneath the cards, with tethers and reference chips"
```

---

### Task 5: Region gestures — draw, drag with residents, resize, drop to join

**Files:**
- Modify: `Maugham/Canvas/CanvasInteraction.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasRegionInteractionTests.swift`
- Test: `MaughamTests/Canvas/CanvasViewMountingTests.swift` (add to the existing class)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces on `CanvasInteraction`: `enum Kind`, `var kind: Kind?`, `var activeRegionID: CanvasRegionID?`, `var pendingRegionDraw: CGRect?`, `enum RegionHit`, `static func regionHit(at:in:)`, `static func joinTarget(for:in:)`, `static func createRegion(_ rect:in:) -> CanvasRegionID?`. Mode gains `.movingRegion`, `.resizingRegion`, `.drawingRegion`.
- Produces on `CanvasView`: nothing new in state — the drawn rect lives in the interaction.

**The gesture vocabulary, decided.** Double-click on empty canvas already makes a scrap; **drag on empty canvas makes a region.** 1C-a documents empty-canvas drag as a deliberate no-op, so this costs no change to `CanvasEventView`'s callbacks — `onDrag` stays `(CGPoint, CanvasDragPhase) -> Void`, and there is still no `DragPhase`. A drag whose rect is smaller than `CanvasRegionMetrics.minimumSide` on either axis creates nothing, so a twitch costs nothing. **A drag starting inside an existing region's interior draws nothing** — nested regions are out of scope (§9), and silently making one would be worse than refusing.

**Where a region can be grabbed.** Its label bar moves it; its bottom-right corner resizes it. **The interior is not a grab handle** — grabbing anywhere inside would make it impossible to pick up a card that sits in a region, which is most of them. Cards are hit-tested first regardless, so a card overlapping the chrome still wins.

**Drop to join is the one gesture that changes membership, and it is a drop, not a coordinate.** At `.ended` of a node move, the node joins the region whose frame **contains the node's centre**; ties break on greatest overlap area. Centre-in-region is predictable and explainable ("drop it so its middle is inside"), where corner-based targeting is the one-pixel absurdity §4.2 cites against Obsidian. **Dropping outside every region does NOT remove a node from its home** — removal is always its own act, and the tether from Task 4 is what makes the resulting state legible.

**Undo extends 1C-a's brackets; it does not add a parallel set.** `handleDrag(.began)` already opens a gesture when the interaction is active and `.ended` already closes it. Region modes make it active, so the only change is the *name*. `CanvasUndo`'s depth counter absorbs re-entry. Do not open a second bracket and do not reach past the model to `model.undo` — the four forwards are the whole surface. The drop-to-join lands **inside** the move's gesture, so one ⌘Z takes back the move and the join together; that is a property worth a test, and it has one below.

**Lesson 1 binds here.** `CanvasRegionInteractionTests` drives the state machine, which is necessary and not sufficient: 1C-a shipped a resize that vanished the card mid-drag with every resize test green, because every one of them asserted after `.ended`. So this task also adds tests to `CanvasViewMountingTests` that drive a **real `CanvasEventNSView`** through `drag(_:from:through:)` and assert on `sceneOnDisk`. Use `waitOut(_:)`, not `pump(_:)`, for anything timing-dependent.

- [ ] **Step 1: Write the failing tests**

`MaughamTests/Canvas/CanvasRegionInteractionTests.swift`:

```swift
import XCTest
@testable import Maugham

final class CanvasRegionInteractionTests: XCTestCase {

    private let r1 = CanvasRegionID("r1")
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")

    /// 'a' sits inside r1; 'b' sits well outside it.
    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 100, y: 100),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 900, y: 100),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        return s
    }

    // MARK: - Where a region can be grabbed

    func test_theInteriorOfARegionIsNotAGrabHandle() {
        XCTAssertNil(CanvasInteraction.regionHit(at: CGPoint(x: 400, y: 300), in: scene()))
    }

    func test_theLabelBarGrabsTheRegion() {
        XCTAssertEqual(CanvasInteraction.regionHit(at: CGPoint(x: 300, y: 8), in: scene()),
                       .chrome(r1))
    }

    func test_theBottomRightCornerResizesTheRegion() {
        XCTAssertEqual(CanvasInteraction.regionHit(at: CGPoint(x: 596, y: 396), in: scene()),
                       .resizeCorner(r1))
    }

    func test_aCardOverTheLabelBarStillWins() {
        var s = scene()
        s.move(a, to: CGPoint(x: 200, y: 0))
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 300, y: 8), in: s)
        XCTAssertEqual(i.activeNodeID, a)
        XCTAssertNil(i.activeRegionID)
    }

    // MARK: - Dragging a region

    /// §4.1: drag a region and its members travel. This is what makes
    /// reorganising one gesture rather than a marquee-select.
    func test_draggingARegionCarriesItsResidents() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 300, y: 8), in: s)
        i.update(to: CGPoint(x: 400, y: 58), in: &s)
        XCTAssertEqual(s.region(r1)?.frame.origin, CGPoint(x: 100, y: 50))
        XCTAssertEqual(s.node(a)?.origin, CGPoint(x: 200, y: 150))
    }

    func test_draggingARegionLeavesVisitorsWhereTheyAre() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 300, y: 8), in: s)
        i.update(to: CGPoint(x: 400, y: 58), in: &s)
        XCTAssertEqual(s.node(b)?.origin, CGPoint(x: 900, y: 100), "a visitor is not luggage")
    }

    func test_draggingARegionDoesNotChangeMembership() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 300, y: 8), in: s)
        i.update(to: CGPoint(x: 4_000, y: 4_000), in: &s)
        i.end()
        XCTAssertTrue(s.region(r1)!.livesHere(a))
        XCTAssertFalse(s.region(r1)!.livesHere(b),
                       "and the region has now swept across b without absorbing it")
    }

    func test_aRegionNeverFlicks() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 300, y: 8), in: s)
        i.update(to: CGPoint(x: 340, y: 8), in: &s, now: 0)
        i.update(to: CGPoint(x: 400, y: 8), in: &s, now: 0.01)
        XCTAssertNil(i.end(now: 0.011),
                     "a region full of cards skating away is not §7.3's 'objects "
                     + "coming to rest'")
    }

    // MARK: - Resizing a region

    func test_resizingARegionMovesOnlyItsFrame() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 596, y: 396), in: s)
        i.update(to: CGPoint(x: 300, y: 250), in: &s)
        XCTAssertEqual(s.region(r1)?.frame.width, 304)
        XCTAssertEqual(s.region(r1)?.frame.height, 254)
        XCTAssertEqual(s.node(a)?.origin, CGPoint(x: 100, y: 100),
                       "resizing must not drag the residents")
        XCTAssertTrue(s.region(r1)!.livesHere(a), "and must never eject one — tldraw #6017")
    }

    func test_resizeIsClampedToAWorkableMinimum() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 596, y: 396), in: s)
        i.update(to: CGPoint(x: -900, y: -900), in: &s)
        XCTAssertEqual(s.region(r1)?.frame.width, CanvasRegionMetrics.minimumSide)
        XCTAssertEqual(s.region(r1)?.frame.height, CanvasRegionMetrics.minimumSide)
    }

    // MARK: - Drawing a region

    func test_aDragOnEmptyCanvasDrawsARegion() throws {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 1_000, y: 1_000), in: s)
        XCTAssertEqual(i.kind, .drawingRegion)
        i.update(to: CGPoint(x: 1_300, y: 1_250), in: &s)
        let rect = try XCTUnwrap(i.pendingRegionDraw)
        XCTAssertEqual(rect, CGRect(x: 1_000, y: 1_000, width: 300, height: 250))
        XCTAssertNotNil(CanvasInteraction.createRegion(rect, in: &s))
        XCTAssertEqual(s.regionCount, 2)
    }

    func test_aDragBackwardsAndUpwardsStillDrawsARegion() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 1_300, y: 1_250), in: s)
        i.update(to: CGPoint(x: 1_000, y: 1_000), in: &s)
        XCTAssertEqual(i.pendingRegionDraw, CGRect(x: 1_000, y: 1_000, width: 300, height: 250))
    }

    func test_aTwitchMakesNoRegion() {
        var s = scene()
        XCTAssertNil(CanvasInteraction.createRegion(
            CGRect(x: 1_000, y: 1_000,
                   width: CanvasRegionMetrics.minimumSide - 1,
                   height: 300),
            in: &s))
        XCTAssertEqual(s.regionCount, 1)
    }

    /// Nested regions are out of scope (§9), and silently making one is worse
    /// than refusing.
    func test_aDragInsideAnExistingRegionDrawsNothing() {
        var s = scene()
        var i = CanvasInteraction()
        i.begin(at: CGPoint(x: 400, y: 300), in: s)
        XCTAssertFalse(i.isActive)
        i.update(to: CGPoint(x: 500, y: 380), in: &s)
        XCTAssertNil(i.pendingRegionDraw)
        XCTAssertEqual(s.regionCount, 1)
    }

    func test_aNewRegionIsUnlabelledAndOwnsNothing() {
        var s = scene()
        let id = CanvasInteraction.createRegion(
            CGRect(x: 1_000, y: 1_000, width: 300, height: 250), in: &s)!
        XCTAssertEqual(s.region(id)?.label, "")
        XCTAssertEqual(s.region(id)?.displayLabel, CanvasRegion.untitledLabel)
        XCTAssertTrue(s.region(id)!.homeMembers.isEmpty,
                      "§4.2: drawing a region around cards absorbs NONE of them — "
                      + "and this rect was drawn nowhere near any, so the fixture "
                      + "below is the one that actually tests it")
    }

    func test_drawingARegionAroundExistingCardsAbsorbsNoneOfThem() {
        var s = scene()
        let id = CanvasInteraction.createRegion(
            CGRect(x: 50, y: 50, width: 400, height: 300), in: &s)!
        XCTAssertTrue(s.region(id)!.homeMembers.isEmpty,
                      "'a' is squarely inside this rect and must not have joined")
    }

    // MARK: - Drop to join

    func test_droppingACardIntoARegionJoinsIt() {
        var s = scene()
        s.move(b, to: CGPoint(x: 200, y: 200))
        XCTAssertEqual(CanvasInteraction.joinTarget(for: b, in: s), r1)
    }

    func test_aCardWhoseMiddleIsOutsideDoesNotJoin() {
        var s = scene()
        // Overlapping by 20pt of a 240pt card: its centre is well outside.
        s.move(b, to: CGPoint(x: 580, y: 200))
        XCTAssertNil(CanvasInteraction.joinTarget(for: b, in: s),
                     "corner-based targeting is the one-pixel absurdity §4.2 cites")
    }

    /// **The ids are chosen so an id-order tiebreak gives the WRONG answer.**
    /// `wide` covers the whole card and `narrow` clips it, and `narrow` sorts
    /// last — so an implementation that broke the tie on id alone, or that took
    /// the last region it found, would return `narrow` and fail here. Written
    /// against a bespoke scene rather than the shared fixture because r1
    /// contains this card entirely too, which would make the overlaps equal and
    /// the assertion vacuous.
    func test_overlappingRegionsBreakTheTieOnGreatestOverlap() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 200, y: 200),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("a-wide"), label: "Wide",
                                    frame: CGRect(x: 150, y: 150, width: 400, height: 300)))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("z-narrow"), label: "Narrow",
                                    frame: CGRect(x: 300, y: 150, width: 200, height: 300)))
        // Centre is (320, 240): inside both. Overlap with the card is the whole
        // 240×80 for 'a-wide' and 140×80 for 'z-narrow'.
        XCTAssertEqual(CanvasInteraction.joinTarget(for: b, in: s), CanvasRegionID("a-wide"))
    }

    func test_droppingACardOutsideEveryRegionDoesNotRemoveItFromItsHome() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.move(a, to: CGPoint(x: 5_000, y: 5_000))
        XCTAssertNil(CanvasInteraction.joinTarget(for: a, in: s))
        XCTAssertTrue(s.region(r1)!.livesHere(a),
                      "removal is always its own act (§4.2) — the tether is what "
                      + "makes this state legible")
    }
}
```

And in `CanvasViewMountingTests`, the real-delivery-path half. Build the fixture through `CanvasStore` as the existing helpers do:

```swift
    // MARK: - Regions, through the real event view

    func test_aDragOnBareCanvasDrawsARegionThatReachesDisk() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 400, y: 300),
             through: [CGPoint(x: 600, y: 460), CGPoint(x: 600, y: 460)])
        pump(1.0)

        let regions = sceneOnDisk(root).regions
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.frame.width, 200)
        XCTAssertTrue(regions.first!.homeMembers.isEmpty,
                      "the fixture's scrap is at (20,20) and this rect starts at "
                      + "(400,300), so nothing was in the way — the absorption "
                      + "rule is asserted in CanvasRegionInteractionTests")
    }

    func test_draggingARegionByItsLabelBarCarriesItsResidentToDisk() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Onto the chrome bar, then 100pt right and 40pt down.
        drag(events, from: CGPoint(x: 200, y: 30),
             through: [CGPoint(x: 300, y: 70), CGPoint(x: 300, y: 70)])
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.region(CanvasRegionID("r1"))?.frame.origin,
                       CGPoint(x: 120, y: 60))
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 160, y: 100),
                       "the resident travelled — through the real event view, the "
                       + "real gesture routing and the real debounced save")
    }

    func test_oneUndoTakesBackARegionDragAndTheCardsItCarried() throws {
        let root = try regionProjectRoot()
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        drag(events, from: CGPoint(x: 200, y: 30),
             through: [CGPoint(x: 300, y: 70), CGPoint(x: 300, y: 70)])
        pump(1.0)
        XCTAssertEqual(sceneOnDisk(root).node(scrapID)?.origin, CGPoint(x: 160, y: 100),
                       "precondition: the drag really happened")

        let undo = try editMenuItem(#selector(CanvasEventNSView.undo(_:)), in: window)
        XCTAssertTrue(undo.isEnabled,
                      "a ⌘Z the Edit menu greys out is a feature the writer cannot reach")
        _ = undo.target.perform(undo.item.action, with: undo.item)
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.region(CanvasRegionID("r1"))?.frame.origin, CGPoint(x: 20, y: 20))
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 60, y: 60),
                       "one ⌘Z takes back the frame AND every resident it carried — "
                       + "which is why the recorder snapshots the scene rather than "
                       + "inverting properties")
    }

    func test_droppingACardIntoARegionJoinsItAndOneUndoTakesBackBoth() throws {
        // The same region, and a scrap that starts OUTSIDE it.
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 500, y: 60),
                                width: 240, cachedHeight: 60))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300)))
        let root = try projectRoot(scene: scene, scraps: [scrapID: scrapText])
        let window = host(CanvasView(model: CanvasModel(), projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        XCTAssertFalse(sceneOnDisk(root).region(CanvasRegionID("r1"))!.livesHere(scrapID),
                       "precondition: it starts outside and unowned")

        // Grab the card at (540, 90) and carry it 340pt left, so its centre
        // lands at (250, 130) — squarely inside the region.
        drag(events, from: CGPoint(x: 540, y: 90),
             through: [CGPoint(x: 200, y: 90), CGPoint(x: 200, y: 90)])
        pump(1.0)

        XCTAssertTrue(sceneOnDisk(root).region(CanvasRegionID("r1"))!.livesHere(scrapID),
                      "the drop joined it")

        let undo = try editMenuItem(#selector(CanvasEventNSView.undo(_:)), in: window)
        _ = undo.target.perform(undo.item.action, with: undo.item)
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 500, y: 60))
        XCTAssertFalse(onDisk.region(CanvasRegionID("r1"))!.livesHere(scrapID),
                       "ONE ⌘Z, because the join lands inside the move's own "
                       + "gesture — a second bracket would leave the card back "
                       + "outside a region that still claimed it")
    }
```

And the shared fixture the first two use, beside the existing `projectRoot()` helpers:

```swift
    /// The fixture scrap at (60,60), owned by a region at (20,20).
    private func regionProjectRoot() throws -> URL {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: scrapID, kind: .scrap, origin: CGPoint(x: 60, y: 60),
                                width: 240, cachedHeight: 60))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 20, y: 20, width: 400, height: 300),
                                        homeMembers: [scrapID]))
        return try projectRoot(scene: scene, scraps: [scrapID: scrapText])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasRegionInteractionTests -only-testing MaughamTests/CanvasViewMountingTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL.

- [ ] **Step 3: Extend `CanvasInteraction`**

Add to `Mode`:

```swift
        case movingRegion(CanvasRegionID, grabOffset: CGSize, residents: Set<CanvasNodeID>)
        case resizingRegion(CanvasRegionID, startFrame: CGRect, startPoint: CGPoint)
        case drawingRegion(start: CGPoint, current: CGPoint)
```

Residents are captured at `.began` because membership cannot change during a drag, and re-deriving them per frame is a set-union over every region at pointer rate.

Add the public surface:

```swift
    enum Kind: Equatable {
        case movingNode, resizingNode, movingRegion, resizingRegion, drawingRegion
    }

    var kind: Kind? { … }
    var activeRegionID: CanvasRegionID? { … }

    /// The rect a `.drawingRegion` gesture has swept, normalised so a drag up
    /// and to the left is the same region as a drag down and to the right.
    /// `nil` in every other mode.
    var pendingRegionDraw: CGRect? {
        guard case .drawingRegion(let start, let current) = mode else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    enum RegionHit: Equatable {
        case chrome(CanvasRegionID)
        case resizeCorner(CanvasRegionID)
    }

    /// The label bar moves a region; the bottom-right corner resizes it. The
    /// INTERIOR is deliberately neither: grabbing anywhere inside would make it
    /// impossible to pick up a card that sits in a region, which is most of them.
    ///
    /// Smallest region first, so a small region overlapping a large one is
    /// reachable. Nested regions are out of scope, but overlapping ones are not.
    static func regionHit(at point: CGPoint, in scene: CanvasScene) -> RegionHit? {
        let candidates = scene.regions.sorted {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }
        for r in candidates where CanvasRegionMetrics.resizeHandleRect(in: r.frame).contains(point) {
            return .resizeCorner(r.id)
        }
        for r in candidates where CanvasRegionMetrics.chromeRect(in: r.frame).contains(point) {
            return .chrome(r.id)
        }
        return nil
    }

    /// Which region a DROP meant. Deciding lives here; recording lives in
    /// `CanvasMembership`, and keeping the two apart is what stops geometry
    /// leaking into membership.
    ///
    /// The node's CENTRE must be inside the region — predictable, and
    /// explainable in one sentence to a writer. Overlap area only breaks ties
    /// between regions that all contain it.
    static func joinTarget(for node: CanvasNodeID, in scene: CanvasScene) -> CanvasRegionID? {
        guard let frame = scene.node(node)?.frame else { return nil }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return scene.regions
            .filter { $0.frame.contains(centre) }
            .max { lhs, rhs in
                let l = lhs.frame.intersection(frame), r = rhs.frame.intersection(frame)
                return (l.width * l.height, lhs.id.raw) < (r.width * r.height, rhs.id.raw)
            }?.id
    }

    /// Mint a region for a swept rect, or nothing if the sweep was a twitch.
    /// Ids get the same uniqueness loop `createScrap` uses — never a bare
    /// random call (tripwire 23's lesson in a second id space).
    static func createRegion(_ rect: CGRect, in scene: inout CanvasScene) -> CanvasRegionID? {
        guard rect.width >= CanvasRegionMetrics.minimumSide,
              rect.height >= CanvasRegionMetrics.minimumSide else { return nil }
        var id = CanvasRegionID(UUID().uuidString.prefix(8).lowercased())
        while scene.region(id) != nil {
            id = CanvasRegionID(UUID().uuidString.prefix(8).lowercased())
        }
        // Deliberately EMPTY. §4.2: drawing a region around cards absorbs none
        // of them — the writer drops what belongs in it.
        scene.insertRegion(CanvasRegion(id: id, label: "", frame: rect))
        return id
    }
```

`begin(at:in:)` gains a fall-through after its existing node branch, in this order: node → region resize corner → region chrome → *inside any region's interior* (idle, no nesting) → `.drawingRegion`.

`update(to:in:now:)` gains three cases: move the region frame **and every captured resident** by the same delta; resize the frame clamped to `minimumSide`; record the current point for a draw.

`end(now:)` keeps its exact signature and returns `nil` for all three new modes — a region never flicks, and neither does a sweep.

- [ ] **Step 4: Route the gestures in `CanvasView`**

In `handleDrag(.began)`, after `interaction.begin`, name the gesture from the kind rather than from `isResizing` alone:

```swift
            if interaction.isActive {
                model.beginGesture(Self.gestureName(for: interaction.kind))
            }
```

with a small private static mapping — `movingNode` → "Move Scrap", `resizingNode` → "Resize Scrap", `movingRegion` → "Move Region", `resizingRegion` → "Resize Region", `drawingRegion` → "New Region".

In `.ended`, read the swept rect **before** `end()` clears the mode, and do the join **inside** the still-open gesture:

```swift
        case .ended:
            guard interaction.isActive else { return }
            let wasResizing = interaction.isResizing
            let drawnRegion = interaction.pendingRegionDraw
            let movedNode = interaction.kind == .movingNode ? interaction.activeNodeID : nil
            let flick = interaction.end()

            if let drawnRegion {
                model.withScene(persist: false) {
                    if let id = CanvasInteraction.createRegion(drawnRegion, in: &$0) {
                        model.selection = .region(id)
                    }
                }
                model.bumpSceneRevision()
            } else if let movedNode, interaction.hasMoved {
                // The drop, INSIDE the move's own gesture — so one ⌘Z takes back
                // the move and the join together.
                model.withScene(persist: false) {
                    if let target = CanvasInteraction.joinTarget(for: movedNode, in: $0) {
                        CanvasMembership.join(movedNode, home: target, in: &$0)
                    }
                }
            }
            … the existing resize / move branches, unchanged …
```

**Do not touch** the existing `.ended` ordering where `rebuildLayouts()` precedes `endGesture()` on the resize branch, the unconditional re-measure, the `hasMoved` guard on the move branch, or the coast-truncation bump at `.began`. Each has a named defect behind it.

In `handleClick`, single click now also sets the selection before it leaves the open scrap:

```swift
        guard clickCount >= 2 else {
            model.selection = selectionTarget(at: contentPoint)
            leaveTheOpenScrap()
            model.scheduleSave()
            return
        }
```

with:

```swift
    /// What a single click selects. The same precedence the drag uses — a card
    /// beats the region chrome under it — so clicking a thing and dragging it
    /// never disagree about which thing it was.
    private func selectionTarget(at contentPoint: CGPoint) -> CanvasSelection? {
        if let node = model.scene.topmostNode(at: contentPoint) { return .node(node.id) }
        switch CanvasInteraction.regionHit(at: contentPoint, in: model.scene) {
        case .chrome(let id), .resizeCorner(let id): return .region(id)
        case nil: return nil
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the two test classes, then the full suite, then Release.

- [ ] **Step 6: Check every assertion could fail**

For each new test in both files, answer in the report: *what implementation bug turns this red?* Two are already written to be self-answering (`test_drawingARegionAroundExistingCardsAbsorbsNoneOfThem` places the rect over a real card; `test_aRegionNeverFlicks` drives two fast samples so a missing guard would return a velocity). Do the same for the rest.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasInteraction.swift Maugham/Canvas/CanvasView.swift MaughamTests/Canvas/
git commit -m "feat(canvas): draw, drag, resize and drop into regions"
```

---

### Task 6: Delete — the ⌫ path, for regions and for scraps

**Files:**
- Modify: `Maugham/Canvas/CanvasEventView.swift`
- Modify: `Maugham/Canvas/CanvasView.swift`
- Test: `MaughamTests/Canvas/CanvasEventViewTests.swift` (add to the existing class)
- Test: `MaughamTests/Canvas/CanvasViewMountingTests.swift` (add to the existing class)

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces on `CanvasEventNSView`/`CanvasEventView`: `onDeleteKey: (() -> Void)?`, and a `keyDown` override.
- Produces on `CanvasView`: `private func deleteSelection()`.

**Why this is in 1C-b at all.** 1C-a shipped **no delete path anywhere**: `CanvasScene.remove`, its inverse and the `"Delete Scrap"` undo step are all built and exercised, with no production caller. What the writer meets today is that a stray double-click makes an empty card, ⌘Z takes it back, and once they have clicked away it is on the canvas permanently. Denver assigned the gap to this slice on 2026-07-27, because regions raise "what happens to the contents" the moment they exist. The undo layer has been waiting for this caller.

**The semantics, and the second one is the spec's:**

- **Selection is a region** → the region goes; **its cards stay on the canvas**. §3.1's rule for items, generalised: the canvas owns arrangement, not existence. Membership records die with the region, which is why Task 1 has `removeRegion` touch nothing else.
- **Selection is a node** → the node goes, its scrap text goes from `canvas.md`, and Task 1's `remove` scrubs it from every region.
- **Nothing selected** → nothing happens, and the event goes to `super` so the key is not swallowed.

**⌫ never fights the editor.** While a scrap is focused the mounted `NSTextView` is frontmost and first responder, so the key never reaches the event view — the writer is deleting characters, which is what they meant. Every route out of a scrap runs `commitActiveEdit`, so by the time the event view has the key there is no open gesture. Pin this rather than assume it.

**Lesson 1 binds hardest here.** A delete that works when you call `deleteSelection()` and does nothing when the writer presses ⌫ is exactly 1C-a's undo defect, which was twenty-two green tests deep. **One test must send a real `NSEvent` through the real responder chain.**

- [ ] **Step 1: Write the failing tests**

In `CanvasEventViewTests`:

```swift
    func test_theDeleteKeyIsReportedAndOtherKeysAreNot() {
        let v = CanvasEventNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        var deletes = 0
        v.onDeleteKey = { deletes += 1 }

        v.keyDown(with: key("\u{7F}"))          // ⌫
        XCTAssertEqual(deletes, 1)
        v.keyDown(with: key("\u{8}"))           // forward delete's character
        XCTAssertEqual(deletes, 2)
        v.keyDown(with: key("a"))
        XCTAssertEqual(deletes, 2, "an ordinary key must pass through")
    }

    private func key(_ character: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil,
                         characters: character, charactersIgnoringModifiers: character,
                         isARepeat: false, keyCode: 51)!
    }
```

In `CanvasViewMountingTests` — the delivery path, end to end:

```swift
    func test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Single click on the card: selects it and takes first responder.
        events.applyMouseDown(at: CGPoint(x: 60, y: 40), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 60, y: 40))
        pump()
        XCTAssertEqual(model.selection, .node(scrapID), "precondition: it is selected")
        XCTAssertTrue(window.firstResponder === events,
                      "precondition: the key will actually arrive here")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        XCTAssertNil(sceneOnDisk(root).node(scrapID))
        XCTAssertNil(scrapsOnDisk(root)[scrapID],
                     "the words go with the card — canvas.md is the only place "
                     + "they live")
    }

    func test_backspaceWithNothingSelectedChangesNothing() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // Bare canvas, far from the fixture scrap at (20,20).
        events.applyMouseDown(at: CGPoint(x: 500, y: 400), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 500, y: 400))
        pump()
        XCTAssertNil(model.selection, "precondition: clicking nothing selects nothing")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)
        XCTAssertNotNil(sceneOnDisk(root).node(scrapID),
                        "⌫ over an empty selection must be a no-op, not a guess")
    }

    /// **⌫ never fights the editor.** While a scrap is focused the mounted text
    /// view is frontmost and first responder, so the key deletes a character —
    /// which is what the writer meant. If the event view ever won that race, a
    /// backspace mid-sentence would delete the whole card.
    func test_backspaceInsideAScrapDeletesACharacterAndNotTheCard() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        // The helper's own settle already outlasts the straighten, so the editor
        // is level, visible and first responder by the time it returns.
        _ = try doubleClickTheScrap(in: window)
        let editor = try XCTUnwrap(
            firstDescendant(NSTextView.self, in: try XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.firstResponder === editor,
                      "precondition: the editor holds first responder, so the key "
                      + "never reaches CanvasEventNSView at all")

        editor.setSelectedRange(NSRange(location: (scrapText as NSString).length, length: 0))
        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        XCTAssertNotNil(sceneOnDisk(root).node(scrapID), "the card is still there")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], String(scrapText.dropLast()),
                       "exactly one character, and it reached disk")
    }

    func test_undoBringsBackADeletedScrapWithItsWords() throws {
        let root = try projectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        events.applyMouseDown(at: CGPoint(x: 60, y: 40), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 60, y: 40))
        pump()
        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)
        XCTAssertNil(sceneOnDisk(root).node(scrapID), "precondition: it is gone")

        let undo = try editMenuItem(#selector(CanvasEventNSView.undo(_:)), in: window)
        XCTAssertTrue(undo.isEnabled)
        _ = undo.target.perform(undo.item.action, with: undo.item)
        pump(1.0)

        XCTAssertNotNil(sceneOnDisk(root).node(scrapID))
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText,
                       "the words come back with the card — the scene and the "
                       + "scrap text are one snapshot, which is why they cannot "
                       + "be restored out of step")
    }

    /// Spec §3.1, generalised: the canvas owns arrangement, not existence.
    func test_deletingARegionLeavesItsCardsWhereTheyWere() throws {
        let root = try regionProjectRoot()
        let model = CanvasModel()
        let window = host(CanvasView(model: model, projectRoot: root,
                                     paletteSwatchHexes: { [] }))
        let events = try eventView(in: window)

        // The region's label bar: frame starts at (20,20), so y=30 is inside the
        // 24pt chrome, and x=200 is clear of the card at (60,60)…(300,120).
        events.applyMouseDown(at: CGPoint(x: 200, y: 30), clickCount: 1)
        events.applyMouseUp(at: CGPoint(x: 200, y: 30))
        pump()
        XCTAssertEqual(model.selection, .region(CanvasRegionID("r1")),
                       "precondition: the label bar selected the region")

        window.sendEvent(deleteKeyEvent(for: window))
        pump(1.0)

        let onDisk = sceneOnDisk(root)
        XCTAssertEqual(onDisk.regionCount, 0)
        XCTAssertEqual(onDisk.node(scrapID)?.origin, CGPoint(x: 60, y: 60),
                       "deleting a region never deletes cards, and never moves them")
        XCTAssertEqual(scrapsOnDisk(root)[scrapID], scrapText)
    }
```

Two helpers go beside the existing `sceneOnDisk(_:)`:

```swift
    private func scrapsOnDisk(_ root: URL) -> [CanvasNodeID: String] {
        CanvasStore(projectRoot: root).load().scraps
    }

    /// A real ⌫, built the way AppKit delivers one. `charactersIgnoringModifiers`
    /// is what `keyDown` switches on, so it is what this has to carry.
    private func deleteKeyEvent(for window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
                         isARepeat: false, keyCode: 51)!
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/CanvasEventViewTests -only-testing MaughamTests/CanvasViewMountingTests CODE_SIGNING_ALLOWED=NO`
Expected: FAIL.

- [ ] **Step 3: Add the key path to `CanvasEventNSView`**

```swift
    /// ⌫ with something selected. `nil` while nothing is.
    var onDeleteKey: (() -> Void)?

    /// **This is the whole of ⌫ on the canvas**, and it is deliberately a
    /// `keyDown` rather than `deleteBackward(_:)`: this view is not a text
    /// responder, does not call `interpretKeyEvents`, and would never receive
    /// the action message.
    ///
    /// It only ever reaches here with NO scrap focused — the mounted editor is
    /// frontmost and first responder while the writer is in a scrap, so ⌫ there
    /// deletes a character, which is what they meant. Unhandled keys go to
    /// `super` so nothing else is swallowed.
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\u{7F}", "\u{8}":
            onDeleteKey?()
        default:
            super.keyDown(with: event)
        }
    }
```

and wire `v.onDeleteKey = onDeleteKey` in `CanvasEventView.wire`, alongside the existing four.

- [ ] **Step 4: Implement `deleteSelection()` in `CanvasView`**

```swift
    /// ⌫. The region case is the one with a rule behind it: **deleting a region
    /// never deletes cards** — the canvas owns arrangement, not existence
    /// (§3.1, generalised). Its membership records die with it, which is all
    /// `CanvasScene.removeRegion` touches.
    private func deleteSelection() {
        switch model.selection {
        case .region(let id):
            guard model.scene.region(id) != nil else { return }
            model.mutate("Delete Region") { $0.removeRegion(id) }
        case .node(let id):
            guard model.scene.node(id) != nil else { return }
            // The writer cannot be standing in it — a single click both selected
            // it and left the open scrap — but an undo can have moved focus
            // since, and an editor bound to a node that no longer exists is the
            // state `.unenterableNode` already refuses to leave standing.
            if editingNodeID == id { leaveTheOpenScrap() }
            model.beginGesture("Delete Scrap")
            model.withScene(persist: false) { $0.remove(id) }
            model.removeScrapText(id)
            model.endGesture()
            // A delete is a structural change — AREA.md's list of what bumps
            // this said "deletion is not on that list because 1C-a has no delete
            // path", and this task is why that sentence changes.
            rebuildLayouts()
        case .none:
            return
        }
        model.selection = nil
        model.bumpSceneRevision()
        model.scheduleSave()
    }
```

and pass it through: `CanvasEventView(…, onDeleteKey: { deleteSelection() }, undoManager: model.undoManager)`.

- [ ] **Step 5: Run the tests to verify they pass**

The two classes, then the full suite, then Release.

- [ ] **Step 6: Prove the delivery path is the thing under test**

Temporarily comment out the `onDeleteKey?()` line in `keyDown` and confirm `test_backspaceDeletesTheSelectedScrapThroughTheRealResponderChain` goes red while `CanvasEventViewTests` — which calls `keyDown` directly — also goes red, and that the model-level tests stay green. Restore. Report both outcomes: this is the check 1C-a's undo work did not have, and it is the reason ⌘Z shipped unreachable.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/CanvasEventView.swift Maugham/Canvas/CanvasView.swift MaughamTests/Canvas/
git commit -m "feat(canvas): delete a region or a scrap with ⌫, and undo it"
```

---

### Task 7: `RegionBinding` and the region inspector

**Files:**
- Create: `Maugham/Canvas/RegionBinding.swift`
- Create: `Maugham/Canvas/RegionInspector.swift`
- Modify: `Maugham/Views/ProjectWindow.swift`
- Test: `MaughamTests/Canvas/RegionBindingTests.swift`

**Interfaces:**
- Consumes: Tasks 1–6; `ProjectStore.manifest.structure: [StructureItem]` (`id`, `title`, `type`), and `MaughamCore.TreeWalk.collect(in:where:)`.
- Produces: `enum RegionBinding` with `bind(_:toPiece:in:)`, `unbind(_:in:)`, `boundPiece(of:in:)`, `references(forPiece:in:) -> Set<CanvasNodeID>`; `struct RegionInspector: View` with a nested `PieceChoice`.

**What this slice produces and does not consume.** §4.4's binding is the durable half of the bridge to authoring: *"the nodes that live in a piece's region become the pinned references beside the editor when you write it."* That consumer is **1A's** reference rail, and 1A is unwritten. Producing a value nothing reads yet is deliberate — the binding has to exist before the consumer can be built. **CLAUDE.md rule 8 is satisfied by this inspector, not by a consumer:** every new data type gets a UI surface for inspection and action, and two land here (the binding and `isCollapsed`). `isCollapsed` is the one at risk — Task 4 renders it and Task 2 round-trips it, and without a control nothing but a test could ever set it. A schema field only a test can reach is a field that rots.

**Only residents bind.** *"Only nodes that live in the region are bound. Visitors are not, or two regions sharing a card would each claim it."* Two regions may bind to the same piece; `references(forPiece:)` unions their residents.

**Tripwire 16 does not apply.** That rule is about an inline rename `TextField` that *appears* inside a `List(selection:)` row and has to steal focus from the list's own focus pass. This label field is always present in a static inspector form, so there is no focus race — do not copy `BinderRow.claimFocus()` into it. Commit on `.onSubmit` and on focus loss, so one rename is one undo step rather than one per keystroke.

**Tripwire 15 applies.** The empty state needs `ContentUnavailableView(…).frame(maxWidth: .infinity, maxHeight: .infinity)` **and** the enclosing `VStack` needs `alignment: .top`, or the toolbar floats to the window's centre. It has recurred four or more times; `HistoryPane` is the canonical example.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import MaughamCore
@testable import Maugham

final class RegionBindingTests: XCTestCase {

    private var root: URL!
    private let r1 = CanvasRegionID("r1")
    private let r2 = CanvasRegionID("r2")
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("region-binding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for id in [a, b] {
            s.insert(CanvasNode(id: id, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
        }
        for (id, label) in [(r1, "Act II fog"), (r2, "Falls")] {
            s.insertRegion(CanvasRegion(id: id, label: label,
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        }
        return s
    }

    private func model() -> CanvasModel {
        let m = CanvasModel()
        m.attach(projectRoot: root)
        m.withScene { $0 = self.scene() }
        m.selection = .region(r1)
        return m
    }

    private func inspector(_ m: CanvasModel) -> RegionInspector {
        RegionInspector(model: m, regionID: r1,
                        pieces: [RegionInspector.PieceChoice(id: "piece-3", title: "October")])
    }

    // MARK: - The binding rules

    func test_onlyResidentsAreBoundToThePiece() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: s), [a],
                       "§4.4: a visitor is not bound, or two regions sharing a "
                       + "card would each claim it")
    }

    func test_twoRegionsBoundToOnePieceUnionTheirResidents() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.join(b, home: r2, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        RegionBinding.bind(r2, toPiece: "piece-3", in: &s)
        XCTAssertEqual(RegionBinding.references(forPiece: "piece-3", in: s), [a, b])
    }

    func test_unbindingKeepsMembershipIntact() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "piece-3", in: &s)
        RegionBinding.unbind(r1, in: &s)
        XCTAssertNil(RegionBinding.boundPiece(of: r1, in: s))
        XCTAssertTrue(s.region(r1)!.livesHere(a), "the binding is not the membership")
        XCTAssertTrue(RegionBinding.references(forPiece: "piece-3", in: s).isEmpty)
    }

    func test_aPieceNobodyBoundToHasNoReferences() {
        XCTAssertTrue(RegionBinding.references(forPiece: "piece-9", in: scene()).isEmpty)
    }

    // MARK: - The inspector, which is the only way any of this is reachable

    func test_renamingThroughTheInspectorIsOneUndoStepAndReachesDisk() {
        let m = model()
        inspector(m).commitLabel("Falls at night")
        m.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.region(r1)?.label,
                       "Falls at night")
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.label, "Act II fog")
        XCTAssertFalse(m.undo.canUndo, "one rename, one step — not one per keystroke")
    }

    func test_committingTheSameLabelTwiceLeavesOneStep() {
        let m = model()
        inspector(m).commitLabel("Falls")
        inspector(m).commitLabel("Falls")
        m.undo.undo()
        XCTAssertEqual(m.scene.region(r1)?.label, "Act II fog",
                       "a commit on focus loss that changed nothing must not push "
                       + "a step the writer has to press ⌘Z twice to get past")
    }

    func test_collapsingThroughTheInspectorHidesTheResidents() {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        inspector(m).commitCollapsed(true)
        XCTAssertTrue(m.scene.isHidden(a))
        inspector(m).commitCollapsed(false)
        XCTAssertFalse(m.scene.isHidden(a))
    }

    func test_bindingThroughTheInspectorReachesDisk() {
        let m = model()
        inspector(m).commitBinding("piece-3")
        m.flush()
        XCTAssertEqual(CanvasStore(projectRoot: root).load().scene.region(r1)?.boundPieceID,
                       "piece-3")
    }

    func test_removingAMemberThroughTheInspectorIsAnExplicitAct() {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        inspector(m).remove(a)
        XCTAssertFalse(m.scene.region(r1)!.livesHere(a))
        XCTAssertNotNil(m.scene.node(a), "removing from a region never deletes the card")
        m.undo.undo()
        XCTAssertTrue(m.scene.region(r1)!.livesHere(a))
    }

    func test_theInspectorListsResidentsAndVisitorsSeparately() {
        let m = model()
        m.withScene {
            CanvasMembership.join(self.a, home: self.r1, in: &$0)
            CanvasMembership.addAppearance(self.b, to: self.r1, in: &$0)
        }
        let i = inspector(m)
        XCTAssertEqual(i.residents.map(\.node), [a])
        XCTAssertEqual(i.visitors.map(\.node), [b],
                       "§4.3: any region should answer 'which of these live here "
                       + "and which are visiting' at a glance")
    }

    func test_deletingTheRegionFromTheInspectorLeavesTheCards() {
        let m = model()
        m.withScene { CanvasMembership.join(self.a, home: self.r1, in: &$0) }
        inspector(m).deleteRegion()
        XCTAssertEqual(m.scene.regionCount, 1, "r2 survives")
        XCTAssertNil(m.scene.region(r1))
        XCTAssertNotNil(m.scene.node(a))
        XCTAssertNil(m.selection)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/RegionBindingTests CODE_SIGNING_ALLOWED=NO`
Expected: compile failure.

- [ ] **Step 3: Write `RegionBinding.swift`**

```swift
import Foundation

/// §4.4, the bridge: *"the nodes that live in a piece's region become the
/// pinned references beside the editor when you write it, and the context the
/// authoring compiler reads."*
///
/// **Produced here, consumed in 1A.** The reference rail is 1A's work and 1A is
/// unwritten; the binding is the durable half and has to exist first. The
/// inspector is what makes it inspectable and changeable today.
enum RegionBinding {

    static func bind(_ region: CanvasRegionID, toPiece piece: String,
                     in scene: inout CanvasScene) {
        scene.updateRegion(region) { $0.boundPieceID = piece }
    }

    static func unbind(_ region: CanvasRegionID, in scene: inout CanvasScene) {
        scene.updateRegion(region) { $0.boundPieceID = nil }
    }

    static func boundPiece(of region: CanvasRegionID, in scene: CanvasScene) -> String? {
        scene.region(region)?.boundPieceID
    }

    /// **Residents only.** A visitor is cited, not owned — bind on appearances
    /// and two regions sharing a card would each claim it as their piece's
    /// context. Unioned across regions, because more than one region may bind to
    /// the same piece and each contributes what lives in it.
    static func references(forPiece piece: String, in scene: CanvasScene) -> Set<CanvasNodeID> {
        scene.unorderedRegions
            .filter { $0.boundPieceID == piece }
            .reduce(into: Set<CanvasNodeID>()) {
                $0.formUnion(CanvasMembership.residents(of: $1.id, in: scene))
            }
    }
}
```

- [ ] **Step 4: Write `RegionInspector.swift`**

A static `Form`: the label `TextField` (committing on `.onSubmit` and focus loss), a collapse `Toggle`, a piece `Picker` over `pieces` with a "None" tag, a "Lives here" section and an "Appears here" section each listing `chipTitle`-style rows with a remove button, and a destructive "Delete Region" at the foot.

The commit methods are the test surface and each is one `model.mutate`. **Every one of them checks first that the value actually changed**, so a commit on focus loss that changed nothing pushes no step:

```swift
    func commitLabel(_ new: String) {
        guard let r = model.scene.region(regionID), r.label != new else { return }
        model.mutate("Rename Region") { $0.updateRegion(self.regionID) { $0.label = new } }
    }
```

`residents` and `visitors` are computed `[Row]` where `Row` carries the node id and the title, ordered by `CanvasRenderer.chipTitle` for a stable, readable list.

- [ ] **Step 5: Wire the `.canvas` inspector arm**

`existingInspectorSwitch`'s `.canvas` arm must stay **one expression**, so extract a helper:

```swift
        case .canvas:
            canvasInspector(store: store)
```

```swift
    @ViewBuilder
    private func canvasInspector(store: ProjectStore) -> some View {
        if let region = canvasModel.selectedRegion {
            RegionInspector(
                model: canvasModel,
                regionID: region.id,
                pieces: TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document })
                    .map { RegionInspector.PieceChoice(id: $0.id, title: $0.title) })
        } else {
            // Tripwire 15: the full-frame chain is required, and so is the
            // enclosing VStack's `alignment: .top` — without both, the toolbar
            // floats to the centre of the window. It has recurred four times.
            ContentUnavailableView("Select a region", systemImage: "square.dashed")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

`RegionBindingTests`, then the full suite, then Release — this touched `ProjectWindow`.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/RegionBinding.swift Maugham/Canvas/RegionInspector.swift \
        Maugham/Views/ProjectWindow.swift MaughamTests/Canvas/RegionBindingTests.swift
git commit -m "feat(canvas): the region inspector — label, collapse, piece binding, membership"
```

---

### Task 8: Docs

**Files:**
- Modify: `Maugham/Canvas/AREA.md`
- Modify: `Maugham/Canvas/CanvasView.swift` (two comments this slice falsifies)
- Modify: `docs/adr/0026-planning-canvas-rendering.md`
- Modify: `CLAUDE.md` (tripwire table, Canvas area row)
- Modify: `docs/guide/` (the persona topic), `docs/roadmap.md`, `docs/problem-map.md`

**ADR decision, made here so nobody relitigates it:** this slice **amends ADR 0026**; it does not mint a new number. Membership is part of the same canvas-architecture decision the ADR already records, and 1C-c is being written against the same tree — an unplanned number here would collide with it. If 1C-c wants its own ADR for promotion, it takes the next free one.

- [ ] **Step 1: Extend `AREA.md`**

Add a **Membership** section covering: explicit-only; the three tools that got it wrong and how; the one-home invariant and both places it is enforced (`CanvasMembership.join` and the codec's loader); what travels on a region drag (residents, never visitors); that removal is always its own act; that drop targeting is **the node's centre, ties broken on greatest overlap** — never a corner; and that collapse hides residents **in the scene**, so hit testing, culling, drawing and the AX tree agree by construction.

State plainly: **if you are about to write `region.frame.contains(node.origin)` near membership, you are reintroducing the bug class this design exists to eliminate.**

Add a **Who owns what** paragraph, with two rules rather than descriptions:

- **`CanvasModel` hosts `CanvasUndo`; it does not reimplement it.** A second snapshot mechanism silently loses `breakGesture` (per-sentence ⌘Z inside a scrap), the deferred `beginUndoGrouping` (a group cannot span an event boundary), the nesting depth counter, and the mid-gesture re-baseline. *Named symptom for the last:* type in A, click into B, ⌘Z, type in B, click out — and the next ⌘Z resurrects A's discarded text.
- **`sceneRevision` exists in two places on purpose.** `CanvasView`'s `@State` copy keeps its name because `CanvasAccessibilityTests` greps for `.onChange(of: sceneRevision`; the model's copy exists because the inspector mutates the scene from the other column. The view mirrors the model's in one line. Neither may be keyed on `revision`.

- [ ] **Step 2: Correct what this slice made false**

Three claims are now wrong and each is in more than one place. Rule 10: sweep them in this commit.

- **"1C-a has no delete path" / "`CanvasScene.remove` … has no production caller"** — in `AREA.md`'s "What 1C-a deliberately does not do", in its counters section, and in the `sceneRevision` doc comment in `CanvasView.swift`. Delete now exists (Task 6) and bumps the counter; say so, and remove the open scope question along with it.
- **"the interior of a region"/empty-canvas drag is a no-op** — `handleDrag`'s doc comment in `CanvasView.swift` says a left-drag beginning over empty canvas is intentionally a no-op and that there is no marquee-select. The first half is now false; the second is still true and should stay.
- **`CanvasScene.nodes(intersecting:)` and `topmostNode(at:)`** now skip hidden nodes. Their doc comments describe the filter; extend them.

```bash
grep -rn "no delete path\|no production caller\|intentionally a no-op" Maugham/ docs/
```

- [ ] **Step 3: Amend ADR 0026**

Add a section recording: membership is stored and geometry never changes it (with the Obsidian / tldraw #6017 / Scapple evidence); one home plus many appearances, and why copies were rejected; that the accepted cost — a resident sitting outside its region — is paid in the renderer as a tether; that region state persists in the canvas sidecar at schema 2 and not in the manifest, which is why the inspector takes a `CanvasModel` rather than a `ProjectStore`; and that a schema-2 sidecar opened by an older build costs the layout and not the words. Cite the constitution principles by name.

- [ ] **Step 4: Add the tripwire**

`CLAUDE.md`'s table is at **30**, so this slice takes **31**. Check the table before writing the row rather than trusting this number — a duplicate is worse than a gap.

| # | Rule | Why (1 clause) | Enforced / more |
|---|---|---|---|
| 31 | Canvas membership is never derived from geometry — not on move, not on resize, not on region creation. A drop targets by the node's CENTRE (ties on greatest overlap) and is the only gesture that changes it; removal is always its own act | Obsidian, tldraw (#6017) and Scapple each ship a distinct bug from the geometry→membership transition rule, and tldraw's persists *despite* explicit storage | `CanvasMembershipTests` (the firewall tests were falsified by introducing tldraw's ejection bug); `CanvasRegionInteractionTests` |

Also update the `Maugham/Canvas/` row of the per-area table: the canvas now has regions, a `CanvasModel` owned by `ProjectWindow`, and a delete path.

- [ ] **Step 5: Sweep the guide, roadmap and problem map**

Describe only what ships (rule 7): drawing a region by dragging on empty canvas, dropping a card in, the difference between living in and appearing in, collapsing, binding a region to a piece, ⌫, and that deleting a region never deletes cards. Do **not** describe promotion — that is 1C-c — and do **not** claim the binding yet feeds the editor's reference rail; that consumer is 1A.

```bash
grep -rn "region\|canvas" docs/roadmap.md docs/problem-map.md docs/guide/ | grep -iv corkboard
```

- [ ] **Step 6: Full verification**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test -only-testing MaughamTests/DocSyncTests CODE_SIGNING_ALLOWED=NO`
Expected: PASS. **Docs claims are code claims here** — a doc-only `CLAUDE.md` edit broke `DocSyncTests` during 1C-a.

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: full Mac suite green. Integration failures only surface in the full suite; do not call this done off a filtered run.

Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: green — confirms nothing leaked into MaughamCore. If the simulator wedges, re-run; do not `simctl shutdown all`.

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Maugham/Canvas/AREA.md Maugham/Canvas/CanvasView.swift \
        docs/adr/0026-planning-canvas-rendering.md CLAUDE.md \
        docs/guide docs/roadmap.md docs/problem-map.md
git commit -m "docs(canvas): membership rules, tripwire 31, ADR 0026 amendment, guide sweep"
```

---

## Whole-slice verification

- [ ] Full Mac suite, full phone suite, Release build — all green
- [ ] **Whole-branch review of the 1C-b diff.** Per-task reviews cannot see emergent interactions; the T5×T6 precedent on the unified-undo milestone is why this is not optional. Look hardest at **Task 3's blast radius across `CanvasView.swift`**: read that diff line by line and confirm nothing 1C-a shipped was deleted — the straighten clock and its timeline, `mountedEditorNodeID`/`visibleEditorNodeID` as two properties, momentum and its rest-branch bump, both revision counters, `lastKeystrokeAt`, all three commit points for the writer's words, every undo bracket, and the `.ended` resize ordering. Tasks 3, 5 and 6 each rewrite parts of that file and each can land green having quietly dropped one.
- [ ] `git diff --stat` on `Maugham/Canvas/CanvasView.swift` is a *small* number. A large one means it was retyped rather than edited.
- [ ] `git status` shows nothing under `Maugham.xcodeproj/`
- [ ] **The unfalsifiable-assertion sweep, over the whole slice.** 1C-a's plans carried seventeen assertions that could not fail for the reason they existed. Each task above has a step that asks the question locally; do one pass over every test this slice added and report the count of assertions strengthened or deleted.

### Smoke — regions

Drag on empty canvas over two existing cards → a region appears and has absorbed **neither** → drag one card in so its middle lands inside → drag the region by its label bar → the resident travels, the other card does not → **⌘Z once puts the whole drag back** → resize the region from its corner until it is tiny → the resident is still a member → drag the resident far outside → a tether draws → select a second card and cite it in the region from the inspector → it renders as a chip, visibly not a card, hairlined to the real one → rename the region in the inspector → collapse it → its residents vanish, the label says how many, and clicking where one was does nothing → expand it → bind it to a piece → select the region and press ⌫ → the region goes, the cards stay → ⌘Z → it comes back with its membership → select a card and press ⌫ → it goes → ⌘Z → it comes back with its words → quit and reopen → all of it survives.

### Smoke — the 1C-a behaviours Tasks 3, 5 and 6 could have broken

None of these would be noticed by a region test.

- Flick a card and let go: it coasts and comes to rest rather than stopping dead.
- Move a card quickly, hold it still, release: it stays where you parked it.
- Double-click a scrap: it straightens over a beat and the text does not blink or jump as the editor takes over.
- Double-click empty canvas and type immediately: the first characters are all there.
- Type two sentences into a scrap, then ⌘Z twice: it takes back a sentence at a time, not the whole visit.
- Type a sentence and ⌘Q **without clicking away**, then reopen: the sentence is there.
- Drag a scrap's bottom-right corner: it rewraps live and stays clickable.
- Pan and zoom: the grain does not crawl, text stays crisp, the point under the pointer stays under it.

**Do not push or tag.** M1 ships only when 1A and 1C are both in.
