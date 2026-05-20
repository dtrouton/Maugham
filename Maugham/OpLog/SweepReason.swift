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
///    removes B, the resulting pending sweep covers {A, B}. The merged
///    value inherits the LATER reason's `cause` — most-recent path wins.
///
/// The `cause` field drives the `synthesisSource` stamped on the
/// `claude_archive` lifecycle ops the sweep emits. Pre-rewind, every
/// archive op was hard-coded to `.paragraphDeleted`; carrying `cause`
/// lets a rewind-triggered sweep stamp its archives with `.rewind` so
/// the history viewer can distinguish "your edit deleted this paragraph"
/// from "your time-travel undid this paragraph."
internal struct SweepReason: Equatable, Sendable {
    /// The paragraph ids whose annotations should be archived on the next
    /// sweep. Always non-empty when this value reached `_pendingSweep`
    /// (the `.userTyped` / `.externalLog` / `.useCloud` / `.rewind`
    /// factories all return nil for an empty removed set).
    let removed: Set<String>
    /// The `synthesisSource` that every `claude_archive` op produced by
    /// this sweep should carry. Defaults to `.paragraphDeleted` to
    /// preserve the pre-rewind behaviour for all four legacy callers.
    let cause: SynthesisSource

    init(removed: Set<String>, cause: SynthesisSource = .paragraphDeleted) {
        self.removed = removed
        self.cause = cause
    }

    /// Union this reason's removed set with `other`'s. The merged value
    /// inherits `other`'s `cause` so the "most recent" path stays
    /// visible in any future diagnostics and in the synthesisSource
    /// stamp on the claude_archive ops.
    func merging(_ other: SweepReason) -> SweepReason {
        SweepReason(removed: removed.union(other.removed), cause: other.cause)
    }

    /// Construct a sweep reason only if `removed` is non-empty. The
    /// callers in `Document` (`setFullText`, `deleteParagraph`,
    /// `handleExternalLogChange`, `handleExternalDiskChangeForceIngest`,
    /// `restoreToOp`) all funnel through these so the "empty set means
    /// no sweep needed" invariant is structural rather than convention.
    static func userTyped(removed: Set<String>) -> SweepReason? {
        removed.isEmpty
            ? nil
            : SweepReason(removed: removed, cause: .paragraphDeleted)
    }
    static func externalLog(removed: Set<String>) -> SweepReason? {
        removed.isEmpty
            ? nil
            : SweepReason(removed: removed, cause: .paragraphDeleted)
    }
    static func useCloud(removed: Set<String>) -> SweepReason? {
        // Pre-rewind, `sweepOrphanedAnnotations` hard-coded `.paragraphDeleted`
        // on every archive op regardless of which factory flagged the sweep —
        // including this one. Preserve that on-disk shape so existing logs
        // round-trip identically; only the new `.rewind` factory introduces
        // a different `synthesisSource` value.
        removed.isEmpty
            ? nil
            : SweepReason(removed: removed, cause: .paragraphDeleted)
    }
    /// Sweep flagged by `Document.restoreToOp` when the rewind drops
    /// paragraphs. Stamped on the resulting `claude_archive` ops via
    /// `cause = .rewind` so a future history-viewer can distinguish
    /// these from typing-driven paragraph deletions.
    static func rewind(removed: Set<String>) -> SweepReason? {
        removed.isEmpty
            ? nil
            : SweepReason(removed: removed, cause: .rewind)
    }
}
