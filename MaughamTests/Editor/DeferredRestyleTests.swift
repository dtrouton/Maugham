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

    private func isBold(_ tv: NSTextView, at index: Int) -> Bool {
        guard let storage = tv.textStorage, index < storage.length else { return false }
        let attrs = storage.attributes(at: index, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else { return false }
        return font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    /// Policy: prose defers the restyle to the burst settle; screenplay paints
    /// it live (its styling is element-classification heavy, so the settle delay
    /// reads as pervasive lag). The coordinator branches on this flag.
    func test_restyleDeferralPolicyPerMode() {
        XCTAssertTrue(ProseMode().defersRestyleWhileTyping,
            "prose defers the restyle to settle (flicker-free emphasis)")
        XCTAssertFalse(ScreenplayMode().defersRestyleWhileTyping,
            "screenplay paints the restyle live on each keystroke")
    }

    /// Screenplay must NOT defer: a scene heading typed on a fresh line is
    /// styled (bold) immediately, with no settle wait. The settle delay is set
    /// absurdly high so that, if the code deferred, the assertion would fail.
    func test_screenplayRestylesLiveWhileTyping() async {
        let h = EditorIntegrationHarness(mode: ScreenplayMode(), initialText: "")
        h.coordinator.restyleSettleDelayMs = 5000   // prove we do NOT wait for it
        await h.typeString("INT. HOUSE - DAY")

        // No settle sleep: the live path must already have painted the scene
        // heading bold. (A deferred path would still be unstyled here.)
        XCTAssertTrue(isBold(h.textView, at: 0),
            "screenplay scene heading must be styled live on the keystroke, not deferred")
    }

    /// The live screenplay path windows the restyle to the changed paragraph,
    /// not the whole document — same sentinel proof as the prose settle test.
    func test_screenplayLiveRestyleIsWindowedNotWholeDocument() async {
        let body = "INT. HOUSE - DAY\n\nAction line here.\n\n"
            + "EXT. STREET - NIGHT\n\nMore action at the very end of the document."
        let h = EditorIntegrationHarness(mode: ScreenplayMode(), initialText: body)

        // After init the synchronous whole-doc styling has applied. Plant a
        // sentinel attribute in the FIRST line, far from where we'll edit.
        let sentinel = NSAttributedString.Key("maugham.test.sentinel")
        h.textView.textStorage?.addAttribute(
            sentinel, value: true, range: NSRange(location: 0, length: 1))

        // Edit at the very end of the document.
        h.setCursor(to: (body as NSString).length)
        h.typeCharacter("!")

        let attrs = h.textView.textStorage?.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attrs?[sentinel],
            "live screenplay restyle must be windowed to the edit, not a "
            + "whole-document setAttributes (which wipes far attributes + snaps scroll)")
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
