import XCTest
@testable import Maugham

final class UIStateDetailPersistenceTests: XCTestCase {
    func test_detailSegment_roundTrip() throws {
        let state = UIState(
            selectedItemId: nil,
            isNoChromeOn: false,
            binderSegment: .manuscript,
            detailSegment: .research,
            outlineLayout: .table)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.detailSegment, .research)
    }

    func test_outlineLayout_roundTrip() throws {
        let state = UIState(
            selectedItemId: nil,
            isNoChromeOn: false,
            binderSegment: .manuscript,
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
}
