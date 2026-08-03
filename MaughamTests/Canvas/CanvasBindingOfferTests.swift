import XCTest
@testable import Maugham

/// §4's third row and §4.1's ruling on it: **a document with nothing bound**
/// dims the board and the canvas says what to do next — and a group never does,
/// however empty it is.
final class CanvasBindingOfferTests: XCTestCase {

    private let r1 = CanvasRegionID("r1")
    private let a = CanvasNodeID("a")

    /// One card, one region, and whatever binding the caller wants on it.
    private func scene(boundTo piece: String? = nil,
                       resident: Bool = true) -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                                    homeMembers: resident ? [a] : [],
                                    boundPieceID: piece))
        return s
    }

    private func offer(_ subject: CanvasSubject, _ scene: CanvasScene) -> Bool {
        CanvasBindingOffer.isOffered(
            subject: subject,
            highlight: CanvasHighlight.resolve(subject: subject, in: scene))
    }

    func test_theOfferAppearsForADocumentWithNothingBound() {
        XCTAssertTrue(offer(.piece("ch1"), scene()),
                      "a chapter with nothing bound dims the whole board and says "
                      + "nothing about why — which is the one state where a dim "
                      + "reads as a dead end (§4)")
    }

    func test_theOfferGoesAwayOnceSomethingIsBound() {
        XCTAssertFalse(offer(.piece("ch1"), scene(boundTo: "ch1")),
                       "the canvas offers to bind a region while one is already "
                       + "bound and lit — the offer contradicting the board")
    }

    /// A region bound to some OTHER chapter is not this one's context, so the
    /// offer stands.
    func test_aRegionBoundToAnotherChapterDoesNotAnswerForThisOne() {
        XCTAssertTrue(offer(.piece("ch1"), scene(boundTo: "ch2")))
    }

    /// **The two signals, and the test that one is not enough** (§4.1: the
    /// standing text never appears for a group). `litNothing` is asserted true in
    /// the same breath, so a failure here says exactly which signal was dropped.
    func test_theOfferNeverAppearsForAGroupHoweverEmpty() {
        let subject = CanvasSubject.group(["ch1", "ch2"])
        let highlight = CanvasHighlight.resolve(subject: subject, in: scene())
        XCTAssertTrue(highlight.litNothing,
                      "precondition: nothing under this group is bound, so the "
                      + "lit-set signal ALONE would show the offer")
        XCTAssertFalse(CanvasBindingOffer.isOffered(subject: subject, highlight: highlight),
                       "the offer appeared under a group: a dimmed board with Part "
                       + "One selected says \"here is everything under Part One\", "
                       + "and a sweep there makes a PLAIN region — so the offer "
                       + "would promise something the gesture does not do")
    }

    /// A group of no documents at all — an id the tree cannot find. Same ruling,
    /// and it is the shape most likely to slip through a `pieces.isEmpty` test.
    func test_theOfferNeverAppearsForAGroupOfNoDocuments() {
        XCTAssertFalse(offer(.group([]), scene()))
    }

    func test_theOfferNeverAppearsOnTheProjectRow() {
        let highlight = CanvasHighlight.resolve(subject: .wholeProject, in: scene())
        XCTAssertFalse(highlight.litNothing,
                       "precondition: the project row does not filter, so it is not "
                       + "\"nothing answers to the subject\" — the two states have "
                       + "to stay distinguishable")
        XCTAssertFalse(CanvasBindingOffer.isOffered(subject: .wholeProject,
                                                    highlight: highlight))
    }

    /// **The bound-but-empty region, confirmed rather than inherited** (tasks
    /// 1–3 flagged it as task 6's call).
    ///
    /// `litNothing` counts regions as well as cards, so a chapter whose only
    /// bound region holds nothing gets **no** offer — and the offer's own
    /// sentence is what settles it. *"Nothing on this canvas is bound to this
    /// document yet"* would be false on that board: a region IS bound to it, lit,
    /// and named in the inspector. An offer whose first line contradicts what the
    /// writer is looking at is worse than no offer, and the empty region is a
    /// place to put cards rather than a state needing a second one.
    func test_aBoundButEmptyRegionIsNotTheOfferState() {
        XCTAssertFalse(offer(.piece("ch1"), scene(boundTo: "ch1", resident: false)),
                       "the canvas offered to bind a region to a chapter that "
                       + "already has one lit and empty on screen — the offer's "
                       + "own first line would be false")
    }

    /// The sentences are the offer, so they are pinned: an offer that names no
    /// gesture is a dead end with extra words.
    func test_theOfferNamesTheGestureThatAnswersIt() {
        XCTAssertTrue(CanvasBindingOffer.instruction.lowercased().contains("region"),
                      "the instruction does not name the region gesture: \""
                      + CanvasBindingOffer.instruction + "\"")
        XCTAssertTrue(CanvasBindingOffer.headline.hasSuffix("."),
                      "standing chrome is a sentence, not a label")
    }
}
