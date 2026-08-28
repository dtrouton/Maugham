import XCTest
@testable import Maugham

final class PDFCompilerTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
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
}
