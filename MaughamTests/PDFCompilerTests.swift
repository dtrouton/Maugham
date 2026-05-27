import XCTest
@testable import Maugham

final class PDFCompilerTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFCompilerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try PublishStarter.install(into: tmp, force: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testCompiles_simpleProject_producesPDF() async throws {
        // Skip if no tectonic anywhere (the same fallback the compiler uses).
        let testBundlePath = Bundle(for: PDFCompilerTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard let _ = try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath)) else {
            throw XCTSkip("tectonic binary not bundled in test host")
        }

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
}
