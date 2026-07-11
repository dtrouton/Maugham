// MaughamTests/OpLog/PendingBufferSequenceTests.swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class PendingBufferSequenceTests: XCTestCase {
    private func tmpProject() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("pb-\(UUID())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// setSequence is durable across flush + reload.
    func test_sequence_roundTripsThroughDisk() async throws {
        let root = tmpProject()
        let a = PendingBuffer(projectURL: root, docId: "doc-1", device: "d")
        a.recordChange(paragraphId: "aaaa", prior: nil, next: "Alpha.")
        a.setSequence(["bbbb", "aaaa"])           // order differs from any op-log default
        try await a.flushToDisk()

        let b = PendingBuffer(projectURL: root, docId: "doc-1", device: "d")
        try await b.loadFromDisk()
        XCTAssertEqual(b.sequence, ["bbbb", "aaaa"])
        XCTAssertEqual(b.snapshot().map(\.paragraphId), ["aaaa"])  // changes intact
    }

    /// Empty by default; clear wipes both.
    func test_sequence_defaultsEmpty_clearWipes() async throws {
        let root = tmpProject()
        let a = PendingBuffer(projectURL: root, docId: "doc-1", device: "d")
        XCTAssertEqual(a.sequence, [])
        a.setSequence(["aaaa"]); a.recordChange(paragraphId: "aaaa", prior: nil, next: "x")
        try await a.clear()
        XCTAssertEqual(a.sequence, [])
        XCTAssertTrue(a.isEmpty())
    }

    /// An old-format JSONL pending file (one JSON object per line, no enclosing
    /// `{ sequence, changes }` wrapper) is abandoned-by-design: it fails to decode
    /// as the new DiskState and is ignored — never folded into recovery.
    func test_oldJsonlPendingFormat_isIgnored() async throws {
        let root = tmpProject()
        // Hand-write a legacy JSONL pending file at this device's path.
        let seed = PendingBuffer(projectURL: root, docId: "doc-1", device: "d")
        seed.recordChange(paragraphId: "aaaa", prior: nil, next: "legacy")
        try await seed.flushToDisk()  // creates the directory + file at the right path
        // Overwrite with the OLD JSONL shape (one bare ParagraphChange per line).
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let line = String(data: try enc.encode(
            Op.ParagraphChange(paragraphId: "aaaa", prior: nil, next: "legacy")),
            encoding: .utf8)!
        let url = root.appendingPathComponent(
            ".maugham/pending/doc-1.\(DeviceSlug.make(from: "d")).pending.jsonl")
        try Data((line + "\n").utf8).write(to: url, options: .atomic)

        let b = PendingBuffer(projectURL: root, docId: "doc-1", device: "d")
        try await b.loadFromDisk()
        XCTAssertTrue(b.isEmpty(), "old JSONL pending must not decode as DiskState")
        XCTAssertEqual(b.sequence, [])
    }
}

/// Crash recovery folds the pending buffer into a real op whose `sequence` comes
/// from the **pending buffer** (durable, op-log-domain) — NOT from the `.md`'s
/// parsed anchor order (ADR 0019). Proven by seeding a pending file whose sequence
/// diverges from the `.md`'s anchor order and asserting the recovered op matches
/// the pending order.
@MainActor
final class CrashRecoveryUsesPendingSequenceTests: XCTestCase {
    func test_recovery_usesPendingSequence_notMdAnchorOrder() async throws {
        let device = "m"
        let (project, url) = try makeTestProject(prefix: "CRPS", initialMd: "Alpha.\n\nBravo.\n")

        // Session 1: open (mints anchors), establish a bursted op-log sequence,
        // and close. `mdOrder` is the in-memory op-log order (doc.sequence),
        // not parsed from the .md.
        let docId: String
        let mdOrder: [String]
        do {
            let doc = try await Document.load(
                url: url, device: device, session: "s1", presenter: nil)
            docId = doc.docId
            mdOrder = doc.sequence            // [alpha, bravo]
            XCTAssertEqual(mdOrder.count, 2)
            doc.setFullText("Alpha edited.\n\nBravo.")
            try await doc.flushBurstNow()     // op log now has a forward-order burst
            await doc.close()
        }

        // ADR 0019: the .md on disk is now CLEAN — it carries NO anchors at all,
        // so recovery provably cannot consult a .md anchor order (there is none).
        // The order under test comes from the pending buffer's sequence below.
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        let parsedOrder = ParagraphParser.parse(onDisk).compactMap(\.id)
        XCTAssertTrue(parsedOrder.isEmpty, "precondition: the on-disk .md is clean (no anchors)")
        XCTAssertFalse(onDisk.contains("<!-- ¶"), "precondition: the on-disk .md is clean (no anchors)")

        // Seed a crash: an un-flushed pending buffer whose sequence is the
        // REVERSE of the .md anchor order. Recovery must honor THIS order.
        let pendingOrder = Array(mdOrder.reversed())
        do {
            let pb = PendingBuffer(projectURL: project, docId: docId, device: device)
            pb.recordChange(paragraphId: mdOrder[0], prior: nil, next: "Alpha reordered.")
            pb.setSequence(pendingOrder)
            try await pb.flushToDisk()
        }

        // Session 2: reopen — crash recovery fires.
        let doc2 = try await Document.load(
            url: url, device: device, session: "s2", presenter: nil)
        _ = doc2

        // The recovery op is the newest typing_burst op (latest ULID).
        let ops = try await OpLogStore(projectURL: project).load(docId: docId)
        let recovered = ops
            .filter { $0.kind == .typingBurst }
            .max(by: { $0.opId < $1.opId })
        XCTAssertNotNil(recovered, "a recovery typing_burst op must exist")
        XCTAssertEqual(recovered?.sequence, pendingOrder,
            "recovery order must come from the pending buffer, not the .md")
        XCTAssertNotEqual(recovered?.sequence, mdOrder,
            "recovery must NOT use the .md's parsed anchor order")
    }
}
