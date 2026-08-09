import XCTest
import MaughamCore
@testable import Maugham

/// CHARACTERISATION of `Maugham/Publish/Republisher.swift`'s mint-before-compile
/// guarantee (issue #25, P1: commit 680f2ff1b0c819494b5949aa82e6a19cf73041e0).
///
/// Claim id `M7-PB-001` corresponds to `register/reconciliation/Publications.claims.json`
/// — the register's FIRST publish claim, filed WITH the fix rather than excavated
/// after. This pin is a tighter restatement of two of `RepublisherTests`' P1
/// tests (`test_republishLeavesTheOriginalArtifactBytesUntouched` and
/// `test_twoRepublishesProduceTwoNewDistinctFiles`) for permanence: it must
/// fail if either fact — distinct catalog paths, or an existing record's
/// untouched bytes — ever regresses.
@MainActor
final class PublicationsCharacterization: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PubChar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private struct Src: ProjectASTBuilder.Source {
        func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
            [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
        }
    }

    // MARK: - Republisher.republish / CompileOrchestrator.compile

    /// M7-PB-001 — every catalog record's outputPath resolves to a distinct
    /// file, and the bytes at an existing record's outputPath are not
    /// modified by any later compile or republish.
    func test_M7PB001_everyCatalogRecordHasADistinctPath_andEarlierBytesSurviveALaterRepublish() async throws {
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Pin", author: "T")))

        let pubStore = PublicationStore(projectURL: tmp)
        let snapStore = PublicationSnapshotStore(projectURL: tmp)

        // 1. Original compile creates the first catalog record + artifact.
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let initial = try await orch.compile(format: .epub, label: nil)
        guard case .completed(let initialPub, _) = initial else {
            XCTFail("initial compile failed: \(initial)")
            return
        }
        let originalURL = tmp.appendingPathComponent(initialPub.outputPath)
        let originalBytes = try Data(contentsOf: originalURL)
        XCTAssertFalse(originalBytes.isEmpty, "fixture sanity: original artifact must be non-empty")

        // 2. Two republishes from the same snapshot, both with no label — the
        //    collision case, since nothing external disambiguates the name.
        let r = Republisher(
            projectURL: tmp, astSource: Src(),
            publicationStore: pubStore, snapshotStore: snapStore,
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let first = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed(let firstPub, _) = first else {
            XCTFail("first republish failed: \(first)")
            return
        }
        let second = try await r.republish(
            snapshotID: initialPub.snapshotID, format: .epub, label: nil)
        guard case .completed(let secondPub, _) = second else {
            XCTFail("second republish failed: \(second)")
            return
        }

        // FACT 1: every catalog record resolves to a distinct outputPath.
        let allPaths = [initialPub.outputPath, firstPub.outputPath, secondPub.outputPath]
        XCTAssertEqual(Set(allPaths).count, 3,
            "every catalog record must resolve to a distinct outputPath, got \(allPaths)")

        // FACT 2: the EARLIEST record's bytes survive both later republishes,
        // verbatim — not just existence, the bytes themselves.
        let bytesAfter = try Data(contentsOf: originalURL)
        XCTAssertEqual(bytesAfter, originalBytes,
            "an existing record's bytes must not be modified by any later compile or republish")

        // Every distinct path still resolves to a real file on disk.
        for path in allPaths {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: tmp.appendingPathComponent(path).path),
                "expected a surviving file at \(path)")
        }
    }
}
