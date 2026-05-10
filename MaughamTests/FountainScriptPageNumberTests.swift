import XCTest
@testable import Maugham

final class FountainScriptPageNumberTests: XCTestCase {
    private let parser = FountainTokenizer()

    func test_firstSceneHeading_isPage1() {
        let script = parser.parse("INT. KITCHEN - DAY\n\nLarry sits.")
        let scene = script.lines.first { $0.element == .sceneHeading }
        XCTAssertNotNil(scene)
        XCTAssertEqual(script.pageNumber(at: scene!), 1)
    }

    func test_pageNumber_monotonicallyIncreasesByLineOrder() {
        // Build a long document with multiple scene headings and dialogue.
        var blob = ""
        for i in 1...10 {
            blob += "INT. ROOM \(i) - DAY\n\n"
            blob += String(repeating: "Action paragraph. ", count: 30) + "\n\n"
        }
        let script = parser.parse(blob)
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        XCTAssertGreaterThan(scenes.count, 5)
        var prevPage = 0
        for scene in scenes {
            let page = script.pageNumber(at: scene)
            XCTAssertGreaterThanOrEqual(page, prevPage)
            prevPage = page
        }
    }

    func test_pageNumber_respectsLineWrapping() {
        // 110 lines of action ≈ 2 pages. The 60th line should be page 2.
        let actionLines = (1...110).map { "Line \($0). " + String(repeating: "x", count: 40) }
            .joined(separator: "\n")
        let script = parser.parse(actionLines)
        XCTAssertGreaterThan(script.lines.count, 100)
        let firstLinePage = script.pageNumber(at: script.lines[0])
        let lastLinePage = script.pageNumber(at: script.lines.last!)
        XCTAssertEqual(firstLinePage, 1)
        XCTAssertGreaterThan(lastLinePage, 1)
    }

    func test_emptyScript_pageNumberReturns1() {
        let script = FountainScript.empty
        // Synthetic line at location 0 should return 1.
        let synthetic = FountainLine(
            range: NSRange(location: 0, length: 0),
            element: .action, content: "",
            isForced: false, sourceCase: .neutral)
        XCTAssertEqual(script.pageNumber(at: synthetic), 1)
    }

    func test_estimatedPageCount_unchanged_afterRefactor() {
        // Sanity: estimatedPageCount math should remain identical.
        let blob = (1...27).map { "INT. ROOM \($0) - DAY\n\n" }.joined()
        let script = parser.parse(blob)
        XCTAssertEqual(script.estimatedPageCount, 0.98, accuracy: 0.05)
    }
}
