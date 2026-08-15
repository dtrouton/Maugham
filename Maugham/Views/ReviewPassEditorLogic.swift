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
    ///
    /// **Scope: uniquified against the WORKING array only**, not against
    /// preset ids or ids deleted in past sessions. Through the shipped UI this
    /// cannot collide — the Add button's name is the "New Pass" literal and a
    /// rename never re-mints an id — and a collision with a historical id
    /// would anyway only surface the documented stale-states-reappear rule
    /// (`deleted`'s doc), never corrupt anything.
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

    /// Whether the working list is fit to Save: every pass has a visible name.
    ///
    /// A blank-named pass would persist as a blank column header on the board
    /// and a blank ladder row in both inspectors — a control with no label,
    /// forever, on a surface the writer reads all day (M3 P1's whole-branch
    /// review, deferred-minor adjudication). The guard sits at SAVE rather
    /// than inside `renamed(_:id:to:)` because the sheet's `TextField` binding
    /// writes per keystroke: refusing the empty string mid-edit would snap the
    /// old name back under the writer's cursor the moment they cleared the
    /// field to retype. An EMPTY list is savable — that is the deliberate
    /// delete-all-restores-presets path, and `allSatisfy` on `[]` is true.
    static func isSavable(_ passes: [ReviewPass]) -> Bool {
        passes.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
