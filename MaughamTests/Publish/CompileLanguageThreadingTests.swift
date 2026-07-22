import XCTest
import Foundation
@testable import Maugham

/// Task 7: per-compile `language`/`allow_stale` threading + snapshot fold.
///
/// These drive EPUB compiles (pure Swift — no bundled tectonic needed) and the
/// PDF `metadata.tex` write (which PDFCompiler emits BEFORE it invokes tectonic),
/// so the whole suite runs without the tectonic binary. Each `test_rule*` maps to
/// a numbered rule in `task-7-brief.md`; `test_configSavePin_*` guards the
/// shared-config-not-clobbered invariant.
@MainActor
final class CompileLanguageThreadingTests: XCTestCase {

    var tmp: URL!
    var projectURL: URL!
    var registry: ProjectRegistry!
    var store: ProjectStore!
    var stores: PublishingStores!
    var pid: String!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompileLang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "Lang", in: tmp)
        store = try await ProjectStore.load(from: projectURL)
        registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        pid = ProjectIdentifier.id(for: projectURL)
        PublishingStores._resetForTesting()
        stores = PublishingStores.sharedFor(projectID: pid, projectURL: projectURL)

        // Base (source-language) metadata + a Spanish edition override.
        var cfg = try await stores.configStore.load() ?? PublishConfig()
        cfg.metadata.title = "Base Title"
        cfg.metadata.author = "Base Author"
        cfg.metadata.language = "en"
        cfg.languageOverrides = [
            "es": .init(metadata: ["title": "Título ES", "author": "Autor ES"])
        ]
        try await stores.configStore.save(cfg)
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - helpers

    private func makeOrchestrator() -> CompileOrchestrator {
        CompileOrchestrator(
            projectURL: projectURL,
            astSource: ProjectStoreASTSource(projectStore: store),
            configStore: stores.configStore,
            publicationStore: stores.publicationStore,
            snapshotStore: stores.snapshotStore,
            jobManager: stores.jobManager,
            maughamVersion: "9.9.9",
            tectonicVersion: "0.15.0")
    }

    private func completedPublication(
        _ outcome: CompileOrchestrator.Outcome,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Publication {
        guard case .completed(let pub, _) = outcome else {
            XCTFail("expected completed compile, got \(outcome)", file: file, line: line)
            throw XCTSkip("compile did not complete")
        }
        return pub
    }

    // MARK: - Rule 1: snapshot freezes the language-effective config

    func test_rule1_snapshotFreezesEffectiveConfig() async throws {
        let outcome = try await makeOrchestrator().compile(
            format: .epub, label: nil, language: "es")
        let pub = try completedPublication(outcome)

        let snap = try stores.snapshotStore.load(id: pub.snapshotID)
        // dc:language + the ES override title are baked into the snapshot's
        // config, so Republisher (which reads snap.config) reproduces the
        // Spanish edition with zero further changes.
        XCTAssertEqual(snap.config.metadata.language, "es")
        XCTAssertEqual(snap.config.metadata.title, "Título ES")
        XCTAssertEqual(snap.config.metadata.author, "Autor ES")
    }

    // MARK: - Rule 2: Publication.language carries the tag

    func test_rule2_publicationLanguageSet() async throws {
        let esOutcome = try await makeOrchestrator().compile(
            format: .epub, label: nil, language: "es")
        XCTAssertEqual(try completedPublication(esOutcome).language, "es")
    }

    func test_rule2_publicationLanguageNilForSourceCompile() async throws {
        let outcome = try await makeOrchestrator().compile(
            format: .epub, label: nil, language: nil)
        XCTAssertNil(try completedPublication(outcome).language)
    }

    // MARK: - Rule 3: output filename carries the language

    func test_rule3_filenameContainsLanguage() async throws {
        let outcome = try await makeOrchestrator().compile(
            format: .epub, label: nil, language: "es")
        let pub = try completedPublication(outcome)
        // Default template `{title}-v{version}{label_suffix}.{ext}` has no
        // {language} token, so the builder's collision guard appends `-es`.
        XCTAssertTrue(pub.outputPath.hasSuffix("-es.epub"),
                      "expected language-suffixed filename, got \(pub.outputPath)")
    }

    // MARK: - Rule 4: EPUB dc:language reflects the effective metadata

    func test_rule4_epubOPFDcLanguage() async throws {
        let outcome = try await makeOrchestrator().compile(
            format: .epub, label: nil, language: "es")
        let pub = try completedPublication(outcome)
        let epubURL = projectURL.appendingPathComponent(pub.outputPath)
        let opf = try unzipEntry(epubURL, entry: "OEBPS/content.opf")
        XCTAssertTrue(opf.contains("<dc:language>es</dc:language>"),
                      "OPF missing Spanish dc:language:\n\(opf)")
    }

    // MARK: - Rule 5: PDF build/metadata.tex \renewcommand{\MaughamLanguage}

    func test_rule5_pdfMetadataTexHasMaughamLanguage_es() async throws {
        var cfg = try await stores.configStore.load()!
        cfg.metadata = cfg.effectiveMetadata(language: "es")
        let pdf = try PDFCompiler(
            projectURL: projectURL,
            astSource: ProjectStoreASTSource(projectStore: store),
            config: cfg, jobManager: stores.jobManager,
            maughamVersion: "9.9.9", language: "es")
        // metadata.tex is written before tectonic is invoked; the compile may
        // then throw if tectonic is unavailable — that's fine, we only assert
        // the pre-tectonic artifact.
        _ = try? await pdf.compile(label: nil)

        let metaTex = try metadataTexContents()
        XCTAssertTrue(metaTex.contains("\\renewcommand{\\MaughamLanguage}{es}"),
                      "metadata.tex missing Spanish MaughamLanguage:\n\(metaTex)")
    }

    func test_rule5_pdfMetadataTexDefaultsLanguageToEn() async throws {
        let cfg = try await stores.configStore.load()!
        let pdf = try PDFCompiler(
            projectURL: projectURL,
            astSource: ProjectStoreASTSource(projectStore: store),
            config: cfg, jobManager: stores.jobManager,
            maughamVersion: "9.9.9", language: nil)
        _ = try? await pdf.compile(label: nil)

        let metaTex = try metadataTexContents()
        XCTAssertTrue(metaTex.contains("\\renewcommand{\\MaughamLanguage}{en}"),
                      "metadata.tex missing default MaughamLanguage:\n\(metaTex)")
    }

    // Orchestrator-level companion to the two PDFCompiler-direct tests above:
    // the direct tests prove PDFCompiler writes `\MaughamLanguage` correctly
    // in isolation, but don't prove `CompileOrchestrator.compile` actually
    // threads `language` through to PDFCompiler in the production call path.
    func test_rule5_orchestratorPdfCompile_threadsLanguageToMetadataTexAndFilename() async throws {
        let testBundlePath = Bundle(for: CompileLanguageThreadingTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil else {
            throw XCTSkip("tectonic missing")
        }

        let outcome = try await makeOrchestrator().compile(
            format: .pdf, label: nil, language: "es")
        let pub = try completedPublication(outcome)

        XCTAssertTrue(pub.outputPath.hasSuffix("-es.pdf"),
                      "expected language-suffixed PDF filename, got \(pub.outputPath)")

        let metaTex = try metadataTexContents()
        XCTAssertTrue(metaTex.contains("\\renewcommand{\\MaughamLanguage}{es}"),
                      "metadata.tex missing Spanish MaughamLanguage:\n\(metaTex)")
    }

    // MARK: - config-save pin: a language compile must NOT rewrite the shared config

    func test_configSavePin_languageCompileLeavesBaseMetadataIntactBumpsVersion() async throws {
        let before = try await stores.configStore.load()!
        XCTAssertEqual(before.nextVersion, "0.1")

        _ = try await makeOrchestrator().compile(
            format: .epub, label: nil, language: "es")

        let after = try await stores.configStore.load()!
        // The on-disk config's base metadata is untouched — a Spanish compile
        // must never persist Spanish metadata over the shared config.
        XCTAssertEqual(after.metadata.language, "en")
        XCTAssertEqual(after.metadata.title, "Base Title")
        XCTAssertEqual(after.metadata.author, "Base Author")
        // ...but the version was still bumped.
        XCTAssertEqual(
            after.nextVersion,
            PublishConfigValidator.bumpedNextVersion(from: before.nextVersion))
    }

    // MARK: - MCP validation: invalid language tag rejected

    func test_invalidLanguageTag_rejectedByCompileTool() async throws {
        await XCTAssertThrowsErrorAsync(
            try await CompileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"epub","language":"ES!"}"#.utf8),
                registry: registry)
        ) { error in
            guard case MCPError.invalidArgument = error else {
                XCTFail("expected MCPError.invalidArgument, got \(error)")
                return
            }
        }
    }

    // MARK: - low-level helpers

    private func metadataTexContents() throws -> String {
        let url = projectURL.appendingPathComponent(
            ".maugham/publish/build/metadata.tex")
        return try String(contentsOf: url, encoding: .utf8)
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
