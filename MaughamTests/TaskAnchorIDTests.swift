import XCTest
@testable import Maugham

final class TaskAnchorIDTests: XCTestCase {
    func test_mint_returnsSixCharFromAlphabet() {
        for _ in 0..<200 {
            let id = TaskAnchorID.mint()
            XCTAssertEqual(id.count, 6)
            XCTAssertTrue(id.allSatisfy {
                "0123456789abcdefghjkmnpqrstvwxyz".contains($0)
            })
        }
    }

    func test_parseComment_validAnchor_returnsId() {
        XCTAssertEqual(TaskAnchorID.parseComment("<!--t-9k2x6a-->"), "9k2x6a")
        XCTAssertEqual(TaskAnchorID.parseComment("<!--t-abcdef-->"), "abcdef")
    }

    func test_parseComment_rejectsInvalid() {
        XCTAssertNil(TaskAnchorID.parseComment("<!-- ¶mnj6qx -->"))  // paragraph
        XCTAssertNil(TaskAnchorID.parseComment("<!--t-toolong-1-->"))
        XCTAssertNil(TaskAnchorID.parseComment("<!--t-12345-->"))  // 5 chars
        XCTAssertNil(TaskAnchorID.parseComment("<!--t-9K2X6A-->"))  // uppercase
        XCTAssertNil(TaskAnchorID.parseComment("ignore <!--t-9k2x6a-->"))  // surrounding text
        XCTAssertNil(TaskAnchorID.parseComment(""))
    }

    func test_formatComment_roundTrips() {
        let id = TaskAnchorID.mint()
        let comment = TaskAnchorID.formatComment(id)
        XCTAssertEqual(TaskAnchorID.parseComment(comment), id)
    }
}
