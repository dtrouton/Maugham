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

    /// Recovered paragraphs NOT in the sequence the writer will actually see,
    /// in the returned file's own order. Which derivation that is depends on
    /// whether the return MOVED anything — see `report(currentOps:returnedOps:mergeHappened:)`.
    public let orphans: [Orphan]
    /// True when every returned op already exists in the current log —
    /// sync delivered the history while it was set aside.
    public let redundant: Bool

    public init(orphans: [Orphan], redundant: Bool) {
        self.orphans = orphans
        self.redundant = redundant
    }

    /// The honest aggregate of a sweep that touched several records — the
    /// History pane's Retry and `EditorHost`'s auto-return both attempt every
    /// held record for a document and then have to say ONE thing about it.
    ///
    /// Orphans concatenate in sweep order. `redundant` is true only when there
    /// was at least one report and EVERY one of them was redundant: a sweep in
    /// which anything came back carrying history the current log lacks is not
    /// a redundant sweep, and an EMPTY sweep is not redundant either (nothing
    /// was delivered, so there is nothing for sync to have already delivered).
    public static func aggregate(_ reports: [RecoveredHistoryReport]) -> RecoveredHistoryReport {
        RecoveredHistoryReport(
            orphans: reports.flatMap(\.orphans),
            redundant: !reports.isEmpty && reports.allSatisfy(\.redundant))
    }
}

/// Pure computation — no filesystem, no clock — deciding which paragraphs a
/// recovered history file carries that the sequence the writer will see does
/// not have.
public enum RecoveredHistory {
    /// The orphan accounting for one attempted return.
    ///
    /// `mergeHappened` is the load-bearing argument, and it is the caller's
    /// fact rather than this function's guess: `attemptReturn` has two
    /// outcomes, and only ONE of them moves the archive back into
    /// `.maugham/ops/`.
    ///
    /// - `true` — the file moved. The draft the writer will see derives from
    ///   `union(current, returned)`, so a returned paragraph that survives
    ///   that merge is not missing from anything.
    /// - `false` — nothing moved (sync had already refilled the destination;
    ///   the archive stays where it is). The draft the writer will see derives
    ///   from the CURRENT log alone, and the archive is not in it — so every
    ///   returned paragraph absent from `derive(current)` is an orphan, even
    ///   one that a hypothetical merge would have kept. Computing this branch
    ///   against the merge was the review's C1: an archive whose keyframe
    ///   *would* have won reported zero orphans while living in no readable
    ///   log, and the writer was told "nothing was missing".
    public static func report(
        currentOps: [Op], returnedOps: [Op], mergeHappened: Bool
    ) -> RecoveredHistoryReport {
        // The ops the writer's draft will actually derive from.
        let survivingOps = mergeHappened ? union(currentOps, returnedOps) : currentOps
        let survivingState = Deriver.deriveWithSequenceFallback(ops: survivingOps)
        let returnedState = Deriver.deriveWithSequenceFallback(ops: returnedOps)

        let survivingIds = Set(survivingState.sequence)
        let orphans = returnedState.sequence
            .filter { !survivingIds.contains($0) }
            .map {
                RecoveredHistoryReport.Orphan(
                    paragraphId: $0, text: returnedState.paragraphs[$0] ?? "")
            }

        // Unchanged by `mergeHappened`: this asks whether the CURRENT log
        // already holds every op the archive does, which is a fact about the
        // two op sets and not about what the filesystem did with them.
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
