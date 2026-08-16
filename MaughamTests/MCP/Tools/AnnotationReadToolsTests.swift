import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class AnnotationReadToolsTests: XCTestCase {

    private struct Harness {
        let projectURL: URL
        let projectId: String
        let projectStore: ProjectStore
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let doc: Document
        let docPath: String
    }

    private func makeHarness() async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ART-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-read-test"
        try "First paragraph.".write(
            to: tmp.appendingPathComponent(docPath),
            atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: docId, title: "Chapter 1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [item], research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let pStore = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        pStore.documentStore = ds

        let docURL = tmp.appendingPathComponent(docPath)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: docPath)

        let reg = ProjectRegistry()
        reg.register(url: tmp, store: pStore)
        let projectId = ProjectIdentifier.id(for: tmp)

        return Harness(
            projectURL: tmp,
            projectId: projectId,
            projectStore: pStore,
            documentStore: ds,
            registry: reg,
            doc: doc,
            docPath: docPath)
    }

    // MARK: - list_annotations

    func test_listAnnotations_filtersByKindAndStatus() async throws {
        let h = try await makeHarness()

        // Obtain a real paragraph id from the bootstrap op.
        let pid = try await h.doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId

        let commentId = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "comment")
        _ = try await h.doc.addAnnotation(
            kind: .craftNote, paragraphId: nil, body: "craft")
        try await h.doc.archiveAnnotation(id: commentId)

        // Default (open only) — should show only the craftNote.
        let allOpenData = try JSONSerialization.data(
            withJSONObject: [
                "project_id": h.projectId,
                "document_id": h.doc.docId
            ])
        let openResult = try await ListAnnotationsTool.handle(
            paramsJSON: allOpenData, registry: h.registry)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let openList = try dec.decode(
            [ListAnnotationsTool.Item].self, from: openResult)
        XCTAssertEqual(openList.count, 1)
        XCTAssertEqual(openList[0].kind, "craft_note")

        // Filter for archived.
        let archivedData = try JSONSerialization.data(
            withJSONObject: [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "statuses": ["archived"]
            ])
        let archivedResult = try await ListAnnotationsTool.handle(
            paramsJSON: archivedData, registry: h.registry)
        let archivedList = try dec.decode(
            [ListAnnotationsTool.Item].self, from: archivedResult)
        XCTAssertEqual(archivedList.count, 1)
        XCTAssertEqual(archivedList[0].kind, "comment")
        XCTAssertEqual(archivedList[0].status, "archived")

        await h.documentStore.close()
    }

    // MARK: - get_annotation

    func test_getAnnotation_returnsFullRecord() async throws {
        let h = try await makeHarness()

        let pid = try await h.doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId

        let id = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "specific text")

        let data = try JSONSerialization.data(
            withJSONObject: [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
                "annotation_id": id
            ])
        let resultData = try await GetAnnotationTool.handle(
            paramsJSON: data, registry: h.registry)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let result = try dec.decode(
            GetAnnotationTool.Result.self, from: resultData)
        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.body, "specific text")
        XCTAssertEqual(result.status, "open")
        XCTAssertFalse(result.history.isEmpty)  // at least the creation op

        await h.documentStore.close()
    }

    // MARK: - the writer's marks come back (M3 P3 Task 8)

    /// RAW JSON, not the tool's own `Codable` type: decoding through `Item`
    /// cannot tell an OMITTED key from an emitted `null`, and "untriaged" has
    /// to be distinguishable from "this tool does not report triage".
    private func rawArray(_ data: Data) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func rawObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_listAnnotations_reportsTriageAndTheReviewPassStamp() async throws {
        let h = try await makeHarness()
        let pid = try await h.doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId

        let stamped = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "stamped",
            reviewPassId: "line")
        try await h.doc.triageAnnotation(id: stamped, mark: .do)

        let data = try JSONSerialization.data(
            withJSONObject: [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
            ])
        let items = try rawArray(
            try await ListAnnotationsTool.handle(paramsJSON: data, registry: h.registry))
        let item = try XCTUnwrap(items.first { $0["id"] as? String == stamped })
        XCTAssertEqual(item["triage"] as? String, "do")
        XCTAssertEqual(item["review_pass_id"] as? String, "line")
        // **The wire census.** `Item.encode` is hand-written, so a field added
        // to the struct and forgotten in the encoder vanishes with nothing
        // red. This is the shape of an open, triaged, stamped comment — the
        // nil optionals below it use `encodeIfPresent` and are absent by
        // design (`suggested_text`, `user_response`, `resolved_at`).
        XCTAssertEqual(Set(item.keys), [
            "id", "kind", "paragraph_id", "body", "status", "created_at",
            "is_stale", "triage", "review_pass_id",
        ], "get the encoder and this list back in step before changing either")

        await h.documentStore.close()
    }

    /// An untriaged note written before passes existed. Both keys are emitted
    /// carrying JSON `null` — an unstamped note belongs to EVERY pass, which
    /// is a fact a reader has to be able to read off the wire.
    func test_listAnnotations_unstampedUntriagedNoteEmitsBothKeysAsNull() async throws {
        let h = try await makeHarness()
        let pid = try await h.doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId
        let legacy = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "legacy")

        let data = try JSONSerialization.data(
            withJSONObject: [
                "project_id": h.projectId,
                "document_id": h.doc.docId,
            ])
        let items = try rawArray(
            try await ListAnnotationsTool.handle(paramsJSON: data, registry: h.registry))
        let item = try XCTUnwrap(items.first { $0["id"] as? String == legacy })
        XCTAssertTrue(item.keys.contains("triage"),
                      "triage must be emitted as null, not omitted")
        XCTAssertTrue(item["triage"] is NSNull)
        XCTAssertTrue(item.keys.contains("review_pass_id"),
                      "review_pass_id must be emitted as null, not omitted")
        XCTAssertTrue(item["review_pass_id"] is NSNull)

        await h.documentStore.close()
    }

    func test_getAnnotation_agreesWithTheListOnTriageAndPass() async throws {
        let h = try await makeHarness()
        let pid = try await h.doc.opLog()
            .first(where: { $0.kind == .bootstrap })!
            .changes.first!.paragraphId

        let stamped = try await h.doc.addAnnotation(
            kind: .query, paragraphId: pid, body: "q", reviewPassId: "copyedit")
        try await h.doc.triageAnnotation(id: stamped, mark: .discuss)
        let legacy = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "legacy")

        func fetch(_ id: String) async throws -> [String: Any] {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "project_id": h.projectId,
                    "document_id": h.doc.docId,
                    "annotation_id": id,
                ])
            return try rawObject(
                try await GetAnnotationTool.handle(paramsJSON: data, registry: h.registry))
        }

        let marked = try await fetch(stamped)
        XCTAssertEqual(marked["triage"] as? String, "discuss")
        XCTAssertEqual(marked["review_pass_id"] as? String, "copyedit")
        // The census, as above — `Result.encode` is hand-written too. The
        // single-record sibling carries two keys the list has no field for:
        // `history`, and `prior_text`, which an anchored note takes from the
        // paragraph it was written against. The `encodeIfPresent` absentees
        // here are `suggested_text`, `user_response` and `resolved_at`.
        XCTAssertEqual(Set(marked.keys), [
            "id", "kind", "paragraph_id", "body", "prior_text", "status",
            "created_at", "is_stale", "triage", "review_pass_id", "history",
        ], "get the encoder and this list back in step before changing either")

        let bare = try await fetch(legacy)
        XCTAssertTrue(bare.keys.contains("triage"))
        XCTAssertTrue(bare["triage"] is NSNull)
        XCTAssertTrue(bare.keys.contains("review_pass_id"))
        XCTAssertTrue(bare["review_pass_id"] is NSNull)

        await h.documentStore.close()
    }

    /// The P2 staleness the survey caught: `stetted` shipped as a status and
    /// the tool's own description never learned about it.
    func test_bothDescriptions_nameTheStettedStatusAndTheTwoSemantics() {
        XCTAssertTrue(ListAnnotationsTool.description.contains("stetted"))
        XCTAssertTrue(ListAnnotationsTool.description.contains("review_pass_id"))
        for text in [ListAnnotationsTool.description, GetAnnotationTool.description] {
            XCTAssertTrue(text.contains("triage"),
                          "the description must say Claude never sets triage")
        }
    }
}
