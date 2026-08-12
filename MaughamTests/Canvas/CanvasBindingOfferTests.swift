import XCTest
@testable import Maugham

/// §4's third row and §4.1's ruling on it: **a document with nothing bound**
/// dims the board and the canvas says what to do next — and a group never does,
/// however empty it is.
///
/// **Stage 3b adds the second sentence pair and keeps ONE decision function.** A
/// research subject whose card is not on this canvas is the same shape one
/// subject over — a board dimmed with nothing lit — and it is answered by the
/// same standing chrome saying a different thing. Two predicates would be two
/// answers to "is anything showing in the middle of the board", and the two can
/// disagree only by both being true.
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

    /// The whole decision, as the view asks it.
    private func message(_ subject: CanvasSubject,
                         _ scene: CanvasScene) -> CanvasBindingOffer.Message? {
        CanvasBindingOffer.message(
            subject: subject,
            highlight: CanvasHighlight.resolve(subject: subject, in: scene))
    }

    /// *Is there chrome at all* — which is what every case below §4's row three
    /// is about, and what `isOffered` used to answer on its own.
    private func offer(_ subject: CanvasSubject, _ scene: CanvasScene) -> Bool {
        message(subject, scene) != nil
    }

    /// A card for a research item, joined to it the way the canvas joins them:
    /// `CanvasNodeID.item(id)` is DERIVED, so a fixture that mints its own id
    /// would test a card the production lookup can never find.
    private func sceneWithTheCardFor(_ researchID: String) -> CanvasScene {
        var s = scene()
        s.insert(CanvasNode(id: .item(researchID), kind: .item(.project(id: researchID)),
                            origin: CGPoint(x: 800, y: 600), width: 200, cachedHeight: 140))
        return s
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
        XCTAssertNil(CanvasBindingOffer.message(subject: subject, highlight: highlight),
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
        XCTAssertNil(CanvasBindingOffer.message(subject: .wholeProject,
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
        XCTAssertTrue(CanvasBindingOffer.nothingBound.instruction.lowercased()
                        .contains("region"),
                      "the instruction does not name the region gesture: \""
                      + CanvasBindingOffer.nothingBound.instruction + "\"")
        XCTAssertTrue(CanvasBindingOffer.nothingBound.headline.hasSuffix("."),
                      "standing chrome is a sentence, not a label")
    }

    // MARK: - Stage 3b: the research item whose card is not here

    /// **The piece arm's message, pinned by identity rather than by presence.**
    /// Now that two messages exist, "some chrome appeared" no longer says the
    /// right one did — and a board dimmed to a chapter that reads *"drag its row
    /// from the tree"* names a gesture that binds nothing.
    func test_aDocumentWithNothingBoundIsStillToldToSweepARegion() {
        XCTAssertEqual(message(.piece("ch1"), scene()), CanvasBindingOffer.nothingBound)
    }

    /// §4's *"its card highlighted on the board"* with no card to highlight. It
    /// DIMS (Task 1's ruling) — so without chrome the writer's click is a board
    /// gone dark with nothing lit and nothing said.
    func test_aResearchItemWithNoCardOnTheBoardIsToldHowToPlaceIt() {
        let subject = CanvasSubject.research("r-1")
        let highlight = CanvasHighlight.resolve(subject: subject, in: scene())
        XCTAssertTrue(highlight.litNothing, "precondition: the board holds no card "
                      + "for this item, which is the signal this chrome hangs off")
        XCTAssertEqual(CanvasBindingOffer.message(subject: subject, highlight: highlight),
                       CanvasBindingOffer.cardNotHere)
    }

    /// The card is here, lit, in front of the writer — chrome saying it is not
    /// would be the offer contradicting the board, which is
    /// `test_theOfferGoesAwayOnceSomethingIsBound`'s rule arriving on the second
    /// subject.
    func test_aResearchItemWhoseCardIsOnTheBoardGetsNoChromeAtAll() {
        XCTAssertNil(message(.research("r-1"), sceneWithTheCardFor("r-1")))
    }

    /// The join is DERIVED, so a card for some *other* research item answers for
    /// nothing — the same shape as a region bound to another chapter.
    func test_someoneElsesCardDoesNotAnswerForThisItem() {
        XCTAssertEqual(message(.research("r-1"), sceneWithTheCardFor("r-2")),
                       CanvasBindingOffer.cardNotHere)
    }

    /// The two pairs are distinct sentences and each names its own gesture: the
    /// research one names the TREE, because a sweep does not place a card and a
    /// writer told to drag out a region here would get a plain rectangle.
    func test_theSecondMessageNamesTheGestureThatPlacesACard() {
        XCTAssertNotEqual(CanvasBindingOffer.cardNotHere, CanvasBindingOffer.nothingBound)
        XCTAssertTrue(CanvasBindingOffer.cardNotHere.instruction.lowercased()
                        .contains("drag"),
                      "the instruction does not name the drag that places the card: \""
                      + CanvasBindingOffer.cardNotHere.instruction + "\"")
        XCTAssertTrue(CanvasBindingOffer.cardNotHere.instruction.lowercased()
                        .contains("tree"),
                      "the instruction does not say WHERE to drag from — the row is "
                      + "in the tree and the writer is looking at the board: \""
                      + CanvasBindingOffer.cardNotHere.instruction + "\"")
        XCTAssertFalse(CanvasBindingOffer.cardNotHere.instruction.lowercased()
                        .contains("region"),
                      "a research subject's sweep draws a PLAIN region and binds "
                      + "nothing (§4.1's group precedent) — naming it here promises "
                      + "something the gesture does not do")
        XCTAssertTrue(CanvasBindingOffer.cardNotHere.headline.hasSuffix("."),
                      "standing chrome is a sentence, not a label")
    }
}
