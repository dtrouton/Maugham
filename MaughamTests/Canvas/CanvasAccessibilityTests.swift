import XCTest
import MaughamCore
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
        s.insert(CanvasNode(id: .item("r-9"), kind: .item(.project(id: "r-9")),
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
        XCTAssertEqual(element?.label, "Reference")
    }

    /// **The mark is SPOKEN on the same terms it is drawn** (1C-d Task 8, one
    /// predicate: `CanvasNodeKind.carriesAMark`). An owned picture that produced
    /// a research asset says so; a reference carrying the field a hand-edited
    /// sidecar could put there does not, because nothing about the project's own
    /// research item made it true.
    ///
    /// A promoted picture drawn with a stripe and silent to VoiceOver is exactly
    /// the drawn/spoken divergence §7A.6 exists to prevent — and the two on this
    /// surface that ARE deliberate are recorded in `Maugham/Canvas/AREA.md`.
    func test_anOwnedPicturesMarkIsSpokenAndAReferencesIsNot() throws {
        var scene = CanvasScene()
        let owned = CanvasNodeID("owned-1")
        scene.insert(CanvasNode(id: owned, kind: .item(.owned(path: "canvas_assets/p.png")),
                                origin: .zero, width: 180, cachedHeight: 200,
                                promotedItemID: "res-asset"))
        scene.insert(CanvasNode(id: .item("r-9"), kind: .item(.project(id: "r-9")),
                                origin: CGPoint(x: 400, y: 0), width: 180,
                                cachedHeight: 120, promotedItemID: "res-nonsense"))
        let elements = CanvasAccessibility.elements(scene: scene, scraps: [:])

        let picture = try XCTUnwrap(elements.first { $0.id == .node(owned) }).label
        XCTAssertTrue(picture.contains(CanvasAccessibility.promotedTerm),
                      "found: \(picture)")
        let reference = try XCTUnwrap(elements.first { $0.id == .node(.item("r-9")) }).label
        XCTAssertFalse(reference.contains(CanvasAccessibility.promotedTerm),
                       "the control, and the refusal that stands: found \(reference)")
    }

    /// **What an item node READS OUT is its title, and never its reference id**
    /// *(1C-d)*. It was `Item · r-9` — the placeholder label — which was honest
    /// only while the card drew the same string; a card that shows "Notebook
    /// page 3" over an element that says `Item · r-9` is a drawn/spoken
    /// divergence nobody decided, and the two on this surface that ARE decided
    /// are recorded as such in `Maugham/Canvas/AREA.md`.
    ///
    /// The id assertion is the one that matters and it is written as an absence,
    /// with the title equality beside it as the control: "does not contain the
    /// id" is satisfied by an empty string, and an element that says nothing is
    /// the §7A.6 failure this whole layer exists to prevent.
    func test_anItemNodeReadsOutItsTitleRatherThanItsReferenceId() throws {
        let scene = sampleScene()
        let index = CanvasItemIndex(entriesByID: [
            "r-9": .init(title: "Notebook page 3", kind: .researchNote)])
        let element = try XCTUnwrap(
            CanvasAccessibility.elements(scene: scene, scraps: scraps,
                                         items: .facts(in: scene, index: index))
                .first { $0.id == .node(.item("r-9")) })

        XCTAssertEqual(element.value, "Notebook page 3")
        XCTAssertFalse(element.value.contains("r-9"),
                       "an item node still reads out its reference id — a code is not "
                       + "something a listener can act on, and the card beside it "
                       + "draws a title")
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

    // MARK: - Where, not just what — the half of it that needs no window

    /// **The frame an assistive client points at, asked where nothing can be
    /// unavailable.**
    ///
    /// A published frame is the end of a pipeline with six hops: the scene, the
    /// content-space rect this file builds, the camera, SwiftUI's publication of
    /// it, the accessibility runtime, and the screen coordinates that come back.
    /// The last three need a hosted window and an attached assistive client, and
    /// `CanvasViewMountingSurfaceTests` owns them — they are also the hops that behave
    /// differently on different macOS versions, which is what split this coverage
    /// in two on 2026-07-31.
    ///
    /// **The first two hops hold every mistake we can make ourselves**, and they
    /// are pure arithmetic over a struct. So they are asked here, of a card whose
    /// numbers can discriminate: a y that differs from its x (an axis swap is
    /// caught), and neither of them zero.
    ///
    /// That last part is the whole reason these tests exist beside
    /// `test_elementsAreCameraIndependentAndResolveThroughTheCamera` rather than
    /// inside it. That test reads `s1`, which sits at the content ORIGIN, and
    /// (0, 0) is the one point a negated y leaves exactly where it was.
    ///
    /// **The shape of the flip decides whether it can see one, and that was
    /// settled by experiment rather than by reading.** Negate the CONTENT y on
    /// its way into the camera — `viewPoint(fromContent:)` handed
    /// `-contentFrame.origin.y`, which is the mistake a y-down/y-up confusion
    /// actually makes — and that test stays GREEN while these go red, because
    /// −0 is 0. Negate the view y the camera has already produced and all of
    /// them fail, because the pan has made it non-zero by then. Only the second
    /// of those two was ever covered.
    private func offOriginScene() -> CanvasScene {
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: CanvasNodeID("s1"), kind: .scrap,
                                origin: CGPoint(x: 20, y: 90), width: 240,
                                cachedHeight: 60))
        return scene
    }

    private func offOriginElement() throws -> CanvasAXElement {
        try XCTUnwrap(CanvasAccessibility.elements(scene: offOriginScene(),
                                                   scraps: [CanvasNodeID("s1"): "the falls at night"])
            .first { $0.id == .node(CanvasNodeID("s1")) })
    }

    /// Hop one: the rect the element carries is the card's own rectangle, in the
    /// scene's own coordinates — origin from the node, width from the node,
    /// height from what measuring it produced.
    func test_aCardsContentFrameIsTheCardsOwnRectangle() throws {
        XCTAssertEqual(try offOriginElement().contentFrame,
                       CGRect(x: 20, y: 90, width: 240, height: 60),
                       "the element's rect is not the card's — an assistive client "
                       + "is pointed somewhere the writer's card is not, and no "
                       + "camera downstream can put it back")
    }

    /// Hop two: the camera maps that rect to where the card is drawn.
    ///
    /// Pan and zoom are both non-identity and the two axes differ, so the
    /// expected rect is wrong under every neighbouring mistake: a negated y
    /// reads −150, a camera never applied reads (20, 90, 240, 60), a pan applied
    /// without the zoom reads (70, 120), and a swapped pair reads (140, 160).
    func test_theCameraMapsThatRectangleToWhereTheCardIsDrawn() throws {
        var camera = CanvasCamera()
        camera.zoom = 2
        camera.pan = CGPoint(x: 50, y: 30)
        XCTAssertEqual(try offOriginElement().viewFrame(in: camera),
                       CGRect(x: 90, y: 210, width: 480, height: 120),
                       "the element does not resolve to where the card is drawn — "
                       + "on the y axis the likeliest cause is a flip between "
                       + "SwiftUI's y-down space and AppKit's y-up screen "
                       + "coordinates, and on the size it is a zoom left off")
    }

    /// The control for both of the above: at rest the two spaces coincide, so a
    /// camera that has not moved must change nothing at all. Without this, an
    /// implementation that applied some constant offset would satisfy neither
    /// test above by accident and this one says which of them is the fixture and
    /// which is the arithmetic.
    func test_aCameraAtRestLeavesTheCardWhereTheSceneHasIt() throws {
        let element = try offOriginElement()
        XCTAssertEqual(element.viewFrame(in: CanvasCamera()), element.contentFrame,
                       "an untouched camera moved the card: view and content "
                       + "coordinates are the same space until the writer pans or "
                       + "zooms, so every frame on a fresh canvas is already wrong")
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
    ///
    /// **The newline case is the one that made the trims matter.**
    /// `.whitespaces` is space and tab only, so `"\n"` survives it. The renderer
    /// trimmed that narrower set until 1C-c3 widened it
    /// (`CanvasLineRenderTests.test_aWhitespaceOnlyLabelDrawsNoPill` is its
    /// half), so the three readings now agree — reached by fixing the drawing,
    /// not by announcing it. This assertion is unchanged either way: it is about
    /// what is SAID, and it fails on its own if this trim ever narrows.
    func test_aWhitespaceLabelIsNotReadOutAsAName() {
        for blank in ["   ", "\n", " \t\n "] {
            var scene = CanvasScene()
            scene.insert(scrapNode("a", x: 0, y: 0))
            scene.insert(scrapNode("b", x: 400, y: 0))
            scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                        to: CanvasNodeID("b"), label: blank))
            XCTAssertEqual(label("a", in: scene), "Scrap, 1 line",
                           "a label of \(blank.debugDescription) is read out as a "
                           + "name, so the card announces \"1 line:\" and then stops")
        }
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

    /// The renderer has this test (`test_anItemNodeGetsNoMarkBecauseItCannotBePromoted`)
    /// and the accessibility layer did not. An item node already exists as
    /// itself, so a mark on one says nothing true — and a hand-edited sidecar
    /// can put the field there, which is the only route to this state. The
    /// `promoted: false` in `elements`' `.item` arm is the code that refuses it,
    /// and nothing was asserting it.
    ///
    /// The control is the scrap beside it: **the same mark on a card DOES say
    /// "promoted"**, so this is about the kind and not about a label that never
    /// mentions promotion at all.
    func test_anItemNodeWithAHandEditedMarkIsNotAnnouncedAsPromoted() {
        var s = CanvasScene()
        s.insert(CanvasNode(id: .item("r-9"), kind: .item(.project(id: "r-9")),
                            origin: .zero, width: 180, cachedHeight: 120,
                            promotedItemID: "res-nonsense"))
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap,
                            origin: CGPoint(x: 0, y: 400), width: 240, cachedHeight: 80,
                            promotedItemID: "res-a"))
        let elements = CanvasAccessibility.elements(scene: s, scraps: [:])
        let reference = elements.first { $0.id == .node(.item("r-9")) }?.label
        let card = elements.first { $0.id == .node(CanvasNodeID("a")) }?.label
        XCTAssertEqual(reference, "Reference",
                       "a mark on a reference is meaningless, and the renderer "
                       + "refuses to draw one for the same reason")
        XCTAssertEqual(card, "Scrap, \(CanvasAccessibility.promotedTerm)",
                       "the control: the same field on a card IS announced")
    }

    func test_aPromotedRegionSaysSoAfterItsName() {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                    promotedItemID: "res-fog"))
        XCTAssertEqual(CanvasAccessibility.elements(scene: s, scraps: [:]).first?.label,
                       "Region, Act II fog, promoted")
    }

    // MARK: - Whose hand made this (§8A.2)

    /// The drawn signal is a cooler paper and a cooler hairline, and neither is
    /// visible to an assistive client — §8A.2 constraint 1 is not met by a colour
    /// alone. So the label says it, in the same words the rest of the surface
    /// uses: `CanvasClaudePlacement.defaultRegionLabel` is "From Claude" and
    /// `CanvasClaudeWrite.undoStepName` is "Add Scraps from Claude", and a third
    /// phrasing here would make one fact sound like three.
    ///
    /// **The kind stays first**, for the reason every label on this surface leads
    /// with it: `CanvasAXRole` never reaches an assistive client. Then provenance
    /// — where the card came from is prior to what has happened to it since — and
    /// then the durable facts in the order they were added.
    func test_aScrapFromClaudeSaysSoWithTheKindStillFirst() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80, promotedItemID: "res-a",
                            author: .claude))
        s.insert(CanvasNode(id: CanvasNodeID("b"), kind: .scrap,
                            origin: CGPoint(x: 0, y: 400), width: 240, cachedHeight: 80))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b"), label: "because"))
        let elements = CanvasAccessibility.elements(scene: s, scraps: [:])
        let card = try XCTUnwrap(elements.first { $0.id == .node(CanvasNodeID("a")) },
                                 "the card is not in the tree at all")
        XCTAssertEqual(card.label,
                       "Scrap, \(CanvasAccessibility.claudeTerm), "
                       + "\(CanvasAccessibility.promotedTerm), 1 line: because")
    }

    /// The control for the test above: without an author the label says nothing
    /// extra, so "from Claude" is the author being read and not a word every card
    /// carries.
    func test_aScrapTheWriterMadeSaysNothingAboutClaude() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80))
        let card = try XCTUnwrap(CanvasAccessibility.elements(scene: s, scraps: [:]).first)
        XCTAssertEqual(card.label, "Scrap")
    }

    /// **This is what carries a Claude line's provenance if the cooler hairline
    /// turns out too quiet to see**, which is why it is not optional politeness:
    /// a line is an element nowhere, so its ends are the only place anything can
    /// be said about it at all.
    ///
    /// Both ends, because a relationship is legible at its ends and a user who
    /// walks to only one of the two cards must still hear it.
    func test_aLineFromClaudeIsNamedAsSuchAtBothItsEnds() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: CanvasNodeID("b"), kind: .scrap,
                            origin: CGPoint(x: 0, y: 400), width: 240, cachedHeight: 80))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b"), label: "because", author: .claude))
        let elements = CanvasAccessibility.elements(scene: s, scraps: [:])
        XCTAssertEqual(elements.count, 2, "both ends must be in the tree to be read")
        for id in [CanvasNodeID("a"), CanvasNodeID("b")] {
            let card = try XCTUnwrap(elements.first { $0.id == .node(id) },
                                     "\(id.raw) is not in the tree")
            XCTAssertEqual(card.label,
                           "Scrap, 1 line \(CanvasAccessibility.claudeTerm): because",
                           "the end \(id.raw) does not say who drew the line touching it")
        }
    }

    /// A writer's line and Claude's on the same card. The count is the whole set
    /// and the provenance is a share of it, so "3 lines" never becomes a number
    /// that excludes half of them — and the two phrasings differ on purpose: all
    /// of them reads "2 lines from Claude", some of them reads "3 lines, 2 from
    /// Claude", and "3 lines, 3 from Claude" would be the clumsy way to say the
    /// first.
    func test_aCardWithBothKindsOfLineSaysHowManyAreClaudes() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80))
        for (index, author) in [nil, AnnotationAuthor.SourceKind.claude, .claude].enumerated() {
            s.insert(CanvasNode(id: CanvasNodeID("e\(index)"), kind: .scrap,
                                origin: CGPoint(x: 400, y: 400 + 200 * Double(index)),
                                width: 240, cachedHeight: 80))
            s.insertLine(CanvasLine(id: CanvasLineID("l\(index)"), from: CanvasNodeID("a"),
                                    to: CanvasNodeID("e\(index)"), author: author))
        }
        let card = try XCTUnwrap(CanvasAccessibility.elements(scene: s, scraps: [:])
            .first { $0.id == .node(CanvasNodeID("a")) })
        XCTAssertEqual(card.label, "Scrap, 3 lines, 2 \(CanvasAccessibility.claudeTerm)")
    }

    /// A card the writer drew every line on says nothing about Claude, so the
    /// clause above is the authors being read rather than a phrase every
    /// connected card carries.
    func test_aCardWhoseLinesAreAllTheWritersSaysNothingAboutClaude() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: CanvasNodeID("b"), kind: .scrap,
                            origin: CGPoint(x: 0, y: 400), width: 240, cachedHeight: 80))
        s.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                to: CanvasNodeID("b"), label: "because"))
        let card = try XCTUnwrap(CanvasAccessibility.elements(scene: s, scraps: [:])
            .first { $0.id == .node(CanvasNodeID("a")) })
        XCTAssertEqual(card.label, "Scrap, 1 line: because")
    }

    /// **The spoken label deliberately does NOT mirror
    /// `CanvasRenderer.paper(for:)`, which refuses to tint an item node whatever
    /// its author says** (`CanvasAuthorRenderTests.test_anItemNodeIsNeverTinted`).
    /// The two answer different questions. The tint's is *whose words are these*,
    /// and a source page's words are the writer's own photograph — so refusing it
    /// is right. The tilt's is *who placed this here*, and since 2026-07-30
    /// `CanvasClaudePlacement` writes `author: .claude` on every source page it
    /// creates, so `seededRotation(for:)` draws it perfectly straight. A lean is
    /// inaudible: staying silent here left the page marked on screen and silent
    /// to VoiceOver, which is the §7A.6 failure this layer exists to prevent.
    /// Denver ruled on 2026-07-30 that it is spoken, with one phrase rather than
    /// a second wording for the placement-versus-authorship distinction.
    ///
    /// **The control is the writer's own reference**: an item node with no author
    /// says nothing, so the term is the author being read rather than a word
    /// every reference carries.
    func test_anItemNodePlacedByClaudeSaysSoEvenThoughItsWordsAreTheWritersOwn() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: .item("r-9"), kind: .item(.project(id: "r-9")),
                            origin: .zero, width: 180, cachedHeight: 120, author: .claude))
        s.insert(CanvasNode(id: .item("r-4"), kind: .item(.project(id: "r-4")),
                            origin: CGPoint(x: 0, y: 400), width: 180, cachedHeight: 120))
        let elements = CanvasAccessibility.elements(scene: s, scraps: [:])
        let claudes = try XCTUnwrap(elements.first { $0.id == .node(.item("r-9")) },
                                    "Claude's reference is not in the tree at all")
        let writers = try XCTUnwrap(elements.first { $0.id == .node(.item("r-4")) },
                                    "the writer's reference is not in the tree at all")
        XCTAssertEqual(claudes.label, "Reference, \(CanvasAccessibility.claudeTerm)",
                       "a page Claude placed is drawn perfectly straight and a lean "
                       + "is inaudible, so this label is the only thing that can say it")
        XCTAssertEqual(writers.label, "Reference",
                       "the control: a reference the writer dropped in says nothing")
    }

    /// **A region has no tint at all**, so the 1° lean is the whole of its drawn
    /// provenance and a lean is inaudible — the strongest case on the surface for
    /// saying it. The term sits after the region's NAME (kind-plus-name is how a
    /// primitive identifies itself) and before the durable facts, which is
    /// `CanvasAccessibility.label`'s one ordering rule.
    ///
    /// **The control is the writer's own region**, swept by hand, which says
    /// nothing.
    func test_aClaudeRegionSaysSoBecauseItsOnlyOtherMarkIsAnInaudibleLean() throws {
        func label(author: AnnotationAuthor.SourceKind?) throws -> String {
            var s = CanvasScene()
            s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                        author: author))
            let region = try XCTUnwrap(CanvasAccessibility.elements(scene: s, scraps: [:])
                .first { $0.id == .region(CanvasRegionID("r1")) },
                                       "the region is not in the tree at all")
            return region.label
        }
        XCTAssertEqual(try label(author: .claude),
                       "\(CanvasAccessibility.regionKind), Act II fog, "
                       + "\(CanvasAccessibility.claudeTerm)",
                       "a region Claude swept carries no colour and leans 1° — nothing "
                       + "else can say whose it is")
        XCTAssertEqual(try label(author: nil),
                       "\(CanvasAccessibility.regionKind), Act II fog",
                       "the control: a region the writer swept says nothing")
    }

    /// The whole label of a Claude region that has also been promoted and
    /// collapsed, against the scrap's, so the ordering rule is asserted as ONE
    /// rule rather than twice: kind, name, provenance, then the durable facts in
    /// the order they were added.
    func test_provenanceSitsInTheSamePlaceOnARegionAsOnAScrap() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80, promotedItemID: "res-a",
                            author: .claude))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: -20, y: -20, width: 600, height: 400),
                                    isCollapsed: true, promotedItemID: "res-fog",
                                    author: .claude))
        let elements = CanvasAccessibility.elements(scene: s, scraps: [:])
        let region = try XCTUnwrap(elements.first { $0.role == .region },
                                   "the region is not in the tree at all")
        XCTAssertEqual(region.label,
                       "\(CanvasAccessibility.regionKind), Act II fog, "
                       + "\(CanvasAccessibility.claudeTerm), "
                       + "\(CanvasAccessibility.promotedTerm), "
                       + "\(CanvasAccessibility.collapsedTerm)")
        // The card is a resident of a collapsed region, so it has left the tree —
        // which is why its label is asserted from a second scene rather than
        // this one.
        var flat = CanvasScene()
        flat.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                               width: 240, cachedHeight: 80, promotedItemID: "res-a",
                               author: .claude))
        let card = try XCTUnwrap(CanvasAccessibility.elements(scene: flat, scraps: [:]).first,
                                 "the card is not in the tree at all")
        XCTAssertEqual(card.label,
                       "Scrap, \(CanvasAccessibility.claudeTerm), "
                       + "\(CanvasAccessibility.promotedTerm)",
                       "provenance must sit between the kind and the durable facts on "
                       + "both, or there are two ordering rules on one surface")
    }

    /// **The repetition is accepted, not overlooked** (Denver, 2026-07-30), and
    /// this test is what stops a future reader "fixing" it. A Claude region and
    /// each of its Claude cards say the phrase separately, and a region left on
    /// `defaultRegionLabel` says it twice running.
    ///
    /// The alternative was saying it once, on the region. **This tree is FLAT** —
    /// `rowOrdered` interleaves regions and cards by position and a card is not a
    /// child of its region — so a user walking card to card can reach a Claude
    /// card without ever passing the region that would have said it. Silence in
    /// that case is the failure the term exists to prevent, so repetitive and
    /// never wrong beats quiet and sometimes wrong.
    ///
    /// The `contains` loop discriminates despite the default label, because
    /// `claudeTerm` is lower-case and `defaultRegionLabel` is "**F**rom Claude" —
    /// and the last assertion pins the whole string anyway.
    func test_aClaudeRegionAndItsCardsEachSayItBecauseTheTreeIsFlat() throws {
        var s = CanvasScene()
        let residents = [CanvasNodeID("a"), CanvasNodeID("b")]
        for (index, id) in residents.enumerated() {
            s.insert(CanvasNode(id: id, kind: .scrap,
                                origin: CGPoint(x: 40 + 300 * Double(index), y: 40),
                                width: 240, cachedHeight: 80, author: .claude))
        }
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"),
                                    label: CanvasClaudePlacement.defaultRegionLabel,
                                    frame: CGRect(x: 0, y: 0, width: 900, height: 400),
                                    homeMembers: Set(residents), author: .claude))
        let elements = CanvasAccessibility.elements(scene: s, scraps: [:])
        XCTAssertEqual(elements.count, 3,
                       "the region and both cards must all be in the tree, or this "
                       + "measures the wrong thing")
        for element in elements {
            XCTAssertTrue(element.label.contains(CanvasAccessibility.claudeTerm),
                          "\(element.id.raw) says nothing about Claude, and a user "
                          + "walking a flat tree can reach it without passing "
                          + "anything that does: \(element.label)")
        }
        let region = try XCTUnwrap(elements.first { $0.role == .region },
                                   "the region is not in the tree at all")
        XCTAssertEqual(region.label,
                       "\(CanvasAccessibility.regionKind), "
                       + "\(CanvasClaudePlacement.defaultRegionLabel), "
                       + "\(CanvasAccessibility.claudeTerm)",
                       "the accepted stutter: the default label already contains the "
                       + "phrase and the term is still said, because a term whose "
                       + "presence depends on the region's name is one no listener "
                       + "can rely on")
    }

    /// One wording for one fact. The term an assistive client hears must be the
    /// term the rest of the surface uses, and these three are the whole set: a
    /// third phrasing is how "Claude's" becomes three things to learn.
    func test_theSpokenTermAgreesWithTheRegionLabelAndTheUndoStep() {
        XCTAssertEqual(CanvasClaudePlacement.defaultRegionLabel, "From Claude")
        XCTAssertEqual(CanvasClaudeWrite.undoStepName, "Add Scraps from Claude")
        XCTAssertEqual(CanvasAccessibility.claudeTerm, "from Claude")
    }

    // MARK: - The dim is audible (§4, slice 3 task 7)

    /// A scene where `ch1` owns `r1` and the card in it, and `loose` sits on
    /// bare canvas outside every region. Under `.piece("ch1")` the region and
    /// `home` are lit; `loose` and `r2` are dimmed.
    private func boundScene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("home"), kind: .scrap,
                            origin: CGPoint(x: 40, y: 40), width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: CanvasNodeID("loose"), kind: .scrap,
                            origin: CGPoint(x: 40, y: 400), width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 200)))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r2"), label: "Elsewhere",
                                    frame: CGRect(x: 0, y: 360, width: 600, height: 200)))
        CanvasMembership.join(CanvasNodeID("home"), home: CanvasRegionID("r1"), in: &s)
        RegionBinding.bind(CanvasRegionID("r1"), toPiece: "ch1", in: &s)
        return s
    }

    private func filtered() -> CanvasHighlight {
        CanvasHighlight.resolve(subject: .piece("ch1"), in: boundScene())
    }

    private func label(of id: String, under highlight: CanvasHighlight) throws -> String {
        let elements = CanvasAccessibility.elements(scene: boundScene(), scraps: [:],
                                                    highlight: highlight)
        return try XCTUnwrap(elements.first { $0.id.raw == id },
                             "\(id) is not in the tree at all, so there is no label to "
                             + "read — see the removal test below")
            .label
    }

    /// **The deliverable, and ADR 0026 §10 is the precedent exactly.** Claude's
    /// cards got a spoken term because a lean is inaudible; a dim is inaudible by
    /// the same argument, and until this test the whole of §4 reached a VoiceOver
    /// user as nothing at all.
    ///
    /// Both halves, because either alone is satisfied by an implementation that
    /// says the term everywhere or nowhere.
    func test_aDimmedCardSaysSoAndALitOneDoesNot() throws {
        let highlight = filtered()
        XCTAssertTrue(try label(of: "loose", under: highlight)
                        .contains(CanvasAccessibility.dimmedTerm),
                      "the whole of §4 is inaudible: a card the tree's selection "
                      + "does not name is drawn at \(CanvasMaterial.dimmedOpacity) "
                      + "alpha and announced identically to one it does")
        XCTAssertFalse(try label(of: "home", under: highlight)
                        .contains(CanvasAccessibility.dimmedTerm),
                      "a LIT card says it is dimmed — the term is being said "
                      + "unconditionally, which tells a listener nothing")
    }

    /// The control that decides the POLARITY, and it is the reason the term marks
    /// the dimmed rather than the lit.
    ///
    /// On an undimmed board every element is silent about the dim, exactly as
    /// every element is drawn at full strength. Marking the LIT ones instead
    /// would leave a dimmed card and a card on an unfiltered board sounding
    /// identical — an ambiguity the sighted channel does not have, since a dimmed
    /// card plainly *looks* different from an undimmed one. Marked this way round
    /// the only pair that collides is lit-vs-undimmed, which is the pair that
    /// collides on screen too.
    func test_anUndimmedBoardSaysNothingAboutTheDimAtAll() throws {
        for id in ["home", "loose", "region:r1", "region:r2"] {
            XCTAssertFalse(try label(of: id, under: .undimmed)
                            .contains(CanvasAccessibility.dimmedTerm),
                           "\(id) announces a dim on a board where nothing is dimmed")
        }
    }

    /// **Every primitive says it for itself, because the tree is FLAT** — the
    /// ruling `claudeTerm` already carries (Denver, 2026-07-30). `rowOrdered`
    /// interleaves regions and cards by position and a card is not a child of its
    /// region, so a term spoken only on the region leaves cards reachable in
    /// silence.
    ///
    /// The members are named rather than counted: a card, an item node and a
    /// region, all dimmed, all in one scene.
    func test_aDimmedCardAnItemNodeAndARegionEachSayItForThemselves() throws {
        var s = boundScene()
        s.insert(CanvasNode(id: .item("r-9"), kind: .item(.project(id: "r-9")),
                            origin: CGPoint(x: 40, y: 420), width: 180, cachedHeight: 120))
        let highlight = CanvasHighlight.resolve(subject: .piece("ch1"), in: s)
        let elements = CanvasAccessibility.elements(scene: s, scraps: [:], highlight: highlight)

        for id in ["loose", "item:r-9", "region:r2"] {
            let element = try XCTUnwrap(elements.first { $0.id.raw == id },
                                        "\(id) is not in the tree at all")
            XCTAssertTrue(element.label.contains(CanvasAccessibility.dimmedTerm),
                          "\(id) is drawn dim and says nothing about it: \(element.label)")
        }
        let lit = try XCTUnwrap(elements.first { $0.id.raw == "region:r1" })
        XCTAssertFalse(lit.label.contains(CanvasAccessibility.dimmedTerm),
                       "the control: the bound region is lit and must stay silent")
    }

    /// **The term comes FIRST, ahead of the kind, and it is the one thing in this
    /// label that is not a fact about the object.**
    ///
    /// Two reasons, and the second is the one that cannot be argued round. A
    /// listener skimming a filtered board is listening for the cards that do
    /// *not* carry the term — so the discriminating word has to arrive before the
    /// variable-length material (a name, a provenance, a mark, a list of line
    /// labels, and then the writer's whole sentence in the value), or every card
    /// has to be heard to the end before it can be skipped. And appended, it
    /// lands immediately after `connectionPhrase`'s comma-joined list of line
    /// names, where it reads as one more line called "outside the binder's
    /// selection".
    ///
    /// The whole string is asserted rather than the prefix alone, so this is one
    /// ordering rule with a new head rather than a second rule.
    func test_theDimmedTermIsSpokenAheadOfTheKindAndTheRestIsUnchanged() throws {
        var s = CanvasScene()
        s.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80, promotedItemID: "res-a",
                            author: .claude))
        s.insertRegion(CanvasRegion(id: CanvasRegionID("r1"), label: "Act II fog",
                                    frame: CGRect(x: -20, y: -20, width: 600, height: 400),
                                    isCollapsed: true, promotedItemID: "res-fog",
                                    author: .claude))
        // Nothing is bound, so a subject that names anything dims all of it.
        let highlight = CanvasHighlight.resolve(subject: .piece("ch1"), in: s)
        let elements = CanvasAccessibility.elements(scene: s, scraps: [:], highlight: highlight)

        let region = try XCTUnwrap(elements.first { $0.role == .region },
                                   "the region is not in the tree at all")
        XCTAssertEqual(region.label,
                       "\(CanvasAccessibility.dimmedTerm), "
                       + "\(CanvasAccessibility.regionKind), Act II fog, "
                       + "\(CanvasAccessibility.claudeTerm), "
                       + "\(CanvasAccessibility.promotedTerm), "
                       + "\(CanvasAccessibility.collapsedTerm)")

        var flat = CanvasScene()
        flat.insert(CanvasNode(id: CanvasNodeID("a"), kind: .scrap, origin: .zero,
                               width: 240, cachedHeight: 80, promotedItemID: "res-a",
                               author: .claude))
        let card = try XCTUnwrap(
            CanvasAccessibility.elements(
                scene: flat, scraps: [:],
                highlight: CanvasHighlight.resolve(subject: .piece("ch1"), in: flat)).first,
            "the card is not in the tree at all")
        XCTAssertEqual(card.label,
                       "\(CanvasAccessibility.dimmedTerm), Scrap, "
                       + "\(CanvasAccessibility.claudeTerm), "
                       + "\(CanvasAccessibility.promotedTerm)",
                       "the head of the label must be the same head on both, or "
                       + "there are two ordering rules on one surface")
    }

    /// **The word may not be the system's word for UNAVAILABLE**, and "dimmed" is
    /// exactly that word: macOS speaks it for a control whose `AXEnabled` is
    /// false — a greyed-out menu item, a disabled button — so a card announced as
    /// "dimmed" is a card a VoiceOver user is told they cannot use.
    ///
    /// This surface's contract is the opposite and is stated in three places
    /// (§4's plan, `CanvasRenderer.draw`'s doc comment, AREA.md): **the dim is
    /// de-emphasis and never disabling** — a dimmed card is still hit-tested,
    /// still selectable, still editable, and its selection ring is drawn at full
    /// strength. So the term names what the dim MEANS rather than what it looks
    /// like, which is `claudeTerm`'s own precedent one primitive over: the drawn
    /// signal there is a 1° lean and the spoken term is "from Claude", not
    /// "leaning".
    func test_theSpokenTermIsNotTheSystemsWordForUnavailable() {
        XCTAssertFalse(CanvasAccessibility.dimmedTerm.isEmpty,
                       "an empty term is a silent dim wearing a constant")
        for word in ["dimmed", "disabled", "unavailable", "greyed", "grayed"] {
            XCTAssertFalse(CanvasAccessibility.dimmedTerm.lowercased().contains(word),
                           "\"\(word)\" is how an assistive client says a control "
                           + "cannot be used, and a dimmed card can be clicked, "
                           + "selected, dragged and typed into")
        }
    }

    /// **The counterfactual, planted: the dim as a REMOVAL.**
    ///
    /// Dropping dimmed nodes from `elements` is available, is cheaper, and would
    /// pass every "a lit card and a dimmed card sound different" assertion above
    /// — they would sound different because one of them would not exist. It is
    /// the wrong answer: the dim is de-emphasis for a sighted writer and a
    /// removal would make it a disappearance for a listener, on a card that is
    /// still clickable, still selectable and still holding the writer's words.
    ///
    /// The value is asserted beside the count because a half-hearted version of
    /// the same mistake keeps the element and blanks it, which reaches a listener
    /// as the same loss.
    func test_aDimmedCardIsStillReachableAndStillReadsOutItsWords() throws {
        let words = "The falls at night."
        let elements = CanvasAccessibility.elements(
            scene: boundScene(), scraps: [CanvasNodeID("loose"): words],
            highlight: filtered())
        XCTAssertEqual(elements.count, 4,
                       "both cards and both regions must be in the tree — a dim that "
                       + "removes elements is a disappearance for a listener where it "
                       + "is a de-emphasis for everyone else")
        let loose = try XCTUnwrap(elements.first { $0.id.raw == "loose" })
        XCTAssertEqual(loose.value, words,
                       "a dimmed card kept its element and lost its words, which "
                       + "reaches a listener as the same removal")
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
