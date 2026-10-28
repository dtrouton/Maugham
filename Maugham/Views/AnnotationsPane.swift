import SwiftUI
import AppKit
import MaughamCore

@MainActor
struct AnnotationsPane: View {
    /// The piece the centre column is showing.
    ///
    /// **Optional as of M3 P2 Task 7.** The queue's project scope is a view of
    /// the whole manuscript and has to render with nothing open at all — which
    /// is exactly the state a writer arrives in from the board's open-notes
    /// column. Document scope answers the same nil with the "Select a document"
    /// empty state the mount used to hold.
    let document: Document?
    /// The project: the cross-document walk's owner
    /// (`listAnnotationsAcrossProject`, Task 6) and the manifest whose order
    /// the sections follow.
    let store: ProjectStore
    /// Where a project-scope row finds ITS document. The open-vs-closed
    /// question every row verb is gated on is asked here and nowhere else.
    let documentStore: DocumentStore
    /// How wide the queue is looking. Window state on `ProjectWindow` rather
    /// than the pane's own, so Task 9's board click-through can set it from
    /// outside — and not persisted (a scope is a glance, not a home).
    @Binding var scope: AnnotationScope
    /// Travel to another piece. The window's SUBJECT write and nothing else:
    /// Review's centre shows documents, so this navigation never moves the
    /// persona (the ejection trap — `ManuscriptNavigation`).
    let onTravel: (String) -> Void
    /// **The window's compiler and its sidecar — the round cockpit's two
    /// stores** (M4 P2 Task 3). Optional because this pane serves hosts that
    /// surface no compiler at all (the probe mounts, and any caller predating
    /// the strip): a `nil` here draws no cockpit and never crashes.
    var orchestrator: CompilerOrchestrator?
    var diagnostics: DiagnosticsStore?
    /// **The derivation cache a ruling has to drop** — the same store
    /// `DiagnosticsPane` holds, threaded here because the round cockpit's
    /// letter carries Add to intent (editorial letter P1 Task 9).
    ///
    /// Optional for the hosts that surface no compiler, and `nil` costs only
    /// the invalidation: `RulingPerformer.rule` takes it optionally and the
    /// next run re-derives from a changed statement either way. `nil` here
    /// would be the stale-reading defect `DiagnosticsPane.world`'s own doc
    /// describes, which is why `DetailPaneToggle` passes the real one.
    var world: DeclaredWorldStore?
    /// Record which pass a piece is being reviewed through — `(docId, passId)`.
    /// The write itself is `ProjectWindow.recordActivePass`, the ONE writer of
    /// `UIState.activePassMemory`; this pane only ever asks for it. Defaulted
    /// to a no-op so a host with no window behind it still compiles.
    var onSetActivePass: (String, String) -> Void = { _, _ in }
    /// **The gear menu's persisted choice, threaded to the round cockpit**
    /// (editorial letter P1, Task 8) — the same value + closure pair
    /// `DetailPaneToggle` already holds for the Diagnostics segment. Defaulted
    /// so a caller that surfaces no cockpit (the probe mounts) keeps
    /// compiling with Standard and a no-op write.
    var compilerModel: CompilerModelChoice = .standard
    var onCompilerModelChange: (CompilerModelChoice) -> Void = { _ in }
    /// **The nudge's own verbs** (pass-order nudge gains its verbs) —
    /// `(docId, passId, state)`. The store's per-piece pass write is a closed
    /// three-file census (`PersonaPaneRegistryTests.passStateWritingFiles`:
    /// InspectorView, PieceInspector, ProjectWindow) and this pane is
    /// deliberately not a fourth: the closure is threaded from the SAME
    /// `ProjectWindow` site that already writes the board's chip verb, so a
    /// writer who presses "Mark done" or "Skip" in the queue reaches the one
    /// store channel every other ruling surface reaches, with no direct call
    /// to that store verb anywhere in this file.
    /// Defaulted to a no-op so a host with no window behind it still compiles.
    var onSetPassState: (String, String, PassState?) -> Void = { _, _, _ in }
    /// **The second stet's offer, published as it comes and goes** (editorial
    /// letter P2 Task 8) — `DesignGateView.onConfirmationChanged`'s twin, and
    /// for its reason: the alert below is drawn from the same state and
    /// production passes nothing, but an alert belongs to the window server and
    /// a headless mount can neither read its words nor press its buttons. With
    /// nothing here, the one place the app ASKS about the ledger would be the
    /// one place no test could get past.
    var onChoiceOfferChanged: (ChoiceOffer?) -> Void = { _ in }
    @Environment(UserPreferences.self) private var userPreferences
    /// The window's undo manager — passed into every accept so the Document
    /// registers its undo action against the manager ⌘Z reaches (and clears
    /// the stale native typing-undo stack; the ⌘Z EXC_BAD_ACCESS class).
    @Environment(\.undoManager) private var undoManager

    /// **The run whose turn clause has already been filed** —
    /// `DiagnosticsPane.turnClauseFiledForRun`'s twin, for the same reason:
    /// a second press would file the identical ruling twice, and the letter's
    /// own `scenePosition` was stamped before the ruling existed.
    @State private var turnClauseFiledForRun: String?
    /// What a refused Add to intent said. A press that reached the op log and
    /// was turned away must say so where it happened.
    @State private var letterOfferFailure: String?
    /// **What the last Keep filed, and which run it came from** (Task 10) —
    /// `DiagnosticsPane.keptLetter`'s twin. Not a `Bool`: a second Keep of the
    /// same run makes a second note (spec §3.6 — a copy, not a move), so what
    /// this holds is the note's own title for the confirmation line.
    @State private var keptLetter: LetterKeep.Kept?
    /// What a refused Keep said, in this pane's own channel — the shape
    /// `letterOfferFailure` already takes, for the same reason.
    @State private var letterKeepFailure: String?
    /// One refusal channel for all three ledger verbs, on the same reasoning:
    /// the writer can only be mid-one-press.
    @State private var letterLedgerFailure: String?
    /// `DiagnosticsPane.ledgerRevision`'s twin — the ledger is a statement
    /// document nothing here observes, so a landed lesson re-renders this pane
    /// only because this counter moved. Its own note says what goes wrong
    /// without it.
    @State private var letterLedgerRevision = 0

    @State private var kindFilter: KindOption = .all
    /// Which review pass the queue is looking through (M3 P2 Task 8).
    /// `.followActivePass` — the state it starts in, and returns to whenever
    /// the writer travels to another piece — means "whatever pass this piece
    /// is being reviewed through", so a board chip click lands here already
    /// narrowed to the pass that was clicked.
    @State private var passSelection: AnnotationPassFilter.Selection = .followActivePass
    @State private var triageFilter: AnnotationTriageFilter = .all
    @State private var authorFilter: String = AnnotationAuthorFilter.all
    @State private var showResolved: Bool = false
    @State private var rejectSheet: AnnotationTarget?
    @State private var querySheet: AnnotationTarget?
    /// The language-tagged question being answered as a ruling (publish
    /// department, Task 8) — the edition brief's `## Rulings` and the thread's
    /// reply, from one sentence.
    @State private var rulingSheet: AnnotationTarget?
    /// What `QueryRuling.commit` refused, in its own words. A refusal here can
    /// arrive with half the act done (the ruling landed, the reply did not), so
    /// it is never swallowed — the sentence says what is where.
    @State private var rulingNotice: String?
    /// **What a ledger verb refused, in its own words** (editorial letter P2
    /// Task 8) — the queue's **This is a choice** and **Keep as lesson…**.
    ///
    /// Deliberately not `rulingNotice`. That channel's alert is titled *"That
    /// answer could not be filed"*, and a choice's worst refusal says the
    /// opposite — the ledger row landed and only the stet did not. A title
    /// contradicting its own message is a refusal the writer cannot act on.
    @State private var ledgerNotice: String?
    /// The second stet standing at its offer, or nil the rest of the time —
    /// which is most of the time. Both answers ride on the value
    /// (`ChoiceOffer`), so the button labelled **Make it a choice** is the one
    /// that files, and a test can drive the offer the window server will not
    /// let it press.
    @State private var choiceOffer: ChoiceOffer?
    /// The accepted craft note being shortened into a ledger entry (spec §6's
    /// second door).
    @State private var keepLessonSheet: AnnotationTarget?
    @State private var staleConfirm: AnnotationTarget?
    /// A suggestion whose accept was REFUSED because its quoted phrase is no
    /// longer in the paragraph (RULING-5). Drives the told-why alert; the
    /// refusal itself is `Document.acceptAnnotation`'s throw — this state only
    /// makes it audible.
    @State private var anchorLostNotice: AnnotationTarget?
    /// The accepted suggestion pending a revert confirmation — set when the
    /// paragraph's text drifted since the accept, so reverting would clobber
    /// the intervening edits (mirror of `staleConfirm` on the accept path).
    @State private var revertConfirm: AnnotationTarget?
    /// The annotation currently being edited in the inline edit sheet (author
    /// self-service). Only ever the reviewer's own annotation (gated by the
    /// Edit affordance's `isOwn` check).
    @State private var editSheet: AnnotationTarget?
    /// The annotation pending a withdraw (delete) confirmation.
    @State private var withdrawConfirm: AnnotationTarget?
    /// Annotation ids currently showing the transient "stet" flourish after the
    /// writer STETS a note. Keyed per-row so it survives the ~2.5s window
    /// between the stet op and the row leaving the open list.
    ///
    /// It fired on REJECT until M3 P2, where the word got a verb of its own and
    /// the flourish went with it: "stet" means *let it stand*, and a rejected
    /// note is precisely the one that did not.
    @State private var stetFlourishIds: Set<String> = []
    /// Selection mode (M3 P2 Task 5). While on, every row grows a leading
    /// selection control and the bulk bar sits at the foot of the column. Off
    /// by default and off is the pane Task 4 left: a writer working one note at
    /// a time never sees a checkbox.
    @State private var showBulkBar: Bool = false
    /// The ids the writer has ticked. Read through `effectiveSelection`, never
    /// directly — an id in here can stop being on screen (a bulk stet hides its
    /// row under the default `[.open]` filter; a filter change narrows the set),
    /// and acting on a row nobody can see is the author filter's stale-target
    /// bug in another key.
    @State private var selectedIds: Set<String> = []
    /// The one summary a bulk run posts when some of it could not be done
    /// (`AnnotationBulkActions.Outcome.notice`). One notice for the batch —
    /// never an alert per refusal, and never silence.
    @State private var bulkNotice: String?
    /// True while a batch is running, so the bar's verbs cannot be fired twice
    /// over a set the first run is still changing.
    @State private var bulkInFlight: Bool = false
    /// **Project scope's own refresh** (M3 P2 Task 7).
    ///
    /// `ProjectStore.listAnnotationsAcrossProject` is deliberately
    /// NON-reactive: its cache is `@ObservationIgnored`, so nothing re-renders
    /// because a note somewhere in the project changed. Every verb below bumps
    /// this, and `projectSnapshot` reads it — so a stet fired from a
    /// cross-document row re-reads the walk instead of leaving its own row on
    /// screen unchanged. `AnnotationScopeTests`' census keeps the two halves
    /// together as verbs are added.
    ///
    /// It is also the seam for Task 9's annotation event, which is what will
    /// refresh a change arriving from another device or a closed document.
    @State private var projectRefreshToken: Int = 0
    /// This pane's hosting window, for the ADR 0021 receive helper's liveness
    /// guard (`.onProjectEvent` on `.maughamAnnotationsChanged`).
    @State private var window: NSWindow?

    /// A sheet's subject, plus the document it belongs to.
    ///
    /// In project scope the row's document is not the pane's own, and a sheet
    /// that remembered only the annotation would commit its reject reason or
    /// its edit against whichever piece happened to be centred.
    struct AnnotationTarget: Identifiable {
        let document: Document
        let annotation: Annotation
        var id: String { annotation.id }
    }

    private var filter: AnnotationFilter {
        let kinds: Set<AnnotationKind>? = kindFilter.kind.map { Set([$0]) }
        let statuses: Set<AnnotationStatus>? = showResolved ? nil : [.open]
        return AnnotationFilter(kinds: kinds, statuses: statuses)
    }

    /// **The kind + status pass, in one place for both scopes.**
    ///
    /// The status half deliberately keeps any row mid-"stet" on screen after
    /// the stet flips its status out of the open filter, so the ~2.5s flourish
    /// is visible. The KIND half still applies to a retained row: a note the
    /// writer filtered out by kind has no business reappearing because they
    /// stetted it.
    private func passesKindAndStatus(_ annotation: Annotation) -> Bool {
        if let kinds = filter.kinds, !kinds.contains(annotation.kind) { return false }
        guard let statuses = filter.statuses else { return true }
        return statuses.contains(annotation.status)
            || stetFlourishIds.contains(annotation.id)
    }

    /// The author + triage + review-pass filters. **The resolved author filter
    /// is passed IN** rather than read per row: resolving it consults the whole
    /// in-scope pool, and in project scope that pool comes from a walk whose
    /// cache key stats every closed piece's op log. Asking per annotation
    /// turned one render into one file-stat sweep per note. The resolved pass
    /// travels the same way for symmetry, and because both scopes resolve it
    /// once per render rather than once per row.
    private func passesRowFilters(
        _ annotation: Annotation, authorFilter selected: String, passId: String?
    ) -> Bool {
        AnnotationAuthorFilter.matches(annotation, selected: selected)
            && triageFilter.matches(annotation)
            && AnnotationPassFilter.matches(annotation, passId: passId)
    }

    // MARK: - The active pass (M3 P2 Task 8)
    //
    // All three inputs are read off the two stores this pane already holds,
    // the way `boardRows` reads `store.manifest.structure` a few lines down.
    // Threading copies of them through the mount would be a second path to
    // the same values with nothing keeping the two in step — and the pane can
    // reach both stores regardless, so the copies would buy no confinement.
    // Reading them inside the body is also what makes them REACTIVE: both
    // stores are `@Observable`, so an inspector ruling on a pass, or a board
    // chip recording one, re-renders the queue.
    //
    // Reading pass states is all this pane's OWN code ever does with them.
    // Writing one is a closed census of three files (`PersonaPaneRegistryTests.
    // passStateWritingFiles`) and this file is deliberately not a fourth: the
    // nudge's Mark done / Skip buttons call `onSetPassState`, a closure the
    // host supplies, rather than the store's write verb directly — so a writer
    // CAN rule on a pass from here, but only through the one channel every
    // other ruling surface already writes through.

    /// The project's named passes — the filter menu's contents, and the order
    /// the advisory nudge reads "earlier" off.
    private var reviewPasses: [ReviewPass] { store.manifest.effectiveReviewPasses }

    /// Which pass each piece was last looked at through. The board's chip
    /// click is the only writer; this pane only ever reads it.
    private var activePassMemory: ActivePassMemory {
        documentStore.uiState.activePassMemory
    }

    /// The centred piece's recorded pass states, for the nudge. Nil with no
    /// piece open, which is also every case in which the nudge has nothing to
    /// be about.
    private var piecePassStates: [String: PassState]? {
        guard let docId = document?.docId else { return nil }
        return TreeWalk.find(id: docId, in: store.manifest.structure)?.passStates
    }

    /// **Which pass the queue is looking through**, or nil for every pass —
    /// the pane's selection resolved against the piece's remembered active
    /// pass and the project's live pass list (`AnnotationPassFilter.resolved`).
    ///
    /// `piece` is the CENTRED document in document scope and nil in project
    /// scope, where there is no single piece whose active pass could be the
    /// default; an explicit choice still narrows every piece's section.
    private var resolvedPassId: String? {
        AnnotationPassFilter.resolved(
            passSelection,
            piece: scope.isProject ? nil : document?.docId,
            memory: activePassMemory,
            passes: reviewPasses)
    }

    /// Document scope's rows after the kind/status filter, before the author
    /// filter.
    private func kindStatusAnnotations(of document: Document) -> [Annotation] {
        // Observing annotationsVersion forces re-render when cache invalidates.
        _ = document.annotationsVersion
        return document.annotations(filter: AnnotationFilter(statuses: nil))
            .filter(passesKindAndStatus)
    }

    /// The notes in scope after the kind/status filter, whichever scope that
    /// is. The distinct-authors list derives from these so it reflects
    /// everything currently in scope regardless of which author is selected.
    private var kindStatusPool: [Annotation] {
        switch scope {
        case .document:
            return document.map(kindStatusAnnotations(of:)) ?? []
        case .project:
            return projectSnapshot.annotations
                .map(\.annotation).filter(passesKindAndStatus)
        }
    }

    /// The author filter, ignored when its target is no longer in scope (e.g.
    /// the status filter changed and that contributor's only rows fell away).
    /// Prevents a stale selection from hiding everything with no way to reset.
    private func effectiveAuthorFilter(in pool: [Annotation]) -> String {
        guard authorFilter != AnnotationAuthorFilter.all else { return authorFilter }
        return AnnotationAuthorFilter.distinctLabels(in: pool).contains(authorFilter)
            ? authorFilter : AnnotationAuthorFilter.all
    }

    private func visibleAnnotations(of document: Document) -> [Annotation] {
        let pool = kindStatusAnnotations(of: document)
        let selected = effectiveAuthorFilter(in: pool)
        let passId = resolvedPassId
        let rows = pool.filter {
            passesRowFilters($0, authorFilter: selected, passId: passId)
        }
        // The queue's working order (M3 P2): what the writer said they'd do,
        // then document order. The DERIVER's newest-first order (claim
        // M5-AN-004) is untouched — that claim is about the projection, and
        // this sorts the pane's rows out of it.
        return AnnotationQueueOrder.sorted(rows, sequence: document.sequence)
    }

    private var authorLabels: [String] {
        AnnotationAuthorFilter.distinctLabels(in: kindStatusPool)
    }

    // MARK: - Project scope

    /// The project-wide walk (Task 6), read through Task 7's refresh
    /// obligation: the token every verb bumps, and the OPEN document's own
    /// version counter, so an edit made from the margin card or the editor
    /// while project scope is up reaches the queue too. The store's cache key
    /// already folds every open document's version — what these two reads add
    /// is somebody OBSERVING them, which the `@ObservationIgnored` cache
    /// otherwise leaves nobody to do.
    private var projectSnapshot: ProjectAnnotationsSnapshot {
        _ = projectRefreshToken
        _ = document?.annotationsVersion
        return store.listAnnotationsAcrossProject()
    }

    /// The board's rows — the order and grouping of the whole project, asked of
    /// the one walk that already answers it (`ReviewBoardRows`, P1).
    private var boardRows: [ReviewBoardRows.Row] {
        ReviewBoardRows.derive(structure: store.manifest.structure)
    }

    private func projectSections(
        _ snapshot: ProjectAnnotationsSnapshot
    ) -> [AnnotationScopeSections.Section] {
        let pool = snapshot.annotations.filter { passesKindAndStatus($0.annotation) }
        let selected = effectiveAuthorFilter(in: pool.map(\.annotation))
        let passId = resolvedPassId
        let entries = pool.filter {
            passesRowFilters($0.annotation, authorFilter: selected, passId: passId)
        }
        return AnnotationScopeSections.build(
            rows: boardRows, annotations: entries, sequences: snapshot.sequences,
            figures: store.manifest.figures ?? [])
    }

    // MARK: - Selection (document scope only)

    /// The selection narrowed to what is actually on screen — the self-healing
    /// read of `selectedIds`, mirroring `effectiveAuthorFilter`'s shape (a
    /// computed fallback, because a stored set cannot be pruned from inside
    /// `body`). A bulk stet that hides its own rows leaves the tick marks
    /// pointing at nothing; this is what stops the next verb acting on them.
    /// The stored set is pruned to this after each run.
    private func effectiveSelection(in rows: [Annotation]) -> Set<String> {
        guard !selectedIds.isEmpty else { return [] }
        return selectedIds.intersection(rows.map(\.id))
    }

    /// What a bulk verb acts on: the selection when there is one, else the
    /// whole visible filtered set (spec §5's "over the current filtered set").
    /// The bar says which, so the writer is never guessing.
    private func bulkTargets(in rows: [Annotation]) -> [Annotation] {
        let selection = effectiveSelection(in: rows)
        guard !selection.isEmpty else { return rows }
        return rows.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            roundCockpit
            passOrderNudge
            switch scope {
            case .document:
                documentScope
            case .project(let focusPiece):
                projectScope(focusPiece: focusPiece)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The pass default is PER PIECE, so travelling re-asks the question.
        // Carrying an explicit choice across would filter the new piece's
        // queue by a pass the writer chose while reading a different chapter —
        // and, worse, silently hide notes on a piece they have just arrived at.
        .onChange(of: document?.docId) { _, _ in
            passSelection = .followActivePass
            loadDiagnostics()
        }
        // The cockpit reads the diagnostics sidecar, and nothing else in this
        // column loads it — a writer who never opened the Diagnostics pane for
        // this piece would otherwise see "round —" over a lane with four
        // rounds on disk. `load` is `DiagnosticsPane`'s own idiom (`onAppear`
        // + the docId change), refuses while a run is previewing, and is never
        // called from `body`.
        .onAppear { loadDiagnostics() }
        // Every sheet and alert a row's verbs raise, over this pane's own state
        // (`AnnotationsPaneDialogs`).
        .modifier(AnnotationsPaneDialogs(
            store: store, verbs: verbs,
            rejectSheet: $rejectSheet, querySheet: $querySheet,
            rulingSheet: $rulingSheet, rulingNotice: $rulingNotice,
            choiceOffer: $choiceOffer, ledgerNotice: $ledgerNotice,
            keepLessonSheet: $keepLessonSheet, staleConfirm: $staleConfirm,
            anchorLostNotice: $anchorLostNotice, revertConfirm: $revertConfirm,
            bulkNotice: $bulkNotice, editSheet: $editSheet,
            withdrawConfirm: $withdrawConfirm))
        // The closed-document / cross-device half of project scope's refresh
        // (M3 P2 Task 9). The verbs below bump the token for the notes the
        // writer changes HERE; this is for the ones that changed somewhere
        // else — a peer device's sync, a note added to a piece this window
        // never opened. `.onProjectEvent` owns the scope filter and the
        // closed-window liveness guard (ADR 0021, tripwire 21); the window is
        // resolved through `WindowAccessor` because a cached `nil` is not a
        // close check (`MaughamEvent.isLive`).
        .background(WindowAccessor(window: $window))
        .onProjectEvent(.maughamAnnotationsChanged, url: store.url, window: window) { _ in
            verbs.noteChanged()
        }
        // **This column's chrome may not move the WINDOW's floor.** The stack
        // above is non-scrolling: the toolbar, the round cockpit and the
        // advisory nudge each demand their full height as a MINIMUM, and that
        // minimum propagates out to `NSHostingView`. `window.contentMinSize` is
        // stamped once at mount, so a strip that appears later (the nudge, on a
        // pass swap) raises the layout's minimum above a window size the window
        // still considers legal — and SwiftUI CENTRES what it cannot compress,
        // which puts the binder tree's scroll view partly above the window's
        // top edge with its scroller never having moved. Measured 2026-08-18:
        // the pass write raised this pane's minimum height by exactly the
        // nudge's 26pt. See `WindowFloorFreeLayout` and
        // `TreeScrollStabilityTests`.
        .doesNotRaiseTheWindowFloor()
    }

    // MARK: - The round cockpit (M4 P2 Task 3)

    /// The strip below the toolbar — `AnnotationsRoundCockpit`, whose own doc
    /// says why it lives there. The letter's state is this pane's, handed down
    /// as bindings so it lives exactly as long as it did.
    private var roundCockpit: some View {
        AnnotationsRoundCockpit(
            scope: scope, document: document, store: store,
            documentStore: documentStore, orchestrator: orchestrator,
            diagnostics: diagnostics, world: world,
            reviewPasses: reviewPasses, cockpitActivePass: cockpitActivePass,
            onSetActivePass: onSetActivePass,
            compilerModel: compilerModel,
            onCompilerModelChange: onCompilerModelChange,
            undoManager: undoManager,
            onJumpToParagraph: { jump(toParagraph: $0) },
            turnClauseFiledForRun: $turnClauseFiledForRun,
            letterOfferFailure: $letterOfferFailure,
            keptLetter: $keptLetter,
            letterKeepFailure: $letterKeepFailure,
            letterLedgerFailure: $letterLedgerFailure,
            letterLedgerRevision: $letterLedgerRevision)
    }

    /// **The piece's RECORDED active pass** — `validatedActivePass`, the one
    /// spelling of the read rule, and deliberately not `resolvedPassId`.
    ///
    /// `resolvedPassId` is the queue's FILTER: a lens the writer may have
    /// widened to "All Passes" to see every note. What a round is filed under
    /// is this value (`CompilerEnvironment+Project`'s `activePass` closure
    /// reads exactly it), so a strip keyed on the filter would name one lane
    /// and run another. `passOrderNudge` refuses the same substitution.
    private var cockpitActivePass: ReviewPass? {
        guard let docId = document?.docId,
              let id = activePassMemory.validatedActivePass(
                forPiece: docId, in: reviewPasses)
        else { return nil }
        return reviewPasses.first { $0.id == id }
    }

    /// **The lessons ledger as it stands, for the rows** (P3 Task 8).
    ///
    /// Every row is handed this so *Keep as lesson…* can be withdrawn over a
    /// sentence the writer has already filed (`QueueLedgerVerbs.offersAKeep`).
    /// `letterLedgerRevision` is read for `ledgerHandlers`' reason and the same
    /// one press-by-press: a note kept from this very queue must take its own
    /// button off the row, and nothing else observes that counter.
    ///
    /// **Read once per pass and threaded DOWN**, on the same reasoning as the
    /// sequences the project scope carries into its sections (tripwire 4): a
    /// closed statement's `displayText` re-lists and re-stats its op-log files
    /// and re-materialises its text on every call, so asking for it per row
    /// would put a small filesystem walk behind every note in the queue.
    private var ledgerText: String? {
        _ = letterLedgerRevision
        return LessonLedgerVerbs.ledgerText(store: store)
    }

    /// Pull this document's sidecar into the store so the strip's round and
    /// report line are the ones on disk. Never called from `body` — `load`
    /// bumps `version`, which is what the reads above observe.
    private func loadDiagnostics() {
        guard let diagnostics, let docId = document?.docId else { return }
        diagnostics.load(docId: docId)
    }

    // MARK: - The advisory nudge (M3 P2 Task 8)

    /// One quiet line when the piece is being worked through a pass while an
    /// earlier one is still open. **Advice, not a gate** (the constitution's
    /// lenses-not-gates): nothing is disabled, nothing is confirmed, and a
    /// writer who means to proofread before the structural pass is finished
    /// reads one sentence and carries on.
    ///
    /// **Keyed on the piece's RECORDED active pass, never on `resolvedPassId`.**
    /// The filter is a lens over the same piece; what the writer is *working*
    /// it through does not change because they widened the view to see every
    /// note (spec §2, and `PassOrderAdvice.advice`, whose signature has no
    /// selection to hand it).
    ///
    /// Document scope only: it is a statement about ONE piece's pass states,
    /// and in project scope every section is a different piece with different
    /// ones — a single caption there could only be wrong.
    ///
    /// **Gains its own verbs** (pass-order nudge gains its verbs): Mark done
    /// and Skip, so the writer can close the earlier pass at the moment the
    /// question arises rather than leaving to the Inspector's ladder or the
    /// board's chip menu. Still advisory — the row draws no confirmation and
    /// disables nothing; pressing a button is the writer's own act, exactly as
    /// choosing a state in the ladder always was.
    @ViewBuilder
    private var passOrderNudge: some View {
        if let nudge = Self.passOrderNudgeDecision(
            isProjectScope: scope.isProject, docId: document?.docId,
            memory: activePassMemory, passes: reviewPasses,
            passStates: piecePassStates,
            posture: { documentStore.posture(forDocId: $0) },
            onSetPassState: onSetPassState) {
            PassOrderNudgeRow(
                pass: nudge.pass, onMarkDone: nudge.onMarkDone, onSkip: nudge.onSkip)
            Divider()
        }
    }

    // MARK: - Document scope

    @ViewBuilder
    private var documentScope: some View {
        if let document {
            documentQueue(document)
        } else {
            // The empty state the mount used to hold, moved inside so the scope
            // toggle above it stays reachable: a writer who closed the piece
            // must still be able to widen to the project (tripwire 15's frame
            // chain travels with it).
            ContentUnavailableView(
                "Select a document",
                systemImage: "doc.text",
                description: Text("Open a manuscript to see and act on its notes — or switch to All Pieces for the whole project."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The centred document's queue — `AnnotationsDocumentQueue`, handed the
    /// rows this pane's lens leaves and the selection it holds.
    private func documentQueue(_ document: Document) -> some View {
        let rows = visibleAnnotations(of: document)
        return AnnotationsDocumentQueue(
            document: document, rows: rows,
            deletedNotes: showResolved ? document.withdrawnAnnotations() : [],
            showResolved: showResolved, showBulkBar: showBulkBar,
            selection: effectiveSelection(in: rows),
            targets: bulkTargets(in: rows),
            ledgerText: { ledgerText },
            documentStore: documentStore,
            cockpitActivePass: cockpitActivePass,
            bulkInFlight: bulkInFlight,
            selectedIds: $selectedIds,
            wiring: rowWiring, verbs: verbs)
    }

    // MARK: - Project scope (M3 P2 Task 7)

    /// Every piece's notes — `AnnotationsProjectQueue`, over the one snapshot
    /// read, the sections this pane's lens leaves and its footnote.
    private func projectScope(focusPiece: String?) -> some View {
        let snapshot = projectSnapshot
        return AnnotationsProjectQueue(
            focusPiece: focusPiece, scope: scope, snapshot: snapshot,
            sections: projectSections(snapshot),
            notice: AnnotationScopeSections.unreadableNotice(
                unreadableDocIds: snapshot.unreadableDocIds, rows: boardRows,
                figures: store.manifest.figures ?? []),
            ledgerText: { ledgerText },
            documentStore: documentStore,
            wiring: rowWiring)
    }

    // MARK: - One row, either scope

    /// What every `AnnotationListView` here is handed: this pane's sheets and
    /// verbs, each pressed against the row's OWN document.
    private var rowWiring: AnnotationRowWiring {
        AnnotationRowWiring(
            localName: userPreferences.collaboratorDisplayName,
            stetFlourishIds: stetFlourishIds,
            manifest: store.manifest,
            rowVerbs: { rowVerbs(for: $0, docId: $1, isOwn: $2) },
            onToggleSelection: { toggleSelection($0) },
            onAccept: { verbs.accept($0, $1) },
            onReject: { rejectSheet = AnnotationTarget(document: $0, annotation: $1) },
            onStet: { verbs.stet($0, $1) },
            onTriage: { verbs.triage($0, $1, mark: $2) },
            onArchive: { verbs.archive($0, $1) },
            onReply: { querySheet = AnnotationTarget(document: $0, annotation: $1) },
            onAnswerAsRuling: {
                rulingSheet = AnnotationTarget(document: $0, annotation: $1) },
            onMakeChoice: { verbs.performChoice($0, $1) },
            onKeepAsLesson: {
                keepLessonSheet = AnnotationTarget(document: $0, annotation: $1) },
            onEdit: { editSheet = AnnotationTarget(document: $0, annotation: $1) },
            onWithdraw: {
                withdrawConfirm = AnnotationTarget(document: $0, annotation: $1) },
            onRevert: { verbs.revert($0, $1) },
            onReopen: { verbs.reopen($0, id: $1.id) },
            onJump: { click(docId: $0, annotation: $1) })
    }

    /// This pane's verbs — `AnnotationsPaneVerbs`, built per call over
    /// bindings to its own state and never stored.
    private var verbs: AnnotationsPaneVerbs {
        AnnotationsPaneVerbs(
            store: store, documentStore: documentStore, world: world,
            userPreferences: userPreferences, undoManager: undoManager,
            onChoiceOfferChanged: onChoiceOfferChanged,
            projectSnapshot: { projectSnapshot },
            visibleAnnotations: { visibleAnnotations(of: $0) },
            effectiveSelection: { effectiveSelection(in: $0) },
            staleConfirm: $staleConfirm, anchorLostNotice: $anchorLostNotice,
            revertConfirm: $revertConfirm, rulingNotice: $rulingNotice,
            ledgerNotice: $ledgerNotice, choiceOffer: $choiceOffer,
            stetFlourishIds: $stetFlourishIds, bulkInFlight: $bulkInFlight,
            selectedIds: $selectedIds, bulkNotice: $bulkNotice,
            letterLedgerRevision: $letterLedgerRevision,
            projectRefreshToken: $projectRefreshToken)
    }

    /// **Which verbs this Mac may offer on this row** (P3c Task 5) — asked of
    /// the posture of THE ROW'S OWN DOCUMENT, by `docId`, never of the
    /// window's selection: in project scope a pieces-author's own chapter
    /// carries its verbs and the chapter beside it, somebody else's, carries
    /// none. The drawing door answers for a closed document too, so a closed
    /// piece's row is judged by its own posture as well (its verbs are also
    /// disabled until it is opened — `AnnotationScopePolicy.verbsEnabled`).
    /// Reading the door observes `postureEpoch`, so a promotion or a demotion
    /// redraws the queue with no reopen.
    private func rowVerbs(
        for ann: Annotation, docId: String, isOwn: Bool
    ) -> AnnotationRowVerbs {
        let rulingKind: Statement.Kind? = switch RulingDestination.offered(
            for: ann, manifest: store.manifest) {
        case .editionBrief(let language): .editionBrief(language)
        case .firstReader: .firstReader
        case nil: nil
        }
        return AnnotationRowVerbs.decide(
            posture: documentStore.posture(forDocId: docId),
            isOwn: isOwn,
            rulingStatement: rulingKind.map(postureOfStatement(_:)),
            lessons: postureOfStatement(.lessons))
    }

    /// The posture of a PROJECT statement (every statement a queue verb files
    /// into is one), through the same door and the same id rule the statement
    /// pane uses — a statement not yet written asks the project stream.
    private func postureOfStatement(_ kind: Statement.Kind) -> Posture {
        documentStore.posture(forDocId: StatementEditorHost.postureDocId(
            kind: kind, scope: .project, statements: store.manifest.statements))
    }

    /// **What clicking a row means** — the pure rule's answer, applied.
    /// Travelling writes the window's SUBJECT and nothing else; the persona is
    /// never touched (`AnnotationScopeTests`, and `ManuscriptNavigation`'s
    /// ruling behind it).
    private func click(docId: String, annotation: Annotation) {
        switch AnnotationScopePolicy.click(
            rowDocId: docId, activeDocId: document?.docId) {
        case .jump:
            jump(annotation)
        case .travel(let piece):
            onTravel(piece)
        case .stay:
            break
        }
    }

    /// The queue's filters. Its composition — and the width pressure a narrow
    /// right column puts it under — is `AnnotationsQueueToolbar`'s, so that the
    /// one thing it must do can be measured without mounting this whole pane
    /// (`AnnotationsQueueToolbarWidthTests`).
    @ViewBuilder
    private var toolbar: some View {
        AnnotationsQueueToolbar(
            kindFilter: $kindFilter,
            passSelection: $passSelection,
            triageFilter: $triageFilter,
            authorFilter: $authorFilter,
            showResolved: $showResolved,
            reviewPasses: reviewPasses,
            resolvedPassId: resolvedPassId,
            scopeIsProject: scope.isProject,
            // …and only where this document's posture leaves a bulk verb to
            // press (P3c Task 5): selection mode over a bar with no verbs is a
            // mode with nothing at the end of it.
            showsBulkAffordances:
                AnnotationScopePolicy.showsBulkAffordances(scope)
                    && (document.map {
                        Self.bulkOffersAVerb(posture: documentStore.posture(forDocId: $0.docId))
                    } ?? true),
            selectionModeOn: showBulkBar,
            authorLabels: authorLabels,
            onSetScope: { setScope($0) },
            onToggleSelectionMode: toggleSelectionMode)
    }

    /// Selection mode's door. A mode rather than always-on checkboxes: the
    /// column is narrow and a writer answering notes one at a time should not
    /// pay for a control they are not using. Leaving the mode drops the ticks —
    /// a selection nobody can see is a trap the next entry would spring.
    private func toggleSelectionMode() {
        showBulkBar.toggle()
        if !showBulkBar { selectedIds.removeAll() }
    }

    /// Widening leaves selection mode behind. The ticks are document-scope
    /// state, and a selection nobody can see is the trap the mode's own door
    /// already clears them to avoid.
    private func setScope(_ newScope: AnnotationScope) {
        scope = newScope
        if !AnnotationScopePolicy.showsBulkAffordances(newScope) {
            showBulkBar = false
            selectedIds.removeAll()
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func jump(_ ann: Annotation) {
        // Span-precise navigation: the editor selects the exact resolved span
        // when it has one, else falls back to the paragraph. Carry both so the
        // fallback works even when the span is stale / paragraph-level. Also post
        // the legacy paragraph notification so ProjectWindow still focuses the
        // manuscript pane.
        var info: [String: Any] = ["annotation_id": ann.id]
        if let pid = ann.paragraphId { info["paragraph_id"] = pid }
        MaughamEvent.post(
            .maughamNavigateToAnnotation, to: .keyWindow, payload: info)
        if let pid = ann.paragraphId { jump(toParagraph: pid) }
    }

    /// **The one place this file posts `.maughamNavigateToParagraph`** (fix
    /// round 1, Minor 5; tripwire 21). A row's jump carries a span as well and
    /// posts its own annotation event first; the letter's carries only the
    /// paragraph. Both end here, so the payload key and the scope are spelled
    /// once.
    private func jump(toParagraph pid: String) {
        MaughamEvent.post(
            .maughamNavigateToParagraph, to: .keyWindow,
            payload: ["paragraph_id": pid])
    }
}
