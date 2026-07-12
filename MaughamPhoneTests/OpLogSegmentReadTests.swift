import XCTest
import MaughamCore

/// The phone gets sealed-segment reading FOR FREE through the shared
/// MaughamCore helpers (growth spec §5.3) — pinned here so a phone-local
/// reader regression (the phone-v0.1.1 class of bug) can't silently return.
@MainActor
final class OpLogSegmentReadTests: XCTestCase {

    func test_loadSyncMerged_readsSealedSegmentPlusTail() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-seg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)

        func op(_ opId: String, next: String) -> Op {
            Op(opId: opId, docId: "doc-ph1", at: Date(timeIntervalSince1970: 0),
               device: "mac", session: "s", kind: .typingBurst,
               changes: [.init(paragraphId: "aaaa", prior: nil, next: next)],
               sequence: ["aaaa"])
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        var jsonl = Data()
        jsonl.append(try enc.encode(op("01A", next: "sealed")))
        jsonl.append(0x0A)
        try OpLogSegment.encode(jsonl: jsonl).write(
            to: OpLogStore.segmentFileURL(
                forDocId: "doc-ph1", deviceSlug: DeviceSlug.make(from: "mac"), index: 1, in: projectURL))
        var tail = Data()
        tail.append(try enc.encode(op("01B", next: "live")))
        tail.append(0x0A)
        try tail.write(to: OpLogStore.opLogFileURL(
            forDocId: "doc-ph1", deviceSlug: DeviceSlug.make(from: "mac"), in: projectURL))

        let ops = OpLogStore.loadSyncMerged(forDocId: "doc-ph1", in: projectURL)
        XCTAssertEqual(ops.map(\.opId), ["01A", "01B"])
        XCTAssertEqual(Deriver.derive(ops: ops).paragraphs["aaaa"], "live")
    }
}
