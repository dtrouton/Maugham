import Foundation
import MaughamCore

/// **When To resolve reads and groups again** (shell plan 2). The view keys
/// one `.task(id:)` on this value; the project walks, the reader and the
/// grouping run once per change of it, never per row and never per caret
/// move (tripwire 4).
///
/// - `scope`: what the faces name (`.piece(x, false) != .piece(x, true)`).
/// - `annotationsToken`: the view's own counter, bumped on
///   `.maughamAnnotationsChanged` (the walk's cache is not observable).
/// - `annotationsVersion` / `tasksVersion`: the OPEN piece's
///   `Document.annotationsVersion` and `.tasksVersion`, nil when the faces'
///   piece is not open.
/// - `diagnosticsVersion`: `DiagnosticsStore.version`.
/// - `script`: the window's `lastParsedScript` (from the editor, or
///   `ScreenplayScriptSource.derive`) when the scope is a screenplay's piece,
///   nil otherwise. The scene grouping and the paragraph text it is placed
///   against must refresh together, so a new parse re-reads as well as
///   regroups. `FountainScript`'s equality rejects in O(1) in the common case.
struct ResolveRefreshKey: Equatable {
    let scope: ResolveScope
    let annotationsToken: Int
    let annotationsVersion: Int?
    let tasksVersion: Int?
    let diagnosticsVersion: Int
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
