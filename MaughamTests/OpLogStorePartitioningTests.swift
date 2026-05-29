import XCTest
import MaughamCore
@testable import Maugham

/// Phase B0 — per-device JSONL partitioning (ADR 0012, spec §3.12).
/// Each device appends only to `<docId>.<slug>.jsonl`; load globs every sibling
/// (incl. the legacy unsuffixed `<docId>.jsonl`) and merges opId-sorted+deduped.
@MainActor
final class OpLogStorePartitioningTests: XCTestCase {

    private let docId = "d_01HQ7T3JKM2N4P5R6S8VWX0Y2Z"

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oplogpart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        return root
    }

    private func opsDir(_ root: URL) -> URL {
        root.appendingPathComponent(".maugham/ops")
    }

    private func op(_ opId: String, device: String,
                    pid: String = "aaaa", next: String) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: device, session: "s", kind: .typingBurst,
           changes: [Op.ParagraphChange(paragraphId: pid, prior: nil, next: next)],
           sequence: [pid])
    }

    /// Seed a specific file (e.g. the legacy `<docId>.jsonl`) directly.
    private func seed(_ url: URL, _ ops: [Op]) async throws {
        let store = JSONLAppendStore<Op>(
            fileURL: url, dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
        for o in ops { try await store.append(o) }
    }

    func test_append_writesToPerDeviceFile_notShared() async throws {
        let root = try makeProject()
        let store = OpLogStore(projectURL: root)
        try await store.append(op("op-a", device: "Denvers-Mac.local", next: "x"))

        let macSlug = DeviceSlug.make(from: "Denvers-Mac.local")
        let perDevice = opsDir(root).appendingPathComponent("\(docId).\(macSlug).jsonl")
        let shared = opsDir(root).appendingPathComponent("\(docId).jsonl")

        XCTAssertTrue(FileManager.default.fileExists(atPath: perDevice.path),
                      "append must write to the device's own file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path),
                       "append must NOT write to the shared/legacy path")

        // A second device writes to a distinct file.
        try await store.append(op("op-b", device: "phone:D2A1F8B0", next: "y"))
        let phoneSlug = DeviceSlug.make(from: "phone:D2A1F8B0")
        XCTAssertNotEqual(macSlug, phoneSlug)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: opsDir(root).appendingPathComponent("\(docId).\(phoneSlug).jsonl").path))
    }

    func test_load_mergesLegacyAndPerDeviceFiles_sortedAndDeduped() async throws {
        let root = try makeProject()
        // Legacy file (one writer, pre-partitioning history).
        try await seed(opsDir(root).appendingPathComponent("\(docId).jsonl"),
                       [op("op-b", device: "legacy", next: "B")])
        // Two per-device files; op-a duplicated across files to exercise dedup.
        try await seed(opsDir(root).appendingPathComponent("\(docId).maca.jsonl"),
                       [op("op-a", device: "macA", next: "A"),
                        op("op-c", device: "macA", next: "C")])
        try await seed(opsDir(root).appendingPathComponent("\(docId).phoneb.jsonl"),
                       [op("op-a", device: "phoneB", next: "A"),
                        op("op-d", device: "phoneB", next: "D")])

        let merged = try await OpLogStore(projectURL: root).load(docId: docId)
        XCTAssertEqual(merged.map(\.opId), ["op-a", "op-b", "op-c", "op-d"],
                       "merge is opId-sorted and deduped across all files")
    }

    func test_load_backwardCompat_onlyLegacyFile() async throws {
        let root = try makeProject()
        let ops = [op("op-a", device: "d", next: "A"),
                   op("op-b", device: "d", next: "B"),
                   op("op-c", device: "d", next: "C")]
        try await seed(opsDir(root).appendingPathComponent("\(docId).jsonl"), ops)

        let loaded = try await OpLogStore(projectURL: root).load(docId: docId)
        XCTAssertEqual(loaded.map(\.opId), ["op-a", "op-b", "op-c"],
                       "a project with only the legacy file loads exactly as before")
    }

    func test_deriverParity_mergedAcrossFilesEqualsSingleFile() async throws {
        // Same logical ops, two physical layouts → identical derived state.
        let opA = op("op-a", device: "macA", pid: "aaaa", next: "first")
        let opB = op("op-b", device: "phoneB", pid: "aaaa", next: "second") // later opId wins

        let single = Deriver.derive(ops: [opA, opB])

        let root = try makeProject()
        try await seed(opsDir(root).appendingPathComponent("\(docId).maca.jsonl"), [opA])
        try await seed(opsDir(root).appendingPathComponent("\(docId).phoneb.jsonl"), [opB])
        let merged = Deriver.derive(ops: try await OpLogStore(projectURL: root).load(docId: docId))

        XCTAssertEqual(merged, single,
                       "storage layout must not change derivation output")
        XCTAssertEqual(merged.paragraphs["aaaa"], "second")
    }
}
