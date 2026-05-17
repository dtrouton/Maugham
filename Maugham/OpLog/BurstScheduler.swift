// Maugham/OpLog/BurstScheduler.swift
import Foundation

/// Closes a burst when either:
///   - no activity for `idle`, or
///   - the burst has been open for `max` since first activity.
/// Force-flush is available for document-switch / window-close / ⌘S.
@MainActor
public final class BurstScheduler {
    public let idle: Duration
    public let max: Duration
    public let onFire: () -> Void

    private var idleTimer: DispatchWorkItem?
    private var maxTimer: DispatchWorkItem?
    private var burstOpen: Bool = false

    public init(idle: Duration, max: Duration, onFire: @escaping () -> Void) {
        self.idle = idle
        self.max = max
        self.onFire = onFire
    }

    public func recordActivity() {
        idleTimer?.cancel()
        let token = DispatchWorkItem { [weak self] in
            self?.fire()
        }
        idleTimer = token
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.toSeconds(idle), execute: token)

        if !burstOpen {
            burstOpen = true
            let maxToken = DispatchWorkItem { [weak self] in
                self?.fire()
            }
            maxTimer = maxToken
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.toSeconds(max), execute: maxToken)
        }
    }

    public func forceFlush() {
        if burstOpen { fire() }
    }

    private func fire() {
        idleTimer?.cancel()
        maxTimer?.cancel()
        idleTimer = nil
        maxTimer = nil
        burstOpen = false
        onFire()
    }

    private static func toSeconds(_ d: Duration) -> Double {
        let comps = d.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
}
