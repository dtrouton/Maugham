import Foundation

/// A round's identity, as one finding rather than one note.
///
/// **The ONE spelling of round-over-round identity.** The model rewords the
/// same finding every time it raises it, so prose cannot be the join key: a
/// comparison that read `body` would report every persisting note as one
/// resolved plus one new, and "since last round" would say nothing true. What
/// is stable is the section it came from, the writer's own clause it is
/// measured against, and the paragraph it is anchored to — a conformance
/// strain and a continuity question carry a `clauseQuote` (plus their anchor);
/// a reader report carries `(kind, paragraphId)` with no quote, because a
/// reader report is not measured against a clause at all.
///
/// Matching is struct equality; nothing here is fuzzy. `Hashable` (which is
/// how it is `Equatable`) is what lets `RoundComparison` partition two rounds
/// with set arithmetic rather than a quadratic walk.
struct RoundFingerprint: Codable, Hashable, Sendable {
    /// `DiagnosticKind.rawValue`. A `String` rather than the enum because this
    /// is a stored wire shape whose whole job is to survive contracts the
    /// enum has since moved on from — an unknown section read back must
    /// compare unequal, never fail the file (ADR 0015's shape, one field wide).
    let kind: String
    let clauseQuote: String?
    let paragraphId: String?

    /// `nil` for a v1 note (`kind == nil`), which has no section and therefore
    /// no identity this contract can compare. `DiagnosticsStore.load` drops
    /// those as superseded anyway; inventing an identity for one would match it
    /// against notes written under a contract it never spoke.
    ///
    /// **Also `nil` when a note has neither an anchor nor a clause to be
    /// measured against.** Both are reachable shapes — an anchorless note is
    /// supported by design, and a reader report with no resolving ref or a
    /// continuity question with no `cites` produces one — and a fingerprint of
    /// `(kind, nil, nil)` is not an identity but a bucket: every such note in a
    /// round would collapse into a single finding, so three that persisted
    /// would read as one persisting and two resolved. An unidentifiable
    /// finding takes no part, exactly as a v1 note does.
    static func make(of diagnostic: Diagnostic) -> RoundFingerprint? {
        guard let kind = diagnostic.kind else { return nil }
        guard diagnostic.clauseQuote != nil || diagnostic.anchor != nil else { return nil }
        return RoundFingerprint(
            kind: kind.rawValue,
            clauseQuote: diagnostic.clauseQuote,
            paragraphId: diagnostic.anchor?.paragraphId)
    }
}

/// One round that finished: which lane it belonged to, and what it found.
///
/// Stored in `DiagnosticsStore`'s round ring, which outlives the supersession
/// of the run record it came from — the notes of round N are gone the moment
/// round N+1 replaces them, and their fingerprints are the only thing left to
/// measure the new round against.
///
/// It carries fingerprints and nothing else of the notes: not their prose, not
/// their ids. A ring that stored notes would be a second, stale copy of the
/// register, and the comparison does not need one.
struct RoundRecord: Codable, Equatable, Sendable {
    let runId: String
    let at: Date
    /// The comparison lane (decision 1). `nil` is the passless lane — a ⌘R
    /// with no active pass — and it is a lane of its own, never a wildcard.
    let passId: String?
    /// `nil` on a passless run: an ordinary M2 run records and supersedes
    /// normally but mints no round number.
    let round: Int?
    let freshEyes: Bool?
    let fingerprints: [RoundFingerprint]

    init(runId: String, at: Date, passId: String?, round: Int?, freshEyes: Bool?,
         fingerprints: [RoundFingerprint]) {
        self.runId = runId
        self.at = at
        self.passId = passId
        self.round = round
        self.freshEyes = freshEyes
        self.fingerprints = fingerprints
    }

    /// **One spelling of "this finished run, as a round".** Two callers, and
    /// they read the same content from opposite ends of a run:
    /// `DiagnosticsStore.replace` files the run it is superseding, and
    /// `DiagnosticsStore.standingRound` hands the run still standing to the
    /// briefing of the round about to begin. A second spelling is two ways to
    /// describe one round, and the pane's line and the model's briefing are
    /// exactly the two things that must never disagree about what the last
    /// round found.
    init(run: CompilerRun, diagnostics: [Diagnostic]) {
        self.init(runId: run.id, at: run.at, passId: run.passId, round: run.round,
                  freshEyes: run.freshEyes,
                  fingerprints: diagnostics.compactMap(RoundFingerprint.make(of:)))
    }
}

/// What changed between one round and the next, computed from records.
///
/// Pure, on `DriftDetector`'s mould — no store, no dates, no I/O — for the
/// same constitutional reason (spec §7): a pattern across runs is *computed
/// from records on demand*, never accumulated by a background process.
///
/// **A round's comparison lane is `(document, pass id)`** (decision 1). This
/// type is handed the previous round to compare against; choosing WHICH record
/// that is belongs to the caller, and the rule is "the most recent prior
/// record with the same `passId`", where a passless run is its own lane. The
/// pane and the briefing both come through here, so the two can never
/// disagree about what resolved.
enum RoundComparison {
    struct Outcome: Equatable {
        /// In the previous round, gone from this one.
        let resolved: Int
        /// Raised in both.
        let persisting: Int
        /// Raised in this round only.
        let new: Int
    }

    /// `current` is this run's accepted diagnostics; notes with no fingerprint
    /// (a v1 record) take no part.
    ///
    /// Both sides are deduped to distinct findings first: the model can name
    /// one clause from two paragraphs' worth of prose, and counting the echoes
    /// would report more new findings than the pane draws.
    static func compare(previous: RoundRecord, current: [Diagnostic]) -> Outcome {
        let before = Set(previous.fingerprints)
        let now = Set(current.compactMap(RoundFingerprint.make(of:)))
        return Outcome(
            resolved: before.subtracting(now).count,
            persisting: before.intersection(now).count,
            new: now.subtracting(before).count)
    }
}
