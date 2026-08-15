import XCTest
@testable import Maugham

final class UIStateTests: XCTestCase {

    func test_empty_hasExpectedDefaults() {
        let s = UIState.empty
        XCTAssertEqual(s.schemaVersion, UIState.currentSchemaVersion)
        XCTAssertNil(s.selectedSubject)
        XCTAssertFalse(s.isNoChromeOn)
    }

    func test_codable_roundTrip() throws {
        let original = UIState(
            schemaVersion: 1,
            selectedSubject: .item("doc-abc"),
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
            selectedSubject: .item("doc-x"),
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
        XCTAssertEqual(loaded.selectedSubject, .item("doc-x"))
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
        state.personaMemory.record(persona: .author, detailSegment: .history)
        state.personaMemory.record(persona: .plan, detailSegment: .inbox)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.personaMemory, state.personaMemory)
        XCTAssertEqual(decoded.personaMemory.restoredDetailSegment(for: .author), .history)
        XCTAssertEqual(decoded.personaMemory.restoredDetailSegment(for: .plan), .inbox)
    }

    func test_decode_ofV4StateWithoutPersonaMemory_isEmptyNotAFailure() throws {
        // A project last opened by the first persona build has no
        // `personaMemory` key. It must decode, not throw, and every persona
        // then lands on its own default pane.
        //
        // **The `binderSegment` key is still in this fixture on purpose**, and
        // it is the point of the test as much as the missing one is: a file
        // written before shell-finish stage 2b Task 7 carries a left-column
        // choice this build has no field for, and a keyed container never asks
        // for a key it has no case for. No migration (tripwire 11) — the value
        // decodes away and is dropped on the next write.
        let json = Data("""
        {"schemaVersion":4,"isNoChromeOn":false,"binderSegment":"research",
         "researchPreviewVisible":false,"detailSegment":"inspector",
         "outlineLayout":"table","isReviewModeOn":false,"persona":"plan"}
        """.utf8)
        let decoded = try JSONDecoder().decode(UIState.self, from: json)
        XCTAssertEqual(decoded.personaMemory, .empty)
        XCTAssertEqual(decoded.persona, .plan)
        XCTAssertEqual(decoded.detailSegment, .inspector,
                       "the fields this build still has come through beside the "
                       + "one it no longer does")
    }

    /// **Every legacy `binderSegment` value meets a decoder with no field for
    /// it, and none of them costs the writer anything else** (stage 2b Task 7).
    ///
    /// Asked over the whole set the old enum could write — including the two
    /// (`find`, `trash`) that stopped being written a task or two earlier and
    /// the one (`manuscript`) that was the default — because "unknown keys are
    /// skipped" is a property of the container and a per-value assertion is what
    /// makes it a property of THIS type. A hand-rolled decoder that grew a
    /// `binderSegment` case again would fail here rather than in a writer's
    /// window.
    func test_everyLegacyBinderSegmentValueDecodesAwayWithoutCost() throws {
        for legacy in ["manuscript", "tree", "research", "palette",
                       "scenes", "canvas", "trash", "find"] {
            let json = Data("""
            {"schemaVersion":5,"isNoChromeOn":true,"binderSegment":"\(legacy)",
             "researchPreviewVisible":false,"detailSegment":"tasks",
             "outlineLayout":"table","isReviewModeOn":false,"persona":"review",
             "selectedItemId":"doc-1"}
            """.utf8)
            let decoded = try JSONDecoder().decode(UIState.self, from: json)
            XCTAssertEqual(decoded.persona, .review, legacy)
            XCTAssertEqual(decoded.detailSegment, .tasks, legacy)
            XCTAssertEqual(decoded.selectedSubject, .item("doc-1"), legacy)
            XCTAssertTrue(decoded.isNoChromeOn, legacy)
        }
    }

    // MARK: - Active pass memory (additive, no schema bump — M3-P1 Task 5)

    func test_activePassMemory_roundTripsThroughEncoding() throws {
        var state = UIState.empty
        state.activePassMemory.record(piece: "piece-1", passId: "line")
        state.activePassMemory.record(piece: "piece-2", passId: "proof")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.activePassMemory, state.activePassMemory)
        XCTAssertEqual(decoded.activePassMemory.activePass(forPiece: "piece-1"), "line")
        XCTAssertEqual(decoded.activePassMemory.activePass(forPiece: "piece-2"), "proof")
    }

    /// A project last opened by a pre-Task-5 build has no `activePassMemory`
    /// key. It must decode, not throw, land on `.empty`, and cost the schema
    /// no bump — `currentSchemaVersion` stays 5, this is one additive key
    /// with a default (`compilerModel`'s own no-bump reason).
    func test_decode_ofStateWithoutActivePassMemory_isEmptyNotAFailure() throws {
        let json = Data("""
        {"schemaVersion":5,"isNoChromeOn":false,
         "researchPreviewVisible":false,"detailSegment":"inspector",
         "outlineLayout":"table","isReviewModeOn":false,"persona":"author"}
        """.utf8)
        let decoded = try JSONDecoder().decode(UIState.self, from: json)
        XCTAssertEqual(decoded.activePassMemory, .empty)
        XCTAssertEqual(decoded.persona, .author,
                       "the fields this build still has come through beside the "
                       + "one it did not carry yet")
    }

    func test_currentSchemaVersion_didNotBumpForActivePassMemory() {
        // Additive key with a default — see the property's doc comment.
        XCTAssertEqual(UIState.currentSchemaVersion, 5)
    }

    /// A stored pass id no longer present in a project's current pass list
    /// still reads back raw from `UIState` — sitting harmlessly, never swept
    /// — because `UIState`'s decode is `ActivePassMemory`'s own tolerant
    /// decode; there is nothing UIState-specific to filter here. Threading a
    /// validity check against `effectiveReviewPasses` happens where the
    /// board reads the memory (a later task), not at this decode.
    func test_decode_ofAStalePassId_stillReadsBackRawFromUIState() throws {
        let json = Data("""
        {"schemaVersion":5,"isNoChromeOn":false,
         "researchPreviewVisible":false,"detailSegment":"inspector",
         "outlineLayout":"table","isReviewModeOn":false,"persona":"author",
         "activePassMemory":{"active":{"piece-1":"retired-pass"}}}
        """.utf8)
        let decoded = try JSONDecoder().decode(UIState.self, from: json)
        XCTAssertEqual(decoded.activePassMemory.activePass(forPiece: "piece-1"), "retired-pass")
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
