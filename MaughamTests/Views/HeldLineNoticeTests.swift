// MaughamTests/Views/HeldLineNoticeTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **A voice for every held line** (signed op log P3b Task 7, closing Task 2's
/// review I1).
///
/// P2 held a line for exactly one reason and History said so. P3a added a
/// second (a permit this build cannot judge) and P3b a third (a stream nothing
/// signs, after the first narrowing) and a fourth reading of the second (a
/// piece nobody has claimed) — and all of them were held SILENTLY: the
/// admission sentence narrows to strangers on purpose, and nothing else said
/// anything at all. Words sitting outside the draft with no sentence anywhere
/// is the one shape a refusal may not take.
///
/// Pure over a `FileProvenance`, so the copy pins with no window and no disk.
final class HeldLineNoticeTests: XCTestCase {

    private let stranger = String(repeating: "f1", count: 32)
    private let sam = String(repeating: "a2", count: 32)

    /// A file provenance holding `counts`, with `strangers` stamped exactly as
    /// a load's own trust table stamps it.
    private func provenance(
        counts: [String: Int], strangers: Set<String>
    ) -> OpLogProvenance {
        OpLogProvenance(files: [FileProvenance(
            name: "doc.author-a.jsonl",
            pending: counts.values.reduce(0, +),
            pendingByDevice: counts,
            pendingStrangerDevices: strangers)])
    }

    /// **A stranger's lines are NOT repeated here**: they have their own
    /// sentence and their own control one line up, and saying it twice would
    /// put two counts about one device on one screen.
    func test_aStrangersLinesAreLeftToTheAdmissionSentence() {
        XCTAssertEqual(
            HistoryPane.heldLineNotices(
                provenance: provenance(
                    counts: [stranger: 3], strangers: [stranger]),
                startedAPiece: [], names: [:]),
            [])
    }

    /// An admitted person whose line this build cannot judge gets a sentence,
    /// and it is not an admission sentence.
    func test_anUnjudgeableLineGetsItsOwnSentence() throws {
        let notices = HistoryPane.heldLineNotices(
            provenance: provenance(counts: [sam: 2], strangers: []),
            startedAPiece: [], names: [sam: "Sam"])

        XCTAssertEqual(notices.count, 1)
        let notice = try XCTUnwrap(notices.first)
        XCTAssertTrue(notice.contains("Sam"))
        XCTAssertTrue(notice.contains("2 notes"))
        XCTAssertFalse(notice.localizedCaseInsensitiveContains("admission"))
    }

    /// And the same holder, when the WALK said she opened a piece, gets the
    /// other sentence — the one that names a question rather than a wait.
    func test_aPieceNobodyHasClaimedGetsTheOtherSentence() throws {
        let notice = try XCTUnwrap(HistoryPane.heldLineNotices(
            provenance: provenance(counts: [sam: 2], strangers: []),
            startedAPiece: [sam], names: [sam: "Sam"]).first)

        XCTAssertTrue(notice.localizedCaseInsensitiveContains("nobody has claimed"))
        XCTAssertFalse(notice.localizedCaseInsensitiveContains("newer"))
    }

    /// An unsigned stream is named by its stream and points at the Inbox,
    /// because there is no device to admit and no permit to widen.
    func test_anUnsignedStreamPointsAtTheInbox() throws {
        let holder = HeldLines.unsignedHolder(
            forStreamKey: "doc.author-beef", deviceSlug: "author-beef")
        let notice = try XCTUnwrap(HistoryPane.heldLineNotices(
            provenance: provenance(counts: [holder: 5], strangers: []),
            startedAPiece: [], names: [:]).first)

        XCTAssertTrue(notice.localizedCaseInsensitiveContains("Inbox"))
        XCTAssertFalse(
            notice.localizedCaseInsensitiveContains("waiting for admission"))
    }

    /// Nothing held is nothing said, and so is a document that is not open.
    func test_nothingHeldIsNoNotice() {
        XCTAssertEqual(
            HistoryPane.heldLineNotices(
                provenance: provenance(counts: [:], strangers: []),
                startedAPiece: [], names: [:]),
            [])
        XCTAssertEqual(
            HistoryPane.heldLineNotices(
                provenance: nil, startedAPiece: [], names: [:]),
            [])
    }

    /// Two holders are two sentences in a stable order, so two reloads over
    /// one document say the same things in the same sequence.
    func test_twoHoldersAreTwoSentencesInAStableOrder() {
        let other = String(repeating: "b3", count: 32)
        let notices = HistoryPane.heldLineNotices(
            provenance: provenance(counts: [sam: 1, other: 1], strangers: []),
            startedAPiece: [], names: [sam: "Sam", other: "Kit"])
        XCTAssertEqual(notices.count, 2)
        // By HOLDER, which is the only key both sentences have: "a2…" before
        // "b3…", whatever the writer called either of them.
        XCTAssertTrue(try XCTUnwrap(notices.first).contains("Sam"), notices[0])
        XCTAssertTrue(notices[1].contains("Kit"), notices[1])
    }

    // MARK: - §7.2's rows (fix round 1, I3)

    /// **The pane asks the same question the sheet does**, off the same model
    /// — so a row and a dialog cannot name a different count, piece or person
    /// about one question.
    func test_thePaneDrawsTheSameQuestionTheSheetDoes() throws {
        let root = String(repeating: "a1", count: 32)
        let registry = Registry(devices: [], people: [
            PersonRecord(person: root, label: "Denver", ownName: "Mac",
                         admittedAt: Date(timeIntervalSince1970: 1),
                         admittedBy: root),
            PersonRecord(person: sam, label: "Sam", ownName: "Sam’s Mac",
                         admittedAt: Date(timeIntervalSince1970: 2),
                         admittedBy: root),
        ])
        let model = PeopleAndDevicesModel.make(
            registry: registry,
            table: TrustTable.resolve(
                registry: registry, mine: .forTesting(author: .softwareForTesting()),
                joinedRoot: nil),
            remembered: [:], requests: [], claimants: [],
            standing: .init(code: "AAAA", isRoot: true),
            me: root,
            held: [sam: 3],
            pieces: [.init(id: "ch-2", title: "The Orchard")],
            heldPieceStarts: [sam: ["ch-2": 3]],
            declinedPieces: [])

        XCTAssertEqual(model.pendingPieces.count, 1)
        let row = try XCTUnwrap(model.pendingPieces.first)
        XCTAssertEqual(row.question.docId, "ch-2")
        XCTAssertEqual(row.question.heldLines, 3)
        XCTAssertTrue(row.question.question.contains("The Orchard"))
        XCTAssertFalse(row.putOff)
    }

    /// **A question the writer put off is listed HERE and nowhere else** — the
    /// sheet is silent about it for good, so hiding it here too would leave
    /// them no way back to a question they meant to answer later.
    func test_aQuestionPutOffIsStillDrawnInThePaneAndSaysSo() throws {
        let root = String(repeating: "a1", count: 32)
        let registry = Registry(devices: [], people: [
            PersonRecord(person: root, label: "Denver", ownName: "Mac",
                         admittedAt: Date(timeIntervalSince1970: 1),
                         admittedBy: root),
            PersonRecord(person: sam, label: "Sam", ownName: "Sam’s Mac",
                         admittedAt: Date(timeIntervalSince1970: 2),
                         admittedBy: root),
        ])
        let model = PeopleAndDevicesModel.make(
            registry: registry,
            table: TrustTable.resolve(
                registry: registry, mine: .forTesting(author: .softwareForTesting()),
                joinedRoot: nil),
            remembered: [:], requests: [], claimants: [],
            standing: .init(code: "AAAA", isRoot: true),
            me: root,
            held: [sam: 3],
            pieces: [.init(id: "ch-2", title: "The Orchard")],
            heldPieceStarts: [sam: ["ch-2": 3]],
            declinedPieces: [.init(person: sam, docId: "ch-2")])

        XCTAssertEqual(model.pendingPieces.count, 1)
        XCTAssertTrue(try XCTUnwrap(model.pendingPieces.first).putOff)
        XCTAssertFalse(PeopleAndDevicesModel.pieceQuestionPutOff.isEmpty)
    }

    /// **A question the writer ANSWERED is not drawn at all** (fix round 3,
    /// minor 5).
    ///
    /// Put off and answered are different facts, and reading one set for both
    /// made a settled question appear under *You put this off* — which tells
    /// the writer the opposite of what they did, about a permit change they
    /// have already made.
    func test_aQuestionAlreadyAnsweredIsNotDrawnAtAll() throws {
        let root = String(repeating: "a1", count: 32)
        let registry = Registry(devices: [], people: [
            PersonRecord(person: root, label: "Denver", ownName: "Mac",
                         admittedAt: Date(timeIntervalSince1970: 1),
                         admittedBy: root),
            PersonRecord(person: sam, label: "Sam", ownName: "Sam’s Mac",
                         admittedAt: Date(timeIntervalSince1970: 2),
                         admittedBy: root),
        ])
        let model = PeopleAndDevicesModel.make(
            registry: registry,
            table: TrustTable.resolve(
                registry: registry, mine: .forTesting(author: .softwareForTesting()),
                joinedRoot: nil),
            remembered: [:], requests: [], claimants: [],
            standing: .init(code: "AAAA", isRoot: true),
            me: root,
            held: [sam: 3],
            pieces: [.init(id: "ch-2", title: "The Orchard")],
            heldPieceStarts: [sam: ["ch-2": 3]],
            declinedPieces: [],
            settledPieces: [.init(person: sam, docId: "ch-2")])

        XCTAssertTrue(
            model.pendingPieces.isEmpty,
            "answered is over; it is not a question waiting to be answered")
    }

    // MARK: - A History row about somebody with no record (fix round 1, I2)

    /// The clause is DRAWN, not merely available: `unknownSubject` had no
    /// production caller at all before this.
    func test_aHistoryRowAboutAnUnknownSubjectCarriesTheClause() throws {
        let subject = String(repeating: "c4", count: 32)
        let line = try XCTUnwrap(HistoryPane.trustEventLines(
            [TrustEvent(
                date: Date(timeIntervalSince1970: 1), kind: .admitted,
                subject: subject, label: nil, ownName: nil, by: nil,
                isMine: false)],
            labels: [:]).first)
        XCTAssertTrue(
            line.sentence.contains("hasn\u{2019}t received their record yet"),
            line.sentence)
    }

    /// And a row about somebody the book DOES know carries no such clause.
    func test_aHistoryRowAboutAKnownSubjectCarriesNoClause() throws {
        let subject = String(repeating: "c4", count: 32)
        let line = try XCTUnwrap(HistoryPane.trustEventLines(
            [TrustEvent(
                date: Date(timeIntervalSince1970: 1), kind: .admitted,
                subject: subject, label: "Sam", ownName: nil, by: nil,
                isMine: false)],
            labels: [:]).first)
        XCTAssertFalse(line.sentence.contains("record yet"), line.sentence)
    }

    // MARK: - The Inbox says the same things (fix round 1, I5)

    /// Every holder shape, in one pass: a stranger is left to the banner above
    /// (which carries the Admit… control), and the other three get their own
    /// sentence off the same `HeldLines` the History rows read.
    func test_theInboxNamesEveryHeldShapeButTheStranger() throws {
        let root = String(repeating: "a1", count: 32)
        let unsigned = HeldLines.unsignedHolder(
            forStreamKey: "inbox.author-beef", deviceSlug: "author-beef")
        let registry = Registry(devices: [], people: [
            PersonRecord(person: root, label: "Denver", ownName: "Mac",
                         admittedAt: Date(timeIntervalSince1970: 1),
                         admittedBy: root),
            PersonRecord(person: sam, label: "Sam", ownName: "Sam’s Mac",
                         admittedAt: Date(timeIntervalSince1970: 2),
                         admittedBy: root),
        ])

        let notices = InboxStore.heldNotices(
            from: [sam: 2, stranger: 5, unsigned: 1], registry: registry)

        XCTAssertEqual(notices.count, 2, "the stranger has the banner: \(notices)")
        XCTAssertFalse(
            notices.contains { $0.localizedCaseInsensitiveContains("waiting for admission") },
            "\(notices)")
        XCTAssertTrue(
            notices.contains {
                $0.localizedCaseInsensitiveContains("this version of maugham")
            }, "the admitted person's own sentence: \(notices)")
        XCTAssertTrue(
            notices.contains { $0.localizedCaseInsensitiveContains("Inbox") },
            "\(notices)")
    }

    /// Nothing held is nothing said.
    func test_anInboxHoldingNothingSaysNothing() {
        XCTAssertEqual(
            InboxStore.heldNotices(from: [:], registry: Registry()), [])
    }
}
