import XCTest
@testable import MaughamCore

/// `DocumentFormat` is the one home for what a manuscript's extension decides:
/// the extension itself, the held-blank rule, the screenplay family, the help
/// resource and the icon. Every property is pinned here per case.
final class DocumentFormatTests: XCTestCase {

    private struct Expected {
        let fileExtension: String
        let preservesHeldBlankLines: Bool
        let isScreenplay: Bool
        let helpResourceName: String
        let symbolName: String
    }

    private func expected(_ format: DocumentFormat) -> Expected {
        switch format {
        case .markdown:
            return Expected(fileExtension: "md", preservesHeldBlankLines: false,
                            isScreenplay: false, helpResourceName: "markdown-syntax",
                            symbolName: "doc.text")
        case .fountain:
            return Expected(fileExtension: "fountain", preservesHeldBlankLines: true,
                            isScreenplay: true, helpResourceName: "fountain-syntax",
                            symbolName: "film")
        }
    }

    func test_everyCase_answersEveryProperty() {
        XCTAssertEqual(DocumentFormat.allCases, [.markdown, .fountain])
        for format in DocumentFormat.allCases {
            let want = expected(format)
            XCTAssertEqual(format.fileExtension, want.fileExtension, "\(format)")
            XCTAssertEqual(format.preservesHeldBlankLines, want.preservesHeldBlankLines, "\(format)")
            XCTAssertEqual(format.isScreenplay, want.isScreenplay, "\(format)")
            XCTAssertEqual(format.helpResourceName, want.helpResourceName, "\(format)")
            XCTAssertEqual(format.symbolName, want.symbolName, "\(format)")
        }
    }

    func test_extensionParsing_isCaseInsensitive_andRefusesEverythingElse() {
        let table: [(String, DocumentFormat?)] = [
            ("md", .markdown),
            ("MD", .markdown),
            ("fountain", .fountain),
            ("FOUNTAIN", .fountain),
            ("Fountain", .fountain),
            ("txt", nil),
            ("", nil),
            // The phone routes `.markdown` to `.other` today; it must keep doing so.
            ("markdown", nil),
        ]
        for (ext, want) in table {
            XCTAssertEqual(DocumentFormat(fileExtension: ext), want, "extension \"\(ext)\"")
        }
    }

    func test_urlAndPathInits_readThePathExtension() {
        XCTAssertEqual(DocumentFormat(url: URL(fileURLWithPath: "/p/Draft.fountain")), .fountain)
        XCTAssertEqual(DocumentFormat(url: URL(fileURLWithPath: "/p/Draft.FOUNTAIN")), .fountain)
        XCTAssertEqual(DocumentFormat(url: URL(fileURLWithPath: "/p/Chapter.md")), .markdown)
        XCTAssertNil(DocumentFormat(url: URL(fileURLWithPath: "/p/notes.txt")))
        XCTAssertNil(DocumentFormat(url: URL(fileURLWithPath: "/p/README")))

        XCTAssertEqual(DocumentFormat(path: "scripts/Draft.fountain"), .fountain)
        XCTAssertEqual(DocumentFormat(path: "Chapter.MD"), .markdown)
        XCTAssertEqual(DocumentFormat(path: "B.MD"), .markdown)
        XCTAssertNil(DocumentFormat(path: "notes.txt"))
        XCTAssertNil(DocumentFormat(path: "README"))
    }

    func test_ofManuscript_defaultsToMarkdown() {
        XCTAssertEqual(DocumentFormat.ofManuscript(url: URL(fileURLWithPath: "/p/Draft.fountain")), .fountain)
        XCTAssertEqual(DocumentFormat.ofManuscript(url: URL(fileURLWithPath: "/p/Draft.Fountain")), .fountain)
        XCTAssertEqual(DocumentFormat.ofManuscript(url: URL(fileURLWithPath: "/p/Chapter.md")), .markdown)
        XCTAssertEqual(DocumentFormat.ofManuscript(url: URL(fileURLWithPath: "/p/notes.txt")), .markdown)
        XCTAssertEqual(DocumentFormat.ofManuscript(url: URL(fileURLWithPath: "/p/README")), .markdown)

        XCTAssertEqual(DocumentFormat.ofManuscript(path: "Draft.FOUNTAIN"), .fountain)
        XCTAssertEqual(DocumentFormat.ofManuscript(path: "notes.txt"), .markdown)
        XCTAssertEqual(DocumentFormat.ofManuscript(path: "README"), .markdown)
        XCTAssertEqual(DocumentFormat.ofManuscript(path: nil), .markdown, "a path-less manuscript is prose")
        // Ruling P9: a file literally named ".fountain" has no extension.
        XCTAssertEqual(DocumentFormat.ofManuscript(path: ".fountain"), .markdown)
    }

    func test_fileExtension_roundTripsThroughTheParser() {
        for format in DocumentFormat.allCases {
            XCTAssertEqual(DocumentFormat(fileExtension: format.fileExtension), format)
        }
    }
}
