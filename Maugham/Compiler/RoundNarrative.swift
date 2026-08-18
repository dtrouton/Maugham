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
        return "Since round \(previousNumber): \(outcome.resolved) resolved "
            + "\u{00b7} \(outcome.persisting) persisting \u{00b7} \(outcome.new) new"
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
}
