import XCTest
import MaughamCore
@testable import Maugham

final class PDFCompilerTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = TestTemp.root
            .appendingPathComponent("PDFCompilerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testCompiles_simpleProject_producesPDF() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "Chapter 1",
                       mode: .prose, displayText: "Hello, world.")]
            }
        }

        let cfg = PublishConfig(metadata: .init(title: "Smoke", author: "Tester"))
        let mgr = CompileJobManager()
        let compiler = try PDFCompiler(
            projectURL: tmp,
            astSource: Src(),
            config: cfg,
            jobManager: mgr,
            maughamVersion: "0.0.0-test")

        let result = try await compiler.compile(label: nil)
        XCTAssertTrue(result.errors.isEmpty,
                      "errors: \(result.errors.map(\.message))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputPath))
        XCTAssertTrue(result.outputPath.hasSuffix(".pdf"))
    }

    // MARK: - M1: the wrapper's \input prefix

    /// An `\input` inside `build/body.tex` resolves relative to the PRIMARY
    /// TEMPLATE's own directory, so the wrapper carries one `../` per
    /// directory the template sits below the publish dir.
    ///
    /// M1 (whole-branch review): a `.` segment is not a directory.
    /// `./template.tex` is the publish dir's own root — the same file
    /// `template.tex` names — and giving it a `../` sends every `\input` a
    /// level above the publish dir, where none of the build files are.
    ///
    /// No tectonic: this is a pure string function, and the prefix it returns
    /// is what a real compile would then fail on.
    ///
    /// Disable experiment: drop the `.`-filter and the `./template.tex` case
    /// returns "../".
    func test_wrapperInputPrefixCountsDirectoriesAndNotDotSegments() {
        XCTAssertEqual(
            PDFCompiler.wrapperInputPrefix(forTemplate: "template.tex"), "",
            "a template at the publish dir's root needs no prefix")
        XCTAssertEqual(
            PDFCompiler.wrapperInputPrefix(forTemplate: "./template.tex"), "",
            "`.` names that same root — it is not a directory to climb out of")
        XCTAssertEqual(
            PDFCompiler.wrapperInputPrefix(forTemplate: "templates/x.tex"), "../",
            "one directory down, one `../`")
        XCTAssertEqual(
            PDFCompiler.wrapperInputPrefix(forTemplate: "templates/a/b.tex"), "../../",
            "two directories down, two")
        XCTAssertEqual(
            PDFCompiler.wrapperInputPrefix(forTemplate: "./templates/x.tex"), "../",
            "and the two rules compose")
    }

    // MARK: - report foundations plan 2, Task 5

    private struct Book: ProjectASTBuilder.Source {
        let paragraphs: [(id: String, text: String)]
        let context: PublishContext
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "a", title: "A", mode: .prose,
                   displayText: paragraphs.map(\.text).joined(separator: "\n\n"),
                   paragraphs: paragraphs)]
        }
        func publishContext() -> PublishContext { context }
    }

    private func resolution(_ paragraphs: [(id: String, text: String)],
                            project: URL? = nil) throws -> PublishResolution {
        var context = PublishContext.empty
        context.projectURL = project
        context.piecePaths = ["a": "manuscript/a.md"]
        return try PublishResolution.forCompile(
            source: Book(paragraphs: paragraphs, context: context), bodyTag: nil,
            imageAllowed: ["png", "jpg", "jpeg", "pdf"])
    }

    /// `build/metadata.tex` keeps its bytes for a book with no figure and no
    /// table: the package lines are appended only for the element the book has.
    func test_documentMetadata_isTheMetadataBlockUnlessTheBookHasFiguresOrTables() throws {
        let cfg = PublishConfig(metadata: .init(title: "T", author: "A"))
        let plain = try resolution([("a1b2", "# Heading"), ("c3d4", "Prose [^1].")])
        XCTAssertEqual(PDFCompiler.documentMetadata(config: cfg, label: "x", resolutions: [plain]),
                       PDFCompiler.metadataBlock(config: cfg, label: "x"))

        let table = try resolution([("a1b2", "| a |\n|---|\n| 1 |")])
        XCTAssertEqual(PDFCompiler.documentMetadata(config: cfg, label: nil, resolutions: [plain, table]),
                       PDFCompiler.metadataBlock(config: cfg, label: nil)
                       + "\n\\IfFileExists{longtable.sty}{\\usepackage{longtable}}{}")

        let figure = try resolution([("a1b2", "![F](../research/f.png)")])
        XCTAssertEqual(PDFCompiler.documentMetadata(config: cfg, label: nil, resolutions: [figure, table]),
                       PDFCompiler.metadataBlock(config: cfg, label: nil)
                       + "\n\\IfFileExists{graphicx.sty}{\\usepackage{graphicx}}{}"
                       + "\n\\IfFileExists{longtable.sty}{\\usepackage{longtable}}{}")
    }

    /// R-P2-7: each resolved image is copied (never read into memory) into
    /// `build/figures/` under a content-hash name, written relative to the
    /// template's directory; two figures of one file share one copy; a copy
    /// that fails unresolves its figure and becomes an `imageUnreadable` problem.
    func test_stageFigures_copiesUnderAContentHashName_andAFailedCopyIsAProblem() throws {
        let project = tmp.appendingPathComponent("Project With Spaces")
        let research = project.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        let aBytes = try TestImageBytes.png(seed: 1)
        try aBytes.write(to: research.appendingPathComponent("a.png"))
        try TestImageBytes.png(seed: 2).write(to: research.appendingPathComponent("gone.png"))
        var r = try resolution([("a1b2", "![One](../research/a.png)"),
                                ("c3d4", "![Again](../research/a.png)"),
                                ("e5f6", "![Gone](../research/gone.png)")], project: project)
        XCTAssertEqual(r.figureFiles["a"]?.count, 3, "premise: all three resolve")
        XCTAssertTrue(r.problems.isEmpty, "premise: \(r.problems)")
        try FileManager.default.removeItem(at: research.appendingPathComponent("gone.png"))

        let publish = project.appendingPathComponent(".maugham/publish")
        let staged = PDFCompiler.stageFigures(of: &r, publishDir: publish, pathPrefix: "../")

        let one = try XCTUnwrap(staged["a"]?[0])
        XCTAssertEqual(staged["a"]?[1], one, "one file, one staged copy")
        XCTAssertTrue(one.hasPrefix("../build/figures/"), one)
        let name = String(one.dropFirst("../build/figures/".count))
        XCTAssertTrue(name.hasSuffix(".png") && LaTeXSafeFilename(name) != nil, name)
        XCTAssertEqual(name.count, 16 + ".png".count, "a 16-hex-digit sha256 prefix: \(name)")
        let copy = publish.appendingPathComponent("build/figures/\(name)")
        XCTAssertEqual(try Data(contentsOf: copy), aBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copy.deletingLastPathComponent().path).count, 1)

        XCTAssertNil(staged["a"]?[2], "the failed copy is not staged")
        XCTAssertNil(r.figureFiles["a"]?[2], "and is no longer resolved")
        XCTAssertEqual(r.problems.count, 1)
        guard case .imageUnreadable(let reason)? = r.problems.first?.kind else {
            return XCTFail("\(r.problems)")
        }
        XCTAssertTrue(reason.contains("../research/gone.png"), reason)
        XCTAssertEqual(r.problems.first?.paragraphID, "e5f6")
    }

    /// m1: a staged copy a crash cut short is not reused: a file whose hash no
    /// longer matches its name is replaced, and a stale `.partial` is cleared.
    func test_stageFigures_replacesATruncatedCopy_andClearsAStalePartial() throws {
        let project = tmp.appendingPathComponent("Truncated")
        let research = project.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        let bytes = try TestImageBytes.png(seed: 3)
        try bytes.write(to: research.appendingPathComponent("a.png"))
        let publish = project.appendingPathComponent(".maugham/publish")
        let paragraphs = [(id: "a1b2", text: "![One](../research/a.png)")]

        var first = try resolution(paragraphs, project: project)
        let path = try XCTUnwrap(PDFCompiler.stageFigures(of: &first, publishDir: publish, pathPrefix: "")["a"]?[0])
        let staged = publish.appendingPathComponent(path)
        try bytes.prefix(10).write(to: staged)   // the interrupted copy
        let partial = staged.deletingLastPathComponent()
            .appendingPathComponent(staged.lastPathComponent + ".partial")
        try Data([1]).write(to: partial)          // a stale temporary

        var again = try resolution(paragraphs, project: project)
        XCTAssertEqual(PDFCompiler.stageFigures(of: &again, publishDir: publish, pathPrefix: "")["a"]?[0], path)
        XCTAssertEqual(try Data(contentsOf: staged), bytes, "the truncated copy was replaced")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "no temporary left behind")
        XCTAssertTrue(again.problems.isEmpty, "\(again.problems)")
    }

    /// M5 (final review): a staged copy whose size is its source's is trusted
    /// — its name is the source's hash — and not read again; the truncated
    /// copy above, being shorter, is still replaced.
    func test_stageFigures_trustsAStagedCopyOfTheSourcesSize_withoutRereadingIt() throws {
        let project = tmp.appendingPathComponent("SameSize")
        let research = project.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        let bytes = try TestImageBytes.png(seed: 4)
        try bytes.write(to: research.appendingPathComponent("a.png"))
        let publish = project.appendingPathComponent(".maugham/publish")
        let paragraphs = [(id: "a1b2", text: "![One](../research/a.png)")]

        var first = try resolution(paragraphs, project: project)
        let path = try XCTUnwrap(PDFCompiler.stageFigures(of: &first, publishDir: publish, pathPrefix: "")["a"]?[0])
        let staged = publish.appendingPathComponent(path)
        let marker = Data(repeating: 0x2A, count: bytes.count)   // same size, other bytes
        try marker.write(to: staged)

        var again = try resolution(paragraphs, project: project)
        XCTAssertEqual(PDFCompiler.stageFigures(of: &again, publishDir: publish, pathPrefix: "")["a"]?[0], path)
        XCTAssertEqual(try Data(contentsOf: staged), marker, "the same-size copy was kept, not re-hashed")
    }

    /// M1 (final review): an image that won't open — here an encrypted PDF —
    /// is a staging problem naming its paragraph, and never reaches TeX.
    func test_stageFigures_anImageThatWontOpen_isAProblem_andIsNotStaged() throws {
        let project = tmp.appendingPathComponent("WontOpen")
        let research = project.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        try TestImageBytes.pdf(encrypted: true).write(to: research.appendingPathComponent("locked.pdf"))
        let publish = project.appendingPathComponent(".maugham/publish")
        var r = try resolution([("a1b2", "Intro."), ("c3d4", "![Locked](../research/locked.pdf)")],
                               project: project)
        XCTAssertNotNil(r.figureFiles["a"]?[1], "premise: the path resolves")

        let staged = PDFCompiler.stageFigures(of: &r, publishDir: publish, pathPrefix: "")

        XCTAssertNil(staged["a"]?[1])
        XCTAssertNil(r.figureFiles["a"]?[1], "unresolved: it renders as its literal source")
        XCTAssertEqual(r.problems.map(\.paragraphID), ["c3d4"])
        XCTAssertEqual(r.problems.first?.message,
                       "The figure image can't be used: ../research/locked.pdf is an encrypted PDF, "
                       + "which can't be placed in a book.")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: publish.appendingPathComponent("build/figures").path)
            && ((try? FileManager.default.contentsOfDirectory(
                atPath: publish.appendingPathComponent("build/figures").path)) ?? []).contains { $0.hasSuffix(".pdf") },
            "nothing staged for TeX")
    }
}

/// The PDF twin of `EPUBPrepareReuseTests`: a whole-book body's resolution
/// reuses the AST the compile built, so the manuscript is derived once.
final class PDFPrepareReuseTests: XCTestCase {

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

    func test_aWholeBookSourceIsReadOnce() throws {
        let counter = Counter()
        let source = IncludeFilteredASTSource(base: CountingBook(counter: counter), excludedSectionIDs: [])
        let publish = TestTemp.root.appendingPathComponent("PDFPrepareReuse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: publish) }
        // The live path: the door's gate resolves, the compiler stages.
        let resolved = try PDFCompiler.resolve(bodies: [
            BodyPlan.Body(tag: nil, displayTag: "en", source: source, config: PublishConfig())])
        let prepared = PDFCompiler.prepare(resolution: try XCTUnwrap(resolved.first).resolution,
                                           publishDir: publish, pathPrefix: "")
        XCTAssertEqual(counter.reads, 1, "the built AST is the whole book: no second derivation")
        XCTAssertEqual(prepared.resolution.tableNumbers["a"], [0: 1])
    }
}
