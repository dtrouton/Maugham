import SwiftUI
import MaughamCore
import UniformTypeIdentifiers

/// Shared recursive research tree node used by ResearchView (novel/short
/// story/screenplay) and CollectionResearchPane (per-section). Extracted so
/// collections get real nesting + drop-into-group instead of the flat fork
/// that made groups decorative (2026-07-16 research-restructuring spec).
/// A single "Move to ▸" submenu entry: a stable menu identity, a display
/// title (nested groups flattened as "Outer / Inner"), and the typed move
/// destination the store consumes.
struct ResearchMoveMenuTarget: Identifiable {
    let id: String          // stable menu identity, e.g. "shared" / "group-<id>" / "piece-<id>"
    let title: String       // "Shared", "World / Maps", piece title
    let target: ResearchMoveTarget
}

struct ResearchTreeActions {
    var rename: (String, String) -> Void
    /// Returns whether the drop is ACCEPTED. `ResearchRow` returns exactly this
    /// from its `.dropDestination`, so a surface whose routing is not built yet
    /// says `false` and the writer's drag bounces back, rather than being
    /// animated home and silently discarded (fix round 1; see `ResearchRow`).
    var internalDrop: (_ draggedId: String, _ position: DropIntent.Position, _ target: ResearchItem) -> Bool
    /// Returns whether the drop is accepted — see `internalDrop`.
    var externalDrop: (_ providers: [NSItemProvider], _ position: DropIntent.Position, _ target: ResearchItem) -> Bool
    var newNote: (_ parentId: String?) -> Void
    var newGroup: (_ parentId: String?) -> Void
    var addFile: (_ parentId: String?) -> Void
    var addLink: (_ parentId: String?) -> Void
    var duplicate: (String) -> Void
    var delete: (String) -> Void
    /// Ordered ids the context menu should act on for `rowId`: the whole
    /// selection when `rowId` is inside a multi-selection, else just `rowId`.
    var selectionForRow: (_ rowId: String) -> [String]
    /// Valid "Move to" destinations for `forIds` (empty ⇒ hide the submenu).
    var moveTargets: (_ forIds: [String]) -> [ResearchMoveMenuTarget]
    var move: (_ ids: [String], _ target: ResearchMoveTarget) -> Void
    var deleteMany: (_ ids: [String]) -> Void
}

struct ResearchTreeNode<Tag: Hashable>: View {
    let item: ResearchItem
    @Binding var renamingItemId: String?
    let findParentId: (String) -> String?
    let actions: ResearchTreeActions
    /// The value each row tags itself with, for the enclosing `List`'s
    /// selection. `ResearchView`/`CollectionResearchPane` tag bare `item.id`
    /// (their `List` selects over `Set<String>`, unchanged); the binder tree
    /// (Task 4) tags `.research(item.id)` — a `BinderSubject` — instead.
    let tagFor: (ResearchItem) -> Tag

    var body: some View {
        if item.type == .group {
            DisclosureGroup {
                AnyView(childNodes)
            } label: {
                row
            }
        } else {
            row
        }
    }

    private var childNodes: some View {
        ForEach(item.children ?? []) { child in
            AnyView(ResearchTreeNode(
                item: child,
                renamingItemId: $renamingItemId,
                findParentId: findParentId,
                actions: actions,
                tagFor: tagFor))
        }
    }

    private var row: some View {
        ResearchRow(
            item: item,
            renamingItemId: $renamingItemId,
            onRename: actions.rename,
            onDrop: { draggedId, position in
                actions.internalDrop(draggedId, position, item)
            },
            onExternalDrop: { providers, position in
                actions.externalDrop(providers, position, item)
            })  // both pass the bundle's accept/refuse straight back to the row
            .tag(tagFor(item))
            .contextMenu {
                Button("New Note") {
                    actions.newNote(item.type == .group ? item.id : findParentId(item.id))
                }
                if item.type == .group {
                    Button("New Group") { actions.newGroup(item.id) }
                    Button("Add File…") { actions.addFile(item.id) }
                    Button("Add Link…") { actions.addLink(item.id) }
                    Divider()
                }
                let acting = actions.selectionForRow(item.id)
                let targets = actions.moveTargets(acting)
                if !targets.isEmpty {
                    Menu("Move to") {
                        ForEach(targets) { t in
                            Button(t.title) { actions.move(acting, t.target) }
                        }
                    }
                    Divider()
                }
                if acting.count > 1 {
                    Button("Delete \(acting.count) Items", role: .destructive) {
                        actions.deleteMany(acting)
                    }
                } else {
                    Button("Duplicate") { actions.duplicate(item.id) }
                    Button("Rename") { renamingItemId = item.id }
                    Button("Delete", role: .destructive) { actions.delete(item.id) }
                }
            }
    }
}

/// Selection⇄preview sync + drag-expansion rules shared by the two research
/// surfaces. Pure functions — unit-tested in ResearchSelectionTests.
enum ResearchSelectionSync {
    /// The preview pane shows a single item or nothing.
    static func previewId(for selection: Set<String>) -> String? {
        selection.count == 1 ? selection.first : nil
    }

    /// Selection ordered by depth-first manifest tree position (visual order).
    static func orderedSelection(
        _ selection: Set<String>, in research: [ResearchItem]
    ) -> [String] {
        TreeWalk.collect(in: research, where: { selection.contains($0.id) })
            .map(\.id)
    }

    /// Selection with ids that no longer exist in `research` dropped —
    /// post-delete hygiene (2026-07-19 sweep W6): a stale id left behind
    /// drives `previewId(for:)` to a ghost item in the single-preview pane.
    static func pruned(
        _ selection: Set<String>, in research: [ResearchItem]
    ) -> Set<String> {
        selection.intersection(TreeWalk.collectIds(in: research))
    }

    /// Standard Mac behavior: dragging a row inside the selection drags the
    /// whole selection; dragging an unselected row drags just that row.
    static func expandedDragIds(
        draggedId: String, selection: Set<String>, in research: [ResearchItem]
    ) -> [String] {
        guard selection.contains(draggedId), selection.count > 1 else {
            return [draggedId]
        }
        return orderedSelection(selection, in: research)
    }

    /// Insertion index for a batch drop beside `targetId`, computed against
    /// the destination sibling list WITH the moving ids filtered out. This
    /// matches `moveResearchItems(atIndex:)` semantics: the store removes the
    /// whole batch first, then inserts at `destIndex` — so an index taken
    /// against the pre-removal list drifts right by however many moved items
    /// preceded the target. `.top` inserts before the target; `.bottom` and
    /// `.middle` (non-group) insert after. Returns nil when the target is
    /// itself part of the batch or absent from `siblings` (callers treat nil
    /// as append/bail).
    static func postRemovalInsertionIndex(
        targetId: String, position: DropIntent.Position,
        movingIds: [String], siblings: [ResearchItem]
    ) -> Int? {
        let moving = Set(movingIds)
        guard !moving.contains(targetId) else { return nil }
        let remaining = siblings.filter { !moving.contains($0.id) }
        guard let idx = remaining.firstIndex(where: { $0.id == targetId }) else {
            return nil
        }
        return position == .top ? idx : idx + 1
    }

    /// Menu targets for moving `ids`: Shared root, every group (nested titles
    /// flattened as "Outer / Inner"), and — in collections — every loose
    /// piece. Excludes invalid destinations: groups inside a moving group
    /// (cycle), the moving groups themselves (no-op / self), and everything
    /// cross-scope for role-bearing items.
    static func moveTargets(
        forIds ids: [String], manifest: ProjectManifest
    ) -> [ResearchMoveMenuTarget] {
        let movingItems = ids.compactMap { TreeWalk.find(id: $0, in: manifest.research) }
        guard !movingItems.isEmpty else { return [] }
        let movingGroupIds = Set(movingItems.filter { $0.type == .group }.map(\.id))
        let anyRoleBearing = movingItems.contains { $0.role != nil }

        func isInsideMovingGroup(_ id: String) -> Bool {
            movingItems.contains { g in
                g.type == .group && TreeWalk.contains(id: id, in: g.children ?? [])
            }
        }

        var targets: [ResearchMoveMenuTarget] = [
            .init(id: "shared", title: "Shared", target: .sharedRoot)
        ]
        // Groups, flattened titles.
        func walkGroups(_ items: [ResearchItem], prefix: String) {
            for item in items where item.type == .group {
                let title = prefix.isEmpty ? item.title : "\(prefix) / \(item.title)"
                if !movingGroupIds.contains(item.id), !isInsideMovingGroup(item.id) {
                    targets.append(.init(
                        id: "group-\(item.id)", title: title, target: .group(item.id)))
                }
                walkGroups(item.children ?? [], prefix: title)
            }
        }
        walkGroups(manifest.research, prefix: "")
        // Loose pieces (collections).
        if manifest.type == .collection {
            for piece in manifest.structure
                where piece.type == .document && piece.pieceKind == .loose {
                targets.append(.init(
                    id: "piece-\(piece.id)", title: piece.title,
                    target: .piece(piece.id)))
            }
        }
        // Role-bearing selections may only move within their scope — cheapest
        // honest menu: offer nothing (the store would refuse anyway).
        return anyRoleBearing ? [] : targets
    }
}
