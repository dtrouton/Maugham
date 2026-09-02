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
    /// **Who reads this piece** — the one resolution (`PieceReader`, spec
    /// §4.1). Defaulted to `.nobody` for every caller that has not been given
    /// one, which reads exactly as this pane did before the seat existed:
    /// "Claude reads this piece" and "Press ⌘R and Claude reads what you've
    /// written." Named by the header's reader line and the empty state's
    /// promise — one input, two readers, so neither can name someone the
    /// other doesn't.
    var reader: PieceReader = .nobody
    /// What pressing the reader line does — travel to Review, where the seat
    /// is actually held. The line names but never picks (spec §4.2); a
    /// caller that has not been given a destination gets a no-op rather than
    /// a button that presses into nowhere.
    var onOpenBoard: () -> Void = {}

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

    // MARK: - Reads

    /// Observing `diagnostics.version` forces re-render on every store
    /// mutation — the `AnnotationsPane.kindStatusAnnotations` idiom.
    private var rows: [Diagnostic] {
        _ = diagnostics.version
        return diagnostics.live(docId: docId, currentText: currentText)
    }

    private var lastRun: CompilerRun? {
        _ = diagnostics.version
        return diagnostics.lastRun(docId: docId)
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

    /// The rounds this document has finished, oldest→newest — the ring the
    /// since-last-round line is measured against, read the same version-gated
    /// way as everything else here.
    private var roundHistory: [RoundRecord] {
        _ = diagnostics.version
        return diagnostics.roundHistory(docId: docId)
    }

    /// **The open document's queue, in every state** — what the
    /// since-last-round line is counted from (M4 P1 Task 5).
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
    /// only thing left holding the seam up. Both halves were run:
    /// `test_theSinceLastRoundLineFollowsAStetWithoutAnotherCheck` goes red
    /// with the cache ignored AND this line gone, and green with the cache
    /// ignored and this line present. Keep it; the test pins the behaviour
    /// under either mechanism.
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
        guard let document = paneDocument else { return [] }
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

    /// `notes` in the order their paragraphs appear in the document, with the
    /// ones that name no live paragraph after them.
    ///
    /// Pure and static so the order is a direct assertion without a mount, and
    /// **stable within a rank**: `sorted(by:)` is not, and the tie is common —
    /// a round often raises two findings against one paragraph, and rows that
    /// swapped places between two renders of the same check would be the pane
    /// shuffling under a writer mid-read. Ties break on the annotation's own
    /// id — a ULID, monotonic within the process (`ULID.swift`) — which is
    /// mint order.
    ///
    /// **Deliberately NOT the incoming array's own order.** An earlier version
    /// broke ties on `notes`' position, reasoning that array order already
    /// WAS mint order — false: `queueAnnotations` reads
    /// `Document.annotations(filter:)`, and `AnnotationDeriver.derive` sorts
    /// its result **newest-first** for the queue's own purposes. Inheriting
    /// that array's order for a tie silently put the newest of two
    /// same-paragraph notes first — exactly the "queue-consistent
    /// newest-first" the manuscript-order ruling exists to NOT be. Caught by
    /// `test_theEmptyStateAcknowledgesACheckTheWriterHasHandled` failing with
    /// the wrong row surviving after two same-paragraph dispositions pressed
    /// in mint order.
    ///
    /// The trailing bucket is two cases with one honest answer: a doc-scoped
    /// craft note (the compiler's whole-piece observation, anchored to no
    /// paragraph by design) and a note whose paragraph has since left the
    /// sequence. Neither has a place in the prose, so both follow it.
    static func inManuscriptOrder(
        _ notes: [Annotation], sequence: [String]
    ) -> [Annotation] {
        var position: [String: Int] = [:]
        for (index, paragraphId) in sequence.enumerated() { position[paragraphId] = index }
        return notes.sorted { lhs, rhs in
            let left = lhs.paragraphId.flatMap { position[$0] } ?? Int.max
            let right = rhs.paragraphId.flatMap { position[$0] } ?? Int.max
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    /// **What the wet-ink view has to say about this check, as far as the
    /// empty state's copy is concerned** (M4 P2 Task 1 review, Important 2).
    ///
    /// The invariant this type exists to keep: **the copy never announces as
    /// waiting what is visible or settled here.** Before it, the empty state
    /// read `CompilerRun.mintedNotes` — the historical record of what the run
    /// put in the queue — and said "2 notes went to your queue" over the two
    /// notes sitting directly above it with verbs on them, and went on saying
    /// it after the writer had settled both. A surface telling the writer to
    /// go elsewhere for what is in front of them is worse than one that says
    /// nothing.
    enum WetInk: Equatable {
        /// Nothing this check queued is accounted for here — either it queued
        /// nothing, or this pane cannot see the document's queue at all. The
        /// historical sentence is the honest one: those notes exist and the
        /// writer has to be told where.
        case none
        /// Rows are on screen. The section IS the news, so the copy beneath it
        /// says nothing about a queue.
        case showing
        /// This check queued notes and the writer has settled every one of
        /// them. Re-announcing them would be the pane forgetting what it just
        /// watched them do.
        case settled
    }

    /// Pure, on `headerCopy`'s rule — every sentence this pane can say is
    /// assertable without mounting anything.
    ///
    /// `queueVisible` is the honest half: with no document behind the pane
    /// there is no queue to read, so an empty `openNow` means "cannot see"
    /// rather than "handled", and the answer is `.none`.
    static func wetInkStanding(
        mintedNotes: Int?, queueVisible: Bool, openNow: Int
    ) -> WetInk {
        if openNow > 0 { return .showing }
        guard queueVisible, let mintedNotes, mintedNotes > 0 else { return .none }
        return .settled
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
                          noteCount: strains.count, docId: docId)
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
            diagnostics.markRead(docId: docId)
        }
        .onChange(of: docId) { _, new in
            diagnostics.load(docId: new)
            diagnostics.markRead(docId: new)
        }
        // Notes landing while this pane is already on screen were never
        // unread: the picker's badge is for a run that finished somewhere the
        // writer wasn't looking. `markRead` does not bump `version`, so this
        // cannot re-enter itself.
        .onChange(of: diagnostics.version) { _, _ in
            diagnostics.markRead(docId: docId)
        }
    }

    // MARK: - Header state — pure, so every state is a test without a mount

    enum HeaderState: Equatable {
        case neverRun
        case idle(lastRun: CompilerRun)
        /// Carrying what the run is reading, so the wait is legible from the
        /// moment it starts (requirement 5).
        case running(checking: CompilerOrchestrator.DeltaCounts)
        case nothingNew(at: Date)
        case failed(CompilerRunFailure, at: Date)
        case clean(lastRun: CompilerRun)
    }

    /// Derives the header's state from the orchestrator's run state, the
    /// last-run record, and how many notes are currently live.
    ///
    /// `runState` wins whenever it describes something that just happened **to
    /// this document** — the `where` clause is on all three run-describing
    /// cases and not only on `.running`, because the run state is per-window
    /// while this pane is per-document. Anything about another document falls
    /// through to what is on disk here, which is also what makes a reopened
    /// project show its last answer rather than reverting to "never run".
    static func headerState(
        runState: CompilerOrchestrator.RunState,
        lastRun: CompilerRun?,
        noteCount: Int,
        docId: String
    ) -> HeaderState {
        switch runState {
        case .running(let runDocId, let checking) where runDocId == docId:
            return .running(checking: checking)
        case .nothingNew(let runDocId, let at) where runDocId == docId:
            return .nothingNew(at: at)
        case .failed(let runDocId, let failure, let at) where runDocId == docId:
            return .failed(failure, at: at)
        default:
            guard let lastRun else { return .neverRun }
            return noteCount == 0 ? .clean(lastRun: lastRun) : .idle(lastRun: lastRun)
        }
    }

    /// **Whether a row offers a fate at all — false for every row of a preview.**
    ///
    /// The notes on screen during `.running` came from a turn that has not
    /// ended: `finish` reconciles the whole turn with `parseAll` and REPLACES
    /// all of them, so a note answered mid-stream is answered against a record
    /// about to be superseded. Both fates end in `DiagnosticsStore.dismiss`,
    /// whose write would put the half-report on disk as the standing sidecar —
    /// with the run-start marker on it, so the prose the run stopped reading is
    /// never re-checked — and a completed turn would then raise the answered
    /// note again for a duplicate ruling.
    ///
    /// Pure and taking `HeaderState` rather than `RunState`, so it inherits
    /// `headerState`'s per-document scoping instead of reading the run state a
    /// second way: a run on ANOTHER document reaches here as `.idle`/`.clean`
    /// and this pane's rows keep their fates.
    ///
    /// Only `.running` withholds them. `.failed` and `.nothingNew` describe runs
    /// that are over, and the rows under them are the last finished run's, on
    /// disk — a writer must still be able to answer those.
    static func offersDurableActions(state: HeaderState) -> Bool {
        if case .running = state { return false }
        return true
    }

    /// **The cold-start offer's decision, pure** — no view mounted, the same
    /// idiom `headerState`/`emptyState` use for exactly this reason.
    ///
    /// True only for a document this build has genuinely never run
    /// (`state == .neverRun`; any run at all, even one that found nothing,
    /// moves `state` off this case for good), whose manuscript is more than a
    /// stub (`liveParagraphCount > 1` — the discriminator is LIVE paragraphs,
    /// never ops: an op count would call a document "worth reading" for a
    /// checkpoint or an annotation that touched no prose), and that the
    /// writer has not already refused.
    static func showsColdStartOffer(
        state: HeaderState, liveParagraphCount: Int, hasRefused: Bool
    ) -> Bool {
        guard case .neverRun = state else { return false }
        guard liveParagraphCount > 1 else { return false }
        return !hasRefused
    }

    /// The offer's one sentence. A `static let` for `headerCopy`'s reason —
    /// every sentence the pane can say is assertable without mounting anything
    /// — and because the property that it WRAPS rather than truncating is now
    /// pinned by a test (`DiagnosticsPaneColumnHeightTests`), which must ask
    /// production for the words rather than quote them.
    static let coldStartOfferSentence =
        "I haven\u{2019}t read this piece. Read it whole and take notes?"

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            // No spinner: the register is understated, and the state word in
            // `headerLine` ("Checking 14 new paragraphs…") already says what's
            // happening — an indeterminate control here would only animate to say
            // it twice.
            HStack(spacing: 8) {
                // **This wraps, and it must NOT be made to wrap with
                // `fixedSize(horizontal: false, vertical: true)`.** A `Text`
                // already reports its WRAPPED height as its ideal for whatever
                // width it is proposed, so it wraps here without the modifier;
                // what the modifier adds is an *unbreakable minimum* height, and
                // AppKit resolves that minimum at a probe width far narrower than
                // the column — `cliNotFound`'s sentence came back ~400pt tall.
                // `NSSplitView` takes the tallest column, so a pane that cannot be
                // broken grows all three columns past the window: the tree is laid
                // out taller than the window and shows a band the writer cannot
                // scroll back up from, and the centre column's content is pushed
                // above the visible region. There is no max-height constraint for
                // AppKit to break here, which is why this fails differently from
                // the WIDTH conflict `DetailColumnWidthTests` documents.
                // Measured 2026-08-08 (macOS 26.5); see
                // `DiagnosticsPaneColumnHeightTests`.
                Text(headerLine)
                    .font(.caption)
                    .foregroundStyle(isFailureState ? Color.red : .secondary)
                Spacer()
                if case .running = state {
                    Button("Cancel") { orchestrator.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                gearMenu
            }
            // **A label whose only action is travel — no picker here** (spec
            // §4.2). Changing who holds the seat is Review's own control (the
            // board's coach line, or the Inspector's pass rows); this line
            // only says who it is today and takes the writer to where that's
            // changed.
            Button(action: onOpenBoard) {
                Text(readerLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Change who reads in Review")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private var isFailureState: Bool {
        if case .failed = state { return true }
        return false
    }

    private var headerLine: String { Self.headerCopy(for: state, wetInk: wetInk) }

    /// **"Le Guin reads this piece", "Le Guin · Structural", "Claude reads
    /// this piece"** — the same resolution the round cockpit's `coachLine`
    /// draws, in the header's own shape: a stage names its lane after the
    /// editor, since that is the word the board and the ladder already use
    /// for it; the coach and the vacant seat both read as an introduction,
    /// because neither is ever a lane a control can select
    /// (`ReviewPass.laneDisplayName`'s reasoning — her pass name, "Workshop",
    /// is never drawn).
    ///
    /// Static and pure for `emptyState`'s reason: every sentence this pane can
    /// say is assertable without mounting anything, and a test constructing
    /// one `PieceReader` gets the header's answer and the empty state's from
    /// the same value rather than two independently-spelled copies.
    static func readerCopy(for reader: PieceReader) -> String {
        if case .stage(let pass) = reader {
            return "\(reader.editorName) \u{00b7} \(pass.name)"
        }
        return "\(reader.editorName) reads this piece"
    }

    private var readerLine: String { Self.readerCopy(for: reader) }

    /// The header's one line, per state. Static and exhaustive for
    /// `emptyState`'s reason: every sentence the pane can say is then assertable
    /// without mounting anything.
    ///
    /// **Also carries `WetInk`, on the same rule as `emptyState`** — found by
    /// smoke, after the fix round that introduced `WetInk` only reached
    /// `emptyState`'s `ContentUnavailableView`. This header line renders
    /// unconditionally, ABOVE `content` and its own empty state (`body`'s
    /// `VStack(header, Divider, content)`), so a `.clean` run with mintedNotes
    /// still said "N notes went to your queue" here even after `emptyState`
    /// below it stopped saying it — the same defect, one call site over.
    static func headerCopy(
        for state: HeaderState, wetInk: WetInk = .none
    ) -> String {
        switch state {
        case .neverRun:
            return "Not checked yet \u{2014} press \u{2318}R to check your writing."
        case .idle(let run):
            return "Last checked \(relative(run.at)) \u{00b7} \(run.deltaSummary)"
        case .running(let checking):
            return RoundNarrative.checkingCopy(checking)
        case .nothingNew:
            return "Nothing new since the last check."
        case .failed(let failure, _):
            // `RoundNarrative`'s, since 2026-08-18 — Review's cockpit says the
            // same sentence over the same death, and this pane is one caller
            // among two rather than the owner (the hoist `checkingCopy` and the
            // round lines already made).
            return RoundNarrative.failureCopy(failure)
        case .clean(let run):
            // **`.clean` means this PANE has nothing to show, which is not the
            // same as the run having found nothing** (M4 P1). A run that raised
            // three continuity questions and no conformance strain leaves this
            // store empty and the writer's queue three notes fuller; "Nothing
            // to flag" over it is the surface affirming a falsehood. The
            // queued sentence therefore REPLACES the seal rather than being
            // appended to it — the two cannot both be true.
            //
            // Unless `wetInk` says those notes are RIGHT HERE, below this
            // header, on this same pane — showing with their own verbs, or
            // already settled. Then "N notes went to your queue" would point
            // the writer somewhere else for what is (or was) directly beneath
            // this line, so it drops to the same "Nothing to flag" the header
            // has always said when a run truly minted nothing.
            //
            // **A round whose findings were already open in another pass gets
            // the same treatment** (#42, whole-branch review I1): nothing
            // landed here and nothing landed in the queue this writer is
            // looking at, so the seal would affirm the same falsehood one case
            // along. It sits below the queued sentence — notes that really
            // landed are the stronger news — and inside the `.none` arm alone,
            // exactly where the seal it replaces lives: under `.showing` /
            // `.settled` this run's own notes are on screen beneath the header,
            // and that arm's whole point is not to send the writer elsewhere.
            let opening: String
            switch wetInk {
            case .none:
                if let queued = queuedNotesSentence(run.mintedNotes) {
                    opening = queued
                } else if RoundNarrative.openInOtherLanes(run.openInOtherLanes) != nil {
                    opening = "Nothing new to flag"
                } else {
                    opening = "Nothing to flag"
                }
            case .showing, .settled:
                opening = "Nothing to flag"
            }
            let line = "\(opening). Last checked \(relative(run.at))."
            // Appended rather than interleaved: the standing sentence is the
            // one the writer reads at a glance, and this is the footnote to it.
            guard let discarded = discardedNotesSentence(run.droppedDangling) else {
                return line
            }
            return "\(line) (\(discarded))"
        }
    }

    /// **What a run lost, said plainly and without alarm** — or `nil` when it
    /// lost nothing, which is what keeps the clean bill clean.
    ///
    /// One spelling, read by the header and by the empty state, because two
    /// copies of a sentence about the same number are two things that can
    /// disagree. It names what happened (the paragraphs moved) rather than what
    /// Maugham could not do about it: "unknown paragraphs" is the parser's
    /// vocabulary, and to the writer it reads as an error they caused.
    static func discardedNotesSentence(_ count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "1 note arrived against a paragraph that has changed "
            + "and was discarded"
        default: return "\(count) notes arrived against paragraphs that have "
            + "changed and were discarded"
        }
    }

    /// **What a run put in the queue**, or `nil` when it put nothing there —
    /// the one spelling, read by the header and by the empty state, on
    /// `discardedNotesSentence`'s rule that two sentences about the same fact
    /// are two sentences that can disagree.
    ///
    /// `nil` for `nil` as well as for zero: a record written before the field
    /// existed, and a preview, both know nothing about a mint, and a surface
    /// must not claim "0 notes went to the queue" on their behalf.
    ///
    /// It names the destination rather than the count alone, because the
    /// writer has to know WHERE to go and this pane is not it.
    static func queuedNotesSentence(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1
            ? "1 note went to your queue"
            : "\(count) notes went to your queue"
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// **Moved to `CompilerModelMenu`** (editorial letter P1, Task 8) so
    /// Review's round cockpit can mount the identical control — one view
    /// type, one `ForEach(CompilerModelChoice.allCases` site.
    private var gearMenu: some View {
        CompilerModelMenu(choice: compilerModel, onChange: onCompilerModelChange)
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
                        freshEyesLine
                        roundLine
                        // **The state §7.0 exists for.** A round in a pass over a
                        // piece with no declared intent raises no clause and no
                        // strain, so `hasReport` is false — and since P1 that
                        // round's whole output is queued notes. This arm used to be
                        // the writer's entire feedback from an expensive keystroke:
                        // one sentence saying how many notes went somewhere else.
                        thisCheckSection
                        let empty = Self.emptyState(
                            for: state, wetInk: wetInk, readerName: reader.editorName)
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
                    freshEyesLine
                    roundLine
                    thisCheckSection
                    driftLine
                    conformanceSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// **The cold-start offer** (spec §4). Understated, on `content`'s
    /// register: no sheet, no alert — the same two-button margin-note shape
    /// the pane uses everywhere else (`DiagnosticRow`'s Answer/Promote row).
    @ViewBuilder
    private var coldStartOffer: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            // **No `fixedSize(horizontal:vertical:)` here, and the absence is
            // load-bearing** — see `header`'s own note. This sentence carried
            // one, and it is what Denver's 2026-08-08 smoke found: the whole
            // window's three columns laid out ~600pt taller than the window,
            // so the tree showed a band scrolled off the top that could not be
            // scrolled back, and the centre column's editor sat above the
            // visible region entirely. `DiagnosticsPaneColumnHeightTests`
            // measures it.
            Text(Self.coldStartOfferSentence)
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            HStack(spacing: 8) {
                Button("Not now") { diagnostics.refuseColdStart(docId: docId) }
                    .buttonStyle(.bordered)
                Button("Read") { orchestrator.runRequested(docId: docId) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// **The report leads with the distance travelled** (spec §6): what the
    /// writer has settled since the last round in this lane, what is still in
    /// front of them, and what this round raised. Above the drift line and
    /// above the conformance summary, because it is the sentence a writer in a
    /// review pass reads first — and above the empty state too, for the same
    /// reason (`content`).
    ///
    /// Not a button and not a `Diagnostic`: there is nothing to dismiss, and
    /// nowhere for it to go that would be right. **The notes it counts are not
    /// on this pane at all** since Task 3 — they are in the queue — so the
    /// obvious link would be to the Notes pane, and the obvious link is wrong:
    /// the sentence is about three different sets of notes at once and could
    /// only travel to one of them. The next round replaces it; a round that
    /// cannot be compared simply has no line. See `RoundNarrative.sinceLastRoundLine`.
    @ViewBuilder
    private var roundLine: some View {
        if let line = RoundNarrative.sinceLastRoundLine(
            history: roundHistory, run: lastRun, annotations: queueAnnotations) {
            Text(line)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            Divider()
        }
    }

    /// **The cold read names itself**, in `roundLine`'s own register and its
    /// own slot — the two never render together (`RoundNarrative.freshEyesHeader`). Drawn
    /// above the comparison line rather than below it because it is the same
    /// sentence's place in the report: what this round IS, before what it
    /// found.
    @ViewBuilder
    private var freshEyesLine: some View {
        if let line = RoundNarrative.freshEyesHeader(run: lastRun) {
            Text(line)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            Divider()
        }
    }

    /// **The drift line — a pattern across runs, not a note about one.**
    /// Above the conformance summary because it is a claim about a clause the
    /// summary is about to name again (spec §4's last bullet). Not a
    /// `Diagnostic`: no id, no dismissal, no reply field — pressing it opens
    /// Intent, and the pattern breaking is what takes the line away, not a
    /// tap. See `driftNote`.
    @ViewBuilder
    private var driftLine: some View {
        if let line = Self.driftNote(driftFindings) {
            Button {
                MaughamEvent.postDetailSegment(.intent)
            } label: {
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Divider()
        }
    }

    /// **The wet-ink view** (spec §7.0) — the notes this check just raised,
    /// drawn in the pane's own register rather than the queue's.
    ///
    /// It draws above the drift line and the conformance summary because those
    /// two are the standing account of the writer's declared world, and this is
    /// what the keystroke they just pressed came back with. Nothing here says
    /// who wrote it: the byline in Author stays Claude's, and the named editors
    /// belong to Review's pass lanes — wet-ink feedback is not a pass.
    ///
    /// No section at all when there is nothing to draw, rather than a heading
    /// over an empty list: this is a view of one run's output, and a run that
    /// raised nothing has nothing to show for itself here.
    @ViewBuilder
    private var thisCheckSection: some View {
        let notes = thisCheckAnnotations
        if !notes.isEmpty {
            PaneSectionHeader(title: "This check") { EmptyView() }
            ForEach(notes) { note in
                CompilerNoteRow(
                    annotation: note,
                    excerpt: Self.jumpExcerpt(for: note, currentText: currentText),
                    canDispose: offersDurableActions,
                    failure: answerFailures[note.id],
                    onJump: { jump(toParagraph: $0) },
                    onGotIt: { gotIt(note) },
                    onNotThis: { notThis(note) })
                Divider()
            }
        }
    }

    /// The words a wet-ink row's jump chip carries — **never its paragraph
    /// id** (requirement 3, `test_noParagraphIdIsEverRendered`).
    ///
    /// A `Diagnostic` arrives carrying the excerpt the model quoted; an
    /// `Annotation` carries no excerpt at all, so the words come from the live
    /// paragraph through `currentText` — the closure this pane already holds
    /// for `DiagnosticsStore.live`'s staleness check, rather than a second
    /// reach for the document.
    ///
    /// `nil` in the two cases where a chip would be a button labelled nothing:
    /// a doc-scoped craft note (the compiler's anchorless finding — no
    /// paragraph to travel to) and a paragraph this pane cannot read. The row
    /// itself still jumps on a tap where there is an id.
    ///
    /// Trimmed by `truncatedDriftQuote`, whose budget is the right one for the
    /// same reason it is right there: one line of a narrow pane. `ExcerptChip`
    /// limits itself to a single line anyway, so the budget only decides where
    /// the ellipsis falls rather than what is legible.
    static func jumpExcerpt(
        for annotation: Annotation, currentText: (String) -> String?
    ) -> Diagnostic.Ref? {
        guard let paragraphId = annotation.paragraphId,
              let text = currentText(paragraphId) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Diagnostic.Ref(
            paragraphId: paragraphId, excerpt: truncatedDriftQuote(trimmed))
    }

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
        Task {
            do {
                try await document.acceptAnnotation(
                    id: annotation.id, undoManager: undoManager)
            } catch let error as AnnotationAcceptError where error == .suggestionAnchorLost {
                documentLog.error("\u{201C}Got it\u{201D} refused for \(annotation.id, privacy: .public): the suggestion's anchor is gone")
                answerFailures[annotation.id] = Self.anchorLostRefusal
            } catch {
                documentLog.error("\u{201C}Got it\u{201D} failed for \(annotation.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                answerFailures[annotation.id] = Self.dispositionRefusal(error)
            }
        }
    }

    /// **What a refused disposition says in the row it was pressed in** (M4 P2
    /// Task 1 review, Minor 2).
    ///
    /// The log is not a surface. A Got it that the op log refused leaves the
    /// row exactly where it was — which is correct, the note did not settle —
    /// and without a sentence beside it that reads as a button that did
    /// nothing, so the writer presses it again. It names what did not happen
    /// rather than the mechanism, and carries the error's own words after it
    /// because a refusal with no detail cannot be acted on.
    static func dispositionRefusal(_ error: Error) -> String {
        "That didn\u{2019}t settle: \(error.localizedDescription)"
    }

    /// The one refusal with a cause worth naming in the writer's terms rather
    /// than the error's — unreachable from this pane today (`gotIt`'s own
    /// doc), and spelled out so it cannot arrive as a raw `Error` string the
    /// day something mints a suggestion.
    static let anchorLostRefusal =
        "That didn\u{2019}t settle: the passage it points at has changed since "
        + "the note was written."

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
            do {
                try await document.rejectAnnotation(
                    id: annotation.id, undoManager: undoManager)
            } catch {
                documentLog.error("\u{201C}Not this\u{201D} failed for \(annotation.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                answerFailures[annotation.id] = Self.dispositionRefusal(error)
            }
        }
    }

    /// **The report's first section, and the reason the pane exists** — the
    /// writer's own clauses, quoted, each with how this draft sat against it.
    @ViewBuilder
    private var conformanceSection: some View {
        let paired = Self.conformanceRows(clauses: clauses, strains: strains)
        if !paired.rows.isEmpty || !paired.orphans.isEmpty {
            PaneSectionHeader(title: "Conformance") {
                // The clauses are derived from the writer's intent statement,
                // and this is the door to it — the one place on the pane where
                // the declared world can be changed rather than answered.
                Button("Open Intent") { MaughamEvent.postDetailSegment(.intent) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(paired.rows) { row in
                ClauseRow(row: row, canAnswer: store != nil && offersDurableActions,
                          canPromote: offersDurableActions,
                          answering: answering, answerFailures: answerFailures,
                          onJump: { jump(toParagraph: $0) },
                          onPromote: { promote($0) },
                          onAnswer: { answer($0, to: $1) })
                Divider()
            }
            // A strain whose clause is not in this run's summary at all. It
            // cannot happen through the ingest — a strain and its `ClauseStatus`
            // are minted from the same entry — and it is drawn anyway, because
            // the alternative is a note the compiler raised disappearing with
            // nothing said.
            ForEach(paired.orphans) { note in
                noteRow(note)
                Divider()
            }
        }
    }

    // **The Continuity and "The reader" sections are gone** (M4 P1 Task 3),
    // and with them the reader's truncation sentence. Both kinds now mint as
    // annotations at the end of a run, so the writer answers them where every
    // other note about their prose lives — in the queue, under the round and
    // the editor that raised them, surviving the next check. A pane that still
    // drew them would be the second home this milestone exists to close.
    // `CompilerRun.truncatedReader` is still recorded; nothing reads it here,
    // because the sentence belongs beside the reports it is about.

    @ViewBuilder
    private func noteRow(_ diagnostic: Diagnostic) -> some View {
        DiagnosticRow(
            diagnostic: diagnostic,
            canAnswer: store != nil && Self.offersAnAnswer(diagnostic) && offersDurableActions,
            canPromote: offersDurableActions,
            isSubmitting: answering.contains(diagnostic.id),
            answerFailure: answerFailures[diagnostic.id],
            onJump: { jump(toParagraph: $0) },
            onPromote: { promote(diagnostic) },
            onAnswer: { answer($0, to: diagnostic) })
    }

    /// One clause of the summary and every strain raised against it.
    struct ConformanceRow: Identifiable {
        /// Where this clause sat in the run's own list. Part of the identity
        /// and nothing else — the rows are never sorted by it.
        let position: Int
        let status: DiagnosticIngest.ClauseStatus
        let strains: [Diagnostic]
        /// **Position first, then the writer's sentence.** The quote alone is
        /// not unique: `conformanceRows` deliberately renders a clause the
        /// writer declared twice as two rows (see its doc), which handed
        /// SwiftUI's `ForEach` two identical ids — undefined behaviour for the
        /// duplicate the design intends to keep.
        var id: String { "\(position)\u{0}\(status.clauseQuote)" }
    }

    /// Pair every clause with the strains raised against it, and report any
    /// strain left over.
    ///
    /// Pure and returned as a value rather than assembled in the body, so the
    /// pairing — including the leftovers, which are the interesting half — is a
    /// direct test without a mount. Matching is on the quoted clause because
    /// that is the only thing the two records share: `DiagnosticIngest` mints a
    /// `ClauseStatus` and a `.conformanceStrain` from one entry and stamps both
    /// with the same `clause_quote`.
    ///
    /// Clauses keep the order the run reported them in; a duplicate quote (the
    /// writer declared the same sentence twice) takes the same strains on both
    /// rows rather than dropping one — a wrong-looking duplicate is a smaller
    /// harm than a missing finding.
    static func conformanceRows(
        clauses: [DiagnosticIngest.ClauseStatus], strains: [Diagnostic]
    ) -> (rows: [ConformanceRow], orphans: [Diagnostic]) {
        let quotes = Set(clauses.map(\.clauseQuote))
        let rows = clauses.enumerated().map { position, status in
            ConformanceRow(
                position: position, status: status,
                strains: strains.filter { $0.clauseQuote == status.clauseQuote })
        }
        let orphans = strains.filter { strain in
            guard let quote = strain.clauseQuote else { return true }
            return !quotes.contains(quote)
        }
        return (rows, orphans)
    }

    // MARK: - Drift (spec §4's last bullet; findings computed by `DriftDetector`)

    /// **The one line above the conformance summary when a clause is
    /// drifting** — pinned to `findings.first`, in the order
    /// `DriftDetector.drift` reports it (the newest run's own clause order).
    /// With more than one, "and one more" says a second is drifting without
    /// counting how many — two findings and five read identically, the same
    /// discipline the pane's now-deleted reader section once kept with its
    /// own "The reader had more to say." line (M4 P1 Task 3): how many is
    /// forensic detail the writer did not ask for.
    ///
    /// **No count beyond the fixed "three runs" is ever spoken**, either —
    /// not `DriftFinding.runsStraining`'s true streak length, which the
    /// detector reports honestly and can run past the threshold (its own
    /// doc: "the pane ... can choose to say so"; this pane chooses not to,
    /// for the reason above).
    static func driftNote(_ findings: [DriftFinding]) -> String? {
        guard let first = findings.first else { return nil }
        let quote = truncatedDriftQuote(first.clauseQuote)
        let andOneMore = findings.count > 1 ? " \u{2014} and one more" : ""
        return "Your line may have moved \u{2014} \u{201C}\(quote)\u{201D} has strained "
            + "three runs running\(andOneMore). Draft\u{2019}s right, or intent\u{2019}s right?"
    }

    /// How much of the clause the drift line's one sentence can carry —
    /// smaller than `IntentStrip.maximumLength` because this quote sits
    /// inside a longer sentence rather than filling a strip on its own.
    private static let driftQuoteMaxLength = 60

    /// `quote` if it fits, else cut at the last word boundary inside the
    /// budget and ellipsised — `IntentStrip.truncated`'s idiom, restated here
    /// because that one is `private` to its own file and the two truncate
    /// different budgets for different reasons.
    static func truncatedDriftQuote(_ quote: String) -> String {
        guard quote.count > driftQuoteMaxLength else { return quote }
        let head = String(quote.prefix(driftQuoteMaxLength))
        guard let lastSpace = head.lastIndex(of: " ") else { return head + "\u{2026}" }
        let cut = String(head[head.startIndex..<lastSpace])
            .trimmingCharacters(in: .whitespaces)
        return (cut.isEmpty ? head : cut) + "\u{2026}"
    }

    /// The glyph for one clause's answer. Deliberately three quiet marks: a
    /// strain is something to look at, not an error, and an alarm here would be
    /// the pane raising its voice at the writer's own declaration.
    ///
    /// A status this build has never heard of gets a neutral mark rather than
    /// falling into one of the three — `DiagnosticIngest` drops those at ingest,
    /// so this arm is unreachable through the run and exists so a later
    /// contract's fourth word cannot silently render as "holds".
    static func statusSymbol(_ status: String) -> String {
        switch status {
        case DiagnosticIngest.SectionField.holds: return "checkmark"
        case DiagnosticIngest.SectionField.strains: return "arrow.left.and.right"
        case DiagnosticIngest.SectionField.silent: return "circle.dashed"
        default: return "questionmark"
        }
    }

    /// What that glyph says aloud — VoiceOver reads this, and a mark alone is
    /// silent.
    static func statusWord(_ status: String) -> String {
        switch status {
        case DiagnosticIngest.SectionField.holds: return "holds"
        case DiagnosticIngest.SectionField.strains: return "strains"
        case DiagnosticIngest.SectionField.silent:
            return "nothing in this draft touches it"
        default: return status
        }
    }

    // **`readerKindLabel` is gone with the section it labelled** (M4 P1
    // Task 3). `Diagnostic.category` is set by the ingest for a reader report
    // and for nothing else, and a reader report no longer reaches this pane —
    // so the label had no row left to sit above. The reader's two kinds are
    // still CONTENT and still parsed (`DiagnosticIngest.SectionField
    // .dreamBreak`/`.belief`); what changed is where the report is read.

    /// **Which notes offer to be answered** — a conformance strain, and only
    /// it (spec §5's fates, narrowed by M4 P1 Task 3).
    ///
    /// A conformance strain is read beside the clause it strains against, and
    /// the writer's reply to it is a decision: it lands as a ruling. A
    /// continuity question and a reader report are both about the WORDS
    /// rather than a declared clause — they now mint as pass-stamped
    /// annotations at the end of a run (`strains`'s own doc) and never reach
    /// this pane as a `Diagnostic` row, so a `.continuity` arm answering
    /// `true` here was dead: nothing upstream ever hands this function a
    /// continuity note. A reader report was never answerable either way —
    /// "I stopped believing her here" has no answer to rule on, and a reply
    /// field under one would invite the writer to argue with a reader, which
    /// is not a decision that belongs in the declared world.
    static func offersAnAnswer(_ diagnostic: Diagnostic) -> Bool {
        switch diagnostic.kind {
        case .conformanceStrain: return true
        case .continuity, .readerReport, .letterQuestion, .none: return false
        }
    }

    /// What an empty pane says, per state. Pure and exhaustive so each answer
    /// is assertable without a mount, and so no state can fall through to
    /// another's copy.
    ///
    /// **A failed check gets neither the seal nor "Nothing to flag."** Those
    /// two say the compiler looked and found nothing; a run that died never
    /// looked, and the header is already carrying the honest sentence about
    /// why. Repeating it here would be the pane saying the same thing twice
    /// under a checkmark that contradicts it.
    ///
    /// **Nor does a run that lost every note it raised.** That is the adjacent
    /// case rather than the same one: it looked, it spoke, and Maugham could
    /// not place what it said. The seal is for a run that came back with
    /// nothing to say — 0 raised and 0 discarded — so a discard takes the
    /// checkmark off without borrowing the failure's warning triangle.
    ///
    /// **And it never announces as waiting what the pane is already showing**
    /// (M4 P2 Task 1 review, Important 2 — see `WetInk`). `wetInk` defaults to
    /// `.none`, which is the pre-§7.0 world and what every state that has no
    /// notes of its own passes; the two other answers replace the queued
    /// sentence rather than joining it, on `queuedNotesSentence`'s own rule
    /// that two sentences about one fact are two sentences that can disagree.
    static func emptyState(
        for state: HeaderState, wetInk: WetInk = .none,
        readerName: String = PieceReader.nobody.editorName
    ) -> (title: String, symbol: String, description: String) {
        // **Ordered above every arm below**, including the failure and
        // never-run ones, is deliberate only in appearance: `wetInk` is
        // `.none` in both — a run that never happened queued nothing, and a
        // failed one minted nothing — so this branch cannot capture them.
        switch wetInk {
        case .none:
            break
        case .showing:
            return ("Nothing else to flag.", "checkmark.seal",
                    clauseSentence(for: state))
        case .settled:
            return ("You\u{2019}ve handled this check\u{2019}s notes.", "checkmark.seal",
                    clauseSentence(for: state))
        }
        switch state {
        case .neverRun:
            return ("Not checked yet", "checkmark.seal",
                    "Press \u{2318}R and \(readerName) reads what you've written.")
        case .running(let checking):
            guard let phrase = RoundNarrative.paragraphPhrase(checking) else {
                return ("Checking\u{2026}", "hourglass",
                        "Claude is reading what you've written since the last check.")
            }
            return ("Checking\u{2026}", "hourglass", "Claude is reading \(phrase).")
        case .failed:
            return ("No notes", "exclamationmark.triangle",
                    "The last check didn't finish, so there are none from it.")
        case .clean(let run) where queuedNotesSentence(run.mintedNotes) != nil:
            // **The seal may not stand over a run that queued notes** (M4 P1).
            // This pane holds conformance strains alone; the questions and the
            // reader's reports went somewhere the writer has to be told about,
            // and a checkmark saying "nothing to raise" is the opposite of what
            // happened. Ordered above the discarded arm because it is the
            // stronger claim: a run can have queued notes AND lost some, and
            // the queued ones are the news.
            let queued = queuedNotesSentence(run.mintedNotes) ?? ""
            return ("Notes in your queue", "tray.and.arrow.down",
                    "\(queued). " + clauseSentence(for: state))
        case .clean(let run)
            where RoundNarrative.openInOtherLanes(run.openInOtherLanes) != nil:
            // **The seal may not stand over a round whose findings were
            // already open in another pass either** (#42, whole-branch review
            // I1) — the same argument as the queued arm above, one case along,
            // and from the same ruling that produced the count. This round
            // raised something; the mint refused it because the writer is
            // holding it in a lane they cannot see from here, so nothing
            // reached this pane and nothing reached their queue. "The compiler
            // found nothing to raise" is then the opposite of what happened.
            //
            // **And this is precisely where the since-line cannot help**: the
            // cross-lane-only round is most often round 1 of a lane, where
            // that line is silent by construction (nothing behind it to be
            // "since"). Below the queued arm because notes that really landed
            // are the stronger news; above the discarded arm because that one
            // still wears the seal, and the discard footnote is carried along
            // by `clauseSentence` rather than lost.
            let elsewhere = RoundNarrative.openInOtherLanes(run.openInOtherLanes)
            return ("Nothing new to flag.", "tray.full",
                    (elsewhere?.sentence ?? "") + " " + clauseSentence(for: state))
        case .clean(let run) where discardedNotesSentence(run.droppedDangling) != nil:
            return ("Nothing to flag.", "circle.dashed",
                    (discardedNotesSentence(run.droppedDangling) ?? "") + ".")
        case .idle, .nothingNew, .clean:
            // `.idle` cannot reach here, and the reason is a pair rather than
            // one function: `content` renders this only when `hasReport` is
            // false, which requires `strains` to be empty, and `headerState` is
            // handed that same `strains` count — so an empty report and
            // `.clean` are the same condition read twice. (Before M4 P1 the
            // count came from `rows`, which since the slimming can hold notes
            // this pane refuses to draw; a legacy sidecar of continuity rows
            // reached this arm as `.idle` and called itself clean.) Named
            // rather than defaulted so a new state cannot inherit this copy by
            // omission.
            return ("Nothing to flag.", "checkmark.seal",
                    "The compiler found nothing to raise against the last check.")
        }
    }

    /// **What the check found against the writer's own clauses, plus what it
    /// lost** — the sentence under every empty state that describes a run
    /// rather than the absence of one.
    ///
    /// One spelling, read by the queued arm and by both wet-ink arms, on
    /// `discardedNotesSentence`'s rule: three copies of a sentence about the
    /// same two facts are three things that can drift apart. The discard
    /// footnote is appended rather than interleaved, exactly as it was, and is
    /// absent for any state that carries no run to have lost anything.
    static func clauseSentence(for state: HeaderState) -> String {
        let base = "No clause you declared strained in this check."
        guard case .clean(let run) = state,
              let discarded = discardedNotesSentence(run.droppedDangling) else { return base }
        return base + " (\(discarded).)"
    }

    /// The paragraph a click on `diagnostic` should jump to, or `nil` for a note
    /// that named none. Split out as a pure static so the mapping is a direct
    /// unit test without mounting a view or simulating a tap gesture, which
    /// SwiftUI does not expose the way it does a `Button`'s press.
    static func paragraphToNavigateTo(for diagnostic: Diagnostic) -> String? {
        diagnostic.anchor?.paragraphId
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

    // MARK: - The answer, which is a ruling

    /// What the ruling's line says about where it came from — a builder
    /// rather than a constant (M4 P1 Task 6), because *"answered a compiler
    /// note"* alone left the reader with no idea which note: a real defect
    /// this shipped with (Tribute) read "The reader is supposed to read this
    /// as it covering up" in the Intent pane, the ruling text's own dangling
    /// *this* with nothing beside it naming what it answered.
    ///
    /// **It names no paragraph, and that is requirement 3 rather than a
    /// shortfall.** The shim this replaced left a note anticipating *"from a run
    /// on ¶wnse"* — but a ruling's provenance is prose the writer reads, in the
    /// Intent pane, for as long as the decision stands, and a bare id is exactly
    /// what v2 took off every surface. The DATE is not restated here either:
    /// `RulingsSection` stamps every line with `ruled <d MMM yyyy>`, so a
    /// provenance carrying one too would print the day twice.
    ///
    /// **The excerpt is the note's own `clauseQuote`** — a conformance strain's
    /// clause, the only answerable kind post-Task-3 (`offersAnAnswer`) and the
    /// only one that carries one. Trimmed to `driftQuoteMaxLength` (60,
    /// `truncatedDriftQuote`'s own budget — the same idiom, restated for the
    /// same reason it already is here) and with every em-dash collapsed to a
    /// plain hyphen: `RulingsSection.parseItem` splits an item on its
    /// RIGHT-MOST "—", so an excerpt that still carried one could shift that
    /// split point into the quote and cut the writer's own sentence off
    /// mid-word. A `nil` `clauseQuote` — a v1 sidecar record, or a future note
    /// kind that answers without one — falls back to the bare legacy line.
    static func answeredNoteProvenance(for diagnostic: Diagnostic) -> String {
        guard let quote = diagnostic.clauseQuote, !quote.isEmpty else {
            return "answered a compiler note"
        }
        let sanitized = quote.replacingOccurrences(of: "\u{2014}", with: "-")
        let excerpt = truncatedDriftQuote(sanitized)
        return "answered a compiler note: \u{00AB}\(excerpt)\u{00BB}"
    }

    /// **Write the writer's answer into the piece's rulings, and take the note
    /// off the pane once it is there** — the loop this milestone exists for.
    ///
    /// A `static` taking everything it touches, so the whole of it is a direct
    /// test against a real `ProjectStore` and a real `DiagnosticsStore`. SwiftUI
    /// exposes no way to deliver a Return keystroke into a hosted `TextField`'s
    /// editor, so a commit written inline in the field's `.onSubmit` would be
    /// the one part of this path nothing could drive.
    ///
    /// **Through `RulingPerformer.rule`, which is the only door into the
    /// writer-owned layer** (spec §3.4). The answer arrives itemized, dated and
    /// carrying where it came from, under `## Rulings` — never as a paragraph
    /// appended to the essay the writer wrote, which is what shipped in M2 and
    /// what §3.4 names as the membrane's loosest point.
    ///
    /// **The dismissal is conditional on the write, and the order is the
    /// contract.** A note dismissed before the ruling could lose both the note
    /// and the answer to one refusal; dismissed after, the worst case is a note
    /// the writer answers twice. Returns the refusal's own sentence, or `nil`.
    ///
    /// Asymmetric about undo for `promote`'s reason: the answer is an op in the
    /// statement's log and ⌘Z reaches it there, while the dismissal is
    /// per-device derived state with no undo of its own — a ⌘Z that resurrected
    /// the note would claim the compiler had re-checked something it has not
    /// looked at since.
    static func commitAnswer(
        _ text: String, to diagnostic: Diagnostic, docId: String,
        store: ProjectStore, world: DeclaredWorldStore?, diagnostics: DiagnosticsStore
    ) async -> String? {
        do {
            try await RulingPerformer.rule(
                text, provenance: answeredNoteProvenance(for: diagnostic),
                kind: .intent, forScope: .document(docId), store: store, world: world)
        } catch {
            return error.localizedDescription
        }
        diagnostics.dismiss(diagnostic.id, docId: docId)
        return nil
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

    private func jump(toParagraph pid: String) {
        // Reuses `AnnotationsPane.jump`'s event rather than a copy — span
        // precision is that pane's alone; a diagnostic anchors a whole
        // paragraph.
        MaughamEvent.post(
            .maughamNavigateToParagraph, to: .keyWindow,
            payload: ["paragraph_id": pid])
    }
}

// MARK: - Sections

@MainActor
private struct PaneSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// One clause of the conformance summary: the writer's sentence, how the draft
/// sat against it, and — when it strains — what pulled.
@MainActor
private struct ClauseRow: View {
    let row: DiagnosticsPane.ConformanceRow
    let canAnswer: Bool
    /// Passed through to every strain under this clause — see
    /// `DiagnosticsPane.offersDurableActions`. Separate from `canAnswer`
    /// because the two are false for different reasons: no project to write a
    /// ruling into, versus a run still arriving.
    let canPromote: Bool
    let answering: Set<String>
    let answerFailures: [String: String]
    let onJump: (String) -> Void
    let onPromote: (Diagnostic) -> Void
    let onAnswer: (String, Diagnostic) -> Void

    /// **Open, and collapsible — not closed and expandable.** The note under a
    /// strain is the finding; a summary that hid it behind a chevron would make
    /// the writer click once per strain to learn what the run actually said,
    /// and a finding one click away is a finding half the time.
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: DiagnosticsPane.statusSymbol(row.status.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(DiagnosticsPane.statusWord(row.status.status))
                // The writer's own words, quoted — never a summary of them.
                Text("\u{201C}\(row.status.clauseQuote)\u{201D}")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !row.strains.isEmpty {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(isExpanded ? "Hide what pulls" : "Show what pulls")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, row.strains.isEmpty || !isExpanded ? 10 : 0)

            if isExpanded {
                ForEach(row.strains) { strain in
                    DiagnosticRow(
                        diagnostic: strain,
                        canAnswer: canAnswer && DiagnosticsPane.offersAnAnswer(strain),
                        canPromote: canPromote,
                        isSubmitting: answering.contains(strain.id),
                        answerFailure: answerFailures[strain.id],
                        onJump: onJump,
                        onPromote: { onPromote(strain) },
                        onAnswer: { onAnswer($0, strain) })
                }
            }
        }
    }
}

// MARK: - One note

@MainActor
private struct DiagnosticRow: View {
    let diagnostic: Diagnostic
    /// Whether this row offers the **Answer** action at all — false for a
    /// reader report, false with no project to write into, and false for every
    /// row of a preview (`DiagnosticsPane.offersDurableActions`).
    let canAnswer: Bool
    /// Whether this row offers **Promote to Task**. Its own flag rather than
    /// `canAnswer`'s: a reader's report has no answer to give and promotes
    /// perfectly well, so the two are false on different rows for different
    /// reasons and only a preview takes both away at once.
    let canPromote: Bool
    /// An answer of this row's already on its way to the piece's rulings.
    let isSubmitting: Bool
    /// What the last answer refused with, or `nil`. Its arrival is what tells
    /// the row the round trip is over and the field is the writer's again.
    let answerFailure: String?
    let onJump: (String) -> Void
    let onPromote: () -> Void
    let onAnswer: (String) -> Void

    /// The field is REVEALED rather than standing: a text box under every note
    /// is a form, and the pane's register is a margin note.
    @State private var isAnswering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(diagnostic.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            // **The writer's prose, never its id** (requirement 3). One chip a
            // line: a chip is already a short quotation, and two side by side in
            // a pane this narrow would each be truncated to nothing.
            ForEach(diagnostic.refs ?? [], id: \.paragraphId) { ref in
                ExcerptChip(ref: ref, onJump: onJump)
            }
            HStack(spacing: 6) {
                if canAnswer && !isAnswering {
                    Button("Answer", action: reveal)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Say why this is deliberate. It becomes a ruling in your "
                              + "intent, and the next check reads it.")
                }
                if canPromote {
                    Button("Promote to Task", action: onPromote)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Keep this note as a task on the document.")
                }
            }
            if isAnswering { replyField }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        // The tap-to-jump must not fire from inside the field the writer is
        // typing in — `onTapGesture` on the row would otherwise scroll the
        // editor out from under them mid-sentence.
        .onTapGesture {
            guard !isAnswering,
                  let pid = DiagnosticsPane.paragraphToNavigateTo(for: diagnostic)
            else { return }
            onJump(pid)
        }
    }

    /// **Understated on purpose.** A plain field with a prompt rather than a
    /// bordered box with a Send button: the writer is answering a margin note,
    /// not filling in a form, and this pane's whole register is that nothing on
    /// it nags.
    @ViewBuilder
    private var replyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Why is this deliberate?", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($fieldFocused)
                .disabled(isSubmitting)
                .onSubmit { commit() }
                .onExitCommand { cancel() }
            if let answerFailure {
                Text(answerFailure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Reveal the field and put the caret in it. The deferral is tripwire 16's:
    /// a single `DispatchQueue.main.async` tick loses the race with SwiftUI's
    /// own focus pass, and a field the writer has to click into is an action
    /// that only half happened. `BinderRow.claimFocus()` is the canonical
    /// spelling.
    private func reveal() {
        isAnswering = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            fieldFocused = true
        }
    }

    /// **The words go up and the field stays open** — closing it is not this
    /// method's job. The pane owns the round trip: on success the note is
    /// dismissed and this whole row goes with it, and on failure the row stays
    /// exactly as it is with the draft still in it, because a commit that
    /// emptied the field would take the writer's sentence with it on the one
    /// path where they still need it.
    ///
    /// Return on an untouched field is a cancel rather than a refusal: nothing
    /// was said, so there is nothing to report.
    private func commit() {
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            cancel()
            return
        }
        onAnswer(words)
    }

    /// Escape: the field goes away and nothing is written. The draft goes with
    /// it — the writer said no.
    private func cancel() {
        isAnswering = false
        fieldFocused = false
        draft = ""
    }
}

// MARK: - One note from this check (spec §7.0)

/// **One note the latest run raised** — `DiagnosticRow`'s shape over an
/// `Annotation` rather than a `Diagnostic`.
///
/// A sibling rather than a widening of that row, and the two are not the same
/// thing wearing two types: a `Diagnostic` is a conformance strain read beside
/// the clause it pulls against, whose fates are a ruling and a task; this is a
/// note about the WORDS, whose fates are the annotation layer's own accept and
/// decline. A row generic over both would be two rows sharing a body with a
/// branch on every line of it.
///
/// **No byline.** The note is signed in the queue by the pass's named editor;
/// in Author the voice is Claude's and unremarked, because wet-ink feedback is
/// not a pass (spec §7.0).
@MainActor
private struct CompilerNoteRow: View {
    let annotation: Annotation
    /// The words the jump chip shows, or `nil` for a note with nowhere to jump
    /// — `DiagnosticsPane.jumpExcerpt`.
    let excerpt: Diagnostic.Ref?
    /// Whether the two verbs are offered at all — false for every row of a
    /// preview (`DiagnosticsPane.offersDurableActions`), because a run still
    /// arriving has not raised these notes yet in the only sense that matters:
    /// `finish` is what mints them, and what is on screen mid-stream is the
    /// last finished run's.
    let canDispose: Bool
    /// What the last disposition of this note refused with, or `nil` — the
    /// pane's `answerFailures` idiom, keyed by the annotation's own id. A
    /// refusal that reached only the log would leave a row that looks pressed
    /// and a note that did not move.
    let failure: String?
    let onJump: (String) -> Void
    let onGotIt: () -> Void
    let onNotThis: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The kind's own glyph and its own word, from MaughamCore's
                // single spelling — the queue draws these notes with the same
                // two, and a second mapping here is how one surface comes to
                // call a question something the other does not.
                Image(systemName: annotation.kind.systemImageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(annotation.kind.displayName)
                Text(annotation.body)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let excerpt {
                ExcerptChip(ref: excerpt, onJump: onJump)
            }
            if canDispose {
                HStack(spacing: 6) {
                    Button("Got it", action: onGotIt)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Take the note. It settles here and in your queue.")
                    Button("Not this", action: onNotThis)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Let it go. Nothing to explain \u{2014} the written "
                              + "decline belongs to a review pass.")
                }
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let paragraphId = annotation.paragraphId else { return }
            onJump(paragraphId)
        }
    }
}

/// A paragraph the note points at, drawn as **the words it said** — the whole
/// of requirement 3 on this surface. Pressing it makes the same jump the row
/// makes; the id it carries is a payload and never a label.
@MainActor
private struct ExcerptChip: View {
    let ref: Diagnostic.Ref
    let onJump: (String) -> Void

    var body: some View {
        Button {
            onJump(ref.paragraphId)
        } label: {
            Text("\u{201C}\(ref.excerpt)\u{201D}")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Go to this paragraph")
    }
}
