import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// Report foundations plan 2, Task 7: the publish problems the resolution pass
/// finds become gate decisions and diagnostics. A Report's versioned compile
/// or republish refuses on an error before its version is minted; every other
/// book, and every preview, carries them as warnings (R-P2-1); `dry_run` lists
/// them; each diagnostic names its piece's file, the piece and the paragraph;
/// and the compiler emits with the resolution the gate judged.
///
/// Every compile here is an EPUB: pure Swift, no tectonic.
@MainActor
final class PublishProblemGateTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = TestTemp.root.appendingPathComponent("ProblemGate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        let research = tmp.flatMap { FileManager.default.enumerator(atPath: $0.path) }
        while let path = research?.nextObject() as? String {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: tmp.appendingPathComponent(path).path)
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture

    private struct Fixture {
        let store: ProjectStore
        let stores: PublishingStores
        let pieceID: String
        let path: String
        let url: URL
    }

    private static func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// A one-chapter project whose chapter reads `text`, written before its
    /// first load so Bootstrap mints the anchors; a Report when `report`.
    /// `{up}` in `text` is the chapter's way up to the project root.
    private func makeProject(report: Bool, text: String) async throws -> Fixture {
        let url = try await ProjectFactory.createNovelProject(
            named: "Gate-\(UUID().uuidString.prefix(6))", in: tmp)
        let store = try await ProjectStore.load(from: url)
        if report { store.manifest.profile = .report }
        store.manifest.research.append(ResearchItem(
            id: "r-smith", title: "Annual Report", type: .asset,
            citation: CitationInfo(key: "smith2026", authors: ["Smith, Jane"],
                                   sourceTitle: "Annual Report", year: 2026)))
        try await store.saveManifest()
        let research = url.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        try Self.png().write(to: research.appendingPathComponent("chart.png"))

        let item = try XCTUnwrap(ProjectStore.collectDocuments(in: store.manifest.structure).first)
        let path = try XCTUnwrap(item.path)
        let up = String(repeating: "../", count: path.split(separator: "/").count - 1)
        let docURL = url.appendingPathComponent(path)
        try text.replacingOccurrences(of: "{up}", with: up)
            .write(to: docURL, atomically: true, encoding: .utf8)
        let doc = try await Document.load(url: docURL, actor: .author, session: "gate", presenter: nil)
        await doc.close()

        PublishingStores._resetForTesting()
        let stores = PublishingStores.sharedFor(projectID: ProjectIdentifier.id(for: url), projectURL: url)
        var cfg = try await stores.configStore.load() ?? PublishConfig()
        cfg.metadata.title = "Gate"
        cfg.metadata.author = "Tester"
        try await stores.configStore.save(cfg)
        return Fixture(store: store, stores: stores, pieceID: item.id, path: path, url: url)
    }

    private func orchestrator(_ fx: Fixture) -> CompileOrchestrator {
        CompileOrchestrator(
            projectURL: fx.url, astSource: ProjectStoreASTSource(projectStore: fx.store),
            configStore: fx.stores.configStore, publicationStore: fx.stores.publicationStore,
            snapshotStore: fx.stores.snapshotStore, jobManager: fx.stores.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
    }

    private func republisher(_ fx: Fixture) -> Republisher {
        Republisher(
            projectURL: fx.url, astSource: ProjectStoreASTSource(projectStore: fx.store),
            publicationStore: fx.stores.publicationStore, snapshotStore: fx.stores.snapshotStore,
            jobManager: fx.stores.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
    }

    /// The ¶id of the paragraph whose text contains `needle`, as the op log has it.
    private func paragraphID(containing needle: String, in fx: Fixture) throws -> String {
        let piece = try XCTUnwrap(try ProjectStoreASTSource(projectStore: fx.store).orderedPieces()
            .first { $0.pieceID == fx.pieceID })
        return try XCTUnwrap(piece.paragraphs?.first { $0.text.contains(needle) }?.id,
                             "premise: a paragraph reads \(needle)")
    }

    private func exportedEPUBs(_ fx: Fixture) -> [String] {
        let exports = fx.url.appendingPathComponent("Exports")
        return ((try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? [])
            .filter { $0.hasSuffix(".epub") }
    }

    private func problemDiagnostics(_ diags: [TectonicLogParser.Diagnostic]) -> [TectonicLogParser.Diagnostic] {
        diags.filter { $0.pieceID != nil }
    }

    // MARK: - a Report refuses before the mint

    func test_aReportWithAnUnknownKeyRefusesCompile_andMintsNothing() async throws {
        let fx = try await makeProject(report: true, text: "Intro.\n\nRevenue grew [@nobody].")
        let paragraph = try paragraphID(containing: "[@nobody]", in: fx)

        let outcome = try await orchestrator(fx).compile(format: .epub, label: nil)

        guard case .failed(let errors, let excerpt) = outcome else {
            return XCTFail("a Report with an unknown key must refuse: \(outcome)")
        }
        XCTAssertTrue(excerpt.hasPrefix(CompileOrchestrator.publishProblemsLogExcerpt), excerpt)
        let diag = try XCTUnwrap(errors.first { $0.message.contains("nobody") }, "\(errors)")
        XCTAssertEqual(diag.level, .error)
        XCTAssertEqual(diag.pieceID, fx.pieceID)
        XCTAssertEqual(diag.paragraphID, paragraph)
        XCTAssertEqual(diag.file, fx.path, "file is the piece's project-relative path")
        XCTAssertNil(diag.line)

        let pubs = try await fx.stores.publicationStore.load()
        XCTAssertTrue(pubs.isEmpty, "no version minted: \(pubs)")
        let nextVersion = try await fx.stores.configStore.load()?.nextVersion
        XCTAssertEqual(nextVersion, "0.1", "next_version did not advance")
        XCTAssertTrue(exportedEPUBs(fx).isEmpty, "nothing exported: \(exportedEPUBs(fx))")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fx.url.appendingPathComponent(".maugham/publish/build/body.xhtml").path),
                       "refused at the gate: the compiler never ran")
    }

    func test_aReportDryRunListsTheProblemWithItsParagraph() async throws {
        let fx = try await makeProject(report: true, text: "Intro.\n\nRevenue grew [@nobody].")
        let paragraph = try paragraphID(containing: "[@nobody]", in: fx)

        let outcome = try await orchestrator(fx).compile(format: .epub, label: nil, dryRun: true)

        guard case .failed(let errors, let excerpt) = outcome else {
            return XCTFail("a Report's dry run reports the refusal a compile would meet: \(outcome)")
        }
        XCTAssertTrue(excerpt.hasPrefix(CompileOrchestrator.publishProblemsLogExcerpt), excerpt)
        XCTAssertEqual(problemDiagnostics(errors).map(\.paragraphID), [paragraph])
        let pubs = try await fx.stores.publicationStore.load()
        XCTAssertTrue(pubs.isEmpty)
    }

    /// The refusal carries every problem, the warning kinds as warnings — and
    /// the errors first, so `errors.first` (the desk's line, MCP's
    /// `errors[0]`) names an error even when a warning comes first in the book.
    func test_aReportRefusalCarriesItsWarningsToo() async throws {
        let fx = try await makeProject(
            report: true, text: "# Heading {#nonsense}\n\nThen [@nobody].")
        guard case .failed(let errors, _) = try await orchestrator(fx).compile(format: .epub, label: nil)
        else { return XCTFail("must refuse") }
        let problems = problemDiagnostics(errors)
        XCTAssertEqual(problems.map(\.level), [.error, .warning], "\(problems.map(\.message))")
        XCTAssertTrue(errors.first?.message.contains("nobody") ?? false, "\(errors.map(\.message))")
        XCTAssertTrue(problems.last?.message.contains("nonsense") ?? false, "\(problems.map(\.message))")
    }

    /// A Report whose problems are only warnings compiles, carrying them.
    func test_aReportWithOnlyWarningsCompiles() async throws {
        let fx = try await makeProject(report: true, text: "Clean [@smith2026].\n\n[^spare]: Never used.")
        guard case .completed(_, let warnings) = try await orchestrator(fx).compile(format: .epub, label: nil)
        else { return XCTFail("only warnings: the Report compiles") }
        XCTAssertEqual(problemDiagnostics(warnings).count, 1, "\(warnings)")
        XCTAssertEqual(problemDiagnostics(warnings).first?.level, .warning)
    }

    // MARK: - Review focus 4: ordinary prose stays prose

    func test_aNovelWithTheSameTextCompiles_withWarnings() async throws {
        let fx = try await makeProject(
            report: false,
            text: "Ask [@sarah] about it.\n\nEmail me @fig:nothing tomorrow.\n\nShe typed [^missing] and left.")

        let dry = try await orchestrator(fx).compile(format: .epub, label: nil, dryRun: true)
        guard case .dryRunPassed(let dryWarnings) = dry else {
            return XCTFail("a novel's dry run passes: \(dry)")
        }
        let outcome = try await orchestrator(fx).compile(format: .epub, label: nil)
        guard case .completed(let pub, let warnings) = outcome else {
            return XCTFail("a novel never refuses on publish problems: \(outcome)")
        }
        XCTAssertEqual(pub.version, "0.1")
        XCTAssertEqual(exportedEPUBs(fx).count, 1)
        let problems = problemDiagnostics(warnings)
        XCTAssertEqual(problems.count, 3, "\(problems.map(\.message))")
        XCTAssertTrue(problems.allSatisfy { $0.level == .warning && $0.pieceID == fx.pieceID
            && $0.paragraphID != nil && $0.file == fx.path }, "\(problems)")
        // One resolution, judged and emitted: the gate's list (what dry_run
        // returned) is exactly what the compiler finished with.
        XCTAssertEqual(problemDiagnostics(dryWarnings), problems)
    }

    // MARK: - fix round 1

    /// A compile that fails for its own reason (here an occupied destination)
    /// still carries the book's publish problems, after its own errors.
    func test_aCompileThatFailsForItsOwnReasonStillCarriesTheProblems() async throws {
        let fx = try await makeProject(report: false, text: "Ask [@sarah] about it.")
        let loaded = try await fx.stores.configStore.load()
        let cfg = try XCTUnwrap(loaded)
        let exports = fx.url.appendingPathComponent(cfg.outputs.directory)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: exports.appendingPathComponent(
            OutputFilenameBuilder.make(config: cfg, format: .epub, label: nil, language: nil)))

        let outcome = try await orchestrator(fx).compile(format: .epub, label: nil)
        guard case .failed(let errors, let excerpt) = outcome else {
            return XCTFail("an occupied destination fails the compile: \(outcome)")
        }
        XCTAssertFalse(excerpt.hasPrefix(CompileOrchestrator.publishProblemsLogExcerpt),
                       "a fault, not a problem refusal: \(excerpt)")
        XCTAssertEqual(errors.count, 2, "\(errors.map(\.message))")
        XCTAssertNil(errors.first?.pieceID, "the tool's own error comes first: \(errors)")
        let problem = try XCTUnwrap(problemDiagnostics(errors).first, "\(errors)")
        XCTAssertTrue(problem.message.contains("sarah"), problem.message)
        XCTAssertEqual(problem.paragraphID, try paragraphID(containing: "[@sarah]", in: fx))
    }

    /// R-P2-8 end to end: a two-body EPUB whose translation dropped a label.
    /// The reference is unresolved in THAT body only, its problem prefixed
    /// with the body's tag and pointing at the referring paragraph.
    func test_aBilingualCompile_reportsTheTranslationsDroppedLabelUnderItsTag() async throws {
        let fx = try await makeProject(report: false, text: "# Intro {#sec:intro}\n\nSee @sec:intro.")
        let loaded = try await fx.stores.configStore.load()
        var cfg = try XCTUnwrap(loaded)
        cfg.metadata.language = "en"
        try await fx.stores.configStore.save(cfg)
        let doc = try await Document.load(url: fx.url.appendingPathComponent(fx.path),
                                          actor: .author, session: "gate", presenter: nil)
        let ids = doc.sequence
        XCTAssertEqual(ids.count, 2, "premise: two paragraphs")
        for (id, text) in zip(ids, ["# Uvod", "Vidi @sec:intro."]) {
            try await TranslationStore.append(
                TranslationRecord(paragraphId: id, language: "sr", text: text,
                                  sourceHash: TranslationHash.hash(doc.paragraphs[id] ?? ""),
                                  verbatim: false),
                forDocId: fx.pieceID, identity: LocalIdentities.current.translator,
                identities: .current, in: fx.url)
        }
        await doc.close()

        let outcome = try await orchestrator(fx).compile(format: .epub, label: nil, languages: ["en", "sr"])
        guard case .completed(_, let warnings) = outcome else {
            return XCTFail("a novel compiles: \(outcome)")
        }
        let problems = problemDiagnostics(warnings)
        XCTAssertEqual(problems.count, 1, "only the sr body lost the label: \(problems.map(\.message))")
        XCTAssertTrue(problems.first?.message.hasPrefix("[sr] ") ?? false, "\(problems.map(\.message))")
        XCTAssertEqual(problems.first?.paragraphID, ids[1], "the referring paragraph")
        XCTAssertEqual(problems.first?.pieceID, fx.pieceID)
        XCTAssertEqual(problems.first?.bodyLanguage, "sr",
            "R-S14: the problem reveals in the edition whose body held it")
    }

    /// R-S14's other half: in the same two-body compile, a problem in the
    /// SOURCE body carries no language — it reveals in the source text.
    func test_aBilingualCompile_aSourceBodyProblemCarriesNoLanguage() async throws {
        let fx = try await makeProject(report: false, text: "# Intro\n\nSee @fig:nowhere.")
        let loaded = try await fx.stores.configStore.load()
        var cfg = try XCTUnwrap(loaded)
        cfg.metadata.language = "en"
        try await fx.stores.configStore.save(cfg)
        let doc = try await Document.load(url: fx.url.appendingPathComponent(fx.path),
                                          actor: .author, session: "gate", presenter: nil)
        let ids = doc.sequence
        for (id, text) in zip(ids, ["# Uvod", "Vidi @fig:nowhere."]) {
            try await TranslationStore.append(
                TranslationRecord(paragraphId: id, language: "sr", text: text,
                                  sourceHash: TranslationHash.hash(doc.paragraphs[id] ?? ""),
                                  verbatim: false),
                forDocId: fx.pieceID, identity: LocalIdentities.current.translator,
                identities: .current, in: fx.url)
        }
        await doc.close()

        let outcome = try await orchestrator(fx).compile(format: .epub, label: nil, languages: ["en", "sr"])
        guard case .completed(_, let warnings) = outcome else {
            return XCTFail("a novel compiles: \(outcome)")
        }
        let problems = problemDiagnostics(warnings)
        XCTAssertEqual(problems.count, 2, "one per body: \(problems.map(\.message))")
        XCTAssertEqual(Set(problems.map(\.bodyLanguage)), [nil, "sr"],
                       "\(problems.map { ($0.message, $0.bodyLanguage) })")
        let source = try XCTUnwrap(problems.first { $0.bodyLanguage == nil })
        XCTAssertFalse(source.message.hasPrefix("[sr]"), source.message)
        XCTAssertEqual(source.paragraphID, ids[1])
    }

    // MARK: - R-S15: the edition's book is the gate's book

    /// A Report of two chapters whose second is a draft the writer left out
    /// (`include: false`), each written before its first load.
    private func makeReportWithExcludedDraft(kept: String, draft: String) async throws -> (Fixture, String) {
        let fx = try await makeProject(report: true, text: kept)
        fx.store.manifest.structure.append(StructureItem(
            id: "doc-draft", title: "Draft", type: .document, path: "manuscript/draft.md"))
        try await fx.store.saveManifest()
        let draftURL = fx.url.appendingPathComponent("manuscript/draft.md")
        try draft.write(to: draftURL, atomically: true, encoding: .utf8)
        let doc = try await Document.load(url: draftURL, actor: .author, session: "gate", presenter: nil)
        await doc.close()
        var cfg = try await fx.stores.configStore.load() ?? PublishConfig()
        cfg.sections["doc-draft"] = PublishConfig.Section(include: false)
        try await fx.stores.configStore.save(cfg)
        let ids = try ProjectStoreASTSource(projectStore: fx.store).orderedPieces().map(\.pieceID)
        XCTAssertEqual(ids, [fx.pieceID, "doc-draft"], "premise: the draft is in the binder")
        return (fx, "doc-draft")
    }

    /// A draft chapter the edition leaves out is not in the book the gate
    /// judges: its unknown key refuses nothing.
    func test_aReportsExcludedDraftCitingAnUnknownKey_compiles() async throws {
        let (fx, _) = try await makeReportWithExcludedDraft(
            kept: "Intro.\n\nRevenue grew [@smith2026].", draft: "Draft.\n\nTo do [@todo].")
        let outcome = try await orchestrator(fx).compile(format: .epub, label: nil)
        guard case .completed(_, let warnings) = outcome else {
            return XCTFail("the excluded draft must not block the Report: \(outcome)")
        }
        XCTAssertEqual(problemDiagnostics(warnings).map(\.message), [], "\(warnings)")
    }

    /// A reference from the published chapter into the excluded draft points
    /// at a figure the book doesn't contain: the Report refuses, naming it.
    func test_aReportReferringIntoItsExcludedDraft_refuses() async throws {
        let (fx, _) = try await makeReportWithExcludedDraft(
            kept: "Intro.\n\nSee @fig:draftchart.",
            draft: "Draft.\n\n![Chart]({up}research/chart.png){#fig:draftchart}"
                .replacingOccurrences(of: "{up}", with: "../"))
        let outcome = try await orchestrator(fx).compile(format: .epub, label: nil, dryRun: true)
        guard case .failed(let errors, let excerpt) = outcome else {
            return XCTFail("a reference into excluded text must refuse: \(outcome)")
        }
        XCTAssertTrue(excerpt.hasPrefix(CompileOrchestrator.publishProblemsLogExcerpt), excerpt)
        let problems = problemDiagnostics(errors)
        XCTAssertEqual(problems.map(\.message), ["No figure is labelled fig:draftchart."])
        XCTAssertEqual(problems.first?.paragraphID, try paragraphID(containing: "@fig:draftchart", in: fx))
    }

    // MARK: - previews never refuse

    func test_aPreviewOfAReportRendersWithWarnings() async throws {
        let fx = try await makeProject(report: true, text: "Intro.\n\nRevenue grew [@nobody].")
        let result = try await PreviewCompiler(
            projectURL: fx.url, astSource: ProjectStoreASTSource(projectStore: fx.store),
            configStore: fx.stores.configStore, jobManager: fx.stores.jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a"
        ).preview(format: .epub, sectionIDs: nil, maxPages: nil)

        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertFalse(result.outputPath.isEmpty, "the preview rendered")
        let diag = try XCTUnwrap(problemDiagnostics(result.warnings).first)
        XCTAssertEqual(diag.level, .warning)
        XCTAssertEqual(diag.paragraphID, try paragraphID(containing: "[@nobody]", in: fx))
    }

    // MARK: - republish re-checks the live manuscript

    func test_aRepublishOfAReportThatGainedABrokenReferenceRefuses() async throws {
        let fx = try await makeProject(report: true, text: "Intro.\n\nClean [@smith2026].")
        guard case .completed(let pub, _) = try await orchestrator(fx).compile(format: .epub, label: nil)
        else { return XCTFail("premise: the clean Report compiles") }

        let doc = try await Document.load(url: fx.url.appendingPathComponent(fx.path),
                                          actor: .author, session: "gate", presenter: nil)
        doc.setFullText("Intro.\n\nClean [@smith2026].\n\nSee @fig:gone.")
        await doc.close()
        let paragraph = try paragraphID(containing: "@fig:gone", in: fx)

        let outcome = try await republisher(fx).republish(
            snapshotID: pub.snapshotID, format: .epub, label: nil)

        guard case .failed(let errors, let excerpt) = outcome else {
            return XCTFail("the republish must refuse: \(outcome)")
        }
        XCTAssertTrue(excerpt.hasPrefix(CompileOrchestrator.publishProblemsLogExcerpt), excerpt)
        XCTAssertEqual(problemDiagnostics(errors).map(\.paragraphID), [paragraph])
        XCTAssertEqual(problemDiagnostics(errors).first?.level, .error)
        let pubs = try await fx.stores.publicationStore.load()
        XCTAssertEqual(pubs.count, 1, "no republish minted")
    }

    // MARK: - R-S10: a figure that fails to stage after the gate

    private func lockChart(_ fx: Fixture) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fx.url.appendingPathComponent("research/chart.png").path)
    }

    func test_aFigureThatFailsToStage_failsAReport_andMintsNothing() async throws {
        let fx = try await makeProject(report: true, text: "Intro.\n\n![Chart]({up}research/chart.png)")
        try lockChart(fx)

        let outcome = try await orchestrator(fx).compile(format: .epub, label: nil)

        guard case .failed(let errors, let excerpt) = outcome else {
            return XCTFail("an unstageable image fails a Report: \(outcome)")
        }
        XCTAssertTrue(excerpt.hasPrefix(CompileOrchestrator.publishProblemsLogExcerpt), excerpt)
        let diag = try XCTUnwrap(problemDiagnostics(errors).first, "\(errors)")
        XCTAssertEqual(diag.level, .error)
        XCTAssertEqual(diag.paragraphID, try paragraphID(containing: "chart.png", in: fx))
        XCTAssertTrue(diag.message.contains("chart.png"), diag.message)
        let pubs = try await fx.stores.publicationStore.load()
        XCTAssertTrue(pubs.isEmpty)
        XCTAssertTrue(exportedEPUBs(fx).isEmpty, "the written output is removed: \(exportedEPUBs(fx))")
    }

    func test_aFigureThatFailsToStage_isAWarningInANovel() async throws {
        let fx = try await makeProject(report: false, text: "Intro.\n\n![Chart]({up}research/chart.png)")
        try lockChart(fx)
        guard case .completed(_, let warnings) = try await orchestrator(fx).compile(format: .epub, label: nil)
        else { return XCTFail("a novel compiles") }
        let diag = try XCTUnwrap(problemDiagnostics(warnings).first, "the problem is never lost: \(warnings)")
        XCTAssertEqual(diag.level, .warning)
        XCTAssertTrue(diag.message.contains("chart.png"), diag.message)
    }

    /// M1 (final review): an image that won't open is found at staging in an
    /// EPUB too — a Report fails naming its paragraph, and nothing ships.
    func test_anImageThatWontOpen_failsAReport_namingItsParagraph() async throws {
        let fx = try await makeProject(report: true, text: "Intro.\n\n![Chart]({up}research/chart.png)")
        let png = try Self.png()
        try png.prefix(png.count / 2).write(to: fx.url.appendingPathComponent("research/chart.png"))

        let outcome = try await orchestrator(fx).compile(format: .epub, label: nil)

        guard case .failed(let errors, _) = outcome else {
            return XCTFail("a cut-short image fails a Report: \(outcome)")
        }
        let diag = try XCTUnwrap(problemDiagnostics(errors).first, "\(errors)")
        XCTAssertEqual(diag.paragraphID, try paragraphID(containing: "chart.png", in: fx))
        XCTAssertTrue(diag.message.hasSuffix("is cut short (the PNG ends before its last chunk)."), diag.message)
        XCTAssertTrue(exportedEPUBs(fx).isEmpty)
    }

    // MARK: - the format decides the image check

    /// A GIF is an EPUB image and not a PDF one (R-P2-7): the gate resolves for
    /// the format being compiled, so the same Report passes as an EPUB and
    /// refuses as a PDF — before any tectonic run.
    func test_theGateResolvesForTheFormatBeingCompiled() async throws {
        let fx = try await makeProject(report: true, text: "Intro.\n\n![Anim]({up}research/anim.gif)")
        try Data("GIF89a".utf8).write(to: fx.url.appendingPathComponent("research/anim.gif"))

        let epub = try await orchestrator(fx).compile(format: .epub, label: nil, dryRun: true)
        guard case .dryRunPassed = epub else { return XCTFail("an EPUB shows a gif: \(epub)") }
        let pdf = try await orchestrator(fx).compile(format: .pdf, label: nil, dryRun: true)
        guard case .failed(let errors, _) = pdf else { return XCTFail("a PDF can't show a gif: \(pdf)") }
        XCTAssertEqual(problemDiagnostics(errors).first?.level, .error, "\(errors)")
    }

    // MARK: - one resolution, read once

    private final class Counter: @unchecked Sendable { var reads = 0 }
    private struct CountingBook: ProjectASTBuilder.Source {
        let counter: Counter
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            counter.reads += 1
            return [.init(pieceID: "a", title: "A", mode: .prose, displayText: "See @tbl:none.")]
        }
    }

    /// The compiler handed the gate's bodies emits with them: it reads the
    /// manuscript no second time, and finishes with the gate's problems.
    func test_aCompilerHandedTheGatesBodiesNeitherRereadsNorReresolves() async throws {
        let counter = Counter()
        let body = BodyPlan.Body(tag: nil, displayTag: "en", source: CountingBook(counter: counter),
                                 config: PublishConfig(metadata: .init(title: "T", author: "A")))
        let resolved = try EPUBCompiler.resolve(bodies: [body])
        XCTAssertEqual(counter.reads, 1)
        let project = tmp.appendingPathComponent("counting")
        try await PublishStarter.install(into: project, force: false)
        let result = try await EPUBCompiler(
            projectURL: project, bodies: [body], config: body.config,
            jobManager: CompileJobManager(), maughamVersion: "0", tectonicVersion: "n/a",
            resolved: resolved
        ).compile(label: nil)
        XCTAssertEqual(counter.reads, 1, "the compile reused the gate's AST")
        XCTAssertEqual(result.problems, resolved.flatMap(\.resolution.problems))
        XCTAssertEqual(result.problems.count, 1)
    }

    /// A book whose every read is counted, and where it happened.
    private final class ThreadedCounter: @unchecked Sendable {
        var reads = 0
        var offMain = 0
    }
    private struct ThreadedBook: ProjectASTBuilder.Source {
        let counter: ThreadedCounter
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            counter.reads += 1
            if !Thread.isMainThread { counter.offMain += 1 }
            return [.init(pieceID: "a", title: "A", mode: .prose, displayText: "| x |\n|---|\n| 1 |\nTable: One {#tbl:one}"),
                    .init(pieceID: "b", title: "B", mode: .prose, displayText: "See @tbl:one and @tbl:none.")]
        }
    }

    /// M4 (final review): a preview resolves through the gate's door before it
    /// compiles — on the main actor, where the production source's conformance
    /// lives — and hands the bodies down, so a one-chapter preview reads the
    /// book once and its warnings are about what it emitted.
    func test_aPreviewResolvesOnceOnTheMainActor_andWarnsAboutWhatItEmits() async throws {
        let counter = ThreadedCounter()
        let project = tmp.appendingPathComponent("preview-once")
        try await PublishStarter.install(into: project, force: false)
        let configStore = PublishConfigStore(projectURL: project)
        try await configStore.save(PublishConfig(metadata: .init(title: "T", author: "A")))
        let result = try await PreviewCompiler(
            projectURL: project, astSource: ThreadedBook(counter: counter),
            configStore: configStore, jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a"
        ).preview(format: .epub, sectionIDs: ["b"], maxPages: nil)

        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertEqual(counter.reads, 1, "the subset and its book are one read")
        XCTAssertEqual(counter.offMain, 0, "resolved on the main actor, before the compile hops off it")
        XCTAssertEqual(problemDiagnostics(result.warnings).map(\.message),
                       ["No table is labelled tbl:none."], "the narrowed piece's own problem, once")
    }

    // MARK: - the gate's table

    private func problem(_ kind: PublishProblem.Kind, tag: String? = nil) -> PublishProblem {
        PublishProblem(kind: kind, pieceID: "d_abc", paragraphID: "ab3x", bodyTag: tag)
    }

    private func context(_ profile: ProjectProfile?) -> PublishContext {
        var context = PublishContext.empty
        context.profile = profile
        context.piecePaths = ["d_abc": "Manuscript/One.md"]
        return context
    }

    func test_judge_onlyAReportsVersionedCompileRefuses() {
        let problems = [problem(.unknownCitationKey("x")), problem(.unusedFootnoteDefinition("n"))]
        guard case .refused(let errors) = PublishProblemGate.judge(
            problems, context: context(.report), refusesOnErrors: true) else {
            return XCTFail("a Report's versioned compile refuses on an error")
        }
        XCTAssertEqual(errors.map(\.level), [.error, .warning])
        XCTAssertEqual(PublishProblemGate.judge(problems, context: context(nil), refusesOnErrors: true),
                       .passed(warnings: PublishProblemGate.warnings(problems, context: context(nil))))
        guard case .passed(let warnings) = PublishProblemGate.judge(
            problems, context: context(.report), refusesOnErrors: false) else {
            return XCTFail("a preview never refuses")
        }
        XCTAssertEqual(warnings.map(\.level), [.warning, .warning])
        guard case .passed = PublishProblemGate.judge(
            [problem(.malformedLabel("x"))], context: context(.report), refusesOnErrors: true) else {
            return XCTFail("a Report with only warning kinds passes")
        }
    }

    /// M8 (final review): a reason ending in a system message's own full
    /// stop still makes one sentence, and the refusal's line is true for a
    /// compile and a republish alike (a republish mints no version).
    func test_wording_oneFullStop_andARefusalLineTrueForEveryDoor() {
        let p = problem(.imageUnreadable("research/x.png couldn't be copied (The file couldn't be opened.)."))
        XCTAssertEqual(p.message,
                       "The figure image can't be used: research/x.png couldn't be copied "
                       + "(The file couldn't be opened.).")
        XCTAssertEqual(problem(.imageUnreadable("research/x.png couldn't be opened.")).message,
                       "The figure image can't be used: research/x.png couldn't be opened.")
        let error = PublishProblemGate.diagnostic(problem(.unknownCitationKey("k")), level: .error,
                                                  piecePaths: [:])
        XCTAssertEqual(error.contextLines, ["A report won't publish with this problem, so nothing was published."])
        XCTAssertFalse(error.contextLines.joined().contains("version"))
    }

    func test_aProblemsDiagnosticNamesItsFilePieceAndParagraph_andItsBody() {
        let diag = PublishProblemGate.diagnostic(problem(.unknownCitationKey("x"), tag: "sr"),
                                                 level: .warning, piecePaths: ["d_abc": "Manuscript/One.md"])
        XCTAssertEqual(diag.file, "Manuscript/One.md")
        XCTAssertNil(diag.line)
        XCTAssertEqual(diag.pieceID, "d_abc")
        XCTAssertEqual(diag.paragraphID, "ab3x")
        XCTAssertTrue(diag.message.hasPrefix("[sr] "), "R-P2-8: \(diag.message)")
    }
}
