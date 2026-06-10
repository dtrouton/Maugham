import XCTest
@testable import MaughamCore

/// Pins `FountainScript.sceneSummaries()` (the one-pass, O(document) navigator
/// API) line-for-line against the per-call `pageNumber(at:)` +
/// `sceneLength(startingAt:)` it replaces. The one-pass walk must produce
/// EXACTLY the same page number and length for every scene — it reuses the
/// same private helpers, so any divergence is a bug. See tripwire 4 and the
/// `SceneNavigatorPane` body that renders from these summaries.
final class SceneSummariesParityTests: XCTestCase {
    private let parser = FountainTokenizer()

    /// Builds a long, varied screenplay: 60 scenes mixing action of varying
    /// length, dialogue, parentheticals, transitions, and dual-dialogue
    /// (`^`) pairs — every element class that feeds the page/length math.
    private func makeVariedScript() -> FountainScript {
        var blocks: [String] = []
        for i in 0..<60 {
            let interior = (i % 2 == 0) ? "INT." : "EXT."
            blocks.append("\(interior) LOCATION \(i) - DAY")
            blocks.append("")
            // Vary action length so page wraps differ scene to scene.
            let actionLen = 10 + (i * 7) % 140
            blocks.append(String(repeating: "x", count: actionLen) + " action.")
            blocks.append("")

            switch i % 4 {
            case 0:
                // Plain dialogue.
                blocks.append("ALICE")
                blocks.append("A line of dialogue that may wrap once or twice depending.")
                blocks.append("")
            case 1:
                // Dialogue with a parenthetical.
                blocks.append("BOB")
                blocks.append("(softly)")
                blocks.append("Another spoken line here for the block.")
                blocks.append("")
            case 2:
                // Dual dialogue pair.
                blocks.append("CARL")
                blocks.append("First half of a simultaneous exchange.")
                blocks.append("")
                blocks.append("DANA ^")
                blocks.append("Second half, side by side.")
                blocks.append("")
            default:
                // A transition then short action.
                blocks.append("CUT TO:")
                blocks.append("")
                blocks.append("Short beat.")
                blocks.append("")
            }
        }
        return parser.parse(blocks.joined(separator: "\n"))
    }

    func test_summaries_matchPerCallAPIs_exactly() {
        let script = makeVariedScript()
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        let summaries = script.sceneSummaries()

        XCTAssertGreaterThanOrEqual(scenes.count, 50,
            "Fixture should exercise 50+ scenes")
        XCTAssertEqual(summaries.count, scenes.count,
            "One summary per scene heading")

        for (summary, scene) in zip(summaries, scenes) {
            XCTAssertEqual(summary.line.range.location, scene.range.location,
                "Summary order must match scene-heading order")
            XCTAssertEqual(summary.pageNumber, script.pageNumber(at: scene),
                "pageNumber parity for scene at \(scene.range.location)")
            XCTAssertEqual(summary.length, script.sceneLength(startingAt: scene),
                accuracy: 0.0,
                "length parity for scene at \(scene.range.location)")
        }
    }

    func test_zeroScenes_returnsEmpty() {
        let script = parser.parse("""
        Just an action paragraph with no scene heading at all.

        And another, still no slugline.
        """)
        XCTAssertTrue(script.sceneSummaries().isEmpty)
    }

    func test_sceneAtLineZero() throws {
        let script = parser.parse("""
        INT. FIRST - DAY

        Opening action.

        ALICE
        Hi.
        """)
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        let summaries = script.sceneSummaries()
        XCTAssertEqual(summaries.count, 1)
        let first = try XCTUnwrap(summaries.first)
        XCTAssertEqual(first.line.range.location, scenes.first?.range.location)
        XCTAssertEqual(first.pageNumber, script.pageNumber(at: scenes[0]))
        XCTAssertEqual(first.length, script.sceneLength(startingAt: scenes[0]),
                       accuracy: 0.0)
        XCTAssertEqual(first.pageNumber, 1, "First scene begins on page 1")
    }

    func test_lastScene_runsToEnd() throws {
        let script = parser.parse("""
        INT. ONE - DAY

        Action.

        INT. TWO - NIGHT

        A long final action paragraph that fills several wrapped lines because \
        it keeps going past sixty characters more than once over here. \
        And keeps going. And going. And going.
        """)
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        let summaries = script.sceneSummaries()
        XCTAssertEqual(summaries.count, 2)
        // Last summary must match the per-call length for the trailing scene.
        let last = try XCTUnwrap(summaries.last)
        XCTAssertEqual(last.length,
                       script.sceneLength(startingAt: scenes[1]),
                       accuracy: 0.0)
        XCTAssertEqual(last.pageNumber,
                       script.pageNumber(at: scenes[1]))
        // Sanity: scene lengths sum to the whole-script page count.
        let summed = summaries.reduce(0) { $0 + $1.length }
        XCTAssertEqual(summed, script.estimatedPageCount, accuracy: 0.001)
    }

    func test_dualDialogueScene_parity() {
        let script = parser.parse("""
        INT. BAR - NIGHT

        BRICK
        Long line one here that wraps around.
        Long line two here that wraps around.
        Long line three here that wraps around.

        STEVE ^
        Hi.

        EXT. STREET - DAY

        After.
        """)
        let scenes = script.lines.filter { $0.element == .sceneHeading }
        let summaries = script.sceneSummaries()
        XCTAssertEqual(summaries.count, 2)
        for (summary, scene) in zip(summaries, scenes) {
            XCTAssertEqual(summary.pageNumber, script.pageNumber(at: scene))
            XCTAssertEqual(summary.length, script.sceneLength(startingAt: scene),
                           accuracy: 0.0)
        }
    }
}
