import Foundation
import XCTest

/// The run-loop waits every mounted-view test needs, in one place.
///
/// Roughly twenty suites each carried a private copy of these three functions,
/// character-identical apart from the odd default. The copies are gone; this is
/// the core they all now call.
///
/// **Why a runloop turn AND a suspension.** SwiftUI mounts representables and
/// applies state changes on the main runloop, so nothing is observable until the
/// loop has turned — but the work under test (`createStatement`, `Document.load`,
/// `Document.close`, an op-log append) is `await`ed on the MainActor, and a test
/// that only spins `RunLoop.run(until:)` never lets those jobs start. Measured
/// while writing the statement-mount suites: with runloop turns alone the first
/// keystroke's mint did not complete inside five seconds of pumping, and landed
/// the moment the test's own `await` gave the main actor up. Every wait here
/// therefore interleaves both.
///
/// **Which one to reach for.** Prefer ``until(deadline:_:)`` — it returns as soon
/// as the thing you are waiting for is true, so a suite pays the wait's real cost
/// rather than its worst case. Reach for ``waitOut(_:)`` only when the assertion
/// that follows is a NEGATIVE one ("no second editor mounted", "no op was
/// appended"): proving an absence needs a window of wall clock, and shortening it
/// weakens the test.
@MainActor
enum RunLoopPump {

    /// How long each poll iteration turns the runloop before yielding the actor.
    /// Small enough that a satisfied condition is noticed promptly; large enough
    /// that the loop has something to service each turn.
    static let pollInterval: TimeInterval = 0.01

    /// Turn the runloop for `seconds`, with no condition.
    ///
    /// `RunLoop.run(until:)` returns as soon as it has nothing left to service, so
    /// one call is a *chance to make progress*, not a wait. Use ``waitOut(_:)``
    /// when you need the wall clock to actually elapse.
    static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Turn the runloop for at least `seconds` of wall clock, **synchronously**.
    ///
    /// The undo suites are not `async` — they drive an async body through a
    /// completion box — so they cannot reach ``waitOut(_:)``. This is the same
    /// wait in a form a synchronous test can call, and it is a genuinely
    /// different function from ``spin(_:)``: repeated short `run(mode:before:)`
    /// turns really do burn the clock, where a single `run(until:)` may return at
    /// once. Consolidating the two would have quietly deleted the wait these
    /// suites depend on.
    static func spinFor(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
        }
    }

    /// Turn the runloop until `predicate` holds or `timeout` passes,
    /// **synchronously** — the condition wait for suites that are not `async`.
    ///
    /// Like ``until(deadline:_:)`` it does not assert; the caller's own assertion
    /// reports the failure.
    static func waitUntil(_ predicate: @MainActor () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
        }
    }

    /// Turn the runloop until `condition` holds, or `deadline` seconds pass.
    ///
    /// Returns `true` if the condition was observed, `false` on timeout. It does
    /// **not** assert on timeout — the caller's own assertion is what fails, with
    /// its own message. That keeps the failure readable: you see "expected two
    /// editors, found one", not "pumpUntil timed out".
    ///
    /// `condition` is `@escaping` only because an `async` function may not pass a
    /// non-escaping closure onward across a suspension point — nothing here stores
    /// it, and it is never called after this function returns.
    @discardableResult
    static func until(deadline: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            spin(pollInterval)
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Wait out at least `seconds` of WALL CLOCK, turning the runloop and yielding
    /// the main actor throughout.
    ///
    /// For negative assertions. If you can name a condition, use
    /// ``until(deadline:_:)`` instead.
    static func waitOut(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            spin(pollInterval)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Gives a type the three waits under the names the suites already used, so the
/// consolidation was a deletion rather than a rewrite.
///
/// **A protocol extension rather than an extension on `XCTestCase`, deliberately.**
/// Members added to a *class* in an extension are treated as overridable, so a
/// subclass that still declares its own `pump(_:)` fails to build with "overriding
/// declaration requires an 'override' keyword". The canvas suites keep private
/// copies on purpose (their pumps must not be shortened — see CLAUDE.md), and
/// several are exactly that shape. Coming in through a protocol makes a local
/// declaration plain shadowing instead, which is legal and wins for its own type,
/// so those suites keep their own timings and never see this file.
protocol RunLoopPumping {}

extension XCTestCase: RunLoopPumping {}

@MainActor
extension RunLoopPumping {

    /// Turn the runloop for `seconds`. See ``RunLoopPump/spin(_:)``.
    func pump(_ seconds: TimeInterval = 0.15) {
        RunLoopPump.spin(seconds)
    }

    /// Burn `seconds` of wall clock, synchronously — for negative assertions in a
    /// non-`async` test. See ``RunLoopPump/spinFor(_:)``.
    func pumpFor(_ seconds: TimeInterval) {
        RunLoopPump.spinFor(seconds)
    }

    /// Turn the runloop until `predicate` holds, synchronously.
    /// See ``RunLoopPump/waitUntil(_:timeout:)``.
    func waitUntil(_ predicate: @MainActor () -> Bool, timeout: TimeInterval = 5) {
        RunLoopPump.waitUntil(predicate, timeout: timeout)
    }

    /// Turn the runloop until `condition` holds or `deadline` seconds pass;
    /// `true` if it held. See ``RunLoopPump/until(deadline:_:)``.
    @discardableResult
    func pumpUntil(deadline: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
        await RunLoopPump.until(deadline: deadline, condition)
    }

    /// Wait out `seconds` of wall clock — for negative assertions only.
    /// See ``RunLoopPump/waitOut(_:)``.
    func waitOut(_ seconds: TimeInterval) async {
        await RunLoopPump.waitOut(seconds)
    }
}
