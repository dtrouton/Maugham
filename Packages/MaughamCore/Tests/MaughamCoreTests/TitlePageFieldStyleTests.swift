import XCTest
@testable import MaughamCore

/// Pins the per-key title-page treatment values. This is the single source the
/// Mac editor and the iOS reader both consume; the values mirror the Mac's
/// original `titlePageValueAttributes(key:)` reference rendering.
final class TitlePageFieldStyleTests: XCTestCase {

    func test_title_isLargeBoldCentered() {
        let s = TitlePageFieldStyle.style(forKey: "Title")
        XCTAssertEqual(s.scale, 1.5)
        XCTAssertTrue(s.bold)
        XCTAssertFalse(s.italic)
        XCTAssertFalse(s.dimmed)
        XCTAssertEqual(s.alignment, .center)
    }

    func test_credit_isItalicCentered() {
        let s = TitlePageFieldStyle.style(forKey: "Credit")
        XCTAssertEqual(s.scale, 1.0)
        XCTAssertFalse(s.bold)
        XCTAssertTrue(s.italic)
        XCTAssertFalse(s.dimmed)
        XCTAssertEqual(s.alignment, .center)
    }

    func test_author_isPlainCentered() {
        let s = TitlePageFieldStyle.style(forKey: "Author")
        XCTAssertEqual(s.scale, 1.0)
        XCTAssertFalse(s.bold)
        XCTAssertFalse(s.italic)
        XCTAssertFalse(s.dimmed)
        XCTAssertEqual(s.alignment, .center)
    }

    func test_source_isSmallerItalicCentered() {
        let s = TitlePageFieldStyle.style(forKey: "Source")
        XCTAssertEqual(s.scale, 0.9)
        XCTAssertFalse(s.bold)
        XCTAssertTrue(s.italic)
        XCTAssertFalse(s.dimmed)
        XCTAssertEqual(s.alignment, .center)
    }

    func test_draftDate_isSmallerDimmedLeading() {
        let s = TitlePageFieldStyle.style(forKey: "Draft date")
        XCTAssertEqual(s.scale, 0.85)
        XCTAssertFalse(s.bold)
        XCTAssertFalse(s.italic)
        XCTAssertTrue(s.dimmed)
        XCTAssertEqual(s.alignment, .leading)
    }

    func test_otherKeys_fallThroughToDimmedLeading() {
        for key in ["Contact", "Notes", "Copyright", "Wholly Unknown"] {
            let s = TitlePageFieldStyle.style(forKey: key)
            XCTAssertEqual(s, TitlePageFieldStyle.style(forKey: "Draft date"),
                           "\(key) should share the 'other' treatment")
        }
    }
}
