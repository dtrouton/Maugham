import Foundation
import Observation

/// **What the Publish persona's centre column is showing, and the rules for
/// changing it.** Every write the window and `PublishPreviewModifier` make
/// is a named method, so each rule — above all, that a design proposal and
/// a translation round clear each other — has one home a test can reach
/// without a window. `ProjectWindow.publishCentre(…)`, the static decision
/// of which surface draws, still takes plain values; the window hands it
/// this model's.
///
/// None of it is persisted. Each value's doc says why it is transient.
@MainActor @Observable
final class PublishCentreModel {

    /// **The books the centre column can draw.** A resolution rather than a
    /// `[Publication]` because the two ways of having nothing to draw — never
    /// compiled, versus a catalog that cannot be read — are different facts,
    /// each with its own notice. Written by `publishSelection(after:)`, which
    /// `PublishPreviewModifier` calls; nothing here polls.
    var preview: PublishPreviewResolution = .nothingCompiled

    /// **Which of them the writer is looking at, by `publicationID`** — `nil` is
    /// the newest. Window-transient and deliberately NOT `UIState`: Denver's
    /// ruling is that the pick is transient, so a relaunch opens on the newest
    /// book rather than on whatever proof was being checked last week. A new
    /// compile clears it too (`publishSelection(after:)`). The header picker
    /// writes it directly through a binding.
    var selectedPublicationID: String?

    /// **The design proposal the department desk's Show put in the centre**, or
    /// `nil` for the book. The whole value rather than an id: the desk already
    /// read it off disk, so nothing here reads `.maugham/design/` a second time
    /// and the gate cannot disagree with the row that opened it. Cleared on any
    /// persona change (`clearDecisions`) — a gate is a place in a decision.
    private(set) var selectedProposal: DesignProposalStore.Proposal?

    /// **The translation round the desk sent to the centre.** The whole value
    /// for `selectedProposal`'s reason. Drawn by `PublishCentre.translationRound`,
    /// which outranks the gate; cleared on a persona change as the proposal is.
    private(set) var selectedRound: TranslationRound?

    /// **The publish problems the desk's Show Problems put in the centre**
    /// (report foundations plan 2, Task 8) — the diagnostics themselves, as the
    /// desk's last compile reported them. The whole value for `selectedRound`'s
    /// reason; outranks the round and the gate (R-S12) and draws over a chapter
    /// as the round does. Cleared on a persona change.
    private(set) var selectedProblems: [TectonicLogParser.Diagnostic]?

    // MARK: - The desk's Shows

    /// **One centre, one selection.** The gate, round and problems arms are
    /// readings of the same column, so each Show clears the others: leaving two
    /// set would make which one the centre draws a question about the order of
    /// two writes.
    func show(proposal: DesignProposalStore.Proposal) {
        selectedProposal = proposal
        selectedRound = nil
        selectedProblems = nil
    }

    /// The round's Show — `show(proposal:)`'s mirror.
    func show(round: TranslationRound) {
        selectedRound = round
        selectedProposal = nil
        selectedProblems = nil
    }

    /// Show Problems — `show(proposal:)`'s mirror.
    func show(problems: [TectonicLogParser.Diagnostic]) {
        selectedProblems = problems
        selectedProposal = nil
        selectedRound = nil
    }

    // MARK: - Letting go

    /// The gate's Back. Deselecting is the whole of it: the arm is a pure
    /// function of this one value, so dropping it hands the column back to
    /// whatever the book's own rule answers.
    func clearProposal() { selectedProposal = nil }

    /// The round report's Back, and its reveal — the report gives way to the
    /// manuscript it points into.
    func clearRound() { selectedRound = nil }

    /// The problems list's Back, and its reveal — `clearRound()`'s mirror.
    func clearProblems() { selectedProblems = nil }

    /// **A persona change lets both decisions go and keeps the book's pick.**
    /// The asymmetry is the point: the publication pick is a place in a
    /// *reading* (Denver's ruling keeps it across a walk out of Publish), while
    /// the gate and the report are places in a *decision* the writer leaves by
    /// changing persona.
    func clearDecisions() {
        selectedProposal = nil
        selectedRound = nil
        selectedProblems = nil
    }

    // MARK: - A new compile resets the picker

    /// **Adopt a fresh resolution of the catalog, taking the writer's manual
    /// pick away when the NEWEST publication changed** (Denver, 2026-08-12:
    /// *"a NEW compile snaps the preview back to the newest"*). Keyed on the
    /// newest book changing, not on the refresh — a refresh is not news, a new
    /// book is.
    func publishSelection(after compiled: PublishPreviewResolution) {
        if compiled.publication?.publicationID
            != preview.publication?.publicationID {
            selectedPublicationID = nil
        }
        preview = compiled
    }

    // MARK: - A verb's answer

    /// The gate's write-back: a verb's refreshed proposal, adopted through
    /// `publishSelection(after:showing:)` and never straight in — a verb
    /// answers from a `Task` that outlives the press, and the writer is free to
    /// press Back or Show another round while it runs. Writes the proposal
    /// alone: an answer about a gate the writer left must not clear the round
    /// they opened since.
    func adoptVerbAnswer(_ updated: DesignProposalStore.Proposal) {
        selectedProposal = Self.publishSelection(after: updated,
                                                 showing: selectedProposal)
    }

    /// The round report's write-back, for the same reason.
    func adoptVerbAnswer(_ updated: TranslationRound) {
        selectedRound = Self.publishSelection(after: updated,
                                              showing: selectedRound)
    }

    /// **A gate verb's answer, adopted only if it is about the proposal on
    /// screen.** A verb answers from a `Task` that outlives the press, and the
    /// writer may press Back or Show a different round meanwhile; writing the
    /// answer unconditionally would reopen a gate they closed or replace the
    /// round they just opened. A static because it is a rule about which of two
    /// values wins, and the tests reach it as one.
    static func publishSelection(after updated: DesignProposalStore.Proposal,
                                 showing current: DesignProposalStore.Proposal?)
    -> DesignProposalStore.Proposal? {
        current?.id == updated.id ? updated : current
    }

    /// **The same rule for a round's verb**, by the same argument. A round has
    /// no `id`; it is identified by `(language, number)`, the key of
    /// `TranslationRoundStore`'s ring. Spelled here rather than as an
    /// `Equatable` conformance: two rounds with the same number in the same
    /// language ARE the same round at two moments, while `TranslationRound:
    /// Equatable` is a value comparison the store and the tests depend on.
    static func publishSelection(after updated: TranslationRound,
                                 showing current: TranslationRound?)
    -> TranslationRound? {
        current.map { $0.language == updated.language && $0.number == updated.number } == true
            ? updated
            : current
    }

    // MARK: - The gate's proposal goes stale where it sits

    /// **The selected proposal as the store now holds it** — or nothing, when
    /// the store no longer holds it at all.
    ///
    /// Re-read BY ID rather than re-derived from the listing: which round the
    /// writer is looking at is their own choice, and no event may move them to a
    /// different one. What an event can change is what that round IS —
    /// `.superseded` and `.rejected` draw `DesignGate.settledNote` and no verbs,
    /// which is already a pure function of the status.
    ///
    /// **An unreadable proposal clears the selection**, which is the honest
    /// answer rather than a defensive one: the record is gone or unparseable, so
    /// there is nothing for the gate to describe and the column hands itself
    /// back to the book. `load` answers `nil` for that case.
    func rereadProposal(_ load: (String) -> DesignProposalStore.Proposal?) {
        guard let id = selectedProposal?.id else { return }
        selectedProposal = load(id)
    }
}
