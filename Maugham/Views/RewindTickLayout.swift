import Foundation
import MaughamCore
import CoreGraphics

/// Pure-function layout helper for the Rewind modal's scrubber. Extracted
/// so the density rule is unit-testable independent of SwiftUI.
internal enum RewindTickLayout {
    struct RawTick: Equatable, Sendable {
        let opId: String
        let at: Date
        let kind: OpKind
    }

    /// Apply the density rule: at most one tick per pixel, with
    /// checkpoint ticks always preserved as navigation landmarks.
    ///
    /// Spec §2.3 — the auto-decimation rule is the only adaptive
    /// behaviour in v1. Pan/zoom is a deferred carry-forward.
    static func decimate(ticks: [RawTick], width: CGFloat) -> [RawTick] {
        guard !ticks.isEmpty, width > 0 else { return ticks }
        let firstT = ticks.first!.at.timeIntervalSince1970
        let lastT = ticks.last!.at.timeIntervalSince1970
        let span = max(lastT - firstT, 0.001)

        var lastPx: CGFloat = -1
        var result: [RawTick] = []
        for tick in ticks {
            // Checkpoints always emit (with their position recorded).
            if tick.kind == .checkpoint || tick.kind == .checkpointRestore {
                result.append(tick)
                let frac = (tick.at.timeIntervalSince1970 - firstT) / span
                lastPx = CGFloat(frac) * width
                continue
            }
            let frac = (tick.at.timeIntervalSince1970 - firstT) / span
            let px = CGFloat(frac) * width
            if px - lastPx >= 1.0 {
                result.append(tick)
                lastPx = px
            }
        }
        // Guarantee first and last are always present (the iteration above
        // emits the first if it's >= 1px from lastPx=-1; the last may be
        // dropped if it sits in the same pixel as a previous emitted tick).
        if let first = ticks.first,
           !result.contains(where: { $0.opId == first.opId }) {
            result.insert(first, at: 0)
        }
        if let last = ticks.last,
           result.last?.opId != last.opId {
            result.append(last)
        }
        return result
    }
}
