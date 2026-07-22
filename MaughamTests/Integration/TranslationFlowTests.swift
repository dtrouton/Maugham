import XCTest
import MaughamCore
@testable import Maugham

/// Task 16: end-to-end translation flow, driven through the REAL MCP tool
/// handlers wherever the flow allows — the closest automated approximation of
/// the Claude workflow the translation-layer milestone ships.
///
/// The arc, in one test per output format:
///   write_translation (2 real + 1 verbatim) → translation_status all fresh →
///   edit one paragraph (`Document.setParagraph`) → status shows 1 stale →
///   compile the language edition → BLOCKED, error names that exact ¶id →
///   retranslate it → compile succeeds → assert the edition's identity
///   (`Publication.language`, language-suffixed filename, and — EPUB —
///   `dc:language` in the OPF, or — PDF — `\MaughamLanguage` in metadata.tex).
///
/// The EPUB leg is pure Swift (no bundled tectonic) so it always runs; the PDF
/// leg follows the established XCTSkip-if-unbundled pattern.
@MainActor
final class TranslationFlowTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransFlow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - harness

    /// A publish-ready novel project (starter installed via `ProjectFactory`)
    /// whose sole manuscript is overwritten with three real paragraphs BEFORE
    /// its first `Document.load`, so Bootstrap mints anchors from them. The doc
    /// is registered in a `DocumentStore` wired onto the `ProjectStore`, so the
    /// MCP handlers AND the coverage gate all read the SAME live `Document` —
    /// an in-memory `setParagraph` edit is visible to the gate with no flush.
    private struct Harness {
        let projectURL: URL
        let projectId: String
        let documentStore: DocumentStore
        let registry: ProjectRegistry
        let stores: PublishingStores
        let doc: Document
    }

    private func makeHarness() async throws -> Harness {
        let projectURL = try await ProjectFactory.createNovelProject(named: "Flow", in: tmp)

        // Find the starter manuscript and overwrite it before the first load.
        let probe = try await ProjectStore.load(from: projectURL)
        let item = try XCTUnwrap(
            ProjectStore.collectDocuments(in: probe.manifest.structure).first)
        let path = try XCTUnwrap(item.path)
        let docURL = projectURL.appendingPathComponent(path)
        try """
        First paragraph with a **bold** word.

        Second paragraph, plain prose.

        Third paragraph, also plain.
        """.write(to: docURL, atomically: true, encoding: .utf8)

        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        let store = try await ProjectStore.load(from: projectURL)
        let ds = try await DocumentStore.open(url: projectURL)
        store.documentStore = ds
        ds.register(document: doc, for: path)

        let registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)

        let pid = ProjectIdentifier.id(for: projectURL)
        PublishingStores._resetForTesting()
        let stores = PublishingStores.sharedFor(projectID: pid, projectURL: projectURL)

        // Base (source) metadata + a Spanish edition override. The override's
        // title proves the effective-config fold runs; base language is `en`.
        var cfg = try await stores.configStore.load() ?? PublishConfig()
        cfg.metadata.title = "Base Title"
        cfg.metadata.author = "Base Author"
        cfg.metadata.language = "en"
        cfg.languageOverrides = [
            "es": .init(metadata: ["title": "Título ES", "author": "Autor ES"])
        ]
        try await stores.configStore.save(cfg)

        return Harness(
            projectURL: projectURL, projectId: pid,
            documentStore: ds, registry: registry, stores: stores, doc: doc)
    }

    // MARK: - MCP-handler drivers

    private func writeTranslation(
        _ h: Harness, entries: [[String: Any]]
    ) async throws -> WriteTranslationTool.Result {
        let data = try JSONSerialization.data(withJSONObject: [
            "project_id": h.projectId,
            "document_id": h.doc.docId,
            "language": "es",
            "entries": entries
        ])
        let out = try await WriteTranslationTool.handle(paramsJSON: data, registry: h.registry)
        return try JSONDecoder().decode(WriteTranslationTool.Result.self, from: out)
    }

    private func status(_ h: Harness) async throws -> TranslationStatusTool.Result {
        let data = try JSONSerialization.data(withJSONObject: [
            "project_id": h.projectId,
            "document_id": h.doc.docId
        ])
        let out = try await TranslationStatusTool.handle(paramsJSON: data, registry: h.registry)
        return try JSONDecoder().decode(TranslationStatusTool.Result.self, from: out)
    }

    /// Drive the real `compile` MCP handler and return the decoded response
    /// object. EPUB completes synchronously within the default wait; PDF may
    /// too (or the caller guards on tectonic).
    private func compile(
        _ h: Harness, format: String
    ) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: [
            "project_id": h.projectId,
            "format": format,
            "language": "es"
        ])
        let out = try await CompileTool.handle(paramsJSON: data, registry: h.registry)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    private func esRow(_ result: TranslationStatusTool.Result) throws -> TranslationStatusTool.Row {
        try XCTUnwrap(result.rows.first { $0.language == "es" },
                      "status must carry an es row: \(result.rows)")
    }

    /// The shared arc up to (but not including) the final assertions: seed a
    /// full es layer, verify fresh, edit ¶0, verify stale, compile → BLOCKED
    /// naming ¶0, retranslate ¶0 fresh. Returns the harness + the stale ¶id so
    /// each format test finishes with its own success-compile assertions.
    private func runToRetranslated() async throws -> (Harness, String) {
        let h = try await makeHarness()
        let ids = h.doc.sequence
        XCTAssertEqual(ids.count, 3, "fixture must have three paragraphs")

        // write_translation: two real translations + one verbatim → all three
        // paragraphs carry a fresh record.
        let written = try await writeTranslation(h, entries: [
            ["paragraph_id": ids[0], "text": "Primer párrafo con una palabra en **negrita**."],
            ["paragraph_id": ids[1], "text": "Segundo párrafo, prosa simple."],
            ["paragraph_id": ids[2], "verbatim": true]
        ])
        XCTAssertEqual(written.written, 3)
        XCTAssertEqual(written.language, "es")

        // translation_status: everything fresh, nothing stale or missing.
        let fresh = try esRow(try await status(h))
        XCTAssertEqual(fresh.fresh, 3, "all three paragraphs fresh: \(fresh)")
        XCTAssertEqual(fresh.stale, 0)
        XCTAssertEqual(fresh.missing, 0)

        // Edit ¶0 through the op-log path. The record's stamped sourceHash no
        // longer matches the live source, so it becomes stale.
        h.doc.setParagraph(id: ids[0], text: "Primer párrafo, ahora reescrito por completo.")

        let afterEdit = try esRow(try await status(h))
        XCTAssertEqual(afterEdit.stale, 1, "the edited paragraph is now stale: \(afterEdit)")
        XCTAssertEqual(afterEdit.fresh, 2)
        XCTAssertEqual(afterEdit.missing, 0)

        // compile the es edition with the gate armed (allow_stale defaults
        // false): BLOCKED, and the error names the exact stale ¶id.
        let blocked = try await compile(h, format: "epub")
        XCTAssertEqual(blocked["status"] as? String, "failed",
                       "stale gate must block the compile: \(blocked)")
        let errorMessages = ((blocked["errors"] as? [[String: Any]]) ?? [])
            .compactMap { $0["message"] as? String }.joined(separator: "\n")
        XCTAssertTrue(errorMessages.contains("¶\(ids[0])"),
                      "blocked error must name the stale ¶id \(ids[0]): \(errorMessages)")
        XCTAssertTrue(errorMessages.contains("1 stale"), errorMessages)

        // retranslate ¶0 against its NEW source → fresh again.
        let redo = try await writeTranslation(h, entries: [
            ["paragraph_id": ids[0], "text": "Primer párrafo, reescrito y retraducido."]
        ])
        XCTAssertEqual(redo.written, 1)
        let healed = try esRow(try await status(h))
        XCTAssertEqual(healed.stale, 0, "retranslation clears the stale gap: \(healed)")
        XCTAssertEqual(healed.fresh, 3)

        return (h, ids[0])
    }

    // MARK: - EPUB end-to-end (always runs — pure Swift)

    func test_endToEnd_epub_writeStaleGateRetranslatePublish() async throws {
        let (h, _) = try await runToRetranslated()

        let done = try await compile(h, format: "epub")
        XCTAssertEqual(done["status"] as? String, "completed",
                       "post-retranslation compile must succeed: \(done)")
        XCTAssertEqual(done["language"] as? String, "es")
        let outputPath = try XCTUnwrap(done["output_path"] as? String)
        XCTAssertTrue(outputPath.hasSuffix("-es.epub"),
                      "output filename must carry the language: \(outputPath)")

        // Publication.language, asserted on the persisted typed record.
        let pubs = try await h.stores.publicationStore.load()
        let esPub = try XCTUnwrap(pubs.first { $0.language == "es" },
                                  "a Spanish Publication must be recorded: \(pubs)")
        XCTAssertEqual(esPub.language, "es")
        XCTAssertEqual(esPub.outputPath, outputPath)

        // OPF dc:language reflects the Spanish edition.
        let epubURL = h.projectURL.appendingPathComponent(outputPath)
        let opf = try unzipEntry(epubURL, entry: "OEBPS/content.opf")
        XCTAssertTrue(opf.contains("<dc:language>es</dc:language>"),
                      "OPF must declare the Spanish language:\n\(opf)")
    }

    // MARK: - PDF end-to-end (tectonic-gated)

    func test_endToEnd_pdf_gateAndLanguageSuffixedFilename() async throws {
        guard tectonicBundled() else { throw XCTSkip("tectonic missing") }

        let (h, _) = try await runToRetranslated()

        let done = try await compile(h, format: "pdf")
        XCTAssertEqual(done["status"] as? String, "completed",
                       "post-retranslation PDF compile must succeed: \(done)")
        XCTAssertEqual(done["language"] as? String, "es")
        let outputPath = try XCTUnwrap(done["output_path"] as? String)
        XCTAssertTrue(outputPath.hasSuffix("-es.pdf"),
                      "PDF filename must carry the language: \(outputPath)")

        let pubs = try await h.stores.publicationStore.load()
        let esPub = try XCTUnwrap(pubs.first { $0.language == "es" })
        XCTAssertEqual(esPub.language, "es")

        // metadata.tex (written before tectonic runs) carries \MaughamLanguage.
        let metaTex = try String(
            contentsOf: h.projectURL.appendingPathComponent(".maugham/publish/build/metadata.tex"),
            encoding: .utf8)
        XCTAssertTrue(metaTex.contains("\\renewcommand{\\MaughamLanguage}{es}"),
                      "metadata.tex must set the Spanish language:\n\(metaTex)")
    }

    // MARK: - low-level helpers

    private func tectonicBundled() -> Bool {
        let testBundlePath = Bundle(for: TranslationFlowTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        return (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil
    }

    private func unzipEntry(_ archive: URL, entry: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-p", archive.path, entry]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
