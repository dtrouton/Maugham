import XCTest
@testable import Maugham

final class EPUBOPFWriterTests: XCTestCase {

    func testEmits_metadataBlock() {
        let pkg = EPUBPackage(
            metadata: .init(
                title: "Stories", author: "Denver", subject: "Fiction",
                language: "en", isbn: nil, publisher: nil, publishedYear: 2026,
                keywords: ["short"], version: "0.3", label: "galley",
                checkpointID: "chk-abc", compiledAtISO8601: "2026-05-26T10:00:00Z"),
            sections: [],
            cover: nil
        )
        let xml = EPUBOPFWriter.opfXML(for: pkg)
        XCTAssertTrue(xml.contains("<dc:title>Stories</dc:title>"))
        XCTAssertTrue(xml.contains("<dc:creator>Denver</dc:creator>"))
        XCTAssertTrue(xml.contains("<dc:subject>Fiction</dc:subject>"))
        XCTAssertTrue(xml.contains("<dc:language>en</dc:language>"))
        XCTAssertTrue(xml.contains("maugham:version"))
        XCTAssertTrue(xml.contains("0.3"))
        XCTAssertTrue(xml.contains("maugham:label"))
        XCTAssertTrue(xml.contains("galley"))
    }

    func testEmits_manifestEntries_perSection() {
        let pkg = EPUBPackage(
            metadata: .init(title: "X", author: "Y"),
            sections: [
                .init(id: "s1", filename: "section-001.xhtml", title: "One", xhtmlBody: "",
                      language: "en"),
                .init(id: "s2", filename: "section-002.xhtml", title: "Two", xhtmlBody: "",
                      language: "en"),
            ],
            cover: nil)
        let xml = EPUBOPFWriter.opfXML(for: pkg)
        XCTAssertTrue(xml.contains("href=\"section-001.xhtml\""))
        XCTAssertTrue(xml.contains("href=\"section-002.xhtml\""))
        XCTAssertTrue(xml.contains("id=\"s1\""))
        XCTAssertTrue(xml.contains("id=\"s2\""))
    }

    func testEmits_spine_inOrder() {
        let pkg = EPUBPackage(
            metadata: .init(title: "X", author: "Y"),
            sections: [
                .init(id: "first", filename: "a.xhtml", title: "A", xhtmlBody: "",
                      language: "en"),
                .init(id: "second", filename: "b.xhtml", title: "B", xhtmlBody: "",
                      language: "en"),
            ], cover: nil)
        let xml = EPUBOPFWriter.opfXML(for: pkg)
        let spineStart = xml.range(of: "<spine")!.lowerBound
        let spineEnd   = xml.range(of: "</spine>")!.upperBound
        let spine = String(xml[spineStart..<spineEnd])
        XCTAssertTrue(spine.contains("idref=\"first\""))
        XCTAssertTrue(spine.contains("idref=\"second\""))
        let firstIdx  = spine.range(of: "idref=\"first\"")!.lowerBound
        let secondIdx = spine.range(of: "idref=\"second\"")!.lowerBound
        XCTAssertLessThan(firstIdx, secondIdx)
    }

    func testIncludes_coverManifestItem_whenCoverPresent() {
        let pkg = EPUBPackage(
            metadata: .init(title: "X", author: "Y"),
            sections: [],
            cover: .init(filename: "cover.jpg", data: Data(), mediaType: "image/jpeg"))
        let xml = EPUBOPFWriter.opfXML(for: pkg)
        XCTAssertTrue(xml.contains("href=\"cover.jpg\""))
        XCTAssertTrue(xml.contains("properties=\"cover-image\""))
    }
}
