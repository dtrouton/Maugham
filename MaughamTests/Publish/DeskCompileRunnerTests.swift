import XCTest
import MaughamCore
@testable import Maugham

/// **The desk's own compile, as a model** (imprints P3 Task 4).
///
/// Until this task there was exactly one production construction of
/// `CompileOrchestrator` — `CompileTool`'s — and the only way to make a book
/// was to ask Claude for one. The runner is the second, and the whole point of
/// it is that it is the SAME construction: the same shared `PublishingStores`,
/// the same unbound `ProjectStoreASTSource`, and the same two toolchain
/// versions, which this task folds out of four separate spellings into
/// `PublishToolchain`.
///
/// **EPUB throughout, so nothing here needs tectonic.** The one thing a PDF
/// would add is the typesetter, and none of these tests is about typesetting —
/// they are about what the runner does with an `Outcome`, which is identical
/// for both formats.
@MainActor
final class DeskCompileRunnerTests: XCTestCase {

    var tmp: URL!
    var projectURL: URL!
    var store: ProjectStore!
    var registry: ProjectRegistry!
    var pid: String!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskCompileRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        projectURL = try await ProjectFactory.createNovelProject(named: "Desk", in: tmp)
        store = try await ProjectStore.load(from: projectURL)
        registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)
        pid = ProjectIdentifier.id(for: projectURL)
        PublishingStores._resetForTesting()
    }

    override func tearDown() async throws {
        PublishingStores._resetForTesting()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Helpers

    private var stores: PublishingStores {
        PublishingStores.sharedFor(projectID: pid, projectURL: projectURL)
    }

    private func book(_ format: PublishConfig.Format = .epub,
                      imprint: String? = nil,
                      languages: [String] = []) -> DeskCompileRunner.Request {
        DeskCompileRunner.Request(format: format, languages: languages,
                                  imprint: imprint, allowStale: false)
    }

    /// Run the runner to a standstill. The compile is a real one, so the wait is
    /// a runloop pump against a deadline rather than a fixed pause.
    private func settle(_ runner: DeskCompileRunner,
                        deadline: TimeInterval = 60,
                        file: StaticString = #filePath,
                        line: UInt = #line) async {
        let done = await pumpUntil(deadline: deadline) { !runner.state.isRunning }
        XCTAssertTrue(done, "the compile never settled — state: \(runner.state.phase)",
                      file: file, line: line)
    }

    /// Seeds the imprint the refusal tests name a sibling of, matching
    /// `CompileToolsTests.seedImprints`.
    @discardableResult
    private func seedImprints() async throws -> PublishConfig {
        let loaded = try await stores.configStore.load()
        var cfg = try XCTUnwrap(loaded)
        cfg.imprints = [
            "special": .init(metadata: ["title": .string("Special Edition")]),
            "other": .init()
        ]
        try await stores.configStore.save(cfg)
        return cfg
    }

    // MARK: - The compile the desk can run

    /// **A press of Compile makes a book.** The whole of Task 4's reason for
    /// existing: a real orchestrator, a real catalog row, and a state the desk
    /// can draw without asking anything else what happened.
    func test_aCompileStartedFromTheDeskLandsARecordAndSaysSo() async throws {
        let runner = DeskCompileRunner()
        runner.start(book(), projectStore: store, projectURL: projectURL)
        XCTAssertTrue(runner.state.isRunning,
                      "the state must say so the moment the press lands — a "
                      + "desk that only learns it is compiling when the compile "
                      + "ends has no progress to draw")
        await settle(runner)

        guard case .completed(let record) = runner.state.phase else {
            return XCTFail("expected a completed compile — got \(runner.state.phase)")
        }
        let catalog = try await stores.publicationStore.load()
        XCTAssertEqual(catalog.map(\.publicationID), [record.publicationID],
                       "the phase carries the row the catalog actually holds")
        XCTAssertEqual(record.format, .epub)
        XCTAssertFalse(runner.state.isRunning)
        XCTAssertEqual(runner.state.statusLine,
                       DepartmentCompileState.completedLine(record))
    }

    /// **One spelling of the toolchain, and this is what proves it.** The
    /// runner's record and the MCP tool's record are compiled by two different
    /// call sites; if either one carried its own literal, these would differ the
    /// day somebody bumped the bundled tectonic in the other file.
    func test_theRecordCarriesTheOneToolchainTheToolAlsoStamps() async throws {
        let runner = DeskCompileRunner()
        runner.start(book(), projectStore: store, projectURL: projectURL)
        await settle(runner)
        guard case .completed(let fromDesk) = runner.state.phase else {
            return XCTFail("expected a completed compile — got \(runner.state.phase)")
        }

        let data = try await CompileTool.handle(
            paramsJSON: Data(#"{"project_id":"\#(pid!)","format":"epub","wait_seconds":120}"#.utf8),
            registry: registry)
        let resp = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(resp?["status"] as? String, "completed",
                       "premise: the tool compiled too — got \(resp ?? [:])")
        let catalog = try await stores.publicationStore.load()
        let fromTool = try XCTUnwrap(catalog.last)
        XCTAssertNotEqual(fromTool.publicationID, fromDesk.publicationID,
                          "premise: two different compiles")

        XCTAssertEqual(fromDesk.tectonicVersion, PublishToolchain.tectonicVersion)
        XCTAssertEqual(fromDesk.maughamVersion, PublishToolchain.maughamVersion)
        XCTAssertEqual(fromDesk.tectonicVersion, fromTool.tectonicVersion,
                       "the desk and the tool must stamp the same bundled "
                       + "tectonic — two literals is how they drift")
        XCTAssertEqual(fromDesk.maughamVersion, fromTool.maughamVersion)
    }

    /// **The completion reaches the centre column.** The preview centre resets
    /// its picker on `.maughamPublicationCompleted`; a compile the desk started
    /// must post it exactly as the tool's does, or the writer presses Compile
    /// and their own book never appears.
    func test_aDeskCompilePostsTheCompletionEventTheCentreRefreshesOn() async throws {
        var receivedIDs: [String] = []
        let observer = NotificationCenter.default.addObserver( // adr-0021-ok: headless test observes the post; the scoped receive helpers are View modifiers
            forName: .maughamPublicationCompleted, object: nil, queue: nil
        ) { note in
            if let id = note.object as? String { receivedIDs.append(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let runner = DeskCompileRunner()
        runner.start(book(), projectStore: store, projectURL: projectURL)
        await settle(runner)
        guard case .completed(let record) = runner.state.phase else {
            return XCTFail("expected a completed compile — got \(runner.state.phase)")
        }
        XCTAssertEqual(receivedIDs, [record.publicationID],
                       "the desk's compile posts the completion event with its "
                       + "own publication id, exactly as the MCP path does")
    }

    /// **An unknown imprint is a refusal, not a failure.** The orchestrator
    /// answers `.failed` for it — a caller's typo that never registered a job —
    /// and the desk must draw that as the refused sentence rather than as a
    /// dead compile, because nothing went wrong with the book.
    func test_anUnknownImprintIsRefusedWithItsOwnSentenceAndNoRow() async throws {
        try await seedImprints()
        let runner = DeskCompileRunner()
        runner.start(book(imprint: "nope"), projectStore: store, projectURL: projectURL)
        await settle(runner)

        guard case .refused(let sentence) = runner.state.phase else {
            return XCTFail("expected a refusal — got \(runner.state.phase)")
        }
        XCTAssertTrue(sentence.contains("unknown imprint 'nope'"), "got: \(sentence)")
        XCTAssertTrue(sentence.contains("other, special"),
                      "the refusal carries the orchestrator's own sentence, "
                      + "which names what this project does define — got: \(sentence)")
        XCTAssertEqual(runner.state.statusLine, sentence)
        let catalog = try await stores.publicationStore.load()
        XCTAssertTrue(catalog.isEmpty, "nothing was compiled — no record, no bump")
    }

    /// **CONTROL for the refusal above**: a real compile failure is still drawn
    /// as a failure, so `.refused` is not swallowing everything the orchestrator
    /// declines to do. A language edition with no source publication is the
    /// nearest deterministic failure that needs no tectonic.
    func test_aRealFailureIsStillDrawnAsAFailure() async throws {
        let runner = DeskCompileRunner()
        runner.start(book(languages: ["es"]), projectStore: store, projectURL: projectURL)
        await settle(runner)

        guard case .failed(let message) = runner.state.phase else {
            return XCTFail("expected a failure — got \(runner.state.phase)")
        }
        XCTAssertTrue(message.contains("no source publication exists"), "got: \(message)")
        XCTAssertEqual(runner.state.statusLine, message)
    }

    /// **One press at a time.** The second press is answered in words and never
    /// starts a second compile — two orchestrators on one project would race
    /// the mint gate and one of them would lose with a sentence about a
    /// collision the writer never caused.
    func test_aSecondPressIsRefusedAndNeverStartsASecondCompile() async throws {
        let runner = DeskCompileRunner()
        runner.start(book(), projectStore: store, projectURL: projectURL)
        runner.start(book(), projectStore: store, projectURL: projectURL)

        guard case .refused(let sentence) = runner.state.phase else {
            return XCTFail("expected the second press to be refused — got \(runner.state.phase)")
        }
        XCTAssertEqual(sentence, DepartmentCompileState.alreadyRunning)
        XCTAssertTrue(runner.state.isRunning,
                      "and the refusal must not have cancelled the run it "
                      + "refused — a desk that reads idle here re-enables its "
                      + "own button mid-compile")

        await settle(runner)
        let catalog = try await stores.publicationStore.load()
        XCTAssertEqual(catalog.count, 1, "one press, one book")
    }

    // MARK: - Cancel

    /// **The writer's cancel reaches THE DESK'S OWN job**, which is the verb
    /// `CompileCancelTool` performs with an id a caller handed it — here, the
    /// id the orchestrator hands back through `onJobRegistered`.
    ///
    /// The premise is asserted rather than assumed: the desk must have learned
    /// an id, and that id must be a job the manager really has in flight.
    ///
    /// Disable experiment: put `cancel()` back to
    /// `allInProgress().last` and this still passes (one job, so the newest IS
    /// this one) — which is exactly why it needs the negative below it. The two
    /// together are the pin.
    func test_cancelCancelsTheJobTheProjectHasInFlight() async throws {
        let runner = DeskCompileRunner()
        XCTAssertNil(runner.currentJobID,
                     "premise: a desk that has pressed nothing owns no job")
        runner.start(book(), projectStore: store, projectURL: projectURL)

        let learned = await pumpUntil(deadline: 10) { runner.currentJobID != nil }
        XCTAssertTrue(learned, "the desk never learned the id of its own compile's job")
        let own = try XCTUnwrap(runner.currentJobID)
        let inFlight = await stores.jobManager.allInProgress().map(\.jobID)
        XCTAssertTrue(inFlight.contains(own),
                      "premise: the id the desk owns must be a job the manager "
                      + "really has in flight \u{2014} in flight: \(inFlight)")

        runner.cancel()

        var status: CompileJob.Status?
        let deadline = Date().addingTimeInterval(10)
        repeat {
            status = await stores.jobManager.get(jobID: own)?.status
            if case .cancelled = status { break }
            await waitOut(0.05)
        } while Date() < deadline
        if case .cancelled = status {} else {
            XCTFail("cancel must reach the desk's own in-flight job — got "
                    + "\(String(describing: status))")
        }
        await settle(runner)
        XCTAssertNil(runner.currentJobID,
                     "a settled desk owns no job, so a later press of Cancel "
                     + "has nothing to aim at")
    }

    /// **The desk's Cancel never takes somebody else's compile with it** —
    /// the branch's one Critical, and the reason `onJobRegistered` exists.
    ///
    /// One `CompileJobManager` serves the whole project. `PreviewCompiler`
    /// (every `preview_compile` Claude runs) and the designer's
    /// `SampleCompiler` register on it and pass through no mint gate, so
    /// "the newest job in flight" — which is what `cancel()` used to take —
    /// is as likely to be Claude's preview as the writer's own book. The
    /// consequence was not a stuck button: the preview died, the BOOK went on
    /// and published itself, under a Cancel whose help says nothing is
    /// published.
    ///
    /// The foreign job is registered AFTER the press, which is precisely the
    /// ordering `allInProgress().last` gets wrong.
    ///
    /// Disable experiment: restore
    /// `guard let job = await stores.jobManager.allInProgress().last else { return }`
    /// and this fails with `the desk's Cancel took a foreign job with it —
    /// got Optional(cancelled)`. The control is the test directly above: the
    /// desk's OWN job really is cancelled by the same press, so this is not a
    /// Cancel that has simply stopped working.
    func test_aForeignJobOnTheSharedManagerIsNotTheDesksToCancel() async throws {
        let runner = DeskCompileRunner()
        runner.start(book(), projectStore: store, projectURL: projectURL)
        let learned = await pumpUntil(deadline: 10) { runner.currentJobID != nil }
        XCTAssertTrue(learned, "premise: the desk knows which job is its own")
        let own = try XCTUnwrap(runner.currentJobID)

        // A preview compile, or a designer sample: somebody else's job on the
        // same shared manager, newer than the desk's.
        let foreign = await stores.jobManager.register(phase: .renderingBody)
        XCTAssertNotEqual(own, foreign)
        let newest = await stores.jobManager.allInProgress().last?.jobID
        XCTAssertEqual(newest, foreign,
                       "premise: the foreign job is the NEWEST in flight — the "
                       + "one the old `allInProgress().last` would have taken")

        runner.cancel()
        await settle(runner)
        // A generous wait after the settle, so a cancel that merely arrived
        // late still fails this rather than passing on timing.
        await waitOut(0.3)

        let foreignStatus = await stores.jobManager.get(jobID: foreign)?.status
        guard case .inProgress = foreignStatus else {
            return XCTFail("the desk's Cancel took a foreign job with it — got "
                           + "\(String(describing: foreignStatus))")
        }
    }

    /// **A Cancel with no compile of its own does nothing** — before the first
    /// press, and again once one has settled. Not a crash and not somebody
    /// else's job: nothing.
    func test_aCancelWithNoCompileOfItsOwnTouchesNothing() async throws {
        let runner = DeskCompileRunner()
        let foreign = await stores.jobManager.register(phase: .renderingBody)

        runner.cancel()          // before any press: no stores, no job
        await waitOut(0.2)
        XCTAssertNil(runner.currentJobID)

        runner.start(book(), projectStore: store, projectURL: projectURL)
        await settle(runner)
        XCTAssertNil(runner.currentJobID, "the settled desk released its job")

        runner.cancel()          // after the compile ended: an id it no longer has
        await waitOut(0.2)

        let status = await stores.jobManager.get(jobID: foreign)?.status
        guard case .inProgress = status else {
            return XCTFail("a desk with no compile of its own cancelled "
                           + "something — got \(String(describing: status))")
        }
    }

    /// **A cancelled compile publishes nothing and is not drawn as a failure**
    /// (`DepartmentRunTests.test_aCancelIsNotDrawnAsAFailure`, in this
    /// surface's currency).
    ///
    /// The race is removed rather than won: `CompileJobManager
    /// ._cancelJobsAtRegistrationForTesting` makes every job this manager hands
    /// out born cancelled, so the orchestrator's one cancellation checkpoint —
    /// after the render, before the snapshot — is reached with the token
    /// already set, every run. Polling `allInProgress()` and racing the EPUB
    /// writer would have been the alternative, and it is a coin flip.
    func test_aCancelledCompileLeavesNoRecordAndIsNotAFailure() async throws {
        await stores.jobManager._cancelJobsAtRegistrationForTesting(true)
        let runner = DeskCompileRunner()
        runner.start(book(), projectStore: store, projectURL: projectURL)
        await settle(runner)

        XCTAssertEqual(runner.state.phase, .idle,
                       "a cancel is the writer's own act and leaves the desk "
                       + "where it started — got \(runner.state.phase)")
        XCTAssertEqual(runner.state.statusLine, DepartmentCompileState.cancelledLine)
        if case .failed = runner.state.phase {
            XCTFail("a cancel must not wear a failure's sentence")
        }
        let catalog = try await stores.publicationStore.load()
        XCTAssertTrue(catalog.isEmpty, "no catalog row")
    }

    // MARK: - What the desk draws (pure state)

    func test_theRunningLineNamesTheBookTheFormatAndTheLanguages() {
        let state = DepartmentCompileState(
            phase: .running(format: .pdf, languages: ["en", "sr"], imprint: nil),
            isRunning: true)
        XCTAssertEqual(state.statusLine,
                       "Compiling the book as PDF (en + sr)\u{2026}")
    }

    func test_theRunningLineSpellsTheImprintWhenThereIsOne() {
        let state = DepartmentCompileState(
            phase: .running(format: .epub, languages: ["sr"], imprint: "special-glb"),
            isRunning: true)
        XCTAssertEqual(state.statusLine,
                       "Compiling the special-glb imprint as EPUB (sr)\u{2026}")
    }

    /// A compile with no languages named draws no parenthetical — the desk
    /// spells a source-only compile by passing the book's own tag, and an empty
    /// list has nothing honest to say.
    func test_theRunningLineDropsTheParentheticalWhenNoLanguageWasNamed() {
        let state = DepartmentCompileState(
            phase: .running(format: .epub, languages: [], imprint: nil),
            isRunning: true)
        XCTAssertEqual(state.statusLine, "Compiling the book as EPUB\u{2026}")
    }

    /// **Task 6 widened this line to draw `PublishPreviewCentre.parts(for:)`**,
    /// which also appends when the compile happened — so this pins the parts
    /// that identify the EDITION (version, imprint, language) in order, and
    /// the wrapper text, rather than the exact compiled-at string (locale- and
    /// clock-dependent, and already `parts(for:)`'s own concern to get right).
    func test_theCompletedLineNamesTheVersionTheImprintAndTheEdition() {
        let pub = Self.publication(version: "0.1", imprint: "special-glb", language: "en+sr")
        let line = DepartmentCompileState.completedLine(pub)
        XCTAssertTrue(
            line.hasPrefix("Compiled v0.1 \u{00B7} special-glb \u{00B7} EN+SR \u{00B7} "),
            "expected version, imprint and edition in that order before the "
            + "compiled date, got: \(line)")
        XCTAssertTrue(line.hasSuffix("\u{2014} in Exports"),
                      "expected the file location at the end, got: \(line)")
    }

    /// The book's own edition carries neither an imprint nor a language, and
    /// the line must not grow empty separators for them — only the version and
    /// the compiled date remain.
    func test_theCompletedLineOfThePlainBookIsJustItsVersion() {
        let pub = Self.publication(version: "0.2", imprint: nil, language: nil)
        let line = DepartmentCompileState.completedLine(pub)
        XCTAssertTrue(line.hasPrefix("Compiled v0.2 \u{00B7} "),
                      "expected just the version before the compiled date — no "
                      + "empty separators for the absent imprint/language, got: \(line)")
        XCTAssertTrue(line.hasSuffix("\u{2014} in Exports"),
                      "expected the file location at the end, got: \(line)")
        XCTAssertFalse(line.contains("special-glb"),
                       "the plain book must not carry the other test's imprint")
    }

    func test_anIdleDeskThatHasCompiledNothingSaysNothing() {
        XCTAssertNil(DepartmentCompileState().statusLine)
    }

    /// Every `Outcome` the orchestrator can answer maps to exactly one state,
    /// and the mapping is a pure function so the desk's drawing is testable
    /// without a compile.
    func test_everyOutcomeSettlesIntoOneState() {
        let pub = Self.publication(version: "0.1", imprint: nil, language: nil)
        XCTAssertEqual(DepartmentCompileState.settled(after: .completed(pub, warnings: [])),
                       DepartmentCompileState(phase: .completed(pub), isRunning: false))

        let diag = TectonicLogParser.Diagnostic(
            level: .error, file: nil, line: nil, message: "it broke", contextLines: [])
        XCTAssertEqual(
            DepartmentCompileState.settled(after: .failed(errors: [diag], logExcerpt: "")),
            DepartmentCompileState(phase: .failed("it broke"), isRunning: false))

        XCTAssertEqual(
            DepartmentCompileState.settled(after: .failed(
                errors: [diag],
                logExcerpt: CompileOrchestrator.unknownImprintLogExcerpt + "nope")),
            DepartmentCompileState(phase: .refused("it broke"), isRunning: false),
            "the orchestrator's own marker is what tells a typo from a failure")

        XCTAssertEqual(
            DepartmentCompileState.settled(after: .cancelled),
            DepartmentCompileState(phase: .idle, isRunning: false,
                                   report: DepartmentCompileState.cancelledLine))

        XCTAssertEqual(
            DepartmentCompileState.settled(after: .dryRunPassed(warnings: [])),
            DepartmentCompileState(phase: .idle, isRunning: false,
                                   report: DepartmentCompileState.dryRunLine))
    }

    /// A failure with no diagnostics at all still says something — a red desk
    /// with an empty line is the dead control RULING-35 is about.
    func test_aFailureWithNoDiagnosticStillSaysSomething() {
        let state = DepartmentCompileState.settled(
            after: .failed(errors: [], logExcerpt: ""))
        XCTAssertEqual(state.phase, .failed(DepartmentCompileState.failedWithoutADiagnostic))
        XCTAssertFalse(state.statusLine?.isEmpty ?? true)
    }

    private static func publication(version: String,
                                    imprint: String?,
                                    language: String?) -> Publication {
        Publication(
            publicationID: "pub-\(version)", version: version, label: nil,
            format: .epub, outputPath: "Exports/x.epub", snapshotID: "s",
            checkpointID: "", republishedFrom: nil, compiledAt: Date(),
            maughamVersion: "0.0.0-test", tectonicVersion: "n/a",
            language: language, allowStale: false, imprint: imprint)
    }
}
