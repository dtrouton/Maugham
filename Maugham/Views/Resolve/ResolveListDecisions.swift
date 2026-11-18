import SwiftUI
import MaughamCore

// The list's caret reader and its pure decisions, moved out of
// `ResolvePane.swift` so the view reads as a view (shell plan 2 Task 7,
// Task 6 review M9).

// MARK: - The caret

/// **The caret's group, read where it changes.** Mounted only on the open
/// piece at a `.piece` scope. It reads `Document.cursorLocation` itself, so a
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
        let paragraph = ResolvePane.caretParagraph(scope: scope, mayAct: true) {
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
    /// scope, the event token, every open document's versions (a typed to-do
    /// bumps its `tasksVersion` at once), the Book's to-dos, the sidecar, the
    /// passes and the local name.
    static func readKey(scope: ResolveScope, annotationsToken: Int, store: ProjectStore,
                        documentStore: DocumentStore, diagnostics: DiagnosticsStore?,
                        localName: String) -> ResolveReadKey {
        ResolveReadKey(
            scope: scope, annotationsToken: annotationsToken,
            // Open to-dos are NOT the read's: a keystroke on a to-do line
            // moves `tasksVersion`, and that is `ResolveListKey.openTodos`'s
            // cheap splice, never the project's task walk.
            openAnnotationVersions: documentStore.allOpenDocuments().map(\.annotationsVersion),
            projectTasksVersion: store.projectTasksVersion,
            diagnosticsVersion: diagnostics?.version ?? 0,
            passes: store.manifest.effectiveReviewPasses,
            localName: localName)
    }

    /// **Read before regroup.** A read key that moved runs the read (which
    /// also reads the piece's text); a script-only change re-reads the text.
    static func refreshStep(_ key: ResolveListKey, last: ResolveListKey?) -> ResolveRefreshStep {
        guard let last, last.regroup.read == key.regroup.read else { return .read }
        return last.regroup.script == key.regroup.script ? .todos : .reread
    }

    /// The sum of `tasksVersion` over the open pieces the scope holds.
    static func openTodoVersion(scope: ResolveScope, documentStore: DocumentStore) -> Int {
        let inScope = Set(scope.docIds)
        return documentStore.allOpenDocuments()
            .filter { inScope.contains($0.docId) }
            .reduce(0) { $0 &+ $1.tasksVersion }
    }

    /// One refresh step's read. `.read` is `ResolveReader.read` (the walks);
    /// `.reread` the open piece's text, then its live to-dos; `.todos` the
    /// live to-dos alone — `Document.tasks` per open piece in scope.
    static func refreshed(_ held: ResolveSnapshot, step: ResolveRefreshStep, scope: ResolveScope,
                          store: ProjectStore, documentStore: DocumentStore,
                          diagnostics: DiagnosticsStore?) -> ResolveSnapshot {
        switch step {
        case .read:
            return ResolveReader.read(scope: scope, store: store,
                                      documentStore: documentStore, diagnostics: diagnostics)
        case .reread:
            let text = ResolveReader.rereadText(held, scope: scope, store: store,
                                                documentStore: documentStore)
            return splicingTodos(text, order: scope.docIds,
                                 live: liveTodos(scope: scope, documentStore: documentStore))
        case .todos:
            return splicingTodos(held, order: scope.docIds,
                                 live: liveTodos(scope: scope, documentStore: documentStore))
        }
    }

    /// The open in-scope pieces' open to-dos, read off their documents.
    static func liveTodos(scope: ResolveScope, documentStore: DocumentStore) -> [String: [WriterTask]] {
        var live: [String: [WriterTask]] = [:]
        for docId in scope.docIds {
            guard let doc = documentStore.document(forDocId: docId) else { continue }
            live[docId] = doc.tasks(filter: TaskFilter(scope: .document(docId: docId), statuses: [.open]))
        }
        return live
    }

    /// `held` with each piece in `live` holding exactly its live to-dos;
    /// every other item is untouched.
    static func splicingTodos(_ held: ResolveSnapshot, order: [String],
                              live: [String: [WriterTask]]) -> ResolveSnapshot {
        guard !live.isEmpty else { return held }
        let kept = held.items.filter { item in
            if case .todo = item { return live[item.docId] == nil }
            return true
        }
        let fresh = order.flatMap { live[$0] ?? [] }.map(ResolveItem.todo)
        return ResolveSnapshot(items: kept + fresh, sequences: held.sequences,
                               paragraphText: held.paragraphText,
                               unreadableDocIds: held.unreadableDocIds)
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

    /// The caret's paragraph, read only on the open piece at a `.piece`
    /// scope; nil anywhere else, without reading it.
    static func caretParagraph(scope: ResolveScope, mayAct: Bool,
                               read: () -> String?) -> String? {
        guard mayAct, case .piece = scope else { return nil }
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

    /// A finding's verbs: Answer files a ruling (any piece, by the intent's
    /// posture); Promote writes the piece's `Document` (the open piece only).
    /// Nothing while a check is still arriving.
    static func findingOffers(_ item: ResolveItem, mayAct: Bool, posture: Posture,
                              statementAllowsAnswer: Bool,
                              durable: Bool) -> (answer: Bool, promote: Bool) {
        guard case .finding(_, let finding) = item, durable else { return (false, false) }
        return ResolveVerbGate.findingVerbs(
            answer: statementAllowsAnswer && CheckNarrative.offersAnAnswer(finding),
            promote: posture.allows(.task),
            mayAct: mayAct)
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
