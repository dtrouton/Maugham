import XCTest
@testable import Maugham

final class UIStateTests: XCTestCase {

    func test_empty_hasExpectedDefaults() {
        let s = UIState.empty
        XCTAssertEqual(s.schemaVersion, UIState.currentSchemaVersion)
        XCTAssertNil(s.selectedItemId)
        XCTAssertFalse(s.isNoChromeOn)
        XCTAssertEqual(s.scrollLine, 0)
        XCTAssertEqual(s.binderSegment, .manuscript)
    }

    func test_codable_roundTrip() throws {
        let original = UIState(
            schemaVersion: 1,
            selectedItemId: "doc-abc",
            isNoChromeOn: true,
            scrollLine: 47)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_loadOrEmpty_returnsEmpty_whenFileMissing() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("missing.json")
        XCTAssertEqual(UIState.loadOrEmpty(from: url), .empty)
    }

    func test_loadOrEmpty_returnsEmpty_whenJSONMalformed() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("ui-state.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(UIState.loadOrEmpty(from: url), .empty)
    }

    func test_loadOrEmpty_returnsEmpty_whenSchemaVersionUnknown() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("ui-state.json")
        let badJSON = #"""
        {"schemaVersion": 99, "selectedItemId": "x", "isNoChromeOn": false, "scrollLine": 0}
        """#
        try badJSON.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(UIState.loadOrEmpty(from: url), .empty)
    }

    func test_loadOrEmpty_loadsValidFile() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("ui-state.json")
        let s = UIState(
            schemaVersion: UIState.currentSchemaVersion,
            selectedItemId: "doc-x",
            isNoChromeOn: true,
            scrollLine: 12)
        try JSONEncoder().encode(s).write(to: url)
        XCTAssertEqual(UIState.loadOrEmpty(from: url), s)
    }
}
