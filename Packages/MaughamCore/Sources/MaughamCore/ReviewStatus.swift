import Foundation

/// The one derived review status a piece shows wherever the app draws a
/// status dot — the projection `OutlineTable`, `BinderRow`, `CorkboardGrid`
/// and `PieceRow` used to compute four separate (and slightly divergent)
/// ways from the free-string `StructureItem.status` (M3 P1 Task 3).
///
/// **No `default:`** — the plan's global constraint names this type
/// explicitly; a future case must be reasoned about at every switch site,
/// not silently swallowed.
public enum ReviewStatus: String, Sendable {
    case draft
    case revising
    case final

    /// Derives the one status from a piece's per-pass states, the project's
    /// effective pass list, and the legacy free-string `status` field.
    ///
    /// **No pass states at all** (`passStates` nil/empty, or the project has
    /// no passes to score against) falls back to the legacy string: `"final"`
    /// → `.final`, `"revising"` → `.revising`, anything else (nil, `"draft"`,
    /// garbage) → `.draft`. This is the ONLY path that reads `legacyStatus` —
    /// once a project has real pass states, the legacy string is retired
    /// (Task 4: `status` gets no writers after this milestone).
    ///
    /// **With pass states**, each pass in `passes` is either touched (a key
    /// present in `passStates`) or untouched (absent):
    /// - Any pass `.inProgress` → `.revising` (work is actively happening).
    /// - Nothing touched at all → `.draft` (equivalent to no states).
    /// - A mix of touched and untouched → `.revising` (started, not through).
    /// - Every pass touched, all `.done`/`.skipped` → `.final` — **including
    ///   all-skipped**, the spec's recorded edge: skipping every pass is a
    ///   deliberate adjudication, not an accident, and reads as finished.
    /// - Every pass touched, but at least one `.unknown` → `.revising`.
    ///   `.unknown` is a state written by a newer build that this one can't
    ///   interpret; treating it as done/skipped would silently promote a
    ///   piece to "final" on data this build can't actually read, so it
    ///   counts as touched-but-open and can NEVER complete the final case on
    ///   its own.
    public static func derived(
        passStates: [String: PassState]?,
        passes: [ReviewPass],
        legacyStatus: String?
    ) -> ReviewStatus {
        guard let passStates, !passStates.isEmpty, !passes.isEmpty else {
            switch legacyStatus {
            case "final": return .final
            case "revising": return .revising
            default: return .draft
            }
        }

        var anyInProgress = false
        var anyUntouched = false
        var anyUnknown = false
        var touchedCount = 0

        for pass in passes {
            guard let state = passStates[pass.id] else {
                anyUntouched = true
                continue
            }
            touchedCount += 1
            switch state {
            case .inProgress: anyInProgress = true
            case .done, .skipped: break
            case .unknown: anyUnknown = true
            }
        }

        if anyInProgress { return .revising }
        if touchedCount == 0 { return .draft }
        if anyUntouched { return .revising }
        if anyUnknown { return .revising }
        return .final
    }
}
