import Foundation
import MaughamCore

/// The rewind-cursor derivation, kept Mac-side because `RewindCursor` is an
/// editor/time-travel contract. The core fold (`derive(ops:)` /
/// `deriveWithSequenceFallback`) lives in MaughamCore's `Deriver`; this extension
/// only adds the "state as of a cursor" variant the `RewindWindow` needs.
extension Deriver {
    /// Derive state as it was when op `cursor` had just been applied — or the
    /// full state when `cursor == .now`.
    ///
    /// Same fold semantics as `derive(ops:)`: only manuscript-mutating op kinds
    /// contribute paragraph text; annotation creation ops are walked for
    /// sequence/timing purposes but their `.next` is not applied.
    ///
    /// When `cursor` references an op_id not present in `ops`, returns the full
    /// derivation — defensive against stale UI cursors that survived a cross-Mac
    /// merge that compacted the source op away.
    public static func derive(ops: [Op], upTo cursor: RewindCursor) -> DerivedState {
        switch cursor {
        case .now:
            return deriveWithSequenceFallback(ops: ops)
        case .atOp(let opId, _):
            // Find the inclusive index of the target op.
            guard let idx = ops.firstIndex(where: { $0.opId == opId }) else {
                return deriveWithSequenceFallback(ops: ops)
            }
            let prefix = Array(ops.prefix(through: idx))
            return deriveWithSequenceFallback(ops: prefix)
        }
    }
}
