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
    /// (`RoundNarrative.checkingCopy`), the way every other line it says is.
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
        /// A round asked for from the review board never started, because the
        /// piece its chip names did not open inside `RunWhenDocumentOpens`'
        /// bound. Denver's 2026-08-18 ruling: the drop used to be a log line
        /// and nothing else, so a chip press produced no round, no error and
        /// no word — indistinguishable from a control that does nothing. The
        /// only acknowledgment here that reports a FAILURE rather than a
        /// start, which is why it says what to do next.
        case pieceWouldNotOpen
        /// A round was asked for on a piece with no STAGE — unassigned, or
        /// parked in a pass the writer has since retired. The seat does not
        /// enter into it: the coach reads checks, and a round with no lane is
        /// a numbered entry in nothing (`RoundEditor`). The second
        /// acknowledgment that reports a FAILURE rather than a start, and it
        /// says what to do next for the same reason `pieceWouldNotOpen` does.
        case noEditor

        /// The capsule's word. Kept beside the case rather than in the window
        /// that draws it, so all five sentences are assertable without a
        /// mount — and so the difference between them cannot be lost in a
        /// view's `switch`.
        var flashLabel: String {
            switch self {
            case .started: return "Checking\u{2026}"
            case .alreadyChecking: return "Still checking\u{2026}"
            case .freshEyes: return "Reading whole\u{2026}"
            case .pieceWouldNotOpen: return "Couldn\u{2019}t open the piece \u{2014} try again."
            case .noEditor: return "Set a pass to run a round."
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
        /// `ReviewPass.name` — the pass as the writer named it, which is the
        /// second half of the briefing's role frame ("this manuscript's
        /// Copyedit editor") and the whole content of the fallback when the
        /// pass has no brief. Carried with the rest for `editorName`'s reason:
        /// a rename between the keystroke and the send would otherwise frame
        /// the round as a pass the round is not.
        let name: String
        /// `ReviewPass.effectiveEditorName` — never nil, because every pass has
        /// a name to fall back to.
        let editorName: String
        /// `ReviewPass.effectiveBrief`. **Threaded in Task 3 and read in Task
        /// 4**: the briefing is the next task's, and resolving it in a second
        /// place then would be the drift this type exists to prevent.
        let brief: String?
        /// Whether this pass is the **coach's seat** rather than a rung of the
        /// ladder (editorial letter P1, spec §4.1). Resolved once, in
        /// `AuthorReader` — the CHECK's reader, and the only verb that can
        /// carry it, since a round's frame is always a stage's (two loops P1
        /// Task 2) — and read by `CompilerPrompt.passSection`, which
        /// frames a coach as a teacher and a stage as an editor. She is a pass
        /// in every other respect the run cares about — a name, an editor, a
        /// brief — so a second branch on this flag would be a second place the
        /// seat stops behaving like a pass. No census guards that; the claim
        /// here is about what SHOULD branch, not a counted fact.
        ///
        /// **What she is NOT is a lane** (two loops P1 Task 2). She held one
        /// under `PieceReader`, and numbered rounds and pass-stamped notes
        /// came with it; now `beginRun` stamps a lane for a round alone, so a
        /// check she reads files nowhere however completely she frames it.
        ///
        /// Defaulted in the initializer so every construction site that
        /// predates the seat still compiles and still means "a stage".
        let isCoach: Bool

        init(id: String, name: String, editorName: String, brief: String?,
             isCoach: Bool = false) {
            self.id = id
            self.name = name
            self.editorName = editorName
            self.brief = brief
            self.isCoach = isCoach
        }
    }

    /// What one round's mint actually did — beside `Environment.mintAnnotations`
    /// below, because it is that closure's answer and nothing else's.
    ///
    /// **Two numbers rather than one, because the dedupe has two outcomes and
    /// only one of them used to be reportable** (#42 F-H). A finding the mint
    /// refused is not nothing happening: it is a finding the writer is already
    /// holding. When they are holding it in the lane the round was run in, the
    /// since-line already accounts for it as *persisting*. When they are
    /// holding it in ANOTHER pass's lane, every count on that line is zero and
    /// the report used to say so over a round that engaged the question.
    struct MintOutcome: Equatable, Sendable {
        /// Notes really appended to the document — after the dedupe dropped
        /// what was already open, and after any that could not be placed
        /// failed their own append.
        let minted: Int
        /// Distinct findings this round raised that the dedupe refused and
        /// **no lane holding them is this round's own** — own-lane presence
        /// wins, because one fingerprint can be held by two open notes at once
        /// (`CompilerEnvironment+Project`'s mint loop spells the shape). A
        /// finding standing in the round's own lane is the *persisting* case,
        /// already on the since-line, and counting it here as well would tell
        /// the writer one finding is two.
        ///
        /// Per FINDING, not per matched note: two notes holding one fingerprint
        /// are one thing the writer is holding elsewhere.
        let openInOtherLanes: Int

        /// A mint that did not happen: no document to write to, or no note
        /// worth writing.
        ///
        /// **Zero, and indistinguishable on the wire from a run that minted
        /// nothing** — `finish` records whatever it gets, so both store `0`.
        /// The `nil` that `CompilerRun.mintedNotes`/`openInOtherLanes` document
        /// comes from the PREVIEW path alone (and from records written before
        /// those fields existed); it is never this value.
        static let nothing = MintOutcome(minted: 0, openInOtherLanes: 0)
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
        /// **The lessons ledger, whole** (`Statement.Kind.lessons`, editorial
        /// letter P2 Task 4) — the writer's own record of what they are
        /// working on, what they have settled, and what they have retired.
        /// `nil` is a project with no ledger, which is every project until the
        /// writer keeps their first lesson; the briefing simply carries none.
        ///
        /// **It takes nothing, and it is the one closure here that does.** The
        /// ledger has project scope by construction — `StatementConvention`
        /// answers no path for a document-scoped one — so a docId parameter
        /// would be an argument this closure could only ignore, and a seam
        /// suggesting a per-piece ledger that cannot exist.
        ///
        /// Defaulted to nothing, on `activePass`/`projectType`'s rule, so
        /// every `Environment` built before the ledger existed still compiles
        /// and still runs.
        var lessons: @MainActor () -> String? = { nil }
        /// **Who reads this piece, for THIS verb** — asked once per run at the
        /// keystroke (two loops P1 Task 2).
        ///
        /// **The kind is a parameter because the two loops have two
        /// resolutions**, and that is the whole of this milestone's first
        /// half. A `.check` is `AuthorReader` — the coach while her seat is
        /// held, else nobody — and never reads the review board's memory. A
        /// `.round` is `RoundEditor` — the stage the writer put this piece in,
        /// validated against the ladder — and is never the coach. Answering
        /// one question for both verbs is what filed an Author ⌘R as a
        /// numbered round in a lane the writer was not standing in.
        ///
        /// Already validated against the project's live pass list by whoever
        /// answers: a lane is a pass that exists, and a run filed against a
        /// retired id would be a round nothing can ever compare.
        ///
        /// `nil` means two different things by kind, and both are handled at
        /// the one call site. For a `.check` it is the passless lane — an
        /// ordinary M2 ⌘R, which mints no round number at all rather than
        /// round 1 of nothing. For a `.round` it is a REFUSAL:
        /// `runRequested` flashes `.noEditor` and starts nothing.
        ///
        /// Defaulted so that every `Environment` built before rounds existed
        /// still compiles: the answer it gives is the passless lane, which is
        /// exactly what those runs were.
        ///
        /// **It answers with the whole pass, not its id** (M4 P1 Task 3): the
        /// lane, the editor's name and the brief are resolved together here and
        /// nowhere else, so the round's filing, the notes' authorship and the
        /// briefing cannot describe different passes.
        var reader: @MainActor (String, RunKind) -> ActivePass? = { _, _ in nil }
        /// **The project's own type**, for the letter's scene position (spec
        /// §3.4, editorial letter P1 Task 3). A screenplay moves by scenes in
        /// the strong sense by its form; everything else reads as prose until
        /// the writer's own intent says otherwise.
        ///
        /// Keyed by docId like every other closure here even though the answer
        /// is project-wide: the caller has a document in hand, and a
        /// project-wide signature would be the one closure on this type that
        /// takes nothing, which is a seam a Collection's per-piece answer would
        /// later have to break.
        ///
        /// Defaulted to `nil` — read as prose — so every `Environment` built
        /// before the scene position existed still compiles and still runs.
        /// Those runs get the weak form, which is what a run with nothing
        /// declared about form should get.
        var projectType: @MainActor (String) -> ProjectType? = { _ in nil }
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
        /// **What the annotation layer already holds about this piece** (M4 P1
        /// Task 4) — the compiler-authored notes on it and what the writer has
        /// done about each, as the briefing's dispositions section.
        ///
        /// Asked once, in `beginRun`'s synchronous prefix, for
        /// `previousRound`'s reason: this is the last instant at which the
        /// answer describes the round that is starting rather than the round
        /// that is under way. A value rather than the `Document` — nothing here
        /// holds one across a subprocess turn (tripwires 3, 6).
        ///
        /// Its counterpart below writes what this run adds. The two are the
        /// same layer read and written a turn apart, which is what makes the
        /// dispositions briefing the warm path's duplicate guard and
        /// `mintAnnotations`' own dedupe the cold one.
        ///
        /// Defaulted to nothing so every `Environment` built before the
        /// briefing existed still compiles and still runs — those runs simply
        /// brief no dispositions, which is what they did.
        var annotationContext: @MainActor (String) -> [CompilerAnnotationDisposition]
            = { _ in [] }
        /// **Where a continuity question and a reader's report actually go**
        /// (M4 P1 Task 3) — the annotation layer, not the sidecar.
        ///
        /// Called once per finished run, after `replace`, with everything the
        /// run raised that is not a conformance strain. Answers how many notes
        /// it really minted, which is not the count it was handed: the dedupe
        /// backstop drops a finding already open on the document, and a note
        /// whose paragraph the writer deleted between parse and mint fails its
        /// own append — and, beside it, how many of those refusals were
        /// findings open in ANOTHER pass's lane (`MintOutcome`, #42 F-H).
        ///
        /// **It cannot fail the run**, and its signature says so: no `throws`,
        /// a plain value rather than a result. The compiler is a background
        /// convenience (spec §3.2) and a note that could not be written is not
        /// a reason to tell the writer their check failed.
        ///
        /// Defaulted to a no-op returning `.nothing` so every `Environment`
        /// built before the mint existed still compiles and still runs — those
        /// runs simply write no annotations, which is what they did.
        var mintAnnotations: @MainActor ([CompilerNote], CompilerMintContext) async -> MintOutcome
            = { _, _ in .nothing }
        /// What this run established, on its way into the bible. Never a note:
        /// a fact-candidate lands silently and surfaces in the Intent pane's
        /// bible stratum, where the writer's three actions reach it.
        var recordFacts: @MainActor ([BibleFact]) -> Void
        /// What the writer pinned beside this document — linked research
        /// unioned with the canvas cluster (`PinnedReferences`, §7.2) — as
        /// "title (id) — tool" lines, grouped exactly as the `PinnedShelf`
        /// arranges them: a `## <title>` line ahead of each titled section,
        /// no header over an untitled one (`pinnedListingLines`). Empty is a
        /// valid answer (nothing pinned, or the Plan side never opened);
        /// `CompilerPrompt` omits the whole section rather than showing
        /// nothing.
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
        /// **Who read this run** — the frame, minted at the keystroke
        /// (`beginRun`) and carried so the preview cannot describe a different
        /// reader from the answer that supersedes it. It travels WHOLE (M4
        /// P1) — the editor's name and the brief are resolved with it and
        /// never re-asked, because the writer can move the piece to another
        /// pass, or vacate the seat, while the run is in flight.
        let activePass: ActivePass?
        /// **The LANE, which is not the reader's id** (two loops P1 Task 2).
        /// A check has a reader — the coach signs what it writes — and no
        /// lane at all, so this is `nil` for every check and the frame beside
        /// it is not. Stored rather than derived from `activePass`, because a
        /// derivation here would be a second place the decision is made, and
        /// the two would part company the first time either changed.
        let passId: String?
        let round: Int?
        /// **The letter's scene position, derived at the keystroke and
        /// carried** (spec §3.4). Carried for the lane's own reason: the
        /// writer can switch passes — and edit their intent — while the check
        /// runs, and the run was briefed on the position it started in. The
        /// preview stamps it on the letter and so does `finish`, so a preview
        /// and the answer that supersedes it can never disagree about what
        /// form the model was told this piece takes.
        let scenePosition: ScenePosition
        /// **The draft stage this run's delta reads as, derived at the
        /// keystroke and carried** (spec §3.8). Carried on the scene
        /// position's own terms — the writer keeps typing while the check
        /// runs, and the stage is a fact about the delta the run was READ on,
        /// not about the document by the time the answer lands. The preview
        /// stamps it and so does `finish`, so the two cannot disagree about
        /// what the model was asked for.
        ///
        /// **`nil` for a round** (two loops P1 Task 4): the stage is derived
        /// for a check alone, so a round has none to carry rather than one it
        /// carries and never uses.
        let stage: DraftStage?
        /// **How much letter that stage earned** (global constraint 24), the
        /// same value the briefing stated, carried so ingest can enforce it.
        /// Derived rather than re-asked at `finish`: `dosage(freshEyes:)`
        /// takes the run's own fresh-eyes flag, and a second derivation is a
        /// second place the ask and the enforcement could drift apart.
        let dosage: LetterDosage
        /// **What the writer asked of this run, read at the keystroke and
        /// carried** (P2 Task 3). Carried for the lane's and the position's
        /// reason, plus one of its own: the field is expected to be cleared
        /// or rewritten the moment the check ends — a writer asks, reads the
        /// answer, asks something else — so the run must stamp what it was
        /// actually briefed on rather than whatever the field says by then.
        let ask: String?
        /// Whether this round was read cold (⌘⇧R) — carried for the same
        /// reason the lane is: the preview and the answer must describe one
        /// round, and the pane draws its header off this stamp.
        let freshEyes: Bool
        /// **Which loop asked for this run**, minted from the persona at the
        /// keystroke and carried for the lane's own reason: the writer can
        /// switch personas while the check runs, and the run belongs to the
        /// loop that started it. The preview stamps it and so does `finish`,
        /// so the two cannot disagree about which verb this was.
        let kind: RunKind
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
    /// - Parameter kind: **which loop asked** (two loops P1). Required and
    ///   undefaulted, on `record`'s rule: a default would let a call site
    ///   quietly file a round as a check, and nothing about the run would look
    ///   wrong. It is minted from the key window's persona in exactly one
    ///   place — `CompilerRunModifier`, the only site holding a persona — and
    ///   every other caller is a surface that belongs to one loop by
    ///   construction and says so literally. **Nothing reads it yet**: P1 Task
    ///   1 carries and stamps it, and the two verbs part company in Task 2.
    func runRequested(docId: String, kind: RunKind, freshEyes: Bool = false) {
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

        // **A round needs an editor, and there is no substitute for one** (two
        // loops P1 Task 2). A round is a numbered entry in a named lane; with
        // no stage on this piece there is no lane, so there is nothing to
        // number and nothing a later round could be measured against. The
        // coach is not a fallback here — she reads checks (`AuthorReader`),
        // and filing her a round is how an unassigned piece came to have a
        // lane at all.
        //
        // **Above the flash, so the refusal is the ONLY thing the press
        // does.** Nothing is spawned, no marker moves, no `runState` changes:
        // the writer gets one sentence telling them what to set, and the
        // window is exactly as they left it. It sits below the `isRunning`
        // guard on purpose — a press arriving mid-run is still "still
        // checking", whatever the piece's lane says.
        if kind == .round, environment.reader(docId, .round) == nil {
            environment.onRunAcknowledged(.noEditor)
            return
        }

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
                          kind: kind, freshEyes: freshEyes,
                          environment: environment, diagnostics: diagnostics)
        }
    }

    /// The run proper, from the delta on — everything that was `runRequested`'s
    /// body before the burst-flush hop moved in above it.
    private func beginRun(
        docId: String, reading: DocumentReading, generation: Int, kind: RunKind,
        freshEyes: Bool,
        environment: Environment, diagnostics: DiagnosticsStore
    ) {
        let marker = diagnostics.lastOpId(docId: docId)
        // **A cold read does not consult the marker** (M3-P3 §6). `since: nil`
        // is `DeltaBuilder`'s "everything is new", which is what makes ⌘⇧R
        // over untouched prose a real read where ⌘R is honestly `nothingNew`.
        // The marker is still READ above and still advances below — a fresh
        // run leaves the document exactly as any run does, or the ⌘R after it
        // would re-read the piece a second time.
        //
        // **And a ROUND does not consult it either — ever** (two loops P1 Task
        // 4, spec §4.5). The marker is the CHECK's: it records what the writer
        // has read of their own prose, and a round is somebody else's read of
        // the piece entire. `since: nil` is the same "everything is new" a
        // cold read gets, for a different reason — a round has no history of
        // its own to diff against, and what changed since the last round
        // reaches it through the prior-round and dispositions sections rather
        // than through a diff.
        let delta = DeltaBuilder.delta(
            ops: reading.ops, since: (freshEyes || kind == .round) ? nil : marker,
            currentParagraphs: reading.paragraphs, sequence: reading.sequence)

        guard !delta.isEmpty else {
            // Ops may still have landed that changed no prose. Passing them
            // costs nothing and saves every later run from re-reading them.
            //
            // **The CHECK's alone** (Task 4). A round is here only over a
            // piece with nothing in it, and moving the marker for it would
            // consume, on the round loop's behalf, ops the writer's own next
            // ⌘R is owed — the check would open on a document whose opening
            // paragraphs it has never read and nothing on screen would say so.
            if kind == .check, let newest = delta.newestOpId {
                diagnostics.advanceMarker(to: newest, docId: docId)
            }
            runState = .nothingNew(docId: docId, at: Date())
            return
        }

        // **Maugham's own observation of the writer's process, at the
        // keystroke** (spec §5). Computed off `reading` and nothing else —
        // `ProcessSignals` takes the ops, the sequence and a `now`, which is
        // exactly what `DeltaBuilder` was already given a line above, so this
        // needs no `Environment` closure of its own and cannot disagree with
        // the delta about which instant of the document it describes.
        //
        // Below the empty-delta guard with the lane and the round, and for the
        // same reason: a ⌘R with nothing new is not a round, and observing the
        // writer's practice for a check that never happened would put numbers
        // behind a letter nobody is going to read.
        //
        // `DeltaBuilder.ordered` therefore runs TWICE per ⌘R — once inside
        // `DeltaBuilder.delta` above and once inside this initializer — and
        // that is accepted rather than overlooked: it measured 1 ms, and the
        // two readers are independent pure values over the same ops. Handing
        // both a pre-sorted array would couple the delta's shape to the
        // signals' and give a later change to one a way to move the other
        // silently. Revisit only if it stops being 1 ms.
        //
        // **The CHECK's, both of its readers** (two loops P1 Task 4): the
        // signals brief the check and the stage they feed doses it, and a
        // round wants neither, so a round takes no reading at all rather than
        // computing one nothing downstream would look at.
        let signals = kind == .check
            ? ProcessSignals(ops: reading.ops, sequence: reading.sequence, now: Date())
            : nil
        // **The stage is derived, never set** (global constraint 23, spec
        // §3.8). Two inputs, both already in hand: what this delta is made of,
        // and whether the frontier moved in the latest sitting. The writer is
        // never asked, no manifest field records it, and the only persisted
        // trace is the stamp `record` puts on the letter.
        //
        // **And it is derived for a CHECK alone** (spec §4.8). The stage says
        // how far along the writer's own draft is; a round is always the full
        // letter, because its pass brief is what decides which parts an editor
        // writes. So a round derives none, states none and stamps none —
        // `nil` here rather than a stage the dose below then has to ignore,
        // which would leave two places to remember the rule.
        let stage: DraftStage? = kind == .check
            ? DraftStage.derive(counts: DeltaCounts(of: delta), signals: signals)
            : nil
        // **Stated in the briefing AND enforced at ingest** (global constraint
        // 24) — derived once, here, so the two ends cannot ask for different
        // amounts of letter. Fresh Eyes is always the full letter, which is why
        // the flag is an argument rather than something `parseLetter` re-reads.
        // No stage — a round — is `.full` for that rule's own reason: the dose
        // is a stage's to shorten, and nothing else may.
        let dosage = stage?.dosage(freshEyes: freshEyes) ?? .full

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
        // **The frame is resolved WHOLE, and this is the one site** (M4 P1
        // Task 3). The reader's editor signs the notes this run mints and
        // their brief is what it is briefed on; asking for either again later
        // would read a project the writer may have moved on since.
        //
        // **Asked for THIS verb** (two loops P1 Task 2): a check is the
        // coach's or nobody's, a round is the stage's. A round with no editor
        // never reaches here at all — `runRequested` refused the press — so
        // `nil` at this point is always a check with a vacated seat.
        let activePass = environment.reader(docId, kind)
        // **A CHECK is filed in no lane, whoever read it.** The coach is a
        // reader and not a lane: her frame briefs the run and signs its notes,
        // and stamping her id here would enter an Author ⌘R into a numbered
        // lane the writer was never standing in — the exact defect the two
        // resolutions split apart. Only a round has a lane, and by the guard
        // above a round always has one.
        let passId = kind == .round ? activePass?.id : nil
        // A passless run mints no number at all rather than round 1 of
        // nothing (decision 1: the passless lane is a lane, and an ordinary M2
        // run is what it holds). Every check is now such a run.
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
        // (`RoundNarrative.sinceLastRoundLine`), so the briefing and the
        // report agree about what this round was measured against — nothing.
        //
        // **And a CHECK is briefed on none of it either** (two loops P1 Task
        // 2). "What the last round raised, and what became of each" is the
        // round loop's question; a check is the writer's own read of what they
        // have just written, and handing it a lane's history would make ⌘R
        // answer for a loop it does not belong to. Asked on the kind rather
        // than on `passId == nil`, which is the same answer today by
        // arithmetic and would stop being one the moment a check acquires a
        // lane of its own.
        let previousRound = (freshEyes || kind == .check) ? nil : Self.previousRound(
            inLane: passId, docId: docId, diagnostics: diagnostics, environment: environment)

        // **What the writer has already done about this piece's notes**, read
        // at the same instant and omitted on the same terms (M4 P1 §5.5).
        //
        // Two reasons it is here rather than beside the send. It is a read of
        // the live annotation layer, and this run is about to WRITE into that
        // layer at `finish` — asked later, it would hand the model this round's
        // own notes as notes it had already seen. And the writer disposes of a
        // note whenever they like, including while a check runs; the round was
        // begun against the queue as it stood, and a mid-run answer belongs to
        // the next ⌘R.
        //
        // **A cold read is briefed on none of it, exactly as it is briefed on
        // no previous round.** Fresh eyes means a reader who has not seen this
        // piece, and a list of everything they supposedly raised and the
        // writer answered is the opposite of that. The duplicate guard on that
        // path is `mintAnnotations`' own fingerprint dedupe, which is why it
        // is load-bearing rather than a backstop there.
        let dispositions = freshEyes ? [] : environment.annotationContext(docId)

        // **What the writer asked of this run**, read at the same instant as
        // the lane and the dispositions and carried for the same reason: they
        // can clear the field while the check runs, and the run was briefed on
        // what stood when they pressed ⌘R.
        //
        // **Asked of the store rather than through an `Environment` closure.**
        // The orchestrator already holds `DiagnosticsStore` — it is the
        // parameter this method is given — and the ask lives there beside the
        // refusal memory, so a closure would be a second route to a store
        // already in hand.
        //
        // **A cold read is briefed on it, where it is briefed on no round and
        // no dispositions.** Fresh eyes means a reader who has not seen the
        // piece, not a reader who has not met the writer: the ask is the
        // writer's own question about the prose, and refusing to hear it on
        // ⌘⇧R would answer a question nobody asked while ignoring the one
        // they did.
        // **Whatever is still in the ask field counts as asked** (P2 Task 7,
        // fix round 1). ⌘R is a menu command and never touches the first
        // responder, so without this a worry typed and not submitted would
        // watch its own round go out briefed on the previous ask. Here rather
        // than in the key handler because every trigger passes through this
        // one line — the two keystrokes, the cockpit's buttons and the
        // cold-start offer — and because a pending draft equal to the stored
        // ask writes nothing.
        diagnostics.commitPendingAsk(docId: docId)
        let ask = diagnostics.ask(docId: docId)

        // **The ledger, read beside the intent** and hashed with it (Task 4):
        // both are declarations the writer has made rather than per-run
        // context, so both diff in as one unit and a round that changed
        // neither is told so in one line.
        let lessons = environment.lessons()
        let briefing = environment.intent(docId)
        // The essay half alone (spec §3.2). **This is the atomic switch**: the
        // strata below the essay reach the run as the derived clauses resolved
        // below, and briefing them as prose as well would put the same
        // declaration in front of the model twice — see
        // `CompilerRunCommandTests.test_rulingsAreBriefedAsClausesNotProse`.
        let essay = briefing.map { StatementEssay.half(of: $0.statementText) }
        // **The letter's scene position, resolved here with the lane** (spec
        // §3.4). Three things the writer owns decide it, and all three are
        // read at the keystroke for the lane's own reason — the writer can
        // switch passes or edit their intent while the check runs, and the
        // run was briefed on the position it started in.
        //
        // **The WHOLE statement, not `essay` above.** Task 9's Add-to-intent
        // offer files "Every scene turns." as a dated ruling under
        // `## Rulings`; derived over the essay half, the clause would land
        // where the derivation never looks, the offer would return every round
        // forever, and no strain would ever be raised. The prompt's own essay
        // section keeps the half — the strata below it reach the run as
        // derived clauses, and briefing them as prose too would declare the
        // same thing twice.
        let scenePosition = ScenePosition.derive(
            projectType: environment.projectType(docId),
            statement: briefing?.statementText,
            passBrief: activePass?.brief)
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
        //
        // **A round records the marker it FOUND** (two loops P1 Task 4). Its
        // own delta was built `since: nil`, so `newestOpId` is the newest op
        // in the document — writing that would advance the check's position
        // past prose the writer has never had read back to them. Carrying the
        // marker forward unchanged is what makes a round invisible to the
        // check loop while the two still share one standing record (Task 5
        // gives them a slot each; until then this is what keeps the check's
        // position from regressing OR jumping).
        let lastOpId = kind == .check ? (delta.newestOpId ?? marker) : marker
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
            // **Which loop asked, said by WHICH DOOR is used** (two loops P1
            // Task 4). The two builders are `runMessageV2` with their kind
            // fixed and the other loop's inputs absent from the signature —
            // there is no `previousRound` to hand a check and no `stage`,
            // `freshEyes` or `signals` to hand a round — so a round briefed as
            // a check is a compile error here rather than a diff arriving with
            // a stage's dose on it.
            let (message, briefingHash): (String, String?)
            switch kind {
            case .check:
                (message, briefingHash) = CompilerPrompt.checkMessage(
                    delta: delta,
                    world: world, essay: essay, bibleFacts: bibleFacts,
                    paletteListing: paletteListing, pinnedListing: pinnedListing,
                    pass: activePass,
                    scenePosition: scenePosition,
                    dispositions: dispositions,
                    ask: ask,
                    lessons: lessons,
                    stage: stage,
                    // The one thing the prompt needs the flag for: a cold read
                    // is always the full letter, so the stage section must not
                    // ask for the short one over a run ingest will let through
                    // whole.
                    freshEyes: freshEyes,
                    signals: signals,
                    previousBriefingHash: previousHash)
            case .round:
                (message, briefingHash) = CompilerPrompt.roundMessage(
                    delta: delta,
                    world: world, essay: essay, bibleFacts: bibleFacts,
                    paletteListing: paletteListing, pinnedListing: pinnedListing,
                    pass: activePass,
                    scenePosition: scenePosition,
                    previousRound: previousRound,
                    dispositions: dispositions,
                    ask: ask,
                    lessons: lessons,
                    previousBriefingHash: previousHash)
            }

            // **Armed immediately before the send, and never earlier.** A run
            // abandoned while its declared world derived — a subprocess, and
            // the longer of the two suspensions — must leave nothing for a
            // stream to land in.
            self.streaming = StreamingRun(
                generation: generation, docId: docId, runId: runId, model: model,
                lastOpId: lastOpId, deltaSummary: deltaSummary,
                intentSnapshot: briefing?.statementText, activePass: activePass,
                passId: passId, round: round,
                scenePosition: scenePosition, stage: stage, dosage: dosage,
                ask: ask, freshEyes: freshEyes, kind: kind)
            runner.setPartialHandler { [weak self] chunk in
                self?.receivePartial(chunk, generation: generation)
            }

            let event = await runner.send(message: message, systemPreamble: preamble)
            await self.finish(event, docId: docId, runId: runId, lastOpId: lastOpId,
                              deltaSummary: deltaSummary,
                              intentSnapshot: briefing?.statementText,
                              activePass: activePass, passId: passId, round: round,
                              scenePosition: scenePosition, stage: stage,
                              dosage: dosage, ask: ask,
                              freshEyes: freshEyes, kind: kind,
                              briefingHash: briefingHash, model: model,
                              generation: generation)
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
                },
                // **The dose the run was READ on, not one asked for again
                // here** (global constraint 24). The preview shows what the
                // report will show, so a question the short letter drops must
                // never appear on the pane mid-check and vanish when the
                // answer lands.
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
        diagnostics.preview(
            run: Self.record(id: runId, model: run.model, lastOpId: run.lastOpId,
                             deltaSummary: run.deltaSummary,
                             intentSnapshot: run.intentSnapshot,
                             passId: run.passId, round: run.round,
                             freshEyes: run.freshEyes,
                             // The verb the run was started as, stamped on the
                             // preview exactly as `finish` stamps it on the
                             // answer — a preview that disagreed would change
                             // which loop the report belonged to as the check
                             // ended.
                             kind: run.kind,
                             outcome: run.outcome,
                             // The position the run was briefed on, stamped on
                             // the preview's letter exactly as `finish` stamps
                             // it on the answer's — a preview that disagreed
                             // with the run superseding it would flip the
                             // letter's scene section under the writer as the
                             // check ended.
                             scenePosition: run.scenePosition,
                             // The stage the run was read on, stamped on the
                             // preview exactly as `finish` stamps it on the
                             // answer — the preview and the answer describe one
                             // check or they describe two.
                             stage: run.stage,
                             // The ask the run was briefed on, stamped on the
                             // preview exactly as `finish` stamps it on the
                             // answer — a preview that disagreed would change
                             // what the letter says it was asked as the check
                             // ended.
                             ask: run.ask,
                             // A preview has minted nothing: the notes it would
                             // mint are minted at `finish` or not at all, so
                             // `nil` here is "no mint has happened" rather than
                             // a claim that this run queued none — and the
                             // cross-lane count is the same fact seen from the
                             // other side, so it is nil for the same reason.
                             mintedNotes: nil, openInOtherLanes: nil),
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
    /// disagree. `stage` is undefaulted on that rule (P3 Task 4): a default
    /// would let a call site stamp `revising` over a drafting run's letter,
    /// and nothing about the record would look wrong. It is OPTIONAL as of two
    /// loops P1 Task 4 — a round derives no stage — and `nil` leaves
    /// `Letter.stage` unset, which is the field's own tolerated-missing case
    /// (`Letter.draftStage` reads an absent or unknown raw value as `nil`, and
    /// every surface that draws the word already handles it).
    /// `mintedNotes` and `openInOtherLanes` are `nil` for a preview — nothing
    /// is minted until the turn ends — and the finished run's real counts
    /// otherwise. Undefaulted for `passId`/`round`/`freshEyes`'s reason: a
    /// third call site that quietly omitted either would record a run claiming
    /// it queued nothing and engaged nothing.
    /// `kind` is undefaulted on the same rule, and its own case is sharper
    /// than the rest: the two loops are about to diverge on it, so a call site
    /// that could omit it would file a round as a check with nothing to
    /// notice.
    private static func record(
        id: String, model: String, lastOpId: String?, deltaSummary: String,
        intentSnapshot: String?, passId: String?, round: Int?, freshEyes: Bool,
        kind: RunKind,
        outcome: DiagnosticIngest.SectionedOutcome, scenePosition: ScenePosition,
        stage: DraftStage?, ask: String?, mintedNotes: Int?, openInOtherLanes: Int?
    ) -> CompilerRun {
        // **The letter's one mutable field, stamped here** (spec §3.4). The
        // position is the run's, not the model's: it is derived app-side at
        // the keystroke and the model is only told about it, so the record
        // must carry what the run decided rather than anything the answer
        // echoed back. Stamped in the one `record` spelling for the reason
        // every other field is — the preview and the final answer must
        // describe one check.
        //
        // A turn that answered no letter has nothing to stamp, and `nil` stays
        // `nil`: the position is a fact about a letter, not about a run.
        var letter = outcome.letter
        letter?.scenePosition = scenePosition.rawValue
        // **The letter's second stamp, beside the position and for the same
        // reason** (P2 Task 3): what the writer asked is the run's own fact,
        // read at the keystroke, and the record must carry it rather than
        // anything the answer echoed back. It is also what lets the section
        // say what was asked after the writer has cleared the field — which
        // they do the moment they have read the answer.
        letter?.asked = ask
        letter?.stage = stage?.rawValue
        // **The letter's third stamp, and it is deliberately on the line
        // touching the second** (spec §3.8, global constraint 23). The stage is
        // the same kind of fact as the position and the ask — the run's own,
        // derived at the keystroke, never echoed back by the model — so it is
        // stamped in the same place, and `CompilerRunCommandTests`'
        // `test_theStageIsStampedBesideTheAskInTheOneRecordSpelling` reads the
        // adjacency off this file. `rawValue` rather than the case, because
        // `Letter.stage` is a disk format: a rename reads back as `nil` on
        // every letter already written, which `Letter.draftStage` tolerates.
        //
        // A turn that answered no letter has nothing to stamp, exactly as with
        // its two siblings: the stage is a fact about a letter, not a claim
        // every run makes.
        return CompilerRun(
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
            intentDriftVerdict: intentSnapshot == nil ? nil : outcome.intentDriftVerdict,
            // **What this run put in the queue.** The pane's own report holds
            // conformance strains alone now, so without this a run that raised
            // three questions and no strain would be indistinguishable from a
            // run that found nothing — and the surface would say so.
            mintedNotes: mintedNotes,
            // **What this run engaged but could not queue, because the writer
            // is already holding it in another pass** (#42 F-H). The same
            // argument one field along: without it a round that re-raised a
            // question open in the Structural lane reads as three zeroes on
            // the since-line, which is a check that did engage the piece
            // reported as one that found nothing in it.
            openInOtherLanes: openInOtherLanes,
            // **Which loop asked** (two loops P1). Stamped in the one `record`
            // spelling for every other field's reason — the preview and the
            // answer must describe one verb, and a run whose kind changed at
            // the end would be a different verb's run as far as every record
            // downstream is concerned.
            //
            // **Stamped ALWAYS, and deliberately not on `freshEyes`'
            // absent-means-false terms.** There is no value here that means
            // the same as absent: `nil` is a record written before this field
            // existed, and `CompilerRun.effectiveKind` is the one place that
            // legacy is read.
            kind: kind,
            // **The sixth section, P1.** Read straight off the outcome, the
            // same way `intentDriftVerdict` is — the preview and the finished
            // answer describe the same turn's letter, and `nil` where no
            // section has answered it yet (Task 2 wires the parse).
            letter: letter)
    }

    /// **What the last round in this run's lane raised**, or `nil` when there
    /// is nothing this round can honestly be measured against.
    ///
    /// The lane rule, in one place (`SinceLastRound`'s decision 1): only a
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
    ///
    /// **`generation` is the run's own, and it is re-checked after the mint** —
    /// the third suspension this class carries a generation across, after the
    /// burst flush and the derivation, and the only one that resumes with
    /// writes still to do. A Cancel inside the mint window bumps the
    /// generation and sets `.idle`; the very next ⌘R is then a live run, and a
    /// finish resuming afterwards would write `sentBriefing` and `runState`
    /// over it — telling the new run's session it had already been briefed,
    /// and calling a check that is still going idle. Everything before the
    /// mint is synchronous with the turn's own resumption and needs no guard.
    private func finish(
        _ event: CompilerRunEvent, docId: String, runId: String, lastOpId: String?,
        deltaSummary: String, intentSnapshot: String?, activePass: ActivePass?,
        passId: String?, round: Int?,
        scenePosition: ScenePosition, stage: DraftStage?, dosage: LetterDosage,
        ask: String?, freshEyes: Bool, kind: RunKind, briefingHash: String?,
        model: String, generation: Int
    ) async {
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
                },
                // **Where the short letter is MADE short** (global constraint
                // 24). The briefing asked for it; this is what makes it true
                // whatever the model wrote — and it runs above the mint, so a
                // question the dose drops cannot reach the queue as a `.query`
                // either.
                dosage: dosage)
            else {
                discardStreamPreview()
                runState = .failed(docId: docId, failure: .unusableOutput, at: Date())
                return
            }

            // **The split, and it is the whole point of M4 P1's first plan.**
            // A conformance strain is read beside the clause it strains
            // against, so it stays in the report; a continuity question and a
            // reader's report are about the words and outlive the check, so
            // they leave for the annotation layer. One finding, one home — and
            // the two halves land in the same commit, because a build in which
            // a note appears in both is a build that asks the writer to answer
            // it twice.
            //
            // **The mint runs BEFORE the record is built, and the order is
            // load-bearing.** How many notes went to the queue is not knowable
            // until the mint has run — the dedupe drops what is already open,
            // and a note whose paragraph has gone fails its own append — and a
            // record written without that number leaves the pane free to say
            // "Nothing to flag" over a run that flagged three things. The
            // report waits out N op-log appends to be able to say what
            // happened, which is the right trade: a header that lies is worse
            // than one that is a few milliseconds late, and the writer is
            // watching "Checking…" the whole time either way.
            let notes = outcome.mintable
            var mint = MintOutcome.nothing
            if !notes.isEmpty, let environment {
                mint = await environment.mintAnnotations(
                    notes,
                    CompilerMintContext(
                        docId: docId, runId: runId, passId: passId, round: round,
                        freshEyes: freshEyes,
                        // A passless run signs "Claude" — M2's identity, and
                        // the label `AnnotationAuthorPresentation` already
                        // gives an author-less note. **The fallback is read
                        // off the resolution rather than off the constant**
                        // (editorial letter P1 Task 5): `AuthorReader.nobody`
                        // IS the case this `??` covers — a check with the seat
                        // vacated, the only way a run reaches here with no
                        // frame at all — and naming it keeps
                        // `passlessEditorName` to the one production use
                        // `TripwireGrepTests`' census pins. A held seat never
                        // reaches the fallback — the coach is an `ActivePass`
                        // with an editor of her own — and neither does a
                        // round, which was refused without one.
                        editorName: activePass?.editorName ?? AuthorReader.nobody.editorName))
            }
            // The one suspension in this method, and the writes below are what
            // make it worth guarding. See the doc comment.
            guard runGeneration == generation else { return }

            let run = Self.record(
                id: runId, model: model, lastOpId: lastOpId,
                deltaSummary: deltaSummary, intentSnapshot: intentSnapshot,
                // The pair minted at the keystroke, not re-asked here: the
                // store's own standing content is this run's preview by now,
                // and the writer may have moved the piece to another pass
                // while it ran.
                passId: passId, round: round, freshEyes: freshEyes,
                // Minted at the keystroke beside them, and carried for their
                // reason: the writer can switch personas while the check runs.
                kind: kind,
                outcome: outcome, scenePosition: scenePosition, stage: stage, ask: ask,
                mintedNotes: mint.minted,
                openInOtherLanes: mint.openInOtherLanes)
            // Dropped rather than discarded: `replace` below supersedes the
            // preview wholesale, so taking it off the pane first would blink
            // the report out and back.
            streaming = nil
            diagnostics?.replace(
                run: run, diagnostics: outcome.sidecarDiagnostics, docId: docId)
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
