import Foundation
import MaughamCore

/// **The run.** One keystroke, carried in order: the delta against the
/// last-run marker, the prompt, the warm session, the parse, the mint, the
/// store. AREA.md's "The run's order" and "Two loops, two readers" state the
/// rules this file keeps.
///
/// Owned by `ProjectWindow` (the `CanvasModel` pattern), so the right-hand
/// pane reads the run state the centre column's keystroke started. One
/// orchestrator per window; one session per orchestrator.
///
/// **It reads the editor and never writes to it**: a run takes a
/// `DocumentReading` value at the keystroke and reads paragraph text back
/// through a closure, never holding a binding or a `Document` (tripwires 3, 6).
@Observable @MainActor
final class CompilerOrchestrator {

    // History: docs/history/compiler.md#orchestrator-runstate
    /// What the surface says about the last thing the run key did.
    /// `nothingNew` is not `idle`: the pane must tell "checked, nothing new"
    /// from "the key did nothing".
    ///
    /// **Every run case names its document and its loop.** The surface is
    /// per-document and this state per-window, and one session serves both
    /// loops, so each surface matches its own `docId` and `RunKind` and names
    /// the other loop's run (`DiagnosticsPane.otherLoopLine`,
    /// `ReviewRoundCockpit.otherLoopLine`). `.idle` claims nothing.
    enum RunState: Equatable {
        case idle
        case running(docId: String, kind: RunKind, checking: DeltaCounts)
        case nothingNew(docId: String, kind: RunKind, at: Date)
        case failed(docId: String, kind: RunKind, failure: CompilerRunFailure, at: Date)
    }

    /// **What a run is reading, in counts** (requirement 5): known before the
    /// send, so the header says what is being read from the keystroke on. The
    /// sentence is the pane's (`RoundNarrative.checkingCopy`).
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

    // History: docs/history/compiler.md#orchestrator-acknowledgment
    /// **What the run key flashed about**: ⌘S's capsule borrowed by ⌘R
    /// (`SaveFlashOverlay`). Typed, so a new acknowledgment is a new case
    /// every emit site must handle.
    enum Acknowledgment: Equatable, Sendable {
        /// A run just started on this document.
        case started
        /// One was already running, and this press started nothing.
        case alreadyChecking
        /// A **cold** run just started (⌘⇧R). Its own case: a whole piece takes
        /// minutes, and "Checking…" would promise seconds.
        case freshEyes
        /// A board chip's round never started: the piece did not open inside
        /// `RunWhenDocumentOpens`' bound (Denver's 2026-08-18 ruling). A
        /// FAILURE, so it says what to do next.
        case pieceWouldNotOpen
        /// A round on a piece with no STAGE (unassigned, or a retired pass). A
        /// round with no lane numbers nothing (`RoundEditor`); the coach reads
        /// checks and is no substitute. A FAILURE, worded the same way.
        case noEditor
        /// **A round on a piece this Mac may not write** (P3c Task 6, ruling
        /// R4): a round moves the lane and stamps a pass, which a reviewer's
        /// posture does not offer. Refused before anything starts; never asked
        /// of a check; never a fallback to another reader.
        case notYourPiece

        /// The capsule's word, beside the case so every sentence is assertable
        /// without a mount.
        var flashLabel: String {
            switch self {
            case .started: return "Checking\u{2026}"
            case .alreadyChecking: return "Still checking\u{2026}"
            case .freshEyes: return "Reading whole\u{2026}"
            case .pieceWouldNotOpen: return "Couldn\u{2019}t open the piece \u{2014} try again."
            case .noEditor: return "Set a pass to run a round."
            case .notYourPiece: return "Not your piece \u{2014} leave a note instead."
            }
        }
    }

    /// What one run reads off the live `Document`, captured at the keystroke:
    /// a value, never the `Document` across a subprocess turn (tripwires 3, 6).
    /// `sequence` is authoritative for order.
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

    /// What a run is checked against: **the statement WHOLE** (the derivation
    /// reads the rulings too; the briefing embeds only the essay) **and the
    /// key its reading is cached under**, spelled by `DeclaredWorldStore` and
    /// never rebuilt here (two spellings are two caches, one never hit).
    struct IntentBriefing: Equatable, Sendable {
        let statementText: String
        let scopeKey: String

        init(statementText: String, scopeKey: String) {
            self.statementText = statementText
            self.scopeKey = scopeKey
        }
    }

    // History: docs/history/compiler.md#orchestrator-activepass
    /// **The review pass a ROUND belongs to, resolved ONCE**, in `beginRun`'s
    /// synchronous prefix. Lane, signing editor and doctrine are three
    /// readings of one answer and travel together; `ReviewPass
    /// .effectiveEditorName`/`.effectiveBrief` are the one resolution, never
    /// re-derived downstream.
    ///
    /// Review's alone: a CHECK is read by an `AuthorReader`, and there is no
    /// `isCoach` flag (`TripwireGrepTests.test_isCoachIsGone`). No pass means
    /// no round number, no pass stamp, notes signed "Claude".
    struct ActivePass: Equatable, Sendable {
        let id: String
        /// `ReviewPass.name`: half the role frame ("this manuscript's Copyedit
        /// editor") and the fallback brief. Carried so a rename mid-run cannot
        /// reframe the round.
        let name: String
        /// `ReviewPass.effectiveEditorName`: never nil.
        let editorName: String
        /// `ReviewPass.effectiveBrief`.
        let brief: String?

        init(id: String, name: String, editorName: String, brief: String?) {
            self.id = id
            self.name = name
            self.editorName = editorName
            self.brief = brief
        }
    }

    // History: docs/history/compiler.md#orchestrator-mintoutcome
    /// What one round's mint did (`Environment.mintAnnotations`' answer).
    /// **Two numbers, because the dedupe has two outcomes**: a refused finding
    /// held in this round's own lane is *persisting* on the since-line; one
    /// held only in ANOTHER pass's lane needs its own count.
    struct MintOutcome: Equatable, Sendable {
        /// Notes really appended, after the dedupe and any failed append.
        let minted: Int
        /// Distinct findings refused where **no lane holding them is this
        /// round's own**. Own-lane presence wins (one fingerprint can be held
        /// by two open notes; `CompilerEnvironment+Project`'s mint loop), so a
        /// finding is never counted twice. Per FINDING, not per note.
        let openInOtherLanes: Int
        /// The open notes behind that count, so `RoundNarrative.openElsewhere`
        /// filters live at render. Defaulted for count-only doubles.
        var openInOtherLanesNoteIds: [String] = []

        /// No document or no note to write: zero, the same on the wire as a
        /// mint that wrote nothing. A `nil` count on `CompilerRun` comes from
        /// the PREVIEW path (and older records) only.
        static let nothing = MintOutcome(minted: 0, openInOtherLanes: 0)
    }

    // History: docs/history/compiler.md#orchestrator-environment
    /// Everything the orchestrator needs from its window: closures, not
    /// stores, so a test runs with no project on disk and `detach()` drops the
    /// graph in one line. All `@MainActor`: a hop between keystroke and delta
    /// would let the writer type in the gap. A closure added later is
    /// defaulted to the answer runs had before it existed.
    struct Environment {
        var projectId: String
        /// The model each run is spawned against.
        var model: String
        /// **Close the writer's burst before `reading` is asked**; awaited at
        /// the top of every run. Never throws: a stale delta checks real prose,
        /// a refused run checks none.
        var prepareForRun: @MainActor (String) async -> Void
        /// The live document, or `nil` when the subject is not a manuscript
        /// document. Read AFTER `prepareForRun`.
        var reading: @MainActor (String) -> DocumentReading?
        /// `(docId, paragraphId)` → the paragraph's text **now**, read at
        /// ingest; what makes `DiagnosticsStore.live`'s staleness rule correct.
        var liveParagraphText: @MainActor (String, String) -> String?
        /// The intent this document answers to, piece-first. `nil` is valid
        /// (M1A): the conformance section has nothing to check.
        var intent: @MainActor (String) -> IntentBriefing?
        /// **The lessons ledger, whole**, or `nil`. Takes no docId: the ledger
        /// is project-scoped by construction (`StatementConvention`).
        var lessons: @MainActor () -> String? = { nil }
        /// **Who reads a CHECK** (`.nobody`: no frame, no lane, signed
        /// "Claude"). A separate closure from `roundEditor`, with a different
        /// answer type, so asking the other loop's question does not
        /// type-check; never merge them. Reads no review-board memory
        /// (tripwire 34).
        var authorReader: @MainActor (String) -> AuthorReader = { _ in .nobody }
        /// **Who reads a ROUND**: the piece's stage, validated against the live
        /// pass list, answered whole so lane, name and brief agree. `nil` is a
        /// REFUSAL (`.noEditor`), never a fallback to the coach.
        var roundEditor: @MainActor (String) -> ActivePass? = { _ in nil }
        /// **May this Mac run a ROUND here?** (P3c Task 6, ruling R4.) `false`
        /// flashes `.notYourPiece`; `nil` (the window's door is gone) starts
        /// and says nothing. Never asked of a check. **Async because it is the
        /// ACTING door** (`DocumentStore.settledPosture(forDocId:)`, controller
        /// ruling I): the drawing door is stale just after a demotion.
        /// Production always supplies it (`PostureSurfaceTests`).
        var mayRunRound: @MainActor (String) async -> Bool? = { _ in true }
        /// The project's type, for the scene position (spec §3.4); keyed by
        /// docId so a per-piece answer fits the seam. `nil` reads as prose.
        var projectType: @MainActor (String) -> ProjectType? = { _ in nil }
        /// The reading held for this statement's EXACT text, or `nil`. Pure:
        /// never derives, so a hit is told from a miss before spending a
        /// subprocess.
        var cachedWorld: @MainActor (IntentBriefing) -> DerivedWorld?
        /// Derive and cache a reading, on the model passed. **The lazy
        /// trigger** (AREA.md, "the derivation trigger"): only on a miss, only
        /// from `resolveWorld`. `nil` costs the run its clauses, not the run.
        var deriveWorld: @MainActor (IntentBriefing, String) async -> DerivedWorld?
        /// What the ledger believes about subjects this delta names (spec §5);
        /// the matching rule lives at the production call site.
        var bibleSlice: @MainActor (String) -> [BibleFact]
        /// The compiler's notes on this piece and what the writer did about
        /// each: the dispositions briefing, asked in `beginRun`'s synchronous
        /// prefix. The warm path's duplicate guard; `mintAnnotations`' dedupe
        /// is the cold one.
        var annotationContext: @MainActor (String) -> [CompilerAnnotationDisposition]
            = { _ in [] }
        /// **Continuity questions and reader reports go here**, to the
        /// annotation layer: once per finished run, BEFORE the record is
        /// built. Answers what really minted (`MintOutcome`). **Cannot fail the
        /// run** (no `throws`; spec §3.2).
        var mintAnnotations: @MainActor ([CompilerNote], CompilerMintContext) async -> MintOutcome
            = { _, _ in .nothing }
        /// Facts on their way into the bible: silently, never as a note.
        var recordFacts: @MainActor ([BibleFact]) -> Void
        /// What is pinned beside this document (`PinnedReferences`, §7.2), as
        /// "title (id) — tool" lines grouped as the `PinnedShelf` groups them
        /// (`pinnedListingLines`). Empty is valid; the prompt omits it.
        var pinnedListing: @MainActor (String) -> [String]
        /// Every palette card, "title (id)": project-wide, so no document.
        var paletteListing: @MainActor () -> [String]
        /// Writes the per-session `--mcp-config` and returns its path; its life
        /// is `ensureRunner`'s from here.
        var writeMCPConfig: @MainActor () throws -> URL
        /// `(configPath, model)` → the session. The model is passed so `model`
        /// is decided in one place.
        var makeRunner: @MainActor (URL, String) -> CompilerRunner
        /// The flash, synchronous with the keystroke, for a start AND for a
        /// press that finds a run in flight.
        var onRunAcknowledged: @MainActor (Acknowledgment) -> Void
    }

    // History: docs/history/compiler.md#orchestrator-defaultmodel
    /// The model before the gear menu is read (spec §3.5). `nonisolated`: it
    /// is a default argument of `Environment.production`, evaluated in the
    /// caller's context, where main-actor isolation is a Swift 6 error.
    nonisolated static let defaultModel = "sonnet"

    /// Who signs a passless run's notes: `AnnotationAuthorPresentation`'s
    /// label for an author-less note, so it joins an existing filter bucket.
    nonisolated static let passlessEditorName = "Claude"

    private(set) var runState: RunState = .idle

    /// When the run in flight started, and what the CLI has thought so far
    /// (spec 2026-09-09 §5). Both `nil` between runs; cleared by `endLiveRun`.
    private(set) var runStartedAt: Date?
    private(set) var runProgress: RunProgress?

    private(set) var diagnostics: DiagnosticsStore?

    private var environment: Environment?
    private var runner: CompilerRunner?
    private var configURL: URL?
    /// The model `runner` was **spawned** with (`--model` is a spawn argument),
    /// compared by `ensureRunner`.
    private var runnerModel: String?

    // History: docs/history/compiler.md#orchestrator-stored-state
    /// Per document: the briefing hash last sent, and the session epoch it
    /// went into; elision needs both. The hash covers essay, derived world and
    /// bible slice as one unit (`CompilerPrompt.runMessageV2`).
    private var sentBriefing: [String: (hash: String, epoch: Int)] = [:]

    /// True between the keystroke and the delta (the burst, or a round's
    /// permit question). `isRunning` counts it: a double-press is one run.
    private var isPreparingRun = false

    /// The generation a run's suspensions belong to; a teardown bumps it and
    /// **abandons** the run ("Generations, not booleans", AREA.md). Re-checked
    /// after every suspension: the permit, the burst, the derivation, the mint.
    private var runGeneration = 0

    // History: docs/history/compiler.md#orchestrator-streamingrun
    /// **The turn as it arrives**, or `nil` between runs. Every `let` is minted
    /// at the keystroke and carried, because the writer may change passes,
    /// readers, intent or ask mid-run; the preview and `finish` stamp the same
    /// values.
    private struct StreamingRun {
        let generation: Int
        let docId: String
        let runId: String
        let model: String
        let lastOpId: String?
        let deltaSummary: String
        let intentSnapshot: String?
        /// A check's reader; `nil` for a round, whose byline is its lane's.
        let readerName: String?
        /// The LANE, not the reader: `nil` for every check.
        let passId: String?
        let round: Int?
        let scenePosition: ScenePosition
        /// `nil` for a round: only a check derives a stage.
        let stage: DraftStage?
        /// The dose the briefing stated (global constraint 24), so ingest
        /// enforces the same one.
        let dosage: LetterDosage
        let ask: String?
        let freshEyes: Bool
        let kind: RunKind
        /// Text not yet closed by a newline: the transport cuts chunks, so only
        /// a whole line is read.
        var buffer = ""
        /// Closed sections, folded as `parseAll` folds (`DiagnosticIngest.combining`).
        var outcome = DiagnosticIngest.SectionedOutcome.empty
        /// Whether anything reached the pane, so a discard knows to take it back.
        var isShowing = false
    }

    private var streaming: StreamingRun?

    var isRunning: Bool {
        if isPreparingRun { return true }
        if case .running = runState { return true }
        return false
    }

    /// Wire to the window, from `ProjectWindow.load()`; never from a `body`.
    func configure(environment: Environment, diagnostics: DiagnosticsStore) {
        self.environment = environment
        self.diagnostics = diagnostics
    }

    /// The gear menu's model. It does not retune the warm session: the next
    /// run's `ensureRunner` retires it, so a check in flight is never killed.
    func updateModel(_ model: String) {
        environment?.model = model
    }

    /// The model the next spawn will use, or nil while unwired
    /// (`AgentRosterTests` asserts through it).
    var configuredModel: String? { environment?.model }

    // MARK: - The one entry

    // History: docs/history/compiler.md#orchestrator-runrequested
    /// The run key. Silent with nothing to act on; otherwise every press is
    /// acknowledged, a refusal included.
    ///
    /// **`freshEyes` is the same run read cold** (⌘⇧R, M3-P3 §6): the session
    /// is retired, the marker is not consulted, and no prior round or
    /// dispositions are briefed. The round still mints, the marker still
    /// advances, and `CompilerRun.freshEyes` records it.
    /// - Parameter kind: **which loop asked.** Undefaulted, so no call site
    ///   files a round as a check unnoticed. Minted from the persona only in
    ///   `CompilerRunModifier`; every other caller belongs to one loop.
    func runRequested(docId: String, kind: RunKind, freshEyes: Bool = false) {
        guard let environment, diagnostics != nil else { return }
        // In flight: nothing queues, but the press is answered; a silent press
        // on a two-minute cold run reads as a dead key (requirement 4b).
        guard !isRunning else {
            environment.onRunAcknowledged(.alreadyChecking)
            return
        }
        // No document under the subject: nothing to act on or acknowledge.
        guard environment.reading(docId) != nil else { return }

        // **A round needs an editor; no substitute.** Above the flash, so the
        // refusal is the ONLY thing the press does; below `isRunning`, so a
        // mid-run press still reads "still checking".
        if kind == .round, environment.roundEditor(docId) == nil {
            environment.onRunAcknowledged(.noEditor)
            return
        }

        // **A round is the piece-writer's** (ruling R4), asked of the async
        // SETTLED posture. The press holds the in-flight gate while it asks,
        // and the flash waits, so a refusal is still the only thing it does.
        // A check never reaches this.
        if kind == .round {
            runGeneration &+= 1
            let generation = runGeneration
            isPreparingRun = true
            Task { [weak self] in
                let mayRun = await environment.mayRunRound(docId)
                // Re-asked after the hop: a close or cancel takes the press.
                guard let self, self.runGeneration == generation,
                      let environment = self.environment else { return }
                self.isPreparingRun = false
                guard let mayRun else { return }  // no window: nothing to say
                guard mayRun else {
                    environment.onRunAcknowledged(.notYourPiece)
                    return
                }
                self.acknowledgeAndPrepare(
                    docId: docId, kind: kind, freshEyes: freshEyes,
                    environment: environment)
            }
            return
        }
        acknowledgeAndPrepare(docId: docId, kind: kind, freshEyes: freshEyes,
                              environment: environment)
    }

    // History: docs/history/compiler.md#orchestrator-acknowledgeandprepare
    /// The press, past every refusal: the flash, then the burst, then the run.
    private func acknowledgeAndPrepare(
        docId: String, kind: RunKind, freshEyes: Bool, environment: Environment
    ) {
        // Synchronous, ahead of the hop: ⌘S's muscle-memory acknowledgment, not
        // progress. Below the refusals, so a refused fresh-eyes press never
        // retires the session (that lives in `beginRun`).
        environment.onRunAcknowledged(freshEyes ? .freshEyes : .started)

        // **The burst first, the delta second**: the wet ink is what the
        // compiler is for (spec §3.2). The document closes its own burst and we
        // take a value afterwards (tripwires 3, 6).
        runGeneration &+= 1
        let generation = runGeneration
        isPreparingRun = true
        Task { [weak self] in
            await environment.prepareForRun(docId)
            guard let self, self.runGeneration == generation else { return }
            self.isPreparingRun = false
            // Re-asked after the hop: the window, Claude, or the selection may
            // have gone.
            guard let environment = self.environment,
                  let diagnostics = self.diagnostics,
                  let reading = environment.reading(docId) else { return }
            self.beginRun(docId: docId, reading: reading, generation: generation,
                          kind: kind, freshEyes: freshEyes,
                          environment: environment, diagnostics: diagnostics)
        }
    }

    // History: docs/history/compiler.md#orchestrator-beginrun
    /// The run proper, past the burst. **Its synchronous prefix is the
    /// keystroke's instant**: everything the run is briefed on or stamps is
    /// resolved here, before the first suspension, because from the first
    /// streamed section the standing content is this run's own preview and
    /// the writer may change passes, readers, notes or ask mid-run.
    private func beginRun(
        docId: String, reading: DocumentReading, generation: Int, kind: RunKind,
        freshEyes: Bool,
        environment: Environment, diagnostics: DiagnosticsStore
    ) {
        // The round's editor, re-read after the hop (a stage can be cleared or
        // its pass retired meanwhile): refused as `runRequested` refuses, never
        // filed passless. Above the empty-delta guard and every write.
        let roundPass: ActivePass? = kind == .round ? environment.roundEditor(docId) : nil
        if kind == .round, roundPass == nil {
            environment.onRunAcknowledged(.noEditor)
            return
        }

        let marker = diagnostics.lastOpId(docId: docId)
        // **The marker is the CHECK's; only a warm check diffs against it.** A
        // cold read (M3-P3 §6) and a round (spec §4.5) are `since: nil`, the
        // whole piece. A cold check still advances it below.
        let delta = DeltaBuilder.delta(
            ops: reading.ops, since: (freshEyes || kind == .round) ? nil : marker,
            currentParagraphs: reading.paragraphs, sequence: reading.sequence)

        guard !delta.isEmpty else {
            // Prose-less ops still move a CHECK's marker; never a round's, which
            // would consume ops the writer's next ⌘R is owed.
            if kind == .check, let newest = delta.newestOpId {
                diagnostics.advanceMarker(to: newest, docId: docId)
            }
            runState = .nothingNew(docId: docId, kind: kind, at: Date())
            return
        }

        // Each verb asks its own reader; above the dose, which is hers for a
        // first reader.
        let reader: AuthorReader = kind == .check ? environment.authorReader(docId) : .nobody

        // The writer's process (spec §5), a CHECK's only, pure over `reading`
        // so it describes the delta's instant. `DeltaBuilder.ordered` runs
        // twice per ⌘R; accepted at 1 ms over coupling the two readers.
        let signals = kind == .check
            ? ProcessSignals(ops: reading.ops, sequence: reading.sequence, now: Date())
            : nil
        // **Derived, never set** (constraint 23, §3.8), for a CHECK alone
        // (§4.8): a round is always the full letter.
        let stage: DraftStage? = kind == .check
            ? DraftStage.derive(counts: DeltaCounts(of: delta), signals: signals)
            : nil
        // **Stated AND enforced** (constraint 24), so derived once. Fresh Eyes
        // and a round are `.full`; **a first reader's dose outranks both**
        // (ruling P2-4).
        let dosage: LetterDosage = reader.isFirstReader
            ? .reader
            : (stage?.dosage(freshEyes: freshEyes) ?? .full)
        // A first reader is told no process line (ruling P2-6; ingest's
        // `LetterDosage.allowsProcess` is the other end) and no stage (ruling
        // P2-4: `stageSection` contradicts `firstReaderInstruction`). The
        // record still stamps `stage`.
        let briefedSignals = reader.isFirstReader ? nil : signals
        let briefedStage = reader.isFirstReader ? nil : stage

        // **Lane and round, minted before a byte of the answer** (M3-P3 §6):
        // `latestRound` asked later would read this run's own preview. Below
        // the empty-delta guard, so a ⌘R with nothing new leaves no gap. **A
        // check is filed in no lane** (a reader is not a lane): `roundPass` is
        // nil for a check by construction.
        let passId = roundPass?.id
        // Never nil: an unread check signs "Claude".
        let editorName = kind == .check
            ? reader.editorName
            : (roundPass?.editorName ?? AuthorReader.nobody.editorName)
        // The record keeps a check's byline (P1's Ruling 10); a round's is its
        // lane's.
        let readerName = kind == .check ? reader.editorName : nil
        // Passless: no number, not round 1 of nothing (decision 1).
        let round = passId == nil
            ? nil
            : (diagnostics.latestRound(forPass: passId, docId: docId) ?? 0) + 1

        // Until `finish` replaces it, the standing content IS the previous
        // round. None for a cold read (`RoundNarrative.sinceLastRoundLine`
        // agrees) or a check; asked on the kind, not `passId == nil`.
        let previousRound = (freshEyes || kind == .check) ? nil : Self.previousRound(
            inLane: passId, docId: docId, diagnostics: diagnostics, environment: environment)

        // Read before this run writes into the same layer. None for a cold
        // read, which makes `mintAnnotations`' dedupe its duplicate guard.
        let dispositions = freshEyes ? [] : environment.annotationContext(docId)

        // The ask, from the store in hand; a cold read IS briefed on it. An
        // unsubmitted ask counts: ⌘R never touches the first responder, and
        // every trigger passes this line.
        diagnostics.commitPendingAsk(docId: docId, kind: kind)
        let ask = diagnostics.ask(docId: docId, kind: kind)

        // Hashed with the intent. **None for a first reader** (ruling P2-7):
        // it is craft vocabulary, so the file is not even read.
        let lessons = reader.isFirstReader ? nil : environment.lessons()
        let briefing = environment.intent(docId)
        // The essay half (§3.2). **The atomic switch**: the strata reach the run
        // as clauses, never also as prose
        // (`CompilerRunCommandTests.test_rulingsAreBriefedAsClausesNotProse`).
        let essay = briefing.map { StatementEssay.half(of: $0.statementText) }
        // From the WHOLE statement (§3.4): Add-to-intent files under `##
        // Rulings`. The brief is the verb's reader's; a first reader's is `nil`
        // on purpose (`AuthorReader.brief`).
        let scenePosition = ScenePosition.derive(
            projectType: environment.projectType(docId),
            statement: briefing?.statementText,
            passBrief: kind == .check ? reader.brief : roundPass?.brief)
        let pinnedListing = environment.pinnedListing(docId)
        let paletteListing = environment.paletteListing()
        let bibleFacts = environment.bibleSlice(Self.prose(of: delta))

        // **Fresh eyes retires the warm process here** (it has read this piece);
        // `retireSession` clears `sentBriefing`, so the new one is briefed in
        // full. Late on purpose: a refused, abandoned or empty press costs
        // nothing (`test_freshEyesWithNothingToReadKeepsTheWarmSession`).
        if freshEyes { retireSession() }
        guard let runner = ensureRunner(model: environment.model) else {
            runState = .failed(
                docId: docId, kind: kind,
                failure: .sessionDied(
                    detail: "the compiler's bridge config could not be written"),
                at: Date())
            return
        }

        let preamble = CompilerPrompt.sessionSystemPreamble(projectId: environment.projectId)
        let model = environment.model

        // Before the derivation, or a second ⌘R in those seconds would run the
        // same delta twice.
        runState = .running(docId: docId, kind: kind, checking: DeltaCounts(of: delta))
        // The writer's wait starts at the keystroke.
        runStartedAt = Date()
        runProgress = nil
        // Now: the stream stores notes against it before there is an answer.
        let runId = ULID.generate()
        // `?? marker`: an empty-after-marker delta must not nil the marker. **A
        // round records the marker it FOUND**, so the check's position never
        // jumps past prose it has not read.
        let lastOpId = kind == .check ? (delta.newestOpId ?? marker) : marker
        let deltaSummary = Self.summary(of: delta)
        Task { [weak self] in
            let world = await Self.resolveWorld(briefing, model: model, in: environment)
            // The second, longest suspension.
            guard let self, self.runGeneration == generation else { return }

            // Elided only while the SAME process reads (`sessionEpoch`), asked
            // after the derivation, which can outlive a session.
            let previousHash = self.sentBriefing[docId].flatMap {
                $0.epoch == runner.sessionEpoch ? $0.hash : nil
            }
            // **The door says the loop**: each builder's signature omits the
            // other loop's inputs, so a round briefed as a check does not
            // compile. `checkMessage` has no `pass:`.
            let (message, briefingHash): (String, String?)
            switch kind {
            case .check:
                (message, briefingHash) = CompilerPrompt.checkMessage(
                    delta: delta,
                    world: world, essay: essay, bibleFacts: bibleFacts,
                    paletteListing: paletteListing, pinnedListing: pinnedListing,
                    reader: reader,
                    scenePosition: scenePosition,
                    dispositions: dispositions,
                    ask: ask,
                    lessons: lessons,
                    stage: briefedStage,
                    // A cold read is always the full letter.
                    freshEyes: freshEyes,
                    signals: briefedSignals,
                    previousBriefingHash: previousHash)
            case .round:
                (message, briefingHash) = CompilerPrompt.roundMessage(
                    delta: delta,
                    world: world, essay: essay, bibleFacts: bibleFacts,
                    paletteListing: paletteListing, pinnedListing: pinnedListing,
                    pass: roundPass,
                    scenePosition: scenePosition,
                    previousRound: previousRound,
                    dispositions: dispositions,
                    ask: ask,
                    lessons: lessons,
                    previousBriefingHash: previousHash)
            }

            // Armed just before the send: an abandoned run leaves nothing for a
            // stream to land in.
            self.streaming = StreamingRun(
                generation: generation, docId: docId, runId: runId, model: model,
                lastOpId: lastOpId, deltaSummary: deltaSummary,
                intentSnapshot: briefing?.statementText, readerName: readerName,
                passId: passId, round: round,
                scenePosition: scenePosition, stage: stage, dosage: dosage,
                ask: ask, freshEyes: freshEyes, kind: kind)
            runner.setPartialHandler { [weak self] chunk in
                self?.receivePartial(chunk, generation: generation)
            }
            // A retired session's late report is not this run's.
            runner.setProgressHandler { [weak self] progress in
                guard let self, self.runGeneration == generation else { return }
                self.runProgress = progress
            }

            let event = await runner.send(message: message, systemPreamble: preamble)
            await self.finish(event, docId: docId, runId: runId, lastOpId: lastOpId,
                              deltaSummary: deltaSummary,
                              intentSnapshot: briefing?.statementText,
                              editorName: editorName, readerName: readerName,
                              passId: passId, round: round,
                              scenePosition: scenePosition, stage: stage,
                              dosage: dosage, ask: ask,
                              freshEyes: freshEyes, kind: kind,
                              briefingHash: briefingHash, model: model,
                              generation: generation)
        }
    }

    // MARK: - The turn arriving

    // History: docs/history/compiler.md#orchestrator-receivepartial
    /// **One chunk of the answer, mid-turn**: accumulate, and read the lines it
    /// closed. A section is one line (`DiagnosticIngest.parseSection`); a line
    /// that is not one reads as nothing.
    ///
    /// **A PREVIEW, never the answer**: `DiagnosticsStore.preview` persists
    /// nothing and raises no badge, and `finish` REPLACES it via `parseAll`. A
    /// stream can be cut, doubled or absent, so nothing concluded from it may
    /// outlive the turn.
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
                },
                // The run's own dose: a question the short letter drops never
                // shows mid-check.
                dosage: run.dosage)
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
        // Every stamp is the run's carried value, as `finish` stamps the answer.
        // Nothing is minted or resolved yet: counts and timing are `nil`.
        diagnostics.preview(
            run: Self.record(id: runId, model: run.model, lastOpId: run.lastOpId,
                             deltaSummary: run.deltaSummary,
                             intentSnapshot: run.intentSnapshot,
                             passId: run.passId, round: run.round,
                             freshEyes: run.freshEyes,
                             kind: run.kind,
                             readerName: run.readerName,
                             outcome: run.outcome,
                             scenePosition: run.scenePosition,
                             stage: run.stage,
                             ask: run.ask,
                             mintedNotes: nil, openInOtherLanes: nil,
                             openInOtherLanesNoteIds: nil,
                             timing: nil),
            // Conformance strains only, as the report; the rest mints at
            // `finish` or not at all.
            diagnostics: run.outcome.sidecarDiagnostics, docId: docId)
    }

    /// **The two live-run facts, cleared together** and in lockstep with
    /// `runState`, wherever a run stops being live (spec 2026-09-09 §5).
    private func endLiveRun() {
        runStartedAt = nil
        runProgress = nil
    }

    /// Wherever a run ends without an answer: **no half-report survives.**
    private func discardStreamPreview() {
        guard let run = streaming else { return }
        streaming = nil
        guard run.isShowing else { return }
        // Its own kind: the other loop's standing run is untouched.
        diagnostics?.discardPreview(docId: run.docId, kind: run.kind)
    }

    // History: docs/history/compiler.md#orchestrator-record
    /// The run record: **one spelling, for the preview and the answer**, so
    /// the two cannot describe one check differently. Every keystroke-minted
    /// field is undefaulted, so no call site can omit one unnoticed. `stage`
    /// is `nil` for a round (`Letter.draftStage` tolerates it); the mint
    /// counts are `nil` for a preview only.
    private static func record(
        id: String, model: String, lastOpId: String?, deltaSummary: String,
        intentSnapshot: String?, passId: String?, round: Int?, freshEyes: Bool,
        kind: RunKind, readerName: String?,
        outcome: DiagnosticIngest.SectionedOutcome, scenePosition: ScenePosition,
        stage: DraftStage?, ask: String?, mintedNotes: Int?, openInOtherLanes: Int?,
        openInOtherLanesNoteIds: [String]?, timing: RunTiming?
    ) -> CompilerRun {
        // **The letter's stamps** (§3.4, §3.8): the run's own facts, never the
        // model's echo; no letter, no stamp. The stage line stays on the line
        // after the ask
        // (`CompilerRunCommandTests.test_theStageIsStampedBesideTheAskInTheOneRecordSpelling`).
        // `rawValue`: `Letter.stage` is a disk format.
        var letter = outcome.letter
        letter?.scenePosition = scenePosition.rawValue
        letter?.asked = ask
        letter?.stage = stage?.rawValue
        return CompilerRun(
            id: id, at: Date(), model: model, lastOpId: lastOpId,
            deltaSummary: deltaSummary, intentSnapshot: intentSnapshot,
            // So a run whose every note dangled does not wear the seal.
            droppedDangling: outcome.droppedDangling,
            clauseStatuses: outcome.conformance,
            truncatedReader: outcome.truncatedReader,
            passId: passId, round: round,
            // **Absent, not `false`**: readers ask `== true`, and a ⌘R's
            // sidecar stays byte-for-byte unchanged.
            freshEyes: freshEyes ? true : nil,
            // **Nothing declared, no verdict**, whatever the model said: the
            // sidecar must tell "never judged" from "held".
            intentDriftVerdict: intentSnapshot == nil ? nil : outcome.intentDriftVerdict,
            // So a run that queued questions is not read as finding nothing.
            mintedNotes: mintedNotes,
            // Engaged but held in another pass: not three zeroes.
            openInOtherLanes: openInOtherLanes,
            openInOtherLanesNoteIds: openInOtherLanesNoteIds,
            // **Always stamped**: `nil` is a pre-field record, read only by
            // `CompilerRun.effectiveKind`.
            kind: kind,
            readerName: readerName,
            letter: letter,
            // What the turn cost (spec 2026-09-09 §5); `nil` when unmeasured.
            timing: timing)
    }

    /// **What the last round in this lane raised**, or `nil`. Only a prior
    /// round with the SAME `passId` briefs the next (`SinceLastRound`'s
    /// decision 1), and only the standing run: older rounds keep fingerprints,
    /// not prose.
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
            // A sectionless v1 note has no identity (`RoundFingerprint.make`).
            guard let kind = note.kind else { return nil }
            return CompilerPrompt.PriorNote(
                body: note.body, kind: kind,
                // `DiagnosticsStore.live`'s rule; a gone paragraph is edited.
                sinceEdited: note.anchor.map {
                    environment.liveParagraphText(docId, $0.paragraphId) != $0.anchorText
                } ?? false)
        }
        return CompilerPrompt.PriorRound(record: standing.record, notes: notes)
    }

    /// The declared world: the cached reading of exactly this text, else one
    /// derived now. **The lazy trigger's only production site** (AREA.md, "the
    /// derivation trigger"); never on a timer or save. `nil` is non-fatal: the
    /// run goes ahead on the essay alone.
    private static func resolveWorld(
        _ briefing: IntentBriefing?, model: String, in environment: Environment
    ) async -> DerivedWorld? {
        guard let briefing else { return nil }
        if let cached = environment.cachedWorld(briefing) { return cached }
        return await environment.deriveWorld(briefing, model)
    }

    /// The delta's words, matched by the bible slice. A revision's BEFORE text
    /// counts: a character just written out is what continuity is for.
    static func prose(of delta: CompilerDelta) -> String {
        (delta.new.map(\.text)
            + delta.revised.map(\.prior)
            + delta.revised.map(\.text))
            .joined(separator: "\n")
    }

    /// End the turn in flight; the session stays warm. A run still closing its
    /// burst or deriving has no turn (`cancelCurrentRun` no-ops), so it is
    /// abandoned by generation, as `shutdown()` does.
    func cancel() {
        let hasUnsentRun = isRunning && runner?.isRunning != true
        runner?.cancelCurrentRun()
        // Here too, not only in `finish`: its continuation is a tick later, and
        // a runner may answer a cancel without a failure.
        discardStreamPreview()
        guard hasUnsentRun else { return }
        runGeneration &+= 1
        isPreparingRun = false
        runState = .idle
        // A SENT run's cancel ends the live run in `finish` instead.
        endLiveRun()
    }

    /// End the session: toggle off, project close, app quit. **Not optional**:
    /// `ClaudeCLISession` cannot reap its child from `deinit`, so a released
    /// session is a live, billing process.
    func shutdown() {
        retireSession()
        // A run with no session yet is abandoned by generation.
        runGeneration &+= 1
        isPreparingRun = false
        discardStreamPreview()
        // A cut turn would read "running" forever; a REPORTED failure keeps
        // its banner.
        if isRunning {
            runState = .idle
            endLiveRun()
        }
    }

    /// Close-the-window: shut down and drop the object graph. Not
    /// `shutdown()`, after which ⌘R must still work once Claude is back on.
    func detach() {
        shutdown()
        environment = nil
        diagnostics = nil
    }

    // MARK: - The turn coming back

    // History: docs/history/compiler.md#orchestrator-finish
    /// **`async` because the run is not over until its notes are written**:
    /// `.idle` before the mint's appends land would call the check finished.
    /// The mint cannot throw or fail the run.
    ///
    /// **`generation` is re-checked after the mint**: a Cancel inside it lets
    /// a newer ⌘R go live, and writing `sentBriefing` and `runState` over that
    /// run would mis-brief its session and call it idle.
    private func finish(
        _ event: CompilerRunEvent, docId: String, runId: String, lastOpId: String?,
        deltaSummary: String, intentSnapshot: String?,
        editorName: String, readerName: String?,
        passId: String?, round: Int?,
        scenePosition: ScenePosition, stage: DraftStage?, dosage: LetterDosage,
        ask: String?, freshEyes: Bool, kind: RunKind, briefingHash: String?,
        model: String, generation: Int
    ) async {
        switch event {
        case .started:
            // Unreachable: `send` resolves with a terminal event, and chunks
            // arrive through the partial handler.
            return

        case .failed(let failure):
            // **A retired session's failure is not this run's**: `send`
            // resolves only after the killed process's grace, when a newer run
            // may be live. A Cancel does not bump the generation, so its own
            // failure lands.
            guard runGeneration == generation else { return }
            // Marker and briefing hash stay put: nothing was checked.
            discardStreamPreview()
            runState = failure.isTheWritersOwnDoing
                ? .idle
                : .failed(docId: docId, kind: kind, failure: failure, at: Date())
            endLiveRun()

        case .resultText(let text):
            // **The whole turn REPLACES the stream**, never folds into it, so a
            // restated section shows once and an unterminated last one counts.
            guard let outcome = DiagnosticIngest.parseAll(
                resultText: text, runId: runId, docId: docId,
                liveParagraphText: { [weak self] paragraphId in
                    self?.environment?.liveParagraphText(docId, paragraphId)
                },
                // **Where the short letter is made short** (constraint 24),
                // above the mint, so a dropped question never becomes a `.query`.
                dosage: dosage)
            else {
                guard runGeneration == generation else { return }
                discardStreamPreview()
                runState = .failed(docId: docId, kind: kind, failure: .unusableOutput, at: Date())
                endLiveRun()
                return
            }

            // **The split**: a strain stays in the report beside its clause;
            // continuity questions and reader reports outlive the check and
            // go to the annotation layer. One finding, one home. **Mint BEFORE
            // the record**, which carries the count, or the pane could say
            // "Nothing to flag" over three queued notes.
            let notes = outcome.mintable
            var mint = MintOutcome.nothing
            if !notes.isEmpty, let environment {
                mint = await environment.mintAnnotations(
                    notes,
                    CompilerMintContext(
                        docId: docId, runId: runId, passId: passId, round: round,
                        freshEyes: freshEyes,
                        // The keystroke's signer; "Claude" comes from
                        // `AuthorReader.nobody.editorName`, keeping
                        // `passlessEditorName`'s one production use.
                        editorName: editorName))
            }
            // See the doc comment.
            guard runGeneration == generation else { return }

            let run = Self.record(
                id: runId, model: model, lastOpId: lastOpId,
                deltaSummary: deltaSummary, intentSnapshot: intentSnapshot,
                passId: passId, round: round, freshEyes: freshEyes,
                kind: kind, readerName: readerName,
                outcome: outcome, scenePosition: scenePosition, stage: stage, ask: ask,
                mintedNotes: mint.minted,
                openInOtherLanes: mint.openInOtherLanes,
                openInOtherLanesNoteIds: mint.openInOtherLanesNoteIds,
                // The one stamp not known until the answer lands.
                timing: runner?.lastTurnTiming)
            // Dropped, not discarded: `replace` supersedes the preview, and a
            // discard first would blink the report.
            streaming = nil
            diagnostics?.replace(
                run: run, diagnostics: outcome.sidecarDiagnostics, docId: docId)
            // Silently: the bible is a ledger the writer acts on, not a report.
            if !outcome.facts.isEmpty {
                environment?.recordFacts(outcome.facts)
            }
            if let briefingHash, let runner {
                sentBriefing[docId] = (briefingHash, runner.sessionEpoch)
            }
            runState = .idle
            endLiveRun()
        }
    }

    // MARK: - The session

    /// The warm session, spawned lazily on the first run, with its
    /// `--mcp-config` written once per session and deleted with it.
    private func ensureRunner(model: String) -> CompilerRunner? {
        if let runner {
            // The model changed since the spawn; safe here, between turns.
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

    /// End the session and everything scoped to it, leaving `runState` alone:
    /// `shutdown()` minus the surface.
    private func retireSession() {
        runner?.shutdown()
        runner = nil
        runnerModel = nil
        if let configURL {
            try? FileManager.default.removeItem(at: configURL)
        }
        configURL = nil
        // A new process has read nothing; nothing may be elided.
        sentBriefing.removeAll()
    }

    /// The run record's one-line description of what was checked.
    static func summary(of delta: CompilerDelta) -> String {
        "\(delta.new.count) new, \(delta.revised.count) revised \u{00b6}"
    }
}
