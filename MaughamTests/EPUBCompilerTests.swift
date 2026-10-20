import XCTest
import MaughamCore
@testable import Maugham

final class EPUBCompilerTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = TestTemp.root
            .appendingPathComponent("EPUBCompilerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testCompiles_simpleProject_producesEPUB() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "Chapter 1",
                       mode: .prose, displayText: "Hello.")]
            }
        }
        let cfg = PublishConfig(metadata: .init(title: "EpubSmoke", author: "T"))
        let mgr = CompileJobManager()
        let compiler = try EPUBCompiler(
            projectURL: tmp, astSource: Src(), config: cfg,
            jobManager: mgr, maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")

        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath))
        XCTAssertTrue(result.outputPath.hasSuffix(".epub"))
    }
}

// MARK: - report foundations plan 2, Task 6

final class EPUBCompilerLabelHrefTests: XCTestCase {

    /// A label's href names the section file its piece is emitted in, plus
    /// the label's id; a target in a piece this compile does not emit (a
    /// subset) gets none, so its cross-reference reads unlinked.
    func test_labelHrefs_nameTheTargetsFile_andSkipAPieceNotEmitted() throws {
        let source = EPUBHrefBook()
        let r = try PublishResolution.forCompile(source: source, bodyTag: nil,
                                                 imageAllowed: EPUBCompiler.imageAllowed)
        let fig = try XCTUnwrap(ManuscriptLabel(reference: "fig:one"))
        let tbl = try XCTUnwrap(ManuscriptLabel(reference: "tbl:two"))
        let single = EPUBCompiler.labelHrefs(r, emittedPieces: ["a", "b"], tag: "en", bodyCount: 1)
        XCTAssertEqual(single[fig], "section-001.xhtml#lbl-fig-one")
        XCTAssertEqual(single[tbl], "section-002.xhtml#lbl-tbl-two")
        let subset = EPUBCompiler.labelHrefs(r, emittedPieces: ["b"], tag: "en", bodyCount: 1)
        XCTAssertNil(subset[fig], "piece a is not in this compile")
        XCTAssertEqual(subset[tbl], "section-001.xhtml#lbl-tbl-two", "b is the subset's first file")
        let multi = EPUBCompiler.labelHrefs(r, emittedPieces: ["a", "b"], tag: "sr", bodyCount: 2)
        XCTAssertEqual(multi[tbl], "section-sr-002.xhtml#lbl-sr-tbl-two")
    }

    func test_referencesFilename_isPerBodyOnlyWhenThereAreSeveral() {
        XCTAssertEqual(EPUBCompiler.referencesFilename(tag: "en", bodyCount: 1), "references.xhtml")
        XCTAssertEqual(EPUBCompiler.referencesFilename(tag: "sr", bodyCount: 2), "references-sr.xhtml")
    }
}

private struct EPUBHrefBook: ProjectASTBuilder.Source {
    func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
        [.init(pieceID: "a", title: "A", mode: .prose,
               displayText: "![One](../research/1.png){#fig:one}"),
         .init(pieceID: "b", title: "B", mode: .prose,
               displayText: "| x |\n|---|\n| 1 |\nTable: Two {#tbl:two}")]
    }
}

/// The orchestrator's compile derives its manuscript once
/// (`CompileOrchestratorTests.testImprint_thePieceListIsReadOnlyWhenAnImprintCouldNeedIt`):
/// the EPUB's resolution reuses the AST the compile built when its source is
/// the whole book, and builds the whole book only for a subset.
final class EPUBPrepareReuseTests: XCTestCase {

    private final class Counter: @unchecked Sendable { var reads = 0 }

    private struct CountingBook: ProjectASTBuilder.Source {
        let counter: Counter
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            counter.reads += 1
            return [.init(pieceID: "a", title: "A", mode: .prose,
                          displayText: "| x |\n|---|\n| 1 |\nTable: One {#tbl:one}"),
                    .init(pieceID: "b", title: "B", mode: .prose, displayText: "See @tbl:one.")]
        }
    }

    private func body(_ source: ProjectASTBuilder.Source) -> BodyPlan.Body {
        BodyPlan.Body(tag: nil, displayTag: "en", source: source, config: PublishConfig())
    }

    func test_aWholeBookSourceIsReadOnce() throws {
        let counter = Counter()
        let source = IncludeFilteredASTSource(base: CountingBook(counter: counter), excludedSectionIDs: [])
        XCTAssertTrue(source.isWholeBook)
        let ast = try ProjectASTBuilder.build(from: source)
        let prepared = try EPUBCompiler.prepare(body: body(source), bodyTag: nil, built: ast)
        XCTAssertEqual(counter.reads, 1, "the built AST is the whole book: no second derivation")
        XCTAssertEqual(prepared.resolution.tableNumbers["a"], [0: 1])
    }

    func test_aSubsetSourceStillResolvesOverItsWholeBook() throws {
        let counter = Counter()
        let source = IncludeFilteredASTSource(base: CountingBook(counter: counter), excludedSectionIDs: ["a"])
        XCTAssertFalse(source.isWholeBook)
        XCTAssertFalse(FilteredASTSource(base: source, sectionIDs: nil).isWholeBook,
                       "a pass-through over a subset is still a subset")
        XCTAssertFalse(FilteredASTSource(base: CountingBook(counter: counter), sectionIDs: ["b"]).isWholeBook)
        let ast = try ProjectASTBuilder.build(from: source)
        XCTAssertEqual(ast.sections.map(\.pieceID), ["b"], "premise: a subset")
        let prepared = try EPUBCompiler.prepare(body: body(source), bodyTag: nil, built: ast)
        XCTAssertEqual(counter.reads, 2, "the subset's whole book is built for the resolution")
        XCTAssertEqual(prepared.resolution.targets[try XCTUnwrap(ManuscriptLabel(reference: "tbl:one"))]?.text,
                       "Table 1", "the excluded piece's table still resolves")
    }
}
