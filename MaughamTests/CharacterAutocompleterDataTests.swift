import XCTest
@testable import Maugham

final class CharacterAutocompleterDataTests: XCTestCase {

    func test_rankSuggestions_emptyNames_returnsEmpty() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "B", characterNames: [])
        XCTAssertEqual(suggestions, [])
    }

    func test_rankSuggestions_emptyPrefix_returnsEmpty() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "", characterNames: ["BARRY", "SAM"])
        XCTAssertEqual(suggestions, [])
    }

    func test_rankSuggestions_prefixMatchesFirst() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "B",
            characterNames: ["SAM", "BARRY", "ABBY", "BARTENDER"])
        XCTAssertEqual(suggestions, ["BARRY", "BARTENDER", "ABBY"])
    }

    func test_rankSuggestions_caseInsensitive() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "bar",
            characterNames: ["BARRY", "BARTENDER"])
        XCTAssertEqual(suggestions, ["BARRY", "BARTENDER"])
    }

    func test_rankSuggestions_substringMatchAfterPrefix() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "RT",
            characterNames: ["BARTENDER", "MARTHA", "ART"])
        // None prefix-match RT; BARTENDER and MARTHA contain RT (substring).
        // Ordered alphabetically among substring matches.
        XCTAssertEqual(suggestions, ["BARTENDER", "MARTHA"])
    }

    func test_rankSuggestions_alphabeticalWithinTier() {
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "S",
            characterNames: ["SAM", "SARAH", "SLIM"])
        XCTAssertEqual(suggestions, ["SAM", "SARAH", "SLIM"])
    }

    func test_rankSuggestions_capsAtEight() {
        let names: Set<String> = Set((1...20).map { "ALPHA\($0)" })
        let suggestions = CharacterAutocompleter.rankSuggestions(
            prefix: "ALPHA", characterNames: names)
        XCTAssertEqual(suggestions.count, 8)
    }
}
