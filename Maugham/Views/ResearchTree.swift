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
            .tag(item.id as String?)
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
