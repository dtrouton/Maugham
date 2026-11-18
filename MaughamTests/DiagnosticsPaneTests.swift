import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The pane the compiler's notes land on** (M2 Task 8). The header states
/// are pure — `CheckNarrative.headerState(...)` derives one from
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
                         openInOtherLanesNoteIds: [String]? = nil,
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
                           openInOtherLanesNoteIds: openInOtherLanesNoteIds,
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

    // MARK: - Header state (pure — no mount)

    func test_headerState_neverRun() {
        let state = CheckNarrative.headerState(
            runState: .idle, lastRun: nil, noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .neverRun)
    }

    func test_headerState_idleWithLastRunLine() {
        let run = makeRun()
        let state = CheckNarrative.headerState(
            runState: .idle, lastRun: run, noteCount: 2, docId: "d1")
        XCTAssertEqual(state, .idle(lastRun: run))
    }

    func test_headerState_running() {
        let since = Date(timeIntervalSince1970: 1_000)
        let state = CheckNarrative.headerState(
            runState: .running(docId: "d1", kind: .check, checking: counts(new: 14, revised: 0)),
            lastRun: nil, noteCount: 0, docId: "d1",
            runStartedAt: since, runProgress: RunProgress(thinkingTokens: 500, at: since))
        XCTAssertEqual(state, .running(checking: counts(new: 14, revised: 0), since: since,
                                       progress: RunProgress(thinkingTokens: 500, at: since)))
    }

    /// **The running header ticks** (spec 2026-09-09 §5): the same state read a
    /// minute later says how long the writer has been waiting, and how far the
    /// model has got. Pure, so the clock is assertable without a mount.
    func test_theRunningHeaderSaysHowLongAndHowFar() {
        let since = Date(timeIntervalSince1970: 1_000)
        let state = CheckNarrative.HeaderState.running(
            checking: counts(new: 457, revised: 0), since: since,
            progress: RunProgress(thinkingTokens: 12_400, at: since))
        XCTAssertEqual(
            CheckNarrative.headerCopy(for: state, now: since.addingTimeInterval(130), annotations: [], passes: []),
            "Checking 457 new paragraphs\u{2026} 2m 10s \u{00b7} thinking (12k tokens)")
    }

    /// A finished run says how long it took; a legacy run without timing says
    /// exactly what it did before.
    func test_theIdleHeaderCarriesReadIn() throws {
        var run = makeRun()
        XCTAssertFalse(CheckNarrative.headerCopy(for: .idle(lastRun: run), annotations: [], passes: []).contains("read in"))
        run.timing = RunTiming(elapsed: 252, model: "opus", effort: "high")
        XCTAssertTrue(CheckNarrative.headerCopy(for: .idle(lastRun: run), annotations: [], passes: [])
            .hasSuffix(" \u{00b7} read in 4m 12s"))
    }

    /// **The clean header says it too**, and this is the arm that matters most
    /// for a first reader: she raises no conformance strain, so every check of
    /// hers leaves this pane `.clean` and the `.idle` line above is never
    /// reached. The suffix sits inside the sentence, before the full stop,
    /// because the sentence is what the writer reads.
    func test_theCleanHeaderCarriesReadIn() throws {
        var run = makeRun()
        let untimed = CheckNarrative.headerCopy(for: .clean(lastRun: run), annotations: [], passes: [])
        XCTAssertTrue(untimed.hasPrefix("Nothing to flag. Last checked "), untimed)
        XCTAssertFalse(untimed.contains("read in"),
                       "a run filed before timing existed says what it always did: \(untimed)")

        run.timing = RunTiming(elapsed: 252, model: "opus", effort: "high")
        let timed = CheckNarrative.headerCopy(for: .clean(lastRun: run), annotations: [], passes: [])
        XCTAssertEqual(timed,
                       String(untimed.dropLast()) + " \u{00b7} read in 4m 12s.",
                       "the suffix belongs inside the sentence, before the full stop")
    }

    // MARK: - The legible wait (requirement 5)

    /// **A two-minute "Checking…" reads as a hang.** The running header names
    /// what the compiler is reading, in the writer's English, from the moment
    /// the run starts — the counts are known before the send, so nothing waits
    /// on the answer to say them.
    func test_theRunningHeaderSaysWhatItIsReading() {
        XCTAssertEqual(
            CheckNarrative.headerCopy(
                for: .running(checking: counts(new: 14, revised: 0), since: nil, progress: nil), annotations: [], passes: []),
            "Checking 14 new paragraphs\u{2026}")
        XCTAssertEqual(
            CheckNarrative.headerCopy(
                for: .running(checking: counts(new: 1, revised: 0), since: nil, progress: nil), annotations: [], passes: []),
            "Checking 1 new paragraph\u{2026}",
            "one paragraph is not \u{201C}1 new paragraphs\u{201D}")
        XCTAssertEqual(
            CheckNarrative.headerCopy(
                for: .running(checking: counts(new: 0, revised: 3), since: nil, progress: nil), annotations: [], passes: []),
            "Checking 3 revised paragraphs\u{2026}")
        XCTAssertEqual(
            CheckNarrative.headerCopy(
                for: .running(checking: counts(new: 14, revised: 3), since: nil, progress: nil), annotations: [], passes: []),
            "Checking 14 new and 3 revised paragraphs\u{2026}")
    }

    /// The arm a delta cannot reach — `beginRun` refuses an empty one before
    /// the running state is ever set — asserted anyway, because a function
    /// whose caller has to reason before calling it is one the next caller gets
    /// wrong.
    func test_theRunningHeaderIsTotalOverCountsADeltaCannotHave() {
        XCTAssertEqual(
            CheckNarrative.headerCopy(
                for: .running(checking: counts(new: 0, revised: 0), since: nil, progress: nil), annotations: [], passes: []),
            "Checking\u{2026}")
        XCTAssertNil(RoundNarrative.paragraphPhrase(counts(new: 0, revised: 0)))
    }

    /// And the empty pane says the same thing, off the same spelling — two
    /// sentences about the same two numbers are two things that can disagree.
    func test_theEmptyPaneNamesTheSameDeltaTheHeaderDoes() {
        let empty = CheckNarrative.emptyState(
            for: .running(checking: counts(new: 14, revised: 3), since: nil, progress: nil), annotations: [], passes: [])
        XCTAssertEqual(empty.title, "Checking\u{2026}")
        XCTAssertTrue(empty.description.contains("14 new and 3 revised paragraphs"),
                      "got: \(empty.description)")
    }

    /// A run in flight for a DIFFERENT document does not read as "running"
    /// here — this pane is scoped to one document, and `.running` for another
    /// doc must fall through to whatever the last-run record says.
    func test_headerState_runningAnotherDocFallsThroughToLastRun() {
        let run = makeRun()
        let state = CheckNarrative.headerState(
            runState: .running(docId: "other-doc", kind: .check, checking: counts(new: 2, revised: 0)),
            lastRun: run, noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .clean(lastRun: run))
    }

    // MARK: - Each loop shows its own run (#77 F7)

    /// **A ROUND on this piece is not a check** (#77 F7, the controller's
    /// symmetric half of Denver's ruling). The header keeps its own state —
    /// the last check — and says one line about the round holding the
    /// window's one session.
    func test_theDiagnosticsHeaderSaysARoundIsRunning() {
        let run = makeRun()
        let round = CompilerOrchestrator.RunState.running(
            docId: "d1", kind: .round, checking: counts(new: 9, revised: 0))
        let state = CheckNarrative.headerState(
            runState: round, lastRun: run, noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .clean(lastRun: run),
                       "a round's run must not read as this pane's check")
        XCTAssertEqual(CheckNarrative.otherLoopLine(runState: round, docId: "d1"),
                       "A round is running \u{2014} \u{2318}R waits until it finishes.")
        XCTAssertEqual(CheckNarrative.roundIsRunningLine,
                       "A round is running \u{2014} \u{2318}R waits until it finishes.")
        XCTAssertTrue(CheckNarrative.offersCancel(
            state: state, otherLoopLine: CheckNarrative.otherLoopLine(runState: round, docId: "d1")),
            "the writer may stop the round from here (#77 F7 review ruling)")
        XCTAssertFalse(CheckNarrative.offersCancel(state: state, otherLoopLine: nil),
                       "control: a header with no run in flight offers no Cancel")
        XCTAssertTrue(CheckNarrative.offersCancel(
            state: .running(checking: counts(new: 1, revised: 0), since: nil, progress: nil),
            otherLoopLine: nil), "control: the pane's own check still offers Cancel")
        XCTAssertNil(CheckNarrative.otherLoopLine(
            runState: .running(docId: "d1", kind: .check, checking: counts(new: 1, revised: 0)),
            docId: "d1"), "the pane's own check draws its own line, not the other loop's")
        XCTAssertNil(CheckNarrative.otherLoopLine(runState: .idle, docId: "d1"))
    }

    /// **The other loop's line is WINDOW-wide** (#77 F7 review ruling): the
    /// session is the window's, so ⌘R on this document is refused while a
    /// round reads another one. The pane's OWN check still matches by document.
    func test_theHeaderNamesARoundOnAnyDocument() {
        let roundOnA = CompilerOrchestrator.RunState.running(
            docId: "doc-a", kind: .round, checking: counts(new: 3, revised: 0))
        XCTAssertEqual(CheckNarrative.otherLoopLine(runState: roundOnA, docId: "doc-b"),
                       "A round is running \u{2014} \u{2318}R waits until it finishes.")
        let run = makeRun()
        let checkOnA = CompilerOrchestrator.RunState.running(
            docId: "doc-a", kind: .check, checking: counts(new: 3, revised: 0))
        XCTAssertEqual(
            CheckNarrative.headerState(runState: checkOnA, lastRun: run,
                                        noteCount: 0, docId: "doc-b"),
            .clean(lastRun: run),
            "control: the pane's OWN check still matches by document")
        // **Flipped by #83:** the check on A holds the window's one session,
        // so ⌘R on B waits \u{2014} and the header says whose run it waits for.
        XCTAssertEqual(
            CheckNarrative.otherLoopLine(runState: checkOnA, docId: "doc-b",
                                          titleOf: { $0 == "doc-a" ? "The Ferry" : nil }),
            "A check is running on \u{201C}The Ferry\u{201D} \u{2014} \u{2318}R waits until it finishes.")
    }

    /// **A check on another piece is named, and ⌘R waits** (#83). Cancel is
    /// offered, Reread and the cold-start Read are refused up front, and the
    /// pane's own state is still the last check here.
    func test_theHeaderNamesAuthorsCheckOnAnotherPiece() {
        let run = makeRun()
        let checkOnA = CompilerOrchestrator.RunState.running(
            docId: "doc-a", kind: .check, checking: counts(new: 3, revised: 0))
        let state = CheckNarrative.headerState(
            runState: checkOnA, lastRun: run, noteCount: 2, docId: "doc-b")
        XCTAssertEqual(state, .idle(lastRun: run), "the pane keeps its own last check")
        let line = CheckNarrative.otherLoopLine(
            runState: checkOnA, docId: "doc-b", titleOf: { _ in "The Ferry" })
        XCTAssertNotNil(line)
        XCTAssertTrue(CheckNarrative.offersCancel(state: state, otherLoopLine: line),
                      "Cancel stops the one session's check, wherever it reads")
        XCTAssertTrue(CheckNarrative.refusesColdStartRead(otherLoopLine: line),
                      "the cold-start Read is refused up front, not on press")
        XCTAssertFalse(CheckNarrative.refusesColdStartRead(otherLoopLine: nil),
                       "control: with nothing in flight the cold-start Read is live")
        XCTAssertTrue(CheckNarrative.refusesColdStartRead(
            otherLoopLine: CheckNarrative.otherLoopLine(
                runState: .running(docId: "doc-a", kind: .round,
                                   checking: counts(new: 1, revised: 0)),
                docId: "doc-b")),
            "a round anywhere refuses the cold-start Read too")
    }

    /// **No title, no id** (#83 ruling).
    func test_theHeaderSaysAnotherPieceWhenTheTitleIsUnknown() {
        let checkOnA = CompilerOrchestrator.RunState.running(
            docId: "doc-a", kind: .check, checking: counts(new: 3, revised: 0))
        let line = CheckNarrative.otherLoopLine(runState: checkOnA, docId: "doc-b")
        XCTAssertEqual(line, "A check is running on another piece \u{2014} \u{2318}R waits until it finishes.")
        XCTAssertFalse(line?.contains("doc-a") ?? true, "the raw id is never shown")
    }

    /// **The same document still shows its own check running** (#83 control):
    /// no other-loop line, and the header reads `.running`.
    func test_thisDocumentsCheckStillReadsAsRunning() {
        let checkHere = CompilerOrchestrator.RunState.running(
            docId: "doc-b", kind: .check, checking: counts(new: 3, revised: 0))
        XCTAssertNil(CheckNarrative.otherLoopLine(
            runState: checkHere, docId: "doc-b", titleOf: { _ in "Should not be asked" }))
        guard case .running = CheckNarrative.headerState(
            runState: checkHere, lastRun: makeRun(), noteCount: 0, docId: "doc-b")
        else { return XCTFail("this piece's own check reads as running") }
    }

    /// **A round that died is Review's failure, not a check's** (#77 F7).
    func test_aRoundsFailureIsNotACheckFailure() {
        let run = makeRun()
        let state = CheckNarrative.headerState(
            runState: .failed(docId: "d1", kind: .round, failure: .timedOut(), at: Date()),
            lastRun: run, noteCount: 2, docId: "d1")
        XCTAssertEqual(state, .idle(lastRun: run))
        let nothing = CheckNarrative.headerState(
            runState: .nothingNew(docId: "d1", kind: .round, at: Date()),
            lastRun: run, noteCount: 2, docId: "d1")
        XCTAssertEqual(nothing, .idle(lastRun: run),
                       "a round over an empty piece is not 'Nothing new since the last check.'")
    }

    func test_headerState_nothingNew() {
        let at = Date()
        let state = CheckNarrative.headerState(
            runState: .nothingNew(docId: "d1", kind: .check, at: at), lastRun: makeRun(),
            noteCount: 3, docId: "d1")
        XCTAssertEqual(state, .nothingNew(at: at))
    }

    /// "Nothing new since the last check." is a claim about ONE document. Said
    /// over another one it describes a check that document never had — and it
    /// stands until the next run, because nothing else moves the run state.
    func test_headerState_nothingNewForAnotherDocFallsThroughToLastRun() {
        let run = makeRun()
        let state = CheckNarrative.headerState(
            runState: .nothingNew(docId: "other-doc", kind: .check, at: Date()), lastRun: run,
            noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .clean(lastRun: run),
            "another document's empty delta must not speak for this one")
    }

    /// The same leak, at its worst: chapter 1's check dies, the writer clicks
    /// chapter 2, and a red failure line is painted over chapter 2's perfectly
    /// good notes.
    func test_headerState_failedForAnotherDocFallsThroughToLastRun() {
        let run = makeRun()
        let state = CheckNarrative.headerState(
            runState: .failed(docId: "doc-a", kind: .check, failure: .cliNotFound, at: Date()),
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
        let state = CheckNarrative.headerState(
            runState: .failed(docId: "d1", kind: .check, failure: .cliNotFound, at: at),
            lastRun: nil, noteCount: 0, docId: "d1")
        XCTAssertEqual(state, .failed(.cliNotFound, at: at))

        XCTAssertTrue(RoundNarrative.failureCopy(.cliNotFound).contains("Claude Code isn't installed"))
        XCTAssertTrue(RoundNarrative.failureCopy(.cliNotFound).contains("Settings"))
        XCTAssertTrue(RoundNarrative.failureCopy(.disabledByToggle).contains("Claude access is off in Settings"))
        XCTAssertTrue(RoundNarrative.failureCopy(.disabledByToggle)
            .contains("Allow Claude to connect (MCP)"),
            "the copy must name the exact Settings toggle (General \u{2192} Claude integration), "
            + "not a paraphrase a writer cannot find")
        XCTAssertFalse(RoundNarrative.failureCopy(.timedOut()).isEmpty)
        XCTAssertTrue(RoundNarrative.failureCopy(.sessionDied(detail: "the CLI exited"))
            .contains("the CLI exited"))
        XCTAssertFalse(RoundNarrative.failureCopy(.unusableOutput).isEmpty)
    }

    func test_headerState_cleanRun() {
        let run = makeRun()
        let state = CheckNarrative.headerState(
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

    // MARK: - Streaming (Task 4)

    /// **The wait copy stays while the report grows.** The header describes the
    /// RUN, and the run is still going — a section landing must not flip it to
    /// "Last checked just now" over a check that has not finished.
    ///
    /// Pure, because that is where the decision lives: `headerState` prefers
    /// `runState` for this document over anything on disk, and a preview is on
    /// disk's side of that fence.
    func test_theWaitCopyStaysWhileSectionsLand() {
        let previewed = makeRun(clauseStatuses: [makeClause("Cold.", "strains")])

        let state = CheckNarrative.headerState(
            runState: .running(docId: "doc-1", kind: .check, checking: counts(new: 1, revised: 0)),
            lastRun: previewed, noteCount: 1, docId: "doc-1")

        XCTAssertEqual(state,
                       .running(checking: counts(new: 1, revised: 0), since: nil, progress: nil),
                       "a section arriving must not end the wait")
        XCTAssertEqual(CheckNarrative.headerCopy(for: state, annotations: [], passes: []), "Checking 1 new paragraph\u{2026}")
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
        runner.nextEvent = .failed(.timedOut())

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

    /// The unread dot's offset is derived for To resolve (shell plan 2 Task 7)
    /// from the rendered list, so it stays on To resolve when a selection is
    /// appended after it.
    func test_badgeOffset_findsToResolveAndSurvivesAnAppendedSegment() {
        let chapter = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))
        let shown = DetailPaneToggle<AnyView>.visibleSegments(subject: chapter)
        XCTAssertEqual(
            DetailPaneToggle<AnyView>.badgeOffset(of: .resolve, in: shown),
            shown.count - 1,
            "To resolve leads a chapter's picker, so its dot shifts the full width of the row")
        let withDeskAppended = DetailPaneToggle<AnyView>.visibleSegments(
            subject: chapter, including: .department)
        XCTAssertEqual(
            DetailPaneToggle<AnyView>.badgeOffset(of: .resolve, in: withDeskAppended),
            withDeskAppended.count - 1)
        XCTAssertEqual(
            DetailPaneToggle<AnyView>.badgeOffset(of: .department, in: withDeskAppended), 0,
            "the appended segment is last, so a badge on it does not shift at all")
    }

    /// **The Visual Language segment badges too** (translation pipeline P5) —
    /// a proposal waiting on the writer is exactly the "something changed
    /// while you weren't looking" signal the inbox and diagnostics badges are
    /// for. Its own offset, on the same derivation as the other two.
    func test_theVisualLanguageSegmentBadgesWhenAProposalStands() {
        XCTAssertEqual(DetailPaneToggle<AnyView>.badgeOffset(of: .visualLanguage, in: [.resolve, .intent, .visualLanguage, .inspector]), 1)
        XCTAssertTrue(DetailPaneToggle<AnyView>.visualLanguageBadgeHelp.contains("⌘⌥V"))
    }

    // MARK: - Empty state

    /// **A failed check may not wear the seal.** `checkmark.seal` over
    /// "Nothing to flag." says the compiler looked and found nothing; a run
    /// that died never looked. Each state's copy is asserted rather than
    /// falling through to a `default:`.
    func test_emptyState_neverSealsARunThatDidNotHappen() {
        let failed = CheckNarrative.emptyState(for: .failed(.cliNotFound, at: Date()), annotations: [], passes: [])
        XCTAssertNotEqual(failed.symbol, "checkmark.seal")
        XCTAssertFalse(failed.title.contains("Nothing to flag"))

        let running = CheckNarrative.emptyState(
            for: .running(checking: counts(new: 1, revised: 0), since: nil, progress: nil), annotations: [], passes: [])
        XCTAssertNotEqual(running.symbol, "checkmark.seal")
        XCTAssertFalse(running.title.contains("Nothing to flag"))

        XCTAssertEqual(CheckNarrative.emptyState(for: .neverRun, annotations: [], passes: []).title, "Not checked yet")
        XCTAssertEqual(CheckNarrative.emptyState(for: .clean(lastRun: makeRun()), annotations: [], passes: []).title,
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
        let line = CheckNarrative.headerCopy(for: .clean(lastRun: run), annotations: [], passes: [])

        XCTAssertTrue(line.contains("Nothing to flag."),
            "the run genuinely raised nothing that could be placed")
        XCTAssertTrue(
            line.contains("3 notes arrived against paragraphs that have changed "
                          + "and were discarded"),
            "got: \(line)")
        XCTAssertFalse(line.lowercased().contains("unknown paragraph"),
            "the parser's vocabulary is not the writer's, and it reads as their fault")

        let empty = CheckNarrative.emptyState(for: .clean(lastRun: run), annotations: [], passes: [])
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
        let line = CheckNarrative.headerCopy(for: .clean(lastRun: run), annotations: [], passes: [])

        XCTAssertTrue(line.hasPrefix("Nothing to flag."))
        XCTAssertFalse(line.contains("discarded"), "got: \(line)")
        XCTAssertEqual(CheckNarrative.emptyState(for: .clean(lastRun: run), annotations: [], passes: []).symbol,
                       "checkmark.seal")
    }

    /// One note is not "1 notes", and the singular is the common case.
    func test_theDiscardedSentenceCountsInTheWritersEnglish() {
        XCTAssertNil(CheckNarrative.discardedNotesSentence(0))
        XCTAssertEqual(
            CheckNarrative.discardedNotesSentence(1),
            "1 note arrived against a paragraph that has changed and was discarded")
        XCTAssertEqual(
            CheckNarrative.discardedNotesSentence(2),
            "2 notes arrived against paragraphs that have changed and were discarded")
    }

    // MARK: - The cold-start offer (Stage 3) — pure decision

    /// **The pure gate, no view mounted** — the `headerState`/`emptyState`
    /// idiom. True only when all three conditions hold at once; each
    /// assertion below flips exactly one of them.
    func test_showsColdStartOffer_trueOnlyForANeverRunNonTrivialUnrefusedDocument() {
        XCTAssertTrue(CheckNarrative.showsColdStartOffer(
            state: .neverRun, liveParagraphCount: 2, hasRefused: false))

        XCTAssertFalse(CheckNarrative.showsColdStartOffer(
            state: .neverRun, liveParagraphCount: 1, hasRefused: false),
            "a stub manuscript (\u{2264}1 live paragraph) is not worth offering to read")
        XCTAssertFalse(CheckNarrative.showsColdStartOffer(
            state: .neverRun, liveParagraphCount: 0, hasRefused: false))
        XCTAssertFalse(CheckNarrative.showsColdStartOffer(
            state: .neverRun, liveParagraphCount: 2, hasRefused: true),
            "a refused document never offers again")
        XCTAssertFalse(CheckNarrative.showsColdStartOffer(
            state: .idle(lastRun: makeRun()), liveParagraphCount: 2, hasRefused: false),
            "any run at all — even one with nothing to show — moves state off .neverRun")
        XCTAssertFalse(CheckNarrative.showsColdStartOffer(
            state: .clean(lastRun: makeRun()), liveParagraphCount: 2, hasRefused: false))
        XCTAssertFalse(CheckNarrative.showsColdStartOffer(
            state: .running(checking: counts(new: 1, revised: 0), since: nil, progress: nil),
            liveParagraphCount: 2,
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

    // MARK: - Open Intent

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
        let line = CheckNarrative.readerCopy(for: .coach(ReviewPass.coachPreset))
        XCTAssertEqual(line, "Le Guin reads this piece")
        XCTAssertFalse(line.contains("Workshop"), "got: \(line)")
    }

    func test_readerCopy_nobodyIsSignedClaude() {
        XCTAssertEqual(CheckNarrative.readerCopy(for: .nobody), "Claude reads this piece")
    }

    /// **One input, two readers.** A test constructing the pane with a coach
    /// reader gets the coach's name in both the header line and the
    /// empty-state promise; the vacated seat is the control, since it is the
    /// other arm and must agree with itself the same way.
    func test_theHeaderLineAndTheEmptyStatePromiseNameTheSameReader_coach() {
        let reader = AuthorReader.coach(ReviewPass.coachPreset)
        let header = CheckNarrative.readerCopy(for: reader)
        let empty = CheckNarrative.emptyState(for: .neverRun, readerName: reader.editorName, annotations: [], passes: [])
        XCTAssertTrue(header.contains("Le Guin"), "got: \(header)")
        XCTAssertTrue(empty.description.contains("Le Guin"), "got: \(empty.description)")
    }

    func test_theHeaderLineAndTheEmptyStatePromiseNameTheSameReader_nobody() {
        let reader = AuthorReader.nobody
        let header = CheckNarrative.readerCopy(for: reader)
        let empty = CheckNarrative.emptyState(for: .neverRun, readerName: reader.editorName, annotations: [], passes: [])
        XCTAssertTrue(header.contains("Claude"), "got: \(header)")
        XCTAssertTrue(empty.description.contains("Claude"), "got: \(empty.description)")
    }

    func test_emptyState_neverRun_promiseNamesTheGivenReader() {
        let empty = CheckNarrative.emptyState(for: .neverRun, readerName: "Le Guin", annotations: [], passes: [])
        XCTAssertEqual(empty.description, "Press \u{2318}R and Le Guin reads what you've written.")
    }

    /// **`.nobody` reads exactly as before, apart from the new line** — the
    /// pane's default `reader`, so every caller that has not been given one
    /// (and every OTHER `emptyState` test in this file, which passes no
    /// `readerName`) keeps its old behaviour.
    func test_emptyState_neverRun_defaultsToClaudeWhenNoReaderIsGiven() {
        let empty = CheckNarrative.emptyState(for: .neverRun, annotations: [], passes: [])
        XCTAssertEqual(empty.description, "Press \u{2318}R and Claude reads what you've written.")
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
            CheckNarrative.readerMenuItems(manifest: manifest(vacated: false, name: "Ursula")),
            [.coach, .firstReader, .nobody])
        XCTAssertEqual(
            CheckNarrative.readerMenuItems(manifest: manifest(vacated: true, name: "Ursula")),
            [.firstReader, .nobody])
        XCTAssertEqual(
            CheckNarrative.readerMenuItems(manifest: manifest(vacated: false, name: nil)),
            [.coach, .nobody])
        XCTAssertEqual(
            CheckNarrative.readerMenuItems(manifest: manifest(vacated: true, name: nil)),
            [.nobody],
            "nobody is the one choice with no premise to lose")

        // A name that is only whitespace is no name — a hand-edited
        // `project.json` is a writer of this field too.
        XCTAssertEqual(
            CheckNarrative.readerMenuItems(manifest: manifest(vacated: true, name: "   ")),
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
            CheckNarrative.readerMenuTitle(.coach, manifest: manifest), "Le Guin")
        XCTAssertEqual(
            CheckNarrative.readerMenuTitle(.firstReader, manifest: manifest), "Ursula")
        XCTAssertEqual(
            CheckNarrative.readerMenuTitle(.nobody, manifest: manifest), "Claude")
    }

    /// The checkmark follows whoever RESOLVED, not the stored choice: a choice
    /// whose subject has gone falls back to the default rule, and a mark beside
    /// a reader who is not reading would contradict the line above it.
    func test_resolvedChoice_marksTheArmTheReaderActuallyIs() {
        XCTAssertEqual(
            CheckNarrative.resolvedChoice(for: .coach(ReviewPass.coachPreset)), .coach)
        XCTAssertEqual(
            CheckNarrative.resolvedChoice(
                for: .firstReader(FirstReader(name: "Ursula", statement: nil))),
            .firstReader)
        XCTAssertEqual(CheckNarrative.resolvedChoice(for: .nobody), .nobody)
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
        let source = try Self.source(of: "Views/DiagnosticsPaneHeader.swift")
        let menu = try XCTUnwrap(
            Self.declaration(named: "private var readerMenu: some View {", in: source),
            "the header must carry a readable reader menu for this census to "
            + "have a subject")

        XCTAssertTrue(menu.contains("onChooseReader(candidate)"),
                      "each reader item writes the choice. Got:\n\(menu)")
        XCTAssertTrue(menu.contains("CheckNarrative.defineFirstReaderTitle")
                      || menu.contains("Self.defineFirstReaderTitle"),
                      "the define item draws the shared title. Got:\n\(menu)")
        XCTAssertTrue(menu.contains("onOpenProjectSettings()"),
                      "\u{2026}and it opens Project Settings, which is where "
                      + "her name is typed. Got:\n\(menu)")
        XCTAssertFalse(menu.contains("postDetailSegment("),
                       "\u{2026}and it opens no other pane either. Got:\n\(menu)")

        // The define item stands only while she is unnamed: once she has a
        // name her own row is in the list above, and a second door to Settings
        // beneath it would be an offer to define somebody already defined.
        XCTAssertTrue(menu.contains("if !CheckNarrative.hasFirstReader(manifest) {"),
                      "Got:\n\(menu)")
    }

    /// **Project Settings is opened from exactly one place** — counted across
    /// every view, so a second opener in a sibling is caught. That the header
    /// is given the CHOSEN reader and both verbs (the pane defaults them to
    /// `.nobody` and no-ops, which no assertion on values can see) is
    /// `WiringCensusTests`' entry for `DetailPaneToggle.diagnosticsPane`.
    func test_projectSettingsHasOneOpener() throws {
        XCTAssertEqual(
            try Self.projectSettingsOpeners(), 1,
            "Project Settings is opened from exactly one place — counted across "
            + "every view, so a second opener in a sibling is caught")
    }

    // MARK: - The Describe… hand-off (fix round 1)

    /// **A dismissal hands the writer on only when Project Settings is what
    /// closed.**
    ///
    /// The request is set by one sheet's button, and
    /// `.sheet(item:onDismiss:)` fires the same callback for all three of this
    /// window's sheets. The first fix guarded on the request alone: after the
    /// race it was written for — Escape while `describeFirstReader`'s two
    /// awaits are in flight — the next translator's-note or Claude Desktop
    /// sheet the writer closed jumped the right column to her statement.
    ///
    /// PLANTED REVERT: `requested: true` with a foreign sheet is the exact
    /// input the old guard answered true for, and it is asserted false here.
    func test_opensFirstReader_onlyForProjectSettingsOwnDismissal() {
        XCTAssertTrue(ProjectWindow.opensFirstReader(
            requested: true, dismissed: .projectSettings))

        XCTAssertFalse(ProjectWindow.opensFirstReader(
            requested: true, dismissed: .claudeDesktop),
            "a Claude Desktop dismissal is not her door")
        XCTAssertFalse(ProjectWindow.opensFirstReader(
            requested: true, dismissed: nil),
            "\u{2026}nor is a dismissal with nothing recorded")

        XCTAssertFalse(ProjectWindow.opensFirstReader(
            requested: false, dismissed: .projectSettings),
            "control: closing Project Settings without pressing Describe\u{2026} "
            + "hands the writer nowhere")
    }

    /// **And a stale request dies at the next presentation**, which is the
    /// other half: without it the flag survives with no sheet on screen and
    /// the guard above only narrows which dismissal it fires at. Driven
    /// through `FirstReaderHandoff`, the value the window holds and calls from
    /// its `activeSheet` change, its Describe\u{2026} closure and its
    /// `onDismiss` (those three calls are `WiringCensusTests`' entry for
    /// `ProjectWindow`).
    func test_everySheetPresentationClearsAStaleHandoff() {
        // The race the guard was written for: Describe… lands after Escape
        // closed Project Settings, and the next sheet up is a foreign one.
        var handoff = FirstReaderHandoff()
        handoff.sheetPresented(.projectSettings)
        XCTAssertFalse(handoff.sheetDismissed(), "Escape: nothing was requested")
        handoff.describeRequested()
        handoff.sheetPresented(.claudeDesktop)
        XCTAssertFalse(handoff.requested, "a presentation clears the stale request")
        XCTAssertFalse(handoff.sheetDismissed(),
                       "closing Claude Desktop does not hand the writer on")

        // …and a stale request does not survive into Project Settings' next
        // presentation either: it has to be pressed again in THAT sheet.
        handoff.describeRequested()
        handoff.sheetPresented(.projectSettings)
        XCTAssertFalse(handoff.sheetDismissed(),
                       "a request from before this presentation is not this sheet's")
    }

    /// The hand-off's own path: pressed in Project Settings, acted on at its
    /// dismissal, once.
    func test_aDescribePressInProjectSettingsHandsOnAtItsDismissalOnce() {
        var handoff = FirstReaderHandoff()
        handoff.sheetPresented(.projectSettings)
        handoff.describeRequested()
        handoff.sheetPresented(nil)   // `activeSheet` going nil is not a presentation
        XCTAssertTrue(handoff.requested, "a nil change clears nothing")
        XCTAssertTrue(handoff.sheetDismissed(), "Project Settings closed after Describe\u{2026}")
        XCTAssertEqual(handoff, FirstReaderHandoff(), "the dismissal spends the request and the sheet")
        XCTAssertFalse(handoff.sheetDismissed(), "\u{2026}so a second dismissal hands nobody on")
    }

    // MARK: - Reread (two loops P1 Task 7)

    /// **Reread posts ⇧⌘R's own command, and nothing else** (shell plan 2
    /// Task 5: one delivery path).
    ///
    /// It used to call `runRequested(docId:kind:.check, freshEyes: true)`
    /// itself and a press test pinned that call. The button now posts
    /// `RunCommand.reread` through `MaughamEvent`, so the window runs its open
    /// piece and answers a piece it cannot open; what `.reread` asks for (a
    /// cold check, never a round) is `CompilerRunCommandTests`' and the
    /// `CompilerRunModifier` entry in `WiringCensusTests`. A census, so
    /// nothing is pressed and waited on (tripwire 33).
    func test_theRereadButtonPostsTheRereadCommand() throws {
        let source = try Self.source(of: "Views/DiagnosticsPaneHeader.swift")
        let code = SourceScan.codeLines(of: source).joined(separator: "\n")
        let button = try XCTUnwrap(
            code.range(of: "Button(CheckNarrative.rereadTitle) {"),
            "Reread must still be a button")
        let action = String(code[button.upperBound...].prefix(80))
        XCTAssertTrue(action.contains("MaughamEvent.postRun(.reread)"),
                      "Reread posts the cold check's command. Got: \(action)")
        XCTAssertFalse(code.contains("runRequested("),
                       "and the header calls the orchestrator no other way")
        XCTAssertEqual(RunCommand.reread.kind, .check)
        XCTAssertTrue(RunCommand.reread.isFreshEyes)
    }

    /// Every append the Reread press makes, in order. A reference box because
    /// `Environment`'s closures are stored rather than captured-by-inout.
    @MainActor
    private final class RunRequests {
        var readings: [String] = []
        var roundEditorAsks: [String] = []
        var acknowledgments: [CompilerOrchestrator.Acknowledgment] = []
    }

    // MARK: - Drift (spec §4's last bullet, computed in Stage 3 by `DriftDetector`)
    //
    // `DriftDetector.drift` has its own suite (`DriftDetectorTests`) for
    // whether a finding fires; these pin what the PANE says once one does,
    // and that the line behaves as the register requires — not a `Diagnostic`.

    func test_driftNote_isNilWithNoFindings() {
        XCTAssertNil(CheckNarrative.driftNote([]))
    }

    func test_driftNote_formatsTheRegisterVerbatim() {
        let finding = DriftFinding(clauseQuote: "Cold, and never wistful.", runsStraining: 3)
        XCTAssertEqual(
            CheckNarrative.driftNote([finding]),
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
        guard let line = CheckNarrative.driftNote([finding]) else {
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

        let two = CheckNarrative.driftNote([first, second])
        XCTAssertEqual(
            two,
            "Your line may have moved \u{2014} \u{201C}Cold, and never wistful.\u{201D} has "
            + "strained three runs running \u{2014} and one more. Draft\u{2019}s right, "
            + "or intent\u{2019}s right?")

        let three = CheckNarrative.driftNote([first, second, third])
        XCTAssertEqual(two, three,
            "the line reads the same for two findings and for three \u{2014} \u{201C}and "
            + "one more\u{201D} must never become \u{201C}and 2 more\u{201D}")
        XCTAssertFalse(three?.contains("Kelly") ?? true,
                       "only the first finding's clause is ever quoted")
    }

    func test_truncatedDriftQuote_fitsAsIs() {
        XCTAssertEqual(CheckNarrative.truncatedDriftQuote("Cold, and never wistful."),
                       "Cold, and never wistful.")
    }

    /// `IntentStrip.truncated`'s idiom: cut at the last word boundary inside
    /// the budget, ellipsised — never mid-word, and never a trailing space
    /// left dangling before the ellipsis.
    func test_truncatedDriftQuote_cutsOnAWordBoundaryAndEllipsises() {
        let long = "Kelly never speaks first, not once, not even when the silence "
            + "would have been the crueler thing to let stand between them."
        let truncated = CheckNarrative.truncatedDriftQuote(long)

        XCTAssertTrue(truncated.hasSuffix("\u{2026}"), "got: \(truncated)")
        XCTAssertLessThan(truncated.count, long.count, "control: it actually cut something")
        let withoutEllipsis = String(truncated.dropLast())
        XCTAssertFalse(withoutEllipsis.hasSuffix(" "),
                       "trimmed before the ellipsis, not left with a trailing space")
        XCTAssertTrue(long.hasPrefix(withoutEllipsis),
                      "the cut is a true prefix of the source \u{2014} a word boundary, not "
                      + "a mid-word chop")
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
        XCTAssertEqual(CheckNarrative.paragraphToNavigateTo(for: anchored), "abcd")

        // The schema's own escape hatch: a note about the delta rather than one
        // paragraph. It renders in its kind's section like any other and has
        // nothing to jump to.
        let anchorless = makeDiagnostic(docId: "d1", anchor: nil)
        XCTAssertNil(CheckNarrative.paragraphToNavigateTo(for: anchorless))
    }

    func test_jump_postsTheSameEventAnnotationsRowUses() throws {
        // A finding's chip goes through To resolve's one navigation (shell
        // plan 2 Task 7): the row event, with the finding's piece and the
        // chip's paragraph.
        let source = try readSource("Maugham/Views/Resolve/ResolveNavigation.swift")
        XCTAssertTrue(source.contains(".maughamNavigateToParagraph"),
                     "the check's jump must reuse the row navigation event, not a copy")
        XCTAssertTrue(source.contains(#"static let paragraphIdKey = "paragraph_id""#))
        let pane = try readSource("Maugham/Views/Resolve/ResolvePane.swift")
        XCTAssertTrue(pane.contains("onJump: { ResolveNavigation.go(toDocId: docId, paragraphId: $0) }"))
    }

    // MARK: - The conformance summary (spec §5's first section)

    /// The same rule at the source, where every sentence is assertable without
    /// a mount — and the one-note wording, which a mounted test would only
    /// reach by rendering a second pane.
    func test_theCleanCopyDefersToWhatWentToTheQueue() {
        let queued = makeRun(mintedNotes: 1)
        XCTAssertTrue(
            CheckNarrative.headerCopy(for: .clean(lastRun: queued), annotations: [], passes: [])
                .hasPrefix("1 note went to your queue."),
            CheckNarrative.headerCopy(for: .clean(lastRun: queued), annotations: [], passes: []))
        XCTAssertFalse(
            CheckNarrative.headerCopy(for: .clean(lastRun: queued), annotations: [], passes: [])
                .contains("Nothing to flag"))
        XCTAssertEqual(
            CheckNarrative.emptyState(for: .clean(lastRun: queued), annotations: [], passes: []).title,
            "Notes in your queue")

        // Zero and nil both mean "nothing went anywhere", and neither may
        // invent a sentence claiming a count.
        for nothing in [makeRun(mintedNotes: 0), makeRun()] {
            XCTAssertTrue(
                CheckNarrative.headerCopy(for: .clean(lastRun: nothing), annotations: [], passes: [])
                    .hasPrefix("Nothing to flag."),
                "a run that queued nothing must still be allowed to say so")
            XCTAssertEqual(
                CheckNarrative.emptyState(for: .clean(lastRun: nothing), annotations: [], passes: []).symbol,
                "checkmark.seal")
        }
        XCTAssertNil(CheckNarrative.queuedNotesSentence(nil))
        XCTAssertNil(CheckNarrative.queuedNotesSentence(0))
    }

    /// A run can both queue notes AND lose some, and the queued ones are the
    /// news — the discard is the footnote it has always been.
    func test_theQueuedSentenceOutranksTheDiscardFootnote() {
        let both = makeRun(droppedDangling: 2, mintedNotes: 3)
        let header = CheckNarrative.headerCopy(for: .clean(lastRun: both), annotations: [], passes: [])
        XCTAssertTrue(header.hasPrefix("3 notes went to your queue."), header)
        XCTAssertTrue(header.contains("were discarded"), header)
        XCTAssertEqual(
            CheckNarrative.emptyState(for: .clean(lastRun: both), annotations: [], passes: []).title,
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
        let header = CheckNarrative.headerCopy(for: .clean(lastRun: elsewhere), annotations: [], passes: [])
        XCTAssertTrue(header.hasPrefix("Nothing new to flag."), header)

        let empty = CheckNarrative.emptyState(for: .clean(lastRun: elsewhere), annotations: [], passes: [])
        XCTAssertEqual(empty.title, "Nothing new to flag.")
        XCTAssertTrue(
            empty.description.contains(
                "was already open in another pass's queue"),
            empty.description)
        XCTAssertFalse(empty.description.contains("found nothing to raise"),
                       "the seal's own sentence stood under the new title: "
                       + empty.description)

        // Plural, from the one helper both wordings live in.
        let many = CheckNarrative.emptyState(for: .clean(lastRun: makeRun(openInOtherLanes: 2)), annotations: [], passes: [])
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
                CheckNarrative.headerCopy(for: .clean(lastRun: quiet), annotations: [], passes: [])
                    .hasPrefix("Nothing to flag."),
                CheckNarrative.headerCopy(for: .clean(lastRun: quiet), annotations: [], passes: []))
            let empty = CheckNarrative.emptyState(for: .clean(lastRun: quiet), annotations: [], passes: [])
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
            CheckNarrative.headerCopy(for: .clean(lastRun: both), annotations: [], passes: [])
                .hasPrefix("2 notes went to your queue."),
            CheckNarrative.headerCopy(for: .clean(lastRun: both), annotations: [], passes: []))
        XCTAssertEqual(
            CheckNarrative.emptyState(for: .clean(lastRun: both), annotations: [], passes: []).title,
            "Notes in your queue")
    }

    /// **Wet ink outranks it as well**, on the arm's own rule: under
    /// `.showing` / `.settled` this run's notes are on screen beneath the
    /// header, and that arm exists precisely so the copy does not send the
    /// writer somewhere else for what is right there.
    func test_theCrossLaneClauseYieldsToWetInk() {
        let elsewhere = makeRun(openInOtherLanes: 1)
        for ink in [CheckNarrative.WetInk.showing, .settled] {
            XCTAssertTrue(
                CheckNarrative.headerCopy(for: .clean(lastRun: elsewhere), wetInk: ink, annotations: [], passes: [])
                    .hasPrefix("Nothing to flag."),
                CheckNarrative.headerCopy(for: .clean(lastRun: elsewhere), wetInk: ink, annotations: [], passes: []))
        }
    }

    /// **The seal arm reads the since-line's live projection** (#53). A check
    /// whose finding is still open in Structural names it; once the writer
    /// settles that note, the same stored run gets its seal back — the header
    /// and the empty state agreeing, on every render.
    func test_theCrossLaneSealArmIsLiveAndNamesThePass() {
        let run = makeRun(openInOtherLanes: 1, openInOtherLanesNoteIds: ["n-1"])
        func note(_ status: AnnotationStatus) -> Annotation {
            Annotation(
                id: "n-1", kind: .query, paragraphId: "a1b2", body: "How long?",
                suggestedText: nil, priorText: nil, createdAt: Date(timeIntervalSince1970: 1),
                createdBySession: nil, status: status, userResponse: nil, resolvedAt: nil,
                isStale: false, reviewPassId: "structural", compilerRunId: "run-0",
                compilerRound: 1, compilerFingerprint: "f-1")
        }
        let passes = ReviewPass.presets

        let open = [note(.open)]
        XCTAssertTrue(
            CheckNarrative.headerCopy(for: .clean(lastRun: run),
                                       annotations: open, passes: passes)
                .hasPrefix("Nothing new to flag."))
        let held = CheckNarrative.emptyState(
            for: .clean(lastRun: run), annotations: open, passes: passes)
        XCTAssertEqual(held.title, "Nothing new to flag.")
        XCTAssertTrue(
            held.description.hasPrefix(
                "1 finding it raised is still open in Structural."),
            held.description)

        let settled = [note(.stetted)]
        XCTAssertTrue(
            CheckNarrative.headerCopy(for: .clean(lastRun: run),
                                       annotations: settled, passes: passes)
                .hasPrefix("Nothing to flag."))
        let sealed = CheckNarrative.emptyState(
            for: .clean(lastRun: run), annotations: settled, passes: passes)
        XCTAssertEqual(sealed.title, "Nothing to flag.")
        XCTAssertEqual(sealed.symbol, "checkmark.seal")
    }

    /// **A queue the pane cannot see is not an empty queue** (#53 final
    /// review). With no matching document — none open, or a newly selected
    /// piece still loading — the pane passes `nil`, and a new run's held
    /// finding keeps the stored count's past-tense sentence rather than the
    /// seal: `[]` would have filtered its ids to nothing and affirmed "Nothing
    /// to flag." over a finding the writer is holding elsewhere.
    func test_anUnseenQueueKeepsTheStoredCountInsteadOfTheSeal() {
        let run = makeRun(openInOtherLanes: 1, openInOtherLanesNoteIds: ["n-1"])
        let passes = ReviewPass.presets

        XCTAssertTrue(
            CheckNarrative.headerCopy(for: .clean(lastRun: run),
                                       annotations: nil, passes: passes)
                .hasPrefix("Nothing new to flag."))
        let unseen = CheckNarrative.emptyState(
            for: .clean(lastRun: run), annotations: nil, passes: passes)
        XCTAssertEqual(unseen.title, "Nothing new to flag.")
        XCTAssertEqual(unseen.symbol, "tray.full")
        XCTAssertTrue(
            unseen.description.hasPrefix(
                "What this check raised was already open in another pass's queue."),
            unseen.description)

        // The contrast that makes `nil` load-bearing: an empty, VISIBLE queue
        // is a settled one, and the seal is right there.
        XCTAssertEqual(
            CheckNarrative.emptyState(
                for: .clean(lastRun: run), annotations: [], passes: passes).symbol,
            "checkmark.seal")
    }

    // MARK: - Excerpt chips (requirement 3)

    // MARK: - Tripwire 15

    // `test_everyContentUnavailableViewChainsFullFrame` retired with the
    // Diagnostics pane (shell plan 2 Task 7): the check's surface draws no
    // empty state of its own; tripwire 15 is `TripwireGrepTests`' global census.

    // MARK: - Registry wiring

    /// To resolve leads the picker whatever the subject (shell plan 2 Task 7;
    /// the Diagnostics pane it replaced led a piece's only).
    func test_toResolveLeadsEveryPicker() {
        let chapter = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))
        XCTAssertEqual(DetailPaneToggle<AnyView>.visibleSegments(subject: chapter).first, .resolve)
        XCTAssertEqual(DetailPaneToggle<AnyView>.visibleSegments(subject: .book).first, .resolve)
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
        XCTAssertTrue(CheckNarrative.offersAnAnswer(
            makeDiagnostic(docId: "d1", kind: .conformanceStrain)))
        XCTAssertFalse(CheckNarrative.offersAnAnswer(
            makeDiagnostic(docId: "d1", kind: .continuity)))
        XCTAssertFalse(CheckNarrative.offersAnAnswer(
            makeDiagnostic(docId: "d1", kind: .readerReport)))
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
        let failure = await CheckNarrative.commitAnswer(
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

        _ = await CheckNarrative.commitAnswer(
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
            CheckNarrative.answeredNoteProvenance(for: note),
            "answered a compiler note: \u{00AB}the dread stays unnamed\u{00BB}")
    }

    /// A clause quote past the 60-character budget is cut at a word boundary
    /// and ellipsised — `truncatedDriftQuote`'s own idiom, restated for the
    /// same reason the drift line already restates it.
    func test_answeredNoteProvenance_longQuoteTruncatedWithEllipsis() {
        let quote = "The fog came in off the water and stayed for three days "
            + "without once naming what it was hiding."
        let note = makeDiagnostic(docId: "d1", kind: .conformanceStrain, clauseQuote: quote)

        let provenance = CheckNarrative.answeredNoteProvenance(for: note)

        XCTAssertTrue(provenance.contains("\u{2026}"),
                      "over budget, so the excerpt must be marked as cut")
        XCTAssertEqual(
            provenance,
            "answered a compiler note: \u{00AB}"
                + CheckNarrative.truncatedDriftQuote(quote) + "\u{00BB}",
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

        let provenance = CheckNarrative.answeredNoteProvenance(for: note)

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
            CheckNarrative.answeredNoteProvenance(for: note), "answered a compiler note")
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
        let failure = await CheckNarrative.commitAnswer(
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
            ruling.provenance, CheckNarrative.answeredNoteProvenance(for: note),
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

        let failure = await CheckNarrative.commitAnswer(
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

        let failure = await CheckNarrative.commitAnswer(
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
        // The field is `DiagnosticRow`'s, the commit the pane's own `answer`.
        let source = try DiagnosticsPaneSource.surfaceSource()
        XCTAssertTrue(
            source.contains(".onSubmit { commit() }"),
            "return must commit the answer \u{2014} a field with no submit verb is a "
            + "box the writer types into and cannot send")
        XCTAssertTrue(
            source.contains(".onExitCommand { cancel() }"),
            "escape must take the field away without writing anything")
        XCTAssertTrue(
            try AnnotationsPaneSource.surfaceSource().contains("CheckNarrative.commitAnswer("),
            "and To resolve must go through the one function the tests above drive \u{2014} "
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
        XCTAssertFalse(CheckNarrative.offersDurableActions(
            state: .running(checking: counts(new: 1, revised: 0), since: nil, progress: nil)))
        XCTAssertTrue(CheckNarrative.offersDurableActions(state: .neverRun))
        XCTAssertTrue(CheckNarrative.offersDurableActions(state: .idle(lastRun: run)))
        XCTAssertTrue(CheckNarrative.offersDurableActions(state: .clean(lastRun: run)))
        XCTAssertTrue(CheckNarrative.offersDurableActions(state: .nothingNew(at: Date())),
                      "a run that found nothing is over \u{2014} what stands is the last "
                      + "finished report, and it is answerable")
        XCTAssertTrue(CheckNarrative.offersDurableActions(
            state: .failed(.timedOut(), at: Date())),
                      "a run that died never replaced anything, so the previous run's "
                      + "notes must not be frozen behind it")
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
    // whole tempo is wet ink — was left with a count ("3 notes went to
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
    /// non-throwing, so a caller can ask after a note that may have left.
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

    /// ⌘Z reaches the decline through the undo manager the verb is handed —
    /// the annotation layer's existing machinery, wired rather than
    /// reimplemented. Windowless (#120, tripwire 33): the pane hands the verb
    /// its own `undoManager` (`WiringCensusTests`, `type:DiagnosticsPane`), and
    /// the undo's async hop is awaited through `awaitPendingUndoWork`, not
    /// polled.
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

        let undoManager = UndoManager()
        let failure = await CheckNarrative.notThis(
            annotationId: noteId, in: document, undoManager: undoManager)
        XCTAssertNil(failure, "control: the decline landed")
        XCTAssertEqual(try status(of: noteId, in: document), .rejected,
                       "control: the decline landed")

        XCTAssertTrue(undoManager.canUndo,
                      "the decline registered no undo action at all")
        undoManager.undo()
        await document.awaitPendingUndoWork()

        XCTAssertEqual(try status(of: noteId, in: document), .open,
                       "\u{2318}Z after Not this must reopen the note")
    }

    // MARK: - The order, the room, and what the copy may claim (review fixes)

    /// The standing, pure — including the case that keeps the historical
    /// sentence honest: a pane with no document behind it cannot see the
    /// queue, so an empty view means "cannot tell", never "handled".
    func test_wetInkStanding_readsTheThreeCasesApart() {
        XCTAssertEqual(
            CheckNarrative.wetInkStanding(mintedNotes: 2, queueVisible: true, openNow: 2),
            .showing)
        XCTAssertEqual(
            CheckNarrative.wetInkStanding(mintedNotes: 2, queueVisible: true, openNow: 0),
            .settled)
        XCTAssertEqual(
            CheckNarrative.wetInkStanding(mintedNotes: 2, queueVisible: false, openNow: 0),
            .none,
            "with no queue to read, the run's own record is the only honest thing "
            + "to say")
        XCTAssertEqual(
            CheckNarrative.wetInkStanding(mintedNotes: 0, queueVisible: true, openNow: 0),
            .none)
        XCTAssertEqual(
            CheckNarrative.wetInkStanding(mintedNotes: nil, queueVisible: true, openNow: 0),
            .none,
            "a preview and a pre-P1 record both know nothing about a mint")
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

    /// CONTROL for the census above: the HEADER line is deliberately NOT
    /// guarded. "Le Guin reads this piece" and the empty state's "Press ⌘R
    /// and … reads what you've written." are promises about the NEXT run, so
    /// they must move the moment the writer changes the roster — which is the
    /// opposite of the rule for a letter that has already been written.
    func test_control_theHeaderLineStaysOnTheLiveReader() throws {
        let source = try readSource("Maugham/Views/DiagnosticsPaneHeader.swift")
        XCTAssertTrue(
            source.contains(#"static func readerCopy(for reader: AuthorReader) -> String {"#),
            "find the header's copy by name if it moved")
        XCTAssertTrue(
            source.contains(#""\(reader.editorName) reads this piece""#),
            "the header names who WILL read, so it reads the live reader")
    }

    /// **The census the behavioural tests cannot make**: both hosts decide and
    /// write the offer through the ONE builder, and neither re-spells the
    /// predicate. A host keeping its own copy would pass every behavioural
    /// test above that mounts it once, and drift silently afterwards.
    func test_bothHostsDecideTheOfferThroughTheOneBuilder() throws {
        for path in [Self.resolveHeadPath] {  // the one letter host, both loops (shell plan 2 Task 7)
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

    // MARK: - Ask about… (P2 Task 7, spec §3.7)

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
        for path in [Self.resolveHeadPath] {  // the one letter host, both loops (shell plan 2 Task 7)
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

    /// **Neither host spells a ledger write.** All three presses are built by
    /// `LessonOffer.handlers`, so the provenance, the date and the refusal
    /// channel cannot come out different in Author than in Review — a
    /// difference that would be invisible until a writer read their ledger
    /// months later.
    func test_bothHostsTakeTheLedgerVerbsFromTheOneBuilder() throws {
        for path in [Self.resolveHeadPath] {  // the one letter host, both loops (shell plan 2 Task 7)
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

    /// `activeSheet = .projectSettings` as code across every file under
    /// `Maugham/Views`.
    private static func projectSettingsOpeners(base: URL = SourceTree.repoRoot) throws -> Int {
        try SourceTree.codeOccurrences(of: "activeSheet = .projectSettings", base: base)
            .values.reduce(0, +)
    }

    /// **The planted control for the opener count** (foundations plan 2): it
    /// sees a second opener in a sibling view, while a comment naming one is
    /// not counted.
    func test_theOpenerCountReachesSiblingViews() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/ProjectWindow.swift": """
            struct ProjectWindow: View {
                // activeSheet = .projectSettings in a comment
                func openProjectSettings() { activeSheet = .projectSettings }
            }
            """,
            "Maugham/Views/SomeSiblingView.swift": """
            struct SomeSiblingView { func g() { activeSheet = .projectSettings } }
            """,
        ])
        XCTAssertEqual(try Self.projectSettingsOpeners(base: base), 2,
                       "the window's opener and the sibling's")
    }

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

    /// What one verb posted, on `name` — captured synchronously, because
    /// `MaughamEvent.post` is a plain `NotificationCenter` post on the calling
    /// thread. A reference box rather than a captured local array: the
    /// observer's closure is `@Sendable`.
    private final class PostBox: @unchecked Sendable {
        private(set) var received: [Notification] = []
        func record(_ note: Notification) { received.append(note) }
    }

    /// The verb a control's action runs, called with no press (tripwire 33,
    /// #120); the control itself is asserted DRAWN, and the action naming the
    /// verb is `WiringCensusTests`'.
    private func notesPosted(
        by verb: () -> Void, on name: Notification.Name = .maughamSetDetailSegment
    ) -> [Notification] {
        let box = PostBox()
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: capture-only observer inspecting the exact scoped Notification the verb posts
            forName: name, object: nil, queue: nil
        ) { box.record($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        verb()
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

    /// A letter host's code: each host is its whole pane (#116 F11). Each
    /// pane is split across files, and a ban must see every one of them.
    private static let resolveHeadPath = "Maugham/Views/Resolve/ResolveHead.swift"

    /// **`DiagnosticsPaneSource.surfaceFiles` is every file the pane is split
    /// into** (#116 F11): every `Diagnostic*.swift` in `Maugham/Views/` is the
    /// pane's or named in `notThePane`, so a census reading the surface cannot
    /// go blind to a new child file.
    func test_thePaneSurfaceListIsEveryFileThePaneIsSplitInto() throws {
        let problems = try PaneSurfaceClassification.problems(
            prefix: "Diagnostic", dir: DiagnosticsPaneSource.viewsDir,
            surface: DiagnosticsPaneSource.surfaceFiles,
            notThePane: DiagnosticsPaneSource.notThePane)
        XCTAssertEqual(problems, [],
                       "every Diagnostic*.swift must be classified, or each "
                       + "census reading the pane's surface is blind to it")
    }

    // MARK: - The turn clause, windowless (re-made, shell plan 2 Task 7 fix)
    //
    // To resolve's head draws Add to intent through `TurnClauseOffer` (the
    // one letter host, `RunLetterSection`). The decisions are pinned here
    // through the same builder the head calls, never by mounting a button.

    /// Whether `TurnClauseOffer` offers the clause for `letter` on `docId`.
    private func offersTheClause(store: ProjectStore?, docId: String, letter: Letter) -> Bool {
        TurnClauseOffer.handler(
            letter: letter, run: makeRun(letter: letter), docId: docId, store: store, world: nil,
            voice: ReviewPass.coachPreset.effectiveEditorName, filedRunId: nil,
            postureOf: { _, _ in .author },
            onFiled: { _ in }, onFailure: { _ in }) != nil
    }

    /// Files the turn clause through `TurnClauseOffer.handler` — the closure
    /// the head hands its Add-to-intent button — and returns once the ruling
    /// has landed (tripwire 33: no press, no poll).
    private func fileTheTurnClause(
        store: ProjectStore, docId: String, letter: Letter
    ) async throws {
        let run = makeRun(letter: letter)
        var failure: String?
        var offered = true
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            guard let handler = TurnClauseOffer.handler(
                letter: letter, run: run, docId: docId, store: store, world: nil,
                voice: ReviewPass.coachPreset.effectiveEditorName, filedRunId: nil,
                postureOf: { _, _ in .author },
                onFiled: { _ in done.resume() },
                onFailure: { message in
                    guard let message else { return }
                    failure = message
                    done.resume()
                })
            else {
                offered = false
                done.resume()
                return
            }
            handler()
        }
        XCTAssertTrue(offered, "the clause was not offered for \(docId)")
        if let failure { XCTFail("the ruling was refused: \(failure)") }
    }

    /// **The offer is `strong_default`'s alone**, and needs a project to file in.
    func test_theTurnOfferIsOfferedForStrongDefaultAndForNothingElse() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOffer")
        for position in [ScenePosition.strongDeclared, .weak, .none] {
            XCTAssertFalse(offersTheClause(store: store, docId: chapter.id,
                                           letter: makeLetter(scenePosition: position.rawValue)),
                           "\(position.rawValue) must not offer the clause")
        }
        XCTAssertTrue(offersTheClause(store: store, docId: chapter.id, letter: makeLetter()),
                      "the strong form with no clause of the writer's is the gap the offer exists for")
        XCTAssertTrue(LetterSection.hasTurnlessScene(makeLetter()), "control")
        XCTAssertFalse(LetterSection.hasTurnlessScene(makeLetter(turn: "She stops asking")),
                       "every scene already turns \u{2014} the section draws no offer")
        XCTAssertFalse(offersTheClause(store: nil, docId: chapter.id, letter: makeLetter()),
                       "no project, nowhere to file a ruling")
    }

    /// **Add to intent files the clause in the writer's own layer, with the
    /// letter's provenance — and the loop closes.**
    func test_addToIntentFilesTheClauseAndTheNextDeriveReadsItBack() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "TurnOfferFiles")
        XCTAssertEqual(TurnClauseOffer.buttonTitle(store: store, docId: chapter.id),
                       LetterSection.addToIntentTitle, "the piece's own tense")
        try await fileTheTurnClause(store: store, docId: chapter.id, letter: makeLetter())
        let statement = try XCTUnwrap(store.statement(kind: .intent, scope: .document(chapter.id)))
        let text = try store.statementText(of: statement)
        XCTAssertTrue(text.contains(LetterSection.turnClauseRuling), text)
        XCTAssertTrue(text.contains("## Rulings"), "a dated ruling, never an appended paragraph: \(text)")
        XCTAssertTrue(text.contains("from \(ReviewPass.coachPreset.effectiveEditorName)'s letter"), text)
        XCTAssertEqual(ScenePosition.derive(projectType: .novel, statement: text, passBrief: nil),
                       .strongDeclared, "the round after the click strains against the clause")
        let derived = try await derivedText(of: statement, in: url)
        XCTAssertTrue(derived.contains(LetterSection.turnClauseRuling))
    }

    /// **The clause lands in the intent the piece is MEASURED against** (a
    /// chapter with no intent of its own reads the book's).
    func test_theClauseLandsInTheIntentThePieceIsMeasuredAgainst() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOfferBookScope")
        let book = try await store.createStatement(kind: .intent, scope: .project)
        try await store.appendToStatement("A ghost story told through weather on the coast.",
                                          to: book, session: "seed")
        XCTAssertEqual(store.effectiveIntent(forDocId: chapter.id)?.scope, .project, "premise")
        XCTAssertEqual(TurnClauseOffer.buttonTitle(store: store, docId: chapter.id),
                       LetterSection.addToBookIntentTitle, "the book's tense")
        try await fileTheTurnClause(store: store, docId: chapter.id, letter: makeLetter())
        let text = try store.statementText(of: try XCTUnwrap(
            store.statement(kind: .intent, scope: .project)))
        XCTAssertTrue(text.contains("## Rulings") && text.contains(LetterSection.turnClauseRuling), text)
        XCTAssertTrue(text.contains("A ghost story told through weather on the coast."), text)
        XCTAssertNil(store.statement(kind: .intent, scope: .document(chapter.id)),
                     "no document-scoped statement may be minted")
        XCTAssertEqual(store.effectiveIntent(forDocId: chapter.id)?.scope, .project)
    }

    /// The control: a piece with its own intent files under itself.
    func test_aPieceWithItsOwnIntentFilesTheClauseUnderItself() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOfferPieceScope")
        let book = try await store.createStatement(kind: .intent, scope: .project)
        try await store.appendToStatement("A ghost story told through weather on the coast.",
                                          to: book, session: "seed")
        let own = try await store.createStatement(kind: .intent, scope: .document(chapter.id))
        try await store.appendToStatement("This chapter belongs to the dock and the fog.",
                                          to: own, session: "seed")
        XCTAssertEqual(TurnClauseOffer.buttonTitle(store: store, docId: chapter.id),
                       LetterSection.addToIntentTitle)
        try await fileTheTurnClause(store: store, docId: chapter.id, letter: makeLetter())
        let bookText = try store.statementText(of: try XCTUnwrap(
            store.statement(kind: .intent, scope: .project)))
        XCTAssertFalse(bookText.contains(LetterSection.turnClauseRuling),
                       "a chapter's clause may not reach the book: \(bookText)")
    }

    /// **The offer's memory is the writer's intent**, read live.
    func test_aFreshOfferDoesNotAskForAClauseTheIntentAlreadyCarries() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOfferLive")
        XCTAssertTrue(offersTheClause(store: store, docId: chapter.id, letter: makeLetter()), "control")
        try await RulingPerformer.rule(
            LetterSection.turnClauseRuling, provenance: "from Le Guin's letter",
            kind: .intent, forScope: .document(chapter.id), store: store, world: nil)
        XCTAssertFalse(offersTheClause(store: store, docId: chapter.id, letter: makeLetter()),
                       "the clause is in the writer's intent now")
    }

    /// A book-level clause silences the offer on a chapter that reads it.
    func test_aProjectLevelClauseSilencesTheOfferOnAChapter() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOfferProject")
        try await RulingPerformer.rule(
            LetterSection.turnClauseRuling, provenance: "from Le Guin's letter",
            kind: .intent, forScope: .project, store: store, world: nil)
        XCTAssertFalse(offersTheClause(store: store, docId: chapter.id, letter: makeLetter()))
    }

    /// A prose piece opted in by its pass brief still gets the offer.
    func test_aProsePieceOptedInByItsPassBriefStillGetsTheOffer() async throws {
        let (_, store, chapter) = try await loadedNovel(named: "TurnOfferBriefOptIn")
        XCTAssertEqual(ScenePosition.live(store: store, docId: chapter.id), .weak, "premise")
        XCTAssertTrue(offersTheClause(store: store, docId: chapter.id, letter: makeLetter()),
                      "a live `.weak` must not withdraw the offer")
    }

    /// A refused disposition says so in the row it was pressed in.
    func test_aRefusedDispositionSpeaksInTheRow() {
        struct Refusal: LocalizedError {
            var errorDescription: String? { "the op log is read-only" }
        }
        XCTAssertEqual(CheckNarrative.dispositionRefusal(Refusal()),
                       "That didn\u{2019}t settle: the op log is read-only")
    }

    // MARK: - The check header, the cold-start offer and the drift line,
    // mounted as To resolve's head mounts them (re-made, shell plan 2 Task 7 fix)

    /// The check header exactly as `ResolveHeadView.checkHeader` builds it,
    /// for a piece never checked.
    private func checkHeader(
        store: ProjectStore?, diagnostics: DiagnosticsStore, docId: String,
        orchestrator: CompilerOrchestrator? = nil,
        reader: AuthorReader = .nobody
    ) -> AnyView {
        let orchestrator = orchestrator ?? CompilerOrchestrator()
        return AnyView(DiagnosticsPaneHeader(
            state: .neverRun, wetInk: .none, visibleQueue: [], reviewPasses: [],
            otherLoopLine: nil, orchestrator: orchestrator, diagnostics: diagnostics,
            docId: docId, reader: reader, store: store, compilerModel: .standard,
            onCompilerModelChange: { _ in }, onChooseReader: { _ in },
            onOpenProjectSettings: {}, offersModelMenu: false))
    }

    /// **The reader line is a picker when there is a project** — drawn, not
    /// opened (tripwire 33).
    func test_mountedHeader_theReaderLineIsAPickerWhenThereIsAProject() async throws {
        let (_, store, _) = try await loadedNovel(named: "ReaderPickerDrawn")
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let window = mount(checkHeader(store: store, diagnostics: diagnostics,
                                       docId: "doc-picker", reader: .coach(ReviewPass.coachPreset)))
        pump(0.2)
        XCTAssertTrue(allLabels(in: window).contains("Le Guin reads this piece"),
                      "got \(allLabels(in: window))")
        XCTAssertTrue(roles(labelled: "Le Guin reads this piece", in: window)
                        .contains { $0 != "AXStaticText" },
                      "the reader line must be a control the writer can open")
    }

    /// **With no project the line is a plain label, never a door to Review.**
    func test_mountedHeader_withNoProjectTheLineIsAPlainLabelAndNoDoor() throws {
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let window = mount(checkHeader(store: nil, diagnostics: diagnostics,
                                       docId: "doc-no-project", reader: .coach(ReviewPass.coachPreset)))
        pump(0.2)
        XCTAssertTrue(allLabels(in: window).contains("Le Guin reads this piece"), "control")
        XCTAssertEqual(roles(labelled: "Le Guin reads this piece", in: window)
                        .filter { $0 != "AXStaticText" }, [],
                       "with no store there is nothing to pick between")
        XCTAssertNil(findButton(labelled: "Le Guin reads this piece", in: window),
                     "the reader line is a label, never a door to Review")
    }

    /// **The header's Ask field opens holding the stored ask.**
    func test_theAskFieldShowsTheStoredAskOnMount() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AskFieldSeeded")
        let diagnostics = DiagnosticsStore(projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        diagnostics.setAsk("I'm worried the middle sags.", docId: chapter.id, kind: .check)
        let window = mount(checkHeader(store: store, diagnostics: diagnostics, docId: chapter.id))
        pump(0.3)
        let fields = textFields(in: window)
        XCTAssertTrue(fields.contains { axAttribute($0, "accessibilityValue") as? String
                        == "I'm worried the middle sags." },
                      "read: \(fields.map { axAttribute($0, "accessibilityValue") as? String ?? "nil" })")
    }

    /// **⌘R commits what is still in the header's Ask field**: typed, not
    /// committed, and the check is briefed with it.
    func test_theRunKeyCommitsWhatIsStillInTheAskField() async throws {
        let (url, store, chapter) = try await loadedNovel(named: "AskRunKey")
        let diagnostics = DiagnosticsStore(projectRoot: url, device: DeviceSlug.make(from: "test-mac"))
        let runner = SpyRunner()
        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(environment: makeEnvironment(docId: chapter.id, runner: runner),
                               diagnostics: diagnostics)
        let window = mount(checkHeader(store: store, diagnostics: diagnostics, docId: chapter.id,
                                       orchestrator: orchestrator))
        pump(0.4)
        let worry = "I'm worried the middle sags."
        let field = try XCTUnwrap(askTextField(in: window), "no ask field in the header")
        type(worry, into: field)
        pump(0.2)
        XCTAssertNil(diagnostics.ask(docId: chapter.id, kind: .check), "premise: typing commits nothing")
        // Exactly what ⌘R's receiver does (`CompilerRunModifier`).
        orchestrator.runRequested(docId: chapter.id, kind: .check)
        try await waitUntilAsync(timeout: 5) { !runner.sentMessages.isEmpty }
        XCTAssertEqual(diagnostics.ask(docId: chapter.id, kind: .check), worry)
        XCTAssertTrue(runner.sentMessages.first?.contains(worry) == true,
                      "sent: \(runner.sentMessages.first ?? "nothing")")
    }

    /// **The cold-start offer draws Read and Not now**, as To resolve mounts
    /// it on a never-checked open piece; Read's act is the run command
    /// (`ResolveMountingTests.test_noViewCallsRunRequestedDirectly`).
    func test_theColdStartOfferDrawsReadAndNotNow() throws {
        let diagnostics = DiagnosticsStore(
            projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        let window = mount(AnyView(DiagnosticsColdStartOffer(
            docId: "doc-cold", diagnostics: diagnostics, otherLoopLine: nil)))
        pump(0.2)
        XCTAssertNotNil(findButton(labelled: "Read", in: window))
        XCTAssertNotNil(findButton(labelled: "Not now", in: window))
        XCTAssertTrue(allLabels(in: window).contains(CheckNarrative.coldStartOfferSentence))
        // Not now's act, called (tripwire 33): the refusal is recorded, so
        // the offer never stands again for this piece.
        diagnostics.refuseColdStart(docId: "doc-cold")
        XCTAssertFalse(CheckNarrative.showsColdStartOffer(
            state: .neverRun, liveParagraphCount: 5,
            hasRefused: diagnostics.hasRefusedColdStart(docId: "doc-cold")))
    }

    /// **The drift line, mounted as the head mounts it**: three straining
    /// runs of one clause draw the line, as a button.
    func test_theDriftLineDrawsAsAButtonForAPattern() throws {
        let docId = "doc-drift"
        let store = DiagnosticsStore(projectRoot: temp.url, device: DeviceSlug.make(from: "test-mac"))
        for _ in 0..<3 {
            store.replace(run: makeRun(clauseStatuses: [makeClause("Cold, and never wistful.", "strains")]),
                          diagnostics: [], docId: docId)
        }
        let findings = DriftDetector.drift(history: store.clauseStatusHistory(docId: docId))
        let line = try XCTUnwrap(CheckNarrative.driftNote(findings))
        let window = mount(AnyView(DiagnosticsDriftLine(driftFindings: findings)))
        pump(0.2)
        XCTAssertNoThrow(try button(labelled: line, in: window), "the drift line is a button")
        let none = mount(AnyView(DiagnosticsDriftLine(driftFindings: [])))
        pump(0.1)
        XCTAssertFalse(allLabels(in: none).contains(line), "no pattern, no line")
    }

    /// **No paragraph id is rendered on a finding's row** (re-made over To
    /// resolve's finding row, shell plan 2 Task 7 fix). Every reference
    /// travels as the words that paragraph said; the id is a payload the chip
    /// carries and never shows. Proved against a planted offender.
    func test_noParagraphIdIsEverRendered() {
        let ids = ["a1b2", "c3d4", "e5f6"]
        let findings = [
            makeDiagnostic(
                docId: "doc-no-ids",
                anchor: Diagnostic.Anchor(paragraphId: ids[0], anchorText: "The fog came in."),
                body: "The sentence pulls the other way.", kind: .conformanceStrain,
                refs: [Diagnostic.Ref(paragraphId: ids[0], excerpt: "The fog came in off the water and")],
                clauseQuote: "Cold, and never wistful."),
            makeDiagnostic(
                docId: "doc-no-ids", body: "Was that learned offstage?",
                refs: [Diagnostic.Ref(paragraphId: ids[1], excerpt: "She already knew about the letter"),
                       Diagnostic.Ref(paragraphId: ids[2], excerpt: "He had not told anyone yet")]),
        ]
        let window = mount(AnyView(VStack(spacing: 0) {
            ForEach(findings) { finding in
                DiagnosticRow(diagnostic: finding, canAnswer: true, canPromote: true,
                              isSubmitting: false, answerFailure: nil,
                              onJump: { _ in }, onPromote: {}, onAnswer: { _ in })
            }
        }))
        pump(0.3)
        let rendered = allLabels(in: window)
        for id in ids {
            XCTAssertFalse(rendered.contains { $0.contains(id) },
                           "the row rendered the paragraph id \u{201C}\(id)\u{201D}")
        }
        XCTAssertTrue(rendered.contains { $0.contains("The fog came in off the water and") },
                      "control: the chip's own words did render, so the walk sees chips")
        let offender = mount(AnyView(VStack { Text("\u{00b6}\(ids[0])") }))
        pump(0.2)
        XCTAssertTrue(allLabels(in: offender).contains { $0.contains(ids[0]) },
                      "the walk must be able to see a rendered id")
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
