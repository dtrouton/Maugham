import XCTest
import MaughamCore
@testable import Maugham

final class SceneNavigatorTests: XCTestCase {
    private let parser = FountainTokenizer()

    func test_sceneFilter_extractsOnlySceneHeadings() {
        let text = """
        INT. KITCHEN - DAY

        Larry sits.

        BARRY
        Hi.

        EXT. ROOFTOP - NIGHT

        Action.
        """
        let script = parser.parse(text)
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].content, "INT. KITCHEN - DAY")
        XCTAssertEqual(scenes[1].content, "EXT. ROOFTOP - NIGHT")
    }

    func test_sceneFilter_includesForcedSceneHeadings() {
        let script = parser.parse("INT. ROOM\n\n.barbershop\n\nINT. CAR")
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        XCTAssertEqual(scenes.count, 3)
        XCTAssertEqual(scenes[1].content, "barbershop")
    }

    func test_sceneFilter_emptyScript_returnsEmpty() {
        let script = FountainScript.empty
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        XCTAssertEqual(scenes.count, 0)
    }

    func test_sceneFilter_preservesOrder() {
        let text = (1...5).map { "INT. ROOM \($0) - DAY\n\nAction.\n\n" }.joined()
        let script = parser.parse(text)
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        XCTAssertEqual(scenes.count, 5)
        for i in 0..<5 {
            XCTAssertEqual(scenes[i].content, "INT. ROOM \(i+1) - DAY")
        }
    }

    // MARK: - Row caption rendering (one-pass summaries)

    func test_rowCaption_withLength_showsPageAndCompactFraction() {
        let line = FountainLine(range: NSRange(location: 0, length: 0),
                                element: .sceneHeading, content: "INT. X - DAY",
                                isForced: false, sourceCase: .upper)
        let summary = FountainScript.SceneSummary(line: line, pageNumber: 3, length: 0.25)
        XCTAssertEqual(SceneNavigatorPane.rowCaption(for: summary), "p3 · ¼")
    }

    func test_rowCaption_zeroLength_collapsesToPageOnly() {
        let line = FountainLine(range: NSRange(location: 0, length: 0),
                                element: .sceneHeading, content: "INT. X - DAY",
                                isForced: false, sourceCase: .upper)
        let summary = FountainScript.SceneSummary(line: line, pageNumber: 7, length: 0)
        XCTAssertEqual(SceneNavigatorPane.rowCaption(for: summary), "p7")
    }

    func test_rowCaption_matchesPriorFormat_fromParsedScript() {
        let script = parser.parse("""
        INT. KITCHEN - DAY

        Larry sits and thinks about the day ahead of him.

        BARRY
        Hi there friend.

        EXT. ROOFTOP - NIGHT

        A short beat.
        """)
        let summaries = script.sceneSummaries()
        XCTAssertEqual(summaries.count, 2)
        // Recompute the caption the OLD way and confirm pixel-identical output.
        for summary in summaries {
            let expectedLen = SceneNavigatorPane.formatPagesCompact(summary.length)
            let expected = expectedLen.isEmpty
                ? "p\(summary.pageNumber)"
                : "p\(summary.pageNumber) · \(expectedLen)"
            XCTAssertEqual(SceneNavigatorPane.rowCaption(for: summary), expected)
        }
    }
}
