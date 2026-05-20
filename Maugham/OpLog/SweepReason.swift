import Foundation

/// Why an orphan-annotation sweep is pending, plus *which* paragraph ids
/// were observed disappearing. Replaces the older `_pendingOrphanSweep: Bool`
/// flag so that:
///
/// 1. A sweep can only be flagged when there's a concrete set of removed
///    paragraphs. The old `Bool` was set "true" with no proof of removal;
///    code that flipped the flag for the wrong reason silently archived
///    every paragraph-anchored annotation whose id wasn't in `sequence`,
///    which included in-memory-only paragraphs the transient `Document`
///    didn't know about. Carrying the removed set means sweep can ask
///    "did this exact id get removed?" instead of "is this id missing?"
///
/// 2. Multiple flags merge via union. If `setFullText` removes A, and
///    before the next `flushBurstNow` runs `handleExternalLogChange`
///    removes B, the resulting pending sweep covers {A, B}.
///
/// The `case` labels are forensic only — they record the path that flagged
/// the sweep. The downstream `claude_archive` op records `synthesisSource:
/// "paragraph_deleted"` regardless of which case triggered it, so a future
/// change that wants per-case provenance can extend `appendLifecycleOp`
/// without changing the public op shape.
internal enum SweepReason: Equatable {
    case userTypedDeletion(removed: Set<String>)
    case externalLogShrink(removed: Set<String>)
    case useCloudResolution(removed: Set<String>)

    /// The paragraph ids whose annotations should be archived on the next
    /// sweep. Always non-empty by construction (see `.flag` factories).
    var removed: Set<String> {
        switch self {
        case .userTypedDeletion(let r),
             .externalLogShrink(let r),
             .useCloudResolution(let r):
            return r
        }
    }

    /// Union this reason's removed set with `other`'s. The merged value
    /// inherits `other`'s case label so the "most recent" path stays
    /// visible in any future diagnostics; both removed sets are preserved.
    func merging(_ other: SweepReason) -> SweepReason {
        let combined = removed.union(other.removed)
        switch other {
        case .userTypedDeletion:
            return .userTypedDeletion(removed: combined)
        case .externalLogShrink:
            return .externalLogShrink(removed: combined)
        case .useCloudResolution:
            return .useCloudResolution(removed: combined)
        }
    }

    /// Construct a sweep reason only if `removed` is non-empty. The four
    /// callers in `Document` (`setFullText`, `deleteParagraph`,
    /// `handleExternalLogChange`, `handleExternalDiskChangeForceIngest`)
    /// all funnel through these so the "empty set means no sweep needed"
    /// invariant is structural rather than convention.
    static func userTyped(removed: Set<String>) -> SweepReason? {
        removed.isEmpty ? nil : .userTypedDeletion(removed: removed)
    }
    static func externalLog(removed: Set<String>) -> SweepReason? {
        removed.isEmpty ? nil : .externalLogShrink(removed: removed)
    }
    static func useCloud(removed: Set<String>) -> SweepReason? {
        removed.isEmpty ? nil : .useCloudResolution(removed: removed)
    }
}
