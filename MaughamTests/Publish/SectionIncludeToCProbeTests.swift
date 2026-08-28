import XCTest
import PDFKit
@testable import Maugham

/// F1 ToC integrity probe (real tectonic compile): three prose pieces with the
/// MIDDLE one excluded via `sections.<id>.include = false`. The compiled PDF's
/// table of contents (the starter `frontmatter.tex` emits `\tableofcontents`,
/// and each `\begin{prose}{title}` adds a `\addcontentsline` entry) must list
/// EXACTLY the two included titles, and the compile must be clean — a dangling
/// `\pageref` from an emitted-but-excluded section would surface as a tectonic
/// error rather than a completed outcome.
///
/// Goes through `CompileOrchestrator` (not `PDFCompiler` directly) because the
/// include filter is applied by the orchestrator's `IncludeFilteredASTSource`
/// wrap, which is the production path.
@MainActor
final class SectionIncludeToCProbeTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectionToCProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    private struct ThreePieceSource: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "Alphapiece", mode: .prose,
                   displayText: "The first piece body text."),
             .init(pieceID: "p2", title: "Bravopiece", mode: .prose,
                   displayText: "The excluded middle piece body text."),
             .init(pieceID: "p3", title: "Charliepiece", mode: .prose,
                   displayText: "The third piece body text.")]
        }
    }

    func test_middlePieceExcluded_tocListsOnlyTheTwoIncludedTitles() async throws {
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "SectionToC", in: tmp)
        PublishingStores._resetForTesting()

        let configStore = PublishConfigStore(projectURL: projectURL)
        var cfg = try await configStore.load()
            ?? PublishConfig(metadata: .init(title: "ToC Book", author: "Tester"))
        cfg.metadata.title = "ToC Book"
        cfg.metadata.author = "Tester"
        cfg.sections["p2"] = .init(include: false)   // exclude the middle piece
        try await configStore.save(cfg)

        let orch = CompileOrchestrator(
            projectURL: projectURL,
            astSource: ThreePieceSource(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: projectURL),
            snapshotStore: PublicationSnapshotStore(projectURL: projectURL),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")

        let outcome = try await orch.compile(format: .pdf, label: nil)
        guard case .completed(let pub, _) = outcome else {
            return XCTFail("expected a clean compile, got \(outcome)")
        }

        // The emitted body must have dropped the excluded piece entirely
        // (no leftover heading/text that could dangle a \pageref).
        // (P2: `build/body.tex` is now the wrapper over the document's bodies —
        // the emitted book lives at `build/body.<tag>.tex`, `en` for this fixture.)
        let body = try String(
            contentsOf: projectURL.appendingPathComponent(
                ".maugham/publish/build/body.en.tex"),
            encoding: .utf8)
        XCTAssertTrue(body.contains("{Alphapiece}"), "included Alphapiece missing from body")
        XCTAssertTrue(body.contains("{Charliepiece}"), "included Charliepiece missing from body")
        XCTAssertFalse(body.contains("Bravopiece"),
                       "excluded Bravopiece leaked into the emitted body")
        XCTAssertFalse(body.contains("excluded middle piece"),
                       "excluded body text leaked into the emitted body")

        // Extract the rendered PDF text: the ToC lists exactly the two included
        // titles, and the excluded one appears nowhere in the document.
        let pdfURL = projectURL.appendingPathComponent(pub.outputPath)
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL),
                                "produced file is not a valid PDF")
        var text = ""
        for i in 0..<pdf.pageCount { text += pdf.page(at: i)?.string ?? "" }
        XCTAssertTrue(text.contains("Alphapiece"), "PDF missing included Alphapiece; text:\n\(text)")
        XCTAssertTrue(text.contains("Charliepiece"), "PDF missing included Charliepiece; text:\n\(text)")
        XCTAssertFalse(text.contains("Bravopiece"),
                       "excluded Bravopiece rendered in the PDF; text:\n\(text)")
        // A dangling ToC \pageref renders as "??" — clean compile has none.
        XCTAssertFalse(text.contains("??"),
                       "PDF contains '??' — a dangling \\pageref survived; text:\n\(text)")
    }
}
