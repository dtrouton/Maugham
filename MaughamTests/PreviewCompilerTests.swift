import XCTest
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
        try? FileManager.default.removeItem(at: tmp)
    }

    func testPreview_doesNotBumpVersion() async throws {
        let testBundlePath = Bundle(for: PreviewCompilerTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard let _ = try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath)) else {
            throw XCTSkip("tectonic missing")
        }

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
}
