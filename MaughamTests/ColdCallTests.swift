// MaughamTests/ColdCallTests.swift
import XCTest
@testable import Maugham

/// `ColdCall` is the one runner every cold session shares (translation
/// pipeline spec §5): a fresh sealed process per call, one briefing in, one
/// report out, the process ended. Reader, collator, gloss and Ask-the-collator
/// are its four callers (Plans 3–4); this suite pins the runner's own
/// contract over a spy.
@MainActor
final class ColdCallTests: XCTestCase {

    /// **The spy moved out of this file in P4 Task 6** — `SpotCheckTests` drives
    /// the same runner through the same seam, and the loop-spy convention (each
    /// loop keeps its own, because each diverges as its loop grows) does not
    /// hold for the one runner four callers share. `TestSupport/ColdCallSpy
    /// .swift` is where it lives; these aliases keep this suite's own prose
    /// reading as it did.
    private typealias SpyRunner = ColdCallSpyRunner
    private typealias Factory = ColdCallSpyFactory

    private func makeColdCall() -> (ColdCall, Factory) {
        ColdCallSpyFactory.makeColdCall()
    }

    // MARK: - One call, one process

    func test_aCallSpawnsOneRunnerSendsOnceAndShutsItDown() async {
        let (coldCall, factory) = makeColdCall()

        let event = await coldCall.call(
            message: "read this", preamble: "you are blind", model: "opus")

        XCTAssertEqual(event, .resultText("{\"gloss\":\"the fog came\"}"))
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(factory.models, ["opus"], "the model is the caller's, per call")
        XCTAssertEqual(factory.made[0].sends.count, 1)
        XCTAssertEqual(factory.made[0].sends[0].message, "read this")
        XCTAssertEqual(factory.made[0].sends[0].preamble, "you are blind")
        XCTAssertEqual(factory.made[0].shutdowns, 1,
                       "the process ends with the call — warmth would cost blindness")
        XCTAssertFalse(coldCall.isRunning)
    }

    func test_twoCallsAreTwoProcesses() async {
        let (coldCall, factory) = makeColdCall()

        _ = await coldCall.call(message: "one", preamble: nil, model: "opus")
        _ = await coldCall.call(message: "two", preamble: nil, model: "opus")

        XCTAssertEqual(factory.made.count, 2, "nothing is remembered between calls")
        XCTAssertEqual(factory.made.map(\.shutdowns), [1, 1])
    }

    /// A failed turn is still a finished call: the process is ended and the
    /// failure is returned as it came.
    func test_aFailedTurnEndsTheProcessAndReturnsTheFailure() async {
        let (coldCall, factory) = makeColdCall()
        factory.configure = { $0.nextEvent = .failed(.timedOut) }

        let event = await coldCall.call(message: "x", preamble: nil, model: "opus")

        XCTAssertEqual(event, .failed(.timedOut))
        XCTAssertEqual(factory.made[0].shutdowns, 1)
        XCTAssertFalse(coldCall.isRunning)
    }

    // MARK: - Refusals

    func test_anUnconfiguredColdCallRefusesInWords() async {
        let coldCall = ColdCall()
        let event = await coldCall.call(message: "x", preamble: nil, model: "opus")
        guard case .failed(.sessionDied(let detail)) = event else {
            return XCTFail("expected a sessionDied refusal, got \(event)")
        }
        XCTAssertEqual(detail, ColdCall.notWiredDetail)
    }

    /// One call at a time, like the orchestrators: a second call arriving
    /// while the first is out is refused with the seam's own spelling, and
    /// spawns nothing.
    func test_aSecondCallWhileOneIsInFlightIsRefusedAndSpawnsNothing() async {
        let (coldCall, factory) = makeColdCall()
        factory.configure = { $0.nextEvent = nil }   // hold the turn open

        let first = Task { await coldCall.call(message: "one", preamble: nil, model: "opus") }
        _ = await pumpUntil(deadline: 2) { coldCall.isRunning }

        let second = await coldCall.call(message: "two", preamble: nil, model: "opus")
        XCTAssertEqual(second, .failed(.sessionDied(detail: CompilerRunFailure.Detail.runInFlight)))
        XCTAssertEqual(factory.made.count, 1)

        factory.made[0].release(.resultText("{}"))
        let firstEvent = await first.value
        XCTAssertEqual(firstEvent, .resultText("{}"))
    }

    // MARK: - Cancel and shutdown

    func test_cancelReachesTheLiveProcessAndTheCallReturnsCancelled() async {
        let (coldCall, factory) = makeColdCall()
        factory.configure = { $0.nextEvent = nil }

        let call = Task { await coldCall.call(message: "one", preamble: nil, model: "opus") }
        _ = await pumpUntil(deadline: 2) { coldCall.isRunning }

        coldCall.cancel()
        let event = await call.value

        XCTAssertEqual(event, .failed(.sessionDied(detail: CompilerRunFailure.Detail.cancelled)))
        XCTAssertEqual(factory.made[0].cancels, 1)
        XCTAssertEqual(factory.made[0].shutdowns, 1, "cancelled or not, the process ends")
        XCTAssertFalse(coldCall.isRunning)
    }

    /// The window closing mid-read: `shutdown()` ends the process, the call
    /// resolves as shut down, and the runner is shut down exactly once — the
    /// call's own completion must not reach a process the shutdown already
    /// ended.
    func test_shutdownMidCallEndsTheProcessOnce() async {
        let (coldCall, factory) = makeColdCall()
        factory.configure = { $0.nextEvent = nil }

        let call = Task { await coldCall.call(message: "one", preamble: nil, model: "opus") }
        _ = await pumpUntil(deadline: 2) { coldCall.isRunning }

        coldCall.shutdown()
        let event = await call.value

        XCTAssertEqual(event, .failed(.sessionDied(detail: CompilerRunFailure.Detail.sessionShutDown)))
        XCTAssertEqual(factory.made[0].shutdowns, 1)
        XCTAssertFalse(coldCall.isRunning)
    }

    func test_shutdownWithNothingInFlightIsANoOp() {
        let (coldCall, factory) = makeColdCall()
        coldCall.shutdown()
        XCTAssertTrue(factory.made.isEmpty)
    }

    /// `detach()` is `shutdown()` plus dropping the factory: the next call
    /// refuses rather than spawning against a window that is gone.
    func test_detachDropsTheFactory() async {
        let (coldCall, _) = makeColdCall()
        coldCall.detach()
        let event = await coldCall.call(message: "x", preamble: nil, model: "opus")
        XCTAssertEqual(event, .failed(.sessionDied(detail: ColdCall.notWiredDetail)))
    }

    // MARK: - Production

    /// The production factory builds a SEALED session — the whole of spec §11
    /// from this side. `ClaudeCLISession.confinement` is readable for exactly
    /// this assertion.
    func test_theProductionFactoryBuildsASealedSession() {
        let suite = "ColdCallTests-\(UUID().uuidString)"
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let factory = ColdCall.productionRunnerFactory(preferences: preferences)

        let runner = factory("haiku")
        let session = runner as? ClaudeCLISession
        XCTAssertNotNil(session, "production spawns the real CLI session")
        XCTAssertEqual(session?.confinement, .sealed)
        XCTAssertEqual(session?.runTimeout, ClaudeCLISession.translationRunTimeout,
                       "a cold read of a whole chapter gets the translation cast's budget, not the compiler's")
        session?.shutdown()
    }
}
