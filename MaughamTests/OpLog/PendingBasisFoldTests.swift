import XCTest
import MaughamCore
@testable import Maugham

/// Issue 2 (2026-07-01) — clean-close leaves no pending file, and the load-time
/// recovery fold is basis-aware so a stale `{sequence, changes: []}` mirror can
/// never reassert an order over peer ops it predates.
///
///  (a) A clean close leaves NO pending file on disk.
///  (b) A peer's delete syncing in while closed, with a stale pending file
///      planted, does NOT revert the delete (empty-changes fold is skipped when
///      the basis is stale).
///  (c) A crash-with-changes whose basis no longer matches the newest op recovers
///      the TEXT but does NOT reassert the (stale) order.
///  (d) A crash-with-changes whose basis still matches recovers the order too
///      (today's behavior).
@MainActor
final class PendingBasisFoldTests: XCTestCase {

    private func pendingFileURL(project: URL, docId: String, device: String) -> URL {
        project
            .appendingPathComponent(".maugham/pending")
            .appendingPathComponent(
                "\(docId).\(DeviceSlug.make(from: device)).pending.jsonl")
    }

    // MARK: - (a) clean quit → no pending file

    func test_cleanClose_leavesNoPendingFile() async throws {
        let (project, url) = try makeTestProject(prefix: "PBF", initialMd: "Alpha.\n\nBravo.")

        let docId: String
        do {
            let doc = try await Document.load(
                url: url, device: "m", session: "s1", presenter: nil)
            docId = doc.docId
            doc.setFullText("Alpha edited.\n\nBravo.")
            await doc.close()
        }

        let pendingURL = pendingFileURL(project: project, docId: docId, device: "m")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pendingURL.path),
            "a clean close must leave no pending file — the burst already persisted the edits as ops")
    }

    // MARK: - (b) peer delete while closed → not reverted by a stale pending file

    func test_peerDeleteWhileClosed_staleEmptyPending_doesNotRevertDelete() async throws {
        let (project, url) = try makeTestProject(
            prefix: "PBF",
            initialMd: "Alpha.\n\nBravo.\n\nCharlie.")

        // Session 1: bootstrap all three, capture ids + the bootstrap opId.
        let docId: String
        let ids: [String]
        do {
            let doc = try await Document.load(
                url: url, device: "m", session: "s1", presenter: nil)
            docId = doc.docId
            ids = doc.sequence
            XCTAssertEqual(ids.count, 3)
            await doc.close()
        }
        let bootstrapOpId = try await OpLogStore(projectURL: project)
            .load(docId: docId).map(\.opId).max()!

        // Plant a stale local pending mirror asserting the FULL pre-delete order,
        // stamped against the bootstrap (the newest op the local device had seen).
        do {
            let pb = PendingBuffer(projectURL: project, docId: docId, device: "m")
            pb.setSequence(ids, basis: bootstrapOpId)
            try await pb.flushToDisk()
        }

        // A PEER deletes Bravo while we were closed: a newer-ULID ordering-only
        // burst on a different device file. Its opId sorts after the bootstrap.
        let peerOpId = ULID.generate()
        let peerOp = """
        {"op_id":"\(peerOpId)","doc_id":"\(docId)","at":"2027-01-01T00:00:00.000Z","device":"peer","session":"p","kind":"typing_burst","changes":[],"sequence":["\(ids[0])","\(ids[2])"]}
        """
        let peerFile = project
            .appendingPathComponent(".maugham/ops")
            .appendingPathComponent("\(docId).peerdev.jsonl")
        try (peerOp + "\n").data(using: .utf8)!.write(to: peerFile)

        // Session 2: reopen. The stale basis (bootstrap != peer) makes the
        // empty-changes fold SKIP, so the peer's delete stands.
        let reopened = try await Document.load(
            url: url, device: "m", session: "s2", presenter: nil)
        XCTAssertEqual(reopened.sequence, [ids[0], ids[2]],
            "a stale empty-changes pending file must not revert a peer's while-closed delete")
        XCTAssertFalse(reopened.sequence.contains(ids[1]),
            "the deleted paragraph must not resurrect")

        // And no recovery op reasserting the full pre-delete order was appended.
        let ops = try await OpLogStore(projectURL: project).load(docId: docId)
        XCTAssertFalse(
            ops.contains { $0.kind == .typingBurst && $0.sequence == ids },
            "no junk recovery op reasserting the stale order")
    }

    // MARK: - (c) crash-with-changes + stale basis → text recovered, order NOT reasserted

    func test_crashWithChanges_staleBasis_recoversTextNotOrder() async throws {
        let (project, url) = try makeTestProject(
            prefix: "PBF",
            initialMd: "Alpha.\n\nBravo.\n\nCharlie.")

        let docId: String
        let ids: [String]
        do {
            let doc = try await Document.load(
                url: url, device: "m", session: "s1", presenter: nil)
            docId = doc.docId
            ids = doc.sequence
            await doc.close()
        }
        let bootstrapOpId = try await OpLogStore(projectURL: project)
            .load(docId: docId).map(\.opId).max()!

        // A PEER reorders to [charlie, bravo, alpha] while we were closed.
        let peerOpId = ULID.generate()
        let peerOrder = [ids[2], ids[1], ids[0]]
        let peerOp = """
        {"op_id":"\(peerOpId)","doc_id":"\(docId)","at":"2027-01-01T00:00:00.000Z","device":"peer","session":"p","kind":"typing_burst","changes":[],"sequence":["\(peerOrder[0])","\(peerOrder[1])","\(peerOrder[2])"]}
        """
        let peerFile = project
            .appendingPathComponent(".maugham/ops")
            .appendingPathComponent("\(docId).peerdev.jsonl")
        try (peerOp + "\n").data(using: .utf8)!.write(to: peerFile)

        // Plant a crash-with-changes pending file: a real text edit to alpha,
        // plus a STALE order (basis = bootstrap, now superseded by the peer op).
        do {
            let pb = PendingBuffer(projectURL: project, docId: docId, device: "m")
            pb.recordChange(paragraphId: ids[0], prior: "Alpha.", next: "Alpha crashed-edit.")
            pb.setSequence(ids, basis: bootstrapOpId)
            try await pb.flushToDisk()
        }

        let reopened = try await Document.load(
            url: url, device: "m", session: "s2", presenter: nil)
        // Text change is recovered.
        XCTAssertEqual(reopened.paragraph(id: ids[0]), "Alpha crashed-edit.",
            "the crashed text edit must be recovered")
        // But the stale order is NOT reasserted — the peer's order carries forward.
        XCTAssertEqual(reopened.sequence, peerOrder,
            "a stale basis must not reassert the pre-peer order")

        // The recovery op carries the text change but NO sequence.
        let ops = try await OpLogStore(projectURL: project).load(docId: docId)
        let recovery = ops.first {
            $0.changes.contains { $0.paragraphId == ids[0] && $0.next == "Alpha crashed-edit." }
        }
        XCTAssertNotNil(recovery, "a recovery op with the text change must exist")
        XCTAssertNil(recovery?.sequence,
            "a stale-basis recovery must attach sequence: nil")
    }

    // MARK: - (d) crash-with-changes + current basis → order recovered (today's behavior)

    func test_crashWithChanges_currentBasis_recoversOrder() async throws {
        let (project, url) = try makeTestProject(
            prefix: "PBF",
            initialMd: "Alpha.\n\nBravo.\n\nCharlie.")

        let docId: String
        let ids: [String]
        do {
            let doc = try await Document.load(
                url: url, device: "m", session: "s1", presenter: nil)
            docId = doc.docId
            ids = doc.sequence
            await doc.close()
        }
        let bootstrapOpId = try await OpLogStore(projectURL: project)
            .load(docId: docId).map(\.opId).max()!

        // No peer op — the local pending order is CURRENT (basis == newest op).
        let reordered = [ids[2], ids[0], ids[1]]
        do {
            let pb = PendingBuffer(projectURL: project, docId: docId, device: "m")
            pb.recordChange(paragraphId: ids[0], prior: "Alpha.", next: "Alpha crashed-edit.")
            pb.setSequence(reordered, basis: bootstrapOpId)
            try await pb.flushToDisk()
        }

        let reopened = try await Document.load(
            url: url, device: "m", session: "s2", presenter: nil)
        XCTAssertEqual(reopened.paragraph(id: ids[0]), "Alpha crashed-edit.")
        XCTAssertEqual(reopened.sequence, reordered,
            "a current basis recovers both text and order (today's behavior)")

        let ops = try await OpLogStore(projectURL: project).load(docId: docId)
        let recovery = ops.first {
            $0.changes.contains { $0.paragraphId == ids[0] && $0.next == "Alpha crashed-edit." }
        }
        XCTAssertEqual(recovery?.sequence, reordered,
            "a current-basis recovery reasserts the pending order")
    }
}
