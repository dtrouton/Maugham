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
    private struct AnnotationTarget: Identifiable {
        let document: Document
        let annotation: Annotation
        var id: String { annotation.id }
    }

    enum KindOption: String, CaseIterable, Identifiable, FilterRowItem {
        case all, comments, suggestions, queries, craft

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .comments: return "Comments"
            case .suggestions: return "Suggestions"
            case .queries: return "Queries"
            case .craft: return "Craft"
            }
        }

        var symbolName: String {
            switch self {
            case .all: return "circle"
            case .comments: return "bubble.left"
            case .suggestions: return "pencil.line"
            case .queries: return "questionmark.circle"
            case .craft: return "book"
            }
        }

        var kind: AnnotationKind? {
            switch self {
            case .all: return nil
            case .comments: return .comment
            case .suggestions: return .suggestedChange
            case .queries: return .query
            case .craft: return .craftNote
            }
        }
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

    /// **Whether the document-scope empty state means "nothing here" or
    /// "narrowed to nothing"** (M4 P2 Task 8, T3 carry; widened in review,
    /// corrected in whole-branch review — see below).
    ///
    /// Pure so both readings are assertable without a mount — `pool` is every
    /// OPEN annotation on the document regardless of kind, author, triage or
    /// pass (`AnnotationFilter(statuses: [.open])`), `visibleRows` is fully
    /// filtered (`visibleAnnotations`), and the two can only disagree when
    /// one of those four — not the queue itself, and not resolved status —
    /// is what's showing nothing.
    ///
    /// **`pool` must stay pinned to `.open` and never widen to every status.**
    /// A writer who settles every note (the loop's own success state) has
    /// zero open notes and some number of resolved ones; if `pool` counted
    /// the resolved notes too, this predicate would read "narrowed to
    /// nothing" and the pane would claim Kind/Author/Triage/the pass filter
    /// was hiding notes that no such filter can reveal — only **Show
    /// Resolved** can, and that control isn't named in the copy this
    /// function's answer feeds. A cleared queue is the ordinary empty case,
    /// not a filtered one, and it's also the moment `emptyState`'s own
    /// `.settled` arm ("You've handled this check's notes.") is telling the
    /// SAME writer the SAME thing on the sibling pane — the two must not
    /// disagree about whether the queue is empty.
    static func documentQueueIsGenuinelyEmpty(
        pool: [Annotation], visibleRows: [Annotation]
    ) -> Bool {
        visibleRows.isEmpty && pool.isEmpty
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
            rows: boardRows, annotations: entries, sequences: snapshot.sequences)
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
        .sheet(item: $rejectSheet) { target in
            RejectReasoningSheet(annotation: target.annotation) { reason in
                reject(target.document, target.annotation, reason: reason)
                rejectSheet = nil
            } onCancel: { rejectSheet = nil }
        }
        .sheet(item: $querySheet) { target in
            QueryReplySheet(annotation: target.annotation) { reply in
                replyToQuery(target.document, target.annotation, reply: reply)
                querySheet = nil
            } onCancel: { querySheet = nil }
        }
        .sheet(item: $rulingSheet) { target in
            // The tag is what opened the sheet, so it is there; the fallback
            // draws a sheet that will refuse in `commit`'s own words rather
            // than crashing on the writer's sentence.
            QueryRulingSheet(
                annotation: target.annotation,
                language: QueryRuling.language(of: target.annotation) ?? ""
            ) { answer in
                answerAsRuling(target.document, target.annotation, answer: answer)
                rulingSheet = nil
            } onCancel: { rulingSheet = nil }
        }
        .alert(
            "That answer could not be filed",
            isPresented: Binding(
                get: { rulingNotice != nil },
                set: { if !$0 { rulingNotice = nil } })
        ) {
            Button("OK") { rulingNotice = nil }
        } message: {
            Text(rulingNotice ?? "")
        }
        // **The second stet's offer** (editorial letter P2 Task 8, spec §6).
        // An alert rather than an `NSAlert`: the answer has to be observable
        // from a test, and a panel the headless worker has to dismiss is a
        // gate that hangs.
        //
        // **Three buttons, and Cancel is the one that carries `.cancel`**
        // (Denver's ruling, fix round 1). Escape ABANDONS: the offer goes away
        // and the note is left exactly as the writer found it. Giving the role
        // to **Just stet** would make Escape settle a note — a keystroke that
        // resolves something is not a way out of a question, and the writer who
        // hit it to make the dialog go away would find the note gone from their
        // queue. Both real answers are pressed on purpose.
        .alert(
            QueueLedgerVerbs.secondStetTitle(choiceOffer?.heading ?? ""),
            isPresented: Binding(
                get: { choiceOffer != nil },
                set: { if !$0 { setChoiceOffer(nil) } }),
            presenting: choiceOffer
        ) { offer in
            Button(QueueLedgerVerbs.makeItAChoiceTitle, action: offer.makeItAChoice)
            Button(QueueLedgerVerbs.justStetTitle, action: offer.justStet)
            Button(QueueLedgerVerbs.cancelTitle, role: .cancel,
                   action: offer.cancel)
        } message: { _ in
            Text(QueueLedgerVerbs.secondStetHelp)
        }
        .alert(
            "That could not be filed in your ledger",
            isPresented: Binding(
                get: { ledgerNotice != nil },
                set: { if !$0 { ledgerNotice = nil } })
        ) {
            Button("OK") { ledgerNotice = nil }
        } message: {
            Text(ledgerNotice ?? "")
        }
        .sheet(item: $keepLessonSheet) { target in
            LessonHeadingSheet(annotation: target.annotation) { heading in
                keepAsLesson(target.annotation, heading: heading)
                keepLessonSheet = nil
            } onCancel: { keepLessonSheet = nil }
        }
        .alert(
            "Paragraph has changed since this suggestion",
            isPresented: Binding(
                get: { staleConfirm != nil },
                set: { if !$0 { staleConfirm = nil } })
        ) {
            Button("Apply anyway") {
                if let target = staleConfirm {
                    Task { await performAccept(target.document, target.annotation) }
                }
                staleConfirm = nil
            }
            Button("Cancel", role: .cancel) { staleConfirm = nil }
        } message: {
            Text("Applying this suggestion will replace the current paragraph text with the originally-proposed replacement.")
        }
        .alert(
            "This suggestion can no longer be applied",
            isPresented: Binding(
                get: { anchorLostNotice != nil },
                set: { if !$0 { anchorLostNotice = nil } })
        ) {
            Button("OK") { anchorLostNotice = nil }
        } message: {
            Text(anchorLostMessage)
        }
        .alert(
            "Paragraph has changed since this suggestion was accepted",
            isPresented: Binding(
                get: { revertConfirm != nil },
                set: { if !$0 { revertConfirm = nil } })
        ) {
            Button("Revert anyway") {
                if let target = revertConfirm {
                    performRevert(target.document, target.annotation)
                }
                revertConfirm = nil
            }
            Button("Cancel", role: .cancel) { revertConfirm = nil }
        } message: {
            Text("Reverting will replace the current paragraph text with what it was before the accept. Edits made since the accept will be lost.")
        }
        .alert(
            "Not everything in the batch could be done",
            isPresented: Binding(
                get: { bulkNotice != nil },
                set: { if !$0 { bulkNotice = nil } })
        ) {
            Button("OK") { bulkNotice = nil }
        } message: {
            Text(bulkNotice ?? "")
        }
        .sheet(item: $editSheet) { target in
            EditAnnotationSheet(annotation: target.annotation) { newBody, newSuggested in
                editOwn(target.document, target.annotation,
                        newBody: newBody, newSuggested: newSuggested)
                editSheet = nil
            } onCancel: { editSheet = nil }
        }
        .alert(
            "Delete your annotation",
            isPresented: Binding(
                get: { withdrawConfirm != nil },
                set: { if !$0 { withdrawConfirm = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let target = withdrawConfirm {
                    withdrawOwn(target.document, target.annotation)
                }
                withdrawConfirm = nil
            }
            Button("Cancel", role: .cancel) { withdrawConfirm = nil }
        } message: {
            Text("This removes your annotation. The history is preserved, but the annotation will no longer appear here or in the editor.")
        }
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
            noteChanged()
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

    /// **The strip that says where the reviewer is and offers the next round**
    /// — `ReviewRoundCockpit`, mounted below the toolbar's divider and above
    /// the nudge (spec §7).
    ///
    /// **Not in the toolbar, and that is structural rather than aesthetic.**
    /// `AnnotationsQueueToolbar`'s one job is fitting a column whose floor is
    /// 240pt, and `AnnotationsQueueToolbarWidthTests` measures the row as
    /// declared; a control added there would inflate the pane's layout width
    /// and centre every annotation body against a width the column does not
    /// have — the exact defect that suite was written for.
    ///
    /// **Document scope only.** The strip is a statement about ONE piece's
    /// pass, round and next run; in project scope every section is a different
    /// piece with different answers, and a single strip there could only be
    /// wrong (`passOrderNudge` refuses the same way for the same reason).
    ///
    /// A `nil` orchestrator or store draws nothing: this pane serves hosts
    /// with no compiler behind them.
    @ViewBuilder
    private var roundCockpit: some View {
        if !scope.isProject, let document, let orchestrator, let diagnostics {
            let pass = cockpitActivePass
            // **The seat, for the label alone** (editorial letter P1, Task 6).
            // `effectiveCoach` rather than `PieceReader`: the strip already
            // holds the piece's resolved stage beside it, and the two values
            // together are exactly the resolution's arms — a second reader
            // here would be a copy of `reader(forPiece:memory:)` with nothing
            // keeping the two in step.
            let coach = store.manifest.effectiveCoach
            ReviewRoundCockpit(
                passes: reviewPasses,
                activePassId: pass?.id,
                // **Her lane, when the piece has no stage.** `latestRound` is
                // asked about a LANE id, and an unassigned coached piece files
                // its rounds under hers — asking with `nil` would report no
                // round over a piece she has read three times.
                round: cockpitRound(diagnostics, docId: document.docId,
                                    passId: pass?.id ?? coach?.id),
                coach: coach,
                phase: ReviewRoundCockpit.phase(
                    runState: orchestrator.runState, docId: document.docId),
                reportLine: cockpitReportLine(diagnostics, docId: document.docId),
                onRun: { freshEyes in
                    orchestrator.runRequested(
                        docId: document.docId, freshEyes: freshEyes)
                },
                onSetActivePass: { passId in
                    onSetActivePass(document.docId, passId)
                },
                onCancel: { orchestrator.cancel() },
                compilerModel: compilerModel,
                onCompilerModelChange: onCompilerModelChange,
                // **The letter, in one line with the whole of it behind a
                // disclosure** (spec §3.5). The line comes from the strip's
                // own static so Author and Review cannot disagree about what
                // it says; the disclosure opens the SAME `LetterSection`
                // Author draws, wired to this pane's document and project.
                letterLine: ReviewRoundCockpit.letterLine(
                    cockpitLetter(diagnostics, docId: document.docId)),
                // **The stage beside the round, both the last run's** (P3 Task
                // 5, global constraint 28). Read off the run rather than
                // `cockpitLetter`, which drops a letter with nothing in it: a
                // run can derive a stage and still write a letter that says
                // nothing, and the lane line is about the RUN.
                stage: cockpitStage(diagnostics, docId: document.docId),
                letterDisclosure: cockpitLetter(diagnostics, docId: document.docId)
                    .map { letter in
                        { AnyView(letterSection(letter, document: document,
                                                diagnostics: diagnostics)) }
                    },
                // **The same field Author's header carries, over the same
                // per-document value** (spec §3.7). The strip holds no store,
                // so the commit arrives as a closure — `AskField.commit` is
                // the one spelling of it, so neither home can refuse a long
                // ask in different words.
                ask: AskField.Input(
                    docId: document.docId,
                    text: cockpitAsk(diagnostics, docId: document.docId),
                    commit: { text in
                        AskField.commit(text, docId: document.docId,
                                        diagnostics: diagnostics)
                    },
                    note: { text, doc in
                        AskField.note(text, docId: doc, diagnostics: diagnostics)
                    }))
            Divider()
        }
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

    /// **Who reads this piece** — the one resolution (`PieceReader`, spec §4.1),
    /// asked here so the empty queue's offer names the same editor the run
    /// will sign with.
    ///
    /// Deliberately not a second copy of `cockpitActivePass`: that value is
    /// the piece's STAGE and must stay nil over a coached piece, because the
    /// cockpit's lane label takes its coach arm on exactly that. This answers
    /// the whole question — stage, coach, or nobody — and the two agree by
    /// construction, since the resolution reads `validatedActivePass` too.
    ///
    /// The offer reads `activePass?.editorName` rather than `editorName`,
    /// because a piece nobody reads has no editor to name in an invitation:
    /// `editorName` is never nil (it falls back to "Claude", the byline a
    /// passless run signs with), and naming that in "Run Claude's round" would
    /// invent a personification the seat-vacant case exists to avoid.
    private var cockpitReader: PieceReader? {
        guard let docId = document?.docId else { return nil }
        return store.manifest.reader(forPiece: docId, memory: activePassMemory)
    }

    /// The lane's newest round number. `latestRound` consults the standing run
    /// before the ring — the ONE spelling of "which round is this lane on",
    /// shared with the round mint, so the strip and the run cannot disagree.
    private func cockpitRound(
        _ diagnostics: DiagnosticsStore, docId: String, passId: String?
    ) -> Int? {
        _ = diagnostics.version
        return diagnostics.latestRound(forPass: passId, docId: docId)
    }

    /// The stage the last run on this piece derived, version-gated exactly as
    /// every other read of the sidecar here is (P3 Task 5). `Letter.draftStage`
    /// is the ONE conversion from the stored raw.
    private func cockpitStage(
        _ diagnostics: DiagnosticsStore, docId: String
    ) -> DraftStage? {
        _ = diagnostics.version
        return diagnostics.lastRun(docId: docId)?.letter?.draftStage
    }

    /// The writer's standing ask for this piece, version-gated exactly as
    /// every other read of the sidecar here is — so a commit made in Author's
    /// header is what this field shows.
    private func cockpitAsk(
        _ diagnostics: DiagnosticsStore, docId: String
    ) -> String? {
        _ = diagnostics.version
        return diagnostics.ask(docId: docId)
    }

    /// The standing run's letter for this piece, version-gated exactly as
    /// every other read of the sidecar here is. `nil` for no run, no letter,
    /// or a letter with nothing in it — `ReviewRoundCockpit.letterLine` makes
    /// the same judgement about emptiness, and this feeds both the line and
    /// the disclosure so they can never disagree about whether there is one.
    private func cockpitLetter(
        _ diagnostics: DiagnosticsStore, docId: String
    ) -> Letter? {
        _ = diagnostics.version
        guard let letter = diagnostics.lastRun(docId: docId)?.letter,
              !letter.isEmpty else { return nil }
        return letter
    }

    /// **The disclosure's contents: Author's own section, in Review's
    /// column.** Every verb is this pane's — the jump is its event, the task
    /// is its document, the ruling is its project — so the reviewer can act on
    /// the letter without leaving the queue.
    @ViewBuilder
    private func letterSection(
        _ letter: Letter, document: Document, diagnostics: DiagnosticsStore
    ) -> some View {
        let run = diagnostics.lastRun(docId: document.docId)
        let ledger = ledgerHandlers(letter, run: run)
        LetterSection(
            letter: letter,
            // **The run, so an accepted exercise is forgotten with it** \u{2014}
            // an index means nothing outside one letter (final review).
            runId: run?.id,
            signature: LetterSection.signature(
                voice: cockpitReader?.editorName ?? PieceReader.nobody.editorName,
                round: run?.round, stage: run?.letter?.draftStage),
            currentText: { document.paragraphs[$0] },
            onJump: { jump(toParagraph: $0) },
            onAcceptExercise: { habit in
                document.createPaneTask(
                    body: habit.exercise ?? habit.name,
                    parentTaskId: nil,
                    paragraphId: habit.refs.first?.paragraphId,
                    undoManager: undoManager)
            },
            onAddTurnClause: turnClauseOffer(letter, run: run, docId: document.docId),
            // The tense follows the scope the ruling will be filed at, and
            // both come from the same builder.
            addToIntentTitle: TurnClauseOffer.buttonTitle(
                store: store, docId: document.docId),
            // **The same verb Author's pane presses** (`LetterKeep`, spec
            // §3.6): one render, one scope, one router — so a letter kept from
            // the queue and a letter kept from the report are the same note.
            onKeep: LetterKeep.handler(
                letter: letter, run: run, docId: document.docId, store: store,
                editorName: cockpitReader?.editorName ?? PieceReader.nobody.editorName,
                onKept: { keptLetter = $0 },
                onFailure: { letterKeepFailure = $0 }),
            offerFailure: letterOfferFailure,
            keepConfirmation: LetterKeep.confirmation(for: keptLetter, run: run),
            keepFailure: letterKeepFailure,
            // **The same builder Author's pane calls** (`LessonOffer.handlers`,
            // P2 Task 7): one provenance, one date, one refusal channel — so a
            // lesson kept from the queue and a lesson kept from the report are
            // the same row, filed the same way.
            ledgerText: ledger.ledgerText,
            freshEyes: run?.freshEyes == true,
            onKeepAsLesson: ledger.onKeepAsLesson,
            onAllChoices: ledger.onAllChoices,
            onRetire: ledger.onRetire,
            ledgerFailure: letterLedgerFailure)
    }

    /// **The ledger's four inputs, from the one builder both hosts call.** The
    /// provenance and the date live there; this supplies the queue's own
    /// voice, its own store and its own re-read.
    private func ledgerHandlers(
        _ letter: Letter, run: CompilerRun?
    ) -> LessonLedgerHandlers {
        // Read so the ledger text below is re-derived once a write lands —
        // see `letterLedgerRevision`, which nothing else observes.
        _ = letterLedgerRevision
        return LessonOffer.handlers(
            letter: letter, run: run, store: store, world: world,
            voice: cockpitReader?.editorName ?? PieceReader.nobody.editorName,
            onFiled: { letterLedgerRevision += 1 },
            onFailure: { letterLedgerFailure = $0 })
    }

    /// **The offer, decided and written by `TurnClauseOffer`** — the one
    /// builder Author's Diagnostics pane calls too (fix round 1, Minor 4).
    /// The predicate and the ruling live there; this supplies the queue's own
    /// values and its own refusal channel.
    private func turnClauseOffer(
        _ letter: Letter, run: CompilerRun?, docId: String
    ) -> (() -> Void)? {
        TurnClauseOffer.handler(
            letter: letter, run: run, docId: docId, store: store, world: world,
            voice: cockpitReader?.editorName ?? PieceReader.nobody.editorName,
            filedRunId: turnClauseFiledForRun,
            onFiled: { turnClauseFiledForRun = $0 },
            onFailure: { letterOfferFailure = $0 })
    }

    private func cockpitReportLine(
        _ diagnostics: DiagnosticsStore, docId: String
    ) -> String? {
        _ = diagnostics.version
        return ReviewRoundCockpit.reportLine(
            history: diagnostics.roundHistory(docId: docId),
            run: diagnostics.lastRun(docId: docId),
            annotations: cockpitAnnotations)
    }

    /// **The document's queue in EVERY state** — what the since-last-round
    /// line is counted from, and never the pane's visible rows.
    ///
    /// The rows on screen are filtered by kind, status, author, triage and
    /// pass. Counting those would make "resolved" permanently zero under the
    /// default `[.open]` filter and would skew all three numbers under any
    /// other — a number the writer is trusting, quietly wrong. The status
    /// filtering the line needs is `SinceLastRound`'s own.
    ///
    /// Gated on `annotationsVersion` on this pane's own idiom, so a note the
    /// writer stets in the queue moves the sentence rather than leaving it
    /// stale until the next round.
    private var cockpitAnnotations: [Annotation] {
        guard let document else { return [] }
        _ = document.annotationsVersion
        return document.annotations(filter: AnnotationFilter(statuses: nil))
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
        if !scope.isProject,
           let docId = document?.docId,
           let earlier = PassOrderAdvice.advice(
                forPiece: docId, memory: activePassMemory,
                passes: reviewPasses, passStates: piecePassStates) {
            PassOrderNudgeRow(
                pass: earlier,
                onMarkDone: { onSetPassState(docId, earlier.id, .done) },
                onSkip: { onSetPassState(docId, earlier.id, .skipped) })
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

    @ViewBuilder
    private func documentQueue(_ document: Document) -> some View {
        let rows = visibleAnnotations(of: document)
        let deletedNotes = showResolved ? document.withdrawnAnnotations() : []
        if rows.isEmpty && deletedNotes.isEmpty {
            // **Two different empty states, and only one of them is empty**
            // (M4 P2 Task 8, T3 carry; widened, then corrected, in review).
            // `rows` is the pool after EVERY filter — kind, status, author,
            // triage and pass — has narrowed it; a writer whose queue is
            // merely filtered down to nothing was being told to go ask for a
            // round that had, in fact, already answered.
            //
            // **The pool this checks against is `.open`, never every
            // status.** A writer who has settled every note (the loop's own
            // success state) has zero open notes and, typically, some
            // resolved ones — counting those as "still there" would claim
            // Kind/Author/Triage/the pass filter was hiding notes that ONLY
            // Show Resolved can reveal, over a queue that is genuinely and
            // correctly empty (`documentQueueIsGenuinelyEmpty`'s own doc
            // comment carries the fuller account, incl. why this cannot
            // disagree with `emptyState`'s `.settled` arm on the sibling
            // pane). Never `kindStatusAnnotations` either: that pre-filters
            // by KIND, so a writer narrowed to Suggestions on a document
            // holding only open comments would have read `pool.isEmpty` too
            // and drawn the round-teaching "No annotations" over notes the
            // KIND filter alone was hiding.
            if !Self.documentQueueIsGenuinelyEmpty(
                pool: document.annotations(filter: AnnotationFilter(statuses: [.open])),
                visibleRows: rows) {
                ContentUnavailableView(
                    "No notes match your filters",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Your queue isn\u{2019}t empty \u{2014} these "
                        + "notes are just hidden by Kind, Author, Triage, or "
                        + "the pass filter. Widen one to see them."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // **The empty state teaches the loop** (M4 P2 Task 3). It used
                // to name one of the two ways this queue fills — "ask Claude
                // for editorial feedback" — and that is no longer the one
                // Review is built around. Both are named now, the round first
                // and by the editor who reads it
                // (`ReviewRoundCockpit.emptyQueueTeaching`).
                //
                // **The editor comes from the one reader resolution**
                // (`cockpitReader`, editorial letter P1 Task 6 fix round), so
                // an unassigned piece under a held seat offers Le Guin's round
                // rather than falling back to "ask Claude in Claude Desktop" —
                // the round it offers is the round the run would actually make.
                ContentUnavailableView(
                    "No annotations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(ReviewRoundCockpit.emptyQueueTeaching(
                        editorName: cockpitReader?.activePass?.editorName)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                let livePids = Set(document.sequence)
                let selection = effectiveSelection(in: rows)
                LazyVStack(spacing: 0) {
                    ForEach(rows) { ann in
                        annotationRow(
                            ann, docId: document.docId, document: document,
                            livePids: livePids,
                            isSelectable: showBulkBar,
                            isSelected: selection.contains(ann.id))
                        Divider()
                    }
                    // RULING-34: delete is normalised for annotations too.
                    // The writer's withdrawn notes are findable here and
                    // restorable — not gone at one expired ⌘Z's mercy.
                    if showResolved && !deletedNotes.isEmpty {
                        Text("Deleted")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.top, 10)
                        ForEach(deletedNotes, id: \.id) { note in
                            HStack(spacing: 8) {
                                Text(note.body)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Spacer()
                                Button("Restore") { reopen(document, id: note.id) }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
            // Only over rows: the Deleted section below the queue is
            // restore-only, and a bar offering to accept nothing is a
            // dead control (RULING-35).
            if showBulkBar && !rows.isEmpty {
                Divider()
                bulkBar(document: document, rows: rows)
            }
        }
    }

    // MARK: - Project scope (M3 P2 Task 7)

    @ViewBuilder
    private func projectScope(focusPiece: String?) -> some View {
        let snapshot = projectSnapshot
        let sections = projectSections(snapshot)
        let notice = AnnotationScopeSections.unreadableNotice(
            unreadableDocIds: snapshot.unreadableDocIds, rows: boardRows)
        if sections.isEmpty && notice == nil {
            ContentUnavailableView(
                "No annotations in this project",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Every piece's notes gather here. Ask Claude for editorial feedback to see annotations."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sections) { section in
                            // The sequences travel DOWN from the one snapshot
                            // read: asking the store per section would restat
                            // every closed piece's op log once per heading.
                            sectionView(section, sequences: snapshot.sequences)
                        }
                        if let notice { unreadableFootnote(notice) }
                    }
                }
                .onAppear { scroll(to: focusPiece, proxy: proxy) }
                .onChange(of: scope) { _, newScope in
                    if case .project(let piece) = newScope {
                        scroll(to: piece, proxy: proxy)
                    }
                }
            }
        }
    }

    /// Bring an arriving piece's section into view (Task 9's click-through from
    /// the board sets `focusPiece`). Deferred a tick: the sections mount lazily
    /// and a `scrollTo` issued in the same pass lands on a stack that has not
    /// laid its rows out yet — the `TreeScrollTarget` shape.
    private func scroll(to piece: String?, proxy: ScrollViewProxy) {
        guard let piece else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            withAnimation { proxy.scrollTo(piece, anchor: .top) }
        }
    }

    @ViewBuilder
    private func sectionView(
        _ section: AnnotationScopeSections.Section,
        sequences: [String: [String]]
    ) -> some View {
        switch section.kind {
        case .group(let depth):
            Text(section.item.title)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12 + CGFloat(depth) * 12)
                .padding(.trailing, 12)
                .padding(.top, 14).padding(.bottom, 2)
                .id(section.id)
        case .piece:
            pieceSection(section, sequences: sequences)
        }
    }

    @ViewBuilder
    private func pieceSection(
        _ section: AnnotationScopeSections.Section,
        sequences: [String: [String]]
    ) -> some View {
        // The row's own document, and the whole of the open-vs-closed question:
        // a closed piece's notes are readable here and actable in ITS window.
        let rowDocument = documentStore.document(forDocId: section.item.id)
        let livePids = Set(rowDocument?.sequence
            ?? sequences[section.item.id] ?? [])
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(section.item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(section.annotations.count)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer(minLength: 4)
                if rowDocument == nil {
                    Image(systemName: "lock")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(AnnotationScopePolicy.closedPieceReason)
                        .accessibilityLabel(AnnotationScopePolicy.closedPieceReason)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ForEach(section.annotations) { ann in
                annotationRow(ann, docId: section.item.id,
                              document: rowDocument, livePids: livePids)
                Divider()
            }
        }
        .id(section.id)
    }

    /// RULING-54's honesty half at the queue's foot — see
    /// `AnnotationScopeSections.unreadableNotice`.
    @ViewBuilder
    private func unreadableFootnote(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.caption2)
            Text(notice).font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: - One row, either scope

    /// The one row builder. Document scope passes its own document for every
    /// row; project scope passes the row's, which is `nil` for a closed piece —
    /// and that nil is the whole of the verb gate.
    @ViewBuilder
    private func annotationRow(
        _ ann: Annotation,
        docId: String,
        document rowDocument: Document?,
        livePids: Set<String>,
        isSelectable: Bool = false,
        isSelected: Bool = false
    ) -> some View {
        AnnotationRow(
            annotation: ann,
            revertIsEnabled: AnnotationRowPolicy.revertEnabled(ann, livePids: livePids),
            showingStet: stetFlourishIds.contains(ann.id),
            isOwn: AnnotationOwnership.isOwn(
                ann, localName: userPreferences.collaboratorDisplayName),
            verbsEnabled: AnnotationScopePolicy.verbsEnabled(
                documentIsOpen: rowDocument != nil),
            verbsDisabledReason: AnnotationScopePolicy.closedPieceReason,
            isSelectable: isSelectable,
            isSelected: isSelected,
            onToggleSelection: { toggleSelection(ann.id) },
            onAccept: { withDocument(rowDocument) { accept($0, ann) } },
            onReject: { withDocument(rowDocument) {
                rejectSheet = AnnotationTarget(document: $0, annotation: ann) } },
            onStet: { withDocument(rowDocument) { stet($0, ann) } },
            onTriage: { mark in
                withDocument(rowDocument) { triage($0, ann, mark: mark) } },
            onArchive: { withDocument(rowDocument) { archive($0, ann) } },
            onReply: { withDocument(rowDocument) {
                querySheet = AnnotationTarget(document: $0, annotation: ann) } },
            onAnswerAsRuling: { withDocument(rowDocument) {
                rulingSheet = AnnotationTarget(document: $0, annotation: ann) } },
            onMakeChoice: { withDocument(rowDocument) { performChoice($0, ann) } },
            onKeepAsLesson: { withDocument(rowDocument) {
                keepLessonSheet = AnnotationTarget(document: $0, annotation: ann) } },
            onEdit: { withDocument(rowDocument) {
                editSheet = AnnotationTarget(document: $0, annotation: ann) } },
            onWithdraw: { withDocument(rowDocument) {
                withdrawConfirm = AnnotationTarget(document: $0, annotation: ann) } },
            onRevert: { withDocument(rowDocument) { revert($0, ann) } },
            onReopen: { withDocument(rowDocument) { reopen($0, id: ann.id) } },
            onJumpToParagraph: { click(docId: docId, annotation: ann) })
    }

    /// Belt behind the disabled verbs: a control that somehow fires with no
    /// live document does nothing, rather than reaching for a transient one
    /// whose ops the writer's ⌘Z could never find.
    private func withDocument(_ document: Document?, _ body: (Document) -> Void) {
        guard let document else { return }
        body(document)
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
            showsBulkAffordances:
                AnnotationScopePolicy.showsBulkAffordances(scope),
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

    /// The bulk bar. Two rows so nothing truncates in a narrow column: the
    /// scope on top (what is being acted on, and the one control that changes
    /// it), the verbs below.
    @ViewBuilder
    private func bulkBar(document: Document, rows: [Annotation]) -> some View {
        let targets = bulkTargets(in: rows)
        let selection = effectiveSelection(in: rows)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(selection.isEmpty ? "Select All" : "Deselect All") {
                    selectedIds = selection.isEmpty ? Set(rows.map(\.id)) : []
                }
                .buttonStyle(.link)
                Spacer(minLength: 4)
                Text(selection.isEmpty
                     ? "All \(targets.count) shown"
                     : "\(selection.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                bulkTriageMenu(document: document, targets: targets,
                               hasSelection: !selection.isEmpty)
            }
            HStack(spacing: 8) {
                bulkButton(.accept, document: document, targets: targets,
                           hasSelection: !selection.isEmpty,
                           help: "Answer these at once. ⌘Z reverses the batch — "
                               + "except for accepted suggestions, where it reaches "
                               + "only the last; use a row's Revert for the others.")
                bulkButton(.stet, document: document, targets: targets,
                           hasSelection: !selection.isEmpty,
                           help: "Read, considered — and the words stand. "
                               + "Resolves these without applying or refusing anything.")
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    @ViewBuilder
    private func bulkButton(
        _ verb: AnnotationBulkActions.BulkVerb, document: Document,
        targets: [Annotation], hasSelection: Bool, help: String
    ) -> some View {
        let planned = AnnotationBulkActions.plan(targets, verb: verb)
        Button(AnnotationBulkActions.buttonTitle(
            verb, planned: planned.count, targetCount: targets.count,
            hasSelection: hasSelection)
        ) {
            runBulk(verb, on: planned, in: document)
        }
        .buttonStyle(.bordered)
        .disabled(planned.isEmpty || bulkInFlight)
        .help(help)
    }

    /// Marking a pile is the gesture bulk was built for — a writer skims forty
    /// notes, flags what they mean to do, then works the `Do` band. Each item
    /// carries its own honest count, since the notes already holding that mark
    /// are not reached (the row's menu refuses the same re-mark).
    @ViewBuilder
    private func bulkTriageMenu(
        document: Document, targets: [Annotation], hasSelection: Bool
    ) -> some View {
        Menu {
            ForEach(TriageMark.allCases, id: \.self) { mark in
                bulkMenuItem(.triage(mark), document: document, targets: targets,
                             hasSelection: hasSelection)
            }
            Divider()
            bulkMenuItem(.triage(nil), document: document, targets: targets,
                         hasSelection: hasSelection)
        } label: {
            Label("Triage", systemImage: "flag")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(bulkInFlight)
        .help("Mark what you plan to do about all of these")
    }

    @ViewBuilder
    private func bulkMenuItem(
        _ verb: AnnotationBulkActions.BulkVerb, document: Document,
        targets: [Annotation], hasSelection: Bool
    ) -> some View {
        let planned = AnnotationBulkActions.plan(targets, verb: verb)
        Button(AnnotationBulkActions.buttonTitle(
            verb, planned: planned.count, targetCount: targets.count,
            hasSelection: hasSelection)
        ) {
            runBulk(verb, on: planned, in: document)
        }
        .disabled(planned.isEmpty)
    }

    /// Run one verb over the planned ids.
    ///
    /// **No undo group wraps this** (ADR 0023's D1 corollary): a group would
    /// have to cover accept, and `Document.acceptAnnotation` calls
    /// `removeAllActions` from inside itself. Each note registers its own undo
    /// action instead; `NSUndoManager`'s event grouping then coalesces the
    /// batch, so one ⌘Z reverses it — which is what one deliberate click should
    /// cost. The accepted consequence is accept's own: each SUGGESTION accept
    /// wipes the previous registrations, so after a bulk accept only the LAST
    /// suggestion is reachable by ⌘Z and the rest need a row's Revert. The
    /// Accept button's tooltip says so; `AnnotationBulkActionsTests` pins it.
    /// It stays true of a mixed batch because `AnnotationBulkActions.plan`
    /// sorts suggestions ahead of textless notes, so the wipes land before any
    /// comment registers — see that function's doc for why the alternative left
    /// an accepted comment reachable by nothing at all.
    private func runBulk(
        _ verb: AnnotationBulkActions.BulkVerb, on ids: [String],
        in document: Document
    ) {
        guard !ids.isEmpty, !bulkInFlight else { return }
        bulkInFlight = true
        // The same flourish a single Stet wears, at scale: the rows stay put
        // for ~2.5s wearing the proofreader's mark before they resolve out of
        // the open list, so the writer sees what they just did.
        if verb == .stet { stetFlourishIds.formUnion(ids) }
        Task {
            let outcome = await AnnotationBulkActions.perform(
                verb, on: ids, in: document, undoManager: undoManager)
            bulkInFlight = false
            noteChanged()
            // Selection hygiene: the run may have taken its own rows off
            // screen. Prune to what is still visible rather than leaving ticks
            // pointing at nothing.
            selectedIds = effectiveSelection(in: visibleAnnotations(of: document))
            if let notice = outcome.notice { bulkNotice = notice }
            if verb == .stet {
                // Drop the mark from anything that did NOT stet immediately:
                // the flourish says "this note has been let stand", and a row
                // wearing it for 2.5s over a note that is still open is the
                // surface lying about what happened.
                stetFlourishIds.subtract(
                    Set(ids).subtracting(outcome.succeeded))
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                stetFlourishIds.subtract(outcome.succeeded)
            }
        }
    }

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    // MARK: - The verbs
    //
    // Every one of them takes the document EXPLICITLY. In project scope the
    // row's document is not the pane's own, and a verb that reached for
    // `self.document` would answer a note about Chapter Nine by editing
    // whatever happens to be centred. The pane's own document is just the
    // argument document scope passes.
    //
    // Every one of them also calls `noteChanged()` when its work lands — see
    // `projectRefreshToken`. `AnnotationScopeTests` keeps the two together.

    private func accept(_ document: Document, _ ann: Annotation) {
        if ann.kind == .suggestedChange && ann.isStale {
            staleConfirm = AnnotationTarget(document: document, annotation: ann)
            return
        }
        Task { await performAccept(document, ann) }
    }

    private var anchorLostMessage: String {
        let quoted: String
        if let quote = anchorLostNotice?.annotation.span?.quote, !quote.isEmpty {
            quoted = " (\u{201C}\(quote)\u{201D})"
        } else {
            quoted = ""
        }
        return "The passage it would replace\(quoted) is no longer in the "
            + "paragraph, so applying it could put the replacement in the wrong "
            + "place. The suggestion stays open — ask Claude for a fresh one "
            + "against the current text."
    }

    /// The one accept executor for suggestion-capable paths: a refusal for a
    /// lost span anchor (RULING-5) is surfaced, never swallowed — `try?` here
    /// would be the M5-AN-050 silence back again.
    private func performAccept(_ document: Document, _ ann: Annotation) async {
        do {
            try await document.acceptAnnotation(id: ann.id, undoManager: undoManager)
        } catch let error as AnnotationAcceptError where error == .suggestionAnchorLost {
            anchorLostNotice = AnnotationTarget(document: document, annotation: ann)
        } catch {
            documentLog.error("acceptAnnotation failed for \(ann.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        noteChanged()
    }

    /// Reply to a query — an accept carrying the writer's words.
    private func replyToQuery(
        _ document: Document, _ ann: Annotation, reply: String
    ) {
        Task {
            try? await document.acceptAnnotation(
                id: ann.id, userResponse: reply, undoManager: undoManager)
            noteChanged()
        }
    }

    /// Answer a translator's question as doctrine — the ruling in the edition
    /// brief and the reply on the thread, from one sentence (`QueryRuling`).
    ///
    /// The refusal is surfaced rather than logged: unlike a reply, this act can
    /// land half-done, and a writer who is not told would answer again and mint
    /// a second ruling for a decision already in the brief.
    private func answerAsRuling(
        _ document: Document, _ ann: Annotation, answer: String
    ) {
        Task {
            rulingNotice = await QueryRuling.commit(
                answer, answering: ann, in: document, store: store,
                undoManager: undoManager)
            noteChanged()
        }
    }

    private func reject(_ document: Document, _ ann: Annotation, reason: String) {
        Task {
            try? await document.rejectAnnotation(
                id: ann.id, userResponse: reason, undoManager: undoManager)
            noteChanged()
        }
    }

    /// **Stet, or the offer that a second one raises** (editorial letter P2
    /// Task 8, spec §6).
    ///
    /// Once is a note let stand. Twice on the same habit is a pattern, and the
    /// app *asks* at that point — it never files on its own, because the ledger
    /// moves only by the writer's hand. Everything else, including a first stet
    /// and any stet of a note carrying no heading, is the plain stet below,
    /// unchanged.
    private func stet(_ document: Document, _ ann: Annotation) {
        if let heading = QueueLedgerVerbs.secondStetOffer(
            for: ann, in: document,
            ledgerText: LessonLedgerVerbs.ledgerText(store: store)) {
            setChoiceOffer(ChoiceOffer(
                annotationId: ann.id, heading: heading,
                makeItAChoice: {
                    setChoiceOffer(nil)
                    performChoice(document, ann)
                },
                justStet: {
                    setChoiceOffer(nil)
                    performStet(document, ann)
                },
                cancel: { setChoiceOffer(nil) }))
            return
        }
        performStet(document, ann)
    }

    /// The one place the offer is raised and dropped, so the alert's state and
    /// the witness cannot come apart.
    private func setChoiceOffer(_ offer: ChoiceOffer?) {
        choiceOffer = offer
        onChoiceOfferChanged(offer)
    }

    /// Stet — the proofreader's own gesture, and now the only one that wears the
    /// proofreader's mark. The op is recorded immediately (never blocked); the
    /// flag holds the row on-screen ~2.5s so the STET badge and the reinstated
    /// text read clearly before the row resolves out of the open list.
    private func performStet(_ document: Document, _ ann: Annotation) {
        stetFlourishIds.insert(ann.id)
        Task {
            try? await document.stetAnnotation(id: ann.id, undoManager: undoManager)
            noteChanged()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            stetFlourishIds.remove(ann.id)
        }
    }

    /// **This is a choice** — the ledger row and the stet, in that order
    /// (`QueueLedgerVerbs.makeChoice`, which owns both the ordering and the two
    /// refusal sentences).
    ///
    /// The flourish plays exactly as it does for a plain stet: what the writer
    /// did to the note is the same thing, and a choice that resolved a row with
    /// no STET mark would read as a different verb.
    ///
    /// `letterLedgerRevision` moves because the ledger did — the letter's own
    /// Keep and Retire offers are computed against `ledgerText`, and without
    /// this a habit just filed as a choice still draws a Keep button.
    private func performChoice(_ document: Document, _ ann: Annotation) {
        stetFlourishIds.insert(ann.id)
        Task {
            let refusal = await QueueLedgerVerbs.makeChoice(
                ann, in: document, store: store, world: world,
                undoManager: undoManager)
            ledgerNotice = refusal
            letterLedgerRevision += 1
            noteChanged()
            // **A refusal takes the mark off at once** — `runBulk`'s own guard,
            // for its reason: the flourish says "this note has been let
            // stand", and a row wearing it for 2.5s over a note that is still
            // open is the surface lying about what happened. Sleeping first
            // would put the lie on screen for exactly as long as the truth.
            guard refusal == nil else {
                stetFlourishIds.remove(ann.id)
                return
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            stetFlourishIds.remove(ann.id)
        }
    }

    /// **Keep as lesson…** — the writer's shortened sentence, filed. No
    /// annotation op: the note is already accepted, and this is a second,
    /// independent act (`QueueLedgerVerbs.keepAsLesson`).
    private func keepAsLesson(_ ann: Annotation, heading: String) {
        Task {
            ledgerNotice = await QueueLedgerVerbs.keepAsLesson(
                heading, from: ann, store: store, world: world)
            letterLedgerRevision += 1
        }
    }

    /// Mark (or clear) what the writer plans to do about a note. Not a
    /// resolution — the row stays exactly as open as it was; only its place in
    /// the queue moves.
    private func triage(_ document: Document, _ ann: Annotation, mark: TriageMark?) {
        Task {
            try? await document.triageAnnotation(
                id: ann.id, mark: mark, undoManager: undoManager)
            noteChanged()
        }
    }

    private func archive(_ document: Document, _ ann: Annotation) {
        Task {
            try? await document.archiveAnnotation(id: ann.id, undoManager: undoManager)
            noteChanged()
        }
    }

    /// RULING-29's verb, and RULING-34's Restore — one spelling, taking an id
    /// because a withdrawn note is not in the projection to be passed whole.
    /// Extracted from the row's closure so the refresh census can see it; the
    /// `reopenAnnotation` caller census is unmoved, since this is the same file
    /// it already names. Restore reaches the undo-manager overload where it
    /// used to call the bare one, which changes nothing: that overload
    /// registers a ⌘Z pair only for a rejected / archived / stetted note and
    /// falls through un-registered for a withdrawn one, which is all Restore
    /// ever passes it.
    private func reopen(_ document: Document, id: String) {
        Task {
            try? await document.reopenAnnotation(id: id, undoManager: undoManager)
            noteChanged()
        }
    }

    /// Revert an accepted suggestion from the pane (visible under the
    /// resolved/All filter). Reaches accepts ⌘Z can't — ⌘Z only undoes the
    /// most recent one. Gated behind a confirm when the paragraph drifted
    /// since the accept (revert restores the PRE-accept text, clobbering the
    /// intervening edits) — mirror of the accept path's `staleConfirm` gate.
    /// Only THIS pane button gates: the ⌘Z undo closure calls
    /// `revertAcceptedAnnotation` directly (undo of an immediately-prior
    /// action needs no confirm).
    private func revert(_ document: Document, _ ann: Annotation) {
        if document.acceptedTextDrifted(annotationId: ann.id) {
            revertConfirm = AnnotationTarget(document: document, annotation: ann)
            return
        }
        performRevert(document, ann)
    }

    /// Passing the window's undo manager makes the revert itself ⌘Z-undoable
    /// (re-accept, original reply preserved).
    private func performRevert(_ document: Document, _ ann: Annotation) {
        Task {
            try? await document.revertAcceptedAnnotation(
                id: ann.id, undoManager: undoManager)
            noteChanged()
        }
    }

    /// Author self-service edit of one's own annotation. The pane updates via
    /// `annotationsVersion`; the notification refreshes the key-window editor's
    /// crafted marks immediately (mirrors the create-case refresh).
    private func editOwn(
        _ document: Document, _ ann: Annotation,
        newBody: String, newSuggested: String?
    ) {
        Task {
            try? await document.editReviewerAnnotation(
                id: ann.id,
                newBody: newBody,
                newSuggestedText: newSuggested,
                authorName: userPreferences.collaboratorDisplayName,
                undoManager: undoManager)
            noteChanged()
            // No explicit editor notify: the edit bumps `annotationsVersion` on
            // the shared Document, which EditorHost mirrors into the control model
            // → `applyControl` → `setReviewAnnotations`, recomputing crafted marks
            // automatically (ADR 0017).
        }
    }

    /// Author self-service withdraw (delete) of one's own annotation.
    private func withdrawOwn(_ document: Document, _ ann: Annotation) {
        Task {
            try? await document.withdrawReviewerAnnotation(
                id: ann.id,
                authorName: userPreferences.collaboratorDisplayName,
                undoManager: undoManager)
            noteChanged()
        }
    }

    /// Something changed under a row. Bumps the token `projectSnapshot` is
    /// keyed on, so the cross-document queue re-reads a walk nothing else
    /// observes (see `projectRefreshToken`). Cheap and unconditional: it costs
    /// one integer in document scope, where nothing reads it.
    private func noteChanged() {
        projectRefreshToken &+= 1
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

/// RULING-35's other half as a modifier: a reason when there is one, and no
/// tooltip at all when there is not.
private struct RowDisabledReason: ViewModifier {
    let reason: String?

    func body(content: Content) -> some View {
        if let reason {
            content.help(reason)
        } else {
            content
        }
    }
}

@MainActor
/// Row-level control policy — pure, so RULING-35's no-dead-controls rule is
/// testable without mounting the pane.
/// **The advisory nudge's row** (pass-order nudge gains its verbs) — extracted
/// as its own view, the way `AnnotationRow` and `AnnotationsQueueToolbar` are,
/// so its width is measurable the same way theirs is
/// (`AnnotationsQueueToolbarWidthTests`). `AnnotationsPane.passOrderNudge` is a
/// thin wrapper supplying the pass and the two closures; this struct owns no
/// store and calls neither closure itself — pressing a button is the
/// writer's, not the row's.
///
/// The two buttons say only "Mark done" / "Skip" rather than repeating the
/// pass's name: the caption beside them already names it (`PassOrderAdvice.
/// caption(for:)`), and there is only ever one earlier open pass to act on,
/// so a second naming of it would be the row arguing with itself about which
/// word is load-bearing.
struct PassOrderNudgeRow: View {
    let pass: ReviewPass
    let onMarkDone: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.caption2)
            Text(PassOrderAdvice.caption(for: pass))
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Mark done", action: onMarkDone)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            Button("Skip", action: onSkip)
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

enum AnnotationRowPolicy {
    /// Revert makes sense only for an accepted suggestion whose anchor
    /// paragraph still exists — an enabled Revert that silently does nothing
    /// was the M5-AN-030 defect.
    static func revertEnabled(_ ann: Annotation, livePids: Set<String>) -> Bool {
        guard ann.status == .accepted, ann.kind == .suggestedChange,
              let pid = ann.paragraphId else { return true }
        return livePids.contains(pid)
    }
}

struct AnnotationRow: View {
    let annotation: Annotation
    var revertIsEnabled: Bool = true
    var showingStet: Bool = false
    /// True iff this is the local reviewer's own human annotation — gates the
    /// Edit + Delete (withdraw) affordances. Claude's / other humans' rows
    /// never show them.
    var isOwn: Bool = false
    /// **Whether this row's verbs can act** (M3 P2 Task 7). False in the
    /// cross-document scope when the row's piece is closed: there is no live
    /// `Document` to append to, and the alternative — a transient one — would
    /// land an op the writer's ⌘Z could never reach. Disabled WITH a reason,
    /// never enabled and silently inert (RULING-35).
    var verbsEnabled: Bool = true
    var verbsDisabledReason: String? = nil
    /// Multiselect (M3 P2 Task 5) — true only while the pane is in selection
    /// mode. The control is a `Button`, so it takes the click the row's
    /// whole-body `.onTapGesture` would otherwise read as navigation: selecting
    /// a note and travelling to it are different intentions and must not share
    /// a gesture.
    var isSelectable: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: () -> Void = {}
    let onAccept: () -> Void
    let onReject: () -> Void
    /// M3 P2's fourth resolution — read, considered, and the words stand.
    var onStet: () -> Void = {}
    /// Set or clear the note's triage mark (nil clears). Pane-only: the margin
    /// card deliberately has no triage affordance — see `ReviewCardActions`.
    var onTriage: (TriageMark?) -> Void = { _ in }
    let onArchive: () -> Void
    let onReply: () -> Void
    /// The translator's answer that becomes doctrine (publish department, Task
    /// 8). Defaulted to a no-op so every host predating it still compiles —
    /// and never drawn where it would do nothing, since the affordance is
    /// gated on `QueryRuling.offersARuling` rather than on the closure.
    var onAnswerAsRuling: () -> Void = {}
    /// **This is a choice** — a stet that also files the habit heading this
    /// note was raised under (editorial letter P2 Task 8). Defaulted to a no-op
    /// on `onAnswerAsRuling`'s reasoning, and gated on the same shape of
    /// predicate rather than on the closure: nothing draws it where it would do
    /// nothing (`QueueLedgerVerbs.offersAChoice`).
    var onMakeChoice: () -> Void = {}
    /// **Keep as lesson…** on an accepted craft note — spec §6's second door,
    /// gated by `QueueLedgerVerbs.offersAKeep`.
    var onKeepAsLesson: () -> Void = {}
    var onEdit: () -> Void = {}
    var onWithdraw: () -> Void = {}
    var onRevert: () -> Void = {}
    /// RULING-29: resolution is the writer's to reverse, from the surface that
    /// shows it — rendered for archived, rejected and (M3 P2) stetted rows.
    var onReopen: () -> Void = {}
    let onJumpToParagraph: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isSelectable { selectionToggle }
            rowContent
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onJumpToParagraph() }
        .animation(.easeInOut(duration: 0.3), value: showingStet)
    }

    @ViewBuilder
    private var selectionToggle: some View {
        Button(action: onToggleSelection) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
        .help(isSelected ? "Deselect this note" : "Select this note")
        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(annotation.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = annotation.previousRejectionReason, !reason.isEmpty {
                // RULING-31: the writer's rejection reason is part of the
                // note's history and stays visible after a reopen.
                Text("Previously rejected: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
            // Stet reaches every kind now, so the flourish has to as well —
            // it can no longer live inside the suggestion-only diff card.
            if showingStet {
                stetCard
            } else if annotation.kind == .suggestedChange {
                diffCard
            }
            actionRow
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Label(annotation.kind.displayName, systemImage: annotation.kind.systemImageName)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(kindColor)
            authorBadge
            if annotation.isStale {
                Text("Stale")
                    .font(.caption2.smallCaps())
                    .padding(.horizontal, 4)
                    .background(Color.orange.opacity(0.3))
                    .clipShape(Capsule())
            }
            Spacer()
            Text(relativeTimestamp)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Author provenance badge: a colour dot (matching the editor review marks
    /// via `ReviewPalette`) plus the author's display label. nil author → Claude
    /// with the reserved terracotta dot.
    @ViewBuilder
    private var authorBadge: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(authorColor)
                .frame(width: 7, height: 7)
            Text(AnnotationAuthorPresentation.label(for: annotation.author))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help("Authored by \(AnnotationAuthorPresentation.label(for: annotation.author))")
    }

    private var authorColor: Color {
        Color(nsColor: ReviewPalette().color(for: annotation.author))
    }

    /// Strips inline task anchors (`<!--t-XXXXXX-->`) from annotation text before
    /// display. Mirrors `AnnotationDetailView.displayText` on the phone side.
    /// Pure + nonisolated so it's directly unit-testable.
    nonisolated static func displayText(_ raw: String) -> String {
        MarkdownDisplayFilter.stripTaskAnchorsInline(raw)
    }

    @ViewBuilder
    private var diffCard: some View {
        VStack(alignment: .leading, spacing: 1) {
            // "Before" matches the suggestion's grain: the SPAN's original
            // text for a sub-paragraph suggestion, else the whole paragraph —
            // so a one-word suggestion reads `very angry → furious`, not
            // `<whole paragraph> → furious` (SuggestionDisplay, shared w/ phone).
            if let prior = SuggestionDisplay.before(for: annotation) {
                Text("\u{2212} \(AnnotationRow.displayText(prior))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }
            if let suggested = annotation.suggestedText {
                Text("+ \(AnnotationRow.displayText(suggested))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// The proofreader's "stet" treatment shown briefly on stetting a note: for
    /// a suggestion the struck prior text is reinstated (no strike), marked with a
    /// dotted underline, and headed by a clear "STET — let it stand" badge so the
    /// gesture is unmistakable rather than a faint italic aside. A subtle tinted
    /// card + the row-level fade give the eye something to catch in the ~2.5s
    /// dwell before the row resolves.
    @ViewBuilder
    private var stetCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("STET")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(stetAccent)
                    .clipShape(Capsule())
                Text("let it stand")
                    .font(.caption2.italic())
                    .foregroundStyle(stetAccent)
            }
            if let prior = SuggestionDisplay.before(for: annotation) {
                Text(AnnotationRow.displayText(prior))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .underline(true, pattern: .dot, color: stetAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stetAccent.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(stetAccent.opacity(0.5), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .transition(.opacity)
    }

    /// A legible, intentional editor's-ink colour for the stet mark — distinct
    /// from the red/green diff so the eye reads it as a separate gesture.
    private var stetAccent: Color { Color(red: 0.20, green: 0.45, blue: 0.78) }

    /// RULING-29's arm: a resolution is the writer's to reverse, from the
    /// surface that shows it. Stet joined archive and reject there in M3 P2 — it
    /// is a resolution like the other two. Exhaustive on purpose: a fifth status
    /// must decide whether it is reopenable, not inherit an `else`.
    private var showsReopen: Bool {
        switch annotation.status {
        case .archived, .rejected, .stetted: return true
        case .open, .accepted: return false
        }
    }

    /// The row's answers. Every verb keeps its word at the pane's default width;
    /// under pressure (a 240pt column, an own suggestion carrying seven
    /// controls) the secondary ones fall back to icons with the same word as the
    /// tooltip, the way `AdaptiveFilterRow` degrades the kind filter above. The
    /// primary verb — Accept / Got it / Reply — never loses its label.
    ///
    /// **Three variants, not two, because `ViewThatFits` draws its LAST child
    /// whether it fits or not.** Measured 2026-08-15 on the worst honest row —
    /// the writer's own open suggestion, carrying Accept / Reject / Stet /
    /// Archive / triage / edit / delete — the icon variant at the row's default
    /// `spacing: 8` wanted 245pt in a 240pt column and 280.6pt in a 280pt one.
    /// A few points over is the same defect as a hundred: it inflates the pane's
    /// layout width, and everything in the column is then centred against a
    /// width the column does not have. The third variant closes the gaps instead
    /// of taking anything else away, since by that point there is no word left
    /// to lose. `AnnotationsQueueToolbarWidthTests.test_theRowsVerbsFitTheColumn`
    /// is the measurement.
    @ViewBuilder
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actions(useIcons: false)
            actions(useIcons: true)
            actions(useIcons: true, spacing: Self.tightVerbSpacing)
        }
        .controlSize(.small)
        // The whole row of verbs, gated together: a closed piece's note is
        // readable and not actable, and the tooltip says what to do about it.
        // The `.help` is applied only when there IS something to say — an
        // empty help string is a tooltip that opens with nothing in it.
        .disabled(!verbsEnabled)
        .modifier(RowDisabledReason(
            reason: verbsEnabled ? nil : verbsDisabledReason))
    }

    /// The gap the last-resort variant closes to. Small enough to buy back the
    /// points the seven-control row was over by, large enough that two bordered
    /// buttons still read as two.
    static let tightVerbSpacing: CGFloat = 3

    @ViewBuilder
    private func actions(useIcons: Bool, spacing: CGFloat = 8) -> some View {
        HStack(spacing: spacing) {
            if showsReopen {
                // (An accepted suggestion keeps its Revert below — reopening it
                // is Revert's job, text included.)
                Button("Reopen", action: onReopen).buttonStyle(.bordered)
                    .help("Return this to the open list — resolution is yours to reverse (⌘Z re-applies it)")
            } else {
                dispositions(useIcons: useIcons)
            }
            triageMenu
            if isOwn {
                Spacer(minLength: 4)
                ownAffordances
            }
        }
    }

    @ViewBuilder
    private func dispositions(useIcons: Bool) -> some View {
        switch annotation.kind {
        case .comment:
            Button("Got it", action: onAccept).buttonStyle(.borderedProminent)
            stetButton(useIcons: useIcons)
            secondary("Archive", symbol: "archivebox", useIcons: useIcons, action: onArchive)
        case .suggestedChange:
            if annotation.status == .accepted {
                // Accepted rows (visible under the resolved/All filter):
                // the one meaningful action is putting the text back.
                // ⌘Z only reaches the MOST RECENT accept; this reaches
                // any accepted suggestion at any time.
                Button("Revert", action: onRevert).buttonStyle(.bordered)
                    .disabled(!revertIsEnabled)
                    .help(revertIsEnabled
                          ? "Restore the pre-accept text and reopen this suggestion"
                          : "Its paragraph was deleted — there is nothing to revert into")
            } else {
                Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
                secondary("Reject\u{2026}", symbol: "xmark", useIcons: useIcons, action: onReject)
                stetButton(useIcons: useIcons)
                secondary("Archive", symbol: "archivebox", useIcons: useIcons, action: onArchive)
            }
        case .query:
            Button("Reply\u{2026}", action: onReply).buttonStyle(.borderedProminent)
            answerAsRulingButton(useIcons: useIcons)
            choiceButton(useIcons: useIcons)
            stetButton(useIcons: useIcons)
            secondary("Archive", symbol: "archivebox", useIcons: useIcons, action: onArchive)
        case .craftNote:
            Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
            answerAsRulingButton(useIcons: useIcons)
            keepAsLessonButton(useIcons: useIcons)
            secondary("Reject\u{2026}", symbol: "xmark", useIcons: useIcons, action: onReject)
            stetButton(useIcons: useIcons)
            secondary("Archive", symbol: "archivebox", useIcons: useIcons, action: onArchive)
        }
    }

    /// **A habit the writer makes on purpose can be settled from the queue**
    /// (editorial letter P2 Task 8, spec §6) — the ledger row and the stet in
    /// one press.
    ///
    /// Beside Stet rather than in place of it, because it is a stet *and* a
    /// declaration: a writer who only means "let it stand this once" still has
    /// the plain verb, and the second time they press it the app asks whether
    /// they meant this one.
    ///
    /// Secondary, and it degrades to its icon under column pressure with the
    /// rest — a question raised under a habit carries one more control than one
    /// that was not, and the narrow column is where that costs a word.
    @ViewBuilder
    private func choiceButton(useIcons: Bool) -> some View {
        if QueueLedgerVerbs.offersAChoice(annotation) {
            secondary(QueueLedgerVerbs.choiceTitle, symbol: "checkmark.seal",
                      useIcons: useIcons,
                      help: QueueLedgerVerbs.choiceHelp,
                      action: onMakeChoice)
        }
    }

    /// **Spec §6's second door** — an accepted craft note's point, kept.
    /// `QueueLedgerVerbs.offersAKeep` says why it is accepted notes and no
    /// others.
    @ViewBuilder
    private func keepAsLessonButton(useIcons: Bool) -> some View {
        if QueueLedgerVerbs.offersAKeep(annotation) {
            secondary(QueueLedgerVerbs.keepTitle, symbol: "graduationcap",
                      useIcons: useIcons,
                      help: QueueLedgerVerbs.keepHelp,
                      action: onKeepAsLesson)
        }
    }

    /// **A translator's question can be answered into doctrine** (publish
    /// department, Task 8) — offered on the two kinds a language tag ever
    /// reaches, and only while the tag is there and the question open
    /// (`QueryRuling.offersARuling`).
    ///
    /// Secondary rather than primary: Reply is still the ordinary answer, and
    /// most notes in this queue are not a translator's. It degrades to its icon
    /// under column pressure with the others — a tagged query carries one more
    /// control than an untagged one, and the narrow column is exactly where
    /// that has to cost a word rather than the pane's layout width.
    @ViewBuilder
    private func answerAsRulingButton(useIcons: Bool) -> some View {
        if QueryRuling.offersARuling(annotation) {
            secondary("Answer as ruling\u{2026}", symbol: "building.columns",
                      useIcons: useIcons,
                      help: "Answer as ruling\u{2026} — a dated ruling in the edition brief, and your reply here",
                      action: onAnswerAsRuling)
        }
    }

    /// Stet — offered wherever Archive is, and the margin card mirrors it
    /// (`ReviewCardActions`). The symbol is the proofreader's own mark: dots
    /// under the words that stand.
    @ViewBuilder
    private func stetButton(useIcons: Bool) -> some View {
        secondary(
            "Stet", symbol: "textformat.abc.dottedunderline", useIcons: useIcons,
            help: "Read, considered — and the words stand. Resolves the note without applying or refusing anything.",
            action: onStet)
    }

    @ViewBuilder
    private func secondary(
        _ title: String, symbol: String, useIcons: Bool,
        help: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if useIcons {
                Image(systemName: symbol)
            } else {
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .help(help ?? title)
    }

    /// What the writer plans to DO about this note — the queue's sort key, not a
    /// resolution. The mark it already holds is checked AND disabled: re-applying
    /// it appends an op whose ⌘Z undoes nothing the writer can see, so the
    /// affordance refuses rather than the verb.
    @ViewBuilder
    private var triageMenu: some View {
        Menu {
            ForEach(TriageMark.allCases, id: \.self) { mark in
                Button {
                    onTriage(mark)
                } label: {
                    if annotation.triage == mark {
                        Label(mark.queueLabel, systemImage: "checkmark")
                    } else {
                        Text(mark.queueLabel)
                    }
                }
                .disabled(annotation.triage == mark)
            }
            if annotation.triage != nil {
                Divider()
                Button("Clear") { onTriage(nil) }
            }
        } label: {
            if let mark = annotation.triage {
                Label(mark.queueLabel, systemImage: mark.symbolName)
            } else {
                Image(systemName: "flag")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(annotation.triage.map { "Triaged \($0.queueLabel) — change or clear it" }
              ?? "Mark what you plan to do about this note")
    }

    /// Edit (pencil) + Delete (trash) for the reviewer's own annotation only.
    @ViewBuilder
    private var ownAffordances: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil")
        }
        .buttonStyle(.bordered)
        .help("Edit your annotation")
        Button(action: onWithdraw) {
            Image(systemName: "trash")
        }
        .buttonStyle(.bordered)
        .help("Delete your annotation")
    }

    private var kindColor: Color {
        switch annotation.kind {
        case .comment: return .blue
        case .suggestedChange: return .orange
        case .query: return .purple
        case .craftNote: return .yellow
        }
    }
    private var relativeTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(
            for: annotation.createdAt, relativeTo: Date())
    }
}

@MainActor
private struct RejectReasoningSheet: View {
    let annotation: Annotation
    let onReject: (String) -> Void
    let onCancel: () -> Void
    @State private var reason: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why are you rejecting this?")
                .font(.headline)
            Text("Your reasoning is saved with the annotation so Claude can see it in future sessions.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $reason)
                .frame(minHeight: 80)
                .border(Color.gray.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Reject") {
                    onReject(reason.trimmingCharacters(
                        in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 380)
    }
}

/// Inline editor for the reviewer's own annotation (author self-service).
/// Pre-fills the body; for a suggested change, also exposes the replacement
/// text. On commit delivers (newBody, newSuggested?) where newSuggested is nil
/// for non-suggestion kinds. Mirrors the look of the reject/reply sheets.
@MainActor
private struct EditAnnotationSheet: View {
    let annotation: Annotation
    /// (newBody, newSuggestedText?) — newSuggestedText is nil unless this is a
    /// suggested change.
    let onCommit: (String, String?) -> Void
    let onCancel: () -> Void
    @State private var noteBody: String
    @State private var suggested: String

    init(
        annotation: Annotation,
        onCommit: @escaping (String, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.annotation = annotation
        self.onCommit = onCommit
        self.onCancel = onCancel
        _noteBody = State(initialValue: AnnotationRow.displayText(annotation.body))
        _suggested = State(initialValue:
            annotation.suggestedText.map(AnnotationRow.displayText) ?? "")
    }

    private var isSuggestion: Bool { annotation.kind == .suggestedChange }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit your \(annotation.kind.displayName.lowercased())")
                .font(.headline)
            Text("Only you can edit or delete your own annotations.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Note")
                .font(.caption.smallCaps()).foregroundStyle(.secondary)
            TextEditor(text: $noteBody)
                .frame(minHeight: 70)
                .border(Color.gray.opacity(0.3))
            if isSuggestion {
                Text("Replacement text")
                    .font(.caption.smallCaps()).foregroundStyle(.secondary)
                TextEditor(text: $suggested)
                    .frame(minHeight: 50)
                    .border(Color.gray.opacity(0.3))
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onCommit(
                        noteBody.trimmingCharacters(in: .whitespacesAndNewlines),
                        isSuggestion ? suggested : nil)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 380)
    }
}

@MainActor
private struct QueryReplySheet: View {
    let annotation: Annotation
    let onReply: (String) -> Void
    let onCancel: () -> Void
    @State private var reply: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reply")
                .font(.headline)
            Text(annotation.body)
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $reply)
                .frame(minHeight: 80)
                .border(Color.gray.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Reply") {
                    onReply(reply.trimmingCharacters(
                        in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 380)
    }
}
