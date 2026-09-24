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
    private static let everythingButStarting = everything.subtracting([.startAPiece])

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
            offers: everythingButStarting, reason: nil),
        Row(name: "pieces author inside her piece's statement",
            posture: Posture(permit(.author(.pieces(["a"])), .pieceStatement(piece: "a"))),
            offers: everythingButStarting, reason: nil),
        Row(name: "pieces author outside her pieces",
            posture: Posture(permit(.author(.pieces(["a"])), .piece("b"))),
            offers: [.annotate], reason: .notYourPiece),
        Row(name: "pieces author on the project stream",
            posture: Posture(permit(.author(.pieces(["a"])), .projectStream)),
            offers: [.task, .annotate], reason: .notYourPiece),
        Row(name: "pieces author on a project statement",
            posture: Posture(permit(.author(.pieces(["a"])), .projectStatement)),
            offers: [.annotate], reason: .notYourPiece),
        Row(name: "pieces author on a statement this build cannot place",
            posture: Posture(permit(.author(.pieces(["a"])), .unplaceable("s"))),
            offers: [.annotate], reason: .cannotJudge),
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

    /// Starting a piece is the book author's alone until plan 2 (ruling R3) —
    /// whatever class the posture was built for.
    func test_startingAPieceIsTheBookAuthorsAlone() {
        let classes: [DocumentClass] = [
            .piece("a"), .pieceStatement(piece: "a"), .projectStatement,
            .projectStream, .translation(piece: "a"),
        ]
        for cls in classes {
            XCTAssertTrue(Posture(Self.permit(.bookAuthor, cls)).allows(.startAPiece), "\(cls)")
            XCTAssertFalse(Posture(Self.permit(.author(.pieces(["a"])), cls)).allows(.startAPiece), "\(cls)")
            XCTAssertFalse(Posture(Self.permit(.author(.pieces([])), cls)).allows(.startAPiece), "\(cls)")
            XCTAssertFalse(Posture(Self.permit(.reviewer, cls)).allows(.startAPiece), "\(cls)")
        }
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
        XCTAssertEqual(unlocked, Self.everythingButStarting.subtracting([.annotate]))
    }
}
