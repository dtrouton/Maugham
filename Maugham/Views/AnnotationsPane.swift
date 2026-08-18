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
    /// Record which pass a piece is being reviewed through — `(docId, passId)`.
    /// The write itself is `ProjectWindow.recordActivePass`, the ONE writer of
    /// `UIState.activePassMemory`; this pane only ever asks for it. Defaulted
    /// to a no-op so a host with no window behind it still compiles.
    var onSetActivePass: (String, String) -> Void = { _, _ in }
    @Environment(UserPreferences.self) private var userPreferences
    /// The window's undo manager — passed into every accept so the Document
    /// registers its undo action against the manager ⌘Z reaches (and clears
    /// the stale native typing-undo stack; the ⌘Z EXC_BAD_ACCESS class).
    @Environment(\.undoManager) private var undoManager

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
    // Reading pass states is all this pane ever does with them. Writing one is
    // a closed census of three files (`PersonaPaneRegistryTests.
    // passStateWritingFiles`) and the queue is deliberately not among them:
    // it advises about passes, it never rules on them.

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
            ReviewRoundCockpit(
                passes: reviewPasses,
                activePassId: pass?.id,
                round: cockpitRound(diagnostics, docId: document.docId, passId: pass?.id),
                phase: ReviewRoundCockpit.phase(
                    runState: orchestrator.runState, docId: document.docId),
                reportLine: cockpitReportLine(diagnostics, docId: document.docId),
                onRun: { freshEyes in
                    orchestrator.runRequested(
                        docId: document.docId, freshEyes: freshEyes)
                },
                onSetActivePass: { passId in
                    onSetActivePass(document.docId, passId)
                })
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

    /// The lane's newest round number. `latestRound` consults the standing run
    /// before the ring — the ONE spelling of "which round is this lane on",
    /// shared with the round mint, so the strip and the run cannot disagree.
    private func cockpitRound(
        _ diagnostics: DiagnosticsStore, docId: String, passId: String?
    ) -> Int? {
        _ = diagnostics.version
        return diagnostics.latestRound(forPass: passId, docId: docId)
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
    @ViewBuilder
    private var passOrderNudge: some View {
        if !scope.isProject,
           let earlier = PassOrderAdvice.advice(
                forPiece: document?.docId, memory: activePassMemory,
                passes: reviewPasses, passStates: piecePassStates) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").font(.caption2)
                Text(PassOrderAdvice.caption(for: earlier))
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
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
                ContentUnavailableView(
                    "No annotations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(ReviewRoundCockpit.emptyQueueTeaching(
                        editorName: cockpitActivePass?.effectiveEditorName)))
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

    private func reject(_ document: Document, _ ann: Annotation, reason: String) {
        Task {
            try? await document.rejectAnnotation(
                id: ann.id, userResponse: reason, undoManager: undoManager)
            noteChanged()
        }
    }

    /// Stet — the proofreader's own gesture, and now the only one that wears the
    /// proofreader's mark. The op is recorded immediately (never blocked); the
    /// flag holds the row on-screen ~2.5s so the STET badge and the reinstated
    /// text read clearly before the row resolves out of the open list.
    private func stet(_ document: Document, _ ann: Annotation) {
        stetFlourishIds.insert(ann.id)
        Task {
            try? await document.stetAnnotation(id: ann.id, undoManager: undoManager)
            noteChanged()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            stetFlourishIds.remove(ann.id)
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
        if let pid = ann.paragraphId {
            MaughamEvent.post(
                .maughamNavigateToParagraph, to: .keyWindow,
                payload: ["paragraph_id": pid])
        }
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
            stetButton(useIcons: useIcons)
            secondary("Archive", symbol: "archivebox", useIcons: useIcons, action: onArchive)
        case .craftNote:
            Button("Accept", action: onAccept).buttonStyle(.borderedProminent)
            secondary("Reject\u{2026}", symbol: "xmark", useIcons: useIcons, action: onReject)
            stetButton(useIcons: useIcons)
            secondary("Archive", symbol: "archivebox", useIcons: useIcons, action: onArchive)
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
