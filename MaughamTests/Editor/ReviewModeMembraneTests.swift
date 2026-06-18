import XCTest
import SwiftUI
import AppKit
@testable import Maugham

final class ReviewModeMembraneTests: XCTestCase {
    func test_reviewMode_disallowsTextMutation() {
        XCTAssertFalse(EditorEditPolicy.allowsTextMutation(isReviewMode: true))
        XCTAssertTrue(EditorEditPolicy.allowsTextMutation(isReviewMode: false))
    }

    /// Bug B regression: the synchronous membrane flip must take effect BEFORE
    /// the next key event, not after a SwiftUI render round-trip. `setReviewMode`
    /// is the same synchronous mutator the ⌘⌥R observer drives; once it has run,
    /// `shouldChangeTextIn` (the single mutation choke point AppKit funnels typing
    /// / paste / delete / Enter through) must reject every mutation. Before the
    /// fix, `isReviewMode` only flipped in updateNSView, so a fast Enter right
    /// after ⌘⌥R slipped a newline through.
    @MainActor
    func test_setReviewMode_blocksMutationImmediately() {
        final class TextBox { var value = "Hello world" }
        let box = TextBox()
        let coordinator = EditorCoordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            mode: ProseMode(),
            theme: .light, typography: .defaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        tv.string = box.value
        tv.delegate = coordinator
        coordinator.attach(to: tv)

        // Before entering review, a mutation (e.g. typing a newline) is allowed.
        XCTAssertTrue(
            coordinator.textView(
                tv,
                shouldChangeTextIn: NSRange(location: 5, length: 0),
                replacementString: "\n"),
            "edits must pass through before review mode is on")

        // The synchronous flip (the path the ⌘⌥R observer drives).
        coordinator.setReviewMode(true)

        // Immediately after — no render round-trip — the membrane must block.
        XCTAssertFalse(
            coordinator.textView(
                tv,
                shouldChangeTextIn: NSRange(location: 5, length: 0),
                replacementString: "\n"),
            "after the synchronous review flip the membrane must block the very next keystroke")

        // Leaving review re-opens the membrane.
        coordinator.setReviewMode(false)
        XCTAssertTrue(
            coordinator.textView(
                tv,
                shouldChangeTextIn: NSRange(location: 5, length: 0),
                replacementString: "\n"),
            "leaving review must restore normal editing")
    }
}
