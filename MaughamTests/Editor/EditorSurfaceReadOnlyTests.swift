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

    private static func keyEvent(_ char: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: char, charactersIgnoringModifiers: char,
            isARepeat: false, keyCode: 0)!
    }
}
