import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// M3 of the typing-perf milestone (spec §7): the EditorCoordinator computes
/// `EditorMetrics` from the keystroke's OWN parse (`lastParsedScript`) and
/// delivers them through `onMetricsChanged` — coalesced to the same debounced
/// trailing edge as the script broadcast while typing, immediate on attach /
/// applyExternalText. ProjectWindow's consumer does zero parsing. These tests
/// drive a real EditorCoordinator headlessly via `EditorIntegrationHarness`
/// (the same offscreen NSTextView setup the binding-race harness uses), and
/// pin the FountainScript `==` O(1) rejection-gate optimization.
@MainActor
final class CoordinatorMetricsTests: XCTestCase {

    /// Slightly more than the coordinator's 350ms debounce window.
    private func awaitDebounce() async {
        try? await Task.sleep(for: .milliseconds(420))
    }

    // (a) Typing path: metrics arrive ONCE per debounce window, with pageCount
    //     from the parsed script and the correct word count.
    func test_typingPath_deliversOnceWithParsedPageCountAndWordCount() async {
        let body = """
        INT. KITCHEN - DAY

        She pours the coffee and waits for the kettle to sing.

        MIRANDA
        It's cold.
        """
        let harness = EditorIntegrationHarness(
            mode: ScreenplayMode(), initialText: body)

        var deliveries: [EditorMetrics] = []
        harness.coordinator.onMetricsChanged = { deliveries.append($0) }

        // Type a short burst at the end. Each keystroke re-arms the debounce.
        harness.setCursor(to: (harness.currentText as NSString).length)
        await harness.typeString(" now", intervalMs: 0)

        // Nothing should have fired synchronously during the burst (debounced).
        XCTAssertTrue(deliveries.isEmpty,
                      "typing-path metrics must be debounced, not per-keystroke")

        await awaitDebounce()

        XCTAssertEqual(deliveries.count, 1,
                       "exactly one metrics delivery per typing burst")
        let m = deliveries[0]
        // pageCount must equal the keystroke's own parse of the final text.
        let expectedScript = FountainTokenizer().parse(harness.currentText)
        XCTAssertEqual(m.pageCount, expectedScript.estimatedPageCount,
                       "pageCount must come from the parsed script, not a re-parse")
        // wordCount must match the shared WritingMode.wordCount semantics.
        let expectedWords = ScreenplayMode().wordCount(harness.currentText)
        XCTAssertEqual(m.wordCount, expectedWords)
        XCTAssertEqual(m.characterCount, (harness.currentText as NSString).length)
    }

    // (b) Attach delivers immediately (non-debounced).
    func test_attach_deliversImmediately() {
        let body = "INT. LAB - NIGHT\n\nThe machine hums."
        let harness = EditorIntegrationHarness(
            mode: ScreenplayMode(), initialText: body)

        var deliveries: [EditorMetrics] = []
        harness.coordinator.onMetricsChanged = { deliveries.append($0) }

        // Re-attach is the production doc-switch delivery path (a fresh
        // EditorSurface's coordinator attaches to its text view). It must
        // deliver SYNCHRONOUSLY — no debounce. (attach also re-applies
        // appearance, so it may emit more than one immediate post; the contract
        // is "immediate", not "exactly once".)
        harness.coordinator.attach(to: harness.textView)

        XCTAssertFalse(deliveries.isEmpty,
                       "attach must deliver metrics immediately (synchronously)")
        let expectedScript = FountainTokenizer().parse(harness.currentText)
        XCTAssertEqual(deliveries.last?.pageCount,
                       expectedScript.estimatedPageCount)
    }

    // (c) Doc switch mid-debounce delivers nothing stale: a pending debounced
    //     metrics post is cancelled by the next attach (the doc-switch path),
    //     and only the new immediate post lands.
    func test_docSwitchMidDebounce_dropsStalePost() async {
        let harness = EditorIntegrationHarness(
            mode: ScreenplayMode(), initialText: "INT. A - DAY\n\nAction one.")

        var deliveries: [EditorMetrics] = []
        harness.coordinator.onMetricsChanged = { deliveries.append($0) }

        // Arm the debounce by typing, then immediately "switch docs" via
        // applyExternalText (the cloud-conflict whole-doc replace path, which
        // shares the cancel-pending-then-immediate-post discipline with attach).
        harness.setCursor(to: (harness.currentText as NSString).length)
        await harness.typeString(" stale", intervalMs: 0)
        // One immediate delivery from applyExternalText; the armed debounced
        // one must be cancelled.
        deliveries.removeAll()
        harness.coordinator.applyExternalText("INT. B - NIGHT\n\nFresh action.")
        XCTAssertEqual(deliveries.count, 1,
                       "applyExternalText delivers exactly one immediate post")
        let immediate = deliveries[0]

        await awaitDebounce()

        XCTAssertEqual(deliveries.count, 1,
                       "no stale debounced post may land after the doc switch")
        // The surviving delivery reflects the NEW text, not the typed-into old one.
        let newScript = FountainTokenizer().parse(harness.currentText)
        XCTAssertEqual(immediate.pageCount, newScript.estimatedPageCount)
    }

    // (d) Prose mode delivers the same metrics `mode.metrics(text)` would.
    func test_proseMode_deliversMetricsEquivalent() async {
        let body = "A first paragraph.\n\nA second one, a little longer here."
        let harness = EditorIntegrationHarness(
            mode: ProseMode(), initialText: body)

        var deliveries: [EditorMetrics] = []
        harness.coordinator.onMetricsChanged = { deliveries.append($0) }

        harness.setCursor(to: (harness.currentText as NSString).length)
        await harness.typeString(" more.", intervalMs: 0)
        await awaitDebounce()

        XCTAssertEqual(deliveries.count, 1)
        let expected = ProseMode().metrics(harness.currentText)
        XCTAssertEqual(deliveries[0], expected,
                       "prose metrics must equal the parse-free mode.metrics")
        XCTAssertNil(deliveries[0].pageCount, "prose has no page count")
    }

    // (e) FountainScript == pre-check pin: two scripts with EQUAL rejection
    //     gates (line count, last-line range, titlePage) but a differing MIDDLE
    //     line must still compare UNEQUAL — the gates are an optimization, not
    //     an equality oracle.
    func test_precheckEqualButContentUnequal_comparesUnequal() {
        func line(_ loc: Int, _ len: Int, _ element: ScreenplayElement,
                  _ content: String) -> FountainLine {
            FountainLine(
                range: NSRange(location: loc, length: len),
                element: element, content: content,
                isForced: false, sourceCase: .mixed)
        }
        // Same line count (3), same last-line range, same titlePage (nil),
        // but the MIDDLE line's content/element differ.
        let a = FountainScript(lines: [
            line(0, 10, .action, "First line"),
            line(10, 10, .action, "Middle AAA"),
            line(20, 5, .action, "Tail."),
        ])
        let b = FountainScript(lines: [
            line(0, 10, .action, "First line"),
            line(10, 10, .character, "Middle BBB"),
            line(20, 5, .action, "Tail."),
        ])

        // Rejection gates are all equal.
        XCTAssertEqual(a.lines.count, b.lines.count)
        XCTAssertEqual(a.lines.last?.range, b.lines.last?.range)
        XCTAssertEqual(a.titlePage, b.titlePage)
        // ...yet the scripts are NOT equal.
        XCTAssertNotEqual(a, b,
                          "equal pre-check gates must still fall through to the "
                          + "full elementwise compare")

        // And a genuinely-equal pair stays equal.
        let aCopy = FountainScript(lines: a.lines)
        XCTAssertEqual(a, aCopy)
    }
}
