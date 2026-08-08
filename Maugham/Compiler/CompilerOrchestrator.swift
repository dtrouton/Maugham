import Foundation
import MaughamCore

/// **The run.** One keystroke arrives here, and everything Tasks 1–6 built is
/// called in order: the delta against the last-run marker, the prompt, the warm
/// session, the parse, the store.
///
/// Owned by `ProjectWindow` — the `CanvasModel` pattern — because the pane that
/// shows the notes lives in the right-hand column and must read the same run
/// state the centre column's keystroke started. One orchestrator per window;
/// one session per orchestrator.
///
/// **It reads the editor and never writes to it.** What a run needs off the
/// live `Document` arrives as a `DocumentReading` value captured at the
/// keystroke, and the ingest reads paragraph text back through a closure.
/// Nothing here holds an editor binding or a `Document` (tripwires 3, 6).
@Observable @MainActor
final class CompilerOrchestrator {

    /// What the surface says about the last thing the run key did.
    ///
    /// `nothingNew` is an idle state, not a failure: the key worked, the delta
    /// was empty, and there is nothing to report. It is separate from `idle` so
    /// the pane can say which of the two it is — a writer who presses ⌘R and
    /// sees the previous run's notes unchanged has no way to tell "checked,
    /// nothing new" from "the key did nothing".
    ///
    /// **Every state that describes a run names the document it ran on.** The
    /// surface is per-document and this state is per-window, so a case without
    /// a `docId` is a claim with nowhere to check it against: ⌘R on chapter 1
    /// reports "nothing new", the writer clicks chapter 2, and chapter 2's
    /// header says the compiler found nothing new in a document it never read —
    /// indefinitely, since the state only moves on the next run. A failure is
    /// the same defect with a red line painted over another document's
    /// perfectly good notes. `.idle` carries none because it claims nothing.
    enum RunState: Equatable {
        case idle
        case running(docId: String)
        case nothingNew(docId: String, at: Date)
        case failed(docId: String, failure: CompilerRunFailure, at: Date)
    }

    /// What one run reads off the live `Document`, captured at the keystroke.
    ///
    /// A value rather than the `Document` itself: the run is asynchronous, and
    /// holding the editor's own state across a subprocess turn is the shape
    /// tripwires 3 and 6 exist about. `sequence` is authoritative for order.
    struct DocumentReading: Equatable {
        let ops: [Op]
        let paragraphs: [String: String]
        let sequence: [String]

        init(ops: [Op], paragraphs: [String: String], sequence: [String]) {
            self.ops = ops
            self.paragraphs = paragraphs
            self.sequence = sequence
        }
    }

    /// What a run is checked against, resolved at the keystroke.
    ///
    /// **The statement WHOLE, and the key its reading is cached under.** Two
    /// fields because the two halves are read by different things and must not
    /// be re-derived apart: the derivation reads all of it (the rulings are
    /// half of what there is to derive), the briefing embeds only its essay,
    /// and the cache is keyed by the scope — spelled by `DeclaredWorldStore`
    /// itself rather than rebuilt here, because two spellings are two caches
    /// and one of them is never hit.
    struct IntentBriefing: Equatable, Sendable {
        let statementText: String
        let scopeKey: String

        init(statementText: String, scopeKey: String) {
            self.statementText = statementText
            self.scopeKey = scopeKey
        }
    }

    /// Everything the orchestrator needs from the window it belongs to. Closures
    /// rather than stores, so a test drives a run without a project on disk and
    /// so `detach()` can drop the window's whole object graph in one line.
    /// Every closure is `@MainActor`: the stores they read are, the run itself
    /// is, and an isolation hop between the keystroke and the delta would let
    /// the writer type in the gap.
    struct Environment {
        var projectId: String
        /// The model each run is spawned against.
        var model: String
        /// **Bring the document up to date before `reading` is asked.** Awaited
        /// at the top of every run: freshly typed prose lives in the
        /// `PendingBuffer` until a pause closes the burst, so a snapshot taken
        /// at the keystroke omits the very sentences the writer pressed ⌘R
        /// about. Production closes the burst here.
        ///
        /// Not throwing, deliberately. Whatever it could not do, the run still
        /// happens on the snapshot as it stands — the words themselves are the
        /// op log's problem, not the compiler's, and a stale delta checks real
        /// prose where a refused run checks none.
        var prepareForRun: @MainActor (String) async -> Void
        /// The live document for a docId, or `nil` when the window's subject is
        /// not a manuscript document. Read AFTER `prepareForRun`.
        var reading: @MainActor (String) -> DocumentReading?
        /// `(docId, paragraphId)` → the paragraph's text **now**. Read at
        /// ingest, which is what makes `DiagnosticsStore.live`'s exact-match
        /// staleness rule correct.
        var liveParagraphText: @MainActor (String, String) -> String?
        /// The intent this document answers to, piece-first. `nil` is a valid
        /// answer and mints nothing (M1A's rule): the run proceeds with nothing
        /// declared, and the conformance section simply has nothing to check.
        var intent: @MainActor (String) -> IntentBriefing?
        /// The reading already held for this statement's EXACT text, or `nil`
        /// for a miss. Pure — it never derives and never spawns, which is what
        /// lets the run tell a hit from a miss before deciding to spend a
        /// subprocess.
        var cachedWorld: @MainActor (IntentBriefing) -> DerivedWorld?
        /// Derive a reading of this statement and cache it, on the model given
        /// — passed rather than captured, for `makeRunner`'s reason: `model`
        /// above is the one place it is decided.
        ///
        /// **The lazy trigger's other half** (`AREA.md`, "the derivation
        /// trigger"): called only on a miss, only from here, and never on a
        /// timer. `nil` is honest and non-fatal — a missing CLI, the toggle
        /// off, unreadable output — and costs the run its clauses, not the run.
        var deriveWorld: @MainActor (IntentBriefing, String) async -> DerivedWorld?
        /// What the ledger already believes about the subjects this delta's
        /// prose names (spec §5: "a run about Kelly's scene carries Kelly's
        /// facts, not the ledger"). The matching rule lives at the production
        /// call site, which is the only thing that knows the ledger.
        var bibleSlice: @MainActor (String) -> [BibleFact]
        /// What this run established, on its way into the bible. Never a note:
        /// a fact-candidate lands silently and surfaces in the Intent pane's
        /// bible stratum, where the writer's three actions reach it.
        var recordFacts: @MainActor ([BibleFact]) -> Void
        /// What the writer pinned beside this document — linked research
        /// unioned with the canvas cluster (`PinnedReferences`, §7.2) — as
        /// "title (id) — tool" lines. Empty is a valid answer (nothing
        /// pinned, or the Plan side never opened); `CompilerPrompt` omits the
        /// whole section rather than showing nothing.
        var pinnedListing: @MainActor (String) -> [String]
        /// Every card in the project's palette, "title (id)" — independent
        /// of the document, because the palette is project-wide vocabulary
        /// rather than something pinned per-piece.
        var paletteListing: @MainActor () -> [String]
        /// Writes the per-session `--mcp-config` file and returns its path. The
        /// orchestrator owns the file's life from here (see `ensureRunner`).
        var writeMCPConfig: @MainActor () throws -> URL
        /// `(configPath, model)` → the session. The model is passed rather than
        /// captured so `model` above is the only place it is decided; a second
        /// spelling inside this closure is what the run record and the
        /// subprocess would disagree about.
        var makeRunner: @MainActor (URL, String) -> CompilerRunner
        /// The acknowledgment flash. Called synchronously with the keystroke.
        var onRunAcknowledged: @MainActor () -> Void
    }

    /// The model a run uses before the Diagnostics pane's gear-menu setting
    /// has ever been read — a fresh project, or a `UIState` written before
    /// `compilerModel` existed. Sonnet is the spec's default (§3.5).
    ///
    /// `nonisolated` because `Environment.production` uses it as a **default
    /// argument**, which is evaluated in the caller's context rather than this
    /// type's: main-actor isolation on a constant string bought nothing and was
    /// a Swift 6 error waiting at that call site. The diagnostic had been there
    /// since the gear menu landed and was invisible in every warm build that
    /// did not recompile that file (CLAUDE.md's warning-census caveat, met in
    /// the wild).
    nonisolated static let defaultModel = "sonnet"

    private(set) var runState: RunState = .idle
    private(set) var diagnostics: DiagnosticsStore?

    private var environment: Environment?
    private var runner: CompilerRunner?
    private var configURL: URL?
    /// The model `runner` was **spawned** against. Kept beside the session
    /// because `--model` is a spawn argument (`ClaudeCLISession.arguments`) —
    /// a warm process cannot be retuned, so this is what `ensureRunner` compares
    /// the current setting to.
    private var runnerModel: String?

    /// Per document: the briefing hash the last successful run sent, and the
    /// session epoch it was sent into. Both halves matter — see `previousHash`.
    ///
    /// The hash covers essay + derived world + bible slice as one unit
    /// (`CompilerPrompt.runMessageV2`), widened from v1's intent-only hash: a
    /// briefing that came apart — the essay elided while the facts re-embedded
    /// — would describe a world the session was never told half of.
    private var sentBriefing: [String: (hash: String, epoch: Int)] = [:]

    /// True between the keystroke and the delta, while `prepareForRun` closes
    /// the writer's burst. `isRunning` counts it, so the second ⌘R of a
    /// double-press is refused there exactly as it is mid-turn — the window is
    /// short, but two runs on one document are two sessions' worth of work and
    /// one of them would be reading a delta the other has already claimed.
    private var isPreparingRun = false

    /// The generation a run's suspensions belong to. A teardown between the
    /// keystroke and the send **abandons** the run rather than letting it spawn
    /// a session the writer has just switched off; a boolean cleared and re-set
    /// by the next keystroke could not tell the two apart. Same reasoning as
    /// `ClaudeCLISession.generation` (AREA.md, "generations, not booleans").
    ///
    /// **Two hops carry it, not one.** The burst flush was the first; the
    /// declared world's derivation is the second, and it is the longer of the
    /// two by orders of magnitude — a whole `claude -p` process. A run that
    /// checked its generation before deriving and not after would spawn the
    /// session a toggle-off was there to prevent, seconds later.
    private var runGeneration = 0

    var isRunning: Bool {
        if isPreparingRun { return true }
        if case .running = runState { return true }
        return false
    }

    /// Wire the orchestrator to its window. Called from `ProjectWindow.load()`,
    /// where the stores exist — never from a `body`.
    func configure(environment: Environment, diagnostics: DiagnosticsStore) {
        self.environment = environment
        self.diagnostics = diagnostics
    }

    /// Change the model runs are spawned against — the Diagnostics pane's gear
    /// menu (Task 8).
    ///
    /// **Setting this is not enough on its own, and that is why the retirement
    /// lives in `ensureRunner` rather than here.** The model is a spawn
    /// argument, so the warm session already running was built with the old one
    /// and will keep answering in it however many times the setting is changed.
    /// The stale session is retired lazily, at the next run, so choosing Deep
    /// mid-check never kills the check in flight — the writer gets the answer
    /// they are waiting for, and the run after it is the one that changes.
    func updateModel(_ model: String) {
        environment?.model = model
    }

    // MARK: - The one entry

    /// The run key. Builds the delta, assembles the prompt, sends it, ingests
    /// the answer — and refuses, quietly, in the two cases where the honest
    /// thing to do is nothing.
    func runRequested(docId: String) {
        guard let environment, diagnostics != nil else { return }
        // A run already in flight. Quiet on purpose: the pane header is already
        // saying what is happening, and there is one session per window, so a
        // second turn is not something to queue — it is something the next
        // keystroke can do.
        guard !isRunning else { return }
        // No document under the window's subject — the project row, or nothing
        // selected. Not an error, not a run, and nothing to acknowledge: the
        // key had nothing to act on. Asked here only for that answer; the
        // reading the delta is built from is taken below, after the burst.
        guard environment.reading(docId) != nil else { return }

        // Synchronous with the keystroke, and deliberately ahead of the hop
        // below: the flash is ⌘S's muscle-memory acknowledgment, not a progress
        // indicator, and one that waited on a disk write would be neither.
        environment.onRunAcknowledged()

        // **The burst first, the delta second.** The writer's last sentences
        // are in the `PendingBuffer` until a pause closes the burst, so a
        // reading taken now is a document that predates the keystroke that
        // asked about it — measured in the field as a 14-paragraph chunk
        // reported as "0 new, 1 revised". The wet ink is what the compiler is
        // for (spec §3.2). Nothing here touches the editor's binding: the
        // document closes its own burst and we take a value afterwards
        // (tripwires 3, 6).
        runGeneration &+= 1
        let generation = runGeneration
        isPreparingRun = true
        Task { [weak self] in
            await environment.prepareForRun(docId)
            guard let self, self.runGeneration == generation else { return }
            self.isPreparingRun = false
            // Re-asked after the hop: the window can have closed, Claude can
            // have been switched off, and the writer can have moved the
            // selection off a document entirely while the burst was landing.
            guard let environment = self.environment,
                  let diagnostics = self.diagnostics,
                  let reading = environment.reading(docId) else { return }
            self.beginRun(docId: docId, reading: reading, generation: generation,
                          environment: environment, diagnostics: diagnostics)
        }
    }

    /// The run proper, from the delta on — everything that was `runRequested`'s
    /// body before the burst-flush hop moved in above it.
    private func beginRun(
        docId: String, reading: DocumentReading, generation: Int,
        environment: Environment, diagnostics: DiagnosticsStore
    ) {
        let marker = diagnostics.lastOpId(docId: docId)
        let delta = DeltaBuilder.delta(
            ops: reading.ops, since: marker,
            currentParagraphs: reading.paragraphs, sequence: reading.sequence)

        guard !delta.isEmpty else {
            // Ops may still have landed that changed no prose. Passing them
            // costs nothing and saves every later run from re-reading them.
            if let newest = delta.newestOpId {
                diagnostics.advanceMarker(to: newest, docId: docId)
            }
            runState = .nothingNew(docId: docId, at: Date())
            return
        }

        let briefing = environment.intent(docId)
        // The essay half alone (spec §3.2). **This is the atomic switch**: the
        // strata below the essay reach the run as the derived clauses resolved
        // below, and briefing them as prose as well would put the same
        // declaration in front of the model twice — see
        // `CompilerRunCommandTests.test_rulingsAreBriefedAsClausesNotProse`.
        let essay = briefing.map { StatementEssay.half(of: $0.statementText) }
        // Empty is a real answer (nothing pinned, no palette cards); the prompt
        // omits an empty section by design, so this is a smaller prompt rather
        // than a broken one. Read here, at the keystroke's own moment, so the
        // context and the delta describe one instant of the project.
        let pinnedListing = environment.pinnedListing(docId)
        let paletteListing = environment.paletteListing()
        let bibleFacts = environment.bibleSlice(Self.prose(of: delta))

        guard let runner = ensureRunner(model: environment.model) else {
            runState = .failed(
                docId: docId,
                failure: .sessionDied(
                    detail: "the compiler's bridge config could not be written"),
                at: Date())
            return
        }

        let preamble = CompilerPrompt.sessionSystemPreamble(projectId: environment.projectId)
        let model = environment.model

        // Set before the derivation, not after it: deriving is a subprocess,
        // and a window that said `idle` for the seconds it takes would take a
        // second ⌘R and run the same delta twice.
        runState = .running(docId: docId)
        Task { [weak self] in
            let world = await Self.resolveWorld(briefing, model: model, in: environment)
            // The derivation is the run's second suspension, and everything the
            // burst-flush hop can lose in its own window can be lost in this
            // one — only over seconds rather than milliseconds.
            guard let self, self.runGeneration == generation else { return }

            // Elided only while the SAME process is still reading — see
            // `CompilerRunner.sessionEpoch`. Asked after the derivation because
            // the session can have been retired while it ran, and a fresh
            // process has read nothing.
            let previousHash = self.sentBriefing[docId].flatMap {
                $0.epoch == runner.sessionEpoch ? $0.hash : nil
            }
            let (message, briefingHash) = CompilerPrompt.runMessageV2(
                delta: delta, world: world, essay: essay, bibleFacts: bibleFacts,
                paletteListing: paletteListing, pinnedListing: pinnedListing,
                previousBriefingHash: previousHash)
            let event = await runner.send(message: message, systemPreamble: preamble)
            self.finish(event, docId: docId, delta: delta, marker: marker,
                        intentSnapshot: briefing?.statementText,
                        briefingHash: briefingHash, model: model)
        }
    }

    /// The declared world for this run: the cached reading if one was made from
    /// exactly this text, else one derived now and cached by the closure that
    /// derived it.
    ///
    /// **The lazy trigger, and its only production site** (`AREA.md`, "the
    /// derivation trigger"): nothing here runs on a timer or on a save. A
    /// statement is edited for reasons that have nothing to do with a check
    /// being imminent, and a derivation per edit would spawn `claude` for prose
    /// nobody is about to compile against.
    ///
    /// `nil` at either step is honest and non-fatal — no statement at all, a
    /// missing CLI, the toggle switched off, output that could not be read. The
    /// run proceeds on the essay alone and the conformance section has nothing
    /// to check, which the schema tolerates (an empty `checks` array). A run
    /// that refused over a missing convenience would be the compiler holding
    /// the writer's ⌘R hostage to a subprocess.
    private static func resolveWorld(
        _ briefing: IntentBriefing?, model: String, in environment: Environment
    ) async -> DerivedWorld? {
        guard let briefing else { return nil }
        if let cached = environment.cachedWorld(briefing) { return cached }
        return await environment.deriveWorld(briefing, model)
    }

    /// The delta's own words, as one string — what the bible slice is matched
    /// against.
    ///
    /// A revision's BEFORE text counts as well as its after: the message shows
    /// the model both, so a subject named in either is one the run is about,
    /// and a fact about a character the writer has just written out of a
    /// paragraph is exactly the kind of thing a continuity question is for.
    static func prose(of delta: CompilerDelta) -> String {
        (delta.new.map(\.text)
            + delta.revised.map(\.prior)
            + delta.revised.map(\.text))
            .joined(separator: "\n")
    }

    /// End the turn in flight. The session stays warm.
    ///
    /// **A run can be under way without a turn to end**, and that window is
    /// now seconds rather than an instant: between the keystroke and the send
    /// the run closes the writer's burst and then derives their declared
    /// world, a whole subprocess. `cancelCurrentRun` guards on the session
    /// having a turn, so it no-ops against exactly that run — Cancel would
    /// mean "carry on", and the run it did not stop would go on to spend a
    /// full turn. So the unsent case is abandoned here by generation, the way
    /// `shutdown()` abandons it, and the session is left alone because there
    /// is nothing of ours in it.
    func cancel() {
        let hasUnsentRun = isRunning && runner?.isRunning != true
        runner?.cancelCurrentRun()
        guard hasUnsentRun else { return }
        runGeneration &+= 1
        isPreparingRun = false
        runState = .idle
    }

    /// End the session: the AI toggle going off, project close, app quit.
    ///
    /// **Not optional on any of those paths.** `ClaudeCLISession` cannot reap
    /// its own child from `deinit`, so a session merely released outlives the
    /// window as a live, billing process.
    func shutdown() {
        retireSession()
        // A run acknowledged a moment ago but still closing its burst — or
        // waiting on a derivation — has no session yet, so `retireSession`
        // cannot reach it. Abandon it here, or the toggle going off is followed
        // by the run it was meant to prevent.
        runGeneration &+= 1
        isPreparingRun = false
        // A turn cut short leaves the surface saying "running" forever
        // otherwise. A REPORTED failure is left alone: the toggle going off
        // must not erase the banner explaining why the last run failed.
        if isRunning { runState = .idle }
    }

    /// Shut down and release the window's object graph. The close-the-window
    /// verb, distinct from `shutdown()` because a writer who turns Claude off
    /// and on again must still have a working ⌘R.
    func detach() {
        shutdown()
        environment = nil
        diagnostics = nil
    }

    // MARK: - The turn coming back

    private func finish(
        _ event: CompilerRunEvent, docId: String, delta: CompilerDelta,
        marker: String?, intentSnapshot: String?, briefingHash: String?, model: String
    ) {
        switch event {
        case .started:
            // Unreachable through `send`, which resolves with a terminal event
            // (`CompilerRunner`'s own contract). The case exists for a
            // streaming consumer that does not exist yet — the section-by-
            // section arrival Stage 2 recorded as a follow-on (AREA.md,
            // "Streaming"); noted rather than silently ignored.
            return

        case .failed(let failure):
            // The marker and the briefing hash are both left exactly where they
            // were. A run that produced nothing checked nothing — advance
            // either and the next run describes a session that never read it.
            runState = failure.isTheWritersOwnDoing
                ? .idle
                : .failed(docId: docId, failure: failure, at: Date())

        case .resultText(let text):
            let runId = ULID.generate()
            // The whole turn at once. `parseAll` is `parseSection` folded over
            // the turn's objects and nothing else, so the day the session
            // surfaces partial text this becomes a per-section feed without the
            // meaning of a section changing (`DiagnosticIngest`'s own contract).
            guard let outcome = DiagnosticIngest.parseAll(
                resultText: text, runId: runId, docId: docId,
                liveParagraphText: { [weak self] paragraphId in
                    self?.environment?.liveParagraphText(docId, paragraphId)
                })
            else {
                runState = .failed(docId: docId, failure: .unusableOutput, at: Date())
                return
            }

            let run = CompilerRun(
                id: runId, at: Date(), model: model,
                // `?? marker` rather than a bare `newestOpId`: a delta built
                // with nothing after the marker still checked the prose it was
                // given, and nil-ing the marker would make the next run re-read
                // the whole document.
                lastOpId: delta.newestOpId ?? marker,
                deltaSummary: Self.summary(of: delta),
                intentSnapshot: intentSnapshot,
                // Carried, not swallowed. A run whose every note named a
                // paragraph the writer has since changed accepts nothing, and
                // without this the pane would wear the seal over it.
                droppedDangling: outcome.droppedDangling,
                // The clauses that produced no note are most of the summary:
                // stored with the run, superseded with the run.
                clauseStatuses: outcome.conformance,
                // How many reader reports were over the schema's cap of three,
                // stored with the run so the pane can report the truncation.
                truncatedReader: outcome.truncatedReader)
            // The notes stay in the order the sections arrived — conformance,
            // continuity, reader — because a store the pane has to re-sort is
            // two places that can disagree about the order.
            diagnostics?.replace(run: run, diagnostics: outcome.accepted, docId: docId)
            // Silently, and never as notes: the bible is a ledger the writer
            // acts on in the Intent pane, not a thing the compiler reports.
            if !outcome.facts.isEmpty {
                environment?.recordFacts(outcome.facts)
            }
            if let briefingHash, let runner {
                sentBriefing[docId] = (briefingHash, runner.sessionEpoch)
            }
            runState = .idle
        }
    }

    // MARK: - The session

    /// The warm session, spawned lazily on the first run — and its
    /// `--mcp-config` file, written once per session and deleted with it.
    /// One config per RUN would leave a JSON file per keystroke in the temp
    /// directory for the life of the machine.
    private func ensureRunner(model: String) -> CompilerRunner? {
        if let runner {
            // The gear menu moved since this session was spawned. Retire it
            // here rather than at the setting's own call site: this runs only
            // between turns (`runRequested` guards `!isRunning`), so the change
            // costs nothing in flight.
            guard runnerModel != model else { return runner }
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
    /// touching `runState` — `shutdown()`'s body minus the surface, so the
    /// model swap above is invisible to a writer who only sees the answer.
    private func retireSession() {
        runner?.shutdown()
        runner = nil
        runnerModel = nil
        if let configURL {
            try? FileManager.default.removeItem(at: configURL)
        }
        configURL = nil
        // A new process has read nothing, so nothing may be elided from its
        // first message.
        sentBriefing.removeAll()
    }

    /// The run record's one-line description of what was checked.
    static func summary(of delta: CompilerDelta) -> String {
        "\(delta.new.count) new, \(delta.revised.count) revised \u{00b6}"
    }
}
