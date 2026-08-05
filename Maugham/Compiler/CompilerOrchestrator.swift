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
    enum RunState: Equatable {
        case idle
        case running(docId: String)
        case nothingNew(at: Date)
        case failed(CompilerRunFailure, at: Date)
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
        /// The live document for a docId, or `nil` when the window's subject is
        /// not a manuscript document.
        var reading: @MainActor (String) -> DocumentReading?
        /// `(docId, paragraphId)` → the paragraph's text **now**. Read at
        /// ingest, which is what makes `DiagnosticsStore.live`'s exact-match
        /// staleness rule correct.
        var liveParagraphText: @MainActor (String, String) -> String?
        /// The intent this document answers to, piece-first, and what to call
        /// its scope in the prompt.
        var intent: @MainActor (String) -> (text: String?, scopeLabel: String)
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
    static let defaultModel = "sonnet"

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

    /// Per document: the intent hash the last successful run sent, and the
    /// session epoch it was sent into. Both halves matter — see `previousHash`.
    private var sentIntent: [String: (hash: String, epoch: Int)] = [:]

    var isRunning: Bool {
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
        guard let environment, let diagnostics else { return }
        // A run already in flight. Quiet on purpose: the pane header is already
        // saying what is happening, and there is one session per window, so a
        // second turn is not something to queue — it is something the next
        // keystroke can do.
        guard !isRunning else { return }
        // No document under the window's subject — the project row, or nothing
        // selected. Not an error, not a run, and nothing to acknowledge: the
        // key had nothing to act on.
        guard let reading = environment.reading(docId) else { return }

        environment.onRunAcknowledged()

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
            runState = .nothingNew(at: Date())
            return
        }

        let (intentText, scopeLabel) = environment.intent(docId)
        let context = CompilerContext(
            projectId: environment.projectId,
            intentText: intentText,
            intentScopeLabel: scopeLabel,
            // Plan 2 wires the pinned union and the palette (spec §3.3); the
            // prompt omits an empty section by design, so this is a smaller
            // prompt rather than a broken one.
            pinnedListing: [], paletteListing: [])

        guard let runner = ensureRunner(model: environment.model) else {
            runState = .failed(
                .sessionDied(detail: "the compiler's bridge config could not be written"),
                at: Date())
            return
        }

        // Elided only while the SAME process is still reading — see
        // `CompilerRunner.sessionEpoch`.
        let previousHash = sentIntent[docId].flatMap {
            $0.epoch == runner.sessionEpoch ? $0.hash : nil
        }
        let (message, intentHash) = CompilerPrompt.runMessage(
            delta: delta, context: context, previousIntentHash: previousHash)
        let preamble = CompilerPrompt.sessionSystemPreamble(projectId: environment.projectId)
        let model = environment.model

        runState = .running(docId: docId)
        Task { [weak self] in
            let event = await runner.send(message: message, systemPreamble: preamble)
            self?.finish(event, docId: docId, delta: delta, marker: marker,
                         intentSnapshot: intentText, intentHash: intentHash, model: model)
        }
    }

    /// End the turn in flight. The session stays warm.
    func cancel() {
        runner?.cancelCurrentRun()
    }

    /// End the session: the AI toggle going off, project close, app quit.
    ///
    /// **Not optional on any of those paths.** `ClaudeCLISession` cannot reap
    /// its own child from `deinit`, so a session merely released outlives the
    /// window as a live, billing process.
    func shutdown() {
        retireSession()
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
        marker: String?, intentSnapshot: String?, intentHash: String?, model: String
    ) {
        switch event {
        case .started:
            // Unreachable through `send`, which resolves with a terminal event
            // (`CompilerRunner`'s own contract). The case exists for a
            // streaming consumer that does not exist yet; noted for the
            // whole-branch review rather than silently ignored.
            return

        case .failed(let failure):
            // The marker and the intent hash are both left exactly where they
            // were. A run that produced nothing checked nothing — advance
            // either and the next run describes a session that never read it.
            runState = failure.isTheWritersOwnDoing ? .idle : .failed(failure, at: Date())

        case .resultText(let text):
            let runId = ULID.generate()
            guard let outcome = DiagnosticIngest.parse(
                resultText: text, runId: runId, docId: docId,
                liveParagraphText: { [weak self] paragraphId in
                    self?.environment?.liveParagraphText(docId, paragraphId)
                })
            else {
                runState = .failed(.unusableOutput, at: Date())
                return
            }

            // Drift first: the pane pins it at the top, and a store the pane has
            // to re-sort is two places that can disagree about the order.
            let notes = (outcome.drift.map { [$0] } ?? []) + outcome.accepted
            let run = CompilerRun(
                id: runId, at: Date(), model: model,
                // `?? marker` rather than a bare `newestOpId`: a delta built
                // with nothing after the marker still checked the prose it was
                // given, and nil-ing the marker would make the next run re-read
                // the whole document.
                lastOpId: delta.newestOpId ?? marker,
                deltaSummary: Self.summary(of: delta),
                intentSnapshot: intentSnapshot)
            diagnostics?.replace(run: run, diagnostics: notes, docId: docId)
            if let intentHash, let runner {
                sentIntent[docId] = (intentHash, runner.sessionEpoch)
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
        sentIntent.removeAll()
    }

    /// The run record's one-line description of what was checked.
    static func summary(of delta: CompilerDelta) -> String {
        "\(delta.new.count) new, \(delta.revised.count) revised \u{00b6}"
    }
}
