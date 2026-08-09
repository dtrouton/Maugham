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

    /// M7-PB-005, M7-PB-006 — fixed under RULING-7 + RULING-52 (2026-08-09):
    /// a failure after the first durable mutation surfaces as `.failed` with
    /// the DurableProgress ledger naming what landed (the export, the
    /// snapshot) and what did not, and the job record is terminal — never
    /// stranded `.inProgress` about a dead compile.
    func test_aFailureAfterMutationNamesWhatLandedAndTheJobIsTerminal() async throws {
        let (orch, cfg, _, jobs) = try await makeOrchestrator()
        try await cfg.save(PublishConfig(metadata: .init(title: "Pin", author: "T")))
        // Injection: the device's own catalog file path becomes a directory,
        // so the append throws AFTER the export and snapshot have landed.
        let catalogURL = PublicationStore.fileURL(
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current), in: tmp)
        try FileManager.default.createDirectory(
            at: catalogURL, withIntermediateDirectories: true)

        let outcome = try await orch.compile(format: .epub, label: nil)
        guard case .failed(let errors, _) = outcome else {
            return XCTFail("M7-PB-005: the thrown error surfaces as .failed, got \(outcome)")
        }
        XCTAssertEqual(try exportFiles().count, 1, "the export landed")
        XCTAssertEqual(try snapshotFiles().count, 1, "the snapshot landed")
        let context = (errors.first?.contextLines ?? []).joined(separator: "\n")
        XCTAssertTrue(context.contains("Exports/") && context.lowercased().contains("snapshot"),
                      "M7-PB-006: the failure names both — found: \(context)")
        let inFlight = await jobs.allInProgress()
        XCTAssertTrue(inFlight.isEmpty,
                      "M7-PB-005: the job is terminal — compile_status tells the truth")
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

    /// M7-PB-009 — fixed under RULING-22 (2026-08-09): the writer's cancel
    /// STANDS. A late terminal write never overwrites `.cancelled`, and the
    /// token census now expects the two production pollers (the orchestrator's
    /// and the republisher's pre-commit checks) that make "cancelled" mean
    /// nothing was published.
    func test_cancelStandsAndTheTokenHasItsPreCommitPollers() async throws {
        let jobs = CompileJobManager()
        let id = await jobs.register(phase: .renderingBody)
        let cancelResult = await jobs.cancel(jobID: id)
        XCTAssertEqual(cancelResult, .cancelled)
        await jobs.complete(jobID: id, outputPath: "/x", warnings: [], errors: [])
        let job = await jobs.get(jobID: id)
        guard case .cancelled = try XCTUnwrap(job).status else {
            return XCTFail("a late complete overwrote .cancelled")
        }
        // The census half: the token is polled where it matters — before the
        // durable commit in BOTH pipelines.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let grep = Process()
        grep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        grep.arguments = ["-rl", "isCancelled(jobID:", "--include=*.swift",
                          root.appendingPathComponent("Maugham").path]
        let pipe = Pipe()
        grep.standardOutput = pipe
        try grep.run()
        grep.waitUntilExit()
        let hits = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                           encoding: .utf8) ?? "")
            .split(separator: "\n").map { ($0 as NSString).lastPathComponent }
            .sorted()
        XCTAssertEqual(hits, ["CompileJobManager.swift", "CompileOrchestrator.swift",
                              "Republisher.swift"],
                       "the declaration and its two pre-commit pollers — found: \(hits)")
    }

    /// M7-PB-010 — fixed under RULING-7 (2026-08-09): a preview with no
    /// publish config carries its cause in `Result.errors`, so the tool
    /// renders the failed shape — one call, one answer.
    func test_aPreviewWithNoConfigReportsItsCauseAsAFailure() async throws {
        let jobs = CompileJobManager()
        let preview = PreviewCompiler(
            projectURL: tmp, astSource: Src(),
            configStore: PublishConfigStore(projectURL: tmp),
            jobManager: jobs,
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a")
        let result = try await preview.preview(format: .epub, sectionIDs: nil, maxPages: nil)
        XCTAssertEqual(result.outputPath, "")
        XCTAssertTrue(result.errors.first?.message.contains("config") == true,
                      "the cause reaches the caller — found: "
                      + String(describing: result.errors.first?.message))
        let inFlight = await jobs.allInProgress()
        XCTAssertTrue(inFlight.isEmpty, "and the job agrees: terminal, failed")
    }

    /// M7-PB-008 — fixed under RULING-8 (2026-08-09): the compile path
    /// refuses an occupied destination exactly as the republish path does,
    /// so a template without {version} can no longer let a later compile
    /// replace an earlier record's bytes. Previews keep overwriting their
    /// own output — that half is deliberate and pinned in
    /// `PreviewCompilerTests.testPreview_overwritesItsOwnPriorOutput`.
    func test_anOccupiedDestinationRefusesAndTheEarlierRecordsBytesSurvive() async throws {
        let (orch, cfg, pubStore, _) = try await makeOrchestrator()
        var config = PublishConfig(metadata: .init(title: "Pin", author: "T"))
        config.outputs.filenameTemplate = "{title}.{ext}"
        try await cfg.save(config)

        guard case .completed(let first, _) = try await orch.compile(format: .epub, label: nil)
        else { return XCTFail("first compile failed") }
        let firstURL = tmp.appendingPathComponent(first.outputPath)
        let firstBytes = try Data(contentsOf: firstURL)

        let outcome = try await orch.compile(format: .epub, label: nil)
        guard case .failed(let errors, _) = outcome else {
            return XCTFail("expected the occupied refusal, got \(outcome)")
        }
        XCTAssertTrue(errors.first?.message.contains("refusing to overwrite") == true)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes,
                       "the first record's bytes survive — the catalog and the "
                       + "disk keep agreeing")
        let catalog = try await pubStore.load()
        XCTAssertEqual(catalog.count, 1, "and no second row was minted")
    }

    /// M7-PB-011 — fixed under RULING-8 (2026-08-09): BOTH pipelines post the
    /// completion event, so the Exports pane refreshes after a republish the
    /// same as after a compile.
    func test_theCompletionEventIsPostedByBothPipelines() throws {
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
        XCTAssertEqual(posters.map { ($0 as NSString).lastPathComponent }.sorted(),
                       ["CompileOrchestrator.swift", "Republisher.swift"],
                       "M7-PB-011: both pipelines post it")
    }
}
