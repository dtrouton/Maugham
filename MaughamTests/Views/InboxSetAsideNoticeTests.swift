import XCTest
@testable import MaughamCore
@testable import Maugham

/// The inbox says what it held back (the whole-branch review's I8).
///
/// `InboxStore.refresh` reads its manifests through the verified read, which
/// records a run of lines it cannot vouch for under the inbox's own stream id.
/// `HistoryPane` only ever asks for a DOCUMENT's records, so those records were
/// written to disk and communicated to nobody — a silent refusal, which is the
/// one shape the milestone's constraint 7 forbids.
///
/// Tripwire 33: the copy is a pure static, pinned without a window.
@MainActor
final class InboxSetAsideNoticeTests: XCTestCase {

    // MARK: - The copy

    func test_nothingSetAsideSaysNothing() {
        XCTAssertNil(InboxPane.setAsideNotice(lineCount: 0))
    }

    func test_oneCaptureIsSingular() {
        XCTAssertEqual(
            InboxPane.setAsideNotice(lineCount: 1),
            "1 capture was written to the inbox by something that is not "
            + "Maugham; kept in backup, not shown.")
    }

    func test_severalCapturesArePlural() {
        XCTAssertEqual(
            InboxPane.setAsideNotice(lineCount: 4),
            "4 captures were written to the inbox by something that is not "
            + "Maugham; kept in backup, not shown.")
    }

    // MARK: - The count

    /// The counting is `OpLogQuarantine`'s, shared with History rather than
    /// copied — one record can hold a run of lines, and the writer's question is
    /// how many CHANGES, not how many records.
    func test_theCountIsLinesAcrossRecordsAndSkipsWholeFileRecords() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-setaside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let source = project.appendingPathComponent(
            ".maugham/inbox/inbox.other.jsonl")
        try Data("{}\n".utf8).write(to: source)

        let two = try OpLogQuarantine.setAsideLines(
            [Data("{\"a\":1}".utf8), Data("{\"a\":2}".utf8)],
            from: source, docId: InboxManifest.chainDocId,
            reason: "written by something that is not Maugham", in: project)
        let one = try OpLogQuarantine.setAsideLines(
            [Data("{\"a\":3}".utf8)],
            from: source, docId: InboxManifest.chainDocId,
            reason: "written by something that is not Maugham", in: project)
        XCTAssertNotNil(two)
        XCTAssertNotNil(one)

        let records = OpLogQuarantine.records(
            forDocId: InboxManifest.chainDocId, in: project)
        XCTAssertEqual(
            OpLogQuarantine.setAsideLineCount(records: records, in: project), 3,
            "three lines across two records, not two")
    }
}
