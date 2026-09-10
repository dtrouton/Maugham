import XCTest
import MaughamCore
@testable import Maugham

/// I2: the read-only translation review plane is built anchor-free. EditorHost
/// derives the surface buffer, the badge ranges, and the ⌘⌥L pane from ONE set
/// of per-paragraph entry texts (`EditorHost.reviewBadgeEntries`), stripping
/// inline task anchors at that single point. These tests pin the anchor-free
/// rendering without an AppKit surface (mirrors `TranslationBadgeMappingTests`).
/// Entries come from the real `TranslationDeriver.derive` (its `Entry` has no
/// public memberwise init) so the fixture also exercises the derive path.
final class EditorHostTranslationSurfaceTests: XCTestCase {

    func test_missingParagraph_sourceFallbackIsAnchorFree() {
        // Paragraph "b" has an inline task anchor and NO translation record →
        // derives `.missing`, rendering its source text as the fallback. The
        // review plane must strip the anchor.
        let sequence = ["a", "b"]
        let paragraphs = [
            "a": "Translated once",
            "b": "- [ ] buy milk <!--t-aaaaaa-->",
        ]
        let records = [
            TranslationRecord(paragraphId: "a", language: "es", text: "Traducido",
                              sourceHash: TranslationHash.hash("Translated once")),
        ]
        let derived = TranslationDeriver.derive(
            records: records, sequence: sequence, paragraphs: paragraphs, language: "es")

        let badges = EditorHost.reviewBadgeEntries(from: derived.entries)
        XCTAssertEqual(badges.count, 2)
        XCTAssertEqual(badges[0].text, "Traducido")
        XCTAssertEqual(badges[1].status, .missing)
        XCTAssertFalse(badges[1].text.contains("<!--t-"),
            "the missing paragraph's source fallback must render anchor-free (got: \(badges[1].text))")
        XCTAssertEqual(badges[1].text, "- [ ] buy milk",
            "the anchor is stripped but the checkbox body stays")

        // The joined surface buffer (what EditorHost swaps in) is anchor-free too.
        let surface = badges.map(\.text).joined(separator: "\n\n")
        XCTAssertFalse(surface.contains("<!--t-"))
    }

    func test_translatedText_passesThroughAndKeepsStatus() {
        // A normal translated paragraph passes through unchanged and keeps its
        // status for the badge overlay.
        let derived = TranslationDeriver.derive(
            records: [TranslationRecord(paragraphId: "a", language: "es", text: "Uno",
                                        sourceHash: "STALE")],
            sequence: ["a"], paragraphs: ["a": "One"], language: "es")
        let badges = EditorHost.reviewBadgeEntries(from: derived.entries)
        XCTAssertEqual(badges[0].text, "Uno")
        XCTAssertEqual(badges[0].status, .stale)
        XCTAssertEqual(badges[0].paragraphId, "a")
    }

    // MARK: - A present-but-unreadable translation file (P2a D0)

    /// **The read-only surface says why, and names the file.**
    ///
    /// The surface renders `translatedText ?? sourceText`, so a skipped actor
    /// file would draw this document's SOURCE paragraphs into the translation
    /// plane — a pane that looks like an untranslated manuscript over a
    /// translation sitting on disk intact. The refusal takes the surface
    /// instead, and it carries the filename.
    func test_theSurfaceShowsTheRefusalsOwnSentenceNamingTheFile() {
        let text = EditorHost.translationSurfaceRefusal(
            OpLogStore.ReadError.unreadableFile(
                name: "doc-1.es.maca-1234.jsonl",
                underlying: "Permission denied"))
        XCTAssertTrue(text.contains("doc-1.es.maca-1234.jsonl"),
                      "the writer is told which file to go and fix: \(text)")
        XCTAssertTrue(text.contains("Permission denied"),
                      "…and what stopped the read: \(text)")
    }
}
