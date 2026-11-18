import SwiftUI
import MaughamCore

// The list's caret reader and its pure decisions, moved out of
// `ResolvePane.swift` so the view reads as a view (shell plan 2 Task 7,
// Task 6 review M9).

// MARK: - The caret

/// **The caret's group, read where it changes.** Mounted only on the open
/// piece, where the faces' scope holds it (its own list, or the Book or Part
/// list it was opened inside, review I1). It reads `Document.cursorLocation` itself, so a
/// caret move re-renders this empty view and nothing else; per move only
/// `paragraphId(at:)` and the caret function over groups already built run
/// (tripwire 4), and the list hears of it only when the GROUP changes.
@MainActor
struct ResolveCaretReader: View {
    let document: Document
    let scope: ResolveScope
    let sceneIndex: [String: Int]?
    let groups: [ResolveGroup]
    @Binding var caretGroup: ResolveGroup.Key?

    var body: some View {
        let paragraph = ResolvePane.caretParagraph(scope: scope, openDocId: document.docId,
                                                   mayAct: true) {
            document.paragraphId(at: document.cursorLocation)
        }
        let key = ResolveFilter.cursorGroup(paragraphId: paragraph, docId: document.docId,
                                            sceneIndex: sceneIndex, groups: groups)
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: key, initial: true) { _, new in caretGroup = new }
    }
}

// MARK: - The decisions, pure

extension ResolvePane {

    /// **What To resolve's read is keyed on**, from the live stores: the
    /// scope, the event token, which of the scope's pieces are open, the
    /// Book's to-dos, the sidecar, the passes and the local name. No open
    /// piece's version is in it (review C1): those are the list key's splice.
    static func readKey(scope: ResolveScope, annotationsToken: Int, store: ProjectStore,
                        documentStore: DocumentStore, diagnostics: DiagnosticsStore?,
                        localName: String) -> ResolveReadKey {
        let inScope = Set(scope.docIds)
        return ResolveReadKey(
            scope: scope, annotationsToken: annotationsToken,
            openPieces: documentStore.allOpenDocuments().map(\.docId).filter(inScope.contains),
            projectTasksVersion: store.projectTasksVersion,
            diagnosticsVersion: diagnostics?.version ?? 0,
            passes: store.manifest.effectiveReviewPasses,
            localName: localName)
    }

    /// The whole key the view's `.task(id:)` runs on.
    static func listKey(scope: ResolveScope, annotationsToken: Int, store: ProjectStore,
                        documentStore: DocumentStore, diagnostics: DiagnosticsStore?,
                        localName: String, script: FountainScript?) -> ResolveListKey {
        ResolveListKey(
            regroup: ResolveRegroupKey(
                read: readKey(scope: scope, annotationsToken: annotationsToken, store: store,
                              documentStore: documentStore, diagnostics: diagnostics,
                              localName: localName),
                script: script),
            openTodos: openTodoVersion(scope: scope, documentStore: documentStore),
            openNotes: openNoteVersion(scope: scope, documentStore: documentStore))
    }

    /// **Read before regroup.** A read key that moved runs the read (which
    /// also reads the piece's text); a script-only change re-reads the text;
    /// an open piece's notes or to-dos alone are the live splice.
    static func refreshStep(_ key: ResolveListKey, last: ResolveListKey?) -> ResolveRefreshStep {
        guard let last, last.regroup.read == key.regroup.read else { return .read }
        return last.regroup.script == key.regroup.script ? .live : .reread
    }

    /// The sum of `tasksVersion` over the open pieces the scope holds.
    static func openTodoVersion(scope: ResolveScope, documentStore: DocumentStore) -> Int {
        let inScope = Set(scope.docIds)
        return documentStore.allOpenDocuments()
            .filter { inScope.contains($0.docId) }
            .reduce(0) { $0 &+ $1.tasksVersion }
    }

    /// The sum of `annotationsVersion` over the open pieces the scope holds:
    /// a burst flush, a minted note or a verb on one moves it.
    static func openNoteVersion(scope: ResolveScope, documentStore: DocumentStore) -> Int {
        let inScope = Set(scope.docIds)
        return documentStore.allOpenDocuments()
            .filter { inScope.contains($0.docId) }
            .reduce(0) { $0 &+ $1.annotationsVersion }
    }

    /// **Whether a `.maughamAnnotationsChanged` re-walks** (review C1): only
    /// when no window holds the document open — a closed piece's op log, a
    /// figure's stream, a peer's sync into a closed piece. An open piece's
    /// event (its own append, a mint, a merge) moves its `annotationsVersion`
    /// too, which the live splice reads off the `Document`.
    static func annotationsEventMovesTheWalk(docId: String?, documentStore: DocumentStore) -> Bool {
        guard let docId else { return true }
        return documentStore.document(forDocId: docId) == nil
    }

    /// One refresh step's read. `.read` gathers over the held walks
    /// (`ResolveWalkHold`, asked again only when `key.walk` moved) with the
    /// open pieces read live; `.reread` the open piece's text, then the live
    /// pieces; `.live` the live pieces alone — each open in-scope piece's
    /// notes, to-dos, paragraph order and (at a `.piece`) text, off its
    /// `Document`. Neither of the last two asks a walk.
    static func refreshed(_ held: ResolveSnapshot, step: ResolveRefreshStep, key: ResolveReadKey,
                          walks: inout ResolveWalkHold, store: ProjectStore,
                          documentStore: DocumentStore,
                          diagnostics: DiagnosticsStore?) -> ResolveSnapshot {
        let scope = key.scope
        let live = livePieces(scope: scope, documentStore: documentStore)
        switch step {
        case .read:
            guard !scope.docIds.isEmpty || scope.includesBookLevel else { return .empty }
            return ResolveReader.read(
                scope: scope,
                annotations: walks.annotations(for: key.walk, store: store),
                tasks: walks.tasks(for: key.tasksWalk, store: store),
                live: live, store: store, documentStore: documentStore, diagnostics: diagnostics)
        case .reread:
            let text = ResolveReader.rereadText(held, scope: scope, store: store,
                                                documentStore: documentStore)
            return splicing(text, scope: scope, live: live)
        case .live:
            return splicing(held, scope: scope, live: live)
        }
    }

    /// Every note in the project in every status, as the held walk and the
    /// open pieces now hold them — what the stet hold and the second-stet
    /// offer look notes up in, without a walk.
    static func projectNotes(walks: ResolveWalkHold, scope: ResolveScope,
                             documentStore: DocumentStore) -> ProjectAnnotationsSnapshot {
        ResolveReader.overlaying(
            walks.annotations ?? ProjectAnnotationsSnapshot(annotations: [], unreadableDocIds: [], sequences: [:]),
            live: livePieces(scope: scope, documentStore: documentStore))
    }

    /// The open in-scope pieces, read off their documents: their notes (every
    /// status), their open to-dos, their paragraph order and their text.
    static func livePieces(scope: ResolveScope, documentStore: DocumentStore) -> [String: ResolveLivePiece] {
        var live: [String: ResolveLivePiece] = [:]
        for docId in scope.docIds {
            guard let doc = documentStore.document(forDocId: docId) else { continue }
            live[docId] = ResolveLivePiece(
                notes: doc.annotations(filter: AnnotationFilter(kinds: nil, statuses: nil)),
                todos: doc.tasks(filter: TaskFilter(scope: .document(docId: docId), statuses: [.open])),
                sequence: doc.sequence, paragraphs: doc.paragraphs)
        }
        return live
    }

    /// `held` with each piece in `live` holding exactly its live open notes,
    /// its live to-dos and its live paragraph order — so a to-do typed into a
    /// new paragraph is placed there, never under "No longer in the text" —
    /// and, at a `.piece` scope, that piece's live text (its group titles).
    /// Every other item, piece and name is untouched.
    static func splicing(_ held: ResolveSnapshot, scope: ResolveScope,
                         live: [String: ResolveLivePiece]) -> ResolveSnapshot {
        guard !live.isEmpty else { return held }
        func isLive(_ item: ResolveItem) -> Bool {
            switch item {
            case .note, .todo: return live[item.docId] != nil
            case .finding: return false
            }
        }
        let freshNotes = scope.docIds.flatMap { docId in
            (live[docId]?.notes ?? []).filter { $0.status == .open }
                .map { ResolveItem.note(ProjectAnnotation(docId: docId, annotation: $0)) }
        }
        let freshTodos = scope.docIds.flatMap { live[$0]?.todos ?? [] }.map(ResolveItem.todo)
        let kept = held.items.filter { !isLive($0) }
        var sequences = held.sequences
        for (docId, piece) in live { sequences[docId] = piece.sequence }
        var text = held.paragraphText
        if case .piece(let docId, _) = scope, let piece = live[docId] { text = piece.paragraphs }
        return ResolveSnapshot(items: freshNotes + kept + freshTodos, sequences: sequences,
                               paragraphText: text,
                               unreadableDocIds: held.unreadableDocIds.filter { live[$0] == nil })
    }

    /// The window's script, where it is about the scope's piece: a
    /// screenplay piece (by its format) that is the open one, a screenplay's
    /// Book, or the one document of a one-script project. Otherwise no scenes.
    static func script(for scope: ResolveScope, structure: [StructureItem], openDocId: String?,
                       script: FountainScript?) -> FountainScript? {
        guard let script, case .piece(let docId, let isBook) = scope,
              let item = TreeWalk.find(id: docId, in: structure),
              DocumentFormat.ofManuscript(path: item.path).isScreenplay
        else { return nil }
        let isTheOnlyDocument = TreeWalk.collect(in: structure) { $0.type == .document }.count == 1
        guard isBook || docId == openDocId || isTheOnlyDocument else { return nil }
        return script
    }

    /// **To-dos reorder** only under Mine alone, when every visible item is a
    /// to-do of one piece and that piece is open (`mayAct`). The Book's
    /// to-dos have no `Document` to reorder through.
    static func reordersTodos(visible: [ResolveItem], selection: Set<ResolveSource>,
                              mayAct: Bool) -> Bool {
        guard mayAct, selection == [.mine], let first = visible.first,
              first.docId != ProjectStore.projectTasksDocId else { return false }
        return visible.allSatisfy { item in
            if case .todo = item { return item.docId == first.docId }
            return false
        }
    }

    /// A request, applied: a filter through `ResolveFilter.selection(for:)`
    /// (inert when its chip is absent); a focus opens and scrolls to that
    /// piece's or figure's group.
    static func apply(_ request: ResolveRequest, groups: [ResolveGroup], chips: [ResolveSource],
                      activePassId: String?, dense: Bool, selection: Set<ResolveSource>,
                      choices: [ResolveGroup.Key: Bool]) -> ResolveRequestOutcome {
        switch request {
        case .filter(let key):
            let next = ResolveFilter.selection(for: key, chips: chips,
                                               activePassId: activePassId, dense: dense)
            return ResolveRequestOutcome(selection: next ?? selection, choices: choices, scrollTo: nil)
        case .focus(let ownerId):
            guard let key = focusKey(ownerId: ownerId, in: groups) else {
                return ResolveRequestOutcome(selection: selection, choices: choices, scrollTo: nil)
            }
            var opened = choices
            opened[key] = true
            return ResolveRequestOutcome(selection: selection, choices: opened, scrollTo: key)
        }
    }

    /// The group a piece or a figure owns among the built groups.
    static func focusKey(ownerId: String, in groups: [ResolveGroup]) -> ResolveGroup.Key? {
        groups.first { group in
            switch group.key {
            case .piece(let docId): return docId == ownerId
            case .figure(let id): return id == ownerId
            default: return false
            }
        }?.key
    }

    /// The caret's paragraph, read only on the open piece, and only where the
    /// scope holds it (its own list, or a Book or Part list it was opened
    /// inside); nil anywhere else, without reading it.
    static func caretParagraph(scope: ResolveScope, openDocId: String?, mayAct: Bool,
                               read: () -> String?) -> String? {
        guard mayAct, let openDocId, !DocumentClass.isFigureDocId(openDocId),
              scope.docIds.contains(openDocId) else { return nil }
        return read()
    }

    /// Scroll only when the caret's group changes to a group.
    static func scrollTarget(from old: ResolveGroup.Key?, to new: ResolveGroup.Key?) -> ResolveGroup.Key? {
        guard let new, new != old else { return nil }
        return new
    }

    static let fromTheCheckCaption = "From the check"
    static let replacedByTheNextCheckCaption = "Replaced by the next check"

    /// The one caption a row may wear: a check-minted note is "From the
    /// check"; a sidecar strain is "Replaced by the next check".
    static func caption(for item: ResolveItem, localName: String) -> String? {
        switch item {
        case .finding: return replacedByTheNextCheckCaption
        case .note:
            return ResolveFilter.source(of: item, localName: localName) == .checks
                ? fromTheCheckCaption : nil
        case .todo: return nil
        }
    }

    /// **A finding's verbs, by who may write where** (P3c Task 7/8, controller
    /// rulings Q and U; the Diagnostics pane's posture rules, now To resolve's
    /// one gate). Answer files a ruling into the piece's OWN intent, so it asks
    /// `.editStatement` of that statement and nothing else; Promote files a
    /// task on the piece's `Document`, so it asks `.task` of the piece and only
    /// on the open piece. Nothing while a check is still arriving.
    ///
    /// `statementDoor` is the window's statement door
    /// (`DocumentStore.posture(ofStatement:scope:statements:)`), asked here —
    /// once, with the scope the answer writes — rather than at the call site.
    static func findingOffers(_ item: ResolveItem, mayAct: Bool, posture: Posture,
                              statementDoor: (Statement.Kind, Statement.Scope) -> Posture,
                              durable: Bool) -> (answer: Bool, promote: Bool) {
        guard case .finding(let docId, let finding) = item, durable else { return (false, false) }
        let answers = statementDoor(.intent, .document(docId)).allows(.editStatement)
        return ResolveVerbGate.findingVerbs(
            answer: answers && CheckNarrative.offersAnAnswer(finding),
            promote: posture.allows(.task),
            mayAct: mayAct)
    }

    /// **One-gesture Not this on a check's note** (controller ruling, shell
    /// plan 2 Task 7 fix): a note the check minted (`ResolveFilter.source`
    /// `.checks`) on the open piece keeps the wet-ink decline — a reject with
    /// no reason field — where the piece's posture allows `.acceptOrReject`.
    /// Hidden, never disabled; the `Document`'s door refuses a press that
    /// arrives anyway.
    static func offersNotThis(_ item: ResolveItem, localName: String, mayAct: Bool,
                              posture: Posture) -> Bool {
        guard case .note(let note) = item, note.annotation.status == .open,
              ResolveFilter.source(of: item, localName: localName) == .checks
        else { return false }
        return mayAct && posture.allows(.acceptOrReject)
    }

    /// The document the unread dot is about and the list clears: the faces'
    /// piece at a `.piece` scope, else none. The picker's dot and the list's
    /// clear both ask this one function, so a dot never stands over a list
    /// that cannot clear it (risk (c)).
    static func unreadDocId(scope: ResolveScope) -> String? {
        if case .piece(let docId, _) = scope { return docId }
        return nil
    }

    /// The line above the list naming any piece that would not read
    /// (RULING-54).
    static func incompleteLine(_ snapshot: ResolveSnapshot, structure: [StructureItem],
                               figureNames: [String: String]) -> String? {
        ResolveIncompleteness.of(snapshot, structure: structure, figureNames: figureNames)?.message
    }

    enum EmptyState: Equatable {
        /// The faces are an edition, the Canvas, the Inbox or the Palette.
        case outside
        /// A Collection piece that lives in another project.
        case elsewhere
        /// A piece with nothing and no standing check: the cold-start offer.
        case coldStart
        /// Nothing to resolve.
        case nothing
        /// There are items, and the filter hides every one.
        case filteredOut

        var sentence: String {
            switch self {
            case .outside:
                return "To resolve gathers what has been raised about a piece, a Part or the Book: "
                    + "notes, checks, to-dos and questions. Choose one in the tree."
            case .elsewhere:
                return "This piece belongs to another project. Open that project to see what it raises."
            case .coldStart:
                return CheckNarrative.coldStartOfferSentence
            case .nothing:
                return "Nothing to resolve."
            case .filteredOut:
                return "Nothing under this filter."
            }
        }
    }

    static func emptyState(scope: ResolveScope, hasItems: Bool, hasVisible: Bool,
                           offersColdStart: Bool) -> EmptyState? {
        switch scope {
        case .outside: return .outside
        case .elsewhere: return .elsewhere
        case .piece, .pieces, .figure:
            guard !hasItems else { return hasVisible ? nil : .filteredOut }
            return offersColdStart ? .coldStart : .nothing
        }
    }
}

/// **One open piece as its `Document` holds it now** — what a `.live` step
/// splices in: its notes, its open to-dos, its paragraph order, its text.
struct ResolveLivePiece: Equatable {
    /// Every status: the open ones list, the rest serve the stet hold.
    let notes: [Annotation]
    let todos: [WriterTask]
    let sequence: [String]
    let paragraphs: [String: String]
}
