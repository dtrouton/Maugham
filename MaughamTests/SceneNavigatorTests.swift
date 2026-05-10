import XCTest
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
}
