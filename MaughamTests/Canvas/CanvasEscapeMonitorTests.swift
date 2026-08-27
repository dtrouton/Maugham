import XCTest
import AppKit
@testable import Maugham

/// The four refusals in `CanvasEscapeMonitor.disposition`, one at a time.
///
/// **These are not the test that matters most for this fix** — that one is
/// `CanvasViewMountingEditingTests.test_escapeLeavesTheDimWithTheKeyboardSomewhereElseEntirely`,
/// which sends a real `NSEvent` through `NSApp.sendEvent(_:)` with the canvas
/// holding no keyboard at all, because a decision function proves nothing about
/// whether the mechanism is reachable. What these add is exhaustiveness on the
/// refusals, and a planted offender for each of the two that a monitor can get
/// wrong silently.
@MainActor
final class CanvasEscapeMonitorTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    private func makeWindow() -> NSWindow {
        let w = TestWindow.make(SilentTestWindow.self,
                                contentRect: CGRect(x: 0, y: 0, width: 300, height: 200))
        windows.append(w)
        return w
    }

    /// Built exactly as AppKit delivers one — `charactersIgnoringModifiers` is
    /// what the production switch reads, and `windowNumber` is what gives the
    /// event its `window`, which is what the scope check compares.
    private func key(_ characters: String, for window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: characters,
                         charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: 53)!
    }

    // MARK: - The control

    /// An Escape in our window, with nothing being typed and a canvas that wants
    /// it, is consumed. Every refusal below is a departure from this one state, so
    /// without it they could all pass against a monitor that consumed nothing.
    func test_anEscapeTheCanvasWantsIsConsumed() {
        let window = makeWindow()
        XCTAssertNil(CanvasEscapeMonitor.disposition(of: key("\u{1B}", for: window),
                                                     ourWindow: window,
                                                     canvasUsesIt: { true }),
                     "the canvas asked for the key and the monitor passed it on "
                     + "anyway, so whatever is above gets it too — in full screen "
                     + "that is NSWindow, and the writer leaves full screen")
    }

    // MARK: - Refusal 1: not Escape

    /// The monitor matches every `.keyDown` in the application, so this runs on
    /// each character the writer types anywhere. It must return them untouched.
    func test_anOrdinaryKeystrokeIsUntouched() {
        let window = makeWindow()
        for character in ["e", " ", "\u{7F}", "\r"] {
            XCTAssertNotNil(CanvasEscapeMonitor.disposition(of: key(character, for: window),
                                                            ourWindow: window,
                                                            canvasUsesIt: { true }),
                            "the monitor ate \(character.debugDescription) — it sees "
                            + "every keystroke in the app, so this is every keystroke "
                            + "the writer types")
        }
    }

    // MARK: - Refusal 2: not our window

    /// **Tripwire 21's rule, at the one place this mechanism can break it.** A
    /// local monitor is app-global; a second project window, and a sheet over this
    /// canvas, are both "not our window" and are both answered by one comparison.
    func test_anEscapeAddressedToAnotherWindowTravelsOn() {
        let ours = makeWindow()
        let theirs = makeWindow()
        XCTAssertNotNil(CanvasEscapeMonitor.disposition(of: key("\u{1B}", for: theirs),
                                                        ourWindow: ours,
                                                        canvasUsesIt: { true }),
                        "one window's dimmed board ate another window's Escape")
    }

    /// A view with no window answers for nothing — the state between construction
    /// and mounting, and the state after AppKit pulls the view out.
    func test_aCanvasWithNoWindowAnswersForNothing() {
        let window = makeWindow()
        XCTAssertNotNil(CanvasEscapeMonitor.disposition(of: key("\u{1B}", for: window),
                                                        ourWindow: nil,
                                                        canvasUsesIt: { true }),
                        "a canvas that is not in a window claimed a key anyway")
    }

    /// **The offender, planted: the scope check left out.** The assertions above
    /// are worth exactly what this shows — that they can tell the two apart.
    func test_theScopeAssertionFiresOnAnUnscopedMonitor() {
        let ours = makeWindow()
        let theirs = makeWindow()
        let unscoped = { (event: NSEvent, canvasUsesIt: () -> Bool) -> NSEvent? in
            guard event.charactersIgnoringModifiers == CanvasEventNSView.escape else {
                return event
            }
            return canvasUsesIt() ? nil : event
        }
        XCTAssertNil(unscoped(key("\u{1B}", for: theirs), { true }),
                     "the planted unscoped monitor did not exhibit the bug it is "
                     + "planted to exhibit, so the scope test above proves nothing")
    }

    // MARK: - Refusal 3: something is being typed

    /// **The rename hazard, as a predicate.** The behaviour is driven end to end
    /// against a real SwiftUI `TextField` in
    /// `CanvasViewMountingEditingTests.test_theMonitorDoesNotEatTheEscapeThatCancelsAnInlineRename`;
    /// what this adds is the full set of types the guard has to recognise, which
    /// no single hosted field can show.
    func test_everyTextResponderKeepsItsEscape() {
        let window = makeWindow()
        let cases: [(String, NSResponder)] = [
            ("the mounted scrap editor, and the find bar", NSTextView(frame: .zero)),
            ("the window's field editor, which is what an NSTextField installs",
             NSText(frame: .zero)),
            ("a text field between taking focus and getting its editor",
             NSTextField(frame: .zero)),
        ]
        for (what, responder) in cases {
            XCTAssertTrue(CanvasEscapeMonitor.isEditingText(responder),
                          "\(what) was not recognised as text, so its Escape is "
                          + "eaten by the dim and the writer cannot cancel")
        }
        XCTAssertFalse(CanvasEscapeMonitor.isEditingText(nil))
        XCTAssertFalse(CanvasEscapeMonitor.isEditingText(window),
                       "an ordinary responder was treated as text, which turns the "
                       + "guard into a refusal of every Escape and puts the bug back")
        XCTAssertFalse(CanvasEscapeMonitor.isEditingText(CanvasEventNSView(frame: .zero)),
                       "the canvas's own event view was treated as text — the one "
                       + "responder that must NOT be, since it is what holds the "
                       + "keyboard when the writer clicks the board")
    }

    /// The predicate, wired into the decision: the guard is asked, not merely
    /// present. Driven through a real window whose first responder is a real text
    /// view.
    func test_theDecisionAsksTheTextGuard() {
        let window = makeWindow()
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor), "precondition")

        XCTAssertNotNil(CanvasEscapeMonitor.disposition(of: key("\u{1B}", for: window),
                                                        ourWindow: window,
                                                        canvasUsesIt: { true }),
                        "the monitor ate an Escape while a text view held the "
                        + "keyboard — that is the rename's cancel, the find bar's "
                        + "dismiss and §4.1's ruling about the mounted scrap, all "
                        + "in one")
    }

    /// **The offender, planted: the text guard left out.**
    func test_theTextGuardAssertionFiresOnAGuardlessMonitor() {
        let window = makeWindow()
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor), "precondition")

        let guardless = { (event: NSEvent, ours: NSWindow, canvasUsesIt: () -> Bool) -> NSEvent? in
            guard event.charactersIgnoringModifiers == CanvasEventNSView.escape else {
                return event
            }
            guard event.window === ours else { return event }
            return canvasUsesIt() ? nil : event
        }
        XCTAssertNil(guardless(key("\u{1B}", for: window), window, { true }),
                     "the planted guardless monitor did not eat the text view's "
                     + "Escape, so the assertion above cannot tell a guarded "
                     + "monitor from an unguarded one")
    }

    // MARK: - Refusal 4: the canvas did not use it

    /// The canvas's own answer is `CanvasView.escapeAsksForTheWholeBoard()` and it
    /// refuses an undimmed board and an open scrap. A monitor that consumed
    /// regardless would be invisible on screen and would take Escape from
    /// everything above.
    func test_anEscapeTheCanvasDeclinedTravelsOn() {
        let window = makeWindow()
        XCTAssertNotNil(CanvasEscapeMonitor.disposition(of: key("\u{1B}", for: window),
                                                        ourWindow: window,
                                                        canvasUsesIt: { false }),
                        "the monitor claimed a key the canvas did nothing with")
    }

    // MARK: - The token

    /// Install/remove is idempotent in both directions and leaves no token behind.
    /// The pairing is invisible from outside AppKit, and a leaked monitor is a
    /// block that goes on eating keys in a window that no longer has a canvas.
    func test_installAndRemoveAreIdempotentAndLeaveNothingBehind() {
        let monitor = CanvasEscapeMonitor()
        XCTAssertFalse(monitor.isInstalled)

        monitor.install(window: { nil }, canvasUsesIt: { false })
        XCTAssertTrue(monitor.isInstalled)
        monitor.install(window: { nil }, canvasUsesIt: { false })
        XCTAssertTrue(monitor.isInstalled, "a second install must not stack a "
                      + "second monitor whose token the first one overwrote")

        monitor.remove()
        XCTAssertFalse(monitor.isInstalled)
        monitor.remove()
        XCTAssertFalse(monitor.isInstalled, "removing twice must not throw or "
                       + "re-arm")
    }
}
