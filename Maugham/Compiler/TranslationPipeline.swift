import Foundation
import MaughamCore
import os

private let pipelineLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "TranslationPipeline")

/// **One Run, seven legs** (translation pipeline spec §5). A state machine
/// and nothing else: it owns no session, gathers no briefing, parses no
/// translator report. It sequences legs by calling the translator's
/// orchestrator (`runTranslation`, `runFix`) and awaiting the `onRunEnded`/
/// `onRunAbandoned` the window feeds back in, and by calling `ColdCall` for
/// the reader and collator — whose raw text it turns into a `ReaderReport`/
/// `CollatorReport`, because `ColdCall` returns text and the report contract
/// is the caller's.
///
/// | Leg | Who | Input | Output |
/// |---|---|---|---|
/// | 1 translate | translator | stale ∪ missing ∪ directed | entries, queries |
/// | 2 read | reader | translated text, blind | notes + overall |
/// | 3 fix | translator | leg 2's notes | addressed/declined |
/// | 4 re-read | reader | the text again | notes + overall |
/// | 5 fix | translator | leg 4's notes | addressed/declined |
/// | 6 collate | collator | source + translation | departures + overall |
/// | 7 fix | translator | leg 6's `drifted` | addressed/declined, summary, proposals |
///
/// **Skips are recorded, never silent**; **a failing, rejected or cancelled
/// leg ends the round there**, earlier legs' writes stay; **Cancel** reaches
/// the live leg and the generation check catches a cancel in the gap;
/// **the book queue** runs the desk's document set through one round each.
/// Every outcome lands in one `TranslationRound` handed to `saveRound` —
/// the record is the pipeline's whole product.
///
/// **Note ids are minted here, before the fix leg is briefed**: a reader's
/// note or a collator's departure becomes a `TranslatorBriefing.FixNote`
/// whose `id` is the record's own, so `addressed`/`declined` name a row of
/// the record and nothing has to be matched by text afterwards.
///
/// **The owner must call `shutdown()` or `detach()`** on every window-ending
/// path — not for a process (it holds none) but for a leg awaiting a
/// translator summary that will never come once the orchestrator is shut
/// down: `shutdown()` resumes it as cancelled.
@Observable @MainActor
final class TranslationPipeline {

    struct BookProgress: Equatable, Sendable {
        let position: Int
        let count: Int
    }

    /// What the desk draws (Plan 4): idle, or which leg of which pair — and
    /// for a book queue, which chapter of how many.
    enum Status: Equatable, Sendable {
        case idle
        case running(docId: String, language: String, leg: TranslationRound.Leg,
                     book: BookProgress?)

        var language: String? {
            if case .running(_, let language, _, _) = self { return language }
            return nil
        }
    }

    /// What the environment mints a declined note as (spec §6): one `.query`
    /// per item, anchored to the note's paragraph, authored by the reader or
    /// collator (`note.author`, signed with `authorRoleId`), language-tagged,
    /// with the translator's reason in the body under the translator's name.
    struct DeclinedMint: Equatable {
        struct Item: Equatable {
            let note: TranslatorBriefing.FixNote
            let reason: String
            let authorRoleId: String
        }
        let docId: String
        let language: String
        let translatorName: String
        let items: [Item]
    }

    struct Environment {
        var model: String = CompilerOrchestrator.defaultModel
        /// `TranslatorOrchestrator.runTranslation` — the run id, or nil when refused.
        var runTranslation: @MainActor (String, String) -> String?
        /// `TranslatorOrchestrator.runFix(docId:language:notes:isFinalLeg:)`.
        var runFix: @MainActor (String, String, [TranslatorBriefing.FixNote], Bool) -> String?
        var cancelTranslator: @MainActor () -> Void
        /// The translator's display name for a language — read-only
        /// (`EditionStatus.translatorName`), for the declined mint's byline.
        var translatorName: @MainActor (String) -> String
        /// Find-or-create (`ProjectStore.readerRole/collatorRole(for:)`) — a
        /// run is the write act that earns the mint. Asked BEFORE the
        /// briefing, `TranslatorOrchestrator.begin`'s order, for its reason.
        var readerIdentity: @MainActor (String) async throws -> (name: String, roleId: String)
        var collatorIdentity: @MainActor (String) async throws -> (name: String, roleId: String)
        var briefReader: @MainActor (String, String) async -> ReaderBriefing.Inputs?
        var briefCollator: @MainActor (String, String) async -> CollatorBriefing.Inputs?
        /// `ColdCall.call(message:preamble:model:)`.
        var coldCall: @MainActor (String, String?, String) async -> CompilerRunEvent
        var cancelColdCall: @MainActor () -> Void
        /// Mints the declined notes as queries; answers note id → annotation id.
        var mintDeclinedQueries: @MainActor (DeclinedMint) async -> [String: String]
        var nextRoundNumber: @MainActor (String) -> Int
        var saveRound: @MainActor (TranslationRound) -> Void
        var onRoundEnded: @MainActor (TranslationRound) -> Void
    }

    // MARK: - Copy

    /// What governs a cold SESSION. Everything about who and what is in the
    /// briefing (`ReaderBriefing`/`CollatorBriefing`), which is re-sent whole
    /// every time — a second spelling here would be one the writer's doctrine
    /// could drift from.
    static let coldPreamble =
        "You are answering one question about one document for the writer of a "
        + "manuscript-in-progress. Everything you need is in the message: who you "
        + "are, the language, the writer's doctrine and the text. Answer with the "
        + "report the message describes and nothing else."

    static let nothingToTranslateReason = "nothing stale, missing or directed"
    static let nothingToReadReason = "nothing translated to read"
    static let nothingChangedReason = "nothing changed since the first read"
    static let readerFoundNothingReason = "the reader found nothing to fix"
    static let collatorFoundNoDriftReason = "the collator found no drift"
    static let noCurrentTranslationReason =
        "none of the noted paragraphs still has a current translation"
    static let nothingWrittenReason = "nothing was written this round"
    static let nothingToCollateReason = "nothing translated to collate"
    static let nothingToDoSummary = "Nothing to do \u{2014} nothing was written this round."
    static let translatorRefusedSentence = "The translator refused to start a leg."
    static func unbriefableSentence(role: String) -> String {
        "The \(role) could not be briefed on this document."
    }
    static func identitySentence(role: String, error: Error) -> String {
        "The \(role)'s identity could not be resolved: \(error)"
    }

    // MARK: - State

    private(set) var status: Status = .idle
    private var environment: Environment?
    /// Bumped by `cancel()`, `shutdown()` and every `run`; a leg resuming
    /// compares the generation it started under (`TranslatorOrchestrator
    /// .runGeneration`'s discipline, one owner up).
    private var generation = 0
    private var queue: [String] = []

    private enum TranslatorLegEnd {
        case refused
        case abandoned
        case ended(TranslatorOrchestrator.RunSummary)
    }
    /// The translator leg awaiting its summary. `runId` is nil for the
    /// instant between asking for the run and learning its id — a summary
    /// arriving in that instant is accepted, so a synchronous end cannot
    /// slip past.
    private var pending: (runId: String?, continuation: CheckedContinuation<TranslatorLegEnd, Never>)? = nil
    private enum LiveKind { case translator, cold, gap }
    private var live: LiveKind = .gap

    var isRunning: Bool { status != .idle }

    func configure(environment: Environment) { self.environment = environment }

    func updateModel(_ model: String) { environment?.model = model }

    // MARK: - Entry

    /// One round on one pair. `false` when refused: nothing wired, or a round
    /// (or book) already running.
    @discardableResult
    func run(docId: String, language: String) -> Bool {
        start(queue: [docId], language: language)
    }

    private func start(queue documents: [String], language: String) -> Bool {
        guard let environment, !isRunning, !documents.isEmpty else { return false }
        generation &+= 1
        let gen = generation
        queue = documents
        let count = documents.count
        status = .running(docId: documents[0], language: language, leg: .translate,
                          book: count > 1 ? BookProgress(position: 1, count: count) : nil)
        Task { [weak self] in
            await self?.execute(language: language, count: count, generation: gen,
                                environment: environment)
        }
        return true
    }

    private func execute(language: String, count: Int, generation gen: Int,
                         environment: Environment) async {
        var position = 0
        while generation == gen, !queue.isEmpty {
            let docId = queue.removeFirst()
            position += 1
            let book = count > 1 ? BookProgress(position: position, count: count) : nil
            let round = await runRound(docId: docId, language: language, book: book,
                                       generation: gen, environment: environment)
            // A failed or cancelled round stops a book queue: the next chapter
            // would meet the same session, and the author should see this one.
            if round.stoppedAt != nil { break }
        }
        if generation == gen {
            queue = []
            status = .idle
        }
    }

    // MARK: - The translator's summary, fed back by the window

    func translatorRunEnded(_ summary: TranslatorOrchestrator.RunSummary) {
        guard let pending, pending.runId == nil || pending.runId == summary.runId else { return }
        self.pending = nil
        pending.continuation.resume(returning: .ended(summary))
    }

    func translatorRunAbandoned(_ runId: String) {
        guard let pending, pending.runId == nil || pending.runId == runId else { return }
        self.pending = nil
        pending.continuation.resume(returning: .abandoned)
    }

    // MARK: - One round

    private enum LegResult {
        case ran(TranslationRound.LegCounts)
        case skipped(String)
        case failed(String)
        case cancelled
    }

    private func runRound(docId: String, language: String, book: BookProgress?,
                          generation gen: Int, environment env: Environment) async -> TranslationRound {
        var round = TranslationRound(number: env.nextRoundNumber(language), language: language,
                                     docId: docId, startedAt: Date())
        var wroteAnything = false
        var reader: (name: String, roleId: String)?
        var collator: (name: String, roleId: String)?
        var leg3Wrote = false
        var leg2Notes: [TranslatorBriefing.FixNote] = []
        var leg4Notes: [TranslatorBriefing.FixNote] = []
        var driftNotes: [TranslatorBriefing.FixNote] = []

        func record(_ leg: TranslationRound.Leg, _ result: LegResult) -> Bool {
            switch result {
            case .ran(let counts):
                round.legs.append(.init(leg: leg, status: .ran, counts: counts))
                return true
            case .skipped(let reason):
                round.legs.append(.init(leg: leg, status: .skipped, reason: reason))
                return true
            case .failed(let sentence):
                round.legs.append(.init(leg: leg, status: .failed, reason: sentence))
                return false
            case .cancelled:
                round.legs.append(.init(leg: leg, status: .cancelled))
                return false
            }
        }

        legs: for leg in TranslationRound.Leg.allCases {
            guard generation == gen else {
                // A cancel or shutdown landed in the gap: this leg never starts.
                round.legs.append(.init(leg: leg, status: .cancelled))
                break
            }
            status = .running(docId: docId, language: language, leg: leg, book: book)
            let result: LegResult
            switch leg {
            case .translate:
                result = await translatorLeg(
                    generation: gen, skipReason: Self.nothingToTranslateReason,
                    start: { env.runTranslation(docId, language) },
                    onIngested: { outcome in
                        wroteAnything = wroteAnything || outcome.entriesWritten > 0
                    })

            case .read, .reread:
                if leg == .reread, !leg3Wrote {
                    result = .skipped(Self.nothingChangedReason)
                    break
                }
                let read = await readerLeg(leg, docId: docId, language: language,
                                           identity: reader, generation: gen, environment: env)
                reader = read.identity
                result = read.result
                if let report = read.report {
                    let reportRecord = TranslationRound.ReaderReportRecord(
                        verdict: report.overall.verdict.rawValue, text: report.overall.text)
                    if leg == .read { round.leg2 = reportRecord } else { round.leg4 = reportRecord }
                    let notes = report.notes.map { note in
                        TranslationRound.NoteRecord(
                            id: ULID.generate(), leg: leg, author: reader?.name ?? "",
                            paragraphId: note.paragraphId, kind: note.kind.rawValue,
                            severity: note.severity.rawValue, text: note.text)
                    }
                    round.notes.append(contentsOf: notes)
                    let fixNotes = notes.map { $0.fixNote }
                    if leg == .read { leg2Notes = fixNotes } else { leg4Notes = fixNotes }
                }

            case .fix, .fixAgain, .finalFix:
                let notes = leg == .fix ? leg2Notes : leg == .fixAgain ? leg4Notes : driftNotes
                guard !notes.isEmpty else {
                    result = .skipped(leg == .finalFix ? Self.collatorFoundNoDriftReason
                                                       : Self.readerFoundNothingReason)
                    break
                }
                let authorRoleId = leg == .finalFix ? (collator?.roleId ?? "") : (reader?.roleId ?? "")
                var fixOutcome: TranslatorOrchestrator.IngestOutcome?
                result = await translatorLeg(
                    generation: gen, skipReason: Self.noCurrentTranslationReason,
                    start: { env.runFix(docId, language, notes, leg == .finalFix) },
                    onIngested: { fixOutcome = $0 })
                if let outcome = fixOutcome {
                    wroteAnything = wroteAnything || outcome.entriesWritten > 0
                    if leg == .fix { leg3Wrote = outcome.entriesWritten > 0 }
                    let annotationIds: [String: String]
                    if outcome.declined.isEmpty {
                        annotationIds = [:]
                    } else {
                        let byId = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
                        annotationIds = await env.mintDeclinedQueries(DeclinedMint(
                            docId: docId, language: language,
                            translatorName: env.translatorName(language),
                            items: outcome.declined.compactMap { declined in
                                byId[declined.noteId].map {
                                    .init(note: $0, reason: declined.reason, authorRoleId: authorRoleId)
                                }
                            }))
                        guard generation == gen else {
                            _ = record(leg, .cancelled)
                            break legs
                        }
                    }
                    applyFixOutcomes(outcome, annotationIds: annotationIds, notes: notes, to: &round)
                    if leg == .finalFix {
                        round.summary = outcome.summary
                        round.glossaryProposals = outcome.glossaryProposals.map {
                            .init(term: $0.term, rendering: $0.rendering, reason: $0.reason, adopted: false)
                        }
                    }
                }

            case .collate:
                guard wroteAnything else {
                    result = .skipped(Self.nothingWrittenReason)
                    break
                }
                let collated = await collatorLeg(docId: docId, language: language,
                                                 identity: collator, generation: gen, environment: env)
                collator = collated.identity
                result = collated.result
                if let report = collated.report {
                    round.collatorOverall = report.overall
                    let records = report.departures.map { departure in
                        TranslationRound.DepartureRecord(
                            id: ULID.generate(), paragraphId: departure.paragraphId,
                            verdict: departure.verdict.rawValue, kind: departure.kind.rawValue,
                            note: departure.note, gloss: departure.gloss)
                    }
                    round.departures = records
                    driftNotes = records.filter { $0.verdict == CollatorReport.Verdict.drifted.rawValue }
                        .map { $0.fixNote(author: collator?.name ?? "") }
                }
            }
            if !record(leg, result) { break }
        }

        if !wroteAnything, round.stoppedAt == nil, round.summary == nil {
            round.summary = Self.nothingToDoSummary
        }
        round.endedAt = Date()
        live = .gap
        env.saveRound(round)
        env.onRoundEnded(round)
        return round
    }

    /// Route `addressed`/`declined` onto the record rows the fix leg was
    /// briefed with — notes for legs 3/5, departures for leg 7.
    ///
    /// **Scoped to `notes`, and that is load-bearing.** Legs 3 and 5 are two
    /// turns of ONE warm translator session, so leg 2's note ids are still in
    /// the model's context when leg 5 answers; an id echoed from the earlier
    /// turn would otherwise reach into a row this leg was never briefed with
    /// and silently overwrite the verdict already recorded there — a note the
    /// author will read as declined when it was addressed, or the reverse.
    /// A leg records outcomes for its own work-list and nothing else.
    private func applyFixOutcomes(_ outcome: TranslatorOrchestrator.IngestOutcome,
                                  annotationIds: [String: String],
                                  notes: [TranslatorBriefing.FixNote],
                                  to round: inout TranslationRound) {
        let briefed = Set(notes.map(\.id))
        let rewrites = Dictionary(outcome.rewrites.map { ($0.paragraphId, $0) },
                                  uniquingKeysWith: { first, _ in first })
        func rewrite(for paragraphId: String) -> TranslationRound.Rewrite {
            let r = rewrites[paragraphId]
            return .init(beforeRecordId: r?.beforeRecordId, before: r?.before,
                         afterRecordId: r?.afterRecordId, after: r?.after)
        }
        let declined = Dictionary(outcome.declined.map { ($0.noteId, $0.reason) },
                                  uniquingKeysWith: { first, _ in first })
        for index in round.notes.indices {
            let note = round.notes[index]
            guard briefed.contains(note.id) else { continue }
            if outcome.addressed.contains(note.id) {
                round.notes[index].outcome = .addressed(rewrite(for: note.paragraphId))
            } else if let reason = declined[note.id] {
                round.notes[index].outcome = .declined(reason: reason, annotationId: annotationIds[note.id])
            }
        }
        for index in round.departures.indices {
            let departure = round.departures[index]
            guard briefed.contains(departure.id) else { continue }
            if outcome.addressed.contains(departure.id) {
                round.departures[index].outcome = .addressed(rewrite(for: departure.paragraphId))
            } else if let reason = declined[departure.id] {
                round.departures[index].outcome = .declined(reason: reason, annotationId: annotationIds[departure.id])
            }
        }
    }

    // MARK: - Legs

    /// A translator leg: ask for the run, await the summary the window feeds
    /// back, map it. `skipReason` is what `nothingToTranslate` means for THIS
    /// leg. A cancel arriving mid-leg lands here as a `.cancelled` summary
    /// (the orchestrator's own vocabulary) — and if the generation moved, as
    /// cancelled regardless of what the summary says.
    private func translatorLeg(
        generation gen: Int, skipReason: String,
        start: @MainActor () -> String?,
        onIngested: (TranslatorOrchestrator.IngestOutcome) -> Void
    ) async -> LegResult {
        live = .translator
        let end: TranslatorLegEnd = await withCheckedContinuation { continuation in
            pending = (nil, continuation)
            guard let runId = start() else {
                // Only refuse if this leg still owns the continuation. A
                // callback landing synchronously inside `start()` has already
                // cleared `pending` and resumed it — and Task 5 adds two more
                // resume paths (`cancel()`, `shutdown()`) into this same slot,
                // so a second resume here would trap rather than misreport.
                guard pending != nil else { return }
                pending = nil
                continuation.resume(returning: .refused)
                return
            }
            pending?.runId = runId
        }
        live = .gap
        guard generation == gen else { return .cancelled }
        switch end {
        case .refused: return .failed(Self.translatorRefusedSentence)
        case .abandoned: return .failed(Self.unbriefableSentence(role: "translator"))
        case .ended(let summary):
            switch summary.outcome {
            case .ingested(let outcome):
                if let rejection = outcome.rejection { return .failed(rejection) }
                onIngested(outcome)
                return .ran(.init(entries: outcome.entriesWritten, queries: outcome.queriesMinted,
                                  addressed: outcome.addressed.count,
                                  declined: outcome.declined.count))
            case .nothingToTranslate: return .skipped(skipReason)
            case .cancelled: return .cancelled
            case .failed(let failure): return .failed(DepartmentRunState.failureCopy(failure))
            }
        }
    }

    private enum ColdEnd {
        case text(String)
        case failed(String)
        case cancelled
    }

    private func coldLeg(message: String, generation gen: Int,
                         environment env: Environment) async -> ColdEnd {
        live = .cold
        let event = await env.coldCall(message, Self.coldPreamble, env.model)
        live = .gap
        guard generation == gen else { return .cancelled }
        switch event {
        case .resultText(let text): return .text(text)
        case .failed(let failure):
            return failure.isTheWritersOwnDoing
                ? .cancelled
                : .failed(RoundNarrative.failureCopy(failure, session: .translation))
        case .started:
            return .failed(RoundNarrative.failureCopy(.unusableOutput, session: .translation))
        }
    }

    /// The reader's leg. The identity travels in and back out rather than by
    /// `inout`: it is resolved once per round and the caller keeps it for the
    /// re-read and for the declined mint's byline.
    private func readerLeg(
        _ leg: TranslationRound.Leg, docId: String, language: String,
        identity: (name: String, roleId: String)?, generation gen: Int,
        environment env: Environment
    ) async -> (result: LegResult, report: ReaderReport?, identity: (name: String, roleId: String)?) {
        var identity = identity
        if identity == nil {
            do { identity = try await env.readerIdentity(language) } catch {
                guard generation == gen else { return (.cancelled, nil, identity) }
                return (.failed(Self.identitySentence(role: "reader", error: error)), nil, identity)
            }
            guard generation == gen else { return (.cancelled, nil, identity) }
        }
        guard let inputs = await env.briefReader(docId, language) else {
            guard generation == gen else { return (.cancelled, nil, identity) }
            return (.failed(Self.unbriefableSentence(role: "reader")), nil, identity)
        }
        guard generation == gen else { return (.cancelled, nil, identity) }
        guard !inputs.briefedParagraphIds.isEmpty else {
            return (.skipped(Self.nothingToReadReason), nil, identity)
        }
        switch await coldLeg(message: ReaderBriefing.compose(inputs: inputs),
                             generation: gen, environment: env) {
        case .cancelled: return (.cancelled, nil, identity)
        case .failed(let sentence): return (.failed(sentence), nil, identity)
        case .text(let text):
            guard let report = ReaderReport.parse(text, briefedParagraphIds: inputs.briefedParagraphIds) else {
                return (.failed(RoundNarrative.failureCopy(.unusableOutput, session: .translation)),
                        nil, identity)
            }
            return (.ran(.init(notes: report.notes.count)), report, identity)
        }
    }

    private func collatorLeg(
        docId: String, language: String,
        identity: (name: String, roleId: String)?, generation gen: Int,
        environment env: Environment
    ) async -> (result: LegResult, report: CollatorReport?, identity: (name: String, roleId: String)?) {
        var identity = identity
        if identity == nil {
            do { identity = try await env.collatorIdentity(language) } catch {
                guard generation == gen else { return (.cancelled, nil, identity) }
                return (.failed(Self.identitySentence(role: "collator", error: error)), nil, identity)
            }
            guard generation == gen else { return (.cancelled, nil, identity) }
        }
        guard let inputs = await env.briefCollator(docId, language) else {
            guard generation == gen else { return (.cancelled, nil, identity) }
            return (.failed(Self.unbriefableSentence(role: "collator")), nil, identity)
        }
        guard generation == gen else { return (.cancelled, nil, identity) }
        guard !inputs.briefedParagraphIds.isEmpty else {
            return (.skipped(Self.nothingToCollateReason), nil, identity)
        }
        switch await coldLeg(message: CollatorBriefing.compose(inputs: inputs),
                             generation: gen, environment: env) {
        case .cancelled: return (.cancelled, nil, identity)
        case .failed(let sentence): return (.failed(sentence), nil, identity)
        case .text(let text):
            guard let report = CollatorReport.parse(text, briefedParagraphIds: inputs.briefedParagraphIds) else {
                return (.failed(RoundNarrative.failureCopy(.unusableOutput, session: .translation)),
                        nil, identity)
            }
            return (.ran(.init(departures: report.departures.count)), report, identity)
        }
    }

    // MARK: - Cancel and shutdown (completed in Task 5)

    func cancel() {}
    func shutdown() {}
    func detach() {}
}

extension TranslationRound.NoteRecord {
    /// The note as the fix leg is briefed with it — same id.
    var fixNote: TranslatorBriefing.FixNote {
        .init(id: id, paragraphId: paragraphId, author: author, kind: kind,
              severity: severity, text: text)
    }
}

extension TranslationRound.DepartureRecord {
    /// A departure as a fix note: the collator's reason and the gloss, so
    /// the translator sees what the author will judge it by.
    func fixNote(author: String) -> TranslatorBriefing.FixNote {
        .init(id: id, paragraphId: paragraphId, author: author, kind: kind, severity: nil,
              text: "\(note) The translation now says: \(gloss)")
    }
}
