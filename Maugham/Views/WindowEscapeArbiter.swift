import AppKit

/// **One Escape monitor per window, offered to its consumers in a fixed priority
/// order.**
///
/// ### The defect this exists to remove
///
/// Escape reaches two overlays in this app by the same mechanism — a local
/// `NSEvent` monitor (`CanvasEscapeMonitor`), because the ordinary way into
/// either leaves the keyboard somewhere else. Until 2026-08-05 each owned its
/// **own instance**: `CanvasEventNSView` armed one while the board was dimmed,
/// and `AssistantColumnEscape` armed another while a reference was studied.
///
/// Both are reachable on one window, and by an ordinary route: in Plan, clicking
/// a chapter in the tree dims the board, and ⌘⌥E then clicking a pin opens the
/// assistant column. **`NSEvent` local monitors run most-recently-installed
/// first, and a `nil` return short-circuits every monitor installed before it**
/// — so whichever happened to arm LAST won Escape outright and the other never
/// saw the key at all. Which one that was depended on the writer's action order
/// (dim-then-study, or study-then-dim), not on any decision. Worse, the code
/// comments on both sides claimed the two *shared* a monitor, which is true of
/// the class and false of the instance — and instance-sharing is precisely what
/// would have made the arbitration deliberate.
///
/// ### The rule
///
/// The order in `Consumer` is the priority, highest first, and it is a design
/// statement rather than an implementation detail: **the assistant column goes
/// before the canvas dim**, because the column is something the writer opened on
/// purpose one gesture ago and the dim is a consequence of a selection they made
/// earlier. One Escape sends the studied reference back; the next lifts the dim.
/// That is the same answer in both arming orders, which is the whole point.
///
/// A consumer that declines (`claim()` returning false) passes the offer down
/// the list, and an Escape nobody claims **travels on** — a great many responders
/// above these two want that key, and `CanvasEscapeMonitor.disposition`'s three
/// refusals (not Escape, not this window, a text responder is editing) are
/// applied once, here, before any consumer is asked.
@MainActor
final class WindowEscapeArbiter {

    /// **Declaration order IS priority order**, highest first. Adding a case
    /// means deciding where in this list it belongs;
    /// `AssistantColumnTests.test_theEscapePriorityOrderIsTheDeclaredOne` is the
    /// census that stops a case being appended without that decision being made.
    enum Consumer: Int, CaseIterable, Sendable {
        /// A reference the writer promoted into the assistant column.
        case assistantColumn
        /// The planning canvas dimmed by a tree selection (§4.1, slice 3).
        case canvasDim
    }

    /// One arbiter per live window. **Keyed by identity and validated on read**:
    /// an `ObjectIdentifier` is only unique among *live* objects, so a closed
    /// window's address can be handed to a new one — hence the `===` check below
    /// rather than a bare lookup.
    private static var arbiters: [ObjectIdentifier: WindowEscapeArbiter] = [:]

    static func arbiter(for window: NSWindow) -> WindowEscapeArbiter {
        // Purge arbiters whose window has gone. Nothing else collects them: the
        // table holds the arbiter strongly and the window weakly, which is the
        // direction that cannot retain a closed window's whole view graph.
        arbiters = arbiters.filter { $0.value.window != nil }
        let key = ObjectIdentifier(window)
        if let existing = arbiters[key], existing.window === window { return existing }
        let made = WindowEscapeArbiter(window: window)
        arbiters[key] = made
        return made
    }

    /// Whether any arbiter is currently holding a monitor — the instrument a
    /// test uses to say the mechanism left nothing behind.
    static var armedWindowCount: Int {
        arbiters.values.count { $0.isArmed }
    }

    private let monitor = CanvasEscapeMonitor()
    private weak var window: NSWindow?
    private var claims: [Consumer: () -> Bool] = [:]

    private init(window: NSWindow) { self.window = window }

    var isArmed: Bool { monitor.isInstalled }

    func isRegistered(_ consumer: Consumer) -> Bool { claims[consumer] != nil }

    /// Register (or re-register) a consumer's claim. `claim` is called at EVENT
    /// time and returns whether it used the key — the same contract
    /// `CanvasEventNSView.onEscape` already had.
    func register(_ consumer: Consumer, claim: @escaping () -> Bool) {
        claims[consumer] = claim
        // Idempotent by `CanvasEscapeMonitor.install`'s own guard, so a
        // re-register does not stack a second token. The closures it captures
        // are this object's, and this object outlives every consumer, so the
        // "first install's closure is the one that sticks" hazard cannot bite:
        // both read through `self` at event time.
        monitor.install(window: { [weak self] in self?.window },
                        canvasUsesIt: { [weak self] in self?.offerEscape() ?? false })
    }

    /// Give the key back. The monitor is removed only when the LAST consumer
    /// leaves — a window with one overlay still open must go on watching.
    func resign(_ consumer: Consumer) {
        claims[consumer] = nil
        guard claims.isEmpty else { return }
        monitor.remove()
        if let window { Self.arbiters[ObjectIdentifier(window)] = nil }
    }

    /// **The arbitration**, as a function so it can be asked without an
    /// `NSEvent`: offer the key down the priority list and stop at the first
    /// consumer that uses it.
    @discardableResult
    func offerEscape() -> Bool {
        for consumer in Consumer.allCases {
            guard let claim = claims[consumer] else { continue }
            if claim() { return true }
        }
        return false
    }
}
