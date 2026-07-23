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
}
