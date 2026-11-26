import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **To resolve's head folds** (the owner's report, 2026-11-26: the head
/// took two thirds of the column and the list the bottom third). Folded is
/// the default; folded, a piece's head is its name and standing, one action
/// row, and one line only when there is something to say — never hiding a
/// run in progress. Pure decisions first, then mounts (no press-then-wait,
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

    // MARK: - Row 1: the summary, for each ladder state

    func test_anUntouchedPieceNamesTheFirstPassNext() {
        XCTAssertEqual(ResolveHeadFold.ladderPhrase(passes: passes, passStates: nil), "Structural next")
        XCTAssertEqual(ResolveHeadFold.summary(status: .draft, passes: passes, passStates: nil),
                       "Draft \u{00B7} Structural next")
    }

    func test_aPassInProgressIsNamedBeforeAnEarlierOpenOne() {
        let states: [String: PassState] = [ids[1]: .inProgress]
        XCTAssertEqual(ResolveHeadFold.ladderPhrase(passes: passes, passStates: states), "Line in progress")
    }

    func test_doneAndSkippedPassesAreRuledAndTheNextOpenOneIsNamed() {
        let states: [String: PassState] = [ids[0]: .done, ids[1]: .skipped]
        XCTAssertEqual(ResolveHeadFold.ladderPhrase(passes: passes, passStates: states), "Copyedit next")
    }

    func test_aStateFromANewerBuildCountsAsOpen() {
        let states: [String: PassState] = [ids[0]: .unknown("parked")]
        XCTAssertEqual(ResolveHeadFold.ladderPhrase(passes: passes, passStates: states), "Structural next")
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

    // MARK: - Row 3: what the folded line says

    private let counts = CompilerOrchestrator.DeltaCounts(new: 3, revised: 1)
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    func test_aRunningRoundIsNeverHiddenFolded() {
        XCTAssertEqual(ResolveHeadFold.pieceLine(roundPhase: .running(counts), checkState: .neverRun,
                                                 nudge: "Structural still open", letter: "Letter from Lish"),
                       .roundRunning,
                       "a running round outranks the nudge and the letter")
    }

    func test_aRunningCheckIsNeverHiddenFolded() {
        XCTAssertEqual(ResolveHeadFold.pieceLine(
            roundPhase: .authorsCheckIsRunning,
            checkState: .running(checking: counts, since: nil, progress: nil),
            nudge: "n", letter: "l"), .checkRunning)
    }

    func test_aFailedRoundOrCheckSaysItsFailureInRed() {
        let round = ResolveHeadFold.pieceLine(roundPhase: .failed(.cliNotFound, at: at), checkState: .neverRun,
                                              nudge: "n", letter: "l")
        XCTAssertEqual(round, .failed(RoundNarrative.failureCopy(.cliNotFound)))
        XCTAssertTrue(round?.isFailure == true)
        let check = ResolveHeadFold.pieceLine(roundPhase: .idle, checkState: .failed(.cliNotFound, at: at),
                                              nudge: "n", letter: "l")
        XCTAssertEqual(check, .failed(CheckNarrative.headerCopy(
            for: .failed(.cliNotFound, at: at), annotations: nil, passes: [])))
    }

    func test_aRunElsewhereHoldingTheSessionIsSaid() {
        XCTAssertEqual(ResolveHeadFold.pieceLine(roundPhase: .roundIsRunningElsewhere(title: "Chapter 2"),
                                                 checkState: .neverRun, nudge: "n", letter: "l"),
                       .otherRun(RoundNarrative.runElsewhereLine(kind: .round, title: "Chapter 2")))
    }

    func test_theNudgeThenTheLetterThenNothing() {
        XCTAssertEqual(ResolveHeadFold.pieceLine(roundPhase: .idle, checkState: .neverRun,
                                                 nudge: "Structural still open on this chapter",
                                                 letter: "Letter from Lish"),
                       .nudge("Structural still open on this chapter"))
        XCTAssertEqual(ResolveHeadFold.pieceLine(roundPhase: .idle, checkState: .neverRun,
                                                 nudge: nil, letter: "Letter from Lish"),
                       .letter("Letter from Lish"))
        XCTAssertNil(ResolveHeadFold.pieceLine(roundPhase: .idle, checkState: .neverRun, nudge: nil, letter: nil))
    }

    func test_theLetterLineNamesItsVoiceAndWhen() {
        let line = ResolveHeadFold.letterLine(voice: "Lish", at: at, now: at.addingTimeInterval(7200))
        XCTAssertTrue(line.hasPrefix("Letter from Lish \u{00B7} "), line)
        XCTAssertTrue(line.contains("2 hours ago"), line)
    }

    func test_aTranslationHeadsLineOrder() {
        func line(running: String? = nil, elsewhere: String? = nil, failure: String? = nil,
                  stopped: (String, Bool)? = nil, notice: String? = nil, letter: String? = nil)
            -> ResolveHeadFold.Line? {
            ResolveHeadFold.translationLine(running: running, elsewhere: elsewhere, failure: failure,
                                            stopped: stopped.map { (line: $0.0, failed: $0.1) },
                                            notice: notice, letter: letter)
        }
        XCTAssertEqual(line(running: "r", elsewhere: "e", failure: "f", notice: "n", letter: "l"), .running("r"))
        XCTAssertEqual(line(elsewhere: "e", failure: "f", letter: "l"), .otherRun("e"))
        XCTAssertEqual(line(failure: "f", stopped: ("s", false), letter: "l"), .failed("f"))
        XCTAssertEqual(line(stopped: ("s", true), notice: "n"), .failed("s"))
        XCTAssertEqual(line(stopped: ("s", false), notice: "n"), .stopped("s"))
        XCTAssertEqual(line(notice: "n", letter: "l"), .notice("n"))
        XCTAssertEqual(line(letter: "l"), .letter("l"))
        XCTAssertNil(line())
    }

    // MARK: - The routes

    func test_onlyTranslateOpensTheHead() {
        let offer = TranslateMenuOffer.book(language: "es")
        XCTAssertTrue(ResolveHeadFold.opensTheHead(.translate(offer)))
        XCTAssertFalse(ResolveHeadFold.opensTheHead(.filter(.questions)))
        XCTAssertFalse(ResolveHeadFold.opensTheHead(.focus(groupOwnerId: "ch-1")))
        XCTAssertFalse(ResolveHeadFold.opensTheHead(.focusFinding(docId: "ch-1", itemId: nil)))
        XCTAssertFalse(ResolveHeadFold.opensTheHead(.showParagraph(docId: "ch-1", paragraphId: "abcd")))
    }

    /// The pane opens the head on the route the head answers, through the
    /// one decision.
    func test_thePaneAsksTheDecisionBeforeHandingTheHeadTheAsk() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/Resolve/ResolvePane.swift"), encoding: .utf8)
        let open = try XCTUnwrap(source.range(of: "ResolveHeadFold.opensTheHead(pending)"),
                                 "the pane opens the head for the route the head answers")
        let hand = try XCTUnwrap(source.range(of: "translateAsk = ask"))
        XCTAssertLessThan(open.lowerBound, hand.lowerBound, "the head opens before it is handed the ask")
    }

    // MARK: - The list's room

    func test_anOpenHeadLeavesTheListItsFloor() {
        // Room enough: the head's own height.
        XCTAssertEqual(ResolveHeadRoomLayout.headHeight(total: 900, headIdeal: 400, headMinimum: 30,
                                                        restMinimum: 40, listFloor: 120), 400)
        // Tight: the head gets what leaves the list 120pt, and scrolls.
        XCTAssertEqual(ResolveHeadRoomLayout.headHeight(total: 500, headIdeal: 400, headMinimum: 30,
                                                        restMinimum: 40, listFloor: 120), 340)
        // Never less than its first row: the chevron stays.
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
        let data = try JSONEncoder().encode(open)
        XCTAssertTrue(try JSONDecoder().decode(UIState.self, from: data).resolveHeadOpen)
        let older = try JSONEncoder().encode(UIState.empty)
        XCTAssertFalse(try JSONDecoder().decode(UIState.self, from: older).resolveHeadOpen,
                       "a file without the key opens folded")
    }

    func test_theStoreSetsTheWindowsOneSetting() async throws {
        let f = try await makeFixture()
        XCTAssertFalse(f.documentStore.uiState.resolveHeadOpen)
        f.documentStore.setResolveHeadOpen(true)
        XCTAssertTrue(f.documentStore.uiState.resolveHeadOpen)
        f.documentStore.setResolveHeadOpen(false)
        XCTAssertFalse(f.documentStore.uiState.resolveHeadOpen)
    }

    // MARK: - Mounted

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
    }

    func test_theFoldedHeadOffersRunRoundAndReread_andReadsAsOneSentence() async throws {
        let f = try await makeFixture()
        let window = mount(head(f), width: 260)
        await waitOut(0.3)
        try requireAssistiveClient()
        let chevron = try XCTUnwrap(try axButtons(labelled: ResolveHeadFold.chevronLabel, in: window).first)
        XCTAssertEqual(axAttribute(chevron, "accessibilityValue") as? String, "Collapsed")
        let labels = try axButtonLabels(in: window).joined(separator: ", ")
        XCTAssertEqual(try axButtons(labelled: ReviewRoundCockpit.runTitle, in: window).count, 1, labels)
        XCTAssertEqual(try axButtons(labelled: CheckNarrative.rereadTitle, in: window).count, 1)
        XCTAssertTrue(try axButtons(labelled: ReviewRoundCockpit.freshEyesTitle, in: window).isEmpty,
                      "Fresh Eyes is behind the fold")
        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains("Chapter 1: Draft, Structural next."), texts.joined(separator: " | "))
    }

    func test_theFoldedHeadIsAtMostThreeRows() async throws {
        let f = try await makeFixture()
        func height(open: Bool) -> CGFloat {
            f.documentStore.setResolveHeadOpen(open)
            let host = NSHostingView(rootView: head(f).frame(width: 240))
            return host.fittingSize.height
        }
        let folded = height(open: false)
        let open = height(open: true)
        // Three short rows: the name and standing, the action row, one
        // caption line — a small control's height each, and their padding.
        XCTAssertLessThanOrEqual(folded, 96, "folded head is \(folded)pt")
        XCTAssertGreaterThan(open, folded * 2, "open \(open)pt against folded \(folded)pt")
    }

    func test_aRunningRoundsLineShowsWhileFolded() async throws {
        let phase = ReviewRoundCockpit.RunPhase.running(counts)
        let line = try XCTUnwrap(ResolveHeadFold.pieceLine(roundPhase: phase, checkState: .neverRun,
                                                           nudge: "n", letter: "l"))
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

    // MARK: - Fixture

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

    private func head(_ f: Fixture) -> some View {
        ResolveHeadView(
            scope: .piece(docId: f.docId, includesBookLevel: false), snapshot: .empty, openDocId: f.docId,
            store: f.store, documentStore: f.documentStore,
            orchestrator: f.orchestrator, diagnostics: f.diagnostics, world: nil,
            reader: .nobody, compilerModel: .standard,
            onCompilerModelChange: { _ in }, onChooseReader: { _ in }, onOpenProjectSettings: {},
            onSetActivePass: { _, _ in }, onSetPassState: { _, _, _ in })
    }

    private func mount(_ view: some View, width: CGFloat) -> NSWindow {
        let window = TestWindow.mount(view.frame(width: width), size: CGSize(width: width, height: 800))
        windows.append(window)
        return window
    }

    private func askFields(in window: NSWindow) -> Int {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        return descendants(window.contentView ?? NSView()).filter {
            ($0 as? NSTextField)?.placeholderString == AskField.placeholder
        }.count
    }
}
