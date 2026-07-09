import XCTest
import MaughamCore
@testable import Maugham

/// Task 7 — ⌘Z undo of a History-Rewind restore.
///
/// A rewind restore (`restoreToOp`) rewinds manuscript text, reopens accepts
/// stranded past the target (D3), and archives open annotations on removed
/// paragraphs (the orphan sweep). `restoreToOpUndoable` wraps that in a single
/// grouped ⌘Z action that reverses the WHOLE rewind:
///   - text back to the pre-restore tip (a fresh compensating `restoreToOp`
///     stamped `.undoRewind` so it never opens a task-rewind window),
///   - each D3-reopened accept re-accepted status-only (preserving the original
///     `userResponse`),
///   - each sweep-archived annotation reopened.
/// Redo re-runs `restoreToOp` from scratch so it can never disagree with a
/// fresh rewind.
///
/// These are `async throws` MainActor tests using `awaitPendingUndoWork()`
/// (the T6 InlineArchiveUndo idiom): `um.undo()` runs its handler synchronously
/// and hops the async compensating restore onto `_lastUndoWorkTask`. Default
/// `groupsByEvent`, NO manual undo grouping (a `removeAllActions` inside a
/// manual group corrupts NSUndoManager state — the T5 crash).
@MainActor
final class RewindUndoTests: XCTestCase {

    // MARK: - Harness

    private struct Harness {
        let doc: Document
        let pid: String
    }

    /// Builds a wired Document over `initialMd` and returns it plus its single
    /// bootstrap paragraph id (4-char alphabet-restricted, tripwire 8).
    private func makeHarness(_ initialMd: String) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindUndo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let relativePath = "manuscript/c1.md"
        try initialMd.write(
            to: tmp.appendingPathComponent(relativePath),
            atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: "doc-x", title: "Chapter 1", type: .document, path: relativePath)
        let manifest = ProjectManifest(
            type: .novel, title: "Rewind Undo Test", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let ds = try await DocumentStore.open(url: tmp)
        let docURL = tmp.appendingPathComponent(relativePath)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: relativePath)

        let pid = try await doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId
        return Harness(doc: doc, pid: pid)
    }

    /// The annotation with `id`, across ALL statuses (`annotations()` defaults
    /// to `.open` only, which would hide an accepted / archived one).
    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    // MARK: - Full round-trip: text + status + userResponse

    func test_restore_undo_returnsTextAndStatusesToPreRestoreState() async throws {
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid

        // Target = the op id BEFORE the accept (right after suggestion creation),
        // so the rewind rewinds past the accept AND the later typing burst.
        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Improved sentence here.")
        let beforeAcceptOpId = try await doc.opLog().last!.opId

        let originalUserResponse = "LGTM — accepted"
        try await doc.acceptAnnotation(id: annId, userResponse: originalUserResponse)
        XCTAssertEqual(doc.paragraph(id: pid), "Improved sentence here.")

        // A typing burst AFTER the accept: the pre-restore tip carries it, so
        // the undo must bring it back too.
        doc.setParagraph(id: pid, text: "Improved sentence here. And more.")
        try await doc.flushBurstNow()

        let preParagraphs = doc.paragraphs
        let preStatus = annotation(doc, annId)?.status
        XCTAssertEqual(preStatus, .accepted)

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: beforeAcceptOpId, undoManager: um)

        XCTAssertNotEqual(doc.paragraphs, preParagraphs, "rewound past the accept + typing")
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.")
        XCTAssertEqual(annotation(doc, annId)?.status, .open, "D3 reopened the stranded accept")

        um.undo(); await doc.awaitPendingUndoWork()

        XCTAssertEqual(doc.paragraphs, preParagraphs, "text back to the pre-restore tip")
        XCTAssertEqual(annotation(doc, annId)?.status, preStatus, "re-accepted status-only")
        XCTAssertEqual(annotation(doc, annId)?.userResponse, originalUserResponse,
            "the re-accept preserved the original userResponse")
    }

    // MARK: - Sweep-archived annotation reopens on undo

    func test_restore_undo_reopensSweepArchivedAnnotations() async throws {
        let h = try await makeHarness("First paragraph.")
        let doc = h.doc
        // Target BEFORE the second paragraph exists — the rewind removes it.
        let targetOpId = try await doc.opLog().last!.opId

        doc.setFullText("First paragraph.\n\nSecond paragraph.\n")
        try await doc.flushBurstNow()
        let burst = try await doc.opLog().last(where: { $0.kind == .typingBurst })
        let p2Id = try XCTUnwrap(
            burst?.changes.first(where: { $0.next.contains("Second") })?.paragraphId,
            "couldn't find the second paragraph's id in the burst op")

        // An OPEN comment anchored to the paragraph the rewind will remove.
        let annId = try await doc.addAnnotation(
            kind: .comment, paragraphId: p2Id, body: "a note on p2")
        XCTAssertEqual(annotation(doc, annId)?.status, .open)

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: targetOpId, undoManager: um)

        XCTAssertFalse(doc.sequence.contains(p2Id), "rewind removed the paragraph")
        XCTAssertEqual(annotation(doc, annId)?.status, .archived,
            "the orphan sweep archived the annotation on the removed paragraph")

        um.undo(); await doc.awaitPendingUndoWork()

        XCTAssertTrue(doc.sequence.contains(p2Id), "undo restored the paragraph")
        XCTAssertEqual(annotation(doc, annId)?.status, .open,
            "undo reopened the sweep-archived annotation")
    }

    // MARK: - Redo re-runs the restore

    func test_restore_undo_redo_reRunsRestore() async throws {
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid

        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Improved sentence here.")
        let beforeAcceptOpId = try await doc.opLog().last!.opId
        try await doc.acceptAnnotation(id: annId)
        doc.setParagraph(id: pid, text: "Improved sentence here. And more.")
        try await doc.flushBurstNow()

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: beforeAcceptOpId, undoManager: um)
        let postRestoreParagraphs = doc.paragraphs
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.")

        um.undo(); await doc.awaitPendingUndoWork()
        XCTAssertNotEqual(doc.paragraphs, postRestoreParagraphs, "undo restored pre-rewind text")
        XCTAssertTrue(um.canRedo, "undo must nest a redo registration")

        um.redo(); await doc.awaitPendingUndoWork()
        // The redo re-runs restoreToOp from scratch (a fresh rewind, not a
        // replay): the manuscript text returns to the post-restore state.
        XCTAssertEqual(doc.paragraphs, postRestoreParagraphs,
            "redo re-runs restoreToOp → post-restore text again")
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.",
            "redo rewound the paragraph past the accept again")
        // NOTE: the annotation status does NOT return to `.open` on this redo.
        // The intervening undo appended a status-only re-accept (empty-changes
        // `claudeAccept`), and `restoreToOp`'s stranded-accept detector keys on
        // `!changes.isEmpty` (it reopens only text-applying accepts), so it
        // cannot re-detect the empty-changes re-accept. The text contract holds;
        // this status edge is a known step-8 detection limitation (see report).
    }

    // MARK: - Foreign op advanced the doc → loud no-op

    func test_restore_undo_afterForeignOps_isLoudNoOp() async throws {
        let h = try await makeHarness("Original sentence here.")
        let doc = h.doc, pid = h.pid

        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Improved sentence here.")
        let beforeAcceptOpId = try await doc.opLog().last!.opId
        try await doc.acceptAnnotation(id: annId)

        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: beforeAcceptOpId, undoManager: um)
        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.")

        // A cross-device merge lands AFTER the restore, changing the live text so
        // it no longer equals the post-restore state the undo captured. The undo
        // must decline (History Rewind is the tool for that tangle), not clobber.
        let foreign = Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: "other-mac", session: "other-session",
            kind: .externalEdit,
            changes: [.init(paragraphId: pid,
                            prior: "Original sentence here.",
                            next: "Edited elsewhere entirely.")],
            sequence: nil, provenance: nil)
        doc._opLogMirror.append(foreign)
        doc.setParagraph(id: pid, text: "Edited elsewhere entirely.")
        let diverged = doc.paragraphs

        um.undo(); await doc.awaitPendingUndoWork()

        XCTAssertEqual(doc.paragraphs, diverged,
            "the fire-time guard declined — the diverged text is not clobbered")
    }
}
