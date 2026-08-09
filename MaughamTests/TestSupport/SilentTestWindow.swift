import AppKit

/// An `NSWindow` whose unhandled key events don't play the system alert sound.
///
/// AppKit emits the beep in `noResponderFor(_:)` — once per key event that no
/// responder claims. The mounted canvas suites decline events ON PURPOSE
/// (Escape with nothing focused, ⌫ with no selection, typing at bare canvas),
/// so on a developer's machine the suite is a beep chorus over whatever else
/// they're doing. Swallowing the no-responder path silences exactly the
/// audible side effect and nothing else: event delivery, handled/declined
/// assertions, and responder-chain routing are all upstream of this call.
///
/// Mount test windows from this class (or a subclass — `CanvasHostWindow`)
/// whenever a test synthesizes key events. The production app keeps its
/// beeps; they are real writer feedback.
class SilentTestWindow: NSWindow {
    override func noResponder(for eventSelector: Selector) {}
}
