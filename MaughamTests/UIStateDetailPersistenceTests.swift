import XCTest
@testable import Maugham

final class UIStateDetailPersistenceTests: XCTestCase {
    /// The right column's remembered position round-trips, every case.
    func test_rightColumnPosition_roundTrip() throws {
        for position in RightColumnPosition.allCases {
            let state = UIState(isNoChromeOn: false, rightColumnPosition: position)
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(UIState.self, from: data)
            XCTAssertEqual(decoded.rightColumnPosition, position)
        }
    }

    /// The legacy `outlineLayout` key is read to seed the Book's view and
    /// never written back (shell p1 Task 6); `bookView` is what round-trips.
    func test_bookView_roundTrip() throws {
        let state = UIState(bookView: .cards, isNoChromeOn: false)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.bookView, .cards)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("outlineLayout"))
    }

    func test_olderUIState_decodesWithDefaults() throws {
        // Pre-companion UIState JSON (no position / outlineLayout fields)
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
        XCTAssertEqual(decoded.rightColumnPosition, .resolve)
        XCTAssertEqual(decoded.bookView, .outline)
    }

    /// **No migration (tripwire 11).** The pane picker's `detailSegment` key
    /// died with the picker (shell plan 3 Task 9). A `ui-state.json` written
    /// by any earlier build still carries it — a live segment of that build, a
    /// retired one of an older build, or something that was never a segment —
    /// and every one decodes without error, is ignored, and costs the writer
    /// nothing else in the file. The window opens on To resolve.
    func test_aFileCarryingTheOldDetailSegmentDecodesAndIgnoresIt() throws {
        let everyValueAnyBuildWrote = [
            // The picker's last cases.
            "resolve", "inspector", "history", "translation", "intent", "visualLanguage",
            "lessons", "firstReader", "references", "department",
            // Retired before it.
            "outline", "research", "palette", "inbox", "annotations", "diagnostics", "tasks",
            // Never a segment.
            "", "nonsense",
        ]
        for old in everyValueAnyBuildWrote {
            let raw = #"{"schemaVersion": 5, "detailSegment": "\#(old)", "isNoChromeOn": true}"#
            let decoded = try JSONDecoder().decode(UIState.self, from: Data(raw.utf8))
            XCTAssertEqual(decoded.rightColumnPosition, .resolve,
                           "a stored \"\(old)\" opens on To resolve")
            XCTAssertTrue(decoded.isNoChromeOn, "the rest of the file survives \"\(old)\"")
        }
        // Not a string at all.
        for junk in ["7", "null", "{}", "[\"history\"]"] {
            let raw = #"{"schemaVersion": 5, "detailSegment": \#(junk), "isNoChromeOn": true}"#
            let decoded = try JSONDecoder().decode(UIState.self, from: Data(raw.utf8))
            XCTAssertEqual(decoded.rightColumnPosition, .resolve, junk)
            XCTAssertTrue(decoded.isNoChromeOn, junk)
        }
    }

    /// The old key beside the new one: the new one is what is read.
    func test_thePositionIsReadBesideAnOldDetailSegment() throws {
        let raw = #"{"schemaVersion": 5, "detailSegment": "history", "rightColumnPosition": "brief"}"#
        let decoded = try JSONDecoder().decode(UIState.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.rightColumnPosition, .brief)
    }

    /// **The downgrade**: a file this build writes opens in the previous
    /// commit's build and in the shipped one. Both decode `detailSegment`
    /// through `try?` with a default and require only `schemaVersion`
    /// (`git show 5c74101e:Maugham/Stores/UIState.swift`), and a keyed
    /// container skips the keys they do not know — so what must hold HERE is
    /// that the old key is not written (a stale value would be read back by
    /// the older build), `schemaVersion` is, and it did not move.
    func test_aFileThisBuildWritesNoLongerCarriesTheOldKeyAndKeepsItsSchema() throws {
        let state = UIState(isNoChromeOn: true, rightColumnPosition: .pulledUp)
        let written = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertFalse(written.contains("detailSegment"), written)
        XCTAssertTrue(written.contains("\"rightColumnPosition\":\"pulledUp\""), written)
        XCTAssertTrue(written.contains("\"schemaVersion\":\(UIState.currentSchemaVersion)"), written)
        XCTAssertEqual(UIState.currentSchemaVersion, 5,
                       "the position is one additive key with a default: no bump")
    }
}
