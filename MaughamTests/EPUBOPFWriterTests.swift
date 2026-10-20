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

    // MARK: - report foundations plan 2, Task 6

    private func imagePackage(_ images: [EPUBPackage.Image]) -> EPUBPackage {
        EPUBPackage(
            metadata: .init(title: "X", author: "Y"),
            sections: [.init(id: "s1", filename: "section-001.xhtml", title: "One",
                             xhtmlBody: "", language: "en")],
            cover: nil, images: images)
    }

    /// Each image is a manifest item with its media type, and never a spine
    /// entry: an image is not a reading-order document.
    func test_imagesAreManifestItemsWithTheirMediaTypes_andNotInTheSpine() {
        let src = URL(fileURLWithPath: "/nowhere")
        let xml = EPUBOPFWriter.opfXML(for: imagePackage([
            .init(filename: "aa11.png", source: src, mediaType: "image/png"),
            .init(filename: "bb22.jpg", source: src, mediaType: "image/jpeg"),
            .init(filename: "cc33.gif", source: src, mediaType: "image/gif"),
            .init(filename: "dd44.svg", source: src, mediaType: "image/svg+xml"),
        ]))
        for line in [
            #"<item id="img-aa11.png" href="images/aa11.png" media-type="image/png"/>"#,
            #"<item id="img-bb22.jpg" href="images/bb22.jpg" media-type="image/jpeg"/>"#,
            #"<item id="img-cc33.gif" href="images/cc33.gif" media-type="image/gif"/>"#,
            #"<item id="img-dd44.svg" href="images/dd44.svg" media-type="image/svg+xml"/>"#,
        ] {
            XCTAssertTrue(xml.contains(line), "missing \(line) in\n\(xml)")
        }
        let spine = String(xml[xml.range(of: "<spine>")!.lowerBound...])
        XCTAssertFalse(spine.contains("img-"), spine)
    }

    /// The same image used twice is one file and one item.
    func test_theSameImageTwiceIsOneItem() {
        let src = URL(fileURLWithPath: "/nowhere")
        let pkg = imagePackage([
            .init(filename: "aa11.png", source: src, mediaType: "image/png"),
            .init(filename: "aa11.png", source: src, mediaType: "image/png"),
        ])
        XCTAssertEqual(pkg.images.map(\.filename), ["aa11.png"])
        XCTAssertEqual(EPUBOPFWriter.opfXML(for: pkg).components(separatedBy: "img-aa11").count - 1, 1)
    }

    func test_mediaTypes_coverEveryEPUBImageFormat() {
        XCTAssertEqual(EPUBCompiler.mediaType(forExtension: "png"), "image/png")
        XCTAssertEqual(EPUBCompiler.mediaType(forExtension: "jpg"), "image/jpeg")
        XCTAssertEqual(EPUBCompiler.mediaType(forExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(EPUBCompiler.mediaType(forExtension: "gif"), "image/gif")
        XCTAssertEqual(EPUBCompiler.mediaType(forExtension: "svg"), "image/svg+xml")
        XCTAssertNil(EPUBCompiler.mediaType(forExtension: "pdf"))
        XCTAssertEqual(Set(EPUBCompiler.imageAllowed), ["png", "jpg", "jpeg", "gif", "svg"])
    }

    /// The section document declares `xmlns:epub`, which `epub:type="noteref"`
    /// and `epub:type="footnote"` need to be well-formed XML.
    func test_theSectionDocumentDeclaresTheEpubNamespace() {
        let doc = EPUBOPFWriter.sectionXHTML(for: .init(
            id: "s1", filename: "section-001.xhtml", title: "One", xhtmlBody: "<section/>",
            language: "en"))
        XCTAssertTrue(doc.contains(
            #"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">"#),
            doc)
    }

    /// R-P2-6: the lists are nav entries of their own, only when non-empty.
    func test_theNavCarriesTheListsOfFiguresAndTables_onlyWhenNonEmpty() {
        let base = EPUBPackage(
            metadata: .init(title: "X", author: "Y"),
            sections: [.init(id: "s1", filename: "section-001.xhtml", title: "One",
                             xhtmlBody: "", language: "en")],
            cover: nil,
            listOfFigures: [.init(title: "Figure 1. Revenue & cost", href: "section-001.xhtml#fig-1")],
            listOfTables: [.init(title: "Table 1.", href: "section-001.xhtml#lbl-tbl-sales")])
        let nav = EPUBOPFWriter.navXHTML(for: base)
        XCTAssertTrue(nav.contains("""
            <nav epub:type="loi" id="loi">
              <h1>List of Figures</h1>
              <ol>
                <li><a href="section-001.xhtml#fig-1">Figure 1. Revenue &amp; cost</a></li>
              </ol>
            </nav>
            <nav epub:type="lot" id="lot">
              <h1>List of Tables</h1>
              <ol>
                <li><a href="section-001.xhtml#lbl-tbl-sales">Table 1.</a></li>
              </ol>
            </nav>
            </body></html>
            """), nav)
        let none = EPUBOPFWriter.navXHTML(for: EPUBPackage(
            metadata: .init(title: "X", author: "Y"), sections: base.sections, cover: nil))
        XCTAssertFalse(none.contains("loi"), none)
        XCTAssertFalse(none.contains("lot"), none)
    }
}
