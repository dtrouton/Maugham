import XCTest
@testable import MaughamCore
@testable import Maugham

/// Static-copy pins for the signed op log's two writer-facing sentences in
/// `HistoryPane` — what part of this document's history is UNSIGNED, and what
/// was SET ASIDE because something that is not Maugham wrote it.
///
/// Pinned without mounting, the `unreadableCheckpointNotice` /
/// `quarantineNotice` pattern: the copy is a pure static over counts, so its
/// grammar and its nil case are assertable with no window and no disk. The one
/// static that must read disk (`setAsideLineCount`, ruling 2's "N is the number
/// of LINES, not records") is pinned against a real temp project instead, and
/// is deliberately not the notice itself — a notice that read files would do
/// file I/O on every `body` evaluation.
///
/// The vocabulary rule these enforce: `unsealed` lines are the ordinary state
/// between seals and are NEVER mentioned; a legacy segment's lines are legacy,
/// never foreign; the internal words ("quarantine", "provenance", "chain")
/// never reach the writer.
@MainActor
final class HistoryPaneProvenanceNoticeTests: XCTestCase {

    // MARK: - unsignedHistoryNotice

    func test_unsignedHistoryNotice_nilForNoProvenance() {
        XCTAssertNil(HistoryPane.unsignedHistoryNotice(provenance: nil))
    }

    func test_unsignedHistoryNotice_nilWhenEverythingIsThisDevicesOwn() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.mac.jsonl", verified: 12, unsealed: 3)
        ])
        XCTAssertNil(
            HistoryPane.unsignedHistoryNotice(provenance: provenance),
            "unsealed lines are the ordinary state between seals — never a notice")
    }

    func test_unsignedHistoryNotice_legacyOnly_saysWrittenBeforeTheBookWasSigned() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.mac.jsonl", legacy: 40, unsealed: 2)
        ])
        XCTAssertEqual(
            HistoryPane.unsignedHistoryNotice(provenance: provenance),
            "Part of this document’s history was written before this book was signed.")
    }

    func test_unsignedHistoryNotice_foreignOnly_countsTheChanges() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", unsignedHistory: 7)
        ])
        XCTAssertEqual(
            HistoryPane.unsignedHistoryNotice(provenance: provenance),
            "7 changes from another device are applied as unsigned history.")
    }

    func test_unsignedHistoryNotice_oneForeignChange_usesSingularGrammar() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.phone.jsonl", unsignedHistory: 1)
        ])
        XCTAssertEqual(
            HistoryPane.unsignedHistoryNotice(provenance: provenance),
            "1 change from another device is applied as unsigned history.")
    }

    /// The coalescing rule (`Maugham/OpLog/AREA.md`, "The Document's one
    /// writer-facing channel"): the slot holds ONE sentence, so both facts
    /// arrive as one.
    func test_unsignedHistoryNotice_bothCausesCoalesceIntoOneSentence() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.mac.jsonl", legacy: 9),
            FileProvenance(name: "doc-a.phone.jsonl", unsignedHistory: 4),
        ])
        let notice = HistoryPane.unsignedHistoryNotice(provenance: provenance)
        XCTAssertEqual(
            notice,
            "Part of this document’s history was written before this book was signed, "
            + "and 4 changes from another device are applied as unsigned history.")
        XCTAssertEqual(
            notice?.filter { $0 == "." }.count, 1,
            "one sentence, not two — the toast/notice slot holds one")
    }

    func test_unsignedHistoryNotice_bothCauses_singularForeignGrammar() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.mac.jsonl", legacy: 9),
            FileProvenance(name: "doc-a.phone.jsonl", unsignedHistory: 1),
        ])
        XCTAssertEqual(
            HistoryPane.unsignedHistoryNotice(provenance: provenance),
            "Part of this document’s history was written before this book was signed, "
            + "and 1 change from another device is applied as unsigned history.")
    }

    func test_unsignedHistoryNotice_neverUsesInternalVocabulary() {
        let provenance = OpLogProvenance(files: [
            FileProvenance(name: "doc-a.mac.jsonl", legacy: 3, unsignedHistory: 2)
        ])
        let notice = try! XCTUnwrap(
            HistoryPane.unsignedHistoryNotice(provenance: provenance))
        for word in ["quarantine", "provenance", "chain", "seal", "hash"] {
            XCTAssertFalse(
                notice.localizedCaseInsensitiveContains(word),
                "internal term ‘\(word)’ must never reach the writer — \(notice)")
        }
    }

    // MARK: - setAsideLinesNotice

    func test_setAsideLinesNotice_nilWhenNothingWasSetAside() {
        XCTAssertNil(HistoryPane.setAsideLinesNotice(lineCount: 0))
    }

    func test_setAsideLinesNotice_countsTheChanges() {
        XCTAssertEqual(
            HistoryPane.setAsideLinesNotice(lineCount: 3),
            "3 changes were written to this document by something that is not "
            + "Maugham; kept in backup, not applied.")
    }

    func test_setAsideLinesNotice_singularGrammar() {
        XCTAssertEqual(
            HistoryPane.setAsideLinesNotice(lineCount: 1),
            "1 change was written to this document by something that is not "
            + "Maugham; kept in backup, not applied.")
    }

    // MARK: - setAsideLineCount (ruling 2: LINES, not records)

    func test_setAsideLineCount_zeroWhenNoRecords() {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        XCTAssertEqual(
            HistoryPane.setAsideLineCount(records: [], in: project), 0)
    }

    func test_setAsideLineCount_countsLinesAcrossRecords_notRecords() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let opsURL = project.appendingPathComponent(".maugham/ops/doc-abcd.phone.jsonl")

        let first = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [Data("{\"a\":1}".utf8), Data("{\"a\":2}".utf8), Data("{\"a\":3}".utf8)],
            from: opsURL, docId: "doc-abcd",
            reason: "written by something that is not Maugham", in: project))
        let second = try XCTUnwrap(OpLogQuarantine.setAsideLines(
            [Data("{\"b\":1}".utf8), Data("{\"b\":2}".utf8)],
            from: opsURL, docId: "doc-abcd",
            reason: "written by something that is not Maugham", in: project))

        XCTAssertEqual(
            HistoryPane.setAsideLineCount(records: [first, second], in: project), 5,
            "N is the number of set-aside CHANGES — five lines across two records")
    }

    /// A `.file` record's data file is a whole op log; its line count is not
    /// what this sentence counts, so the counter reads `.lines` records only.
    func test_setAsideLineCount_ignoresFileRecords() throws {
        let project = makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        let opsURL = project.appendingPathComponent(".maugham/ops/doc-abcd.phone.jsonl")
        try Data("{\"a\":1}\n{\"a\":2}\n".utf8).write(to: opsURL)

        let fileRecord = try OpLogQuarantine.quarantine(
            fileURL: opsURL, docId: "doc-abcd", reason: "unreadable", in: project)
        XCTAssertEqual(
            HistoryPane.setAsideLineCount(records: [fileRecord], in: project), 0,
            "a whole set-aside FILE is the Retry notice's subject, not this one's")
    }

    private func makeProject() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("histprov-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        return url
    }
}
