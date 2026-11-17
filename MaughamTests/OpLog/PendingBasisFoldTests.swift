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
                "\(docId).\(DeviceSlug.make(from: device).raw).pending.jsonl")
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

    /// #143 Q2: an autosave that lands while `close()` seals re-creates the
    /// `{sequence, changes: []}` mirror; the clean clear must still win.
    func test_anAutosaveArrivingDuringTheSealsLeavesNoPendingFileAfterAClose() async throws {
        let (project, url) = try makeTestProject(prefix: "PBF", initialMd: "Alpha.\n\nBravo.")
        let doc = try await Document.load(
            url: url, device: "m", session: "s1", presenter: nil)
        let pendingURL = pendingFileURL(project: project, docId: doc.docId, device: "m")
        doc.setFullText("Alpha edited.\n\nBravo.")
        var mirrorRecreated = false
        doc.closeWillFinishForTesting = { [unowned doc] in
            try? await doc.performAutosave()
            mirrorRecreated = FileManager.default.fileExists(atPath: pendingURL.path)
        }
        await doc.close()

        XCTAssertTrue(mirrorRecreated, "premise: the late autosave wrote the pending mirror")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pendingURL.path),
            "a clean close must leave no pending file, even when an autosave lands during the seals")
    }

    /// #146 (F4): a close that finishes late must not delete the recovery file
    /// of the same document reopened meanwhile. The clean clear removes the
    /// file only when it still holds the bytes THIS instance last wrote.
    func test_aLateCloseLeavesTheReopenedDocumentsPendingFileInPlace() async throws {
        let (project, url) = try makeTestProject(prefix: "PBF", initialMd: "Alpha.\n\nBravo.")
        let first = try await Document.load(
            url: url, device: "m", session: "s1", presenter: nil)
        let pendingURL = pendingFileURL(project: project, docId: first.docId, device: "m")
        first.setFullText("Alpha edited.\n\nBravo.")
        try await first.performAutosave()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path),
            "premise: the first instance wrote its pending file")

        var second: Document?
        var secondsBytes: Data?
        first.closeWillFinishForTesting = {
            let reopened = try? await Document.load(
                url: url, device: "m", session: "s2", presenter: nil)
            reopened?.setFullText("Alpha edited again.\n\nBravo.")
            try? await reopened?.performAutosave()
            secondsBytes = try? Data(contentsOf: pendingURL)
            second = reopened
        }
        await first.close()

        XCTAssertNotNil(second, "premise: the reopen loaded while the first close was held")
        XCTAssertNotNil(secondsBytes, "premise: the reopened instance wrote its pending file")
        XCTAssertEqual(try? Data(contentsOf: pendingURL), secondsBytes,
            "the late close must leave the reopened document's pending file, with its bytes, in place")

        // The reopened instance's own clean close still clears its file.
        await second?.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path),
            "the reopened instance's clean close leaves no pending file")
    }

    /// M9-OL-019 under compare-and-clear: a single clean close after an
    /// autosave wrote the pending file still leaves none.
    func test_aCleanCloseAfterAnAutosaveWroteThePendingFileLeavesNone() async throws {
        let (project, url) = try makeTestProject(prefix: "PBF", initialMd: "Alpha.\n\nBravo.")
        let doc = try await Document.load(
            url: url, device: "m", session: "s1", presenter: nil)
        let pendingURL = pendingFileURL(project: project, docId: doc.docId, device: "m")
        doc.setFullText("Alpha edited.\n\nBravo.")
        try await doc.performAutosave()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path),
            "premise: the autosave wrote the pending file")
        await doc.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path),
            "a clean close leaves no pending file")
    }

    /// A current, clean mirror the load read but did not fold (its order equals
    /// the derived one) is this instance's too: a close with no typing clears it.
    func test_aCleanCloseClearsAMirrorTheLoadReadAndDidNotFold() async throws {
        let (project, url) = try makeTestProject(prefix: "PBF", initialMd: "Alpha.\n\nBravo.")
        let docId: String
        let ids: [String]
        do {
            let doc = try await Document.load(
                url: url, device: "m", session: "s1", presenter: nil)
            docId = doc.docId
            ids = doc.sequence
            await doc.close()
        }
        let newest = try await OpLogStore(projectURL: project)
            .load(docId: docId).map(\.opId).max()!
        let pendingURL = pendingFileURL(project: project, docId: docId, device: "m")
        do {
            let pb = PendingBuffer(projectURL: project, docId: docId, device: "m")
            pb.setSequence(ids, basis: newest)
            try await pb.flushToDisk()
        }

        let reopened = try await Document.load(
            url: url, device: "m", session: "s2", presenter: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingURL.path),
            "premise: the load read the mirror and did not fold or clear it")
        await reopened.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingURL.path),
            "a clean close clears the mirror its own load read")
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
