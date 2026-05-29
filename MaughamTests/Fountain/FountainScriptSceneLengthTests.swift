import XCTest
import MaughamCore
@testable import Maugham

final class FountainScriptSceneLengthTests: XCTestCase {
    private let parser = FountainTokenizer()

    func testSceneLengthSumsToTotal() {
        // Two short scenes
        let raw = """
        INT. KITCHEN - DAY

        Action one.

        BARRY
        Hello.

        INT. ROOM - NIGHT

        Action two.

        SAM
        Goodbye.
        """
        let script = parser.parse(raw)
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        XCTAssertEqual(scenes.count, 2)
        let lengthA = script.sceneLength(startingAt: scenes[0])
        let lengthB = script.sceneLength(startingAt: scenes[1])
        XCTAssertGreaterThan(lengthA, 0)
        XCTAssertGreaterThan(lengthB, 0)
        XCTAssertEqual(lengthA + lengthB, script.estimatedPageCount, accuracy: 0.001,
                       "Scene lengths should sum to the script's total page count")
    }

    func testSceneLengthForLastSceneRunsToEnd() {
        let raw = """
        INT. ONLY SCENE - DAY

        A long action paragraph that fills many lines because of the wrap heuristic at sixty characters per line in action elements. \
        And another bit of action. \
        And yet more. \
        Finishing up here.
        """
        let script = parser.parse(raw)
        guard let scene = script.lines.first(where: { $0.element == .sceneHeading }) else {
            return XCTFail("No scene heading parsed")
        }
        let length = script.sceneLength(startingAt: scene)
        XCTAssertGreaterThan(length, 0)
        XCTAssertEqual(length, script.estimatedPageCount, accuracy: 0.001)
    }

    func testFormatPages() {
        XCTAssertEqual(SceneNavigatorPane.formatPages(0), "—")
        XCTAssertEqual(SceneNavigatorPane.formatPages(0.05), "<¼p")
        XCTAssertEqual(SceneNavigatorPane.formatPages(0.25), "¼p")
        XCTAssertEqual(SceneNavigatorPane.formatPages(0.5), "½p")
        XCTAssertEqual(SceneNavigatorPane.formatPages(0.75), "¾p")
        XCTAssertEqual(SceneNavigatorPane.formatPages(1.0), "1p")
        XCTAssertEqual(SceneNavigatorPane.formatPages(1.25), "1¼p")
        XCTAssertEqual(SceneNavigatorPane.formatPages(2.5), "2½p")
        XCTAssertEqual(SceneNavigatorPane.formatPages(3.75), "3¾p")
    }

    func test_sceneLength_includesDualPairAdjustment() {
        let parser = FountainTokenizer()
        let source = """
        INT. BAR - NIGHT

        BRICK
        Long line one here that wraps.
        Long line two here that wraps.
        Long line three here that wraps.

        STEVE ^
        Hi.
        """
        let script = parser.parse(source)
        guard let scene = script.lines.first(where: {
            $0.element == .sceneHeading
        }) else {
            XCTFail("Scene heading not found"); return
        }
        // Scene heading: 2 lines. BRICK block: 4. STEVE block: 2.
        // Raw: 2+4+2 = 8. Adjustment: min(4,2)=2. Net: 6.
        XCTAssertEqual(script.sceneLength(startingAt: scene),
                       6.0 / 55.0, accuracy: 0.001)
    }
}
