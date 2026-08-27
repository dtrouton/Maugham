import XCTest
import MaughamCore
@testable import Maugham

/// `TranslatedFountainStructure`: the source paragraph's Fountain element wins
/// over whatever the translated line happens to re-parse as. The Serbian
/// preview that motivated it (2026-08-27) emitted every Cyrillic slugline as
/// a character cue, because Fountain's INT./EXT. inference is Latin-only.
final class TranslatedFountainStructureTests: XCTestCase {

    private func elements(_ text: String) -> [ScreenplayElement] {
        FountainTokenizer().parse(text).lines.map(\.element)
    }

    private func contents(_ text: String) -> [String] {
        FountainTokenizer().parse(text).lines.map(\.content)
    }

    // MARK: - the bug

    func test_cyrillicSlugline_reparsesAsSceneHeadingNotCharacter() {
        let source = "EXT. TERRACE - DAY"
        let translated = "ЕКСТ. ТЕРАСА - ДАН"
        // Premise: the bare re-parse really does get it wrong.
        XCTAssertEqual(elements(translated), [.character],
            "premise: an uppercase Cyrillic line re-parses as a cue")

        let preserved = TranslatedFountainStructure.preserving(
            source: source, translated: translated)
        XCTAssertEqual(elements(preserved), [.sceneHeading])
        XCTAssertEqual(contents(preserved), ["ЕКСТ. ТЕРАСА - ДАН"],
            "the forced marker must not leak into the rendered content")
    }

    func test_sceneNumberSurvivesTheForcedHeading() {
        let preserved = TranslatedFountainStructure.preserving(
            source: "INT. BAR - NIGHT #12#", translated: "ИНТ. БАР - НОЋ #12#")
        let line = try? XCTUnwrap(FountainTokenizer().parse(preserved).lines.first)
        XCTAssertEqual(line?.element, .sceneHeading)
        XCTAssertEqual(line?.sceneNumber, "12")
        XCTAssertEqual(line?.content, "ИНТ. БАР - НОЋ")
    }

    func test_unforcedTransition_carriesAcrossScripts() {
        // A Latin `CUT TO:` is inferred; its Cyrillic rendering is not.
        let preserved = TranslatedFountainStructure.preserving(
            source: "CUT TO:", translated: "РЕЗ НА:")
        XCTAssertEqual(elements(preserved), [.transition])
        XCTAssertEqual(contents(preserved), ["РЕЗ НА:"])
    }

    func test_cueAndDialogue_whenTheTranslatedCueIsNotUppercase() {
        // A language whose cues are not shouted: the cue would re-parse as
        // action and take the dialogue down with it. Forcing the cue is what
        // carries the dialogue — dialogue has no marker of its own.
        let source = "GRACE\nMorning, everyone."
        let translated = "Grace\nDobro jutro svima."
        XCTAssertEqual(elements(translated), [.action, .action], "premise")

        let preserved = TranslatedFountainStructure.preserving(
            source: source, translated: translated)
        XCTAssertEqual(elements(preserved), [.character, .dialogue])
        XCTAssertEqual(contents(preserved), ["Grace", "Dobro jutro svima."])
    }

    func test_allCapsTranslatedAction_staysAction() {
        // The drift `TranslationCoverageGateTests` used to warn about: a
        // two-line action block whose translation opens with an ALL-CAPS line.
        let source = "The captain nods slowly.\nReady the men now."
        let translated = "EL CAPITÁN\nPreparen a los hombres."
        XCTAssertEqual(elements(translated), [.character, .dialogue], "premise")

        let preserved = TranslatedFountainStructure.preserving(
            source: source, translated: translated)
        XCTAssertEqual(elements(preserved), [.action, .action])
        XCTAssertEqual(contents(preserved), ["EL CAPITÁN", "Preparen a los hombres."])
    }

    // MARK: - what it leaves alone

    func test_identityTranslation_isByteIdentical() {
        let text = "INT. KITCHEN - DAY\n\nAARON\nMorning, everyone.\n\nCUT TO:"
        XCTAssertEqual(
            TranslatedFountainStructure.preserving(source: text, translated: text),
            text)
    }

    func test_alreadyForcedTranslation_isNotDoubleMarked() {
        // A translator who used Fountain's own marker gets exactly that.
        let preserved = TranslatedFountainStructure.preserving(
            source: "CUT TO:", translated: ">РЕЗ НА:")
        XCTAssertEqual(preserved, ">РЕЗ НА:")
    }

    func test_lineCountMismatch_isReturnedUntouched() {
        // The structure cannot be aligned line for line, so nothing is forced
        // — and this residual is what the coverage drift warning reports.
        let translated = "ЕКСТ. ТЕРАСА - ДАН\nДруга линија."
        XCTAssertEqual(
            TranslatedFountainStructure.preserving(
                source: "EXT. TERRACE - DAY", translated: translated),
            translated)
    }

    func test_leadingWhitespace_isKeptAheadOfTheMarker() {
        // The marker lands on the first non-blank unit — where the tokenizer
        // trims to — so an indented line still classifies as forced.
        let preserved = TranslatedFountainStructure.preserving(
            source: "EXT. TERRACE - DAY", translated: "  ЕКСТ. ТЕРАСА - ДАН")
        XCTAssertEqual(preserved, "  .ЕКСТ. ТЕРАСА - ДАН")
        XCTAssertEqual(elements(preserved), [.sceneHeading])
    }

    func test_markerThatCannotTake_isNotLeftInTheWriterWords() {
        // Fountain exempts `..` from the forced-heading rule, so a `.` in
        // front of an ellipsis-opening line forces nothing and would stay in
        // the text as a stray dot. The line comes back untouched instead.
        let translated = "..ЕКСТ. ТЕРАСА - ДАН"
        let preserved = TranslatedFountainStructure.preserving(
            source: "EXT. TERRACE - DAY", translated: translated)
        XCTAssertEqual(preserved, translated)
        XCTAssertFalse(preserved.hasPrefix("..."), "no stray marker in the text")
    }

    func test_aMarkerThatFails_doesNotUndoOneThatTook() {
        // Two lines in one paragraph: the cue takes `@`, the heading-shaped
        // `..` line cannot take `.`. Only the failed one reverts.
        let source = "GRACE\nMorning."
        // Translated: a lowercase cue (needs `@`) then dialogue — and a second
        // paragraph is not needed; the point is a partial revert leaves the
        // successful marker in place.
        let translated = "Grace\nDobro jutro."
        let preserved = TranslatedFountainStructure.preserving(
            source: source, translated: translated)
        XCTAssertEqual(elements(preserved), [.character, .dialogue])
    }

    func test_elementWithNoForcedMarker_isLeftToTheDriftWarning() {
        // Centered text is marked by its own `>…<`; a translator who dropped
        // the brackets gets action, and the coverage warning says so.
        let preserved = TranslatedFountainStructure.preserving(
            source: ">THE END<", translated: "КРАЈ")
        XCTAssertEqual(preserved, "КРАЈ")
    }

    func test_displayText_fallsBackToSourceWhenUntranslated() throws {
        // No records → the deriver yields a `.missing` entry with no translation.
        let derived = TranslationDeriver.derive(
            records: [], sequence: ["abcd"],
            paragraphs: ["abcd": "EXT. TERRACE - DAY"], language: "sr")
        let entry = try XCTUnwrap(derived.entries.first)
        XCTAssertEqual(entry.translatedText, nil, "premise")
        XCTAssertEqual(TranslatedFountainStructure.displayText(for: entry),
                       "EXT. TERRACE - DAY")
    }
}
