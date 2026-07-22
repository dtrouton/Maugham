import XCTest
@testable import MaughamCore

final class TranslationDeriverTests: XCTestCase {
    func test_hashNormalization_stripsAnchorsAndTrailingWhitespace() {
        XCTAssertEqual(TranslationHash.hash("Hello world"),
                       TranslationHash.hash("Hello world   "))
        XCTAssertEqual(TranslationHash.hash("Line one\nLine two"),
                       TranslationHash.hash("Line one  \nLine two\t"))
        // MarkdownDisplayFilter's inline task-anchor regex eats one leading
        // whitespace char along with the anchor (documented there, to avoid a
        // stray double space after collapse), so this normalizes to one space,
        // not two.
        XCTAssertEqual(TranslationHash.hash("Text <!--t-aaaaaa--> tail"),
                       TranslationHash.hash("Text tail")) // task anchor stripped
        XCTAssertNotEqual(TranslationHash.hash("Hello"), TranslationHash.hash("Hola"))
    }

    func test_derive_statuses() {
        let paragraphs = ["aaaa": "One", "bbbb": "Two", "cccc": "Three"]
        let sequence = ["aaaa", "bbbb", "cccc"]
        let records = [
            TranslationRecord(paragraphId: "aaaa", language: "es", text: "Uno",
                              sourceHash: TranslationHash.hash("One")),
            TranslationRecord(paragraphId: "bbbb", language: "es", text: "Dos",
                              sourceHash: TranslationHash.hash("OLD TEXT")),
            TranslationRecord(paragraphId: "zzzz", language: "es", text: "Huérfano",
                              sourceHash: "x"),
        ]
        let doc = TranslationDeriver.derive(records: records, sequence: sequence,
                                            paragraphs: paragraphs, language: "es")
        XCTAssertEqual(doc.entries.map(\.status), [.fresh, .stale, .missing])
        XCTAssertEqual(doc.entries.map(\.paragraphId), sequence) // sequence order
        XCTAssertEqual(doc.orphans.map(\.paragraphId), ["zzzz"])
        XCTAssertEqual(doc.freshCount, 1); XCTAssertEqual(doc.staleCount, 1)
        XCTAssertEqual(doc.missingCount, 1)
        XCTAssertNil(doc.entries[2].translatedText)
        XCTAssertEqual(doc.entries[2].sourceText, "Three")
    }

    func test_derive_latestWinsWithinRecords() {
        let old = TranslationRecord(paragraphId: "aaaa", language: "es", text: "vieja",
                                    sourceHash: TranslationHash.hash("One"))
        let new = TranslationRecord(paragraphId: "aaaa", language: "es", text: "nueva",
                                    sourceHash: TranslationHash.hash("One"))
        let doc = TranslationDeriver.derive(records: [old, new], sequence: ["aaaa"],
                                            paragraphs: ["aaaa": "One"], language: "es")
        XCTAssertEqual(doc.entries[0].translatedText, "nueva")
    }
}
