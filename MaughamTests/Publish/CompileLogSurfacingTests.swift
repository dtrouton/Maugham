import XCTest
@testable import Maugham

@MainActor
final class CompileLogSurfacingTests: XCTestCase {

    var tmp: URL!
    var projectURL: URL!
    var registry: ProjectRegistry!
    var pid: String!

    // Mirrors PublishingEndToEndTests: in the xctest harness Bundle.main isn't
    // the host .app, so TectonicLocator.locate() returns nil even though
    // tectonic is bundled. Probe the host explicitly.
    private func tectonicAvailable() -> Bool {
        let testBundlePath = Bundle(for: CompileLogSurfacingTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        return (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil
    }

    override func setUp() async throws {
        guard tectonicAvailable() else {
            throw XCTSkip("tectonic binary not bundled in test host — full E2E requires bundled binary")
        }
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
