import XCTest
@testable import Maugham

/// Tests that EPUBCompiler persists build/body.xhtml for inspection via
/// `read_publish_file build/body.xhtml` (open-loop iteration workflow).
final class EPUBBodyArtifactTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPUBBodyArtifactTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_epubCompile_persistsBodyXhtml() async throws {
        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "Chapter One",
                       mode: .prose, displayText: "The quick brown fox.")]
            }
        }
        let cfg = PublishConfig(metadata: .init(title: "ArtifactSmoke", author: "T"))
        let mgr = CompileJobManager()
        let compiler = EPUBCompiler(
            projectURL: tmp, astSource: Src(), config: cfg,
            jobManager: mgr, maughamVersion: "0.0.0-test",
            tectonicVersion: "n/a")

        _ = try await compiler.compile(label: nil)

        let bodyXhtml = tmp
            .appendingPathComponent(".maugham/publish/build/body.xhtml")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bodyXhtml.path),
            "build/body.xhtml not found at \(bodyXhtml.path)")

        let contents = try String(contentsOf: bodyXhtml, encoding: .utf8)
        XCTAssertTrue(
            contents.contains("<section"),
            "build/body.xhtml does not contain <section — contents: \(contents.prefix(500))")
    }
}
