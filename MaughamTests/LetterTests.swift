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
            questions: [Letter.Question(refs: [makeRef()], question: "does Marta know this yet?")],
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
}
