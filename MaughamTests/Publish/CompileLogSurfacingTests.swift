import XCTest
@testable import Maugham

@MainActor
final class CompileLogSurfacingTests: XCTestCase {

    var tmp: URL!
    var projectURL: URL!
    var registry: ProjectRegistry!
    var pid: String!

    override func setUp() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompileLogE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "LogTest", in: tmp)
        let store = try await ProjectStore.load(from: projectURL)
        registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        pid = ProjectIdentifier.id(for: projectURL)
        PublishingStores._resetForTesting()
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - compile.log surfacing

    func test_completedResponse_surfacesWarningsAndLogPath() throws {
        let pub = Publication(
            publicationID: "pub-abc123",
            version: "0.1",
            label: nil,
            format: .pdf,
            outputPath: "Exports/test.pdf",
            snapshotID: "snap-xyz",
            checkpointID: "",
            republishedFrom: nil,
            compiledAt: Date(),
            maughamVersion: "0.0.0-test",
            tectonicVersion: "0.15.0")
        let warning = TectonicLogParser.Diagnostic(
            level: .warning,
            file: "prose.tex",
            line: 3,
            message: "Overfull \\hbox",
            contextLines: [])
        let data = try CompileResponseEncoder.encodeCompleted(pub, warnings: [warning])
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["status"] as? String, "completed")
        XCTAssertEqual(obj["log_path"] as? String, "build/compile.log")
        let warnings = try XCTUnwrap(obj["warnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?["message"] as? String, "Overfull \\hbox")
    }

    func testCompile_writesCompileLogToBuildDirectory() async throws {
        // Run a real PDF compile (template already installed by ProjectFactory).
        let pdfData = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":180}"#.utf8),
            registry: registry)
        let pdfResp = try JSONSerialization.jsonObject(with: pdfData) as? [String: Any]
        XCTAssertEqual(pdfResp?["status"] as? String, "completed",
                       "PDF compile failed unexpectedly: \(pdfResp ?? [:])")

        // The compile.log must exist at <projectRoot>/.maugham/publish/build/compile.log
        let compileLog = projectURL
            .appendingPathComponent(".maugham/publish/build/compile.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: compileLog.path),
                      "compile.log not found at \(compileLog.path)")

        let contents = try String(contentsOf: compileLog, encoding: .utf8)
        XCTAssertFalse(contents.isEmpty,
                       "compile.log exists but is empty — expected tectonic output")
    }
}
