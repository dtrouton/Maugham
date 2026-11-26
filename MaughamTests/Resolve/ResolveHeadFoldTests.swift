import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **To resolve's head folds** (the owner's report, 2026-11-26: the head
/// took two thirds of the column and the list the bottom third). Folded is
/// the default; folded, a piece's head is where it stands, one action row,
/// and one line only when there is something to say — never hiding a run in
/// progress. Pure decisions first, then mounts (no press-then-wait,
/// tripwire 33).
@MainActor
final class ResolveHeadFoldTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        windows.removeAll()
        try await super.tearDown()
    }

    private let passes = ReviewPass.presets
    private var ids: [String] { passes.map(\.id) }
    private let counts = CompilerOrchestrator.DeltaCounts(new: 3, revised: 1)
    private let at = Date(timeIntervalSince1970: 1_700_000_000)
    private var mark: ResolveHeadFold.LetterMark { .init(voice: "Lish", at: at) }

    // MARK: - Row 1: the summary, for each ladder state

    func test_anUntouchedPieceNamesTheFirstPassNext() {
        XCTAssertEqual(ResolveHeadFold.ladderPhrase(passes: passes, passStates: nil), "Structural next")
        XCTAssertEqual(ResolveHeadFold.summary(status: .draft, passes: passes, passStates: nil),
                       "Draft \u{00B7} Structural next")
    }

    func test_aPassInProgressIsNamedBeforeAnEarlierOpenOne() {
        XCTAssertEqual(ResolveHeadFold.ladderPhrase(passes: passes, passStates: [ids[1]: .inProgress]),
                       "Line in progress")
    }

    func test_doneAndSkippedPassesAreRuledAndTheNextOpenOneIsNamed() {
        XCTAssertEqual(ResolveHeadFold.ladderPhrase(passes: passes, passStates: [ids[0]: .done, ids[1]: .skipped]),
                       "Copyedit next")
    }

    func test_aStateFromANewerBuildCountsAsOpen() {
        XCTAssertEqual(ResolveHeadFold.ladderPhrase(passes: passes, passStates: [ids[0]: .unknown("parked")]),
                       "Structural next")
    }

    func test_everyPassRuledSaysAllFourDone() {
        let states = Dictionary(uniqueKeysWithValues: ids.map { ($0, PassState.done) })
        XCTAssertEqual(ResolveHeadFold.summary(status: .final, passes: passes, passStates: states),
                       "Final \u{00B7} all four passes done")
    }

    func test_oneRuledPassIsNamed_andNoPassesIsTheStatusAlone() {
        let only = [passes[3]]
        XCTAssertEqual(ResolveHeadFold.ladderPhrase(passes: only, passStates: [only[0].id: .done]), "Proof done")
        XCTAssertNil(ResolveHeadFold.ladderPhrase(passes: [], passStates: nil))
        XCTAssertEqual(ResolveHeadFold.summary(status: .revising, passes: [], passStates: nil), "Revising")
    }

    func test_theSummaryReadsAsOneSentence() {
        XCTAssertEqual(ResolveHeadFold.sentence(title: "Chapter 1", summary: "Revising \u{00B7} Line next"),
                       "Chapter 1: Revising, Line next.")
        XCTAssertEqual(ResolveHeadFold.sentence(title: "Chapter 1", summary: nil), "Chapter 1.")
    }

    /// **The name leads only where it is information** (B1).
    func test_theNameLeadsOnlyWhenTheFacesPieceIsNotTheOpenOne() {
        XCTAssertFalse(ResolveHeadFold.namesThePiece(docId: "ch-1", openDocId: "ch-1"))
        XCTAssertTrue(ResolveHeadFold.namesThePiece(docId: "ch-1", openDocId: "ch-2"))
        XCTAssertTrue(ResolveHeadFold.namesThePiece(docId: "ch-1", openDocId: nil))
    }

    // MARK: - Row 3: what the folded line says

    func test_aRunningRoundIsNeverHiddenFolded() {
        XCTAssertEqual(ResolveHeadFold.pieceLine(roundPhase: .running(counts), checkState: .neverRun,
                                                 nudge: "Structural still open", letter: mark, ask: "a"),
                       .roundRunning, "a running round outranks the nudge, the letter and the ask")
    }

    func test_aRunningCheckIsNeverHiddenFolded() {
        XCTAssertEqual(ResolveHeadFold.pieceLine(
            roundPhase: .authorsCheckIsRunning,
            checkState: .running(checking: counts, since: nil, progress: nil),
            nudge: "n", letter: mark), .checkRunning)
    }

    func test_aFailedRoundOrCheckSaysItsFailureInRed() {
        let round = ResolveHeadFold.pieceLine(roundPhase: .failed(.cliNotFound, at: at), checkState: .neverRun,
                                              nudge: "n", letter: mark)
        XCTAssertEqual(round, .failed(RoundNarrative.failureCopy(.cliNotFound)))
        XCTAssertTrue(round?.isFailure == true)
        let check = ResolveHeadFold.pieceLine(roundPhase: .idle, checkState: .failed(.cliNotFound, at: at),
                                              nudge: "n", letter: mark)
        XCTAssertEqual(check, .failed(CheckNarrative.headerCopy(
            for: .failed(.cliNotFound, at: at), annotations: nil, passes: [])))
    }

    func test_aRunElsewhereHoldingTheSessionIsSaid() {
        XCTAssertEqual(ResolveHeadFold.pieceLine(roundPhase: .roundIsRunningElsewhere(title: "Chapter 2"),
                                                 checkState: .neverRun, nudge: "n", letter: mark),
                       .otherRun(RoundNarrative.runElsewhereLine(kind: .round, title: "Chapter 2")))
    }

    /// **A letter is never shadowed by a standing nudge** (fix round 1, A2).
    func test_theLetterOutranksTheNudge_thenTheNudge_thenTheAsk_thenNothing() {
        XCTAssertEqual(ResolveHeadFold.pieceLine(roundPhase: .idle, checkState: .neverRun,
                                                 nudge: "Structural still open on this chapter",
                                                 letter: mark, ask: "the middle"),
                       .letter(voice: "Lish", at: at))
        XCTAssertEqual(ResolveHeadFold.pieceLine(roundPhase: .idle, checkState: .neverRun,
                                                 nudge: "Structural still open on this chapter",
                                                 letter: nil, ask: "the middle"),
                       .nudge("Structural still open on this chapter"))
        XCTAssertEqual(ResolveHeadFold.pieceLine(roundPhase: .idle, checkState: .neverRun,
                                                 nudge: nil, letter: nil, ask: "the middle"),
                       .ask("Asking about: the middle"))
        XCTAssertNil(ResolveHeadFold.pieceLine(roundPhase: .idle, checkState: .neverRun, nudge: nil, letter: nil))
    }

    /// **A check that found nothing new says so folded** (A6), over an older
    /// letter; it clears with the run state, as open.
    func test_aCheckThatFoundNothingNewSaysSoOverTheLetter() {
        let state = CheckNarrative.HeaderState.nothingNew(at: at)
        XCTAssertEqual(ResolveHeadFold.pieceLine(roundPhase: .idle, checkState: state, nudge: "n", letter: mark),
                       .nothingNew(CheckNarrative.headerCopy(for: state, annotations: nil, passes: [])))
        XCTAssertEqual(ResolveHeadFold.pieceLine(roundPhase: .idle, checkState: .neverRun, nudge: nil, letter: mark),
                       .letter(voice: "Lish", at: at), "control: with no fresh check the letter stands")
    }

    /// **A hidden ask is said** (A5): cut to a line, and in the tooltips.
    func test_aStandingAskIsSaidCutToALine() {
        XCTAssertEqual(ResolveHeadFold.askLine("the middle sags"), "Asking about: the middle sags")
        let line = ResolveHeadFold.askLine(String(repeating: "word ", count: 30))
        XCTAssertTrue(line.hasSuffix("\u{2026}"), line)
        XCTAssertLessThanOrEqual(line.count, "Asking about: ".count + ResolveHeadFold.askPreviewLength + 1)
        XCTAssertEqual(ResolveHeadFold.help("Run", ask: nil), "Run")
        XCTAssertEqual(ResolveHeadFold.help("Run", ask: "the middle"), "Run\nAsking about: the middle")
    }

    /// **Check Writing on a piece never checked, Reread after** (A4).
    func test_theCheckButtonIsCheckWritingUntilThereIsACheckToReread() {
        XCTAssertEqual(ResolveHeadFold.checkCommand(.neverRun), .checkWriting)
        XCTAssertEqual(ResolveHeadFold.checkCommand(.nothingNew(at: at)), .reread)
        XCTAssertEqual(ResolveHeadFold.checkCommand(.failed(.cliNotFound, at: at)), .reread)
    }

    func test_theLetterLineNamesItsVoiceAndWhen() {
        let line = ResolveHeadFold.letterLine(voice: "Lish", at: at, now: at.addingTimeInterval(7200))
        XCTAssertTrue(line.hasPrefix("Letter from Lish \u{00B7} "), line)
        XCTAssertTrue(line.contains("2 hours ago"), line)
    }

    func test_aTranslationHeadsLineOrder() {
        func line(running: String? = nil, elsewhere: String? = nil, failure: String? = nil,
                  stopped: (String, Bool)? = nil, notice: String? = nil,
                  letter: ResolveHeadFold.LetterMark? = nil) -> ResolveHeadFold.Line? {
            ResolveHeadFold.translationLine(running: running, elsewhere: elsewhere, failure: failure,
                                            stopped: stopped.map { (line: $0.0, failed: $0.1) },
                                            notice: notice, letter: letter)
        }
        XCTAssertEqual(line(running: "r", elsewhere: "e", failure: "f", notice: "n", letter: mark), .running("r"))
        XCTAssertEqual(line(elsewhere: "e", failure: "f", letter: mark), .otherRun("e"))
        XCTAssertEqual(line(failure: "f", stopped: ("s", false), letter: mark), .failed("f"))
        XCTAssertEqual(line(stopped: ("s", true), notice: "n"), .failed("s"))
        XCTAssertEqual(line(stopped: ("s", false), notice: "n"), .stopped("s"))
        XCTAssertEqual(line(notice: "n", letter: mark), .notice("n"))
        XCTAssertEqual(line(letter: mark), .letter(voice: "Lish", at: at))
        XCTAssertNil(line())
    }

    // MARK: - The list's room

    func test_anOpenHeadLeavesTheListItsFloor() {
        XCTAssertEqual(ResolveHeadRoomLayout.headHeight(total: 900, headIdeal: 400, headMinimum: 30,
                                                        restMinimum: 40, listFloor: 120), 400)
        XCTAssertEqual(ResolveHeadRoomLayout.headHeight(total: 500, headIdeal: 400, headMinimum: 30,
                                                        restMinimum: 40, listFloor: 120), 340)
        XCTAssertEqual(ResolveHeadRoomLayout.headHeight(total: 150, headIdeal: 400, headMinimum: 30,
                                                        restMinimum: 40, listFloor: 120), 30)
    }

    // MARK: - The remembered setting

    func test_theSettingRoundTripsThroughUIState() throws {
        XCTAssertFalse(UIState.empty.resolveHeadOpen, "folded is the default")
        let folded = String(decoding: try JSONEncoder().encode(UIState.empty), as: UTF8.self)
        XCTAssertFalse(folded.contains("resolveHeadOpen"), "a folded window's file is the file it always was")
        var open = UIState.empty
        open.resolveHeadOpen = true
        XCTAssertTrue(try JSONDecoder().decode(UIState.self, from: try JSONEncoder().encode(open)).resolveHeadOpen)
        XCTAssertFalse(try JSONDecoder().decode(UIState.self, from: try JSONEncoder().encode(UIState.empty))
            .resolveHeadOpen, "a file without the key opens folded")
    }

    func test_theStoreSetsTheWindowsOneSetting() async throws {
        let f = try await makeFixture()
        XCTAssertFalse(f.documentStore.uiState.resolveHeadOpen)
        f.documentStore.setResolveHeadOpen(true)
        XCTAssertTrue(f.documentStore.uiState.resolveHeadOpen)
        f.documentStore.setResolveHeadOpen(false)
        XCTAssertFalse(f.documentStore.uiState.resolveHeadOpen)
    }

    // MARK: - Mounted: the head

    func test_theHeadIsFoldedByDefault_andTheOpenHeadHoldsTodaysControls() async throws {
        let f = try await makeFixture()
        let folded = mount(head(f), width: 260)
        await waitOut(0.3)
        XCTAssertEqual(askFields(in: folded), 0, "folded, no Ask about… field is drawn")

        f.documentStore.setResolveHeadOpen(true)
        let open = mount(head(f), width: 260)
        await waitOut(0.3)
        XCTAssertEqual(askFields(in: open), 2, "open, the round's and the check's Ask about… are drawn")

        try requireAssistiveClient()
        let chevrons = try axButtons(labelled: ResolveHeadFold.chevronLabel, in: open)
        XCTAssertEqual(chevrons.count, 1)
        XCTAssertEqual(chevrons.first.flatMap { axAttribute($0, "accessibilityValue") as? String }, "Expanded")
        XCTAssertFalse(try axButtons(labelled: ReviewRoundCockpit.freshEyesTitle, in: open).isEmpty,
                       "open, Fresh Eyes is drawn")
        XCTAssertEqual(summaryHelp(in: open), "",
                       "open, the first row repeats nothing above the ladder (B1)")
    }

    /// Folded on the open, never-checked piece: Run Round and Check Writing
    /// (A4), the summary without the name it already has (B1), and a
    /// VoiceOver sentence that still names it.
    func test_theFoldedHeadOffersRunRoundAndCheckWriting_andNamesThePieceOnlyAloud() async throws {
        let f = try await makeFixture()
        let window = mount(head(f), width: 260)
        await waitOut(0.3)
        try requireAssistiveClient()
        let chevron = try XCTUnwrap(try axButtons(labelled: ResolveHeadFold.chevronLabel, in: window).first)
        XCTAssertEqual(axAttribute(chevron, "accessibilityValue") as? String, "Collapsed")
        let labels = try axButtonLabels(in: window).joined(separator: ", ")
        XCTAssertEqual(try axButtons(labelled: ReviewRoundCockpit.runTitle, in: window).count, 1, labels)
        XCTAssertEqual(try axButtons(labelled: RunCommand.checkWriting.title, in: window).count, 1, labels)
        XCTAssertTrue(try axButtons(labelled: CheckNarrative.rereadTitle, in: window).isEmpty,
                      "nothing to reread on a piece never checked")
        XCTAssertTrue(try axButtons(labelled: ReviewRoundCockpit.freshEyesTitle, in: window).isEmpty,
                      "Fresh Eyes is behind the fold")
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains("Chapter 1: Draft, Structural next."), texts.joined(separator: " | "))
        XCTAssertEqual(summaryHelp(in: window), "Draft \u{00B7} Structural next",
                       "the open piece's name is not drawn again (B1)")
    }

    /// A piece that is not the open one: its name leads (B1); row 2 is the
    /// line that opens it, and row 3 still says what stands (A3).
    func test_aPieceNotOpenNamesItselfAndStillSaysWhatStands() async throws {
        let f = try await makeFixture()
        f.documentStore.updateUIState { $0.activePassMemory.record(piece: f.docId, passId: "line") }
        let window = mount(head(f, openDocId: .some(nil)), width: 300)
        await waitOut(0.3)
        try requireAssistiveClient()
        XCTAssertEqual(summaryHelp(in: window), "Chapter 1 \u{00B7} Draft \u{00B7} Structural next")
        let texts = try axTexts(in: window)
        let caption = PassOrderAdvice.caption(for: passes[0], noun: .chapter)
        XCTAssertTrue(texts.contains(caption), "the nudge is said on a piece not open: "
                      + texts.joined(separator: " | "))
        XCTAssertTrue(try axButtons(labelled: ReviewRoundCockpit.runTitle, in: window).isEmpty,
                      "no Run on a piece not open")
    }

    /// **A standing ask is said folded** (A5).
    func test_aStandingAskIsSaidFolded() async throws {
        let f = try await makeFixture()
        f.diagnostics.setAsk("the middle sags", docId: f.docId, kind: .round)
        let window = mount(head(f), width: 300)
        await waitOut(0.3)
        try requireAssistiveClient()
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains("Asking about: the middle sags"), texts.joined(separator: " | "))
    }

    func test_theFoldedHeadIsAtMostThreeRows() async throws {
        let f = try await makeFixture()
        func height(open: Bool) -> CGFloat {
            f.documentStore.setResolveHeadOpen(open)
            return NSHostingView(rootView: head(f).frame(width: 240)).fittingSize.height
        }
        let folded = height(open: false)
        let open = height(open: true)
        XCTAssertLessThanOrEqual(folded, 96, "folded head is \(folded)pt")
        XCTAssertGreaterThan(open, folded * 2, "open \(open)pt against folded \(folded)pt")
    }

    func test_aRunningRoundsLineShowsWhileFolded() async throws {
        let phase = ReviewRoundCockpit.RunPhase.running(counts)
        let line = try XCTUnwrap(ResolveHeadFold.pieceLine(roundPhase: phase, checkState: .neverRun,
                                                           nudge: "n", letter: mark))
        let expected = try XCTUnwrap(ReviewRoundCockpit.statusLine(
            phase: phase, reportLine: nil, runSince: nil, runProgress: nil))
        let window = mount(ResolveHeadFoldedLine(
            line: line,
            runningText: { now in
                ReviewRoundCockpit.statusLine(phase: phase, reportLine: nil, runSince: nil,
                                              runProgress: nil, now: now) ?? ""
            },
            onOpen: {}), width: 260)
        await waitOut(0.3)
        try requireAssistiveClient()
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains(expected),
                      "the running round's line is drawn folded: " + texts.joined(separator: " | "))
    }

    // MARK: - Mounted: the pane, per scope shape (A1)

    /// **Every scope's list sits under its head, inside the pane** (fix round
    /// 1, A1): an edition's head and a piece read in a language's are two
    /// views and a figure's none, and the pane's layout once took them as
    /// subviews of its own and drew the list off the top.
    func test_everyScopesListSitsUnderItsHeadInsideThePane() async throws {
        let f = try await makeFixture()
        try requireAssistiveClient()
        let source = PublishConfig.Metadata().language
        let shapes: [(String, BinderSubject, String?)] = [
            ("a piece", .item(f.docId), nil),
            ("the Book", .project, nil),
            ("the Source edition", .edition(language: source), nil),
            ("a translated edition", .edition(language: "es"), nil),
            ("a piece read in a language", .item(f.docId), "es"),
            ("a figure", .figure("fig-1"), nil),
            ("outside", .canvas, nil),
        ]
        var offenders: [String] = []
        for open in [false, true] {
            f.documentStore.setResolveHeadOpen(open)
            for (name, faces, readIn) in shapes {
                let window = mount(pane(f, faces: faces, readIn: readIn), width: 300, height: 700)
                await waitOut(0.5)
                if let problem = try placementProblem(in: window) {
                    offenders.append("\(name), \(open ? "open" : "folded"): \(problem)")
                }
                window.contentView = NSView(frame: .zero)
            }
        }
        XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
    }

    /// **The folded head in a real window** at the column's narrowest and a
    /// short window: at most three rows, the rest of the pane the list's.
    func test_theFoldedHeadInAShortNarrowWindowIsAtMostThreeRows() async throws {
        let f = try await makeFixture()
        try requireAssistiveClient()
        let window = mount(pane(f, faces: .item(f.docId)), width: Self.narrowest, height: 360)
        await waitOut(0.5)
        let head = try XCTUnwrap(frame(of: ResolvePane.headIdentifier, in: window))
        XCTAssertLessThanOrEqual(head.height, 96, "folded head is \(head.height)pt")
        XCTAssertNil(try placementProblem(in: window))
    }

    /// **A short window under a long open head keeps the list its floor**:
    /// the head scrolls within itself.
    func test_aShortWindowUnderALongOpenHeadKeepsTheListItsFloor() async throws {
        let f = try await makeFixture()
        try requireAssistiveClient()
        f.documentStore.setResolveHeadOpen(true)
        let window = mount(pane(f, faces: .item(f.docId)), width: Self.narrowest, height: 360)
        await waitOut(0.5)
        let rest = try XCTUnwrap(frame(of: ResolvePane.restIdentifier, in: window))
        XCTAssertGreaterThanOrEqual(rest.height, ResolveHeadFold.listFloor,
                                    "the list and its bar have \(rest.height)pt under the open head")
        XCTAssertNil(try placementProblem(in: window))
        XCTAssertEqual(askFields(in: window), 2, "premise: the open head is the long one")
    }

    /// **File ▸ Translate… is answered folded and leaves the fold as it is**
    /// (A7): the edition head's notice shows in row 3, and the remembered
    /// setting is not flipped open.
    func test_translateIsAnsweredFoldedAndDoesNotOpenTheHead() async throws {
        let f = try await makeFixture()
        try requireAssistiveClient()
        let window = mount(pane(f, faces: .edition(language: "es"),
                                request: .translate(.book(language: "es"))), width: 300, height: 700)
        let answered = await pumpUntil(deadline: 5) {
            ((try? self.axElements(in: window)) ?? []).contains {
                (self.axAttribute($0, "accessibilityIdentifier") as? String) == "resolve.head.foldedLine"
            }
        }
        XCTAssertTrue(answered, "the folded edition head says what came of the ask: "
                      + ((try? axTexts(in: window)) ?? []).joined(separator: " | "))
        XCTAssertFalse(f.documentStore.uiState.resolveHeadOpen, "the ask did not open the head")
    }

    // MARK: - Fixture

    private static var narrowest: CGFloat {
        CGFloat(ProjectWindow.effectiveDetailColumnWidth(
            persisted: UIState.detailColumnWidthRange.lowerBound,
            containerWidth: Double(ProjectWindow.windowFloor)))
    }

    private struct Fixture {
        let store: ProjectStore
        let documentStore: DocumentStore
        let docId: String
        let orchestrator: CompilerOrchestrator
        let diagnostics: DiagnosticsStore
    }

    private func makeFixture() async throws -> Fixture {
        let root = TestTemp.root.appendingPathComponent("HeadFold-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manuscript"),
                                                withIntermediateDirectories: true)
        let docPath = "manuscript/ch1.md"
        try "The fog came.\n".write(to: root.appendingPathComponent(docPath), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "ch-1", title: "Chapter 1", type: .document, path: docPath)],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        store.documentStore = documentStore
        let document = try await Document.load(url: root.appendingPathComponent(docPath),
                                               device: "test-mac", session: "s", presenter: nil)
        documentStore.register(document: document, for: docPath)
        return Fixture(store: store, documentStore: documentStore, docId: "ch-1",
                       orchestrator: CompilerOrchestrator(),
                       diagnostics: DiagnosticsStore(projectRoot: root, device: DeviceSlug.make(from: "test-mac")))
    }

    private func head(_ f: Fixture, openDocId: String?? = .none) -> some View {
        let open: String? = openDocId ?? f.docId
        return ResolveHeadView(
            scope: .piece(docId: f.docId, includesBookLevel: false), snapshot: .empty, openDocId: open,
            store: f.store, documentStore: f.documentStore,
            orchestrator: f.orchestrator, diagnostics: f.diagnostics, world: nil,
            reader: .nobody, compilerModel: .standard,
            onCompilerModelChange: { _ in }, onChooseReader: { _ in }, onOpenProjectSettings: {},
            onSetActivePass: { _, _ in }, onSetPassState: { _, _, _ in })
    }

    private func pane(_ f: Fixture, faces: BinderSubject, readIn: String? = nil,
                      request: ResolveRequest? = nil) -> some View {
        let control = EditorControl()
        control.translationLanguage = readIn
        return ResolvePane(
            store: f.store, documentStore: f.documentStore,
            subject: WindowSubject(open: .item(f.docId), faces: faces),
            script: nil, diagnostics: f.diagnostics, orchestrator: f.orchestrator, world: nil,
            compilerModel: .standard, onCompilerModelChange: { _ in },
            onSetPassState: { _, _, _ in }, onSetActivePass: { _, _ in },
            request: .constant(request), onSelectionShown: { _ in }, figureTree: nil,
            readIn: readIn, editorControl: control)
            .environment(UserPreferences(defaults: UserDefaults(suiteName: "HeadFold-\(UUID())")!))
    }

    private func mount(_ view: some View, width: CGFloat, height: CGFloat = 800) -> NSWindow {
        let window = TestWindow.mount(view.frame(width: width, height: height),
                                      size: CGSize(width: width, height: height))
        windows.append(window)
        return window
    }

    private func askFields(in window: NSWindow) -> Int {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        return descendants(window.contentView ?? NSView()).filter {
            ($0 as? NSTextField)?.placeholderString == AskField.placeholder
        }.count
    }

    /// The first row's drawn words, read off its tooltip (its VoiceOver label
    /// is the spoken sentence, which always names the piece).
    private func summaryHelp(in window: NSWindow) -> String? {
        ((try? axElements(in: window)) ?? []).first {
            (axAttribute($0, "accessibilityIdentifier") as? String) == "resolve.head.summary"
        }.flatMap { axAttribute($0, "accessibilityHelp") as? String }
    }

    /// An element's frame, in screen coordinates, by identifier.
    private func frame(of identifier: String, in window: NSWindow) throws -> CGRect? {
        try axElements(in: window).first {
            (axAttribute($0, "accessibilityIdentifier") as? String) == identifier
        }.flatMap { (axAttribute($0, "accessibilityFrame") as? NSValue)?.rectValue }
    }

    /// What is wrong with the pane's placement, or nil: the rest (the list,
    /// or the empty view) starts at or below the head's bottom, lies inside
    /// the pane, and has height.
    private func placementProblem(in window: NSWindow) throws -> String? {
        let pane = window.convertToScreen(window.contentLayoutRect)
        guard let rest = try frame(of: ResolvePane.restIdentifier, in: window) else {
            return "no list was laid out"
        }
        // Screen coordinates rise upward: the head's bottom is its minY.
        let headBottom = try frame(of: ResolvePane.headIdentifier, in: window).map(\.minY) ?? pane.maxY
        if rest.height <= 0 { return "the list has no height (\(rest))" }
        if rest.maxY > headBottom + 0.5 { return "the list starts above the head's bottom (\(rest) vs \(headBottom))" }
        if rest.maxY > pane.maxY + 0.5 || rest.minY < pane.minY - 0.5 {
            return "the list lies outside the pane (\(rest) in \(pane))"
        }
        return nil
    }
}
