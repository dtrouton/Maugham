import XCTest
@testable import MaughamCore
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
        let perDevice = opsDir(root).appendingPathComponent("\(docId).\(macSlug.raw).jsonl")
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
            atPath: opsDir(root).appendingPathComponent("\(docId).\(phoneSlug.raw).jsonl").path))
    }

    // RED until M1/M2 — asserts post-fix load-order-independent merge on a
    // DIVERGENT-content same-opId collision across files; see plan 0.2/0.4 +
    // finding 0.4. The old test duplicated op-a with BYTE-IDENTICAL payloads, so
    // the dangerous divergent-content merge path was never exercised: first-wins
    // over a non-stable sort + filesystem-enumeration-order reads is silently
    // load-order-dependent and that was never caught.
    func test_load_mergesAcrossFiles_isDeterministicOnDivergentCollision() async throws {
        // op-a appears in BOTH per-device files with DIFFERENT `next`
        // ("A-macA" vs "A-phoneB") — a genuine divergent-content opId collision.
        let opA_macA = op("op-a", device: "macA", next: "A-macA")
        let opA_phoneB = op("op-a", device: "phoneB", next: "A-phoneB")
        let opB = op("op-b", device: "legacy", next: "B")
        let opC = op("op-c", device: "macA", next: "C")
        let opD = op("op-d", device: "phoneB", next: "D")

        // `contentsOfDirectory` enumeration order is not guaranteed, so the file
        // layout already exercises "either file could be read first." We can't
        // control that order, so we assert determinism two ways:
        //  (1) the loaded result equals a reference computed from an explicit
        //      canonical ordering of the SAME logical ops, and
        //  (2) the reference is itself order-independent — flipping which copy
        //      of op-a comes first in the canonical input yields the same merge.
        let root = try makeProject()
        try await seed(opsDir(root).appendingPathComponent("\(docId).jsonl"), [opB])
        try await seed(opsDir(root).appendingPathComponent("\(docId).maca.jsonl"),
                       [opA_macA, opC])
        try await seed(opsDir(root).appendingPathComponent("\(docId).phoneb.jsonl"),
                       [opA_phoneB, opD])

        let loaded = try await OpLogStore(projectURL: root).load(docId: docId)

        // Dedup + opId-sort across all files still holds.
        XCTAssertEqual(loaded.map(\.opId), ["op-a", "op-b", "op-c", "op-d"],
                       "merge is opId-sorted and deduped across all files")

        // Determinism = LOAD-ORDER INDEPENDENCE. Reference merges of the same
        // logical ops, differing ONLY in which copy of the colliding op-a is
        // seen first, must agree — and `load`'s result (whatever the filesystem
        // enumeration order was) must equal them. We do NOT pin which payload
        // wins; that survivor rule is M2.1's unmade decision.
        let refXY = OpLogStore.mergeSortedDedup([opA_macA, opA_phoneB, opB, opC, opD])
        let refYX = OpLogStore.mergeSortedDedup([opA_phoneB, opA_macA, opB, opC, opD])
        XCTAssertEqual(refXY.first { $0.opId == "op-a" }?.changes.first?.next,
                       refYX.first { $0.opId == "op-a" }?.changes.first?.next,
                       "divergent same-opId collision must resolve the same "
                           + "regardless of input order")
        XCTAssertEqual(loaded.first { $0.opId == "op-a" }?.changes.first?.next,
                       refXY.first { $0.opId == "op-a" }?.changes.first?.next,
                       "load() must be deterministic regardless of which file "
                           + "the OS enumerates first")

        // And the same load-order independence holds for derived state.
        XCTAssertEqual(Deriver.derive(ops: loaded), Deriver.derive(ops: refXY),
                       "storage/enumeration order must not change derived state")
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
