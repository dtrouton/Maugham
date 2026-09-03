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

    /// A ledger the writer has really typed: two live lessons and a settled
    /// choice, in `RulingsSection`'s own shape (a hand-written entry needs no
    /// `\u{2014} ruled` suffix, which is `LessonsLedger`'s stated tolerance).
    nonisolated private static let ledger = """
    ## Rulings

    - Vary the opening.
    - Cut the filter words.
    - Choice: Fragments
    """

    /// Two habits — what the plural choice press needs before it stands at all
    /// (`LessonOffer.allChoicesIsOffered`).
    nonisolated private static let twoHabits = [
        Letter.Habit(name: "Every paragraph starts with a subject",
                     refs: [ref("a1b2")], cost: "The rhythm flattens.",
                     lesson: "Vary the opening.", exercise: "Cut every was."),
        Letter.Habit(name: "Filter words", refs: [ref("c3d4")],
                     cost: "The prose steps back.", lesson: nil, exercise: nil),
    ]

    /// The full letter with P2's two new parts filled: an ask and its answer,
    /// and a heading the round looked for and did not find.
    nonisolated private static func answeredLetter(
        answer: String? = "The dock is still down in this scene.",
        asked: String? = "Is the timeline of the dock clear?",
        retired: [String]? = ["Vary the opening."],
        habits: [Letter.Habit]? = nil
    ) -> Letter {
        var letter = habits.map { fullLetter(habits: $0) } ?? fullLetter()
        letter.answer = answer
        letter.asked = asked
        letter.retired = retired
        return letter
    }

    /// The full letter with P3's two new stamps: a process line, and the stage
    /// the run derived.
    nonisolated private static func processedLetter(
        process: String? = "You have come back to this chapter nine days running.",
        stage: DraftStage? = .drafting,
        retired: [String]? = ["Vary the opening."]
    ) -> Letter {
        var letter = fullLetter()
        letter.process = process
        letter.stage = stage?.rawValue
        letter.retired = retired
        return letter
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

    // MARK: - Pure: the signature carries the stage (P3 Task 5)

    /// The signature names the stage the run derived, after the round it
    /// signed — the Author-side sibling of Review's lane line, in the same
    /// word (`DraftStage.laneWord`, global constraint 28).
    func test_theSignatureCarriesTheStageTheRunDerived() {
        XCTAssertEqual(
            LetterSection.signature(voice: "Le Guin", round: 3, stage: .drafting),
            "\u{2014} Le Guin \u{00b7} round 3 \u{00b7} drafting")
        XCTAssertEqual(
            LetterSection.signature(voice: "Claude", round: nil, stage: .revising),
            "\u{2014} Claude \u{00b7} revising",
            "a passless run still derived a stage, and the letter is signed with it")
    }

    /// **The CONTROL**: a run that wrote no letter derived no stage, and the
    /// signature is exactly the signature it always was.
    func test_aSignatureWithNoStageIsUnmoved() {
        XCTAssertEqual(
            LetterSection.signature(voice: "Le Guin", round: 3, stage: nil),
            LetterSection.signature(voice: "Le Guin", round: 3))
        XCTAssertEqual(
            LetterSection.signature(voice: "Le Guin", round: 3, stage: nil),
            "\u{2014} Le Guin \u{00b7} round 3")
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
                    onKeep: {},
                    freshEyes: true,
                    onKeepAsLesson: { _ in }, onAllChoices: {})
            }
        }
    }

    // MARK: - Mounted: the answer (P2 Task 6)

    /// **The answer draws first, under the ask it answers.** A writer who
    /// asked something reads for that before anything else, so it precedes
    /// even the say-back.
    func test_theAnswerDrawsFirstUnderTheAskItAnswers() throws {
        let texts = try axTexts(in: mount(Self.answeredLetter()))
        let caption = LetterSection.askedCaption("Is the timeline of the dock clear?")

        let captionAt = try XCTUnwrap(
            texts.firstIndex(of: caption), "the ask never drew. Read: \(texts)")
        let answerAt = try XCTUnwrap(
            texts.firstIndex(of: "The dock is still down in this scene."),
            "the answer never drew. Read: \(texts)")
        let aboutAt = try XCTUnwrap(
            texts.firstIndex(of: "A ghost story told through weather."))

        XCTAssertLessThan(captionAt, answerAt, "the ask captions the answer")
        XCTAssertLessThan(
            answerAt, aboutAt,
            "the answer precedes the say-back \u{2014} a reply buried under the "
            + "letter's opening is a reply the writer has to hunt for")
    }

    /// **An ask with no answer draws nothing at all.** The letter is never
    /// refused over a missing answer, and a caption alone would be the app
    /// quoting the writer's own question back at them with silence under it.
    /// Control: the same mount with an answer.
    func test_anAskWithNoAnswerDrawsNothing() throws {
        let caption = LetterSection.askedCaption("Is the timeline of the dock clear?")
        let silent = try axTexts(in: mount(Self.answeredLetter(answer: nil)))
        XCTAssertFalse(
            silent.contains(caption),
            "there is nothing to caption. Read: \(silent)")

        let answered = try axTexts(in: mount(Self.answeredLetter()))
        XCTAssertTrue(
            answered.contains(caption),
            "the control must draw it, or the absence above says nothing")
    }

    /// An answer to nothing in particular — a run whose ask was cleared
    /// between the check and the read — still draws, without a caption.
    func test_anAnswerWithNoRememberedAskDrawsWithoutACaption() throws {
        let texts = try axTexts(in: mount(Self.answeredLetter(asked: nil)))
        XCTAssertTrue(texts.contains("The dock is still down in this scene."))
        XCTAssertFalse(
            texts.contains { $0.hasPrefix("You asked:") },
            "no caption is invented for an ask nothing remembers. Read: \(texts)")
    }

    // MARK: - Mounted: Keep as lesson (P2 Task 6)

    /// **Keep as lesson hands the habit over, once**, and stands beside Accept
    /// as task rather than in place of it: the two answer different questions.
    func test_keepAsLessonHandsTheHabitOverAndThenRefuses() throws {
        var kept: [Letter.Habit] = []
        let window = mount(Self.fullLetter(), onKeepAsLesson: { kept.append($0) })

        XCTAssertNotNil(
            findButton(labelled: LetterSection.acceptTitle, in: window),
            "Accept as task must still be there \u{2014} Keep is beside it, not "
            + "instead of it")
        let labels = try axButtonLabels(in: window)
        let button = try XCTUnwrap(
            findButton(labelled: LetterSection.keepAsLessonTitle, in: window),
            "Keep as lesson never reached the surface: \(labels)")
        XCTAssertEqual(axEnabled(button), true)

        press(button)
        pump(0.15)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.lesson, "Vary the opening.")

        let after = try XCTUnwrap(
            findButton(labelled: LetterSection.keepAsLessonTitle, in: window),
            "disabled rather than gone, `acceptTitle`'s rule")
        XCTAssertEqual(axEnabled(after), false)
        press(after)
        pump(0.15)
        XCTAssertEqual(
            kept.count, 1, "a second press would file the same lesson twice")
    }

    /// A habit with no exercise is still worth keeping: the two buttons are
    /// independent, and a lesson does not need a thing to do beside it.
    func test_aHabitWithNoExerciseStillOffersKeepAsLesson() throws {
        let window = mount(
            Self.fullLetter(habits: [
                Letter.Habit(name: "Filter words", refs: [Self.ref("a1b2")],
                             cost: "The prose steps back.", lesson: nil,
                             exercise: nil),
            ]),
            onKeepAsLesson: { _ in })
        let labels = try axButtonLabels(in: window)
        XCTAssertNil(findButton(labelled: LetterSection.acceptTitle, in: window))
        XCTAssertNotNil(
            findButton(labelled: LetterSection.keepAsLessonTitle, in: window),
            "Buttons: \(labels)")
    }

    /// **Keep is withdrawn once the heading already stands in the ledger.** A
    /// second Keep would file a duplicate row that then briefs every round
    /// twice. Control: the same mount over a ledger that does not carry it.
    func test_keepAsLessonIsHiddenOnceTheLedgerCarriesTheHeading() throws {
        let standing = mount(
            Self.fullLetter(), ledgerText: Self.ledger, onKeepAsLesson: { _ in })
        let labels = try axButtonLabels(in: standing)
        XCTAssertNil(
            findButton(labelled: LetterSection.keepAsLessonTitle, in: standing),
            "\u{201C}Vary the opening.\u{201D} is already a lesson. Buttons: \(labels)")

        let fresh = mount(
            Self.fullLetter(),
            ledgerText: "## Rulings\n\n- Something else entirely.",
            onKeepAsLesson: { _ in })
        XCTAssertNotNil(
            findButton(labelled: LetterSection.keepAsLessonTitle, in: fresh),
            "the control: a ledger that has never carried it still offers")
    }

    /// A host with nowhere to file hides the button outright —
    /// `onAddTurnClause`'s rule, for its reason.
    func test_noKeepHandlerHidesTheButton() throws {
        let none = mount(Self.fullLetter())
        XCTAssertNil(findButton(labelled: LetterSection.keepAsLessonTitle, in: none))
        let some = mount(Self.fullLetter(), onKeepAsLesson: { _ in })
        XCTAssertNotNil(findButton(labelled: LetterSection.keepAsLessonTitle, in: some))
    }

    // MARK: - Mounted: These are all choices (P2 Task 6)

    /// The plural press files once and then says so. Whether it is offered at
    /// all is the host's answer (`LessonOffer.allChoicesIsOffered`), carried
    /// in as the presence of the closure.
    func test_theseAreAllChoicesFilesOnceAndThenRefuses() throws {
        var pressed = 0
        let window = mount(
            Self.fullLetter(habits: Self.twoHabits), freshEyes: true,
            onAllChoices: { pressed += 1 })
        let labels = try axButtonLabels(in: window)
        let button = try XCTUnwrap(
            findButton(labelled: LetterSection.allChoicesTitle, in: window),
            "Buttons: \(labels)")
        press(button)
        pump(0.15)
        XCTAssertEqual(pressed, 1)

        let after = try XCTUnwrap(
            findButton(labelled: LetterSection.allChoicesTitle, in: window))
        XCTAssertEqual(axEnabled(after), false)
        press(after)
        pump(0.15)
        XCTAssertEqual(pressed, 1)

        XCTAssertNil(
            findButton(labelled: LetterSection.allChoicesTitle,
                       in: mount(Self.fullLetter(habits: Self.twoHabits),
                                 freshEyes: true)),
            "a host that did not offer it must not draw it")
    }

    // MARK: - Mounted: what the round did not find (P2 Task 6)

    /// **A warm round says what it can and offers nothing.** It read a delta,
    /// and a three-paragraph delta proves nothing about a habit (spec §6).
    func test_aWarmRoundDrawsTheLineWithNoRetireButton() throws {
        let window = mount(Self.answeredLetter(), ledgerText: Self.ledger)
        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains(LetterSection.warmRetiredLine("Vary the opening.")),
            "Read: \(texts)")
        XCTAssertFalse(
            texts.contains(LetterSection.freshRetiredLine("Vary the opening.")),
            "a warm round must not claim it read the whole piece")
        let labels = try axButtonLabels(in: window)
        XCTAssertNil(
            findButton(labelled: LetterSection.retireTitle, in: window),
            "Buttons: \(labels)")
    }

    /// **A Fresh Eyes round read the whole piece cold**, which is the evidence
    /// a retirement stands on — so it offers, in its own words.
    func test_aFreshEyesRoundOffersTheRetirementInItsOwnWords() throws {
        var retired: [String] = []
        let window = mount(
            Self.answeredLetter(), ledgerText: Self.ledger, freshEyes: true,
            onRetire: { retired.append($0) })
        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains(LetterSection.freshRetiredLine("Vary the opening.")),
            "Read: \(texts)")
        XCTAssertFalse(texts.contains(LetterSection.warmRetiredLine("Vary the opening.")))

        let labels = try axButtonLabels(in: window)
        let button = try XCTUnwrap(
            findButton(labelled: LetterSection.retireTitle, in: window),
            "Buttons: \(labels)")
        press(button)
        pump(0.15)
        XCTAssertEqual(
            retired, ["Vary the opening."],
            "the heading travels verbatim \u{2014} it is what addresses the "
            + "writer's own file")

        XCTAssertNil(
            findButton(labelled: LetterSection.retireTitle, in: window),
            "the offer is spent")
        let spent = try axButtonLabels(in: window)
        let after = try XCTUnwrap(
            findButton(labelled: LetterSection.retiredTitle, in: window),
            "and says so where it stood: \(spent)")
        XCTAssertEqual(axEnabled(after), false)
        press(after)
        pump(0.15)
        XCTAssertEqual(retired.count, 1)
    }

    /// **A heading that names no live lesson draws nothing** (global
    /// constraint 15) — a near-miss, a settled choice, and one never kept.
    /// Control: the exact heading, same mount.
    func test_aRetiredHeadingThatNamesNoLiveLessonDrawsNothing() throws {
        for (label, heading) in [("a near-miss", "vary the opening"),
                                 ("a settled choice", "Fragments"),
                                 ("something never kept", "Weather first.")] {
            let texts = try axTexts(in: mount(
                Self.answeredLetter(retired: [heading]),
                ledgerText: Self.ledger, freshEyes: true, onRetire: { _ in }))
            XCTAssertFalse(
                texts.contains { $0.contains(heading) },
                "\(label) names no live lesson. Read: \(texts)")
        }

        let noLedger = try axTexts(in: mount(
            Self.answeredLetter(), ledgerText: nil, freshEyes: true,
            onRetire: { _ in }))
        XCTAssertFalse(
            noLedger.contains { $0.hasPrefix("I didn't find") },
            "a project with no ledger has nothing to retire from. Read: \(noLedger)")

        let exact = try axTexts(in: mount(
            Self.answeredLetter(), ledgerText: Self.ledger, freshEyes: true,
            onRetire: { _ in }))
        XCTAssertTrue(
            exact.contains(LetterSection.freshRetiredLine("Vary the opening.")),
            "the control: the exact heading does draw, or every absence above is "
            + "evidence about nothing. Read: \(exact)")
    }

    /// A refused ledger verb says so, in one channel for all three.
    func test_aRefusedLedgerVerbSaysSo() throws {
        let refusal = "There is nothing here to rule on yet."
        XCTAssertTrue(
            try axTexts(in: mount(Self.fullLetter(), ledgerFailure: refusal))
                .contains(refusal))
        XCTAssertFalse(
            try axTexts(in: mount(Self.fullLetter())).contains(refusal),
            "and nothing red is drawn when nothing was refused")
    }

    /// **Every part of a P2 letter, in the schema's reading order** — the
    /// answer at the top and what the round did not find below the table.
    func test_aP2LetterRendersItsNewPartsInReadingOrder() throws {
        let window = mount(
            Self.answeredLetter(), onAddTurnClause: {}, ledgerText: Self.ledger,
            freshEyes: true, onRetire: { _ in })
        let texts = try axTexts(in: window)

        let expected = [
            LetterSection.title,
            LetterSection.askedCaption("Is the timeline of the dock clear?"),
            "The dock is still down in this scene.",
            "A ghost story told through weather.",
            LetterSection.workingTitle,
            LetterSection.habitsTitle,
            LetterSection.questionsTitle,
            LetterSection.scenesTitle,
            LetterSection.freshRetiredLine("Vary the opening."),
            LetterSection.turnOfferLine,
            "\u{2014} Le Guin \u{00b7} round 2",
            LetterSection.keepTitle,
        ]
        let positions = expected.map { texts.firstIndex(of: $0) ?? -1 }
        for (marker, position) in zip(expected, positions) {
            XCTAssertGreaterThanOrEqual(
                position, 0,
                "\u{201C}\(marker)\u{201D} never reached the surface. Read: \(texts)")
        }
        XCTAssertEqual(
            positions, positions.sorted(),
            "the answer leads and the not-found list follows the table. "
            + "Read: \(texts)")
    }

    /// **The ledger's presses belong to their run too** (P1's own rule, in
    /// three more places). Held across runs the next round's first habit is
    /// born disabled, and a disabled Keep as lesson is the app saying the
    /// lesson is already in the ledger.
    func test_theLedgerPressesAreRememberedPerRun() throws {
        let host = RunSwapHost(letter: Self.fullLetter(habits: Self.twoHabits))
        let window = mount(AnyView(host))

        press(try XCTUnwrap(
            findButton(labelled: LetterSection.keepAsLessonTitle, in: window)))
        press(try XCTUnwrap(
            findButton(labelled: LetterSection.allChoicesTitle, in: window)))
        pump(0.2)
        for title in [LetterSection.keepAsLessonTitle, LetterSection.allChoicesTitle] {
            XCTAssertEqual(
                axEnabled(try XCTUnwrap(findButton(labelled: title, in: window))),
                false, "the premise: \(title) is spent for this run")
        }

        press(try XCTUnwrap(findButton(labelled: RunSwapHost.redrawTitle, in: window)))
        pump(0.2)
        for title in [LetterSection.keepAsLessonTitle, LetterSection.allChoicesTitle] {
            XCTAssertEqual(
                axEnabled(try XCTUnwrap(findButton(labelled: title, in: window))),
                false,
                "a redraw inside one run must not forget the press \u{2014} the "
                + "writer would file \(title) twice")
        }

        press(try XCTUnwrap(findButton(labelled: RunSwapHost.nextRunTitle, in: window)))
        pump(0.25)
        for title in [LetterSection.keepAsLessonTitle, LetterSection.allChoicesTitle] {
            XCTAssertEqual(
                axEnabled(try XCTUnwrap(findButton(labelled: title, in: window))),
                true,
                "a new run is a new letter, and a button born disabled tells the "
                + "writer \(title) fired when it did not")
        }
    }

    /// **A refused write gives the control back** (fix round 1, Important 1).
    ///
    /// The press is remembered before the handler runs, which is what stops a
    /// double file — but a write the op log turned away then leaves a disabled
    /// button over a ledger that never moved, and the writer has nothing left
    /// to press. Control: the identical host with no failure keeps it disabled.
    func test_aRefusedLedgerWriteGivesTheControlBack() throws {
        let host = LedgerFailureHost(letter: Self.fullLetter())
        let window = mount(AnyView(host))

        press(try XCTUnwrap(
            findButton(labelled: LetterSection.keepAsLessonTitle, in: window)))
        pump(0.2)
        XCTAssertEqual(
            axEnabled(try XCTUnwrap(
                findButton(labelled: LetterSection.keepAsLessonTitle, in: window))),
            false,
            "the premise and the control: with nothing refused, one press is one "
            + "file and the button stays down")

        press(try XCTUnwrap(
            findButton(labelled: LedgerFailureHost.refuseTitle, in: window)))
        pump(0.25)
        XCTAssertTrue(
            try axTexts(in: window).contains(LedgerFailureHost.refusal),
            "the premise: the refusal is on screen")
        XCTAssertEqual(
            axEnabled(try XCTUnwrap(
                findButton(labelled: LetterSection.keepAsLessonTitle, in: window))),
            true,
            "a ledger that never moved must leave the writer something to press")
    }

    /// A host that can raise a refusal under one live `LetterSection`, which is
    /// what a failed write does. A fresh mount would prove nothing: the defect
    /// is precisely that the memory survives where the view stays put.
    private struct LedgerFailureHost: View {
        static let refuseTitle = "Refuse"
        static let refusal = "There is nothing here to rule on yet."

        let letter: Letter
        @State private var failure: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Button(Self.refuseTitle) { failure = Self.refusal }
                LetterSection(
                    letter: letter, runId: "run-1",
                    signature: "\u{2014} Le Guin", currentText: { _ in nil },
                    onJump: { _ in }, onAcceptExercise: { _ in },
                    onAddTurnClause: nil,
                    addToIntentTitle: LetterSection.addToIntentTitle,
                    onKeep: {},
                    onKeepAsLesson: { _ in }, ledgerFailure: failure)
            }
        }
    }

    /// **A warm round says the warm thing, whatever the host wired** (fix
    /// round 1, Important 2). Carried as the presence of `onRetire`, a host
    /// that passed the handler unconditionally would make the app claim it had
    /// read the whole piece over a three-paragraph delta.
    func test_aWarmRoundSaysSoEvenWithEveryHandlerWired() throws {
        let window = mount(
            Self.answeredLetter(habits: Self.twoHabits), ledgerText: Self.ledger,
            freshEyes: false, onAllChoices: {}, onRetire: { _ in })
        let texts = try axTexts(in: window)
        let labels = try axButtonLabels(in: window)

        XCTAssertTrue(
            texts.contains(LetterSection.warmRetiredLine("Vary the opening.")),
            "Read: \(texts)")
        XCTAssertFalse(
            texts.contains(LetterSection.freshRetiredLine("Vary the opening.")),
            "a delta is no evidence about the whole piece. Read: \(texts)")
        XCTAssertNil(
            findButton(labelled: LetterSection.retireTitle, in: window),
            "Buttons: \(labels)")
        XCTAssertNil(
            findButton(labelled: LetterSection.allChoicesTitle, in: window),
            "the seeding gesture is a cold read's. Buttons: \(labels)")

        // The control: the identical mount, told the round was cold.
        let cold = mount(
            Self.answeredLetter(habits: Self.twoHabits), ledgerText: Self.ledger,
            freshEyes: true, onAllChoices: {}, onRetire: { _ in })
        XCTAssertTrue(
            try axTexts(in: cold)
                .contains(LetterSection.freshRetiredLine("Vary the opening.")))
        XCTAssertNotNil(findButton(labelled: LetterSection.retireTitle, in: cold))
        XCTAssertNotNil(findButton(labelled: LetterSection.allChoicesTitle, in: cold))
    }

    /// A cold round whose host handed over no handler draws the WARM line
    /// rather than the cold claim with nothing to press: the sentence is the
    /// app's account of what it did, and an unfilable offer is no reason to
    /// overstate it.
    func test_aFreshRoundWithNoHandlerDrawsTheLineWithoutTheButton() throws {
        let window = mount(
            Self.answeredLetter(), ledgerText: Self.ledger, freshEyes: true)
        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains(LetterSection.warmRetiredLine("Vary the opening.")),
            "Read: \(texts)")
        XCTAssertNil(findButton(labelled: LetterSection.retireTitle, in: window))
    }

    // MARK: - Mounted: the process line and the short-letter line (P3 Task 5)

    /// **The process line draws under its own caption, between what the round
    /// did not find and the signature** (spec §3.1/§5). A caption rather than
    /// bare prose, because a sentence about how often the writer comes back to
    /// a chapter reads as a claim about the PROSE without one.
    func test_theProcessLineDrawsUnderItsCaptionAfterWhatWasNotFound() throws {
        let window = mount(Self.processedLetter(), ledgerText: Self.ledger)
        let texts = try axTexts(in: window)

        let expected = [
            LetterSection.scenesTitle,
            LetterSection.warmRetiredLine("Vary the opening."),
            LetterSection.processCaption,
            "You have come back to this chapter nine days running.",
            "\u{2014} Le Guin \u{00b7} round 2",
        ]
        let positions = expected.map { texts.firstIndex(of: $0) ?? -1 }
        for (marker, position) in zip(expected, positions) {
            XCTAssertGreaterThanOrEqual(
                position, 0,
                "\u{201C}\(marker)\u{201D} never reached the surface. Read: \(texts)")
        }
        XCTAssertEqual(
            positions, positions.sorted(),
            "the process line reads after the round's last observation and "
            + "before the signature. Read: \(texts)")
    }

    /// **An empty process line draws nothing at all** — the section's own
    /// empty-part rule. The briefing carries numbers only when a threshold
    /// says they are worth a sentence, so most letters have no line, and a
    /// caption over nothing would be the app promising an observation it did
    /// not make.
    ///
    /// Control in the same test: the identical mount with a line in it says
    /// the caption, or the absence above is evidence of nothing.
    ///
    /// **Disable experiment** (2026-09-03): drawing `processPart`
    /// unconditionally reddens BOTH absences — the bare *XCTAssertFalse
    /// failed* over the absent line and *XCTAssertFalse failed - whitespace is
    /// the same nothing* over the blank one — while the control stays green.
    func test_aLetterWithNoProcessLineDrawsNoCaption() throws {
        let none = try axTexts(in: mount(Self.processedLetter(process: nil)))
        XCTAssertFalse(none.contains(LetterSection.processCaption), "\(none)")

        let blank = try axTexts(in: mount(Self.processedLetter(process: "   ")))
        XCTAssertFalse(
            blank.contains(LetterSection.processCaption),
            "whitespace is the same nothing: \(blank)")

        let filled = try axTexts(in: mount(Self.processedLetter()))
        XCTAssertTrue(
            filled.contains(LetterSection.processCaption),
            "the control, or the two absences above say nothing: \(filled)")
    }

    /// **The short-letter line stands under the title over a warm drafting
    /// letter** (spec §3.8) — a writer who wants the full letter mid-draft has
    /// to be told the letter was dosed and how to ask for the whole thing.
    func test_aWarmDraftingLetterSaysItIsShortAndHowToAskForMore() throws {
        let texts = try axTexts(in: mount(Self.processedLetter(stage: .drafting)))
        guard let title = texts.firstIndex(of: LetterSection.title),
              let line = texts.firstIndex(of: LetterSection.shortLetterLine)
        else { return XCTFail("the short-letter line never drew: \(texts)") }
        XCTAssertLessThan(title, line, "it reads under the title: \(texts)")
    }

    /// **A Fresh Eyes letter never claims to be short, whatever stage the run
    /// derived** — it read the whole piece cold, which is the full letter by
    /// definition (spec §3.8), and the offer to ask for Fresh Eyes over a
    /// Fresh Eyes letter is the app telling the writer to press what they just
    /// pressed.
    ///
    /// **Disable experiment** (2026-09-03): dropping `!freshEyes` from
    /// `shortLetterPart`'s condition reddens the first assertion below —
    /// *XCTAssertFalse failed - a cold read is the full letter, and must not
    /// say it was dosed* — with the short-letter line second in the read tree,
    /// while the warm control stays green.
    func test_aFreshEyesLetterNeverClaimsToBeShort() throws {
        let cold = try axTexts(
            in: mount(Self.processedLetter(stage: .drafting), freshEyes: true))
        XCTAssertFalse(
            cold.contains(LetterSection.shortLetterLine),
            "a cold read is the full letter, and must not say it was dosed: \(cold)")

        let warm = try axTexts(
            in: mount(Self.processedLetter(stage: .drafting), freshEyes: false))
        XCTAssertTrue(
            warm.contains(LetterSection.shortLetterLine),
            "the control, or the absence above says nothing: \(warm)")
    }

    /// A revising letter is the full letter, and a run that derived no stage
    /// at all says nothing about dosage either.
    ///
    /// **The cover for the `== .drafting` half of the predicate** (fix round 1,
    /// minor 3). Disable experiment (2026-09-03): widening it to
    /// `letter.draftStage != nil` reddens the revising assertion — *XCTAssertFalse
    /// failed - ["Letter", "A short letter while you draft — Fresh Eyes reads
    /// the whole piece.", …]*. The stageless assertion below stays green under
    /// that particular widening, which is why both are asserted: only the pair
    /// distinguishes "drafting" from "any stage at all" from "a stage was
    /// stamped".
    func test_aRevisingOrStagelessLetterSaysNothingAboutDosage() throws {
        let revising = try axTexts(in: mount(Self.processedLetter(stage: .revising)))
        XCTAssertFalse(
            revising.contains(LetterSection.shortLetterLine), "\(revising)")

        let stageless = try axTexts(in: mount(Self.processedLetter(stage: nil)))
        XCTAssertFalse(
            stageless.contains(LetterSection.shortLetterLine), "\(stageless)")
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
        keepConfirmation: String? = nil,
        ledgerText: String? = nil,
        freshEyes: Bool = false,
        onKeepAsLesson: ((Letter.Habit) -> Void)? = nil,
        onAllChoices: (() -> Void)? = nil,
        onRetire: ((String) -> Void)? = nil,
        ledgerFailure: String? = nil
    ) -> NSWindow {
        mount(AnyView(LetterSection(
            letter: letter, runId: runId, signature: signature,
            currentText: currentText,
            onJump: onJump, onAcceptExercise: onAcceptExercise,
            onAddTurnClause: onAddTurnClause,
            addToIntentTitle: addToIntentTitle, onKeep: onKeep,
            offerFailure: offerFailure, keepConfirmation: keepConfirmation,
            ledgerText: ledgerText, freshEyes: freshEyes,
            onKeepAsLesson: onKeepAsLesson,
            onAllChoices: onAllChoices, onRetire: onRetire,
            ledgerFailure: ledgerFailure)))
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
