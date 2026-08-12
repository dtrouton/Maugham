import Foundation

/// The result of reconciling a recovered (previously-unreadable, then
/// set-aside) op-log file against the current draft — Plan B's honest half.
/// A writer who quarantined an unreadable device file and later gets it
/// readable again needs to know what it carries that the merged draft, which
/// has been evolving without it, does not.
public struct RecoveredHistoryReport: Equatable, Sendable {
    public struct Orphan: Equatable, Sendable, Identifiable {
        public var id: String { paragraphId }
        public let paragraphId: String
        public let text: String

        public init(paragraphId: String, text: String) {
            self.paragraphId = paragraphId
            self.text = text
        }
    }

    /// Recovered paragraphs NOT in the merged draft's sequence, in the
    /// returned file's own order.
    public let orphans: [Orphan]
    /// True when every returned op already exists in the current log —
    /// sync delivered the history while it was set aside.
    public let redundant: Bool

    public init(orphans: [Orphan], redundant: Bool) {
        self.orphans = orphans
        self.redundant = redundant
    }
}

/// Pure computation — no filesystem, no clock — deciding which paragraphs a
/// recovered history file carries that the current merged draft has lost.
public enum RecoveredHistory {
    public static func report(currentOps: [Op], returnedOps: [Op]) -> RecoveredHistoryReport {
        let merged = union(currentOps, returnedOps)
        let mergedState = Deriver.deriveWithSequenceFallback(ops: merged)
        let returnedState = Deriver.deriveWithSequenceFallback(ops: returnedOps)

        let mergedIds = Set(mergedState.sequence)
        let orphans = returnedState.sequence
            .filter { !mergedIds.contains($0) }
            .map {
                RecoveredHistoryReport.Orphan(
                    paragraphId: $0, text: returnedState.paragraphs[$0] ?? "")
            }

        let currentIds = Set(currentOps.map(\.opId))
        let redundant = returnedOps.allSatisfy { currentIds.contains($0.opId) }

        return RecoveredHistoryReport(orphans: orphans, redundant: redundant)
    }

    /// Local opId-keyed union of the two op sets, deduped first-occurrence-
    /// wins over the SAME total order `(opId, canonicalContent)` that
    /// `Deriver.opOrder` already sorts by (and that `OpLogStore.mergeSortedDedup`
    /// documents as its own dedup order — see that function's doc comment).
    /// Reimplemented locally rather than widening `mergeSortedDedup` to
    /// `public`: this pure report computation has no business depending on
    /// the op-log store's storage-facing API, and `Deriver.opOrder` (already
    /// internal-and-shared within this module) is the one piece of that
    /// ordering worth reusing rather than re-deriving.
    private static func union(_ a: [Op], _ b: [Op]) -> [Op] {
        var seen = Set<String>()
        var result: [Op] = []
        for op in (a + b).sorted(by: Deriver.opOrder) {
            if seen.insert(op.opId).inserted {
                result.append(op)
            }
        }
        return result
    }
}
