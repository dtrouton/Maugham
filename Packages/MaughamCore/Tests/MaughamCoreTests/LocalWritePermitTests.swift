import XCTest
@testable import MaughamCore

/// **The value the write side asks before a line exists** (P3a Task 8).
///
/// `LocalWritePermit` is allowed to skip resolving a document class, and these
/// tests are the whole of why that is safe. The skip rests on two claims about
/// `Permit.allows`, and neither is asserted anywhere else:
///
/// 1. A project statement is the HARDEST class — nothing it allows is refused
///    anywhere else — so a `.yes` there is a `.yes` everywhere.
/// 2. The writer's own hand under a whole-book permit gives the SAME answer in
///    every class, for every kind. That is the one condition under which the
///    class is left unresolved, so it has to be exactly true rather than merely
///    true of the kinds today's callers happen to ask about.
final class LocalWritePermitTests: XCTestCase {

    /// Every class a stream can be in, including two ids so the scope test has
    /// something to be wrong about.
    private let classes: [DocumentClass] = [
        .piece("p1"), .piece("p2"),
        .pieceStatement(piece: "p1"), .pieceStatement(piece: "p2"),
        .projectStatement, .projectStream,
        .translation(piece: "p1"), .translation(piece: "p2"),
        .inbox, .unplaceable("s1"),
    ]

    private let permits: [Permit] = [
        .reviewer, .author(.book), .author(.pieces([])), .author(.pieces(["p1"])),
        .unjudgeable(raw: "curator"),
    ]

    private var writtens: [Written] {
        OpKind.allCases.map { Written.op($0) } + [.translationRecord, .inboxRow]
    }

    // MARK: - Claim 1: the hardest class

    func test_theHardestClassRefusesEverythingAnyOtherClassRefuses() {
        for permit in permits {
            for actor in DeviceActor.allCases {
                for what in writtens {
                    guard permit.allows(
                        what, in: LocalWritePermit.hardestClass, actor: actor) == .yes
                    else { continue }
                    for documentClass in classes {
                        XCTAssertEqual(
                            permit.allows(what, in: documentClass, actor: actor), .yes,
                            "\(permit)/\(actor)/\(what) is yes in the hardest class "
                            + "but not in \(documentClass) — the stand-in class is "
                            + "not a stand-in any more")
                    }
                }
            }
        }
    }

    // MARK: - Claim 2: the one permit the class is skipped under

    func test_theWritersOwnHandUnderAWholeBookPermitAnswersTheSameInEveryClass() {
        for what in writtens {
            let inTheHardest = Permit.bookAuthor.allows(
                what, in: LocalWritePermit.hardestClass, actor: .author)
            for documentClass in classes {
                XCTAssertEqual(
                    Permit.bookAuthor.allows(what, in: documentClass, actor: .author),
                    inTheHardest,
                    "a book author's own hand must not be able to tell \(documentClass) "
                    + "from a project statement, or the unresolved class is a guess")
            }
        }
    }

    /// The converse, and the reason the condition names the ACTOR as well as
    /// the permit: a narrowed key under the very same whole-book permit CAN
    /// tell the classes apart — the assistant's refusal names *a statement* in
    /// one and *the manuscript* in another — so it is excluded from the skip.
    func test_aNarrowedKeyUnderTheSamePermitCanTellTheClassesApart() {
        XCTAssertFalse(
            LocalWritePermit.answersWithoutTheClass(.bookAuthor, as: .assistant))
        XCTAssertEqual(
            Permit.bookAuthor.allows(
                .op(.typingBurst), in: .projectStatement, actor: .assistant),
            .no(.statement))
        XCTAssertEqual(
            Permit.bookAuthor.allows(
                .op(.typingBurst), in: .piece("p1"), actor: .assistant),
            .no(.manuscriptText))
    }

    func test_onlyTheWholeBookAndTheWritersOwnHandSkipsTheClass() {
        for permit in permits {
            for actor in DeviceActor.allCases {
                XCTAssertEqual(
                    LocalWritePermit.answersWithoutTheClass(permit, as: actor),
                    permit == .bookAuthor && actor == .author,
                    "\(permit)/\(actor)")
            }
        }
    }

    // MARK: - The value itself

    func test_theUnrestrictedAnswerIsYesToEverythingTheWritersHandCanWrite() {
        for what in writtens where Permit.group(of: what) != .unreadable {
            XCTAssertEqual(
                LocalWritePermit.unrestricted.allows(what), .yes,
                "every book already on disk means this, for \(what)")
        }
    }

    func test_anUnreadableKindIsHeldEvenUnderTheWholeBook() {
        XCTAssertEqual(
            LocalWritePermit.unrestricted.allows(.op(.unknown)), .cannotJudge,
            "an older Mac must not apply what it cannot read, or refuse it")
    }

    func test_aReviewerMayNotWriteThePieceButMayStillAnnotateIt() {
        let permit = LocalWritePermit(
            permit: .reviewer, actor: .author, documentClass: .piece("p1"))
        XCTAssertEqual(permit.allows(.op(.typingBurst)), .no(.manuscriptText))
        XCTAssertEqual(permit.allows(.op(.bootstrap)), .no(.manuscriptText))
        XCTAssertEqual(permit.allows(.op(.taskCreate)), .no(.task))
        XCTAssertEqual(permit.allows(.op(.claudeComment)), .yes)
        XCTAssertEqual(permit.allows(.inboxRow), .yes)
    }

    func test_anAuthorOfSomePiecesWritesHersAndWaitsOnEverybodyElses() {
        let hers = LocalWritePermit(
            permit: .author(.pieces(["p1"])), actor: .author,
            documentClass: .piece("p1"))
        let theirs = LocalWritePermit(
            permit: .author(.pieces(["p1"])), actor: .author,
            documentClass: .piece("p2"))
        XCTAssertEqual(hers.allows(.op(.bootstrap)), .yes)
        XCTAssertEqual(theirs.allows(.op(.bootstrap)), .no(.manuscriptText))
        // And tasks on the project stream are hers wherever her pieces are.
        let stream = LocalWritePermit(
            permit: .author(.pieces(["p1"])), actor: .author,
            documentClass: .projectStream)
        XCTAssertEqual(stream.allows(.op(.taskCreate)), .yes)
    }

    /// The rebalance's own door: `maugham` signs one kind, and only where the
    /// person may sign a task there at all.
    func test_theRebalancesKeyIsAskedOfItsOwnRow() {
        let reviewer = LocalWritePermit(
            permit: .reviewer, actor: .author, documentClass: .piece("p1"))
        XCTAssertEqual(
            reviewer.allows(.op(.taskPriorityChange), signedBy: .maugham), .no(.task))
        let author = LocalWritePermit(
            permit: .author(.book), actor: .author, documentClass: .piece("p1"))
        XCTAssertEqual(
            author.allows(.op(.taskPriorityChange), signedBy: .maugham), .yes)
        XCTAssertEqual(
            author.allows(.op(.typingBurst), signedBy: .maugham), .no(.manuscriptText),
            "the app on nobody's instruction writes task order and nothing else")
    }
}
