import XCTest
@testable import MaughamCore

@MainActor
final class OpLogStoreSegmentTests: XCTestCase {

    private let docId = "doc-seg1"
    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func op(_ opId: String, pid: String = "aaaa", next: String) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: "maca", session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: pid, prior: nil, next: next)],
           sequence: [pid])
    }

    private func jsonlBytes(_ ops: [Op]) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        var out = Data()
        for o in ops {
            out.append(try enc.encode(o))
            out.append(0x0A)
        }
        return out
    }

    private func writeSegment(_ ops: [Op], slug: String = "maca", index: Int = 1) throws -> URL {
        let url = OpLogStore.segmentFileURL(
            forDocId: docId, deviceSlug: slug, index: index, in: projectURL)
        try OpLogSegment.encode(jsonl: jsonlBytes(ops)).write(to: url)
        return url
    }

    // Recognition: filename helpers are the ONLY places that know the shape.
    func test_filenameHelpers_recognizeSegments() {
        let url = OpLogStore.segmentFileURL(
            forDocId: docId, deviceSlug: "maca", index: 3, in: projectURL)
        XCTAssertEqual(url.lastPathComponent, "doc-seg1.maca.seg0003.mzseg")
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: url.lastPathComponent), docId)
        XCTAssertEqual(OpLogStore.segmentIndex(
            fromFilename: url.lastPathComponent, docId: docId, deviceSlug: "maca"), 3)
        XCTAssertNil(OpLogStore.docId(fromOpLogFilename: "__project__.maca.seg0001.mzseg"),
                     "__project__ stays excluded")
        XCTAssertNil(OpLogStore.segmentIndex(
            fromFilename: "doc-seg1.OTHER.seg0001.mzseg", docId: docId, deviceSlug: "maca"),
            "another device's segment is not ours")
    }

    func test_opLogFileURLs_includeSegments() throws {
        let segURL = try writeSegment([op("01A", next: "x")])
        let tailURL = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: "maca", in: projectURL)
        try Data("".utf8).write(to: tailURL)
        let urls = Set(OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL)
            .map(\.lastPathComponent))
        XCTAssertTrue(urls.contains(segURL.lastPathComponent))
        XCTAssertTrue(urls.contains(tailURL.lastPathComponent))
    }

    // T9 — parity: derive over (segment + tail) == derive over one file.
    func test_parityAcrossSeal() async throws {
        let sealed = [op("01A", next: "first"), op("01B", next: "second")]
        let live = [op("01C", next: "third")]
        _ = try writeSegment(sealed)
        let store = OpLogStore(projectURL: projectURL)
        for o in live { try await store.append(o) }

        let merged = try await store.load(docId: docId)
        XCTAssertEqual(merged.map(\.opId), ["01A", "01B", "01C"])
        XCTAssertEqual(Deriver.derive(ops: merged),
                       Deriver.derive(ops: sealed + live),
                       "storage layout must not change derivation output")
    }

    // T10 — crash window between seal-write and tail-delete: duplicates dedupe.
    func test_crashBetweenSealAndTruncate_dedupes() async throws {
        let ops = [op("01A", next: "first"), op("01B", next: "second")]
        let store = OpLogStore(projectURL: projectURL)
        for o in ops { try await store.append(o) }      // tail still present
        _ = try writeSegment(ops)                        // same ops also sealed

        let merged = try await store.load(docId: docId)
        XCTAssertEqual(merged.map(\.opId), ["01A", "01B"],
                       "segment+tail overlap must collapse by opId")
        XCTAssertEqual(Deriver.derive(ops: merged), Deriver.derive(ops: ops))
    }

    // Tampered segment: skipped surfaced via diagnostics; salvageable ops kept.
    func test_tamperedSegment_surfacesDiagnosticsAndSalvages() async throws {
        let segURL = try writeSegment([op("01A", next: "first")])
        var bytes = try Data(contentsOf: segURL)
        bytes[16] ^= 0xFF                                // corrupt stored digest
        try bytes.write(to: segURL)
        let store = OpLogStore(projectURL: projectURL)
        try await store.append(op("01B", next: "second"))

        let (ops, diagnostics) = try await store.loadDiagnosed(docId: docId)
        XCTAssertFalse(diagnostics.skipped.isEmpty,
                       "checksum failure must surface in ParseDiagnostics")
        XCTAssertTrue(ops.contains { $0.opId == "01A" },
                      "salvageable ops inside the failed segment still derive")
        XCTAssertTrue(ops.contains { $0.opId == "01B" })
    }

    // Phone read path: loadSyncMerged sees segments through the same helpers.
    func test_loadSyncMerged_readsSegmentsPlusTail() async throws {
        _ = try writeSegment([op("01A", next: "first")])
        try await OpLogStore(projectURL: projectURL).append(op("01B", next: "second"))
        let ops = OpLogStore.loadSyncMerged(forDocId: docId, in: projectURL)
        XCTAssertEqual(ops.map(\.opId), ["01A", "01B"])
    }

    // T15 (first half) — opIds inside segments stay visible to the
    // dangling-checkpoint-pointer check via ProjectIntegrity.check.
    func test_integrityCheck_resolvesOpIdsInsideSegments() async throws {
        _ = try writeSegment([op("01A", next: "first")])
        let cp = Checkpoint(
            checkpointId: "cp1", label: "l", labelSource: .auto,
            at: Date(timeIntervalSince1970: 0), device: "maca",
            activeDoc: docId, docPointers: [docId: "01A"],
            manuscriptWordCount: 1)
        try await CheckpointStore(projectURL: projectURL).append(cp)

        let report = try await ProjectIntegrity.check(projectURL: projectURL)
        XCTAssertTrue(report.danglingPointers.isEmpty,
                      "a pointer into a sealed segment is NOT dangling")
        XCTAssertTrue(report.docSkips.isEmpty, "a healthy segment yields no skips")
    }

    // T15 (second half) — `.mzseg` never flagged as an iCloud conflict twin.
    func test_segmentNeverFlaggedAsConflictTwin() {
        let twins = IntegrityChecks.conflictTwins(inOpsDirectoryFilenames: [
            "doc-seg1.maca.seg0001.mzseg",
            "doc-seg1.maca.seg0001 2.mzseg",   // even an iCloud-suffixed segment
            "doc-seg1.maca 2.jsonl",           // real twin still caught
        ])
        XCTAssertEqual(twins, ["doc-seg1.maca 2.jsonl"])
    }
}
