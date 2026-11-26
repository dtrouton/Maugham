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

/// **A window that draws at 1x**, whatever display the Mac has: the CI
/// runner's display is non-Retina, where SwiftUI rounds a frame to whole
/// points rather than half points, so a layout a hair wider than its column
/// shows a whole point past it there and only half a point here. A width
/// census mounts at both scales (`PulledUpFitsTheColumnTests`). Measured
/// 2026-11-26: mounted through this class, the column reproduced the runner's
/// failures to the point (maxX 241.0 against a 240pt column).
final class OneXTestWindow: SilentTestWindow {
    override var backingScaleFactor: CGFloat { 1 }
}
