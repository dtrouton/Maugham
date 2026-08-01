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

final class UIStatePersonaTests: XCTestCase {
    func test_currentSchemaVersion_is5() {
        // Bumped to 5 by the per-persona column memory (2026-07-25 smoke,
        // defect B). This is UIState's OWN constant — `ProjectManifest`'s is a
        // different one and stays at 3.
        XCTAssertEqual(UIState.currentSchemaVersion, 5)
    }

    func test_empty_defaultsToAuthorPersona() {
        XCTAssertEqual(UIState.empty.persona, .author)
    }

    func test_decode_ofV3StateWithoutPersona_defaultsToAuthor() throws {
        // A project last opened by a pre-persona build has no `persona` key.
        // It must decode, not throw, and land on the default.
        let json = Data("""
        {"schemaVersion":3,"isNoChromeOn":false,"binderSegment":"manuscript",
         "researchPreviewVisible":false,"detailSegment":"inspector",
         "outlineLayout":"table","isReviewModeOn":false}
        """.utf8)
        let decoded = try JSONDecoder().decode(UIState.self, from: json)
        XCTAssertEqual(decoded.persona, .author)
    }

    func test_persona_roundTripsThroughEncoding() throws {
        var state = UIState.empty
        state.persona = .plan
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.persona, .plan)
    }

    // MARK: - Per-persona column memory (schema v5)

    func test_personaMemory_roundTripsThroughEncoding() throws {
        var state = UIState.empty
        state.personaMemory.record(persona: .author,
                                   binderSegment: .manuscript,
                                   detailSegment: .history)
        state.personaMemory.record(persona: .plan,
                                   binderSegment: .palette,
                                   detailSegment: .inbox)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.personaMemory, state.personaMemory)
        XCTAssertEqual(
            decoded.personaMemory.restoredBinderSegment(for: .author, projectType: .novel),
            .manuscript)
        XCTAssertEqual(decoded.personaMemory.restoredDetailSegment(for: .plan), .inbox)
    }

    func test_decode_ofV4StateWithoutPersonaMemory_isEmptyNotAFailure() throws {
        // A project last opened by the first persona build has no
        // `personaMemory` key. It must decode, not throw, and every persona
        // then lands on its own home.
        let json = Data("""
        {"schemaVersion":4,"isNoChromeOn":false,"binderSegment":"research",
         "researchPreviewVisible":false,"detailSegment":"inspector",
         "outlineLayout":"table","isReviewModeOn":false,"persona":"plan"}
        """.utf8)
        let decoded = try JSONDecoder().decode(UIState.self, from: json)
        XCTAssertEqual(decoded.personaMemory, .empty)
        XCTAssertEqual(decoded.persona, .plan)
        XCTAssertEqual(decoded.binderSegment, .research)
    }

    func test_loadOrEmpty_rejectsStateFromANewerSchema() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UIStatePersonaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ui-state.json")
        try Data(#"{"schemaVersion":99,"persona":"plan"}"#.utf8).write(to: url)

        XCTAssertEqual(UIState.loadOrEmpty(from: url).persona, .author,
                       "a newer schema must fall back to .empty, not adopt its values")
    }
}
