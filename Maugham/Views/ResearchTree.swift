import SwiftUI
import MaughamCore
import UniformTypeIdentifiers

/// Shared recursive research tree node used by ResearchView (novel/short
/// story/screenplay) and CollectionResearchPane (per-section). Extracted so
/// collections get real nesting + drop-into-group instead of the flat fork
/// that made groups decorative (2026-07-16 research-restructuring spec).
struct ResearchTreeActions {
    var rename: (String, String) -> Void
    var internalDrop: (_ draggedId: String, _ position: DropIntent.Position, _ target: ResearchItem) -> Void
    var externalDrop: (_ providers: [NSItemProvider], _ position: DropIntent.Position, _ target: ResearchItem) -> Void
    var newNote: (_ parentId: String?) -> Void
    var newGroup: (_ parentId: String?) -> Void
    var addFile: (_ parentId: String?) -> Void
    var addLink: (_ parentId: String?) -> Void
    var duplicate: (String) -> Void
    var delete: (String) -> Void
}

struct ResearchTreeNode: View {
    let item: ResearchItem
    @Binding var renamingItemId: String?
    let findParentId: (String) -> String?
    let actions: ResearchTreeActions

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
                actions: actions))
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
            })
            .tag(item.id)
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
                Button("Duplicate") { actions.duplicate(item.id) }
                Button("Rename") { renamingItemId = item.id }
                Button("Delete", role: .destructive) { actions.delete(item.id) }
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
        var ordered: [String] = []
        func walk(_ items: [ResearchItem]) {
            for item in items {
                if selection.contains(item.id) { ordered.append(item.id) }
                if let children = item.children { walk(children) }
            }
        }
        walk(research)
        return ordered
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
}
