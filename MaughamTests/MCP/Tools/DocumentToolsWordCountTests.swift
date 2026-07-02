import XCTest
import MaughamCore
@testable import Maugham

/// `read_document` returns the ANCHORED manuscript body (so Claude can target
/// paragraphs by `<!-- ¶id -->`), but `word_count` must count the DISPLAY form
/// — the anchor comment tokens (`<!--`, `¶id`, `-->`) are not words and would
/// inflate the count by ~3 per paragraph (spec "Minor" finding).
@MainActor
final class DocumentToolsWordCountTests: XCTestCase {

    func test_readDocument_wordCount_excludesAnchorTokens() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("WCFresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)

        let docPath = "manuscript/c1.md"
        let docId = "doc-wcfresh"
        let docURL = tmp.appendingPathComponent(docPath)
        // Two paragraphs → Bootstrap mints one `<!-- ¶id -->` anchor each.
        try "Alpha beta gamma.\n\nDelta epsilon.".write(
            to: docURL, atomically: true, encoding: .utf8)

        let item = StructureItem(id: docId, title: "Ch 1", type: .document, path: docPath)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))

        // Bootstrap seeds the op log; leave the doc CLOSED so read_document
        // returns the derived anchored form.
        _ = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)

        let store = try await ProjectStore.load(from: tmp)
        let reg = ProjectRegistry()
        reg.register(url: tmp, store: store)
        let projectId = ProjectIdentifier.id(for: tmp)

        let paramsData = Data(
            "{\"project_id\":\"\(projectId)\",\"document_id\":\"\(docId)\"}".utf8)
        let result = try await ReadDocumentTool.handle(paramsJSON: paramsData, registry: reg)
        let content = try JSONDecoder().decode(
            ReadDocumentTool.DocumentContent.self, from: result)

        // Precondition: the returned body IS anchored (otherwise the test is
        // vacuous — nothing to over-count).
        XCTAssertTrue(content.text.contains("<!--"),
            "read_document should return the anchored body; got: \(content.text)")

        // The five display words (Alpha beta gamma. Delta epsilon.) — anchor
        // tokens must not inflate the count.
        let displayWords = MarkdownDisplayFilter.stripAnchors(content.text)
            .split { $0.isWhitespace || $0.isNewline }.count
        XCTAssertEqual(content.word_count, displayWords,
            "word_count must be computed over the display form, not the anchored body")
        XCTAssertEqual(content.word_count, 5,
            "expected 5 display words; got \(content.word_count)")
    }
}
