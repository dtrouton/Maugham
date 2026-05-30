import Foundation
import LocalAuthentication   // production seam only

/// Abstracts the biometric/passcode evaluation so `LaunchAuthGate`'s state
/// machine is unit-testable without real Face ID. Production wraps `LAContext`;
/// tests inject a deterministic mock. (You cannot drive `LAContext` from a unit
/// test, hence the seam.)
protocol BiometricEvaluating: Sendable {
    /// Whether device-owner auth (biometric or passcode) can be evaluated —
    /// false when no passcode is set on the device. Drives the fail-open path.
    func canEvaluate() -> Bool
    /// Run the evaluation; throws on user cancel / failure.
    func evaluate(reason: String) async throws
}

/// Production evaluator over `LAContext`. A fresh `LAContext` is created per call
/// because a context that has already succeeded caches that result and would not
/// re-prompt — we want each `evaluate()` we actually run to be a real prompt.
struct LiveBiometricEvaluator: BiometricEvaluating {
    func canEvaluate() -> Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
    }
    func evaluate(reason: String) async throws {
        try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}

/// Opt-in, per-launch Face ID gate protecting the Annotations tab (spec §3.14).
///
/// When `requireFaceId` is OFF (default), `evaluate()` resolves to `.unlocked`
/// without ever touching biometrics. When ON, the Annotations tab is gated behind
/// device-owner auth on cold launch and on foreground-from-background. Capture /
/// Read / Settings are never gated by this type — the view consults `isUnlocked`
/// only for the Annotations tab.
///
/// # Re-lock semantics
/// A 5-minute window guards *foreground* re-evaluations so tab switches don't
/// nag the writer. Backgrounding (`onBackground()`) clears the last-unlock time,
/// forcing a fresh prompt on the next `evaluate()` regardless of the window.
///
/// # Fail-open
/// If the device cannot evaluate the policy (no passcode set) the state is
/// `.unavailable`, which the view treats as unlocked — we never lock the writer
/// out of their own app over a missing passcode.
///
/// # Why not @AppStorage
/// `@AppStorage` is a SwiftUI `DynamicProperty` whose observation only activates
/// inside a `View` body and can't be redirected to a test-isolated suite. We hold
/// a plain property (so `@Observable` tracks it) and read/write `UserDefaults`
/// explicitly — same reasoning as `RecentsTracker`.
@MainActor
@Observable
final class LaunchAuthGate {

    enum State: Equatable { case unlocked, locked, evaluating, unavailable }

    private(set) var state: State = .locked

    /// Backed by `UserDefaults` (key "requireFaceIdOnLaunch"); the Settings
    /// toggle binds to this. Assigning in `init` does NOT fire `didSet` (Swift
    /// initializer rule), so loading the persisted value never writes back.
    var requireFaceId: Bool { didSet { defaults.set(requireFaceId, forKey: Keys.requireFaceId) } }

    /// For the Settings toggle's gray-disable + hint when no passcode is set.
    var canUseBiometrics: Bool { biometrics.canEvaluate() }

    /// View-facing: `.unlocked` OR `.unavailable` both mean "show content"
    /// (fail-open).
    var isUnlocked: Bool { state == .unlocked || state == .unavailable }

    // MARK: - Internals

    private var lastUnlockTime: Date?
    private let reLockAfter: TimeInterval = 5 * 60
    private let biometrics: BiometricEvaluating
    private let defaults: UserDefaults
    private let now: () -> Date

    private enum Keys { static let requireFaceId = "requireFaceIdOnLaunch" }

    // Localized prompt copy; not an identity string (tripwire 13 N/A).
    private static let reason = "Unlock your annotations"

    init(
        biometrics: BiometricEvaluating = LiveBiometricEvaluator(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.biometrics = biometrics
        self.defaults = defaults
        self.now = now
        self.requireFaceId = defaults.bool(forKey: Keys.requireFaceId)  // default false
    }

    // MARK: - State machine

    /// Resolve the gate per spec §3.14. Idempotent within the 5-minute window.
    func evaluate() async {
        // 1. Toggle off → no biometrics, ever.
        guard requireFaceId else {
            state = .unlocked
            return
        }

        // 2. Within the re-lock window of a prior unlock → stay unlocked without
        //    re-prompting (so tab switches don't nag).
        if let last = lastUnlockTime, now().timeIntervalSince(last) < reLockAfter {
            state = .unlocked
            return
        }

        // 3. Device can't evaluate (no passcode) → fail open.
        guard biometrics.canEvaluate() else {
            state = .unavailable
            return
        }

        // 4. Run the real evaluation.
        state = .evaluating
        do {
            try await biometrics.evaluate(reason: Self.reason)
            lastUnlockTime = now()
            state = .unlocked
        } catch {
            // User cancel / biometric failure → locked, retry available.
            state = .locked
        }
    }

    /// Called when the app goes to background. Clears the last-unlock time so the
    /// next `evaluate()` re-prompts — backgrounding always forces a re-auth on
    /// return, independent of the 5-minute foreground window.
    func onBackground() {
        lastUnlockTime = nil
    }
}
