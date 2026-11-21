import Foundation
import MaughamCore

/// **When To resolve reads again** (shell plan 2). The view keys its read
/// `.task(id:)` on this value: the sidecar and the reader run once per change
/// of it — never per row, never per caret move, never for a new screenplay
/// parse alone (that is `ResolveRegroupKey`'s), and never for a keystroke, a
/// burst flush, a note minted on an open piece or a verb on one (review C1:
/// those are `ResolveListKey`'s cheap splice off the open piece's `Document`).
///
/// The project walks themselves run only when `walk` moves (`ResolveWalkHold`):
/// a read for any other field gathers over the walks it already holds.
///
/// Every field is an integer or a small value the view already holds; making
/// one is O(open documents), no walk and no stat.
///
/// - `scope`: what the faces name (`.piece(x, false) != .piece(x, true)`).
/// - `annotationsToken`: the view's own counter, bumped on a
///   `.maughamAnnotationsChanged` about a document no window holds open — a
///   closed piece's op log, a figure's stream, a peer's sync
///   (`ResolvePane.annotationsEventMovesTheWalk`). An open piece's own event
///   is ignored: its notes come from its live `Document`.
/// - `openPieces`: the scope's pieces a window holds open, sorted. A piece
///   opening or closing changes where its notes are read from, so it re-walks.
/// - `projectTasksVersion`: `ProjectStore.projectTasksVersion`, the Book's own
///   to-dos (the project op log).
/// - `diagnosticsVersion`: `DiagnosticsStore.version`.
/// - `passes`, `localName`: what the chips depend on
///   (`manifest.effectiveReviewPasses`, the collaborator display name), so a
///   pass added, renamed or reordered, or a new name, refreshes the chips.
struct ResolveReadKey: Equatable {
    let scope: ResolveScope
    let annotationsToken: Int
    let openPieces: [String]
    let projectTasksVersion: Int
    let diagnosticsVersion: Int
    let passes: [ReviewPass]
    let localName: String
    /// **An edition's questions, from the window's presence read** (shell p4
    /// Task 6 fix round, review I4): at an `.edition` scope with a tree
    /// behind the list, the read takes its notes from here — read off the
    /// main actor — and never asks the annotation walk. Nil elsewhere.
    var presence: ResolvePresence.BookReading? = nil

    init(scope: ResolveScope, annotationsToken: Int, openPieces: [String],
         projectTasksVersion: Int, diagnosticsVersion: Int,
         passes: [ReviewPass], localName: String,
         presence: ResolvePresence.BookReading? = nil) {
        self.scope = scope
        self.annotationsToken = annotationsToken
        self.openPieces = Array(Set(openPieces)).sorted()
        self.projectTasksVersion = projectTasksVersion
        self.diagnosticsVersion = diagnosticsVersion
        self.passes = passes
        self.localName = localName
        self.presence = presence
    }

    /// What the annotation walk is re-run on: the real cross-piece signals.
    var walk: ResolveWalkKey {
        ResolveWalkKey(scope: scope, annotationsToken: annotationsToken, openPieces: openPieces)
    }

    /// What the task walk is re-run on: those, and the Book's own to-dos.
    var tasksWalk: ResolveTasksWalkKey {
        ResolveTasksWalkKey(walk: walk, projectTasksVersion: projectTasksVersion)
    }
}

struct ResolveWalkKey: Equatable {
    let scope: ResolveScope
    let annotationsToken: Int
    let openPieces: [String]
}

struct ResolveTasksWalkKey: Equatable {
    let walk: ResolveWalkKey
    let projectTasksVersion: Int
}

/// **The project walks, held between reads** (review C1). The store's own
/// caches are keyed on every open document's versions, so asking them after
/// a keystroke re-derives every closed piece; To resolve asks only when a
/// real cross-piece signal moved (`ResolveReadKey.walk`), and reads the open
/// pieces off their `Document`s in between (`ResolvePane.livePieces`).
struct ResolveWalkHold {
    private(set) var annotations: ProjectAnnotationsSnapshot?
    private var annotationsKey: ResolveWalkKey?
    private(set) var tasks: [WriterTask]?
    private var tasksKey: ResolveTasksWalkKey?

    /// The annotation walk for `key`: held, or asked of the store when the
    /// key moved.
    @MainActor
    mutating func annotations(for key: ResolveWalkKey, store: ProjectStore) -> ProjectAnnotationsSnapshot {
        if let annotations, annotationsKey == key { return annotations }
        let read = store.listAnnotationsAcrossProject()
        annotations = read
        annotationsKey = key
        return read
    }

    /// The open to-dos of the task walk for `key`, held or asked.
    @MainActor
    mutating func tasks(for key: ResolveTasksWalkKey, store: ProjectStore) -> [WriterTask] {
        if let tasks, tasksKey == key { return tasks }
        let read = store.listTasksAcrossProject(filter: TaskFilter(scope: .project, statuses: [.open]))
        tasks = read
        tasksKey = key
        return read
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
