import XCTest
@testable import Maugham

final class UIStateDetailPersistenceTests: XCTestCase {
    func test_detailSegment_roundTrip() throws {
        let state = UIState(
            selectedSubject: nil,
            isNoChromeOn: false,
            detailSegment: .annotations,
            outlineLayout: .table)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.detailSegment, .annotations)
    }

    func test_outlineLayout_roundTrip() throws {
        let state = UIState(
            selectedSubject: nil,
            isNoChromeOn: false,
            detailSegment: .inspector,
            outlineLayout: .cards)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.outlineLayout, .cards)
    }

    func test_olderUIState_decodesWithDefaults() throws {
        // Pre-companion UIState JSON (no detailSegment / outlineLayout fields)
        let raw = """
        {
          "schemaVersion": 1,
          "isNoChromeOn": false,
          "binderSegment": "manuscript",
          "researchPreviewVisible": false
        }
        """
        let decoded = try JSONDecoder().decode(
            UIState.self, from: raw.data(using: .utf8)!)
        XCTAssertEqual(decoded.detailSegment, .inspector)
        XCTAssertEqual(decoded.outlineLayout, .table)
    }

    /// **No migration (tripwire 11).** `.outline`/`.research`/`.palette` no
    /// longer exist as `DetailSegment` cases (stage 3a Task 6); a project's
    /// `ui-state.json` written before that still carries one of those raw
    /// strings, and `DetailSegment`'s synthesized decode simply fails for it —
    /// `UIState`'s own `try?` catches that and falls back to `.inspector`,
    /// same as any other unreadable field.
    func test_olderDetailSegment_fallsBackToInspector() throws {
        for retired in ["outline", "research", "palette"] {
            let raw = """
            {"schemaVersion": 1, "detailSegment": "\(retired)"}
            """
            let decoded = try JSONDecoder().decode(
                UIState.self, from: raw.data(using: .utf8)!)
            XCTAssertEqual(decoded.detailSegment, .inspector,
                           "a stored \"\(retired)\" should fall back to .inspector")
        }
    }
}
