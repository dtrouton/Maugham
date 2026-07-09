import XCTest
import MaughamCore
@testable import Maugham

/// Rewinding past an accepted suggestion must not strand the annotation as
/// `.accepted` while its applied text no longer exists. `restoreToOp` reverts
/// the text (derives from the log prefix) but the `claudeAccept` op survives
/// (append-only), so the annotation would keep deriving `.accepted` and hide
/// in the resolved filter with no visible change. The restore appends a
/// changes-free `claudeAcceptRevert` per stranded accept to reopen it, and
/// reports those creation-op ids in `RewindRestoreResult.reopenedAnnotationOpIds`.
@MainActor
final class RewindReopensAcceptsTests: XCTestCase {

    // MARK: - Harness

    /// Builds a wired Document over `initialMd` and returns it plus its single
    /// bootstrap paragraph id (4-char alphabet-restricted, tripwire 8).
    private func makeDocWithParagraph(_ initialMd: String) async throws -> (Document, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewindReopen-\(UUID().uuidString)")
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
            type: .novel, title: "Rewind Reopen Test", author: "A",
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
        return (doc, pid)
    }

    /// The annotation with `id`, across ALL statuses (`annotations()` defaults
    /// to `.open` only, which would hide an accepted one).
    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    // MARK: - Tests

    func test_rewindPastAccept_reopensAnnotation_andRevertsText() async throws {
        let (doc, pid) = try await makeDocWithParagraph("Original sentence here.")
        // Capture the last op id BEFORE the suggestion+accept — the rewind target.
        let targetOpId = try await doc.opLog().last!.opId

        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Improved sentence here.")
        try await doc.acceptAnnotation(id: annId)
        XCTAssertEqual(doc.paragraph(id: pid), "Improved sentence here.")
        XCTAssertEqual(annotation(doc, annId)?.status, .accepted)

        let result = try await doc.restoreToOp(opId: targetOpId)

        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.")
        XCTAssertEqual(annotation(doc, annId)?.status, .open,
            "an accept whose effect was rewound away must not stay 'accepted'")
        XCTAssertEqual(result.reopenedAnnotationOpIds, [annId])
    }

    func test_rewindRemovingParagraph_archivesStrandedAccept() async throws {
        let (doc, _) = try await makeDocWithParagraph("First paragraph.")
        // Target BEFORE the second paragraph exists — the rewind will remove
        // the paragraph AND strand the accept on it.
        let targetOpId = try await doc.opLog().last!.opId

        doc.setFullText("First paragraph.\n\nSecond paragraph.\n")
        try await doc.flushBurstNow()
        let burst = try await doc.opLog().last(where: { $0.kind == .typingBurst })
        let p2Id = try XCTUnwrap(
            burst?.changes.first(where: { $0.next.contains("Second") })?.paragraphId,
            "couldn't find the second paragraph's id in the burst op")

        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: p2Id,
            body: "b", suggestedText: "Better second paragraph.")
        try await doc.acceptAnnotation(id: annId)
        XCTAssertEqual(annotation(doc, annId)?.status, .accepted)

        let result = try await doc.restoreToOp(opId: targetOpId)

        // The accept's paragraph is gone; reopening would leave an open
        // annotation on a nonexistent paragraph, so it is ARCHIVED instead —
        // the removed-paragraph convention the sweep already establishes.
        XCTAssertEqual(annotation(doc, annId)?.status, .archived,
            "an accept stranded on a rewind-removed paragraph must not stay 'accepted'")
        XCTAssertFalse(result.reopenedAnnotationOpIds.contains(annId),
            "a removed-paragraph accept is archived, never reopened")

        // The archive is reported through the existing archivedAnnotationOpIds
        // contract (archive-op ids, same as the sweep's).
        let archiveOp = try await doc.opLog().last(where: {
            $0.kind == .claudeArchive
                && $0.provenance?.sourceAnnotationId == annId
        })
        let archiveOpId = try XCTUnwrap(archiveOp?.opId,
            "restore must append a claudeArchive for the stranded accept")
        XCTAssertEqual(archiveOp?.provenance?.synthesisSource, .rewind)
        XCTAssertTrue(result.archivedAnnotationOpIds.contains(archiveOpId),
            "the stranded-accept archive must be reported in archivedAnnotationOpIds")
    }

    func test_rewindAfterAccept_leavesAcceptAlone() async throws {
        let (doc, pid) = try await makeDocWithParagraph("Original sentence here.")
        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Improved sentence here.")
        try await doc.acceptAnnotation(id: annId)
        // Type something AFTER the accept, then rewind only past the typing.
        let acceptOpId = try await doc.opLog().last!.opId
        doc.setParagraph(id: pid, text: "Improved sentence here. And more.")
        try await doc.flushBurstNow()

        let result = try await doc.restoreToOp(opId: acceptOpId)

        XCTAssertEqual(doc.paragraph(id: pid), "Improved sentence here.")
        XCTAssertEqual(annotation(doc, annId)?.status, .accepted)
        XCTAssertEqual(result.reopenedAnnotationOpIds, [])
    }
}
