import Foundation
import MaughamCore

/// **When To resolve reads again** (shell plan 2). The view keys its read
/// `.task(id:)` on this value: the two project walks, the sidecar and the
/// reader run once per change of it — never per row, never per caret move,
/// and never for a new screenplay parse alone (that is `ResolveRegroupKey`'s).
///
/// Every field is an integer or a small value the view already holds; making
/// one is O(open documents) integer adds, no walk and no stat.
///
/// - `scope`: what the faces name (`.piece(x, false) != .piece(x, true)`).
/// - `annotationsToken`: the view's own counter, bumped on
///   `.maughamAnnotationsChanged` (the walk's cache is not observable). That
///   event also fires for any op-log file change of a closed piece, which is
///   what refreshes a closed piece's notes and to-dos.
/// - `openAnnotationsVersion` / `openTasksVersion`: the SUMS of
///   `Document.annotationsVersion` / `.tasksVersion` over every open document
///   (`DocumentStore.allOpenDocuments()`), the open-document half of the task
///   walk's own cache key — so a to-do typed in the open piece refreshes a
///   Book or Part list too. Typing a to-do posts no event.
/// - `projectTasksVersion`: `ProjectStore.projectTasksVersion`, the Book's own
///   to-dos (the project op log).
/// - `diagnosticsVersion`: `DiagnosticsStore.version`.
/// - `passes`, `localName`: what the chips depend on
///   (`manifest.effectiveReviewPasses`, the collaborator display name), so a
///   pass added, renamed or reordered, or a new name, refreshes the chips.
struct ResolveReadKey: Equatable {
    let scope: ResolveScope
    let annotationsToken: Int
    let openAnnotationsVersion: Int
    let openTasksVersion: Int
    let projectTasksVersion: Int
    let diagnosticsVersion: Int
    let passes: [ReviewPass]
    let localName: String

    /// `openVersions` is one `(annotations, tasks)` version pair per open
    /// document; the key keeps their sums (wrapping, as the task cache does).
    init(scope: ResolveScope, annotationsToken: Int,
         openVersions: [(annotations: Int, tasks: Int)],
         projectTasksVersion: Int, diagnosticsVersion: Int,
         passes: [ReviewPass], localName: String) {
        self.scope = scope
        self.annotationsToken = annotationsToken
        self.openAnnotationsVersion = openVersions.reduce(0) { $0 &+ $1.annotations }
        self.openTasksVersion = openVersions.reduce(0) { $0 &+ $1.tasks }
        self.projectTasksVersion = projectTasksVersion
        self.diagnosticsVersion = diagnosticsVersion
        self.passes = passes
        self.localName = localName
    }
}

/// **When To resolve regroups** (shell plan 2): the read key plus the
/// window's parsed screenplay. A change of `script` alone does NOT re-run the
/// walks: the view re-reads only the open piece's paragraph state
/// (`ResolveReader.rereadText`) and regroups over the items it holds.
///
/// `script` is the window's `lastParsedScript` (the editor's, or
/// `ScreenplayScriptSource.derive`'s) when the scope is a screenplay's piece,
/// nil otherwise — decided by capability or an exhaustive switch, never
/// `== .screenplay` (tripwire 55). `FountainScript`'s `==` rejects most
/// UNEQUAL scripts on a few integer checks; two equal scripts in different
/// buffers compare line by line (equal copies of one buffer short-circuit).
struct ResolveRegroupKey: Equatable {
    let read: ResolveReadKey
    let script: FountainScript?
}

/// **"This list may be incomplete"** — what the view shows whenever the
/// snapshot names a piece or figure that would not read (RULING-54). The board
/// shows "unknown" for such a piece; the list beside it must never look
/// complete.
struct ResolveIncompleteness: Equatable {
    let docIds: [String]
    let names: [String]

    var message: String {
        "This list may be incomplete: \(Self.joined(names)) could not be read."
    }

    /// Nil when every piece in scope read. Names come from the manuscript's
    /// tree, or the figure's name; "Untitled" when neither knows the id.
    static func of(_ snapshot: ResolveSnapshot, structure: [StructureItem],
                   figureNames: [String: String]) -> ResolveIncompleteness? {
        guard !snapshot.unreadableDocIds.isEmpty else { return nil }
        let names = snapshot.unreadableDocIds.map { id in
            figureNames[id] ?? TreeWalk.find(id: id, in: structure)?.title ?? "Untitled"
        }
        return ResolveIncompleteness(docIds: snapshot.unreadableDocIds, names: names)
    }

    private static func joined(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
