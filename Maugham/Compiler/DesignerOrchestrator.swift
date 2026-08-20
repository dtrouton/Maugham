import Foundation
import MaughamCore

/// **The design round.** One click arrives here, and Tasks 1–5 are called in
/// order: the briefing over the writer's visual doctrine and what the book
/// actually contains, the warm session, the parse, the staging.
///
/// `TranslatorOrchestrator`'s rails, deliberately: the same closure
/// `Environment` so a round is driven end to end with no project on disk, the
/// same warm-session-with-lazy-spawn shape, the same generation discipline
/// across every suspension, and the same vocabulary for what a run can be.
/// What differs is what a round is FOR — the translator produces words the
/// writer will publish, the designer produces a PROPOSAL the writer stands at
/// a gate and judges — and the two places that follows from are marked below:
/// the session is warm per project rather than per `(docId, language)`, and a
/// round stays OPEN after it ends so `requestChanges` has something to change.
///
/// **It stages through a closure and touches no store.** The report comes
/// back, is parsed, and is handed to `Environment.stage`, whose production
/// implementation (Task 9) writes it into `DesignProposalStore` and kicks off
/// the sample compile. Nothing here holds a `ProjectStore`, a proposal or an
/// editor binding across a subprocess turn (tripwires 3, 6).
///
/// **The spawned session never writes; Maugham writes at staging**, which is
/// what makes atomicity structural rather than careful: `Environment.stage` is
/// reachable from exactly one place in this file — the arm holding a
/// successfully parsed report — so a session that died, timed out, was
/// cancelled or answered gibberish has no path to the writer's `.maugham/`
/// tree at all (spec §6). And nothing here can reach the LIVE templates by any
/// path: a proposal stages beside them and is promoted only by the writer's own
/// approval (Task 8).
/// `DesignerOrchestratorTests.test_aFailedRunStagesNothing` is the guard.
///
/// **No clock starts a round.** The keystroke is the only trigger (ADR 0028's
/// tempo discipline, restated by this milestone's own constitution check);
/// every timer in this area ends a session, and none of them lives here.
/// `test_noClockStartsARoundInThisFile` keeps it that way.
///
/// **The owner must call `shutdown()`.** This is `ClaudeCLISession`'s contract
/// inherited whole, and this type is its third owner. Releasing a live
/// orchestrator does NOT kill its `claude`: `deinit` is nonisolated and cannot
/// touch main-actor state, and deallocating a `Process` neither signals nor
/// reaps the child, so an orchestrator merely released leaves a real, billing,
/// API-calling process running for as long as it survives its closed stdin.
/// Every path that ends a window — window close, project close, app quit, the
/// AI toggle — owns a call to `shutdown()` or `detach()`. A `deinit` here would
/// be a reaper that cannot reach the process it claims to reap, which is why
/// there isn't one.
@Observable @MainActor
final class DesignerOrchestrator {

    /// What the desk says about the last thing a run verb did.
    ///
    /// `TranslatorOrchestrator.RunState`'s vocabulary minus its
    /// `nothingToTranslate`, which has no analogue here: a translation round
    /// can honestly find nothing stale, but there is always a book to design,
    /// so a round that starts always has something to propose. What a round
    /// produced is on the desk as a pending proposal (`DesignProposalStore`),
    /// which is why success returns to `.idle` rather than inventing a state
    /// for it.
    ///
    /// **Every state that describes a run names the round and the edition it
    /// ran for.** The desk shows one design row, but a proposal is for the base
    /// edition or for a language, and a failure that named neither would put a
    /// red line under a round the writer never asked for.
    enum RunState: Equatable {
        case idle
        case running(round: Int, language: String?)
        case failed(failure: Failure, at: Date)
    }

    /// Why a round did not land its proposal.
    ///
    /// Two cases because they fail at different boundaries and a desk row says
    /// different things about them. `run` is everything that went wrong between
    /// the click and a readable report — the compiler's own `CompilerRunFailure`
    /// reused rather than re-spelled, including `unusableOutput` for a turn
    /// `DesignerReport.parse` refused whole. `stagingRejected` is a report that
    /// was read perfectly and could not be written down: a disk that refused the
    /// proposal directory. The second is less serious — the design is still
    /// there to be re-run — and a desk that could not tell them apart would have
    /// to guess which.
    enum Failure: Equatable, Sendable {
        case run(CompilerRunFailure)
        case stagingRejected(String)
    }

    /// What staging is told about the round whose report it is writing.
    ///
    /// **The designer's identity travels here rather than being re-resolved
    /// downstream** — `TranslatorOrchestrator.IngestContext`'s reasoning, with
    /// one guarantee added: `designerName` is read off
    /// `DesignerBriefing.Inputs.designerName`, so the name that signs the
    /// proposal is literally the string the briefing put in front of the model.
    /// A store that resolved it again could sign a proposal in a name the
    /// session was never told it had.
    struct StageContext: Equatable, Sendable {
        /// This round's own id — what the desk row and the record name the same
        /// run by.
        let runId: String
        /// 1 for a fresh design round; `n+1` for the `requestChanges` that
        /// follows round `n`.
        let round: Int
        /// `ProductionRole.effectiveName` for this project's designer.
        let designerName: String
        /// The edition this proposal is for; `nil` is the base (untranslated)
        /// one.
        let language: String?

        init(runId: String, round: Int, designerName: String, language: String?) {
            self.runId = runId
            self.round = round
            self.designerName = designerName
            self.language = language
        }
    }

    /// What staging did with a report.
    ///
    /// **`rejection` is not an error the run threw**: staging cannot fail the
    /// app and its signature says so (no `throws`), because a refused proposal
    /// is a legitimate answer the writer has to see rather than a crash. When it
    /// is non-nil nothing was staged, and this orchestrator turns it into a
    /// `failed` state carrying the sentence.
    ///
    /// **`sample` is advisory and never blocks** (spec §6): sample pages that
    /// would not compile are shown at the gate WITH their tectonic error, beside
    /// a spec the writer can still read, reject, or ask changes to. A run whose
    /// samples failed is not a failed run — it is a proposal with something
    /// wrong in it, which is exactly what the gate is for. The store's own type
    /// is carried rather than re-spelled: two vocabularies for one compile
    /// outcome is one reword away from a gate that cannot recognise the result
    /// it was handed.
    struct StageOutcome: Equatable, Sendable {
        /// The proposal that now exists on disk, or `nil` when none does. What
        /// makes the round OPEN — see `hasOpenProposalRound`.
        let proposalId: String?
        let filesStaged: Int
        let sample: DesignProposalStore.SampleResult?
        let rejection: String?

        init(proposalId: String? = nil, filesStaged: Int = 0,
             sample: DesignProposalStore.SampleResult? = nil, rejection: String? = nil) {
            self.proposalId = proposalId
            self.filesStaged = filesStaged
            self.sample = sample
            self.rejection = rejection
        }
    }

    /// One finished round, for whoever keeps the record (P4's desk).
    ///
    /// Emitted exactly once for every run that STARTED — including the one the
    /// writer cancelled — and never for a click that was refused or had nothing
    /// to act on, because a spinner nothing closes is worse than a row that says
    /// "cancelled".
    struct RunSummary: Equatable, Sendable {
        let runId: String
        let round: Int
        let language: String?
        let at: Date
        let outcome: Outcome

        enum Outcome: Equatable, Sendable {
            /// A report came back, parsed, and was handed to staging. The value
            /// says what became of it, `rejection` included: the summary is the
            /// record and loses nothing, while `runState` above is the surface
            /// and says only whether the writer needs to look.
            case staged(StageOutcome)
            /// The writer's own act — Cancel, the window closing, the toggle
            /// going off. Not a failure and never drawn as one.
            case cancelled
            case failed(Failure)
        }

        init(runId: String, round: Int, language: String?, at: Date, outcome: Outcome) {
            self.runId = runId
            self.round = round
            self.language = language
            self.at = at
            self.outcome = outcome
        }
    }

    /// Everything the round needs from the window it belongs to. Closures
    /// rather than stores, so a round is driven with no project on disk and so
    /// `detach()` drops the window's whole object graph in one line. Every
    /// closure is `@MainActor`: the stores they reach are, and an isolation hop
    /// between the click and the gather would let the writer type in the gap.
    struct Environment {
        var projectId: String
        /// The model a round is spawned against — the compiler's setting, so a
        /// writer who chose a deeper model for their checks gets it for their
        /// design too. Defaulted to the compiler's own constant rather than a
        /// second literal.
        var model: String = CompilerOrchestrator.defaultModel
        /// `(direction, language)` → everything one briefing needs, **including
        /// the designer's name**, or `nil` when this project cannot be designed
        /// for at all (no publish posture, no AST to census). `nil` is not an
        /// error and not a run — the compiler's `reading(docId) == nil` guard,
        /// in this currency.
        ///
        /// **It reads the designer, it does not mint one.** `designerRole()` is
        /// a read by construction (`ProjectStore+ProductionRoles`' own rule: the
        /// preset lives in the merge, not on disk), so unlike the translator's
        /// loop there is no identity closure here and no mint to order the
        /// gather against — the name arrives inside `Inputs`, which is also the
        /// only place it is spelled.
        var briefRound: @MainActor (String?, String?) async -> DesignerBriefing.Inputs?
        /// Writes the per-session `--mcp-config` file and returns its path. The
        /// orchestrator owns the file's life from here (`ensureRunner`).
        var writeMCPConfig: @MainActor () throws -> URL
        /// `(configPath, model)` → the session. The model is passed rather than
        /// captured so `model` above is the only place it is decided.
        var makeRunner: @MainActor (URL, String) -> CompilerRunner
        /// **Where the proposal actually lands**, and the only writing this loop
        /// does. Task 9 stages it through `DesignProposalStore` and kicks off the
        /// sample compile; nothing live is touched until the writer approves
        /// (Task 8).
        ///
        /// It cannot fail the run and its signature says so: no `throws`, an
        /// outcome rather than a result. A proposal the store refuses comes back
        /// as `StageOutcome.rejection` — a thing the writer is told, not a thing
        /// that throws past them.
        var stage: @MainActor (DesignerReport, StageContext) async -> StageOutcome
        /// One finished round, for the record. See `RunSummary`.
        var onRunEnded: @MainActor (RunSummary) -> Void
    }

    // MARK: - The session preamble

    /// What governs the SESSION rather than the round.
    ///
    /// Deliberately says nothing about who the designer is, what the book looks
    /// like, or what the report must contain: all three live in
    /// `DesignerBriefing.compose`, which runs every fresh round, and a second
    /// spelling here would be one the writer's own doctrine could drift away
    /// from. What is left is what a system prompt is actually for — the
    /// session's shape, and the project the bridge's read tools are scoped to.
    static func sessionSystemPreamble(projectId: String) -> String {
        """
        You are the book designer for a manuscript-in-progress, working for the \
        writer who is still writing it. Every message names the designer you \
        are, the writer's declared look, what the book actually contains and \
        what this round asks for — read that frame each time rather than \
        assuming it carries over, because the writer can change any of it \
        between rounds.

        This session is long-lived: the writer reviews each proposal on sample \
        pages and may come back asking for changes to the one you just made, so \
        keep track of what you have proposed here. You never write to the live \
        template set and you will not see your files installed — you answer \
        with a report, Maugham stages it, and nothing reaches the book until \
        the writer approves it.

        Project: \(projectId)
        """
    }

    /// The follow-up turn: the writer's words, and the contract restated by
    /// reference so a second round cannot drift off the wire shape.
    ///
    /// **Short on purpose.** The doctrine, the census, the live templates and
    /// the sample plan are already in this session's context from the round
    /// being changed; re-briefing them would be telling the model what it is
    /// looking at, and would make a "change" round indistinguishable from a
    /// fresh one.
    static func changeRequestMessage(feedback: String) -> String {
        """
        The writer has reviewed your proposal and asks for changes:

        \(MarkdownDisplayFilter.stripAnchors(feedback))

        Answer with a revised proposal — the whole of it, files included, not a \
        diff against what you sent last time.

        \(DesignerReport.schemaDescription)
        """
    }

    // MARK: - State

    private(set) var runState: RunState = .idle

    private var environment: Environment?
    private var runner: CompilerRunner?
    private var configURL: URL?
    /// The model `runner` was **spawned** for. A spawn fact rather than a
    /// setting — `--model` is an argument — so this is what `ensureRunner`
    /// compares against.
    ///
    /// **There is no pair beside it, and that is the divergence from
    /// `TranslatorOrchestrator`.** See `ensureRunner`.
    private var runnerModel: String?

    /// True between the click and the send, while the briefing is gathered.
    /// `isRunning` counts it, so the second click of a double-click is refused
    /// there exactly as it is mid-turn — the window is short, but two rounds are
    /// two sessions' worth of work over one book.
    private var isPreparingRun = false

    /// The generation a round's suspensions belong to. A teardown between the
    /// click and the send **abandons** the round rather than letting it spawn a
    /// session the writer has just closed the window on; a boolean cleared and
    /// re-set by the next click could not tell the two apart. Same reasoning as
    /// `ClaudeCLISession.generation` (AREA.md, "generations, not booleans"). Two
    /// suspensions carry it: the briefing gather and the staging.
    private var runGeneration = 0

    /// The round in flight, or `nil` between rounds — kept so a cancel arriving
    /// before the send can still name the run it ended.
    private var active: (generation: Int, runId: String, round: Int, language: String?)?

    /// The proposal this session has made and is still able to revise.
    ///
    /// `epoch` is the load-bearing field. `ClaudeCLISession` respawns silently
    /// after a timeout, a cancel or an idle expiry, and a fresh process asked to
    /// revise "your proposal" has never made one — it would invent a revision of
    /// nothing. `CompilerRunner.sessionEpoch` is what tells "the process that
    /// heard my proposal" from "one that replaced it", which is exactly the
    /// question this field asks.
    private struct OpenRound {
        let round: Int
        let proposalId: String
        let designerName: String
        let language: String?
        let epoch: Int
    }

    private var openRound: OpenRound?

    var isRunning: Bool {
        if isPreparingRun { return true }
        if case .running = runState { return true }
        return false
    }

    /// Whether there is a proposal on the desk that the session which made it
    /// can still be asked to revise. P4's gate reads this to decide whether
    /// Request changes is a live control — a refusal a writer can see coming
    /// beats a button that does nothing.
    var hasOpenProposalRound: Bool {
        guard let openRound, let runner else { return false }
        return runner.sessionEpoch == openRound.epoch
    }

    /// Wire the orchestrator to its window. Called where the stores exist —
    /// never from a `body`.
    func configure(environment: Environment) {
        self.environment = environment
    }

    /// Change the model rounds are spawned against.
    ///
    /// Setting this is not enough on its own, and that is why the retirement
    /// lives in `ensureRunner`: the model is a spawn argument, so a warm session
    /// was built with the old one and will keep answering in it. The stale
    /// session is retired lazily, at the next FRESH round, so a change made
    /// mid-line never kills the round in flight and never orphans a proposal the
    /// writer is still iterating on — `requestChanges` deliberately does not
    /// consult it, because a follow-up is only meaningful to the process that
    /// heard the proposal.
    func updateModel(_ model: String) {
        environment?.model = model
    }

    // MARK: - The two entries

    /// Run a fresh design round, optionally with the writer's words for it and
    /// the edition it is for.
    ///
    /// Refuses quietly in the two cases where the honest thing to do is nothing:
    /// a round already in flight (one session per orchestrator; a second round
    /// is what the next click is for), and a project the window cannot brief at
    /// all.
    func runDesign(direction: String? = nil, language: String? = nil) {
        guard let environment, !isRunning else { return }

        runGeneration &+= 1
        let generation = runGeneration
        // Minted at the click rather than when an answer lands: a cancel before
        // the send still has to name the run it ended, and the desk's row and
        // the staging must agree about which round they describe.
        let runId = ULID.generate()
        active = (generation, runId, 1, language)
        isPreparingRun = true

        Task { [weak self] in
            await self?.begin(direction: direction, language: language,
                              runId: runId, generation: generation,
                              environment: environment)
        }
    }

    /// **The gate's iterate arm.** Feed the writer's words back into the SAME
    /// warm session and take the next round of the same proposal line.
    ///
    /// Refused — visibly, so a surface can say why — in four cases: no
    /// environment, a run already in flight, no words to act on, and no open
    /// round. That last one covers more than "nothing has run yet": a round
    /// whose report failed staged no proposal, and a session that respawned
    /// behind the seam is not the one that heard it. In every one of those the
    /// honest verb for the writer is Run again with their words as the round's
    /// direction, which is what `runDesign(direction:)` is.
    @discardableResult
    func requestChanges(_ feedback: String) -> Bool {
        let words = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let environment, !isRunning, !words.isEmpty,
              hasOpenProposalRound, let open = openRound, let runner
        else { return false }

        runGeneration &+= 1
        let generation = runGeneration
        let runId = ULID.generate()
        let round = open.round + 1
        active = (generation, runId, round, open.language)
        runState = .running(round: round, language: open.language)

        let context = StageContext(runId: runId, round: round,
                                   designerName: open.designerName,
                                   language: open.language)
        Task { [weak self] in
            let event = await runner.send(
                message: Self.changeRequestMessage(feedback: words),
                systemPreamble: Self.sessionSystemPreamble(
                    projectId: environment.projectId))
            await self?.finish(event, context: context, generation: generation)
        }
        return true
    }

    /// The round's asynchronous prefix: what the book looks like, what it
    /// contains, and the send.
    private func begin(
        direction: String?, language: String?, runId: String, generation: Int,
        environment: Environment
    ) async {
        guard let inputs = await environment.briefRound(direction, language) else {
            // Not a run: the click had nothing to act on, so there is nothing to
            // report and nothing to end.
            guard runGeneration == generation else { return }
            abandon()
            return
        }
        guard runGeneration == generation else { return }

        guard let runner = ensureRunner(model: environment.model) else {
            end(.failed(.run(.sessionDied(
                detail: "the designer's bridge config could not be written"))),
                runId: runId, round: 1, language: language)
            return
        }

        isPreparingRun = false
        runState = .running(round: 1, language: language)

        let context = StageContext(runId: runId, round: 1,
                                   designerName: inputs.designerName, language: language)
        let event = await runner.send(
            message: DesignerBriefing.compose(inputs: inputs),
            systemPreamble: Self.sessionSystemPreamble(projectId: environment.projectId))
        await finish(event, context: context, generation: generation)
    }

    // MARK: - The turn coming back

    /// **The one place staging is reachable from**, and the reason atomicity is
    /// structural: the closure is called inside the `.resultText` arm, past a
    /// successful parse, with a `DesignerReport` in hand. There is no path from
    /// a death, a timeout, a cancel or unreadable output to the writer's
    /// `.maugham/` tree.
    ///
    /// `async` because the round is not over until its proposal is written: a
    /// `runState` that went `.idle` before staging landed would tell the writer
    /// the round was finished while its files were still arriving.
    private func finish(
        _ event: CompilerRunEvent, context: StageContext, generation: Int
    ) async {
        switch event {
        case .started:
            // Unreachable through `send`, which resolves with a terminal event
            // (`CompilerRunner`'s own contract). Named rather than silently
            // ignored.
            return

        case .failed(let failure):
            guard runGeneration == generation else { return }
            // Nothing is staged, and nothing needs undoing: the session that
            // died had written nothing either (spec §6, the property Approach A
            // bought). The next click starts the same round over.
            end(failure.isTheWritersOwnDoing ? .cancelled : .failed(.run(failure)),
                runId: context.runId, round: context.round, language: context.language)

        case .resultText(let text):
            guard let report = DesignerReport.parse(text) else {
                guard runGeneration == generation else { return }
                // All-or-nothing starts at parse: a turn that got one path wrong
                // is a model that has lost the contract, and there is no knowing
                // which of its other files to trust.
                end(.failed(.run(.unusableOutput)), runId: context.runId,
                    round: context.round, language: context.language)
                return
            }
            guard runGeneration == generation, let environment else { return }

            let outcome = await environment.stage(report, context)
            // The last suspension, and the only one this class resumes from with
            // writes still to do. A shutdown inside the staging window has
            // already set the surface idle; resuming afterwards would paint a
            // finished round onto a window that is going away.
            guard runGeneration == generation else { return }
            // **The round opens exactly where a proposal exists** — same arm as
            // the stage call, so there is no reachable state in which the writer
            // is offered Request changes over a proposal that was refused.
            if outcome.rejection == nil, let proposalId = outcome.proposalId {
                openRound = OpenRound(round: context.round, proposalId: proposalId,
                                      designerName: context.designerName,
                                      language: context.language,
                                      epoch: runner?.sessionEpoch ?? 0)
            }
            end(.staged(outcome), runId: context.runId, round: context.round,
                language: context.language)
        }
    }

    /// **Where every round ends** — one site, so the surface and the record
    /// cannot describe the same round differently.
    private func end(
        _ outcome: RunSummary.Outcome, runId: String, round: Int, language: String?
    ) {
        isPreparingRun = false
        active = nil
        let at = Date()
        switch outcome {
        case .staged(let staged):
            // A rejection is the one staging answer the writer must act on; the
            // sample result and the counts are the desk's, and ride the summary.
            runState = staged.rejection.map {
                .failed(failure: .stagingRejected($0), at: at)
            } ?? .idle
        case .cancelled:
            runState = .idle
        case .failed(let failure):
            runState = .failed(failure: failure, at: at)
        }
        environment?.onRunEnded(
            RunSummary(runId: runId, round: round, language: language, at: at,
                       outcome: outcome))
    }

    /// A round that turned out not to be one. No state, no summary — the click
    /// had nothing to act on, which is not something a desk row should report.
    private func abandon() {
        isPreparingRun = false
        active = nil
        if case .running = runState { runState = .idle }
    }

    // MARK: - Cancel and shutdown

    /// End the turn in flight. The session stays warm, and an open round stays
    /// open: a cancelled follow-up leaves the proposal exactly where it was, and
    /// the writer can ask again.
    ///
    /// **A round can be under way without a turn to end**: between the click and
    /// the send it gathers a briefing (a store read, an AST build, a directory
    /// walk). `cancelCurrentRun` guards on the session having a turn, so it
    /// no-ops against exactly that round — Cancel would mean "carry on", and the
    /// round it did not stop would go on to spend a whole turn. So the unsent
    /// case is abandoned here by generation, the way `shutdown()` abandons it,
    /// and the session is left alone because there is nothing of ours in it.
    func cancel() {
        let hasUnsentRun = isRunning && runner?.isRunning != true
        runner?.cancelCurrentRun()
        guard hasUnsentRun, let active else { return }
        runGeneration &+= 1
        end(.cancelled, runId: active.runId, round: active.round, language: active.language)
    }

    /// End the session: the window closing, project close, app quit, the AI
    /// toggle going off.
    ///
    /// **Not optional on any of those paths.** See this type's own contract
    /// paragraph: a session merely released outlives the window as a live,
    /// billing process.
    func shutdown() {
        retireSession()
        // A round that has been clicked but has not spawned yet — still
        // gathering its briefing — has no session for `retireSession` to reach.
        // Abandon it here, or the window closing is followed by the round it was
        // meant to prevent.
        runGeneration &+= 1
        isPreparingRun = false
        active = nil
        // A turn cut short leaves the surface saying "designing" forever
        // otherwise. A REPORTED failure is left alone: the window going away
        // must not erase the row explaining why the last round failed.
        if case .running = runState { runState = .idle }
    }

    /// Shut down and release the window's object graph. Distinct from
    /// `shutdown()` for the compiler's reason: a writer who turns Claude off and
    /// on again must still have a working run verb.
    func detach() {
        shutdown()
        environment = nil
    }

    // MARK: - The session

    /// The warm session, spawned lazily on the first round — and its
    /// `--mcp-config` file, written once per session and deleted with it.
    ///
    /// **Warm per project, and this is where it departs from
    /// `TranslatorOrchestrator`**, which retires its session whenever the
    /// `(docId, language)` pair changes. Two reasons it would be wrong here.
    /// First, there is nothing to key on: a designer round has no document, and
    /// a design is the whole book's — a round for the Spanish edition is still
    /// about the same pages, so nothing foreign is carried across the way
    /// another edition's register would be. Second, and decisive:
    /// `requestChanges` is a follow-up on the proposal this process just made,
    /// so retiring the session between rounds would throw away the only thing
    /// the writer's words could be about. The session outlives every round and
    /// is retired by a model change or a `shutdown()`, nothing else.
    private func ensureRunner(model: String) -> CompilerRunner? {
        if let runner {
            if runnerModel == model { return runner }
            // Between turns by construction (`runDesign` guards `!isRunning`),
            // so retiring here costs nothing in flight.
            retireSession()
        }
        guard let environment, let url = try? environment.writeMCPConfig() else {
            return nil
        }
        configURL = url
        let made = environment.makeRunner(url, model)
        runner = made
        runnerModel = model
        return made
    }

    /// End the current session and drop everything scoped to it, without
    /// touching `runState` — `shutdown()`'s body minus the surface.
    ///
    /// **The open round is scoped to the session and goes with it.** The
    /// proposal itself stays on disk, listed and reviewable; what ends is this
    /// process's ability to revise it, which is what `requestChanges` needs and
    /// what `hasOpenProposalRound` answers.
    private func retireSession() {
        runner?.shutdown()
        runner = nil
        runnerModel = nil
        openRound = nil
        if let configURL {
            try? FileManager.default.removeItem(at: configURL)
        }
        configURL = nil
    }
}
