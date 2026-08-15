import Foundation

/// Whether the intent strip should carry its quiet mark — the ONE decision
/// behind "intent may trail the draft" (M3-P3 §7).
///
/// **A pure function is the whole feature.** There is no stored mark, no
/// timer, no dismissal and no heuristic, because every way the mark should go
/// away is already a movement in one of the two inputs:
///
/// - a later round answering `holds` moves `lastRun`, and the verdict this
///   reads is the standing run's;
/// - the writer editing the statement moves its hash away from the snapshot
///   the drifted run checked against;
///
/// and there is nothing left over to un-set. That is what makes the mark safe
/// to draw over the prose: the writer can always clear it by doing one of the
/// two things the mark is asking them to consider.
///
/// **The identity of "the statement has not changed" is
/// `DerivedWorld.sourceHash(of:)`** — the exact-text SHA-256 that already
/// decides whether a cached reading of a statement is still that statement's.
/// Asked for rather than re-spelled: a second notion of statement identity is
/// a second thing to keep in step, and the accepted cost (a whitespace-only
/// edit clears the mark) is the same cost the cache already pays.
///
/// **What this never touches is what the model SAID.** The verdict is one of
/// two words the app chose the vocabulary for; the sentence the schema asks
/// for beside it is dropped at ingest (`DiagnosticIngest.parseIntentDrift`),
/// and the string the strip draws is a compile-time constant in
/// `IntentStrip`. ADR 0027 §1 holds through the strip's own narrow input:
/// a `Bool` cannot carry prose.
enum IntentDrift {

    /// True iff the standing run judged the draft **drifted** from an intent
    /// the writer has not touched since.
    ///
    /// Either side missing is false — a run with no snapshot checked against
    /// nothing this can compare, and a document with no intent now has nothing
    /// for the draft to trail.
    static func mayTrailDraft(lastRun: CompilerRun?, currentStatementText: String?) -> Bool {
        guard let lastRun,
              lastRun.intentDriftVerdict == DiagnosticIngest.SectionField.drifted,
              let snapshot = lastRun.intentSnapshot,
              let current = currentStatementText
        else { return false }
        return DerivedWorld.sourceHash(of: current)
            == DerivedWorld.sourceHash(of: snapshot)
    }

    /// The same decision, resolved against a project.
    ///
    /// **`ProjectStore.effectiveIntent(forDocId:)` + `statementText(of:)`, in
    /// that order** — the one piece-first/project-fallback spelling the strip
    /// and the compiler's own briefing both use, so the text compared here is
    /// byte-for-byte the text a run would snapshot. Resolving it any other way
    /// would make the hash comparison a comparison of two different readings
    /// and the mark would never clear.
    ///
    /// The WHOLE statement, not its essay half: `CompilerRun.intentSnapshot`
    /// is the whole (`CompilerEnvironment+Project`'s `intent` closure), and a
    /// hash over half of it can only ever disagree.
    ///
    /// RULING-54: an unreadable statement reads as no mark, exactly as an
    /// absent one does — the strip is the fringe-est reader there is, and the
    /// Intent pane's editor owns surfacing the refusal.
    @MainActor
    static func mayTrailDraft(
        store: ProjectStore, docId: String, lastRun: CompilerRun?
    ) -> Bool {
        guard let resolved = store.effectiveIntent(forDocId: docId) else { return false }
        return mayTrailDraft(
            lastRun: lastRun, currentStatementText: try? store.statementText(of: resolved))
    }
}
