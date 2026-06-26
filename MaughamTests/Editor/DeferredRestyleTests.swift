import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// Option B (forgiving-emphasis reframe): while typing, the visual syntax
/// repaint is deferred to the trailing edge of the typing burst so transient
/// invalid states (e.g. `*italic *` mid-edit) don't flip the styling on every
/// keystroke. CommonMark semantics are unchanged — only the *timing* of the
/// repaint moves. The compute (tokenize/metrics/element/cursor/scroll) stays
/// live; only the paint settles.
@MainActor
final class DeferredRestyleTests: XCTestCase {

    private func isItalic(_ tv: NSTextView, at index: Int) -> Bool {
        guard let storage = tv.textStorage, index < storage.length else { return false }
        let attrs = storage.attributes(at: index, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.italic)
    }

    /// Typing a fresh `*word*` does not paint the emphasis on the final
    /// keystroke — it waits for the burst to settle, then applies it.
    func test_emphasisRepaintIsDeferredUntilTypingSettles() async {
        let h = EditorIntegrationHarness(mode: ProseMode(), initialText: "")
        h.coordinator.restyleSettleDelayMs = 40
        await h.typeString("*word*")

        // Index 2 == "o" inside "word". Mid-burst (settle not yet fired): no italic.
        XCTAssertFalse(isItalic(h.textView, at: 2),
            "emphasis must not be painted on the keystroke — it is deferred to settle")

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(isItalic(h.textView, at: 2),
            "emphasis must be painted once the typing burst settles")
    }

    /// The transient invalid state never paints: extending an existing italic
    /// run by typing a trailing space does not strip the italic mid-burst
    /// (the user's flicker complaint). It only reconciles at settle.
    func test_extendingEmphasisDoesNotFlickerMidBurst() async {
        let h = EditorIntegrationHarness(
            mode: ProseMode(), initialText: "*italic*")
        h.coordinator.restyleSettleDelayMs = 40
        // Let the initial (synchronous, whole-doc) styling apply.
        XCTAssertTrue(isItalic(h.textView, at: 2), "precondition: *italic* is italic")

        // Put the caret just before the closing '*' and type a space, making the
        // transient `*italic *` — invalid CommonMark emphasis.
        h.setCursor(to: 7)            // ...c|*  (before the closing '*')
        h.typeCharacter(" ")

        // Mid-burst the existing italic must NOT be stripped (no flip-off).
        XCTAssertTrue(isItalic(h.textView, at: 2),
            "italic must not flip off mid-burst when a transient invalid state appears")
    }

    /// The settle paint must restyle only the burst's CHANGED window, not the
    /// whole document. A whole-doc `setAttributes` invalidates all layout, which
    /// perturbs the scroll origin and forces a fragile capture/restore that
    /// mis-lands on the last line (the "moves to a position then moves again /
    /// ends up off screen" bug). We prove the restyle is windowed by planting a
    /// sentinel attribute far from the edit: a whole-doc `setAttributes` wipes
    /// it; a windowed one leaves it intact.
    func test_settleRestyleIsWindowedNotWholeDocument() async {
        let body = "First paragraph here.\n\nSecond paragraph here.\n\n"
            + "Third and final paragraph at the very end of the document."
        let h = EditorIntegrationHarness(mode: ProseMode(), initialText: body)
        h.coordinator.restyleSettleDelayMs = 40

        // After init the synchronous whole-doc styling has applied. Plant a
        // sentinel attribute in the FIRST paragraph, far from where we'll edit.
        let sentinel = NSAttributedString.Key("maugham.test.sentinel")
        h.textView.textStorage?.addAttribute(
            sentinel, value: true, range: NSRange(location: 0, length: 1))

        // Edit at the very end of the document (the last line).
        h.setCursor(to: (body as NSString).length)
        h.typeCharacter("!")
        try? await Task.sleep(for: .milliseconds(120))

        let attrs = h.textView.textStorage?.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attrs?[sentinel],
            "settle restyle must be windowed to the edit, not a whole-document "
            + "setAttributes (a whole-doc repaint wipes far attributes and snaps scroll)")
    }
}
