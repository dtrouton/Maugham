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
        /// **The verb filed a ruling, and this is where it went** — read off
        /// the write (`RulingPerformer.rule`'s `FiledDestination`), never a
        /// literal (shell p4 Task 6; ADR 0037's "Not yet built"). The surface
        /// says it through `FiledUnder` from its own faces and links to the
        /// Brief it names; the sentence is the verb's own, for a surface with
        /// no filed line.
        case filed(TranslationRound?, FiledDestination, String)
        case refused(String)
    }

    /// "Fine": the author dismisses a departure. `(round, departureId)`.
    var dismiss: (TranslationRound, String) async -> Outcome
        = { _, _ in .refused(TranslationRoundReport.notWired) }

    /// "Keep mine": a translator's note against the paragraph, in the writer's
    /// own instruction and with the home they chose.
    /// `(round, paragraphId, instruction, home, settling)` — `settling` is the
    /// departure it answers, which the filing settles (controller's ruling,
    /// shell p4 Task 6 fix round: filing settles a change as Fine does); a
    /// departure already settled is refused before anything is filed.
    var keepMine: (TranslationRound, String, String, TranslatorsNote.Home, String?) async -> Outcome
        = { _, _, _, _, _ in .refused(TranslationRoundReport.notWired) }

    /// "Make it a rule": the sentence becomes doctrine for this edition.
    /// `(round, text, settling)` — `settling` as for Keep mine; nil from a
    /// disagreement row, which settles no departure.
    var makeRule: (TranslationRound, String, String?) async -> Outcome
        = { _, _, _ in .refused(TranslationRoundReport.notWired) }

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

    /// A glossary proposal, by its `identity` (term and rendering), resolved
    /// against the record as it stands at the write — never a position a
    /// surface held (shell p4 Task 6 fix round).
    var adopt: (TranslationRound, String) async -> Outcome
        = { _, _ in .refused(TranslationRoundReport.notWired) }

    var skip: (TranslationRound, String) async -> Outcome
        = { _, _ in .refused(TranslationRoundReport.notWired) }

    /// A plain reply on a translator's open question. `(round, annotation, text)`.
    var answer: (TranslationRound, Annotation, String) async -> Outcome
        = { _, _, _ in .refused(TranslationRoundReport.notWired) }

    /// …and the same answer filed as doctrine as well — `QueryRuling`'s two
    /// records, reached from this surface.
    var answerAsRuling: (TranslationRound, Annotation, String) async -> Outcome
        = { _, _, _ in .refused(TranslationRoundReport.notWired) }
}

// MARK: - What the posture lets a translation surface offer (P3c Task 8)

/// **Which of the author's verbs on a translation a surface may draw** — a pure
/// decision over two postures (controller ruling Q): the round's DOCUMENT, where
/// a disposition on a translator's query settles a note, and the edition's
/// BRIEF, where a ruling is filed. Shared by the round report and the
/// translation review pane, so the two surfaces cannot disagree about who may
/// answer a translator. Hidden, never disabled: each verb's own door
/// (`Document.PostureRefusal`, `RulingRefusal`) refuses a press that arrives
/// anyway, in words.
///
/// These are the WRITER's acts on the writer's side of the table — a reply is
/// her disposition, a ruling her statement — so both postures are the
/// author's. Only the translation's own words are the translator's
/// (`TranslationWritePipeline`), and nothing here writes one.
struct TranslationAuthorVerbs: Equatable {
    /// Reply / Translator's right — `.acceptOrReject` on the round's document.
    let answer: Bool
    /// Answer as ruling — a reply AND a ruling in the edition brief.
    let answerAsRuling: Bool
    /// Make it a rule / Adopt — a ruling in the edition brief.
    let rule: Bool
    /// Keep mine — a translator's note, filed either in the piece's own intent
    /// (every edition) or in the edition's brief (`TranslatorsNote.destination`),
    /// so it is offered where EITHER home may be written (controller ruling
    /// AF). The sheet opens on a home that may (`keepMineHome`).
    let keepMine: Bool
    /// Where Keep mine's sheet opens: the edition's brief where a ruling may be
    /// filed there, else the piece's intent.
    let keepMineOpensOnTheEdition: Bool
    /// Whether Keep mine's OTHER home — the piece's own intent, *Every
    /// edition* — may be written (P3c plan 2 Task 8). Held apart from
    /// `keepMine` so the sheet offers only the homes that may be written
    /// (`keepMineHomes`), rather than both with a door refusing one in words.
    let keepMineOnEveryEdition: Bool
    /// Reader's (or Collator's) right: a ruling, and — where the note minted a
    /// query — the reply that settles it. Decided per row by `sideWithTheNote`.
    private let replies: Bool

    /// The P1 surface — every verb. For an unwired surface and a host with no
    /// window's door behind it.
    static let unrestricted = TranslationAuthorVerbs(
        answer: true, answerAsRuling: true, rule: true, keepMine: true,
        keepMineOpensOnTheEdition: true, keepMineOnEveryEdition: true, replies: true)

    /// No verb — a host with no window's door behind it (fails closed;
    /// whole-branch fix wave, Minor 2).
    static let none = TranslationAuthorVerbs(
        answer: false, answerAsRuling: false, rule: false, keepMine: false,
        keepMineOpensOnTheEdition: false, keepMineOnEveryEdition: false, replies: false)

    /// `pieceIntent` is the posture of the round's piece's own intent
    /// statement — Keep mine's other home. Nil (a host that did not say)
    /// offers Keep mine only where the edition's brief may be written: the
    /// narrower answer, never the wider.
    static func decide(
        document: Posture, editionBrief: Posture, pieceIntent: Posture? = nil
    ) -> TranslationAuthorVerbs {
        let answer = document.allows(.acceptOrReject)
        let rule = editionBrief.allows(.editStatement)
        let intent = pieceIntent?.allows(.editStatement) ?? false
        return TranslationAuthorVerbs(
            answer: answer, answerAsRuling: answer && rule, rule: rule,
            keepMine: rule || intent, keepMineOpensOnTheEdition: rule,
            keepMineOnEveryEdition: intent, replies: answer)
    }

    /// Keep mine's opening home for `language` (see `keepMineOpensOnTheEdition`).
    func keepMineHome(language: String) -> TranslatorsNote.Home {
        keepMineOpensOnTheEdition ? .edition(language) : .everyEdition
    }

    /// **The homes Keep mine's sheet offers for `language`** — only the ones
    /// that may be written (P3c plan 2 Task 8). It used to offer both whenever
    /// either could be, opening on the one that may and letting the door refuse
    /// the other in words; a home the writer may not file in is now simply not
    /// in the picker. *Every edition* first, as the sheet has always ordered
    /// them. Empty exactly where `keepMine` is false.
    func keepMineHomes(language: String) -> [TranslatorsNote.Home] {
        (keepMineOnEveryEdition ? [.everyEdition] : [])
            + (keepMineOpensOnTheEdition ? [.edition(language)] : [])
    }

    /// Reader's/Collator's right on a row: the ruling always, the reply only
    /// where there is a query to settle.
    func sideWithTheNote(hasQuery: Bool) -> Bool {
        rule && (!hasQuery || replies)
    }
}

/// **The nine verbs, wired to a window** (translation pipeline P4 Task 4).
///
/// `CentreColumn.designGateActions`' shape one surface over: closures rather
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

        // **The record verbs' one write: a read-modify-write of the round AS
        // THE LEDGER HOLDS IT NOW** (shell p4 Task 6 fix round, review C1).
        // The round the surface holds is only the key — language, piece,
        // number — so two verbs pressed over one stale copy each change their
        // own field and neither undoes the other. A write is announced
        // (`.maughamTranslationRoundChanged`, project-scoped, tripwire 21) so
        // the tree's mark, Status and every open list or report read again.
        let rounds = TranslationRoundStore(projectURL: projectURL)
        //
        // **The ledger is decoded and written off the main actor** (fix round
        // 2, N5: a 200-chapter ledger is ~3 MB, and a decode plus an encode
        // held the main actor ~28 ms per Fine). Only the announcement is the
        // main actor's.
        func mutate(_ round: TranslationRound,
                    _ change: @escaping @Sendable (inout TranslationRound) throws -> Void)
        async -> Result<TranslationRound, Error> {
            let (language, docId, number) = (round.language, round.docId, round.number)
            let result = await Task.detached(priority: .userInitiated) { () -> Result<TranslationRound, Error> in
                do {
                    return .success(try rounds.mutate(language: language, docId: docId, number: number, change))
                } catch {
                    return .failure(error)
                }
            }.value
            if case .success = result { MaughamEvent.postTranslationRoundChanged(projectURL: projectURL) }
            return result
        }
        /// The round as it stands, for a verb that must decide before it
        /// files — read off the main actor.
        func current(_ round: TranslationRound) async -> TranslationRound? {
            let (language, docId, number) = (round.language, round.docId, round.number)
            return await Task.detached(priority: .userInitiated) {
                rounds.record(language: language, docId: docId, number: number)
            }.value
        }
        /// Whether `departureId` is still a change to look at in the stored
        /// round — nil when the round or the departure is gone.
        func stillToLookAt(_ round: TranslationRound, _ departureId: String) async -> Bool? {
            guard let stored = await current(round),
                  let departure = stored.departures.first(where: { $0.id == departureId })
            else { return nil }
            return EditionStatusRows.isToLookAt(departure)
        }
        /// **A filing's outcome, settling `departureId`**: dismissed AND
        /// ruled. Filed but not settled says so in words (fix round 2, N3),
        /// never `.filed` over a change still listed that a second press
        /// would file again.
        func settled(_ round: TranslationRound, _ departureId: String?,
                     _ destination: FiledDestination, _ sentence: String) async -> Outcome {
            guard let departureId else { return .filed(nil, destination, sentence) }
            switch await mutate(round, { stored in
                guard let index = stored.departures.firstIndex(where: { $0.id == departureId })
                else { throw TranslationRoundVerbRefusal.rowGone }
                stored.departures[index].dismissed = true
                stored.departures[index].ruled = true
            }) {
            case .success(let written): return .filed(written, destination, sentence)
            case .failure(let error):
                return .refused(TranslationRoundReport.filedButNotSettled(reason: error.localizedDescription))
            }
        }

        // MARK: Fine

        actions.dismiss = { round, departureId in
            // **Beside the translator's fact, never over it.** `outcome` holds
            // what the translator did — the rewrite, the reason they declined —
            // and Fine is offered on every row, so writing the disposition there
            // would erase a before/after or a decline reason on one click.
            switch await mutate(round, { stored in
                guard let index = stored.departures.firstIndex(where: { $0.id == departureId })
                else { throw TranslationRoundVerbRefusal.rowGone }
                stored.departures[index].dismissed = true
            }) {
            case .success(let written): return .done(written, TranslationRoundReport.dismissedLine)
            case .failure(TranslationRoundVerbRefusal.rowGone): return .refused(TranslationRoundReport.rowGone)
            case .failure(let error): return .refused(error.localizedDescription)
            }
        }

        // MARK: Keep mine

        actions.keepMine = { [weak store, weak world] round, paragraphId, instruction, home, settling in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            let words = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            // The translator's-note voice, because this IS that act reached
            // from a second surface: an instruction with no words says nothing
            // to a translator, and a blank directive would be briefed to every
            // later round as though it did.
            guard !words.isEmpty else { return .refused(TranslatorsNoteCopy.emptyRefusal) }
            // A change already settled — here or on another surface — files
            // nothing a second time.
            // **Claimed first, before any await, then checked against the
            // stored round** (fix round 2, N3): a second press anywhere in
            // this app finds the claim; one after the first ends finds the
            // change settled.
            let claim = settling.map { TranslationRoundActions.claimKey(round, "departure/" + $0) }
            if let claim, !TranslationRoundActions.claim(claim) {
                return .refused(TranslationRoundReport.alreadySettledLine)
            }
            defer { claim.map(TranslationRoundActions.release) }
            if let settling {
                switch await stillToLookAt(round, settling) {
                case nil: return .refused(TranslationRoundReport.rowGone)
                case false?: return .refused(TranslationRoundReport.alreadySettledLine)
                case true?: break
                }
            }
            let (kind, scope) = TranslatorsNote.destination(home: home, docId: round.docId)
            let destination: FiledDestination
            do {
                destination = try await RulingPerformer.rule(
                    Ruling.directiveText(paragraphId: paragraphId, words),
                    provenance: TranslationRoundReport.provenance(round: round,
                                                                  verb: "keep mine"),
                    kind: kind, forScope: scope, store: store,
                    world: home == .everyEdition ? world : nil)
            } catch {
                return .refused(error.localizedDescription)
            }
            return await settled(round, settling, destination, TranslationRoundReport.keptLine(home: home))
        }

        // MARK: Make it a rule

        actions.makeRule = { [weak store] round, text, settling in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            let claim = settling.map { TranslationRoundActions.claimKey(round, "departure/" + $0) }
            if let claim, !TranslationRoundActions.claim(claim) {
                return .refused(TranslationRoundReport.alreadySettledLine)
            }
            defer { claim.map(TranslationRoundActions.release) }
            if let settling {
                switch await stillToLookAt(round, settling) {
                case nil: return .refused(TranslationRoundReport.rowGone)
                case false?: return .refused(TranslationRoundReport.alreadySettledLine)
                case true?: break
                }
            }
            let destination: FiledDestination
            do {
                // Unanchored on purpose: a rule made from a round is doctrine
                // for the edition, not a directive about one paragraph. An
                // empty one is refused by `RulingPerformer` in its own words.
                destination = try await RulingPerformer.rule(
                    text,
                    provenance: TranslationRoundReport.provenance(round: round,
                                                                  verb: "make it a rule"),
                    kind: .editionBrief(round.language), forScope: .project,
                    store: store, world: nil)
            } catch {
                return .refused(error.localizedDescription)
            }
            // **Where it went, read off the write** (shell plan 3 Task 6): the
            // report draws this sentence under the row's own section.
            return await settled(round, settling, destination, FiledUnder.sentence(
                destination, faces: .edition(language: round.language),
                structure: store.manifest.structure, projectType: store.manifest.type,
                firstReaderName: FirstReaderRuling.readerName(in: store.manifest)))
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

        actions.adopt = { [weak store] round, identity in
            guard let store else { return .refused(TranslationRoundReport.notWired) }
            // **Decided over the STORED record** (review C1): a proposal
            // already adopted or skipped — here, in the report, on another
            // Mac — files no second glossary ruling. Every copy of the pair
            // is one proposal (fix round 2, N2): one still open answers.
            // **Claimed first, before any await** (fix round 2, N3): a second
            // press — this surface, the report, another window — finds the
            // claim; one after the first ends finds the proposal answered.
            let claim = TranslationRoundActions.claimKey(round, "glossary/" + identity)
            guard TranslationRoundActions.claim(claim) else {
                return .refused(TranslationRoundReport.alreadyAnsweredLine)
            }
            defer { TranslationRoundActions.release(claim) }
            guard let stored = await current(round),
                  stored.glossaryProposals.contains(where: { $0.identity == identity })
            else { return .refused(TranslationRoundReport.rowGone) }
            guard let proposal = stored.glossaryProposals.first(where: {
                $0.identity == identity && ResolveEditionItems.isOpen($0)
            }) else { return .refused(TranslationRoundReport.alreadyAnsweredLine) }
            guard !proposal.term.trimmingCharacters(in: .whitespaces).isEmpty,
                  !proposal.rendering.trimmingCharacters(in: .whitespaces).isEmpty
            else { return .refused(TranslationRoundReport.emptyGlossaryTerm) }
            let destination: FiledDestination
            do {
                // `Ruling.Provenance.glossary`, not the round's own line: a
                // glossary entry is read back BY SHAPE (`Ruling.glossary`) and
                // its provenance is the one word every briefing recognises it
                // by, whichever round proposed it.
                destination = try await RulingPerformer.rule(
                    Ruling.glossaryText(term: proposal.term,
                                        rendering: proposal.rendering,
                                        note: proposal.reason),
                    provenance: Ruling.Provenance.glossary,
                    kind: .editionBrief(round.language), forScope: .project,
                    store: store, world: nil)
            } catch {
                return .refused(error.localizedDescription)
            }
            switch await mutate(round, { stored in
                let matches = stored.glossaryProposals.indices.filter {
                    stored.glossaryProposals[$0].identity == identity
                }
                guard !matches.isEmpty else { throw TranslationRoundVerbRefusal.rowGone }
                for index in matches { stored.glossaryProposals[index].adopted = true }
            }) {
            case .success(let written):
                return .filed(written, destination, TranslationRoundReport.adoptedLine)
            case .failure(let error):
                return .refused(TranslationRoundReport.adoptedButNotRecorded(
                    term: proposal.term, reason: error.localizedDescription))
            }
        }

        actions.skip = { round, identity in
            switch await mutate(round, { stored in
                let matches = stored.glossaryProposals.indices.filter {
                    stored.glossaryProposals[$0].identity == identity
                }
                guard !matches.isEmpty else { throw TranslationRoundVerbRefusal.rowGone }
                // An adopted proposal is a ruling already filed: Skip over it
                // would say the opposite of what the brief holds.
                guard !matches.contains(where: { stored.glossaryProposals[$0].adopted })
                else { throw TranslationRoundVerbRefusal.alreadyAnswered }
                for index in matches { stored.glossaryProposals[index].skipped = true }
            }) {
            case .success(let written): return .done(written, TranslationRoundReport.skippedLine)
            case .failure(TranslationRoundVerbRefusal.rowGone): return .refused(TranslationRoundReport.rowGone)
            case .failure(TranslationRoundVerbRefusal.alreadyAnswered):
                return .refused(TranslationRoundReport.alreadyAnsweredLine)
            case .failure(let error): return .refused(error.localizedDescription)
            }
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

/// Why a record verb refused inside its read-modify-write (shell p4 Task 6
/// fix round): the row is no longer in the stored round, or it was already
/// answered there.
enum TranslationRoundVerbRefusal: Error, Equatable {
    case rowGone
    case alreadyAnswered
}

// MARK: - One filing at a time (fix round 2, N3)

extension TranslationRoundActions {
    /// The filings in flight, by round and row: a verb that files across an
    /// `await` claims its row first, so a second press anywhere in this app —
    /// the list, the report, another window — files nothing while it runs.
    @MainActor private static var inFlight: Set<String> = []

    static func claimKey(_ round: TranslationRound, _ row: String) -> String {
        "\(round.language.lowercased())/\(round.docId)#\(round.number)/\(row)"
    }

    /// True when the claim was taken; false when a filing already holds it.
    @MainActor static func claim(_ key: String) -> Bool { inFlight.insert(key).inserted }
    @MainActor static func release(_ key: String) { inFlight.remove(key) }
}
