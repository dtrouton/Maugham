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
        let projectStore: ProjectStore
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
            projectStore: pStore,
            documentStore: ds,
            registry: reg,
            doc1: doc1, doc2: doc2)
    }

    private func seed(_ h: Harness, doc: Document, paragraphId: String,
                      language: String, text: String, verbatim: Bool = false) async throws {
        let source = doc.paragraphs[paragraphId] ?? ""
        let record = TranslationRecord(
            paragraphId: paragraphId, language: language,
            text: text, sourceHash: TranslationHash.hash(source), verbatim: verbatim)
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

    // MARK: - F8: verbatim count in the row

    func test_translationStatus_verbatimCount() async throws {
        let h = try await makeHarness()
        let ids = h.doc1.sequence
        try await seed(h, doc: h.doc1, paragraphId: ids[0], language: "es",
                       text: h.doc1.paragraphs[ids[0]] ?? "", verbatim: true)
        try await seed(h, doc: h.doc1, paragraphId: ids[1], language: "es", text: "b")

        let result = try await status(h, [
            "project_id": h.projectId,
            "document_id": "doc-1"
        ])
        let byLang = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.language, $0) })
        XCTAssertEqual(byLang["es"]?.verbatim, 1,
                       "one of the two translated paragraphs is verbatim")
        XCTAssertEqual(byLang["es"]?.fresh, 2)

        await h.documentStore.close()
    }

    // MARK: - open_queries counts language-tagged open queries

    func test_translationStatus_countsLanguageTaggedOpenQueries() async throws {
        let h = try await makeHarness()
        let ids = h.doc1.sequence
        // Translate the first paragraph into es and fr so both languages
        // produce a row.
        try await seed(h, doc: h.doc1, paragraphId: ids[0], language: "es", text: "a")
        try await seed(h, doc: h.doc1, paragraphId: ids[0], language: "fr", text: "c")

        // One open query tagged es, one tagged fr, one untagged — only the
        // language-matched ones count toward that language's open_queries.
        try await addQuery(h, doc: h.doc1, paragraphId: ids[0],
                           body: "how formal here?", language: "es")
        try await addQuery(h, doc: h.doc1, paragraphId: ids[1],
                           body: "idiom or literal?", language: "es")
        try await addQuery(h, doc: h.doc1, paragraphId: ids[0],
                           body: "tu or vous?", language: "fr")
        try await addQuery(h, doc: h.doc1, paragraphId: ids[0],
                           body: "plain craft query", language: nil)

        let result = try await status(h, [
            "project_id": h.projectId,
            "document_id": "doc-1"
        ])
        let byLang = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.language, $0) })
        XCTAssertEqual(byLang["es"]?.open_queries, 2,
                       "two es-tagged open queries counted for es")
        XCTAssertEqual(byLang["fr"]?.open_queries, 1,
                       "one fr-tagged open query counted for fr")

        await h.documentStore.close()
    }

    private func addQuery(_ h: Harness, doc: Document, paragraphId: String,
                          body: String, language: String?) async throws {
        var params: [String: Any] = [
            "project_id": h.projectId,
            "document_id": doc.docId,
            "paragraph_id": paragraphId,
            "body": body
        ]
        if let language { params["language"] = language }
        let data = try JSONSerialization.data(withJSONObject: params)
        _ = try await AddQueryTool.handle(paramsJSON: data, registry: h.registry)
    }

    // MARK: - M2: a query-first language (open .query, zero translation files)

    /// A translator can ask a question about a language before any file for
    /// it exists — the "ask first, translate later" workflow the `.query`
    /// `language` tag exists for. Project-wide walk must surface that
    /// language's row even though `TranslationStore.languages` (a filename
    /// scan) never saw it.
    func test_queryOnlyLanguageGetsARow() async throws {
        let h = try await makeHarness()
        let ids = h.doc1.sequence
        // No fr translation records at all — only an open fr-tagged query.
        try await addQuery(h, doc: h.doc1, paragraphId: ids[0],
                           body: "formal register?", language: "fr")

        let result = try await status(h, [
            "project_id": h.projectId
        ])

        let frRow = result.rows.first { $0.document_id == "doc-1" && $0.language == "fr" }
        XCTAssertNotNil(frRow, "a query-only language still gets a row")
        XCTAssertEqual(frRow?.open_queries, 1)
        XCTAssertEqual(frRow?.fresh, 0)
        XCTAssertEqual(frRow?.stale, 0)
        XCTAssertEqual(frRow?.missing, 0,
                       "no file yet — coverage is absent, not 'every paragraph missing'")
        XCTAssertEqual(frRow?.verbatim, 0)
        XCTAssertEqual(frRow?.orphans, 0)

        await h.documentStore.close()
    }

    /// The union must hold on both handler paths — project-wide walk AND the
    /// explicit `document_id` path — since Task 3 touches both.
    func test_bothPathsSeeIt() async throws {
        let h = try await makeHarness()
        let ids = h.doc1.sequence
        try await addQuery(h, doc: h.doc1, paragraphId: ids[0],
                           body: "formal register?", language: "fr")

        let explicit = try await status(h, [
            "project_id": h.projectId,
            "document_id": "doc-1"
        ])
        let projectWide = try await status(h, [
            "project_id": h.projectId
        ])

        for result in [explicit, projectWide] {
            let frRow = result.rows.first { $0.document_id == "doc-1" && $0.language == "fr" }
            XCTAssertNotNil(frRow, "query-only language visible via explicit document_id and project-wide")
            XCTAssertEqual(frRow?.open_queries, 1)
        }

        await h.documentStore.close()
    }

    /// A language with BOTH translation files and open queries gets exactly
    /// one row, with the file-derived coverage and the real open_queries
    /// count — not a second query-only row.
    func test_languageWithFilesAndQueriesNotDoubleCounted() async throws {
        let h = try await makeHarness()
        let ids = h.doc1.sequence
        try await seed(h, doc: h.doc1, paragraphId: ids[0], language: "es", text: "a")
        try await addQuery(h, doc: h.doc1, paragraphId: ids[0],
                           body: "idiom or literal?", language: "es")

        let result = try await status(h, [
            "project_id": h.projectId,
            "document_id": "doc-1"
        ])

        let esRows = result.rows.filter { $0.document_id == "doc-1" && $0.language == "es" }
        XCTAssertEqual(esRows.count, 1, "one row per (document, language), not two")
        XCTAssertEqual(esRows.first?.open_queries, 1)
        XCTAssertEqual(esRows.first?.fresh, 1)
        XCTAssertEqual(esRows.first?.missing, 1, "still the real file-derived coverage")

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

    // MARK: - Task 8: the row names the translator

    /// A stored, renamed `es` role reports the rename — `effectiveName`, not
    /// the preset, once the writer has actually named this person.
    func test_translatorField_reportsAStoredRename() async throws {
        let h = try await makeHarness()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0],
                       language: "es", text: "a")
        let minted = try await h.projectStore.translatorRole(for: "es")
        try await h.projectStore.renameProductionRole(id: minted.id, to: "Alejandra")

        let result = try await status(h, [
            "project_id": h.projectId,
            "document_id": "doc-1"
        ])
        let esRow = result.rows.first { $0.language == "es" }
        XCTAssertEqual(esRow?.translator, "Alejandra")

        await h.documentStore.close()
    }

    /// An unminted `es` with translation files reports the preset name — and
    /// the lookup must NOT mint: the manifest on disk is untouched by asking.
    /// (Task 8's contract: a read tool must not mint; disable experiment is
    /// to route this lookup through `translatorRole(for:)` instead and watch
    /// this assertion fail.)
    func test_translatorField_unmintedPresetLanguage_doesNotMintOnRead() async throws {
        let h = try await makeHarness()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0],
                       language: "es", text: "a")

        let manifestURL = h.projectURL.appendingPathComponent("project.maugham.json")
        let bytesBefore = try Data(contentsOf: manifestURL)

        let result = try await status(h, [
            "project_id": h.projectId,
            "document_id": "doc-1"
        ])
        let esRow = result.rows.first { $0.language == "es" }
        XCTAssertEqual(esRow?.translator, "Cortázar")

        let bytesAfter = try Data(contentsOf: manifestURL)
        XCTAssertEqual(bytesBefore, bytesAfter,
                       "a read tool must not mint a production role")
        XCTAssertTrue(h.projectStore.manifest.productionRoles.isEmpty,
                      "in-memory manifest must also be untouched")

        await h.documentStore.close()
    }

    /// An unlisted, unminted language (no preset, nothing stored) has no
    /// honest name to report — the field is omitted rather than guessed.
    func test_translatorField_unlistedUnmintedLanguage_omitsField() async throws {
        let h = try await makeHarness()
        try await seed(h, doc: h.doc1, paragraphId: h.doc1.sequence[0],
                       language: "xx", text: "a")

        let result = try await status(h, [
            "project_id": h.projectId,
            "document_id": "doc-1"
        ])
        let xxRow = result.rows.first { $0.language == "xx" }
        XCTAssertNotNil(xxRow)
        XCTAssertNil(xxRow?.translator,
                     "unlisted and unminted — nothing honest to report")

        await h.documentStore.close()
    }
}
