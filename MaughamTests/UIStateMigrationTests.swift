import XCTest
@testable import Maugham

final class UIStateMigrationTests: XCTestCase {

    func test_v1JSON_upgradesToV2_withDefaultSegment() throws {
        let v1JSON = """
        {
          "schemaVersion": 1,
          "selectedItemId": "doc-1",
          "isNoChromeOn": true,
          "scrollLine": 42
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try v1JSON.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = UIState.loadOrEmpty(from: url)
        XCTAssertEqual(loaded.schemaVersion, UIState.currentSchemaVersion)
        XCTAssertEqual(loaded.selectedItemId, "doc-1")
        XCTAssertTrue(loaded.isNoChromeOn)
        XCTAssertEqual(loaded.scrollLine, 42)
        XCTAssertEqual(loaded.binderSegment, .manuscript)
    }

    func test_v2JSON_roundtrips() throws {
        let original = UIState(
            schemaVersion: 2,
            selectedItemId: "doc-9",
            isNoChromeOn: false,
            scrollLine: 0,
            binderSegment: .research)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(original).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = UIState.loadOrEmpty(from: url)
        XCTAssertEqual(loaded.binderSegment, .research)
        XCTAssertEqual(loaded.selectedItemId, "doc-9")
    }

    func test_unknownFutureSchema_returnsEmpty() throws {
        let v999JSON = """
        { "schemaVersion": 999, "selectedItemId": null, "isNoChromeOn": false, "scrollLine": 0 }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try v999JSON.data(using: .utf8)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = UIState.loadOrEmpty(from: url)
        XCTAssertEqual(loaded, UIState.empty)
    }

    func test_emptyUIState_hasManuscriptSegment() {
        XCTAssertEqual(UIState.empty.binderSegment, .manuscript)
    }
}
