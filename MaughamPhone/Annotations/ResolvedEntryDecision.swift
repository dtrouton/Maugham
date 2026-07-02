import MaughamCore

/// Pure decision for `AnnotationDetailView.rederive()`: given whether the note
/// was ALREADY resolved when the detail opened (entered from a resolved row in
/// All mode) and its freshly-derived status, decide whether this is the
/// cross-device race (collapse the actions + tell the list to reload) or just a
/// read-only review of an already-resolved note (do neither). Kept out of the
/// view so the concurrency decision is unit-testable without I/O.
enum ResolvedEntryDecision {
    /// - raceCollapse: set `resolvedElsewhere` (hide actions — Race-2 guard).
    /// - notifyList: call `onResolved()` (bump resolveTick → store.reload()).
    static func afterRederive(
        openedResolved: Bool, freshStatus: AnnotationStatus?
    ) -> (raceCollapse: Bool, notifyList: Bool) {
        // Entered from a resolved row: pure review — never collapse, never reload.
        if openedResolved { return (false, false) }
        // Entered on an open note that is STILL open: normal, nothing to do.
        if freshStatus == .open { return (false, false) }
        // Entered open, now resolved-or-vanished: the cross-device race (§5.3).
        return (true, true)
    }
}
