import SwiftUI
import AppKit
import MaughamCore

/// **What a key or another surface asks To resolve to do** — applied once,
/// then cleared. `.filter` selects a source's chip (inert when the chip is
/// absent); `.focus` scrolls to and opens a piece's or a figure's group.
enum ResolveRequest: Equatable {
    case filter(ResolveKeyFilter)
    case focus(groupOwnerId: String)
}

/// What one refresh does (`ResolvePane.refreshStep`).
enum ResolveRefreshStep: Equatable {
    /// The walks and the sidecar: `ResolveReader.read`, then the regroup.
    case read
    /// A new screenplay parse: the open piece's text and its live notes and
    /// to-dos, then the regroup.
    case reread
    /// An open piece's notes or to-dos moved (a keystroke on a to-do line, a
    /// burst flush, a minted note, a verb): its live notes and to-dos are
    /// spliced into what is held, then the regroup. No walk (review C1).
    case live
}

/// **What To resolve refreshes on**: the regroup key (the read key and the
/// script) plus the open in-scope pieces' `tasksVersion` and
/// `annotationsVersion` sums. Typing on a to-do line, a burst flush, a note
/// minted on an open piece and a verb on one move only these, which cost one
/// `Document.tasks` and one `Document.annotations` per open piece in scope and
/// never a project walk (review C1).
struct ResolveListKey: Equatable {
    let regroup: ResolveRegroupKey
    let openTodos: Int
    var openNotes: Int = 0
}

/// **A stetted note's flourish** — the old queue's 2.5 seconds. The verbs hold
/// the STET mark this long; the list holds the row through any read that
/// lands inside it, so the note does not vanish under its own mark.
enum ResolveStetHold {
    static let seconds: TimeInterval = 2.5
    static var nanoseconds: UInt64 { UInt64(seconds * 1_000_000_000) }

    static func holds(stettedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(stettedAt) < seconds
    }

    /// `fresh`, with every note `previous` held that was stetted inside the
    /// hold and that `fresh` no longer lists put back — **as it now is**:
    /// `live` (item id → the note in every status, from the walk) supplies
    /// the stetted note, never the stale open copy. A note `live` does not
    /// know is not put back. Returns the ids put back.
    static func keeping(_ fresh: ResolveSnapshot, previous: ResolveSnapshot,
                        stettedAt: [String: Date], now: Date,
                        live: [String: ProjectAnnotation])
        -> (snapshot: ResolveSnapshot, kept: Set<String>) {
        let freshIds = Set(fresh.items.map(\.id))
        var kept: Set<String> = []
        let back: [ResolveItem] = previous.items.compactMap { item in
            guard case .note(let note) = item, !freshIds.contains(item.id),
                  let at = stettedAt[note.annotation.id],
                  holds(stettedAt: at, now: now),
                  let now = live[item.id] else { return nil }
            kept.insert(note.annotation.id)
            return .note(now)
        }
        guard !back.isEmpty else { return (fresh, []) }
        return (ResolveSnapshot(items: back + fresh.items, sequences: fresh.sequences,
                                paragraphText: fresh.paragraphText,
                                unreadableDocIds: fresh.unreadableDocIds), kept)
    }

    /// **What a row wearing the flourish offers**: Reopen alone, once the
    /// note is stetted (the old queue's live stetted row); nothing while its
    /// status is still open (the frame between the press and the read) — so a
    /// second Stet, an Accept or an Archive over a stetted note is never
    /// reachable during the hold.
    static func heldVerbs(_ decided: AnnotationRowVerbs, status: AnnotationStatus) -> AnnotationRowVerbs {
        AnnotationRowVerbs(
            acceptOrReject: false,
            dispose: decided.dispose && status != .open,
            answerAsRuling: false, makeChoice: false, keepAsLesson: false, ownNote: false)
    }
}

/// What applying a request leaves (`ResolvePane.apply`).
struct ResolveRequestOutcome: Equatable {
    let selection: Set<ResolveSource>
    let choices: [ResolveGroup.Key: Bool]
    let scrollTo: ResolveGroup.Key?
}

/// **To resolve** — the right column's one list of what has been raised about
/// the faces' subject: notes, a check's strains, to-dos (shell plan 2).
///
/// The head (`ResolveHeadView`), the filter bar, then one `ScrollView` of a
/// `LazyVStack` — never a `List` (tripwire 9). Groups are sections; a closed
/// group is its title and its count. **Read anywhere, act only on the open
/// piece** (`ResolveVerbGate`): a row on another piece reads, offers only what
/// needs no `Document`, and its click opens the piece on its paragraph.
///
/// **Reading.** `.task(id: ResolveRegroupKey)` builds everything once per key
/// change — the read (`ResolveReader.read`), the groups, the chips, density —
/// into state; no row and no caret move reads a store. A script-only change
/// re-reads the open piece's text and regroups without the walks.
///
/// **The caret.** Only on the open piece at a `.piece` scope, a small child
/// view reads `Document.cursorLocation` (so a caret move re-renders it, not
/// the list) and runs the caret function over groups already built; the list
/// scrolls only when the caret's group changes. `EditorHost` gains nothing.
///
/// The sheets and alerts the note verbs raise are owned here
/// (`ResolveDialogs`), as are the finding answers, New To-do's sheet and the
/// bulk selection.
@MainActor
struct ResolvePane: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let subject: WindowSubject
    /// The window's parsed screenplay (`lastParsedScript`).
    let script: FountainScript?
    let diagnostics: DiagnosticsStore?
    let orchestrator: CompilerOrchestrator?
    let world: DeclaredWorldStore?
    let compilerModel: CompilerModelChoice
    let onCompilerModelChange: (CompilerModelChoice) -> Void
    /// `(piece, passId, state)` — `RightColumn`'s `ProjectStore.setPassState`.
    let onSetPassState: (String, String, PassState?) -> Void
    /// `(piece, passId)` — `ProjectWindow.recordActivePass`.
    let onSetActivePass: (String, String) -> Void
    @Binding var request: ResolveRequest?
    /// The check header's "Define a first reader…" (the window's sheet).
    var onOpenProjectSettings: () -> Void = {}
    /// A figure note's click travels to its figure (the window's subject).
    var onTravel: (BinderSubject) -> Void = { _ in }
    var drawsFigure: (String) -> Bool = { _ in false }
    var revealFigure: (String) -> Void = { _ in }
    var revealFigureCell: (_ figureId: String, _ cell: CellKey, _ pending: Bool) -> Bool = { _, _, _ in false }
    var onChoiceOfferChanged: (ChoiceOffer?) -> Void = { _ in }

    @Environment(UserPreferences.self) private var userPreferences
    @Environment(\.undoManager) private var undoManager

    // MARK: The read, and what it builds (once per key)

    @State private var held: ResolveSnapshot = .empty
    @State private var lastKey: ResolveListKey?
    /// The project walks this list last asked for (review C1).
    @State private var walks = ResolveWalkHold()
    /// When each stetted note took its mark, and which held rows are there
    /// only for their flourish.
    @State private var stettedAt: [String: Date] = [:]
    @State private var keptStetted: Set<String> = []
    @State private var groups: [ResolveGroup] = []
    @State private var sceneIndex: [String: Int]?
    @State private var chips: [ResolveSource] = []
    @State private var dense = false
    @State private var incomplete: String?
    @State private var figureCells: [String: SuggestionDisplay.FigureCells] = [:]
    @State private var figureNames: [String: String] = [:]
    @State private var ledgerText: String?
    /// The groups the selection leaves, and their items in order.
    @State private var shown: [ResolveGroup] = []
    @State private var visible: [ResolveItem] = []
    /// Bumped by a `.maughamAnnotationsChanged` about a document no window
    /// holds open, and by a figure note's verb (the walk's cache is not
    /// observable). Never by the open piece's own notes (review C1).
    @State private var annotationsToken = 0

    // MARK: The writer's

    @State private var selection: Set<ResolveSource> = []
    @State private var choices: [ResolveGroup.Key: Bool] = [:]
    @State private var caretGroup: ResolveGroup.Key?
    @State private var pendingRequest: ResolveRequest?
    @State private var scrollRequest: ResolveGroup.Key?
    @State private var settledExpanded = false
    @State private var bookSettledExpanded = false

    // MARK: A finding's answer

    @State private var answering: Set<String> = []
    @State private var answerFailures: [String: String] = [:]

    // MARK: New To-do

    @State private var showCreateSheet = false
    @State private var newTaskBody = ""
    @State private var newTaskScope: ResolveTaskScope = .document

    // MARK: The note verbs' sheets and alerts (moved from the Annotations pane)

    @State private var rejectSheet: ResolveNoteTarget?
    @State private var querySheet: ResolveNoteTarget?
    @State private var figureRejectSheet: ResolveFigureNoteTarget?
    @State private var figureReplySheet: ResolveFigureNoteTarget?
    @State private var rulingSheet: ResolveNoteTarget?
    @State private var rulingNotice: String?
    @State private var ledgerNotice: String?
    @State private var choiceOffer: ChoiceOffer?
    @State private var keepLessonSheet: ResolveLessonTarget?
    @State private var staleConfirm: ResolveNoteTarget?
    @State private var anchorLostNotice: ResolveNoteTarget?
    @State private var revertConfirm: ResolveNoteTarget?
    @State private var editSheet: ResolveNoteTarget?
    @State private var withdrawConfirm: ResolveNoteTarget?
    @State private var stetFlourishIds: Set<String> = []
    @State private var selectionModeOn = false
    /// The triage choice (Task 7b): remembered for the life of the view, not
    /// stored; whether the control is offered, recomputed once per refilter.
    @State private var triageChoice: ResolveTriageChoice = .all
    @State private var triageOffered = false
    @State private var selectedIds: Set<String> = []
    @State private var bulkNotice: String?
    @State private var bulkInFlight = false
    @State private var letterLedgerRevision = 0
    @State private var window: NSWindow?

    // MARK: - Derived per render (no walk)

    private var scope: ResolveScope {
        ResolveScope.of(subject.faces, structure: store.manifest.structure,
                        projectType: store.manifest.type)
    }

    private var openDocId: String? { subject.open.itemID }

    private var localName: String { userPreferences.collaboratorDisplayName }

    private var passes: [ReviewPass] { store.manifest.effectiveReviewPasses }

    /// The faces' piece, at a `.piece` scope.
    private var pieceDocId: String? {
        if case .piece(let docId, _) = scope { return docId }
        return nil
    }

    private func mayAct(on docId: String) -> Bool {
        ResolveVerbGate.mayAct(onDocId: docId, openDocId: openDocId,
                               isRegistered: { documentStore.document(forDocId: $0) != nil })
    }

    /// May this window act on the faces' piece?
    private var mayActOnFaces: Bool { pieceDocId.map(mayAct(on:)) ?? false }

    private var listKey: ResolveListKey {
        Self.listKey(scope: scope, annotationsToken: annotationsToken, store: store,
                     documentStore: documentStore, diagnostics: diagnostics, localName: localName,
                     script: Self.script(for: scope, structure: store.manifest.structure,
                                         openDocId: openDocId, script: script))
    }

    private var shownSelection: Set<ResolveSource> {
        ResolveFilter.normalized(selection, chips: chips, dense: dense)
    }

    private var hasList: Bool {
        switch scope {
        case .piece, .pieces, .figure: return true
        case .elsewhere, .outside: return false
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ResolveHeadView(
                scope: scope, snapshot: held, openDocId: openDocId,
                store: store, documentStore: documentStore,
                orchestrator: orchestrator, diagnostics: diagnostics, world: world,
                reader: store.manifest.authorReader(
                    choice: documentStore.uiState.authorReaderChoice,
                    statementText: { _ in nil }),
                compilerModel: compilerModel,
                onCompilerModelChange: onCompilerModelChange,
                onChooseReader: { documentStore.setAuthorReaderChoice($0) },
                onOpenProjectSettings: onOpenProjectSettings,
                onSetActivePass: onSetActivePass,
                onSetPassState: onSetPassState)
            if hasList {
                filterBar
                Divider()
                list
            } else {
                ContentUnavailableView {
                    Label("To resolve", systemImage: "checklist")
                } description: {
                    Text((Self.emptyState(scope: scope, hasItems: false, hasVisible: false,
                                          offersColdStart: false)
                          ?? .outside).sentence)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: listKey) { refresh(listKey) }
        // The sidecar for the scope's pieces — never from `body`; its
        // `version` moves the read key.
        .task(id: scope) {
            if let diagnostics { ResolveReader.loadFindings(scope: scope, diagnostics: diagnostics) }
        }
        .onChange(of: scope) { _, _ in
            selection = []
            choices = [:]
            caretGroup = nil
            selectionModeOn = false
            selectedIds = []
            settledExpanded = false
            bookSettledExpanded = false
            markChecksRead()
        }
        .onChange(of: request, initial: true) { _, new in take(new) }
        .onChange(of: triageChoice) { _, new in
            dense = ResolveTriage.isDense(held.items, choice: new)
            refilter()
        }
        .onChange(of: selection) { _, _ in
            refilter()
            markChecksRead()
        }
        .onChange(of: stetFlourishIds) { old, new in stetMarksChanged(from: old, to: new) }
        .onChange(of: letterLedgerRevision) { _, _ in
            ledgerText = LessonLedgerVerbs.ledgerText(store: store)
        }
        .onChange(of: mayActOnFaces) { _, may in if !may { caretGroup = nil } }
        .onAppear { markChecksRead() }
        // Notes landing while the checks' items are on screen were never
        // unread: the dot is for a run that finished somewhere the writer
        // wasn't looking (the Diagnostics pane's rule, kept). `markRead` does
        // not bump `version`, so this cannot re-enter itself.
        .onChange(of: diagnostics?.version) { _, _ in markChecksRead() }
        .modifier(ResolveDialogs(
            store: store, verbs: noteVerbs,
            rejectSheet: $rejectSheet, querySheet: $querySheet,
            rulingSheet: $rulingSheet, rulingNotice: $rulingNotice,
            choiceOffer: $choiceOffer, ledgerNotice: $ledgerNotice,
            keepLessonSheet: $keepLessonSheet, staleConfirm: $staleConfirm,
            anchorLostNotice: $anchorLostNotice, revertConfirm: $revertConfirm,
            bulkNotice: $bulkNotice, editSheet: $editSheet,
            withdrawConfirm: $withdrawConfirm,
            figureRejectSheet: $figureRejectSheet, figureReplySheet: $figureReplySheet))
        .sheet(isPresented: $showCreateSheet) {
            let creation = creationVerbs.creation
            NewTaskSheet(
                taskBody: $newTaskBody, scope: $newTaskScope,
                canPickDocumentScope: creation.document,
                canPickProjectScope: creation.project,
                onCommit: commitNewTask,
                onCancel: {
                    showCreateSheet = false
                    newTaskBody = ""
                })
        }
        .background(WindowAccessor(window: $window))
        // A note changed where no window holds the document — a closed
        // piece's file, a figure's stream, a peer's sync. An open piece's own
        // event is its live splice's, never a walk (review C1).
        .onProjectEvent(.maughamAnnotationsChanged, url: store.url, window: window) { note in
            if Self.annotationsEventMovesTheWalk(
                docId: note.userInfo?[MaughamEvent.annotationDocIdKey] as? String,
                documentStore: documentStore) {
                annotationsToken &+= 1
            }
        }
        .doesNotRaiseTheWindowFloor()
    }

    // MARK: - The filter bar

    private var filterBar: some View {
        ResolveFilterBar(
            chips: chips, selection: shownSelection, passes: passes,
            showsSelectionMode: showsSelectionMode,
            selectionModeOn: selectionModeOn,
            showsNewTodo: creationVerbs.creation.offersAny,
            checksUnread: checksUnread,
            triage: triageOffered ? triageChoice : nil,
            onTriage: { triageChoice = $0 },
            onToggle: { selection = ResolveFilter.toggled(shownSelection, $0, dense: dense) },
            onToggleSelectionMode: {
                selectionModeOn.toggle()
                if !selectionModeOn { selectedIds.removeAll() }
            },
            onNewTodo: presentCreateSheet)
    }

    /// Selection mode's door: a `.piece` scope on the open piece with notes,
    /// where its posture leaves a bulk verb to press.
    private var showsSelectionMode: Bool {
        guard mayActOnFaces, let docId = pieceDocId, !bulkRows.isEmpty else { return false }
        return ResolveNoteVerbs.bulkOffersAVerb(posture: documentStore.posture(forDocId: docId))
    }

    // MARK: - The list

    private var list: some View {
        let acting = openDocId.flatMap {
            AnnotationRowHost.actingDocument(docId: $0, openDocId: openDocId,
                                             documentStore: documentStore)
        }
        let wiring = rowWiring
        let open = ResolveFilter.expanded(shown, cursor: caretGroup, dense: dense, choices: choices)
        let reorders = reordersHere
        let piece = pieceDocId
        let empty = Self.emptyState(scope: scope, hasItems: !held.items.isEmpty,
                                    hasVisible: !shown.isEmpty,
                                    offersColdStart: offersColdStart)
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let incomplete {
                            Text(incomplete)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        emptyLine(empty)
                        ForEach(shown) { group in
                            groupHeader(group, isOpen: open.contains(group.key))
                                .id(group.key)
                            if open.contains(group.key) {
                                ForEach(group.items) { item in
                                    row(item, acting: acting, piece: piece, wiring: wiring, reorders: reorders)
                                    Divider()
                                }
                            }
                        }
                        if ResolveSettled.offered(scope: scope, mayAct: mayActOnFaces),
                           let acting, acting.docId == pieceDocId {
                            ResolveSettledSection(
                                document: acting,
                                posture: documentStore.posture(forDocId: acting.docId),
                                ledgerText: ledgerText, wiring: wiring,
                                noteVerbs: noteVerbs, taskVerbs: rowTaskVerbs,
                                onJumpToTask: { go(.todo($0)) },
                                isExpanded: $settledExpanded)
                        }
                        if ResolveSettled.offersBook(scope: scope) {
                            ResolveBookSettledSection(
                                store: store,
                                posture: documentStore.posture(forDocId: ProjectStore.projectTasksDocId),
                                taskVerbs: rowTaskVerbs,
                                isExpanded: $bookSettledExpanded)
                        }
                    }
                }
                .onChange(of: caretGroup) { old, new in
                    guard let target = Self.scrollTarget(from: old, to: new) else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                }
                .onChange(of: scrollRequest) { _, key in
                    guard let key else { return }
                    withAnimation { proxy.scrollTo(key, anchor: .top) }
                    scrollRequest = nil
                }
            }
            .background {
                if mayActOnFaces, let acting, acting.docId == pieceDocId {
                    ResolveCaretReader(document: acting, scope: scope, sceneIndex: sceneIndex,
                                       groups: shown, caretGroup: $caretGroup)
                }
            }
            if selectionModeOn, mayActOnFaces, let acting, acting.docId == pieceDocId,
               !bulkRows.isEmpty,
               ResolveNoteVerbs.bulkOffersAVerb(posture: documentStore.posture(forDocId: acting.docId)) {
                Divider()
                AnnotationsBulkBar(
                    document: acting, rows: bulkRows,
                    selection: effectiveSelection(in: bulkRows),
                    targets: bulkTargets(in: bulkRows),
                    documentStore: documentStore, bulkInFlight: bulkInFlight,
                    selectedIds: $selectedIds, verbs: noteVerbs)
            }
        }
    }

    /// Nothing to resolve: a quiet line, not furniture; a never-checked piece
    /// the cold-start offer.
    @ViewBuilder
    private func emptyLine(_ empty: EmptyState?) -> some View {
        switch empty {
        case .coldStart?:
            if let pieceDocId, let diagnostics, let orchestrator {
                DiagnosticsColdStartOffer(
                    docId: pieceDocId, diagnostics: diagnostics,
                    otherLoopLine: CheckNarrative.otherLoopLine(
                        runState: orchestrator.runState, docId: pieceDocId,
                        titleOf: { RoundNarrative.pieceTitle(of: $0, in: store.manifest.structure) }))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        case .nothing?, .filteredOut?:
            Text((empty ?? .nothing).sentence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
        case .outside?, .elsewhere?, nil:
            EmptyView()
        }
    }

    // MARK: - A group

    private func groupHeader(_ group: ResolveGroup, isOpen: Bool) -> some View {
        let atCaret = group.key == caretGroup
        return Button {
            choices[group.key] = !isOpen
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(atCaret ? Color.primary : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text("\(group.items.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                if atCaret {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title), \(group.items.count)")
        .accessibilityAddTraits(atCaret ? .isSelected : [])
    }

    // MARK: - A row

    @ViewBuilder
    private func row(_ item: ResolveItem, acting: Document?, piece: String?,
                     wiring: AnnotationRowWiring, reorders: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let caption = Self.caption(for: item, localName: localName) {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 6)
            }
            switch item {
            case .note(let note):
                AnnotationRowHost(
                    annotation: note.annotation, docId: note.docId,
                    document: note.docId == acting?.docId ? acting : nil,
                    livePids: [], ledgerText: ledgerText,
                    isSelectable: selectionModeOn && note.docId == piece,
                    isSelected: selectedIds.contains(note.annotation.id),
                    figureTitle: figureNames[note.docId],
                    figureCells: figureCells[note.annotation.id],
                    wiring: wiring)
                notThisLine(item, note: note, acting: acting)
            case .finding(let docId, let finding):
                findingRow(item, docId: docId, finding: finding, acting: acting)
            case .todo(let task):
                todoRow(task, acting: acting, reorders: reorders)
            }
        }
    }

    /// The check's note's one-gesture decline (`offersNotThis`), and what a
    /// refused one said.
    @ViewBuilder
    private func notThisLine(_ item: ResolveItem, note: ProjectAnnotation,
                             acting: Document?) -> some View {
        if Self.offersNotThis(item, localName: localName, mayAct: acting?.docId == note.docId,
                              posture: documentStore.posture(forDocId: note.docId)),
           let acting {
            HStack(spacing: 6) {
                Button(Self.notThisTitle) {
                    let id = note.annotation.id
                    answerFailures[id] = nil
                    let undoManager = undoManager
                    Task {
                        if let failure = await CheckNarrative.notThis(
                            annotationId: id, in: acting, undoManager: undoManager) {
                            answerFailures[id] = failure
                        }
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Let it go. Nothing to explain \u{2014} the written decline belongs to a review pass.")
                if let failure = answerFailures[note.annotation.id] {
                    Text(failure).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
    }

    static let notThisTitle = "Not this"

    private func findingRow(_ item: ResolveItem, docId: String, finding: Diagnostic,
                            acting: Document?) -> some View {
        let offers = Self.findingOffers(
            item, mayAct: acting?.docId == docId,
            posture: documentStore.posture(forDocId: docId),
            statementDoor: { [statements = store.manifest.statements] kind, scope in
                documentStore.posture(ofStatement: kind, scope: scope, statements: statements)
            },
            durable: durable(docId))
        return DiagnosticRow(
            diagnostic: finding,
            canAnswer: offers.answer,
            canPromote: offers.promote,
            isSubmitting: answering.contains(finding.id),
            answerFailure: answerFailures[finding.id],
            // A finding's chips name their own paragraphs: go to the one
            // pressed, on the finding's piece.
            onJump: { ResolveNavigation.go(toDocId: docId, paragraphId: $0) },
            onPromote: { promote(finding, docId: docId) },
            onAnswer: { answer($0, to: finding, docId: docId) })
    }

    @ViewBuilder
    private func todoRow(_ task: WriterTask, acting: Document?, reorders: Bool) -> some View {
        let offered = rowTaskVerbs.offered(task)
        let base = TaskRow(
            task: task, verbs: offered,
            onToggle: { rowTaskVerbs.toggle(task) },
            onJump: { go(.todo(task)) },
            onArchive: { rowTaskVerbs.archive(task) },
            onDelete: { rowTaskVerbs.delete(task) })
            .padding(.leading, task.parentTaskId == nil ? 12 : 30)
            .padding(.trailing, 12).padding(.vertical, 4)
        if reorders && offered.move {
            base
                .draggable(task.id) {
                    Text(task.body)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
                .dropDestination(for: String.self) { ids, location in
                    drop(ids.first, onto: task, at: location)
                }
        } else {
            base
        }
    }

    // MARK: - Reordering to-dos (re-gated at the drop)

    private var reordersHere: Bool {
        guard let first = visible.first else { return false }
        return Self.reordersTodos(visible: visible, selection: shownSelection,
                                  mayAct: mayAct(on: first.docId))
    }

    private func drop(_ draggedId: String?, onto target: WriterTask, at location: CGPoint) -> Bool {
        let todos = visible.compactMap { item -> WriterTask? in
            if case .todo(let task) = item { return task } else { return nil }
        }
        guard let draggedId, reordersHere,
              rowTaskVerbs.offered(target).move,
              let dragged = todos.first(where: { $0.id == draggedId }),
              rowTaskVerbs.offered(dragged).move,
              ResolveTaskVerbs.acceptsDrop(of: dragged, onto: target),
              let doc = documentStore.document(forDocId: ResolveTaskVerbs.docId(of: dragged)),
              mayAct(on: doc.docId)
        else { return false }
        // the Tasks pane's reading of a drop: the row's top or bottom half.
        let rowHeight: CGFloat = 28
        let yFraction = Double(min(max(location.y, 0), rowHeight) / rowHeight)
        let intent = TaskDropIntent.classify(
            position: TaskDropIntent.position(yFraction: yFraction),
            targetId: target.id, targetParentTaskId: target.parentTaskId)
        rowTaskVerbs.apply(intent: intent, dragged: dragged, in: doc, allTasks: todos)
        return true
    }

    // MARK: - Refresh

    private func refresh(_ key: ResolveListKey) {
        let readScope = key.regroup.read.scope
        let step = Self.refreshStep(key, last: lastKey)
        var walks = walks
        let fresh = Self.refreshed(held, step: step, key: key.regroup.read, walks: &walks,
                                   store: store, documentStore: documentStore, diagnostics: diagnostics)
        self.walks = walks
        // A note just stetted stays for its flourish — on every step, since a
        // stet on the open piece arrives as its live splice. Looked up in the
        // held walk and the live pieces, never a fresh walk.
        var live: [String: ProjectAnnotation] = [:]
        if !stettedAt.isEmpty {
            let notes = Self.projectNotes(walks: walks, scope: readScope, documentStore: documentStore)
            for note in notes.annotations where stettedAt[note.annotation.id] != nil {
                live[ResolveItem.note(note).id] = note
            }
        }
        let hold = ResolveStetHold.keeping(fresh, previous: held, stettedAt: stettedAt,
                                           now: Date(), live: live)
        held = hold.snapshot
        keptStetted = hold.kept
        if step == .read {
            figureCells = walks.annotations?.figureCells ?? [:]
            ledgerText = LessonLedgerVerbs.ledgerText(store: store)
        }
        lastKey = key
        regroup(scope: readScope, script: key.regroup.script)
        applyPendingRequest()
    }

    /// The verbs put a note's id in `stetFlourishIds` when it is stetted and
    /// take it out when the flourish ends: record the start, and when it ends
    /// let a row held only for it go.
    private func stetMarksChanged(from old: Set<String>, to new: Set<String>) {
        let now = Date()
        for id in new.subtracting(old) { stettedAt[id] = now }
        let ended = old.subtracting(new)
        guard !ended.isEmpty else { return }
        for id in ended { stettedAt[id] = nil }
        let gone = keptStetted.intersection(ended)
        guard !gone.isEmpty else { return }
        keptStetted.subtract(gone)
        held = ResolveSnapshot(
            items: held.items.filter { item in
                if case .note(let note) = item { return !gone.contains(note.annotation.id) }
                return true
            },
            sequences: held.sequences, paragraphText: held.paragraphText,
            unreadableDocIds: held.unreadableDocIds)
        regroup(scope: scope, script: lastKey?.regroup.script)
    }

    private func regroup(scope: ResolveScope, script: FountainScript?) {
        let structure = store.manifest.structure
        var names: [String: String] = [:]
        for figure in store.manifest.figures ?? [] where names[figure.id] == nil {
            names[figure.id] = figure.name
        }
        var index: [String: Int]?
        var titles: [String] = []
        if case .piece(let docId, _) = scope, let script {
            let starts = ParagraphOffsets.starts(sequence: held.sequences[docId] ?? [],
                                                 paragraphs: held.paragraphText)
            let summaries = script.sceneSummaries()
            index = ParagraphOffsets.sceneIndex(
                starts: starts, sceneStarts: summaries.map(\.line.range.location))
            titles = summaries.map(\.line.content)
        }
        figureNames = names
        sceneIndex = index
        groups = ResolveGrouping.groups(held, scope: scope, structure: structure,
                                        sceneIndex: index, sceneTitles: titles,
                                        figureNames: names)
        chips = ResolveFilter.chips(held.items, passes: passes, localName: localName)
        dense = ResolveTriage.isDense(held.items, choice: triageChoice)
        incomplete = Self.incompleteLine(held, structure: structure, figureNames: names)
        refilter()
    }

    /// The selection over the built groups — once per selection change or
    /// rebuild, never per row.
    private func refilter() {
        // The triage control comes and goes with the marks (Task 7b): when the
        // last one is cleared the choice returns to All with it.
        triageOffered = ResolveTriage.offered(held.items)
        if !triageOffered, triageChoice != .all { triageChoice = .all }
        let items = ResolveFilter.visible(
            held.items, selection: shownSelection,
            triage: ResolveTriage.effective(triageChoice, offered: triageOffered),
            localName: localName)
        let ids = Set(items.map(\.id))
        shown = groups.compactMap { group in
            let kept = group.items.filter { ids.contains($0.id) }
            return kept.isEmpty ? nil : ResolveGroup(key: group.key, title: group.title, items: kept)
        }
        visible = shown.flatMap(\.items)
    }

    // MARK: - Requests

    private func take(_ new: ResolveRequest?) {
        guard let new else { return }
        request = nil
        pendingRequest = new
        applyPendingRequest()
    }

    /// A request waits for the read of the scope it arrived with.
    private func applyPendingRequest() {
        guard let pending = pendingRequest, lastKey?.regroup.read.scope == scope else { return }
        pendingRequest = nil
        let activePass = pieceDocId.flatMap {
            documentStore.uiState.activePassMemory.validatedActivePass(forPiece: $0, in: passes)
        }
        let outcome = Self.apply(pending, groups: groups, chips: chips, activePassId: activePass,
                                 dense: dense, selection: shownSelection, choices: choices)
        selection = outcome.selection
        choices = outcome.choices
        scrollRequest = outcome.scrollTo
        refilter()
    }

    /// Whether the faces' piece's last check left notes unread — the Checks
    /// chip's dot, which stands only while another filter hides them.
    private var checksUnread: Bool {
        guard let diagnostics, let docId = Self.unreadDocId(scope: scope) else { return false }
        _ = diagnostics.version
        return UnreadDot.shows(unreadChecks: diagnostics.unreadCount(docId: docId))
    }

    /// Showing the checks' items reads them (`clearsUnreadChecks`).
    private func markChecksRead() {
        guard let diagnostics, let docId = Self.unreadDocId(scope: scope),
              ResolveFilter.clearsUnreadChecks(selection: shownSelection) else { return }
        diagnostics.markRead(docId: docId, kind: .check)
    }

    // MARK: - Going to a place

    /// A row's click: its piece, on its paragraph (`ResolveNavigation`); a
    /// figure's note travels to the figure.
    private func go(_ item: ResolveItem) {
        if case .note(let note) = item, DocumentClass.isFigureDocId(note.docId) {
            figureClick(note)
            return
        }
        ResolveNavigation.go(item, firstParagraph: held.sequences[item.docId]?.first)
    }

    private func figureClick(_ note: ProjectAnnotation) {
        let click = FigureNoteClick.click(
            rowDocId: note.docId, activeDocId: openDocId, drawsFigure: drawsFigure)
        if let cell = FigureRowGate.cell(of: note.annotation) {
            let travels = if case .travel = click { true } else { false }
            if revealFigureCell(note.docId, cell, travels) { return }
        }
        if case .travel(let subject) = click {
            if case .figure(let id) = subject { revealFigure(id) }
            onTravel(subject)
        }
    }

    // MARK: - A finding's verbs

    private func durable(_ docId: String) -> Bool {
        guard let orchestrator, let diagnostics else { return true }
        return CheckNarrative.offersDurableActions(state: CheckNarrative.headerState(
            runState: orchestrator.runState, lastRun: diagnostics.lastCheck(docId: docId),
            noteCount: 0, docId: docId))
    }

    /// Promote to Task, on the open piece's live `Document` only.
    private func promote(_ finding: Diagnostic, docId: String) {
        guard let diagnostics, mayAct(on: docId),
              let document = documentStore.document(forDocId: docId) else { return }
        CheckNarrative.promote(finding, run: diagnostics.lastCheck(docId: docId), in: document,
                                diagnostics: diagnostics, undoManager: undoManager)
    }

    private func answer(_ text: String, to finding: Diagnostic, docId: String) {
        guard let diagnostics else { return }
        answerFailures[finding.id] = nil
        answering.insert(finding.id)
        Task {
            let failure = await CheckNarrative.commitAnswer(
                text, to: finding, docId: docId, store: store, world: world,
                diagnostics: diagnostics)
            answering.remove(finding.id)
            answerFailures[finding.id] = failure
        }
    }

    private var offersColdStart: Bool {
        guard mayActOnFaces, let pieceDocId, let diagnostics, let orchestrator else { return false }
        _ = diagnostics.version
        return CheckNarrative.showsColdStartOffer(
            state: CheckNarrative.headerState(
                runState: orchestrator.runState, lastRun: diagnostics.lastCheck(docId: pieceDocId),
                noteCount: 0, docId: pieceDocId),
            liveParagraphCount: held.sequences[pieceDocId]?.count ?? 0,
            hasRefused: diagnostics.hasRefusedColdStart(docId: pieceDocId))
    }

    // MARK: - To-do verbs

    /// The rows' verbs: only the piece open in the centre acts.
    private var rowTaskVerbs: ResolveTaskVerbs {
        ResolveTaskVerbs(store: store, documentStore: documentStore,
                         openDocId: openDocId, undoManager: undoManager)
    }

    /// New To-do's verbs: the faces' piece when it is the open one, else the
    /// Book's stream only — never a piece the list is not about.
    private var creationVerbs: ResolveTaskVerbs {
        ResolveTaskVerbs(store: store, documentStore: documentStore,
                         openDocId: mayActOnFaces ? pieceDocId : nil, undoManager: undoManager)
    }

    private func presentCreateSheet() {
        newTaskBody = ""
        newTaskScope = creationVerbs.creation.document ? .document : .project
        showCreateSheet = true
    }

    private func commitNewTask() {
        let trimmed = newTaskBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            creationVerbs.createTask(body: trimmed, in: newTaskScope)
        }
        showCreateSheet = false
        newTaskBody = ""
    }

    // MARK: - Notes: bulk, wiring, verbs

    /// The open piece's visible notes — what bulk acts over.
    private var bulkRows: [Annotation] {
        guard let pieceDocId else { return [] }
        return visible.compactMap { item -> Annotation? in
            if case .note(let note) = item, note.docId == pieceDocId { return note.annotation }
            return nil
        }
    }

    private func effectiveSelection(in rows: [Annotation]) -> Set<String> {
        guard !selectedIds.isEmpty else { return [] }
        return selectedIds.intersection(rows.map(\.id))
    }

    private func bulkTargets(in rows: [Annotation]) -> [Annotation] {
        let picked = effectiveSelection(in: rows)
        guard !picked.isEmpty else { return rows }
        return rows.filter { picked.contains($0.id) }
    }

    private var noteVerbs: ResolveNoteVerbs {
        ResolveNoteVerbs(
            store: store, documentStore: documentStore, world: world,
            userPreferences: userPreferences, undoManager: undoManager,
            onChoiceOfferChanged: onChoiceOfferChanged,
            // The held walk with the open pieces live: a press asks no walk.
            projectSnapshot: { [walks] in
                Self.projectNotes(walks: walks, scope: scope, documentStore: documentStore)
            },
            visibleAnnotations: { doc in doc.docId == pieceDocId ? bulkRows : [] },
            effectiveSelection: { effectiveSelection(in: $0) },
            staleConfirm: $staleConfirm, anchorLostNotice: $anchorLostNotice,
            revertConfirm: $revertConfirm, rulingNotice: $rulingNotice,
            ledgerNotice: $ledgerNotice, choiceOffer: $choiceOffer,
            stetFlourishIds: $stetFlourishIds, bulkInFlight: $bulkInFlight,
            selectedIds: $selectedIds, bulkNotice: $bulkNotice,
            letterLedgerRevision: $letterLedgerRevision,
            projectRefreshToken: $annotationsToken)
    }

    private var rowWiring: AnnotationRowWiring {
        let verbs = noteVerbs
        let flourishing = stetFlourishIds
        return AnnotationRowWiring(
            localName: localName,
            stetFlourishIds: stetFlourishIds,
            manifest: store.manifest,
            rowVerbs: { ann, docId, isOwn in
                let decided = rowVerbs(for: ann, docId: docId, isOwn: isOwn)
                // A row wearing the stet flourish offers Reopen alone.
                return flourishing.contains(ann.id)
                    ? ResolveStetHold.heldVerbs(decided, status: ann.status) : decided
            },
            onToggleSelection: { id in
                if selectedIds.remove(id) == nil { selectedIds.insert(id) }
            },
            onAccept: { verbs.accept($0, $1) },
            onReject: { rejectSheet = ResolveNoteTarget(document: $0, annotation: $1) },
            onStet: { verbs.stet($0, $1) },
            onTriage: { verbs.triage($0, $1, mark: $2) },
            onArchive: { verbs.archive($0, $1) },
            onReply: { querySheet = ResolveNoteTarget(document: $0, annotation: $1) },
            onAnswerAsRuling: { rulingSheet = ResolveNoteTarget(document: $0, annotation: $1) },
            onMakeChoice: { verbs.performChoice($0, $1) },
            onKeepAsLesson: { keepLessonSheet = ResolveLessonTarget(docId: $0, annotation: $1) },
            onEdit: { editSheet = ResolveNoteTarget(document: $0, annotation: $1) },
            onWithdraw: { withdrawConfirm = ResolveNoteTarget(document: $0, annotation: $1) },
            onRevert: { verbs.revert($0, $1) },
            onReopen: { verbs.reopen($0, id: $1.id) },
            onJump: { docId, ann in go(.note(ProjectAnnotation(docId: docId, annotation: ann))) },
            figure: FigureRowWiring(
                onAccept: { verbs.figureAccept($0, $1) },
                onReject: { figureRejectSheet = ResolveFigureNoteTarget(figureId: $0, annotation: $1) },
                onStet: { verbs.figureStet($0, $1) },
                onArchive: { verbs.figureArchive($0, $1) },
                onReply: { figureReplySheet = ResolveFigureNoteTarget(figureId: $0, annotation: $1) },
                onReopen: { verbs.figureReopen($0, $1) },
                reachable: { drawsFigure($0) }))
    }

    /// The posture of the ROW'S OWN document decides its verbs; the gate in
    /// `AnnotationRowHost` then hides every `Document` verb off the open piece.
    private func rowVerbs(for ann: Annotation, docId: String, isOwn: Bool) -> AnnotationRowVerbs {
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

    private func postureOfStatement(_ kind: Statement.Kind) -> Posture {
        documentStore.posture(forDocId: StatementEditorHost.postureDocId(
            kind: kind, scope: .project, statements: store.manifest.statements))
    }
}
