import SwiftUI
import MaughamCore

struct InspectorLinksSection: View {
    @Bindable var store: ProjectStore
    let currentItemId: String
    @Binding var draftLinks: [String]
    let onCommit: () -> Void
    let onNavigate: (String) -> Void

    @State private var showingAddPopover: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Links")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingAddPopover = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showingAddPopover) {
                        addLinkPopover
                    }
                }
                if draftLinks.isEmpty {
                    Text("No links")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(draftLinks, id: \.self) { id in
                        linkRow(id: id)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Linked from")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if backlinks.isEmpty {
                    Text("No backlinks")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(backlinks, id: \.id) { item in
                        Button {
                            onNavigate(item.id)
                        } label: {
                            HStack {
                                Image(systemName: "arrow.uturn.backward.circle")
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func linkRow(id: String) -> some View {
        HStack {
            Button {
                onNavigate(id)
            } label: {
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    Text(linkedTitle(id: id))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            Button {
                draftLinks.removeAll { $0 == id }
                onCommit()
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
    }

    /// The add-link search — `PieceLinkSearch`, the one search, which the
    /// tree's row menu ("Add Link…") also opens (shell p3 Task 8).
    private var addLinkPopover: some View {
        PieceLinkSearch(
            store: store, currentItemId: currentItemId, existing: draftLinks,
            onPick: { id in
                if !draftLinks.contains(id) {
                    draftLinks.append(id)
                    onCommit()
                }
                showingAddPopover = false
            })
    }

    private var backlinks: [StructureItem] {
        PieceLinks.linkedFrom(currentItemId, in: store.manifest.structure)
    }

    private func linkedTitle(id: String) -> String {
        TreeWalk.find(id: id, in: store.manifest.structure)?.title
            ?? "(missing)"
    }
}
