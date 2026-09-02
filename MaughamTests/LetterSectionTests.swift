import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The letter on screen** (editorial letter P1 Task 9, spec §3.5).
///
/// Two kinds of test, on the house rules the mounted suites here already keep:
///
/// - **Pure**, for every decision the section makes without a window — the
///   signature, the turn-less predicate, the charge column, the chip's
///   fallback, "and N more".
/// - **Mounted**, headless through `TestWindow.mount`, for what the writer
///   actually reads and presses. The ORDER of `axTexts` is asserted rather
///   than mere presence: the schema's reading order is the whole of what a
///   letter is, and a section that drew every part in the wrong sequence
///   would pass a presence check while reading as a list of findings — the
///   one thing the letter exists not to be.
///
/// `accessibilityPerformPress` is the delivery path, as it is in
/// `DiagnosticsPaneTests`: the same action a click performs, without the
/// active-app premise a synthetic `mouseDown` needs.
@MainActor
final class LetterSectionTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        warmUpAccessibility()
    }

    override func tearDown() {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    nonisolated private static func ref(
        _ pid: String, _ excerpt: String = "The fog came in."
    ) -> Diagnostic.Ref {
        Diagnostic.Ref(paragraphId: pid, excerpt: excerpt)
    }

    /// A letter with every part filled — the reading-order fixture.
    nonisolated private static func fullLetter(
        scenePosition: String? = ScenePosition.strongDefault.rawValue,
        scenes: [Letter.Scene]? = [
            Letter.Scene(refs: [ref("a1b2")], wants: "To be let in",
                         changes: "The door opens", turn: "", charge: nil),
        ],
        habits: [Letter.Habit] = [
            Letter.Habit(name: "Every paragraph starts with a subject",
                         refs: [ref("a1b2"), ref("c3d4")],
                         cost: "The rhythm flattens.",
                         lesson: "Vary the opening.",
                         exercise: "Rewrite the scene without a single \u{201C}was\u{201D}."),
        ]
    ) -> Letter {
        Letter(
            about: "A ghost story told through weather.",
            oneThing: "Give the reader the dock before the fire.",
            working: [
                Letter.Working(refs: [ref("a1b2")], what: "The weather carries the dread",
                               why: "It never explains itself."),
            ],
            habits: habits,
            questions: [
                Letter.Question(refs: [ref("a1b2"), ref("c3d4"), ref("e5f6")],
                                question: "Is the dock standing again by this scene?",
                                lessonHeading: nil),
            ],
            scenes: scenes,
            scenePosition: scenePosition)
    }

    nonisolated private static func bareLetter(
        about: String = "A ghost story told through weather."
    ) -> Letter {
        Letter(about: about, oneThing: nil, working: [], habits: [],
               questions: [], scenes: nil, scenePosition: nil)
    }

    // MARK: - Pure: the decisions

    /// The signature is the voice's name and the round it signed — never the
    /// pass, which Review already draws directly above it and Author cannot
    /// name at all.
    func test_theSignatureNamesTheVoiceAndTheRound() {
        XCTAssertEqual(
            LetterSection.signature(voice: "Le Guin", round: 3),
            "\u{2014} Le Guin \u{00b7} round 3")
        XCTAssertEqual(
            LetterSection.signature(voice: "Claude", round: nil),
            "\u{2014} Claude",
            "a passless run has no round to sign \u{2014} \u{201C}round \u{2014}\u{201D} "
            + "here would invent one")
    }

    /// A blank `turn` cell is a scene that does not turn, and whitespace is
    /// the same blank — the model writes `""`, and a stray space must not
    /// silently take the offer away.
    func test_aBlankOrWhitespaceTurnIsATurnlessScene() {
        let blank = Self.fullLetter(scenes: [
            Letter.Scene(refs: [], wants: "w", changes: "c", turn: "", charge: nil),
        ])
        let spaced = Self.fullLetter(scenes: [
            Letter.Scene(refs: [], wants: "w", changes: "c", turn: "   ", charge: nil),
        ])
        let turned = Self.fullLetter(scenes: [
            Letter.Scene(refs: [], wants: "w", changes: "c",
                         turn: "She stops asking", charge: nil),
        ])
        XCTAssertTrue(LetterSection.hasTurnlessScene(blank))
        XCTAssertTrue(LetterSection.hasTurnlessScene(spaced))
        XCTAssertFalse(
            LetterSection.hasTurnlessScene(turned),
            "every row turning is exactly the case with nothing to offer")
        XCTAssertFalse(
            LetterSection.hasTurnlessScene(Self.bareLetter()),
            "no table at all cannot have a turn-less row in it")
    }

    /// The chip shows the paragraph as it reads NOW; the ref's remembered
    /// excerpt is the fallback for a paragraph this host cannot read, and a
    /// ref with neither draws no chip at all rather than a button labelled
    /// nothing.
    func test_theChipPrefersTheLiveParagraphAndFallsBackToTheRefsOwnWords() {
        let ref = Self.ref("a1b2", "The fog came in.")
        XCTAssertEqual(
            LetterSection.chipRef(for: ref, currentText: { _ in "The fog has gone." })?
                .excerpt,
            "The fog has gone.")
        XCTAssertEqual(
            LetterSection.chipRef(for: ref, currentText: { _ in nil })?.excerpt,
            "The fog came in.",
            "a paragraph the host cannot read must still travel as the words the "
            + "letter quoted, never as a bare id")
        XCTAssertNil(
            LetterSection.chipRef(
                for: Self.ref("a1b2", "  "), currentText: { _ in "" }),
            "a chip with no words in it would be a button labelled nothing")
    }

    func test_andMoreCountsTheRefsTheRowDoesNotDraw() {
        XCTAssertNil(LetterSection.andMore([]))
        XCTAssertNil(LetterSection.andMore([Self.ref("a1b2")]))
        XCTAssertEqual(
            LetterSection.andMore([Self.ref("a1b2"), Self.ref("c3d4")]), "and 1 more")
        XCTAssertEqual(
            LetterSection.andMore(
                [Self.ref("a1b2"), Self.ref("c3d4"), Self.ref("e5f6")]), "and 2 more")
    }

    func test_theChargeColumnIsDecidedByWhetherAnyRowCarriesOne() {
        XCTAssertFalse(LetterSection.hasCharge([
            Letter.Scene(refs: [], wants: "w", changes: "c", turn: "t", charge: nil),
        ]))
        XCTAssertFalse(LetterSection.hasCharge([
            Letter.Scene(refs: [], wants: "w", changes: "c", turn: "t", charge: ""),
        ]))
        XCTAssertTrue(LetterSection.hasCharge([
            Letter.Scene(refs: [], wants: "w", changes: "c", turn: "t", charge: nil),
            Letter.Scene(refs: [], wants: "w", changes: "c", turn: "t", charge: "+"),
        ]))
    }

    /// **The clause the offer files must be the clause the next round reads
    /// back.** `ScenePosition.derive` matches `turnClausePhrases` against the
    /// lowercased statement, so a wording change that broke this containment
    /// would leave the offer standing on every round forever with no test red.
    func test_theFiledClauseCarriesThePhraseTheNextRoundMatchesOn() {
        XCTAssertTrue(
            ScenePosition.turnClausePhrases.contains {
                LetterSection.turnClauseRuling.lowercased().contains($0)
            },
            "\u{201C}\(LetterSection.turnClauseRuling)\u{201D} must contain one of "
            + "\(ScenePosition.turnClausePhrases) \u{2014} otherwise filing it "
            + "changes nothing the next round can see")
    }

    // MARK: - Mounted: the reading order

    /// **The whole of what a letter is.** Every part, in the schema's reading
    /// order, asserted as an ORDER rather than as presence.
    func test_aFullLetterRendersEveryPartInReadingOrder() throws {
        let window = mount(Self.fullLetter(), onAddTurnClause: {})
        let texts = try axTexts(in: window)

        let expected = [
            LetterSection.title,
            "A ghost story told through weather.",
            "Give the reader the dock before the fire.",
            LetterSection.workingTitle,
            "The weather carries the dread",
            LetterSection.habitsTitle,
            "Every paragraph starts with a subject",
            LetterSection.questionsTitle,
            "Is the dock standing again by this scene?",
            LetterSection.scenesTitle,
            LetterSection.wantsColumn,
            LetterSection.turnOfferLine,
            "\u{2014} Le Guin \u{00b7} round 2",
            LetterSection.keepTitle,
        ]
        let positions = expected.map { needle in
            texts.firstIndex(of: needle) ?? -1
        }
        for (marker, position) in zip(expected, positions) {
            XCTAssertGreaterThanOrEqual(
                position, 0,
                "\u{201C}\(marker)\u{201D} never reached the surface. Read: \(texts)")
        }
        XCTAssertEqual(
            positions, positions.sorted(),
            "the parts must draw in the schema's reading order \u{2014} about, the "
            + "one thing, What's working, Habits, Questions, Scenes, the offer, the "
            + "signature, Keep this letter. Read: \(texts)")
    }

    /// **An empty part draws no header.** Asserted with a control in the same
    /// test, because "Habits is absent" is only evidence when the identical
    /// mount with a habit in it says Habits.
    func test_anEmptyPartDrawsNoHeaderAndAFilledOneDoes() throws {
        let bare = try axTexts(in: mount(Self.bareLetter()))
        for title in [LetterSection.workingTitle, LetterSection.habitsTitle,
                      LetterSection.questionsTitle, LetterSection.scenesTitle] {
            XCTAssertFalse(
                bare.contains(title),
                "a letter with nothing to say about \u{201C}\(title)\u{201D} must draw "
                + "no heading for it. Read: \(bare)")
        }
        XCTAssertTrue(
            bare.contains("A ghost story told through weather."),
            "about is the one always-present part and must still draw")

        let full = try axTexts(in: mount(Self.fullLetter()))
        for title in [LetterSection.workingTitle, LetterSection.habitsTitle,
                      LetterSection.questionsTitle, LetterSection.scenesTitle] {
            XCTAssertTrue(
                full.contains(title),
                "the control mount must draw \u{201C}\(title)\u{201D}, or the absence "
                + "above is evidence about nothing. Read: \(full)")
        }
    }

    /// `scenes == nil` (a piece that does not move by scenes) and
    /// `scenes == []` (a table with no rows) are different upstream and draw
    /// the same nothing here — neither is a table.
    func test_neitherAbsentNorEmptyScenesDrawATable() throws {
        for scenes in [nil, []] as [[Letter.Scene]?] {
            let texts = try axTexts(in: mount(Self.fullLetter(scenes: scenes)))
            XCTAssertFalse(
                texts.contains(LetterSection.scenesTitle),
                "scenes = \(String(describing: scenes)) is not a table. Read: \(texts)")
            XCTAssertFalse(texts.contains(LetterSection.wantsColumn))
        }
    }

    /// The charge column is drawn only over a table that has a charge in it —
    /// a column of blanks would say the reader had nothing to report about
    /// charge, where the weak form has no charge to report.
    func test_theChargeColumnDrawsOnlyWhenARowCarriesOne() throws {
        let weak = try axTexts(in: mount(Self.fullLetter(scenes: [
            Letter.Scene(refs: [], wants: "To be let in", changes: "The door opens",
                         turn: "She stops asking", charge: nil),
        ])))
        XCTAssertFalse(
            weak.contains(LetterSection.chargeColumn),
            "the weak form carries no charge at all. Read: \(weak)")

        let strong = try axTexts(in: mount(Self.fullLetter(scenes: [
            Letter.Scene(refs: [], wants: "To be let in", changes: "The door opens",
                         turn: "She stops asking", charge: "+"),
        ])))
        XCTAssertTrue(
            strong.contains(LetterSection.chargeColumn),
            "a table with a charge in it must say which column it is. Read: \(strong)")
    }

    /// A blank cell stays blank — the letter's prose may pick up a scene where
    /// nothing changes, and a dash drawn here would put a verdict in the
    /// reader's mouth.
    func test_aBlankCellDrawsBlank() throws {
        let texts = try axTexts(in: mount(Self.fullLetter(scenes: [
            Letter.Scene(refs: [], wants: "To be let in", changes: "",
                         turn: "", charge: nil),
        ])))
        XCTAssertFalse(
            texts.contains("\u{2014}"),
            "no em-dash stands in for a blank cell. Read: \(texts)")
        XCTAssertFalse(texts.contains("n/a"))
    }

    // MARK: - Mounted: the verbs

    /// A question row travels to its FIRST ref, and says how many more it
    /// stands for.
    func test_aQuestionRowJumpsToItsFirstRefAndSaysHowManyMore() throws {
        var jumped: [String] = []
        let window = mount(Self.fullLetter(), onJump: { jumped.append($0) })

        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains("and 2 more"),
            "a question standing on three paragraphs must say so. Read: \(texts)")

        let labels = try axButtonLabels(in: window)
        let chip = try XCTUnwrap(
            findChip(quoting: "The fog came in.", in: window),
            "the question's jump chip never reached the surface: \(labels)")
        press(chip)
        pump(0.1)
        XCTAssertEqual(
            jumped.first, "a1b2",
            "a question row jumps to its first ref \u{2014} that is the paragraph the "
            + "writer is being asked about")
    }

    /// **The count survives a first ref with no words left in it** (fix round
    /// 1, Minor 3). A habit citing three paragraphs stands on three whether or
    /// not the first of them still reads as anything — drawing the count only
    /// beside a chip made the row claim one place where there were three.
    func test_andNMoreIsDrawnEvenWhenTheFirstRefHasNoWordsLeft() throws {
        let window = mount(
            Self.fullLetter(),
            currentText: { _ in "" })   // every paragraph rewritten to nothing
        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains("and 2 more"),
            "the count is a fact about the note, not about the chip. Read: \(texts)")

        // The chip itself is correctly absent: a button labelled nothing is
        // worse than no button. The fixture's refs carry excerpts, so the
        // fallback is what has to be defeated here.
        let blankRefs = Letter(
            about: "A ghost story.", oneThing: nil, working: [], habits: [],
            questions: [Letter.Question(
                refs: [Self.ref("a1b2", " "), Self.ref("c3d4", " ")],
                question: "Is the dock standing again by this scene?",
                lessonHeading: nil)],
            scenes: nil, scenePosition: nil)
        let bare = try axTexts(in: mount(blankRefs, currentText: { _ in "" }))
        XCTAssertTrue(bare.contains("and 1 more"), "Read: \(bare)")
        XCTAssertFalse(
            bare.contains { $0.contains("\u{201C}") },
            "and no chip is drawn for a paragraph with no words. Read: \(bare)")
    }

    /// **Accept as task hands the habit over, once.** The button is disabled
    /// after the press rather than removed: a control that vanished on its own
    /// press leaves the writer unsure whether it fired.
    func test_acceptAsTaskHandsTheHabitOverAndThenRefuses() throws {
        var accepted: [Letter.Habit] = []
        let window = mount(Self.fullLetter(), onAcceptExercise: { accepted.append($0) })

        let labels = try axButtonLabels(in: window)
        let button = try XCTUnwrap(
            findButton(labelled: LetterSection.acceptTitle, in: window),
            "Accept as task never reached the surface: \(labels)")
        XCTAssertEqual(axEnabled(button), true, "it must be pressable before the press")

        press(button)
        pump(0.15)
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(
            accepted.first?.exercise,
            "Rewrite the scene without a single \u{201C}was\u{201D}.",
            "the habit handed over must be the one whose button was pressed")

        let after = try XCTUnwrap(
            findButton(labelled: LetterSection.acceptTitle, in: window),
            "the button must stay on screen, disabled, rather than disappearing")
        XCTAssertEqual(
            axEnabled(after), false,
            "a second press would file the same exercise twice")

        press(after)
        pump(0.15)
        XCTAssertEqual(
            accepted.count, 1,
            "a disabled Accept as task must not reach the handler")
    }

    /// A habit with no exercise offers nothing to accept — there is no thing
    /// to *do*, and a task carrying only the habit's name would be a note
    /// wearing a task's clothes. Control: the same mount with an exercise.
    func test_aHabitWithNoExerciseOffersNoAcceptAsTask() throws {
        let without = mount(Self.fullLetter(habits: [
            Letter.Habit(name: "Every paragraph starts with a subject",
                         refs: [Self.ref("a1b2")], cost: "The rhythm flattens.",
                         lesson: nil, exercise: nil),
        ]))
        let withoutLabels = try axButtonLabels(in: without)
        XCTAssertNil(
            findButton(labelled: LetterSection.acceptTitle, in: without),
            "there is nothing to file. Buttons: \(withoutLabels)")
        XCTAssertTrue(
            try axTexts(in: without).contains("Every paragraph starts with a subject"),
            "the habit itself must still be read \u{2014} it is the exercise that is "
            + "missing, not the observation")

        let with = mount(Self.fullLetter())
        XCTAssertNotNil(
            findButton(labelled: LetterSection.acceptTitle, in: with),
            "the control mount must offer it, or the absence above says nothing")
    }

    /// **The offer needs both halves.** A handler with no turn-less row, and a
    /// turn-less row with no handler, each draw nothing.
    func test_theOfferNeedsBothAHandlerAndATurnlessRow() throws {
        let turnless = [Letter.Scene(refs: [], wants: "w", changes: "c",
                                     turn: "", charge: nil)]
        let turning = [Letter.Scene(refs: [], wants: "w", changes: "c",
                                    turn: "She stops asking", charge: nil)]

        let offered = mount(Self.fullLetter(scenes: turnless), onAddTurnClause: {})
        XCTAssertTrue(try axTexts(in: offered).contains(LetterSection.turnOfferLine))
        XCTAssertNotNil(findButton(labelled: LetterSection.addToIntentTitle, in: offered))

        let noHandler = mount(Self.fullLetter(scenes: turnless), onAddTurnClause: nil)
        XCTAssertFalse(
            try axTexts(in: noHandler).contains(LetterSection.turnOfferLine),
            "a run whose writer already declared the clause \u{2014} or a host with "
            + "nowhere to file one \u{2014} must not be asked again")
        XCTAssertNil(findButton(labelled: LetterSection.addToIntentTitle, in: noHandler))

        let allTurning = mount(Self.fullLetter(scenes: turning), onAddTurnClause: {})
        XCTAssertFalse(
            try axTexts(in: allTurning).contains(LetterSection.turnOfferLine),
            "every scene already turns \u{2014} there is nothing for the clause to "
            + "bite on, and the offer would be a nag")
        XCTAssertNil(findButton(labelled: LetterSection.addToIntentTitle, in: allTurning))
    }

    func test_addToIntentCallsTheHostsHandler() throws {
        var filed = 0
        let window = mount(Self.fullLetter(), onAddTurnClause: { filed += 1 })
        press(try XCTUnwrap(
            findButton(labelled: LetterSection.addToIntentTitle, in: window)))
        pump(0.15)
        XCTAssertEqual(filed, 1)
    }

    /// A refused ruling says so, where the writer pressed. Without this the
    /// button would look pressed and the intent would not have moved.
    func test_aRefusedOfferSaysSoBesideTheButton() throws {
        let refusal = "There is nothing here to rule on yet."
        let shown = mount(Self.fullLetter(), onAddTurnClause: {}, offerFailure: refusal)
        XCTAssertTrue(
            try axTexts(in: shown).contains(refusal),
            "the refusal must be read where the press happened")

        let silent = mount(Self.fullLetter(), onAddTurnClause: {})
        XCTAssertFalse(
            try axTexts(in: silent).contains(refusal),
            "and nothing red is drawn when nothing was refused")
    }

    /// **Keep this letter is a real button now**; what it writes is Task 10.
    func test_keepThisLetterCallsTheClosure() throws {
        var kept = 0
        let window = mount(Self.fullLetter(), onKeep: { kept += 1 })
        press(try XCTUnwrap(findButton(labelled: LetterSection.keepTitle, in: window)))
        pump(0.15)
        XCTAssertEqual(kept, 1)
    }

    func test_theKeepConfirmationDrawsOnlyWhenAHostSuppliesOne() throws {
        let confirmation = "Kept in Research."
        XCTAssertTrue(
            try axTexts(in: mount(Self.fullLetter(), keepConfirmation: confirmation))
                .contains(confirmation))
        XCTAssertFalse(
            try axTexts(in: mount(Self.fullLetter())).contains(confirmation))
    }

    /// **No paragraph id is ever rendered** — the pane's requirement 3, which
    /// the letter is now a second surface for.
    func test_noParagraphIdIsEverRendered() throws {
        let texts = try axTexts(in: mount(Self.fullLetter(), onAddTurnClause: {}))
        for pid in ["a1b2", "c3d4", "e5f6"] {
            XCTAssertFalse(
                texts.contains { $0.contains(pid) },
                "\u{201C}\(pid)\u{201D} reached the surface. Read: \(texts)")
        }
    }

    /// The schema's own key names never reach the writer (global constraint
    /// 12).
    func test_noSchemaKeyIsEverRendered() throws {
        let texts = try axTexts(in: mount(Self.fullLetter(), onAddTurnClause: {}))
        for key in ["one_thing", "strong_default", "strong_declared", "scenePosition"] {
            XCTAssertFalse(
                texts.contains { $0.contains(key) },
                "\u{201C}\(key)\u{201D} is the schema's word, not the writer's. "
                + "Read: \(texts)")
        }
    }

    /// **The offer's button says where the clause will land, and the host is
    /// what knows.** A piece with no intent of its own is measured against the
    /// book's, so the clause files there — and a button reading *Add to
    /// intent* over that act would name a destination the write does not use.
    /// The view draws the title it is handed and decides nothing.
    func test_theOfferButtonSaysWhereTheClauseWillLand() throws {
        let book = mount(
            Self.fullLetter(), onAddTurnClause: {},
            addToIntentTitle: LetterSection.addToBookIntentTitle)
        let labels = try axButtonLabels(in: book)
        XCTAssertNotNil(
            findButton(labelled: LetterSection.addToBookIntentTitle, in: book),
            "the host said the clause lands in the book's intent; the button must "
            + "say so. Buttons: \(labels)")
        XCTAssertNil(
            findButton(labelled: LetterSection.addToIntentTitle, in: book),
            "and it must not also read the piece-scoped tense")

        let piece = mount(Self.fullLetter(), onAddTurnClause: {})
        XCTAssertNotNil(
            findButton(labelled: LetterSection.addToIntentTitle, in: piece),
            "the control: the piece's own tense, drawn from the same input")
    }

    /// **An exercise's memory belongs to its run** (final review, Important).
    ///
    /// `acceptedExercises` is keyed by index, and an index is only meaningful
    /// inside one letter. Held across runs, the next round's first habit is
    /// born disabled — and the guide says a greyed Accept as task means the
    /// task is already filed, so the writer reads a lie and cannot file it.
    /// `LetterKeep.Kept` and `TurnClauseOffer.filedRunId` are both run-keyed;
    /// this is the same shape.
    func test_anAcceptedExercisesMemoryIsPerRun() throws {
        let host = RunSwapHost(letter: Self.fullLetter())
        let window = mount(AnyView(host))

        let accept = try XCTUnwrap(
            findButton(labelled: LetterSection.acceptTitle, in: window))
        press(accept)
        pump(0.15)
        XCTAssertEqual(
            axEnabled(try XCTUnwrap(
                findButton(labelled: LetterSection.acceptTitle, in: window))),
            false, "the premise: pressed once, refused for the rest of this run")

        // The control first: the same run re-rendered still refuses.
        press(try XCTUnwrap(findButton(labelled: RunSwapHost.redrawTitle, in: window)))
        pump(0.15)
        XCTAssertEqual(
            axEnabled(try XCTUnwrap(
                findButton(labelled: LetterSection.acceptTitle, in: window))),
            false,
            "a redraw inside one run must not forget the press \u{2014} the writer "
            + "would file the same exercise twice")

        press(try XCTUnwrap(findButton(labelled: RunSwapHost.nextRunTitle, in: window)))
        pump(0.2)
        XCTAssertEqual(
            axEnabled(try XCTUnwrap(
                findButton(labelled: LetterSection.acceptTitle, in: window))),
            true,
            "a new run is a new letter: its first habit has never been accepted, and "
            + "a button born disabled tells the writer it fired when it did not")
    }

    /// A host that can change the run under one live `LetterSection`, which is
    /// what a reopened pane does. A fresh mount would prove nothing: SwiftUI
    /// state does not survive one, and the defect is precisely that it survives
    /// where the view stays put.
    private struct RunSwapHost: View {
        static let nextRunTitle = "Next run"
        static let redrawTitle = "Redraw"

        let letter: Letter
        @State private var runId = "run-A"
        @State private var nudge = 0

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Button(Self.nextRunTitle) { runId = "run-B" }
                Button(Self.redrawTitle) { nudge += 1 }
                Text("redraws: \(nudge)")
                LetterSection(
                    letter: letter, runId: runId,
                    signature: "\u{2014} Le Guin", currentText: { _ in nil },
                    onJump: { _ in }, onAcceptExercise: { _ in },
                    onAddTurnClause: nil,
                    addToIntentTitle: LetterSection.addToIntentTitle,
                    onKeep: {})
            }
        }
    }

    // MARK: - Mounting

    private func mount(
        _ letter: Letter,
        runId: String? = "run-1",
        signature: String = "\u{2014} Le Guin \u{00b7} round 2",
        currentText: @escaping (String) -> String? = { _ in nil },
        onJump: @escaping (String) -> Void = { _ in },
        onAcceptExercise: @escaping (Letter.Habit) -> Void = { _ in },
        onAddTurnClause: (() -> Void)? = nil,
        addToIntentTitle: String = LetterSection.addToIntentTitle,
        onKeep: @escaping () -> Void = {},
        offerFailure: String? = nil,
        keepConfirmation: String? = nil
    ) -> NSWindow {
        mount(AnyView(LetterSection(
            letter: letter, runId: runId, signature: signature,
            currentText: currentText,
            onJump: onJump, onAcceptExercise: onAcceptExercise,
            onAddTurnClause: onAddTurnClause,
            addToIntentTitle: addToIntentTitle, onKeep: onKeep,
            offerFailure: offerFailure, keepConfirmation: keepConfirmation)))
    }

    private func mount(_ view: AnyView) -> NSWindow {
        let window = TestWindow.mount(view, size: CGSize(width: 420, height: 900))
        windows.append(window)
        pump()
        return window
    }

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// `DiagnosticsPaneTests`' own warm-up: the FIRST accessibility query
    /// against a freshly-launched host can succeed once and then report an
    /// empty tree for several seconds. Absorbing it here keeps every real
    /// lookup below meaningful.
    private func warmUpAccessibility() {
        let window = mount(AnyView(Button("Warmup") {}))
        for _ in 0..<20 {
            if (try? axElements(in: window))?.isEmpty == false { break }
            pump(0.1)
        }
        window.contentView = NSView(frame: .zero)
        pump(0.05)
    }

    /// The non-recording button reader — every "must NOT be present"
    /// assertion here needs a plain optional rather than an `XCTUnwrap` that
    /// records a failure on the expected absence.
    private func findButton(labelled label: String, in window: NSWindow) -> NSObject? {
        (try? axButtons(labelled: label, in: window))?.first as? NSObject
    }

    /// A jump chip is a `.plain` `Button` whose label is the quoted excerpt.
    private func findChip(quoting words: String, in window: NSWindow) -> NSObject? {
        guard let elements = try? axElements(in: window) else { return nil }
        return elements.first { element in
            guard (axAttribute(element, "accessibilityRole") as? String) == "AXButton"
            else { return false }
            let label = (axAttribute(element, "accessibilityLabel") as? String) ?? ""
            return label.contains(words)
        } as? NSObject
    }
}
