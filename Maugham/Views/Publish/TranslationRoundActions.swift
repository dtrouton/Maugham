import Foundation
import MaughamCore

/// **What the author can DO about a round, as closures the window fills in**
/// (translation pipeline P4 Task 3).
///
/// `DesignGateActions`' shape one surface over, and for its reasons: the report
/// reads no store and reaches no disk on a body path (tripwire 4), every verb
/// answers with a sentence whichever way it goes (Global Constraint 2 — a click
/// that produces nothing visible is the silent no-op), and every closure carries
/// a standing refusal so an unwired surface refuses in words rather than doing
/// nothing at all.
///
/// **`Outcome.done` carries an OPTIONAL round**, which is the one thing here
/// that is not `DesignGateActions`' shape. Some of these verbs change the record
/// — "Fine" marks a departure dismissed, "Adopt" marks a glossary proposal
/// adopted — and the surface holds the round as a VALUE, so the changed record
/// has to travel back or the verb would go on being offered over work already
/// done. Others (a translator's note, a ruling, a reply) write somewhere else
/// entirely and leave the round exactly as it was; `nil` is how they say so,
/// rather than handing back a copy the window would then write in for nothing.
///
/// Production wiring is Task 4's. Nothing here reaches a store, an orchestrator
/// or an undo manager: this is the seam, and the whole of it.
struct TranslationRoundActions {

    /// `done(updated, sentence)` — the verb worked, and `updated` is the round
    /// as it now stands (or `nil` when the record did not change).
    /// `refused(sentence)` — it did not, in its own words.
    enum Outcome: Equatable {
        case done(TranslationRound?, String)
        case refused(String)
    }

    /// "Fine": the author dismisses a departure. `(round, departureId)`.
    var dismiss: (TranslationRound, String) async -> Outcome
        = { _, _ in .refused(TranslationRoundReport.notWired) }

    /// "Keep mine": a translator's note against the paragraph, in the writer's
    /// own instruction and with the home they chose.
    /// `(round, paragraphId, instruction, home)`.
    var keepMine: (TranslationRound, String, String, TranslatorsNote.Home) async -> Outcome
        = { _, _, _, _ in .refused(TranslationRoundReport.notWired) }

    /// "Make it a rule": the sentence becomes doctrine for this edition.
    /// `(round, text)`.
    var makeRule: (TranslationRound, String) async -> Outcome
        = { _, _ in .refused(TranslationRoundReport.notWired) }

    /// The author sides with the translator: the query they minted is settled.
    /// `(round, annotationId)`.
    var translatorsRight: (TranslationRound, String) async -> Outcome
        = { _, _ in .refused(TranslationRoundReport.notWired) }

    /// The author sides with whoever raised the note — the reader or the
    /// collator — and the note becomes a directive on that paragraph.
    /// `(round, annotationId, paragraphId, noteText)`; the annotation id is
    /// empty when the declined note minted no query, and the directive is
    /// written all the same.
    var readersRight: (TranslationRound, String, String, String) async -> Outcome
        = { _, _, _, _ in .refused(TranslationRoundReport.notWired) }

    /// A glossary proposal, by its index into `round.glossaryProposals`.
    var adopt: (TranslationRound, Int) async -> Outcome
        = { _, _ in .refused(TranslationRoundReport.notWired) }

    var skip: (TranslationRound, Int) async -> Outcome
        = { _, _ in .refused(TranslationRoundReport.notWired) }

    /// A plain reply on a translator's open question. `(round, annotation, text)`.
    var answer: (TranslationRound, Annotation, String) async -> Outcome
        = { _, _, _ in .refused(TranslationRoundReport.notWired) }

    /// …and the same answer filed as doctrine as well — `QueryRuling`'s two
    /// records, reached from this surface.
    var answerAsRuling: (TranslationRound, Annotation, String) async -> Outcome
        = { _, _, _ in .refused(TranslationRoundReport.notWired) }
}
