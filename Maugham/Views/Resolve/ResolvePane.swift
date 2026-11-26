import SwiftUI
import AppKit
import MaughamCore

/// **What a key or another surface asks To resolve to do** — applied once,
/// then cleared. `.filter` selects a source's chip (inert when the chip is
/// absent); `.focus` scrolls to and opens a piece's or a figure's group;
/// `.focusFinding` opens the group holding one finding and marks its row —
/// Brief's solid mark asks this (`ClauseMarks.jump`). `itemId` is the
/// finding's `ResolveItem.id`, nil when the strain had none; a finding the
/// list no longer holds (answered, replaced by a newer check, or dropped
/// when its anchor text changed) is settled: the Checks chip on that piece,
/// and one quiet line. `.showParagraph` is a margin mark's click (shell p5
/// Task 2): the paragraph's group becomes the list's caret group, as if the
/// caret were there, and the editor's caret does not move.
enum ResolveRequest: Equatable {
    case filter(ResolveKeyFilter)
    case focus(groupOwnerId: String)
    case focusFinding(docId: String, itemId: String?)
    /// `annotationId`: the note whose dot was clicked, when the mark is one
    /// note's (closing round B, M5) — the row the click shows and marks.
    case showParagraph(docId: String, paragraphId: String, annotationId: String? = nil)
    /// File ▸ Translate This Chapter into … / Translate Whole Book into …
    /// (shell p5 Task 7, row 7): the head's own Run, pressed for the menu —
    /// for exactly the target the item was titled for (fix round 1, C1).
    case translate(TranslateMenuOffer)
}

extension ResolvePane {
    /// **What a pending request becomes when the scope changes** (fix round
    /// 1, C1): File ▸ Translate…'s ask is its scope's and dies with it;
    /// every other request waits for the new read, as it always did. Pure.
    static func pendingSurvivingScopeChange(_ pending: ResolveRequest?) -> ResolveRequest? {
        if case .translate? = pending { return nil }
        return pending
    }
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

/// **What To resolve's list shows, and over what** (shell p5 Task 2, fix
/// round 1, M6): the window keeps a piece's own list's selection for the
/// margin's ticks, and nothing a Book's, a Part's or an edition's list chose.
struct ResolveShownSelection: Equatable {
    let scope: ResolveScope
    let selection: Set<ResolveSource>
}

/// What applying a request leaves (`ResolvePane.apply`).
struct ResolveRequestOutcome: Equatable {
    let selection: Set<ResolveSource>
    let choices: [ResolveGroup.Key: Bool]
    let scrollTo: ResolveGroup.Key?
    /// The row a `.focusFinding` marks.
    var marked: String? = nil
    /// A `.focusFinding` whose finding the list no longer holds (answered,
    /// or replaced by a newer check).
    var settled = false
    /// What a `.focusFinding` that found no row says, in one quiet line.
    var line: String? = nil
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
    let script: WindowScript?
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
    /// **The selection the list shows, published to the window with its
    /// scope** (shell p5 Task 2): its one writer, on every change. View ▸
    /// Margin's ticks follow a piece's own list's, and keep the last value
    /// while the column is hidden.
    let onSelectionShown: (ResolveShownSelection) -> Void
    /// **The window's tree** (shell p5 Task 3): its figure cards' changed
    /// sources are listed (`figureSourceChanges`, carried by the read key)
    /// and its figure verbs act on them (`FigureSectionVerbs.shared`). Nil
    /// where no tree stands behind the list: no figure's source is listed.
    /// No default, so a host that has one cannot drop it unseen.
    let figureTree: BinderTreeSectionsState?
    /// The check header's "Define a first reader…" (the window's sheet).
    var onOpenProjectSettings: () -> Void = {}
    /// A figure note's click travels to its figure (the window's subject).
    var onTravel: (BinderSubject) -> Void = { _ in }
    var drawsFigure: (String) -> Bool = { _ in false }
    var revealFigure: (String) -> Void = { _ in }
    /// The figure's grid in the centre (`ResolveFigureSourceVerbs.subjectShowingTheTable`).
    var showFigureInCentre: (String) -> Void = { _ in }
    var revealFigureCell: (_ figureId: String, _ cell: CellKey, _ pending: Bool) -> Bool = { _, _, _ in false }
    var onChoiceOfferChanged: (ChoiceOffer?) -> Void = { _ in }
    /// A filed line's link: the faces move to the Brief it names
    /// (`ProjectWindow.openBrief`). Nil draws the line as text.
    var onOpenBrief: ((BinderSubject) -> Void)? = nil
    /// **The presence read the window already holds**
    /// (`BinderTreeSectionsState.bookReading`): an edition's questions come
    /// from it, read off the main actor, so selecting an edition walks no
    /// annotation log on the main actor (shell p4 Task 6 fix round, review
    /// I4). Nil where no tree stands behind the list: the walk answers.
    var presenceReading: ResolvePresence.BookReading? = nil
    /// The window's publish centre (shell p4 Task 6): which edition is the
    /// Source, the last compile's problems, and the covers an edition's rows
    /// and head open (`show(round:)`, `show(proposal:)`, `show(problems:)`).
    /// Nil where no centre stands behind the list: an edition then lists its
    /// questions and changes, and its Shows do nothing.
    var publishCentre: PublishCentreModel? = nil
    /// **The language the faces are read in** (`ReadingLanguage.of`, shell
    /// p4 Task 9): a piece faced while it is read in a language lists that
    /// language's questions and changes (`ResolveScope.pieceInLanguage`).
    /// Nil reads the faces in the source.
    var readIn: String? = nil
    /// The window's editor control: the translated surface the editor shows
    /// (its badges — what the translation lacks, what is left over) and the
    /// caret's paragraph's spot-checks and cells, on a piece read in a
    /// language. Nil where no editor stands behind the list.
    var editorControl: EditorControl? = nil
    /// **The tree's marks** (`BinderTreeSectionsState.presence`): a piece read
    /// in a language whose list is empty says when its SOURCE has something
    /// open — the dot its row carries — so the two never disagree. Nil where
    /// no tree stands behind the list.
    var presenceMarks: ResolvePresence.Marks? = nil

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
    /// File ▸ Translate…'s ask, for the head's Run (row 7); spent by the head.
    @State private var translateAsk: TranslateMenuOffer?
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
    /// An edition's own read (rounds, proposals, problems), and the events
    /// and verbs heard that change it (shell p4 Task 6).
    @State private var editionRead = ResolveEditionItems.Read.empty
    /// The scope `editionRead` was read for — a list moving between an
    /// edition and one of its pieces in the same language never draws one's
    /// read under the other's head (shell p4 Task 9).
    @State private var editionReadScope: ResolveScope?
    @State private var editionHeard = 0
    /// Bumped by `.maughamTranslationDidUpdate`: a piece read in a language
    /// re-reads what its translation lacks and leaves over.
    @State private var translationHeard = 0

    // MARK: The writer's

    @State private var selection: Set<ResolveSource> = []
    @State private var choices: [ResolveGroup.Key: Bool] = [:]
    @State private var caretGroup: ResolveGroup.Key?
    /// A margin click's group, held as the caret group until the caret
    /// itself moves (shell p5 Task 2, fix round 1, I2).
    @State private var caretPin: ResolveCaretPin?
    @State private var pendingRequest: ResolveRequest?
    @State private var scrollRequest: ResolveGroup.Key?
    @State private var settledExpanded = false
    @State private var bookSettledExpanded = false
    /// The scope's settled figure notes, from the held walk (review I2).
    @State private var figureSettled: [ProjectAnnotation] = []
    @State private var figureSettledExpanded = false

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
    /// Where the last answer was filed — one quiet line under the head
    /// (shell plan 3 Task 6). Also what a mark's jump says when its finding
    /// is settled.
    @State private var filedNotice: FiledNotice.Filing?
    /// The filed line standing when the writer's current press in the list
    /// began (`.some(nil)`: none stood); nil between presses. Task 6a.
    @State private var filedLineAtPress: UUID??
    /// The row a strain mark's jump marked (`.focusFinding`).
    @State private var markedItemId: String?
    /// The figure whose Compare sheet is up, from a changed source's row.
    @State private var comparing: ResolveFigureCompare?

    // MARK: - Derived per render (no walk)

    private var scope: ResolveScope {
        ResolveScope.shown(faces: subject.faces, readIn: readIn, sourceLanguage: publishCentre?.sourceLanguage,
                           manifest: store.manifest)
    }

    /// What an edition's own read — or a piece read in a language's — is
    /// keyed on; nil at every source scope. A piece's has no problems and no
    /// imprint: those are the book's.
    private var editionKey: ResolveEditionKey? {
        guard let language = scope.translationLanguage else { return nil }
        let isEdition = scope.editionLanguage != nil
        return ResolveEditionKey(
            scope: scope,
            roundsModified: ResolveEditionKey.modified(
                TranslationRoundStore.fileURL(language: language, in: store.url)),
            heard: editionHeard,
            problems: isEdition
                ? publishCentre.map { ResolveEditionItems.stoppingProblems($0.compileRunner.state) } ?? []
                : [],
            imprint: isEdition ? documentStore.uiState.publishImprint : nil)
    }

    /// Whether `editionRead` is this scope's.
    private var editionReadIsCurrent: Bool { editionReadScope == scope }

    /// The edition kinds, from this scope's own read — never another
    /// edition's, nor an edition's under one of its pieces. A piece read in
    /// a language lists only its own: no design proposal, no problem.
    private var editionItems: [ResolveItem] {
        guard editionReadIsCurrent else { return [] }
        switch scope {
        case .edition(let language, let isSource, let docIds):
            return ResolveEditionItems.items(language: language, isSource: isSource, docIds: docIds,
                                             read: editionRead)
        case .pieceInLanguage(let docId, let language):
            return ResolveEditionItems.items(language: language, isSource: false, docIds: [docId],
                                             read: editionRead, bookLevel: false)
        case .piece, .pieces, .figure, .elsewhere, .outside:
            return []
        }
    }

    /// The empty edition's sentence — none until this edition's read has
    /// landed (review M4: a list must not say "No round has run" over an
    /// edition with rounds while it reads them). A piece read in a language
    /// says its own (`ResolvePieceInLanguage.clearLine`).
    private var editionClear: String? {
        guard editionReadIsCurrent else { return nil }
        switch scope {
        case .edition(let language, let isSource, _):
            return ResolveEditionItems.clearLine(language: language, isSource: isSource,
                                                 hasRounds: editionRead.hasRounds,
                                                 readingBook: presenceReading.map { !$0.isComplete } ?? false)
        case .pieceInLanguage(let docId, let language):
            return ResolvePieceInLanguage.clearLine(
                language: language,
                noun: PieceNoun.of(TreeWalk.find(id: docId, in: store.manifest.structure), in: store.manifest).singular,
                hasRounds: editionRead.hasRounds,
                readingBook: Self.readsQuestionsFromPresence(docId: docId, presence: presenceReading,
                                                             documentStore: documentStore),
                sourceHasSomething: sourceHasSomething(docId))
        case .piece, .pieces, .figure, .elsewhere, .outside:
            return nil
        }
    }

    /// Whether a piece's SOURCE has something open — the tree's dot on its
    /// row, the one predicate the empty list and its button ask.
    private func sourceHasSomething(_ docId: String) -> Bool {
        presenceMarks.map { ResolvePresence.rowMark(.item(docId), in: $0) == .something } ?? false
    }

    /// **The piece whose source items the empty list offers to show** (plan
    /// 4 closing review, I2): a piece read in a language whose source has
    /// something open, once its read has landed. Nil anywhere else.
    private var sourceToShow: String? {
        guard editionReadIsCurrent, case .pieceInLanguage(let docId, _) = scope,
              sourceHasSomething(docId) else { return nil }
        return docId
    }

    /// **Whether a piece read in a language may still be missing a
    /// question** — its questions come from the window's presence read
    /// (the piece is not open, so no `Document` answers for it) and that
    /// read has not reached the whole book yet. An open piece's own notes
    /// are always whole. Pure over its inputs.
    static func readsQuestionsFromPresence(docId: String, presence: ResolvePresence.BookReading?,
                                           documentStore: DocumentStore) -> Bool {
        guard let presence, documentStore.document(forDocId: docId) == nil else { return false }
        return !presence.isComplete
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

    /// **The piece bulk acts over**: the open piece, at its own scope or
    /// inside the Book or Part list it was opened in (`ResolveVerbGate`).
    private var bulkDocId: String? {
        ResolveVerbGate.bulkDocId(scope: scope, openDocId: openDocId,
                                  isRegistered: { documentStore.document(forDocId: $0) != nil })
    }

    /// Say where an answer was filed, seen from the faces.
    private func filed(_ destination: FiledDestination) {
        filedNotice = FiledNotice.after(
            .filed(FiledUnder.filing(destination, faces: subject.faces, store: store)),
            current: filedNotice)
    }

    /// **The piece whose caret the list follows**: the open piece, wherever
    /// the faces' scope holds it — the piece's own list, or the Book or Part
    /// list it was opened inside (review I1). Nil off the open piece.
    /// The caret's place as `ResolveCaretReader` reads it, now.
    private var caretLocationNow: Int? { caretDocument?.cursorLocation }

    private var caretDocument: Document? {
        guard let openDocId, scope.docIds.contains(openDocId), mayAct(on: openDocId) else { return nil }
        return documentStore.document(forDocId: openDocId)
    }

    private var listKey: ResolveListKey {
        Self.listKey(scope: scope, annotationsToken: annotationsToken, store: store,
                     documentStore: documentStore, diagnostics: diagnostics, localName: localName,
                     script: Self.script(for: scope, structure: store.manifest.structure,
                                         openDocId: openDocId, script: script),
                     presence: editionPresence,
                     figureChanges: figureTree?.figureSourceChanges ?? [])
    }

    /// The presence read, at an edition scope only — what its questions
    /// come from, and what its read is keyed on.
    private var editionPresence: ResolvePresence.BookReading? {
        scope.translationLanguage == nil ? nil : presenceReading
    }

    private var shownSelection: Set<ResolveSource> {
        ResolveFilter.normalized(selection, chips: shownChips, dense: dense)
    }

    /// The chips drawn: a Questions chip stays while it is asked for (row 34).
    private var shownChips: [ResolveSource] {
        ResolveFilter.shownChips(chips, selection: selection)
    }

    private var hasList: Bool {
        switch scope {
        case .piece, .pieces, .figure, .edition, .pieceInLanguage: return true
        case .elsewhere, .outside: return false
        }
    }

    // MARK: - Body

    var body: some View {
        // **The list keeps its room** (`ResolveHeadRoomLayout`): an open head
        // past what the pane affords scrolls within itself.
        ResolveHeadRoomLayout {
            // ONE subview, whatever the head's body is (fix round 1, A1): an
            // edition's head is two views, a figure's none.
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
                    onSetPassState: onSetPassState,
                    onFiledUnder: { filed($0) },
                    editionRead: editionReadIsCurrent ? editionRead : .empty,
                    onShowRound: { publishCentre?.show(round: $0) },
                    onShowProposal: { publishCentre?.show(proposal: $0) },
                    mayDecideDesign: editionVerbs?.mayDecideDesign ?? false,
                    editorControl: editorControl,
                    translationHeard: translationHeard,
                    translateAsk: $translateAsk)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Self.headIdentifier)
            VStack(spacing: 0) {
                if filedNotice != nil {
                    FiledNotice(filing: $filedNotice, onOpenBrief: onOpenBrief, lingers: false)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                }
                if hasList {
                    VStack(spacing: 0) {
                        filterBar
                        Divider()
                        list
                    }
                    // The filed line stands until the writer's next act here —
                    // never a timer (Task 6a). Simultaneous: every control in
                    // the list still takes its own press.
                    .simultaneousGesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if filedLineAtPress == nil { filedLineAtPress = .some(filedNotice?.id) }
                        }
                        .onEnded { _ in
                            filedNotice = FiledNotice.after(
                                .listPressed(over: filedLineAtPress ?? nil), current: filedNotice)
                            filedLineAtPress = nil
                        })
                } else {
                    ContentUnavailableView {
                        Label("To resolve", systemImage: "checklist")
                    } description: {
                        Text((Self.emptyState(scope: scope, hasItems: false, hasVisible: false,
                                              offersColdStart: false, editionClear: editionClear)
                              ?? .outside).sentence)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(Self.restIdentifier)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: listKey) { refresh(listKey) }
        // An edition's rounds, proposals and problems: once per key, the
        // ledger off the main actor (shell p4 Task 6).
        // A piece read in a language reads its own rounds the same way
        // (shell p4 Task 9).
        .task(id: editionKey) {
            guard let key = editionKey else {
                editionRead = .empty
                editionReadScope = nil
                return
            }
            let read: ResolveEditionItems.Read
            switch key.scope {
            case .edition(let language, let isSource, let docIds):
                read = await ResolveEditionItems.read(
                    language: language, isSource: isSource, docIds: docIds, problems: key.problems,
                    store: store, documentStore: documentStore)
            case .pieceInLanguage(let docId, let language):
                read = await ResolveEditionItems.readPiece(
                    docId: docId, language: language, store: store, documentStore: documentStore)
            case .piece, .pieces, .figure, .elsewhere, .outside:
                return
            }
            guard !Task.isCancelled else { return }
            editionRead = read
            editionReadScope = key.scope
            held = ResolveEditionItems.replacing(held, with: editionItems)
            regroup(scope: scope)
        }
        .onProjectEvent(.maughamDesignProposalsChanged, url: store.url, window: window) { _ in
            editionHeard &+= 1
        }
        .onProjectEvent(.maughamTranslationRoundEnded, url: store.url, window: window) { _ in
            editionHeard &+= 1
        }
        // A round's record rewritten by a verb — here, in the round report,
        // in another window (shell p4 Task 6 fix round, review I1).
        .onProjectEvent(.maughamTranslationRoundChanged, url: store.url, window: window) { _ in
            editionHeard &+= 1
        }
        // A translation written — a round's ingest, Claude's write, a Clear:
        // what a piece read in a language lacks and leaves over moved.
        .onProjectEvent(.maughamTranslationDidUpdate, url: store.url, window: window) { _ in
            translationHeard &+= 1
        }
        // The sidecar for the scope's pieces — never from `body`; its
        // `version` moves the read key.
        .task(id: scope) {
            if let diagnostics { ResolveReader.loadFindings(scope: scope, diagnostics: diagnostics) }
        }
        .onChange(of: scope) { _, _ in
            // A menu's ask belongs to the scope it was offered at (C1).
            translateAsk = nil
            pendingRequest = Self.pendingSurvivingScopeChange(pendingRequest)
            selection = []
            choices = [:]
            caretGroup = nil
            caretPin = nil
            selectionModeOn = false
            selectedIds = []
            settledExpanded = false
            bookSettledExpanded = false
            figureSettledExpanded = false
            markChecksRead()
            markedItemId = nil
            // "This chapter" was said of the list it stood over (M1).
            filedNotice = nil
        }
        // The open piece changed inside a Book or Part list: a selection
        // made over the last one's notes is not this one's.
        .onChange(of: bulkDocId) { _, _ in
            selectionModeOn = false
            selectedIds = []
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
        .onChange(of: ResolveShownSelection(scope: scope, selection: shownSelection), initial: true) { _, shown in
            onSelectionShown(shown)
        }
        .onChange(of: stetFlourishIds) { old, new in stetMarksChanged(from: old, to: new) }
        .onChange(of: letterLedgerRevision) { _, _ in
            ledgerText = LessonLedgerVerbs.ledgerText(store: store)
        }
        .onChange(of: caretDocument?.docId) { _, docId in if docId == nil { caretGroup = nil } }
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
        .sheet(item: $comparing) { target in
            if let tree = figureTree {
                ResolveFigureCompareSheet(figureId: target.figureId, store: store,
                                          documentStore: documentStore,
                                          actions: { report in figureActions(tree: tree, report: report) },
                                          // Refresh needs the table here: Open the Table puts its
                                          // grid in this centre, wherever the figure's row lives.
                                          openTheTable: drawsFigure(target.figureId) ? {
                                              ResolveFigureSourceVerbs.openTheTable(
                                                  target.figureId, reveal: revealFigure, show: showFigureInCentre)
                                          } : nil,
                                          done: { comparing = nil })
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            let creation = creationVerbs.creation
            NewTaskSheet(
                taskBody: $newTaskBody, scope: $newTaskScope,
                canPickDocumentScope: creation.document,
                canPickProjectScope: creation.project,
                noun: PieceNoun.of(pieceDocId.flatMap { TreeWalk.find(id: $0, in: store.manifest.structure) },
                                   in: store.manifest),
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

    /// The head's and the rest's accessibility identifiers — what a mounted
    /// test reads their frames by.
    static let headIdentifier = "resolve.head"
    static let restIdentifier = "resolve.rest"

    // MARK: - The filter bar

    private var filterBar: some View {
        ResolveFilterBar(
            chips: shownChips, selection: shownSelection, passes: passes,
            showsSelectionMode: showsSelectionMode,
            selectionModeOn: selectionModeOn,
            // An edition lists no to-dos, so it makes none.
            showsNewTodo: scope.translationLanguage == nil && creationVerbs.creation.offersAny,
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

    /// Selection mode's door: the open piece's notes — at its own scope or
    /// inside a Book or Part list — where its posture leaves a bulk verb.
    private var showsSelectionMode: Bool {
        guard let docId = bulkDocId, !bulkRows.isEmpty else { return false }
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
        let bulk = bulkDocId
        let empty = Self.emptyState(scope: scope, hasItems: !held.items.isEmpty,
                                    hasVisible: !shown.isEmpty,
                                    offersColdStart: offersColdStart,
                                    editionClear: editionClear,
                                    showsOnlyQuestions: shownSelection == [.questions])
        let opensItsPiece = openThePieceLines(shown)
        let headers = Self.drawsGroupHeaders(shown)
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // The may-be-incomplete notice rides the first
                        // group's line (fix round 1, B4); its own row only
                        // over a list with no group to carry it.
                        if let incomplete, shown.isEmpty {
                            Text(incomplete)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        emptyLine(empty)
                        ForEach(shown) { group in
                            let notice = group.id == shown.first?.id ? incomplete : nil
                            if headers {
                                groupHeader(group, isOpen: open.contains(group.key), notice: notice)
                                    .id(group.key)
                                // A piece not open: why its rows have no verbs,
                                // and the way to them (appraisal 1).
                                if let (docId, line) = opensItsPiece[group.key] {
                                    ResolveOpenThePieceButton(
                                        line: line,
                                        open: { ResolveNavigation.goInsideTheFaces(toDocId: docId, paragraphId: nil) })
                                    .padding(.leading, 26).padding(.trailing, 12).padding(.bottom, 6)
                                }
                                if open.contains(group.key) {
                                    ForEach(group.items) { item in
                                        row(item, acting: acting, bulk: bulk, wiring: wiring, reorders: reorders)
                                        Divider()
                                    }
                                }
                            } else {
                                // **A short list draws no headers** (fix round
                                // 1, B3): every group is open, and each row
                                // says what its header would have.
                                VStack(alignment: .leading, spacing: 0) {
                                    if let (docId, line) = opensItsPiece[group.key] {
                                        ResolveOpenThePieceButton(
                                            line: line,
                                            open: { ResolveNavigation.goInsideTheFaces(toDocId: docId, paragraphId: nil) })
                                        .padding(.horizontal, 12).padding(.top, 6)
                                    }
                                    ForEach(group.items) { item in
                                        row(item, acting: acting, bulk: bulk, wiring: wiring, reorders: reorders,
                                            groupCaption: group.title,
                                            captionNotice: item.id == group.items.first?.id ? notice : nil)
                                        Divider()
                                    }
                                }
                                .id(group.key)
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
                        if !figureSettled.isEmpty {
                            ResolveFigureSettledSection(
                                title: ResolveFigureSettledSection.title(for: scope),
                                notes: figureSettled, figureNames: figureNames,
                                figureCells: figureCells, ledgerText: ledgerText,
                                wiring: wiring, isExpanded: $figureSettledExpanded)
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
                    // A pinned group's scroll is its request's (one writer).
                    guard caretPin?.key != new,
                          let target = Self.scrollTarget(from: old, to: new) else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                }
                .onChange(of: scrollRequest) { _, key in
                    guard let key else { return }
                    scrollRequest = nil
                    // The next turn, and not animated: a request is applied
                    // with the read that built its group, before the lazy
                    // list has laid it out, and an animated scroll to it
                    // went nowhere (fix round 1, I2, pinned by
                    // `MarginClickResolveTests`). A request is a jump.
                    DispatchQueue.main.async { proxy.scrollTo(key, anchor: .top) }
                }
            }
            .background {
                if let caret = caretDocument {
                    ResolveCaretReader(document: caret, scope: scope, sceneIndex: sceneIndex,
                                       groups: shown, caretGroup: $caretGroup, pin: $caretPin)
                }
            }
            // Over the open piece's notes only: `acting` is the open piece's
            // `Document`, and bulk is drawn only where it is the bulk piece.
            if selectionModeOn, let bulk, let acting, acting.docId == bulk,
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
                        titleOf: { RoundNarrative.pieceTitle(of: $0, in: store.manifest.structure) }),
                    noun: PieceNoun.of(TreeWalk.find(id: pieceDocId, in: store.manifest.structure),
                                       in: store.manifest))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        case .nothing?, .filteredOut?, .editionClear?, .noQuestions?:
            Text((empty ?? .nothing).sentence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
            // The source's items are one switch away: the line's own button
            // reads the piece in Source and shows them (closing review I2).
            if case .editionClear? = empty, let docId = sourceToShow {
                Button(ResolvePieceInLanguage.readSourceTitle) {
                    ResolvePieceInLanguage.readSource(docId: docId, openDocId: openDocId)
                }
                .buttonStyle(.link)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 10)
                .accessibilityIdentifier("resolve.readSource")
            }
        case .outside?, .elsewhere?, nil:
            EmptyView()
        }
    }

    // MARK: - A group

    /// Once per pass, never per row (tripwire 4): each group whose piece is
    /// not open, its piece, and the line its header says.
    private func openThePieceLines(_ groups: [ResolveGroup]) -> [ResolveGroup.Key: (String, String)] {
        var lines: [ResolveGroup.Key: (String, String)] = [:]
        for group in groups {
            guard let docId = ResolveHead.groupOpensItsPiece(group, mayAct: mayAct(on:)) else { continue }
            lines[group.key] = (docId, ResolveHead.openThePieceLine(
                noun: PieceNoun.of(TreeWalk.find(id: docId, in: store.manifest.structure), in: store.manifest).singular,
                hasItemsToAnswer: true))
        }
        return lines
    }

    private func groupHeader(_ group: ResolveGroup, isOpen: Bool, notice: String? = nil) -> some View {
        let atCaret = group.key == caretGroup
        return Button {
            choices[group.key] = !isOpen
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(atCaret ? Color.primary : Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    // The may-be-incomplete notice, on the first group's
                    // line rather than a row of its own (B4).
                    if let notice {
                        Text(notice)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
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

    /// **Fewer items than this, and the list draws no group headers**
    /// (fix round 1, B3): each row is captioned with its group's title.
    static let groupHeadersFrom = 5

    /// Whether `shown` draws its group headers. Pure.
    static func drawsGroupHeaders(_ shown: [ResolveGroup]) -> Bool {
        shown.reduce(0) { $0 + $1.items.count } >= groupHeadersFrom
    }

    @ViewBuilder
    private func row(_ item: ResolveItem, acting: Document?, bulk: String?,
                     wiring: AnnotationRowWiring, reorders: Bool, groupCaption: String? = nil,
                     captionNotice: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // A headerless row's caption (B3): its group's title, one line;
            // on the first row, the may-be-incomplete notice under it (B4).
            if let groupCaption {
                Text(groupCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12).padding(.top, 6)
                    .accessibilityIdentifier("resolve.row.groupCaption")
            }
            if let captionNotice {
                Text(captionNotice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
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
                    isSelectable: selectionModeOn && note.docId == bulk,
                    isSelected: selectedIds.contains(note.annotation.id),
                    figureTitle: figureNames[note.docId],
                    figureCells: figureCells[note.annotation.id],
                    wiring: wiring)
                notThisLine(item, note: note, acting: acting)
            case .finding(let docId, let finding):
                findingRow(item, docId: docId, finding: finding, acting: acting)
            case .todo(let task):
                todoRow(task, acting: acting, reorders: reorders)
            case .figureSourceChanged(let figureId, let docId, _):
                figureSourceRow(item, figureId: figureId, docId: docId)
            case .translationChange, .glossaryProposal, .designProposal, .compileProblem:
                ResolveEditionRow(item: item, read: editionRead, verbs: editionVerbs ?? ResolveEditionVerbs(),
                                  authorVerbs: editionAuthorVerbs[ResolveEditionItems.authorKey(item)] ?? .none)
            }
        }
        // A strain mark's jump marks its row (`.focusFinding`).
        .background(alignment: .leading) {
            if item.id == markedItemId {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
        .accessibilityAddTraits(item.id == markedItemId ? .isSelected : [])
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
            onJump: { pid in
                if ResolveNavigation.opensInsideTheFaces(docId: docId, scope: scope) {
                    ResolveNavigation.goInsideTheFaces(toDocId: docId, paragraphId: pid)
                } else {
                    ResolveNavigation.go(toDocId: docId, paragraphId: pid)
                }
            },
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
                                   presence: key.regroup.read.presence,
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
        // An edition's own kinds are not the walks': a read keeps the last
        // edition read's (`ResolveEditionItems.replacing`).
        held = scope.translationLanguage == nil
            ? hold.snapshot : ResolveEditionItems.replacing(hold.snapshot, with: editionItems)
        keptStetted = hold.kept
        if step == .read {
            figureCells = walks.annotations?.figureCells ?? [:]
            figureSettled = ResolveSettled.figureNotes(
                in: walks.annotations, scope: readScope,
                figureOwners: ProjectStore.figureNoteOwners(store.manifest.figures ?? []))
            ledgerText = LessonLedgerVerbs.ledgerText(store: store)
        }
        // A read's own task walk may move the Book's to-do version: keyed on
        // what it left, so one refresh is one read.
        lastKey = step == .read ? Self.keyAfterRead(key, tasksVersionNow: store.projectTasksVersion) : key
        regroup(scope: readScope)
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
        regroup(scope: scope)
    }

    private func regroup(scope: ResolveScope) {
        let structure = store.manifest.structure
        var names: [String: String] = [:]
        for figure in store.manifest.figures ?? [] where names[figure.id] == nil {
            names[figure.id] = figure.name
        }
        let (index, titles) = Self.scenes(
            held, scope: scope,
            groupsByScene: Self.groupsByScene(scope, structure: structure, openDocId: openDocId),
            windowScript: WindowScript.live(script, openDocId: openDocId))
        figureNames = names
        sceneIndex = index
        groups = ResolveGrouping.groups(held, scope: scope, structure: structure,
                                        sceneIndex: index, sceneTitles: titles,
                                        figureNames: names, book: PieceNoun.Book(store.manifest))
        chips = ResolveFilter.chips(held.items, passes: passes, localName: localName)
        dense = ResolveTriage.isDense(held.items, choice: triageChoice)
        incomplete = Self.incompleteLine(held, structure: structure, figureNames: names)
        rebuildEditionVerbs()
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
        // The menu's Translate is the head's Run (row 7): the head runs it
        // where it offers Run, and the ask is spent either way.
        if case .translate(let ask) = pending {
            if ask.lands(in: scope) {
                translateAsk = ask
            } else {
                filedNotice = FiledNotice.after(
                    .filed(FiledNotice.Filing(sentence: ask.notHereLine, brief: nil)), current: filedNotice)
            }
            return
        }
        let activePass = pieceDocId.flatMap {
            documentStore.uiState.activePassMemory.validatedActivePass(forPiece: $0, in: passes)
        }
        let outcome = Self.apply(pending, groups: groups, sceneIndex: sceneIndex, chips: chips, activePassId: activePass,
                                 dense: dense, selection: shownSelection, choices: choices,
                                 figureOwners: ProjectStore.figureNoteOwners(store.manifest.figures ?? []),
                                 localName: localName)
        selection = outcome.selection
        choices = outcome.choices
        scrollRequest = outcome.scrollTo
        markedItemId = outcome.marked
        // Every request that scrolls pins its target as the caret group
        // (one mechanism, fix round 2, N1): the caret reader's write and
        // scroll stand down until the writer moves the caret.
        if let target = outcome.scrollTo {
            caretPin = ResolveCaretPin(key: target, caretLocation: caretLocationNow)
            caretGroup = target
        }
        if let line = outcome.line {
            filedNotice = FiledNotice.after(
                .filed(FiledNotice.Filing(sentence: line, brief: nil)), current: filedNotice)
        }
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

    // MARK: - A figure's changed source (shell p5 Task 3)

    /// The tree's figure helper, acting for this window (Compare's Refresh),
    /// reporting to `report` — the Compare sheet's own line (fix round 1, M1).
    private func figureActions(tree: BinderTreeSectionsState,
                               report: @escaping (String) -> Void) -> FigureActions {
        var actions = FigureSectionVerbs(store: store, state: tree)
            .shared(report: report, windowRefusesWrites: tree.figureWritesRefused)
        actions.window = window
        return actions
    }

    private func figureSourceRow(_ item: ResolveItem, figureId: String, docId: String?) -> some View {
        let change = figureTree?.figureSourceChanges.first { $0.figureId == figureId }
        let atFigureScope = if case .figure = scope { true } else { false }
        return ResolveFigureSourceRow(
            sentence: change?.sentence ?? "A figure\u{2019}s source data changed",
            detail: change?.detail,
            offers: ResolveFigureSourceOffers.of(
                change: change, figureId: figureId, docId: docId, hasTree: figureTree != nil,
                drawsFigure: drawsFigure(figureId), atFigureScope: atFigureScope),
            goToTheLine: {
                if let place = ResolveFigureSourceVerbs.place(of: item, change: change, scope: scope,
                                                              paragraphOfLine: paragraphOfLine) {
                    ResolveFigureSourceVerbs.go(to: place)
                }
            },
            compare: { comparing = ResolveFigureCompare(figureId: figureId) },
            open: { ResolveFigureSourceVerbs.open(figureId, reveal: revealFigure, travel: onTravel) })
    }

    /// The paragraph a figure's line is in now (`FigureUseTravel.destination`).
    private func paragraphOfLine(_ use: FigureListing.Use) -> String? {
        if case .paragraph(let reveal) = FigureUseTravel.destination(for: use, store: store,
                                                                      documentStore: documentStore) {
            return reveal.paragraphId
        }
        return nil
    }

    // MARK: - Going to a place

    /// A row's click: its piece, on its paragraph (`ResolveNavigation`); a
    /// figure's note travels to the figure.
    private func go(_ item: ResolveItem) {
        if case .note(let note) = item, DocumentClass.isFigureDocId(note.docId) {
            figureClick(note)
            return
        }
        // **An edition's question opens in its language** (shell p4 Task 6
        // fix round): the paragraph it asks about, read in the edition, as a
        // change's click does — and so does a piece's read in a language
        // (Task 9).
        if case .note(let note) = item, let language = scope.translationLanguage,
           let reveal = Self.editionQuestionReveal(note, language: language) {
            TranslationReveal.post(reveal)
            return
        }
        let first = held.sequences[item.docId]?.first
        // A Book or Part list stays beside the piece it opens (review I1).
        if ResolveNavigation.opensInsideTheFaces(docId: item.docId, scope: scope) {
            ResolveNavigation.goInsideTheFaces(item, firstParagraph: first)
        } else {
            ResolveNavigation.go(item, firstParagraph: first)
        }
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

    // MARK: - An edition's verbs

    /// **An edition question's click**: its paragraph, in the edition's
    /// language (`TranslationReveal`) — nil for a note that is not one of
    /// the edition's questions or names no paragraph. Pure.
    static func editionQuestionReveal(_ note: ProjectAnnotation, language: String) -> TranslationReveal? {
        guard ResolveEditionItems.isQuestion(note.annotation, in: language),
              let paragraphId = note.annotation.paragraphId else { return nil }
        return TranslationReveal(docId: note.docId, language: language, paragraphId: paragraphId)
    }

    /// The author verbs of each piece an edition row is on, asked once per
    /// pass (review M3: never three posture asks per row per render).
    @State private var editionAuthorVerbs: [String: TranslationAuthorVerbs] = [:]

    /// **The round report's verbs and the gate's, wired to this window** —
    /// called, never re-spelled (shell p4 Task 6). Built once per refresh,
    /// not per row (review M3); nil off an edition.
    @State private var editionVerbs: ResolveEditionVerbs?

    private func rebuildEditionVerbs() {
        guard let language = scope.translationLanguage else {
            editionVerbs = nil
            editionAuthorVerbs = [:]
            return
        }
        let projectURL = store.url
        let statements = store.manifest.statements
        var cache: [String: TranslationAuthorVerbs] = [:]
        for item in held.items {
            let key = ResolveEditionItems.authorKey(item)
            guard !key.isEmpty, cache[key] == nil else { continue }
            cache[key] = TranslationAuthorVerbs.decide(
                document: documentStore.posture(forDocId: item.docId),
                editionBrief: documentStore.posture(
                    ofStatement: .editionBrief(language), scope: .project, statements: statements),
                pieceIntent: documentStore.posture(
                    ofStatement: .intent, scope: .document(item.docId), statements: statements))
        }
        editionAuthorVerbs = cache
        editionVerbs = ResolveEditionVerbs(
            round: TranslationRoundActions.production(
                store: store, documentStore: documentStore, projectURL: projectURL, world: world),
            authorVerbs: { docId, _ in cache[docId] ?? .none },
            mayDecideDesign: DesignGate.mayDecide(documentStore: documentStore,
                                                  statements: store.manifest.statements),
            approve: { proposal in
                await DesignGatePromotion.approve(
                    proposal, projectURL: projectURL,
                    jobManager: CentreColumn.compileJobs(for: projectURL))
            },
            discard: { proposal in DesignGatePromotion.discard(proposal, projectURL: projectURL) },
            showRound: { publishCentre?.show(round: $0) },
            showProposal: { publishCentre?.show(proposal: $0) },
            showProblems: {
                if let publishCentre { publishCentre.show(problems: publishCentre.compileRunner.state.problems) }
            },
            onRoundChanged: { roundChanged($0) },
            onProposalChanged: {
                publishCentre?.adoptVerbAnswer($0)
                editionHeard &+= 1
            },
            onFiled: { filed($0) })
    }

    /// **A round as a verb wrote it**, patched in at once (review C1): the
    /// list's read and its items, and the centre's report if it shows that
    /// round — no re-read stands between the write and the next press.
    private func roundChanged(_ updated: TranslationRound) {
        editionRead = ResolveEditionItems.patching(editionRead, with: updated)
        held = ResolveEditionItems.replacing(held, with: editionItems)
        regroup(scope: scope)
        publishCentre?.adoptVerbAnswer(updated)
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
                diagnostics: diagnostics, filedUnder: { filed($0) })
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

    /// The open piece's visible notes — what bulk acts over, in its own list
    /// or a Book or Part list that holds it.
    private var bulkRows: [Annotation] {
        guard let bulkDocId else { return [] }
        return Self.bulkRows(visible, pieceDocId: bulkDocId, heldForFlourish: keptStetted)
    }

    /// The open piece's visible notes, less any row held only for its stet
    /// flourish: it is settled, and a bulk mark on it would be a verb its own
    /// row refuses (`AnnotationRow.offersTriage`, review M6).
    static func bulkRows(_ visible: [ResolveItem], pieceDocId: String,
                         heldForFlourish: Set<String>) -> [Annotation] {
        visible.compactMap { item -> Annotation? in
            if case .note(let note) = item, note.docId == pieceDocId,
               !heldForFlourish.contains(note.annotation.id) { return note.annotation }
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
            visibleAnnotations: { doc in doc.docId == bulkDocId ? bulkRows : [] },
            effectiveSelection: { effectiveSelection(in: $0) },
            staleConfirm: $staleConfirm, anchorLostNotice: $anchorLostNotice,
            revertConfirm: $revertConfirm, rulingNotice: $rulingNotice,
            ledgerNotice: $ledgerNotice, choiceOffer: $choiceOffer,
            stetFlourishIds: $stetFlourishIds, bulkInFlight: $bulkInFlight,
            selectedIds: $selectedIds, bulkNotice: $bulkNotice,
            letterLedgerRevision: $letterLedgerRevision,
            projectRefreshToken: $annotationsToken,
            onFiledUnder: { filed($0) })
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
