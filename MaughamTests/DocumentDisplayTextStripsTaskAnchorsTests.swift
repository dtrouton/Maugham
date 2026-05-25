import XCTest
@testable import Maugham

/// Regression: when a paragraph carries inline task anchors
/// `<!--t-XXXXXX-->` (which it does intentionally for V2 alignment
/// round-trip), `Document.displayText` MUST strip them so the editor
/// doesn't render anchor markup verbatim. The .md on disk and the
/// in-memory `paragraphs[id]` keep anchors; only `displayText` is
/// stripped. Mirrors how paragraph anchors live in the .md but never
/// in displayText.
@MainActor
final class DocumentDisplayTextStripsTaskAnchorsTests: XCTestCase {

    private func makeDoc(text: String) async throws -> Document {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DDST-\(UUID().uuidString)")
        let manuscriptDir = tmp.appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(
            at: manuscriptDir, withIntermediateDirectories: true)
        let mdURL = manuscriptDir.appendingPathComponent("doc.md")
        try text.write(to: mdURL, atomically: true, encoding: .utf8)
        return try await Document.load(
            url: mdURL, device: "test", session: "s", presenter: nil)
    }

    func test_displayText_stripsMarkdownLineTaskAnchors() async throws {
        let stored = """
        <!-- ¶fwvn -->

        - [ ] foo <!--t-aaaaaa-->
        - [x] bar <!--t-bbbbbb-->
        """
        let doc = try await makeDoc(text: stored)
        XCTAssertFalse(doc.displayText.contains("<!--t-"),
            "task anchors must be stripped from displayText; got: \(doc.displayText)")
        XCTAssertEqual(doc.displayText, """
        - [ ] foo
        - [x] bar
        """)
    }

    func test_displayText_stripsFountainInlineTaskAnchors() async throws {
        let stored = """
        <!-- ¶fwvn -->

        And so it goes [[todo: clean this up]]<!--t-vc14vc--> is what she said
        """
        let doc = try await makeDoc(text: stored)
        XCTAssertFalse(doc.displayText.contains("<!--t-"),
            "Fountain inline anchor must be stripped from displayText; got: \(doc.displayText)")
        XCTAssertEqual(doc.displayText,
            "And so it goes [[todo: clean this up]] is what she said")
    }

    func test_paragraphsMap_keepsAnchors() async throws {
        // Symmetric check: anchors must remain in `paragraphs[id]` even
        // though they're stripped from displayText. V2 alignment depends on
        // them being there for the round-trip.
        let stored = """
        <!-- ¶fwvn -->

        - [ ] foo <!--t-aaaaaa-->
        """
        let doc = try await makeDoc(text: stored)
        let para = doc.paragraph(id: "fwvn")
        XCTAssertNotNil(para)
        XCTAssertTrue(para!.contains("<!--t-aaaaaa-->"),
            "paragraphs[id] must keep the anchor for V2 round-trip; got: \(para!)")
    }

    func test_displayText_stripsMixedMarkdownAndFountainAnchors() async throws {
        let stored = """
        <!-- ¶fwvn -->

        - [x] Test of a test <!--t-a3gwy8-->
        And so it goes [[todo: clean this up]]<!--t-vc14vc--> is what she said
        - [ ] stop this <!--t-bda288-->
        """
        let doc = try await makeDoc(text: stored)
        XCTAssertFalse(doc.displayText.contains("<!--t-"),
            "mixed anchors must all be stripped; got: \(doc.displayText)")
    }
}
