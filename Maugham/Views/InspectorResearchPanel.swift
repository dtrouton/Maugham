import SwiftUI
import MaughamCore
import AppKit

struct InspectorResearchPanel: View {
    @Bindable var store: ProjectStore
    let item: ResearchItem

    @State private var draftTitle: String = ""
    @State private var draftCaption: String = ""
    @State private var draftTags: String = ""
    @State private var draftURL: String = ""
    @State private var isLoaded: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.type == .group ? "Group" : kindLabel(item.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Title") {
                    TextField("", text: $draftTitle, onCommit: commitTitle)
                        .textFieldStyle(.plain)
                }
                LabeledContent("Caption") {
                    TextEditor(text: $draftCaption)
                        .font(.body)
                        .frame(minHeight: 60)
                        .onChange(of: draftCaption) { _, _ in commitCaption() }
                }
                LabeledContent("Tags") {
                    TextField("comma-separated", text: $draftTags,
                              onCommit: commitTags)
                        .textFieldStyle(.plain)
                }
                if item.kind == .link {
                    LabeledContent("URL") {
                        TextField("", text: $draftURL, onCommit: commitURL)
                            .textFieldStyle(.plain)
                    }
                }
                if item.type != .group {
                    Divider()
                    // Keyed on the item: a selection change makes a fresh
                    // section, so no commit of item A's draft can land on B.
                    InspectorCitationSection(store: store, item: item)
                        .id(item.id)
                    Divider()
                }
                if let added = item.addedAt {
                    LabeledContent("Added") {
                        Text(added, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let path = item.path {
                    LabeledContent("Path") {
                        HStack {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .truncationMode(.middle)
                                .lineLimit(1)
                            Spacer()
                            Button("Show in Finder") {
                                guard let fullURL = try? store.resolvedProjectPath(path)
                                else { return }
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [fullURL])
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(16)
        }
        .task(id: item.id) {
            draftTitle = item.title
            draftCaption = item.caption ?? ""
            draftTags = (item.tags ?? []).joined(separator: ", ")
            draftURL = item.url ?? ""
            isLoaded = true
        }
    }

    private func kindLabel(_ kind: ResearchItem.AssetKind?) -> String {
        switch kind {
        case .image: return "Image"
        case .pdf:   return "PDF"
        case .document: return "Document"
        case .audio: return "Audio"
        case .link:  return "Link"
        case .none:  return "Item"
        }
    }

    private func commitTitle() {
        Task {
            try? await store.updateResearchItem(id: item.id, title: draftTitle)
        }
    }
    private func commitCaption() {
        Task {
            try? await store.updateResearchItem(id: item.id, caption: draftCaption)
        }
    }
    private func commitTags() {
        let tags = draftTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        Task {
            try? await store.updateResearchItem(id: item.id, tags: tags)
        }
    }
    private func commitURL() {
        Task {
            try? await store.updateResearchItem(id: item.id, url: draftURL)
        }
    }
}
