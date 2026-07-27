import XCTest
@testable import Maugham

final class CanvasAccessibilityTests: XCTestCase {

    private func scrapNode(_ id: String, x: CGFloat, y: CGFloat) -> CanvasNode {
        CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                   origin: CGPoint(x: x, y: y), width: 240, cachedHeight: 80)
    }

    private func sampleScene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(scrapNode("s1", x: 0, y: 0))
        s.insert(scrapNode("s2", x: 400, y: 8))       // same band as s1, to its right
        s.insert(scrapNode("s3", x: 0, y: 400))
        s.insert(CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                            origin: CGPoint(x: 400, y: 400), width: 180, cachedHeight: 120))
        return s
    }

    private let scraps: [CanvasNodeID: String] = [
        CanvasNodeID("s1"): "The falls at night.",
        CanvasNodeID("s2"): "October's doctor was kind about it.",
        CanvasNodeID("s3"): "",
    ]

    func test_everyNodeIsAnAccessibilityElement() {
        let elements = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps)
        XCTAssertEqual(elements.count, 4)
    }

    /// Culling is a DRAWING optimisation. A node you cannot see is still a node
    /// you must be able to reach.
    func test_offscreenNodesAreStillInTheTree() {
        var scene = sampleScene()
        scene.insert(scrapNode("far", x: 90_000, y: 90_000))
        let elements = CanvasAccessibility.elements(scene: scene, scraps: scraps)
        XCTAssertTrue(elements.contains { $0.id == .node(CanvasNodeID("far")) })
    }

    func test_readingOrderIsRowsThenColumns() {
        let ids = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps).map(\.id.raw)
        XCTAssertEqual(ids, ["s1", "s2", "s3", "item:r-9"],
                       "roughly-level cards must read left to right as one row, "
                       + "not in the order the writer happened to touch them")
    }

    /// **The test above cannot fail for the reason it exists, and this one can.**
    ///
    /// In that fixture the right-hand card of the top row is also the LOWER one
    /// (y=8 against y=0), so a plain `sorted by (y, x)` with no banding at all
    /// returns the identical answer — while the assertion message it would print
    /// is about banding. The banding is invisible to it.
    ///
    /// Here the right-hand card is 20pt HIGHER than the left one, so the two
    /// implementations disagree: banded reads `z1` then `a1` (one row, left to
    /// right); un-banded reads `a1` first because it is nearer the top. The ids
    /// are chosen so that an alphabetical sort — the other thing a comparator can
    /// collapse to — also gives the wrong answer. One fixture, three wrong
    /// implementations caught.
    func test_aCardSlightlyHigherToTheRightStillReadsSecondInItsRow() {
        var scene = CanvasScene()
        scene.insert(scrapNode("z1", x: 0, y: 20))
        scene.insert(scrapNode("a1", x: 400, y: 0))
        let ids = CanvasAccessibility.elements(scene: scene, scraps: [:]).map(\.id.raw)
        XCTAssertEqual(ids, ["z1", "a1"],
                       "two cards 20pt apart vertically are one row to a reader, so "
                       + "they must read left to right — sorting on raw y reads the "
                       + "canvas out in a zigzag, and sorting on the id reads it out "
                       + "in an order that means nothing at all")
    }

    /// **The banding must be a proximity band, not a fixed grid.**
    ///
    /// `(y / rowBand).rounded(.down)` measures distance from the ORIGIN rather
    /// than distance between the cards, so wherever a cell boundary happens to
    /// fall, two cards a couple of points apart land in different rows while two
    /// cards nearly a whole band apart share one. On a canvas the writer places
    /// freely, a pair straddling a boundary is routine rather than a corner case
    /// — and it is invisible to
    /// `test_aCardSlightlyHigherToTheRightStillReadsSecondInItsRow` above, whose
    /// fixture passes under a grid only because y=0 and y=20 happen to share a
    /// cell.
    ///
    /// The fixture is deliberately expressed in terms of `rowBand` itself rather
    /// than a literal 60, so shrinking or growing the band cannot quietly turn
    /// this test into one that agrees with any implementation. The ids again make
    /// an alphabetical sort wrong, and the right-hand card is again the higher one
    /// so a raw-y sort is wrong too.
    func test_twoNearLevelCardsEitherSideOfABandBoundaryStillReadAsOneRow() {
        let band = CanvasAccessibility.rowBand
        var scene = CanvasScene()
        scene.insert(scrapNode("z2", x: 0, y: band + 1))       // just below the boundary
        scene.insert(scrapNode("a2", x: 400, y: band - 1))     // just above it
        let ids = CanvasAccessibility.elements(scene: scene, scraps: [:]).map(\.id.raw)
        XCTAssertEqual(ids, ["z2", "a2"],
                       "two cards 2pt apart vertically read as two separate rows "
                       + "because a band boundary falls between them — the banding "
                       + "is a fixed grid keyed on distance from the origin, not a "
                       + "proximity band, so whether roughly-level cards read as one "
                       + "row depends on where they happen to sit on the canvas")
    }

    func test_aScrapCarriesItsTextAsItsValue() {
        let element = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps)
            .first { $0.id == .node(CanvasNodeID("s1")) }
        XCTAssertEqual(element?.role, .scrap)
        XCTAssertEqual(element?.value, "The falls at night.")
        XCTAssertTrue(element?.label.contains("Scrap") == true)
    }

    func test_anEmptyScrapSaysSoRatherThanReadingAsBlank() {
        let element = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps)
            .first { $0.id == .node(CanvasNodeID("s3")) }
        XCTAssertEqual(element?.value, CanvasAccessibility.emptyScrapValue)
        XCTAssertFalse(CanvasAccessibility.emptyScrapValue.isEmpty)
    }

    func test_anItemNodeIsLabelledAsAReference() {
        let element = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps)
            .first { $0.id == .node(.item("r-9")) }
        XCTAssertEqual(element?.role, .item)
        XCTAssertTrue(element?.value.contains("r-9") == true)
    }

    // MARK: - Regions (§7A.6 — a primitive the writer can see and the VoiceOver
    // user cannot is precisely the failure this layer exists to prevent)

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

    /// The value is the card count either way, so without the state in the
    /// LABEL a collapsed region and an expanded one holding the same cards read
    /// out identically — and collapse is the one thing a VoiceOver user cannot
    /// otherwise discover, because a collapsed region's cards have left the tree.
    func test_aCollapsedRegionSoundsDifferentFromAnExpandedOneHoldingTheSameCards() {
        func label(collapsed: Bool) -> String? {
            var s = CanvasScene()
            s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap,
                                origin: CGPoint(x: 50, y: 50), width: 240, cachedHeight: 80))
            s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                        homeMembers: [CanvasNodeID("a")],
                                        isCollapsed: collapsed))
            return CanvasAccessibility.elements(scene: s, scraps: [:])
                .first { $0.role == .region }?.label
        }
        XCTAssertNotEqual(label(collapsed: true), label(collapsed: false))
        XCTAssertEqual(label(collapsed: false), "Act II fog")
    }

    /// Frames are in VIEW coordinates, so an assistive client can point at them.
    func test_elementsAreCameraIndependentAndResolveThroughTheCamera() throws {
        let element = try XCTUnwrap(
            CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps)
                .first { $0.id == .node(CanvasNodeID("s1")) })
        XCTAssertEqual(element.contentFrame, CGRect(x: 0, y: 0, width: 240, height: 80),
                       "elements must not depend on the camera — otherwise every "
                       + "scroll event rebuilds a scene-proportional list inside a "
                       + "per-frame loop")

        var camera = CanvasCamera()
        camera.zoom = 2
        camera.pan = CGPoint(x: 50, y: 30)
        XCTAssertEqual(element.viewFrame(in: camera),
                       CGRect(x: 50, y: 30, width: 480, height: 160),
                       "an assistive client points at VIEW coordinates")
    }

    func test_anUnmeasuredNodeIsStillReachable() {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: CanvasNodeID("new"), kind: .scrap,
                                origin: .zero, width: 240))   // no cachedHeight
        let elements = CanvasAccessibility.elements(scene: scene, scraps: [:])
        XCTAssertEqual(elements.count, 1,
                       "a scrap the writer just made must not be unreachable "
                       + "until it happens to be measured")
        XCTAssertGreaterThan(elements[0].contentFrame.height, 0)
    }

    func test_anEmptyCanvasAnnouncesItselfRatherThanBeingSilent() {
        XCTAssertEqual(CanvasAccessibility.summary(scene: CanvasScene()),
                       CanvasAccessibility.emptyCanvasValue)
        XCTAssertTrue(CanvasAccessibility.summary(scene: sampleScene()).contains("4"))
    }

    /// The tree is only real if the view actually installs it.
    func test_canvasViewInstallsTheAccessibilityChildren() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()    // MaughamTests/Canvas
                .deletingLastPathComponent()    // MaughamTests
                .deletingLastPathComponent()    // repo root
                .appendingPathComponent("Maugham/Canvas/CanvasView.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains(".accessibilityChildren"),
                      "spec §7A.6: drawn content has no AX tree and we own one — "
                      + "CanvasAccessibility exists but CanvasView never installs it")
        XCTAssertTrue(source.contains("CanvasAccessibility.elements"))
    }

    /// The tree must be rebuilt on a state change, never inside `body`. `body`
    /// runs per scroll event, per drag frame and per momentum tick; building a
    /// scene-proportional list there is exactly the work Task 16 asserts stays
    /// proportional to the viewport.
    func test_theTreeIsBuiltOnChangeRatherThanInsideBody() throws {
        let source = try canvasViewSource()
        let build = try XCTUnwrap(source.range(of: "CanvasAccessibility.elements"))
        let onChange = try XCTUnwrap(source.range(of: ".onChange(of: sceneRevision"),
                                     "the AX tree must be rebuilt from an onChange")
        XCTAssertTrue(onChange.lowerBound < build.lowerBound,
                      "CanvasAccessibility.elements is being called before the "
                      + "onChange that should own it — i.e. inside body")
    }

    /// ...and on the STRUCTURAL counter, not the redraw one. `revision` is
    /// bumped by `handleDrag(.changed)` and again by the timeline's per-frame
    /// `.onChange(of: context.date)`, which covers both the straighten clock and
    /// every momentum coast — so an `.onChange(of: revision)` here rebuilds the
    /// whole tree at 60–120 Hz through any drag, coast or focus animation.
    func test_theTreeIsNotKeyedOnTheRedrawCounter() throws {
        XCTAssertFalse(codeOnly(try canvasViewSource()).contains(".onChange(of: revision"),
                       "the accessibility tree is keyed on the redraw counter — it "
                       + "will sort the scene and copy every scrap's string once "
                       + "per frame for the whole of every animation")
    }

    /// The children read the camera, so inline in `body` they are N synthetic
    /// views rebuilt per frame — the same scene-proportional work, one layer
    /// down from the cached list.
    func test_theSyntheticChildrenAreExtractedAndEquatable() throws {
        let src = codeOnly(try canvasViewSource())
        XCTAssertTrue(src.contains("CanvasAXChildren(elements: axElements, camera: camera)"))
        XCTAssertTrue(src.contains(".equatable()"),
                      "without .equatable() the extraction buys nothing — SwiftUI "
                      + "re-evaluates the children on every body pass")
        XCTAssertFalse(src.contains("ForEach(axElements)"),
                       "the ForEach belongs in CanvasAXChildren, not in body")
    }

    /// Task 7's rule, and this is the file that made it worth writing down:
    /// `CanvasScene.nodes` sorts the whole scene on every access, with a `String`
    /// comparison in the predicate. `elements` re-sorts into reading order and
    /// `summary` is read from `body` — either one reaching for `nodes` pays for a
    /// sort it throws away.
    func test_nothingHereReachesForTheDrawOrderedNodeList() throws {
        let src = codeOnly(try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Maugham/Canvas/CanvasAccessibility.swift"),
            encoding: .utf8))
        XCTAssertTrue(src.contains("scene.unorderedNodes"),
                      "the element list must come from the UNORDERED nodes")
        XCTAssertFalse(src.contains("scene.nodes"),
                       "CanvasScene.nodes sorts the whole scene on every access — "
                       + "this file re-sorts into reading order, and `summary` is "
                       + "read from `body` on every pass")
    }

    private func canvasViewSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MaughamTests/Canvas
            .deletingLastPathComponent()    // MaughamTests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("Maugham/Canvas/CanvasView.swift"), encoding: .utf8)
    }

    /// A doc comment that NAMES a modifier is documentation; only code counts —
    /// the same rule `CanvasCompositionTests` uses, for the same reason.
    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
