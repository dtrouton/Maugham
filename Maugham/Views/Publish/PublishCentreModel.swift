import Foundation
import Observation

/// **What the Publish persona's centre column is showing, and the rules for
/// changing it** (foundations plan 4 Task 2).
///
/// Four pieces of window-transient state used to sit on `ProjectWindow` as
/// separate `@State` values, with the rule that a design proposal and a
/// translation round clear each other written out at two closure sites. They
/// live here now, with every write the window and `PublishPreviewModifier`
/// make named as a method, so each rule has one home a test can reach without
/// a window. `ProjectWindow.publishCentre(…)` — the static decision of which
/// surface draws — still takes plain values; the window hands it this model's.
///
/// None of it is persisted. Each value's doc says why it is transient.
@MainActor @Observable
final class PublishCentreModel {

    /// **The books the centre column can draw** (stage 3b Task 5, a list since
    /// the 2026-08-12 revision gave the header a picker).
    ///
    /// A resolution rather than a `[Publication]` because the two ways of having
    /// nothing to draw are different facts — never compiled, versus a catalog
    /// that cannot be read — and the surface they share (the project at
    /// altitude) must not be what erases the difference: each carries its own
    /// notice. Written by `publishSelection(after:)`, which `PublishPreviewModifier`
    /// calls; nothing here polls.
    var preview: PublishPreviewResolution = .nothingCompiled

    /// **Which of them the writer is looking at, by `publicationID`** — `nil` is
    /// the newest. Window-transient and deliberately NOT `UIState`: Denver's
    /// ruling is that the pick is transient, so a relaunch opens on the newest
    /// book rather than on whatever proof was being checked last week. A new
    /// compile clears it too (`publishSelection(after:)`). The header picker
    /// writes it directly through a binding.
    var selectedPublicationID: String?

    /// **The design proposal the department desk's Show put in the centre**
    /// (publish-department P4 Task 5), or `nil` for the book.
    ///
    /// The whole value rather than an id: the desk read it off disk to draw its
    /// own Design row and hands up what it already has, so nothing here reads
    /// `.maugham/design/` a second time and the gate cannot disagree with the
    /// row that opened it. Cleared on any persona change (`clearDecisions`) — a
    /// gate is a place in a decision, and leaving Publish is leaving it.
    private(set) var selectedProposal: DesignProposalStore.Proposal?

    /// **The translation round the desk sent to the centre** (translation
    /// pipeline P4), beside the design proposal above. The whole value for
    /// `selectedProposal`'s reason: the desk derived it to draw the row's own
    /// line, so nothing here reads `TranslationRoundStore` a second time.
    ///
    /// Drawn by `PublishCentre.translationRound`, which outranks the gate; and
    /// cleared on a persona change exactly as the proposal is.
    private(set) var selectedRound: TranslationRound?

    // MARK: - The desk's two Shows

    /// **One centre, one selection.** The gate arm and the round arm are two
    /// readings of the same column, so each Show clears the other: leaving both
    /// set would make which one the centre draws a question about the order of
    /// two writes.
    func show(proposal: DesignProposalStore.Proposal) {
        selectedProposal = proposal
        selectedRound = nil
    }

    /// The round's Show — `show(proposal:)`'s mirror.
    func show(round: TranslationRound) {
        selectedRound = round
        selectedProposal = nil
    }

    // MARK: - Letting go

    /// The gate's Back. Deselecting is the whole of it: the arm is a pure
    /// function of this one value, so dropping it hands the column back to
    /// whatever the book's own rule answers.
    func clearProposal() { selectedProposal = nil }

    /// The round report's Back, and its reveal — the report gives way to the
    /// manuscript it points into.
    func clearRound() { selectedRound = nil }

    /// **A persona change lets both decisions go and keeps the book's pick.**
    ///
    /// The asymmetry is the point. The publication pick is a place in a
    /// *reading* — Denver's ruling keeps it across a walk out of Publish and
    /// back. The gate and the report are places in a *decision*: the writer
    /// entered by pressing Show and a persona change is them leaving. Coming
    /// back to Publish should show the book, and pressing Show again is one
    /// click.
    func clearDecisions() {
        selectedProposal = nil
        selectedRound = nil
    }

    // MARK: - A new compile resets the picker

    /// **Adopt a fresh resolution of the catalog, taking the writer's manual
    /// pick away when the NEWEST publication changed** (Denver, 2026-08-12:
    /// *"a NEW compile snaps the preview back to the newest"*).
    ///
    /// The reset is keyed on the newest book changing rather than on the
    /// refresh happening, so walking out of Publish and back keeps whatever the
    /// writer was looking at — a refresh is not news, a new book is.
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

    /// **A gate verb's answer, adopted only if it is about the round on
    /// screen** (the final-review wave).
    ///
    /// A verb answers from a `Task` that outlives the press: a promotion is file
    /// I/O over the writer's whole template set, and they are free to press Back
    /// — or Show a different round on the desk — while it runs. Writing the
    /// answer in unconditionally would then put the OLD proposal into the centre
    /// column, reopening a gate the writer closed or replacing the round they
    /// had just opened, both of them a frame after they acted.
    ///
    /// A static rather than a guard inside the method because it is a rule
    /// about which of two values wins, and the tests reach it as one.
    static func publishSelection(after updated: DesignProposalStore.Proposal,
                                 showing current: DesignProposalStore.Proposal?)
    -> DesignProposalStore.Proposal? {
        current?.id == updated.id ? updated : current
    }

    /// **The same rule for a round's verb** (translation pipeline P4 Task 3),
    /// and the same argument: "Fine" and "Adopt" answer from a `Task` that
    /// outlives the press, and the writer is free to press Back — or Show a
    /// different round, or the design gate — while it runs.
    ///
    /// A round has no `id`; it is identified by `(language, number)`, which is
    /// what `TranslationRoundStore` keys its ring on. Written out here rather
    /// than as an `Equatable` conformance on the record, because two rounds with
    /// the same number in the same language ARE the same round at two moments —
    /// which is exactly the case this write-back exists for — while
    /// `TranslationRound: Equatable` is a value comparison the store and the
    /// tests depend on.
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
