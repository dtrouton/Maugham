import XCTest
import MaughamCore
@testable import Maugham

/// **History's drawer for what this book is missing** (signed op log P3b
/// Task 6).
///
/// The decisions are pinned on the pure value — which rows are drawn, in whose
/// words, and what changes once the writer has put a loss down — with nothing
/// mounted (tripwire 33: no test presses a mounted control and waits for its
/// effect). Whether the row carries an Acknowledge control at all is the
/// value's own field, so even that is decided here rather than by looking at a
/// window; what the press DOES is pinned on the store verb, through the real
/// production sweeps, in `LostHistoryTests`.
@MainActor
final class HistoryPaneLostHistoryTests: XCTestCase {

    private func lost(
        _ key: String = "doc-one.samsmac", what: OpLogStore.LostHistory.What = .line,
        acknowledged: Bool = false
    ) -> OpLogStore.LostHistory {
        OpLogStore.LostHistory(
            streamKey: key, deviceSlug: "samsmac", label: "Sam", what: what,
            noticedAt: what == .absent ? nil : Date(timeIntervalSince1970: 100),
            acknowledged: acknowledged)
    }

    // MARK: - Which rows, and in whose words

    func test_aBookMissingNothingDrawsNoRow() {
        XCTAssertTrue(HistoryPane.lostHistoryRows([]).isEmpty)
    }

    func test_eachLossIsOneRowNamedForTheDeviceAndPointingAtABackup() {
        let rows = HistoryPane.lostHistoryRows([
            lost("doc-one.samsmac", what: .line),
            lost("doc-two.samsmac", what: .segment),
            lost("doc-three.samsmac", what: .absent),
        ])

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(
            rows.map(\.streamKey),
            ["doc-one.samsmac", "doc-two.samsmac", "doc-three.samsmac"])
        for row in rows {
            XCTAssertTrue(row.sentence.contains("Sam"),
                          "named the way the book names them — got \(row.sentence)")
            XCTAssertTrue(row.sentence.contains("backup"),
                          "and pointing at the one place it can be got back from")
            XCTAssertTrue(
                row.sentence.contains("Nothing has left the draft"),
                "the draft is untouched, which is the first thing a writer needs")
            XCTAssertFalse(row.acknowledged)
        }
        // The three losses are three different facts and say so.
        XCTAssertTrue(rows[0].sentence.contains("shorter than it was"))
        XCTAssertTrue(rows[1].sentence.contains("sealed history is missing"))
        XCTAssertTrue(rows[2].sentence.contains("not in this book any more"))
    }

    /// A stream with no file at all was never NOTICED on a day, so no row
    /// dates it. The other two are dated by the load that met them.
    func test_anAbsentStreamCarriesNoDate() {
        XCTAssertNil(HistoryPane.lostHistoryRows([lost(what: .absent)]).first?.noticedAt)
        XCTAssertNotNil(HistoryPane.lostHistoryRows([lost(what: .line)]).first?.noticedAt)
    }

    // MARK: - What acknowledging changes

    /// **The row stays**, and it says what the press did. A press that made
    /// the row disappear would read as the loss having been undone — and would
    /// take away the only line on screen explaining why this book no longer
    /// waits for that stream.
    func test_anAcknowledgedRowStaysAndSaysWhatThePressDid() {
        let row = try? XCTUnwrap(
            HistoryPane.lostHistoryRows([lost(acknowledged: true)]).first)

        XCTAssertEqual(row?.acknowledged, true)
        XCTAssertTrue(row?.sentence.contains("shorter than it was") ?? false,
                      "the loss is still true, so it is still stated")
        XCTAssertTrue(
            row?.sentence.contains("no longer waits for it") ?? false,
            "and what the press changed is stated with it — got \(row?.sentence ?? "—")")
        XCTAssertTrue(
            row?.sentence.contains("judged as written after that change") ?? false,
            "including the cost, which is the whole of what the writer took on")
    }

    /// The help on the control says what it is FOR rather than *dismiss*: it
    /// is the writer telling this Mac the history is gone.
    func test_theAcknowledgeHelpSaysWhatItIsFor() {
        XCTAssertTrue(HistoryPane.acknowledgeLostHelp.contains("know this history is gone"))
        XCTAssertTrue(
            HistoryPane.acknowledgeLostHelp.contains("stop waiting"),
            "the consequence, not the gesture")
        XCTAssertFalse(
            HistoryPane.acknowledgeLostHelp.localizedCaseInsensitiveContains("dismiss"))
    }

    // MARK: - What the row offers

    /// **Whether the row carries a control is the VALUE's decision**, which is
    /// what lets it be pinned here: the body draws Acknowledge exactly where
    /// `acknowledged` is false. Nothing is mounted and nothing is pressed
    /// (tripwire 33); what the press does is pinned on the store verb in
    /// `LostHistoryTests`.
    func test_theControlIsOfferedExactlyWhileTheLossIsUnacknowledged() {
        let rows = HistoryPane.lostHistoryRows([
            lost("doc-one.samsmac"),
            lost("doc-two.samsmac", acknowledged: true),
        ])
        XCTAssertEqual(rows.map(\.acknowledged), [false, true])
    }
}
