import XCTest
@testable import MaughamCore

/// **`Posture` — every verb, under every permit a Mac can hold** (P3c Task 1).
///
/// One table, every cell asserted: a row is a posture, and the row names the
/// verbs it OFFERS; every verb not named is asserted refused. That is what
/// makes both directions one test — a verb wrongly offered and a verb wrongly
/// hidden fail the same cell.
final class PostureTests: XCTestCase {

    private typealias V = Posture.Verb

    private static func permit(
        _ permit: Permit, _ cls: DocumentClass?, actor: DeviceActor = .author
    ) -> LocalWritePermit {
        LocalWritePermit(permit: permit, actor: actor, documentClass: cls)
    }

    private struct Row {
        let name: String
        let posture: Posture
        let offers: Set<V>
        let reason: Posture.Reason?
    }

    private static let everything = Set(V.allCases)
    /// Option A (P3c plan 2): what an author of some pieces is offered in a
    /// piece she started that nobody has claimed — her words, and what is
    /// probed as her words; never a disposition, a checkpoint, a task or a
    /// translation, which the read side would set aside.
    private static let writingHerStartedPiece: Set<V> = [
        .writeText, .acceptOrReject, .setPassState, .restructure, .runRound,
        .editStatement, .startAPiece, .annotate,
    ]

    private static let rows: [Row] = [
        Row(name: "unrestricted",
            posture: Posture(.unrestricted),
            offers: everything, reason: nil),
        Row(name: "book author, class resolved",
            posture: Posture(permit(.bookAuthor, .piece("x"))),
            offers: everything, reason: nil),
        Row(name: "reviewer in a piece",
            posture: Posture(permit(.reviewer, .piece("x"))),
            offers: [.annotate], reason: .reviewer),
        Row(name: "pieces author inside her piece",
            posture: Posture(permit(.author(.pieces(["a"])), .piece("a"))),
            offers: everything, reason: nil),
        Row(name: "pieces author inside her piece's statement",
            posture: Posture(permit(.author(.pieces(["a"])), .pieceStatement(piece: "a"))),
            offers: everything, reason: nil),
        Row(name: "pieces author outside her pieces",
            posture: Posture(permit(.author(.pieces(["a"])), .piece("b"))),
            offers: [.annotate, .startAPiece], reason: .notYourPiece),
        // Option A: the same piece, one of her own devices started it and no
        // book author has written a word of it.
        Row(name: "pieces author in a piece she started, unclaimed",
            posture: Posture(LocalWritePermit(
                permit: .author(.pieces(["a"])), actor: .author,
                documentClass: .piece("b"), startedHere: true,
                writesAsItsStarter: true)),
            offers: writingHerStartedPiece, reason: .waitingToBeClaimed),
        // …on her OTHER Mac: it may not mint the opening, and writes the same.
        Row(name: "pieces author in a piece her other Mac started, unclaimed",
            posture: Posture(LocalWritePermit(
                permit: .author(.pieces(["a"])), actor: .author,
                documentClass: .piece("b"), startedHere: false,
                writesAsItsStarter: true)),
            offers: writingHerStartedPiece, reason: .waitingToBeClaimed),
        // …and once a book author has written its text, it is theirs.
        Row(name: "pieces author in a piece she started, now claimed",
            posture: Posture(LocalWritePermit(
                permit: .author(.pieces(["a"])), actor: .author,
                documentClass: .piece("b"), startedHere: true,
                writesAsItsStarter: false)),
            offers: [.annotate, .startAPiece], reason: .notYourPiece),
        // The actor narrows Option A exactly as it narrows her scope.
        Row(name: "the assistant under a pieces author, in a piece she started",
            posture: Posture(LocalWritePermit(
                permit: .author(.pieces(["a"])), actor: .assistant,
                documentClass: .piece("b"), startedHere: true,
                writesAsItsStarter: true)),
            offers: [.annotate], reason: .reviewer),
        Row(name: "pieces author on the project stream",
            posture: Posture(permit(.author(.pieces(["a"])), .projectStream)),
            offers: [.task, .annotate, .startAPiece], reason: .notYourPiece),
        Row(name: "pieces author on a project statement",
            posture: Posture(permit(.author(.pieces(["a"])), .projectStatement)),
            offers: [.annotate, .startAPiece], reason: .notYourPiece),
        Row(name: "pieces author on a statement this build cannot place",
            posture: Posture(permit(.author(.pieces(["a"])), .unplaceable("s"))),
            offers: [.annotate, .startAPiece], reason: .cannotJudge),
        Row(name: "unjudgeable permit",
            posture: Posture(permit(.unjudgeable(raw: "editor"), .piece("x"))),
            offers: [.annotate], reason: .cannotJudge),
        Row(name: "root yielding to Sam",
            posture: Posture(.unrestricted, yieldingTo: "Sam"),
            offers: [.annotate], reason: .yielding(to: "Sam")),
        Row(name: "the assistant under the book author",
            posture: Posture(permit(.bookAuthor, .piece("x"), actor: .assistant)),
            offers: [.annotate], reason: .reviewer),
        // The ACTOR narrows, not the rung: the words are hers, the key is not.
        Row(name: "the assistant under a pieces author, inside her piece",
            posture: Posture(permit(.author(.pieces(["a"])), .piece("a"), actor: .assistant)),
            offers: [.annotate], reason: .reviewer),
        Row(name: "the translator in a translation",
            posture: Posture(permit(.bookAuthor, .translation(piece: "x"), actor: .translator)),
            offers: [.translate], reason: .reviewer),
        // P3c Task 8: the translator under an author of some pieces — the
        // TRANSLATOR's key narrows to translation records, and the person's
        // scope decides which piece's. Both the class the reader constructs
        // (`.translation(piece:)`) and the class the Mac's door resolves for
        // the same id (`.piece`, since a translation stream's id IS its
        // piece's) — they must answer alike.
        Row(name: "the translator under a pieces author, in her piece's translation",
            posture: Posture(permit(.author(.pieces(["a"])), .translation(piece: "a"),
                                    actor: .translator)),
            offers: [.translate], reason: .reviewer),
        Row(name: "the translator under a pieces author, in her piece",
            posture: Posture(permit(.author(.pieces(["a"])), .piece("a"), actor: .translator)),
            offers: [.translate], reason: .reviewer),
        Row(name: "the translator under a pieces author, outside her pieces (translation)",
            posture: Posture(permit(.author(.pieces(["a"])), .translation(piece: "b"),
                                    actor: .translator)),
            offers: [], reason: .notYourPiece),
        Row(name: "the translator under a pieces author, outside her pieces (piece)",
            posture: Posture(permit(.author(.pieces(["a"])), .piece("b"), actor: .translator)),
            offers: [], reason: .notYourPiece),
        Row(name: "the translator under a reviewer",
            posture: Posture(permit(.reviewer, .translation(piece: "a"), actor: .translator)),
            offers: [], reason: .reviewer),
    ]

    /// Every verb × every posture, and the reason beside it.
    func test_everyVerbUnderEveryPosture() {
        for row in Self.rows {
            for verb in V.allCases {
                XCTAssertEqual(row.posture.allows(verb), row.offers.contains(verb),
                    "\(row.name): \(verb) should be "
                    + (row.offers.contains(verb) ? "offered" : "refused"))
            }
            XCTAssertEqual(row.posture.reason, row.reason, "\(row.name): reason")
            XCTAssertEqual(row.posture.isRestricted, row.offers != Self.everything,
                "\(row.name): isRestricted")
        }
    }

    /// **Starting a piece is the book author's AND an author of some pieces'**
    /// (P3c plan 2, Option A widens ruling R3) — whatever class the posture
    /// was built for. A reviewer, a permit this build cannot read, and every
    /// narrowed key start nothing.
    func test_startingAPieceIsTheBookAuthorsAndAnAuthorOfSomePiecesToo() {
        let classes: [DocumentClass] = [
            .piece("a"), .pieceStatement(piece: "a"), .projectStatement,
            .projectStream, .translation(piece: "a"),
        ]
        for cls in classes {
            XCTAssertTrue(Posture(Self.permit(.bookAuthor, cls)).allows(.startAPiece), "\(cls)")
            XCTAssertTrue(Posture(Self.permit(.author(.pieces(["a"])), cls)).allows(.startAPiece), "\(cls)")
            XCTAssertTrue(Posture(Self.permit(.author(.pieces([])), cls)).allows(.startAPiece), "\(cls)")
            XCTAssertFalse(Posture(Self.permit(.reviewer, cls)).allows(.startAPiece), "\(cls)")
            XCTAssertFalse(Posture(Self.permit(.unjudgeable(raw: "editor"), cls))
                .allows(.startAPiece), "\(cls)")
            for actor in [DeviceActor.assistant, .translator, .maugham] {
                XCTAssertFalse(
                    Posture(Self.permit(.author(.pieces(["a"])), cls, actor: actor))
                        .allows(.startAPiece), "\(cls)/\(actor)")
            }
        }
    }

    /// **Settling offers the reviewer row and nothing else, and names no
    /// reason** — the door's answer before it can ask (P3c Task 2, fix round 1).
    func test_settlingOffersOnlyTheReviewerRowAndNamesNoReason() {
        let settling = Posture.settling
        for verb in V.allCases {
            XCTAssertEqual(settling.allows(verb), verb == .annotate, "\(verb)")
        }
        XCTAssertNil(settling.reason)
        XCTAssertNil(settling.yieldingTo)
        XCTAssertTrue(settling.isSettling)
        XCTAssertFalse(Posture.author.isSettling)
        XCTAssertNotEqual(settling, Posture.author,
                          "the same permit underneath, not the same answer")
    }

    func test_theAuthorPostureIsTheUnrestrictedOne() {
        XCTAssertEqual(Posture.author, Posture(.unrestricted))
        XCTAssertNil(Posture.author.yieldingTo)
        XCTAssertFalse(Posture.author.isRestricted)
        XCTAssertNotEqual(Posture.author, Posture(.unrestricted, yieldingTo: "Sam"))
        XCTAssertEqual(Posture(.unrestricted, yieldingTo: "Sam").yieldingTo, "Sam")
    }

    /// Both directions of one change: a demotion locks exactly what the
    /// promotion unlocks, in the same document.
    func test_aDemotionLocksWhatAPromotionUnlocks() {
        let promoted = Posture(Self.permit(.author(.pieces(["a"])), .piece("a")))
        let demoted = Posture(Self.permit(.reviewer, .piece("a")))
        let unlocked = Set(V.allCases.filter { promoted.allows($0) && !demoted.allows($0) })
        XCTAssertEqual(unlocked, Self.everything.subtracting([.annotate]))
    }
}
