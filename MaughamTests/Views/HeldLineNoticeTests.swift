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
}
