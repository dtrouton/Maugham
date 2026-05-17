import XCTest
@testable import Maugham

final class ParagraphIDTests: XCTestCase {
    func test_mint_returnsFourLowercaseAlphanumeric() {
        let id = ParagraphID.mint()
        XCTAssertEqual(id.count, 4)
        let allowed = Set("0123456789abcdefghjkmnpqrstvwxyz")
        XCTAssertTrue(id.allSatisfy { allowed.contains($0) })
    }

    func test_mint_isUniqueAcrossManyCalls() {
        let many = (0..<5_000).map { _ in ParagraphID.mint() }
        XCTAssertGreaterThan(Set(many).count, 4_990,
            "too many collisions in 5k mints (got \(Set(many).count) unique)")
    }

    func test_formatComment_producesCanonicalForm() {
        XCTAssertEqual(ParagraphID.formatComment("a3f9"), "<!-- ¶a3f9 -->")
    }

    func test_parseComment_extractsId() {
        XCTAssertEqual(ParagraphID.parseComment("<!-- ¶a3f9 -->"), "a3f9")
        XCTAssertEqual(ParagraphID.parseComment("<!--¶b21c-->"), "b21c")
        XCTAssertEqual(ParagraphID.parseComment("<!--  ¶c1ee  -->"), "c1ee")
    }

    func test_parseComment_rejectsMalformed() {
        XCTAssertNil(ParagraphID.parseComment("<!-- a3f9 -->"))
        XCTAssertNil(ParagraphID.parseComment("¶a3f9"))
        XCTAssertNil(ParagraphID.parseComment("the brown fox"))
        XCTAssertNil(ParagraphID.parseComment("<!-- ¶ABCD -->"))
        XCTAssertNil(ParagraphID.parseComment("<!-- ¶abc -->"))
    }
}
