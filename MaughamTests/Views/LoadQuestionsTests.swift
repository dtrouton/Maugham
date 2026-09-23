// MaughamTests/Views/LoadQuestionsTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The questions a load can raise** (signed op log P3b Task 7, spec §4.5 and
/// §7.2).
///
/// A load holds lines for three reasons and only one of them is a question the
/// writer can answer on the spot: somebody who may write *some* of this book
/// has put a paragraph into a piece that is in nobody's scope. That is §4.5's
/// *she started something new*, it is a question rather than a violation, and
/// until it is answered her words sit outside the draft with nothing on screen
/// saying so.
///
/// Pure, and deliberately ignorant of the folder: it is handed the counts a
/// load already produced, the registry a reader already verified, the titles
/// the manifest already holds and this device's own memory of what it has
/// already asked. Nothing here reads a file.
///
/// **The two directions of every rule are both pinned**, because each of them
/// fails silently in its own way: a question that never appears leaves her
/// words invisible, and a question that appears about the wrong holder asks
/// the writer to widen somebody's access over a line that was never hers.
@MainActor
final class LoadQuestionsTests: XCTestCase {

    private let root = String(repeating: "a1", count: 32)
    private let sam =
        "ffff2222aaaa3333bbbb4444cccc5555dddd6666eeee7777ffff8888aaaa9999"
    private let stranger =
        "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

    // MARK: - Fixtures

    private func person(
        _ fingerprint: String, label: String, admittedBy: String
    ) -> PersonRecord {
        PersonRecord(
            person: fingerprint, label: label, ownName: "A Mac",
            admittedAt: Date(timeIntervalSince1970: 10), admittedBy: admittedBy)
    }

    private func registry(people: [PersonRecord] = []) -> Registry {
        Registry(
            devices: [],
            people: [person(root, label: "Denver", admittedBy: root)] + people)
    }

    /// Sam admitted by this root: the only shape in which the question can be
    /// answered at all, because only her admitting root may widen her scope.
    private func samsBook() -> Registry {
        registry(people: [person(sam, label: "Sam", admittedBy: root)])
    }

    /// `startedAPiece` is now holder → piece → **that piece's own count**
    /// (fix round 1, I4). The helper takes the pieces and the count so the
    /// tests below read as they did, and the per-piece figure is what reaches
    /// the model.
    private func union(
        counts: [String: Int], startedAPiece: [String: Set<String>] = [:]
    ) -> HeldLineUnion {
        var perPiece: [String: [String: Int]] = [:]
        for (holder, docIds) in startedAPiece {
            for docId in docIds {
                perPiece[holder, default: [:]][docId] = counts[holder] ?? 0
            }
        }
        return HeldLineUnion(
            counts: counts, streams: [:], startedAPiece: perPiece)
    }

    // MARK: - The question appears

    func test_aPieceNobodyHasClaimedIsAQuestionNamingHerAndThePiece() {
        let questions = LoadQuestions.newPieces(
            held: union(counts: [sam: 4], startedAPiece: [sam: ["ch-2"]]),
            registry: samsBook(), titles: ["ch-2": "The Orchard"],
            declined: [], me: root)

        XCTAssertEqual(questions.count, 1)
        let question = try! XCTUnwrap(questions.first)
        XCTAssertEqual(question.person, sam)
        XCTAssertEqual(question.docId, "ch-2")
        XCTAssertEqual(question.heldLines, 4)
        XCTAssertTrue(question.question.contains("Sam"))
        XCTAssertTrue(question.question.contains("The Orchard"))
    }

    /// **Two buttons and no third**, and neither of them is *yours*. There is
    /// no verb that applies her text as the opening of the root's own piece —
    /// the root claims a piece by WRITING in it, which refuses her lines rather
    /// than adopting them — so offering it here would be offering a button
    /// nothing could honour.
    func test_thereAreExactlyTwoAnswersAndNeitherIsYours() {
        let question = LoadQuestions.NewPiece(
            person: sam, name: "Sam", docId: "ch-2", title: "The Orchard",
            heldLines: 2)

        XCTAssertEqual(
            [question.theirsTitle, question.notNowTitle].count, 2)
        for word in [question.theirsTitle, question.notNowTitle,
                     question.question, question.consequence] {
            XCTAssertFalse(
                word.localizedCaseInsensitiveContains("yours"), word)
            XCTAssertFalse(
                word.localizedCaseInsensitiveContains("mine"), word)
        }
    }

    /// And it is never worded as an admission: she is already in the book.
    func test_theQuestionIsNeverWordedAsAnAdmission() {
        let question = LoadQuestions.NewPiece(
            person: sam, name: "Sam", docId: "ch-2", title: "The Orchard",
            heldLines: 2)
        for word in [question.question, question.consequence,
                     question.theirsTitle, question.notNowTitle] {
            XCTAssertFalse(word.localizedCaseInsensitiveContains("admit"), word)
            XCTAssertFalse(
                word.localizedCaseInsensitiveContains("admission"), word)
        }
    }

    // MARK: - The question does not appear

    /// **Not now writes nothing and is never asked again by a load.** The
    /// memory is this device's own; the question goes on waiting in People &
    /// Devices, which is where the writer goes when they are ready.
    func test_aPieceTheWriterHasPutOffIsNotAskedAgain() {
        let held = union(counts: [sam: 4], startedAPiece: [sam: ["ch-2"]])
        XCTAssertEqual(
            LoadQuestions.newPieces(
                held: held, registry: samsBook(), titles: [:],
                declined: [.init(person: sam, docId: "ch-2")], me: root),
            [])
    }

    /// A holder the walk did NOT say started a piece raises nothing, however
    /// much of theirs is held. This is the arm that keeps a line this build
    /// cannot judge out of a question about whose a piece is.
    func test_aHeldLineThatDidNotStartAPieceRaisesNoQuestion() {
        XCTAssertEqual(
            LoadQuestions.newPieces(
                held: union(counts: [sam: 9]), registry: samsBook(),
                titles: [:], declined: [], me: root),
            [])
    }

    /// A STRANGER is never one of these, whatever the walk said. She is not in
    /// the book at all, so there is no scope to widen — her question is the
    /// admission sheet's, and asking both would be asking twice.
    func test_aStrangerIsNeverANewPieceQuestion() {
        XCTAssertEqual(
            LoadQuestions.newPieces(
                held: union(counts: [stranger: 3],
                            startedAPiece: [stranger: ["ch-2"]]),
                registry: samsBook(), titles: [:], declined: [], me: root),
            [])
    }

    /// An unsigned stream is never one either: there is no person and no
    /// permit, and its way back in is the Inbox.
    func test_anUnsignedStreamIsNeverANewPieceQuestion() {
        let holder = HeldLines.unsignedHolder(
            forStreamKey: "ch-2.author-beef", deviceSlug: "author-beef")
        XCTAssertEqual(
            LoadQuestions.newPieces(
                held: union(counts: [holder: 3],
                            startedAPiece: [holder: ["ch-2"]]),
                registry: samsBook(), titles: [:], declined: [], me: root),
            [])
    }

    /// **An unsigned holder is not a person, even where something claims it
    /// is.** `HeldLines`' own contract is that its holder string cannot be
    /// mistaken for a key or a person, and this is the guard that depends on
    /// it: without the classifier, a person record whose fingerprint happened
    /// to be spelled like one would turn a stream nothing signs into somebody
    /// whose scope the writer could widen.
    ///
    /// The registry below could not be written by Maugham — `RegistryWriter`
    /// signs a record and a fingerprint is a key — which is the point: this
    /// pins that the surface asks the classifier rather than assuming a holder
    /// string is a person because a lookup happened to find one.
    func test_anUnsignedHolderIsNotAPersonEvenIfARecordNamesIt() {
        let holder = HeldLines.unsignedHolder(
            forStreamKey: "ch-2.author-beef", deviceSlug: "author-beef")
        let confused = registry(people: [
            person(holder, label: "Not a person", admittedBy: root),
        ])
        XCTAssertEqual(
            LoadQuestions.newPieces(
                held: union(counts: [holder: 3],
                            startedAPiece: [holder: ["ch-2"]]),
                registry: confused, titles: [:], declined: [], me: root),
            [])
    }

    /// **A Mac that could not answer it does not ask it.** Only the root that
    /// admitted somebody may widen their scope (`changePermitOutcome`), so on
    /// anybody else's Mac this question is a button that can only refuse.
    func test_aMacThatCannotChangeHerPermitDoesNotAsk() {
        // Sam admitted by somebody else's root.
        let elsewhere = registry(people: [
            person(sam, label: "Sam", admittedBy: stranger),
        ])
        XCTAssertEqual(
            LoadQuestions.newPieces(
                held: union(counts: [sam: 4], startedAPiece: [sam: ["ch-2"]]),
                registry: elsewhere, titles: [:], declined: [], me: root),
            [])
    }

    /// Nothing held is no question, and a holder with a zero count is nothing
    /// held.
    func test_nothingHeldIsNoQuestion() {
        XCTAssertEqual(
            LoadQuestions.newPieces(
                held: union(counts: [sam: 0], startedAPiece: [sam: ["ch-2"]]),
                registry: samsBook(), titles: [:], declined: [], me: root),
            [])
    }

    // MARK: - Order, and a piece with no title

    /// Two pieces of hers are two questions, ordered so two runs over one
    /// folder ask in the same order.
    func test_twoPiecesAreTwoQuestionsInAStableOrder() {
        let questions = LoadQuestions.newPieces(
            held: union(counts: [sam: 6], startedAPiece: [sam: ["ch-9", "ch-2"]]),
            registry: samsBook(),
            titles: ["ch-2": "The Orchard", "ch-9": "The Ferry"],
            declined: [], me: root)

        XCTAssertEqual(questions.map(\.docId), ["ch-2", "ch-9"])
        XCTAssertEqual(questions.map(\.title), ["The Orchard", "The Ferry"])
    }

    /// A piece the manifest has no title for is still a question — the title
    /// is what the writer reads, and having none is not a reason to say
    /// nothing about words waiting outside the draft.
    func test_aPieceWithNoTitleIsStillAsked() {
        let questions = LoadQuestions.newPieces(
            held: union(counts: [sam: 1], startedAPiece: [sam: ["ch-2"]]),
            registry: samsBook(), titles: [:], declined: [], me: root)
        XCTAssertEqual(questions.count, 1)
        XCTAssertFalse(questions[0].title.isEmpty)
    }

    // MARK: - The count is this piece's (fix round 1, I4)

    /// **The number beside the question is the number in THAT piece.** The
    /// holder's total across every open document is a different figure, and it
    /// is the one the sheet was printing — so a writer with three held lines in
    /// one chapter and forty in another was promised forty in both.
    func test_theCountIsThePiecesOwnAndNotTheHoldersTotal() throws {
        let held = HeldLineUnion(
            counts: [sam: 43], streams: [:],
            startedAPiece: [sam: ["ch-2": 3, "ch-9": 40]])

        let questions = LoadQuestions.newPieces(
            held: held, registry: samsBook(),
            titles: ["ch-2": "The Orchard", "ch-9": "The Ferry"],
            declined: [], me: root)

        XCTAssertEqual(questions.map(\.heldLines), [3, 40])
        XCTAssertTrue(try XCTUnwrap(questions.first).consequence.contains("3 lines"))
        XCTAssertTrue(questions[1].consequence.contains("40 lines"))
    }

    /// **The consequence tells the truth about what *Theirs* does** (fix round
    /// 1, C1): what she already wrote HERE joins the draft, and from now on she
    /// may write in this piece. Both halves, because a sentence with only the
    /// second would be the promise the mark could not keep.
    func test_theConsequenceSaysBothWhatComesInAndWhatChangesFromNowOn() throws {
        let question = LoadQuestions.NewPiece(
            person: sam, name: "Sam", docId: "ch-2", title: "The Orchard",
            heldLines: 2)
        XCTAssertTrue(question.consequence.contains("already written here"))
        XCTAssertTrue(question.consequence.contains("from now on"))
        XCTAssertTrue(question.consequence.contains("join the draft"))
    }

    /// A question the writer ANSWERED is never put again either — the closed
    /// set is one set, however it was closed.
    func test_aPieceAlreadyAnsweredIsNotAskedAgain() {
        XCTAssertEqual(
            LoadQuestions.newPieces(
                held: union(counts: [sam: 4], startedAPiece: [sam: ["ch-2"]]),
                registry: samsBook(), titles: [:],
                declined: [.init(person: sam, docId: "ch-2")], me: root),
            [])
    }

    // MARK: - It is not the admission queue

    /// **The two questions never overlap.** A holder raising a new-piece
    /// question is somebody already in the book, so `AdmissionDecision` offers
    /// no sheet about her — the same held count cannot be counted as waiting
    /// for admission anywhere.
    func test_aNewPieceHolderIsInNoAdmissionWordedCount() {
        let book = samsBook()
        XCTAssertEqual(
            LoadQuestions.newPieces(
                held: union(counts: [sam: 4], startedAPiece: [sam: ["ch-2"]]),
                registry: book, titles: [:], declined: [], me: root).count,
            1)
        XCTAssertTrue(
            AdmissionDecision.requests(
                pending: [sam: 4], registry: book, memory: [:], myRoot: root)
                .isEmpty,
            "she is already in the book")
        XCTAssertTrue(book.strangersAwaitingAdmission(among: [sam: 4]).isEmpty)
    }
}
