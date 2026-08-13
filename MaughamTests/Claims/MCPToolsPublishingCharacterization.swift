import XCTest
import MaughamCore
@testable import Maugham

/// MCP/Tools characterisation — register module MCPTools
/// (register/reconciliation/MCPTools.{claims,filings}.json). PERMANENT pinned
/// suite: a red test here means a pinned MCP tool-failure behaviour changed.

/// Characterisation of the MCP **publishing** family's FAILURE surface.
///
/// Every assertion here was written from printed probe output, not from
/// reading the handlers. What is pinned is what Claude actually sees: the
/// rendered `MCPToolsCallHandler.toolErrorPayload(for:)` shape for a thrown
/// error, and the response body for a refusal that returns rather than
/// throws. Several of these pin behaviour that is arguably wrong — they are
/// characterisation tests, so a red one means the behaviour moved, not that
/// the test is broken.
///
/// No tectonic compile runs here: every case is a refusal path or a dry run.
@MainActor
final class MCPToolsPublishingCharacterization: XCTestCase {

    var tmp: URL!
    var registry: ProjectRegistry!
    var pid: String!
    var projectURL: URL!

    /// Paths chmod-ed to 000 by a test; restored in tearDown so the temp tree
    /// can be removed.
    private var lockedPaths: [String] = []

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPPublishingProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "T", in: tmp)
        let store = try await ProjectStore.load(from: projectURL)
        registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        pid = ProjectIdentifier.id(for: projectURL)
        PublishingStores._resetForTesting()
        lockedPaths = []
    }

    override func tearDown() async throws {
        for p in lockedPaths {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: p)
        }
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - helpers

    private func lock(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: url.path)
        lockedPaths.append(url.path)
    }

    /// The payload Claude sees for a thrown tool error.
    private func rendered(_ error: Error) -> MCPError.ToolErrorPayload {
        MCPToolsCallHandler.toolErrorPayload(for: error)
    }

    /// Call a tool expecting a THROW, and return the rendered payload.
    private func payload(
        _ body: () async throws -> Data,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> MCPError.ToolErrorPayload? {
        do {
            _ = try await body()
            XCTFail("expected a throw", file: file, line: line)
            return nil
        } catch {
            return rendered(error)
        }
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func errorMessages(_ resp: [String: Any]) -> String {
        ((resp["errors"] as? [[String: Any]]) ?? [])
            .compactMap { $0["message"] as? String }.joined(separator: " | ")
    }

    private func contextLines(_ resp: [String: Any]) -> [String] {
        ((resp["errors"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["context_lines"] as? [String]) ?? [] }
    }

    private func stores() -> PublishingStores {
        PublishingStores.sharedFor(projectID: pid, projectURL: projectURL)
    }

    private func seedPublication(
        id: String = "pub-seed", version: String = "0.1",
        format: PublishConfig.Format = .pdf, language: String? = nil,
        outputPath: String = "Exports/T-v0.1.pdf",
        snapshotID: String = "snap-seed"
    ) async throws {
        try await stores().publicationStore.append(Publication(
            publicationID: id, version: version, label: nil, format: format,
            outputPath: outputPath, snapshotID: snapshotID, checkpointID: "",
            republishedFrom: nil, compiledAt: Date(),
            maughamVersion: "0.0.0-test", tectonicVersion: "0.15.0",
            language: language))
    }

    private var publishDir: URL {
        projectURL.appendingPathComponent(".maugham/publish", isDirectory: true)
    }

    private var configURL: URL {
        publishDir.appendingPathComponent("config.json")
    }

    // MARK: - The publications catalog: unreadable

    /// `PublicationStore.load` throws a named `ReadError.unreadableFile`
    /// carrying the RULING-54 sentence in `errorDescription` — but the three
    /// tools that call it let it escape to the generic fall-through arm of
    /// `toolErrorPayload(for:)`. Claude sees `internal_error` and the enum's
    /// REFLECTED form, so the filename and the OS cause survive while the
    /// guidance sentence does not.
    func test_unreadableCatalog_rendersAsInternalErrorLosingTheRuling54Sentence() async throws {
        try await seedPublication()
        let catalog = try XCTUnwrap(PublicationStore.fileURLs(in: projectURL).first)
        try lock(catalog)

        let calls: [(String, () async throws -> Data)] = [
            ("list_publications", {
                try await ListPublicationsTool.handle(
                    paramsJSON: Data(#"{"project_id":"\#(self.pid!)"}"#.utf8),
                    registry: self.registry) }),
            ("read_publication_page", {
                try await ReadPublicationPageTool.handle(
                    paramsJSON: Data(#"{"project_id":"\#(self.pid!)","version":"0.1","page_number":1}"#.utf8),
                    registry: self.registry) }),
            ("republish", {
                try await RepublishTool.handle(
                    paramsJSON: Data(#"{"project_id":"\#(self.pid!)","snapshot_id":"snap-seed"}"#.utf8),
                    registry: self.registry) })
        ]
        for (name, call) in calls {
            let p = await payload(call)
            XCTAssertEqual(p?.error, "internal_error", "\(name)")
            XCTAssertTrue(p?.message.hasPrefix("unreadableFile(name:") == true,
                          "\(name) got: \(p?.message ?? "")")
            XCTAssertTrue(p?.message.contains(catalog.lastPathComponent) == true, "\(name)")
            XCTAssertTrue(p?.message.contains("permission") == true, "\(name)")
            // The store's own guidance never reaches the caller.
            XCTAssertFalse(p?.message.contains("overwrite or collide") == true, "\(name)")
            XCTAssertNil(p?.hint, "\(name)")
        }
    }

    /// `compile` is the one caller that catches the same error and renders it
    /// properly: the full `errorDescription`, plus the "nothing landed" line,
    /// inside the ordinary `status: failed` body.
    func test_unreadableCatalog_refusesCompilePreFlightWithTheFullSentence() async throws {
        try await seedPublication()
        let catalog = try XCTUnwrap(PublicationStore.fileURLs(in: projectURL).first)
        try lock(catalog)

        let resp = json(try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":5}"#.utf8),
            registry: registry))
        XCTAssertEqual(resp["status"] as? String, "failed")
        XCTAssertEqual(resp["log_excerpt"] as? String, "publications catalog unreadable")
        let msg = errorMessages(resp)
        XCTAssertTrue(msg.contains("exists but can't be read"), msg)
        XCTAssertTrue(msg.contains("overwrite or collide with an edition you already published"), msg)
        XCTAssertEqual(
            contextLines(resp),
            ["Nothing was compiled — no export, no snapshot, no version bump."])
    }

    /// The strictness is about UNREADABLE files only. A catalog that is
    /// readable but carries undecodable lines is silently short: the rows that
    /// failed to parse are dropped, the response carries no diagnostic key,
    /// and every write-adjacent consumer proceeds against the shorter list.
    func test_corruptCatalogLines_readShortWithNoDiagnostic() async throws {
        try await seedPublication()
        let catalog = try XCTUnwrap(PublicationStore.fileURLs(in: projectURL).first)
        let good = try String(contentsOf: catalog, encoding: .utf8)
        try (good + "{\"publication_id\": TRUNCATED\n" + "not json at all\n")
            .write(to: catalog, atomically: true, encoding: .utf8)

        let resp = json(try await ListPublicationsTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8), registry: registry))
        XCTAssertEqual(resp.keys.sorted(), ["publications"])
        XCTAssertEqual((resp["publications"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - publish files: absent vs unreadable

    /// RULING-54's line for `read_publish_file`: the two are distinguishable —
    /// absent is a named `invalid_argument`, unreadable-yet-present is the
    /// generic `internal_error` carrying the raw Cocoa error (which does say
    /// "permission", and does leak the absolute on-disk path).
    func test_readPublishFile_absentIsInvalidArgument_unreadableIsInternalError() async throws {
        let absent = await payload {
            try await ReadPublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","path":"nope.tex"}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(absent?.error, "invalid_argument")
        XCTAssertEqual(absent?.message, "file not found: nope.tex")

        try lock(publishDir.appendingPathComponent("template.tex"))
        let unreadable = await payload {
            try await ReadPublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","path":"template.tex"}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(unreadable?.error, "internal_error")
        XCTAssertTrue(unreadable?.message.contains("NSCocoaErrorDomain Code=257") == true,
                      unreadable?.message ?? "")
        XCTAssertTrue(unreadable?.message.contains("template.tex") == true)
        XCTAssertTrue(unreadable?.message.contains(publishDir.path) == true,
                      "the absolute on-disk path reaches the caller")

        // read_publish_image's absent arm is the same named refusal.
        let image = await payload {
            try await ReadPublishImageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","path":"cover.jpg"}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(image?.error, "invalid_argument")
        XCTAssertEqual(image?.message, "image not found: cover.jpg")
    }

    /// The DIRECTORY has no such protection: an unreadable `.maugham/publish/`
    /// is reported as an empty publish tree, not as a failure. `list_publish_files`
    /// builds its enumerator with `try?` and a nil enumerator reads as "no files".
    func test_listPublishFiles_unreadableDirectoryReadsAsEmpty() async throws {
        try lock(publishDir)
        let resp = json(try await ListPublishFilesTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8), registry: registry))
        XCTAssertEqual((resp["files"] as? [Any])?.count, 0)
        XCTAssertEqual((resp["build_artifacts"] as? [Any])?.count, 0)
        XCTAssertNil(resp["error"])
    }

    // MARK: - publish config

    /// An ABSENT config is the documented `source: "defaults"`; a corrupt or
    /// unreadable one is never silently defaulted — both throw, both render as
    /// `internal_error` carrying the raw Swift/Cocoa error.
    func test_getPublishConfig_absentIsDefaults_corruptAndUnreadableAreInternalError() async throws {
        try FileManager.default.removeItem(at: configURL)
        let defaults = json(try await GetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)"}"#.utf8), registry: registry))
        XCTAssertEqual(defaults["source"] as? String, "defaults")

        try "{ not json".write(to: configURL, atomically: true, encoding: .utf8)
        let corrupt = await payload {
            try await GetPublishConfigTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)"}"#.utf8), registry: self.registry)
        }
        XCTAssertEqual(corrupt?.error, "internal_error")
        XCTAssertTrue(corrupt?.message.contains("dataCorrupted") == true,
                      corrupt?.message ?? "")

        try "{}".write(to: configURL, atomically: true, encoding: .utf8)
        try lock(configURL)
        let unreadable = await payload {
            try await GetPublishConfigTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)"}"#.utf8), registry: self.registry)
        }
        XCTAssertEqual(unreadable?.error, "internal_error")
        XCTAssertTrue(unreadable?.message.contains("Code=257") == true)
    }

    /// RULING-52 for `set_publish_config`: nothing half-lands. A patch whose
    /// TYPES don't fit the config throws out of the decode — before any save —
    /// and is rendered as `internal_error` even though the fault is the
    /// caller's; a patch that decodes but fails VALIDATION returns the ordinary
    /// body with `errors` and saves nothing.
    func test_setPublishConfig_malformedPatchPersistsNothing() async throws {
        let before = try String(contentsOf: configURL, encoding: .utf8)

        let mismatch = await payload {
            try await SetPublishConfigTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","patch":{"next_version":5}}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(mismatch?.error, "internal_error")
        XCTAssertTrue(mismatch?.message.contains("typeMismatch") == true, mismatch?.message ?? "")
        XCTAssertTrue(mismatch?.message.contains("next_version") == true)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)

        let invalid = json(try await SetPublishConfigTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","patch":{"outputs":{"directory":"../escape"}}}"#.utf8),
            registry: registry))
        let fields = ((invalid["errors"] as? [[String: Any]]) ?? [])
            .compactMap { $0["field"] as? String }
        XCTAssertEqual(fields, ["outputs.directory"])
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), before)
    }

    /// The read half of the read-modify-write is equally strict: an unreadable
    /// `config.json` refuses the patch rather than patching a default config
    /// over the writer's real one.
    func test_setPublishConfig_unreadableConfigRefusesBeforeWriting() async throws {
        try lock(configURL)
        let p = await payload {
            try await SetPublishConfigTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","patch":{"next_version":"9.9"}}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(p?.error, "internal_error")
        XCTAssertTrue(p?.message.contains("Code=257") == true)
    }

    /// DEFECT PIN (deliberately not exercised end-to-end). `SetPublishConfigTool`
    /// guards only that `patch` is PRESENT, then hands the value straight to
    /// `JSONSerialization.data(withJSONObject:)`. A scalar — `"patch":"hello"`
    /// or `"patch":null` — is not a valid top-level JSON object, and that call
    /// raises an Objective-C `NSInvalidArgumentException`, which Swift cannot
    /// catch: the probe run aborted the host process
    /// ("Crash: Maugham at <external symbol>. libsystem_c.dylib: abort()
    /// called"). Calling the handler here would take the whole test process
    /// down with it, so this pins the precondition instead — the values a
    /// client can send that the handler forwards unchecked.
    func test_setPublishConfig_nonObjectPatchIsUnguarded() throws {
        XCTAssertFalse(JSONSerialization.isValidJSONObject("hello"))
        XCTAssertFalse(JSONSerialization.isValidJSONObject(NSNull()))
    }

    // MARK: - compile refusals

    /// Every compile refusal that survives version resolution arrives as an
    /// ordinary SUCCESS response with `status: "failed"` — not as a thrown
    /// error, so a client keying on `isError` sees the call as having worked.
    /// The refusal names its remedy.
    func test_compileRefusals_arriveAsStatusFailedNotAsToolErrors() async throws {
        try await seedPublication(version: "0.1", format: .pdf, language: nil)
        let collision = json(try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":5}"#.utf8),
            registry: registry))
        XCTAssertEqual(collision["status"] as? String, "failed")
        XCTAssertEqual(collision["log_excerpt"] as? String, "version_collision: 0.1/source/pdf")
        XCTAssertTrue(
            errorMessages(collision)
                .contains("Publication v0.1 (source, pdf) already exists; refusing to compile a colliding edition."),
            errorMessages(collision))
        XCTAssertTrue(contextLines(collision).contains {
            $0.contains("Bump next_version via set_publish_config")
        })
    }

    /// The `PublishMintGate` refusal is reachable without a real compile: hold
    /// the triple on the project's SHARED gate and the next compile of it is
    /// refused as in-flight, with the same `status: failed` shape.
    func test_compile_mintGateInFlightRefusalNamesThePollingRemedy() async throws {
        let gate = stores().mintGate
        let key = PublishMintGate.Key(version: "0.1", language: nil, format: .pdf)
        let reserved = await gate.reserve(key)
        XCTAssertTrue(reserved)

        let resp = json(try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","wait_seconds":5}"#.utf8),
            registry: registry))
        await gate.release(key)

        XCTAssertEqual(resp["status"] as? String, "failed")
        XCTAssertEqual(resp["log_excerpt"] as? String, "mint_in_flight: 0.1/source/pdf")
        XCTAssertTrue(errorMessages(resp).contains("is already compiling; wait for it to finish"),
                      errorMessages(resp))
        XCTAssertTrue(contextLines(resp).contains { $0.contains("Poll it with compile_status") })
    }

    /// The refusals that fire BEFORE version resolution do throw: an invalid
    /// language tag and any malformed params. So `compile` has two refusal
    /// channels, and which one a caller gets depends on how far in it failed.
    func test_compile_earlyRefusalsThrowInsteadOfReturningFailed() async throws {
        let badTag = await payload {
            try await CompileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","format":"pdf","language":"not a tag!","wait_seconds":5}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(badTag?.error, "invalid_argument")
        XCTAssertEqual(badTag?.message, "invalid language tag: not a tag!")

        for params in [Data(#"{"project_id":"\#(pid!)"}"#.utf8), nil] as [Data?] {
            let p = await payload {
                try await CompileTool.handle(paramsJSON: params, registry: self.registry)
            }
            XCTAssertEqual(p?.error, "invalid_argument")
            XCTAssertEqual(p?.message, "malformed or missing parameters for compile")
        }
    }

    /// `dry_run` mints nothing: no Publication, no catalog file at all, no
    /// version bump, no `Exports/`, no snapshot directory. It is NOT inert on
    /// disk though — it rewrites `.maugham/publish/EMISSION.md`, which the
    /// orchestrator documents as deliberate ("dry_run included").
    func test_compileDryRun_mintsNothingButStillRewritesEmissionMd() async throws {
        let fm = FileManager.default
        let emission = publishDir.appendingPathComponent("EMISSION.md")
        try "SENTINEL".write(to: emission, atomically: true, encoding: .utf8)
        let configBefore = try String(contentsOf: configURL, encoding: .utf8)

        let resp = json(try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"pdf","dry_run":true,"wait_seconds":30}"#.utf8),
            registry: registry))
        XCTAssertEqual(resp["status"] as? String, "dry_run_passed")
        XCTAssertEqual((resp["warnings"] as? [Any])?.count, 0)

        let pubs = try await stores().publicationStore.load()
        XCTAssertEqual(pubs.count, 0)
        XCTAssertEqual(PublicationStore.fileURLs(in: projectURL).count, 0)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), configBefore)
        XCTAssertFalse(fm.fileExists(atPath: projectURL.appendingPathComponent("Exports").path))
        XCTAssertFalse(fm.fileExists(
            atPath: projectURL.appendingPathComponent(".maugham/publications").path))

        let emissionAfter = try String(contentsOf: emission, encoding: .utf8)
        XCTAssertNotEqual(emissionAfter, "SENTINEL",
                          "a dry run refreshes EMISSION.md — the one file it does write")
        XCTAssertGreaterThan(emissionAfter.count, 1000)
    }

    // MARK: - rasterizing failures

    /// `read_preview_page` distinguishes "no preview" (a named, actionable
    /// `invalid_argument`) from a preview PDF that exists and won't open — the
    /// latter is a generic `internal_error` that names the absolute path but
    /// not whether the file is corrupt, truncated, or unreadable.
    func test_readPreviewPage_noPreviewIsNamed_unopenablePdfIsInternalError() async throws {
        let noPreview = await payload {
            try await ReadPreviewPageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","page_number":1}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(noPreview?.error, "invalid_argument")
        XCTAssertEqual(noPreview?.message, "No preview output — run preview_compile first")

        let previewDir = projectURL.appendingPathComponent(
            PreviewCompiler.previewSubpath, isDirectory: true)
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
        try "not a pdf".write(to: previewDir.appendingPathComponent("preview.pdf"),
                              atomically: true, encoding: .utf8)
        let corrupt = await payload {
            try await ReadPreviewPageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","page_number":1}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(corrupt?.error, "internal_error")
        XCTAssertTrue(corrupt?.message.hasPrefix("could not open preview PDF at ") == true,
                      corrupt?.message ?? "")

        // A newer EPUB beside it is a named refusal, not a fall-back to the PDF.
        let epub = previewDir.appendingPathComponent("preview.epub")
        try "epub".write(to: epub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: epub.path)
        let epubLatest = await payload {
            try await ReadPreviewPageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","page_number":1}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(epubLatest?.error, "invalid_argument")
        XCTAssertTrue(epubLatest?.message.contains("is an EPUB; only PDF previews can be rasterized") == true,
                      epubLatest?.message ?? "")
    }

    /// A catalog row whose output file is gone renders as `internal_error`
    /// naming the absolute path — the addressing succeeded, so the refusal is
    /// about the artifact, but nothing distinguishes "deleted" from "corrupt",
    /// and nothing points at the catalog row that is now dangling.
    func test_readPublicationPage_missingOutputFileIsInternalError() async throws {
        try await seedPublication(outputPath: "Exports/gone.pdf")
        let p = await payload {
            try await ReadPublicationPageTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","version":"0.1","page_number":1}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(p?.error, "internal_error")
        XCTAssertTrue(p?.message.hasPrefix("could not open PDF at ") == true, p?.message ?? "")
        XCTAssertTrue(p?.message.contains("gone.pdf") == true)
    }

    /// `republish` with an unknown `snapshot_id` never reaches a named refusal:
    /// the snapshot read throws a raw Cocoa "no such file" that lands in the
    /// fall-through arm. Compare `read_publication_page`'s unknown
    /// `publication_id`, which IS a named `invalid_argument`.
    func test_republish_unknownSnapshotIdSurfacesTheRawCocoaError() async throws {
        let p = await payload {
            try await RepublishTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","snapshot_id":"snap-nope"}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(p?.error, "internal_error")
        XCTAssertTrue(p?.message.contains("NSCocoaErrorDomain Code=260") == true, p?.message ?? "")
        XCTAssertTrue(p?.message.contains("snap-nope.json") == true)
        XCTAssertFalse(p?.message.contains("snapshot_id") == true,
                       "the refusal never names the parameter the caller got wrong")
    }

    // MARK: - path containment

    /// `..` is refused on both write paths, and nothing lands. But
    /// `PublishPath.validateAndResolve` standardizes without RESOLVING
    /// symlinks, so a symlink already inside `.maugham/publish/` lets
    /// `write_publish_file` place bytes anywhere on disk and report
    /// `{"status":"written"}`. DEFECT PIN — not reachable through the publish
    /// tools alone (they cannot create the symlink), but reachable through a
    /// symlink the writer, an unpacked archive, or a sync client left there.
    func test_publishPath_refusesDotDotButFollowsASymlinkOutOfTheProject() async throws {
        let write = await payload {
            try await WritePublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","path":"../../escape.tex","content":"x"}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(write?.error, "invalid_argument")
        XCTAssertEqual(write?.message, "path must not contain '..' segments")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("escape.tex").path))

        let delete = await payload {
            try await DeletePublishFileTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","path":"../../../etc/hosts"}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(delete?.error, "invalid_argument")
        XCTAssertEqual(delete?.message, "path must not contain '..' segments")

        let outside = tmp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: publishDir.appendingPathComponent("out"), withDestinationURL: outside)
        let resp = json(try await WritePublishFileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","path":"out/evil.tex","content":"pwned"}"#.utf8),
            registry: registry))
        XCTAssertEqual(resp["status"] as? String, "written")
        XCTAssertEqual(
            try String(contentsOf: outside.appendingPathComponent("evil.tex"), encoding: .utf8),
            "pwned",
            "the write escaped .maugham/publish/ through the symlink")
    }

    // MARK: - id and parameter refusals

    /// The family's unknown-project refusal is the canonical structured one,
    /// with a hint and the offending id in `fields`; `set_publish_config`,
    /// which decodes its params by hand, still reaches the same helper and
    /// still names a missing `patch`.
    func test_unknownProjectAndMissingParams_areNamed() async throws {
        for call in [
            { try await ListPublicationsTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_nope"}"#.utf8), registry: self.registry) },
            { try await SetPublishConfigTool.handle(
                paramsJSON: Data(#"{"project_id":"proj_nope","patch":{}}"#.utf8), registry: self.registry) }
        ] as [() async throws -> Data] {
            let p = await payload(call)
            XCTAssertEqual(p?.error, "unknown_project_id")
            XCTAssertEqual(p?.message, "Project ID 'proj_nope' is not open on this server.")
            XCTAssertNotNil(p?.hint)
            XCTAssertEqual(p?.fields["project_id"], .string("proj_nope"))
        }

        let noPatch = await payload {
            try await SetPublishConfigTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)"}"#.utf8), registry: self.registry)
        }
        XCTAssertEqual(noPatch?.error, "invalid_argument")
        XCTAssertEqual(noPatch?.message, "patch required")
    }

    /// `set_piece_style` validates fully before it touches disk: an unknown
    /// piece and an unreadable config each refuse with `pieces/` never created
    /// and no style file written (RULING-52's "nothing half-lands" shape).
    func test_setPieceStyle_refusalsLeaveNothingBehind() async throws {
        let piecesDir = publishDir.appendingPathComponent("pieces")

        let unknown = await payload {
            try await SetPieceStyleTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","piece_id":"nope","content":"% x"}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(unknown?.error, "invalid_argument")
        XCTAssertEqual(unknown?.message,
                       "no piece 'nope' in this project; call get_outline for valid piece ids")
        XCTAssertFalse(FileManager.default.fileExists(atPath: piecesDir.path))

        let entry = try XCTUnwrap(registry.lookup(id: pid))
        let realID = try XCTUnwrap(
            ProjectStore.collectDocuments(in: entry.store.manifest.structure).first?.id)
        try lock(configURL)
        let unreadable = await payload {
            try await SetPieceStyleTool.handle(
                paramsJSON: Data(#"{"project_id":"\#(self.pid!)","piece_id":"\#(realID)","content":"% x"}"#.utf8),
                registry: self.registry)
        }
        XCTAssertEqual(unreadable?.error, "internal_error")
        XCTAssertTrue(unreadable?.message.contains("Code=257") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: piecesDir.path))
    }
}
