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

    // MARK: - The RULING-52 characterisation (2026-08-09): what a failure
    // leaves behind, and what it says about it.

    private func makeOrchestrator(
        configStore: PublishConfigStore? = nil,
        jobManager: CompileJobManager = CompileJobManager()
    ) async throws -> (CompileOrchestrator, PublishConfigStore, PublicationStore, CompileJobManager) {
        let cfg = configStore ?? PublishConfigStore(projectURL: tmp)
        let orch = CompileOrchestrator(
            projectURL: tmp, astSource: Src(),
            configStore: cfg,
            publicationStore: PublicationStore(projectURL: tmp),
            snapshotStore: PublicationSnapshotStore(projectURL: tmp),
            jobManager: jobManager,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        return (orch, cfg, PublicationStore(projectURL: tmp), jobManager)
    }

    private var emissionURL: URL {
        tmp.appendingPathComponent(".maugham/publish/EMISSION.md")
    }

    private func snapshotFiles() throws -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: tmp.appendingPathComponent(".maugham/publications").path)) ?? []
    }

    private func exportFiles() throws -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: tmp.appendingPathComponent("Exports").path)) ?? []
    }

    /// M7-PB-002, M7-PB-004 — the refusal half is validate-first: a refused
    /// compile terminates its job as `.failed` and leaves nothing durable
    /// behind EXCEPT the unconditional EMISSION.md refresh (deliberate, F5),
    /// which happens before every guard, refusals included.
    func test_aRefusedCompileLeavesOnlyTheEmissionRefreshAndATerminalJob() async throws {
        let (orch, cfg, pubStore, jobs) = try await makeOrchestrator()
        try await cfg.save(PublishConfig(metadata: .init(title: "Pin", author: "T")))
        guard case .completed = try await orch.compile(format: .epub, label: nil) else {
            return XCTFail("fixture compile failed")
        }
        let snapsBefore = try snapshotFiles()
        let exportsBefore = try exportFiles()
        let catalogBefore = try await pubStore.load().count
        try? FileManager.default.removeItem(at: emissionURL)

        // Rewind next_version to the already-published one → collision refusal.
        let loadedBack = try await cfg.load()
        var back = try XCTUnwrap(loadedBack)
        back.nextVersion = "0.1"
        try await cfg.save(back)
        let outcome = try await orch.compile(format: .epub, label: nil)
        guard case .failed(let errors, _) = outcome else {
            return XCTFail("expected the collision refusal, got \(outcome)")
        }
        XCTAssertTrue(errors.first?.message.contains("already exists") == true)

        XCTAssertEqual(try snapshotFiles(), snapsBefore, "M7-PB-002: no snapshot")
        XCTAssertEqual(try exportFiles(), exportsBefore, "M7-PB-002: no export")
        let catalogAfter = try await pubStore.load().count
        XCTAssertEqual(catalogAfter, catalogBefore, "M7-PB-002: no catalog row")
        let cfgAfter = try await cfg.load()
        XCTAssertEqual(try XCTUnwrap(cfgAfter).nextVersion, "0.1",
                       "M7-PB-002: no version bump")
        let failed = await jobs.allInProgress()
        XCTAssertTrue(failed.isEmpty, "M7-PB-002: the job is terminal, not in flight")
        XCTAssertTrue(FileManager.default.fileExists(atPath: emissionURL.path),
                      "M7-PB-004: EMISSION.md is rewritten before every guard — "
                      + "refusals included, deliberately (F5)")
    }

    /// M7-PB-003 — a dry run mutates nothing durable except the EMISSION.md
    /// refresh, and terminates in the distinct `dryRunPassed` state.
    func test_aDryRunMutatesNothingDurableExceptTheEmissionRefresh() async throws {
        let (orch, cfg, pubStore, jobs) = try await makeOrchestrator()
        try await cfg.save(PublishConfig(metadata: .init(title: "Pin", author: "T")))
        try? FileManager.default.removeItem(at: emissionURL)

        let outcome = try await orch.compile(format: .epub, label: nil, dryRun: true)
        guard case .dryRunPassed = outcome else {
            return XCTFail("expected dryRunPassed, got \(outcome)")
        }
        XCTAssertEqual(try snapshotFiles(), [], "no snapshot")
        XCTAssertEqual(try exportFiles(), [], "no export")
        let catalog = try await pubStore.load()
        XCTAssertTrue(catalog.isEmpty, "no catalog row")
        let cfgAfter = try await cfg.load()
        XCTAssertEqual(try XCTUnwrap(cfgAfter).nextVersion, "0.1", "no bump")
        XCTAssertTrue(FileManager.default.fileExists(atPath: emissionURL.path))
        let inFlight = await jobs.allInProgress()
        XCTAssertTrue(inFlight.isEmpty, "the dry-run job is terminal")
    }

    /// M7-PB-005, M7-PB-006 — the thrown half is NOT validate-first, and it is
    /// silent about what it left. With the catalog append made to throw (a
    /// directory squatting on this device's publications JSONL path), the
    /// compile has already written the export AND the snapshot; the error that
    /// reaches the caller names neither, and the job record stays
    /// `.inProgress` forever — `compile_status` reports a dead compile as
    /// still compiling.
    func test_aThrowAfterMutationStrandsTheJobAndSaysNothingAboutWhatLanded() async throws {
        let (orch, cfg, _, jobs) = try await makeOrchestrator()
        try await cfg.save(PublishConfig(metadata: .init(title: "Pin", author: "T")))
        // Sabotage: the device's own catalog file path becomes a directory.
        let catalogURL = PublicationStore.fileURL(
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current), in: tmp)
        try FileManager.default.createDirectory(
            at: catalogURL, withIntermediateDirectories: true)

        var thrown: Error?
        do { _ = try await orch.compile(format: .epub, label: nil) }
        catch { thrown = error }
        let error = try XCTUnwrap(thrown, "the append must throw through compile")

        XCTAssertEqual(try exportFiles().count, 1,
                       "M7-PB-006: the export is already in Exports/")
        XCTAssertEqual(try snapshotFiles().count, 1,
                       "M7-PB-006: the snapshot is already persisted")
        let message = String(describing: error)
        XCTAssertFalse(message.contains("Exports"),
                       "M7-PB-006: the error names nothing that landed — found: \(message)")
        let inFlight = await jobs.allInProgress()
        XCTAssertEqual(inFlight.count, 1,
                       "M7-PB-005: the job is stranded in_progress — a poller is "
                       + "told a dead compile is still running")
    }

    /// M7-PB-007 — the commit order is append-then-bump, so a version-bump
    /// failure strands a committed publication behind an unbumped counter (the
    /// file's own TODO). Pinned as a source-order census because
    /// `PublishConfigStore` is an actor with no injection seam: the claim
    /// falls when the order changes or the TODO's two-phase commit arrives.
    func test_theCatalogAppendPrecedesTheVersionBumpAndTheTodoStandsWitness() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Maugham/Publish/CompileOrchestrator.swift"),
            encoding: .utf8)
        let appendAt = try XCTUnwrap(source.range(of: "publicationStore.append(pub)"))
        let bumpAt = try XCTUnwrap(source.range(of: "try await configStore.save(nextConfig)"))
        XCTAssertLessThan(appendAt.lowerBound, bumpAt.lowerBound,
                          "the append precedes the bump — the failure window is "
                          + "publication-committed-version-unbumped")
        XCTAssertTrue(source.contains("TODO: transactional commit"),
                      "the window is the author's own recorded TODO; if the TODO "
                      + "is gone, restate M7-PB-007 against whatever replaced it")
    }

    /// M7-PB-009 — cancellation is advisory and the terminal write wins: a
    /// cancelled job is reported cancelled, nothing polls the token
    /// (`isCancelled` has no production caller), and a compile that finishes
    /// anyway OVERWRITES `.cancelled` with `.completed` — the writer told
    /// "cancelled" gets a publication.
    func test_cancelIsAdvisoryAndTheFinishingCompileOverwritesIt() async throws {
        let jobs = CompileJobManager()
        let id = await jobs.register(phase: .renderingBody)
        let result = await jobs.cancel(jobID: id)
        XCTAssertEqual(result, .cancelled)
        await jobs.complete(jobID: id, outputPath: "/x", warnings: [], errors: [])
        let job = await jobs.get(jobID: id)
        guard case .completed = try XCTUnwrap(job).status else {
            return XCTFail("pin the overwrite: .cancelled was replaced by .completed")
        }
        // The census half: nothing in production polls the token.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let grep = Process()
        grep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        grep.arguments = ["-rn", "isCancelled(jobID:", "--include=*.swift",
                          root.appendingPathComponent("Maugham").path]
        let pipe = Pipe()
        grep.standardOutput = pipe
        try grep.run()
        grep.waitUntilExit()
        let hits = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        let callers = hits.split(separator: "\n")
            .filter { !$0.contains("CompileJobManager.swift") }
        XCTAssertTrue(callers.isEmpty,
                      "M7-PB-009's census: isCancelled has no production caller "
                      + "beyond its own declaration — found: \(callers)")
    }

    /// M7-PB-010 — a preview with no publish config fails its job and then
    /// reports SUCCESS to its caller: `Result(outputPath: "", errors: [])`,
    /// which the tool renders as {status: completed, output_path: ""} — the
    /// "no config" reason never reaches the caller.
    func test_aPreviewWithNoConfigFailsTheJobAndReportsSuccessToTheCaller() async throws {
        let jobs = CompileJobManager()
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: Src(),
            configStore: PublishConfigStore(projectURL: tmp),
            jobManager: jobs,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let result = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertEqual(result.outputPath, "")
        XCTAssertTrue(result.errors.isEmpty,
                      "the empty error list is what the tool reads as success")
        let inFlight = await jobs.allInProgress()
        XCTAssertTrue(inFlight.isEmpty, "while the JOB was failed — two answers "
                      + "to one question, from one call")
    }

    /// M7-PB-008 — the compile path's delete-then-move: with a filename
    /// template that omits {version}, a second source compile renders the SAME
    /// filename and DELETES the first record's bytes before moving its own in
    /// — falsifying M7-PB-001's byte-survival fact on that configuration. The
    /// republish path refuses an occupied destination; the compile path does
    /// not.
    func test_aTemplateWithoutVersionLetsALaterCompileReplaceAnEarlierRecordsBytes() async throws {
        let (orch, cfg, pubStore, _) = try await makeOrchestrator()
        var config = PublishConfig(metadata: .init(title: "Pin", author: "T"))
        config.outputs.filenameTemplate = "{title}.{ext}"
        try await cfg.save(config)

        guard case .completed(let first, _) = try await orch.compile(format: .epub, label: nil)
        else { return XCTFail("first compile failed") }
        let firstURL = tmp.appendingPathComponent(first.outputPath)
        let firstBytes = try Data(contentsOf: firstURL)

        guard case .completed(let second, _) = try await orch.compile(format: .epub, label: nil)
        else { return XCTFail("second compile failed") }
        XCTAssertEqual(second.outputPath, first.outputPath,
                       "same filename — the template carries no {version}")
        XCTAssertNotEqual(try Data(contentsOf: firstURL), firstBytes,
                          "M7-PB-008: the first record's bytes were replaced — "
                          + "its catalog row now points at the second edition's "
                          + "bytes, the disagreement RULING-8 forbids")
        let catalog = try await pubStore.load()
        XCTAssertEqual(catalog.count, 2, "two rows, one file")
    }

    /// M7-PB-011 — the completion event has ONE post site, in
    /// `CompileOrchestrator`: a republish never posts it, so the Exports pane
    /// refreshes after a compile and not after a republish.
    func test_theCompletionEventIsPostedByTheOrchestatorOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let grep = Process()
        grep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        grep.arguments = ["-rln", "maughamPublicationCompleted,", "--include=*.swift",
                          root.appendingPathComponent("Maugham").path]
        let pipe = Pipe()
        grep.standardOutput = pipe
        try grep.run()
        grep.waitUntilExit()
        let hits = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                           encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
            .filter { $0.contains("MaughamEvent.post") || $0.hasSuffix(".swift") }
        // File-level census: the poster list is exactly the orchestrator.
        let posters = hits.filter { $0.hasSuffix(".swift") }
            .filter { path in
                guard let content = try? String(contentsOfFile: path, encoding: .utf8)
                else { return false }
                return content.contains("MaughamEvent.post(\n            .maughamPublicationCompleted")
                    || content.contains("MaughamEvent.post(.maughamPublicationCompleted")
            }
        XCTAssertEqual(posters.map { ($0 as NSString).lastPathComponent },
                       ["CompileOrchestrator.swift"],
                       "M7-PB-011: one poster; Republisher is not it")
    }
}
