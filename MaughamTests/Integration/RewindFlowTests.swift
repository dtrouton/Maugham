import XCTest
@testable import Maugham

/// Integration tests for `Document.restoreToOp(opId:)` — the time-travel
/// core of milestone-history-rewind. Exercises the full path:
///
///   1. Document loads from disk with a bootstrap op.
///   2. User types more paragraphs, generating typing_burst ops.
///   3. (Optionally) Claude adds an annotation on a soon-to-be-removed
///      paragraph.
///   4. `restoreToOp(opId:)` flushes pending burst, derives target state,
///      appends a `.checkpointRestore` op with `synthesisSource = .rewind`,
///      flags an orphan-annotation sweep with cause `.rewind`, flushes
///      again so the sweep emits, and returns a `RewindRestoreResult`.
///
/// These tests share a small `makeDocument` helper that mirrors the
/// `AnnotationFlowTests` harness — the simplest path that wires up a real
/// project folder, manifest, and `Document.load` so the production
/// load/burst/flush paths run end-to-end.
@MainActor
final class RewindFlowTests: XCTestCase {

    // MARK: - Test harness

    private struct Harness {
        let projectURL: URL
        let documentStore: DocumentStore
        let doc: Document
    }

    private func makeDocument(
        initialMd: String,
        relativePath: String = "manuscript/c1.md"
    ) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaughamRewindTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        try initialMd.write(
            to: tmp.appendingPathComponent(relativePath),
            atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: "doc-x", title: "Chapter 1", type: .document, path: relativePath)
        let manifest = ProjectManifest(
            type: .novel, title: "Rewind Test", author: "A",
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

        return Harness(projectURL: tmp, documentStore: ds, doc: doc)
    }

    // MARK: - Core behaviour

    func test_restoreToPastOp_revertsManuscriptText() async throws {
        let h = try await makeDocument(initialMd: "First paragraph.")
        let doc = h.doc
        let firstLog = try await doc.opLog()
        XCTAssertFalse(firstLog.isEmpty)
        let bootstrapOpId = firstLog[0].opId

        // Extend the manuscript.
        doc.setFullText("First paragraph.\n\nSecond paragraph.\n")
        try await doc.flushBurstNow()

        let result = try await doc.restoreToOp(opId: bootstrapOpId)
        XCTAssertEqual(result.restoreOp?.kind, .checkpointRestore)
        XCTAssertGreaterThan(
            result.priorSequenceCount, result.newSequenceCount,
            "Rewind should shrink the sequence (added p2 should be gone)")
    }

    func test_restoreToPastOp_appendsCheckpointRestoreOpWithRewindSource() async throws {
        let h = try await makeDocument(initialMd: "p1\n\np2\n")
        let doc = h.doc
        let log0 = try await doc.opLog()
        let bootstrapId = log0[0].opId
        doc.setFullText("p1\n\np2\n\np3\n")
        try await doc.flushBurstNow()

        _ = try await doc.restoreToOp(opId: bootstrapId)

        let logAfter = try await doc.opLog()
        let restoreOp = logAfter.last { $0.kind == .checkpointRestore }
        XCTAssertNotNil(restoreOp, "restore should append a checkpoint_restore op")
        XCTAssertEqual(restoreOp?.provenance?.synthesisSource, .rewind)
        XCTAssertEqual(restoreOp?.provenance?.sourceCheckpoint, bootstrapId)
    }

    func test_restoreToPastOp_archivesOrphanAnnotations() async throws {
        let h = try await makeDocument(initialMd: "p1\n\np2\n")
        let doc = h.doc

        // Type a new paragraph that will become an annotation anchor.
        doc.setFullText("p1\n\np2\n\np3 with annotation target\n")
        try await doc.flushBurstNow()

        // Find p3's paragraph id from the typing_burst op.
        let log = try await doc.opLog()
        let burstOp = log.last(where: { $0.kind == .typingBurst })
        guard
            let burstChanges = burstOp?.changes,
            let p3Change = burstChanges.first(where: { $0.next.contains("p3") })
        else {
            return XCTFail("Couldn't find p3 paragraph_id in burst op")
        }
        let p3Id = p3Change.paragraphId

        // Add an annotation anchored to p3.
        _ = try await doc.addAnnotation(
            kind: .comment,
            paragraphId: p3Id,
            body: "Look at this")

        // Rewind to bootstrap — p3 disappears.
        let bootstrapId = log[0].opId
        let result = try await doc.restoreToOp(opId: bootstrapId)

        XCTAssertTrue(result.removedParagraphIds.contains(p3Id),
                      "p3 should be in removedParagraphIds")
        XCTAssertFalse(result.archivedAnnotationOpIds.isEmpty,
                       "Orphan annotation on p3 should have been archived")

        // Every archive op produced by this rewind should carry
        // synthesisSource == .rewind.
        let logFinal = try await doc.opLog()
        let rewindArchives = logFinal.filter {
            $0.kind == .claudeArchive
                && $0.provenance?.synthesisSource == .rewind
        }
        XCTAssertEqual(rewindArchives.count, result.archivedAnnotationOpIds.count)
    }

    func test_restoreToPastOp_preservesAnnotationsOnSurvivingParagraphs() async throws {
        let h = try await makeDocument(initialMd: "p1\n")
        let doc = h.doc

        // Annotate bootstrap p1.
        let log0 = try await doc.opLog()
        let bootstrapChanges = log0[0].changes
        guard let p1Id = bootstrapChanges.first?.paragraphId else {
            return XCTFail("Bootstrap should have at least one paragraph")
        }
        _ = try await doc.addAnnotation(
            kind: .comment,
            paragraphId: p1Id,
            body: "I like this")

        // Add a second paragraph (no annotation on it).
        doc.setFullText("p1\n\np2\n")
        try await doc.flushBurstNow()

        // Rewind. p1 survives; the annotation on it should remain open.
        let bootstrapId = log0[0].opId
        let result = try await doc.restoreToOp(opId: bootstrapId)
        XCTAssertTrue(result.archivedAnnotationOpIds.isEmpty,
                      "Annotation on surviving p1 should remain open")
    }

    func test_restoreFlushesPendingBurstFirst() async throws {
        let h = try await makeDocument(initialMd: "p1\n")
        let doc = h.doc

        let log0 = try await doc.opLog()
        let bootstrapId = log0[0].opId
        let priorCount = log0.count

        // Type without flushing — the burst is in-memory pending.
        doc.setFullText("p1\n\nmid-typing edit\n")
        _ = try await doc.restoreToOp(opId: bootstrapId)

        let logAfter = try await doc.opLog()
        // Slice to ops added by restoreToOp so we're not matching against
        // unrelated bootstrap-era ops with `firstIndex(where:)`.
        let newOps = Array(logAfter.dropFirst(priorCount))
        // The first new op must be the flushed typing burst — proves the
        // pending was flushed BEFORE the restore op was appended.
        XCTAssertEqual(newOps.first?.kind, .typingBurst,
                       "Pending burst must flush before the restore op")
        // A later op must be the .checkpointRestore.
        XCTAssertTrue(newOps.contains { $0.kind == .checkpointRestore })
        // And the typing_burst must precede the checkpointRestore in the slice.
        let burstIdx = newOps.firstIndex { $0.kind == .typingBurst }!
        let restoreIdx = newOps.firstIndex { $0.kind == .checkpointRestore }!
        XCTAssertLessThan(burstIdx, restoreIdx)
    }

    func test_restoreToPastOp_noOp_whenTargetEqualsCurrent_doesNotAppendOp() async throws {
        let h = try await makeDocument(initialMd: "p1\n")
        let doc = h.doc
        try await doc.flushBurstNow()
        let log = try await doc.opLog()
        let latestOpId = log.last!.opId
        let priorLogCount = log.count

        let result = try await doc.restoreToOp(opId: latestOpId)

        XCTAssertNil(result.restoreOp, "No-op restore must not synthesize an op")
        XCTAssertTrue(result.removedParagraphIds.isEmpty)
        XCTAssertEqual(result.priorSequenceCount, result.newSequenceCount)

        // Op log unchanged.
        let logAfter = try await doc.opLog()
        XCTAssertEqual(logAfter.count, priorLogCount,
                       "No-op restore must not extend the op log")
    }

    func test_restoreToPastOp_resultCountsMatchSequenceDeltas() async throws {
        let h = try await makeDocument(initialMd: "p1\n\np2\n")
        let doc = h.doc

        let log0 = try await doc.opLog()
        let bootstrapId = log0[0].opId
        XCTAssertEqual(doc.opLogMirrorCount, 1, "Expect just the bootstrap op")

        // Grow from 2 → 4 paragraphs.
        doc.setFullText("p1\n\np2\n\np3\n\np4\n")
        try await doc.flushBurstNow()

        let result = try await doc.restoreToOp(opId: bootstrapId)
        XCTAssertEqual(result.priorSequenceCount, 4)
        XCTAssertEqual(result.newSequenceCount, 2)
        XCTAssertEqual(result.removedParagraphIds.count, 2)
    }
}
