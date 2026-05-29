import XCTest
import MaughamCore
@testable import Maugham

/// Spec §7.6: every rewind-emitted op carries `synthesisSource == .rewind`.
/// HistoryPane row rendering depends on this; future tools (cross-Mac
/// merge audit, MCP list_history if added) will too.
@MainActor
final class RewindForensicProvenanceTests: XCTestCase {

    private func makeProjectWithDoc() async throws -> (Document, String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaughamForensicTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let item = StructureItem(
            id: "doc-x", title: "M", type: .document, path: "m.md")
        let manifest = ProjectManifest(
            type: .novel, title: "F", author: "",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        try "p1\n".write(
            to: tmp.appendingPathComponent("m.md"),
            atomically: true, encoding: .utf8)

        let ds = try await DocumentStore.open(url: tmp)
        let docURL = tmp.appendingPathComponent("m.md")
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: "m.md")

        return (doc, "doc-x")
    }

    func test_restoreOpCarriesRewindSynthesisSource() async throws {
        let (doc, _) = try await makeProjectWithDoc()
        let initialLog = try await doc.opLog()
        let bootstrapId = initialLog[0].opId
        doc.setFullText("p1\n\np2\n")
        try await doc.flushBurstNow()

        _ = try await doc.restoreToOp(opId: bootstrapId)

        let logAfter = try await doc.opLog()
        let restore = logAfter.first(where: { $0.kind == .checkpointRestore })
        XCTAssertNotNil(restore)
        XCTAssertEqual(restore?.provenance?.synthesisSource, .rewind)
    }

    func test_sweepArchiveOpsCarryRewindSynthesisSource() async throws {
        let (doc, _) = try await makeProjectWithDoc()
        let log0 = try await doc.opLog()
        let bootstrapId = log0[0].opId
        doc.setFullText("p1\n\np2-to-be-annotated\n")
        try await doc.flushBurstNow()
        let logAfterType = try await doc.opLog()
        let p2Id = logAfterType.last(where: { $0.kind == .typingBurst })?
            .changes.first(where: { $0.next.contains("p2") })?.paragraphId
        guard let p2Id else {
            return XCTFail("Couldn't find p2 paragraph_id")
        }
        _ = try await doc.addAnnotation(
            kind: .comment,
            paragraphId: p2Id,
            body: "test")
        try await doc.flushBurstNow()

        _ = try await doc.restoreToOp(opId: bootstrapId)

        let logFinal = try await doc.opLog()
        let archives = logFinal.filter { $0.kind == .claudeArchive }
        XCTAssertTrue(archives.contains {
            $0.provenance?.synthesisSource == .rewind
        })
    }
}
