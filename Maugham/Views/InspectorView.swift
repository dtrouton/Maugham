import SwiftUI
import MaughamCore

struct InspectorView: View {
    @Bindable var store: ProjectStore
    let selectedItemId: String?
    let metrics: EditorMetrics
    let onOpenProjectSettings: () -> Void

    @State private var draftSynopsis: String = ""
    @State private var draftStatus: String = "draft"
    @State private var draftTags: [String] = []
    @State private var draftWordTarget: Int = 0
    @State private var draftPageTarget: Int = 0
    @State private var draftLinks: [String] = []
    @State private var loadedItemId: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var pageTargetSaveTask: Task<Void, Never>?

    var body: some View {
        Form {
            if let item = currentItem, item.type == .document {
                Section("Document") {
                    LabeledContent("Title", value: item.title)
                    Picker("Status", selection: $draftStatus) {
                        Text("Draft").tag("draft")
                        Text("Revising").tag("revising")
                        Text("Final").tag("final")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: draftStatus) { _, _ in scheduleSave() }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Synopsis")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $draftSynopsis)
                            .frame(minHeight: 80)
                            .onChange(of: draftSynopsis) { _, _ in scheduleSave() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        InspectorTagsField(
                            tags: $draftTags,
                            suggestions: tagSuggestions,
                            onCommit: scheduleSave)
                    }

                    LabeledContent("Word target") {
                        HStack(spacing: 6) {
                            TextField("",
                                value: $draftWordTarget,
                                format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                                .onChange(of: draftWordTarget) { _, _ in scheduleSave() }
                            Stepper("",
                                value: $draftWordTarget,
                                in: 0...100_000, step: 100)
                                .labelsHidden()
                            if draftWordTarget == 0 {
                                Text("(no target)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    pageTargetRow()

                    InspectorLinksSection(
                        store: store,
                        currentItemId: item.id,
                        draftLinks: $draftLinks,
                        onCommit: scheduleSave,
                        onNavigate: { id in
                            NotificationCenter.default.post(
                                name: .maughamNavigateToDocument,
                                object: nil,
                                userInfo: ["id": id])
                        })

                    LabeledContent("Words") {
                        Text(wordsLabel)
                            .foregroundStyle(.secondary)
                    }
                }
                if PublishStarter.isInitialized(in: store.url) {
                    Section("Publishing") {
                        InspectorPublishSection(
                            projectURL: store.url,
                            selectedPieceID: item.id)
                    }
                }
            } else if let item = currentItem {
                Section("Group") {
                    LabeledContent("Title", value: item.title)
                    Text("Select a document inside this group to view document fields.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Project") {
                Button("Project Settings…", action: onOpenProjectSettings)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 240, idealWidth: 280)
        .onChange(of: selectedItemId) { _, _ in loadDraftIfNeeded() }
        .task { loadDraftIfNeeded() }
    }

    private var currentItem: StructureItem? {
        guard let id = selectedItemId else { return nil }
        return findItem(id: id, in: store.manifest.structure)
    }

    private var wordsLabel: String {
        let w = metrics.wordCount.formatted(.number)
        return metrics.readingMinutes == 0
            ? "\(w) words"
            : "\(w) words · \(metrics.readingMinutes) min read"
    }

    private func loadDraftIfNeeded() {
        guard let item = currentItem,
              loadedItemId != item.id else { return }
        draftSynopsis = item.synopsis ?? ""
        draftStatus = item.status ?? "draft"
        draftTags = item.tags ?? []
        draftWordTarget = item.wordTarget ?? 0
        draftLinks = item.links ?? []
        loadedItemId = item.id
        draftPageTarget = store.manifest.targets?.pageTarget ?? 0
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let id = loadedItemId
        let synopsis = draftSynopsis
        let status = draftStatus
        let tags = draftTags
        let wordTarget = draftWordTarget
        let links = draftLinks
        saveTask = Task { [weak store] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            guard let store, let id else { return }
            try? await store.updateInspector(
                id: id,
                synopsis: synopsis,
                status: status,
                tags: tags,
                wordTarget: wordTarget,
                links: links)
        }
    }

    private var tagSuggestions: [String] {
        var pool = Set<String>()
        for item in collectAllItems(in: store.manifest.structure) {
            for t in item.tags ?? [] { pool.insert(t) }
        }
        return Array(pool).sorted()
    }

    private func collectAllItems(
        in items: [StructureItem]
    ) -> [StructureItem] {
        var result: [StructureItem] = []
        for item in items {
            result.append(item)
            if let children = item.children {
                result.append(contentsOf: collectAllItems(in: children))
            }
        }
        return result
    }

    private func findItem(id: String, in items: [StructureItem]) -> StructureItem? {
        for item in items {
            if item.id == id { return item }
            if let children = item.children,
               let nested = findItem(id: id, in: children) {
                return nested
            }
        }
        return nil
    }

    @ViewBuilder
    private func pageTargetRow() -> some View {
        if store.manifest.type == .screenplay {
            LabeledContent("Page target") {
                HStack(spacing: 6) {
                    TextField("",
                        value: $draftPageTarget,
                        format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onChange(of: draftPageTarget) { _, _ in
                            schedulePageTargetSave()
                        }
                    Stepper("",
                        value: $draftPageTarget,
                        in: 0...500, step: 5)
                        .labelsHidden()
                    if draftPageTarget == 0 {
                        Text("(no target)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func schedulePageTargetSave() {
        pageTargetSaveTask?.cancel()
        let value = draftPageTarget
        pageTargetSaveTask = Task { [weak store] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            guard let store else { return }
            try? await store.updateProjectTargets(pageTarget: value)
        }
    }
}
