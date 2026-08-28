import XCTest
@testable import Maugham

final class EPUBPackageTests: XCTestCase {

    func testBuilds_minimalPackage() {
        let pkg = EPUBPackage(
            metadata: .init(title: "Test", author: "Author"),
            sections: [
                .init(id: "s1", filename: "section-001.xhtml", title: "First",
                      xhtmlBody: "<p>Hello.</p>", language: "en"),
            ],
            cover: nil)
        XCTAssertEqual(pkg.sections.count, 1)
        XCTAssertNil(pkg.cover)
    }

    func testIdentifier_defaultsToUUIDv5_fromTitleAndAuthor() {
        let pkg = EPUBPackage(
            metadata: .init(title: "Test", author: "Author"),
            sections: [], cover: nil)
        XCTAssertFalse(pkg.metadata.identifier.isEmpty)
        XCTAssertTrue(pkg.metadata.identifier.hasPrefix("urn:uuid:"))
    }

    func testIdentifier_usesISBN_whenProvided() {
        let pkg = EPUBPackage(
            metadata: .init(title: "Test", author: "X", isbn: "978-3-16-148410-0"),
            sections: [], cover: nil)
        XCTAssertEqual(pkg.metadata.identifier, "urn:isbn:978-3-16-148410-0")
    }
}
