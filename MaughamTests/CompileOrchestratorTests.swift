import XCTest
@testable import Maugham

@MainActor
final class CompileOrchestratorTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testCompile_pdf_writesPublicationAndSnapshot_andBumpsVersion() async throws {
        // Skip if no tectonic.
        let testBundlePath = Bundle(for: CompileOrchestratorTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard let _ = try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath)) else {
            throw XCTSkip("tectonic missing")
        }

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hi.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(
            metadata: .init(title: "Orch", author: "T")))

        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0")

        let result = try await orch.compile(format: .pdf, label: nil)
        switch result {
        case .completed(let pub):
            XCTAssertEqual(pub.version, "0.1")
            XCTAssertEqual(pub.format, .pdf)
        default:
            XCTFail("expected completed, got \(result)")
        }

        // Verify next compile bumps to 0.2.
        let r2 = try await orch.compile(format: .pdf, label: nil)
        if case .completed(let pub) = r2 {
            XCTAssertEqual(pub.version, "0.2")
        } else {
            XCTFail("expected completed")
        }

        // Verify publications.jsonl exists with 2 entries.
        let pubs = try await PublicationStore(projectURL: tmp).load()
        XCTAssertEqual(pubs.count, 2)
    }

    // MARK: - D3c: pre-compile version-collision guard

    func testCompile_refusesWhenNextVersionCollidesWithExistingPublication() async throws {
        // Seed a publication at version 0.1 directly, then manually set
        // config.next_version back to "0.1" (simulates a writer rolling
        // the counter back via set_publish_config). The next compile must
        // refuse with a structured version_collision diagnostic.
        let configStore = PublishConfigStore(projectURL: tmp)
        var cfg = PublishConfig(metadata: .init(title: "Collide", author: "T"))
        cfg.nextVersion = "0.1"
        try await configStore.save(cfg)

        let pubStore = PublicationStore(projectURL: tmp)
        try await pubStore.append(Publication(
            publicationID: "pub-pre-existing",
            version: "0.1", label: nil, format: .pdf,
            outputPath: "Exports/pre.pdf",
            snapshotID: "snap-x", checkpointID: "",
            republishedFrom: nil,
            compiledAt: Date(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0"))

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "x")]
            }
        }
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore,
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0")

        let result = try await orch.compile(format: .pdf, label: nil)
        switch result {
        case .failed(let errs, let log):
            XCTAssertFalse(errs.isEmpty, "expected structured error in errors[]")
            XCTAssertTrue(errs.contains { $0.message.contains("0.1") && $0.message.lowercased().contains("already exists") })
            XCTAssertTrue(log.contains("version_collision"))
        case .completed:
            XCTFail("expected .failed due to version collision; got .completed")
        }

        // Verify no new Publication was minted.
        let pubs = try await pubStore.load()
        XCTAssertEqual(pubs.count, 1,
                       "collision guard must not append a colliding Publication")
        XCTAssertEqual(pubs.first?.publicationID, "pub-pre-existing")
    }
}
