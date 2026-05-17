// MaughamTests/OpLog/EndToEndIntegrationTests.swift
import XCTest
@testable import Maugham

@MainActor
final class EndToEndIntegrationTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("E2E-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Full round-trip: two typing bursts → checkpoint → restore.
    ///
    /// After burst 1 + checkpoint, burst 2 mutates "a3f9". A restore op is built
    /// targeting the checkpoint state; after re-derivation the doc should be back
    /// to the burst-1 values for both paragraphs.
    func test_typeBurst_checkpoint_restore_roundTrip() async throws {
        // ── 1. Open store ──────────────────────────────────────────────────────
        let store = try await DocumentStore.open(url: tmp)

        // ── 2. Begin op-log context ────────────────────────────────────────────
        store.beginOpLogContext(docId: "doc-1", device: "m", session: "s")

        // ── 3. Burst 1: two paragraphs ────────────────────────────────────────
        store.recordParagraphChange(paragraphId: "a3f9", prior: nil, next: "First v1.")
        store.recordParagraphChange(paragraphId: "b21c", prior: nil, next: "Second v1.")
        try await store.flushBurstNow()

        // ── 4. Checkpoint after burst 1 ───────────────────────────────────────
        let cp = try await CheckpointCapture.run(
            projectURL: tmp,
            activeDocId: "doc-1",
            allDocIds: ["doc-1"],
            device: "m",
            session: "s",
            label: "draft 1")

        XCTAssertEqual(cp.label, "draft 1")
        XCTAssertNotNil(cp.docPointers["doc-1"],
            "checkpoint must record a pointer for doc-1")

        // ── 5. Burst 2: mutate a3f9 ───────────────────────────────────────────
        store.recordParagraphChange(
            paragraphId: "a3f9", prior: "First v1.", next: "First v2.")
        try await store.flushBurstNow()

        // ── 6. Verify pre-restore state ───────────────────────────────────────
        let opStore = OpLogStore(projectURL: tmp)
        let opsAfterBurst2 = try await opStore.load(docId: "doc-1")
        let currentState = Deriver.derive(ops: opsAfterBurst2)
        XCTAssertEqual(currentState.paragraphs["a3f9"], "First v2.",
            "a3f9 should reflect the burst-2 edit before restore")
        XCTAssertEqual(currentState.paragraphs["b21c"], "Second v1.",
            "b21c should be unchanged")

        // ── 7. Build target state from ops up to (and including) the checkpoint pointer ──
        let cpPointer = try XCTUnwrap(
            cp.docPointers["doc-1"],
            "checkpoint must have a pointer for doc-1")

        // Walk ops in ULID order; keep every op whose op_id is ≤ the checkpoint
        // pointer (ULID sort is lexicographic on a fixed-width Crockford-base32
        // string, which preserves time order).
        let opsAtCheckpoint = opsAfterBurst2.prefix(while: { $0.opId <= cpPointer })
        let targetState = Deriver.derive(ops: Array(opsAtCheckpoint))

        // Sanity: target state should have the v1 text for a3f9.
        XCTAssertEqual(targetState.paragraphs["a3f9"], "First v1.",
            "target state at checkpoint should have burst-1 text for a3f9")
        XCTAssertEqual(targetState.paragraphs["b21c"], "Second v1.",
            "target state at checkpoint should have burst-1 text for b21c")

        // ── 8. Build and append a checkpoint_restore op ───────────────────────
        let restoreOp = try XCTUnwrap(
            Restore.buildRestoreOp(
                current: currentState,
                target: targetState,
                scope: .document,
                docId: "doc-1",
                device: "m",
                session: "s",
                sourceCheckpoint: cp.checkpointId),
            "buildRestoreOp must return a non-nil op when changes are needed")

        XCTAssertEqual(restoreOp.kind, .checkpointRestore)
        try await opStore.append(restoreOp)

        // ── 9. Re-derive and verify restore ───────────────────────────────────
        let opsAfterRestore = try await opStore.load(docId: "doc-1")
        let restoredState = Deriver.derive(ops: opsAfterRestore)

        XCTAssertEqual(restoredState.paragraphs["a3f9"], "First v1.",
            "a3f9 should be restored to the v1 text")
        XCTAssertEqual(restoredState.paragraphs["b21c"], "Second v1.",
            "b21c should remain at the v1 text after restore")
    }
}
