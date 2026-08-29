import XCTest
@testable import Maugham

/// The helpers every report parser shares — extracted when the fourth copy
/// (the reader's report) would have been the fourth copy. The three existing
/// parsers' suites are the behavioural pin; these are the helper's own.
final class ReportJSONTests: XCTestCase {

    func test_lastObject_takesTheLastSpanCarryingAShapeKey() throws {
        let raw = """
            Thinking: {"notes":[{"x":1}]} ... and finally:
            ```json
            {"notes":[],"overall":{"text":"fine"}}
            ```
            """
        let object = try XCTUnwrap(ReportJSON.lastObject(in: raw, shapedBy: ["notes", "overall"]))
        XCTAssertNotNil(object["overall"])
    }

    func test_lastObject_ignoresSpansWithoutAShapeKey() {
        XCTAssertNil(ReportJSON.lastObject(in: "{\"other\":1}", shapedBy: ["notes"]))
    }

    func test_parseList_absentKeyIsEmpty_wrongShapeIsNil_badItemIsNil() {
        let ok: [Int]? = ReportJSON.parseList([:], key: "k") { _ in 1 }
        XCTAssertEqual(ok, [])
        let wrong: [Int]? = ReportJSON.parseList(["k": "no"], key: "k") { _ in 1 }
        XCTAssertNil(wrong)
        let bad: [Int]? = ReportJSON.parseList(["k": [["a": 1], ["b": 2]]], key: "k") { $0["a"] as? Int }
        XCTAssertNil(bad, "one failing item fails the list")
    }

    func test_nonEmptyString_trimsAndRefusesBlank() {
        XCTAssertEqual(ReportJSON.nonEmptyString("  hi \n"), "hi")
        XCTAssertNil(ReportJSON.nonEmptyString("   "))
        XCTAssertNil(ReportJSON.nonEmptyString(3))
    }

    private enum Colour: String { case red, blue }

    func test_enumValue_readsAKnownRawAndRefusesTheRest() {
        XCTAssertEqual(ReportJSON.enumValue("red", as: Colour.self), .red)
        XCTAssertNil(ReportJSON.enumValue("green", as: Colour.self))
        XCTAssertNil(ReportJSON.enumValue(1, as: Colour.self))
    }
}
