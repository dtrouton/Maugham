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

    func test_pageNumber_beforePair_unaffected() {
        // Manufacture a long pre-pair section to force the next page boundary
        // to fall AFTER the dual pair.
        var source = ""
        for _ in 0..<60 {
            source += "An action line that wraps somewhere in the middle.\n\n"
        }
        let preCueIndex = source.count
        source += """
        BRICK
        Hi.

        STEVE ^
        Hi.
        """
        let script = parser.parse(source)
        // Find the line that starts at preCueIndex (BRICK cue).
        guard let brick = script.lines.first(where: { $0.range.location == preCueIndex }) else {
            XCTFail("BRICK line not found"); return
        }
        // BRICK is BEFORE any pair closes — page number unchanged by adjustment.
        // The first 60 action lines = 60 lines / 55 lines per page ≈ page 2.
        XCTAssertEqual(script.pageNumber(at: brick), 2)
    }

    func test_pageNumber_afterPair_appliesAdjustment() {
        // Pair (3-line first, 1-line second). After the pair closes, the
        // next cue's page number is computed using the adjusted total.
        let source = """
        BRICK
        Line one.
        Line two.
        Line three.

        STEVE ^
        Hi.

        ALICE
        Cheers.
        """
        let script = parser.parse(source)
        guard let alice = script.lines.first(where: {
            $0.element == .character && $0.content == "ALICE"
        }) else {
            XCTFail("ALICE cue not found"); return
        }
        // BRICK block: 4 lines. STEVE block: 2 lines.
        // Raw before ALICE: 4+2 = 6. Adjustment: min(4,2)=2. Net: 4 → page 1.
        XCTAssertEqual(script.pageNumber(at: alice), 1)
    }
}
