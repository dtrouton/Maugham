// MaughamTests/OpLog/MaterializerTests.swift
import XCTest
@testable import Maugham

final class MaterializerTests: XCTestCase {
    func test_materialize_emptySequence_returnsEmptyString() {
        XCTAssertEqual(Materializer.materialize(paragraphs: [:], sequence: []), "")
    }

    func test_materialize_singleParagraph_withId_emitsCommentAndText() {
        let md = Materializer.materialize(
            paragraphs: ["a3f9": "The morning began."],
            sequence: ["a3f9"])
        XCTAssertEqual(md, "<!-- ¶a3f9 -->\n\nThe morning began.\n")
    }

    func test_materialize_multipleParagraphs_blankLineSeparated() {
        let md = Materializer.materialize(
            paragraphs: ["a3f9": "First.", "b21c": "Second."],
            sequence: ["a3f9", "b21c"])
        XCTAssertEqual(md,
            "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n")
    }

    func test_materialize_missingParagraphInMap_isSkipped() {
        let md = Materializer.materialize(
            paragraphs: ["a3f9": "Present."],
            sequence: ["a3f9", "ghost", "b21c"])
        XCTAssertEqual(md, "<!-- ¶a3f9 -->\n\nPresent.\n")
    }

    func test_roundTrip_parserMaterializerProducesSameStructure() {
        let original = "<!-- ¶a3f9 -->\n\nFirst.\n\n<!-- ¶b21c -->\n\nSecond.\n"
        let parsed = ParagraphParser.parse(original)
        var map = [String: String]()
        var seq = [String]()
        for p in parsed {
            guard let id = p.id else { continue }
            map[id] = p.text
            seq.append(id)
        }
        let mat = Materializer.materialize(paragraphs: map, sequence: seq)
        XCTAssertEqual(mat, original)
    }
}
