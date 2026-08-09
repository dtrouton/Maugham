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
    }

    func test_v2JSON_roundtrips() throws {
        let original = UIState(
            schemaVersion: 2,
            selectedSubject: .item("doc-9"),
            isNoChromeOn: false,
            researchPreviewVisible: true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(original).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = UIState.loadOrEmpty(from: url)
        XCTAssertTrue(loaded.researchPreviewVisible)
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

    /// **The left column is not persisted at all since shell-finish stage 2b
    /// Task 7**, so there is no default for it to have. Every persona shows the
    /// project's own tree; a stale `binderSegment` in a file written by an older
    /// build decodes away (`UIStateTests`).
    func test_emptyUIState_persistsNoLeftColumnChoice() throws {
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(UIState.empty)) as? [String: Any]
        XCTAssertNil(json?["binderSegment"],
                     "a field nothing reads must not be written either — a "
                     + "half-dropped field is one a later build restores")
    }
}
