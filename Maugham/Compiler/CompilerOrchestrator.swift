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
        case running(docId: String, checking: DeltaCounts)
        case nothingNew(docId: String, at: Date)
        case failed(docId: String, failure: CompilerRunFailure, at: Date)
    }

    /// **What a run is reading, in counts** — the running state's payload, and
    /// the whole of requirement 5 on this side of the seam.
    ///
    /// A cold first run over a long delta takes about two minutes, and a bare
    /// "Checking…" for that long reads as a hung app. The delta is known before
    /// the send (`beginRun` builds it, then sets the state, then spawns), so the
    /// header can say what is being read without waiting for anything — the
    /// counts travel with the state rather than being fetched from the
    /// orchestrator by a pane that would have no way to know when they arrived.
    ///
    /// Counts rather than the sentence: the copy is the pane's
    /// (`DiagnosticsPane.checkingCopy`), the way every other line it says is.
    struct DeltaCounts: Equatable, Sendable {
        let new: Int
        let revised: Int

        init(new: Int, revised: Int) {
            self.new = new
            self.revised = revised
        }

        init(of delta: CompilerDelta) {
            self.init(new: delta.new.count, revised: delta.revised.count)
        }
    }

    /// **What the run key flashed about** — the capsule at the top of the
    /// window, `SaveFlashOverlay`'s ⌘S register borrowed by ⌘R.
    ///
    /// Two cases because a press that starts a run and a press that finds one
    /// already in flight are different promises, and the difference is the
    /// whole reason the second one may flash at all (see `runRequested`).
    /// A typed pair rather than a `String` label handed across the seam:
    /// adding a third acknowledgment is adding a case, and every emit site is
    /// then the compiler's problem rather than a reviewer's.
    enum Acknowledgment: Equatable, Sendable {
        /// A run just started on this document.
        case started
        /// One was already running, and this press started nothing.
        case alreadyChecking
        /// A **cold** run just started on this document (⌘⇧R): the warm
        /// session retired, the piece read whole. Its own case because the two
        /// presses promise different things — a delta comes back in seconds
        /// and a whole piece in minutes — and "Checking…" over the second is
        /// the wrong promise, not merely a duller one.
        case freshEyes

        /// The capsule's word. Kept beside the case rather than in the window
        /// that draws it, so all three sentences are assertable without a
        /// mount — and so the difference between them cannot be lost in a
        /// view's `switch`.
        var flashLabel: String {
            switch self {
            case .started: return "Checking\u{2026}"
            case .alreadyChecking: return "Still checking\u{2026}"
            case .freshEyes: return "Reading whole\u{2026}"
            }
        }
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

    /// **The review pass a run belongs to, resolved ONCE** — at the keystroke,
    /// in `beginRun`'s synchronous prefix, beside the round number it is minted
    /// with (M4 P1 Task 3).
    ///
    /// Three things travel together because they are three readings of one
    /// answer and a second resolution site is how they come to disagree: the
    /// lane a round is filed in, the editor whose name its notes are written
    /// under, and the doctrine the round is briefed on. `ReviewPass`'s own
    /// `effectiveEditorName`/`effectiveBrief` are the one resolution spelling
    /// (preset-by-id fallback); nothing downstream re-derives either.
    ///
    /// `nil` — no `ActivePass` at all — is the passless lane: an ordinary M2
    /// ⌘R, which mints no round number, stamps no pass on what it writes, and
    /// signs its notes "Claude".
    struct ActivePass: Equatable, Sendable {
        let id: String
        /// `ReviewPass.effectiveEditorName` — never nil, because every pass has
        /// a name to fall back to.
        let editorName: String
        /// `ReviewPass.effectiveBrief`. **Threaded in Task 3 and read in Task
        /// 4**: the briefing is the next task's, and resolving it in a second
        /// place then would be the drift this type exists to prevent.
        let brief: String?

        init(id: String, editorName: String, brief: String?) {
            self.id = id
            self.editorName = editorName
            self.brief = brief
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
        /// **The review pass the writer has active on this piece** — the
        /// round's comparison lane, asked once per run at the keystroke.
        ///
        /// Already validated against the project's live pass list by whoever
        /// answers: a lane is a pass that exists, and a run filed against a
        /// retired id would be a round nothing can ever compare. `nil` is the
        /// passless lane — an ordinary M2 ⌘R, which mints no round number at
        /// all rather than round 1 of nothing.
        ///
        /// Defaulted so that every `Environment` built before rounds existed
        /// still compiles: the answer it gives is the passless lane, which is
        /// exactly what those runs were.
        ///
        /// **It answers with the whole pass, not its id** (M4 P1 Task 3): the
        /// lane, the editor's name and the brief are resolved together here and
        /// nowhere else, so the round's filing, the notes' authorship and the
        /// briefing cannot describe different passes.
        var activePass: @MainActor (String) -> ActivePass? = { _ in nil }
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
        /// **Where a continuity question and a reader's report actually go**
        /// (M4 P1 Task 3) — the annotation layer, not the sidecar.
        ///
        /// Called once per finished run, after `replace`, with everything the
        /// run raised that is not a conformance strain. Answers how many notes
        /// it really minted, which is not the count it was handed: the dedupe
        /// backstop drops a finding already open on the document, and a note
        /// whose paragraph the writer deleted between parse and mint fails its
        /// own append.
        ///
        /// **It cannot fail the run**, and its signature says so: no `throws`,
        /// an `Int` rather than a result. The compiler is a background
        /// convenience (spec §3.2) and a note that could not be written is not
        /// a reason to tell the writer their check failed.
        ///
        /// Defaulted to a no-op returning 0 so every `Environment` built before
        /// the mint existed still compiles and still runs — those runs simply
        /// write no annotations, which is what they did.
        var mintAnnotations: @MainActor ([CompilerNote], CompilerMintContext) async -> Int
            = { _, _ in 0 }
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
        /// The acknowledgment flash. Called synchronously with the keystroke —
        /// for the press that starts a run AND for the one that finds a run
        /// already in flight, which say different things (`Acknowledgment`).
        var onRunAcknowledged: @MainActor (Acknowledgment) -> Void
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

    /// Who signs a passless run's notes (M4 P1 Task 3). "Claude" is M2's own
    /// identity and the label `AnnotationAuthorPresentation` already gives an
    /// author-less note, so a ⌘R outside every pass writes into the filter
    /// bucket the writer already has rather than opening a new one.
    nonisolated static let passlessEditorName = "Claude"

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

    /// **The turn as it arrives**, or `nil` between runs.
    ///
    /// Everything a preview needs to build a `CompilerRun` before the turn has
    /// produced one, plus the two things the stream itself accumulates. The
    /// record fields are read at the keystroke and carried rather than
    /// re-derived at the end, so the run the pane shows mid-check and the run
    /// it shows afterwards cannot describe the same check differently.
    private struct StreamingRun {
        let generation: Int
        let docId: String
        let runId: String
        let model: String
        let lastOpId: String?
        let deltaSummary: String
        let intentSnapshot: String?
        /// The round's lane and its number, minted at the keystroke
        /// (`beginRun`) and carried so the preview cannot describe a different
        /// round from the answer that supersedes it. The lane travels WHOLE
        /// (M4 P1) — the editor's name and the brief are resolved with it and
        /// never re-asked, because the writer can move the piece to another
        /// pass while the check runs.
        let activePass: ActivePass?
        var passId: String? { activePass?.id }
        let round: Int?
        /// Whether this round was read cold (⌘⇧R) — carried for the same
        /// reason the lane is: the preview and the answer must describe one
        /// round, and the pane draws its header off this stamp.
        let freshEyes: Bool
        /// Text delivered that has not closed a line yet. A chunk is cut by
        /// the transport, not by the contract — a section's JSON object
        /// routinely arrives in three pieces — so nothing is read until a
        /// newline says the line is whole.
        var buffer = ""
        /// Every section that HAS closed, folded exactly the way `parseAll`
        /// folds a whole turn (`DiagnosticIngest.combining`).
        var outcome = DiagnosticIngest.SectionedOutcome.empty
        /// Whether anything reached the pane, so a discard knows whether it
        /// has something to take back.
        var isShowing = false
    }

    private var streaming: StreamingRun?

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
    ///
    /// **`freshEyes` is the same run read cold** (⌘⇧R, M3-P3 §6): the warm
    /// session is retired so the process that answers has read nothing, the
    /// marker is not consulted so the delta is the whole standing manuscript,
    /// and the round is briefed on no prior round. Everything else is
    /// identical — the pass and the round number are minted normally, the
    /// marker advances normally, and the run records what it was
    /// (`CompilerRun.freshEyes`), so the NEXT plain ⌘R is warm again and back
    /// on the marker.
    ///
    /// Defaulted `false` so the ordinary key and every caller predating it —
    /// the cold-start offer's Read button among them — say what they always
    /// said.
    func runRequested(docId: String, freshEyes: Bool = false) {
        guard let environment, diagnostics != nil else { return }
        // A run already in flight. Nothing is queued — there is one session per
        // window, and a second turn is something the next keystroke can do —
        // but the press is answered.
        //
        // **This is M2 Task 7's judgment revisited, and the copy is what
        // answers it.** That task refused to flash here on the grounds that
        // ⌘S's capsule promises work was done, so flashing over a run already
        // under way would be the key claiming something it did not do. The
        // promise lives in the wording, not the capsule: "Still checking…"
        // claims nothing started. What the silence cost is requirement 4b — a
        // cold run takes ~2 minutes, and a writer whose second press produced
        // no reaction at all cannot tell a busy compiler from a dead keystroke.
        guard !isRunning else {
            environment.onRunAcknowledged(.alreadyChecking)
            return
        }
        // No document under the window's subject — the project row, or nothing
        // selected. Not an error, not a run, and nothing to acknowledge: the
        // key had nothing to act on. Asked here only for that answer; the
        // reading the delta is built from is taken below, after the burst.
        guard environment.reading(docId) != nil else { return }

        // Synchronous with the keystroke, and deliberately ahead of the hop
        // below: the flash is ⌘S's muscle-memory acknowledgment, not a progress
        // indicator, and one that waited on a disk write would be neither.
        //
        // **Below the refusals on purpose, both of them.** A fresh-eyes press
        // that arrives mid-run must be answered "still checking" like any
        // other, and must not have retired the session on its way past — the
        // retirement lives in `beginRun`, downstream of everything here, so
        // the turn the writer is waiting on cannot be killed by the keystroke
        // that was refused.
        environment.onRunAcknowledged(freshEyes ? .freshEyes : .started)

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
                          freshEyes: freshEyes,
                          environment: environment, diagnostics: diagnostics)
        }
    }

    /// The run proper, from the delta on — everything that was `runRequested`'s
    /// body before the burst-flush hop moved in above it.
    private func beginRun(
        docId: String, reading: DocumentReading, generation: Int, freshEyes: Bool,
        environment: Environment, diagnostics: DiagnosticsStore
    ) {
        let marker = diagnostics.lastOpId(docId: docId)
        // **A cold read does not consult the marker** (M3-P3 §6). `since: nil`
        // is `DeltaBuilder`'s "everything is new", which is what makes ⌘⇧R
        // over untouched prose a real read where ⌘R is honestly `nothingNew`.
        // The marker is still READ above and still advances below — a fresh
        // run leaves the document exactly as any run does, or the ⌘R after it
        // would re-read the piece a second time.
        let delta = DeltaBuilder.delta(
            ops: reading.ops, since: freshEyes ? nil : marker,
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

        // **The lane and the round, minted HERE — at the keystroke, before a
        // single byte of the answer can arrive** (M3-P3 §6).
        //
        // Two reasons it cannot wait for the record:
        //
        // - `latestRound` reads the store, and in production every run
        //   streams, so from the first closed section onward the standing
        //   content for this document is THIS run's own preview. A mint at
        //   record time would read its own round back and file the answer as
        //   the round after itself.
        // - The writer can click another pass chip while the check runs. The
        //   run was read for the lane it started in; a switch mid-check
        //   belongs to the next ⌘R.
        //
        // So it is minted once, carried on `StreamingRun`, and threaded
        // through the one `record(...)` spelling — the preview and the final
        // answer describe one round or they describe two checks.
        //
        // Below the empty-delta guard on purpose: a ⌘R with nothing new is not
        // a round, and numbering it would leave a gap in the lane the writer
        // never saw a report for.
        //
        // **The lane is resolved WHOLE, and this is the one site** (M4 P1
        // Task 3). The pass's editor signs the notes this round mints and its
        // brief is what the round is briefed on; asking for either again later
        // would read a project the writer may have moved on since.
        let activePass = environment.activePass(docId)
        let passId = activePass?.id
        // A passless run mints no number at all rather than round 1 of
        // nothing (decision 1: the passless lane is a lane, and an ordinary M2
        // run is what it holds).
        let round = passId == nil
            ? nil
            : (diagnostics.latestRound(forPass: passId, docId: docId) ?? 0) + 1

        // **The previous round, read HERE for the same reason the round number
        // is minted here** (M3-P3 §6). At this instant the standing sidecar
        // content IS the previous round — `replace` happens at finish — so
        // this is the last moment it can be asked for. From the first closed
        // section onward the standing content is this run's own preview, and
        // a briefing assembled then would hand the model its own half-report
        // as "what the last round found".
        //
        // **A cold read is briefed on none of it.** The round section hands
        // the model what the last round raised and asks it to say what became
        // of each — the opposite of reading the piece as if for the first
        // time. So fresh eyes skips the gather entirely rather than passing a
        // flag downward: nothing is asked of the store, and the pane's
        // since-last-round line refuses the same round from the other end
        // (`DiagnosticsPane.sinceLastRoundLine`), so the briefing and the
        // report agree about what this round was measured against — nothing.
        let previousRound = freshEyes ? nil : Self.previousRound(
            inLane: passId, docId: docId, diagnostics: diagnostics, environment: environment)

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

        // **The warm process dies HERE, and the read happens on its
        // replacement.** Fresh eyes is a cold read in the literal sense: a
        // session that has already read this piece carries every earlier turn
        // in its context, so re-sending the whole manuscript to it would be
        // the same tired reader given the same pages again. `retireSession`
        // is `shutdown()`'s body minus the surface — the process is signalled
        // and reaped, the config file goes with it, and `sentBriefing` clears
        // so the replacement is told the essay, the world and the bible in
        // full rather than "unchanged since last run".
        //
        // Late on purpose: below the in-flight refusal (`runRequested`), below
        // the burst-flush hop's generation check, and below the empty-delta
        // guard — a keystroke that is refused, abandoned or has nothing to
        // read must not have cost the writer their warm session on the way.
        if freshEyes { retireSession() }
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
        //
        // It carries the delta's counts because they are known HERE and nowhere
        // later — the pane's header says what is being read from this moment on
        // rather than from the moment the answer comes back (requirement 5).
        runState = .running(docId: docId, checking: DeltaCounts(of: delta))
        // Minted here rather than when the answer lands, because the stream
        // stores notes against it before there is an answer — and a note whose
        // run id changed at the end would be a different run's note as far as
        // every record downstream is concerned.
        let runId = ULID.generate()
        // `?? marker` rather than a bare `newestOpId`: a delta built with
        // nothing after the marker still checked the prose it was given, and
        // nil-ing the marker would make the next run re-read the whole
        // document.
        let lastOpId = delta.newestOpId ?? marker
        let deltaSummary = Self.summary(of: delta)
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
                previousRound: previousRound,
                previousBriefingHash: previousHash)

            // **Armed immediately before the send, and never earlier.** A run
            // abandoned while its declared world derived — a subprocess, and
            // the longer of the two suspensions — must leave nothing for a
            // stream to land in.
            self.streaming = StreamingRun(
                generation: generation, docId: docId, runId: runId, model: model,
                lastOpId: lastOpId, deltaSummary: deltaSummary,
                intentSnapshot: briefing?.statementText, activePass: activePass, round: round,
                freshEyes: freshEyes)
            runner.setPartialHandler { [weak self] chunk in
                self?.receivePartial(chunk, generation: generation)
            }

            let event = await runner.send(message: message, systemPreamble: preamble)
            await self.finish(event, docId: docId, runId: runId, lastOpId: lastOpId,
                              deltaSummary: deltaSummary,
                              intentSnapshot: briefing?.statementText,
                              activePass: activePass, round: round, freshEyes: freshEyes,
                              briefingHash: briefingHash, model: model)
        }
    }

    // MARK: - The turn arriving

    /// **One chunk of the answer, mid-turn** — accumulate, and read whatever
    /// lines it closed.
    ///
    /// The sections are the contract's unit (`DiagnosticIngest.parseSection`'s
    /// own doc: "one section is one unit ... so sections can be ingested as
    /// they arrive"), and a section is one line, so a closed line is the
    /// smallest thing worth showing. A line that is not a section — a fence
    /// marker, a sentence of narration, the last section still missing its
    /// newline — reads as nothing and simply waits for the result.
    ///
    /// **What lands here is a PREVIEW and never the answer.** It is stored
    /// through `DiagnosticsStore.preview`, which does not persist, does not
    /// enter the drift ring and does not raise the unread badge; `finish`
    /// reconciles the whole turn with `parseAll` and REPLACES all of it. A
    /// stream can be cut short, can double a section a model restates, and is
    /// absent entirely from a runner that does not stream — so nothing may be
    /// concluded from it that outlives the turn.
    private func receivePartial(_ chunk: String, generation: Int) {
        guard runGeneration == generation,
              var run = streaming, run.generation == generation,
              let diagnostics
        else { return }

        let docId = run.docId
        let runId = run.runId
        run.buffer += chunk
        var closedASection = false
        while let newline = run.buffer.firstIndex(of: "\n") {
            let line = String(run.buffer[run.buffer.startIndex..<newline])
            run.buffer = String(run.buffer[run.buffer.index(after: newline)...])
            guard let section = DiagnosticIngest.parseSection(
                line: line, runId: runId, docId: docId,
                liveParagraphText: { [weak self] paragraphId in
                    self?.environment?.liveParagraphText(docId, paragraphId)
                })
            else { continue }
            run.outcome = DiagnosticIngest.combining(run.outcome, section)
            closedASection = true
        }

        guard closedASection else {
            streaming = run
            return
        }
        run.isShowing = true
        streaming = run
        diagnostics.preview(
            run: Self.record(id: runId, model: run.model, lastOpId: run.lastOpId,
                             deltaSummary: run.deltaSummary,
                             intentSnapshot: run.intentSnapshot,
                             passId: run.passId, round: run.round,
                             freshEyes: run.freshEyes,
                             outcome: run.outcome),
            // **A preview shows what the report shows, and nothing else**
            // (M4 P1 Task 3). Continuity and reader sections still accumulate
            // on `run.outcome` — the run's own record reads its counts off it
            // — but they are no longer the sidecar's, so they must not be
            // previewed into it either. They mint at `finish` or not at all.
            diagnostics: run.outcome.sidecarDiagnostics, docId: docId)
    }

    /// Throw away whatever the stream put on the pane, and forget the stream.
    ///
    /// Called wherever a run ends without an answer — cancel, toggle-off,
    /// project close, a death, output that could not be read. **No half-report
    /// survives a run**: the notes on the pane came from a check that did not
    /// finish, and leaving them would be the compiler reporting on prose it
    /// stopped reading half way through.
    private func discardStreamPreview() {
        guard let run = streaming else { return }
        streaming = nil
        guard run.isShowing else { return }
        diagnostics?.discardPreview(docId: run.docId)
    }

    /// The run record — **one spelling, read by the preview and by the final
    /// answer**, so what the pane says mid-check and what it says afterwards
    /// cannot describe the same check differently.
    ///
    /// `passId`/`round`/`freshEyes` are required rather than defaulted: they
    /// are minted at the keystroke and carried, and a third call site that
    /// could quietly omit them would file an unnumbered round nothing
    /// downstream could notice — the preview and the answer would simply
    /// disagree.
    private static func record(
        id: String, model: String, lastOpId: String?, deltaSummary: String,
        intentSnapshot: String?, passId: String?, round: Int?, freshEyes: Bool,
        outcome: DiagnosticIngest.SectionedOutcome
    ) -> CompilerRun {
        CompilerRun(
            id: id, at: Date(), model: model, lastOpId: lastOpId,
            deltaSummary: deltaSummary, intentSnapshot: intentSnapshot,
            // Carried, not swallowed. A run whose every note named a paragraph
            // the writer has since changed accepts nothing, and without this
            // the pane would wear the seal over it.
            droppedDangling: outcome.droppedDangling,
            // The clauses that produced no note are most of the summary:
            // stored with the run, superseded with the run.
            clauseStatuses: outcome.conformance,
            // How many reader reports were over the schema's cap of three,
            // stored with the run so the pane can report the truncation.
            truncatedReader: outcome.truncatedReader,
            // The lane and its number. Both nil on a passless run, which is an
            // ordinary M2 run rather than a degenerate round.
            passId: passId, round: round,
            // **An ordinary run stamps NOTHING, not `false`** (M3-P3 Task 6).
            // The field is what the pane's header and the since-last-round
            // line both read, and both ask `== true`, so `false` and absent
            // are the same answer to every reader — which makes the absent one
            // strictly better: a ⌘R's sidecar stays byte-for-byte what it was
            // before this task existed, and "read cold" stays a thing a record
            // says rather than a thing every record carries an opinion about.
            freshEyes: freshEyes ? true : nil,
            // The round's judgement of the draft against the declared intent
            // (M3-P3 Task 4). Read straight off the outcome, so the preview
            // and the finished answer say the same thing about the same turn
            // — and nil for a turn that answered only the four sections it
            // knew, which is the additive contract working.
            //
            // It reaches DISK only through `DiagnosticsStore.replace`: a
            // preview carries it in memory, where the strip can draw it as it
            // arrives, and a cancel puts the last finished run's verdict back
            // by re-reading the untouched sidecar.
            //
            // **A run with nothing declared records NO verdict, whatever the
            // model answered** (M3-P3 Task 5). The schema instructs `holds`
            // where there is no intent, which is the obliging answer and not a
            // true one: nothing was checked against anything, so nothing was
            // judged. The guard is here rather than at ingest because this is
            // where the two halves meet — the snapshot is what the round was
            // briefed on, and a verdict without one is a judgement with no
            // subject. Downstream is unaffected either way (the strip's mark
            // fires on `drifted` alone); what this protects is what the RECORD
            // is allowed to claim, since the sidecar is where a later build
            // looks to tell "never judged" from "judged and held".
            intentDriftVerdict: intentSnapshot == nil ? nil : outcome.intentDriftVerdict)
    }

    /// **What the last round in this run's lane raised**, or `nil` when there
    /// is nothing this round can honestly be measured against.
    ///
    /// The lane rule, in one place (`RoundComparison`'s decision 1): only a
    /// prior round with the SAME `passId` briefs the next one. A passless ⌘R
    /// is an ordinary M2 run and is briefed on nothing; a run that opens a new
    /// lane starts clean, because the Line pass's findings are not what a
    /// Proof round is measured against.
    ///
    /// The standing run is the ONLY candidate, and that is not a shortcut: a
    /// round's notes are gone the moment the next round replaces them, so a
    /// round older than the standing one has fingerprints in the ring and no
    /// prose anywhere. If the standing run belongs to another lane, this
    /// lane's last round left nothing to say.
    private static func previousRound(
        inLane passId: String?, docId: String, diagnostics: DiagnosticsStore,
        environment: Environment
    ) -> CompilerPrompt.PriorRound? {
        guard passId != nil,
              let standing = diagnostics.standingRound(docId: docId),
              standing.record.passId == passId,
              standing.record.round != nil
        else { return nil }

        let notes = standing.notes.compactMap { note -> CompilerPrompt.PriorNote? in
            // A note with no section is a v1 record, which has no identity
            // under this contract — `RoundFingerprint.make` refuses one for
            // the same reason, so counting it and briefing it stay in step.
            guard let kind = note.kind else { return nil }
            return CompilerPrompt.PriorNote(
                body: note.body, kind: kind,
                // `DiagnosticsStore.live`'s rule, asked directly: the
                // paragraph's text now against the text the note was anchored
                // to. A paragraph that is gone answers `nil`, which is not the
                // anchor text either — the writer edited it away.
                sinceEdited: note.anchor.map {
                    environment.liveParagraphText(docId, $0.paragraphId) != $0.anchorText
                } ?? false)
        }
        return CompilerPrompt.PriorRound(record: standing.record, notes: notes)
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
        // Here as well as in `finish`'s failure arm, and not instead of it.
        // The turn's continuation resumes on a later tick, so a report left
        // standing until then is a half-report the writer watches for as long
        // as the runloop takes — and a runner that answers a cancel with
        // something other than a failure would never reach `finish` at all.
        discardStreamPreview()
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
        // The toggle going off takes the half-report with it, for the same
        // reason it abandons the run: nothing on the pane may outlive the check
        // that produced it.
        discardStreamPreview()
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

    /// **`async` because the run is not over until its notes are written**
    /// (M4 P1 Task 3). The mint appends to the op log, and a `runState` that
    /// went `.idle` before those appends landed would tell the writer the check
    /// was finished while its findings were still arriving in the pane beside
    /// it. Nothing else about the arm changed: the mint cannot throw, cannot
    /// fail the run, and is reached only on `.resultText`.
    private func finish(
        _ event: CompilerRunEvent, docId: String, runId: String, lastOpId: String?,
        deltaSummary: String, intentSnapshot: String?, activePass: ActivePass?, round: Int?,
        freshEyes: Bool, briefingHash: String?, model: String
    ) async {
        let passId = activePass?.id
        switch event {
        case .started:
            // Unreachable through `send`, which resolves with a terminal event
            // (`CompilerRunner`'s own contract). Streaming does NOT arrive
            // here: a chunk reaches `receivePartial` through the runner's
            // partial handler, because a turn has many chunks and exactly one
            // terminal event. Named rather than silently ignored.
            return

        case .failed(let failure):
            // The marker and the briefing hash are both left exactly where they
            // were. A run that produced nothing checked nothing — advance
            // either and the next run describes a session that never read it.
            // The stream goes with them: what it showed was a check that did
            // not finish.
            discardStreamPreview()
            runState = failure.isTheWritersOwnDoing
                ? .idle
                : .failed(docId: docId, failure: failure, at: Date())

        case .resultText(let text):
            // **The whole turn at once, and it REPLACES whatever streamed.**
            // `parseAll` is `parseSection` folded over the turn's objects and
            // nothing else (`DiagnosticIngest`'s own contract), so this is the
            // same reading of the same sections — but of ALL of them, including
            // a last one whose newline never came and a first one the model
            // restated. Reconciliation rather than accumulation is what leaves
            // one source of truth at the end of a turn: fold the preview into
            // this and a section the model wrote twice would be shown twice.
            guard let outcome = DiagnosticIngest.parseAll(
                resultText: text, runId: runId, docId: docId,
                liveParagraphText: { [weak self] paragraphId in
                    self?.environment?.liveParagraphText(docId, paragraphId)
                })
            else {
                discardStreamPreview()
                runState = .failed(docId: docId, failure: .unusableOutput, at: Date())
                return
            }

            let run = Self.record(
                id: runId, model: model, lastOpId: lastOpId,
                deltaSummary: deltaSummary, intentSnapshot: intentSnapshot,
                // The pair minted at the keystroke, not re-asked here: the
                // store's own standing content is this run's preview by now,
                // and the writer may have moved the piece to another pass
                // while it ran.
                passId: passId, round: round, freshEyes: freshEyes,
                outcome: outcome)
            // Dropped rather than discarded: `replace` below supersedes the
            // preview wholesale, so taking it off the pane first would blink
            // the report out and back.
            streaming = nil
            // **The split, and it is the whole point of M4 P1's first plan.**
            // A conformance strain is read beside the clause it strains
            // against, so it stays in the report; a continuity question and a
            // reader's report are about the words and outlive the check, so
            // they leave for the annotation layer below. One finding, one home
            // — and the two halves land in the same commit, because a build in
            // which a note appears in both is a build that asks the writer to
            // answer it twice.
            diagnostics?.replace(
                run: run, diagnostics: outcome.sidecarDiagnostics, docId: docId)
            // **After `replace`, not before.** The report is what the writer is
            // waiting on and it is synchronous; the mint is an op-log append
            // per note. A mint that ran first would hold the pane's answer
            // behind a disk write for findings the pane does not show.
            let notes = outcome.mintable
            if !notes.isEmpty, let environment {
                _ = await environment.mintAnnotations(
                    notes,
                    CompilerMintContext(
                        docId: docId, runId: runId, passId: passId, round: round,
                        freshEyes: freshEyes,
                        // A passless run signs "Claude" — M2's identity, and
                        // the label `AnnotationAuthorPresentation` already
                        // gives an author-less note.
                        editorName: activePass?.editorName ?? Self.passlessEditorName))
            }
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
