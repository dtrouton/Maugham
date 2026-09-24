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

    // MARK: - Option A (P3c plan 2): the starter and the may-start arm

    /// **No starter recorded, or a book nobody is narrowed in (`startedHere`
    /// nil), is today's rule exactly**: whoever may write the opening mints
    /// it — every permit, every class, every key. Review Focus 3.
    func test_withNoStarterTheOpeningIsTodaysRule() {
        for permit in permits {
            for actor in DeviceActor.allCases {
                for documentClass in classes {
                    let value = LocalWritePermit(
                        permit: permit, actor: actor, documentClass: documentClass)
                    XCTAssertEqual(
                        value.mayMintOpening,
                        value.allows(.op(.bootstrap)) == .yes,
                        "\(permit)/\(actor)/\(documentClass)")
                }
            }
        }
    }

    /// **The starter rule, both directions** (OA-1, OA-2): only the Mac that
    /// started a piece mints its opening — the root's Mac included, and her
    /// own OTHER Mac included — and even the starter mints only what it may
    /// write, so a reviewer an unsigned manifest names as a starter mints
    /// nothing.
    func test_onlyTheStartersMacMintsTheOpeningAndOnlyWhatItMayWrite() {
        func value(_ permit: Permit, here: Bool, hers: Bool = false) -> LocalWritePermit {
            LocalWritePermit(
                permit: permit, actor: .author, documentClass: .piece("p2"),
                startedHere: here, writesAsItsStarter: hers)
        }
        XCTAssertTrue(value(.bookAuthor, here: true).mayMintOpening)
        XCTAssertFalse(value(.bookAuthor, here: false).mayMintOpening,
            "OA-2: the root waits for a piece it did not start")
        XCTAssertTrue(value(.author(.pieces(["p1"])), here: true, hers: true).mayMintOpening,
            "she mints the piece she started")
        XCTAssertFalse(value(.author(.pieces(["p1"])), here: false, hers: true).mayMintOpening,
            "her other Mac waits for the ops (Review Focus 1)")
        XCTAssertFalse(value(.author(.pieces(["p1"])), here: true, hers: false).mayMintOpening,
            "a piece a book author has since written is not hers to open")
        XCTAssertFalse(value(.reviewer, here: true, hers: true).mayMintOpening,
            "a reviewer named as a starter mints nothing")
    }

    /// **The arm widens manuscript text signed by her own hand, and nothing
    /// else** — every kind, every key, against the plain table. A disposition,
    /// a checkpoint, a task or a translation in her unclaimed piece is exactly
    /// what it was, because the read side sets those aside everywhere.
    func test_theArmReachesHerOwnManuscriptTextAndNothingElse() {
        let piecesAuthor = Permit.author(.pieces(["p1"]))
        for actor in DeviceActor.allCases {
            let armed = LocalWritePermit(
                permit: piecesAuthor, actor: actor, documentClass: .piece("p2"),
                startedHere: true, writesAsItsStarter: true)
            for what in writtens {
                let table = piecesAuthor.allows(what, in: .piece("p2"), actor: actor)
                let widened = actor == .author
                    && Permit.group(of: what) == .manuscriptText
                XCTAssertEqual(
                    armed.allows(what), widened ? .yes : table,
                    "\(actor)/\(what)")
            }
            XCTAssertEqual(armed.isWaitingToBeClaimed, actor == .author, "\(actor)")
        }
    }

    /// **And the arm is inert everywhere §4.5 is not the question** — inside
    /// her own scope, for a book author, for a reviewer, and whenever it is
    /// off. Those answers are the table's, cell for cell.
    func test_theArmIsInertWhereSheIsNotStartingAPiece() {
        let cases: [(Permit, DocumentClass)] = [
            (.author(.pieces(["p1"])), .piece("p1")),
            (.author(.pieces(["p1"])), .projectStatement),
            (.author(.pieces(["p1"])), .pieceStatement(piece: "p2")),
            (.author(.pieces(["p1"])), .translation(piece: "p2")),
            (.bookAuthor, .piece("p2")),
            (.reviewer, .piece("p2")),
            (.unjudgeable(raw: "curator"), .piece("p2")),
        ]
        for (permit, documentClass) in cases {
            let armed = LocalWritePermit(
                permit: permit, actor: .author, documentClass: documentClass,
                startedHere: true, writesAsItsStarter: true)
            for what in writtens {
                XCTAssertEqual(
                    armed.allows(what),
                    permit.allows(what, in: documentClass, actor: .author),
                    "\(permit)/\(documentClass)/\(what)")
            }
            XCTAssertFalse(armed.isWaitingToBeClaimed, "\(permit)/\(documentClass)")
        }
        let off = LocalWritePermit(
            permit: .author(.pieces(["p1"])), actor: .author,
            documentClass: .piece("p2"), startedHere: true, writesAsItsStarter: false)
        XCTAssertEqual(off.allows(.op(.typingBurst)), .no(.manuscriptText))
        XCTAssertFalse(off.isWaitingToBeClaimed)
    }

    /// **Starting a piece** is the book author's hand and an author of some
    /// pieces' hand — nobody else's (Option A widens ruling R3).
    func test_startingAPieceIsTheWholeBookOrSomePiecesAndTheWritersOwnHand() {
        for permit in permits {
            for actor in DeviceActor.allCases {
                let value = LocalWritePermit(
                    permit: permit, actor: actor, documentClass: .piece("p1"))
                let expected: Allowed
                switch (permit, actor) {
                case (.author, .author): expected = .yes
                default:
                    expected = permit.allows(
                        .op(.typingBurst), in: LocalWritePermit.hardestClass, actor: actor)
                }
                XCTAssertEqual(value.allowsStartingAPiece(), expected, "\(permit)/\(actor)")
            }
        }
        XCTAssertEqual(
            LocalWritePermit(permit: .reviewer, actor: .author, documentClass: nil)
                .allowsStartingAPiece(), .no(.statement))
    }
}
