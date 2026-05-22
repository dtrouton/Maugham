import XCTest
@testable import Maugham

/// Tests for Document.paragraphId(at:).
///
/// The method scans the paragraph sequence in displayText order and returns
/// the id of whichever paragraph contains the given cursor offset.
/// `displayText` is the paragraphs joined by "\n\n" (anchors stripped).
@MainActor
final class DocumentParagraphIdAtTests: XCTestCase {

    // MARK: - Harness

    /// Builds a Document with the given raw markdown text (no anchors — Bootstrap
    /// will mint them on load). Returns the loaded Document.
    ///
    /// The .md is nested at `tmp/manuscript/doc.md` so that
    /// `resolveProjectURL` falls back to `tmp/` (2 levels up from the .md),
    /// giving each test an isolated `.maugham/` sidecar directory.
    private func makeDoc(text: String) async throws -> Document {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PIDAt-\(UUID().uuidString)")
        let manuscriptDir = tmp.appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(
            at: manuscriptDir, withIntermediateDirectories: true)
        let mdURL = manuscriptDir.appendingPathComponent("doc.md")
        try text.write(to: mdURL, atomically: true, encoding: .utf8)
        return try await Document.load(
            url: mdURL, device: "test", session: "s", presenter: nil)
    }

    // MARK: - Tests

    func test_paragraphId_returnsNilForEmptyText() async throws {
        let doc = try await makeDoc(text: "")
        // Empty document: sequence is empty, so nil is expected.
        let result = doc.paragraphId(at: 0)
        // An empty doc has no paragraphs; result should be nil.
        XCTAssertNil(result)
    }

    func test_paragraphId_returnsIdForSingleParagraph() async throws {
        let doc = try await makeDoc(text: "Hello world.")
        // Bootstrap will mint exactly one paragraph id.
        let ops = try await doc.opLog()
        guard let bootstrapChange = ops.first(where: { $0.kind == .bootstrap })?
            .changes.first else {
            XCTFail("Expected bootstrap op with one change")
            return
        }
        let pid = bootstrapChange.paragraphId
        // Cursor anywhere in "Hello world." should return the single paragraph id.
        XCTAssertEqual(doc.paragraphId(at: 0), pid)
        XCTAssertEqual(doc.paragraphId(at: 5), pid)
        XCTAssertEqual(doc.paragraphId(at: 12), pid) // end of text
    }

    func test_paragraphId_returnsCorrectIdForTwoParagraphs() async throws {
        // Two paragraphs separated by blank line (double newline in .md).
        let doc = try await makeDoc(text: "First paragraph.\n\nSecond paragraph.")
        let ops = try await doc.opLog()
        let changes = ops.first(where: { $0.kind == .bootstrap })?.changes ?? []
        // Bootstrap produces changes in sequence order.
        guard changes.count == 2 else {
            XCTFail("Expected 2 bootstrap changes, got \(changes.count)")
            return
        }
        let firstId = changes[0].paragraphId
        let secondId = changes[1].paragraphId

        // displayText = "First paragraph.\n\nSecond paragraph."
        // "First paragraph." is 16 chars (index 0..15).
        // "\n\n" separator is at 16..17.
        // "Second paragraph." starts at 18.
        XCTAssertEqual(doc.paragraphId(at: 0), firstId)   // start of first
        XCTAssertEqual(doc.paragraphId(at: 8), firstId)   // middle of first
        XCTAssertEqual(doc.paragraphId(at: 16), firstId)  // end of first (within the paragraph)
        XCTAssertEqual(doc.paragraphId(at: 18), secondId) // start of second
        XCTAssertEqual(doc.paragraphId(at: 25), secondId) // middle of second
    }

    func test_paragraphId_clampsNegativeLocationToZero() async throws {
        let doc = try await makeDoc(text: "Some text.")
        // Negative location should not crash and should return the first paragraph.
        let result = doc.paragraphId(at: -1)
        // Should return the (only) paragraph id, not nil.
        let ops = try await doc.opLog()
        let pid = ops.first(where: { $0.kind == .bootstrap })?.changes.first?.paragraphId
        XCTAssertEqual(result, pid)
    }

    func test_paragraphId_clampsLargeLocationToLastParagraph() async throws {
        let doc = try await makeDoc(text: "Some text.")
        // Extremely large location: should return the last paragraph id, not crash.
        let result = doc.paragraphId(at: Int.max)
        let ops = try await doc.opLog()
        let pid = ops.first(where: { $0.kind == .bootstrap })?.changes.last?.paragraphId
        XCTAssertEqual(result, pid)
    }
}
