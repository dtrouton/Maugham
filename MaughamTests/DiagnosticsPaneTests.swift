import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The pane the compiler's notes land on** (M2 Task 8). The header states
/// are pure — `DiagnosticsPane.headerState(...)` derives one from
/// `(runState, lastRun, noteCount, docId)` with no view mounted — so each of
/// the six is a fast, direct assertion. Version-bump re-render, the gear
/// menu's persistence, and the two real buttons (Cancel, Open Intent) need a
/// live pane, so those are mounted for real, the way
/// `InspectorIntentAffordanceTests` presses an inspector's own button rather
/// than calling the closure it happens to name.
@MainActor
final class DiagnosticsPaneTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() {
        temp = TempDirectory()
        warmUpAccessibility()
    }

    /// The FIRST accessibility query against a freshly-launched test host has
    /// been observed to succeed once and then report an empty tree on every
    /// following query for several seconds — a cold-start hiccup in the
    /// assistive-client connection, not a rendering problem (measured here:
    /// identical code that finds a button reliably once the process has been
    /// running a while finds nothing at all as the suite's first AX-touching
    /// test). Absorbing the hiccup here, once, keeps every real test's
    /// `button(labelled:in:)` call meaningful.
    private func warmUpAccessibility() {
        let window = mount(AnyView(Button("Warmup") {}))
        for _ in 0..<20 {
            if (try? axTree(in: window))?.isEmpty == false { break }
            pump(0.1)
        }
        window.contentView = NSView(frame: .zero)
        pump(0.05)
    }

    override func tearDown() {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp = nil
    }

    // MARK: - Fixtures

    /// Every fixture carries a `kind`, because a diagnostic without one is by
    /// definition a v1 record and `DiagnosticsStore.load` drops those as
    /// superseded — and this pane calls `load` in its own `onAppear`, so a
    /// kind-less fixture is gone before the mounted view can render it.
    private func makeDiagnostic(
        docId: String, anchor: Diagnostic.Anchor? = nil,
        body: String = "A diagnostic note", category: String? = nil,
        // **The default is the kind the pane still draws** (M4 P1 Task 3):
        // continuity and reader findings mint as annotations now and never
        // reach a sidecar, so a fixture that means "an ordinary row on this
        // pane" means a conformance strain.
        kind: DiagnosticKind = .conformanceStrain,
        refs: [Diagnostic.Ref]? = nil, clauseQuote: String? = nil
    ) -> Diagnostic {
        Diagnostic(id: ULID.generate(), docId: docId, anchor: anchor,
                  body: body, category: category, runId: ULID.generate(), kind: kind,
                  refs: refs, clauseQuote: clauseQuote)
    }

    private func makeRun(model: String = "sonnet", lastOpId: String? = "op1",
                         droppedDangling: Int = 0,
                         clauseStatuses: [DiagnosticIngest.ClauseStatus]? = nil,
                         truncatedReader: Int? = nil,
                         passId: String? = nil, round: Int? = nil,
                         freshEyes: Bool? = nil,
                         mintedNotes: Int? = nil) -> CompilerRun {
        let wholeSecond = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return CompilerRun(id: ULID.generate(), at: wholeSecond, model: model,
                           lastOpId: lastOpId, deltaSummary: "1 new, 0 revised \u{00b6}",
                           intentSnapshot: nil, droppedDangling: droppedDangling,
                           clauseStatuses: clauseStatuses, truncatedReader: truncatedReader,
                           passId: passId, round: round, freshEyes: freshEyes,
                           mintedNotes: mintedNotes)
    }

    private func makeClause(
        _ quote: String, _ status: String, refs: [Diagnostic.Ref] = []
    ) -> DiagnosticIngest.ClauseStatus {
        DiagnosticIngest.ClauseStatus(clauseQuote: quote, status: status, refs: refs)
    }

    /// One paragraph reference, as it reaches the pane: an id nothing renders
    /// and the words that stand in for it.
    private func ref(_ paragraphId: String, _ excerpt: String) -> Diagnostic.Ref {
        Diagnostic.Ref(paragraphId: paragraphId, excerpt: excerpt)
    }

    private func counts(new: Int, revised: Int) -> CompilerOrchestrator.DeltaCounts {
        CompilerOrchestrator.DeltaCounts(new: new, revised: revised)
    }

    /// A loaded novel with its first chapter, and the store an answer writes
    /// through. `wordCountPopulationTask` is awaited so a test asserting
    /// "nothing was written" is not racing `load`'s own tail.
    private func loadedNovel(
        named name: String
    ) async throws -> (url: URL, store: ProjectStore, chapter: StructureItem) {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        let chapter = try XCTUnwrap(
            store.manifest.structure.first, "the novel fixture has no chapter")
        return (url, store, chapter)
    }

    /// What a statement SAYS, derived from its op log alone — never read off
    /// the `.md` beside it, which is derived output (tripwire 20).
    private func derivedText(of statement: Statement, in projectURL: URL) async throws -> String {
        let ops = try await OpLogStore(projectURL: projectURL).load(docId: statement.id)
        let derived = Deriver.derive(ops: ops)
        return derived.sequence.compactMap { derived.paragraphs[$0] }.joined(separator: "\n\n")
    }

    /// Bytes that are not valid UTF-8, so `String(contentsOf:encoding:.utf8)`
    /// throws — the exact call `Document.load` makes with a `try?` and a
    /// silent `?? ""` fallback, which is what `RulingPerformer` refuses over.
    private static let undecodableBytes = Data([0xFF, 0xFE, 0xFD, 0xFC])

    private func pane(
        store: ProjectStore?, diagnostics: DiagnosticsStore, docId: String,
        world: DeclaredWorldStore? = nil,
        currentText: @escaping (String) -> String? = { _ in nil }
    ) -> AnyView {
        AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics, docId: docId,
            currentText: currentText, compilerModel: .standard, store: store, world: world))
    }

    // MARK: - Header state (pure — no mount)

    func test_headerState_neverRun() {
        let state = DiagnosticsPane.headerState(
            runState: .idle, lastRun: nil, noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .neverRun)
    }

    func test_headerState_idleWithLastRunLine() {
        let run = makeRun()
        let state = DiagnosticsPane.headerState(
            runState: .idle, lastRun: run, noteCount: 2, docId: "d1")
        XCTAssertEqual(state, .idle(lastRun: run))
    }

    func test_headerState_running() {
        let state = DiagnosticsPane.headerState(
            runState: .running(docId: "d1", checking: counts(new: 14, revised: 0)),
            lastRun: nil, noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .running(checking: counts(new: 14, revised: 0)))
    }

    // MARK: - The legible wait (requirement 5)

    /// **A two-minute "Checking…" reads as a hang.** The running header names
    /// what the compiler is reading, in the writer's English, from the moment
    /// the run starts — the counts are known before the send, so nothing waits
    /// on the answer to say them.
    func test_theRunningHeaderSaysWhatItIsReading() {
        XCTAssertEqual(
            DiagnosticsPane.headerCopy(for: .running(checking: counts(new: 14, revised: 0))),
            "Checking 14 new paragraphs\u{2026}")
        XCTAssertEqual(
            DiagnosticsPane.headerCopy(for: .running(checking: counts(new: 1, revised: 0))),
            "Checking 1 new paragraph\u{2026}",
            "one paragraph is not \u{201C}1 new paragraphs\u{201D}")
        XCTAssertEqual(
            DiagnosticsPane.headerCopy(for: .running(checking: counts(new: 0, revised: 3))),
            "Checking 3 revised paragraphs\u{2026}")
        XCTAssertEqual(
            DiagnosticsPane.headerCopy(for: .running(checking: counts(new: 14, revised: 3))),
            "Checking 14 new and 3 revised paragraphs\u{2026}")
    }

    /// The arm a delta cannot reach — `beginRun` refuses an empty one before
    /// the running state is ever set — asserted anyway, because a function
    /// whose caller has to reason before calling it is one the next caller gets
    /// wrong.
    func test_theRunningHeaderIsTotalOverCountsADeltaCannotHave() {
        XCTAssertEqual(
            DiagnosticsPane.headerCopy(for: .running(checking: counts(new: 0, revised: 0))),
            "Checking\u{2026}")
        XCTAssertNil(DiagnosticsPane.paragraphPhrase(counts(new: 0, revised: 0)))
    }

    /// And the empty pane says the same thing, off the same spelling — two
    /// sentences about the same two numbers are two things that can disagree.
    func test_theEmptyPaneNamesTheSameDeltaTheHeaderDoes() {
        let empty = DiagnosticsPane.emptyState(for: .running(checking: counts(new: 14, revised: 3)))
        XCTAssertEqual(empty.title, "Checking\u{2026}")
        XCTAssertTrue(empty.description.contains("14 new and 3 revised paragraphs"),
                      "got: \(empty.description)")
    }

    /// A run in flight for a DIFFERENT document does not read as "running"
    /// here — this pane is scoped to one document, and `.running` for another
    /// doc must fall through to whatever the last-run record says.
    func test_headerState_runningAnotherDocFallsThroughToLastRun() {
        let run = makeRun()
        let state = DiagnosticsPane.headerState(
            runState: .running(docId: "other-doc", checking: counts(new: 2, revised: 0)),
            lastRun: run, noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .clean(lastRun: run))
    }

    func test_headerState_nothingNew() {
        let at = Date()
        let state = DiagnosticsPane.headerState(
            runState: .nothingNew(docId: "d1", at: at), lastRun: makeRun(),
            noteCount: 3, docId: "d1")
        XCTAssertEqual(state, .nothingNew(at: at))
    }

    /// "Nothing new since the last check." is a claim about ONE document. Said
    /// over another one it describes a check that document never had — and it
    /// stands until the next run, because nothing else moves the run state.
    func test_headerState_nothingNewForAnotherDocFallsThroughToLastRun() {
        let run = makeRun()
        let state = DiagnosticsPane.headerState(
            runState: .nothingNew(docId: "other-doc", at: Date()), lastRun: run,
            noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .clean(lastRun: run),
            "another document's empty delta must not speak for this one")
    }

    /// The same leak, at its worst: chapter 1's check dies, the writer clicks
    /// chapter 2, and a red failure line is painted over chapter 2's perfectly
    /// good notes.
    func test_headerState_failedForAnotherDocFallsThroughToLastRun() {
        let run = makeRun()
        let state = DiagnosticsPane.headerState(
            runState: .failed(docId: "doc-a", failure: .cliNotFound, at: Date()),
            lastRun: run, noteCount: 2, docId: "doc-b")
        XCTAssertEqual(state, .idle(lastRun: run),
            "a failure belongs to the document it was raised on")
    }

    func test_headerState_failedWithHonestCopy() {
        let at = Date()
        let state = DiagnosticsPane.headerState(
            runState: .failed(docId: "d1", failure: .cliNotFound, at: at),
            lastRun: nil, noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .failed(.cliNotFound, at: at))

        XCTAssertTrue(DiagnosticsPane.failureCopy(.cliNotFound).contains("Claude Code isn't installed"))
        XCTAssertTrue(DiagnosticsPane.failureCopy(.cliNotFound).contains("Settings"))
        XCTAssertTrue(DiagnosticsPane.failureCopy(.disabledByToggle).contains("Claude access is off in Settings"))
        XCTAssertTrue(DiagnosticsPane.failureCopy(.disabledByToggle)
            .contains("Allow Claude to connect (MCP)"),
            "the copy must name the exact Settings toggle (General \u{2192} Claude integration), "
            + "not a paraphrase a writer cannot find")
        XCTAssertFalse(DiagnosticsPane.failureCopy(.timedOut).isEmpty)
        XCTAssertTrue(DiagnosticsPane.failureCopy(.sessionDied(detail: "the CLI exited"))
            .contains("the CLI exited"))
        XCTAssertFalse(DiagnosticsPane.failureCopy(.unusableOutput).isEmpty)
    }

    func test_headerState_cleanRun() {
        let run = makeRun()
        let state = DiagnosticsPane.headerState(
            runState: .idle, lastRun: run, noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .clean(lastRun: run))
    }

    /// The Settings toggle named in `disabledByToggle`'s copy must be the
    /// real one, not a string this suite made up independently — the pane and
    /// `GeneralSettingsTab` are two files that could silently drift.
    func test_disabledByToggleCopy_namesTheRealSettingsToggle() throws {
        let settingsSource = try readSource("Maugham/Views/SettingsTabs/GeneralSettingsTab.swift")
        XCTAssertTrue(settingsSource.contains("Allow Claude to connect (MCP)"),
                     "the settings toggle's own label changed; update the pane's copy to match")
    }

    // MARK: - Version-bump re-render

    /// **Mount, bump, assert row count changes** — the version counter
    /// idiom, exercised through a real hosted view rather than the store
    /// alone (`DiagnosticsStoreTests` already covers the store's own
    /// bookkeeping).
    func test_thePaneRerendersOnVersionBump() async throws {
        let docId = "doc-version-bump"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(),
            diagnostics: store,
            docId: docId,
            currentText: { _ in "Body one." },
            compilerModel: .standard)))

        XCTAssertEqual(staticTextLabels(in: window, containing: "First finding."), [],
                       "the pane rendered a row before any diagnostic existed")

        // Anchored (not drift) notes, and distinct — two drift notes would
        // collide on `DiagnosticsPane.driftNote`'s "pin the first one" rule,
        // which is correct for production (at most one drift note per run)
        // and would be the wrong shape for THIS test, which wants two
        // ordinary rows.
        let anchorA = Diagnostic.Anchor(paragraphId: "p1", anchorText: "Body one.")
        let anchorB = Diagnostic.Anchor(paragraphId: "p2", anchorText: "Body one.")

        store.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(docId: docId, anchor: anchorA, body: "First finding.")],
            docId: docId)
        waitUntil { self.staticTextLabels(in: window, containing: "First finding.").count == 1 }

        XCTAssertEqual(staticTextLabels(in: window, containing: "First finding.").count, 1,
                       "the pane did not pick up the store's version bump")

        store.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(docId: docId, anchor: anchorA, body: "First finding."),
                          makeDiagnostic(docId: docId, anchor: anchorB, body: "Second finding.")],
            docId: docId)
        waitUntil { self.staticTextLabels(in: window, containing: "Second finding.").count == 1 }

        XCTAssertEqual(staticTextLabels(in: window, containing: "Second finding.").count, 1,
                       "a second version bump (two rows now live) did not re-render either")
    }

    // MARK: - Streaming (Task 4)

    /// **The report grows in place, within one run** — two version bumps, the
    /// same run id, and the pane picking up each of them.
    ///
    /// This is the version-counter idiom doing the streaming's whole job on
    /// this side of the seam, which is why the pane needed no new state for
    /// it. What makes the test worth writing anyway is that the two bumps are
    /// PREVIEWS of one check rather than two finished runs: the conformance
    /// summary is on screen while the continuity section is still generating,
    /// which is the experience the task exists to produce.
    func test_thePaneGrowsTheReportAcrossPreviewsWithinOneRun() {
        let docId = "doc-streaming"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let anchor = Diagnostic.Anchor(paragraphId: "p1", anchorText: "Body one.")

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(),
            diagnostics: store,
            docId: docId,
            currentText: { _ in "Body one." },
            compilerModel: .standard)))

        XCTAssertEqual(staticTextLabels(in: window, containing: "The last line reaches"), [],
                       "the pane drew a section before any had arrived")

        // Section one: conformance, the first thing a turn emits.
        let runId = ULID.generate()
        store.preview(
            run: makeStreamingRun(id: runId, clauseStatuses: [
                makeClause("Cold, and never wistful.", "strains")]),
            diagnostics: [makeDiagnostic(
                docId: docId, anchor: anchor, body: "The last line reaches for a sigh.",
                kind: .conformanceStrain, clauseQuote: "Cold, and never wistful.")],
            docId: docId)
        waitUntil { self.staticTextLabels(in: window, containing: "The last line reaches").count == 1 }
        XCTAssertEqual(staticTextLabels(in: window, containing: "The last line reaches").count, 1,
                       "the first section did not reach the pane")
        XCTAssertEqual(staticTextLabels(in: window, containing: "Should she already").count, 0)

        // Section two arrives while the turn is still open — SAME run.
        store.preview(
            run: makeStreamingRun(id: runId, clauseStatuses: [
                makeClause("Cold, and never wistful.", "strains")]),
            diagnostics: [makeDiagnostic(
                docId: docId, anchor: anchor, body: "The last line reaches for a sigh.",
                kind: .conformanceStrain, clauseQuote: "Cold, and never wistful."),
                          makeDiagnostic(
                docId: docId, anchor: anchor, body: "Should she already know?",
                kind: .conformanceStrain)],
            docId: docId)
        waitUntil { self.staticTextLabels(in: window, containing: "Should she already").count == 1 }

        XCTAssertEqual(staticTextLabels(in: window, containing: "Should she already").count, 1,
                       "the second section did not re-render the pane")
        XCTAssertEqual(staticTextLabels(in: window, containing: "The last line reaches").count, 1,
                       "the first section should still be standing")
    }

    /// **The wait copy stays while the report grows.** The header describes the
    /// RUN, and the run is still going — a section landing must not flip it to
    /// "Last checked just now" over a check that has not finished.
    ///
    /// Pure, because that is where the decision lives: `headerState` prefers
    /// `runState` for this document over anything on disk, and a preview is on
    /// disk's side of that fence.
    func test_theWaitCopyStaysWhileSectionsLand() {
        let previewed = makeRun(clauseStatuses: [makeClause("Cold.", "strains")])

        let state = DiagnosticsPane.headerState(
            runState: .running(docId: "doc-1", checking: counts(new: 1, revised: 0)),
            lastRun: previewed, noteCount: 1, docId: "doc-1")

        XCTAssertEqual(state, .running(checking: counts(new: 1, revised: 0)),
                       "a section arriving must not end the wait")
        XCTAssertEqual(DiagnosticsPane.headerCopy(for: state), "Checking 1 new paragraph\u{2026}")
    }

    /// **Opening the pane mid-check must not blink the report away.**
    ///
    /// `onAppear` reads the sidecar, which holds the last run that FINISHED —
    /// so a writer who presses ⌘R from the editor and then switches to
    /// Diagnostics would mount over the arriving report and watch the previous
    /// run reappear under a header saying "Checking…". Mounted rather than
    /// asserted against the store, because `onAppear` is the caller and a
    /// store-level test would not have one.
    func test_openingThePaneMidStreamKeepsTheArrivingReport() throws {
        let docId = "doc-mounted-mid-stream"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let anchor = Diagnostic.Anchor(paragraphId: "p1", anchorText: "Body one.")

        // A run that finished earlier, on disk.
        store.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(
                docId: docId, anchor: anchor, body: "Last week's finding.")],
            docId: docId)

        // A new check, one section in — the pane is not open yet.
        store.preview(
            run: makeStreamingRun(id: ULID.generate(), clauseStatuses: [
                makeClause("Cold, and never wistful.", "strains")]),
            diagnostics: [makeDiagnostic(
                docId: docId, anchor: anchor, body: "The last line reaches for a sigh.",
                kind: .conformanceStrain, clauseQuote: "Cold, and never wistful.")],
            docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(),
            diagnostics: store,
            docId: docId,
            currentText: { _ in "Body one." },
            compilerModel: .standard)))
        waitUntil { self.staticTextLabels(in: window, containing: "The last line reaches").count == 1 }

        XCTAssertEqual(staticTextLabels(in: window, containing: "The last line reaches").count, 1,
                       "mounting read the sidecar back over the arriving report")
        XCTAssertEqual(staticTextLabels(in: window, containing: "Last week's finding").count, 0,
                       "the previous run reappeared under a check that is still running")
    }

    /// A run record as the stream builds one — the run id is the caller's
    /// because a preview and the answer that supersedes it are the same run.
    private func makeStreamingRun(
        id: String, clauseStatuses: [DiagnosticIngest.ClauseStatus]
    ) -> CompilerRun {
        CompilerRun(id: id, at: Date(), model: "sonnet", lastOpId: "op1",
                    deltaSummary: "1 new, 0 revised \u{00b6}", intentSnapshot: nil,
                    droppedDangling: 0, clauseStatuses: clauseStatuses, truncatedReader: 0)
    }

    /// Turn the runloop until `condition` holds or the deadline passes —
    /// `StatementMountFixture.pumpUntil`'s pattern, synchronous here because
    /// nothing in this suite awaits real async work across the wait.
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            pump(0.05)
        }
    }

    // MARK: - Gear menu persistence

    func test_modelChoicePersistsPerProject() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "DiagModel", in: temp.url)
        let documentStore = try await DocumentStore.open(url: url)
        defer { let ds = documentStore; Task { await ds.close() } }

        XCTAssertEqual(documentStore.uiState.compilerModel, .standard,
                       "a fresh project defaults to Standard")

        documentStore.updateUIState { $0.compilerModel = .deep }
        XCTAssertEqual(documentStore.uiState.compilerModel, .deep)

        // The debounced write reaching disk — a second store opened against
        // the same project root sees the persisted choice, not the default.
        try? await Task.sleep(for: .milliseconds(700))
        let reopened = try await DocumentStore.open(url: url)
        defer { let ds = reopened; Task { await ds.close() } }
        XCTAssertEqual(reopened.uiState.compilerModel, .deep,
                       "the gear menu's choice did not survive a reopen")
    }

    /// A project written before schema v6 has no `compilerModel` key at all;
    /// it must decode to the spec's default rather than fail to load.
    func test_olderUIState_decodesCompilerModelAsStandard() throws {
        let raw = """
        {
          "schemaVersion": 5,
          "isNoChromeOn": false,
          "binderSegment": "manuscript",
          "researchPreviewVisible": false
        }
        """
        let decoded = try JSONDecoder().decode(UIState.self, from: raw.data(using: .utf8)!)
        XCTAssertEqual(decoded.compilerModel, .standard)
    }

    func test_compilerModelChoice_mapsToTheCLIsModelNames() {
        XCTAssertEqual(CompilerModelChoice.fast.claudeModel, "haiku")
        XCTAssertEqual(CompilerModelChoice.standard.claudeModel, "sonnet")
        XCTAssertEqual(CompilerModelChoice.deep.claudeModel, "opus")
    }

    /// **The setting has to reach the subprocess, and setting it does not.**
    /// `--model` is a spawn argument (`ClaudeCLISession.arguments`), so the
    /// warm session the first run left running keeps answering in the model it
    /// was built with however many times the gear menu moves. Writing
    /// `environment.model` and stopping there is a menu that changes a stored
    /// value and nothing a writer can observe — this asserts the CLI itself
    /// sees the new name, and that an UNCHANGED choice does not throw a good
    /// session away.
    func test_theGearMenusChoiceReachesTheCLI_bySpawningAFreshSession() async throws {
        let docId = "doc-model"
        let runner = SpyRunner()
        // A failing turn leaves the delta marker exactly where it was, so
        // every run below has real prose to check and reaches `ensureRunner`.
        runner.nextEvent = .failed(.timedOut)

        let orchestrator = CompilerOrchestrator()
        var environment = makeEnvironment(docId: docId, runner: runner)
        environment.model = CompilerModelChoice.standard.claudeModel
        environment.makeRunner = { _, model in
            runner.spawnedModels.append(model)
            return runner
        }
        orchestrator.configure(
            environment: environment,
            diagnostics: DiagnosticsStore(
                projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac")))

        orchestrator.runRequested(docId: docId)
        await awaitSends(1, on: runner)
        XCTAssertEqual(runner.spawnedModels, ["sonnet"])

        orchestrator.runRequested(docId: docId)
        await awaitSends(2, on: runner)
        XCTAssertEqual(runner.spawnedModels, ["sonnet"],
                       "an unchanged choice must reuse the warm session — respawning per run "
                       + "throws away the one thing the warm session is for")

        orchestrator.updateModel(CompilerModelChoice.deep.claudeModel)
        orchestrator.runRequested(docId: docId)
        await awaitSends(3, on: runner)
        XCTAssertEqual(runner.spawnedModels, ["sonnet", "opus"],
                       "the gear menu moved and the CLI never heard about it")
    }

    // MARK: - Unread badge

    /// Notes landing for a document the writer is not looking at raise a
    /// count; putting the pane in front of them drops it. Mirrors the Inbox
    /// segment's badge, whose argument is the same: a run that finishes while
    /// the writer is heads-down is otherwise invisible.
    func test_unreadCount_risesOnARunAndClearsWhenThePaneIsOnScreen() {
        let docId = "doc-unread"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        XCTAssertEqual(store.unreadCount(docId: docId), 0)

        store.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(docId: docId), makeDiagnostic(docId: docId)],
            docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 2)
        XCTAssertEqual(store.unreadCount(docId: "some-other-doc"), 0,
                       "the badge belongs to the document the run checked")

        store.markRead(docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 0)

        // A clean run clears rather than leaving the previous count standing
        // over a pane with nothing on it.
        store.replace(run: makeRun(),
                      diagnostics: [makeDiagnostic(docId: docId)], docId: docId)
        store.replace(run: makeRun(), diagnostics: [], docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 0)
    }

    /// **A run that queued notes is not a clean run** (M4 P1 review,
    /// Important 1). Since the slimming this store holds conformance strains
    /// alone, so a run that raised three continuity questions and no strain
    /// arrives here with an empty `diagnostics` array — and a badge keyed on
    /// that alone would clear itself on the one run it exists for.
    func test_theBadgeCountsWhatTheRunLeft_whereverItLeftIt() {
        let docId = "doc-unread-minted"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(run: makeRun(),
                      diagnostics: [makeDiagnostic(docId: docId)], docId: docId)
        store.markRead(docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 0, "control: cleared")

        store.replace(run: makeRun(mintedNotes: 3), diagnostics: [], docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 3,
                       "a run that put three notes in the writer's queue left the "
                       + "badge at zero, so nothing anywhere says the check found "
                       + "anything")

        // And a strain beside them counts once each, not twice.
        store.replace(run: makeRun(mintedNotes: 2),
                      diagnostics: [makeDiagnostic(docId: docId)], docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 3)

        // A genuinely empty run still clears.
        store.replace(run: makeRun(mintedNotes: 0), diagnostics: [], docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 0)
    }

    /// **Mounted**, because the clear is the pane's own reaction and a store
    /// test cannot see whether anything calls it.
    func test_theMountedPaneClearsTheBadge_forNotesThatLandWhileItIsOpen() {
        let docId = "doc-unread-mounted"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(run: makeRun(),
                      diagnostics: [makeDiagnostic(docId: docId)], docId: docId)
        XCTAssertEqual(store.unreadCount(docId: docId), 1)

        _ = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.2)
        XCTAssertEqual(store.unreadCount(docId: docId), 0,
                       "opening the pane must drop the badge")

        // And a run landing while it is already open was never unread.
        store.replace(run: makeRun(),
                      diagnostics: [makeDiagnostic(docId: docId)], docId: docId)
        pump(0.3)
        XCTAssertEqual(store.unreadCount(docId: docId), 0,
                       "the badge is for a run that finished where the writer was not looking")
    }

    /// The badge's offset is derived for `.diagnostics` the same way it is for
    /// `.inbox` — and the two can be on screen together, which no persona
    /// registry produces but `⌘⌥B` in Author does (`visibleSegments` appends
    /// the out-of-persona selection).
    func test_badgeOffset_findsDiagnosticsAndCoexistsWithTheInboxBadge() {
        let author = Persona.author.panes
        XCTAssertEqual(
            DetailPaneToggle<AnyView>.badgeOffset(of: .diagnostics, in: author),
            author.count - 1,
            "diagnostics leads Author, so its badge shifts the full width of the row")
        XCTAssertNil(DetailPaneToggle<AnyView>.badgeOffset(of: .inbox, in: author))

        let withInboxAppended = DetailPaneToggle<AnyView>.visibleSegments(
            persona: .author, including: .inbox)
        XCTAssertNotNil(
            DetailPaneToggle<AnyView>.badgeOffset(of: .diagnostics, in: withInboxAppended))
        XCTAssertEqual(
            DetailPaneToggle<AnyView>.badgeOffset(of: .inbox, in: withInboxAppended), 0,
            "the appended segment is last, so its badge does not shift at all")
    }

    // MARK: - Empty state

    /// **A failed check may not wear the seal.** `checkmark.seal` over
    /// "Nothing to flag." says the compiler looked and found nothing; a run
    /// that died never looked. Each state's copy is asserted rather than
    /// falling through to a `default:`.
    func test_emptyState_neverSealsARunThatDidNotHappen() {
        let failed = DiagnosticsPane.emptyState(for: .failed(.cliNotFound, at: Date()))
        XCTAssertNotEqual(failed.symbol, "checkmark.seal")
        XCTAssertFalse(failed.title.contains("Nothing to flag"))

        let running = DiagnosticsPane.emptyState(for: .running(checking: counts(new: 1, revised: 0)))
        XCTAssertNotEqual(running.symbol, "checkmark.seal")
        XCTAssertFalse(running.title.contains("Nothing to flag"))

        XCTAssertEqual(DiagnosticsPane.emptyState(for: .neverRun).title, "Not checked yet")
        XCTAssertEqual(DiagnosticsPane.emptyState(for: .clean(lastRun: makeRun())).title,
                       "Nothing to flag.")
    }

    // MARK: - A run that lost every note it raised

    /// **The adjacent case to a failed run.** The compiler returned three real
    /// notes against paragraphs the writer has since changed, ingest dropped
    /// all three, and nothing was accepted — so the pane, reading only the note
    /// count, showed the seal and a clean bill over a check that did flag
    /// things. The clean run's line now says what it lost.
    func test_aRunThatDiscardedEveryNote_saysSoInsteadOfAClaimingCleanBill() {
        let run = makeRun(droppedDangling: 3)
        let line = DiagnosticsPane.headerCopy(for: .clean(lastRun: run))

        XCTAssertTrue(line.contains("Nothing to flag."),
            "the run genuinely raised nothing that could be placed")
        XCTAssertTrue(
            line.contains("3 notes arrived against paragraphs that have changed "
                          + "and were discarded"),
            "got: \(line)")
        XCTAssertFalse(line.lowercased().contains("unknown paragraph"),
            "the parser's vocabulary is not the writer's, and it reads as their fault")

        let empty = DiagnosticsPane.emptyState(for: .clean(lastRun: run))
        XCTAssertNotEqual(empty.symbol, "checkmark.seal",
            "the seal is for a run with nothing to say, not one that was mistranscribed")
        XCTAssertNotEqual(empty.symbol, "exclamationmark.triangle",
            "…and it is not a failure either — nothing here is alarming")
        XCTAssertTrue(empty.description.contains("3 notes arrived"), "got: \(empty.description)")
    }

    /// The converse, so the clause cannot creep onto every clean run: a
    /// genuinely clean one — nothing raised, nothing discarded — keeps the seal
    /// and says nothing more.
    func test_aGenuinelyCleanRunKeepsTheSealAndSaysNothingMore() {
        let run = makeRun(droppedDangling: 0)
        let line = DiagnosticsPane.headerCopy(for: .clean(lastRun: run))

        XCTAssertTrue(line.hasPrefix("Nothing to flag."))
        XCTAssertFalse(line.contains("discarded"), "got: \(line)")
        XCTAssertEqual(DiagnosticsPane.emptyState(for: .clean(lastRun: run)).symbol,
                       "checkmark.seal")
    }

    /// One note is not "1 notes", and the singular is the common case.
    func test_theDiscardedSentenceCountsInTheWritersEnglish() {
        XCTAssertNil(DiagnosticsPane.discardedNotesSentence(0))
        XCTAssertEqual(
            DiagnosticsPane.discardedNotesSentence(1),
            "1 note arrived against a paragraph that has changed and was discarded")
        XCTAssertEqual(
            DiagnosticsPane.discardedNotesSentence(2),
            "2 notes arrived against paragraphs that have changed and were discarded")
    }

    // MARK: - The cold-start offer (Stage 3) — pure decision

    /// **The pure gate, no view mounted** — the `headerState`/`emptyState`
    /// idiom. True only when all three conditions hold at once; each
    /// assertion below flips exactly one of them.
    func test_showsColdStartOffer_trueOnlyForANeverRunNonTrivialUnrefusedDocument() {
        XCTAssertTrue(DiagnosticsPane.showsColdStartOffer(
            state: .neverRun, liveParagraphCount: 2, hasRefused: false))

        XCTAssertFalse(DiagnosticsPane.showsColdStartOffer(
            state: .neverRun, liveParagraphCount: 1, hasRefused: false),
            "a stub manuscript (\u{2264}1 live paragraph) is not worth offering to read")
        XCTAssertFalse(DiagnosticsPane.showsColdStartOffer(
            state: .neverRun, liveParagraphCount: 0, hasRefused: false))
        XCTAssertFalse(DiagnosticsPane.showsColdStartOffer(
            state: .neverRun, liveParagraphCount: 2, hasRefused: true),
            "a refused document never offers again")
        XCTAssertFalse(DiagnosticsPane.showsColdStartOffer(
            state: .idle(lastRun: makeRun()), liveParagraphCount: 2, hasRefused: false),
            "any run at all — even one with nothing to show — moves state off .neverRun")
        XCTAssertFalse(DiagnosticsPane.showsColdStartOffer(
            state: .clean(lastRun: makeRun()), liveParagraphCount: 2, hasRefused: false))
        XCTAssertFalse(DiagnosticsPane.showsColdStartOffer(
            state: .running(checking: counts(new: 1, revised: 0)), liveParagraphCount: 2,
            hasRefused: false),
            "a run already under way is not the never-run window either")
    }

    // MARK: - The cold-start offer, mounted (real Document, real buttons)

    /// A real, on-disk, multi-paragraph document — `activeDocument()`'s own
    /// contract, so the offer's `liveParagraphCount` discriminator is read
    /// off the same `sequence` `promote()` already reads, not a stand-in.
    private func makeMultiParagraphDocument(
        paragraphs: [String] = ["First paragraph, with some words in it.",
                                "Second paragraph, with some more."]
    ) async throws -> Document {
        let (_, docURL) = try makeTestProject(
            prefix: "COLDSTART", initialMd: paragraphs.joined(separator: "\n\n"))
        return try await Document.load(
            url: docURL, device: "macA", session: "s1", presenter: nil)
    }

    /// **The offer itself, and Read starting the same first run \u{2318}R
    /// takes.** No `activeDocument` closure was threaded through
    /// `makeEnvironment`'s canned reading — the orchestrator's own delta is
    /// independent of the pane's `activeDocument` in every other mounted test
    /// here too, and this one only needs to prove the button reaches
    /// `runRequested` for THIS docId, not that the two descriptions of the
    /// document agree.
    func test_theOfferAppearsAndReadStartsTheFirstRun() async throws {
        let document = try await makeMultiParagraphDocument()
        let docId = document.docId
        let runner = SpyRunner()
        let orchestrator = CompilerOrchestrator()
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        orchestrator.configure(
            environment: makeEnvironment(docId: docId, runner: runner),
            diagnostics: diagnostics)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: orchestrator, diagnostics: diagnostics, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard,
            activeDocument: { document })))

        let readButton = try button(labelled: "Read", in: window)
        XCTAssertNotNil(findButton(labelled: "Not now", in: window))

        _ = readButton.perform(NSSelectorFromString("accessibilityPerformPress"))
        await awaitSends(1, on: runner)

        XCTAssertEqual(runner.sendCount, 1,
            "Read must reach the orchestrator's real runRequested \u{2014} the same "
            + "first-run path \u{2318}R takes, not a second run kind")
    }

    /// **Not now records the refusal, and the offer never renders again for
    /// this document** — asserted in both directions: gone from the pane
    /// that just refused it, and gone from a SECOND, freshly mounted pane
    /// over the same store, because the promise is about the document, not
    /// about one pane instance.
    func test_notNowRefusesAndTheOfferNeverRendersAgainForThatDocument() async throws {
        let document = try await makeMultiParagraphDocument()
        let docId = document.docId
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard,
            activeDocument: { document })))

        let notNow = try button(labelled: "Not now", in: window)
        _ = notNow.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.2)

        XCTAssertTrue(diagnostics.hasRefusedColdStart(docId: docId))
        XCTAssertNil(findButton(labelled: "Read", in: window),
            "the offer must not re-render in place after its own refusal")
        XCTAssertNil(findButton(labelled: "Not now", in: window))

        let secondWindow = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard,
            activeDocument: { document })))
        XCTAssertNil(findButton(labelled: "Read", in: secondWindow),
            "a second pane over the same store must not offer again either")
    }

    /// A manuscript with one live paragraph or fewer never offers — the
    /// plain "Not checked yet" empty state stands instead.
    func test_aTrivialManuscriptNeverOffersColdStart() async throws {
        let document = try await makeMultiParagraphDocument(paragraphs: ["Only paragraph."])
        let docId = document.docId
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard,
            activeDocument: { document })))

        XCTAssertNil(findButton(labelled: "Read", in: window))
        XCTAssertNil(findButton(labelled: "Not now", in: window))
    }

    /// A document with ANY run on record never offers, even a run that found
    /// nothing to say — `headerState` only returns `.neverRun` with no
    /// `lastRun` at all, so this is the structural half of "a doc already run
    /// never shows the offer."
    func test_aDocumentAlreadyRunNeverOffersColdStart() async throws {
        let document = try await makeMultiParagraphDocument()
        let docId = document.docId
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(run: makeRun(), diagnostics: [], docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard,
            activeDocument: { document })))

        XCTAssertNil(findButton(labelled: "Read", in: window))
        XCTAssertNil(findButton(labelled: "Not now", in: window))
    }

    // MARK: - Cancel (real running state, real button)

    /// The Cancel button is visible only while a run for THIS document is in
    /// flight, and pressing it calls the orchestrator's own `cancel()` — not
    /// a copy of what that does.
    func test_cancelButton_visibleOnlyWhileRunning_andCallsCancel() async throws {
        let docId = "doc-cancel"
        let runner = SpyRunner()
        runner.nextEvent = nil   // hold the turn open
        let orchestrator = CompilerOrchestrator()
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        orchestrator.configure(
            environment: makeEnvironment(docId: docId, runner: runner),
            diagnostics: diagnostics)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: orchestrator, diagnostics: diagnostics, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))

        XCTAssertNil(findButton(labelled: "Cancel", in: window),
                     "Cancel must not appear before a run starts")

        orchestrator.runRequested(docId: docId)
        await awaitSends(1, on: runner)
        pump(0.2)

        let cancelButton = try button(labelled: "Cancel", in: window)
        _ = cancelButton.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.2)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(runner.cancels, 1, "pressing Cancel must call the real cancel()")
    }

    // MARK: - Open Intent

    /// The conformance section's "Open Intent" button posts
    /// `postDetailSegment(.intent)` — the same request the inspector's own
    /// Intent affordance posts.
    ///
    /// It sits on the summary because that is what the section is *about*: the
    /// clauses are derived from the writer's statement, and the Intent pane is
    /// where a clause is changed rather than answered. (It used to live on the
    /// drift note, which v2 no longer produces.)
    func test_openIntentButton_postsDetailSegmentIntent() async throws {
        let docId = "doc-open-intent"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(
            run: makeRun(clauseStatuses: [makeClause("Cold, and never wistful.", "holds")]),
            diagnostics: [], docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.2)

        let notes = await notesPosted(pressing: try button(labelled: "Open Intent", in: window))

        XCTAssertEqual(notes.count, 1, "pressing Open Intent should post exactly one request")
        XCTAssertEqual(notes.first?.userInfo?[MaughamEvent.detailSegmentKey] as? String,
                       DetailSegment.intent.rawValue)
    }

    // MARK: - Drift (spec §4's last bullet, computed in Stage 3 by `DriftDetector`)
    //
    // `DriftDetector.drift` has its own suite (`DriftDetectorTests`) for
    // whether a finding fires; these pin what the PANE says once one does,
    // and that the line behaves as the register requires — not a `Diagnostic`.

    func test_driftNote_isNilWithNoFindings() {
        XCTAssertNil(DiagnosticsPane.driftNote([]))
    }

    func test_driftNote_formatsTheRegisterVerbatim() {
        let finding = DriftFinding(clauseQuote: "Cold, and never wistful.", runsStraining: 3)
        XCTAssertEqual(
            DiagnosticsPane.driftNote([finding]),
            "Your line may have moved \u{2014} \u{201C}Cold, and never wistful.\u{201D} "
            + "has strained three runs running. Draft\u{2019}s right, or intent\u{2019}s right?")
    }

    /// **No count beyond the fixed "three runs" is ever spoken** — not the
    /// finding's true streak length, which `DriftDetector` reports honestly and
    /// can run past the threshold
    /// (`DriftDetectorTests.test_aStreakLongerThanTheThresholdReportsItsFullLength`).
    /// Saying "seven runs running" would be exactly the forensic detail the
    /// register refuses elsewhere on this pane (`readerSection`'s truncation
    /// sentence is the same discipline: "The reader had more to say.", no count).
    func test_driftNote_neverSpeaksTheTrueStreakLength() {
        let finding = DriftFinding(clauseQuote: "Cold, and never wistful.", runsStraining: 7)
        guard let line = DiagnosticsPane.driftNote([finding]) else {
            return XCTFail("expected a line")
        }
        XCTAssertTrue(line.contains("three runs running"), "got: \(line)")
        XCTAssertFalse(line.contains("7"), "got: \(line)")
    }

    /// **More than one finding still reads as one line.** The first clause
    /// (the newest run's own order — `DriftDetector.drift`'s) is named, and
    /// "and one more" says there is a second without counting how many —
    /// two findings and five read identically, the same discipline as the
    /// streak length above.
    func test_driftNote_multipleFindingsNameTheFirstAndSayAndOneMoreWithoutACount() {
        let first = DriftFinding(clauseQuote: "Cold, and never wistful.", runsStraining: 3)
        let second = DriftFinding(clauseQuote: "Kelly never speaks first.", runsStraining: 4)
        let third = DriftFinding(clauseQuote: "The weather is a character.", runsStraining: 3)

        let two = DiagnosticsPane.driftNote([first, second])
        XCTAssertEqual(
            two,
            "Your line may have moved \u{2014} \u{201C}Cold, and never wistful.\u{201D} has "
            + "strained three runs running \u{2014} and one more. Draft\u{2019}s right, "
            + "or intent\u{2019}s right?")

        let three = DiagnosticsPane.driftNote([first, second, third])
        XCTAssertEqual(two, three,
            "the line reads the same for two findings and for three \u{2014} \u{201C}and "
            + "one more\u{201D} must never become \u{201C}and 2 more\u{201D}")
        XCTAssertFalse(three?.contains("Kelly") ?? true,
                       "only the first finding's clause is ever quoted")
    }

    func test_truncatedDriftQuote_fitsAsIs() {
        XCTAssertEqual(DiagnosticsPane.truncatedDriftQuote("Cold, and never wistful."),
                       "Cold, and never wistful.")
    }

    /// `IntentStrip.truncated`'s idiom: cut at the last word boundary inside
    /// the budget, ellipsised — never mid-word, and never a trailing space
    /// left dangling before the ellipsis.
    func test_truncatedDriftQuote_cutsOnAWordBoundaryAndEllipsises() {
        let long = "Kelly never speaks first, not once, not even when the silence "
            + "would have been the crueler thing to let stand between them."
        let truncated = DiagnosticsPane.truncatedDriftQuote(long)

        XCTAssertTrue(truncated.hasSuffix("\u{2026}"), "got: \(truncated)")
        XCTAssertLessThan(truncated.count, long.count, "control: it actually cut something")
        let withoutEllipsis = String(truncated.dropLast())
        XCTAssertFalse(withoutEllipsis.hasSuffix(" "),
                       "trimmed before the ellipsis, not left with a trailing space")
        XCTAssertTrue(long.hasPrefix(withoutEllipsis),
                      "the cut is a true prefix of the source \u{2014} a word boundary, not "
                      + "a mid-word chop")
    }

    /// **The pattern's line, mounted for real.** Three straining runs of the
    /// same clause puts the line above "Conformance", and pressing it opens
    /// Intent the same way the summary's own "Open Intent" button does — spec
    /// §4's "your line may have moved" is the same door as the clause it is
    /// about.
    func test_driftLine_rendersAboveConformanceSummary_andOpensIntentOnPress() async throws {
        let docId = "doc-drift"
        let quote = "Cold, and never wistful."
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        for _ in 0..<3 {
            store.replace(run: makeRun(clauseStatuses: [makeClause(quote, "strains")]),
                          diagnostics: [], docId: docId)
        }

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.3)

        let expectedLine = try XCTUnwrap(DiagnosticsPane.driftNote(
            DriftDetector.drift(history: store.clauseStatusHistory(docId: docId))))

        let labels = allLabels(in: window)
        let driftIndex = labels.firstIndex { $0 == expectedLine }
        let conformanceIndex = labels.firstIndex { $0 == "CONFORMANCE" }
        XCTAssertNotNil(driftIndex, "got: \(labels)")
        XCTAssertNotNil(conformanceIndex, "got: \(labels)")
        XCTAssertTrue((driftIndex ?? .max) < (conformanceIndex ?? -1),
                      "the drift line must sit above the conformance summary")

        let notes = await notesPosted(pressing: try button(labelled: expectedLine, in: window))
        XCTAssertEqual(notes.count, 1, "pressing the line should post exactly one request")
        XCTAssertEqual(notes.first?.userInfo?[MaughamEvent.detailSegmentKey] as? String,
                       DetailSegment.intent.rawValue,
                       "the drift line's action is Open Intent's successor \u{2014} the "
                       + "existing drift-note affordance")
    }

    /// **The line disappears when the pattern breaks.** There is nothing to
    /// dismiss: the next run's history simply stops reporting a finding, and
    /// the pane's version-bump re-render (already proven by
    /// `test_thePaneRerendersOnVersionBump`) carries the line away with
    /// everything else that no longer applies.
    func test_driftLine_disappearsWhenTheNextRunBreaksThePattern() {
        let docId = "doc-drift-breaks"
        let quote = "Cold, and never wistful."
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        for _ in 0..<3 {
            store.replace(run: makeRun(clauseStatuses: [makeClause(quote, "strains")]),
                          diagnostics: [], docId: docId)
        }

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.3)
        XCTAssertFalse(
            staticTextLabels(in: window, containing: "Your line may have moved").isEmpty,
            "control: the line rendered while the pattern held")

        store.replace(run: makeRun(clauseStatuses: [makeClause(quote, "holds")]),
                      diagnostics: [], docId: docId)
        pump(0.3)

        XCTAssertTrue(
            staticTextLabels(in: window, containing: "Your line may have moved").isEmpty,
            "the clause holding this run must break the streak, and the line with it")
    }

    /// **Not a `Diagnostic`.** No dismissal and no reply field: pressing the
    /// line opens Intent and nothing else changes — the line is still exactly
    /// where it was, and no `TextField` appeared the way one does under a
    /// question's "Answer".
    func test_driftLineIsNotADiagnostic_offersNoDismissalOrAnswerField() async throws {
        let docId = "doc-drift-not-a-diagnostic"
        let quote = "Cold, and never wistful."
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        for _ in 0..<3 {
            store.replace(run: makeRun(clauseStatuses: [makeClause(quote, "strains")]),
                          diagnostics: [], docId: docId)
        }

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.3)

        let expectedLine = try XCTUnwrap(DiagnosticsPane.driftNote(
            DriftDetector.drift(history: store.clauseStatusHistory(docId: docId))))
        XCTAssertTrue(textFields(in: window).isEmpty,
                     "the drift line must not offer a reply field the way a question's row does")

        _ = try button(labelled: expectedLine, in: window)
            .perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.3)

        XCTAssertFalse(staticTextLabels(in: window, containing: expectedLine).isEmpty,
                       "pressing the line must not dismiss it \u{2014} it has nothing to dismiss")
        XCTAssertTrue(textFields(in: window).isEmpty,
                     "and it must not have opened a reply field either")
    }

    // MARK: - Since last round (M3-P3 Task 3, recounted off the queue in M4 P1)
    //
    // The arithmetic itself belongs to `SinceLastRound` (`RoundHistoryTests`);
    // these pin what the PANE decides — when there is a line at all, which
    // record it is measured against, and that it never speaks over a fresh-eyes
    // round.

    private func makeRoundRecord(
        passId: String? = "line", round: Int? = 1,
        freshEyes: Bool? = nil, at: Date = Date(timeIntervalSince1970: 0)
    ) -> RoundRecord {
        RoundRecord(runId: ULID.generate(), at: at,
                    passId: passId, round: round, freshEyes: freshEyes,
                    fingerprints: [])
    }

    /// A compiler-authored note in the queue, in the state the count turns on.
    private func makeCompilerNote(
        lane: String? = "line", round: Int? = 1,
        status: AnnotationStatus = .open, resolvedAt: Date? = nil
    ) -> Annotation {
        Annotation(
            id: ULID.generate(), kind: .query, paragraphId: "a1b2",
            body: "Whose coat is on the chair?", suggestedText: nil, priorText: nil,
            createdAt: Date(timeIntervalSince1970: 10), createdBySession: nil,
            status: status, userResponse: nil, resolvedAt: resolvedAt,
            isStale: false, reviewPassId: lane,
            compilerRunId: "run-1", compilerRound: round,
            compilerFingerprint: "continuity\u{1f}the fog\u{1f}a1b2\u{1f}")
    }

    func test_sinceLastRoundLine_isNilWithoutARoundNumber() {
        XCTAssertNil(DiagnosticsPane.sinceLastRoundLine(
            history: [makeRoundRecord()], run: nil, annotations: []))
        XCTAssertNil(DiagnosticsPane.sinceLastRoundLine(
            history: [makeRoundRecord()], run: makeRun(), annotations: []),
            "a passless run is an ordinary M2 run \u{2014} there is no round to be since")
    }

    /// **Round 1 has nothing behind it.** The line is about the distance
    /// travelled, and the first round of a lane has travelled none.
    func test_sinceLastRoundLine_isNilForTheFirstRoundOfALane() {
        XCTAssertNil(DiagnosticsPane.sinceLastRoundLine(
            history: [], run: makeRun(passId: "line", round: 1), annotations: []))
    }

    func test_sinceLastRoundLine_countsResolvedPersistingAndNew() {
        let filed = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            DiagnosticsPane.sinceLastRoundLine(
                history: [makeRoundRecord(round: 1, at: filed)],
                run: makeRun(passId: "line", round: 2),
                annotations: [
                    makeCompilerNote(round: 2),
                    makeCompilerNote(round: 1),
                    makeCompilerNote(round: 1, status: .stetted,
                                     resolvedAt: filed.addingTimeInterval(60)),
                ]),
            "Since round 1: 1 resolved \u{00b7} 1 persisting \u{00b7} 1 new")
    }

    /// **The record it measures FROM is the record it counts from.** The
    /// resolved half is "settled since the last round finished", and the
    /// instant that means is the ring record's own `at` — read from the wrong
    /// record and every note the writer ever settled in this pass is counted
    /// again, every round.
    func test_sinceLastRoundLine_measuresResolvedFromThatRecordsOwnTime() {
        let filed = Date(timeIntervalSince1970: 1_000)
        let settledBefore = makeCompilerNote(
            round: 1, status: .stetted, resolvedAt: filed.addingTimeInterval(-60))
        XCTAssertEqual(
            DiagnosticsPane.sinceLastRoundLine(
                history: [makeRoundRecord(round: 1, at: filed)],
                run: makeRun(passId: "line", round: 2),
                annotations: [settledBefore]),
            "Since round 1: 0 resolved \u{00b7} 0 persisting \u{00b7} 0 new")
    }

    /// **It reads only its own lane.** A Proof round filed between two Line
    /// rounds is newer in the ring and is not what the Line round is measured
    /// against — and its NOTES take no part either.
    func test_sinceLastRoundLine_readsOnlyItsOwnLane() {
        let filed = Date(timeIntervalSince1970: 1_000)
        let line = makeRoundRecord(passId: "line", round: 1, at: filed)
        let proof = makeRoundRecord(passId: "proof", round: 1,
                                    at: filed.addingTimeInterval(30))

        XCTAssertEqual(
            DiagnosticsPane.sinceLastRoundLine(
                history: [line, proof], run: makeRun(passId: "line", round: 2),
                annotations: [
                    makeCompilerNote(lane: "proof", round: 2),
                    makeCompilerNote(lane: "proof", round: 1),
                    makeCompilerNote(lane: "line", round: 1, status: .stetted,
                                     resolvedAt: filed.addingTimeInterval(60)),
                ]),
            "Since round 1: 1 resolved \u{00b7} 0 persisting \u{00b7} 0 new",
            "the Proof round sits newest in the ring and must take no part \u{2014} "
            + "neither its record nor its notes")
    }

    /// **A round still streaming has not filed the round it supersedes.**
    /// Mid-preview the newest same-lane record is N−2, and a line drawn
    /// against it would name the wrong round and then correct itself when the
    /// turn ended. The pane simply says nothing until the answer lands.
    func test_sinceLastRoundLine_isNilWhileTheRoundBeforeItIsStillStanding() {
        let twoBack = makeRoundRecord(round: 1)
        XCTAssertNil(DiagnosticsPane.sinceLastRoundLine(
            history: [twoBack], run: makeRun(passId: "line", round: 3), annotations: []))
        XCTAssertNotNil(DiagnosticsPane.sinceLastRoundLine(
            history: [twoBack], run: makeRun(passId: "line", round: 2), annotations: []),
            "control: the record IS round 2's predecessor")
    }

    /// **A fresh-eyes round is not a comparison.** It was read cold and
    /// deliberately briefed on no prior findings (spec §6), so measuring it
    /// against the last round would report a difference the run never made.
    /// Its header says what it is instead (Task 6).
    func test_sinceLastRoundLine_isNilForAFreshEyesRound() {
        let previous = makeRoundRecord(round: 1)
        XCTAssertNotNil(DiagnosticsPane.sinceLastRoundLine(
            history: [previous], run: makeRun(passId: "line", round: 2), annotations: []),
            "control: an ordinary round 2 does speak")
        XCTAssertNil(DiagnosticsPane.sinceLastRoundLine(
            history: [previous],
            run: makeRun(passId: "line", round: 2, freshEyes: true), annotations: []))
    }

    /// **The report leads with it** — above the drift line and above the
    /// conformance summary, mounted for real.
    func test_theSinceLastRoundLineLeadsTheReport() throws {
        let docId = "doc-rounds"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let quote = "Cold, and never wistful."
        let note = makeDiagnostic(
            docId: docId, anchor: .init(paragraphId: "a1b2", anchorText: "The fog came."),
            body: "The last line reaches for a sigh.", kind: .conformanceStrain,
            clauseQuote: quote)
        store.replace(run: makeRun(clauseStatuses: [makeClause(quote, "strains")],
                                   passId: "line", round: 1),
                      diagnostics: [note], docId: docId)
        store.replace(run: makeRun(clauseStatuses: [makeClause(quote, "holds")],
                                   passId: "line", round: 2),
                      diagnostics: [], docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in "The fog came." }, compilerModel: .standard)))
        pump(0.3)

        // No document behind this pane, so the queue is empty and the line says
        // so — three zeroes is a legitimate reading, and what is under test
        // here is WHERE the sentence sits, not what it counted.
        let expected = try XCTUnwrap(DiagnosticsPane.sinceLastRoundLine(
            history: store.roundHistory(docId: docId),
            run: store.lastRun(docId: docId),
            annotations: []))
        XCTAssertEqual(expected, "Since round 1: 0 resolved \u{00b7} 0 persisting \u{00b7} 0 new")

        let labels = allLabels(in: window)
        let lineIndex = labels.firstIndex { $0 == expected }
        let conformanceIndex = labels.firstIndex { $0 == "CONFORMANCE" }
        XCTAssertNotNil(lineIndex, "got: \(labels)")
        XCTAssertNotNil(conformanceIndex, "got: \(labels)")
        XCTAssertTrue((lineIndex ?? .max) < (conformanceIndex ?? -1),
                      "the since-last-round line leads the report")
    }

    /// **The wiring, mounted** (M4 P1 Task 5): the sentence on screen counts
    /// the notes on the OPEN DOCUMENT, not a second account of them kept in
    /// the sidecar. Two of the three kinds a round raises are annotations now,
    /// so a pane that still read the sidecar's own record of the last round
    /// would report zero for a round that queued three questions.
    func test_theSinceLastRoundLineCountsTheQueueOfTheOpenDocument() async throws {
        let document = try await makeMultiParagraphDocument()
        let docId = document.docId
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))

        store.replace(run: makeRun(passId: "line", round: 1), diagnostics: [], docId: docId)
        // Round 1's two notes, as the mint writes them.
        let settled = try await document.addAnnotation(
            kind: .query, paragraphId: paragraphId, body: "Whose coat is this?",
            reviewPassId: "line", compilerRunId: "run-1", compilerRound: 1,
            compilerFingerprint: "continuity\u{1f}the coat\u{1f}\(paragraphId)\u{1f}")
        _ = try await document.addAnnotation(
            kind: .comment, paragraphId: paragraphId, body: "The fog stops convincing here.",
            reviewPassId: "line", compilerRunId: "run-1", compilerRound: 1,
            compilerFingerprint: "readerReport\u{1f}\u{1f}\(paragraphId)\u{1f}belief")
        // The writer settles one of them, then round 2 lands raising nothing.
        try await document.stetAnnotation(id: settled)
        // A clause that holds: the report renders, and nothing in it is a note
        // — so the only sentence with a count in it is the one under test.
        store.replace(run: makeRun(clauseStatuses: [makeClause("Cold.", "holds")],
                                   passId: "line", round: 2),
                      diagnostics: [], docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard,
            activeDocument: { document })))
        pump(0.3)

        let expected = "Since round 1: 1 resolved \u{00b7} 1 persisting \u{00b7} 0 new"
        XCTAssertFalse(
            staticTextLabels(in: window, containing: expected).isEmpty,
            "the line must count the document's own queue; got \(allLabels(in: window))")
    }

    // MARK: - Fresh eyes (M3-P3 Task 6)
    //
    // The cold read's header occupies the slot the since-last-round line would
    // have taken, and the two are mutually exclusive by construction: a round
    // that was briefed on no prior findings has no distance to report.

    func test_freshEyesHeader_namesTheRoundWhenThereIsOne() {
        XCTAssertEqual(
            DiagnosticsPane.freshEyesHeader(
                run: makeRun(passId: "line", round: 3, freshEyes: true)),
            "Fresh eyes \u{00b7} round 3")
    }

    /// A passless cold read is still a cold read — it just has no number to
    /// name, the way an ordinary passless ⌘R has none.
    func test_freshEyesHeader_saysSoWithoutARoundNumber() {
        XCTAssertEqual(
            DiagnosticsPane.freshEyesHeader(run: makeRun(freshEyes: true)),
            "Fresh eyes")
    }

    func test_freshEyesHeader_isNilForAnOrdinaryRun() {
        XCTAssertNil(DiagnosticsPane.freshEyesHeader(run: nil))
        XCTAssertNil(DiagnosticsPane.freshEyesHeader(
            run: makeRun(passId: "line", round: 2)),
            "a run that was never stamped is an ordinary round")
        XCTAssertNil(DiagnosticsPane.freshEyesHeader(
            run: makeRun(passId: "line", round: 2, freshEyes: false)),
            "…and so is one stamped false by some earlier build")
    }

    /// **The two lines never co-render.** Task 3's guard refuses the
    /// comparison for a fresh-eyes round; this is the same rule read from the
    /// other end, so a later change to either function cannot quietly put both
    /// sentences on one report.
    func test_theRoundHeaderAndTheSinceLastRoundLineAreMutuallyExclusive() {
        let previous = makeRoundRecord(round: 1)
        for run in [makeRun(passId: "line", round: 2),
                    makeRun(passId: "line", round: 2, freshEyes: true),
                    makeRun(freshEyes: true),
                    makeRun()] {
            let since = DiagnosticsPane.sinceLastRoundLine(
                history: [previous], run: run, annotations: [makeCompilerNote(round: 1)])
            let fresh = DiagnosticsPane.freshEyesHeader(run: run)
            XCTAssertFalse(since != nil && fresh != nil,
                           "both lines spoke for one round: \(String(describing: since)) "
                           + "/ \(String(describing: fresh))")
        }
    }

    /// Mounted: the header leads the report, and the comparison the ordinary
    /// round would have drawn is nowhere on the pane.
    func test_theFreshEyesHeaderLeadsTheReportAndTheComparisonIsAbsent() throws {
        let docId = "doc-fresh"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let quote = "Cold, and never wistful."
        let note = makeDiagnostic(
            docId: docId, anchor: .init(paragraphId: "a1b2", anchorText: "The fog came."),
            body: "The last line reaches for a sigh.", kind: .conformanceStrain,
            clauseQuote: quote)
        store.replace(run: makeRun(clauseStatuses: [makeClause(quote, "strains")],
                                   passId: "line", round: 1),
                      diagnostics: [note], docId: docId)
        store.replace(run: makeRun(clauseStatuses: [makeClause(quote, "holds")],
                                   passId: "line", round: 2, freshEyes: true),
                      diagnostics: [], docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in "The fog came." }, compilerModel: .standard)))
        pump(0.3)

        let labels = allLabels(in: window)
        let headerIndex = labels.firstIndex { $0 == "Fresh eyes \u{00b7} round 2" }
        let conformanceIndex = labels.firstIndex { $0 == "CONFORMANCE" }
        XCTAssertNotNil(headerIndex, "got: \(labels)")
        XCTAssertNotNil(conformanceIndex, "got: \(labels)")
        XCTAssertTrue((headerIndex ?? .max) < (conformanceIndex ?? -1),
                      "the fresh-eyes header leads the report")
        XCTAssertTrue(labels.allSatisfy { !$0.hasPrefix("Since round") },
                      "a cold read reports no distance travelled; got \(labels)")
    }

    // MARK: - Click-to-jump (wiring census — see reasoning below)

    /// A diagnostic's row has no button role for its tap target (it is the
    /// whole row, like `AnnotationRow`), so this is a source census rather
    /// than a press: it asserts the pane posts the SAME event
    /// `AnnotationsPane.jump` does, with the same payload key, and pins the
    /// pure mapping (anchored → its paragraph id, anchorless → nothing to jump
    /// to) as a direct unit test. The chips, which ARE buttons, are pressed for
    /// real below.
    func test_jump_targetsTheAnchoredParagraphAndNothingForAnAnchorlessNote() {
        let anchored = makeDiagnostic(
            docId: "d1", anchor: Diagnostic.Anchor(paragraphId: "abcd", anchorText: "x"))
        XCTAssertEqual(DiagnosticsPane.paragraphToNavigateTo(for: anchored), "abcd")

        // The schema's own escape hatch: a note about the delta rather than one
        // paragraph. It renders in its kind's section like any other and has
        // nothing to jump to.
        let anchorless = makeDiagnostic(docId: "d1", anchor: nil)
        XCTAssertNil(DiagnosticsPane.paragraphToNavigateTo(for: anchorless))
    }

    func test_jump_postsTheSameEventAnnotationsRowUses() throws {
        let source = try readSource("Maugham/Views/DiagnosticsPane.swift")
        XCTAssertTrue(source.contains(".maughamNavigateToParagraph"),
                     "DiagnosticsPane must reuse AnnotationsPane.jump's event, not a copy")
        XCTAssertTrue(source.contains(#"["paragraph_id": pid]"#))
    }

    // MARK: - The conformance summary (spec §5's first section)

    /// **Every clause the run checked, paired with what strained against it.**
    /// The pairing is on the writer's quoted sentence, because that is the only
    /// thing the two records share — the ingest mints a `ClauseStatus` and a
    /// `.conformanceStrain` from one entry and stamps both with it.
    func test_conformanceRows_pairEveryStrainWithTheClauseItPullsAgainst() {
        let holds = makeClause("Cold, and never wistful.", "holds")
        let strainsClause = makeClause("Kelly only acts on what she has heard.", "strains")
        let silent = makeClause("The weather is a character.", "silent")
        let strain = makeDiagnostic(
            docId: "d1", body: "She answers a question nobody asked her.",
            kind: .conformanceStrain,
            clauseQuote: "Kelly only acts on what she has heard.")

        let paired = DiagnosticsPane.conformanceRows(
            clauses: [holds, strainsClause, silent], strains: [strain])

        XCTAssertEqual(paired.rows.map(\.status.clauseQuote),
                       [holds.clauseQuote, strainsClause.clauseQuote, silent.clauseQuote],
                       "the clauses keep the order the run reported them in")
        XCTAssertEqual(paired.rows[0].strains.count, 0)
        XCTAssertEqual(paired.rows[1].strains.map(\.id), [strain.id])
        XCTAssertEqual(paired.rows[2].strains.count, 0)
        XCTAssertTrue(paired.orphans.isEmpty)
    }

    /// **A strain whose clause is missing from the summary is still drawn.**
    /// It cannot happen through the ingest — both records are minted from one
    /// entry — and the alternative to handling it is a note the compiler raised
    /// vanishing with nothing said, which is the loss shape this codebase keeps
    /// paying for.
    func test_conformanceRows_neverSwallowAStrainWhoseClauseIsNotInTheSummary() {
        let unquoted = makeDiagnostic(
            docId: "d1", body: "Something pulls.", kind: .conformanceStrain,
            clauseQuote: nil)
        let mismatched = makeDiagnostic(
            docId: "d1", body: "Something else pulls.", kind: .conformanceStrain,
            clauseQuote: "A clause this run never reported.")

        let paired = DiagnosticsPane.conformanceRows(
            clauses: [makeClause("Cold, and never wistful.", "holds")],
            strains: [unquoted, mismatched])

        XCTAssertEqual(paired.orphans.map(\.id), [unquoted.id, mismatched.id])
        XCTAssertEqual(paired.rows.count, 1, "control: the clause itself still rendered")
    }

    /// **A clause declared twice makes two rows with two identities.**
    ///
    /// `conformanceRows` renders the duplicate on purpose (its doc: "a
    /// wrong-looking duplicate is a smaller harm than a missing finding"), and
    /// the rows go straight into a SwiftUI `ForEach` — whose behaviour on
    /// repeated ids is undefined, so keying on the quote alone made the
    /// intended case the broken one. The strains are asserted alongside,
    /// because an id built from position must not be one a row can be *sorted*
    /// out of agreement with.
    func test_conformanceRows_giveDuplicateClausesDistinctIdentities() {
        let quote = "Cold, and never wistful."
        let strain = makeDiagnostic(
            docId: "d1", body: "It reads fond here.", kind: .conformanceStrain,
            clauseQuote: quote)

        let paired = DiagnosticsPane.conformanceRows(
            clauses: [makeClause(quote, "holds"), makeClause(quote, "strains")],
            strains: [strain])

        XCTAssertEqual(paired.rows.count, 2, "the duplicate is kept, by design")
        XCTAssertEqual(Set(paired.rows.map(\.id)).count, 2,
                       "two rows shared one ForEach id: \(paired.rows.map(\.id))")
        XCTAssertTrue(paired.rows.allSatisfy { $0.id.contains(quote) },
                      "the writer's own sentence is still part of the identity")
        XCTAssertEqual(paired.rows.map { $0.strains.map(\.id) }, [[strain.id], [strain.id]],
                       "both rows still carry the strain raised against that sentence")
    }

    /// Three quiet marks, each with a word VoiceOver can read — a glyph alone
    /// is silent — and a neutral fourth for a status this build has never heard
    /// of, so a later contract's word cannot render as "holds".
    func test_everyClauseStatusHasItsOwnMarkAndItsOwnWord() {
        let symbols = ["holds", "strains", "silent"].map(DiagnosticsPane.statusSymbol)
        XCTAssertEqual(Set(symbols).count, 3, "got: \(symbols)")
        XCTAssertEqual(DiagnosticsPane.statusWord("holds"), "holds")
        XCTAssertEqual(DiagnosticsPane.statusWord("strains"), "strains")
        XCTAssertFalse(DiagnosticsPane.statusWord("silent").isEmpty)

        XCTAssertFalse(symbols.contains(DiagnosticsPane.statusSymbol("recanted")),
                       "an unknown status must not borrow one of the three marks")
        XCTAssertEqual(DiagnosticsPane.statusWord("recanted"), "recanted")
    }

    /// **A clean conformance report is the good outcome, not an empty pane.**
    /// A run whose every clause holds raises no diagnostics at all — and a pane
    /// that showed `ContentUnavailableView` for it would say the check never
    /// happened, over a check that came back with the best answer there is.
    func test_theSummaryRendersWithNoDiagnosticsAtAll() {
        let docId = "doc-clean-report"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(
            run: makeRun(clauseStatuses: [
                makeClause("Cold, and never wistful.", "holds"),
                makeClause("The weather is a character.", "silent")]),
            diagnostics: [], docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.3)

        XCTAssertEqual(staticTextLabels(in: window, containing: "Cold, and never wistful.").count, 1,
                       "the writer's own clause must be quoted back to them")
        XCTAssertEqual(staticTextLabels(in: window, containing: "The weather is a character.").count, 1)
        // The HEADER still says "Nothing to flag." and should: this run raised
        // no notes. What must not be here is the empty state, which would put
        // that sentence where the report goes and say the check found nothing
        // to report at all.
        XCTAssertTrue(
            staticTextLabels(
                in: window,
                containing: "The compiler found nothing to raise against the last check.").isEmpty,
            "the empty state must not stand over a report that has clauses in it")
    }

    /// **The pane draws the conformance report and nothing else** (M4 P1
    /// Task 3) — the mounted half of the one-home rule.
    ///
    /// A continuity question and a reader's report no longer reach a sidecar at
    /// all; they mint as annotations when the run finishes. This drives the
    /// harder case on purpose: a store handed all three kinds, as a build one
    /// version older would have written it. The strain still renders; the other
    /// two render nowhere, so a legacy sidecar cannot put a second copy of a
    /// note in front of the writer.
    func test_onlyTheConformanceStrainRenders_theOtherTwoKindsHaveLeft() {
        let docId = "doc-one-home"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(
            run: makeRun(clauseStatuses: [makeClause("A clause of mine.", "strains")],
                         truncatedReader: 2),
            diagnostics: [
                makeDiagnostic(docId: docId, body: "The reader stopped believing her.",
                               category: "belief", kind: .readerReport),
                makeDiagnostic(docId: docId, body: "Was that learned offstage?",
                               kind: .continuity),
                makeDiagnostic(docId: docId, body: "The sentence pulls the other way.",
                               kind: .conformanceStrain, clauseQuote: "A clause of mine."),
            ],
            docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.3)

        let labels = allLabels(in: window)
        XCTAssertTrue(labels.contains { $0.contains("The sentence pulls the other way.") },
                      "control: the strain is still the report, and it renders")
        XCTAssertFalse(labels.contains { $0.contains("Was that learned offstage?") },
                       "a continuity question rendered on the pane as well as "
                       + "minting as a note \u{2014} two homes for one finding")
        XCTAssertFalse(labels.contains { $0.contains("The reader stopped believing her.") },
                       "a reader's report rendered on the pane as well as "
                       + "minting as a note")
        XCTAssertFalse(labels.contains { $0.contains("Continuity") },
                       "the Continuity section header outlived its rows")
        XCTAssertFalse(labels.contains { $0.contains("The reader had more to say.") },
                       "the reader's truncation sentence belongs beside the "
                       + "reports it is about, and they are not here")
    }

    /// …and a report made only of the kinds that left is an EMPTY pane, not a
    /// pane claiming a report it draws nothing for.
    ///
    /// **This is the LEGACY case, and it is the honest one**: a sidecar written
    /// by an older build, whose run record knows nothing of a mint
    /// (`mintedNotes == nil`). Nothing happened that this build can show and
    /// nothing went anywhere else, so the seal is true. Its live counterpart —
    /// a run that really did queue notes — is the test below, and the two are
    /// adjacent because the copy must tell them apart.
    func test_aLegacySidecarOfOnlyContinuityAndReaderShowsNoReportAtAll() {
        let docId = "doc-legacy-only"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(
            run: makeRun(),
            diagnostics: [
                makeDiagnostic(docId: docId, body: "Was that learned offstage?",
                               kind: .continuity),
            ],
            docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.3)

        XCTAssertFalse(allLabels(in: window).contains { $0.contains("Was that learned offstage?") },
                       "the question rendered after all")
        XCTAssertFalse(
            staticTextLabels(in: window, containing: "Nothing to flag").isEmpty
                && staticTextLabels(in: window, containing: "nothing to raise").isEmpty,
            "a pane with no drawable rows must say so rather than render a "
            + "report with nothing in it")
    }

    /// **THE PANE NEVER SAYS NOTHING HAPPENED WHEN SOMETHING DID** (M4 P1
    /// review, Important 1) — mounted, because the falsehood was a rendered
    /// sentence rather than a wrong value.
    ///
    /// A run raising three continuity questions and no conformance strain
    /// leaves this store empty and the writer's queue three notes fuller. Every
    /// surface here keyed on "were there diagnostics?" — the header copy, the
    /// empty state's seal, the badge — and all three answered "clean".
    func test_aRunThatQueuedNotesNeverClaimsItFoundNothing() {
        let docId = "doc-minted-clean"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(run: makeRun(mintedNotes: 3), diagnostics: [], docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.3)

        let labels = allLabels(in: window)
        XCTAssertTrue(labels.contains { $0.contains("3 notes went to your queue") },
                      "the pane must say what the run did with its findings; got "
                      + "\(labels)")
        XCTAssertFalse(labels.contains { $0.contains("Nothing to flag") },
                       "the pane told the writer the check found nothing over a "
                       + "check that raised three notes")
        XCTAssertFalse(labels.contains { $0.contains("nothing to raise") },
                       "…and the seal's description said it a second time")
    }

    /// The same rule at the source, where every sentence is assertable without
    /// a mount — and the one-note wording, which a mounted test would only
    /// reach by rendering a second pane.
    func test_theCleanCopyDefersToWhatWentToTheQueue() {
        let queued = makeRun(mintedNotes: 1)
        XCTAssertTrue(
            DiagnosticsPane.headerCopy(for: .clean(lastRun: queued))
                .hasPrefix("1 note went to your queue."),
            DiagnosticsPane.headerCopy(for: .clean(lastRun: queued)))
        XCTAssertFalse(
            DiagnosticsPane.headerCopy(for: .clean(lastRun: queued))
                .contains("Nothing to flag"))
        XCTAssertEqual(
            DiagnosticsPane.emptyState(for: .clean(lastRun: queued)).title,
            "Notes in your queue")

        // Zero and nil both mean "nothing went anywhere", and neither may
        // invent a sentence claiming a count.
        for nothing in [makeRun(mintedNotes: 0), makeRun()] {
            XCTAssertTrue(
                DiagnosticsPane.headerCopy(for: .clean(lastRun: nothing))
                    .hasPrefix("Nothing to flag."),
                "a run that queued nothing must still be allowed to say so")
            XCTAssertEqual(
                DiagnosticsPane.emptyState(for: .clean(lastRun: nothing)).symbol,
                "checkmark.seal")
        }
        XCTAssertNil(DiagnosticsPane.queuedNotesSentence(nil))
        XCTAssertNil(DiagnosticsPane.queuedNotesSentence(0))
    }

    /// A run can both queue notes AND lose some, and the queued ones are the
    /// news — the discard is the footnote it has always been.
    func test_theQueuedSentenceOutranksTheDiscardFootnote() {
        let both = makeRun(droppedDangling: 2, mintedNotes: 3)
        let header = DiagnosticsPane.headerCopy(for: .clean(lastRun: both))
        XCTAssertTrue(header.hasPrefix("3 notes went to your queue."), header)
        XCTAssertTrue(header.contains("were discarded"), header)
        XCTAssertEqual(
            DiagnosticsPane.emptyState(for: .clean(lastRun: both)).title,
            "Notes in your queue",
            "the discard arm took the empty state back to a seal over a run "
            + "that queued three notes")
    }

    // MARK: - Excerpt chips (requirement 3)

    /// **No paragraph id is rendered anywhere on this pane.** Every reference
    /// travels as the words that paragraph said, and the id is a payload the
    /// chip carries and never shows.
    ///
    /// The walk is proved against a **planted offender**: the same tree,
    /// carrying a view that does print an id, must fail the same predicate —
    /// otherwise a pane that rendered every id in the project would pass this
    /// as happily as one that renders none.
    func test_noParagraphIdIsEverRendered() {
        let docId = "doc-no-ids"
        let ids = ["a1b2", "c3d4", "e5f6"]
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(
            run: makeRun(clauseStatuses: [
                makeClause("Cold, and never wistful.", "strains",
                           refs: [ref(ids[0], "The fog came in off the water and")])]),
            diagnostics: [
                makeDiagnostic(
                    docId: docId,
                    anchor: Diagnostic.Anchor(paragraphId: ids[0], anchorText: "The fog came in."),
                    body: "The sentence pulls the other way.", kind: .conformanceStrain,
                    refs: [ref(ids[0], "The fog came in off the water and")],
                    clauseQuote: "Cold, and never wistful."),
                makeDiagnostic(
                    docId: docId, body: "Was that learned offstage?",
                    refs: [ref(ids[1], "She already knew about the letter"),
                           ref(ids[2], "He had not told anyone yet")]),
            ],
            docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            // The anchored note's paragraph still reads as it did, so the
            // strain is live and its chip is on screen to be walked.
            currentText: { _ in "The fog came in." }, compilerModel: .standard)))
        pump(0.3)

        let rendered = allLabels(in: window)
        for id in ids {
            XCTAssertFalse(rendered.contains { $0.contains(id) },
                           "the pane rendered the paragraph id \u{201C}\(id)\u{201D}: "
                           + "\(rendered.filter { $0.contains(id) })")
        }
        XCTAssertTrue(rendered.contains { $0.contains("The fog came in off the water and") },
                      "control: the chip's own words did render, so the walk sees chips")

        // The planted offender: the same walk over a pane that DOES print an id
        // must find it, or the assertions above are unfalsifiable.
        let offender = mount(AnyView(VStack {
            Text("\u{00b6}\(ids[0])")
        }))
        pump(0.2)
        XCTAssertTrue(allLabels(in: offender).contains { $0.contains(ids[0]) },
                      "the accessibility walk cannot see a rendered id at all, so the "
                      + "assertions above prove nothing")
    }

    /// A chip is a real button, and pressing it makes the same jump the row
    /// makes — the anchor row's own machinery, reached from the writer's own
    /// words.
    func test_pressingAnExcerptChipJumpsToThatParagraph() async throws {
        let docId = "doc-chip-jump"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(
                docId: docId, body: "Was that learned offstage?",
                refs: [ref("c3d4", "She already knew about the letter")])],
            docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.3)

        let chip = try button(
            labelled: "\u{201C}She already knew about the letter\u{201D}", in: window)
        let received = await notesPosted(pressing: chip, on: .maughamNavigateToParagraph)

        XCTAssertEqual(received.count, 1, "the chip must post exactly one jump")
        XCTAssertEqual(received.first?.userInfo?["paragraph_id"] as? String, "c3d4")
    }

    // MARK: - Tripwire 15

    func test_everyContentUnavailableViewChainsFullFrame() throws {
        let source = try readSource("Maugham/Views/DiagnosticsPane.swift")
        let occurrences = source.components(separatedBy: "ContentUnavailableView(").count - 1
        let chained = source.components(
            separatedBy: ".frame(maxWidth: .infinity, maxHeight: .infinity)").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 1)
        XCTAssertGreaterThanOrEqual(chained, occurrences,
                                    "every ContentUnavailableView must chain the full-frame modifier (tripwire 15)")
    }

    // MARK: - Registry wiring

    func test_diagnosticsIsAuthorsFirstPane() {
        XCTAssertEqual(Persona.author.defaultPane, .diagnostics)
        XCTAssertFalse(Persona.plan.panes.contains(.diagnostics))
        XCTAssertFalse(Persona.review.panes.contains(.diagnostics))
        XCTAssertFalse(Persona.publish.panes.contains(.diagnostics))
    }

    // MARK: - The fates: answering is ruling (spec §5)
    //
    // Migrated here when `IntentAppendPerformer` was deleted. What the shim's
    // own suite asserted about the performer had already moved to
    // `RulingPerformerTests`; what stays is the pane's half of the loop, now
    // driven through the reply path that routes to `RulingPerformer.rule`
    // directly.

    /// **Which notes offer to be answered.** A conformance strain and a
    /// continuity question each ask the writer something, and the answer is a
    /// decision — a ruling. A reader report is not a question: "I stopped
    /// believing her here" has no answer to rule on.
    func test_onlyQuestionsOfferAnAnswer() {
        XCTAssertTrue(DiagnosticsPane.offersAnAnswer(
            makeDiagnostic(docId: "d1", kind: .conformanceStrain)))
        XCTAssertTrue(DiagnosticsPane.offersAnAnswer(
            makeDiagnostic(docId: "d1", kind: .continuity)))
        XCTAssertFalse(DiagnosticsPane.offersAnAnswer(
            makeDiagnostic(docId: "d1", kind: .readerReport)))
    }

    /// …and the affordance obeys it on the mounted pane, where a writer can
    /// see it: a conformance strain's row offers **Answer** and **Promote**.
    ///
    /// **The reader-report half of this test is gone with the row it was
    /// about** (M4 P1 Task 3). A reader's report no longer reaches this pane at
    /// all, so the rule that it offers no reply field is now only assertable
    /// against the pure predicate above — where it still is, and where
    /// `offersAnAnswer` still refuses it.
    func test_theStrainsRowOffersAnswerAndPromote() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "FatesAffordance")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(
                docId: chapter.id, body: "The sentence pulls the other way.")],
            docId: chapter.id)

        let window = mount(pane(store: store, diagnostics: diagnostics, docId: chapter.id))
        pump(0.3)
        XCTAssertNotNil(findButton(labelled: "Answer", in: window),
                        "a strain asks the writer something, and the reply is a "
                        + "ruling \u{2014} that is what Answer is for")
        XCTAssertNotNil(findButton(labelled: "Promote to Task", in: window),
                        "control: the row itself rendered")
    }

    /// An answerable note offers Answer, and pressing it puts a text field on
    /// the row. Asserted against the real accessibility tree, so the affordance
    /// is one a writer (and VoiceOver) can actually reach.
    func test_answerRevealsAFieldOnAQuestion() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerRevealsField")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(
                docId: chapter.id,
                anchor: Diagnostic.Anchor(paragraphId: "a1b2", anchorText: "The fog came in."),
                body: "Was that learned offstage?")],
            docId: chapter.id)

        let window = mount(pane(store: store, diagnostics: diagnostics, docId: chapter.id,
                                currentText: { _ in "The fog came in." }))
        pump(0.2)
        XCTAssertTrue(textFields(in: window).isEmpty, "the field is revealed, not standing")

        let answer = try button(labelled: "Answer", in: window)
        _ = answer.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.3)

        XCTAssertFalse(
            textFields(in: window).isEmpty,
            "pressing Answer must put a field on the row \u{2014} otherwise the action "
            + "names something the writer cannot type into")
    }

    /// The pane offers no Answer at all without a store to write through, so a
    /// press can never reach a destination that does not exist.
    func test_withoutAProjectStoreThereIsNoAnswerAction() async throws {
        let (url, _, chapter) = try await loadedNovel(named: "AnswerNoStore")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(
                docId: chapter.id,
                anchor: Diagnostic.Anchor(paragraphId: "a1b2", anchorText: "The fog came in."),
                body: "Was that learned offstage?")],
            docId: chapter.id)

        let window = mount(pane(store: nil, diagnostics: diagnostics, docId: chapter.id,
                                currentText: { _ in "The fog came in." }))
        pump(0.2)

        XCTAssertNil(findButton(labelled: "Answer", in: window))
        XCTAssertNotNil(findButton(labelled: "Promote to Task", in: window),
                        "control: the row itself rendered")
    }

    /// **The whole loop in one test**, driven through the exact function the
    /// reply field's `.onSubmit` calls: the answer reaches the piece's rulings
    /// as a *ruling* — dated, with provenance, leaving the essay the writer
    /// wrote untouched — AND the note leaves the pane. The dismissal is what
    /// stops the writer being asked to answer the same note twice.
    func test_answeringLandsARulingAndDismissesTheNote() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerBecomesRuling")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement(
            "A ghost story told in weather.", to: statement, session: "seed")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let note = makeDiagnostic(
            docId: chapter.id,
            anchor: Diagnostic.Anchor(paragraphId: "a1b2", anchorText: "The fog came in."),
            body: "Was that learned offstage?", kind: .continuity)
        diagnostics.replace(run: makeRun(), diagnostics: [note], docId: chapter.id)

        let answer = "The repetition is deliberate \u{2014} the fog is a refrain."
        let failure = await DiagnosticsPane.commitAnswer(
            answer, to: note, docId: chapter.id, store: store, world: nil,
            diagnostics: diagnostics)

        XCTAssertNil(failure, "the commit reported: \(failure ?? "")")
        XCTAssertTrue(
            diagnostics.live(docId: chapter.id, currentText: { _ in "The fog came in." }).isEmpty,
            "an answered note has become a ruling \u{2014} leaving it on the pane asks "
            + "the writer to answer it twice")

        let parsed = RulingsSection.parse(try await derivedText(of: statement, in: url))
        XCTAssertEqual(
            parsed.essay, "A ghost story told in weather.",
            "the essay is the writer's own prose and an answer must not join it")
        XCTAssertEqual(parsed.rulings.map(\.text), [answer])
        XCTAssertNotNil(parsed.rulings.first?.ruledOn, "and it carries the day it was ruled")
        XCTAssertEqual(parsed.rulings.first?.provenance, "answered a compiler note")
    }

    /// **The provenance names no paragraph, and does not restate the date.**
    /// The line a writer reads carries `ruled <date>` from `RulingsSection`
    /// itself, so a provenance carrying one too would print the day twice — and
    /// the ¶ spelling the deleted shim anticipated ("from a run on ¶wnse") is
    /// exactly what requirement 3 takes off every surface the writer reads.
    func test_theRulingsLineCarriesTheDateOnceAndNoParagraphId() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerProvenance")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let note = makeDiagnostic(
            docId: chapter.id,
            anchor: Diagnostic.Anchor(paragraphId: "wnse", anchorText: "The fog came in."),
            body: "Was that learned offstage?", kind: .continuity,
            refs: [ref("wnse", "The fog came in off the water")])
        diagnostics.replace(run: makeRun(), diagnostics: [note], docId: chapter.id)

        _ = await DiagnosticsPane.commitAnswer(
            "Deliberate.", to: note, docId: chapter.id, store: store, world: nil,
            diagnostics: diagnostics)

        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: .document(chapter.id)))
        let markdown = try await derivedText(of: statement, in: url)
        XCTAssertTrue(markdown.contains("ruled "), "got: \(markdown)")
        XCTAssertTrue(markdown.contains("answered a compiler note"))
        XCTAssertFalse(markdown.contains("wnse"),
                       "a ruling's provenance is prose the writer reads for as long as the "
                       + "decision stands, and a bare \u{00b6}id is what v2 removed")
        XCTAssertEqual(markdown.components(separatedBy: "ruled ").count - 1, 1,
                       "the day is stamped once")
    }

    /// **A refused answer keeps the note AND reports why.** The writer's words
    /// are still in the field they typed them into; dismissing a note whose
    /// answer went nowhere would lose both.
    func test_aRefusedAnswerLeavesTheNoteStanding() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerRefusedKeepsNote")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try Self.undecodableBytes.write(to: url.appendingPathComponent(statement.path))
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let note = makeDiagnostic(
            docId: chapter.id,
            anchor: Diagnostic.Anchor(paragraphId: "a1b2", anchorText: "The fog came in."),
            body: "Was that learned offstage?", kind: .continuity)
        diagnostics.replace(run: makeRun(), diagnostics: [note], docId: chapter.id)

        let failure = await DiagnosticsPane.commitAnswer(
            "Deliberate.", to: note, docId: chapter.id, store: store, world: nil,
            diagnostics: diagnostics)

        XCTAssertNotNil(failure, "a refusal must reach the writer as a sentence")
        XCTAssertEqual(
            diagnostics.live(docId: chapter.id,
                             currentText: { _ in "The fog came in." }).count, 1,
            "the note stays \u{2014} the answer went nowhere")
    }

    /// **An answer changes the world the next run is checked against, so the
    /// reading made before it has to go.**
    ///
    /// The shim this replaced passed `nil` here because no pane held the store,
    /// and recorded the gap in its own doc comment. A cached derivation that
    /// survived a ruling would check the writer against a world they had just
    /// changed — a run later, with nothing red anywhere.
    func test_answeringDropsTheDerivationTheRulingHasJustOutdated() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerInvalidates")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let world = DeclaredWorldStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let scopeKey = DeclaredWorldStore.scopeKey(for: .document(chapter.id))
        let hash = DerivedWorld.sourceHash(of: "Cold, and never wistful.")
        world.store(
            DerivedWorld(sourceHash: hash,
                         clauses: [DerivedClause(quote: "Cold, and never wistful.",
                                                 check: "no wistfulness")],
                         rules: [], derivedAt: Date()),
            forScopeKey: scopeKey)
        XCTAssertNotNil(world.cached(forScopeKey: scopeKey, sourceHash: hash),
                        "control: the reading was cached before the answer")

        let note = makeDiagnostic(docId: chapter.id, body: "Was that learned offstage?",
                                  kind: .continuity)
        diagnostics.replace(run: makeRun(), diagnostics: [note], docId: chapter.id)

        let failure = await DiagnosticsPane.commitAnswer(
            "Deliberate.", to: note, docId: chapter.id, store: store, world: world,
            diagnostics: diagnostics)

        XCTAssertNil(failure, "the commit reported: \(failure ?? "")")
        XCTAssertNil(world.cached(forScopeKey: scopeKey, sourceHash: hash),
                     "the ruling changed the prose the clauses are derived from, and the "
                     + "reading made before it must not be served again")
    }

    /// **The wiring the accessibility tree cannot press.** SwiftUI exposes no
    /// way to deliver a Return keystroke into a hosted `TextField`'s editor, so
    /// the two verbs the field's contract turns on — commit on return, escape
    /// cancels — are asserted at the source. Named functions rather than
    /// spelled-out bodies, so a rename fails this rather than a reformat.
    func test_theReplyFieldCommitsOnReturnAndCancelsOnEscape() throws {
        let source = try readSource("Maugham/Views/DiagnosticsPane.swift")
        XCTAssertTrue(
            source.contains(".onSubmit { commit() }"),
            "return must commit the answer \u{2014} a field with no submit verb is a "
            + "box the writer types into and cannot send")
        XCTAssertTrue(
            source.contains(".onExitCommand { cancel() }"),
            "escape must take the field away without writing anything")
        XCTAssertTrue(
            source.contains("Self.commitAnswer("),
            "and the pane must go through the one function the tests above drive \u{2014} "
            + "a ruling spelled out again at the call site is a path nothing covers")
        XCTAssertTrue(
            source.contains("onAnswer(words)"),
            "the row hands the WORDS up rather than writing them itself; a row that "
            + "reached `RulingPerformer` directly would own the failure state the pane "
            + "is holding for it")
    }

    /// **The shim is gone.** `IntentAppendPerformer` was M2's answer flow kept
    /// alive for one stage as a route into `RulingPerformer.rule`; the reply
    /// field calls the verb itself now, and a file that exists only to be
    /// deleted is one a later reader will wire something new into.
    func test_theDeprecatedAnswerShimIsGone() {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent(
                    "Maugham/Compiler/IntentAppendPerformer.swift").path),
            "the answer shim must not come back \u{2014} the pane routes to "
            + "RulingPerformer.rule directly")
    }

    // MARK: - A preview carries no fates (C1)

    /// **The pure gate.** Only a run in flight for THIS document withholds the
    /// fates; every other state is a report that finished, and its rows are the
    /// writer's to act on.
    ///
    /// `.failed` and `.nothingNew` are the interesting arms: both describe a
    /// run that is over, and what stands under them is the previous run's
    /// report off the sidecar. Withholding there would strand answerable notes
    /// behind a check that died.
    func test_offersDurableActions_isFalseOnlyWhileThisDocumentIsRunning() {
        let run = makeRun()
        XCTAssertFalse(DiagnosticsPane.offersDurableActions(
            state: .running(checking: counts(new: 1, revised: 0))))
        XCTAssertTrue(DiagnosticsPane.offersDurableActions(state: .neverRun))
        XCTAssertTrue(DiagnosticsPane.offersDurableActions(state: .idle(lastRun: run)))
        XCTAssertTrue(DiagnosticsPane.offersDurableActions(state: .clean(lastRun: run)))
        XCTAssertTrue(DiagnosticsPane.offersDurableActions(state: .nothingNew(at: Date())),
                      "a run that found nothing is over \u{2014} what stands is the last "
                      + "finished report, and it is answerable")
        XCTAssertTrue(DiagnosticsPane.offersDurableActions(
            state: .failed(.timedOut, at: Date())),
                      "a run that died never replaced anything, so the previous run's "
                      + "notes must not be frozen behind it")
    }

    /// **The whole of C1, on the mounted pane and driven by a real stream.**
    ///
    /// A section landing mid-turn is readable — that is what streaming is for —
    /// but it carries neither fate, because both end in
    /// `DiagnosticsStore.dismiss` and a dismissal against a preview persists
    /// the half-report. The affordances arrive with the reconciled report when
    /// the turn ends.
    ///
    /// The two arms are each other's falsification: the note's own words are
    /// asserted present in the first arm (so "no Answer button" is not "no row
    /// rendered"), and the buttons are asserted present in the second (so the
    /// first arm's absence is the gate rather than the query). Force
    /// `offersDurableActions` to `true` and the first arm goes red; drop the
    /// second and the test could pass over a pane that never draws them at all.
    func test_aPreviewsRowsCarryNoFates_andTheReconciledReportDoes() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "PreviewNoFates")
        let runner = SpyRunner()
        runner.nextEvent = nil   // hold the turn open
        let orchestrator = CompilerOrchestrator()
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        orchestrator.configure(
            environment: makeEnvironment(docId: chapter.id, runner: runner),
            diagnostics: diagnostics)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: orchestrator, diagnostics: diagnostics, docId: chapter.id,
            currentText: { _ in "The fog came." }, compilerModel: .standard,
            store: store)))

        orchestrator.runRequested(docId: chapter.id)
        await awaitSends(1, on: runner)
        runner.stream(Self.streamedQuestion + "\n")
        waitUntil { self.staticTextLabels(in: window, containing: Self.questionBody).count == 1 }

        XCTAssertEqual(staticTextLabels(in: window, containing: Self.questionBody).count, 1,
                       "the streamed section must be READABLE \u{2014} that is the whole "
                       + "value of the preview, and the control for the two assertions below")
        XCTAssertNil(findButton(labelled: "Answer", in: window),
                     "answering a preview persists the half-report through dismiss")
        XCTAssertNil(findButton(labelled: "Promote to Task", in: window),
                     "promoting a preview persists it the same way")

        runner.release(.resultText(Self.turnCarryingTheQuestion))
        try? await Task.sleep(for: .milliseconds(300))
        pump(0.3)

        XCTAssertNotNil(findButton(labelled: "Answer", in: window),
                        "the fates arrive with the reconciled report")
        XCTAssertNotNil(findButton(labelled: "Promote to Task", in: window))
    }

    /// **A run on another document leaves this pane's fates exactly where they
    /// were.** The run state is per-window and this pane is per-document — the
    /// same asymmetry `headerState`'s `where runDocId == docId` exists for, and
    /// the reason `offersDurableActions` reads `HeaderState` rather than
    /// reaching for `runState` a second way.
    func test_aRunOnAnotherDocumentLeavesThisPanesFatesAlone() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "OtherDocRunning")
        let otherDocId = "doc-somewhere-else"
        let runner = SpyRunner()
        runner.nextEvent = nil
        let orchestrator = CompilerOrchestrator()
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        orchestrator.configure(
            environment: makeEnvironment(docId: otherDocId, runner: runner),
            diagnostics: diagnostics)
        diagnostics.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(
                docId: chapter.id,
                anchor: Diagnostic.Anchor(paragraphId: "a1b2", anchorText: "The fog came."),
                body: "Was that learned offstage?")],
            docId: chapter.id)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: orchestrator, diagnostics: diagnostics, docId: chapter.id,
            currentText: { _ in "The fog came." }, compilerModel: .standard,
            store: store)))
        XCTAssertNotNil(findButton(labelled: "Answer", in: window),
                        "control: the finished run's note is answerable before anything runs")

        orchestrator.runRequested(docId: otherDocId)
        await awaitSends(1, on: runner)
        pump(0.3)

        XCTAssertNotNil(findButton(labelled: "Answer", in: window),
                        "another document's run must not freeze this document's report")
        XCTAssertNotNil(findButton(labelled: "Promote to Task", in: window))

        runner.release(.resultText(Self.turnCarryingTheQuestion))
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// The one finding this section streams, and the words that prove its row
    /// reached the pane.
    ///
    /// **A conformance strain, since M4 P1 Task 3**: continuity and reader
    /// sections accumulate during a stream and preview nothing, because they
    /// are no longer the sidecar's. A strain is what a half-arrived report can
    /// still put in front of the writer, which is what these tests are about.
    private static let questionBody = "Should she already know?"

    private static let streamedQuestion =
        "{\"section\":\"conformance\",\"checks\":[{\"clause_quote\":\"Cold, and never wistful.\","
        + "\"status\":\"strains\",\"refs\":[\"a1b2\"],\"what_pulls\":\"\(questionBody)\"}]}"

    /// The turn's own text, carrying the streamed section again — where it
    /// always was. `finish` reconciles from this, not from the stream.
    private static let turnCarryingTheQuestion = """
        \(streamedQuestion)
        {"section":"continuity","questions":[]}
        {"section":"reader","reports":[]}
        {"section":"facts","candidates":[]}
        """

    // MARK: - Fixtures: a fake compiler runner (mirrors CompilerRunCommandTests.SpyRunner)

    @MainActor
    private final class SpyRunner: CompilerRunner {
        private(set) var cancels = 0
        var isRunning = false
        var sessionEpoch = 1
        var nextEvent: CompilerRunEvent? = .resultText(#"{"diagnostics":[]}"#)
        /// Every `--model` the orchestrator has spawned a session against, in
        /// order. Recorded here rather than in a box beside the test because
        /// `Environment.makeRunner` hands the model to whoever builds the
        /// runner, and this IS that.
        var spawnedModels: [String] = []
        var onSend: (() -> Void)?
        private var held: CheckedContinuation<CompilerRunEvent, Never>?
        private(set) var sendCount = 0
        /// Where the orchestrator asked its stream to go — the same seam
        /// `CompilerRunCommandTests.SpyRunner` records, so this suite can BE
        /// the CLI's stdout and put a real preview on a mounted pane.
        private var partialHandler: (@MainActor (String) -> Void)?

        func setPartialHandler(_ handler: (@MainActor (String) -> Void)?) {
            partialHandler = handler
        }

        func stream(_ chunk: String) { partialHandler?(chunk) }

        func send(message: String, systemPreamble: String?) async -> CompilerRunEvent {
            sendCount += 1
            onSend?()
            if let nextEvent { return nextEvent }
            isRunning = true
            return await withCheckedContinuation { held = $0 }
        }

        func release(_ event: CompilerRunEvent) {
            isRunning = false
            let continuation = held
            held = nil
            continuation?.resume(returning: event)
        }

        func cancelCurrentRun() {
            cancels += 1
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)))
        }

        func shutdown() {
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown)))
        }
    }

    private func makeEnvironment(docId: String, runner: SpyRunner) -> CompilerOrchestrator.Environment {
        CompilerOrchestrator.Environment(
            projectId: "p-1",
            model: "test-model",
            prepareForRun: { _ in },
            reading: { id in
                id == docId
                    ? CompilerOrchestrator.DocumentReading(
                        ops: [Op(opId: "op1", docId: docId, at: Date(), device: "macA", session: "s",
                                kind: .bootstrap,
                                changes: [.init(paragraphId: "a1b2", prior: nil, next: "The fog came.")],
                                sequence: nil)],
                        paragraphs: ["a1b2": "The fog came."], sequence: ["a1b2"])
                    : nil
            },
            liveParagraphText: { _, _ in "The fog came." },
            intent: { _ in nil },
            cachedWorld: { _ in nil },
            deriveWorld: { _, _ in nil },
            bibleSlice: { _ in [] },
            recordFacts: { _ in },
            pinnedListing: { _ in [] },
            paletteListing: { [] },
            writeMCPConfig: { self.temp.url.appendingPathComponent("compiler-mcp.json") },
            makeRunner: { _, _ in runner },
            onRunAcknowledged: { _ in })
    }

    /// Poll rather than `XCTestExpectation.wait` — the latter, called from
    /// an `async throws` test method, races the MainActor Task `send` itself
    /// runs on rather than waiting for it (measured here: the expectation
    /// timed out even though `send` runs moments later). `pump` + a bounded
    /// `Task.sleep` loop is `StatementMountFixture.pumpUntil`'s shape.
    private func awaitSends(_ count: Int, on runner: SpyRunner, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runner.sendCount >= count { return }
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Hosting

    private func mount(_ view: AnyView) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump()
        return window
    }

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Accessibility

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so SwiftUI "
                + "never built the tree this test presses through")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    /// Finds a button, retrying briefly to absorb a stray render frame. On a
    /// genuine absence this RECORDS a test failure via `XCTUnwrap` — even
    /// through a caller's `try?`, which swallows the thrown error but not the
    /// `XCTFail` `XCTUnwrap` already issued. That is exactly why a "must NOT
    /// appear" assertion must use `findButton(labelled:in:)` below instead of
    /// `try? button(...)` — the mistake this suite made once, which read as
    /// "the Cancel button never renders" when the button was actually found
    /// on the very first attempt every time; the recorded failure came from
    /// the PRIOR "must not appear yet" check's expected absence.
    private func button(labelled label: String, in window: NSWindow) throws -> NSObject {
        var lastAll: [AnyObject] = []
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            lastAll = try axTree(in: window)
                .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            if let match = lastAll.first(
                where: { (axAttribute($0, "accessibilityLabel") as? String) == label }) as? NSObject {
                return match
            }
            pump(0.05)
        }
        return try XCTUnwrap(
            lastAll.first { (axAttribute($0, "accessibilityLabel") as? String) == label } as? NSObject,
            "no button labelled \u{201C}\(label)\u{201D} reached the hosted pane after "
            + "retrying. Buttons found on the last attempt: "
            + "\(lastAll.map { axAttribute($0, "accessibilityLabel") as? String ?? "nil" })")
    }

    /// The non-recording sibling of `button(labelled:in:)` — for a "must NOT
    /// be present" assertion, which needs a plain optional rather than a
    /// helper whose failure path always calls `XCTFail` regardless of `try?`.
    private func findButton(labelled label: String, in window: NSWindow) -> NSObject? {
        guard let tree = try? axTree(in: window) else { return nil }
        return tree
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .first { (axAttribute($0, "accessibilityLabel") as? String) == label } as? NSObject
    }

    private func staticTextLabels(in window: NSWindow, containing substring: String) -> [String] {
        allLabels(in: window).filter { $0.contains(substring) }
    }

    /// Every string the pane puts in front of a reader, in tree order — what
    /// the id census walks and what the section-order test reads.
    private func allLabels(in window: NSWindow) -> [String] {
        guard let tree = try? axTree(in: window) else { return [] }
        // One string per element (its value, else its label), so a count of
        // matches is a count of things on screen rather than of attributes.
        return tree.compactMap {
            axAttribute($0, "accessibilityValue") as? String
                ?? axAttribute($0, "accessibilityLabel") as? String
        }
    }

    private func textFields(in window: NSWindow) -> [AnyObject] {
        guard let tree = try? axTree(in: window) else { return [] }
        return tree.filter { (axAttribute($0, "accessibilityRole") as? String) == "AXTextField" }
    }

    /// What one button press posted, on `name`. A reference box rather than a
    /// captured local array: the observer's closure is `@Sendable`, and every
    /// post here is made on the main thread by the button the test just
    /// pressed.
    private final class PostBox: @unchecked Sendable {
        private(set) var received: [Notification] = []
        func record(_ note: Notification) { received.append(note) }
    }

    private func notesPosted(
        pressing button: NSObject, on name: Notification.Name = .maughamSetDetailSegment
    ) async -> [Notification] {
        let box = PostBox()
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: capture-only observer inspecting the exact scoped Notification the button posts
            forName: name, object: nil, queue: nil
        ) { box.record($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.2)
        try? await Task.sleep(for: .milliseconds(300))
        pump(0.2)
        return box.received
    }

    // MARK: - Source

    private func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
