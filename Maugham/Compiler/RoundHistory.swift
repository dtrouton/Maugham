import Foundation
import MaughamCore

/// A round's identity, as one finding rather than one note.
///
/// **The ONE spelling of round-over-round identity.** The model rewords the
/// same finding every time it raises it, so prose cannot be the join key: a
/// comparison that read `body` would report every persisting note as one
/// resolved plus one new, and "since last round" would say nothing true. What
/// is stable is the section it came from, the writer's own clause it is
/// measured against, the paragraph it is anchored to, and — for a reader
/// report alone — the reader's own two-valued kind. A conformance strain and a
/// continuity question carry a `clauseQuote` (plus their anchor); a reader
/// report carries `(kind, category, paragraphId)` and no quote, because a
/// reader report is not measured against a clause at all.
///
/// **The category is in the identity because without it the reader's two kinds
/// collapse** (M4 P1). "The dream broke here" and "I stopped believing her" are
/// two different findings about the same paragraph, and a fingerprint of
/// `(readerReport, nil, a1b2)` makes them one — so a round raising both would
/// count as one finding, and the mint's dedupe would silently discard the
/// second. `category` is the schema's own `dream_break`/`belief`
/// (`Diagnostic.category`), never a free-form tag.
///
/// Matching is struct equality; nothing here is fuzzy. **`Equatable` is what
/// is actually used** — `RoundRecord`'s own conformance rests on it, and the
/// format census compares fingerprints directly. `Hashable` is surplus, kept
/// rather than dropped because it costs nothing and removing a conformance
/// from a stored type is churn no reader benefits from. Nothing holds a
/// `Set<RoundFingerprint>`: since Task 5 the only dedupe left is the mint's,
/// and it works in `stringValue` space (`Set<String>`), because an annotation
/// op's provenance carries the string and never the struct.
struct RoundFingerprint: Codable, Hashable, Sendable {
    /// `DiagnosticKind.rawValue`. A `String` rather than the enum because this
    /// is a stored wire shape whose whole job is to survive contracts the
    /// enum has since moved on from — an unknown section read back must
    /// compare unequal, never fail the file (ADR 0015's shape, one field wide).
    let kind: String
    let clauseQuote: String?
    let paragraphId: String?
    /// The reader section's own kind (`dream_break` / `belief`), and `nil` for
    /// every other section — a strain and a continuity question have a
    /// `clauseQuote` doing this work. Optional and appended, so a `RoundRecord`
    /// written before M4 P1 decodes with it `nil` through the synthesised
    /// `decodeIfPresent` — and a strain's category was and is `nil`, so no
    /// stored record's identity moves. (Task 5 stopped the ring carrying
    /// fingerprints at all; the tolerance is what keeps the old ones readable.)
    var category: String? = nil

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
            paragraphId: diagnostic.anchor?.paragraphId,
            // Only the reader's, and only because the reader's is the one
            // section whose entries differ in a field that is not the quote.
            category: kind == .readerReport ? diagnostic.category : nil)
    }

    /// **The identity, as one string** — the same three fields, joined so a
    /// finding can be recognised across a boundary that stores no struct.
    ///
    /// M4 P1 needs the identity where `RoundFingerprint` itself cannot go: an
    /// annotation op's provenance is flat scalars (`Op.Provenance.
    /// compilerFingerprint`), so the mint stamps this string and the dedupe
    /// compares it. **One spelling, not two** — a second derivation of "the
    /// same finding" is how two readers come to disagree about whether a
    /// question the model re-raised is the one already open in front of the
    /// writer, and that disagreement is what mints them a duplicate.
    ///
    /// **The dedupe is now the ONLY reader of this string**, and that is what
    /// makes the since-last-round count honest (Task 5): a re-raise never
    /// reaches the queue as a second note, so the queue can be counted as it
    /// stands rather than diffed against a stored record of what the last
    /// round said.
    ///
    /// Reached only through `make`, so a note with no discriminator has no
    /// string either — it mints unstamped and the dedupe cannot see it, which
    /// is the same abstention `make`'s `nil` already means for the ring.
    ///
    /// **The format is a persisted, synced contract and is pinned as one**
    /// (`RoundHistoryTests`' format census): four fields, always all four, in
    /// this order, joined by `US` (U+001F). Every field is present even when
    /// empty, so the positions cannot shift under a `nil`; `US` cannot occur in
    /// a clause quote, a paragraph id or a category, so no field can be
    /// re-spelled into another's position. `nil` and the empty string are
    /// deliberately the same string here, because neither is a discriminator —
    /// and `make` has already refused a fingerprint for anything with no
    /// discriminator at all.
    ///
    /// Changing the order, the separator or the field set changes what "the
    /// same finding" means for every annotation already stamped in a writer's
    /// op log. It is safe to have settled it here and now because M4 P1 is the
    /// first build that writes one.
    var stringValue: String {
        [kind, clauseQuote ?? "", paragraphId ?? "", category ?? ""]
            .joined(separator: "\u{1f}")
    }
}

/// One round that finished: which lane it belonged to, and **when**.
///
/// Stored in `DiagnosticsStore`'s round ring, which outlives the supersession
/// of the run record it came from — the notes of round N are gone the moment
/// round N+1 replaces them, and this is the only thing left that says the
/// round happened at all.
///
/// **What it does NOT carry, since M4 P1 Task 5, is what the round found.**
/// Two of the three kinds a round raises are annotations now, and a strain the
/// writer answered is not "resolved" merely because the next run stopped
/// saying it — so the distance between two rounds is counted off the queue
/// (`SinceLastRound`), which is the account the writer can check against their
/// own screen. A ring that also stored findings would be a second, staler
/// account of the same thing, free to disagree with the first.
///
/// What survives of that is `at`: the instant this round was filed is the
/// boundary the resolved half is measured from.
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
    /// **Legacy, and written empty.** Kept as a decoded field rather than
    /// deleted so a sidecar written before Task 5 — every writer's, on the
    /// build they are running now — still loads instead of failing whole and
    /// telling them their document was never checked. Nothing reads it; every
    /// new write carries `[]`, pinned as raw JSON by `RoundHistoryTests`.
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
    /// exactly the two things that must never disagree about which round the
    /// writer is in.
    ///
    /// It takes the run and nothing else. The run's DIAGNOSTICS used to come
    /// with it, to be fingerprinted into the ring; Task 5 retired that, so a
    /// caller has nothing left to hand over and cannot accidentally file a
    /// second account of the round's findings.
    init(run: CompilerRun) {
        self.init(runId: run.id, at: run.at, passId: run.passId, round: run.round,
                  freshEyes: run.freshEyes, fingerprints: [])
    }
}

/// **What a round changed, counted off the writer's own queue** (M4 P1 Task 5).
///
/// Pure, on `DriftDetector`'s mould — no store, no I/O, no notion of where
/// annotations come from — for the same constitutional reason (spec §7): a
/// pattern across runs is *computed from records on demand*, never accumulated
/// by a background process.
///
/// **This is the ONE spelling**, and the pane's sentence is the only thing on
/// top of it. What it replaced was a comparison of two rounds' REPORTS, and
/// that comparison could not survive M4 P1: continuity questions and reader
/// reports leave the sidecar entirely now, and a finding the model simply
/// stopped mentioning is not a finding the writer resolved. Counting the queue
/// says something a writer can check — one settled, one still in front of you,
/// one raised today — where diffing two reports said only what the model
/// happened to repeat.
///
/// **The lane is `(document, pass id)`** (decision 1): a passless run is a lane
/// of its own, never a wildcard, so a Proof round's notes take no part in a
/// Line round's count. `annotations` is the whole document's queue in every
/// state, and the filtering is here rather than at the caller precisely so the
/// three counts cannot come from three differently-filtered lists.
enum SinceLastRound {
    struct Outcome: Equatable {
        /// Raised in an earlier round of this lane, and settled since the
        /// previous round was filed — stetted, rejected, accepted or archived.
        let resolved: Int
        /// Raised in an earlier round of this lane and still open: what the
        /// writer is holding.
        let persisting: Int
        /// Minted by THIS round. A finding the model re-raised is not among
        /// them — the mint's fingerprint dedupe refuses a second copy of a
        /// note already open (`RoundFingerprint.stringValue`), so a re-raise
        /// stays exactly one note and is counted once.
        ///
        /// **Where that one note is counted depends on the lane it lives in.**
        /// A re-raise of a note open in THIS lane is `persisting` above — the
        /// note is in the queue the writer is working, and they can see it. A
        /// re-raise of one open in ANOTHER pass's lane is in none of these
        /// three counts and cannot be: this whole computation reads only its
        /// own lane (decision 1), by design. That case is carried on the run
        /// instead — `CompilerRun.openInOtherLanes`, recorded by the mint
        /// itself — and `RoundNarrative.sinceLastRoundLine` appends it to the
        /// sentence as "were already open in other lanes" (#42 F-H), past
        /// tense because it is a snapshot the mint took while these three are
        /// recomputed live. It is not derived here, and nothing here changes
        /// to accommodate it.
        let new: Int
    }

    /// - Parameters:
    ///   - annotations: the document's queue, unfiltered by status. A caller
    ///     that pre-filtered to `[.open]` would report zero resolved forever.
    ///   - passId: the lane. `nil` is the passless lane and matches only notes
    ///     stamped with no pass.
    ///   - currentRound: the round the standing run minted under.
    ///   - previousRoundAt: when the round before it was filed. **Resolved is
    ///     measured from here, not from the beginning of time**: the queue
    ///     holds every note this pass ever raised, so a count without the
    ///     boundary would re-report the same settled note in every round for as
    ///     long as the writer stayed in the pass.
    static func compute(
        annotations: [Annotation], lane passId: String?,
        currentRound: Int, previousRoundAt: Date
    ) -> Outcome {
        var resolved = 0
        var persisting = 0
        var new = 0
        for annotation in annotations {
            // A note a person wrote is not this round's account of itself, and
            // a compiler note with no round predates the stamps.
            guard annotation.isCompilerAuthored,
                  annotation.reviewPassId == passId,
                  let round = annotation.compilerRound else { continue }
            if round == currentRound {
                new += 1
            } else if round < currentRound {
                if annotation.status == .open {
                    // Including a triage-declined one: the mark sorts the
                    // queue, it settles nothing, and the note is still there.
                    persisting += 1
                } else if let settledAt = annotation.resolvedAt,
                          settledAt > previousRoundAt {
                    resolved += 1
                }
            }
        }
        return Outcome(resolved: resolved, persisting: persisting, new: new)
    }
}
