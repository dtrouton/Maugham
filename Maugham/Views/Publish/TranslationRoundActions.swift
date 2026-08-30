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
    /// `(round, annotationId, paragraphId, noteText, rightVerbTitle)`; the
    /// annotation id is empty when the declined note minted no query, and the
    /// directive is written all the same.
    ///
    /// **The verb's own title is the fifth argument, and it is not decoration.**
    /// A declined reader's note offers "Reader's right" and a declined
    /// DEPARTURE offers "Collator's right" (`DisagreementRow.rightVerbTitle`) —
    /// two different people to side with. Without it the closure has no way to
    /// tell them apart, and every settled thread said "Reader's right" over a
    /// collator's departure while the ruling's provenance said the same.
    var readersRight: (TranslationRound, String, String, String, String) async -> Outcome
        = { _, _, _, _, _ in .refused(TranslationRoundReport.notWired) }

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

/// **The nine verbs, wired to a window** (translation pipeline P4 Task 4).
///
/// `ProjectWindow.designGateActions`' shape one surface over: closures rather
/// than stores handed down, because `TranslationRoundReportView` reads no store
/// and reaches no disk on a body path (tripwire 4), and every one of these
/// reaches something that belongs to the window.
///
/// **Four rules hold across all nine**, and each of them is a defect this
/// surface could otherwise ship:
///
/// 1. **No new door into the writer-owned layer.** Every ruling here goes
///    through `RulingPerformer.rule`, every reply through the annotation
///    lifecycle ops, every record change through `TranslationRoundStore.update`.
///    This file chooses destinations and orders writes; it holds no markdown of
///    its own and appends nothing to a statement by hand.
/// 2. **Every capture is weak**, so a verb pressed after the window closed
///    refuses in words (`TranslationRoundReport.notWired`) rather than acting
///    through a store nobody owns any more. `projectURL` is a value and is
///    captured as one — the ledger is on disk and outlives the window that drew
///    it, which is what lets "Fine" answer `roundGone` rather than `notWired`.
/// 3. **Every path answers with a sentence** (Global Constraint 2), including
///    the ones BETWEEN two writes: where a ruling lands and the second write
///    fails, the refusal names what did land (`QueryRuling.commit`'s rule — a
///    writer told only "that didn't work" answers again and mints a second
///    ruling for a decision already made).
/// 4. **`world:` is passed only where an intent reading could be stale.**
///    `RulingPerformer`'s cache holds INTENT readings and nothing derives a
///    world from an edition brief, so every edition-side call passes `nil` and
///    only "Keep mine → every edition" passes the store.
///
/// `documentStore` is the window's own, and it is named here for the reason
/// `TranslationRoundReportHost` takes one: the annotation verbs resolve their
/// document through `withAnnotationDocument`, whose open-doc arm reads
/// `ProjectStore.documentStore` — a **weak** link the window sets to this very
/// instance. It is taken rather than assumed so the dependency is visible at
/// the call site, and it is deliberately not a second resolution path: one
/// spelling of "open doc → live `Document`, closed doc → transient load" is what
/// keeps two callers from disagreeing about which `Document` an annotation was
/// written to.
extension TranslationRoundActions {

    @MainActor
    static func production(store: ProjectStore, documentStore: DocumentStore?,
                           projectURL: URL,
                           world: DeclaredWorldStore?) -> TranslationRoundActions {
        var actions = TranslationRoundActions()

        // The ledger rewrite the three record-changing verbs share. The round
        // is a VALUE the surface has been holding, so `update` is what decides
        // whether the ring still holds it — and its `roundGone` sentence says
        // so in the writer's terms rather than failing silently.
        func record(_ round: TranslationRound) -> String? {
            do {
                try TranslationRoundStore(projectURL: projectURL).update(round)
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        // MARK: Fine

        actions.dismiss = { round, departureId in
            var updated = round
            guard let index = updated.departures.firstIndex(where: { $0.id == departureId })
            else { return .refused(TranslationRoundReport.rowGone) }
            // **Beside the translator's fact, never over it.** `outcome` holds
            // what the translator did — the rewrite, the reason they declined —
            // and Fine is offered on every row, so writing the disposition there
            // would erase a before/after or a decline reason on one click.
            updated.departures[index].dismissed = true
            if let refusal = record(updated) { return .refused(refusal) }
            return .done(updated, TranslationRoundReport.dismissedLine)
        }

        // MARK: Keep mine

        actions.keepMine = { [weak store, weak world] round, paragraphId, instruction, home in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            // The translator's-note voice, because this IS that act reached
            // from a second surface: an instruction with no words says nothing
            // to a translator, and a blank directive would be briefed to every
            // later round as though it did.
            guard !words.isEmpty else { return .refused(TranslatorsNoteCopy.emptyRefusal) }
            let (kind, scope) = TranslatorsNote.destination(home: home, docId: round.docId)
            do {
                try await RulingPerformer.rule(
                    Ruling.directiveText(paragraphId: paragraphId, words),
                    provenance: TranslationRoundReport.provenance(round: round,
                                                                  verb: "keep mine"),
                    kind: kind, forScope: scope, store: store,
                    world: home == .everyEdition ? world : nil)
            } catch {
                return .refused(error.localizedDescription)
            }
            return .done(nil, TranslationRoundReport.keptLine(home: home))
        }

        // MARK: Make it a rule

        actions.makeRule = { [weak store] round, text in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            do {
                // Unanchored on purpose: a rule made from a round is doctrine
                // for the edition, not a directive about one paragraph. An
                // empty one is refused by `RulingPerformer` in its own words.
                try await RulingPerformer.rule(
                    text,
                    provenance: TranslationRoundReport.provenance(round: round,
                                                                  verb: "make it a rule"),
                    kind: .editionBrief(round.language), forScope: .project,
                    store: store, world: nil)
            } catch {
                return .refused(error.localizedDescription)
            }
            return .done(nil, TranslationRoundReport.ruledLine(language: round.language))
        }

        // MARK: The translator was right

        actions.translatorsRight = { [weak store] round, annotationId in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            do {
                try await withAnnotationDocument(
                    store: store, projectURL: projectURL, documentId: round.docId
                ) { document in
                    try await document.rejectAnnotation(
                        id: annotationId,
                        userResponse: TranslationRoundReport.translatorsRightTitle,
                        undoManager: nil)
                }
            } catch {
                return .refused(error.localizedDescription)
            }
            // Nothing on the round changes: a declined note IS the record, and
            // a writer siding with the translator leaves it exactly as the
            // pipeline wrote it.
            return .done(nil, TranslationRoundReport.translatorsRightLine)
        }

        // MARK: The note was right

        actions.readersRight = { [weak store] round, annotationId, paragraphId, noteText, verb in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            // **The directive FIRST, then the reply** — `QueryRuling.commit`'s
            // order, for its reason: a reply posted first settles the question
            // and could then lose the doctrine to one refusal, leaving the
            // writer's decision gone and the thread closed so nothing asks
            // again.
            do {
                // The provenance names the person the author sided with, in the
                // verb's own words lowercased — "round 5, collator's right"
                // over a departure, "round 5, reader's right" over a note.
                try await RulingPerformer.rule(
                    Ruling.directiveText(paragraphId: paragraphId, noteText),
                    provenance: TranslationRoundReport.provenance(
                        round: round, verb: verb.lowercased()),
                    kind: .editionBrief(round.language), forScope: .project,
                    store: store, world: nil)
            } catch {
                return .refused(error.localizedDescription)
            }
            // The id is empty when the declined note minted no query (P3 mints
            // one only where a note had somewhere to go). The decision stands
            // all the same; there is simply no thread to post it on.
            if !annotationId.isEmpty {
                do {
                    try await withAnnotationDocument(
                        store: store, projectURL: projectURL, documentId: round.docId
                    ) { document in
                        try await document.acceptAnnotation(
                            id: annotationId, userResponse: verb, undoManager: nil)
                    }
                } catch {
                    return .refused(TranslationRoundReport.ruledButNoReply(
                        reason: error.localizedDescription))
                }
            }
            return .done(nil, TranslationRoundReport.readersRightLine)
        }

        // MARK: Glossary

        actions.adopt = { [weak store] round, index in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            guard round.glossaryProposals.indices.contains(index) else {
                return .refused(TranslationRoundReport.rowGone)
            }
            let proposal = round.glossaryProposals[index]
            guard !proposal.term.trimmingCharacters(in: .whitespaces).isEmpty,
                  !proposal.rendering.trimmingCharacters(in: .whitespaces).isEmpty
            else { return .refused(TranslationRoundReport.emptyGlossaryTerm) }
            do {
                // `Ruling.Provenance.glossary`, not the round's own line: a
                // glossary entry is read back BY SHAPE (`Ruling.glossary`) and
                // its provenance is the one word every briefing recognises it
                // by, whichever round proposed it.
                try await RulingPerformer.rule(
                    Ruling.glossaryText(term: proposal.term,
                                        rendering: proposal.rendering,
                                        note: proposal.reason),
                    provenance: Ruling.Provenance.glossary,
                    kind: .editionBrief(round.language), forScope: .project,
                    store: store, world: nil)
            } catch {
                return .refused(error.localizedDescription)
            }
            var updated = round
            updated.glossaryProposals[index].adopted = true
            if let refusal = record(updated) {
                return .refused(TranslationRoundReport.adoptedButNotRecorded(
                    term: proposal.term, reason: refusal))
            }
            return .done(updated, TranslationRoundReport.adoptedLine)
        }

        actions.skip = { round, index in
            guard round.glossaryProposals.indices.contains(index) else {
                return .refused(TranslationRoundReport.rowGone)
            }
            var updated = round
            updated.glossaryProposals[index].skipped = true
            if let refusal = record(updated) { return .refused(refusal) }
            return .done(updated, TranslationRoundReport.skippedLine)
        }

        // MARK: Answering a translator

        actions.answer = { [weak store] round, annotation, reply in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            let words = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            // Its siblings' rule: an empty reply would settle the translator's
            // question with nothing in it, and `acceptAnnotation` would take it
            // without complaint.
            guard !words.isEmpty else { return .refused(TranslationRoundReport.emptyReply) }
            do {
                try await withAnnotationDocument(
                    store: store, projectURL: projectURL, documentId: round.docId
                ) { document in
                    try await document.acceptAnnotation(
                        id: annotation.id, userResponse: words, undoManager: nil)
                }
            } catch {
                return .refused(error.localizedDescription)
            }
            return .done(nil, TranslationRoundReport.answeredLine)
        }

        actions.answerAsRuling = { [weak store] round, annotation, answer in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            do {
                // `QueryRuling` owns both records and their order; this verb is
                // a CALLER of it and never a second spelling — the queue's own
                // "Answer as ruling…" reaches the same function.
                let refusal = try await withAnnotationDocument(
                    store: store, projectURL: projectURL, documentId: round.docId
                ) { document in
                    await QueryRuling.commit(answer, answering: annotation,
                                             in: document, store: store,
                                             undoManager: nil)
                }
                if let refusal { return .refused(refusal) }
            } catch {
                return .refused(error.localizedDescription)
            }
            return .done(nil, QueryRuling.confirmation(language: round.language))
        }

        return actions
    }
}
