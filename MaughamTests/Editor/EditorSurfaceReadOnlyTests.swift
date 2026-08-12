import XCTest
import AppKit
@testable import Maugham

/// Recovery spec §4: the read-only surface refuses typing at the AppKit level
/// (no display/model divergence to reconcile — tripwires 3/6) and SIGNALS the
/// refusal so the host can surface the next rung's offer.
@MainActor
final class EditorSurfaceReadOnlyTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    func test_readOnlyTextView_refusesTyping_andSignalsIntent() {
        var refusals = 0
        let tv = MaughamTextView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        tv.isEditable = false
        tv.onTypingRefusedWhileReadOnly = { refusals += 1 }
        tv.string = "Untouchable."

        tv.keyDown(with: Self.keyEvent("a"))

        XCTAssertEqual(tv.string, "Untouchable.", "the keystroke changed nothing")
        XCTAssertEqual(refusals, 1, "…and the host heard about it")
    }

    func test_editableTextView_neverFiresTheRefusalSignal() {
        var refusals = 0
        let tv = MaughamTextView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        tv.isEditable = true
        tv.onTypingRefusedWhileReadOnly = { refusals += 1 }
        tv.keyDown(with: Self.keyEvent("a"))
        XCTAssertEqual(refusals, 0)
    }

    /// Spec §4: copying out of the partial view is half its point — read it,
    /// copy from it, confirm nothing important is missing. `isEditable = false`
    /// leaves selection alone; one well-meaning `isSelectable = false` would
    /// take the point away, and nothing else here would go red.
    func test_readOnlyTextView_staysSelectable_becauseCopyingOutIsThePoint() {
        let tv = MaughamTextView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        tv.isEditable = false
        XCTAssertTrue(tv.isSelectable)
    }

    /// A reading view must still be navigable: the refusal fires for INSERTION
    /// only, and every navigation key falls through to `super`. Before this,
    /// `keyDown` swallowed every event — arrows, page, home/end, Escape — so
    /// the one view whose whole job is being read could not be moved around in,
    /// and the banner flared at the writer for pressing ↓.
    ///
    /// **Why the caret is not measured here.** The obvious assertion — send ↓,
    /// watch `selectedRange` move — cannot work in this harness, and measuring
    /// it wrong would be worse than not measuring it. Two AppKit facts, both
    /// observed rather than assumed (2026-08-12): `NSTextView.keyDown`
    /// translates an event through its input context, and a view's
    /// `inputContext` is nil unless its window is KEY — the test host app never
    /// becomes active (`NSApp.activate` leaves `isActive == false`), so no
    /// synthesised `keyDown` is ever interpreted, in any window, editable or
    /// not. Separately, on a NON-editable text view `moveDown(_:)` is inert
    /// while `moveRight(_:)` moves the selection, so even a direct call is not
    /// the clean proxy it looks like. What is left, and what these two halves
    /// pin, is the whole of the branch: the guard consults
    /// `isTextInsertionEvent`, and `super.keyDown` sits unconditionally after
    /// it.
    func test_navigationKeysFallThroughToAppKit_andNeverFireTheRefusal() {
        var refusals = 0
        let tv = MaughamTextView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        tv.isEditable = false
        tv.onTypingRefusedWhileReadOnly = { refusals += 1 }
        tv.string = "One.\nTwo.\nThree.\n"

        tv.keyDown(with: Self.functionKeyEvent(NSDownArrowFunctionKey, keyCode: 125))
        XCTAssertEqual(refusals, 0, "↓ is navigation, not typing — no refusal")
        tv.keyDown(with: Self.functionKeyEvent(NSPageDownFunctionKey, keyCode: 121))
        tv.keyDown(with: Self.keyEvent("\u{1B}"))   // Escape.
        XCTAssertEqual(refusals, 0, "page keys and Escape are not typing either")
        XCTAssertEqual(tv.string, "One.\nTwo.\nThree.\n", "and none of them edited")

        tv.keyDown(with: Self.keyEvent("a"))
        XCTAssertEqual(refusals, 1, "a letter is still refused, and still told")
    }

    /// The discriminator itself, over the keys a writer actually presses in a
    /// view they are reading. This is the half a mounted window cannot reach.
    func test_theDiscriminatorSeparatesTypingFromEverythingElse() {
        for (key, code) in [(NSUpArrowFunctionKey, UInt16(126)),
                            (NSDownArrowFunctionKey, 125),
                            (NSLeftArrowFunctionKey, 123),
                            (NSRightArrowFunctionKey, 124),
                            (NSPageUpFunctionKey, 116),
                            (NSPageDownFunctionKey, 121),
                            (NSHomeFunctionKey, 115),
                            (NSEndFunctionKey, 119),
                            (NSF1FunctionKey, 122)] {
            XCTAssertFalse(
                MaughamTextView.isTextInsertionEvent(Self.functionKeyEvent(key, keyCode: code)),
                "a navigation/function key must reach AppKit: \(key)")
        }
        for control in ["\u{1B}", "\t", "\r", "\u{7F}"] {   // Escape, Tab, Return, ⌫
            XCTAssertFalse(MaughamTextView.isTextInsertionEvent(Self.keyEvent(control)),
                           "a control character is not a typed character")
        }
        XCTAssertFalse(MaughamTextView.isTextInsertionEvent(Self.keyEvent("s", command: true)),
                       "⌘S is a command being sent, not a word being written")
        // ⌃-chords are AppKit's emacs-style navigation — ⌃A/⌃E to the ends of
        // the line, ⌃P/⌃N up and down, ⌃K to kill. `charactersIgnoringModifiers`
        // hands them back the BARE letter, so the code-point discriminator
        // alone reads ⌃E as someone typing "e": the reading view would swallow
        // the caret move and flare the banner for a navigation key, which is
        // the exact complaint the function-key arm above exists to answer.
        for chord in ["a", "e", "p", "n", "k"] {
            XCTAssertFalse(
                MaughamTextView.isTextInsertionEvent(Self.keyEvent(chord, control: true)),
                "⌃\(chord.uppercased()) is emacs-style navigation, not typing")
        }
        for typed in ["a", "Z", " ", "é", "—", "7"] {
            XCTAssertTrue(MaughamTextView.isTextInsertionEvent(Self.keyEvent(typed)),
                          "\(typed) is someone trying to write")
        }
    }

    private static func keyEvent(
        _ char: String, command: Bool = false, control: Bool = false
    ) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if control { flags.insert(.control) }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: char, charactersIgnoringModifiers: char,
            isARepeat: false, keyCode: 0)!
    }

    /// Arrows and their kin arrive as code points in AppKit's private-use
    /// function-key block, not as characters.
    private static func functionKeyEvent(_ functionKey: Int, keyCode: UInt16) -> NSEvent {
        let char = String(UnicodeScalar(functionKey)!)
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: char, charactersIgnoringModifiers: char,
            isARepeat: false, keyCode: keyCode)!
    }
}
