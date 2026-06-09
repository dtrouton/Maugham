import XCTest
import MaughamCore
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

    // MARK: - Unicode / emoji / task-anchor alignment

    /// Paragraph 1 contains an emoji (🎉), which occupies 2 UTF-16 code units
    /// but only 1 grapheme cluster.  The editor's `selectedRange` is expressed
    /// in UTF-16 (NSRange against textView.string, which is the stripped display
    /// form).  The old `text.count` grapheme-based logic under-counts the first
    /// paragraph's length by 1, so a cursor at display-text UTF-16 offset 7 (the
    /// "\n" of the "\n\n" separator that follows "Café 🎉") was wrongly mapped to
    /// the second paragraph.
    ///
    /// "Café 🎉" UTF-16 length = 7 (C·a·f·é·SP·🎉hi·🎉lo = 7 code units).
    /// "Café 🎉" grapheme count = 6.
    /// With the fix, cursor at UTF-16 offset 7 must land on para 1 (the emoji
    /// paragraph), not para 2.
    func test_paragraphId_emojiParagraph_correctUTF16Mapping() async throws {
        // Two paragraphs; first contains an emoji.
        let doc = try await makeDoc(text: "Caf\u{E9} \u{1F389}\n\nSecond paragraph.")
        let ops = try await doc.opLog()
        let changes = ops.first(where: { $0.kind == .bootstrap })?.changes ?? []
        guard changes.count == 2 else {
            XCTFail("Expected 2 bootstrap changes, got \(changes.count)")
            return
        }
        let emojiParaId = changes[0].paragraphId  // "Café 🎉"
        let secondParaId = changes[1].paragraphId // "Second paragraph."

        // "Café 🎉" has UTF-16 length 7 (é = U+00E9 = 1 UTF-16; 🎉 = U+1F389 = 2 UTF-16).
        // displayText = "Café 🎉\n\nSecond paragraph."
        //               offsets: 0–6 = emoji para content; 7–8 = "\n\n"; 9+ = second para.
        // paragraphId(at:) condition: cursor <= offset + length means
        //   cursor at 7 (the "\n") should still be "within" para 1 (7 <= 0+7).
        // With the old grapheme-count bug: 7 <= 0+6 = false → wrongly returns para 2.
        XCTAssertEqual(doc.paragraphId(at: 0), emojiParaId,  "start of emoji para")
        XCTAssertEqual(doc.paragraphId(at: 5), emojiParaId,  "high surrogate of 🎉")
        XCTAssertEqual(doc.paragraphId(at: 6), emojiParaId,  "low surrogate of 🎉")
        XCTAssertEqual(doc.paragraphId(at: 7), emojiParaId,  "position at para-1 UTF-16 end (cursor still in para 1)")
        XCTAssertEqual(doc.paragraphId(at: 9), secondParaId, "start of second para in display space")
        XCTAssertEqual(doc.paragraphId(at: 15), secondParaId, "middle of second para")

        // Round-trip: displayRange(forParagraphId:) must agree.
        // displayRange uses (stripped as NSString).length — the correct coordinate.
        // After the fix, paragraphId(at: X) and displayRange(forParagraphId: id)
        // must be consistent: the range for emojiParaId starts at 0, length 7.
        if let range = doc.displayRange(forParagraphId: emojiParaId) {
            XCTAssertEqual(range.location, 0, "emoji para range starts at 0")
            XCTAssertEqual(range.length, 7,   "emoji para range length = 7 UTF-16 units")
        } else {
            XCTFail("displayRange(forParagraphId: emojiParaId) returned nil")
        }
        // paragraphId(at: range.location) should round-trip back to emojiParaId.
        if let range = doc.displayRange(forParagraphId: emojiParaId) {
            XCTAssertEqual(doc.paragraphId(at: range.location), emojiParaId,
                           "paragraphId round-trips through displayRange.location")
        }
    }

    /// A task anchor (`<!--t-XXXXXX-->`) embedded in a paragraph increases the
    /// raw `text.count` but is stripped from `displayText`.  `paragraphId(at:)`
    /// must use the stripped length so cursor offsets expressed against
    /// displayText are resolved correctly.
    ///
    /// This test injects a task-anchored paragraph via a direct setParagraph
    /// mutation rather than through the typed checkbox UI, which lets us control
    /// the exact raw text.  A cursor in the second (plain) paragraph must not
    /// "overshoot" into sequence.last when the first paragraph's raw length is
    /// inflated by a task anchor.
    func test_paragraphId_taskAnchoredParagraph_stripBeforeMapping() async throws {
        // Bootstrap with two plain paragraphs.
        let doc = try await makeDoc(text: "First paragraph.\n\nSecond paragraph.")
        let ops = try await doc.opLog()
        let changes = ops.first(where: { $0.kind == .bootstrap })?.changes ?? []
        guard changes.count == 2 else {
            XCTFail("Expected 2 bootstrap changes, got \(changes.count)")
            return
        }
        let firstId  = changes[0].paragraphId
        let secondId = changes[1].paragraphId

        // Inject a task anchor into para 1 via setParagraph.
        // The anchor is 16 chars: "<!--t-aabbcc-->" but <!--t-XXXXXX--> is the
        // real pattern (6-char id + delimiters).  Use a known-valid anchor.
        // Raw stored text = "First paragraph.<!--t-aa1234-->"
        // Stripped display = "First paragraph." (16 chars = 16 UTF-16)
        let anchoredText = "First paragraph.<!--t-aa1234-->"
        doc.setParagraph(id: firstId, text: anchoredText)

        // After mutation displayText = "First paragraph.\n\nSecond paragraph."
        // UTF-16 offsets: 0–15 = first para display; 16–17 = "\n\n"; 18+ = second.
        // With the old raw-text-count bug: text.count = 31 (raw anchored length).
        //   Cursor at 18 <= 0+31 → TRUE → maps to para 1 (wrong!).
        // With the fix: stripped length = 16; cursor 18 > 16 → check para 2 → correct.
        XCTAssertEqual(doc.paragraphId(at: 0),  firstId,  "start of first para")
        XCTAssertEqual(doc.paragraphId(at: 15), firstId,  "end of first para display content")
        XCTAssertEqual(doc.paragraphId(at: 18), secondId, "start of second para (offset 18 = 16 + 2-sep)")
        XCTAssertEqual(doc.paragraphId(at: 25), secondId, "middle of second para")
    }
}
