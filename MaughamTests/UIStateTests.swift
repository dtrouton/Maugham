import XCTest
@testable import Maugham

final class UIStateTests: XCTestCase {

    func test_empty_hasExpectedDefaults() {
        let s = UIState.empty
        XCTAssertEqual(s.schemaVersion, UIState.currentSchemaVersion)
        XCTAssertNil(s.selectedItemId)
        XCTAssertFalse(s.isNoChromeOn)
        XCTAssertEqual(s.binderSegment, .manuscript)
    }

    func test_codable_roundTrip() throws {
        let original = UIState(
            schemaVersion: 1,
            selectedItemId: "doc-abc",
            isNoChromeOn: true)
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
        {"schemaVersion": 99, "selectedItemId": "x", "isNoChromeOn": false}
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
            isNoChromeOn: true)
        try JSONEncoder().encode(s).write(to: url)
        XCTAssertEqual(UIState.loadOrEmpty(from: url), s)
    }

    /// Forward-compatibility: unknown keys on disk (e.g., `scrollLine` left
    /// over from pre-v0.3.1 builds) must not break decode.
    func test_loadOrEmpty_ignoresUnknownKeys() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("ui-state.json")
        let withGhostKey = #"""
        {"schemaVersion": 2, "selectedItemId": "doc-x", "isNoChromeOn": false, "scrollLine": 42, "hasShownOpLogBootstrapNotice": true}
        """#
        try withGhostKey.write(to: url, atomically: true, encoding: .utf8)
        let loaded = UIState.loadOrEmpty(from: url)
        XCTAssertEqual(loaded.selectedItemId, "doc-x")
        XCTAssertFalse(loaded.isNoChromeOn)
    }
}
