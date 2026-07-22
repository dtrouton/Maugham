import XCTest
import MaughamCore
@testable import Maugham

/// Harness carries TWO open manuscripts so the project-wide walk (no
/// `document_id`) can be exercised. Records are seeded through
/// `TranslationStore.append`.
@MainActor
final class TranslationStatusToolTests: XCTestCase {

    private struct Harness {
        let projectURL: URL
        let projectId: String
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let doc1: Document
        let doc2: Document
    }

    private func makeHarness() async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TST-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let path1 = "manuscript/c1.md"
        let path2 = "manuscript/c2.md"
        try "Doc one first.\n\nDoc one second."
            .write(to: tmp.appendingPathComponent(path1), atomically: true, encoding: .utf8)
        try "Doc two only."
            .write(to: tmp.appendingPathComponent(path2), atomically: true, encoding: .utf8)

        let items = [
            StructureItem(id: "doc-1", title: "Chapter 1", type: .document, path: path1),
            StructureItem(id: "doc-2", title: "Chapter 2", type: .document, path: path2),
        ]
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: items, research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        let pStore = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        pStore.documentStore = ds

        let doc1 = try await Document.load(
            url: tmp.appendingPathComponent(path1), device: "test", session: "s", presenter: nil)
        ds.register(document: doc1, for: path1)
        let doc2 = try await Document.load(
            url: tmp.appendingPathComponent(path2), device: "test", session: "s", presenter: nil)
        ds.register(document: doc2, for: path2)

        let reg = ProjectRegistry()
        reg.register(url: tmp, store: pStore)

        return Harness(
            projectURL: tmp,
            projectId: ProjectIdentifier.id(for: tmp),
            documentStore: ds,
            registry: reg,
            doc1: doc1, doc2: doc2)
    }

    private func seed(_ h: Harness, doc: Document, paragraphId: String,
                      language: String, text: String) async throws {
        let source = doc.paragraphs[paragraphId] ?? ""
        let record = TranslationRecord(
            paragraphId: paragraphId, language: language,
            text: text, sourceHash: TranslationHash.hash(source), verbatim: false)
        try await TranslationStore.append(
            record, forDocId: doc.docId,
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
            in: h.projectURL)
    }

    private func status(_ h: Harness, _ obj: [String: Any]) async throws -> TranslationStatusTool.Result {
        let data = try JSONSerialization.data(withJSONObject: obj)
        let out = try await TranslationStatusTool.handle(paramsJSON: data, registry: h.registry)
        return try JSONDecoder().decode(TranslationStatusTool.Result.self, from: out)
    }

    // MARK: - single doc, counts across two languages

    func test_translationStatus_singleDoc_multiLanguageCounts() async throws {
        let h = try await makeHarness()
        let ids = h.doc1.sequence
        XCTAssertEqual(ids.count, 2)
        // es: both paragraphs translated → fresh 2, missing 0.
        try await seed(h, doc: h.doc1, paragraphId: ids[0], language: "es", text: "a")
        try await seed(h, doc: h.doc1, paragraphId: ids[1], language: "es", text: "b")
        // fr: only the first paragraph → fresh 1, missing 1.
        try await seed(h, doc: h.doc1, paragraphId: ids[0], language: "fr", text: "c")

        let result = try await status(h, [
            "project_id": h.projectId,
            "document_id": "doc-1"
        ])

        XCTAssertEqual(Set(result.rows.map(\.document_id)), ["doc-1"],
                       "document_id filter restricts to the one doc")
        let byLang = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.language, $0) })
        XCTAssertEqual(byLang["es"]?.fresh, 2)
        XCTAssertEqual(byLang["es"]?.missing, 0)
        XCTAssertEqual(byLang["es"]?.stale, 0)
        XCTAssertEqual(byLang["es"]?.orphans, 0)
        XCTAssertEqual(byLang["fr"]?.fresh, 1)
        XCTAssertEqual(byLang["fr"]?.missing, 1)
        // open_queries lands in Task 5; until then it is 0.
        XCTAssertEqual(byLang["es"]?.open_queries, 0)
        XCTAssertEqual(byLang["fr"]?.open_queries, 0)

        await h.documentStore.close()
    }

    // MARK: - project-wide walk covers every manuscript doc

    func test_translationStatus_projectWide_covers2Docs() async throws {
        let h = try await makeHarness()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0], language: "es", text: "a")
        try await seed(h, doc: h.doc2, paragraphId: h.doc2.sequence[0], language: "es", text: "z")

        let result = try await status(h, [
            "project_id": h.projectId
        ])

        XCTAssertEqual(Set(result.rows.map(\.document_id)), ["doc-1", "doc-2"],
                       "no document_id walks every manuscript doc that has translations")
        let doc1es = result.rows.first { $0.document_id == "doc-1" && $0.language == "es" }
        let doc2es = result.rows.first { $0.document_id == "doc-2" && $0.language == "es" }
        XCTAssertEqual(doc1es?.fresh, 1)
        XCTAssertEqual(doc1es?.missing, 1, "doc-1 has 2 paragraphs, 1 translated")
        XCTAssertEqual(doc2es?.fresh, 1)
        XCTAssertEqual(doc2es?.missing, 0, "doc-2 has 1 paragraph, translated")

        await h.documentStore.close()
    }
}
