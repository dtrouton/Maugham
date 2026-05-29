import XCTest
@testable import Maugham

final class EPUBContainerWriterTests: XCTestCase {

    func testEmits_mimetype_constant() {
        XCTAssertEqual(EPUBContainerWriter.mimetypeContent, "application/epub+zip")
    }

    func testEmits_containerXML_pointsToContentOPF() {
        let xml = EPUBContainerWriter.containerXML()
        XCTAssertTrue(xml.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(xml.contains("<container version=\"1.0\""))
        XCTAssertTrue(xml.contains("full-path=\"OEBPS/content.opf\""))
        XCTAssertTrue(xml.contains("media-type=\"application/oebps-package+xml\""))
    }
}
