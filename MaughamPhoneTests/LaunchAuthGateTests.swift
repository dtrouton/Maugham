import XCTest
@testable import MaughamPhone

// Fixed reference instant; all clock advances are relative to this so tests are
// deterministic and never touch the real clock.
private let fixedNow = Date(timeIntervalSince1970: 1_768_435_200)  // 2026-01-15 00:00:00 UTC

// MARK: - Test double

/// Controllable `BiometricEvaluating` so the gate's state machine runs without
/// real Face ID. Records call counts and replays a configured outcome.
final class MockBiometrics: BiometricEvaluating, @unchecked Sendable {
    enum Outcome {
        case success
        case failure(Error)
    }

    // `var` so each test configures before use; @unchecked Sendable because all
    // access is single-threaded from @MainActor test bodies.
    var canEvaluateResult: Bool = true
    var evaluateOutcome: Outcome = .success

    private(set) var canEvaluateCallCount = 0
    private(set) var evaluateCallCount = 0

    func canEvaluate() -> Bool {
        canEvaluateCallCount += 1
        return canEvaluateResult
    }

    func evaluate(reason: String) async throws {
        evaluateCallCount += 1
        if case let .failure(err) = evaluateOutcome { throw err }
    }
}

struct CancelError: Error {}

// MARK: - Shared harness

// Non-private so the `final` subclasses below (which XCTest must discover) can
// inherit it. It declares no `test_` methods, so XCTest runs nothing for it.
@MainActor
class LaunchAuthGateTestCase: XCTestCase {
    var suiteName: String!
    var defaults: UserDefaults!
    var mock: MockBiometrics!
    var clock: Date!

    override func setUp() {
        super.setUp()
        suiteName = "\(type(of: self))-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        mock = MockBiometrics()
        clock = fixedNow
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        mock = nil
        clock = nil
        super.tearDown()
    }

    /// Builds a gate over the injected mock/defaults whose `now` reads the mutable
    /// `clock` ivar — advance `clock` to simulate the passage of time with no sleeps.
    func makeGate() -> LaunchAuthGate {
        LaunchAuthGate(biometrics: mock, defaults: defaults, now: { self.clock })
    }
}

// MARK: - 1. Toggle off

@MainActor
final class LaunchAuthGateToggleOffTests: LaunchAuthGateTestCase {
    func test_toggleOff_unlocksImmediately_withoutTouchingBiometrics() async {
        let gate = makeGate()
        XCTAssertFalse(gate.requireFaceId, "default must be off")

        await gate.evaluate()

        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(mock.canEvaluateCallCount, 0, "toggle off must never consult biometrics")
        XCTAssertEqual(mock.evaluateCallCount, 0, "toggle off must never run an evaluation")
    }
}

// MARK: - 2. Toggle on, successful unlock

@MainActor
final class LaunchAuthGateToggleOnUnlockTests: LaunchAuthGateTestCase {
    func test_toggleOn_canEvaluateTrue_success_endsUnlocked() async {
        mock.canEvaluateResult = true
        mock.evaluateOutcome = .success

        let gate = makeGate()
        gate.requireFaceId = true

        await gate.evaluate()

        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertTrue(gate.isUnlocked)
        XCTAssertEqual(mock.evaluateCallCount, 1, "exactly one biometric prompt on cold unlock")
    }
}

// MARK: - 3. Toggle on, user cancels

@MainActor
final class LaunchAuthGateToggleOnCancelTests: LaunchAuthGateTestCase {
    func test_toggleOn_evaluateThrows_endsLocked_retryAvailable() async {
        mock.canEvaluateResult = true
        mock.evaluateOutcome = .failure(CancelError())

        let gate = makeGate()
        gate.requireFaceId = true

        await gate.evaluate()

        XCTAssertEqual(gate.state, .locked, "cancel/failure leaves the gate locked for retry")
        XCTAssertFalse(gate.isUnlocked)
        XCTAssertEqual(mock.evaluateCallCount, 1)
    }
}

// MARK: - 4. Unavailable (no passcode) → fail open

@MainActor
final class LaunchAuthGateUnavailableTests: LaunchAuthGateTestCase {
    func test_toggleOn_cannotEvaluate_failsOpen_withoutAttemptingBiometrics() async {
        mock.canEvaluateResult = false

        let gate = makeGate()
        gate.requireFaceId = true

        await gate.evaluate()

        XCTAssertEqual(gate.state, .unavailable)
        XCTAssertTrue(gate.isUnlocked, "unavailable is treated as unlocked (fail-open)")
        XCTAssertEqual(mock.evaluateCallCount, 0, "must never attempt biometrics when unavailable")
    }
}

// MARK: - 5. Re-lock window vs. backgrounding

@MainActor
final class LaunchAuthGateRelockWindowTests: LaunchAuthGateTestCase {
    func test_withinWindow_noReprompt_thenBackgroundForcesReauth() async {
        mock.canEvaluateResult = true
        mock.evaluateOutcome = .success

        let gate = makeGate()
        gate.requireFaceId = true

        // First unlock → one real prompt.
        await gate.evaluate()
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertEqual(mock.evaluateCallCount, 1)

        // Advance < 5 min → still unlocked, NO second prompt.
        clock = fixedNow.addingTimeInterval(4 * 60)
        await gate.evaluate()
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertEqual(mock.evaluateCallCount, 1, "within the window must not re-prompt")

        // Backgrounding clears the window → next evaluate re-prompts.
        gate.onBackground()
        await gate.evaluate()
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertEqual(mock.evaluateCallCount, 2, "backgrounding forces a fresh prompt")
    }

    func test_beyondWindow_reprompts_evenWithoutBackgrounding() async {
        mock.canEvaluateResult = true
        mock.evaluateOutcome = .success

        let gate = makeGate()
        gate.requireFaceId = true

        await gate.evaluate()
        XCTAssertEqual(mock.evaluateCallCount, 1)

        // Advance > 5 min from the unlock, no backgrounding → window expired.
        clock = fixedNow.addingTimeInterval(5 * 60 + 1)
        await gate.evaluate()
        XCTAssertEqual(gate.state, .unlocked)
        XCTAssertEqual(mock.evaluateCallCount, 2, "past the 5-min window must re-prompt")
    }
}

// MARK: - 6. Persistence of the toggle

@MainActor
final class LaunchAuthGatePersistenceTests: LaunchAuthGateTestCase {
    func test_requireFaceId_persistsAcrossGateInstances() async {
        let writer = makeGate()
        writer.requireFaceId = true   // didSet writes through to defaults

        // Fresh gate over the SAME suite must read the toggle back as true.
        let reader = LaunchAuthGate(biometrics: mock, defaults: defaults, now: { self.clock })
        XCTAssertTrue(reader.requireFaceId, "toggle must survive across gate instances")
    }
}
