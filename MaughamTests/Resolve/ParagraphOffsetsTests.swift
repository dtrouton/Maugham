import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 2, Task 2 — `ParagraphOffsets`: where each paragraph starts in
/// the editor's display text, computed from a sequence and its paragraphs
/// without a `Document`, and which scene each paragraph falls in.
///
/// The offsets must agree with the editor's to the character: the fixtures
/// carry a task anchor (invisible in the display text) and an emoji (two
/// UTF-16 units, one character). The `Document`s here are test fixtures —
/// production To resolve never loads one.
@MainActor
final class ParagraphOffsetsTests: XCTestCase {

    private func load(_ text: String, named name: String) async throws -> Document {
        let dir = TestTemp.root.appendingPathComponent("Offsets-\(UUID().uuidString)")
            .appendingPathComponent("manuscript")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try await Document.load(url: url, device: "test", session: "s", presenter: nil)
    }

    func test_paragraphOffsetsMatchTheDocumentsDisplayRange() async throws {
        let doc = try await load("""
        A party 🎉 begins.

        - [ ] bring the cake <!--t-aaaaaa-->

        More 🎉🎉 joy, after the task.

        - [ ] and the candles <!--t-bbbbbb-->

        The end.
        """, named: "doc.md")

        // Premise: the anchors are in the paragraphs and not on screen.
        XCTAssertTrue(doc.paragraphs.values.contains { $0.contains("<!--t-") },
                      "premise: a paragraph carries a task anchor")
        XCTAssertFalse(doc.displayText.contains("<!--t-"))
        XCTAssertTrue(doc.displayText.contains("🎉"))
        XCTAssertEqual(doc.sequence.count, 5)

        let starts = ParagraphOffsets.starts(sequence: doc.sequence, paragraphs: doc.paragraphs)
        XCTAssertEqual(starts.count, doc.sequence.count)
        for pid in doc.sequence {
            XCTAssertEqual(starts[pid], doc.displayRange(forParagraphId: pid)?.location,
                           "paragraph \(pid) starts where the editor puts it")
        }
        let last = try XCTUnwrap(doc.sequence.last)
        let tail = (doc.displayText as NSString).substring(from: try XCTUnwrap(starts[last]))
        XCTAssertEqual(tail, "The end.", "the last start lands on the last paragraph's first character")

        await doc.close()
    }

    func test_sceneIndexAgreesWithTheEditorsParseOfTheSameText() async throws {
        let doc = try await load("""
        A cold open 🎉 before any heading.

        INT. KITCHEN - DAY

        Larry sits 🎉🎉 by the stove. <!--t-aaaaaa-->

        EXT. ROOF - NIGHT

        He climbs.

        INT. CELLAR - LATER

        She waits.
        """, named: "script.\(DocumentFormat.fountain.fileExtension)")

        XCTAssertTrue(doc.paragraphs.values.contains { $0.contains("<!--t-") },
                      "premise: a paragraph before a slugline carries a task anchor")

        // The editor's parse: the same tokenizer over the same display text.
        let summaries = FountainTokenizer().parse(doc.displayText).sceneSummaries()
        XCTAssertEqual(summaries.map(\.line.content),
                       ["INT. KITCHEN - DAY", "EXT. ROOF - NIGHT", "INT. CELLAR - LATER"])
        let sceneStarts = summaries.map(\.line.range.location)

        let starts = ParagraphOffsets.starts(sequence: doc.sequence, paragraphs: doc.paragraphs)
        let index = ParagraphOffsets.sceneIndex(starts: starts, sceneStarts: sceneStarts)

        func pid(_ prefix: String) throws -> String {
            try XCTUnwrap(doc.sequence.first { doc.paragraphs[$0]?.hasPrefix(prefix) == true },
                          "no paragraph starts \(prefix)")
        }
        // Each slugline's paragraph starts exactly where the parse puts its scene.
        for (i, heading) in ["INT. KITCHEN", "EXT. ROOF", "INT. CELLAR"].enumerated() {
            XCTAssertEqual(starts[try pid(heading)], sceneStarts[i], "\(heading) to the character")
            XCTAssertEqual(index[try pid(heading)], i)
        }
        XCTAssertNil(index[try pid("A cold open")], "before the first slugline: absent")
        XCTAssertEqual(index[try pid("Larry sits")], 0)
        XCTAssertEqual(index[try pid("He climbs")], 1)
        XCTAssertEqual(index[try pid("She waits")], 2)

        await doc.close()
    }

    /// The boundary rule, pure: a paragraph starting exactly at a scene's
    /// start is that scene's; one starting before every scene is absent.
    func test_sceneIndexBoundaries() {
        let index = ParagraphOffsets.sceneIndex(
            starts: ["aa11": 0, "bb22": 10, "cc33": 11, "dd44": 30, "ee55": 45],
            sceneStarts: [10, 30])
        XCTAssertEqual(index, ["bb22": 0, "cc33": 0, "dd44": 1, "ee55": 1])
        XCTAssertEqual(ParagraphOffsets.sceneIndex(starts: ["aa11": 0], sceneStarts: []), [:])
    }
}
