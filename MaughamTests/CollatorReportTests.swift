import XCTest
@testable import Maugham

/// The collator's answer (translation pipeline spec §4): how the two texts
/// hold together, and every departure with a verdict, a kind and — required —
/// a gloss back into the author's language, so the author can rule on it.
final class CollatorReportTests: XCTestCase {

    private let briefed: Set<String> = ["k7mq", "a1b2"]

    func test_roundTrip_overallAndDepartures() throws {
        let raw = """
            {"overall":{"text":"Faithful, one drift in the argument."},
             "departures":[
               {"paragraph_id":"k7mq","verdict":"holds","kind":"rendering","note":"The pun is re-made on 'luz'.","gloss":"The light went out, and so did she."},
               {"paragraph_id":"a1b2","verdict":"drifted","kind":"omission","note":"Second clause dropped.","gloss":"He waited."}]}
            """
        let report = try XCTUnwrap(CollatorReport.parse(raw, briefedParagraphIds: briefed))
        XCTAssertEqual(report.overall, "Faithful, one drift in the argument.")
        XCTAssertEqual(report.departures.count, 2)
        XCTAssertEqual(report.departures[0].verdict, .holds)
        XCTAssertEqual(report.departures[0].kind, .rendering)
        XCTAssertEqual(report.departures[1].gloss, "He waited.")
        XCTAssertEqual(report.drifted.map(\.paragraphId), ["a1b2"])
    }

    func test_zeroDeparturesIsAValidReport() throws {
        let report = try XCTUnwrap(CollatorReport.parse(#"{"overall":{"text":"Clean."}}"#, briefedParagraphIds: briefed))
        XCTAssertTrue(report.departures.isEmpty)
    }

    func test_overallIsRequiredAndNonEmpty() {
        XCTAssertNil(CollatorReport.parse(#"{"departures":[]}"#, briefedParagraphIds: briefed))
        XCTAssertNil(CollatorReport.parse(#"{"overall":{"text":" "},"departures":[]}"#, briefedParagraphIds: briefed))
    }

    func test_glossIsRequiredOnEveryDeparture() {
        let raw = #"{"overall":{"text":"x"},"departures":[{"paragraph_id":"k7mq","verdict":"drifted","kind":"addition","note":"n"}]}"#
        XCTAssertNil(CollatorReport.parse(raw, briefedParagraphIds: briefed))
        let blank = #"{"overall":{"text":"x"},"departures":[{"paragraph_id":"k7mq","verdict":"drifted","kind":"addition","note":"n","gloss":""}]}"#
        XCTAssertNil(CollatorReport.parse(blank, briefedParagraphIds: briefed))
    }

    func test_aDepartureOutsideTheBriefedSetFailsTheReport() {
        let raw = #"{"overall":{"text":"x"},"departures":[{"paragraph_id":"zzzz","verdict":"holds","kind":"rendering","note":"n","gloss":"g"}]}"#
        XCTAssertNil(CollatorReport.parse(raw, briefedParagraphIds: briefed))
    }

    func test_verdictAndKindAreClosedEnums() {
        let badVerdict = #"{"overall":{"text":"x"},"departures":[{"paragraph_id":"k7mq","verdict":"maybe","kind":"rendering","note":"n","gloss":"g"}]}"#
        XCTAssertNil(CollatorReport.parse(badVerdict, briefedParagraphIds: briefed))
        let badKind = #"{"overall":{"text":"x"},"departures":[{"paragraph_id":"k7mq","verdict":"holds","kind":"rhythm","note":"n","gloss":"g"}]}"#
        XCTAssertNil(CollatorReport.parse(badKind, briefedParagraphIds: briefed), "a collator cannot file a fluency kind")
    }

    func test_wireFieldNamesAppearInTheSchemaDescription() {
        for name in ["overall", "text", "departures", "paragraph_id", "verdict", "kind", "note", "gloss",
                     "holds", "drifted", "mistranslation", "omission", "addition", "untranslated",
                     "inconsistency", "rendering"] {
            XCTAssertTrue(CollatorReport.schemaDescription.contains(name), name)
        }
    }
}
