import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// **Escape, the pulled-up thing and the window's one arbiter** (shell plan 3
/// Task 9; these were the study column's Escape tests, re-made on the consumer
/// that took its place and its priority).
///
/// Two things are pinned:
/// - **`WindowEscapeArbiter` itself** — one monitor per window, offered down a
///   declared priority order; a declining consumer passes the offer on, an
///   unclaimed Escape travels on, the window watches until its LAST consumer
///   leaves, and the shared table does not accumulate. The pulled-up thing,
///   the centre item's cover and the canvas's dim are reachable on one window,
///   and all want the key: before the arbiter each overlay owned its own
///   monitor, `NSEvent` local monitors resolve last-armed-first, and they
///   silently starved each other in an order nobody chose.
/// - **`PulledUpEscape`** — its claim lives exactly as long as the pulled-up
///   thing is on screen, it closes what is pulled up NOW (read at event time),
///   and a real Escape through `NSApp.sendEvent` reaches it before the dim.
@MainActor
final class PulledUpEscapeTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
    }

    /// A bare window. Tracked so `tearDown` empties it — a window outliving
    /// its test keeps an arbiter entry alive in the shared table.
    private func makeWindow() -> NSWindow {
        let window = TestWindow.make(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
            contentView: NSView(frame: .zero), present: .unshown)
        windows.append(window)
        return window
    }

    /// A real Escape, built the way AppKit delivers one — the window number is
    /// what lets the local monitor's own-window refusal recognise it.
    private func escapeKeyEvent(for window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                         isARepeat: false, keyCode: 53)!
    }

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The window's subject, held as the window holds it, with something
    /// pulled up, and the close the modifier hands the consumer.
    private final class Held {
        var subject = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"), beside: .lessons)
        var close: () -> Void { { self.subject = ProjectWindow.closingBeside(self.subject) } }
    }

    // MARK: - The claim lives exactly as long as the pulled-up thing is on screen

    /// **A real `NSWindow`, not `nil`.** The arbiter is keyed by window, and a
    /// suite that passed none could not catch the defect the arbiter exists
    /// to fix.
    func test_theConsumerWatchesOnlyWhileThePulledUpThingIsOnScreen() {
        let window = makeWindow()
        let escape = PulledUpEscape()
        let held = Held()

        escape.sync(isPresented: false, window: window, close: held.close)
        XCTAssertFalse(escape.isInstalled,
                       "with nothing on screen the consumer must eat no keys at all")

        escape.sync(isPresented: true, window: window, close: held.close)
        XCTAssertTrue(escape.isInstalled)
        XCTAssertTrue(WindowEscapeArbiter.arbiter(for: window).isRegistered(.pulledUp))

        escape.sync(isPresented: false, window: window, close: held.close)
        XCTAssertFalse(escape.isInstalled,
                       "a consumer left registered goes on swallowing Escape in a "
                       + "window with nothing pulled up in it")
        escape.stop()
    }

    /// **An invisible pulled-up thing holds no claim** — the study column's
    /// final-review C1, one consumer on. ⌘\ takes the chrome, ⌘⌥0 hides the
    /// column, another position covers it: in each the thing is still pulled
    /// up and nothing the writer can see would answer the key, so the claim is
    /// asked of presentation (`PulledUpEscapeModifier.claims`), never of
    /// "something is pulled up".
    func test_anInvisiblePulledUpThingHoldsNoClaimOnEscape() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        let escape = PulledUpEscape()
        let held = Held()
        var dimLifted = 0
        arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })

        let hidden: [(String, RightColumnPosition, Bool, Bool)] = [
            ("under ⌘\\", .pulledUp, true, true),
            ("with the column hidden", .pulledUp, false, false),
            ("under another position", .brief, true, false),
        ]
        for (name, position, showInspector, noChrome) in hidden {
            let presented = PulledUpEscapeModifier.claims(
                pulledUp: held.subject.beside, position: position,
                showInspector: showInspector, isNoChromeOn: noChrome)
            XCTAssertFalse(presented, name)
            escape.sync(isPresented: presented, window: window, close: held.close)
            XCTAssertFalse(arbiter.isRegistered(.pulledUp), name)
            let lifted = dimLifted
            XCTAssertTrue(arbiter.offerEscape())
            XCTAssertEqual(dimLifted, lifted + 1,
                           "\(name): one press must lift the dim — an invisible "
                           + "claim spends the first press on nothing the writer can see")
            XCTAssertEqual(held.subject.beside, .lessons,
                           "\(name): and what is pulled up is not put away behind the writer's back")
        }

        // Back on screen, the claim is back — nothing was stashed.
        escape.sync(
            isPresented: PulledUpEscapeModifier.claims(
                pulledUp: held.subject.beside, position: .pulledUp,
                showInspector: true, isNoChromeOn: false),
            window: window, close: held.close)
        XCTAssertTrue(arbiter.isRegistered(.pulledUp))

        escape.stop()
        arbiter.resign(.canvasDim)
    }

    /// The action closes what is pulled up at EVENT time — the close reads the
    /// window's subject then, so a thing pulled up after the registration is
    /// the one that goes.
    func test_theEscapeActionClosesWhateverIsPulledUpNow() {
        let window = makeWindow()
        let escape = PulledUpEscape()
        let held = Held()
        escape.sync(isPresented: true, window: window, close: held.close)

        held.subject = ClickRule.pullUp(.research("r2"), current: held.subject)
        XCTAssertTrue(escape.performEscape(), "the consumer claims the key while it is on screen")
        XCTAssertNil(held.subject.beside)
        XCTAssertEqual(held.subject.open, .item("ch-1"), "and nothing else moved")
        escape.stop()
    }

    func test_escapeIsRefusedWhenNothingIsOnScreen() {
        let window = makeWindow()
        let escape = PulledUpEscape()
        let held = Held()
        escape.sync(isPresented: false, window: window, close: held.close)

        XCTAssertFalse(escape.performEscape(),
                       "with nothing pulled up on screen the key must travel on — a "
                       + "great many responders above want Escape")
        XCTAssertEqual(held.subject.beside, .lessons)
        escape.stop()
    }

    // MARK: - Several overlays, one window, a decided order

    /// **One Escape puts the pulled-up thing away and leaves the dim alone;
    /// the next lifts the dim.**
    func test_theFirstEscapeTakesThePulledUpThingAndLeavesTheDim() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        let escape = PulledUpEscape()
        let held = Held()
        var dimLifted = 0

        escape.sync(isPresented: true, window: window, close: held.close)
        arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })

        XCTAssertTrue(arbiter.offerEscape(), "the key is used by one of the two")
        XCTAssertNil(held.subject.beside, "the first Escape must put the pulled-up thing away")
        XCTAssertEqual(dimLifted, 0,
                       "the first Escape reached the dim as well — one press resolving "
                       + "both overlays is exactly what the priority order is for")

        // The modifier's sync, as the subject's change makes it.
        escape.sync(isPresented: false, window: window, close: held.close)
        XCTAssertTrue(arbiter.offerEscape(), "the second press is the dim's")
        XCTAssertEqual(dimLifted, 1)

        escape.stop()
        arbiter.resign(.canvasDim)
    }

    /// **The same answer in both arming orders**, which is the difference between
    /// a decision and an accident. The pre-arbiter mechanism gave opposite
    /// answers to these two, and nothing said which was intended.
    func test_theOrderTheTwoArmInDoesNotDecideWhoGetsTheKey() {
        for dimFirst in [true, false] {
            let window = makeWindow()
            let arbiter = WindowEscapeArbiter.arbiter(for: window)
            let escape = PulledUpEscape()
            let held = Held()
            var dimLifted = 0

            if dimFirst {
                arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })
                escape.sync(isPresented: true, window: window, close: held.close)
            } else {
                escape.sync(isPresented: true, window: window, close: held.close)
                arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })
            }

            arbiter.offerEscape()
            XCTAssertNil(held.subject.beside, "dim armed first: \(dimFirst)")
            XCTAssertEqual(dimLifted, 0, "dim armed first: \(dimFirst)")

            escape.stop()
            arbiter.resign(.canvasDim)
        }
    }

    /// The pulled-up thing goes before the centre item's cover too: it is
    /// beside the cover, not under it, and was pulled up one gesture ago.
    func test_thePulledUpThingGoesBeforeTheCentreItemsCover() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        var order: [WindowEscapeArbiter.Consumer] = []
        var open: Set<WindowEscapeArbiter.Consumer> = [.pulledUp, .centreItem, .canvasDim]
        for consumer in [WindowEscapeArbiter.Consumer.canvasDim, .centreItem, .pulledUp] {
            arbiter.register(consumer) {
                guard open.contains(consumer) else { return false }
                open.remove(consumer)
                order.append(consumer)
                return true
            }
        }
        while arbiter.offerEscape() {}
        XCTAssertEqual(order, [.pulledUp, .centreItem, .canvasDim],
                       "three presses, in the declared order, whatever order they armed in")
        for consumer in WindowEscapeArbiter.Consumer.allCases { arbiter.resign(consumer) }
    }

    /// A consumer that declines passes the offer down rather than swallowing the
    /// key — a pulled-up thing that is not on screen must not starve the dim.
    func test_aDecliningConsumerPassesTheOfferOn() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        var dimLifted = 0
        arbiter.register(.pulledUp, claim: { false })
        arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })

        XCTAssertTrue(arbiter.offerEscape())
        XCTAssertEqual(dimLifted, 1)

        arbiter.resign(.pulledUp)
        arbiter.resign(.canvasDim)
    }

    /// An Escape nobody claims travels on. Without this the arbiter would be a
    /// key-eater wearing an arbiter's name.
    func test_anEscapeNoConsumerClaimsIsDeclined() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        arbiter.register(.pulledUp, claim: { false })
        XCTAssertFalse(arbiter.offerEscape())
        arbiter.resign(.pulledUp)
    }

    /// **The census over the priority list.** The order is the design statement;
    /// a case appended without deciding where it belongs is the defect this
    /// whole mechanism was introduced to remove, and `allCases` order is what
    /// `offerEscape` walks.
    func test_theEscapePriorityOrderIsTheDeclaredOne() {
        XCTAssertEqual(WindowEscapeArbiter.Consumer.allCases,
                       [.pulledUp, .centreItem, .canvasDim],
                       "the pulled-up thing precedes the cover and the canvas dim: "
                       + "it is something the writer pulled up one gesture ago, the "
                       + "dim is a consequence of a selection made earlier. A new "
                       + "consumer needs a position argued at the enum, not appended here.")
    }

    /// The monitor is removed only when the LAST consumer leaves — a window with
    /// one overlay still open must go on watching. Removing on the first resign
    /// would silently un-arm the dim the moment a pulled-up thing was closed.
    func test_theWindowKeepsWatchingUntilTheLastConsumerLeaves() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        arbiter.register(.pulledUp, claim: { false })
        arbiter.register(.canvasDim, claim: { false })
        XCTAssertTrue(arbiter.isArmed)

        arbiter.resign(.pulledUp)
        XCTAssertTrue(arbiter.isArmed,
                      "the dim is still up and the window stopped watching for Escape")

        arbiter.resign(.canvasDim)
        XCTAssertFalse(arbiter.isArmed,
                       "a monitor left behind goes on running for a window with no "
                       + "overlay in it")
        XCTAssertFalse(WindowEscapeArbiter.arbiter(for: window).isArmed,
                       "the table handed back an arbiter that is still armed — the "
                       + "entry outlived its last consumer")
    }

    /// The shared table must not accumulate. A leaked entry is a monitor block
    /// still running for a window nobody has an overlay in — invisible until it
    /// eats a key, which is the same failure `CanvasEscapeMonitor`'s own token
    /// discipline exists to prevent, one level up.
    func test_theArbiterTableDoesNotAccumulateArmedWindows() {
        let before = WindowEscapeArbiter.armedWindowCount
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        arbiter.register(.pulledUp, claim: { false })
        XCTAssertEqual(WindowEscapeArbiter.armedWindowCount, before + 1)

        arbiter.resign(.pulledUp)
        XCTAssertEqual(WindowEscapeArbiter.armedWindowCount, before,
                       "an armed arbiter survived its last consumer")
    }

    /// **A real Escape, through `NSApp.sendEvent`** — the delivery path, because
    /// `NSWindow.sendEvent` bypasses local monitors entirely and a test written
    /// that way cannot see this mechanism at all
    /// (`CanvasEscapeMonitor`'s own doc records the measurement).
    func test_aRealEscapeThroughTheApplicationReachesThePulledUpThingFirst() throws {
        let window = makeWindow()
        TestWindow.present(window, as: .key)
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        let escape = PulledUpEscape()
        let held = Held()
        var dimLifted = 0

        escape.sync(isPresented: true, window: window, close: held.close)
        arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)

        XCTAssertNil(held.subject.beside,
                     "a real Escape did not reach the pulled-up thing through the monitor")
        XCTAssertEqual(dimLifted, 0, "and it must not have reached the dim as well")

        escape.stop()
        arbiter.resign(.canvasDim)
    }

    // MARK: - The mount

    /// The modifier syncs on every input its claim reads, and gives the key
    /// back when it goes. It rides the window's body — the right column is
    /// behind `showInspector` and would take the registration down every time
    /// the writer hid it.
    func test_theModifierSyncsOnEveryInputTheClaimReads() throws {
        let modifier = try SourceTree.sourceOfType("PulledUpEscapeModifier", under: ["Maugham"])
        let flat = SourceScan.codeLines(of: modifier).joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        for token in [
            "Self.claims(pulledUp: subject.beside, position: position, showInspector: showInspector, isNoChromeOn: isNoChromeOn)",
            ".onChange(of: presented, initial: true) { _, _ in sync() }",
            ".onChange(of: window) { _, _ in sync() }",
            ".onDisappear { escape.stop() }",
            "subject = ProjectWindow.closingBeside(subject)",
        ] {
            XCTAssertTrue(flat.contains(token), "the mount lost \(token): \(flat)")
        }
        let window = try SourceTree.windowSource()
        let windowFlat = SourceScan.codeLines(of: window).joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(windowFlat.contains(
            ".modifier(PulledUpEscapeModifier( window: window, isNoChromeOn: isNoChromeOn, "
            + "showInspector: showInspector, position: rightColumnPosition, subject: subjectBinding))"),
            "Esc's one mount line on the window's body is gone")
    }
}
