import XCTest
import MaughamCore
@testable import Maugham

/// Harness mirrors `WriteTranslationToolTests`: a project on disk with one
/// two-paragraph manuscript, an open `Document`, and a `ProjectRegistry`.
/// Translation records are seeded directly through `TranslationStore.append`
/// so a record can be forced `stale` (wrong source hash) without editing the
/// manuscript.
@MainActor
final class ReadTranslationToolTests: XCTestCase {

    private struct Harness {
        let projectURL: URL
        let projectId: String
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let doc: Document
    }

    private func makeHarness() async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RTT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        try "First paragraph.\n\nSecond paragraph."
            .write(to: tmp.appendingPathComponent(docPath),
                   atomically: true, encoding: .utf8)

        let item = StructureItem(
            id: "doc-rt-test", title: "Chapter 1", type: .document, path: docPath)
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

        return Harness(
            projectURL: tmp,
            projectId: ProjectIdentifier.id(for: tmp),
            documentStore: ds,
            registry: reg,
            doc: doc)
    }

    /// Appends a record for `paragraphId` in `language`, with a source hash that
    /// either matches the current source (fresh) or is deliberately wrong (stale).
    private func seed(_ h: Harness, paragraphId: String, language: String,
                      text: String, fresh: Bool) async throws {
        let source = h.doc.paragraphs[paragraphId] ?? ""
        let hash = fresh ? TranslationHash.hash(source) : "0000000000000000"
        let record = TranslationRecord(
            paragraphId: paragraphId, language: language,
            text: text, sourceHash: hash, verbatim: false)
        try await TranslationStore.append(
            record, forDocId: h.doc.docId,
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current),
            in: h.projectURL)
    }

    private func read(_ h: Harness, _ obj: [String: Any]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try await ReadTranslationTool.handle(paramsJSON: data, registry: h.registry)
    }

    private func decode(_ data: Data) throws -> ReadTranslationTool.Result {
        try JSONDecoder().decode(ReadTranslationTool.Result.self, from: data)
    }

    // MARK: - Unfiltered read returns every paragraph in sequence order

    func test_readTranslation_unfilteredReturnsAllInSequenceOrder() async throws {
        let h = try await makeHarness()
        let ids = h.doc.sequence
        XCTAssertEqual(ids.count, 2)
        try await seed(h, paragraphId: ids[0], language: "es", text: "Primero", fresh: true)
        try await seed(h, paragraphId: ids[1], language: "es", text: "Segundo", fresh: true)

        let result = try decode(try await read(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es"
        ]))

        XCTAssertEqual(result.language, "es")
        XCTAssertEqual(result.orphan_count, 0)
        XCTAssertEqual(result.entries.map(\.paragraph_id), ids,
                       "entries must be in authoritative sequence order")
        XCTAssertEqual(result.entries.map(\.status), ["fresh", "fresh"])
        XCTAssertEqual(result.entries[0].translated_text, "Primero")
        XCTAssertEqual(result.entries[1].translated_text, "Segundo")

        await h.documentStore.close()
    }

    // MARK: - I2: source_text is anchor-free

    func test_readTranslation_sourceTextStripsInlineTaskAnchors() async throws {
        let h = try await makeHarness()
        let pid = h.doc.sequence[0]
        // Give the paragraph a checkbox, then read tasks to mint the inline
        // task anchor into the live paragraph text (the DocumentTaskAnchorPersist
        // idiom).
        h.doc.setParagraph(id: pid, text: "- [ ] buy milk")
        _ = h.doc.tasks(filter: TaskFilter(
            scope: .document(docId: h.doc.docId),
            statuses: Set(TaskStatus.allCases)))
        // Setup precondition: the live source now carries an anchor.
        XCTAssertTrue(h.doc.paragraph(id: pid)!.contains("<!--t-"),
            "setup must produce an anchored source paragraph")

        try await seed(h, paragraphId: pid, language: "es", text: "comprar leche", fresh: false)

        let result = try decode(try await read(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es"
        ]))
        let entry = result.entries.first { $0.paragraph_id == pid }!
        XCTAssertFalse(entry.source_text.contains("<!--t-"),
            "read_translation must strip inline task anchors from source_text so " +
            "Claude never echoes a marker into a translation (got: \(entry.source_text))")

        await h.documentStore.close()
    }

    // MARK: - status filter narrows to matching entries only

    func test_readTranslation_statusFilterReturnsOnlyStale() async throws {
        let h = try await makeHarness()
        let ids = h.doc.sequence
        try await seed(h, paragraphId: ids[0], language: "es", text: "Primero", fresh: true)
        try await seed(h, paragraphId: ids[1], language: "es", text: "Segundo", fresh: false)

        let result = try decode(try await read(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "status": "stale"
        ]))

        XCTAssertEqual(result.entries.count, 1, "only the stale paragraph should pass the filter")
        XCTAssertEqual(result.entries[0].paragraph_id, ids[1])
        XCTAssertEqual(result.entries[0].status, "stale")

        await h.documentStore.close()
    }

    // MARK: - unknown language is not an error — every paragraph reads as missing

    func test_readTranslation_unknownLanguageAllMissing() async throws {
        let h = try await makeHarness()
        let ids = h.doc.sequence

        let result = try decode(try await read(h, [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "de"
        ]))

        XCTAssertEqual(result.language, "de")
        XCTAssertEqual(result.entries.count, ids.count)
        XCTAssertTrue(result.entries.allSatisfy { $0.status == "missing" },
                      "a language with no records reads as all-missing, not an error")
        XCTAssertTrue(result.entries.allSatisfy { $0.translated_text == nil })
        XCTAssertEqual(result.orphan_count, 0)

        await h.documentStore.close()
    }
}
