import SwiftUI
import MaughamCore

/// The compiler's report on the open document — Author's own pane, reached by
/// ⌘⌥D or by leading its picker (`Persona.author.panes`).
///
/// **It reads as a report about the writer's own clauses, and nothing else**
/// (spec §5, narrowed by M4 P1): the conformance summary — every clause the
/// writer declared, quoted back in their own words, each holding or straining
/// or silent. The summary renders whether or not a single note came with it,
/// because a run whose clauses all hold is not an empty pane: it is the good
/// outcome, and a pane that showed nothing for it would say the check never
/// happened.
///
/// **The continuity questions and the reader's report used to follow it here,
/// and no longer do.** They are findings about the WORDS: they outlive the run
/// that raised them, the writer answers them the way they answer every other
/// note about their prose, and a per-device sidecar the next check wholly
/// supersedes is the wrong place for either. They now mint as pass-stamped
/// annotations at the end of a run (`CompilerOrchestrator.finish` →
/// `Environment.mintAnnotations`). One finding, one home — a pane that still
/// drew them would ask the writer to answer the same question in two places.
///
/// The register is Maugham's: nothing here bounces, nags, or apologises for
/// what it found. A clean run says so plainly; a failed one names what went
/// wrong in one honest sentence and nothing more.
///
/// **No paragraph id is ever rendered.** Every reference travels as a `Ref`
/// carrying the words that paragraph said when the note landed, and the pane
/// draws those words as a chip that clicks through to the prose
/// (requirement 3, `test_noParagraphIdIsEverRendered`).
///
/// **The report can be half-arrived, and the pane needs no case for it.** The
/// compiler streams its answer, so `CompilerOrchestrator` stores each section
/// as its line closes (`DiagnosticsStore.preview`) and the version counter
/// draws it — the conformance summary is readable while the reader's report is
/// still being written. Nothing here *labels* a preview as one, deliberately:
/// the header is already saying "Checking…", which is the one sentence that has
/// to be true, and a second badge saying the same thing would be the pane
/// narrating its own plumbing. What a preview must never do is OUTLIVE its run
/// — that is the orchestrator's discard, not this view's.
///
/// **But a preview is not a run, so its rows carry no fates** (`offersDurableActions`).
/// Reading is the preview's whole value; Answer and Promote arrive with the
/// reconciled report at finish. Acting on a streamed note used to write the
/// half-report to the sidecar through `DiagnosticsStore.dismiss` — a cancelled
/// run then read it back as the standing answer, carrying a delta marker the
/// finished check never earned, and a completed run resurrected the answered
/// note for a second, duplicate ruling. The store refuses that write on its own
/// side too (`dismiss`'s precondition), so this is a hidden button over a shut
/// door rather than the only guard.
///
/// **Drift is one line, above the conformance summary.** v2 dropped the
/// `intent_drift` field; what stands in its place is not a note kind but a
/// PATTERN — a clause straining the same way across consecutive runs, read
/// on demand from `DiagnosticsStore.clauseStatusHistory` by the pure
/// `DriftDetector`. It is deliberately not a `Diagnostic`: no id, no
/// dismissal, no reply field. Pressing it opens Intent (spec §4's last
/// bullet); the pattern breaking is what takes it away, the next time the
/// version bumps. See `driftNote`.
///
/// **The cold-start offer replaces the plain empty state, once, for a
/// document worth reading.** Spec §4: *"one refusable offer... On-demand,
/// never background, never re-asked as a nag."* Drawn only in place of
/// `.neverRun`'s "Not checked yet" line — never a sheet, never something that
/// appears unasked — for a manuscript with more than a stub of prose
/// (`showsColdStartOffer`'s `liveParagraphCount > 1`). **Read** calls
/// `orchestrator.runRequested` exactly as ⌘R does: the offer is UI over the
/// existing first-run path (a document with no prior marker already reads as
/// "everything is new"), never a second run kind. **Not now** records the
/// refusal in `DiagnosticsStore` and the offer never renders again for this
/// document — the writer says no once, not every time they open the pane.
@MainActor
struct DiagnosticsPane: View {
    /// **What this window may offer on this pane** (P3c Task 7, controller
    /// ruling Q). First and required, like `AnnotationRow.verbs`: a host that
    /// forgot it would otherwise draw every verb, so every host — a test's
    /// included — says what it means.
    let posture: DiagnosticsPostures
    let orchestrator: CompilerOrchestrator
    @Bindable var diagnostics: DiagnosticsStore
    let docId: String
    /// `(paragraphId) -> the paragraph's text now` — `DiagnosticsStore.live`'s
    /// staleness check. Mirrors `CompilerEnvironment+Project`'s
    /// `liveParagraphText` closure rather than reaching for a `Document`
    /// itself, so this view has no opinion about where paragraphs live.
    let currentText: (String) -> String?
    let compilerModel: CompilerModelChoice
    var onCompilerModelChange: (CompilerModelChoice) -> Void = { _ in }
    /// The document a promoted note becomes a task on — `TasksPane.activeDoc()`'s
    /// idiom, a closure rather than a `Document` so this view still holds no
    /// editor state (tripwires 3, 6). Defaulted so the callers that only read
    /// notes keep compiling; a `nil` return means there is nothing to promote
    /// onto, and the note is left where it is rather than dismissed into
    /// nowhere.
    var activeDocument: @MainActor () -> Document? = { nil }
    /// The project an answered question becomes a ruling in. Optional, and its
    /// absence is what takes the **Answer** action off every row rather than
    /// leaving one that presses into nowhere — see `offersAnAnswer`.
    var store: ProjectStore? = nil
    /// The derivation cache a ruling has to drop.
    ///
    /// **Not optional out of convenience.** A reply that lands as a ruling
    /// changes the prose the next run's clauses are derived from, and a cached
    /// reading made before it would check the writer against a world they have
    /// just changed — with nothing red, a run later. The deprecated answer shim
    /// passed `nil` here because no pane held the store; `ProjectWindow` builds
    /// one now, and this is where it arrives.
    var world: DeclaredWorldStore? = nil
    /// **Who reads this piece's CHECKS** — `AuthorReader`, the resolution
    /// Author's ⌘R uses (two loops P1 Task 2). This pane is the check loop's
    /// own surface, so it names the coach or nobody and never a stage: a
    /// chapter parked in Gould's lane on the review board is still read here
    /// by the seat, because the lane belongs to the round loop.
    ///
    /// Defaulted to `.nobody` for every caller that has not been given one,
    /// which reads exactly as this pane did before the seat existed: "Claude
    /// reads this piece" and "Press ⌘R and Claude reads what you've written."
    /// Named by the header's reader line and the empty state's promise — one
    /// input, two readers, so neither can name someone the other doesn't.
    var reader: AuthorReader = .nobody
    /// **Pick who reads this project's checks** (two loops P2 Task 6) — the
    /// header's own picker, writing `UIState.authorReaderChoice` through
    /// `DocumentStore.setAuthorReaderChoice`. A closure rather than a store
    /// write here, on `onSetActivePass`' rule: the choice has one writer, and
    /// a pane reaching for a second would be a second spelling of the value
    /// the RUN reads.
    var onChooseReader: (AuthorReaderChoice) -> Void = { _ in }
    /// **Where "Define a first reader…" sends the writer** — Project Settings,
    /// which is the one place her name is typed. A closure for
    /// `onChooseReader`'s reason and because the sheet belongs to the window,
    /// not to this column.
    var onOpenProjectSettings: () -> Void = {}

    @Environment(\.undoManager) private var undoManager

    /// Per note: an action in flight, and the sentence the last one refused
    /// with. Both live on the pane rather than in `DiagnosticRow` because the
    /// commit is asynchronous and the row that started it is gone on success —
    /// a row owning its own in-flight flag could only clear it by outliving
    /// the thing that clears it.
    ///
    /// **`answerFailures` carries the wet-ink dispositions' refusals too**
    /// (M4 P2 Task 1 review, Minor 2), keyed by the annotation's id rather
    /// than a diagnostic's. One idiom rather than two: a Got it that the op
    /// log refused used to reach the log alone, which is a row that looks
    /// pressed and a note that did not move — the same silence
    /// `AnnotationsPane.performAccept`'s named catch exists to prevent, one
    /// layer further out. The two id spaces cannot collide (a diagnostic's is
    /// minted by the ingest, an annotation's is its creation op's) and no row
    /// of either kind reads the other's key.
    @State private var answering: Set<String> = []
    @State private var answerFailures: [String: String] = [:]

    /// **The run whose turn clause has already been filed**, so the offer does
    /// not stand again over a letter the writer has just answered.
    ///
    /// Keyed by run id rather than a bare `Bool` because the next run replaces
    /// `lastRun` and the offer must come back for a round that raised it again
    /// — the letter's own `scenePosition` cannot say so, since it was stamped
    /// before the ruling existed. `nil` is "nothing filed here yet".
    @State private var turnClauseFiledForRun: String?

    /// **What the last Keep filed, and which run it came from** (Task 10).
    /// Not a `Bool`: a second Keep of the same run is allowed and makes a
    /// second note (spec §3.6 — a copy, not a move), so what this remembers is
    /// the note's own title for the confirmation line, discarded the moment a
    /// new run replaces the letter it belongs to.
    @State private var keptLetter: LetterKeep.Kept?

    /// **What a refused ledger verb said** — one channel for Keep as lesson,
    /// These are all choices and Retire, because the writer can only be
    /// mid-one-press (`LetterSection.ledgerFailurePart`'s own reasoning).
    @State private var ledgerFailure: String?

    /// **Bumped after every ledger write, and read by `ledgerHandlers`** (P2
    /// Task 7).
    ///
    /// The lessons ledger is a statement DOCUMENT, and
    /// `ProjectStore.statementText(of:)` reads it through the open document or
    /// the derived cache — neither of which is an observable this pane touches.
    /// So the offers would go on being drawn against the ledger as it stood
    /// when the pane last happened to render: a habit just kept still shows
    /// **Keep as lesson**, and the press memory that hides it for the moment
    /// is wiped by the next refusal (`LetterSection`'s
    /// `onChange(of: ledgerFailure)`), handing the writer a live button over a
    /// lesson already in their file and a duplicate row that then briefs every
    /// later round twice.
    ///
    /// **The FIRST keep in a project hides the defect, which is why the test
    /// that pins this presses twice** (measured 2026-09-02). That press MINTS
    /// the ledger statement, so `manifest.statements` moves and observation
    /// re-renders this pane whether or not the counter exists; the second
    /// appends a ruling to a statement that already exists, and nothing
    /// observable moves at all. With this bump removed,
    /// `test_aKeptLessonStopsBeingOfferedOnceItStandsInTheLedger` fails with
    /// one Keep button still on screen — and a single-press version of that
    /// test passed either way.
    @State private var ledgerRevision = 0

    // MARK: - Reads

    /// Observing `diagnostics.version` forces re-render on every store
    /// mutation — the `AnnotationsPane.kindStatusAnnotations` idiom.
    private var rows: [Diagnostic] {
        _ = diagnostics.version
        return diagnostics.live(docId: docId, currentText: currentText)
    }

    /// **The standing CHECK** (two loops P1 Task 5). This pane reports on
    /// Author's ⌘R; a round finishing in Review must not change what it says
    /// the writer last checked, which is what one shared slot made it do.
    private var lastRun: CompilerRun? {
        _ = diagnostics.version
        return diagnostics.lastCheck(docId: docId)
    }

    /// Every clause the last run checked, whatever the answer. Empty for a run
    /// made with nothing declared — the schema tolerates an empty `checks`
    /// array and absence is valid (spec §7).
    private var clauses: [DiagnosticIngest.ClauseStatus] { lastRun?.clauseStatuses ?? [] }

    /// Every clause straining a pattern across runs, for the document this
    /// pane is showing. `DriftDetector` is pure — no store, no caching — and
    /// is read fresh off the version-gated ring the same way `rows`/`lastRun`
    /// read the store's notes; its own doc: "computed from records, never a
    /// background process."
    private var driftFindings: [DriftFinding] {
        _ = diagnostics.version
        return DriftDetector.drift(history: diagnostics.clauseStatusHistory(docId: docId))
    }

    /// **The open document's queue, in every state** — what `thisCheckSection`
    /// draws the last check's own notes from (M4 P2 Task 1).
    ///
    /// Read through `activeDocument`, which this pane already holds for
    /// `promote()` and the cold-start offer, and gated on `annotationsVersion`
    /// on `AnnotationsPane`'s own idiom, so a note the writer stets in the
    /// other column moves the sentence rather than leaving it stale until the
    /// next check. Unfiltered by status deliberately: a `[.open]` filter here
    /// would make "resolved" permanently zero.
    ///
    /// **The `annotationsVersion` line is insurance, and measured as such.**
    /// Today it is redundant: `Document` is `@Observable` with no
    /// `@ObservationIgnored` anywhere, so `annotations(filter:)`'s own read of
    /// `_annotationsCacheValid` already registers the dependency, and deleting
    /// this line leaves the suite green (M4 P1 Task 5 review, Important 2 —
    /// measured, not assumed). What it buys is that the pane does not depend on
    /// a CACHE INTERNAL staying observable: mark those two properties
    /// `@ObservationIgnored` — a plausible perf change, since the lazy rebuild
    /// writes observable state during body evaluation — and this line is the
    /// only thing left holding the seam up. Both halves were run when the
    /// since-last-round line still lived here (M4 P1 Task 5 review): the pin
    /// went red with the cache ignored AND this line gone, and green with the
    /// cache ignored and this line present. The reader it feeds has changed —
    /// This check draws the notes now — but the seam has not. Keep it.
    ///
    /// Empty when there is no document behind the pane — which is a legitimate
    /// reading (three zeroes), not a missing one.
    ///
    /// **And empty when the document is not the one this pane is about.**
    /// `activeDocument` is the window's active document while `docId` is what
    /// this pane was constructed for; the one production caller passes both
    /// from the same subject, but nothing in the type says so. Counting
    /// another document's notes would be a silently WRONG sentence — a number
    /// the writer cannot account for from anything on their screen — where a
    /// mismatch caught here is merely no sentence. (`promote()` makes the same
    /// assumption and is left alone: that is a pre-existing question about
    /// where a note lands, not about what this line counts.)
    private var queueAnnotations: [Annotation] {
        visibleQueue ?? []
    }

    /// **The queue, or `nil` when this pane cannot see one** (#53 final
    /// review) — what the header and the empty state hand
    /// `RoundNarrative.openElsewhere`. `queueAnnotations`' empty answer is a
    /// legitimate "no notes to draw", but to the cross-lane arm an empty queue
    /// says the finding held elsewhere has been settled, and the seal would
    /// stand over it while a newly selected piece loads. Unseen is passed as
    /// unseen, and that arm falls back to the run's stored count.
    private var visibleQueue: [Annotation]? {
        guard let document = paneDocument else { return nil }
        _ = document.annotationsVersion
        return document.annotations(filter: AnnotationFilter(statuses: nil))
    }

    /// **The open document, when it is the one this pane is about** — the
    /// single spelling of the guard the paragraph above explains at length,
    /// extracted so the wet-ink view's row order and its copy read the same
    /// question rather than each asking it again. `nil` means this pane cannot
    /// see a queue at all, which is a legitimate reading everywhere it is
    /// consumed: no notes to draw, no order to impose, and no claim to make
    /// about what the writer has already handled.
    private var paneDocument: Document? {
        guard let document = activeDocument(), document.docId == docId else { return nil }
        return document
    }

    /// **"This check" — what the run the writer just made raised, live**
    /// (spec §7.0, Denver's smoke correction).
    ///
    /// P1 homed the continuity questions and the reader's reports in the
    /// writer's queue, and the smoke found the consequence: Author — whose
    /// persona IS the wet-ink tempo — was left with a count ("3 notes went to
    /// your queue") and no surface at all. This is the surface. It is a VIEW,
    /// fetched from the annotation layer by the latest run's id: no second
    /// storage, nothing to keep in step, and **never the queue imported into
    /// Author**, which is the other tempo (a list you manage).
    ///
    /// Three properties fall out of the filter rather than being arranged:
    ///
    /// - **only the latest check.** The next ⌘R replaces `lastRun`, and
    ///   with it everything drawn here — a wet-ink view that accumulated
    ///   earlier rounds would be the backlog Author must never show.
    /// - **only what is still open.** Got it and Not this settle the note
    ///   itself, so the row leaves on the disposition with nothing to prune —
    ///   and a note settled in the other column leaves this view too.
    /// - **only this document's.** `queueAnnotations` already refuses a queue
    ///   that is not this pane's document (its own doc explains why), so a run
    ///   id shared with another document's notes cannot draw them here.
    /// **Ordered down the piece** (M4 P2 Task 1 review, ruling): a check's
    /// notes are read in manuscript order — the order the writer would meet
    /// them re-reading their own chapter — never newest-first. A queue sorts
    /// by what to do next; a report follows the prose.
    private var thisCheckAnnotations: [Annotation] {
        guard let runId = lastRun?.id else { return [] }
        let open = queueAnnotations.filter {
            $0.compilerRunId == runId && $0.status == .open
        }
        return Self.inManuscriptOrder(open, sequence: paneDocument?.sequence ?? [])
    }

    private var wetInk: WetInk {
        Self.wetInkStanding(
            mintedNotes: lastRun?.mintedNotes,
            queueVisible: paneDocument != nil,
            openNow: thisCheckAnnotations.count)
    }

    /// **The one note kind this pane draws** (M4 P1 Task 3).
    ///
    /// A conformance strain is read beside the clause it strains against, so
    /// the report is where it belongs. The other two kinds left: a continuity
    /// question and a reader's report are about the WORDS, they outlive the
    /// check that raised them, and they now mint as annotations — one finding,
    /// one home. A run no longer puts either in the sidecar; the filter is what
    /// keeps a sidecar written by an older build from drawing a row this pane
    /// has no section for.
    ///
    /// A note whose `kind` is `nil` is filtered out here too — and cannot reach
    /// here anyway: `DiagnosticsStore.load` drops v1 records as superseded, and
    /// this pane calls `load` in its own `onAppear`.
    private var strains: [Diagnostic] { rows.filter { $0.kind == .conformanceStrain } }

    /// Is there a report to draw at all? **Clauses count even with no notes** —
    /// that is the clean conformance report, and it is the outcome the writer
    /// most wants to see.
    ///
    /// Measured on `strains` rather than `rows`, for the reason above: a legacy
    /// sidecar holding only continuity notes would otherwise claim a report and
    /// then draw nothing at all.
    private var hasReport: Bool { !clauses.isEmpty || !strains.isEmpty }

    private var state: HeaderState {
        // **`strains`, not `rows`** (M4 P1): the header describes the report
        // the writer is looking at, and since the slimming `rows` can hold
        // notes this pane does not draw (a sidecar written by an older build).
        // Counting those made `.idle` reachable over an empty pane, where its
        // copy says the compiler found nothing to raise.
        Self.headerState(runState: orchestrator.runState, lastRun: lastRun,
                          noteCount: strains.count, docId: docId,
                          runStartedAt: orchestrator.runStartedAt,
                          runProgress: orchestrator.runProgress)
    }

    /// Whether the rows on screen may be acted on — read through `state`, which
    /// is this view's ONE reading of `orchestrator.runState` and already scopes
    /// it to this document (`headerState`'s `where runDocId == docId`). A run on
    /// another document leaves this pane's fates exactly where they were.
    private var offersDurableActions: Bool { Self.offersDurableActions(state: state) }

    /// Whether the pane's empty state should offer the cold-start read rather
    /// than show the plain "Not checked yet" line. Reads `activeDocument()`
    /// directly rather than through a closure of its own — the discriminator
    /// is the manuscript's LIVE paragraph count (tripwire-relevant: not the
    /// delta's "new" count, which counts ops since a marker this document has
    /// never had), and `activeDocument` already exists on this pane for
    /// `promote()`. Scoped to the `.neverRun` window only: once any run
    /// happens `state` moves off `.neverRun` for good (`headerState` never
    /// returns to it with a `lastRun` on record), so this stops reading
    /// `sequence` again for the rest of the document's life.
    private var showsColdStartOffer: Bool {
        _ = diagnostics.version
        return Self.showsColdStartOffer(
            state: state,
            liveParagraphCount: activeDocument()?.sequence.count ?? 0,
            hasRefused: diagnostics.hasRefusedColdStart(docId: docId))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            diagnostics.load(docId: docId)
            diagnostics.markRead(docId: docId, kind: .check)
        }
        .onChange(of: docId) { _, new in
            diagnostics.load(docId: new)
            diagnostics.markRead(docId: new, kind: .check)
        }
        // Notes landing while this pane is already on screen were never
        // unread: the picker's badge is for a run that finished somewhere the
        // writer wasn't looking. `markRead` does not bump `version`, so this
        // cannot re-enter itself.
        //
        // `.check` because that is what this pane draws (whole-branch review,
        // finding 2): a round's notes are unread until they are read in
        // Review's queue, and nothing about opening Author's pane says they
        // were.
        .onChange(of: diagnostics.version) { _, _ in
            diagnostics.markRead(docId: docId, kind: .check)
        }
    }

    /// The run's line, its controls, the reader picker and the Ask field —
    /// `DiagnosticsPaneHeader`, handed this pane's one reading of each.
    private var header: some View {
        DiagnosticsPaneHeader(
            state: state, wetInk: wetInk,
            visibleQueue: visibleQueue, reviewPasses: reviewPasses,
            otherLoopLine: otherLoopLine,
            orchestrator: orchestrator, diagnostics: diagnostics, docId: docId,
            reader: reader, store: store,
            compilerModel: compilerModel,
            onCompilerModelChange: onCompilerModelChange,
            onChooseReader: onChooseReader,
            onOpenProjectSettings: onOpenProjectSettings)
    }

    /// This view's one reading of the other loop's run — `orchestrator.runState`
    /// through the pure `otherLoopLine`, scoped to this document.
    private var otherLoopLine: String? {
        Self.otherLoopLine(
            runState: orchestrator.runState, docId: docId,
            titleOf: { id in RoundNarrative.pieceTitle(of: id, in: store?.manifest.structure) })
    }

    /// The ladder the cross-lane clause names its lanes from (#53) — empty
    /// with no project, where an unnamed lane reads "another lane".
    private var reviewPasses: [ReviewPass] {
        store?.manifest.effectiveReviewPasses ?? []
    }

    // MARK: - Content

    /// **The two round lines sit ABOVE the report/no-report fork, not inside
    /// the report** (M4 P1 Task 5 review, Important 1).
    ///
    /// They used to live in the report arm alone, which put them out of reach
    /// in the one state that needs them most: a round in a pass over a piece
    /// with no declared intent raises no clauses and no strains, so `hasReport`
    /// is false — and since Task 3 that round's whole output is in the queue,
    /// with nothing at all on this pane. The empty state's own copy says only
    /// how many notes were queued, which is the `new` count and nothing else;
    /// what became of the last round's findings had no surface. Every one of
    /// the three counts is about notes the pane does not draw, so there is
    /// nothing about "having a report" that the sentence depends on.
    ///
    /// Both lines are `nil` unless there is a round to speak about, so the
    /// cold-start and never-run states are untouched.
    ///
    /// **Tripwire 15 is why this is a wrapper and not a loosened chain.** The
    /// `ContentUnavailableView` keeps its own
    /// `.frame(maxWidth: .infinity, maxHeight: .infinity)` verbatim — it is
    /// what stops the pane's toolbar floating to window centre, has recurred
    /// 4+ times, and is grep-enforced — and the `VStack` that now encloses it
    /// carries the top alignment the tripwire's second half asks for. The
    /// lines are intrinsically sized; the empty view is what expands.
    ///
    /// **And the no-report arm scrolls** (M4 P2 Task 1 review, Important 1).
    /// It carries the wet-ink rows now, and those rows carry the ONLY
    /// disposition affordance Author has — so a check whose notes overflow the
    /// pane would clip the verbs off the bottom with nothing to reach them
    /// with. Nothing caps how many notes a round can mint: the schema's cap of
    /// three is the READER section's alone, continuity questions are unbounded
    /// through the ingest and the mint, and a fresh-eyes reread of a long piece
    /// is exactly the run that raises many at once. The `ScrollView` is a
    /// wrapper for tripwire 15's reason again — the `ContentUnavailableView`'s
    /// full-frame chain and the `VStack`'s top alignment are byte-identical
    /// inside it, and a scroll view proposes rather than demands, so the
    /// column-height failure this pane has hit twice cannot come back through
    /// it.
    ///
    /// **The `GeometryReader` + `minHeight` wrap is load-bearing, not
    /// decorative** (fix round 2 review, Important). A `ScrollView` proposes
    /// an UNBOUNDED height along its scroll axis to its content, so
    /// `.frame(maxHeight: .infinity)` inside one resolves to the content's
    /// INTRINSIC height rather than the pane's — the same tripwire-15 defect
    /// class, reintroduced one layer in and invisible to the source-grep test
    /// (the chain is still byte-identical; it just no longer does anything in
    /// this position). In the common near-empty case (0–2 notes) that put the
    /// `ContentUnavailableView` top-anchored with dead space below it instead
    /// of centered in the pane. `GeometryReader` reads the ACTUAL space this
    /// arm has (the outer `.frame(maxHeight: .infinity)` in `body` is what
    /// gives it one), and `minHeight: proxy.size.height` hands that down as a
    /// FLOOR on the scrolled content: a short arm fills it — restoring the
    /// centering exactly as before the `ScrollView` wrap — and an overflowing
    /// one (Important 1's own case) grows past it and scrolls, unchanged.
    /// Chosen over a conditional arm (plain frame when short, `ScrollView`
    /// when long) specifically to avoid the identity churn a state-dependent
    /// view structure would cost the section's rows on every disposition.
    @ViewBuilder
    private var content: some View {
        if showsColdStartOffer {
            coldStartOffer
        } else if !hasReport {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        letterSection
                        // **The state §7.0 exists for.** A round in a pass over a
                        // piece with no declared intent raises no clause and no
                        // strain, so `hasReport` is false — and since P1 that
                        // round's whole output is queued notes. This arm used to be
                        // the writer's entire feedback from an expensive keystroke:
                        // one sentence saying how many notes went somewhere else.
                        thisCheckSection
                        let empty = Self.emptyState(
                            for: state, wetInk: wetInk, readerName: reader.editorName,
                            annotations: visibleQueue, passes: reviewPasses)
                        ContentUnavailableView(
                            empty.title,
                            systemImage: empty.symbol,
                            description: Text(empty.description))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    letterSection
                    thisCheckSection
                    driftLine
                    conformanceSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - The letter (editorial letter P1 Task 9)

    /// **The letter, above everything else the report says** (spec §3.5).
    ///
    /// It leads because it is what the writer reads first; the notes are the
    /// margin. Drawn in BOTH arms of `content`, and the no-report arm is not
    /// an edge case: a round over a piece with no declared intent raises no
    /// clause and no strain, so its whole output can be one letter — and an
    /// arm that skipped it would leave that round with nothing on screen but
    /// an empty state.
    ///
    /// **`isEmpty` rather than `letter != nil`.** `about` is always present,
    /// so a letter carrying only the say-back is a letter with nothing in it;
    /// drawing a "Letter" heading over one sentence would be a section
    /// pretending there was one.
    @ViewBuilder
    private var letterSection: some View {
        if let run = lastRun, let letter = run.letter, !letter.isEmpty {
            let ledger = ledgerHandlers(for: letter, run: run)
            LetterSection(
                letter: letter,
                // **The run, so an accepted exercise is forgotten with it.**
                // An index means nothing outside one letter (final review).
                runId: run.id,
                signature: LetterSection.signature(
                    // **The name the RUN was read under, not the live one**
                    // (two loops P2 Task 4, P1's Ruling 10). The writer changes
                    // who reads their checks — vacates the seat, names a first
                    // reader — and a standing letter signed by whoever reads
                    // today is yesterday's letter in a stranger's hand. `nil`
                    // is a record written before the stamp existed, which falls
                    // back to the live reader: the same answer those records
                    // always got.
                    voice: run.readerName ?? reader.editorName, round: run.round,
                    // The stage this run derived, off the SAME letter
                    // `shortLetterPart` reads (fix round 1, minor 2) \u{2014}
                    // `run.letter?.draftStage` would be a second path to one
                    // value, and the two could disagree about one letter.
                    stage: letter.draftStage),
                currentText: currentText,
                onJump: { Self.jump(toParagraph: $0) },
                // `promote`'s own verb, one layer out: the exercise is the
                // thing to DO, and a habit with no exercise never draws the
                // button, so the `?? habit.name` fallback is a belt on a path
                // the view already refuses to offer.
                //
                // **`paneDocument`, not `activeDocument()`** (fix round 1):
                // the guard is the pane's own — the window's active document
                // IS this pane's subject, or there is no queue and no task to
                // file. Anchoring a habit's exercise onto another chapter's
                // document would be a task the writer cannot account for from
                // anything on their screen.
                onAcceptExercise: !Self.offersATask(posture) ? nil : { habit in
                    paneDocument?.createPaneTask(
                        body: habit.exercise ?? habit.name,
                        parentTaskId: nil,
                        paragraphId: habit.refs.first?.paragraphId,
                        undoManager: undoManager)
                },
                onAddTurnClause: turnClauseOffer(for: letter, run: run),
                // The tense follows the scope the ruling will be filed at, and
                // both come from the same builder.
                addToIntentTitle: TurnClauseOffer.buttonTitle(
                    store: store, docId: docId),
                // **Keep files a research note, and the router decides where**
                // (`LetterKeep`, spec §3.6). This pane supplies its own values
                // and its own refusal channel; the verb, the render and the
                // scope are shared with Review's cockpit so the two homes
                // cannot file two different letters.
                onKeep: LetterKeep.handler(
                    letter: letter, run: run, docId: docId, store: store,
                    // The kept note's heading says whose letter it was, so it
                    // reads the run's own byline for the signature's reason.
                    editorName: run.readerName ?? reader.editorName,
                    onKept: { keptLetter = $0 },
                    onFailure: { answerFailures[Self.keepFailureKey] = $0 }),
                offerFailure: answerFailures[Self.turnClauseFailureKey],
                keepConfirmation: LetterKeep.confirmation(for: keptLetter, run: run),
                keepFailure: answerFailures[Self.keepFailureKey],
                // **The ledger, from one builder** (P2 Task 7): the text the
                // offers are judged against and the three presses that write
                // into it, so this pane cannot draw offers about one file and
                // write into another — and cannot spell the write differently
                // from Review's cockpit.
                ledgerText: ledger.ledgerText,
                // **A stated fact, not one inferred from the wiring.** The
                // cold claim and the Retire button both turn on it, and a warm
                // round read a three-paragraph delta, which proves nothing
                // about a habit.
                freshEyes: run.freshEyes == true,
                onKeepAsLesson: ledger.onKeepAsLesson,
                onAllChoices: ledger.onAllChoices,
                onRetire: ledger.onRetire,
                ledgerFailure: ledgerFailure)
            Divider()
        }
    }

    /// **The ledger's four inputs, built by the one builder both hosts call**
    /// (`LessonOffer.handlers`). The provenance, the date and the refusal
    /// channel live there; what this pane supplies is its own voice, its own
    /// store and its own re-read.
    private func ledgerHandlers(
        for letter: Letter, run: CompilerRun
    ) -> LessonLedgerHandlers {
        // Read so the text below is re-derived after a write lands — see
        // `ledgerRevision`, which nothing else observes.
        _ = ledgerRevision
        return LessonOffer.handlers(
            letter: letter, run: run, store: store, world: world,
            // The provenance of a filed lesson is whoever wrote the letter it
            // came out of — the run's own byline, not today's reader.
            voice: run.readerName ?? reader.editorName,
            postureOf: posture.statement,
            onFiled: { ledgerRevision += 1 },
            onFailure: { ledgerFailure = $0 })
    }

    /// **The offer, decided and written by `TurnClauseOffer`** — the one
    /// builder both hosts call (fix round 1, Minor 4). The predicate, the two
    /// tenses it reads and the ruling's provenance all live there; what this
    /// pane supplies is its own values and its own refusal channel.
    private func turnClauseOffer(
        for letter: Letter, run: CompilerRun
    ) -> (() -> Void)? {
        TurnClauseOffer.handler(
            letter: letter, run: run, docId: docId, store: store, world: world,
            // "from <voice>'s letter" — the run's own byline, on the
            // signature's rule: a dated ruling must name who actually raised
            // it.
            voice: run.readerName ?? reader.editorName,
            filedRunId: turnClauseFiledForRun,
            postureOf: posture.statement,
            onFiled: { turnClauseFiledForRun = $0 },
            onFailure: { answerFailures[Self.turnClauseFailureKey] = $0 })
    }

    /// The offer's slot in `answerFailures`. A ULID id space cannot produce
    /// it, so it can never collide with a diagnostic's or an annotation's.
    static let turnClauseFailureKey = "letter.turn-clause"

    /// Keep's own slot in `answerFailures`, on the same reasoning: a ULID id
    /// space cannot produce it, so it collides with no diagnostic and no
    /// annotation, and neither of the letter's two verbs can overwrite the
    /// other's refusal.
    static let keepFailureKey = "letter.keep"

    // MARK: - The sections (`DiagnosticsPaneSections.swift`)

    private var coldStartOffer: some View {
        DiagnosticsColdStartOffer(
            docId: docId, diagnostics: diagnostics, orchestrator: orchestrator,
            otherLoopLine: otherLoopLine)
    }

    private var driftLine: some View {
        DiagnosticsDriftLine(driftFindings: driftFindings)
    }

    private var thisCheckSection: some View {
        DiagnosticsThisCheckSection(
            thisCheckAnnotations: thisCheckAnnotations,
            currentText: currentText,
            canDispose: offersDurableActions && Self.offersDisposal(posture),
            answerFailures: answerFailures,
            onGotIt: { gotIt($0) },
            onNotThis: { notThis($0) })
    }

    private var conformanceSection: some View {
        DiagnosticsConformanceSection(
            clauses: clauses, strains: strains,
            canAnswer: store != nil && offersDurableActions
                && Self.offersAnAnswer(docId: docId, posture: posture),
            canPromote: offersDurableActions && Self.offersATask(posture),
            answering: answering, answerFailures: answerFailures,
            onPromote: { promote($0) },
            onAnswer: { answer($0, to: $1) })
    }

    // MARK: - The verbs that write this pane's state

    /// **Got it** — the writer took the note, and it settles.
    ///
    /// `acceptAnnotation` is the annotation layer's own verb, so Review's
    /// ledger and the next round's briefing see exactly what happened here;
    /// nothing about this gesture is a second record of it.
    ///
    /// **The catch is by name, never `try?`** — `AnnotationsPane.performAccept`'s
    /// discipline, and its reason survives the change of caller: a refusal this
    /// pane swallowed would look precisely like a note that settled. The
    /// anchor-lost arm is unreachable from here (the compiler mints questions,
    /// reports and craft notes, and never a suggestion, so there is no span to
    /// lose) and is written out anyway, because the day something mints one the
    /// silence is what would ship.
    private func gotIt(_ annotation: Annotation) {
        guard let document = activeDocument() else { return }
        answerFailures[annotation.id] = nil
        let undoManager = undoManager
        Task {
            if let failure = await Self.gotIt(annotationId: annotation.id, in: document, undoManager: undoManager) {
                answerFailures[annotation.id] = failure
            }
        }
    }

    /// **Not this** — one gesture, and it asks for nothing.
    ///
    /// No reason field, deliberately: the reason-carrying decline is Review's
    /// queue's, where a note is a thing you manage. Wet ink gets a no, and the
    /// briefing carries the finding's own words to say which one was settled
    /// (`CompilerAnnotationDisposition`, `CompilerPrompt.settledNotesHeading`).
    private func notThis(_ annotation: Annotation) {
        guard let document = activeDocument() else { return }
        answerFailures[annotation.id] = nil
        Task {
            if let failure = await Self.notThis(annotationId: annotation.id, in: document, undoManager: undoManager) {
                answerFailures[annotation.id] = failure
            }
        }
    }

    /// Turn a note into a durable task and take it off the pane.
    ///
    /// The two halves are deliberately asymmetric about undo. The task is one
    /// undo step — `createPaneTask` registers its own inverse, so ⌘Z takes it
    /// back. The dismissal is not undoable, and that is intended rather than
    /// missing: the diagnostics sidecar is per-device derived state with no
    /// undo of its own, and a note that still stands is raised again by the
    /// next run. A ⌘Z that resurrected it would be claiming the compiler had
    /// re-checked something it has not looked at since.
    private func promote(_ diagnostic: Diagnostic) {
        guard let document = activeDocument() else { return }
        document.createPaneTask(
            body: DiagnosticPromotion.taskBody(for: diagnostic, run: lastRun),
            parentTaskId: nil,
            paragraphId: diagnostic.anchor?.paragraphId,
            undoManager: undoManager)
        diagnostics.dismiss(diagnostic.id, docId: docId)
    }

    private func answer(_ text: String, to diagnostic: Diagnostic) {
        // Unreachable from the UI — no row without a store offers the action —
        // and it refuses rather than asserting, because a caller that got here
        // has a writer's sentence in hand and nothing to gain from a crash.
        guard let store else { return }
        answerFailures[diagnostic.id] = nil
        answering.insert(diagnostic.id)
        Task {
            let failure = await Self.commitAnswer(
                text, to: diagnostic, docId: docId, store: store, world: world,
                diagnostics: diagnostics)
            answering.remove(diagnostic.id)
            // Only on failure: on success the row is gone with the note, and
            // an entry for a note nobody can see would surface on the next run
            // that happened to mint the same id.
            answerFailures[diagnostic.id] = failure
        }
    }
}

// MARK: - The posture (P3c Task 7)

/// **What a window may offer on Author's Diagnostics pane** — two questions,
/// because the pane's verbs write to two places. `document` is the checked
/// piece's own posture (Got it / Not this settle its notes); `statement`
/// answers for whichever statement a verb would file a ruling in (an Answer,
/// the letter's *Add to intent*, the ledger's presses), at the ruling door's
/// own id (`DocumentStore.posture(ofStatement:scope:statements:)`), so the verb
/// the pane hides and the ruling `RulingPerformer` refuses are one question.
struct DiagnosticsPostures {
    let document: Posture
    let statement: (Statement.Kind, Statement.Scope) -> Posture
}
