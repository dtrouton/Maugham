import XCTest
@testable import MaughamPhone
import MaughamCore

final class BinderRoutingTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/Project", isDirectory: true)

    private func document(path: String?) -> StructureItem {
        StructureItem(id: "d1", title: "Doc", type: .document, path: path)
    }

    private func group() -> StructureItem {
        StructureItem(id: "g1", title: "Group", type: .group, children: [])
    }

    func test_isReadableDocument_trueForDocumentWithPath() {
        XCTAssertTrue(BinderRouting.isReadableDocument(document(path: "ch1.md")))
    }

    func test_isReadableDocument_falseForGroup() {
        XCTAssertFalse(BinderRouting.isReadableDocument(group()))
    }

    func test_isReadableDocument_falseForPathlessDocument() {
        XCTAssertFalse(BinderRouting.isReadableDocument(document(path: nil)))
        XCTAssertFalse(BinderRouting.isReadableDocument(document(path: "")))
    }

    func test_documentURL_joinsProjectRootAndPath() {
        let url = BinderRouting.documentURL(for: document(path: "Chapters/ch1.md"),
                                            projectRoot: root)
        XCTAssertEqual(url, root.appendingPathComponent("Chapters/ch1.md"))
    }

    func test_documentURL_nilForGroup() {
        XCTAssertNil(BinderRouting.documentURL(for: group(), projectRoot: root))
    }

    func test_documentURL_nilForPathlessDocument() {
        XCTAssertNil(BinderRouting.documentURL(for: document(path: nil), projectRoot: root))
    }

    func test_format_classifiesExtensions() {
        XCTAssertEqual(DocumentFormat(url: URL(fileURLWithPath: "/a/b.md")), .markdown)
        XCTAssertEqual(DocumentFormat(url: URL(fileURLWithPath: "/a/b.fountain")), .fountain)
        XCTAssertNil(DocumentFormat(url: URL(fileURLWithPath: "/a/b.txt")))
    }

    func test_format_caseInsensitiveExtension() {
        XCTAssertEqual(DocumentFormat(url: URL(fileURLWithPath: "/a/B.MD")), .markdown)
        // Plan 7 exception 1: an upper-case Fountain extension now reads as Fountain.
        XCTAssertEqual(DocumentFormat(url: URL(fileURLWithPath: "/a/X.FOUNTAIN")), .fountain)
    }
}
