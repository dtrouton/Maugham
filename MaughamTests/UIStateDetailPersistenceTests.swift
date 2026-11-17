import XCTest
@testable import Maugham

final class UIStateDetailPersistenceTests: XCTestCase {
    func test_detailSegment_roundTrip() throws {
        let state = UIState(
            isNoChromeOn: false,
            detailSegment: .annotations)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.detailSegment, .annotations)
    }

    /// The legacy `outlineLayout` key is read to seed the Book's view and
    /// never written back (shell p1 Task 6); `bookView` is what round-trips.
    func test_bookView_roundTrip() throws {
        let state = UIState(bookView: .cards, isNoChromeOn: false, detailSegment: .inspector)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.bookView, .cards)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("outlineLayout"))
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
        XCTAssertEqual(decoded.bookView, .outline)
    }

    /// **No migration (tripwire 11).** `.outline`/`.research`/`.palette` no
    /// longer exist as `DetailSegment` cases (stage 3a Task 6); a project's
    /// `ui-state.json` written before that still carries one of those raw
    /// strings, and `DetailSegment`'s synthesized decode simply fails for it —
    /// `UIState`'s own `try?` catches that and falls back to `.inspector`,
    /// same as any other unreadable field.
    func test_olderDetailSegment_fallsBackToInspector() throws {
        for retired in ["outline", "research", "palette", "inbox"] {
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
