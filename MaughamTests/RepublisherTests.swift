import XCTest
@testable import Maugham

@MainActor
final class RepublisherTests: XCTestCase {

    var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepubTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try await PublishStarter.install(into: tmp, force: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testRepublish_usesSnapshotTemplate_notCurrent() async throws {
        let testBundlePath = Bundle(for: RepublisherTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard let _ = try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath)) else {
            throw XCTSkip("tectonic missing")
        }

        struct Src: ProjectASTBuilder.Source {
            func orderedPieces() -> [ProjectASTBuilder.PieceRef] {
                [.init(pieceID: "p1", title: "C", mode: .prose, displayText: "Hello.")]
            }
        }
        let configStore = PublishConfigStore(projectURL: tmp)
        try await configStore.save(PublishConfig(metadata: .init(title: "Repub", author: "T")))

        // 1. Initial compile creates v0.1 + snapshot.
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: configStore,
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let initial = try await orch.compile(format: .pdf, label: nil)
        guard case .completed(let initialPub) = initial else {
            XCTFail("initial failed: \(initial)")
            return
        }

        // 2. Mutate the live template to be invalid LaTeX. If Republisher
        //    used live state, this would break the compile.
        let templateURL = tmp.appendingPathComponent(".maugham/publish/template.tex")
        try "\\undefined_command_xyz".write(
            to: templateURL, atomically: true, encoding: .utf8)

        // 3. Republish from the original snapshot — succeeds because it uses
        //    the snapshotted template.
        let r = Republisher(
            projectURL: tmp,
            astSource: Src(),
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: CompileJobManager(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0")
        let outcome = try await r.republish(
            snapshotID: initialPub.snapshotID,
            format: .pdf, label: nil)
        switch outcome {
        case .completed(let pub):
            XCTAssertEqual(pub.republishedFrom, "0.1")
        case .failed(let errors, let log):
            XCTFail("republish failed: errors=\(errors.map(\.message)) log=\(log.prefix(300))")
        }
    }
}
