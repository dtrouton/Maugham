// MaughamTests/OpLog/LoadBurstLabelTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The load's own bursts say what they are** (signed op log P3b Task 3;
/// handoff ruling 3).
///
/// Three of the emissions a `Document.load` makes are `typingBurst`s — the
/// pending-recovery fold that carries TEXT, its sibling that carries ORDER
/// alone, and the burst that carries the task-anchor splice — and until this
/// task none of them wrote a `synthesisSource`. That is what left them
/// indistinguishable on disk from a person typing, which is why P3a's
/// grandfather (`Permit.isALoadEmission`) could not reach them and why the
/// release census has to look for them by hand.
///
/// The label is **provenance only**. `PermitPartition.writtenOp` decodes a KIND
/// and nothing else, so the field never reaches the permission table from
/// either direction; `PermitTableTests` pins both halves of that. What is
/// pinned here is that each of the three sites actually writes it, and — the
/// sharper half — that the writer's own words never wear the app's label.
@MainActor
final class LoadBurstLabelTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    private func project(
        _ prefix: String, initialMd: String
    ) throws -> (dir: URL, docURL: URL) {
        let made = try makeTestProject(prefix: prefix, initialMd: initialMd)
        roots.append(made.dir)
        return made
    }

    private func pendingFileURL(
        project: URL, docId: String, device: String
    ) -> URL {
        project
            .appendingPathComponent(".maugham/pending")
            .appendingPathComponent(
                "\(docId).\(DeviceSlug.make(from: device).raw).pending.jsonl")
    }

    private func bursts(in project: URL, docId: String) async throws -> [Op] {
        try await OpLogStore(projectURL: project)
            .load(docId: docId)
            .filter { $0.kind == .typingBurst }
    }

    // MARK: - Site 1: the recovery fold that carries text

    /// A session that crashed mid-burst leaves a pending file; the next load
    /// folds it in. That op is the LOAD's, and it now says so.
    func test_theRecoveryFoldSaysItIsTheLoadsOwn() async throws {
        let (project, url) = try project("LBL", initialMd: "Alpha.\n\nBravo.")
        let docId: String
        let ids: [String]
        do {
            let doc = try await Document.load(
                url: url, device: "m", session: "s1", presenter: nil)
            docId = doc.docId
            ids = doc.sequence
            await doc.close()
        }
        // A crashed session's buffer: text the writer typed that never became
        // an op, left on disk exactly as a mid-burst quit leaves it.
        let newest = try await OpLogStore(projectURL: project)
            .load(docId: docId).map(\.opId).max()!
        do {
            let pb = PendingBuffer(projectURL: project, docId: docId, device: "m")
            pb.recordChange(
                paragraphId: ids[0], prior: "Alpha.", next: "Alpha, recovered.")
            pb.setSequence(ids, basis: newest)
            try await pb.flushToDisk()
        }

        let doc = try await Document.load(
            url: url, device: "m", session: "s2", presenter: nil)
        await doc.close()

        let folded = try await bursts(in: project, docId: docId)
            .filter { !$0.changes.isEmpty }
        XCTAssertEqual(folded.count, 1, "the recovery fold, and nothing else")
        XCTAssertEqual(
            folded.first?.provenance?.synthesisSource, .pendingRecovery,
            "the crashed session's buffer is the load's emission, not a person "
            + "typing")
    }

    // MARK: - Site 2: the fold that carries order alone

    func test_theOrderingOnlyRecoveryFoldSaysTheSameThing() async throws {
        let (project, url) = try project(
            "LBL", initialMd: "Alpha.\n\nBravo.\n\nCharlie.")
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
        // Order only: the basis is CURRENT and the order genuinely diverges.
        do {
            let pb = PendingBuffer(projectURL: project, docId: docId, device: "m")
            pb.setSequence([ids[2], ids[0], ids[1]], basis: newest)
            try await pb.flushToDisk()
        }

        let doc = try await Document.load(
            url: url, device: "m", session: "s2", presenter: nil)
        await doc.close()

        let folded = try await bursts(in: project, docId: docId)
            .filter { $0.changes.isEmpty && $0.sequence != nil }
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(
            folded.first?.provenance?.synthesisSource, .pendingRecovery,
            "one cause for both halves of the fold \u{2014} which half survived "
            + "is already legible from `changes`")
    }

    // MARK: - Site 3: the anchor splice, and only when it is alone

    /// Reading the Tasks pane over a document with an inline task mints an
    /// anchor, splices it into the paragraph and records it into the pending
    /// buffer. The burst that carries it is the derivation's own work.
    func test_theAnchorSpliceBurstSaysItIsTheLoadsOwn() async throws {
        let (project, url) = try project(
            "LBL", initialMd: "- [ ] water the plants\n")
        let doc = try await Document.load(
            url: url, device: "m", session: "s1", presenter: nil)
        let docId = doc.docId
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: docId),
            statuses: Set(TaskStatus.allCases)))
        try await doc.flushBurstNow()
        await doc.close()

        let spliced = try await bursts(in: project, docId: docId)
            .filter { !$0.changes.isEmpty }
        XCTAssertEqual(spliced.count, 1, "the splice, and no keystroke")
        XCTAssertTrue(
            spliced.first?.changes.first?.next.contains("<!--t-") == true,
            "it really is the anchor: \(spliced.first?.changes.first?.next ?? "")")
        XCTAssertEqual(
            spliced.first?.provenance?.synthesisSource, .anchorSplice)
    }

    /// **The sharp half, both directions.** A burst that carries the writer's
    /// own words is NEVER labelled, even when an anchor rode out with it —
    /// calling the writer's sentence housekeeping is the one mistake here that
    /// costs something.
    func test_aBurstCarryingTheWritersWordsIsNeverLabelled() async throws {
        let (project, url) = try project(
            "LBL", initialMd: "- [ ] water the plants\n")
        let doc = try await Document.load(
            url: url, device: "m", session: "s1", presenter: nil)
        let docId = doc.docId
        // The writer types FIRST, then the pane is read: the splice arrives
        // into a buffer that is already the writer's.
        doc.setFullText("- [ ] water the plants\n\nAnd a sentence of my own.")
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: docId),
            statuses: Set(TaskStatus.allCases)))
        try await doc.flushBurstNow()
        await doc.close()

        let written = try await bursts(in: project, docId: docId)
            .filter { !$0.changes.isEmpty }
        XCTAssertFalse(written.isEmpty)
        for burst in written {
            XCTAssertNil(
                burst.provenance?.synthesisSource,
                "a burst holding the writer's own words wears no label")
        }
    }

    /// The other order, which is the one the discriminator is really for: the
    /// splice lands in an empty buffer and the writer then types before the
    /// flush. What goes out is both, so it is not the load's.
    func test_typingAfterTheSpliceTakesTheLabelOffAgain() async throws {
        let (project, url) = try project(
            "LBL", initialMd: "- [ ] water the plants\n\nA second paragraph.")
        let doc = try await Document.load(
            url: url, device: "m", session: "s1", presenter: nil)
        let docId = doc.docId
        let second = doc.sequence[1]
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: docId),
            statuses: Set(TaskStatus.allCases)))
        // The writer types AFTER the splice, into the same buffer.
        doc.setParagraph(id: second, text: "A second paragraph, edited.")
        try await doc.flushBurstNow()
        await doc.close()

        let written = try await bursts(in: project, docId: docId)
            .filter { !$0.changes.isEmpty }
        XCTAssertFalse(written.isEmpty)
        for burst in written {
            XCTAssertNil(burst.provenance?.synthesisSource, "\(burst.opId)")
        }
    }

    /// And an ordinary session — no crash, no inline task — writes exactly what
    /// it wrote before: nothing about a one-writer book moves.
    func test_anOrdinaryBurstIsUnchanged() async throws {
        let (project, url) = try project("LBL", initialMd: "Alpha.\n")
        let doc = try await Document.load(
            url: url, device: "m", session: "s1", presenter: nil)
        let docId = doc.docId
        doc.setFullText("Alpha, edited.\n")
        try await doc.flushBurstNow()
        await doc.close()

        let written = try await bursts(in: project, docId: docId)
        XCTAssertFalse(written.isEmpty)
        for burst in written {
            XCTAssertNil(burst.provenance?.synthesisSource, "\(burst.opId)")
        }
    }
}
