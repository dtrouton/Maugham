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
        body: String = "A diagnostic note", category: String? = "rhythm",
        kind: DiagnosticKind = .continuity
    ) -> Diagnostic {
        Diagnostic(id: ULID.generate(), docId: docId, anchor: anchor,
                  body: body, category: category, runId: ULID.generate(), kind: kind)
    }

    private func makeRun(model: String = "sonnet", lastOpId: String? = "op1",
                         droppedDangling: Int = 0) -> CompilerRun {
        let wholeSecond = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return CompilerRun(id: ULID.generate(), at: wholeSecond, model: model,
                           lastOpId: lastOpId, deltaSummary: "1 new, 0 revised \u{00b6}",
                           intentSnapshot: nil, droppedDangling: droppedDangling)
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
            runState: .running(docId: "d1"), lastRun: nil, noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .running)
    }

    /// A run in flight for a DIFFERENT document does not read as "running"
    /// here — this pane is scoped to one document, and `.running` for another
    /// doc must fall through to whatever the last-run record says.
    func test_headerState_runningAnotherDocFallsThroughToLastRun() {
        let run = makeRun()
        let state = DiagnosticsPane.headerState(
            runState: .running(docId: "other-doc"), lastRun: run, noteCount: 0, docId: "d1")
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
            persona: .author, hideOutline: false, including: .inbox)
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

        let running = DiagnosticsPane.emptyState(for: .running)
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

    /// The drift note's "Open Intent" button posts `postDetailSegment(.intent)`
    /// — the same request the inspector's own Intent affordance posts.
    func test_openIntentButton_postsDetailSegmentIntent() async throws {
        let docId = "doc-drift"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(
            run: makeRun(),
            diagnostics: [makeDiagnostic(docId: docId, anchor: nil,
                                        body: "The outline promised a scene that never got written.",
                                        category: nil)],
            docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.2)

        let notes = await notesPosted(pressing: try button(labelled: "Open Intent", in: window))

        XCTAssertEqual(notes.count, 1, "pressing Open Intent should post exactly one request")
        XCTAssertEqual(notes.first?.userInfo?[MaughamEvent.detailSegmentKey] as? String,
                       DetailSegment.intent.rawValue)
    }

    // MARK: - Click-to-jump (wiring census — see reasoning below)

    /// A diagnostic's row has no button role for its tap target (it is the
    /// whole row, like `AnnotationRow`), so this is a source census rather
    /// than a press: it asserts the pane posts the SAME event
    /// `AnnotationsPane.jump` does, with the same payload key, and pins the
    /// pure mapping (anchored → its paragraph id, drift → nothing to jump to)
    /// as a direct unit test.
    func test_jump_targetsTheAnchoredParagraphAndNothingForDrift() {
        let anchored = makeDiagnostic(
            docId: "d1", anchor: Diagnostic.Anchor(paragraphId: "abcd", anchorText: "x"))
        XCTAssertEqual(DiagnosticsPane.paragraphToNavigateTo(for: anchored), "abcd")

        let drift = makeDiagnostic(docId: "d1", anchor: nil)
        XCTAssertNil(DiagnosticsPane.paragraphToNavigateTo(for: drift))
    }

    func test_jump_postsTheSameEventAnnotationsRowUses() throws {
        let source = try readSource("Maugham/Views/DiagnosticsPane.swift")
        XCTAssertTrue(source.contains(".maughamNavigateToParagraph"),
                     "DiagnosticsPane must reuse AnnotationsPane.jump's event, not a copy")
        XCTAssertTrue(source.contains(#"["paragraph_id": pid]"#))
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
            intent: { _ in (nil, "this document") },
            pinnedListing: { _ in [] },
            paletteListing: { [] },
            writeMCPConfig: { self.temp.url.appendingPathComponent("compiler-mcp.json") },
            makeRunner: { _, _ in runner },
            onRunAcknowledged: {})
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
        guard let tree = try? axTree(in: window) else { return [] }
        return tree
            .compactMap { axAttribute($0, "accessibilityValue") as? String
                ?? axAttribute($0, "accessibilityLabel") as? String }
            .filter { $0.contains(substring) }
    }

    private func notesPosted(pressing button: NSObject) async -> [Notification] {
        var received: [Notification] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: capture-only observer inspecting the exact scoped Notification the button posts
            forName: .maughamSetDetailSegment, object: nil, queue: nil
        ) { received.append($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump(0.2)
        try? await Task.sleep(for: .milliseconds(300))
        pump(0.2)
        return received
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
