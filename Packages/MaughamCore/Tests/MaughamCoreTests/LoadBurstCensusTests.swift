import Foundation
import XCTest
@testable import MaughamCore

/// **The kept release census** (signed op log P3b Task 3, handoff ruling 3 —
/// *A + 3b*).
///
/// v0.37–v0.40 signed the load path's own emissions with whichever actor opened
/// the document. Two of the five kinds are recognisable by KIND alone and are
/// grandfathered (`Permit.isALoadEmission`); the three `typingBurst`s are not,
/// so any of those lines that an older build wrote under the assistant's or the
/// translator's key stay REFUSED — set aside, recoverable by hand, never
/// silently lost. The label this task adds only helps lines written after it
/// ships, which is why the ruling also asks for a census that can be run on
/// every Mac that has opened a book before the P3 release.
///
/// This is that census. It is **read-only**, it decides nothing, and it reads
/// metadata only — `kind`, the stream's own name and `provenance
/// .synthesis_source`. It never looks at `changes`, so it never reads a word of
/// anybody's manuscript.
final class LoadBurstCensusTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoadBurstCensus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    // MARK: - Fixtures

    private func project(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        return url
    }

    /// One op line, written by hand so the census is read against the shape on
    /// disk rather than against this build's encoder.
    private func line(
        opId: String, docId: String, device: String, kind: String,
        synthesisSource: String? = nil
    ) -> String {
        let provenance = synthesisSource.map {
            ",\"provenance\":{\"synthesis_source\":\"\($0)\"}"
        } ?? ""
        return """
        {"op_id":"\(opId)","doc_id":"\(docId)","at":"2026-01-01T00:00:00.000Z",\
        "device":"\(device)","session":"s","kind":"\(kind)","changes":[]\(provenance)}
        """
    }

    private func writeTail(
        _ project: URL, name: String, lines: [String]
    ) throws {
        let url = project.appendingPathComponent(".maugham/ops/\(name)")
        try (lines.joined(separator: "\n") + "\n")
            .data(using: .utf8)!.write(to: url)
    }

    private func writeSegment(
        _ project: URL, name: String, lines: [String]
    ) throws {
        let jsonl = Data((lines.joined(separator: "\n") + "\n").utf8)
        let container = try OpLogSegment.encode(jsonl: jsonl)
        try container.write(
            to: project.appendingPathComponent(".maugham/ops/\(name)"))
    }

    // MARK: - What it finds

    /// **The at-risk shape**: an unlabelled `typingBurst` in a stream whose slug
    /// names the assistant or the translator.
    func test_itFindsAnUnlabelledBurstUnderANonAuthorActor() throws {
        let p = try project("Book")
        try writeTail(p, name: "d-one.assistant-1111222233334444-aaaabbbb.jsonl", lines: [
            line(opId: "01", docId: "d-one",
                 device: "assistant-1111222233334444-aaaabbbb", kind: "typing_burst"),
        ])

        let report = LoadBurstCensus.scan(projectURL: p)

        XCTAssertEqual(report.hits.count, 1)
        let hit = try XCTUnwrap(report.hits.first)
        XCTAssertEqual(hit.opId, "01")
        XCTAssertEqual(hit.docId, "d-one")
        XCTAssertEqual(hit.actor, "assistant")
        XCTAssertNil(hit.synthesisSource, "the shape the ruling is about")
        XCTAssertEqual(report.filesRead, 1)
        XCTAssertEqual(report.segmentsRead, 0)
        XCTAssertEqual(report.unreadable, [])
    }

    /// **And inside a sealed segment**, which the first (Python) census of this
    /// shape skipped and the second had to decode by hand.
    func test_itDecodesSegmentsAsWellAsTails() throws {
        let p = try project("Book")
        try writeSegment(
            p, name: "d-one.translator-1111222233334444-aaaabbbb.seg0001.mzseg",
            lines: [
                line(opId: "01", docId: "d-one",
                     device: "translator-1111222233334444-aaaabbbb",
                     kind: "typing_burst"),
            ])
        try writeTail(
            p, name: "d-one.translator-1111222233334444-aaaabbbb.jsonl", lines: [
                line(opId: "02", docId: "d-one",
                     device: "translator-1111222233334444-aaaabbbb",
                     kind: "typing_burst"),
            ])

        let report = LoadBurstCensus.scan(projectURL: p)

        XCTAssertEqual(report.hits.map(\.opId).sorted(), ["01", "02"])
        XCTAssertEqual(report.hits.map(\.actor), ["translator", "translator"])
        XCTAssertEqual(report.segmentsRead, 1)
        XCTAssertEqual(report.filesRead, 1)
    }

    /// A labelled burst is still reported — the label says this build wrote it
    /// and the line is not at risk — but the field says so, so a hit list can be
    /// read without opening anything.
    func test_aLabelledBurstIsReportedWithItsLabel() throws {
        let p = try project("Book")
        try writeTail(p, name: "d-one.assistant-1111222233334444-aaaabbbb.jsonl", lines: [
            line(opId: "01", docId: "d-one",
                 device: "assistant-1111222233334444-aaaabbbb",
                 kind: "typing_burst", synthesisSource: "anchor_splice"),
        ])

        let report = LoadBurstCensus.scan(projectURL: p)

        XCTAssertEqual(report.hits.count, 1)
        XCTAssertEqual(report.hits.first?.synthesisSource, "anchor_splice")
    }

    // MARK: - What it leaves alone (the other direction, each pinned)

    /// The author's own streams are the whole book; a census that reported them
    /// would report every line anybody has ever typed.
    func test_theAuthorsOwnStreamsAreNotHits() throws {
        let p = try project("Book")
        try writeTail(p, name: "d-one.author-1111222233334444-aaaabbbb.jsonl", lines: [
            line(opId: "01", docId: "d-one",
                 device: "author-1111222233334444-aaaabbbb", kind: "typing_burst"),
        ])
        XCTAssertEqual(LoadBurstCensus.scan(projectURL: p).hits, [])
    }

    /// `bootstrap` and `taskCreate` are the two kinds `Permit.isALoadEmission`
    /// already grandfathers — they apply, so they are not what this looks for.
    func test_theTwoGrandfatheredKindsAreNotHits() throws {
        let p = try project("Book")
        try writeTail(p, name: "d-one.assistant-1111222233334444-aaaabbbb.jsonl", lines: [
            line(opId: "01", docId: "d-one",
                 device: "assistant-1111222233334444-aaaabbbb", kind: "bootstrap"),
            line(opId: "02", docId: "d-one",
                 device: "assistant-1111222233334444-aaaabbbb", kind: "task_create"),
            line(opId: "03", docId: "d-one",
                 device: "assistant-1111222233334444-aaaabbbb", kind: "claude_comment"),
        ])
        XCTAssertEqual(LoadBurstCensus.scan(projectURL: p).hits, [])
    }

    /// The legacy unsuffixed file names no actor at all — pre-signing history,
    /// applied under decision B3, and nothing this census is about.
    func test_theLegacyUnsuffixedFileIsNotAHit() throws {
        let p = try project("Book")
        try writeTail(p, name: "d-one.jsonl", lines: [
            line(opId: "01", docId: "d-one", device: "denvers-macbook-pro",
                 kind: "typing_burst"),
        ])
        XCTAssertEqual(LoadBurstCensus.scan(projectURL: p).hits, [])
        XCTAssertEqual(LoadBurstCensus.scan(projectURL: p).filesRead, 1)
    }

    /// A seal line belongs to the chain and is recognised in `OpLogChain` alone
    /// (tripwire 37): the census asks, it does not have an opinion of its own.
    func test_aSealLineIsNotReadAsAnOp() throws {
        let p = try project("Book")
        try writeTail(p, name: "d-one.assistant-1111222233334444-aaaabbbb.jsonl", lines: [
            line(opId: "01", docId: "d-one",
                 device: "assistant-1111222233334444-aaaabbbb", kind: "typing_burst"),
            "{\"seal\":{\"key\":\"abc\",\"through\":\"x\",\"sig\":\"y\"}}",
        ])
        let report = LoadBurstCensus.scan(projectURL: p)
        XCTAssertEqual(report.hits.count, 1)
        XCTAssertEqual(report.unreadable, [],
            "a seal is not a damaged op")
    }

    /// A file it cannot read is NAMED rather than skipped: a census whose
    /// all-clear covers a folder it could not open is worse than none.
    func test_anUndecodableSegmentIsNamedRatherThanSwallowed() throws {
        let p = try project("Book")
        try Data("not a segment".utf8).write(
            to: p.appendingPathComponent(
                ".maugham/ops/d-one.assistant-1111222233334444-aaaabbbb.seg0001.mzseg"))
        let report = LoadBurstCensus.scan(projectURL: p)
        XCTAssertEqual(report.hits, [])
        XCTAssertEqual(
            report.unreadable,
            ["d-one.assistant-1111222233334444-aaaabbbb.seg0001.mzseg"])
    }

    /// A project with no op log at all answers cleanly — no hits, nothing read,
    /// nothing unreadable.
    func test_aProjectWithNoOpLogAnswersEmpty() {
        let empty = root.appendingPathComponent("NoOps")
        try? FileManager.default.createDirectory(
            at: empty, withIntermediateDirectories: true)
        let report = LoadBurstCensus.scan(projectURL: empty)
        XCTAssertEqual(report.hits, [])
        XCTAssertEqual(report.filesRead, 0)
        XCTAssertEqual(report.unreadable, [])
    }

    // MARK: - Finding the projects, and saying what was found

    func test_itFindsEveryProjectFolderUnderARoot() throws {
        _ = try project("One")
        _ = try project("Nested/Two")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("NotAProject"),
            withIntermediateDirectories: true)

        let found = LoadBurstCensus.projects(under: root)
            .map(\.lastPathComponent).sorted()

        XCTAssertEqual(found, ["One", "Two"])
    }

    /// The sentence the script prints. *None* has to be distinguishable from
    /// *nothing was looked at*, so the summary carries what was read.
    func test_theSummarySaysNoneAndSaysWhatItRead() throws {
        let p = try project("Book")
        try writeTail(p, name: "d-one.author-1111222233334444-aaaabbbb.jsonl", lines: [
            line(opId: "01", docId: "d-one",
                 device: "author-1111222233334444-aaaabbbb", kind: "typing_burst"),
        ])
        let summary = LoadBurstCensus.describe([LoadBurstCensus.scan(projectURL: p)])
        XCTAssertTrue(
            summary.contains("Load bursts under a non-author actor: none."),
            summary)
        XCTAssertTrue(summary.contains("1 project"), summary)
        XCTAssertTrue(summary.contains("1 file"), summary)
    }

    func test_theSummaryNamesEveryHit() throws {
        let p = try project("Book")
        try writeTail(p, name: "d-one.assistant-1111222233334444-aaaabbbb.jsonl", lines: [
            line(opId: "01", docId: "d-one",
                 device: "assistant-1111222233334444-aaaabbbb", kind: "typing_burst"),
        ])
        let summary = LoadBurstCensus.describe([LoadBurstCensus.scan(projectURL: p)])
        XCTAssertFalse(
            summary.contains("Load bursts under a non-author actor: none."),
            summary)
        XCTAssertTrue(summary.contains("01"), summary)
        XCTAssertTrue(summary.contains("assistant"), summary)
        XCTAssertTrue(summary.contains("Book"), summary)
    }

    // MARK: - It changes nothing

    /// Read-only, asserted rather than promised: the folder's every file is
    /// byte-identical and no file was added or removed.
    func test_itWritesNothing() throws {
        let p = try project("Book")
        try writeTail(p, name: "d-one.assistant-1111222233334444-aaaabbbb.jsonl", lines: [
            line(opId: "01", docId: "d-one",
                 device: "assistant-1111222233334444-aaaabbbb", kind: "typing_burst"),
        ])
        func snapshot() throws -> [String: Data] {
            var out: [String: Data] = [:]
            let walker = FileManager.default.enumerator(
                at: p, includingPropertiesForKeys: nil)!
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true else { continue }
                out[url.path] = try Data(contentsOf: url)
            }
            return out
        }
        let before = try snapshot()
        _ = LoadBurstCensus.scan(projectURL: p)
        XCTAssertEqual(try snapshot(), before)
    }
}
