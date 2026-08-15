import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class PreviewCompilerTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewCompilerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    func testPreview_doesNotBumpVersion() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()

        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(
            metadata: .init(title: "Pre", author: "X")))
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C1", mode: .prose, displayText: "A."),
                 .init(pieceID: "p2", title: "C2", mode: .prose, displayText: "B.")]
            }
        }
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let result = try await preview.preview(
            format: .pdf, sectionIDs: ["p1"], maxPages: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath))
        // No publications written.
        let pubs = try await PublicationStore(projectURL: tmp).load()
        XCTAssertTrue(pubs.isEmpty)
        // Version still 0.1.
        let cfg = try await configStore.load()
        XCTAssertEqual(cfg?.nextVersion, "0.1")
    }

    /// RULING-7 (fix for M7-PB-010): a preview with no publish config is a
    /// FAILURE and must say so — the Result carries the cause in `errors`, so
    /// the tool renders the failed shape instead of completed-with-empty-path.
    func testPreview_withNoConfigReturnsTheCauseAsAnError() async throws {
        let bare = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewNoConfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] { [] }
        }
        let jobs = CompileJobManager()
        let preview = PreviewCompiler(
            projectURL: bare, astSource: Src(),
            configStore: PublishConfigStore(projectURL: bare),
            jobManager: jobs,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let result = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertFalse(result.errors.isEmpty,
                       "the failure must reach the caller as an error, not as "
                       + "success with an empty path")
        XCTAssertTrue(result.errors.first?.message.contains("config") == true,
                      "and it names the real cause — found: "
                      + String(describing: result.errors.first?.message))
        let job = await jobs.allInProgress()
        XCTAssertTrue(job.isEmpty, "the job is terminal either way")
    }

    // MARK: - F5: EMISSION.md auto-refresh (previews are where iteration lives)

    /// A stale EMISSION.md seeded before a preview is refreshed to the
    /// current contract, stamped with the app version the preview was
    /// constructed with — mirroring `CompileOrchestrator`'s refresh.
    func testPreview_refreshesStaleEmissionDoc() async throws {
        let emissionURL = tmp.appendingPathComponent(".maugham/publish/EMISSION.md")
        try "# STALE from an old init\n".write(to: emissionURL, atomically: true, encoding: .utf8)

        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "PreF5", author: "T")))
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C1", mode: .prose, displayText: "A.")]
            }
        }
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            jobManager: CompileJobManager(),
            maughamVersion: "9.9.9-previewtest", tectonicVersion: "n/a")
        _ = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)

        let refreshed = try String(contentsOf: emissionURL, encoding: .utf8)
        XCTAssertEqual(refreshed, EmissionContract.renderProjectCopy(appVersion: "9.9.9-previewtest"))
        XCTAssertFalse(refreshed.contains("STALE from an old init"))
    }

    // MARK: - F1: default subset vs. explicit override

    struct ThreePieceSrc: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "Alpha", mode: .prose, displayText: "First."),
             .init(pieceID: "p2", title: "Bravo", mode: .prose, displayText: "Middle."),
             .init(pieceID: "p3", title: "Charlie", mode: .prose, displayText: "Third.")]
        }
    }

    private func excludeMiddleConfigStore() async throws -> PublishConfigStore {
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Pre", author: "X"))
        cfg.sections["p2"] = .init(include: false)
        try await configStore.save(cfg)
        return configStore
    }

    /// No `section_ids` ⇒ "all *included* sections": the excluded piece is
    /// dropped from the preview body (EPUB path, no tectonic).
    func testPreview_noSectionIDs_subsetsToIncluded() async throws {
        let configStore = try await excludeMiddleConfigStore()
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: ThreePieceSrc(),
            configStore: configStore, jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        _ = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)

        let body = try String(
            contentsOf: tmp.appendingPathComponent(".maugham/publish/build/body.xhtml"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("data-piece-id=\"p1\""))
        XCTAssertTrue(body.contains("data-piece-id=\"p3\""))
        XCTAssertFalse(body.contains("data-piece-id=\"p2\""),
                       "default preview subset must drop the excluded piece")
    }

    /// Explicit `section_ids` is an exploratory override: it may name an
    /// excluded piece, and preview renders it anyway.
    func testPreview_explicitSectionIDs_overridesExclusion() async throws {
        let configStore = try await excludeMiddleConfigStore()
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: ThreePieceSrc(),
            configStore: configStore, jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        _ = try await preview.preview(format: .epub, sectionIDs: ["p2"], maxPages: nil)

        let body = try String(
            contentsOf: tmp.appendingPathComponent(".maugham/publish/build/body.xhtml"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("data-piece-id=\"p2\""),
                      "explicit section_ids override must render the named excluded piece")
        XCTAssertFalse(body.contains("data-piece-id=\"p1\""),
                       "explicit section_ids is an allowlist — unnamed pieces drop out")
    }

    // MARK: - F2: preview a translated edition (parity with compile)

    private struct LangFixture {
        let store: ProjectStore
        let docID: String
        let doc: Document
        let stores: PublishingStores
        let projectURL: URL
    }

    /// Novel project (publish starter installed), starter doc overwritten with
    /// `content` before its first `Document.load` so Bootstrap mints anchors from
    /// real paragraphs; base + `es` publish config wired. Mirrors the coverage-
    /// gate fixture so preview exercises the SAME ProjectStore substitution path.
    private func makeLangFixture(content: String) async throws -> LangFixture {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "PrevLang-\(UUID().uuidString.prefix(6))", in: tmp)
        let probe = try await ProjectStore.load(from: projectURL)
        let item = try XCTUnwrap(
            ProjectStore.collectDocuments(in: probe.manifest.structure).first)
        let path = try XCTUnwrap(item.path)
        try content.write(
            to: projectURL.appendingPathComponent(path), atomically: true, encoding: .utf8)

        let doc = try await Document.load(
            url: projectURL.appendingPathComponent(path),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: projectURL)

        let pid = ProjectIdentifier.id(for: projectURL)
        PublishingStores._resetForTesting()
        let stores = PublishingStores.sharedFor(projectID: pid, projectURL: projectURL)
        var cfg = try await stores.configStore.load() ?? PublishConfig()
        cfg.metadata.title = "Base"
        cfg.metadata.author = "Auth"
        cfg.metadata.language = "en"
        cfg.languageOverrides = ["es": .init(metadata: ["title": "Título"])]
        try await stores.configStore.save(cfg)

        return LangFixture(
            store: store, docID: item.id, doc: doc, stores: stores, projectURL: projectURL)
    }

    private func translate(
        _ fx: LangFixture, paragraphID: String, text: String, sourceHash: String
    ) async throws {
        try await TranslationStore.append(
            TranslationRecord(paragraphId: paragraphID, language: "es",
                              text: text, sourceHash: sourceHash, verbatim: false),
            forDocId: fx.docID, deviceSlug: DeviceSlug.make(from: "test-mac"),
            in: fx.projectURL)
    }

    private func makeLangPreview(_ fx: LangFixture, allowStale: Bool) -> PreviewCompiler {
        PreviewCompiler(
            projectURL: fx.projectURL,
            astSource: ProjectStoreASTSource(
                projectStore: fx.store, language: "es"),
            configStore: fx.stores.configStore, jobManager: fx.stores.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a",
            language: "es", allowStale: allowStale)
    }

    /// A fully-translated edition previews with the Spanish text substituted
    /// into the body and the ES `dc:language` folded into the OPF — the exact
    /// edition-parity signal that was impossible before F2.
    func testPreview_language_substitutesTranslatedTextAndDcLanguage() async throws {
        let fx = try await makeLangFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        let ids = fx.doc.sequence
        try await translate(fx, paragraphID: ids[0], text: "Primero.",
                            sourceHash: TranslationHash.hash(fx.doc.paragraphs[ids[0]] ?? ""))
        try await translate(fx, paragraphID: ids[1], text: "Segundo.",
                            sourceHash: TranslationHash.hash(fx.doc.paragraphs[ids[1]] ?? ""))

        let result = try await makeLangPreview(fx, allowStale: false)
            .preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(result.errors.isEmpty, "fully-fresh es preview must not gate: \(result.errors)")

        let body = try String(
            contentsOf: fx.projectURL.appendingPathComponent(".maugham/publish/build/body.xhtml"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("Primero."), "translated text must be substituted")
        XCTAssertFalse(body.contains("First paragraph."), "source text must be replaced")

        // The produced preview .epub's OPF carries the folded es dc:language.
        let epubURL = URL(fileURLWithPath: result.outputPath)
        let opf = unzipEntry(epubURL, entry: "OEBPS/content.opf")
        XCTAssertTrue(opf.contains("<dc:language>es</dc:language>"),
                      "effectiveMetadata must fold dc:language into the preview OPF:\n\(opf)")
    }

    private func unzipEntry(_ archive: URL, entry: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-p", archive.path, entry]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Gate parity: a stale/missing edition blocks the preview without
    /// `allow_stale`, itemizing the exact ¶ids — the same report shape compile
    /// returns.
    func testPreview_language_gateBlocksWithoutAllowStale() async throws {
        let fx = try await makeLangFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        let ids = fx.doc.sequence
        // p0 fresh; p1 left missing (no record).
        try await translate(fx, paragraphID: ids[0], text: "Primero.",
                            sourceHash: TranslationHash.hash(fx.doc.paragraphs[ids[0]] ?? ""))

        let result = try await makeLangPreview(fx, allowStale: false)
            .preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertFalse(result.errors.isEmpty, "missing translation must block the preview")
        let message = result.errors.map(\.message).joined(separator: "\n")
        XCTAssertTrue(message.contains("¶\(ids[1])"),
                      "gate error must list the missing ¶id, got: \(message)")
        XCTAssertTrue(message.contains("missing"), message)
    }

    /// The SAME gaps preview clean under `allow_stale`, with the source-text
    /// fallback warnings surfaced.
    func testPreview_language_allowStalePassesWithWarnings() async throws {
        let fx = try await makeLangFixture(content: """
        First paragraph.

        Second paragraph.
        """)
        let ids = fx.doc.sequence
        try await translate(fx, paragraphID: ids[0], text: "Primero.",
                            sourceHash: TranslationHash.hash(fx.doc.paragraphs[ids[0]] ?? ""))

        let result = try await makeLangPreview(fx, allowStale: true)
            .preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(result.errors.isEmpty, "allow_stale must not block: \(result.errors)")
        let message = result.warnings.map(\.message).joined(separator: "\n").lowercased()
        XCTAssertTrue(message.contains("fallback"),
                      "allow_stale preview must itemize source-text fallbacks: \(message)")
    }

    /// Explicit `section_ids` scopes the gate to exactly the previewed pieces.
    /// A two-piece book where A is fully translated and B is an untranslated
    /// stub: a whole-edition es preview blocks (on B), but previewing ONLY A
    /// passes — an exploratory preview of one section isn't blocked by other
    /// untranslated pieces. Previewing ONLY the untranslated B still blocks,
    /// proving explicit ids don't bypass the gate for what they DO render.
    func testPreview_language_explicitSectionScopesGateToRenderedPieces() async throws {
        let fx = try await makeTwoDocLangFixture(
            a: "Alpha paragraph.", b: "Bravo stub paragraph.")
        // Fully translate A; leave B untranslated.
        for id in fx.docA.doc.sequence {
            try await TranslationStore.append(
                TranslationRecord(paragraphId: id, language: "es", text: "Alfa.",
                                  sourceHash: TranslationHash.hash(fx.docA.doc.paragraphs[id] ?? ""),
                                  verbatim: false),
                forDocId: fx.docA.id, deviceSlug: DeviceSlug.make(from: "test-mac"),
                in: fx.projectURL)
        }

        func preview(_ sectionIDs: [String]?) async throws -> PreviewCompiler.Result {
            try await PreviewCompiler(
                projectURL: fx.projectURL,
                astSource: ProjectStoreASTSource(
                    projectStore: fx.store, language: "es"),
                configStore: fx.stores.configStore, jobManager: fx.stores.jobManager,
                maughamVersion: "0.0.0-test", tectonicVersion: "n/a",
                language: "es", allowStale: false
            ).preview(format: .epub, sectionIDs: sectionIDs, maxPages: nil)
        }

        // Whole edition blocks on B.
        let whole = try await preview(nil)
        XCTAssertFalse(whole.errors.isEmpty, "untranslated B must block the whole-edition preview")

        // Preview only A: the untranslated sibling B must not block.
        let onlyA = try await preview([fx.docA.id])
        XCTAssertTrue(onlyA.errors.isEmpty,
                      "previewing only the translated A must not be blocked by B: \(onlyA.errors)")

        // Preview only B: still gates on B's own missing translation.
        let onlyB = try await preview([fx.docB.id])
        XCTAssertFalse(onlyB.errors.isEmpty,
                       "previewing the untranslated B must still gate")
    }

    private struct TwoDocLangFixture {
        let store: ProjectStore
        let docA: (id: String, doc: Document)
        let docB: (id: String, doc: Document)
        let stores: PublishingStores
        let projectURL: URL
    }

    /// Hand-built two-piece novel project (A then B), each loaded through
    /// `Document.load` so Bootstrap mints anchors, wired with a base + `es`
    /// publish config. Mirrors the coverage-gate suite's two-doc fixture.
    private func makeTwoDocLangFixture(a: String, b: String) async throws -> TwoDocLangFixture {
        let projectDir = tmp
            .appendingPathComponent("PrevTwoDoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectDir.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let pathA = "manuscript/a.md"
        let pathB = "manuscript/b.md"
        let idA = "doc-a"
        let idB = "doc-b"
        try a.write(to: projectDir.appendingPathComponent(pathA), atomically: true, encoding: .utf8)
        try b.write(to: projectDir.appendingPathComponent(pathB), atomically: true, encoding: .utf8)

        let itemA = StructureItem(id: idA, title: "A", type: .document, path: pathA)
        let itemB = StructureItem(id: idB, title: "B", type: .document, path: pathB)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [itemA, itemB], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectDir.appendingPathComponent(ProjectManifest.fileName))

        let store = try await ProjectStore.load(from: projectDir)
        let docA = try await Document.load(
            url: projectDir.appendingPathComponent(pathA),
            device: "test", session: "s", presenter: nil)
        let docB = try await Document.load(
            url: projectDir.appendingPathComponent(pathB),
            device: "test", session: "s", presenter: nil)

        let pid = ProjectIdentifier.id(for: projectDir)
        PublishingStores._resetForTesting()
        let stores = PublishingStores.sharedFor(projectID: pid, projectURL: projectDir)
        var cfg = try await stores.configStore.load() ?? PublishConfig()
        cfg.metadata.title = "Base"
        cfg.metadata.author = "Auth"
        cfg.metadata.language = "en"
        cfg.languageOverrides = ["es": .init(metadata: ["title": "Título"])]
        try await stores.configStore.save(cfg)

        return TwoDocLangFixture(
            store: store, docA: (idA, docA), docB: (idB, docB),
            stores: stores, projectURL: projectDir)
    }
    /// The deliberate other half of the occupied-destination refusal: previews
    /// reuse their filenames by design, so a second preview must keep
    /// OVERWRITING its own prior output rather than refusing.
    func testPreview_overwritesItsOwnPriorOutput() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Twice", author: "X")))
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "A.")]
            }
        }
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let one = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(one.errors.isEmpty, "fixture: first preview must succeed")
        let two = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertTrue(two.errors.isEmpty,
                      "a second preview overwrites its own output, never refuses "
                      + "— found: \(two.errors.map { $0.message })")
        XCTAssertEqual(two.outputPath, one.outputPath)
    }

}
