import Foundation
import MaughamCore

/// **What the letter's scene table is allowed to be, decided app-side**
/// (spec §3.4, editorial letter P1 Task 3).
///
/// The model is TOLD its position and never asked to infer one. Inferring is
/// exactly where a scene table goes wrong: a lyric sequence gets marked down
/// for not turning, and a screenplay's flat scene passes because the reader
/// decided this piece was "more of a mood". So the run derives the position
/// from three things the writer owns — the project's type, their intent
/// statement, and the brief of the pass they put the piece in — and
/// `CompilerPrompt.scenePositionSection` states it in one sentence.
///
/// **The `.strongDeclared` / `.strongDefault` split is the whole doctrine**
/// (spec §3.4, "A strain needs a clause the writer wrote"). Under the strong
/// form a turn-less scene is a conformance strain ONLY where the writer's own
/// words carry the clause it strains against — conformance is keyed on a
/// `clause_quote` from the intent statement, and nothing here may synthesize
/// one on their behalf. Reached any other way — a screenplay whose intent is
/// silent, a prose piece opted in by a pass brief — the turn-less scene stays
/// an observation, and the table ends with the standing *Hold every scene to a
/// turn?* offer (Task 9) that files the sentence as a ruling in the writer's
/// own words.
///
/// The raw values are a **disk format**: `Letter.scenePosition` carries
/// `rawValue` into the diagnostics sidecar, so renaming a case reads back as
/// `nil` on every letter already written (ADR 0015's shape). They are spelled
/// explicitly for that reason and pinned by `ScenePositionTests`.
enum ScenePosition: String, Codable, Equatable, Sendable {
    /// No scene table at all: the writer said this piece does not move by
    /// scenes. `Letter.scenes` is `null`, which is distinct from `[]`.
    case none = "none"
    /// Rows, but the weak form: wants / changes / turn as observation, charge
    /// always `null`, and no conflict field at all. The doctrine the default
    /// encodes is the near-consensus one — something should change — not the
    /// disputed one that it must be a conflict-driven reversal (spec §3.4).
    case weak = "weak"
    /// The strong form, and the writer's own intent carries the clause. A
    /// turn-less scene is ALSO a conformance strain against that quoted
    /// clause.
    case strongDeclared = "strong_declared"
    /// The strong form by the project's form or by a pass brief, with no
    /// clause of the writer's. A turn-less scene is an observation plus the
    /// Add-to-intent offer, never a strain.
    case strongDefault = "strong_default"

    /// **The writer's explicit opt-out**, a small closed list rather than a
    /// judgement (spec §3.4's third and fifth rows). Closed on purpose: this
    /// runs against prose the writer wrote about their own book, and a fuzzy
    /// match here silently deletes a scene table they wanted.
    static let optOutPhrases = ["not scene-driven", "lyric", "essayistic", "meander"]

    /// **The turn clause**, the same shape of closed list. A statement
    /// carrying one of these is a writer who declared that scenes turn, which
    /// is what a strain is measured against; a pass brief carrying one is a
    /// writer who chose that doctrine for the lane, which puts the piece in
    /// the strong form but declares no clause.
    ///
    /// **The bare word "conflict" is deliberately NOT here** (Denver's ruling,
    /// 2026-09-01). It appeared in spec §3.4's table, and matching it read a
    /// negation as a declaration: an intent saying *avoid conflict-driven
    /// plotting* derived the strong form, and a turn-less scene would then be
    /// raised as a conformance strain quoting that very sentence back at the
    /// writer — the app fabricating the standard it judges them by out of
    /// words that reject it. The ruling drops the word rather than adding
    /// negation detection, which is a judgement a closed-list match has no
    /// business making and would fail in the same direction on the next
    /// phrasing. A writer who wants the strong form writes one of the two
    /// phrases below, or clicks the Add-to-intent offer (Task 9), which files
    /// one in their own words. Pinned by
    /// `ScenePositionTests.test_aNegatedConflictClauseDoesNotOptIn`.
    static let turnClausePhrases = [
        "every scene must turn", "moves by dramatic turns",
    ]

    /// - Parameters:
    ///   - projectType: the project's own type. `nil` — unresolved, or a
    ///     window with no project — **reads as prose**, and so does
    ///     `.unknown` (a type written by a newer build, ADR 0015): defaulting
    ///     an unresolved type into the strong form would put an essay
    ///     collection under a doctrine its writer never chose.
    ///   - statement: the intent statement **WHOLE — essay and rulings**, not
    ///     `StatementEssay.half(of:)`. Task 9's Add-to-intent offer files
    ///     "Every scene turns." as a dated ruling under `## Rulings`, and that
    ///     is the entire point of the offer: the round after it strains
    ///     against a clause the writer can find in their own statement. Read
    ///     over the essay half alone, the clause would land where this
    ///     function never looks, the offer would return on every round
    ///     forever, and no strain would ever be raised. (The prompt's own
    ///     essay section is unaffected and still embeds the essay half alone —
    ///     the strata below it reach the run as derived clauses, and briefing
    ///     them as prose as well would declare the same thing twice.)
    ///   - passBrief: the active pass's `effectiveBrief`, as the run resolved
    ///     it. `nil` is the passless lane.
    static func derive(
        projectType: ProjectType?, statement: String?, passBrief: String?
    ) -> ScenePosition {
        let declared = (statement ?? "").lowercased()

        // **The opt-out beats everything** — a clause elsewhere in the same
        // statement, the pass's brief, and the screenplay default. The writer
        // said in their own words that this piece does not move by scenes, and
        // the position exists to honour that rather than to arbitrate it.
        if optOutPhrases.contains(where: { declared.contains($0) }) { return .none }

        // The writer's own clause, which is what makes a strain possible. Asked
        // before the brief, because it decides the split as well as the form.
        if turnClausePhrases.contains(where: { declared.contains($0) }) {
            return .strongDeclared
        }

        // Strong by the piece's FORM, or by a lane the writer put it in.
        // Neither is a sentence they wrote about this book, so neither earns a
        // strain — both land in `.strongDefault` and get the offer instead.
        let brief = (passBrief ?? "").lowercased()
        let strongWithoutAClause = projectType == .screenplay
            || turnClausePhrases.contains(where: { brief.contains($0) })
        return strongWithoutAClause ? .strongDefault : .weak
    }
}
