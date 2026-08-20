import Foundation
import MaughamCore

/// **The translation run.** One click arrives here, and Tasks 1–3 are called
/// in order: the translator's identity, the briefing over this round's
/// stale-and-missing work-list, the warm session, the parse, the ingest.
///
/// `CompilerOrchestrator`'s rails, deliberately: the same closure
/// `Environment` so a run is driven end to end with no project on disk, the
/// same warm-session-with-lazy-spawn shape, the same generation discipline
/// across every suspension, and the same vocabulary for what a run can be.
/// What differs is what a run is FOR — the compiler reads and reports, the
/// translator produces words the writer will publish — and the two places
/// that follows from are marked below: the session is warm per
/// `(docId, language)` rather than per window, and a failure writes nothing
/// at all.
///
/// **It ingests through closures and touches no store.** The report comes
/// back, is parsed, and is handed to `Environment.ingest`, whose production
/// implementation (Task 5) writes entries through the one shared translation
/// pipeline and mints queries as annotations. Nothing here holds a
/// `Document`, a `ProjectStore` or an editor binding across a subprocess turn
/// (tripwires 3, 6).
///
/// **The spawned session never writes; Maugham writes at ingest**, which is
/// what makes atomicity structural rather than careful: `Environment.ingest`
/// is reachable from exactly one place in this file — the arm holding a
/// successfully parsed report — so a session that died, timed out, was
/// cancelled or answered gibberish has no path to the writer's words at all
/// (spec §6). `TranslatorOrchestratorTests.test_aFailedRunIngestsNothing` is
/// the guard.
///
/// **The owner must call `shutdown()`.** This is `ClaudeCLISession`'s
/// contract inherited whole, and this type is its second owner. Releasing a
/// live orchestrator does NOT kill its `claude`: `deinit` is nonisolated and
/// cannot touch main-actor state, and deallocating a `Process` neither
/// signals nor reaps the child, so an orchestrator merely released leaves a
/// real, billing, API-calling process running for as long as it survives its
/// closed stdin. Every path that ends a window — window close, project close,
/// app quit, the AI toggle — owns a call to `shutdown()` or `detach()`. A
/// `deinit` here would be a reaper that cannot reach the process it claims to
/// reap, which is why there isn't one.
@Observable @MainActor
final class TranslatorOrchestrator {

    /// The document-and-language a run is about. One value because neither
    /// half means anything alone here: the work-list, the briefing, the
    /// session and every state below are all per pair.
    struct Pair: Equatable, Sendable {
        let docId: String
        let language: String

        init(docId: String, language: String) {
            self.docId = docId
            self.language = language
        }
    }

    /// What the desk says about the last thing the run verb did.
    ///
    /// `CompilerOrchestrator.RunState`'s vocabulary, with `nothingNew`'s job
    /// done by `nothingToTranslate`: the click worked, the coverage
    /// derivation found nothing stale or missing, and there is nothing to
    /// report. It is separate from `idle` for that type's own reason — a
    /// writer who clicks Run translation and sees the row unchanged has no
    /// way to tell "checked, everything is fresh" from "the button did
    /// nothing".
    ///
    /// **Every state that describes a run names the PAIR it ran on**, and the
    /// language is as load-bearing as the document: a desk shows a row per
    /// edition, so a failure that named only the document would paint a red
    /// line across the Spanish row for a French run that died. `.idle`
    /// carries neither because it claims nothing.
    enum RunState: Equatable {
        case idle
        /// `translating` is the work-list's own count, known before the send,
        /// so the desk can say what is being translated rather than making a
        /// writer stare at a bare spinner for two minutes.
        case running(docId: String, language: String, translating: Int)
        case nothingToTranslate(docId: String, language: String, at: Date)
        case failed(docId: String, language: String, failure: Failure, at: Date)
    }

    /// Why a run did not land its words.
    ///
    /// Two cases because they fail at different boundaries and a desk row
    /// says different things about them. `run` is everything that went wrong
    /// between the click and a readable report — the compiler's own
    /// `CompilerRunFailure` reused rather than re-spelled, including
    /// `unusableOutput` for a turn `TranslatorReport.parse` refused whole.
    /// `ingestRejected` is a report that was read perfectly and could not be
    /// written: the all-or-nothing rule catching a paragraph that vanished
    /// between the send and the ingest, or one the writer EDITED in that
    /// window, whose sentence names the ids (spec §6, "unknown `¶id`s fail
    /// the whole batch loudly, listing them"). The
    /// second is louder-sounding and less serious — the words are still
    /// there to be re-run — and a desk that could not tell them apart would
    /// have to guess which.
    enum Failure: Equatable, Sendable {
        case run(CompilerRunFailure)
        case ingestRejected(String)
    }

    /// One round's briefing, together with what its paragraphs looked like at
    /// the moment it was sent.
    ///
    /// **Two values rather than one because they are read by different
    /// people.** `inputs` is what the model is shown and is a pure function's
    /// argument (`TranslatorBriefing.Inputs` keeps its rule that every field
    /// has a reader in `compose`); `sourceHashes` is shown to nobody and
    /// exists only so ingest can tell whether the writer edited a paragraph
    /// while the round was in flight. Hashed off the RAW paragraph text — the
    /// same string `TranslationWritePipeline` stamps a record's `sourceHash`
    /// from — not off the anchor-stripped display text the work item carries,
    /// because a comparison against a different normalization would be a
    /// guard that fires on nothing.
    struct BriefedRound: Equatable {
        let inputs: TranslatorBriefing.Inputs
        /// `paragraphId` → `TranslationHash.hash` of the raw source as
        /// briefed. Keyed on the work-list only: a context paragraph is not
        /// this round's work and no entry may name one.
        let sourceHashes: [String: String]

        init(inputs: TranslatorBriefing.Inputs, sourceHashes: [String: String]) {
            self.inputs = inputs
            self.sourceHashes = sourceHashes
        }
    }

    /// What ingest is told about the run whose report it is writing.
    ///
    /// The translator's identity travels here rather than being re-resolved
    /// downstream: `translatorRole(for:)` is find-or-create, so a second
    /// resolution is a second chance to mint, and the name that signs a query
    /// must be the name the briefing put in front of the model
    /// (`CompilerOrchestrator.ActivePass`'s reasoning — one answer, resolved
    /// once, carried).
    struct IngestContext: Equatable, Sendable {
        let docId: String
        let language: String
        /// This run's own id — what the desk row, the summary and anything
        /// ingest records name the same check by.
        let runId: String
        /// `ProductionRole.effectiveName` for this language's translator.
        let translatorName: String
        /// `ProductionRole.id` — what an annotation byline is signed with.
        let translatorRoleId: String
        /// `BriefedRound.sourceHashes`, carried whole.
        ///
        /// **Undefaulted on purpose.** An empty map is a run whose paragraphs
        /// nobody can check, and a defaulted parameter is how a new call site
        /// arrives at that silently — the pipeline would then happily stamp
        /// the CURRENT source's hash onto a translation of text the model was
        /// never shown, and the entry would read fresh forever.
        let briefedSourceHashes: [String: String]

        init(docId: String, language: String, runId: String,
             translatorName: String, translatorRoleId: String,
             briefedSourceHashes: [String: String]) {
            self.docId = docId
            self.language = language
            self.runId = runId
            self.translatorName = translatorName
            self.translatorRoleId = translatorRoleId
            self.briefedSourceHashes = briefedSourceHashes
        }
    }

    /// What ingest did with a report.
    ///
    /// **`rejection` is not an error the run threw**: ingest cannot fail the
    /// app and its signature says so (no `throws`), because the batch being
    /// refused is a legitimate answer the writer has to see rather than a
    /// crash. When it is non-nil nothing was written — that is the
    /// all-or-nothing rule the pipeline already enforces — and this
    /// orchestrator turns it into a `failed` state carrying the sentence.
    ///
    /// `warnings` are advisory (construct parity, a translation identical to
    /// its source) and never block: they ride the summary to the desk.
    struct IngestOutcome: Equatable, Sendable {
        let entriesWritten: Int
        let queriesMinted: Int
        let warnings: [String]
        let rejection: String?

        init(entriesWritten: Int = 0, queriesMinted: Int = 0,
             warnings: [String] = [], rejection: String? = nil) {
            self.entriesWritten = entriesWritten
            self.queriesMinted = queriesMinted
            self.warnings = warnings
            self.rejection = rejection
        }
    }

    /// One finished run, for whoever keeps the record (P4's desk).
    ///
    /// Emitted exactly once for every run that STARTED — including the one
    /// that found nothing to do and the one the writer cancelled — and never
    /// for a click that was refused or had nothing to act on, because a
    /// spinner nothing closes is worse than a row that says "cancelled".
    struct RunSummary: Equatable, Sendable {
        let runId: String
        let docId: String
        let language: String
        let at: Date
        let outcome: Outcome

        enum Outcome: Equatable, Sendable {
            /// A report came back, parsed, and was handed to ingest. The
            /// value says what became of it, `rejection` included: the
            /// summary is the record and loses nothing, while `runState`
            /// above is the surface and says only whether the writer needs
            /// to look.
            case ingested(IngestOutcome)
            /// Nothing was stale or missing. No session was spawned.
            case nothingToTranslate
            /// The writer's own act — Cancel, the window closing, the toggle
            /// going off. Not a failure and never drawn as one.
            case cancelled
            case failed(Failure)
        }

        init(runId: String, docId: String, language: String, at: Date, outcome: Outcome) {
            self.runId = runId
            self.docId = docId
            self.language = language
            self.at = at
            self.outcome = outcome
        }
    }

    /// Everything the run needs from the window it belongs to. Closures
    /// rather than stores, so a run is driven with no project on disk and so
    /// `detach()` drops the window's whole object graph in one line. Every
    /// closure is `@MainActor`: the stores they reach are, and an isolation
    /// hop between the click and the work-list would let the writer type in
    /// the gap.
    struct Environment {
        var projectId: String
        /// The model a run is spawned against — the compiler's setting, so a
        /// writer who chose a deeper model for their checks gets it for their
        /// translations too. Defaulted to the compiler's own constant rather
        /// than a second literal.
        var model: String = CompilerOrchestrator.defaultModel
        /// `(docId, language)` → everything one briefing needs **and the
        /// paragraph hashes it was gathered against**, or `nil` when this pair
        /// is not something the window can translate at all (no such document,
        /// no translation posture). `nil` is not an error and not a run — the
        /// compiler's `reading(docId) == nil` guard, in this currency.
        ///
        /// **Asked AFTER `translatorIdentity`, and that order is
        /// load-bearing** — see `begin`. The name this answers with must be
        /// the one the identity resolved: production reads both through
        /// `ProjectStore`'s translator row, which the mint has already put
        /// there by the time this is called.
        var briefRound: @MainActor (String, String) async -> BriefedRound?
        /// The translator for a language, minting one the first time anybody
        /// asks (`ProjectStore.translatorRole(for:)`). **A run is a write
        /// act**, which is what makes the mint legitimate here and illegitimate
        /// on every read path (`ProjectStore+ProductionRoles`'s own rule).
        ///
        /// Throwing, unlike everything else in this struct: a language tag
        /// the store refuses is a run that can produce work nobody could
        /// sign, so it fails before a session is spawned rather than after.
        var translatorIdentity: @MainActor (String) async throws -> (name: String,
                                                                     roleId: String)
        /// Writes the per-session `--mcp-config` file and returns its path.
        /// The orchestrator owns the file's life from here (`ensureRunner`).
        var writeMCPConfig: @MainActor () throws -> URL
        /// `(configPath, model)` → the session. The model is passed rather
        /// than captured so `model` above is the only place it is decided.
        var makeRunner: @MainActor (URL, String) -> CompilerRunner
        /// **Where the words actually land**, and the only writing this loop
        /// does. Entries go through the one shared translation write pipeline
        /// and queries mint as annotations authored by the translator (Task
        /// 5).
        ///
        /// It cannot fail the run and its signature says so: no `throws`, an
        /// outcome rather than a result. A batch the pipeline refuses comes
        /// back as `IngestOutcome.rejection` — a thing the writer is told,
        /// not a thing that throws past them.
        var ingest: @MainActor (TranslatorReport, IngestContext) async -> IngestOutcome
        /// One finished run, for the record. See `RunSummary`.
        var onRunEnded: @MainActor (RunSummary) -> Void
    }

    // MARK: - The session preamble

    /// What governs the SESSION rather than the round.
    ///
    /// Deliberately says nothing about who the translator is, what language
    /// this is, or what the report must look like: all three live in
    /// `TranslatorBriefing.compose`, which runs every round, and a second
    /// spelling here would be one the writer's own doctrine could drift away
    /// from. What is left is what a system prompt is actually for — the
    /// session's shape, and the project the bridge's read tools are scoped
    /// to.
    static func sessionSystemPreamble(projectId: String) -> String {
        """
        You are translating a manuscript-in-progress for the writer who is \
        still writing it. Every message names the translator you are, the \
        language, the writer's standing doctrine and the paragraphs this \
        round asks for — read that frame each time rather than assuming it \
        carries over, because the writer can change any of it between rounds.

        This session is long-lived: later rounds build on what you have \
        already translated here, so keep one voice across them. You never \
        write into the manuscript and you will not see your words written \
        back — you answer with a report and Maugham ingests it.

        Project: \(projectId)
        """
    }

    // MARK: - State

    private(set) var runState: RunState = .idle

    private var environment: Environment?
    private var runner: CompilerRunner?
    private var configURL: URL?
    /// The model and the pair `runner` was **spawned** for. Both are spawn
    /// facts rather than settings — `--model` is an argument, and a session's
    /// context is one document in one language — so this is what
    /// `ensureRunner` compares against.
    private var runnerModel: String?
    private var runnerPair: Pair?

    /// True between the click and the send, while the identity is minted and
    /// the briefing gathered. `isRunning` counts it, so the second click of a
    /// double-click is refused there exactly as it is mid-turn — the window
    /// is short, but two runs on one pair are two sessions' worth of work
    /// over one work-list.
    private var isPreparingRun = false

    /// The generation a run's suspensions belong to. A teardown between the
    /// click and the send **abandons** the run rather than letting it spawn a
    /// session the writer has just closed the window on; a boolean cleared
    /// and re-set by the next click could not tell the two apart. Same
    /// reasoning as `ClaudeCLISession.generation` (AREA.md, "generations, not
    /// booleans"). Three suspensions carry it: the identity mint, the
    /// briefing gather, and the ingest.
    private var runGeneration = 0

    /// The run in flight, or `nil` between runs — kept so a cancel arriving
    /// before the send can still name the run it ended.
    private var active: (generation: Int, runId: String, pair: Pair)?

    var isRunning: Bool {
        if isPreparingRun { return true }
        if case .running = runState { return true }
        return false
    }

    /// Wire the orchestrator to its window. Called where the stores exist —
    /// never from a `body`.
    func configure(environment: Environment) {
        self.environment = environment
    }

    /// Change the model runs are spawned against.
    ///
    /// Setting this is not enough on its own, and that is why the retirement
    /// lives in `ensureRunner`: the model is a spawn argument, so a warm
    /// session was built with the old one and will keep answering in it. The
    /// stale session is retired lazily, at the next run, so a change made
    /// mid-round never kills the round in flight.
    func updateModel(_ model: String) {
        environment?.model = model
    }

    // MARK: - The one entry

    /// Run a translation for this document into this language.
    ///
    /// Refuses quietly in the two cases where the honest thing to do is
    /// nothing: a run already in flight (one session per orchestrator; a
    /// second round is what the next click is for), and a pair the window
    /// cannot brief at all.
    func runTranslation(docId: String, language: String) {
        guard let environment, !isRunning else { return }

        runGeneration &+= 1
        let generation = runGeneration
        let pair = Pair(docId: docId, language: language)
        // Minted at the click rather than when an answer lands: a cancel
        // before the send still has to name the run it ended, and the desk's
        // row and the ingest must agree about which check they describe.
        let runId = ULID.generate()
        active = (generation, runId, pair)
        isPreparingRun = true

        Task { [weak self] in
            await self?.begin(pair: pair, runId: runId, generation: generation,
                              environment: environment)
        }
    }

    /// The run's asynchronous prefix: who is translating, what needs
    /// translating, and the send.
    ///
    /// **The identity is resolved first, and the briefing second.**
    /// `translatorRole(for:)` is find-or-create, and the briefing's role
    /// frame reads the stored row — asked the other way round, the first run
    /// for a language would brief a translator who does not exist yet while
    /// the queries it produced were signed by one who does. The cost of this
    /// order is that a click on a pair with nothing to do still names its
    /// translator; that is the right way round, because pressing Run
    /// translation for a language IS the writer saying this edition has one.
    private func begin(
        pair: Pair, runId: String, generation: Int, environment: Environment
    ) async {
        let identity: (name: String, roleId: String)
        do {
            identity = try await environment.translatorIdentity(pair.language)
        } catch {
            guard runGeneration == generation else { return }
            end(.failed(.run(.sessionDied(
                detail: "the translator's identity could not be resolved: \(error)"))),
                pair: pair, runId: runId)
            return
        }
        guard runGeneration == generation else { return }

        guard let round = await environment.briefRound(pair.docId, pair.language) else {
            // Not a run: the click had nothing to act on, so there is nothing
            // to report and nothing to end.
            guard runGeneration == generation else { return }
            abandon()
            return
        }
        guard runGeneration == generation else { return }
        let inputs = round.inputs

        // **The work-list is this loop's delta.** Nothing stale, nothing
        // missing, no session: spending a subprocess to be told what
        // `TranslationDeriver` already computed is the compiler's
        // empty-delta mistake in another currency. There is no marker to
        // advance here — freshness is the memory (spec §2, "no rounds ring").
        guard !inputs.workList.isEmpty else {
            end(.nothingToTranslate, pair: pair, runId: runId)
            return
        }

        guard let runner = ensureRunner(pair: pair, model: environment.model) else {
            end(.failed(.run(.sessionDied(
                detail: "the translator's bridge config could not be written"))),
                pair: pair, runId: runId)
            return
        }

        isPreparingRun = false
        runState = .running(docId: pair.docId, language: pair.language,
                            translating: inputs.workList.count)

        let event = await runner.send(
            message: TranslatorBriefing.compose(inputs: inputs),
            systemPreamble: Self.sessionSystemPreamble(projectId: environment.projectId))
        await finish(event, pair: pair, runId: runId, identity: identity,
                     briefedSourceHashes: round.sourceHashes, generation: generation)
    }

    // MARK: - The turn coming back

    /// **The one place ingest is reachable from**, and the reason atomicity
    /// is structural: the closure is called inside the `.resultText` arm,
    /// past a successful parse, with a `TranslatorReport` in hand. There is
    /// no path from a death, a timeout, a cancel or unreadable output to the
    /// writer's words.
    ///
    /// `async` because the run is not over until its words are written: a
    /// `runState` that went `.idle` before the ingest landed would tell the
    /// writer the round was finished while its paragraphs were still
    /// arriving.
    private func finish(
        _ event: CompilerRunEvent, pair: Pair, runId: String,
        identity: (name: String, roleId: String),
        briefedSourceHashes: [String: String], generation: Int
    ) async {
        switch event {
        case .started:
            // Unreachable through `send`, which resolves with a terminal
            // event (`CompilerRunner`'s own contract). Named rather than
            // silently ignored.
            return

        case .failed(let failure):
            guard runGeneration == generation else { return }
            // Nothing is written, and nothing needs undoing: the session that
            // died had written nothing either (spec §6, the property Approach
            // A bought). The next click starts the same round over.
            end(failure.isTheWritersOwnDoing ? .cancelled : .failed(.run(failure)),
                pair: pair, runId: runId)

        case .resultText(let text):
            guard let report = TranslatorReport.parse(text) else {
                guard runGeneration == generation else { return }
                // All-or-nothing starts at parse: a turn that got one entry
                // wrong is a model that has lost the contract, and there is
                // no knowing which of its other entries to trust.
                end(.failed(.run(.unusableOutput)), pair: pair, runId: runId)
                return
            }
            guard runGeneration == generation, let environment else { return }

            let outcome = await environment.ingest(
                report,
                IngestContext(docId: pair.docId, language: pair.language, runId: runId,
                              translatorName: identity.name,
                              translatorRoleId: identity.roleId,
                              briefedSourceHashes: briefedSourceHashes))
            // The last suspension, and the only one this class resumes from
            // with writes still to do. A shutdown inside the ingest window
            // has already set the surface idle; resuming afterwards would
            // paint a finished round onto a window that is going away.
            guard runGeneration == generation else { return }
            end(.ingested(outcome), pair: pair, runId: runId)
        }
    }

    /// **Where every run ends** — one site, so the surface and the record
    /// cannot describe the same run differently.
    private func end(_ outcome: RunSummary.Outcome, pair: Pair, runId: String) {
        isPreparingRun = false
        active = nil
        let at = Date()
        switch outcome {
        case .ingested(let ingested):
            // A rejection is the one ingest answer the writer must act on;
            // warnings and counts are the desk's, and ride the summary.
            runState = ingested.rejection.map {
                .failed(docId: pair.docId, language: pair.language,
                        failure: .ingestRejected($0), at: at)
            } ?? .idle
        case .nothingToTranslate:
            runState = .nothingToTranslate(docId: pair.docId, language: pair.language, at: at)
        case .cancelled:
            runState = .idle
        case .failed(let failure):
            runState = .failed(docId: pair.docId, language: pair.language,
                               failure: failure, at: at)
        }
        environment?.onRunEnded(
            RunSummary(runId: runId, docId: pair.docId, language: pair.language,
                       at: at, outcome: outcome))
    }

    /// A run that turned out not to be one. No state, no summary — the click
    /// had nothing to act on, which is not something a desk row should
    /// report.
    private func abandon() {
        isPreparingRun = false
        active = nil
        if case .running = runState { runState = .idle }
    }

    // MARK: - Cancel and shutdown

    /// End the turn in flight. The session stays warm, because the next click
    /// is likely the same pair again.
    ///
    /// **A run can be under way without a turn to end**: between the click
    /// and the send it mints an identity (a manifest write) and gathers a
    /// briefing (a store read and a coverage derivation).
    /// `cancelCurrentRun` guards on the session having a turn, so it no-ops
    /// against exactly that run — Cancel would mean "carry on", and the run
    /// it did not stop would go on to spend a whole turn. So the unsent case
    /// is abandoned here by generation, the way `shutdown()` abandons it, and
    /// the session is left alone because there is nothing of ours in it.
    func cancel() {
        let hasUnsentRun = isRunning && runner?.isRunning != true
        runner?.cancelCurrentRun()
        guard hasUnsentRun, let active else { return }
        runGeneration &+= 1
        end(.cancelled, pair: active.pair, runId: active.runId)
    }

    /// End the session: the window closing, project close, app quit, the AI
    /// toggle going off.
    ///
    /// **Not optional on any of those paths.** See this type's own contract
    /// paragraph: a session merely released outlives the window as a live,
    /// billing process.
    func shutdown() {
        retireSession()
        // A run that has been clicked but has not spawned yet — still minting
        // its identity, still gathering its briefing — has no session for
        // `retireSession` to reach. Abandon it here, or the window closing is
        // followed by the run it was meant to prevent.
        runGeneration &+= 1
        isPreparingRun = false
        active = nil
        // A turn cut short leaves the surface saying "translating" forever
        // otherwise. A REPORTED failure is left alone: the window going away
        // must not erase the row explaining why the last run failed.
        if case .running = runState { runState = .idle }
    }

    /// Shut down and release the window's object graph. Distinct from
    /// `shutdown()` for the compiler's reason: a writer who turns Claude off
    /// and on again must still have a working run verb.
    func detach() {
        shutdown()
        environment = nil
    }

    // MARK: - The session

    /// The warm session, spawned lazily on the first run — and its
    /// `--mcp-config` file, written once per session and deleted with it.
    ///
    /// **Warm per `(docId, language)`, not per window**, which is where this
    /// departs from the compiler. A compiler session reads many documents and
    /// re-briefs each of them under a hash that says what it has already been
    /// told; a translator session has no such discipline and is holding one
    /// edition's voice in its context. Crossing documents or languages inside
    /// one process would carry another edition's register into a round that
    /// never asked for it, so the pair changing retires the session exactly
    /// as a model change does.
    private func ensureRunner(pair: Pair, model: String) -> CompilerRunner? {
        if let runner {
            if runnerPair == pair, runnerModel == model { return runner }
            // Between turns by construction (`runTranslation` guards
            // `!isRunning`), so retiring here costs nothing in flight.
            retireSession()
        }
        guard let environment, let url = try? environment.writeMCPConfig() else {
            return nil
        }
        configURL = url
        let made = environment.makeRunner(url, model)
        runner = made
        runnerModel = model
        runnerPair = pair
        return made
    }

    /// End the current session and drop everything scoped to it, without
    /// touching `runState` — `shutdown()`'s body minus the surface, so a pair
    /// change is invisible to a writer who only sees the words.
    private func retireSession() {
        runner?.shutdown()
        runner = nil
        runnerModel = nil
        runnerPair = nil
        if let configURL {
            try? FileManager.default.removeItem(at: configURL)
        }
        configURL = nil
    }
}
