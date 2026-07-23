import XCTest
@testable import Maugham

@MainActor
final class CompileToolsTests: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!
    var projectURL: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompileToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "T", in: tmp)
        // ProjectFactory installs the publish starter; template.tex / styles.css / config.json present.
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

    // MARK: - compile

    func testCompile_pdf_completedSync_whenWithinWait() async throws {
        // Mirror PDFCompilerTests' lookup: in the xctest harness,
        // Bundle.main isn't the host .app, so locate() returns nil even
        // though tectonic is bundled. Probe the host explicitly.
        let testBundlePath = Bundle(for: CompileToolsTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil else {
            throw XCTSkip("tectonic binary not bundled in test host")
        }
        let data = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":120}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "completed",
                       "unexpected response: \(resp ?? [:])")
        XCTAssertEqual(resp?["format"] as? String, "pdf")
        XCTAssertNotNil(resp?["output_path"])
        XCTAssertNotNil(resp?["version"])
        // Same conditional-key precedent as "label": absent when no
        // language was requested (finding 3 companion — see the
        // language-present case below).
        XCTAssertNil(resp?["language"])
    }

    // Finding 3: `CompileResponseEncoder.encodeCompleted` surfaced `label`
    // but not `language`. A language compile's response must carry the tag
    // so callers (and republish flows) can see which edition was produced.
    func testCompile_pdf_language_completedSync_surfacesLanguageKey() async throws {
        let testBundlePath = Bundle(for: CompileToolsTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil else {
            throw XCTSkip("tectonic binary not bundled in test host")
        }
        let data = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","language":"es","wait_seconds":120}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "completed",
                       "unexpected response: \(resp ?? [:])")
        XCTAssertEqual(resp?["language"] as? String, "es")
    }

    func testCompile_returnsJobID_whenWaitExpired() async throws {
        // wait_seconds=0 forces an immediate timeout. With tectonic
        // present, a real PDF compile takes ~400ms after the cache is
        // warm, so this races: if the orchestrator hasn't finished by
        // the post-timeout lookup we get "in_progress" + a job_id; if
        // it has, we get "completed". Both are valid handoff shapes.
        let testBundlePath = Bundle(for: CompileToolsTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil else {
            throw XCTSkip("tectonic binary not bundled in test host")
        }
        let data = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":0}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = resp?["status"] as? String
        switch status {
        case "in_progress":
            XCTAssertNotNil(resp?["job_id"])
            XCTAssertNotNil(resp?["phase"])
            XCTAssertNotNil(resp?["started_at"])
        case "completed":
            XCTAssertEqual(resp?["format"] as? String, "pdf")
            XCTAssertNotNil(resp?["output_path"])
        default:
            XCTFail("expected in_progress or completed, got: \(resp ?? [:])")
        }
    }

    func testCompile_unknownProject_throws() async throws {
        do {
            _ = try await CompileTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_notreal","format":"pdf","wait_seconds":1}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    // MARK: - compile_status

    func testStatus_returnsNotFound_forUnknownJob() async throws {
        let data = try await CompileStatusTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","job_id":"bogus"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "not_found")
    }

    func testStatus_unknownProject_throws() async throws {
        do {
            _ = try await CompileStatusTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_nope","job_id":"x"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    // MARK: - compile_cancel

    func testCancel_unknown_returnsNotFound() async throws {
        let data = try await CompileCancelTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","job_id":"bogus"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "not_found")
    }

    func testCancel_unknownProject_throws() async throws {
        do {
            _ = try await CompileCancelTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_nope","job_id":"x"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    // MARK: - preview_compile

    func testPreview_pdf_runs() async throws {
        // Mirror PDFCompilerTests' lookup: in the xctest harness,
        // Bundle.main isn't the host .app, so locate() returns nil even
        // though tectonic is bundled. Probe the host explicitly.
        let testBundlePath = Bundle(for: CompileToolsTests.self).bundlePath
        let appPath = testBundlePath.replacingOccurrences(
            of: "/Contents/PlugIns/MaughamTests.xctest", with: "")
        guard (try? TectonicLocator.locateInBundle(
            at: URL(fileURLWithPath: appPath))) != nil else {
            throw XCTSkip("tectonic binary not bundled in test host")
        }
        let data = try await PreviewCompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "completed",
                       "unexpected response: \(resp ?? [:])")
        XCTAssertNotNil(resp?["output_path"])
    }

    func testPreview_unknownProject_throws() async throws {
        do {
            _ = try await PreviewCompileTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_notreal","format":"pdf"}"#.utf8),
                registry: registry)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "unknown_project_id")
        }
    }

    // F2: preview_compile validates `language` the same way compile does.
    func testPreview_invalidLanguageTag_rejected() async throws {
        await XCTAssertThrowsErrorAsync(
            try await PreviewCompileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","language":"ES!"}"#.utf8),
                registry: registry)
        ) { error in
            guard case MCPError.invalidArgument = error else {
                return XCTFail("expected MCPError.invalidArgument, got \(error)")
            }
        }
    }

    // MARK: - F2: compile dry_run

    /// dry_run returns `dry_run_passed` (no tectonic needed — it short-circuits
    /// before compiling) and mints no Publication.
    func testCompile_dryRun_returnsDryRunPassed_noPublication() async throws {
        let data = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","dry_run":true}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "dry_run_passed",
                       "unexpected response: \(resp ?? [:])")
        XCTAssertNotNil(resp?["warnings"])

        let stores = PublishingStores.sharedFor(projectID: pid, projectURL: projectURL)
        let pubs = try await stores.publicationStore.load()
        XCTAssertTrue(pubs.isEmpty, "dry_run must not mint a Publication")
    }

    // MARK: - F2: schema round-trip for the new params

    func testSchema_compile_declaresDryRun() throws {
        let obj = try JSONSerialization.jsonObject(
            with: Data(CompileTool.inputSchemaJSON.utf8)) as? [String: Any]
        let props = obj?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["dry_run"], "compile schema must declare dry_run")
    }

    func testSchema_preview_declaresLanguageAndAllowStale() throws {
        let obj = try JSONSerialization.jsonObject(
            with: Data(PreviewCompileTool.inputSchemaJSON.utf8)) as? [String: Any]
        let props = obj?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["language"], "preview schema must declare language")
        XCTAssertNotNil(props?["allow_stale"], "preview schema must declare allow_stale")
    }
}
