import Foundation
import MaughamCore

/// The report's own English, in one place — the round narrative both
/// personas read. Moved out of `DiagnosticsPane` (M4 P2 Task 2) so a
/// consumer that must not depend on that view — Review's cockpit (Task 3)
/// — can read the same copy without a Review→DiagnosticsPane dependency.
/// `DiagnosticsPane` is one caller among others now, not the owner.
enum RoundNarrative {

    /// **The legible wait** (requirement 5). "Checking 14 new paragraphs…",
    /// never a bare participle: a cold first run over a long delta takes about
    /// two minutes, and a writer watching an unqualified "Checking…" for that
    /// long cannot tell a working compiler from a hung one.
    ///
    /// Total over counts a delta cannot have — `beginRun` refuses an empty one
    /// before the running state is ever set — because a function that has to be
    /// reasoned about before it can be called is one a later caller gets wrong.
    static func checkingCopy(_ counts: CompilerOrchestrator.DeltaCounts) -> String {
        guard let phrase = paragraphPhrase(counts) else { return "Checking\u{2026}" }
        return "Checking \(phrase)\u{2026}"
    }

    /// What a delta is, in the writer's English — the ONE spelling, read by the
    /// header and by the empty state, because two sentences about the same two
    /// numbers are two things that can disagree.
    static func paragraphPhrase(_ counts: CompilerOrchestrator.DeltaCounts) -> String? {
        switch (counts.new, counts.revised) {
        case (0, 0):
            return nil
        case (let new, 0):
            return "\(new) new \(new == 1 ? "paragraph" : "paragraphs")"
        case (0, let revised):
            return "\(revised) revised \(revised == 1 ? "paragraph" : "paragraphs")"
        case (let new, let revised):
            // Always plural: the sum is at least two to reach this arm.
            return "\(new) new and \(revised) revised paragraphs"
        }
    }

    // MARK: - Since last round (spec §6; the arithmetic is `SinceLastRound`)

    /// **"Since round N−1: X resolved · Y persisting · Z new"**, or `nil` when
    /// this run is not a round that can be compared.
    ///
    /// **A fourth clause joins it when the round engaged a finding the writer
    /// is holding in another pass's lane** (#42 F-H) — "· 1 also open in
    /// another lane". The three counts above are lane-local by construction
    /// (`SinceLastRound`'s decision 1) and the mint refuses a cross-lane
    /// re-raise, so that case fell between them and left the round reading
    /// three zeroes. The number is not derived here: it is `CompilerRun`'s
    /// `openInOtherLanes`, recorded by the mint at the one place fingerprints
    /// are already compared. Zero — and a record from before the field existed
    /// — appends nothing, so the sentence a writer already knows is unchanged.
    ///
    /// Pure and static on `driftNote`'s mould, and for the same reason: the
    /// sentence is the pane's, the arithmetic is not. `SinceLastRound.compute`
    /// is the ONE spelling of the three counts.
    ///
    /// **What it counts is the writer's QUEUE, not two rounds' reports** (M4
    /// P1 Task 5). Two of the three kinds a round raises are annotations now,
    /// so the sidecar no longer holds a round's findings to diff against — and
    /// diffing them was never right: the model rewords a finding every time it
    /// raises it, and a finding it simply stopped mentioning is not one the
    /// writer resolved. What the line says now is what they can check against
    /// their own screen — one settled since the last round, one still in front
    /// of them, one raised today.
    ///
    /// Silent in three cases:
    ///
    /// - the run carries no round number. A passless ⌘R is an ordinary M2 run;
    ///   there is no round for this to be *since*.
    /// - the newest record in its own lane is not the round immediately
    ///   before it. Round 1 has nothing behind it; a lane whose earlier rounds
    ///   have aged out of the ring has nothing left to compare; and — the case
    ///   this guard is really for — **a run still streaming has not filed the
    ///   round it supersedes yet**, so the newest same-lane record mid-preview
    ///   is round N−2. Without the check the pane would say "Since round 1"
    ///   over round 3's half-arrived report and then correct itself when the
    ///   turn ended. Within a lane the numbers are consecutive by construction
    ///   (`latestRound + 1`), so this costs nothing a finished round has.
    /// - the run was read with fresh eyes (Task 6). It was deliberately
    ///   briefed on no prior findings, so a difference measured against the
    ///   last round would be an artifact of the reading rather than of the
    ///   draft. Its header says what it is instead.
    ///
    /// `annotations` is the open document's queue in EVERY state — the
    /// filtering is `SinceLastRound`'s, and a caller that pre-filtered to open
    /// notes would report zero resolved forever.
    ///
    /// **This line and the run's own briefing can differ, and both are
    /// honest.** A writer who steps out of a lane and back is briefed on
    /// nothing (the previous round's prose was superseded two runs ago) while
    /// this line still counts, because the notes themselves are still in the
    /// queue carrying the round that raised them.
    static func sinceLastRoundLine(
        history: [RoundRecord], run: CompilerRun?, annotations: [Annotation]
    ) -> String? {
        guard let run, let round = run.round, run.freshEyes != true else { return nil }
        guard let previous = history.last(where: {
            $0.passId == run.passId && $0.round != nil
        }), let previousNumber = previous.round, previousNumber == round - 1 else { return nil }

        // The boundary is the record's own `at` — when the round this line is
        // "since" was filed. Anything the writer settled before then was
        // already reported, in the round they settled it in.
        let outcome = SinceLastRound.compute(
            annotations: annotations, lane: run.passId, currentRound: round,
            previousRoundAt: previous.at)
        let line = "Since round \(previousNumber): \(outcome.resolved) resolved "
            + "\u{00b7} \(outcome.persisting) persisting \u{00b7} \(outcome.new) new"
        // The pair is kept adjacent on purpose: one place to read, so a later
        // edit to either half cannot drift from the other.
        guard let elsewhere = run.openInOtherLanes, elsewhere > 0 else { return line }
        return line + (elsewhere == 1
            ? " \u{00b7} 1 also open in another lane"
            : " \u{00b7} \(elsewhere) also open in other lanes")
    }

    /// **"Fresh eyes · round N"** — what a cold read (⌘⇧R) says about itself,
    /// in the slot the since-last-round line would have taken.
    ///
    /// The two are mutually exclusive by construction and that is the point:
    /// a fresh-eyes round was briefed on no prior findings (spec §6), so it
    /// has no distance to report, and a comparison drawn over it would name a
    /// difference the run never made. `sinceLastRoundLine` refuses the same
    /// round from the other end; this is what stands in its place, so a report
    /// that leads with nothing is never how the writer learns their expensive
    /// keystroke did something different.
    ///
    /// `nil` round is a passless cold read — an ordinary M2 ⌘⇧R — which is
    /// still worth saying, just with no number to name.
    ///
    /// `== true` rather than `?? false`: the stamp is `Bool?` on the wire and
    /// an ordinary run writes no key at all, so absent and `false` must read
    /// alike.
    static func freshEyesHeader(run: CompilerRun?) -> String? {
        guard let run, run.freshEyes == true else { return nil }
        guard let round = run.round else { return "Fresh eyes" }
        return "Fresh eyes \u{00b7} round \(round)"
    }

    // MARK: - When a run does not answer

    /// **One honest sentence per failure** — no apology, no chirp. `cliNotFound`
    /// and `disabledByToggle` each name the surface that fixes them;
    /// `sessionDied` only ever reaches here for a death that was NOT the
    /// writer's own doing (`CompilerOrchestrator.finish` already routes the
    /// other three details to `.idle` through
    /// `CompilerRunFailure.isTheWritersOwnDoing`), so its detail is worth
    /// showing rather than translating away.
    ///
    /// **Hoisted out of `DiagnosticsPane` (2026-08-18, Denver's smoke) for the
    /// reason the rest of this file was hoisted: a second surface now says it.**
    /// Review's cockpit collapsed `.failed` into `.idle` and drew a timed-out
    /// round exactly like a clean one, so two Structural and Line rounds that
    /// died at the 120s budget read as "returned nothing" — the failure was
    /// legible only in Author's Diagnostics pane, which is not where the run was
    /// launched. A failure must surface where the button was pressed, and both
    /// surfaces must say it in the same words: a writer who checks the other
    /// pane to understand the first must not find a differently-worded account
    /// of the same death. `ReviewRoundCockpitTests`' one-spelling census reads
    /// every surface's file and goes red on a restatement.
    ///
    /// **`session` is what the third surface needed** (publish-department P4 Task
    /// 3). The compiler's check, the translator's round — and, when the desk's
    /// Design row runs, the designer's — all die through this one
    /// `CompilerRunFailure`, because they are one `ClaudeCLISession` machinery
    /// with three owners. So there must go on being ONE switch over it. What
    /// differs is only the noun: "The check took too long" is not what a writer
    /// asked for when they pressed Run on the Spanish row, and "couldn't be read
    /// as notes" describes nothing a translator produces. Defaulted to `.check`,
    /// so the two surfaces that came first are unchanged to the byte.
    static func failureCopy(_ failure: CompilerRunFailure,
                            session: SessionWork = .check) -> String {
        switch failure {
        case .cliNotFound:
            return "Claude Code isn't installed. Set it up, then check "
                + "Settings \u{2192} General \u{2192} Claude integration."
        case .disabledByToggle:
            return "Claude access is off in Settings \u{2014} turn on "
                + "\u{201C}Allow Claude to connect (MCP)\u{201D} to \(session.purpose)."
        case .timedOut:
            return "\(session.subject) took too long and was stopped."
        case .sessionDied(let detail):
            return "\(session.owner) ended before it could answer: \(detail)."
        case .unusableOutput:
            return "Claude's answer couldn't be read as \(session.product)."
        }
    }

    /// **Which of the three long-lived sessions died**, for the arms of
    /// `failureCopy` whose sentence names the work rather than a surface to go
    /// and fix.
    ///
    /// Four properties rather than four separate sentences per case: the SHAPE of
    /// each sentence is shared — that is the whole reason there is one switch —
    /// and what a case supplies is the nouns that shape takes.
    enum SessionWork {
        /// The compiler's check (M2). The default, so every existing caller
        /// reads exactly as it did.
        case check
        /// A translation round (publish department).
        case translation
        /// A design round (publish department, P4's desk). The third owner of
        /// the one `ClaudeCLISession` machinery, and the third set of nouns.
        case design

        /// What the writer asked for, as the subject of a sentence.
        var subject: String {
            switch self {
            case .check: return "The check"
            case .translation: return "The translation round"
            case .design: return "The design round"
            }
        }

        /// Whose session it was.
        var owner: String {
            switch self {
            case .check: return "The compiler\u{2019}s session"
            case .translation: return "The translator\u{2019}s session"
            case .design: return "The designer\u{2019}s session"
            }
        }

        /// What a readable answer would have been.
        var product: String {
            switch self {
            case .check: return "notes"
            case .translation: return "translations"
            case .design: return "a design proposal"
            }
        }

        /// What turning the toggle back on would let Claude do.
        var purpose: String {
            switch self {
            case .check: return "check your writing"
            case .translation: return "translate your writing"
            case .design: return "design your book"
            }
        }
    }

    // MARK: - Asking for one

    /// **"Run Gould's round"** — the offer, by the name of the editor who
    /// reads it (M4 P2 Task 4).
    ///
    /// One spelling because it is now said in two places a reviewer sees in
    /// the same minute: the empty queue's teaching in Review's cockpit, and
    /// the verb on every chip of the board. The personification is the whole
    /// point — a writer asks Gould for a copyedit, not "the compiler" for a
    /// "pass" — so the two must not drift into naming the same act two ways.
    ///
    /// The caller resolves the name through `ReviewPass.effectiveEditorName`,
    /// never the raw field: a customized manifest can store a preset-id pass
    /// that predates the editor field, and a pass a writer named themselves
    /// falls back to its own name ("Run Beta Read's round"), which reads as
    /// intended rather than naming a person who does not exist.
    static func runRoundTitle(editorName: String) -> String {
        "Run \(editorName)\u{2019}s round"
    }
}
