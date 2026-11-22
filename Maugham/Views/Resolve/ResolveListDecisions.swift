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
    /// A request's target, which holds as the caret group until the writer
    /// moves the caret (fix rounds 1 and 2, I2, N1, N2): the groups arriving
    /// after the request's read are not a caret move.
    @Binding var pin: ResolveCaretPin?

    private struct Reading: Equatable {
        let location: Int
        let key: ResolveGroup.Key?
    }

    var body: some View {
        let paragraph = ResolvePane.caretParagraph(scope: scope, openDocId: document.docId,
                                                   mayAct: true) {
            document.paragraphId(at: document.cursorLocation)
        }
        let key = ResolveFilter.cursorGroup(paragraphId: paragraph, docId: document.docId,
                                            sceneIndex: sceneIndex, groups: groups)
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: Reading(location: document.cursorLocation, key: key), initial: true) { _, new in
                let decided = ResolveCaretPin.decide(caretLocation: new.location, caretKey: new.key, pin: pin)
                if pin != decided.pin { pin = decided.pin }
                // Per caret move only the pin's question runs; the list hears
                // of it when the group changes.
                if caretGroup != decided.group { caretGroup = decided.group }
            }
    }
}

/// **A request's target, held as the caret group** (shell p5 Task 2, fix
/// rounds 1 and 2): every request that scrolls — a margin click
/// (`.showParagraph`), a strain mark's jump (`.focusFinding`), a Status
/// count (`.focus`) — lands with the caret where it was, so the pin
/// remembers the caret's place; while it stands the caret reader writes
/// the target and its own scroll stands down, so the request's is the one
/// scroll. Any caret move by the writer — a click back into the text, in
/// the same paragraph or not, an arrow, a keystroke — lets the caret's own
/// group back.
struct ResolveCaretPin: Equatable {
    let key: ResolveGroup.Key
    let caretLocation: Int?

    /// What the caret group is, given the caret's place and its group.
    static func decide(caretLocation: Int?, caretKey: ResolveGroup.Key?,
                       pin: ResolveCaretPin?) -> (group: ResolveGroup.Key?, pin: ResolveCaretPin?) {
        if let pin, pin.caretLocation == caretLocation { return (pin.key, pin) }
        return (caretKey, nil)
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
                        localName: String,
                        presence: ResolvePresence.BookReading? = nil,
                        figureChanges: [ResolveFigureChange]) -> ResolveReadKey {
        let inScope = Set(scope.docIds)
        return ResolveReadKey(
            scope: scope, annotationsToken: annotationsToken,
            openPieces: documentStore.allOpenDocuments().map(\.docId).filter(inScope.contains),
            projectTasksVersion: store.projectTasksVersion,
            diagnosticsVersion: diagnostics?.version ?? 0,
            passes: store.manifest.effectiveReviewPasses,
            localName: localName, presence: presence, figureChanges: figureChanges)
    }

    /// The whole key the view's `.task(id:)` runs on.
    static func listKey(scope: ResolveScope, annotationsToken: Int, store: ProjectStore,
                        documentStore: DocumentStore, diagnostics: DiagnosticsStore?,
                        localName: String, script: FountainScript?,
                        presence: ResolvePresence.BookReading? = nil,
                        figureChanges: [ResolveFigureChange]) -> ResolveListKey {
        ResolveListKey(
            regroup: ResolveRegroupKey(
                read: readKey(scope: scope, annotationsToken: annotationsToken, store: store,
                              documentStore: documentStore, diagnostics: diagnostics,
                              localName: localName, presence: presence,
                              figureChanges: figureChanges),
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
                          walks: inout ResolveWalkHold,
                          presence: ResolvePresence.BookReading? = nil, store: ProjectStore,
                          documentStore: DocumentStore,
                          diagnostics: DiagnosticsStore?) -> ResolveSnapshot {
        let scope = key.scope
        let live = livePieces(scope: scope, documentStore: documentStore)
        switch step {
        case .read:
            guard !scope.docIds.isEmpty || scope.includesBookLevel else { return .empty }
            // **An edition reads its questions from the presence read** (review
            // I4): no annotation or task walk on the main actor per navigation.
            // So does a piece read in a language (shell p4 Task 9).
            if scope.translationLanguage != nil, let presence {
                return ResolveReader.read(
                    scope: scope, annotations: presence.languageNotesSnapshot, tasks: [],
                    live: live, store: store, documentStore: documentStore, diagnostics: diagnostics,
                    figureChanges: key.figureChanges)
            }
            return ResolveReader.read(
                scope: scope,
                annotations: walks.annotations(for: key.walk, store: store),
                tasks: walks.tasks(for: key.tasksWalk, store: store),
                live: live, store: store, documentStore: documentStore, diagnostics: diagnostics,
                // The tree's changed figures, which the key carries.
                figureChanges: key.figureChanges)
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
            case .finding, .translationChange, .glossaryProposal, .designProposal, .compileProblem,
                 .figureSourceChanged:
                return false
            }
        }
        var freshNotes = scope.docIds.flatMap { docId in
            (live[docId]?.notes ?? []).filter { $0.status == .open }
                .map { ResolveItem.note(ProjectAnnotation(docId: docId, annotation: $0)) }
        }
        var freshTodos = scope.docIds.flatMap { live[$0]?.todos ?? [] }.map(ResolveItem.todo)
        // An edition holds its language's questions and no to-do — the one
        // predicate (`ResolveEditionItems.isQuestion`, review M13).
        if let language = scope.translationLanguage {
            let isSource = scope.isSourceEdition
            freshNotes = isSource ? [] : freshNotes.filter { item in
                guard case .note(let note) = item else { return false }
                return ResolveEditionItems.isQuestion(note.annotation, in: language)
            }
            freshTodos = []
        }
        let kept = held.items.filter { !isLive($0) }
        var sequences = held.sequences
        for (docId, piece) in live { sequences[docId] = piece.sequence }
        var text = held.paragraphText
        switch scope {
        case .piece(let docId, _), .pieceInLanguage(let docId, _):
            if let piece = live[docId] { text = piece.paragraphs }
        case .pieces, .figure, .edition, .elsewhere, .outside: break
        }
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
    /// piece's or figure's group — a piece's own, else the first of its owned
    /// figures' (the board counts a piece's figure notes on it). When the
    /// selection hides every item of that group, the filter gives way: small,
    /// to everything; dense, to the source of the group's first item.
    static func apply(_ request: ResolveRequest, groups: [ResolveGroup],
                      sceneIndex: [String: Int]?, chips: [ResolveSource],
                      activePassId: String?, dense: Bool, selection: Set<ResolveSource>,
                      choices: [ResolveGroup.Key: Bool],
                      figureOwners: [String: String?] = [:],
                      localName: String = "") -> ResolveRequestOutcome {
        switch request {
        case .filter(let key):
            let next = ResolveFilter.selection(for: key, chips: chips,
                                               activePassId: activePassId, dense: dense)
            return ResolveRequestOutcome(selection: next ?? selection, choices: choices, scrollTo: nil)
        case .focus(let ownerId):
            guard let key = focusKey(ownerId: ownerId, in: groups, figureOwners: figureOwners),
                  let group = groups.first(where: { $0.key == key }) else {
                return ResolveRequestOutcome(selection: selection, choices: choices, scrollTo: nil)
            }
            var opened = choices
            opened[key] = true
            var shown = selection
            let standing = ResolveFilter.normalized(selection, chips: chips, dense: dense)
            if ResolveFilter.visible(group.items, selection: standing, localName: localName).isEmpty {
                shown = dense
                    ? group.items.first.map { [ResolveFilter.source(of: $0, localName: localName)] } ?? []
                    : []
            }
            return ResolveRequestOutcome(selection: shown, choices: opened, scrollTo: key)
        case .focusFinding(let docId, let itemId):
            return focusFinding(docId: docId, itemId: itemId, groups: groups, chips: chips,
                                activePassId: activePassId, dense: dense, selection: selection,
                                choices: choices, figureOwners: figureOwners, localName: localName)
        case .showParagraph(let docId, let paragraphId):
            return showParagraph(docId: docId, paragraphId: paragraphId, groups: groups,
                                 sceneIndex: sceneIndex, chips: chips, dense: dense,
                                 selection: selection, choices: choices, localName: localName)
        }
    }

    /// **A margin mark's click** (shell p5 Task 2): the paragraph's group —
    /// found by the caret's own rule (`ResolveFilter.cursorGroup`), so a
    /// screenplay's is its scene's — opens, the list scrolls to it, and it
    /// becomes the caret group until the caret itself moves. A filter that
    /// hides every item of it gives way as a focus's does. A paragraph the
    /// list has nothing on changes nothing.
    static func showParagraph(docId: String, paragraphId: String, groups: [ResolveGroup],
                              sceneIndex: [String: Int]?, chips: [ResolveSource], dense: Bool,
                              selection: Set<ResolveSource>, choices: [ResolveGroup.Key: Bool],
                              localName: String) -> ResolveRequestOutcome {
        guard let key = ResolveFilter.cursorGroup(paragraphId: paragraphId, docId: docId,
                                                  sceneIndex: sceneIndex, groups: groups),
              let group = groups.first(where: { $0.key == key }) else {
            return ResolveRequestOutcome(selection: selection, choices: choices, scrollTo: nil)
        }
        var opened = choices
        opened[key] = true
        var shown = selection
        let standing = ResolveFilter.normalized(selection, chips: chips, dense: dense)
        if ResolveFilter.visible(group.items, selection: standing, localName: localName).isEmpty {
            shown = dense
                ? group.items.first.map { [ResolveFilter.source(of: $0, localName: localName)] } ?? []
                : []
        }
        return ResolveRequestOutcome(selection: shown, choices: opened, scrollTo: key)
    }

    /// The line a mark's jump says when its finding is no longer listed:
    /// answered, or replaced by a newer check.
    static let settledFindingLine = "Settled \u{2014} nothing about that sentence waits here now."
    /// The line for a strain that never had an item (the ingest kept the
    /// clause's verdict but had nothing to list for it): nothing was settled.
    static let unlistedStrainLine = "The last check flagged this sentence. There is nothing to act on here."

    /// **A strain mark's jump** (shell plan 3 Task 6). The finding's group
    /// opens, the list scrolls to it and its row is marked; a filter that
    /// hides the row gives way as a focus's does (small: everything; dense:
    /// the finding's own source). A finding no longer listed is settled: the
    /// Checks chip (inert when absent) and the piece's own group, if the list
    /// has one, with `settledFindingLine`. A strain that never had an item
    /// (`itemId == nil`) is not settled: the same chip and group, with
    /// `unlistedStrainLine`.
    static func focusFinding(docId: String, itemId: String?, groups: [ResolveGroup],
                             chips: [ResolveSource], activePassId: String?, dense: Bool,
                             selection: Set<ResolveSource>, choices: [ResolveGroup.Key: Bool],
                             figureOwners: [String: String?] = [:],
                             localName: String = "") -> ResolveRequestOutcome {
        if let itemId,
           let group = groups.first(where: { $0.items.contains { $0.id == itemId } }),
           let item = group.items.first(where: { $0.id == itemId }) {
            var opened = choices
            opened[group.key] = true
            var shown = selection
            let standing = ResolveFilter.normalized(selection, chips: chips, dense: dense)
            if ResolveFilter.visible([item], selection: standing, localName: localName).isEmpty {
                shown = dense ? [ResolveFilter.source(of: item, localName: localName)] : []
            }
            return ResolveRequestOutcome(selection: shown, choices: opened, scrollTo: group.key,
                                         marked: itemId)
        }
        let checks = ResolveFilter.selection(for: .checks, chips: chips,
                                             activePassId: activePassId, dense: dense)
        var opened = choices
        let key = focusKey(ownerId: docId, in: groups, figureOwners: [:])
        if let key { opened[key] = true }
        return ResolveRequestOutcome(selection: checks ?? selection, choices: opened,
                                     scrollTo: key, settled: itemId != nil,
                                     line: itemId == nil ? unlistedStrainLine : settledFindingLine)
    }

    /// The group a piece or a figure owns among the built groups; for a
    /// piece with no group of its own, the first group of a figure it owns.
    static func focusKey(ownerId: String, in groups: [ResolveGroup],
                         figureOwners: [String: String?] = [:]) -> ResolveGroup.Key? {
        let own = groups.first { group in
            switch group.key {
            case .piece(let docId): return docId == ownerId
            case .figure(let id): return id == ownerId
            default: return false
            }
        }?.key
        if let own { return own }
        return groups.first { group in
            if case .figure(let id) = group.key {
                return ProjectStore.countsOn(id, owners: figureOwners) == ownerId
            }
            return false
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
    /// An edition's kinds wear their own lifetimes, in the check's style
    /// (shell p4 Task 6; the design's "Two lifetimes").
    static let replacedByTheNextRoundCaption = "Replaced by this chapter\u{2019}s next round"
    static let replacedByTheNextDesignRoundCaption = "Replaced by the next design round"
    static let replacedByTheNextCompileCaption = "Replaced by the next compile"

    /// The one caption a row may wear: a check-minted note is "From the
    /// check"; a sidecar strain is "Replaced by the next check"; a round's
    /// change or glossary proposal, a design proposal and a compile's problem
    /// each name the run that replaces it.
    static func caption(for item: ResolveItem, localName: String) -> String? {
        switch item {
        case .translationChange, .glossaryProposal: return replacedByTheNextRoundCaption
        case .designProposal: return replacedByTheNextDesignRoundCaption
        case .compileProblem: return replacedByTheNextCompileCaption
        case .finding: return replacedByTheNextCheckCaption
        case .note:
            return ResolveFilter.source(of: item, localName: localName) == .checks
                ? fromTheCheckCaption : nil
        case .todo, .figureSourceChanged: return nil
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
        /// An edition, or a piece read in a language, with nothing waiting
        /// (`ResolveEditionItems.clearLine`, `ResolvePieceInLanguage.clearLine`).
        case editionClear(String)

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
            case .editionClear(let sentence):
                return sentence
            }
        }
    }

    /// `editionClear` is what an edition with nothing in it says
    /// (`ResolveEditionItems.clearLine`); nil anywhere else.
    static func emptyState(scope: ResolveScope, hasItems: Bool, hasVisible: Bool,
                           offersColdStart: Bool, editionClear: String? = nil) -> EmptyState? {
        switch scope {
        case .outside: return .outside
        case .elsewhere: return .elsewhere
        case .edition, .pieceInLanguage:
            guard !hasItems else { return hasVisible ? nil : .filteredOut }
            return editionClear.map(EmptyState.editionClear) ?? .nothing
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
