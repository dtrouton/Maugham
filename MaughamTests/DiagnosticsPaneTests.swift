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
                         mintedNotes: Int? = nil,
                         openInOtherLanes: Int? = nil,
                         letter: Letter? = nil,
                         kind: RunKind? = nil,
                         readerName: String? = nil) -> CompilerRun {
        let wholeSecond = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        return CompilerRun(id: ULID.generate(), at: wholeSecond, model: model,
                           lastOpId: lastOpId, deltaSummary: "1 new, 0 revised \u{00b6}",
                           intentSnapshot: nil, droppedDangling: droppedDangling,
                           clauseStatuses: clauseStatuses, truncatedReader: truncatedReader,
                           passId: passId, round: round, freshEyes: freshEyes,
                           mintedNotes: mintedNotes, openInOtherLanes: openInOtherLanes,
                           kind: kind, readerName: readerName, letter: letter)
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
        reader: AuthorReader = .nobody,
        currentText: @escaping (String) -> String? = { _ in nil }
    ) -> AnyView {
        AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics, docId: docId,
            currentText: currentText, compilerModel: .standard, store: store, world: world,
            reader: reader))
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
        XCTAssertNil(RoundNarrative.paragraphPhrase(counts(new: 0, revised: 0)))
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

    /// The sentences moved to `RoundNarrative` on 2026-08-18 — Review's cockpit
    /// now says the same one about the same death, in one spelling, and this
    /// pane is a caller rather than the owner. What is asserted here is
    /// unchanged; only where it is asked. `ReviewRoundCockpitTests`' census is
    /// what keeps a second copy from reappearing in either file.
    func test_headerState_failedWithHonestCopy() {
        let at = Date()
        let state = DiagnosticsPane.headerState(
            runState: .failed(docId: "d1", failure: .cliNotFound, at: at),
            lastRun: nil, noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .failed(.cliNotFound, at: at))

        XCTAssertTrue(RoundNarrative.failureCopy(.cliNotFound).contains("Claude Code isn't installed"))
        XCTAssertTrue(RoundNarrative.failureCopy(.cliNotFound).contains("Settings"))
        XCTAssertTrue(RoundNarrative.failureCopy(.disabledByToggle).contains("Claude access is off in Settings"))
        XCTAssertTrue(RoundNarrative.failureCopy(.disabledByToggle)
            .contains("Allow Claude to connect (MCP)"),
            "the copy must name the exact Settings toggle (General \u{2192} Claude integration), "
            + "not a paraphrase a writer cannot find")
        XCTAssertFalse(RoundNarrative.failureCopy(.timedOut).isEmpty)
        XCTAssertTrue(RoundNarrative.failureCopy(.sessionDied(detail: "the CLI exited"))
            .contains("the CLI exited"))
        XCTAssertFalse(RoundNarrative.failureCopy(.unusableOutput).isEmpty)
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
        XCTAssertEqual(CompilerModelChoice.exhaustive.claudeModel, "fable")
    }

    /// **The fourth depth** (editorial letter P1, Task 8) — last in the enum
    /// and last in the menu, with its own name and its own literal.
    func test_compilerModelChoiceHasFourCasesWithExhaustiveLast() {
        XCTAssertEqual(CompilerModelChoice.allCases.count, 4)
        XCTAssertEqual(CompilerModelChoice.allCases.last, .exhaustive,
                       "Exhaustive is the further step past Deep, drawn last")
        XCTAssertEqual(CompilerModelChoice.exhaustive.displayName, "Exhaustive")
    }

    /// **Pins existing behaviour** — `UIState.swift`'s
    /// `(try? c.decode(CompilerModelChoice.self, forKey: .compilerModel)) ?? .standard`
    /// was already this permissive before Exhaustive existed. This does not
    /// ADD tolerance; it proves the tolerance already there reads the new
    /// case correctly, and still falls back to Standard on a string neither
    /// case recognizes — the same shape `test_olderUIState_decodesCompilerModelAsStandard`
    /// pins for a MISSING key, one case over for a WRONG one.
    func test_uiStateDecodesExhaustiveAndFallsBackToStandardOnAnUnknownString() throws {
        func decode(_ modelValue: String) throws -> UIState {
            let raw = """
            {
              "schemaVersion": 8,
              "isNoChromeOn": false,
              "binderSegment": "manuscript",
              "researchPreviewVisible": false,
              "compilerModel": "\(modelValue)"
            }
            """
            return try JSONDecoder().decode(UIState.self, from: raw.data(using: .utf8)!)
        }

        XCTAssertEqual(try decode("exhaustive").compilerModel, .exhaustive)
        XCTAssertEqual(try decode("quantum").compilerModel, .standard,
                       "an unrecognized model string must not fail the whole decode")
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

        orchestrator.runRequested(docId: docId, kind: .check)
        await awaitSends(1, on: runner)
        XCTAssertEqual(runner.spawnedModels, ["sonnet"])

        orchestrator.runRequested(docId: docId, kind: .check)
        await awaitSends(2, on: runner)
        XCTAssertEqual(runner.spawnedModels, ["sonnet"],
                       "an unchanged choice must reuse the warm session — respawning per run "
                       + "throws away the one thing the warm session is for")

        orchestrator.updateModel(CompilerModelChoice.deep.claudeModel)
        orchestrator.runRequested(docId: docId, kind: .check)
        await awaitSends(3, on: runner)
        XCTAssertEqual(runner.spawnedModels, ["sonnet", "opus"],
                       "the gear menu moved and the CLI never heard about it")

        // Exhaustive (editorial letter P1, Task 8) reaches the CLI the exact
        // same way the three original choices do — no special-cased fourth
        // literal anywhere between the menu and the spawn.
        orchestrator.updateModel(CompilerModelChoice.exhaustive.claudeModel)
        orchestrator.runRequested(docId: docId, kind: .check)
        await awaitSends(4, on: runner)
        XCTAssertEqual(runner.spawnedModels, ["sonnet", "opus", "fable"],
                       "Exhaustive must reach the CLI as \"fable\" too")
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

        store.markRead(docId: docId, kind: .check)
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
        store.markRead(docId: docId, kind: .check)
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

    /// **The Visual Language segment badges too** (translation pipeline P5) —
    /// a proposal waiting on the writer is exactly the "something changed
    /// while you weren't looking" signal the inbox and diagnostics badges are
    /// for. Its own offset, on the same derivation as the other two.
    func test_theVisualLanguageSegmentBadgesWhenAProposalStands() {
        XCTAssertEqual(DetailPaneToggle<AnyView>.badgeOffset(of: .visualLanguage, in: [.diagnostics, .intent, .visualLanguage, .inspector]), 1)
        XCTAssertTrue(DetailPaneToggle<AnyView>.visualLanguageBadgeHelp.contains("⌘⌥V"))
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

    // MARK: - Who reads this piece's checks (two loops P1 Task 2)
    //
    // `AuthorReader` is the check loop's resolution (`AuthorReaderTests` pins
    // the rule itself); these pin the header's line and the empty-state
    // promise it computes from the SAME value, so the two surfaces cannot name
    // two different people.
    //
    // There is no stage arm here and no test for one: a piece parked in
    // Gould's lane on the review board is still read in Author by the seat,
    // and the "editor · pass" spelling this pane used to draw went with the
    // arm.

    /// **Never her pass name** — "Workshop" appears on no surface a writer
    /// has ever seen (`ReviewPass.laneDisplayName`'s own rule); the coach
    /// reads as an introduction exactly as her round-cockpit line does.
    func test_readerCopy_coachReadsAsAnIntroductionNeverHerPassName() {
        let line = DiagnosticsPane.readerCopy(for: .coach(ReviewPass.coachPreset))
        XCTAssertEqual(line, "Le Guin reads this piece")
        XCTAssertFalse(line.contains("Workshop"), "got: \(line)")
    }

    func test_readerCopy_nobodyIsSignedClaude() {
        XCTAssertEqual(DiagnosticsPane.readerCopy(for: .nobody), "Claude reads this piece")
    }

    /// **One input, two readers.** A test constructing the pane with a coach
    /// reader gets the coach's name in both the header line and the
    /// empty-state promise; the vacated seat is the control, since it is the
    /// other arm and must agree with itself the same way.
    func test_theHeaderLineAndTheEmptyStatePromiseNameTheSameReader_coach() {
        let reader = AuthorReader.coach(ReviewPass.coachPreset)
        let header = DiagnosticsPane.readerCopy(for: reader)
        let empty = DiagnosticsPane.emptyState(for: .neverRun, readerName: reader.editorName)
        XCTAssertTrue(header.contains("Le Guin"), "got: \(header)")
        XCTAssertTrue(empty.description.contains("Le Guin"), "got: \(empty.description)")
    }

    func test_theHeaderLineAndTheEmptyStatePromiseNameTheSameReader_nobody() {
        let reader = AuthorReader.nobody
        let header = DiagnosticsPane.readerCopy(for: reader)
        let empty = DiagnosticsPane.emptyState(for: .neverRun, readerName: reader.editorName)
        XCTAssertTrue(header.contains("Claude"), "got: \(header)")
        XCTAssertTrue(empty.description.contains("Claude"), "got: \(empty.description)")
    }

    func test_emptyState_neverRun_promiseNamesTheGivenReader() {
        let empty = DiagnosticsPane.emptyState(for: .neverRun, readerName: "Le Guin")
        XCTAssertEqual(empty.description, "Press \u{2318}R and Le Guin reads what you've written.")
    }

    /// **`.nobody` reads exactly as before, apart from the new line** — the
    /// pane's default `reader`, so every caller that has not been given one
    /// (and every OTHER `emptyState` test in this file, which passes no
    /// `readerName`) keeps its old behaviour.
    func test_emptyState_neverRun_defaultsToClaudeWhenNoReaderIsGiven() {
        let empty = DiagnosticsPane.emptyState(for: .neverRun)
        XCTAssertEqual(empty.description, "Press \u{2318}R and Claude reads what you've written.")
    }

    /// The mounted pane: a coach reader's name reaches both the header's
    /// reader line and the "Not checked yet" promise beneath it, off the one
    /// `reader` input this pane was given.
    func test_mountedPane_headerAndEmptyStateNameTheSameReader_coach() throws {
        let docId = "doc-reader-coach"
        let diagnosticsStore = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnosticsStore, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard,
            reader: .coach(ReviewPass.coachPreset))))
        pump(0.2)

        let labels = allLabels(in: window)
        XCTAssertTrue(labels.contains("Le Guin reads this piece"), "got: \(labels)")
        XCTAssertTrue(
            labels.contains { $0.contains("Le Guin reads what you've written") },
            "the empty-state promise must name the same editor the header does; got \(labels)")
    }

    /// **`.nobody` — the pane's default — reads exactly as it did before the
    /// seat existed, apart from the new line.**
    func test_mountedPane_readsAsTodayApartFromTheNewLine_nobody() throws {
        let docId = "doc-reader-nobody"
        let diagnosticsStore = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnosticsStore, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        pump(0.2)

        let labels = allLabels(in: window)
        XCTAssertTrue(labels.contains("Claude reads this piece"), "got: \(labels)")
        XCTAssertTrue(
            labels.contains { $0.contains("Claude reads what you've written") },
            "got: \(labels)")
    }

    // MARK: - The reader picker (two loops P2 Task 6)

    /// **A reader is offered only while their premise stands** — the same rule
    /// `ProjectManifest.authorReader(choice:statementText:)` resolves by. All
    /// four cells, windowless (tripwire 33).
    func test_readerMenuItems_offersOnlyTheReadersThisProjectHas() {
        func manifest(vacated: Bool, name: String?) -> ProjectManifest {
            var m = ProjectManifest(
                type: .novel, title: "P", author: "A",
                created: Date(), modified: Date(), structure: [], research: [])
            m.coachVacated = vacated
            m.firstReaderName = name
            return m
        }

        XCTAssertEqual(
            DiagnosticsPane.readerMenuItems(manifest: manifest(vacated: false, name: "Ursula")),
            [.coach, .firstReader, .nobody])
        XCTAssertEqual(
            DiagnosticsPane.readerMenuItems(manifest: manifest(vacated: true, name: "Ursula")),
            [.firstReader, .nobody])
        XCTAssertEqual(
            DiagnosticsPane.readerMenuItems(manifest: manifest(vacated: false, name: nil)),
            [.coach, .nobody])
        XCTAssertEqual(
            DiagnosticsPane.readerMenuItems(manifest: manifest(vacated: true, name: nil)),
            [.nobody],
            "nobody is the one choice with no premise to lose")

        // A name that is only whitespace is no name — a hand-edited
        // `project.json` is a writer of this field too.
        XCTAssertEqual(
            DiagnosticsPane.readerMenuItems(manifest: manifest(vacated: true, name: "   ")),
            [.nobody])
    }

    /// The items are named from the same places the resolution reads them, so
    /// the menu cannot name a reader the line above it does not.
    func test_readerMenuTitle_namesTheSameReadersTheResolutionDoes() {
        var manifest = ProjectManifest(
            type: .novel, title: "P", author: "A",
            created: Date(), modified: Date(), structure: [], research: [])
        manifest.firstReaderName = "  Ursula  "

        XCTAssertEqual(
            DiagnosticsPane.readerMenuTitle(.coach, manifest: manifest), "Le Guin")
        XCTAssertEqual(
            DiagnosticsPane.readerMenuTitle(.firstReader, manifest: manifest), "Ursula")
        XCTAssertEqual(
            DiagnosticsPane.readerMenuTitle(.nobody, manifest: manifest), "Claude")
    }

    /// The checkmark follows whoever RESOLVED, not the stored choice: a choice
    /// whose subject has gone falls back to the default rule, and a mark beside
    /// a reader who is not reading would contradict the line above it.
    func test_resolvedChoice_marksTheArmTheReaderActuallyIs() {
        XCTAssertEqual(
            DiagnosticsPane.resolvedChoice(for: .coach(ReviewPass.coachPreset)), .coach)
        XCTAssertEqual(
            DiagnosticsPane.resolvedChoice(
                for: .firstReader(FirstReader(name: "Ursula", statement: nil))),
            .firstReader)
        XCTAssertEqual(DiagnosticsPane.resolvedChoice(for: .nobody), .nobody)
    }

    /// **The mounted header draws a picker, labelled with the reader's own
    /// line.** Asserted as what is DRAWN — the label plus a control role that
    /// is not a plain static text — and never by opening the menu and waiting
    /// for what falls out of it (tripwire 33).
    func test_mountedHeader_theReaderLineIsAPickerWhenThereIsAProject() async throws {
        let (_, store, _) = try await loadedNovel(named: "ReaderPickerDrawn")
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))

        let window = mount(pane(
            store: store, diagnostics: diagnostics, docId: "doc-picker",
            reader: .coach(ReviewPass.coachPreset)))
        pump(0.2)

        XCTAssertTrue(allLabels(in: window).contains("Le Guin reads this piece"),
                      "the label is the line it replaces; got \(allLabels(in: window))")
        XCTAssertTrue(
            roles(labelled: "Le Guin reads this piece", in: window)
                .contains { $0 != "AXStaticText" },
            "the reader line must be a control the writer can open, not a "
            + "label; roles: \(roles(labelled: "Le Guin reads this piece", in: window))")
    }

    /// **A pane with no project draws the plain label it always did.** There
    /// is nothing to choose between with no manifest to read the seat or the
    /// name off, and a menu over one item that changes nothing is a control
    /// that lies about what it can do.
    func test_mountedHeader_withNoProjectTheLineIsStillAPlainLabel() throws {
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics,
            docId: "doc-no-project", currentText: { _ in nil }, compilerModel: .standard,
            reader: .coach(ReviewPass.coachPreset))))
        pump(0.2)

        XCTAssertEqual(
            roles(labelled: "Le Guin reads this piece", in: window)
                .filter { $0 != "AXStaticText" },
            [],
            "with no store there is nothing to pick between")
    }

    /// **Source census: every item writes the choice, one item opens Project
    /// Settings, and nothing in the menu travels to Review.**
    ///
    /// Windowless on purpose (tripwire 33): a SwiftUI `Menu` publishes no items
    /// until it is opened, so pressing one is a press-then-wait by
    /// construction. What could silently break is the WIRING — an item that
    /// wrote nothing, or a "Define a first reader…" that opened the wrong
    /// thing — and the four pure functions above pin everything else.
    func test_theReaderMenusItemsWriteTheChoiceAndOpenNothingButSettings() throws {
        let source = try Self.source(of: "Views/DiagnosticsPane.swift")
        let menu = try XCTUnwrap(
            Self.declaration(named: "private var readerMenu: some View {", in: source),
            "the header must carry a readable reader menu for this census to "
            + "have a subject")

        XCTAssertTrue(menu.contains("onChooseReader(candidate)"),
                      "each reader item writes the choice. Got:\n\(menu)")
        XCTAssertTrue(menu.contains("DiagnosticsPane.defineFirstReaderTitle")
                      || menu.contains("Self.defineFirstReaderTitle"),
                      "the define item draws the shared title. Got:\n\(menu)")
        XCTAssertTrue(menu.contains("onOpenProjectSettings()"),
                      "\u{2026}and it opens Project Settings, which is where "
                      + "her name is typed. Got:\n\(menu)")
        XCTAssertFalse(menu.localizedCaseInsensitiveContains("persona"),
                       "the picker never changes the window's mode \u{2014} P1 "
                       + "removed the door to Review. Got:\n\(menu)")
        XCTAssertFalse(menu.contains("postDetailSegment("),
                       "\u{2026}and it opens no other pane either. Got:\n\(menu)")

        // The define item stands only while she is unnamed: once she has a
        // name her own row is in the list above, and a second door to Settings
        // beneath it would be an offer to define somebody already defined.
        XCTAssertTrue(menu.contains("if !Self.hasFirstReader(manifest) {"),
                      "Got:\n\(menu)")
    }

    /// **The header is given the CHOSEN reader and both verbs.** The pane
    /// defaults `reader` to `.nobody` and both closures to no-ops, so a
    /// host that forgot to wire them would draw a picker that changes nothing
    /// and a header naming a reader the run was not briefed on — neither of
    /// which any assertion on values can see.
    func test_theWindowGivesTheHeaderTheChosenReaderAndItsTwoVerbs() throws {
        let toggle = try Self.source(of: "Views/DetailPaneToggle.swift")
        let arm = try XCTUnwrap(
            Self.declaration(named: "private var diagnosticsPane: some View {", in: toggle))

        XCTAssertTrue(arm.contains("choice: ds.uiState.authorReaderChoice"),
                      "the header reads the writer's CHOICE, not the default "
                      + "rule \u{2014} the same resolution the run makes. "
                      + "Got:\n\(arm)")
        XCTAssertTrue(arm.contains("ds?.setAuthorReaderChoice("),
                      "\u{2026}and the picker writes it through the one verb. "
                      + "Got:\n\(arm)")
        XCTAssertTrue(arm.contains("onOpenProjectSettings: onOpenProjectSettings"),
                      "\u{2026}and the define item reaches the window's sheet. "
                      + "Got:\n\(arm)")

        let window = try Self.source(of: "Views/ProjectWindow.swift")
        XCTAssertTrue(
            window.contains("onOpenProjectSettings: openProjectSettings"),
            "the window opens the sheet the define item asks for")
        // …through the one door, which is also what clears a Describe… request
        // the writer escaped out from under.
        let open = try XCTUnwrap(
            Self.declaration(named: "private func openProjectSettings() {", in: window))
        XCTAssertTrue(open.contains("describeFirstReaderRequested = false"),
                      "opening the sheet clears any stale hand-off. Got:\n\(open)")
        XCTAssertEqual(
            window.components(separatedBy: "activeSheet = .projectSettings").count - 1, 1,
            "Project Settings is opened from exactly one place")
    }

    /// **The reader line is never a door to Review** (two loops P1 Task 7).
    ///
    /// It used to be a button that switched the window to Review — the mode
    /// error P1 removed. Who reads a CHECK is not chosen on the review board,
    /// so travelling there answered a question the writer had not asked. P2
    /// gave the line a picker over the READERS instead; this pane has no store,
    /// so it still draws the plain label, and the `AXButton` that used to
    /// travel is absent either way — which is exactly what a reader with
    /// VoiceOver hears the difference as.
    func test_theReaderLineIsALabelAndNotADoorToReview() throws {
        let docId = "doc-reader-label"
        let diagnosticsStore = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnosticsStore, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard,
            reader: .coach(ReviewPass.coachPreset))))
        pump(0.2)

        XCTAssertTrue(allLabels(in: window).contains("Le Guin reads this piece"),
                      "control: the line is drawn; got \(allLabels(in: window))")
        XCTAssertNil(findButton(labelled: "Le Guin reads this piece", in: window),
                     "the reader line must be a label \u{2014} a button here travels to "
                     + "Review, which is the round loop's furniture")
    }

    // MARK: - Reread (two loops P1 Task 7)

    /// **Reread asks for a cold CHECK of this document, and nothing else.**
    ///
    /// The call is what is asserted, never its effect: `reading` and
    /// `onRunAcknowledged` are closures the harness appends to, and both are
    /// reached synchronously inside `runRequested` — before the hop that would
    /// spawn anything — so there is no window between the press and the
    /// assertion for a poll to have to wait out (tripwire 33).
    ///
    /// Three appends, three claims. `readings` says the press named THIS
    /// document. `acknowledgments` says `freshEyes: true`, because the
    /// orchestrator answers a cold press with its own case. And
    /// `roundEditorAsks` being empty says the press was a `.check`: a `.round`
    /// asks `roundEditor` for a lane synchronously, one line above the
    /// acknowledgment, and is refused when there is none — so a Reread that had
    /// been wired to the round loop would leave this document's id in that
    /// array and no acknowledgment at all.
    func test_theRereadButtonAsksForAColdCheckOfThisDocument() throws {
        let docId = "doc-reread-call"
        let runner = SpyRunner()
        let recorder = RunRequests()
        let orchestrator = CompilerOrchestrator()
        var environment = makeEnvironment(docId: docId, runner: runner)
        let readingOfRecord = environment.reading
        environment.reading = { id in
            recorder.readings.append(id)
            return readingOfRecord(id)
        }
        environment.roundEditor = { id in
            recorder.roundEditorAsks.append(id)
            return nil
        }
        environment.onRunAcknowledged = { recorder.acknowledgments.append($0) }
        orchestrator.configure(
            environment: environment,
            diagnostics: DiagnosticsStore(
                projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac")))

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: orchestrator,
            diagnostics: DiagnosticsStore(
                projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac")),
            docId: docId, currentText: { _ in nil }, compilerModel: .standard)))
        let reread = try button(labelled: DiagnosticsPane.rereadTitle, in: window)

        _ = reread.perform(NSSelectorFromString("accessibilityPerformPress"))

        XCTAssertEqual(recorder.readings, [docId],
                       "Reread must ask about the document this pane is about")
        XCTAssertEqual(recorder.acknowledgments, [.freshEyes],
                       "a cold press is answered with its own case \u{2014} an ordinary "
                       + ".started here means freshEyes never reached the orchestrator")
        XCTAssertTrue(recorder.roundEditorAsks.isEmpty,
                      "Author's Reread is a check; a round would have asked for a "
                      + "lane here and been refused \u{2014} got \(recorder.roundEditorAsks)")

        runner.release(.failed(.timedOut))
    }

    /// Every append the Reread press makes, in order. A reference box because
    /// `Environment`'s closures are stored rather than captured-by-inout.
    @MainActor
    private final class RunRequests {
        var readings: [String] = []
        var roundEditorAsks: [String] = []
        var acknowledgments: [CompilerOrchestrator.Acknowledgment] = []
    }

    /// **Reread refuses while a run is in flight, and in no other state.**
    ///
    /// The run is driven directly rather than by pressing anything, so nothing
    /// here presses a control and then waits for its effect (tripwire 33): by
    /// the time the pane is mounted the orchestrator is already running, and
    /// the button's state is read off the tree it was built with.
    func test_theRereadButtonIsDrawnAndRefusesOnlyWhileARunIsInFlight() async throws {
        let docId = "doc-reread-busy"
        let runner = SpyRunner()
        // Nothing to answer with: the send suspends, so the run stays in flight
        // for as long as this test needs it to.
        runner.nextEvent = nil
        let orchestrator = CompilerOrchestrator()
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))

        let idle = mount(AnyView(DiagnosticsPane(
            orchestrator: orchestrator, diagnostics: diagnostics, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        let idleButton = try button(labelled: DiagnosticsPane.rereadTitle, in: idle)
        XCTAssertEqual(axEnabled(idleButton), true,
                       "an idle pane offers the cold read")

        orchestrator.configure(
            environment: makeEnvironment(docId: docId, runner: runner),
            diagnostics: diagnostics)
        orchestrator.runRequested(docId: docId, kind: .check)
        await awaitSends(1, on: runner)

        let busy = mount(AnyView(DiagnosticsPane(
            orchestrator: orchestrator, diagnostics: diagnostics, docId: docId,
            currentText: { _ in nil }, compilerModel: .standard)))
        let busyButton = try button(labelled: DiagnosticsPane.rereadTitle, in: busy)
        XCTAssertEqual(axEnabled(busyButton), false,
                       "a second read while one is under way starts nothing \u{2014} "
                       + "the button must say so rather than swallow the press")

        runner.release(.failed(.timedOut))
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
    /// register refuses elsewhere on this pane (the pane's now-deleted reader
    /// section once kept the same discipline with its own "The reader had
    /// more to say." line, M4 P1 Task 3 — no count).
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

    /// A bare `Annotation` value for the pure ordering tests below —
    /// `inManuscriptOrder` only reads `paragraphId` (for rank) and identity
    /// (for the stable-tie assertion), so every other field is an arbitrary
    /// but valid fixture value.
    private func makeAnnotation(
        id: String, paragraphId: String?, body: String
    ) -> Annotation {
        Annotation(
            id: id, kind: .query, paragraphId: paragraphId,
            body: body, suggestedText: nil, priorText: nil,
            createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false)
    }

    // MARK: - Author narrates no rounds (two loops P1 Tasks 5 and 7)
    //
    // The sentences themselves belong to `RoundNarrative` and are pinned in
    // `RoundNarrativeTests`; what is asserted here is that this pane says none
    // of them.

    /// **Author's report is the CHECK's, and it narrates no rounds** (two
    /// loops P1 Task 5).
    ///
    /// This replaces four mounted tests that put a round in the sidecar and
    /// read Author's pane for its since-last-round line
    /// (`test_theSinceLastRoundLine…LeadsTheReport` / `…CountsTheQueueOfThe`
    /// `OpenDocument` / `…FollowsAStetWithoutAnotherCheck` /
    /// `…RendersAboveTheEmptyStateToo`, M4 P1 Task 5). They could only pass
    /// while one standing run served both verbs: a check carries no lane and
    /// no round number (Task 2), so `RoundNarrative.sinceLastRoundLine`
    /// refuses it, and the sentence now belongs to the round cockpit, which
    /// derives it from the round slot (`AnnotationsPane.cockpitReportLine`).
    /// The arithmetic those four asserted is `SinceLastRound`'s own and is
    /// pinned windowlessly in `RoundHistoryTests`; what they also asserted —
    /// where the sentence sits in THIS pane — is what this task ends.
    func test_theReportIsTheChecksAndAuthorNarratesNoRounds() throws {
        let docId = "doc-two-slots"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let quote = "Cold, and never wistful."

        // Two rounds, so the ring holds one and a since-line would have every
        // input it needs.
        store.replace(run: makeRun(passId: "line", round: 1), diagnostics: [], docId: docId)
        let roundStrain = makeDiagnostic(
            docId: docId, anchor: .init(paragraphId: "a1b2", anchorText: "The fog came."),
            body: "The round found a sigh here.", kind: .conformanceStrain,
            clauseQuote: quote)
        store.replace(run: makeRun(clauseStatuses: [makeClause(quote, "strains")],
                                   passId: "line", round: 2),
                      diagnostics: [roundStrain], docId: docId)

        // And the writer's own last check, which is what this pane reports on.
        let checkStrain = makeDiagnostic(
            docId: docId, anchor: .init(paragraphId: "a1b2", anchorText: "The fog came."),
            body: "The last line reaches for a sigh.", kind: .conformanceStrain,
            clauseQuote: quote)
        store.replace(run: makeRun(clauseStatuses: [makeClause(quote, "strains")],
                                   kind: .check),
                      diagnostics: [checkStrain], docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in "The fog came." }, compilerModel: .standard)))
        pump(0.3)

        let labels = allLabels(in: window)
        XCTAssertTrue(labels.contains("The last line reaches for a sigh."),
                      "the check's own strain is the report; got \(labels)")
        XCTAssertFalse(labels.contains("The round found a sigh here."),
                       "a round's strains are stored in their own slot and drawn "
                       + "nowhere in P1; got \(labels)")
        XCTAssertTrue(labels.allSatisfy { !$0.hasPrefix("Since round") },
                      "the round's sentence belongs to the cockpit, not to Author's "
                      + "report; got \(labels)")
    }

    /// **Neither round sentence reaches this pane, and the sharpest case is
    /// the one Reread makes** (two loops P1 Task 7).
    ///
    /// A standing round in the ring is what a since-line would be measured
    /// against; a standing CHECK read cold — which is exactly what the new
    /// Reread button files — is what the fresh-eyes header used to name. Both
    /// inputs are present here and neither sentence is drawn, because both
    /// lines left this pane with the round loop they belong to.
    ///
    /// The fresh-eyes half is not hypothetical: before this task a Reread put
    /// "Fresh eyes" at the top of Author's report, borrowing the round
    /// cockpit's vocabulary for a check that has no round to be fresh about.
    func test_neitherRoundSentenceIsDrawnOverAColdCheck() throws {
        let docId = "doc-no-round-lines"
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let quote = "Cold, and never wistful."

        // Two rounds in the lane, so the ring holds a predecessor and a
        // since-line would have every input it needs.
        store.replace(run: makeRun(passId: "line", round: 1), diagnostics: [], docId: docId)
        store.replace(run: makeRun(passId: "line", round: 2), diagnostics: [], docId: docId)

        // …and the writer's own last check, read cold. This is what the pane
        // reports on, and it is a `freshEyes` run.
        let strain = makeDiagnostic(
            docId: docId, anchor: .init(paragraphId: "a1b2", anchorText: "The fog came."),
            body: "The last line reaches for a sigh.", kind: .conformanceStrain,
            clauseQuote: quote)
        store.replace(run: makeRun(clauseStatuses: [makeClause(quote, "strains")],
                                   freshEyes: true, kind: .check),
                      diagnostics: [strain], docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: store, docId: docId,
            currentText: { _ in "The fog came." }, compilerModel: .standard)))
        pump(0.3)

        let labels = allLabels(in: window)
        XCTAssertTrue(labels.contains("The last line reaches for a sigh."),
                      "control: the cold check's own report is drawn; got \(labels)")
        XCTAssertTrue(labels.allSatisfy { !$0.hasPrefix("Since round") },
                      "no since-line, whatever the ring holds; got \(labels)")
        XCTAssertTrue(labels.allSatisfy { !$0.contains("Fresh eyes") },
                      "a check has no round to be fresh about \u{2014} the header the "
                      + "cold read used to draw belongs to the cockpit; got \(labels)")
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

    /// **The seal may not stand over a round whose findings were already open
    /// in another pass** (#42, whole-branch review I1). The mint refused
    /// everything this round raised, because the writer is holding it in a
    /// lane they cannot see from here: nothing reached this pane and nothing
    /// reached the queue in front of them, so "the compiler found nothing to
    /// raise against the last check" is the opposite of what happened.
    ///
    /// This is also precisely where the since-line cannot help \u{2014} a
    /// cross-lane-only round is most often round 1 of a lane, where that line
    /// is silent because there is nothing behind it to be "since".
    func test_theCleanCopyDefersToWhatWasAlreadyOpenInAnotherLane() {
        let elsewhere = makeRun(openInOtherLanes: 1)
        let header = DiagnosticsPane.headerCopy(for: .clean(lastRun: elsewhere))
        XCTAssertTrue(header.hasPrefix("Nothing new to flag."), header)

        let empty = DiagnosticsPane.emptyState(for: .clean(lastRun: elsewhere))
        XCTAssertEqual(empty.title, "Nothing new to flag.")
        XCTAssertTrue(
            empty.description.contains(
                "was already open in another pass's queue"),
            empty.description)
        XCTAssertFalse(empty.description.contains("found nothing to raise"),
                       "the seal's own sentence stood under the new title: "
                       + empty.description)

        // Plural, from the one helper both wordings live in.
        let many = DiagnosticsPane.emptyState(for: .clean(lastRun: makeRun(openInOtherLanes: 2)))
        XCTAssertTrue(
            many.description.contains("was already open in other passes' queues"),
            many.description)
    }

    /// The control, and the falsifier for an arm that fired on the field's
    /// mere presence: zero and nil are both "nothing stood elsewhere", and
    /// over either the seal is the honest sentence and must be untouched.
    func test_theSealStandsOverARoundThatCrossedNoLane() {
        for quiet in [makeRun(openInOtherLanes: 0), makeRun()] {
            XCTAssertTrue(
                DiagnosticsPane.headerCopy(for: .clean(lastRun: quiet))
                    .hasPrefix("Nothing to flag."),
                DiagnosticsPane.headerCopy(for: .clean(lastRun: quiet)))
            let empty = DiagnosticsPane.emptyState(for: .clean(lastRun: quiet))
            XCTAssertEqual(empty.title, "Nothing to flag.")
            XCTAssertEqual(empty.symbol, "checkmark.seal")
            XCTAssertEqual(
                empty.description,
                "The compiler found nothing to raise against the last check.")
        }
    }

    /// **Notes that really landed outrank a lane-crossing**, the same ordering
    /// the discard footnote already loses to: a run can queue notes AND refuse
    /// a finding standing elsewhere, and where the writer has to go next is
    /// the news.
    func test_theQueuedSentenceOutranksTheCrossLaneClause() {
        let both = makeRun(mintedNotes: 2, openInOtherLanes: 1)
        XCTAssertTrue(
            DiagnosticsPane.headerCopy(for: .clean(lastRun: both))
                .hasPrefix("2 notes went to your queue."),
            DiagnosticsPane.headerCopy(for: .clean(lastRun: both)))
        XCTAssertEqual(
            DiagnosticsPane.emptyState(for: .clean(lastRun: both)).title,
            "Notes in your queue")
    }

    /// **Wet ink outranks it as well**, on the arm's own rule: under
    /// `.showing` / `.settled` this run's notes are on screen beneath the
    /// header, and that arm exists precisely so the copy does not send the
    /// writer somewhere else for what is right there.
    func test_theCrossLaneClauseYieldsToWetInk() {
        let elsewhere = makeRun(openInOtherLanes: 1)
        for ink in [DiagnosticsPane.WetInk.showing, .settled] {
            XCTAssertTrue(
                DiagnosticsPane.headerCopy(for: .clean(lastRun: elsewhere), wetInk: ink)
                    .hasPrefix("Nothing to flag."),
                DiagnosticsPane.headerCopy(for: .clean(lastRun: elsewhere), wetInk: ink))
        }
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

    /// **Which notes offer to be answered.** A conformance strain asks the
    /// writer something, and the answer is a decision — a ruling. A
    /// continuity question and a reader report are never handed to this
    /// function through the pane's own rendering (`strains` filters to
    /// `.conformanceStrain` before either ever calls `offersAnAnswer`), and
    /// both now mint as annotations instead of a `Diagnostic` row — so
    /// neither offers an answer here either (M4 P1 Task 3 narrowed the rule
    /// off the arm that never fires).
    func test_onlyConformanceStrainsOfferAnAnswer() {
        XCTAssertTrue(DiagnosticsPane.offersAnAnswer(
            makeDiagnostic(docId: "d1", kind: .conformanceStrain)))
        XCTAssertFalse(DiagnosticsPane.offersAnAnswer(
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

    // MARK: - Rulings carry the note they answered (M4 P1 Task 6)

    /// A short clause quote rides through verbatim, inside the guillemets and
    /// with no ellipsis — nothing to truncate.
    func test_answeredNoteProvenance_shortQuoteRidesVerbatim() {
        let note = makeDiagnostic(
            docId: "d1", kind: .conformanceStrain,
            clauseQuote: "the dread stays unnamed")
        XCTAssertEqual(
            DiagnosticsPane.answeredNoteProvenance(for: note),
            "answered a compiler note: \u{00AB}the dread stays unnamed\u{00BB}")
    }

    /// A clause quote past the 60-character budget is cut at a word boundary
    /// and ellipsised — `truncatedDriftQuote`'s own idiom, restated for the
    /// same reason the drift line already restates it.
    func test_answeredNoteProvenance_longQuoteTruncatedWithEllipsis() {
        let quote = "The fog came in off the water and stayed for three days "
            + "without once naming what it was hiding."
        let note = makeDiagnostic(docId: "d1", kind: .conformanceStrain, clauseQuote: quote)

        let provenance = DiagnosticsPane.answeredNoteProvenance(for: note)

        XCTAssertTrue(provenance.contains("\u{2026}"),
                      "over budget, so the excerpt must be marked as cut")
        XCTAssertEqual(
            provenance,
            "answered a compiler note: \u{00AB}"
                + DiagnosticsPane.truncatedDriftQuote(quote) + "\u{00BB}",
            "the same 60-character, word-boundary budget the drift line uses")
    }

    /// **A clause quote carrying its own em-dash must not be allowed to reach
    /// the ruling line intact.** `RulingsSection.parseItem` splits an item on
    /// its RIGHT-MOST "—"; an excerpt with one of its own would move that
    /// split point into the quote and mangle the writer's ruled sentence on
    /// the next parse.
    func test_answeredNoteProvenance_embeddedEmDashIsCollapsed() {
        let note = makeDiagnostic(
            docId: "d1", kind: .conformanceStrain,
            clauseQuote: "the dread \u{2014} unnamed \u{2014} stays")

        let provenance = DiagnosticsPane.answeredNoteProvenance(for: note)

        XCTAssertFalse(provenance.contains("\u{2014}"),
                       "got: \(provenance) \u{2014} an em-dash here would move "
                       + "parseItem's right-most split into the excerpt")
        XCTAssertEqual(
            provenance,
            "answered a compiler note: \u{00AB}the dread - unnamed - stays\u{00BB}")
    }

    /// A note with no `clauseQuote` — a v1 sidecar record, or a future
    /// answerable kind that never grows one — falls back to the bare legacy
    /// line rather than printing an empty pair of guillemets.
    func test_answeredNoteProvenance_nilClauseQuoteFallsBackToTheBareLegacyString() {
        let note = makeDiagnostic(docId: "d1", kind: .continuity, clauseQuote: nil)
        XCTAssertEqual(
            DiagnosticsPane.answeredNoteProvenance(for: note), "answered a compiler note")
    }

    /// **The round trip, end to end.** A strain carrying a clause quote is
    /// answered through the real `commitAnswer`, and the ruling it wrote is
    /// re-parsed off the real statement: the excerpt is in the provenance, and
    /// — the assertion that matters — the ruling's TEXT is exactly the
    /// writer's sentence, with no fragment of the enriched provenance bled
    /// into it. That is only true if `RulingsSection.parseItem` still found
    /// the right em-dash to split on.
    func test_answeringAStrainEnrichesTheRulingsProvenanceAndTheParserSurvives() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AnswerEnrichesProvenance")
        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement(
            "Cold, and never wistful.", to: statement, session: "seed")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let note = makeDiagnostic(
            docId: chapter.id, kind: .conformanceStrain,
            clauseQuote: "the dread stays unnamed")
        diagnostics.replace(run: makeRun(), diagnostics: [note], docId: chapter.id)

        let answer = "The reader is supposed to feel this as it happening, not "
            + "as something the prose already knows."
        let failure = await DiagnosticsPane.commitAnswer(
            answer, to: note, docId: chapter.id, store: store, world: nil,
            diagnostics: diagnostics)
        XCTAssertNil(failure, "the commit reported: \(failure ?? "")")

        let parsed = RulingsSection.parse(try await derivedText(of: statement, in: url))
        XCTAssertEqual(parsed.rulings.count, 1)
        let ruling = try XCTUnwrap(parsed.rulings.first)
        XCTAssertEqual(ruling.text, answer,
                       "the ruling's TEXT is exactly the writer's sentence — the "
                       + "parser found the real em-dash and not one inside the excerpt")
        XCTAssertEqual(
            ruling.provenance, DiagnosticsPane.answeredNoteProvenance(for: note),
            "…and the provenance carries the excerpt")
        XCTAssertTrue(
            ruling.provenance?.contains("the dread stays unnamed") == true,
            "got: \(ruling.provenance ?? "nil")")
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

        orchestrator.runRequested(docId: chapter.id, kind: .check)
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

        orchestrator.runRequested(docId: otherDocId, kind: .check)
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

    // MARK: - "This check" — Author's wet-ink view (M4 P2 Task 1, spec §7.0)
    //
    // P1 homed the compiler's continuity questions and reader reports in the
    // writer's queue, and Denver's smoke found the consequence: Author — whose
    // persona IS the wet-ink tempo — was left with a count ("3 notes went to
    // your queue") and no surface. §7.0's correction is a live VIEW of the
    // latest run's minted notes, in the pane's own register, with one-gesture
    // dispositions. Never the queue: a list you manage is the other tempo.

    /// Mint one note the way `mintAnnotations` does — stamped with the run
    /// that authored it, so the view can find it by that run's id and by
    /// nothing else.
    @discardableResult
    private func mintNote(
        on document: Document, run: CompilerRun, body: String,
        paragraphId: String?, kind: AnnotationKind = .query, round: Int? = nil
    ) async throws -> String {
        try await document.addAnnotation(
            kind: kind, paragraphId: paragraphId, body: body,
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Gould"),
            compilerRunId: run.id, compilerRound: round,
            compilerFingerprint: "continuity\u{1f}\(body)\u{1f}\(paragraphId ?? "")\u{1f}")
    }

    /// Press a real button through the accessibility tree and poll until the
    /// verb it starts has landed — both dispositions hop to a `Task`, so a
    /// synchronous read would see the pane before the op log has moved.
    ///
    /// **Polls rather than sleeps** (review, Important 3): a fixed sleep is a
    /// bet on how long an op-log append takes, and this suite's tests run in
    /// parallel worker processes against a machine that may be hosting several
    /// other gates.
    ///
    /// **Genuinely `async`, unlike `waitUntil`** — this file's synchronous
    /// idiom pumps only the main run loop, which is the right tool for
    /// catching up to a render that follows an already-applied, synchronous
    /// state change. What this waits on is different in kind: a real
    /// asynchronous disposition (`Document.acceptAnnotation`/
    /// `rejectAnnotation`) that hops off the main actor to append to the op
    /// log. A tight synchronous pump loop measurably starved that hop — the
    /// first version of this fix reused `waitUntil` and every disposition
    /// test timed out at its full budget with the row never moving. Yielding
    /// with a real `await Task.sleep` between polls, as the fixed-sleep
    /// version this replaced did by construction, is what actually lets the
    /// op log's write land.
    private func press(
        _ label: String, in window: NSWindow, timeout: TimeInterval = 5,
        until settled: () -> Bool
    ) async throws {
        let target = try button(labelled: label, in: window)
        _ = target.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await waitUntilAsync(timeout: timeout) { settled() }
    }

    /// `waitUntil`'s async sibling: polls `condition`, yielding with a real
    /// `await Task.sleep` between attempts rather than only pumping the main
    /// run loop, so a condition gated on genuine off-main-actor async work
    /// (an op-log append, not merely a render) gets real chances to progress.
    private func waitUntilAsync(
        timeout: TimeInterval = 3, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            pump(0.05)
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The note's status now, or `nil` if it is not in the projection at all —
    /// non-throwing, because it is also the polling predicate `press` waits on.
    private func statusIfPresent(
        of annotationId: String, in document: Document
    ) -> AnnotationStatus? {
        document.annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == annotationId }?.status
    }

    private func status(
        of annotationId: String, in document: Document
    ) throws -> AnnotationStatus {
        try XCTUnwrap(
            statusIfPresent(of: annotationId, in: document),
            "the note left the document's annotation layer entirely")
    }

    /// A pane over a live document, its store already carrying `run`.
    private func wetInkPane(
        document: Document, store: DiagnosticsStore, docId: String? = nil,
        orchestrator: CompilerOrchestrator? = nil
    ) -> AnyView {
        AnyView(DiagnosticsPane(
            orchestrator: orchestrator ?? CompilerOrchestrator(), diagnostics: store,
            docId: docId ?? document.docId,
            // The pane's own staleness closure is where the jump chip's words
            // come from: an annotation carries no excerpt of its own.
            currentText: { [weak document] pid in document?.paragraphs[pid] },
            compilerModel: .standard, activeDocument: { document }))
    }

    /// **The state Denver smoked.** A round in a pass over a piece with no
    /// declared intent raises no clause and no strain, so the pane draws its
    /// empty state — and every finding that round made is a queued note. Before
    /// §7.0 the writer's whole feedback was the sentence "2 notes went to your
    /// queue"; the notes themselves are now on the pane, above it.
    func test_thisCheckDrawsTheLatestRunsNotesAboveTheEmptyState() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let run = makeRun(mintedNotes: 2)
        store.replace(run: run, diagnostics: [], docId: document.docId)
        try await mintNote(on: document, run: run,
                           body: "Has anyone said how long the fog has been down?",
                           paragraphId: paragraphId)
        try await mintNote(on: document, run: run,
                           body: "The reader stopped believing the fog here.",
                           paragraphId: paragraphId, kind: .comment)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)

        let labels = allLabels(in: window)
        XCTAssertTrue(
            labels.contains("Has anyone said how long the fog has been down?"),
            "the question this check raised never reached Author; got \(labels)")
        XCTAssertTrue(
            labels.contains("The reader stopped believing the fog here."),
            "\u{2026}nor did the reader's report; got \(labels)")
        let sectionIndex = labels.firstIndex { $0 == "THIS CHECK" }
        // "Nothing else to flag.", not the pre-§7.0 "Notes in your queue": with
        // both notes showing right above it, the CUV must not re-announce them
        // as waiting somewhere else (the CUV copy invariant, review Important 2
        // / `WetInk.showing`).
        let emptyIndex = labels.firstIndex { $0 == "Nothing else to flag." }
        XCTAssertNotNil(sectionIndex, "the section names itself; got \(labels)")
        XCTAssertNotNil(emptyIndex,
                        "control: the empty state is what is drawn here; got \(labels)")
        XCTAssertTrue((sectionIndex ?? .max) < (emptyIndex ?? -1),
                      "the notes lead the sentence about where they live; got \(labels)")
        XCTAssertFalse(
            labels.contains { $0.contains("went to your queue") },
            "the header or the empty state re-announced as waiting the two "
            + "notes shown directly above; got \(labels)")
        // Requirement 3 holds on the new rows too: the jump travels as the
        // paragraph's own words.
        XCTAssertFalse(labels.contains { $0.contains(paragraphId) },
                       "the wet-ink row rendered a paragraph id; got \(labels)")
        XCTAssertTrue(
            labels.contains { $0.contains("First paragraph, with some words in it.") },
            "the jump chip must carry the paragraph's words; got \(labels)")
        // **No byline** (spec §7.0): the fixture signs both notes "Gould", the
        // way the mint signs a pass's round, and Author must not say so — the
        // named editors belong to Review's pass lanes, and wet-ink feedback is
        // not a pass.
        XCTAssertFalse(labels.contains { $0.contains("Gould") },
                       "Author drew the editor's name; got \(labels)")
    }

    /// The same section inside a real report — above the conformance summary,
    /// because it is what this check just raised and the summary is the
    /// standing account of the writer's clauses.
    func test_thisCheckLeadsTheConformanceSummaryWhenThereIsAReport() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let run = makeRun(clauseStatuses: [makeClause("Cold, and never wistful.", "holds")],
                          mintedNotes: 1)
        store.replace(run: run, diagnostics: [], docId: document.docId)
        try await mintNote(on: document, run: run,
                           body: "Has anyone said how long yet?", paragraphId: paragraphId)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)

        let labels = allLabels(in: window)
        let sectionIndex = labels.firstIndex { $0 == "THIS CHECK" }
        let conformanceIndex = labels.firstIndex { $0 == "CONFORMANCE" }
        XCTAssertNotNil(sectionIndex, "got \(labels)")
        XCTAssertNotNil(conformanceIndex, "control: the report is drawn; got \(labels)")
        XCTAssertTrue((sectionIndex ?? .max) < (conformanceIndex ?? -1),
                      "the wet ink leads the standing summary; got \(labels)")
    }

    /// **Got it settles the note.** One gesture, the annotation layer's own
    /// accept underneath — so Review's queue and the next round's briefing see
    /// exactly what the writer did, and the row leaves because the view is a
    /// filter over open notes rather than a list it has to prune.
    func test_gotItSettlesTheNoteAndTheRowLeaves() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let run = makeRun(mintedNotes: 1)
        store.replace(run: run, diagnostics: [], docId: document.docId)
        let noteId = try await mintNote(
            on: document, run: run, body: "Has anyone said how long yet?",
            paragraphId: paragraphId)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)
        XCTAssertTrue(allLabels(in: window).contains("Has anyone said how long yet?"),
                      "control: the row is on screen before the press")

        try await press("Got it", in: window) {
            self.statusIfPresent(of: noteId, in: document) != .open
        }

        XCTAssertEqual(try status(of: noteId, in: document), .accepted,
                       "Got it must reach the annotation's own accept, not a "
                       + "second record of the writer's answer")
        XCTAssertTrue(
            document.annotations(filter: AnnotationFilter(statuses: [.open]))
                .allSatisfy { $0.id != noteId },
            "\u{2026}and the queue in Review must see it settled")
        XCTAssertFalse(allLabels(in: window).contains("Has anyone said how long yet?"),
                       "the row stayed after the writer took the note; got "
                       + "\(allLabels(in: window))")
    }

    /// **Not this is one gesture and asks for nothing.** The reason-carrying
    /// decline belongs to Review's queue; wet ink gets a no.
    func test_notThisDeclinesInOneGestureWithNoReasonField() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let run = makeRun(mintedNotes: 1)
        store.replace(run: run, diagnostics: [], docId: document.docId)
        let noteId = try await mintNote(
            on: document, run: run, body: "Has anyone said how long yet?",
            paragraphId: paragraphId)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)

        try await press("Not this", in: window) {
            self.statusIfPresent(of: noteId, in: document) != .open
        }

        XCTAssertEqual(try status(of: noteId, in: document), .rejected)
        XCTAssertTrue(revealedFields(in: window).isEmpty,
                      "Not this opened a field \u{2014} the reasons are Review's")
        XCTAssertFalse(allLabels(in: window).contains("Has anyone said how long yet?"),
                       "got \(allLabels(in: window))")
    }

    /// ⌘Z reaches the decline through the pane's own undo manager — the
    /// annotation layer's existing machinery, wired rather than reimplemented.
    func test_undoAfterNotThisReopensTheNote() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let run = makeRun(mintedNotes: 1)
        store.replace(run: run, diagnostics: [], docId: document.docId)
        let noteId = try await mintNote(
            on: document, run: run, body: "Has anyone said how long yet?",
            paragraphId: paragraphId)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)
        try await press("Not this", in: window) {
            self.statusIfPresent(of: noteId, in: document) != .open
        }
        XCTAssertEqual(try status(of: noteId, in: document), .rejected,
                       "control: the decline landed")

        let undoManager = try XCTUnwrap(
            window.undoManager,
            "the hosted pane has no undo manager, so nothing could have been "
            + "registered through it")
        XCTAssertTrue(undoManager.canUndo,
                      "the decline registered no undo action at all")
        undoManager.undo()
        // Polled, not slept, and genuinely async for the same reason `press`
        // is: the undo handler hops the reopen onto a task off the main
        // actor, and only a real `await` between polls reliably lets it land.
        try await waitUntilAsync {
            self.statusIfPresent(of: noteId, in: document) == .open
        }

        XCTAssertEqual(try status(of: noteId, in: document), .open,
                       "\u{2318}Z after Not this must reopen the note")
    }

    /// A run that minted nothing draws no section — not an empty one with a
    /// heading over it.
    func test_theSectionIsAbsentForARunThatMintedNothing() async throws {
        let document = try await makeMultiParagraphDocument()
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(run: makeRun(mintedNotes: 0), diagnostics: [], docId: document.docId)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)

        XCTAssertFalse(allLabels(in: window).contains("THIS CHECK"),
                       "got \(allLabels(in: window))")
    }

    /// **Only the latest check.** The next ⌘R replaces what this section
    /// draws, wholesale — a wet-ink view that accumulated earlier rounds
    /// would be the backlog Author must never show.
    func test_onlyTheLatestChecksNotesAreDrawn() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let first = makeRun(mintedNotes: 1)
        store.replace(run: first, diagnostics: [], docId: document.docId)
        try await mintNote(on: document, run: first,
                           body: "Round one asked about the coat.", paragraphId: paragraphId)
        let second = makeRun(mintedNotes: 1)
        store.replace(run: second, diagnostics: [], docId: document.docId)
        try await mintNote(on: document, run: second,
                           body: "Round two asked about the afternoon.",
                           paragraphId: paragraphId)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)

        let labels = allLabels(in: window)
        XCTAssertTrue(labels.contains("Round two asked about the afternoon."),
                      "got \(labels)")
        XCTAssertFalse(labels.contains("Round one asked about the coat."),
                       "a superseded check's notes are the writer's queue, not "
                       + "this view; got \(labels)")
    }

    /// The docId guard `queueAnnotations` already carries, read through this
    /// section: another document's notes are another document's, and a run id
    /// they happen to share must not put them here.
    func test_anotherDocumentsNotesNeverReachThisCheck() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let run = makeRun(mintedNotes: 1)
        // The pane is about a different document than the one it is handed.
        store.replace(run: run, diagnostics: [], docId: "doc-somewhere-else")
        try await mintNote(on: document, run: run,
                           body: "Has anyone said how long yet?", paragraphId: paragraphId)

        let window = mount(wetInkPane(
            document: document, store: store, docId: "doc-somewhere-else"))
        pump(0.3)

        let labels = allLabels(in: window)
        XCTAssertFalse(labels.contains("Has anyone said how long yet?"),
                       "got \(labels)")
        XCTAssertFalse(labels.contains("THIS CHECK"), "got \(labels)")
    }

    /// **The live pin** (the T5 observation-seam discipline): the note is
    /// disposed AFTER the pane is mounted and pumped, from somewhere else
    /// entirely — the writer stetting it in Review's column. The row must
    /// leave without another check, or this is a snapshot rather than a view.
    func test_aNoteSettledElsewhereLeavesTheViewWithoutAnotherCheck() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let run = makeRun(mintedNotes: 1)
        store.replace(run: run, diagnostics: [], docId: document.docId)
        let noteId = try await mintNote(
            on: document, run: run, body: "Has anyone said how long yet?",
            paragraphId: paragraphId)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)
        XCTAssertTrue(allLabels(in: window).contains("Has anyone said how long yet?"),
                      "control: the row is on screen; got \(allLabels(in: window))")

        try await document.stetAnnotation(id: noteId)
        pump(0.3)

        XCTAssertFalse(allLabels(in: window).contains("Has anyone said how long yet?"),
                       "the row survived a disposition made in the other column; "
                       + "got \(allLabels(in: window))")
    }

    // MARK: - The order, the room, and what the copy may claim (review fixes)

    /// **A check's notes read down the piece** (review ruling): manuscript
    /// order, never newest-first. The notes are minted in the model's own
    /// order, which is not the writer's.
    func test_theRowsFollowTheProseAndNotTheMintingOrder() {
        let sequence = ["a1b2", "c3d4", "e5f6"]
        let third = makeAnnotation(id: "n1", paragraphId: "e5f6", body: "third")
        let first = makeAnnotation(id: "n2", paragraphId: "a1b2", body: "first")
        let second = makeAnnotation(id: "n3", paragraphId: "c3d4", body: "second")

        let ordered = DiagnosticsPane.inManuscriptOrder(
            [third, first, second], sequence: sequence)

        XCTAssertEqual(ordered.map(\.body), ["first", "second", "third"])
    }

    /// A whole-piece note has no place in the prose, so it follows it — and
    /// so does a note whose paragraph has left the sequence. Ties inside one
    /// rank keep the order they were minted in, because two rows that swap
    /// places between renders of one check are the pane shuffling under a
    /// writer mid-read.
    func test_docScopedAndOrphanedNotesFollowTheProse_andTiesAreStable() {
        let sequence = ["a1b2", "c3d4"]
        let notes = [
            makeAnnotation(id: "n1", paragraphId: nil, body: "whole piece"),
            makeAnnotation(id: "n2", paragraphId: "c3d4", body: "second"),
            makeAnnotation(id: "n3", paragraphId: "zzzz", body: "orphan"),
            makeAnnotation(id: "n4", paragraphId: "a1b2", body: "first A"),
            makeAnnotation(id: "n5", paragraphId: "a1b2", body: "first B"),
        ]

        XCTAssertEqual(
            DiagnosticsPane.inManuscriptOrder(notes, sequence: sequence).map(\.body),
            ["first A", "first B", "second", "whole piece", "orphan"])
    }

    /// **A tie breaks on mint order even when the ARRAY arrives newest-first**
    /// — the real shape of a defect this fix round shipped and then found by
    /// smoke: `queueAnnotations` reads `Document.annotations(filter:)`, and
    /// `AnnotationDeriver.derive` sorts its result newest-first for the
    /// queue's own purposes. An earlier version of `inManuscriptOrder` broke
    /// ties on the incoming array's own position, which silently inherited
    /// that newest-first order for two same-paragraph notes — exactly the
    /// "queue-consistent newest-first" the manuscript-order ruling exists to
    /// not be. Passing `newer` before `older` here, as the real projection
    /// would, is the falsification: `id` — a ULID, monotonic within the
    /// process — is the only thing in this fixture that is actually mint
    /// order, and the older note must lead regardless of array position.
    func test_tiesBreakOnMintOrder_notOnTheIncomingArraysNewestFirstPosition() {
        let sequence = ["a1b2"]
        let older = makeAnnotation(id: "n1", paragraphId: "a1b2", body: "older")
        let newer = makeAnnotation(id: "n2", paragraphId: "a1b2", body: "newer")

        XCTAssertEqual(
            DiagnosticsPane.inManuscriptOrder([newer, older], sequence: sequence).map(\.body),
            ["older", "newer"],
            "the older note (minted first) must lead even though it arrived "
            + "second in a newest-first array")
    }

    /// The same order, mounted: the rows on screen follow the prose.
    func test_theMountedRowsAreInManuscriptOrder() async throws {
        let document = try await makeMultiParagraphDocument()
        let firstParagraph = try XCTUnwrap(document.sequence.first)
        let secondParagraph = try XCTUnwrap(document.sequence.last)
        XCTAssertNotEqual(firstParagraph, secondParagraph, "precondition: two paragraphs")
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let run = makeRun(mintedNotes: 2)
        store.replace(run: run, diagnostics: [], docId: document.docId)
        // Minted against the LAST paragraph first — the model's order, not the
        // writer's.
        try await mintNote(on: document, run: run, body: "About the second paragraph.",
                           paragraphId: secondParagraph)
        try await mintNote(on: document, run: run, body: "About the first paragraph.",
                           paragraphId: firstParagraph)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)

        let labels = allLabels(in: window)
        let firstIndex = labels.firstIndex { $0 == "About the first paragraph." }
        let secondIndex = labels.firstIndex { $0 == "About the second paragraph." }
        XCTAssertNotNil(firstIndex, "got \(labels)")
        XCTAssertNotNil(secondIndex, "got \(labels)")
        XCTAssertTrue((firstIndex ?? .max) < (secondIndex ?? -1),
                      "the rows must read down the piece, not back up it; got \(labels)")
    }

    /// **The no-report arm has to scroll** (review, Important 1).
    ///
    /// Nothing caps how many notes a round mints — the schema's cap of three
    /// is the READER section's alone, and continuity questions are unbounded
    /// through both the ingest and the mint. These rows carry the ONLY
    /// disposition affordance Author has, so a check that overflows the pane
    /// used to clip the verbs off the bottom of a `VStack` with no way to
    /// reach them.
    ///
    /// Asserted on the geometry rather than on a synthetic scroll: the content
    /// is taller than the clip view that holds it, which is the whole of what
    /// "reachable by scrolling" means, and it is false for the arm as it was.
    func test_aCheckThatOverflowsThePaneCanBeScrolledToItsLastVerb() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let run = makeRun(mintedNotes: 12)
        store.replace(run: run, diagnostics: [], docId: document.docId)
        for index in 1...12 {
            try await mintNote(
                on: document, run: run,
                body: "Continuity question number \(index) about this paragraph.",
                paragraphId: paragraphId)
        }

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.4)

        let scrollView = try XCTUnwrap(
            firstScrollView(in: try XCTUnwrap(window.contentView)),
            "the no-report arm draws no scroll view at all, so anything past "
            + "the pane's height is unreachable")
        XCTAssertGreaterThan(
            scrollView.documentView?.frame.height ?? 0,
            scrollView.contentView.bounds.height,
            "precondition: twelve notes must overflow this 700pt pane, or the "
            + "test proves nothing about reaching the last one")
        // …and the last note is really in the content, verbs and all.
        let labels = allLabels(in: window)
        XCTAssertTrue(
            labels.contains("Continuity question number 12 about this paragraph."),
            "the twelfth note never reached the tree; got \(labels)")
        XCTAssertGreaterThanOrEqual(
            labels.filter { $0 == "Got it" }.count, 12,
            "every row must carry its own verbs; got \(labels)")
    }

    /// **The near-empty case must fill the pane, not sit top-anchored with
    /// dead space below it** (fix round 2 review, Important).
    ///
    /// The `ScrollView` wrap that fixed the overflow case above reintroduced
    /// tripwire 15's defect one layer in: a `ScrollView` proposes an
    /// UNBOUNDED height to its content, so `.frame(maxHeight: .infinity)`
    /// inside one resolves to the content's own intrinsic height rather than
    /// the pane's — invisible to the source-grep tripwire test, since the
    /// `ContentUnavailableView`'s own chain is still byte-identical. Two
    /// geometry checks, both on `DiagnosticsPaneColumnHeightTests`' style of
    /// measuring the rendered tree rather than trusting the source:
    ///
    /// 1. The scrolled content's height must fill the pane's visible height
    ///    (not stop short at its own intrinsic size, which is what "dead
    ///    space below it" IS, geometrically).
    /// 2. The empty state's own title must sit near the pane's vertical
    ///    center — the `ContentUnavailableView` centers within whatever frame
    ///    it is given, so a title sitting near the TOP is what "top-anchored"
    ///    looks like measured.
    func test_aNearEmptyCheckFillsThePaneRatherThanSittingTopAnchored() async throws {
        let document = try await makeMultiParagraphDocument()
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        store.replace(run: makeRun(mintedNotes: 0), diagnostics: [], docId: document.docId)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)

        let contentView = try XCTUnwrap(window.contentView)
        let scrollView = try XCTUnwrap(
            firstScrollView(in: contentView),
            "the no-report arm draws no scroll view at all")
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let visibleHeight = scrollView.contentView.bounds.height
        XCTAssertEqual(
            documentHeight, visibleHeight, accuracy: 2,
            "a near-empty check's content must fill the pane's visible height "
            + "via the minHeight floor rather than sitting at its own short "
            + "intrinsic height with dead space below it (tripwire 15, one "
            + "layer in) — documentView \(documentHeight) vs visible "
            + "\(visibleHeight)")

        let title = try element(labelled: "Nothing to flag.", in: window)
        let titleFrame = try XCTUnwrap(
            axFrame(title),
            "the empty state's title carries no accessibility frame")
        let containerFrame = window.convertToScreen(contentView.frame)
        XCTAssertEqual(
            titleFrame.midY, containerFrame.midY, accuracy: 80,
            "the empty state must center in the pane rather than sit "
            + "top-anchored; title midY \(titleFrame.midY) vs container "
            + "midY \(containerFrame.midY)")
    }

    /// **The copy never announces as waiting what is visible here** (review,
    /// Important 2). The empty state used to read the run's historical
    /// `mintedNotes` and say "2 notes went to your queue" directly beneath the
    /// two notes themselves, with verbs on them.
    func test_theEmptyStateDropsTheQueuedSentenceWhileTheNotesAreOnScreen() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let run = makeRun(mintedNotes: 2)
        store.replace(run: run, diagnostics: [], docId: document.docId)
        try await mintNote(on: document, run: run, body: "The first question.",
                           paragraphId: paragraphId)
        try await mintNote(on: document, run: run, body: "The second question.",
                           paragraphId: paragraphId)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)

        let labels = allLabels(in: window)
        XCTAssertTrue(labels.contains("The first question."),
                      "control: the rows are what the copy must defer to; got \(labels)")
        XCTAssertFalse(
            labels.contains { $0.contains("notes went to your queue. No clause") },
            "the empty state told the writer to go to their queue for the two "
            + "notes directly above it; got \(labels)")
        XCTAssertTrue(labels.contains("Nothing else to flag."),
                      "…and it still says what the report itself found; got \(labels)")
    }

    /// Its other half: once the writer has settled every row, the copy
    /// acknowledges that rather than re-announcing the notes they just
    /// handled.
    func test_theEmptyStateAcknowledgesACheckTheWriterHasHandled() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let run = makeRun(mintedNotes: 2)
        store.replace(run: run, diagnostics: [], docId: document.docId)
        let first = try await mintNote(
            on: document, run: run, body: "The first question.", paragraphId: paragraphId)
        let second = try await mintNote(
            on: document, run: run, body: "The second question.", paragraphId: paragraphId)

        let window = mount(wetInkPane(document: document, store: store))
        pump(0.3)

        try await press("Got it", in: window) {
            self.statusIfPresent(of: first, in: document) != .open
        }
        try await press("Not this", in: window) {
            self.statusIfPresent(of: second, in: document) != .open
        }

        let labels = allLabels(in: window)
        XCTAssertFalse(labels.contains("THIS CHECK"),
                       "control: both rows are gone; got \(labels)")
        XCTAssertFalse(
            labels.contains { $0.contains("went to your queue") },
            "the pane re-announced as waiting the two notes it just watched "
            + "the writer settle; got \(labels)")
        XCTAssertTrue(
            labels.contains { $0.contains("You\u{2019}ve handled this check\u{2019}s notes.") },
            "…and it says so; got \(labels)")
    }

    /// The standing, pure — including the case that keeps the historical
    /// sentence honest: a pane with no document behind it cannot see the
    /// queue, so an empty view means "cannot tell", never "handled".
    func test_wetInkStanding_readsTheThreeCasesApart() {
        XCTAssertEqual(
            DiagnosticsPane.wetInkStanding(mintedNotes: 2, queueVisible: true, openNow: 2),
            .showing)
        XCTAssertEqual(
            DiagnosticsPane.wetInkStanding(mintedNotes: 2, queueVisible: true, openNow: 0),
            .settled)
        XCTAssertEqual(
            DiagnosticsPane.wetInkStanding(mintedNotes: 2, queueVisible: false, openNow: 0),
            .none,
            "with no queue to read, the run's own record is the only honest thing "
            + "to say")
        XCTAssertEqual(
            DiagnosticsPane.wetInkStanding(mintedNotes: 0, queueVisible: true, openNow: 0),
            .none)
        XCTAssertEqual(
            DiagnosticsPane.wetInkStanding(mintedNotes: nil, queueVisible: true, openNow: 0),
            .none,
            "a preview and a pre-P1 record both know nothing about a mint")
    }

    /// A refused disposition says so in the row it was pressed in, not only in
    /// the log (review, Minor 2). The sentence names what did not happen and
    /// carries the cause.
    func test_aRefusedDispositionSpeaksInTheRow() {
        struct Refusal: LocalizedError {
            var errorDescription: String? { "the op log is read-only" }
        }
        XCTAssertEqual(DiagnosticsPane.dispositionRefusal(Refusal()),
                       "That didn\u{2019}t settle: the op log is read-only")
        XCTAssertTrue(DiagnosticsPane.anchorLostRefusal.hasPrefix("That didn\u{2019}t settle:"),
                      "both refusals open the same way, so the row reads one voice")
    }

    /// **A preview's rows carry no verbs**, exactly as the report's rows carry
    /// no fates: a half-arrived run's notes are not the writer's to settle.
    /// The body still renders — reading is the preview's whole value.
    func test_aPreviewsWetInkRowsOfferNeitherVerb() async throws {
        let document = try await makeMultiParagraphDocument()
        let paragraphId = try XCTUnwrap(document.sequence.first)
        let runner = SpyRunner()
        runner.nextEvent = nil
        let orchestrator = CompilerOrchestrator()
        let store = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        orchestrator.configure(
            environment: makeEnvironment(docId: document.docId, runner: runner),
            diagnostics: store)
        // **No marker on the stored run**, so the next \u{2318}R has a delta to
        // read: `beginRun` refuses an empty one before the running state is
        // ever set, and a run refused is a run this test never observes.
        let run = makeRun(lastOpId: nil, mintedNotes: 1)
        store.replace(run: run, diagnostics: [], docId: document.docId)
        try await mintNote(on: document, run: run,
                           body: "Has anyone said how long yet?", paragraphId: paragraphId)

        let window = mount(wetInkPane(
            document: document, store: store, orchestrator: orchestrator))
        pump(0.3)
        XCTAssertNotNil(findButton(labelled: "Got it", in: window),
                        "control: a finished run's note is the writer's to settle")

        orchestrator.runRequested(docId: document.docId, kind: .check)
        await awaitSends(1, on: runner)
        pump(0.3)

        XCTAssertTrue(allLabels(in: window).contains("Has anyone said how long yet?"),
                      "the note must still be readable mid-run; got \(allLabels(in: window))")
        XCTAssertNil(findButton(labelled: "Got it", in: window),
                     "a streaming run's half-arrived state must not dispose")
        XCTAssertNil(findButton(labelled: "Not this", in: window))

        runner.release(.resultText(Self.turnCarryingTheQuestion))
        try? await Task.sleep(for: .milliseconds(200))
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
        /// Where the orchestrator asked its stream to go — the same seam
        /// `CompilerRunCommandTests.SpyRunner` records, so this suite can BE
        /// the CLI's stdout and put a real preview on a mounted pane.
        private var partialHandler: (@MainActor (String) -> Void)?

        func setPartialHandler(_ handler: (@MainActor (String) -> Void)?) {
            partialHandler = handler
        }

        func stream(_ chunk: String) { partialHandler?(chunk) }

        /// Every prompt the orchestrator sent, in order — the seam a test
        /// reads to see what a round was actually briefed with.
        private(set) var sentMessages: [String] = []

        func send(message: String, systemPreamble: String?) async -> CompilerRunEvent {
            sendCount += 1
            sentMessages.append(message)
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

    // MARK: - The letter (editorial letter P1 Task 9)

    /// A letter with a habit that carries an exercise, and a scene that does
    /// not turn — the fixture every letter test below narrows from.
    nonisolated private func makeLetter(
        habitRefs: [Diagnostic.Ref] = [],
        exercise: String? = "Read the dialogue aloud with the names removed.",
        scenePosition: String? = ScenePosition.strongDefault.rawValue,
        turn: String = ""
    ) -> Letter {
        Letter(
            about: "A ghost story told through weather.",
            oneThing: "Give the reader the dock before the fire.",
            working: [],
            habits: [Letter.Habit(
                name: "Every speech sounds like the same person",
                refs: habitRefs, cost: "The cast blurs.",
                lesson: nil, exercise: exercise)],
            questions: [],
            scenes: [Letter.Scene(
                refs: [], wants: "To be let in", changes: "The door opens",
                turn: turn, charge: nil)],
            scenePosition: scenePosition)
    }

    /// **Where the letter draws, in BOTH arms** — first, and before This
    /// check.
    ///
    /// It led the report after the round line until two loops P1 Task 7, which
    /// took the round line and the fresh-eyes header off this pane entirely: a
    /// check has no lane and no round number, so neither sentence had anything
    /// to say here. The letter simply moved up into the slot they left, and
    /// this census now also refuses their return.
    ///
    /// A census rather than a mount, because the placement claim is about the
    /// `content` builder's two branches and a mounted pane only ever renders
    /// one of them at a time. The `!hasReport` arm matters as much as the
    /// other: a round over a piece with no declared intent raises no clause
    /// and no strain, and since P1 its whole output can be one letter.
    ///
    /// **The arms are found by their own `if`/`else` anchors, never by a
    /// character budget** (fix round 1, Important). This test took
    /// `prefix(1600)` of the body and the body is ~1900 characters: the slice
    /// stopped inside the report arm before its `roundLine`, the
    /// `where arm.contains("roundLine")` filter then skipped that arm
    /// silently, and the test asserted ONE arm while its name promised two. A
    /// census whose subject can quietly become empty is a census that passes
    /// over the defect it exists for — so both arms are named, and each is
    /// required to be non-empty before anything is asserted about it.
    func test_theLetterLeadsBothArmsAndPrecedesThisCheck() throws {
        let source = try readSource("Maugham/Views/DiagnosticsPane.swift")
        let declaration = "private var content: some View {"
        let bodyStart = try XCTUnwrap(
            source.range(of: declaration),
            "`content` is where the placement lives; find it by name if it moved")
        let body = String(source[bodyStart.upperBound...])
        let bodyEnd = try XCTUnwrap(
            body.range(of: "\n    // MARK:"),
            "`content` is expected to be followed by a MARK; anchor on whatever "
            + "follows it if that changes")
        let content = String(body[..<bodyEnd.lowerBound])

        let noReportAnchor = try XCTUnwrap(
            content.range(of: "} else if !hasReport {"),
            "the no-report arm's own anchor. Body:\n\(content)")
        let reportAnchor = try XCTUnwrap(
            content.range(of: "\n        } else {"),
            "the report arm's own anchor. Body:\n\(content)")
        XCTAssertTrue(
            noReportAnchor.upperBound <= reportAnchor.lowerBound,
            "the no-report arm precedes the report arm")

        let arms = [
            ("no-report", String(content[noReportAnchor.upperBound..<reportAnchor.lowerBound])),
            ("report", String(content[reportAnchor.upperBound...])),
        ]
        for (name, arm) in arms {
            XCTAssertFalse(
                arm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the \(name) arm sliced to nothing \u{2014} the anchors are wrong, and "
                + "an empty arm asserts nothing")
            XCTAssertFalse(
                arm.contains("roundLine") || arm.contains("freshEyesLine"),
                "the round loop's two sentences left this pane in two loops P1 "
                + "Task 7 \u{2014} a check has no round to narrate:\n\(arm)")
            guard let letter = arm.range(of: "letterSection"),
                  let check = arm.range(of: "thisCheckSection") else {
                return XCTFail(
                    "the \(name) arm is missing letterSection or "
                    + "thisCheckSection:\n\(arm)")
            }
            XCTAssertTrue(
                letter.lowerBound < check.lowerBound,
                "the letter precedes This check in the \(name) arm \u{2014} the letter "
                + "is what the writer reads first; the notes are the margin:\n\(arm)")
        }
    }

    /// The letter renders over a run that raised nothing else at all — the
    /// `!hasReport` arm, on the delivery path rather than at the source.
    func test_anAllLetterRunStillDrawsItsLetter() throws {
        let docId = "doc-letter-only"
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(letter: makeLetter()), diagnostics: [], docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics,
            docId: docId, currentText: { _ in nil }, compilerModel: .standard)))

        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains(LetterSection.title),
            "a run whose whole output was a letter must still show it. Read: \(texts)")
        XCTAssertTrue(texts.contains("A ghost story told through weather."))
    }

    /// And over a run that DID raise clauses — the report arm — where it
    /// still leads.
    func test_theLetterLeadsTheReportArm() throws {
        let docId = "doc-letter-report"
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(
                clauseStatuses: [makeClause("No one says the word ghost.", "holds")],
                letter: makeLetter()),
            diagnostics: [], docId: docId)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics,
            docId: docId, currentText: { _ in nil }, compilerModel: .standard)))

        let texts = try axTexts(in: window)
        let letter = try XCTUnwrap(
            texts.firstIndex(of: LetterSection.title),
            "the letter never reached the report arm. Read: \(texts)")
        let clause = try XCTUnwrap(
            texts.firstIndex { $0.contains("No one says the word ghost.") },
            "the conformance summary never reached the surface. Read: \(texts)")
        XCTAssertLessThan(
            letter, clause,
            "the letter is read before the clause-by-clause report. Read: \(texts)")
    }

    /// **An empty letter draws no section**, and so does no letter at all.
    /// `Letter.isEmpty` ignores `about`, so this is the case of a run whose
    /// letter said only the say-back — and a heading over that alone would be
    /// a section pretending there was one.
    func test_anEmptyLetterAndNoLetterBothDrawNothing() throws {
        let empty = Letter(
            about: "A ghost story told through weather.", oneThing: nil,
            working: [], habits: [], questions: [], scenes: nil, scenePosition: nil)
        for (name, letter) in [("empty", empty), ("absent", nil)] as [(String, Letter?)] {
            let docId = "doc-\(name)"
            let diagnostics = DiagnosticsStore(
                projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
            diagnostics.replace(
                run: makeRun(letter: letter), diagnostics: [], docId: docId)
            let window = mount(AnyView(DiagnosticsPane(
                orchestrator: CompilerOrchestrator(), diagnostics: diagnostics,
                docId: docId, currentText: { _ in nil }, compilerModel: .standard)))
            let texts = try axTexts(in: window)
            XCTAssertFalse(
                texts.contains(LetterSection.title),
                "a \(name) letter must draw no section. Read: \(texts)")
        }

        // The control: the same mount with something in the letter draws it.
        let docId = "doc-letter-control"
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(letter: makeLetter()), diagnostics: [], docId: docId)
        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics,
            docId: docId, currentText: { _ in nil }, compilerModel: .standard)))
        XCTAssertTrue(try axTexts(in: window).contains(LetterSection.title))
    }

    /// **The offer is `strong_default`'s alone.** A writer whose own intent
    /// already carries the clause is never asked for it again — asking would
    /// file a second, duplicate ruling and read as the app not having listened.
    func test_theTurnOfferIsOfferedForStrongDefaultAndForNothingElse() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOffer")
        for position in [ScenePosition.strongDeclared, .weak, .none] {
            let window = mountLetterPane(
                store: store, docId: chapter.id,
                letter: makeLetter(scenePosition: position.rawValue))
            XCTAssertNil(
                findButton(labelled: LetterSection.addToIntentTitle, in: window),
                "\(position.rawValue) must not offer the clause")
        }

        let offered = mountLetterPane(
            store: store, docId: chapter.id,
            letter: makeLetter(scenePosition: ScenePosition.strongDefault.rawValue))
        XCTAssertNotNil(
            findButton(labelled: LetterSection.addToIntentTitle, in: offered),
            "the strong form with no clause of the writer's is exactly the gap the "
            + "offer exists for")

        let turning = mountLetterPane(
            store: store, docId: chapter.id,
            letter: makeLetter(turn: "She stops asking"))
        XCTAssertNil(
            findButton(labelled: LetterSection.addToIntentTitle, in: turning),
            "every scene already turns \u{2014} nothing for the clause to bite on")

        let storeless = mountLetterPane(store: nil, docId: chapter.id, letter: makeLetter())
        XCTAssertNil(
            findButton(labelled: LetterSection.addToIntentTitle, in: storeless),
            "a pane with no project has nowhere to file a ruling, and a button that "
            + "presses into nowhere is worse than none")
    }

    /// **Add to intent files the clause in the writer's own layer, with the
    /// letter's provenance — and the loop closes.** The very next
    /// `ScenePosition.derive` over the resulting statement answers
    /// `.strongDeclared`, which is what turns a turn-less scene into a
    /// conformance strain from the next round on.
    func test_addToIntentFilesTheClauseAndTheNextDeriveReadsItBack() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "TurnOfferFiles")
        let window = mountLetterPane(
            store: store, docId: chapter.id, letter: makeLetter(),
            reader: .coach(ReviewPass.coachPreset))

        let add = try button(labelled: LetterSection.addToIntentTitle, in: window)
        _ = add.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await awaitStatement(kind: .intent, scope: .document(chapter.id), in: store)

        let statement = try XCTUnwrap(
            store.statement(kind: .intent, scope: .document(chapter.id)))
        let text = try store.statementText(of: statement)
        XCTAssertTrue(
            text.contains(LetterSection.turnClauseRuling),
            "the writer's own words must be in the statement: \(text)")
        XCTAssertTrue(
            text.contains("## Rulings"),
            "a clause lands as a dated ruling, never as a paragraph appended to the "
            + "essay: \(text)")
        XCTAssertTrue(
            text.contains("from \(ReviewPass.coachPreset.effectiveEditorName)'s letter"),
            "the provenance says which reader asked: \(text)")
        XCTAssertEqual(
            ScenePosition.derive(projectType: .novel, statement: text, passBrief: nil),
            .strongDeclared,
            "the loop's whole point: the round after the click strains against a "
            + "clause the writer can find in their own statement")

        // And the derived render agrees with the op log.
        let derived = try await derivedText(of: statement, in: url)
        XCTAssertTrue(derived.contains(LetterSection.turnClauseRuling))
    }

    /// **The clause lands in the intent the piece is MEASURED against**
    /// (final review, Critical).
    ///
    /// A chapter with no intent of its own is briefed, checked and drifted
    /// against the book's — `effectiveIntent`'s fallback, the one resolution
    /// every reader shares. Filing at `.document(docId)` regardless mints a
    /// document-scoped statement with an empty essay, and document scope wins
    /// from that moment on for the briefing, the intent strip, the drift check
    /// and the live scene position. One click labelled *Add to intent* would
    /// detach the chapter from the book's intent, silently.
    ///
    /// So the offer files where the intent resolved, and says which one it
    /// means before the press.
    func test_theClauseLandsInTheIntentThePieceIsMeasuredAgainst() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOfferBookScope")
        let book = try await store.createStatement(kind: .intent, scope: .project)
        try await store.appendToStatement(
            "A ghost story told through weather on the coast.",
            to: book, session: "seed")
        XCTAssertEqual(
            store.effectiveIntent(forDocId: chapter.id)?.scope, .project,
            "the premise: the chapter has no intent of its own, so it is measured "
            + "against the book's")

        let window = mountLetterPane(
            store: store, docId: chapter.id, letter: makeLetter(),
            reader: .coach(ReviewPass.coachPreset))
        XCTAssertNil(
            findButton(labelled: LetterSection.addToIntentTitle, in: window),
            "the piece-scoped tense names a destination this press does not use")
        let add = try button(labelled: LetterSection.addToBookIntentTitle, in: window)
        _ = add.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await awaitStatement(kind: .intent, scope: .project, in: store)

        let text = try store.statementText(of: try XCTUnwrap(
            store.statement(kind: .intent, scope: .project)))
        XCTAssertTrue(
            text.contains("## Rulings") && text.contains(LetterSection.turnClauseRuling),
            "the clause lands as a dated ruling under the BOOK's intent: \(text)")
        XCTAssertTrue(
            text.contains("A ghost story told through weather on the coast."),
            "and the book's own essay is untouched: \(text)")
        XCTAssertNil(
            store.statement(kind: .intent, scope: .document(chapter.id)),
            "no document-scoped statement may be minted \u{2014} an empty essay at "
            + "document scope silently outranks the book's intent for every reader")
        XCTAssertEqual(
            store.effectiveIntent(forDocId: chapter.id)?.scope, .project,
            "and the chapter still reads the book's intent after the press")
    }

    /// The control: a piece with an intent of its own is measured against
    /// itself, so the clause files there and the button says the plain tense.
    /// The book also has one here, so a resolution that ignored the piece's
    /// own would have somewhere wrong to go.
    func test_aPieceWithItsOwnIntentFilesTheClauseUnderItself() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOfferPieceScope")
        let book = try await store.createStatement(kind: .intent, scope: .project)
        try await store.appendToStatement(
            "A ghost story told through weather on the coast.",
            to: book, session: "seed")
        let own = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement(
            "This chapter belongs to the dock and the fog.", to: own, session: "seed")

        let window = mountLetterPane(
            store: store, docId: chapter.id, letter: makeLetter(),
            reader: .coach(ReviewPass.coachPreset))
        XCTAssertNil(
            findButton(labelled: LetterSection.addToBookIntentTitle, in: window),
            "the book's tense would name a destination this press does not use")
        let add = try button(labelled: LetterSection.addToIntentTitle, in: window)
        _ = add.perform(NSSelectorFromString("accessibilityPerformPress"))
        try await awaitStatement(
            kind: .intent, scope: .document(chapter.id), in: store)

        let bookText = try store.statementText(of: try XCTUnwrap(
            store.statement(kind: .intent, scope: .project)))
        XCTAssertFalse(
            bookText.contains(LetterSection.turnClauseRuling),
            "a chapter's clause may not reach the book every other chapter reads: "
            + "\(bookText)")
    }

    /// **Keep this letter files a research note, through the real button**
    /// (Task 10, spec §3.6). The whole verb end to end: the press, the
    /// router's decision about where a novel chapter's note goes, the rendered
    /// body on disk, and the confirmation naming what the store called it.
    func test_keepThisLetterFilesAResearchNoteAndSaysWhatItCalledIt() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "LetterKeepPane")
        let letter = makeLetter()
        let window = mountLetterPane(
            store: store, docId: chapter.id, letter: letter,
            reader: .coach(ReviewPass.coachPreset))

        let keep = try button(labelled: LetterSection.keepTitle, in: window)
        _ = keep.perform(NSSelectorFromString("accessibilityPerformPress"))
        let kept = try await awaitResearchNote(in: store)

        XCTAssertTrue(kept.path?.hasPrefix("research/") == true, kept.path ?? "nil")
        XCTAssertTrue(store.linkedResearchIds(forDocumentId: chapter.id).contains(kept.id),
                      "a novel chapter's letter is shared research plus a link")
        let body = try String(
            contentsOf: store.url.appendingPathComponent(try XCTUnwrap(kept.path)),
            encoding: .utf8)
        XCTAssertTrue(body.contains(letter.about), body)
        XCTAssertTrue(
            body.contains(ReviewPass.coachPreset.effectiveEditorName),
            "the note is signed by the piece's reader: \(body)")

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains(LetterKeep.confirmation(kept.title)),
                      "the confirmation must name the note the store made. Read: \(texts)")
    }

    /// **A second press makes a second note** — §3.6 says a copy, and a writer
    /// who kept a letter, edited the note into something else and wants the
    /// original back is entitled to it. The confirmation follows the newest
    /// one, so it never names a note the writer cannot find.
    func test_asecondKeepMakesASecondNoteAndTheConfirmationFollowsIt() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "LetterKeepTwice")
        let window = mountLetterPane(
            store: store, docId: chapter.id, letter: makeLetter())

        let keep = try button(labelled: LetterSection.keepTitle, in: window)
        _ = keep.perform(NSSelectorFromString("accessibilityPerformPress"))
        let first = try await awaitResearchNote(in: store)
        _ = keep.perform(NSSelectorFromString("accessibilityPerformPress"))
        let second = try await awaitResearchNote(in: store, count: 2)

        XCTAssertNotEqual(first.id, second.id)
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains(LetterKeep.confirmation(second.title)),
                      "Read: \(texts)")
        XCTAssertFalse(texts.contains(LetterKeep.confirmation(first.title)),
                       "the line names the note just made, not the one before it")
    }

    /// Poll until the store's research list reaches `count` items —
    /// `LetterKeep.keep` is async and the press only starts it.
    private func awaitResearchNote(
        in store: ProjectStore, count: Int = 1, timeout: TimeInterval = 4
    ) async throws -> ResearchItem {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if store.manifest.research.count >= count {
                return store.manifest.research[count - 1]
            }
            pump(0.05)
            try? await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("no kept letter reached research within \(timeout)s")
        throw XCTSkip("no kept letter")
    }

    /// **The signature names the piece's reader**, which is the one resolution
    /// the header and the empty state already read (`AuthorReader`).
    func test_theLetterIsSignedByThePiecesReader() throws {
        let docId = "doc-signature"
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(round: 3, letter: makeLetter()), diagnostics: [], docId: docId)
        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics,
            docId: docId, currentText: { _ in nil }, compilerModel: .standard,
            reader: .coach(ReviewPass.coachPreset))))
        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains(LetterSection.signature(
                voice: ReviewPass.coachPreset.effectiveEditorName, round: 3)),
            "Read: \(texts)")
    }

    /// **A standing letter keeps the name it was written under** (two loops P2
    /// Task 4, closing P1's Ruling 10).
    ///
    /// The live reader here is `.nobody` — the writer vacated the seat, or
    /// chose nobody, after the check ran — and the standing run remembers Le
    /// Guin. Before the record carried a byline, this letter was re-signed
    /// "Claude" the moment the roster changed: yesterday's letter in a
    /// stranger's hand.
    ///
    /// Disable experiment: read `reader.editorName` at the signature and this
    /// fails on the first assertion, with the control below still green.
    func test_aStandingLetterIsSignedByTheReaderWhoWroteIt() throws {
        let docId = "doc-standing-byline"
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(round: 3, letter: makeLetter(), readerName: "Le Guin"),
            diagnostics: [], docId: docId)
        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics,
            docId: docId, currentText: { _ in nil }, compilerModel: .standard,
            reader: .nobody)))
        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains(LetterSection.signature(voice: "Le Guin", round: 3)),
            "the run's own byline signs its letter. Read: \(texts)")
        XCTAssertFalse(
            texts.contains(LetterSection.signature(
                voice: AuthorReader.nobody.editorName, round: 3)),
            "\u{2026}and today's reader does not. Read: \(texts)")
    }

    /// **…and so does everything else the standing letter writes** — Keep's
    /// note heading, a filed lesson's provenance, and the Add-to-intent
    /// ruling's.
    ///
    /// A census rather than four mounted presses. Each of these verbs writes to
    /// disk and would need a press and a poll to observe, which is tripwire 33's
    /// shape and which this file already spends its one representative on
    /// (`test_keepThisLetterFilesAResearchNoteAndSaysWhatItCalledIt`). What the
    /// census sees that a press could not is the whole SET: a fifth verb added
    /// to this section reading today's reader instead of the run's is caught
    /// here, and by nothing else.
    ///
    /// The bare spelling is what is banned. `run.readerName ?? reader.editorName`
    /// contains `reader.editorName` too, so the assertion is over what is LEFT
    /// once every guarded spelling is removed.
    func test_everythingTheStandingLetterWritesIsSignedByTheRunsOwnReader() throws {
        let section = try letterWiringSource()
        XCTAssertEqual(
            section.components(separatedBy: "run.readerName ?? reader.editorName").count - 1,
            4,
            "all four writing sites \u{2014} the signature, Keep's heading, a "
            + "filed lesson's provenance and Add-to-intent's \u{2014} read the "
            + "run's own byline: \(section)")
        let unguarded = section
            .replacingOccurrences(of: "run.readerName ?? reader.editorName", with: "")
        XCTAssertFalse(
            unguarded.contains("reader.editorName"),
            "the standing letter's byline is the RUN's, everywhere it is written "
            + "\u{2014} an unguarded read re-signs yesterday's letter with "
            + "today's reader. Left over:\n\(unguarded)")
    }

    /// CONTROL for the census above: the HEADER line is deliberately NOT
    /// guarded. "Le Guin reads this piece" and the empty state's "Press ⌘R
    /// and … reads what you've written." are promises about the NEXT run, so
    /// they must move the moment the writer changes the roster — which is the
    /// opposite of the rule for a letter that has already been written.
    func test_control_theHeaderLineStaysOnTheLiveReader() throws {
        let source = try readSource("Maugham/Views/DiagnosticsPane.swift")
        XCTAssertTrue(
            source.contains(#"static func readerCopy(for reader: AuthorReader) -> String {"#),
            "find the header's copy by name if it moved")
        XCTAssertTrue(
            source.contains(#""\(reader.editorName) reads this piece""#),
            "the header names who WILL read, so it reads the live reader")
    }

    /// **The letter's jumps are the pane's own event**, not a second post.
    ///
    /// A census because the section takes the jump as a closure and the
    /// mounted test for it lives in `LetterSectionTests`, which asserts the
    /// closure is called — what nothing there can see is WHICH closure this
    /// pane hands over. `jump(toParagraph:)` is the one spelling of
    /// `.maughamNavigateToParagraph` here (tripwire 21).
    func test_theLettersJumpsGoThroughThePanesOwnNavigation() throws {
        let section = try letterSectionSource()
        XCTAssertTrue(
            section.contains("onJump: { jump(toParagraph: $0) }"),
            "the letter must travel through the pane's own navigation, never a "
            + "second `MaughamEvent.post` spelled at the call site: \(section)")
        XCTAssertTrue(
            section.contains("createPaneTask("),
            "and Accept as task must reach the document's own verb: \(section)")
        XCTAssertTrue(
            section.contains("habit.refs.first?.paragraphId"),
            "anchored at the habit's FIRST ref: \(section)")
    }

    /// **The offer's memory is the writer's intent, not this pane's state.**
    ///
    /// A fresh pane over the SAME run must not offer a clause the statement
    /// already carries — the run's stamped `scenePosition` was decided before
    /// the ruling existed and cannot say so, so the host asks the live
    /// statement. `mountLetterPane` builds a new `DiagnosticsStore` every
    /// call, so the per-mount `turnClauseFiledForRun` cannot be what carries
    /// this: only the live read can.
    func test_aFreshPaneDoesNotOfferAClauseTheIntentAlreadyCarries() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOfferLive")

        // The control, first: nothing declared, so the offer stands.
        XCTAssertNotNil(
            findButton(
                labelled: LetterSection.addToIntentTitle,
                in: mountLetterPane(
                    store: store, docId: chapter.id, letter: makeLetter())),
            "a strong-default run over a piece with no clause must offer one, or "
            + "the absence below is evidence about nothing")

        try await RulingPerformer.rule(
            LetterSection.turnClauseRuling, provenance: "from Le Guin's letter",
            kind: .intent, forScope: .document(chapter.id), store: store, world: nil)

        XCTAssertNil(
            findButton(
                labelled: LetterSection.addToIntentTitle,
                in: mountLetterPane(
                    store: store, docId: chapter.id, letter: makeLetter())),
            "the clause is in the writer's own intent now \u{2014} reopening the pane "
            + "must not ask for it again, and a second click would file a duplicate")
    }

    /// And the clause counts wherever the piece would actually READ it from.
    /// `effectiveIntent` is piece-first with a project fallback, so a book-level
    /// declaration silences the offer on every chapter under it — the same
    /// resolution the run itself is briefed through.
    func test_aProjectLevelClauseSilencesTheOfferOnAChapter() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOfferProject")
        try await RulingPerformer.rule(
            LetterSection.turnClauseRuling, provenance: "from Le Guin's letter",
            kind: .intent, forScope: .project, store: store, world: nil)

        XCTAssertNil(
            findButton(
                labelled: LetterSection.addToIntentTitle,
                in: mountLetterPane(
                    store: store, docId: chapter.id, letter: makeLetter())),
            "the chapter reads the book's intent when it has none of its own; "
            + "offering here would ask for a clause the run is already briefed on")
    }

    /// **An opt-out withdraws the offer.** The writer said in their own words
    /// that this piece does not move by scenes; the run's stamp predates that
    /// sentence and cannot know. Control in the same test: the identical mount
    /// over a statement that says nothing still offers.
    func test_anOptOutWithdrawsTheOffer() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOfferOptOut")
        XCTAssertNotNil(
            findButton(
                labelled: LetterSection.addToIntentTitle,
                in: mountLetterPane(
                    store: store, docId: chapter.id, letter: makeLetter())),
            "the control: nothing declared, so the offer stands")

        let statement = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement(
            "This one is not scene-driven; it meanders on purpose.",
            to: statement, session: "seed")

        XCTAssertEqual(
            ScenePosition.live(store: store, docId: chapter.id), ScenePosition.none,
            "the premise: the opt-out beats everything")
        XCTAssertNil(
            findButton(
                labelled: LetterSection.addToIntentTitle,
                in: mountLetterPane(
                    store: store, docId: chapter.id, letter: makeLetter())),
            "asking a writer who just said the piece has no scenes to hold every "
            + "scene to a turn is the app not having listened")
    }

    /// **A prose piece opted in by its PASS BRIEF still gets the offer**, and
    /// this is the case that decides how the live read is spelled.
    ///
    /// `ScenePosition.live` derives with `passBrief: nil` — it must, since a
    /// brief is not a sentence the writer wrote about this book — so such a
    /// piece stamps `strong_default` on the run and derives `.weak` live.
    /// Drawing the offer only for a live `.strongDefault` would withhold it
    /// from exactly the writer spec §3.4 wrote it for. So the live read
    /// withdraws the offer for a declared clause and for an opt-out, and for
    /// nothing else.
    func test_aProsePieceOptedInByItsPassBriefStillGetsTheOffer() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOfferBriefOptIn")
        XCTAssertEqual(
            ScenePosition.live(store: store, docId: chapter.id), .weak,
            "the premise: a novel with no declared intent derives weak live, while "
            + "the RUN was told strong_default by its pass brief")
        XCTAssertNotNil(
            findButton(
                labelled: LetterSection.addToIntentTitle,
                in: mountLetterPane(
                    store: store, docId: chapter.id, letter: makeLetter())),
            "a live reading of `.weak` must NOT withdraw the offer \u{2014} only a "
            + "declared clause or an opt-out does")
    }

    /// **The census the behavioural tests cannot make**: both hosts decide and
    /// write the offer through the ONE builder, and neither re-spells the
    /// predicate. A host keeping its own copy would pass every behavioural
    /// test above that mounts it once, and drift silently afterwards.
    func test_bothHostsDecideTheOfferThroughTheOneBuilder() throws {
        for path in ["Maugham/Views/DiagnosticsPane.swift",
                     "Maugham/Views/AnnotationsPane.swift"] {
            let source = try readSource(path)
            XCTAssertTrue(
                source.contains("TurnClauseOffer.handler("),
                "\(path) must reach the one builder")
            XCTAssertFalse(
                source.contains("ScenePosition.live("),
                "\(path) must not re-derive the live position \u{2014} the two tenses "
                + "are `TurnClauseOffer`'s question, and a second copy is two answers "
                + "waiting to disagree")
            XCTAssertFalse(
                source.contains("RulingPerformer.rule(\n                    LetterSection.turnClauseRuling"),
                "\(path) must not spell the ruling call again either")
            XCTAssertTrue(
                source.contains("TurnClauseOffer.buttonTitle("),
                "\(path) must take the button's tense from the same place the write "
                + "takes its scope \u{2014} a host choosing its own words could label a "
                + "book-scoped ruling as the piece's own")
            XCTAssertFalse(
                source.contains("effectiveIntent(forDocId:"),
                "\(path) must not resolve the scope itself: one resolution, in the "
                + "builder that files the ruling")
        }
    }

    /// **Accept as task files onto the pane's OWN document.** `paneDocument`
    /// refuses a window whose active document is not this pane's subject;
    /// `activeDocument()` does not, and a habit's exercise anchored onto
    /// another chapter is a task the writer cannot account for.
    func test_acceptAsTaskGoesThroughThePanesOwnDocumentGuard() throws {
        let section = try letterSectionSource()
        XCTAssertTrue(
            section.contains("paneDocument?.createPaneTask("),
            "the letter's task must go through the guarded document: \(section)")
        XCTAssertFalse(
            section.contains("activeDocument()?.createPaneTask("),
            "and not through the unguarded one: \(section)")
    }

    // MARK: - Ask about… (P2 Task 7, spec §3.7)

    /// **The field shows what the writer already asked.** An ask outlives the
    /// round it was typed for — a worry usually outlasts one reading — so a
    /// field that opened empty over a stored ask would say the writer had
    /// withdrawn a question the next run is still briefed with.
    func test_theAskFieldShowsTheStoredAskOnMount() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AskFieldSeeded")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.setAsk("I'm worried the middle sags.", docId: chapter.id, kind: .check)

        let window = mount(pane(store: store, diagnostics: diagnostics, docId: chapter.id))
        pump(0.3)

        let fields = textFields(in: window)
        XCTAssertTrue(
            fields.contains { axAttribute($0, "accessibilityValue") as? String
                == "I'm worried the middle sags." },
            "the header's field must open holding the stored ask. Read: "
            + "\(fields.map { axAttribute($0, "accessibilityValue") as? String ?? "nil" })")
    }

    /// CONTROL for the test above, and the claim in its own right: nothing
    /// asked draws an empty field rather than no field, because the invitation
    /// is the point — a writer who has never asked anything is exactly who the
    /// placeholder is for.
    func test_theAskFieldStandsEmptyWhenNothingWasAsked() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AskFieldEmpty")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))

        let window = mount(pane(store: store, diagnostics: diagnostics, docId: chapter.id))
        pump(0.3)

        XCTAssertFalse(
            textFields(in: window).isEmpty,
            "the field is standing, not revealed \u{2014} an ask with no box to type it "
            + "into is a feature the writer cannot reach")
        XCTAssertNil(diagnostics.ask(docId: chapter.id, kind: .check), "and nothing was written")
    }

    /// **The commit lands, and it starts no run.** The keystroke is the only
    /// trigger (spec §2): typing a worry and pressing Return records the worry
    /// and nothing else — what it changes is what the NEXT ⌘R is briefed with.
    ///
    /// Driven through `AskField.commit`, the named function the field's
    /// `.onSubmit` calls, for the reason
    /// `test_theReplyFieldCommitsOnReturnAndCancelsOnEscape` gives: SwiftUI
    /// exposes no way to deliver a Return keystroke into a hosted `TextField`'s
    /// editor. The wiring itself is asserted at the source, below.
    func test_committingAnAskRecordsItAndStartsNoRun() async throws {
        let (url, _, chapter) = try await loadedNovel(named: "AskCommitNoRun")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let runner = SpyRunner()
        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(
            environment: makeEnvironment(docId: chapter.id, runner: runner),
            diagnostics: diagnostics)

        let versionBefore = diagnostics.version
        let refusal = AskField.commit(
            "  Does the middle sag?  ", docId: chapter.id, kind: .check, diagnostics: diagnostics)

        XCTAssertNil(refusal, "the commit reported: \(refusal ?? "")")
        XCTAssertEqual(diagnostics.ask(docId: chapter.id, kind: .check), "Does the middle sag?",
                       "committed trimmed, which is what the briefing carries")
        XCTAssertGreaterThan(diagnostics.version, versionBefore,
                             "control: the store really moved")
        XCTAssertEqual(
            runner.spawnedModels, [],
            "asking is not running \u{2014} a field that started a check would spend the "
            + "writer's money every time they finished a sentence")
        XCTAssertNil(diagnostics.lastRun(docId: chapter.id),
                     "and no run was recorded either")
    }

    /// **Clearing withdraws the ask rather than emptying a box.** ✕ commits
    /// nothing, so the next round is briefed with nothing — a field that
    /// cleared itself locally while the store still held the old sentence
    /// would be the app lying about what it is about to ask.
    func test_clearingTheAskWithdrawsIt() async throws {
        let (url, _, chapter) = try await loadedNovel(named: "AskClear")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.setAsk("Does the ending land?", docId: chapter.id, kind: .check)

        XCTAssertNil(AskField.commit(nil, docId: chapter.id, kind: .check, diagnostics: diagnostics))
        XCTAssertNil(diagnostics.ask(docId: chapter.id, kind: .check))
    }

    /// **A too-long ask is refused in one line, and the words stay put.** The
    /// notice names the limit, because a writer told only that it is too long
    /// has no way to know how much to cut.
    func test_anAskOverTheLimitIsRefusedWithANoticeThatNamesTheLimit() async throws {
        let (url, _, chapter) = try await loadedNovel(named: "AskTooLong")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.setAsk("Does the middle sag?", docId: chapter.id, kind: .check)

        let tooLong = String(repeating: "a", count: DiagnosticsStore.askLimit + 1)
        let refusal = AskField.commit(tooLong, docId: chapter.id, kind: .check, diagnostics: diagnostics)

        XCTAssertEqual(refusal, AskField.tooLongNotice)
        XCTAssertTrue(
            AskField.tooLongNotice.contains("\(DiagnosticsStore.askLimit)"),
            "the refusal must say how long is too long: \(AskField.tooLongNotice)")
        XCTAssertEqual(
            diagnostics.ask(docId: chapter.id, kind: .check), "Does the middle sag?",
            "and the ask that stood still stands")
    }

    /// CONTROL for the refusal: an ask exactly at the limit lands with no
    /// notice, so the cap is a ceiling and not an off-by-one that turns the
    /// longest legal worry away.
    func test_anAskExactlyAtTheLimitIsTaken() async throws {
        let (url, _, chapter) = try await loadedNovel(named: "AskAtLimit")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))

        let atLimit = String(repeating: "a", count: DiagnosticsStore.askLimit)
        XCTAssertNil(AskField.commit(atLimit, docId: chapter.id, kind: .check, diagnostics: diagnostics))
        XCTAssertEqual(diagnostics.ask(docId: chapter.id, kind: .check), atLimit)
    }

    // MARK: - The ask, per tempo (two loops P1 Task 6)

    /// **`Input.kind` carries through `AskField.commit`/`.note` to the store**
    /// — a commit made with `kind: .round` must land under the round's key
    /// and never the check's, and the converse. Driven through the named
    /// functions directly (`AskField.commit`/`.note`), the same wiring the
    /// field's `.onSubmit`/`.onChange` call — asserted at the source, below.
    func test_theCommitPathCarriesItsKindThroughToTheStore() async throws {
        let (url, _, chapter) = try await loadedNovel(named: "AskCommitKind")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))

        XCTAssertNil(AskField.commit(
            "Does the middle sag?", docId: chapter.id, kind: .check, diagnostics: diagnostics))
        XCTAssertNil(AskField.commit(
            "Is the pass's own thread landing?", docId: chapter.id, kind: .round,
            diagnostics: diagnostics))

        XCTAssertEqual(diagnostics.ask(docId: chapter.id, kind: .check), "Does the middle sag?")
        XCTAssertEqual(
            diagnostics.ask(docId: chapter.id, kind: .round),
            "Is the pass's own thread landing?")
    }

    /// The keystroke half of the same wiring: `AskField.note` notes a pending
    /// draft under its own kind, so a round's draft cannot be promoted by a
    /// check's run and the converse (`DiagnosticsStoreTests`' store-level
    /// pin of the same rule).
    func test_theNotePathCarriesItsKindThroughToTheStore() async throws {
        let (url, _, chapter) = try await loadedNovel(named: "AskNoteKind")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))

        AskField.note("Does the middle sag?", docId: chapter.id, kind: .check, diagnostics: diagnostics)

        XCTAssertTrue(diagnostics.commitPendingAsk(docId: chapter.id, kind: .check))
        XCTAssertFalse(
            diagnostics.commitPendingAsk(docId: chapter.id, kind: .round),
            "nothing was ever noted against the round")
        XCTAssertNil(diagnostics.ask(docId: chapter.id, kind: .round))
        XCTAssertEqual(diagnostics.ask(docId: chapter.id, kind: .check), "Does the middle sag?")
    }

    /// **The field commits on submit and on focus loss, and never per
    /// keystroke.** `setAsk` rewrites the asks file and bumps the store's
    /// version on every call, so a binding wired straight to it would be one
    /// file write and one full pane re-render per letter typed.
    ///
    /// Asserted at the source for `test_theReplyFieldCommitsOnReturnAndCancelsOnEscape`'s
    /// reason — a hosted `TextField` cannot be sent a Return — and by named
    /// verbs, so a rename fails this rather than a reformat.
    func test_theAskFieldCommitsOnSubmitAndFocusLossOnly() throws {
        let source = try readSource("Maugham/Views/AskField.swift")
        XCTAssertTrue(
            source.contains(".onSubmit { commitDraft() }"),
            "return must commit \u{2014} a field with no submit verb is a box the writer "
            + "types into and cannot send")
        XCTAssertTrue(
            source.contains(".onChange(of: focused) { was, now in"),
            "and clicking away must commit too, or a typed worry is lost to the next "
            + "thing the writer touches")
        XCTAssertTrue(
            source.contains("TextField(Self.placeholder, text: $draft)"),
            "the field binds to its own draft; a binding straight to the store would "
            + "write the asks file once per keystroke")
        XCTAssertFalse(
            source.contains(".onChange(of: draft) { _, now in commitDraft"),
            "the keystroke handler NOTES, it does not commit")
    }

    /// **Typing costs nothing** (fix round 1, Important 1). Every keystroke is
    /// noted so a round can pick it up, and noting must stay a dictionary
    /// write: a version bump would re-render both panes on every letter, and a
    /// file write would put the asks sidecar on the writer's typing path.
    ///
    /// Measured on the store rather than asserted at the source, because what
    /// matters is the cost and not the spelling.
    func test_notingAKeystrokeWritesNothingAndRendersNothing() throws {
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let file = DiagnosticsStore.asksURL(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let versionBefore = diagnostics.version

        for prefix in ["I", "I'm", "I'm w", "I'm worried"] {
            diagnostics.notePendingAsk(prefix, docId: "doc-1", kind: .check)
        }

        XCTAssertEqual(diagnostics.version, versionBefore,
                       "noting must not re-render the panes reading this store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "nor touch the asks file")
        XCTAssertNil(diagnostics.ask(docId: "doc-1", kind: .check),
                     "and nothing is asked until something commits it")

        // Control: the commit a round makes does all three.
        XCTAssertTrue(diagnostics.commitPendingAsk(docId: "doc-1", kind: .check))
        XCTAssertEqual(diagnostics.ask(docId: "doc-1", kind: .check), "I'm worried")
        XCTAssertGreaterThan(diagnostics.version, versionBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// **⌘R commits what is still in the field, and the round carries it**
    /// (fix round 1, Important 1).
    ///
    /// The run keys are menu commands posted to the key window and they never
    /// touch the first responder, so a writer who types a worry and presses ⌘R
    /// without pressing Return would otherwise watch the round go out briefed
    /// on the ask they had *before*, with the new sentence still on screen.
    ///
    /// Delivered the whole way: a real keystroke into the hosted field, the
    /// real `maugham.*` event, a real orchestrator, and the prompt the runner
    /// was actually sent.
    func test_theRunKeyCommitsWhatIsStillInTheAskField() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AskRunKey")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let runner = SpyRunner()
        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(
            environment: makeEnvironment(docId: chapter.id, runner: runner),
            diagnostics: diagnostics)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: orchestrator, diagnostics: diagnostics, docId: chapter.id,
            currentText: { _ in nil }, compilerModel: .standard, store: store)))
        // The `WindowAccessor` resolves on the next main-queue turn, and the
        // run subscription's scope filter is what it feeds.
        pump(0.4)

        let worry = "I'm worried the middle sags."
        let field = try XCTUnwrap(askTextField(in: window), "no ask field on the pane")
        type(worry, into: field)
        pump(0.2)
        XCTAssertNil(diagnostics.ask(docId: chapter.id, kind: .check),
                     "premise: typing alone commits nothing")

        // The event, then the round — the exact order and the exact
        // synchrony `CompilerRunModifier` produces, which is the one thing
        // this mount does not carry (it hosts the pane, not the window).
        // Exactly what ⌘R does: `CompilerRunModifier` calls this and nothing
        // else. Nothing in between touches the first responder, which is why
        // the pending draft has to be promoted by the run itself.
        orchestrator.runRequested(docId: chapter.id, kind: .check)
        try await waitUntilAsync(timeout: 5) { !runner.sentMessages.isEmpty }

        XCTAssertEqual(
            diagnostics.ask(docId: chapter.id, kind: .check), worry,
            "the round must promote the pending draft into the ask")
        XCTAssertTrue(
            runner.sentMessages.first?.contains(worry) == true,
            "and must actually be briefed with it. Sent: "
            + "\(runner.sentMessages.first ?? "nothing")")
    }




    /// CONTROL for the test above: with nothing typed, the same round is
    /// briefed with no ask at all — so the assertion above is about the
    /// writer's sentence and not about a string every prompt carries.
    func test_aRoundWithNothingTypedIsBriefedWithNoAsk() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AskRunKeyControl")
        let diagnostics = DiagnosticsStore(
            projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let runner = SpyRunner()
        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(
            environment: makeEnvironment(docId: chapter.id, runner: runner),
            diagnostics: diagnostics)

        let window = mount(AnyView(DiagnosticsPane(
            orchestrator: orchestrator, diagnostics: diagnostics, docId: chapter.id,
            currentText: { _ in nil }, compilerModel: .standard, store: store)))
        pump(0.4)
        XCTAssertNotNil(askTextField(in: window), "premise: the field was there to type into")

        orchestrator.runRequested(docId: chapter.id, kind: .check)
        try await waitUntilAsync(timeout: 5) { !runner.sentMessages.isEmpty }

        XCTAssertNil(diagnostics.ask(docId: chapter.id, kind: .check))
        XCTAssertFalse(
            runner.sentMessages.first?.contains("I'm worried the middle sags.") == true,
            "nothing was asked, so nothing about a middle may reach the briefing")
    }

    /// **A draft belongs to the document it was typed about** (fix round 1,
    /// Minor 2).
    ///
    /// Neither host keys the field on the subject and neither pane is rebuilt
    /// when the window's subject changes, so a half-typed sentence about one
    /// chapter used to survive a click onto another and file itself there at
    /// the next commit. Driven through the run event, which is a commit
    /// trigger a mounted test can actually deliver.
    func test_aPendingAskDoesNotFollowTheWriterToAnotherChapter() throws {
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let subject = AskSubject(docId: "doc-a")
        let window = mount(AnyView(
            AskFieldProbe(subject: subject, diagnostics: diagnostics)))
        pump(0.4)

        let field = try XCTUnwrap(askTextField(in: window))
        type("Does the middle of chapter one sag?", into: field)
        pump(0.2)

        subject.docId = "doc-b"
        pump(0.3)

        XCTAssertEqual(
            askTextField(in: window)?.stringValue, "",
            "the draft must go with the chapter it was about")

        // What a round on either chapter would do.
        diagnostics.commitPendingAsk(docId: "doc-b", kind: .check)
        diagnostics.commitPendingAsk(docId: "doc-a", kind: .check)
        XCTAssertNil(diagnostics.ask(docId: "doc-b", kind: .check),
                     "and must never be filed against the chapter the writer moved to")
        XCTAssertNil(diagnostics.ask(docId: "doc-a", kind: .check),
                     "nor against the one they left \u{2014} it was never committed")
    }

    /// CONTROL for the test above: without the subject change the very same
    /// sequence DOES commit, so the assertion is about the switch and not
    /// about the run event failing to arrive.
    func test_withoutASubjectChangeThePendingAskIsCommitted() throws {
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let subject = AskSubject(docId: "doc-a")
        let window = mount(AnyView(
            AskFieldProbe(subject: subject, diagnostics: diagnostics)))
        pump(0.4)

        type("Does the middle of chapter one sag?",
             into: try XCTUnwrap(askTextField(in: window)))
        pump(0.2)
        diagnostics.commitPendingAsk(docId: "doc-a", kind: .check)

        XCTAssertEqual(diagnostics.ask(docId: "doc-a", kind: .check),
                       "Does the middle of chapter one sag?")
    }

    /// **The refusal notice does not outlive its cause** (fix round 1, Minor
    /// 3). A writer who shortens a refused ask back to what already stands has
    /// fixed it, and `commitDraft`'s unchanged-guard returns before writing —
    /// so the clear has to happen on that path too, or a red line stays on
    /// screen with nothing left that can dismiss it.
    func test_theRefusalNoticeIsClearedOnEveryPathThatMakesItUntrue() throws {
        let source = try readSource("Maugham/Views/AskField.swift")
        let commitBody = try XCTUnwrap(
            source.range(of: "private func commitDraft() {").map {
                String(source[$0.upperBound...].prefix(300))
            },
            "`commitDraft` is where the unchanged-guard lives; find it by name if it moved")
        XCTAssertTrue(
            commitBody.contains("clearNotice()"),
            "the early return must clear the notice: \(commitBody)")
        // Bounded by the NEXT modifier rather than by a character budget: a
        // count is a headroom that runs out silently as the comment above the
        // line grows, and the test then goes red for a reason that has
        // nothing to do with what it is about.
        let askStart = try XCTUnwrap(
            source.range(of: ".onChange(of: ask) {"),
            "`.onChange(of: ask)` is where the stored-ask clear lives; "
                + "find it by name if it moved")
        let rest = source[askStart.upperBound...]
        let askChange = String(
            rest[..<(rest.range(of: ".onChange(of: focused)")?.lowerBound
                     ?? rest.endIndex)])
        XCTAssertTrue(
            askChange.contains("clearNotice()"),
            "and so must a stored ask that moved: \(askChange)")
    }

    /// **A commit that changes nothing writes nothing.** Focus loss fires
    /// every time the writer clicks away, including right after a Return that
    /// already committed the same sentence — and `setAsk` rewrites the asks
    /// file and bumps the store's version on every call, so a field that
    /// committed unconditionally would keep the never-per-keystroke rule and
    /// then undo it one click at a time.
    func test_theAskFieldDoesNotRewriteAnUnchangedAsk() throws {
        let source = try readSource("Maugham/Views/AskField.swift")
        XCTAssertTrue(
            source.contains("guard trimmed != (ask ?? \"\") else {"),
            "the commit must compare against the stored ask before writing")
    }

    /// **Both homes commit through the one function**, so neither can refuse a
    /// long ask in different words or trim it differently.
    func test_bothHostsCommitTheAskThroughTheOneFunction() throws {
        for path in ["Maugham/Views/DiagnosticsPane.swift",
                     "Maugham/Views/AnnotationsPane.swift"] {
            let source = try readSource(path)
            XCTAssertTrue(
                source.contains("AskField.commit("),
                "\(path) must go through the shared commit")
            XCTAssertFalse(
                source.contains("diagnostics.setAsk("),
                "\(path) must not spell the store write itself \u{2014} a host with its "
                + "own commit is a second answer about what a refused ask says")
        }
    }

    // MARK: - Letter hosting

    /// `letterSection`'s body, bounded at BOTH ends by a named declaration.
    ///
    /// It used to be `prefix(1400)` off the opening line, which is a slice
    /// whose meaning changes every time a comment above or below it grows: too
    /// short and a real wiring line falls outside the window the assertion
    /// reads, too long and it starts asserting over the next function's body.
    /// Anchoring on the declaration that follows means a moved boundary fails
    /// loudly here instead of quietly narrowing what these censuses cover.
    /// **The letter's whole WIRING region** — `letterSection` plus the two
    /// builders it delegates to (`ledgerHandlers`, `turnClauseOffer`), bounded
    /// at both ends by a named declaration on `letterSectionSource`'s rule.
    ///
    /// Wider than `letterSectionSource` deliberately, and not a replacement for
    /// it: the censuses that ask what `letterSection` ITSELF hands over want
    /// the narrow region, while the byline census is about a fact that must
    /// hold at every site the letter writes from — and one of the four lives
    /// inside `turnClauseOffer`, past the narrow region's end bound (fix round
    /// 1: reverting that site would have stayed green).
    private func letterWiringSource() throws -> String {
        let source = try readSource("Maugham/Views/DiagnosticsPane.swift")
        let start = try XCTUnwrap(
            source.range(of: "private var letterSection: some View {"),
            "`letterSection` opens the region; find it by name if it moved")
        let end = try XCTUnwrap(
            source.range(of: "static let turnClauseFailureKey",
                         range: start.upperBound..<source.endIndex),
            "`turnClauseFailureKey` is the declaration after the last builder; "
            + "find it by name if it moved")
        return String(source[start.upperBound..<end.lowerBound])
    }

    private func letterSectionSource() throws -> String {
        let source = try readSource("Maugham/Views/DiagnosticsPane.swift")
        let start = try XCTUnwrap(
            source.range(of: "private var letterSection: some View {"),
            "`letterSection` is where the wiring lives; find it by name if it moved")
        let end = try XCTUnwrap(
            source.range(of: "private func turnClauseOffer(",
                         range: start.upperBound..<source.endIndex),
            "`turnClauseOffer` is the declaration that bounds it; find it by name "
            + "if it moved")
        return String(source[start.upperBound..<end.lowerBound])
    }

    private func mountLetterPane(
        store: ProjectStore?, docId: String, letter: Letter,
        reader: AuthorReader = .nobody,
        freshEyes: Bool? = nil,
        passId: String? = nil, round: Int? = nil,
        /// **Who the standing RUN was read by**, as `CompilerRun.readerName`
        /// records it — which is not who reads the piece today. `nil`, the
        /// default, is a record written before the stamp existed, and falls
        /// back to the live `reader`.
        readerName: String? = nil
    ) -> NSWindow {
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.replace(
            run: makeRun(passId: passId, round: round, freshEyes: freshEyes,
                         letter: letter, readerName: readerName),
            diagnostics: [], docId: docId)
        return mount(AnyView(DiagnosticsPane(
            orchestrator: CompilerOrchestrator(), diagnostics: diagnostics,
            docId: docId, currentText: { _ in nil }, compilerModel: .standard,
            store: store, reader: reader)))
    }

    // MARK: - The lessons ledger, from the letter (P2 Task 7)

    /// A letter with one habit worth keeping, and nothing else in it.
    private func habitLetter(
        name: String = "Every speech sounds like the same person",
        lesson: String? = "Give each voice one word the others never use.",
        retired: [String]? = nil
    ) -> Letter {
        Letter(
            about: "A ghost story told through weather.",
            oneThing: nil, working: [],
            habits: [Letter.Habit(
                name: name, refs: [], cost: "The cast blurs.",
                lesson: lesson, exercise: nil)],
            questions: [], scenes: nil, scenePosition: nil, retired: retired)
    }

    /// **Retire is a COLD round's offer, and a warm one still says what it
    /// saw.** A warm round read a three-paragraph delta, which proves nothing
    /// about a habit; only Fresh Eyes read the whole piece, which is the
    /// evidence a retirement stands on.
    ///
    /// Disable experiment: wiring `freshEyes: true` unconditionally in
    /// `DiagnosticsPane.letterSection` turns the warm half of this red.
    func test_onlyAColdRoundOffersToRetireALesson() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "RetireOfferTense")
        let lesson = "Vary the opening."
        try await LessonLedgerVerbs.keepAsLesson(
            lesson, provenance: "from Le Guin's letter", store: store, world: nil)

        let warm = mountLetterPane(
            store: store, docId: chapter.id,
            letter: habitLetter(retired: [lesson]), freshEyes: nil)
        pump(0.3)
        XCTAssertNil(
            findButton(labelled: LetterSection.retireTitle, in: warm),
            "a warm round read a delta and must not offer a retirement over it. "
            + "Read: \(allLabels(in: warm))")
        XCTAssertTrue(
            allLabels(in: warm).contains(LetterSection.warmRetiredLine(lesson)),
            "…but it still owes the writer the observation. Read: \(allLabels(in: warm))")

        // Control: the same letter, read cold, offers the button.
        let cold = mountLetterPane(
            store: store, docId: chapter.id,
            letter: habitLetter(retired: [lesson]), freshEyes: true)
        pump(0.3)
        XCTAssertNotNil(
            findButton(labelled: LetterSection.retireTitle, in: cold),
            "a cold round read the whole piece, which is what a retirement stands on. "
            + "Read: \(allLabels(in: cold))")
    }

    /// **Neither host spells a ledger write.** All three presses are built by
    /// `LessonOffer.handlers`, so the provenance, the date and the refusal
    /// channel cannot come out different in Author than in Review — a
    /// difference that would be invisible until a writer read their ledger
    /// months later.
    func test_bothHostsTakeTheLedgerVerbsFromTheOneBuilder() throws {
        for path in ["Maugham/Views/DiagnosticsPane.swift",
                     "Maugham/Views/AnnotationsPane.swift"] {
            let source = try readSource(path)
            XCTAssertTrue(
                source.contains("LessonOffer.handlers("),
                "\(path) must build its ledger closures with the shared builder")
            for verb in ["LessonLedgerVerbs.keepAsLesson(",
                         "LessonLedgerVerbs.makeChoice",
                         "LessonLedgerVerbs.retire("] {
                XCTAssertFalse(
                    source.contains(verb),
                    "\(path) must not call \(verb) itself \u{2014} a host with its own "
                    + "write is a second answer about what a ledger line says")
            }
            XCTAssertTrue(
                source.contains("freshEyes: run.freshEyes == true")
                    || source.contains("freshEyes: run?.freshEyes == true"),
                "\(path) must state the round's tense rather than leave the view to "
                + "infer it from which closures arrived")
        }
    }

    /// Poll until the ruling's statement exists and carries the clause —
    /// `RulingPerformer.rule` is async and the press only starts it.
    private func awaitStatement(
        kind: Statement.Kind, scope: Statement.Scope, in store: ProjectStore,
        timeout: TimeInterval = 4
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let statement = store.statement(kind: kind, scope: scope),
               let text = try? store.statementText(of: statement),
               text.contains(LetterSection.turnClauseRuling) { return }
            pump(0.05)
            try? await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("the ruling never landed within \(timeout)s")
    }

    // MARK: - Hosting

    private func mount(_ view: AnyView) -> NSWindow {
        let window = TestWindow.mount(view, size: CGSize(width: 420, height: 700))
        windows.append(window)
        pump()
        return window
    }

    /// The ask field's own `NSTextField`, found by the placeholder it draws —
    /// the real control, which is what a keystroke reaches.
    private func askTextField(in window: NSWindow) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        var found: [NSTextField] = []
        collect(NSTextField.self, in: root, into: &found)
        return found.first { $0.placeholderString == AskField.placeholder }
    }

    /// **Drive a SwiftUI `TextField`'s binding from outside the responder
    /// chain** — `DepartmentRunTests`' idiom: setting `stringValue` and posting
    /// the notification its delegate listens for is what a real keystroke does
    /// once it reaches the field, without this host having to be the active app.
    private func type(_ text: String, into field: NSTextField) {
        field.stringValue = text
        NotificationCenter.default.post( // adr-0021-ok: Apple's own textDidChange, not a maugham.* event
            name: NSControl.textDidChangeNotification, object: field)
    }

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The first `NSScrollView` in `view`'s subtree, depth-first — the
    /// geometry check for the no-report arm's overflow test needs the real
    /// `NSScrollView` (its `documentView` and `contentView` bounds), which the
    /// accessibility tree does not expose the way it does labels and buttons.
    private func firstScrollView(in view: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        collect(NSScrollView.self, in: view, into: &found)
        return found.first
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
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

    /// Any AX element (not role-restricted, unlike `button(labelled:in:)`)
    /// whose value or label matches `text` exactly — for reading a frame off
    /// a static text element, which carries no `AXButton` role.
    private func element(labelled text: String, in window: NSWindow) throws -> AnyObject {
        try XCTUnwrap(
            (try axTree(in: window)).first {
                (axAttribute($0, "accessibilityValue") as? String) == text
                || (axAttribute($0, "accessibilityLabel") as? String) == text
            },
            "no element labelled \u{201C}\(text)\u{201D} reached the hosted pane; got "
            + "\(allLabels(in: window))")
    }

    /// `element`'s on-screen frame, read via `accessibilityFrame` — screen
    /// coordinates, the same space `NSWindow.frame`/`convertToScreen(_:)`
    /// report in, so a frame read this way is directly comparable to one read
    /// off the window with no flip or origin correction needed.
    private func axFrame(_ element: AnyObject) -> NSRect? {
        (axAttribute(element, "accessibilityFrame") as? NSValue)?.rectValue
    }

    /// Every accessibility ROLE carried by an element whose value or label is
    /// `text` — what tells a plain `Text` from a control the writer can open.
    private func roles(labelled text: String, in window: NSWindow) -> [String] {
        guard let tree = try? axTree(in: window) else { return [] }
        return tree
            .filter {
                (axAttribute($0, "accessibilityValue") as? String) == text
                    || (axAttribute($0, "accessibilityLabel") as? String) == text
            }
            .compactMap { axAttribute($0, "accessibilityRole") as? String }
    }

    // MARK: - Source census helpers (two loops P2 Task 6)

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent("Maugham/\(relativePath)"),
            encoding: .utf8)
    }

    /// The text from `name` to the end of its brace-balanced body. A per-suite
    /// copy, as every census suite in `MaughamTests` declares — see
    /// `ReviewPassEditorTests`' own note on why.
    private static func declaration(named name: String, in source: String) -> String? {
        guard let start = source.range(of: name) else { return nil }
        var depth = 0
        var index = start.lowerBound
        var seenOpen = false
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1; seenOpen = true }
            if character == "}" {
                depth -= 1
                if seenOpen && depth == 0 {
                    return String(source[start.lowerBound...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
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

    /// **Every field the pane REVEALS, which is every field but the header's
    /// standing ask** (P2 Task 7).
    ///
    /// The reply field, the drift line's absent one and Not this's absent one
    /// are all claims about what a press opened. Ask about… stands in the
    /// header from the moment the pane mounts, so a bare count of text fields
    /// stopped being able to say anything about them the day it shipped.
    private func revealedFields(in window: NSWindow) -> [AnyObject] {
        textFields(in: window).filter {
            (axAttribute($0, "accessibilityIdentifier") as? String)
                != AskField.fieldIdentifier
        }
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

/// **A subject a test can move under a mounted field**, so the docId change
/// `AskField` guards against can be delivered rather than described. The
/// window's real subject switch is a `BinderSubject` write several views up;
/// what reaches the field is exactly this — a new `docId` on the same view.
@MainActor
@Observable
final class AskSubject {
    var docId: String
    init(docId: String) { self.docId = docId }
}

/// The field alone, over a subject a test can move. Mirrors what both hosts
/// build: the commit closure resolves the docId at press time, which is the
/// realistic hazard — the host rebuilds it for the NEW chapter while the old
/// chapter's draft is still in the box.
@MainActor
struct AskFieldProbe: View {
    let subject: AskSubject
    let diagnostics: DiagnosticsStore

    var body: some View {
        _ = diagnostics.version
        return AskField(
            input: AskField.Input(
                docId: subject.docId,
                kind: .check,
                text: diagnostics.ask(docId: subject.docId, kind: .check),
                commit: { AskField.commit($0, docId: subject.docId,
                                          kind: .check, diagnostics: diagnostics) },
            note: { text, doc in
                AskField.note(text, docId: doc, kind: .check, diagnostics: diagnostics)
            }))
    }
}
