import XCTest
@testable import Maugham

/// `Letter` is a value type only — no parsing, no ingest, no UI (Task 1).
/// These tests pin its Codable round-trip and its `isEmpty` rule; Task 2
/// pins the parse, Task 3 the scene-position stamp.
final class LetterTests: XCTestCase {
    private func makeRef(id: String = "a1b2") -> Diagnostic.Ref {
        Diagnostic.Ref(paragraphId: id, excerpt: "some excerpt")
    }

    private func fullLetter() -> Letter {
        Letter(
            about: "The middle third pulls its punches.",
            oneThing: "Let Marta want something on the page.",
            working: [Letter.Working(refs: [makeRef()], what: "the opening", why: "it moves")],
            habits: [Letter.Habit(
                name: "throat-clearing", refs: [makeRef()], cost: "buries the turn",
                lesson: "cut the first line", exercise: "delete every paragraph's first sentence")],
            questions: [Letter.Question(refs: [makeRef()], question: "does Marta know this yet?",
                                        lessonHeading: nil)],
            scenes: [Letter.Scene(
                refs: [makeRef()], wants: "to leave", changes: "she can't",
                turn: "the door is locked", charge: "dread")],
            scenePosition: "act2")
    }

    private func emptyLetter() -> Letter {
        Letter(
            about: "Nothing else to say this round.",
            oneThing: nil, working: [], habits: [], questions: [], scenes: nil,
            scenePosition: nil)
    }

    // MARK: - Codable round-trip

    func test_aFullyPopulatedLetter_roundTripsThroughJSON() throws {
        let letter = fullLetter()
        let data = try JSONEncoder().encode(letter)
        let decoded = try JSONDecoder().decode(Letter.self, from: data)
        XCTAssertEqual(decoded, letter)
    }

    func test_anEmptyLetter_roundTripsThroughJSON() throws {
        let letter = emptyLetter()
        let data = try JSONEncoder().encode(letter)
        let decoded = try JSONDecoder().decode(Letter.self, from: data)
        XCTAssertEqual(decoded, letter)
    }

    // MARK: - isEmpty

    func test_isEmpty_isTrueOnlyForTheAllEmptyShape() {
        XCTAssertTrue(emptyLetter().isEmpty)
    }

    /// Disable experiment for the rule above: a single populated array is
    /// enough to flip it, so the predicate is reading real content and not
    /// defaulting to true.
    func test_isEmpty_isFalseWhenOneWorkingEntryIsPresent() {
        var letter = emptyLetter()
        letter = Letter(
            about: letter.about, oneThing: letter.oneThing,
            working: [Letter.Working(refs: [makeRef()], what: "pace", why: "it holds")],
            habits: letter.habits, questions: letter.questions, scenes: letter.scenes,
            scenePosition: letter.scenePosition)
        XCTAssertFalse(letter.isEmpty, "a single working entry must make isEmpty false")
    }

    func test_isEmpty_isTrueWhenScenesIsAnEmptyArray_notOnlyWhenNil() {
        var letter = emptyLetter()
        letter = Letter(
            about: letter.about, oneThing: letter.oneThing, working: letter.working,
            habits: letter.habits, questions: letter.questions, scenes: [],
            scenePosition: letter.scenePosition)
        XCTAssertTrue(letter.isEmpty, "an empty scenes array is the same as nil for emptiness")
    }

    func test_isEmpty_isFalseWhenOneThingIsPresentAloneWithNoOtherContent() {
        var letter = emptyLetter()
        letter = Letter(
            about: letter.about, oneThing: "cut the second act",
            working: letter.working, habits: letter.habits, questions: letter.questions,
            scenes: letter.scenes, scenePosition: letter.scenePosition)
        XCTAssertFalse(letter.isEmpty)
    }

    // MARK: - The ask and its answer (editorial letter P2 Task 3)

    /// An answer is a part of the letter the writer reads, so a letter that
    /// carries only an answer has something to show.
    func test_isEmpty_isFalseWhenTheAnswerIsPresentAlone() {
        var letter = emptyLetter()
        letter.answer = "The middle sags because Marta stops wanting anything."
        XCTAssertFalse(letter.isEmpty)
    }

    /// The control for the rule above: `asked` is a STAMP saying what the run
    /// was briefed on, the way `scenePosition` is a stamp saying what form it
    /// was told this piece takes — a letter carrying only the stamp answered
    /// nothing and has nothing to show.
    func test_isEmpty_staysTrueWhenOnlyTheAskWasStamped() {
        var letter = emptyLetter()
        letter.asked = "Does the middle sag?"
        XCTAssertTrue(letter.isEmpty,
                      "what was asked is a fact about the run; only an answer is content")
    }

    /// Both new fields round-trip, and both are `var` because the run stamps
    /// one of them after the parse.
    func test_theAnswerAndTheAskRoundTripThroughJSON() throws {
        var letter = fullLetter()
        letter.answer = "It sags where the scenes stop turning."
        letter.asked = "Does the middle sag?"

        let decoded = try JSONDecoder().decode(
            Letter.self, from: try JSONEncoder().encode(letter))

        XCTAssertEqual(decoded, letter)
        XCTAssertEqual(decoded.answer, "It sags where the scenes stop turning.")
        XCTAssertEqual(decoded.asked, "Does the middle sag?")
    }

    /// **A sidecar written before P2 decodes clean** — literal JSON rather
    /// than an encode of today's type, because an encode could only ever
    /// produce today's shape and would pin nothing. This is the additive
    /// contract the type's own doc comment promises.
    func test_aLetterWrittenBeforeTheAskDecodesWithBothFieldsNil() throws {
        let json = """
            {"about":"The middle third pulls its punches.","working":[],\
            "habits":[],"questions":[],"scenePosition":"weak"}
            """
        let decoded = try JSONDecoder().decode(Letter.self, from: Data(json.utf8))

        XCTAssertNil(decoded.answer)
        XCTAssertNil(decoded.asked)
        XCTAssertEqual(decoded.scenePosition, "weak")
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - The ledger (editorial letter P2 Task 4)

    /// A letter that raised nothing but named a lesson the writer may now be
    /// done with is a letter with something in it — the retirement offer is
    /// drawn from exactly this, and an `isEmpty` letter draws no section at
    /// all.
    func test_isEmpty_isFalseWhenTheLetterOnlyRetiresSomething() {
        var letter = emptyLetter()
        XCTAssertTrue(letter.isEmpty, "control: the same letter with nothing in it")
        letter.retired = ["Throat-clearing"]
        XCTAssertFalse(letter.isEmpty)
    }

    /// Absent and empty are the same answer downstream, and `retiredHeadings`
    /// is where that collapse happens so no caller has to spell it.
    func test_anEmptyRetiredListIsTheSameAsNone() {
        var letter = emptyLetter()
        XCTAssertEqual(letter.retiredHeadings, [])
        letter.retired = []
        XCTAssertEqual(letter.retiredHeadings, [])
        XCTAssertTrue(letter.isEmpty, "an empty list retires nothing")
    }

    /// The habit a question was raised under and the letter's retirements both
    /// survive the sidecar.
    func test_theHabitHeadingAndTheRetiredListRoundTripThroughJSON() throws {
        var letter = fullLetter()
        letter.retired = ["Throat-clearing", "Over-explaining"]
        letter = Letter(
            about: letter.about, oneThing: letter.oneThing, working: letter.working,
            habits: letter.habits,
            questions: [Letter.Question(refs: [makeRef()], question: "does Marta know?",
                                        lessonHeading: "Filter words")],
            scenes: letter.scenes, scenePosition: letter.scenePosition,
            answer: letter.answer, asked: letter.asked, retired: letter.retired)

        let decoded = try JSONDecoder().decode(
            Letter.self, from: try JSONEncoder().encode(letter))

        XCTAssertEqual(decoded, letter)
        XCTAssertEqual(decoded.questions.first?.lessonHeading, "Filter words")
        XCTAssertEqual(decoded.retiredHeadings, ["Throat-clearing", "Over-explaining"])
    }

    /// **A sidecar written before the ledger decodes clean**, question by
    /// question: literal JSON, so the tolerated-missing contract is pinned
    /// against the shape that is actually on disk rather than against an
    /// encode of today's type.
    func test_aLetterWrittenBeforeTheLedgerDecodesWithNoHeadingsAtAll() throws {
        let json = """
            {"about":"The middle third pulls its punches.","working":[],\
            "habits":[],"questions":[{"refs":[],"question":"does Marta know?"}]}
            """
        let decoded = try JSONDecoder().decode(Letter.self, from: Data(json.utf8))

        XCTAssertNil(decoded.questions.first?.lessonHeading)
        XCTAssertNil(decoded.retired)
        XCTAssertEqual(decoded.retiredHeadings, [])
    }

    // MARK: - The process line and the stage stamp (editorial letter P3 Task 3)

    /// The process line is a part of the letter the writer READS — one
    /// sentence in the reader's own words off Maugham's own numbers — so it
    /// counts towards emptiness on `answer`'s side of that line.
    func test_isEmpty_isFalseWhenTheProcessLineIsPresentAlone() {
        var letter = emptyLetter()
        XCTAssertTrue(letter.isEmpty, "control: the same letter with nothing in it")
        letter.process = "You have come back to this chapter five days running."
        XCTAssertFalse(letter.isEmpty)
    }

    /// The control for the rule above, and the mirror of
    /// `test_isEmpty_staysTrueWhenOnlyTheAskWasStamped`: the stage is a STAMP
    /// saying what the run derived, the way `asked` is a stamp saying what it
    /// was briefed on. A letter carrying only the stamp said nothing.
    func test_isEmpty_staysTrueWhenOnlyTheStageWasStamped() {
        var letter = emptyLetter()
        letter.stage = DraftStage.drafting.rawValue
        XCTAssertTrue(letter.isEmpty,
                      "the stage is a fact about the run; only the process line is content")
    }

    /// Both new fields round-trip, and both are `var` because the run stamps
    /// one of them after the parse — the stage is never on the wire at all.
    func test_theProcessLineAndTheStageStampRoundTripThroughJSON() throws {
        var letter = fullLetter()
        letter.process = "You have come back to this chapter five days running."
        letter.stage = DraftStage.revising.rawValue

        let decoded = try JSONDecoder().decode(
            Letter.self, from: try JSONEncoder().encode(letter))

        XCTAssertEqual(decoded, letter)
        XCTAssertEqual(decoded.process,
                       "You have come back to this chapter five days running.")
        XCTAssertEqual(decoded.stage, "revising")
    }

    /// **A sidecar written before P3 decodes clean** — literal JSON rather
    /// than an encode of today's type, because an encode could only ever
    /// produce today's shape and would pin nothing (constraint 17).
    func test_aLetterWrittenBeforeP3DecodesWithProcessAndStageNil() throws {
        let json = """
            {"about":"The middle third pulls its punches.","working":[],\
            "habits":[],"questions":[],"retired":["Throat-clearing"]}
            """
        let decoded = try JSONDecoder().decode(Letter.self, from: Data(json.utf8))

        XCTAssertNil(decoded.process)
        XCTAssertNil(decoded.stage)
        XCTAssertNil(decoded.draftStage)
        XCTAssertEqual(decoded.retiredHeadings, ["Throat-clearing"],
                       "control: the fields P2 wrote still decode")
    }

    /// **`draftStage` is the one conversion from the raw**, so no reader
    /// re-spells `DraftStage(rawValue:)` against a disk string (constraint
    /// 23).
    func test_theDraftStageReadsTheStoredRaw() {
        var letter = emptyLetter()
        letter.stage = "drafting"
        XCTAssertEqual(letter.draftStage, .drafting)
        letter.stage = "revising"
        XCTAssertEqual(letter.draftStage, .revising)
    }

    /// A raw the enum does not know answers `nil` rather than throwing or
    /// guessing — ADR 0015's shape, and what lets a later build add a third
    /// stage without a sidecar written by this one becoming unreadable.
    ///
    /// Disable experiment, run: implementing `draftStage` as
    /// `stage.map { DraftStage(rawValue: $0)! }` did not fail this test — it
    /// CRASHED the worker (`Crash: Maugham at implicit closure #1 in
    /// LetterTests.test_anUnknownStageRawAnswersNil()`), which is the point:
    /// an unknown raw on disk is a force-unwrap away from taking a window
    /// down, not a wrong answer.
    func test_anUnknownStageRawAnswersNil() {
        var letter = emptyLetter()
        letter.stage = "polishing"
        XCTAssertNil(letter.draftStage)
        XCTAssertEqual(letter.stage, "polishing",
                       "the raw is kept whatever this build makes of it")
    }
}
