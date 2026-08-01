import XCTest
@testable import Maugham

final class UIStateMigrationTests: XCTestCase {

    func test_v1JSON_upgradesToV2_withDefaultSegment() throws {
        // v1 JSONs in the wild carried `scrollLine` (removed in v0.3.1). The
        // unknown-key path silently discards it — that's the forward-compat
        // contract this test pins.
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
        XCTAssertEqual(loaded.selectedSubject, .item("doc-1"))
        XCTAssertTrue(loaded.isNoChromeOn)
        XCTAssertEqual(loaded.binderSegment, .manuscript)
    }

    func test_v2JSON_roundtrips() throws {
        let original = UIState(
            schemaVersion: 2,
            selectedSubject: .item("doc-9"),
            isNoChromeOn: false,
            binderSegment: .research)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(original).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = UIState.loadOrEmpty(from: url)
        XCTAssertEqual(loaded.binderSegment, .research)
        XCTAssertEqual(loaded.selectedSubject, .item("doc-9"))
    }

    func test_unknownFutureSchema_returnsEmpty() throws {
        let v999JSON = """
        { "schemaVersion": 999, "selectedItemId": null, "isNoChromeOn": false }
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
