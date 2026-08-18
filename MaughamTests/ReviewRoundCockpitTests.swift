import XCTest
import SwiftUI
import AppKit
@testable import Maugham
import MaughamCore

/// **The round cockpit — Review's strip** (M4 P2 Task 3).
///
/// The queue is where a reviewer lives, and until this task the loop that
/// fills it was invisible from there: which pass the piece is being read
/// through, which editor reads it, which round they are on, and how to ask
/// for the next one. The cockpit says all four in a strip below the toolbar
/// and above the notes.
///
/// Three kinds of test, on this suite's house rules:
///
/// - **Pure**, for every decision the strip makes — the lane line, the
///   docId-scoped run phase, the report line's mutual exclusion, the empty
///   queue's teaching. None of them needs a window.
/// - **Mounted**, for what a reviewer actually sees and presses.
///   `accessibilityPerformPress` is the delivery path here, as it is in
///   `DiagnosticsPaneTests` — the same action a click runs, without the
///   active-app premise a synthetic `mouseDown` needs.
/// - **Census**, for what a mount cannot see: that the pane feeds the strip
///   the *unfiltered* queue; that the picker's write is the window's one
///   writer rather than a second spelling of it; that the picker's own menu
///   item calls the verb the mounted tests drive in its place; and that the
///   strip is mounted below the toolbar rather than inside it.
///
/// The strip's WIDTH is measured where the column's other width claims live —
/// `AnnotationsQueueToolbarWidthTests`, which owns the instrument.
@MainActor
final class ReviewRoundCockpitTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var roots: [URL] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private static let copyedit = ReviewPass(
        id: "copyedit", name: "Copyedit", brief: "b", editorName: "Gould")
    private static let line = ReviewPass(
        id: "line", name: "Line", brief: "b", editorName: "Lish")
    /// A pass a writer named themselves and never gave an editor — its
    /// `effectiveEditorName` falls back to its own name.
    private static let betaRead = ReviewPass(id: "beta", name: "Beta Read")

    // MARK: - The lane line

    /// **"<Pass> · <Editor> · round N"** — the whole of what a reviewer needs
    /// to know about where they are before they press anything.
    func test_theLaneLineNamesThePassItsEditorAndTheRound() {
        XCTAssertEqual(
            ReviewRoundCockpit.laneLine(pass: Self.copyedit, round: 3),
            "Copyedit \u{00b7} Gould \u{00b7} round 3",
            "the lane line must name the pass, the editor reading it, and the "
            + "round \u{2014} an editor by name is the whole personification")
    }

    /// **"round —" before any round has run**, never "round 0" and never a
    /// silent omission: a piece with a pass set and no round yet is exactly
    /// the state the Run button is for, and the line must say so.
    func test_theLaneLineSaysRoundDashBeforeAnyRoundHasRun() {
        XCTAssertEqual(
            ReviewRoundCockpit.laneLine(pass: Self.copyedit, round: nil),
            "Copyedit \u{00b7} Gould \u{00b7} round \u{2014}")
    }

    /// A pass with no editor of its own falls back to its own NAME
    /// (`ReviewPass.effectiveEditorName`), so the naive line would read
    /// "Beta Read · Beta Read · round 1". The line collapses it.
    func test_theLaneLineDoesNotSayACustomPassNameTwice() {
        XCTAssertEqual(
            ReviewRoundCockpit.laneLine(pass: Self.betaRead, round: 1),
            "Beta Read \u{00b7} round 1",
            "a pass whose editor IS its name must not be named twice")
    }

    /// The editor is resolved through `effectiveEditorName`, never the raw
    /// field: a customized manifest can store a preset-id pass that predates
    /// the field, and reading `pass.editorName` would put nothing on screen.
    func test_theLaneLineResolvesAPresetIdPassThatCarriesNoEditorOfItsOwn() {
        let stored = ReviewPass(id: "copyedit", name: "Copyedit")
        XCTAssertEqual(
            ReviewRoundCockpit.laneLine(pass: stored, round: 2),
            "Copyedit \u{00b7} Gould \u{00b7} round 2",
            "`effectiveEditorName` is the ONE spelling of the resolution")
    }

    // MARK: - The run phase is scoped to THIS document

    /// **The falsification this task's second reader exists for.** The run
    /// state is per WINDOW; the cockpit is per DOCUMENT. Drop the
    /// `runDocId == docId` scope and a run on chapter 2 makes chapter 1's
    /// cockpit claim it is being checked and refuse its own Run button.
    func test_anotherDocumentsRunLeavesThisCockpitIdle() {
        let elsewhere = CompilerOrchestrator.RunState.running(
            docId: "ch-2", checking: CompilerOrchestrator.DeltaCounts(new: 4, revised: 1))

        XCTAssertEqual(
            ReviewRoundCockpit.phase(runState: elsewhere, docId: "ch-1"), .idle,
            "a run on ANOTHER document must leave this cockpit idle \u{2014} the "
            + "run state is per window, the cockpit is per document")
    }

    func test_thePhaseCarriesThisDocumentsDelta() {
        let counts = CompilerOrchestrator.DeltaCounts(new: 4, revised: 1)
        XCTAssertEqual(
            ReviewRoundCockpit.phase(
                runState: .running(docId: "ch-1", checking: counts), docId: "ch-1"),
            .running(counts))
    }

    /// Every state that is not a run in flight on this document reads idle —
    /// `.nothingNew` and `.failed` describe runs that are OVER, and the strip
    /// must offer its buttons again the moment one ends.
    func test_everyFinishedStateReadsIdle() {
        for state: CompilerOrchestrator.RunState in [
            .idle,
            .nothingNew(docId: "ch-1", at: Date()),
            .failed(docId: "ch-1", failure: .unusableOutput, at: Date()),
        ] {
            XCTAssertEqual(ReviewRoundCockpit.phase(runState: state, docId: "ch-1"), .idle,
                           "\(state) is not a run in flight")
        }
    }

    // MARK: - The report line

    /// The strip carries ONE line after a round, and the two candidates are
    /// mutually exclusive by construction (`RoundNarrative`): a cold read was
    /// briefed on no prior findings, so a comparison drawn over it would name
    /// a difference the run never made.
    func test_theReportLineIsTheFreshEyesHeaderForAColdRead() {
        let run = makeRun(round: 3, passId: "copyedit", freshEyes: true)
        XCTAssertEqual(
            ReviewRoundCockpit.reportLine(
                history: [makeRecord(round: 2, passId: "copyedit")],
                run: run, annotations: []),
            "Fresh eyes \u{00b7} round 3",
            "a fresh-eyes round says what it IS, in the slot the comparison "
            + "would have taken")
    }

    func test_theReportLineIsTheComparisonForAWarmRound() {
        let run = makeRun(round: 3, passId: "copyedit", freshEyes: nil)
        let line = ReviewRoundCockpit.reportLine(
            history: [makeRecord(round: 2, passId: "copyedit")],
            run: run, annotations: [])
        XCTAssertEqual(line, "Since round 2: 0 resolved \u{00b7} 0 persisting \u{00b7} 0 new")
    }

    /// A passless ⌘R is an ordinary M2 run — no round, nothing to be *since*,
    /// and no line at all rather than an empty one.
    func test_theReportLineIsSilentForAPasslessRun() {
        XCTAssertNil(ReviewRoundCockpit.reportLine(
            history: [], run: makeRun(round: nil, passId: nil, freshEyes: nil),
            annotations: []))
        XCTAssertNil(ReviewRoundCockpit.reportLine(
            history: [], run: nil, annotations: []))
    }

    // MARK: - The empty queue teaches the loop

    /// **The Review copy carry.** An empty queue used to say only "ask Claude
    /// for editorial feedback" — which is one of the two ways it fills, and no
    /// longer the one the persona is built around.
    func test_theEmptyQueueNamesBothWaysItFills() {
        let withPass = ReviewRoundCockpit.emptyQueueTeaching(editorName: "Gould")
        XCTAssertTrue(withPass.contains("Run Gould\u{2019}s round (\u{2318}R)"),
                      "the round is the first way, and it is named for the "
                      + "editor who reads it \u{2014} got: \(withPass)")
        XCTAssertTrue(withPass.contains("Claude Desktop"),
                      "and asking Claude is the second \u{2014} got: \(withPass)")

        let withoutPass = ReviewRoundCockpit.emptyQueueTeaching(editorName: nil)
        XCTAssertTrue(withoutPass.contains("\u{2318}R"),
                      "with no pass set there is no editor to name, and the "
                      + "keystroke still is \u{2014} got: \(withoutPass)")
        XCTAssertTrue(withoutPass.contains("Claude Desktop"))
    }

    // MARK: - Mounted: what a reviewer sees

    func test_theCockpitShowsThePassItsEditorAndTheRound() throws {
        let window = mountCockpit(activePassId: "copyedit", round: 3)
        let labels = allLabels(in: window)

        XCTAssertTrue(labels.contains("Copyedit \u{00b7} Gould \u{00b7} round 3"),
                      "the lane line never reached the strip \u{2014} got \(labels)")
        XCTAssertNotNil(findButton(labelled: ReviewRoundCockpit.runTitle, in: window),
                        "the strip must offer the round")
        XCTAssertNotNil(findButton(labelled: ReviewRoundCockpit.freshEyesTitle, in: window),
                        "\u{2026}and the cold read beside it")
    }

    /// The picker appears **exactly** when no pass is active — it is the one
    /// affordance that turns a piece nobody has assigned a pass into one the
    /// loop can run on, and it must not sit beside a lane line that already
    /// answers the same question.
    func test_thePickerAppearsExactlyWhenNoPassIsActive() throws {
        let unassigned = allLabels(in: mountCockpit(activePassId: nil, round: nil))
        XCTAssertTrue(unassigned.contains { $0.contains(ReviewRoundCockpit.setAPassTitle) },
                      "a piece with no active pass must be offered one \u{2014} "
                      + "got \(unassigned)")

        let assigned = allLabels(in: mountCockpit(activePassId: "copyedit", round: 1))
        XCTAssertFalse(assigned.contains { $0.contains(ReviewRoundCockpit.setAPassTitle) },
                       "a piece already in a pass must not carry the picker too "
                       + "\u{2014} got \(assigned)")
    }

    /// **The picker's choice records through the window's ONE writer.**
    ///
    /// The item's action is `setPass(_:)` — the same call the mounted menu
    /// item makes (a SwiftUI `Menu`'s items do not exist until the writer
    /// opens it, measured in `InspectorPassLadderTests`, so this is the
    /// closest a test can get to the item and it is the identical code path).
    /// What it is wired to here is exactly what `ProjectWindow.recordActivePass`
    /// does, and the census below pins that the production mount wires it
    /// there and nowhere else.
    func test_thePickersChoiceRecordsThroughTheWindowsOneWriter() async throws {
        let fx = try await makeHarness()
        let cockpit = ReviewRoundCockpit(
            passes: [Self.line, Self.copyedit],
            activePassId: nil,
            round: nil,
            phase: .idle,
            reportLine: nil,
            onRun: { _ in },
            onSetActivePass: { passId in
                fx.documentStore.updateUIState {
                    $0.activePassMemory.record(piece: "ch-1", passId: passId)
                }
            })

        cockpit.setPass("copyedit")

        XCTAssertEqual(
            fx.documentStore.uiState.activePassMemory.activePass(forPiece: "ch-1"),
            "copyedit",
            "choosing a pass in the cockpit must record it as the piece's "
            + "active pass \u{2014} the value the RUN reads to mint its lane")
    }

    /// While this document is being checked the strip says what is being read
    /// — `RoundNarrative.checkingCopy`, the pane's own copy and not a second
    /// spelling — and both buttons refuse with a reason (RULING-35).
    func test_whileRunningTheStripSaysWhatItIsCheckingAndBothButtonsRefuse() throws {
        let counts = CompilerOrchestrator.DeltaCounts(new: 14, revised: 2)
        let window = mountCockpit(
            activePassId: "copyedit", round: 2, phase: .running(counts))

        XCTAssertTrue(allLabels(in: window).contains(RoundNarrative.checkingCopy(counts)),
                      "the wait must be legible \u{2014} got \(allLabels(in: window))")
        for title in [ReviewRoundCockpit.runTitle, ReviewRoundCockpit.freshEyesTitle] {
            let button = try XCTUnwrap(findButton(labelled: title, in: window),
                                       "\(title) must still be drawn while running")
            XCTAssertEqual(axEnabled(button), false,
                           "\(title) must refuse while this document is being "
                           + "checked \u{2014} a second turn is what the NEXT "
                           + "keystroke does")
        }
    }

    /// The control for the refusal above: idle, both buttons are pressable.
    /// Without it a strip that never enabled them at all would pass the test
    /// this pair exists for.
    func test_whenNothingIsRunningBothButtonsArePressable() throws {
        let window = mountCockpit(activePassId: "copyedit", round: 2)
        for title in [ReviewRoundCockpit.runTitle, ReviewRoundCockpit.freshEyesTitle] {
            let button = try XCTUnwrap(findButton(labelled: title, in: window))
            XCTAssertEqual(axEnabled(button), true,
                           "premise: \(title) is live when no run is in flight")
        }
    }

    /// **The end-to-end pin: the cockpit's Run button drives a real round, and
    /// the notes it lands are signed by the pass's own editor.**
    ///
    /// The whole delivery path, in one test: the real `AnnotationsPane`, the
    /// real strip inside it, the button pressed the way a click presses it,
    /// the real `CompilerOrchestrator.runRequested`, the real mint — and
    /// "Gould", not "Claude", on the notes at the end of it.
    func test_theRunButtonDrivesARealRoundWhoseNotesTheEditorSigns() async throws {
        let fx = try await makeHarness()
        let pid = try XCTUnwrap(fx.document.sequence.first)
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "copyedit")
        }
        fx.runner.nextEvent = .resultText(Self.questionAndReport(about: pid))

        let window = mountPane(fx, scope: .document, orchestrator: fx.orchestrator)
        let run = try button(labelled: ReviewRoundCockpit.runTitle, in: window)
        _ = run.perform(NSSelectorFromString("accessibilityPerformPress"))

        await awaitOpenNotes(2, on: fx.document)
        let notes = fx.document.annotations(filter: AnnotationFilter(statuses: [.open]))
        XCTAssertEqual(notes.count, 2,
                       "the cockpit's Run button must reach the same run \u{2318}R "
                       + "takes \u{2014} got \(notes.map(\.body))")
        for note in notes {
            XCTAssertEqual(note.author?.displayName, "Gould",
                           "the Copyedit pass's editor signs its round's notes")
            XCTAssertEqual(note.reviewPassId, "copyedit",
                           "and the round's lane stamps what it wrote")
        }
    }

    /// **Project scope renders no cockpit.** The strip is a statement about
    /// ONE piece's pass, round and next run; across the project every section
    /// is a different piece with a different answer, and a single strip there
    /// could only be wrong.
    func test_projectScopeRendersNoCockpit() async throws {
        let fx = try await makeHarness()
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "copyedit")
        }

        let window = mountPane(fx, scope: .project(focusPiece: nil),
                               orchestrator: fx.orchestrator)

        XCTAssertNil(findButton(labelled: ReviewRoundCockpit.runTitle, in: window),
                     "the cockpit is a piece's, and project scope has no piece")
        XCTAssertFalse(allLabels(in: window).contains {
            $0.contains("Copyedit \u{00b7} Gould")
        }, "\u{2026}and no lane line either")
    }

    /// **A host with no compiler behind it draws no strip.** The pane is
    /// registered in Review and reachable by ⌘⌥A in every persona, and the
    /// probe mounts pass neither store — a Run button over a `nil`
    /// orchestrator would be a control with nothing to call, which is a crash
    /// at best and RULING-35's dead control at worst.
    ///
    /// Asserted against the SAME fixture that draws the strip in
    /// `test_theRunButtonDrivesARealRoundWhoseNotesTheEditorSigns`, so the one
    /// difference between the two is the store.
    func test_aHostWithNoCompilerDrawsNoStrip() async throws {
        let fx = try await makeHarness()
        fx.documentStore.updateUIState {
            $0.activePassMemory.record(piece: "ch-1", passId: "copyedit")
        }

        let window = mountPane(fx, scope: .document, orchestrator: nil)

        XCTAssertNil(findButton(labelled: ReviewRoundCockpit.runTitle, in: window),
                     "a nil orchestrator must draw no Run button \u{2014} there "
                     + "is nothing for it to call")
        XCTAssertNil(findButton(labelled: ReviewRoundCockpit.freshEyesTitle, in: window))
        XCTAssertFalse(allLabels(in: window).contains {
            $0.contains("Copyedit \u{00b7} Gould")
        }, "\u{2026}and no lane line, however much the pass memory knows")
    }

    // MARK: - Census: the seams a mount cannot see

    /// **Whole-branch seam (a).** `sinceLastRoundLine` counts the writer's
    /// QUEUE — what they settled, what persists, what is new — and the pane's
    /// visible rows are filtered by author, status, triage and pass. Feeding
    /// it those would make "resolved" permanently zero under the default
    /// `[.open]` filter and would skew every count under any other.
    func test_theStripIsFedTheUnfilteredQueueAndNotTheVisibleRows() throws {
        let source = try Self.source(of: "Views/AnnotationsPane.swift")
        let read = try XCTUnwrap(
            Self.declaration(named: "private var cockpitAnnotations:", in: source),
            "the strip's annotation read must be a readable declaration")

        XCTAssertTrue(read.contains("AnnotationFilter(statuses: nil)"),
                      "the strip counts the queue in EVERY state \u{2014} a "
                      + "`[.open]` filter here reports zero resolved forever")
        XCTAssertTrue(read.contains("annotationsVersion"),
                      "\u{2026}and observes the document's version, so a note "
                      + "stetted in the queue moves the line")
        for filtered in ["visibleAnnotations", "kindStatusPool", "passesRowFilters"] {
            XCTAssertFalse(read.contains(filtered),
                           "the strip must not read the pane's FILTERED rows "
                           + "(`\(filtered)`)")
        }
    }

    /// The picker's write stays `ProjectWindow.recordActivePass` — the one
    /// writer of `UIState.activePassMemory`. A second spelling in the pane or
    /// in the mount is two places that can disagree about which pass a piece
    /// is in, and the RUN reads only one of them.
    func test_theProductionMountWiresThePickerToTheWindowsOneWriter() throws {
        let window = try Self.source(of: "Views/ProjectWindow.swift")
        XCTAssertTrue(window.contains("onSetActivePass:"),
                      "the window must supply the strip's pass writer")
        let arm = try XCTUnwrap(
            window.range(of: "onSetActivePass:"),
            "the mount must name the closure")
        let after = String(window[arm.upperBound...].prefix(320))
        XCTAssertTrue(after.contains("recordActivePass(forPiece:"),
                      "\u{2026}and it must be the existing private writer, not a "
                      + "second `updateUIState` in the mount \u{2014} got: \(after)")

        let pane = try Self.source(of: "Views/AnnotationsPane.swift")
        XCTAssertFalse(pane.contains("activePassMemory.record("),
                       "the queue advises about passes; it never rules on one "
                       + "\u{2014} the write belongs to the window")
    }

    /// **The link the mounted tests borrow, pinned.**
    ///
    /// `test_thePickersChoiceRecordsThroughTheWindowsOneWriter` drives
    /// `setPass(_:)` directly, because a SwiftUI `Menu` builds its items only
    /// when the writer opens it and the item itself is unreachable from a
    /// hosted view (measured in `InspectorPassLadderTests`). That substitution
    /// is honest only while the item actually calls `setPass` — and nothing
    /// mounted can see whether it does. Rewiring `passPicker`'s button to a
    /// local `@State`, or to `onSetActivePass` under a second spelling, leaves
    /// every other test in this file green over a picker that no longer
    /// records anything.
    ///
    /// So the link is a census over the picker's own declaration. It is the
    /// weakest seam in this task and it is the one the review found.
    func test_thePickersItemCallsTheVerbTheTestsDriveItThrough() throws {
        let source = try Self.source(of: "Views/Review/ReviewRoundCockpit.swift")
        let picker = try XCTUnwrap(
            Self.declaration(named: "private var passPicker:", in: source),
            "the picker must still be a readable declaration for this census "
            + "to have a subject")

        XCTAssertTrue(picker.contains("setPass(pass.id)"),
                      "the picker's menu item must call `setPass(pass.id)` — "
                      + "the verb `test_thePickersChoiceRecordsThroughThe"
                      + "WindowsOneWriter` drives in its place. Anything else "
                      + "here and that test proves nothing about this control. "
                      + "Got:\n\(picker)")
        XCTAssertTrue(picker.contains("ForEach(passes)"),
                      "\u{2026}once per pass the project names, so a project "
                      + "that renamed its ladder offers its own passes")
    }

    /// **The strip is not in the toolbar.** `AnnotationsQueueToolbar`'s one
    /// job is fitting a 240pt column, and its width census
    /// (`AnnotationsQueueToolbarWidthTests`) measures the row as declared —
    /// a control added there would inflate the pane's layout width and centre
    /// every annotation body against a width the column does not have.
    func test_theStripLivesBelowTheToolbarAndNotInsideIt() throws {
        let toolbar = try Self.source(of: "Views/Review/AnnotationsQueueToolbar.swift")
        XCTAssertFalse(toolbar.contains("ReviewRoundCockpit"),
                       "the cockpit must not be drawn inside the toolbar")

        let pane = try Self.source(of: "Views/AnnotationsPane.swift")
        let body = try XCTUnwrap(Self.declaration(named: "var body: some View {", in: pane))
        guard let toolbarLine = body.range(of: "toolbar"),
              let cockpitLine = body.range(of: "roundCockpit") else {
            return XCTFail("the body must mount the toolbar and then the strip")
        }
        XCTAssertTrue(toolbarLine.lowerBound < cockpitLine.lowerBound,
                      "the strip wraps BELOW the toolbar's divider")
    }

    // MARK: - Mounting

    private func mountCockpit(
        activePassId: String?,
        round: Int?,
        phase: ReviewRoundCockpit.RunPhase = .idle,
        reportLine: String? = nil
    ) -> NSWindow {
        mount(AnyView(ReviewRoundCockpit(
            passes: [Self.line, Self.copyedit],
            activePassId: activePassId,
            round: round,
            phase: phase,
            reportLine: reportLine,
            onRun: { _ in },
            onSetActivePass: { _ in })))
    }

    /// `orchestrator` is explicit and **undefaulted** so the no-compiler host
    /// can be mounted off the same fixture with the store as the ONLY
    /// difference — and so a default could never quietly turn the run-button
    /// test into a test of a strip that was never drawn.
    private func mountPane(
        _ fx: Harness, scope: AnnotationScope,
        orchestrator: CompilerOrchestrator?
    ) -> NSWindow {
        mount(AnyView(AnnotationsPane(
            document: fx.document,
            store: fx.store,
            documentStore: fx.documentStore,
            scope: .constant(scope),
            onTravel: { _ in },
            orchestrator: orchestrator,
            diagnostics: fx.diagnostics,
            onSetActivePass: { _, _ in })
            .environment(UserPreferences(
                defaults: UserDefaults(suiteName: "Cockpit-\(UUID())")!))))
    }

    private func mount(_ view: AnyView) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 700)
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

    // MARK: - Accessibility (mirrors DiagnosticsPaneTests' readers)

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    /// Whether an AX element reports itself pressable.
    ///
    /// **Neither shortcut works here** (measured 2026-08-17, macOS 26.6):
    /// SwiftUI's hosted `AccessibilityNode` does NOT respond to
    /// `accessibilityEnabled` — only to the KVC getter `isAccessibilityEnabled`
    /// — and the value it returns is an `__NSCFNumber`, which `as? Bool` fails
    /// on because only `__NSCFBoolean` bridges. So the generic `axAttribute`
    /// reader answers `nil` for both reasons at once, which reads exactly like
    /// "the button is neither enabled nor disabled". `NSNumber.boolValue` is
    /// what makes the answer a fact.
    private func axEnabled(_ element: AnyObject) -> Bool? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString("isAccessibilityEnabled"))
        else { return nil }
        return (object.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue
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
                + "never built the tree this test reads")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    private func button(labelled label: String, in window: NSWindow) throws -> NSObject {
        var lastAll: [AnyObject] = []
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            lastAll = try axTree(in: window)
                .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            if let match = lastAll.first(
                where: { (axAttribute($0, "accessibilityLabel") as? String) == label }
            ) as? NSObject {
                return match
            }
            pump(0.05)
        }
        return try XCTUnwrap(
            lastAll.first { (axAttribute($0, "accessibilityLabel") as? String) == label }
                as? NSObject,
            "no button labelled \u{201C}\(label)\u{201D} reached the hosted view. "
            + "Buttons found: "
            + "\(lastAll.map { axAttribute($0, "accessibilityLabel") as? String ?? "nil" })")
    }

    /// The non-recording sibling, for a "must NOT be present" assertion.
    private func findButton(labelled label: String, in window: NSWindow) -> NSObject? {
        guard let tree = try? axTree(in: window) else { return nil }
        return tree
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .first { (axAttribute($0, "accessibilityLabel") as? String) == label } as? NSObject
    }

    private func allLabels(in window: NSWindow) -> [String] {
        guard let tree = try? axTree(in: window) else { return [] }
        return tree.compactMap {
            axAttribute($0, "accessibilityValue") as? String
                ?? axAttribute($0, "accessibilityLabel") as? String
        }
    }

    // MARK: - Fixtures

    private func makeRun(round: Int?, passId: String?, freshEyes: Bool?) -> CompilerRun {
        CompilerRun(id: "r-\(round ?? 0)", at: Date(), model: "test-model",
                    lastOpId: "op-1", deltaSummary: "1 new", intentSnapshot: nil,
                    passId: passId, round: round, freshEyes: freshEyes)
    }

    private func makeRecord(round: Int, passId: String?) -> RoundRecord {
        RoundRecord(runId: "r-\(round)", at: Date().addingTimeInterval(-600),
                    passId: passId, round: round, freshEyes: nil, fingerprints: [])
    }

    private static func questionAndReport(about paragraphId: String) -> String {
        """
        {"section":"conformance","checks":[]}
        {"section":"continuity","questions":[{"cites":"the fog","refs":["\(paragraphId)"],"question":"Has anyone said how long yet?"}]}
        {"section":"reader","reports":[{"kind":"belief","refs":["\(paragraphId)"],"report":"The reader stopped believing the fog."}]}
        {"section":"facts","candidates":[]}
        """
    }

    private func awaitOpenNotes(_ count: Int, on document: Document) async {
        let deadline = Date().addingTimeInterval(8)
        while document.annotations(filter: AnnotationFilter(statuses: [.open])).count < count,
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private struct Harness {
        let orchestrator: CompilerOrchestrator
        let diagnostics: DiagnosticsStore
        let document: Document
        let store: ProjectStore
        let documentStore: DocumentStore
        let runner: SpyRunner
        let root: URL
    }

    /// A real project on disk with one chapter open, and a compiler whose only
    /// substitution is the subprocess — production would spawn a billing
    /// `claude -p` here. Mirrors `CompilerRunCommandTests.makeLiveDocumentHarness`.
    private func makeHarness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewRoundCockpit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let docPath = "manuscript/ch1.md"
        try "The fog came.\n".write(
            to: root.appendingPathComponent(docPath), atomically: true, encoding: .utf8)
        let chapter = StructureItem(id: "ch-1", title: "Chapter 1", type: .document,
                                    path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [chapter], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest)
            .write(to: root.appendingPathComponent("project.maugham.json"))

        let store = try await ProjectStore.load(from: root)
        let documentStore = try await DocumentStore.open(url: root)
        store.documentStore = documentStore
        let document = try await Document.load(
            url: root.appendingPathComponent(docPath),
            device: "test-mac", session: "s", presenter: nil)
        documentStore.register(document: document, for: docPath)

        let device = DeviceSlug.make(from: "test-mac")
        let diagnostics = DiagnosticsStore(projectRoot: root, device: device)
        let declaredWorld = DeclaredWorldStore(projectRoot: root, device: device)
        let configURL = root.appendingPathComponent("compiler-mcp.json")
        let runner = SpyRunner()
        var environment = CompilerOrchestrator.Environment.production(
            store: store, documentStore: documentStore, projectURL: root,
            declaredWorld: declaredWorld,
            bible: BibleStore(projectRoot: root, device: device),
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "CockpitHarness-\(UUID())")!),
            onRunAcknowledged: { _ in })
        environment.writeMCPConfig = {
            try Data("{}".utf8).write(to: configURL, options: .atomic)
            return configURL
        }
        environment.makeRunner = { _, _ in runner }
        let orchestrator = CompilerOrchestrator()
        orchestrator.configure(environment: environment, diagnostics: diagnostics)

        return Harness(orchestrator: orchestrator, diagnostics: diagnostics,
                       document: document, store: store, documentStore: documentStore,
                       runner: runner, root: root)
    }

    /// A runner that answers what the test says. Mirrors
    /// `CompilerRunCommandTests.SpyRunner`.
    @MainActor
    final class SpyRunner: CompilerRunner {
        var isRunning = false
        var sessionEpoch = 1
        var nextEvent: CompilerRunEvent? = .resultText(#"{"section":"conformance","checks":[]}"#)
        private(set) var sendCount = 0
        private var held: CheckedContinuation<CompilerRunEvent, Never>?
        private var partialHandler: (@MainActor (String) -> Void)?

        func setPartialHandler(_ handler: (@MainActor (String) -> Void)?) {
            partialHandler = handler
        }

        func send(message: String, systemPreamble: String?) async -> CompilerRunEvent {
            sendCount += 1
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
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)))
        }

        func shutdown() {
            release(.failed(.sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown)))
        }
    }

    // MARK: - Source access

    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
        return try String(
            contentsOf: root.appendingPathComponent("Maugham/\(relativePath)"),
            encoding: .utf8)
    }

    /// The text from `name` to the end of its brace-balanced body.
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
}
