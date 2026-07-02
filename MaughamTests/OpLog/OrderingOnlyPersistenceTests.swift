import XCTest
import MaughamCore
@testable import Maugham

/// F1 — ordering-only edits (paragraph delete / pure reorder) must reach the op
/// log and survive a reload.
///
/// A deletion records NOTHING in the pending buffer (`setFullText` only records
/// changes for paragraphs still present); it only flips the in-memory
/// `_orderingDirty`. Two mechanisms carry that change to durability:
///
///  (a) `flushBurstNow` emits a sequence-only op (`changes: []`, explicit
///      `sequence`) when the pending buffer is empty but `_orderingDirty` is set,
///      so a delete-then-quit lands a real op in the log (this session AND for
///      cross-device sync).
///  (b) `Document.load`'s crash-recovery fold also fires when the pending file
///      carries a non-empty `sequence` that differs from the op-log-derived
///      sequence, even with zero changes — guarded by the difference-check so a
///      clean-quit `{sequence, changes: []}` pending file (the NORMAL post-quit
///      state) does not append a junk op on every launch.
@MainActor
final class OrderingOnlyPersistenceTests: XCTestCase {

    // MARK: - Fixture (mirrors CleanMdWriteTests / CrashRecoveryUsesPendingSequenceTests)

    private func makeProject(initialMd: String) throws -> (URL, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OOP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document,
                path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    // MARK: - (a) live path: delete → close → reload stays deleted

    /// Deleting a paragraph (an ordering-only edit that records nothing in the
    /// pending buffer) then closing must land a sequence-only op in the log, so
    /// a reload derives the post-delete order — the paragraph does NOT resurrect.
    func test_deleteParagraph_thenCloseAndReload_staysDeleted() async throws {
        let (project, path) = try makeProject(
            initialMd: "Alpha.\n\nBravo.\n\nCharlie.")
        let url = project.appendingPathComponent(path)

        let docId: String
        let ids: [String]
        do {
            let doc = try await Document.load(
                url: url, device: "m", session: "s1", presenter: nil)
            docId = doc.docId
            ids = doc.sequence               // [alpha, bravo, charlie]
            XCTAssertEqual(ids.count, 3)

            // Delete the middle paragraph via a full-text set — records NO
            // change in the pending buffer, only flips ordering.
            doc.setFullText("Alpha.\n\nCharlie.")
            XCTAssertEqual(doc.sequence, [ids[0], ids[2]])
            await doc.close()
        }

        // (a) The ordering change reached the op log at close time — a
        // sequence-only typing_burst carrying the post-delete order.
        let ops = try await OpLogStore(projectURL: project).load(docId: docId)
        let orderingBurst = ops.first {
            $0.kind == .typingBurst && $0.sequence == [ids[0], ids[2]]
        }
        XCTAssertNotNil(orderingBurst,
            "close() must emit a sequence-only burst carrying the post-delete order")
        XCTAssertEqual(orderingBurst?.changes.count, 0,
            "an ordering-only burst carries no paragraph changes")

        // (b) A fresh load derives the post-delete state.
        let reopened = try await Document.load(
            url: url, device: "m", session: "s2", presenter: nil)
        XCTAssertEqual(reopened.sequence, [ids[0], ids[2]],
            "the deleted paragraph must not resurrect on reload")
        XCTAssertEqual(reopened.displayText, "Alpha.\n\nCharlie.")
    }

    // MARK: - (b) crash path: pending sequence differs from derived → one fold op

    /// A crash after an ordering-only edit but before the burst flush leaves a
    /// `{sequence, changes: []}` pending file. Load's recovery fold must honor
    /// its sequence (differs from the op-log-derived order) and append exactly
    /// one recovery op.
    func test_deleteParagraph_crashBeforeBurst_recoversFromPendingSequence() async throws {
        let (project, path) = try makeProject(
            initialMd: "Alpha.\n\nBravo.\n\nCharlie.")
        let url = project.appendingPathComponent(path)

        // Session 1: establish a bootstrapped op log with all three paragraphs.
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

        // Simulate a crash mid-delete: the pending file holds the post-delete
        // order [alpha, charlie] with NO recorded changes — exactly what
        // performAutosave's setSequence + flushToDisk leaves after a deletion.
        // Stamp the basis (newest folded opId) the way performAutosave now does,
        // so the load-time fold sees a CURRENT basis and recovers (Issue 2b).
        do {
            let newest = try await OpLogStore(projectURL: project)
                .load(docId: docId).map(\.opId).max()
            let pb = PendingBuffer(projectURL: project, docId: docId, device: "m")
            pb.setSequence([ids[0], ids[2]], basis: newest)
            try await pb.flushToDisk()
        }

        let typingBurstsBefore = try await OpLogStore(projectURL: project)
            .load(docId: docId)
            .filter { $0.kind == .typingBurst }
            .count

        // Session 2: reopen — the crash-recovery fold fires.
        let doc2 = try await Document.load(
            url: url, device: "m", session: "s2", presenter: nil)
        XCTAssertEqual(doc2.sequence, [ids[0], ids[2]],
            "recovery must fold the pending sequence even with zero changes")
        XCTAssertEqual(doc2.displayText, "Alpha.\n\nCharlie.")

        let typingBurstsAfter = try await OpLogStore(projectURL: project)
            .load(docId: docId)
            .filter { $0.kind == .typingBurst }
            .count
        XCTAssertEqual(typingBurstsAfter, typingBurstsBefore + 1,
            "recovery must append exactly one ordering-only op")
    }

    // MARK: - (b) guard: clean quit whose pending sequence matches → no junk op

    /// The difference-check guard: after a normal edit + close the pending file
    /// carries `{sequence, changes: []}` whose sequence EQUALS the derived order.
    /// A reload must NOT append a junk recovery op.
    func test_cleanQuit_pendingSequenceMatchesDerived_noJunkRecoveryOp() async throws {
        let (project, path) = try makeProject(initialMd: "Alpha.\n\nBravo.")
        let url = project.appendingPathComponent(path)

        let docId: String
        do {
            let doc = try await Document.load(
                url: url, device: "m", session: "s1", presenter: nil)
            docId = doc.docId
            doc.setFullText("Alpha edited.\n\nBravo.")
            await doc.close()
        }

        let opsBefore = try await OpLogStore(projectURL: project).load(docId: docId)

        // Reload — the pending file's sequence matches the derived order, so the
        // fold must not fire.
        let reopened = try await Document.load(
            url: url, device: "m", session: "s2", presenter: nil)
        _ = reopened

        let opsAfter = try await OpLogStore(projectURL: project).load(docId: docId)
        XCTAssertEqual(opsAfter.count, opsBefore.count,
            "a clean-quit pending file whose sequence matches derived must not append a recovery op")
    }

    // MARK: - Issue 1: an UNTOUCHED open/close appends NO op

    /// Loading a doc and closing it with ZERO edits must append nothing. The
    /// ordering-only burst arm is gated on a REAL ordering change since load
    /// (`_orderingChangedSinceLoad`), not on `_orderingDirty`'s init-true keyframe
    /// flag — otherwise every transient Document load (MCP annotation reads, task
    /// reads, wiki-rename, search-replace, binder navigation) would append a junk
    /// `{changes: [], sequence}` op whose newest-ULID sequence could revert a
    /// peer's not-yet-synced delete.
    func test_openThenCloseZeroEdits_appendsNoOp() async throws {
        let (project, path) = try makeProject(initialMd: "Alpha.\n\nBravo.")
        let url = project.appendingPathComponent(path)

        let docId: String
        let afterBootstrap: Int
        do {
            let doc = try await Document.load(
                url: url, device: "m", session: "s1", presenter: nil)
            docId = doc.docId
            afterBootstrap = try await OpLogStore(projectURL: project)
                .load(docId: docId).count
            await doc.close()
        }
        let afterClose = try await OpLogStore(projectURL: project)
            .load(docId: docId).count
        XCTAssertEqual(afterClose, afterBootstrap,
            "an untouched open/close must not append any op")
    }

    /// The MCP read-annotation shape: a transient load → (read-only body) → close
    /// against an already-bootstrapped doc must append nothing.
    func test_transientReadOnlyReload_appendsNothing() async throws {
        let (project, path) = try makeProject(initialMd: "Alpha.\n\nBravo.")
        let url = project.appendingPathComponent(path)

        let docId: String
        do {
            let doc = try await Document.load(
                url: url, device: "m", session: "s1", presenter: nil)
            docId = doc.docId
            await doc.close()
        }
        let before = try await OpLogStore(projectURL: project)
            .load(docId: docId).count

        // Transient reopen with the MCP device id — mirrors withAnnotationDocument's
        // load → body → close, with a read-only body (no edits).
        do {
            let doc = try await Document.load(
                url: url, device: "mcp", session: "mcp-1", presenter: nil)
            await doc.close()
        }

        let after = try await OpLogStore(projectURL: project)
            .load(docId: docId).count
        XCTAssertEqual(after, before,
            "a transient read-only load+close must append nothing")
    }
}

/// Deriver pin: an empty-changes `typingBurst` carrying an explicit `sequence`
/// is an ordering-only op and MUST be honored. The 2b926fc junk-skip is
/// `.bootstrap`-kind-only — extending it to typingBurst would silently drop the
/// F1 sequence-only bursts.
final class EmptyChangesBurstDeriverTests: XCTestCase {
    func test_emptyChangesTypingBurst_sequenceHonoredByDeriver() {
        let bootstrap = Op(
            opId: "01AAAA", docId: "doc-1", at: Date(), device: "m", session: "s",
            kind: .bootstrap,
            changes: [
                .init(paragraphId: "aaaa", prior: nil, next: "Alpha."),
                .init(paragraphId: "bbbb", prior: nil, next: "Bravo."),
                .init(paragraphId: "cccc", prior: nil, next: "Charlie."),
            ],
            sequence: ["aaaa", "bbbb", "cccc"])
        // Ordering-only burst: bravo removed from the order, no changes.
        let orderingOnly = Op(
            opId: "01BBBB", docId: "doc-1", at: Date(), device: "m", session: "s",
            kind: .typingBurst,
            changes: [],
            sequence: ["aaaa", "cccc"])

        let derived = Deriver.derive(ops: [bootstrap, orderingOnly])
        XCTAssertEqual(derived.sequence, ["aaaa", "cccc"],
            "an empty-changes typing_burst with a sequence must update the order")

        let fallback = Deriver.deriveWithSequenceFallback(ops: [bootstrap, orderingOnly])
        XCTAssertEqual(fallback.sequence, ["aaaa", "cccc"],
            "deriveWithSequenceFallback must also honor an empty-changes ordering burst")
    }
}
