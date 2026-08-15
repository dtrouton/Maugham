import Foundation
import MaughamCore

/// Pure array transforms behind the Review Passes editor
/// (`ProjectSettingsSheet`, M3 P1 Task 9). No store, no view — the sheet
/// mutates a working `[ReviewPass]` through these and Saves the whole array
/// via `ProjectStore.setReviewPasses`. Kept separate so add/rename/delete/
/// reorder are testable without mounting a `Form`.
enum ReviewPassEditorLogic {

    /// Add a new pass named `name`, minting an id from `Slugifier.slug(from:)`
    /// and uniquifying it against every id already in `passes` via
    /// `ProjectStore.dedupedName` — the same collision-avoidance every other
    /// name→id mint in the app uses (`FileNaming`, `PieceStyleSlug`). Two
    /// passes added with the same name ("Line edit", "Line edit") get
    /// distinct ids ("line-edit", "line-edit-2"); their `name`s stay equal on
    /// purpose — only `id` needs to be unique.
    static func added(to passes: [ReviewPass], name: String) -> [ReviewPass] {
        let existingIds = Set(passes.map(\.id))
        let base = Slugifier.slug(from: name)
        let id = ProjectStore.dedupedName(base) { existingIds.contains($0) }
        return passes + [ReviewPass(id: id, name: name)]
    }

    /// Rename the pass with `id` to `newName`. The id is a `let` on
    /// `ReviewPass` and this never mints a new one — a rename preserves
    /// identity, which is what lets a piece's recorded `passStates[id]`
    /// survive the pass being renamed under it.
    static func renamed(_ passes: [ReviewPass], id: String, to newName: String) -> [ReviewPass] {
        passes.map { pass in
            guard pass.id == id else { return pass }
            var renamed = pass
            renamed.name = newName
            return renamed
        }
    }

    /// Remove the pass with `id`. Every piece's `passStates[id]` is left
    /// exactly where it was in the manifest — this function (and the store
    /// verb behind it) never touches `StructureItem` — so the states
    /// reappear the moment the same id is added back (the stale-id rule).
    static func deleted(_ passes: [ReviewPass], id: String) -> [ReviewPass] {
        passes.filter { $0.id != id }
    }

    /// Move the pass with `draggedId` to sit immediately before the pass
    /// with `droppedOnId`. A no-op (returns `passes` unchanged) when either
    /// id is missing or they're the same pass — dropping a row on itself
    /// changes nothing.
    static func reordered(_ passes: [ReviewPass], draggedId: String, droppedOnId: String) -> [ReviewPass] {
        guard draggedId != droppedOnId,
              let fromIndex = passes.firstIndex(where: { $0.id == draggedId })
        else { return passes }
        var remaining = passes
        let dragged = remaining.remove(at: fromIndex)
        guard let targetIndex = remaining.firstIndex(where: { $0.id == droppedOnId }) else {
            return passes
        }
        remaining.insert(dragged, at: targetIndex)
        return remaining
    }
}
