import XCTest
@testable import Maugham

final class CanvasAccessibilityTests: XCTestCase {

    private func scrapNode(_ id: String, x: CGFloat, y: CGFloat) -> CanvasNode {
        CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                   origin: CGPoint(x: x, y: y), width: 240, cachedHeight: 80)
    }

    /// The shared fixture, and **it carries a line on purpose.**
    ///
    /// Every suite in this file drives it, so the line layer is exercised by the
    /// reading-order, frame, role and count assertions rather than only by the
    /// three tests written for it — otherwise the tree's coverage stays frozen at
    /// the shape it had before lines existed while the tree itself grows.
    /// `s1`–`s2` is labelled; `s3` and the item node are deliberately left
    /// unconnected, so the file always holds both halves of the control.
    private func sampleScene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(scrapNode("s1", x: 0, y: 0))
        s.insert(scrapNode("s2", x: 400, y: 8))       // same band as s1, to its right
        s.insert(scrapNode("s3", x: 0, y: 400))
        s.insert(CanvasNode(id: .item("r-9"), kind: .item(referenceId: "r-9"),
                            origin: CGPoint(x: 400, y: 400), width: 180, cachedHeight: 120))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("s1"),
                                to: CanvasNodeID("s2"), label: "because"))
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
        XCTAssertEqual(elements.first?.label,
                       "\(CanvasAccessibility.regionKind), Act II fog")
        XCTAssertEqual(elements.count, 2)
    }

    /// **`role` never reaches an assistive client**, so the kind has to be in the
    /// LABEL or it is not said at all: `CanvasAXChildren` publishes
    /// `accessibilityLabel` and `accessibilityValue` and nothing else, and
    /// `CanvasAXRole` is computed here and read only by these tests. A region
    /// announced as "Act II fog, 3 cards" says what it is called and never says
    /// what it is, beside a scrap that opens with "Scrap" and an item node that
    /// opens with "Reference" — a primitive the writer can see and the VoiceOver
    /// user cannot name, which is what §7A.6 calls this layer's whole job.
    ///
    /// The assertion is against the other two roles rather than against a
    /// literal, so it cannot be satisfied by a word that happens to be there.
    func test_everyRoleNamesItselfInTheLabelBecauseTheRoleItselfIsNeverPublished() {
        var s = sampleScene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        let elements = CanvasAccessibility.elements(scene: s, scraps: scraps)

        for role in [CanvasAXRole.scrap, .item, .region] {
            let label = elements.first { $0.role == role }?.label
            XCTAssertNotNil(label, "no element of role \(role) in the tree at all")
            XCTAssertFalse(label?.isEmpty ?? true,
                           "an element of role \(role) publishes an empty label, so "
                           + "an assistive client is handed a value and no idea "
                           + "what carries it")
        }

        XCTAssertEqual(elements.first { $0.role == .region }?.label,
                       "\(CanvasAccessibility.regionKind), Act II fog",
                       "the region does not name its kind, while the scrap and the "
                       + "item node both do — and `role` is not published, so "
                       + "nothing else says it")
    }

    func test_anUnlabelledRegionAnnouncesItselfRatherThanReadingAsBlank() {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        let label = CanvasAccessibility.elements(scene: s, scraps: [:]).first?.label
        XCTAssertEqual(label,
                       "\(CanvasAccessibility.regionKind), \(CanvasRegion.untitledLabel)")
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
        XCTAssertEqual(label(collapsed: false),
                       "\(CanvasAccessibility.regionKind), Act II fog")
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
        let src = codeOnly(try accessibilitySource())
        XCTAssertTrue(src.contains("scene.unorderedNodes"),
                      "the element list must come from the UNORDERED nodes")
        XCTAssertFalse(src.contains("scene.nodes"),
                       "CanvasScene.nodes sorts the whole scene on every access — "
                       + "this file re-sorts into reading order, and `summary` is "
                       + "read from `body` on every pass")
    }

    // MARK: - Lines (§7A.6 — a relationship nobody can perceive is not a
    // relationship). A line is not an element of its own: an element carries a
    // content-space frame, and a line's is a bounding box a user would navigate
    // into and find nothing in. It is named at both its ends instead.

    private func label(_ id: String, in scene: CanvasScene,
                       scraps: [CanvasNodeID: String] = [:]) -> String? {
        CanvasAccessibility.elements(scene: scene, scraps: scraps)
            .first { $0.id == .node(CanvasNodeID(id)) }?.label
    }

    /// The negative half is the control, and it is in the same fixture: `s3` is
    /// a scrap of exactly the same kind sitting on exactly the same canvas, so a
    /// build that appended the phrase to every card — or to none — fails one of
    /// these two.
    func test_aConnectedScrapSaysSoInItsLabel() {
        let scene = sampleScene()
        XCTAssertEqual(label("s1", in: scene), "Scrap, 1 line: because",
                       "a card with a line on it announces itself identically to one "
                       + "with none, so the whole line layer is inaudible")
        XCTAssertEqual(label("s3", in: scene), "Scrap",
                       "control: an UNCONNECTED card must not claim a connection")
    }

    /// The label is the only thing a line ever says, so it has to reach both
    /// ends — a VoiceOver user arriving at either card must learn the same
    /// relationship. An implementation that indexed only `from` reads correctly
    /// from one direction and is silent from the other.
    func test_aLabelledLineIsNamedInBothItsEndpointsLabels() {
        let scene = sampleScene()
        XCTAssertEqual(label("s1", in: scene), "Scrap, 1 line: because",
                       "the line is not named at its `from` end")
        XCTAssertEqual(label("s2", in: scene), "Scrap, 1 line: because",
                       "the line is not named at its `to` end — indexing one "
                       + "direction reads correctly from whichever card the walk "
                       + "happens to reach first")
    }

    /// An item node is the other connectable primitive, and it took the same
    /// change. Without this, `Reference` keeps 1C-b's shape while `Scrap` grows.
    func test_anItemNodeNamesItsConnectionsToo() {
        var scene = sampleScene()
        scene.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("s3"),
                                    to: .item("r-9"), label: "source"))
        XCTAssertEqual(label("item:r-9", in: scene), "Reference, 1 line: source")
    }

    /// A line is untyped and optionally named by design (spec §5), so most of
    /// them have no name at all — and the count is then the only thing to say.
    func test_anUnlabelledLineIsCountedRatherThanNamed() {
        var scene = CanvasScene()
        scene.insert(scrapNode("a", x: 0, y: 0))
        scene.insert(scrapNode("b", x: 400, y: 0))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                    to: CanvasNodeID("b")))
        XCTAssertEqual(label("a", in: scene), "Scrap, 1 line",
                       "an unlabelled line either vanishes from the label or "
                       + "announces an empty name")
    }

    /// Whitespace is no label — the same rule `LineInspector.normalise` applies
    /// on the way in, asserted here because a label that arrived from a
    /// hand-edited sidecar never passed through it.
    func test_aWhitespaceLabelIsNotReadOutAsAName() {
        var scene = CanvasScene()
        scene.insert(scrapNode("a", x: 0, y: 0))
        scene.insert(scrapNode("b", x: 400, y: 0))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                    to: CanvasNodeID("b"), label: "   "))
        XCTAssertEqual(label("a", in: scene), "Scrap, 1 line",
                       "a label of spaces is read out as a name, so the card "
                       + "announces \"1 line:\" and then stops")
    }

    func test_severalLinesOnOneCardAreCountedAndNamedTogether() {
        var scene = CanvasScene()
        scene.insert(scrapNode("hub", x: 0, y: 0))
        for (i, name) in ["because", nil, "then"].enumerated() {
            scene.insert(scrapNode("n\(i)", x: 400, y: CGFloat(i) * 200))
            scene.insertLine(CanvasLine(id: CanvasLineID("l\(i)"), from: CanvasNodeID("hub"),
                                        to: CanvasNodeID("n\(i)"), label: name))
        }
        XCTAssertEqual(label("hub", in: scene), "Scrap, 3 lines: because, then",
                       "the unlabelled line must still be counted, and the named "
                       + "ones must still be named")
    }

    /// **`Dictionary` iteration is seeded per process**, so a phrase built from
    /// an unordered walk reads differently between two runs of the same binary —
    /// the bug `CanvasMembership.homeRegion` was measured flaking on. The names
    /// come out in `scene.lines`' id order.
    ///
    /// Five lines, so an unordered implementation agrees with this by chance
    /// about once in 120 runs rather than half the time. That is a probabilistic
    /// guard against a probabilistic bug, exactly as the `homeRegion` one is; if
    /// it is ever seen flaking, somebody dropped the ordered accessor.
    func test_theNamesComeOutInAStableOrder() {
        var scene = CanvasScene()
        scene.insert(scrapNode("hub", x: 0, y: 0))
        // Inserted in an order that is neither the id order nor its reverse.
        for (i, id) in ["l3", "l1", "l5", "l2", "l4"].enumerated() {
            scene.insert(scrapNode("n\(i)", x: 400, y: CGFloat(i) * 200))
            scene.insertLine(CanvasLine(id: CanvasLineID(id), from: CanvasNodeID("hub"),
                                        to: CanvasNodeID("n\(i)"), label: id))
        }
        XCTAssertEqual(label("hub", in: scene), "Scrap, 5 lines: l1, l2, l3, l4, l5",
                       "the names are in dictionary order, which Swift seeds per "
                       + "process — so the same canvas reads differently between two "
                       + "runs of the same binary")
    }

    /// **A resident of a collapsed region has left the tree entirely**, so a line
    /// to it names a card an assistive client cannot navigate to. The filter is
    /// `scene.isHidden`, the same predicate the node loop reads, so this tree has
    /// one rule about collapse rather than two.
    func test_aLineIntoACollapsedRegionIsNotAnnouncedOnTheCardOutsideIt() {
        var scene = CanvasScene()
        scene.insert(scrapNode("out", x: 0, y: 0))
        scene.insert(scrapNode("in", x: 400, y: 0))
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Cut",
                                        frame: CGRect(x: 380, y: -40, width: 300, height: 200),
                                        homeMembers: [CanvasNodeID("in")]))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("out"),
                                    to: CanvasNodeID("in"), label: "because"))

        XCTAssertEqual(label("out", in: scene), "Scrap, 1 line: because",
                       "control: while the region is expanded the line IS announced, "
                       + "so the silence below is the collapse and not the membership")

        scene.updateRegion(CanvasRegionID("r1")) { $0.isCollapsed = true }
        XCTAssertTrue(scene.isHidden(CanvasNodeID("in")),
                      "precondition: the far end really is hidden")
        XCTAssertEqual(label("out", in: scene), "Scrap",
                       "a card announces a line to a card that is not in the tree at "
                       + "all — the user is told about a relationship and given "
                       + "nowhere to walk to")
    }

    /// **An UNMEASURED end is different from a hidden one, and this is the pair
    /// that says so.** `CanvasScene.drawnLines` drops both and would have been
    /// the tempting single source — but the node loop keeps an unmeasured card in
    /// the tree on purpose, so a line to a card that IS in the tree belongs in
    /// the tree with it.
    func test_aLineToAnUnmeasuredCardIsStillAnnounced() {
        var scene = CanvasScene()
        scene.insert(scrapNode("a", x: 0, y: 0))
        scene.insert(CanvasNode(id: CanvasNodeID("fresh"), kind: .scrap,
                                origin: CGPoint(x: 400, y: 0), width: 240))   // no height
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                    to: CanvasNodeID("fresh"), label: "because"))
        XCTAssertTrue(scene.drawnLines.isEmpty,
                      "precondition: the RENDERER drops this line, so this test is "
                      + "about the tree deliberately not following it")
        XCTAssertNotNil(label("fresh", in: scene),
                        "precondition: the unmeasured card is itself in the tree")
        XCTAssertEqual(label("a", in: scene), "Scrap, 1 line: because",
                       "a line to a card the writer just made goes unannounced until "
                       + "a layout pass happens to run")
    }

    /// A line's frame would be the bounding box of two other people's cards —
    /// mostly bare ground, and a sliver when the line is near-axis-aligned. A
    /// VoiceOver user would navigate into it and find nothing.
    func test_aLineIsNotAnElementOfItsOwn() {
        let elements = CanvasAccessibility.elements(scene: sampleScene(), scraps: scraps)
        XCTAssertEqual(elements.count, 4,
                       "the line became a fifth element — an element carries a frame, "
                       + "and a line's is a rectangle with nothing in it")
        XCTAssertEqual(Set(elements.map(\.role)), [.scrap, .item],
                       "control: the four that are here are the four nodes")
    }

    /// Without this, a canvas the writer has drawn twenty relationships on
    /// announces itself identically to one with none — and lines are elements
    /// nowhere, so the summary is the only place the layer's size is said.
    func test_theSummaryReportsTheLineCount() {
        var bare = sampleScene()
        for line in bare.lines { bare.removeLine(line.id) }
        XCTAssertEqual(CanvasAccessibility.summary(scene: bare), "4 items",
                       "control: with no lines the summary says nothing about them")

        XCTAssertEqual(CanvasAccessibility.summary(scene: sampleScene()), "4 items, 1 line")

        var two = sampleScene()
        two.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("s2"),
                                  to: CanvasNodeID("s3")))
        XCTAssertEqual(CanvasAccessibility.summary(scene: two), "4 items, 2 lines")
    }

    /// `summary` is read from `body`, and `CanvasScene.lines` sorts the whole set
    /// with a `String` comparison in its predicate on every access — the original
    /// `scene.nodes.count` regression, in a second id space.
    ///
    /// It slices from the declaration rather than scanning the file, because
    /// `elements` legitimately DOES reach for the ordered accessor: it needs one
    /// walk in a stable order and it is not on the `body` path.
    func test_theSummaryCountsLinesWithoutSortingThem() throws {
        let src = codeOnly(try accessibilitySource())
        let decl = try XCTUnwrap(src.range(of: "static func summary(scene:"),
                                 "summary has been renamed — this scan is now "
                                 + "asserting nothing")
        let body = String(src[decl.lowerBound...])
        XCTAssertTrue(body.contains("scene.lineCount"),
                      "summary must count lines through the dictionary's own count")
        XCTAssertFalse(body.contains("scene.lines"),
                       "summary reaches for the SORTED line list, and it is read from "
                       + "`body` — a full sort of the line set per render")
    }

    private func accessibilitySource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham/Canvas/CanvasAccessibility.swift"),
            encoding: .utf8)
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
