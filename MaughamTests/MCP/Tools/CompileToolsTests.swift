import XCTest
import MaughamCore
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
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
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
    //
    // Edition identity (spec 2026-07-23): a language edition now renders an
    // EXISTING source version rather than minting its own, so seed a source
    // publication first — without it the es compile fails loudly ("compile the
    // source edition first"). The edition's version must equal the source's.
    func testCompile_pdf_language_completedSync_surfacesLanguageKey() async throws {
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
        let stores = PublishingStores.sharedFor(projectID: pid, projectURL: projectURL)
        try await stores.publicationStore.append(Publication(
            publicationID: "pub-src", version: "0.1", label: nil, format: .pdf,
            outputPath: "Exports/src.pdf", snapshotID: "snap-src", checkpointID: "",
            republishedFrom: nil, compiledAt: Date(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0", language: nil))

        let data = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","language":"es","wait_seconds":120}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "completed",
                       "unexpected response: \(resp ?? [:])")
        XCTAssertEqual(resp?["language"] as? String, "es")
        XCTAssertEqual(resp?["version"] as? String, "0.1",
                       "es edition renders the source version, not a new one")
    }

    // Edition identity (spec 2026-07-23): tool-level refusal shapes. These fail
    // during version resolution / the collision guard — BEFORE any tectonic
    // compile — so they're deterministic without a bundled tectonic.

    /// A `language` compile with no source publication surfaces the standard
    /// failed shape naming the remedy.
    func testCompile_language_noSourcePublication_returnsFailed() async throws {
        let data = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"epub","language":"es","wait_seconds":1}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "failed",
                       "unexpected response: \(resp ?? [:])")
        let errors = resp?["errors"] as? [[String: Any]]
        let message = (errors ?? []).compactMap { $0["message"] as? String }.joined()
        XCTAssertTrue(message.contains("compile the source edition first"),
                      "got: \(message)")
    }

    /// `version:` without `language:` is refused at the tool boundary too.
    func testCompile_versionWithoutLanguage_returnsFailed() async throws {
        let data = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"epub","version":"0.1","wait_seconds":1}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "failed",
                       "unexpected response: \(resp ?? [:])")
        let errors = resp?["errors"] as? [[String: Any]]
        let message = (errors ?? []).compactMap { $0["message"] as? String }.joined()
        XCTAssertTrue(message.contains("requires a language"), "got: \(message)")
    }

    func testCompile_returnsJobID_whenWaitExpired() async throws {
        // wait_seconds=0 forces an immediate timeout. With tectonic
        // present, a real PDF compile takes ~400ms after the cache is
        // warm, so this races: if the orchestrator hasn't finished by
        // the post-timeout lookup we get "in_progress" + a job_id; if
        // it has, we get "completed". Both are valid handoff shapes.
        //
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
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
        // Reads the real premise: tectonic bundled AND its TeX bundle obtainable.
        try await TectonicProbe.requireReady()
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

    /// F2 review fix 1: a dry_run job's terminal state must survive a
    /// `compile_status` poll (reachable via the wait_seconds:0 timeout race) —
    /// it reports `dry_run_passed` + warnings, NOT a completed job with an
    /// empty output_path.
    func testStatus_dryRunJob_reportsDryRunPassed() async throws {
        let stores = PublishingStores.sharedFor(projectID: pid, projectURL: projectURL)
        let jobID = await stores.jobManager.register(phase: .renderingBody)
        let warning = TectonicLogParser.Diagnostic(
            level: .warning, file: nil, line: nil,
            message: "Chapter One: 1 missing (¶abcd) — compiled with source-text fallback",
            contextLines: [])
        await stores.jobManager.completeDryRun(jobID: jobID, warnings: [warning])

        let data = try await CompileStatusTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","job_id":"\#(jobID)"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "dry_run_passed",
                       "polled dry_run job must not degrade: \(resp ?? [:])")
        XCTAssertNil(resp?["output_path"], "dry_run has no output")
        let warnings = resp?["warnings"] as? [[String: Any]]
        XCTAssertEqual(warnings?.count, 1)
        XCTAssertTrue((warnings?.first?["message"] as? String ?? "").contains("¶abcd"))
    }

    /// F2 review fix 2: tool-level parity pin — a gate-blocked
    /// `preview_compile` returns the standard failed JSON shape through
    /// `PreviewCompileTool.handle` itself: `status: failed`, itemized `errors`
    /// diagnostics, `log_excerpt`, and `log_path`.
    func testPreview_gateBlocked_returnsStandardFailedShape() async throws {
        // Real-content fixture: overwrite the starter doc BEFORE first
        // Document.load so Bootstrap mints anchors, translate only the first
        // paragraph, leave the second missing — the es gate must block.
        let fixtureURL = try await ProjectFactory.createNovelProject(
            named: "GateShape-\(UUID().uuidString.prefix(6))", in: tmp)
        let probe = try await ProjectStore.load(from: fixtureURL)
        let item = try XCTUnwrap(
            ProjectStore.collectDocuments(in: probe.manifest.structure).first)
        let path = try XCTUnwrap(item.path)
        try """
        First paragraph.

        Second paragraph.
        """.write(to: fixtureURL.appendingPathComponent(path),
                  atomically: true, encoding: .utf8)
        let doc = try await Document.load(
            url: fixtureURL.appendingPathComponent(path),
            device: "test", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: fixtureURL)
        registry.register(url: fixtureURL, store: store)
        let fixturePid = ProjectIdentifier.id(for: fixtureURL)

        let ids = doc.sequence
        try await TranslationStore.append(
            TranslationRecord(
                paragraphId: ids[0], language: "es", text: "Primero.",
                sourceHash: TranslationHash.hash(doc.paragraphs[ids[0]] ?? ""),
                verbatim: false),
            forDocId: item.id, deviceSlug: DeviceSlug.make(from: "test-mac"),
            in: fixtureURL)

        let data = try await PreviewCompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(fixturePid)","format":"epub","language":"es"}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "failed",
                       "gate block must surface as failed: \(resp ?? [:])")
        let errors = resp?["errors"] as? [[String: Any]]
        XCTAssertFalse(errors?.isEmpty ?? true, "failed shape must itemize errors")
        let message = (errors ?? []).compactMap { $0["message"] as? String }.joined()
        XCTAssertTrue(message.contains("¶\(ids[1])"),
                      "gate error must list the missing ¶id, got: \(message)")
        XCTAssertEqual(resp?["log_excerpt"] as? String, "translation_stale: es",
                       "failed shape must carry the gate logExcerpt")
        XCTAssertEqual(resp?["log_path"] as? String, "build/compile.log",
                       "failed shape must carry log_path (compile parity)")
    }

    // MARK: - F2: schema round-trip for the new params

    func testSchema_compile_declaresDryRun() throws {
        let obj = try JSONSerialization.jsonObject(
            with: Data(CompileTool.inputSchemaJSON.utf8)) as? [String: Any]
        let props = obj?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["dry_run"], "compile schema must declare dry_run")
    }

    // Edition identity (spec 2026-07-23): the pinned-version param is advertised.
    func testSchema_compile_declaresVersion() throws {
        let obj = try JSONSerialization.jsonObject(
            with: Data(CompileTool.inputSchemaJSON.utf8)) as? [String: Any]
        let props = obj?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["version"], "compile schema must declare version")
    }

    func testSchema_preview_declaresLanguageAndAllowStale() throws {
        let obj = try JSONSerialization.jsonObject(
            with: Data(PreviewCompileTool.inputSchemaJSON.utf8)) as? [String: Any]
        let props = obj?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["language"], "preview schema must declare language")
        XCTAssertNotNil(props?["allow_stale"], "preview schema must declare allow_stale")
    }
}
