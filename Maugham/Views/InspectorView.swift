import SwiftUI
import MaughamCore

struct InspectorView: View {
    @Bindable var store: ProjectStore
    let selectedItemId: String?
    let metrics: EditorMetrics
    let onOpenProjectSettings: () -> Void

    @State private var draftSynopsis: String = ""
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
                    // The review section (M3 P1 Task 4). The free-string
                    // draft/revising/final picker that stood here is gone: the
                    // status is now DERIVED from the passes below it.
                    //
                    // **It deliberately does not go through `scheduleSave()`.**
                    // That path exists for the text fields — it debounces 500 ms
                    // and then writes the WHOLE draft back, which is right for a
                    // synopsis being typed and wrong for a discrete choice: a
                    // pass state would land half a second late (invisible on the
                    // board and the swatches meanwhile), a second choice inside
                    // the window would cancel the first, and the write would
                    // carry a draft snapshot taken before the writer touched the
                    // menu. The ladder writes one pass, immediately, through the
                    // verb that names it.
                    PassLadder(
                        item: item,
                        passes: store.manifest.effectiveReviewPasses,
                        onSet: { passId, state in
                            setPass(passId, to: state, on: item.id)
                        })

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
                            MaughamEvent.post(
                                .maughamNavigateToDocument,
                                to: .project(for: store.url),
                                payload: ["id": id])
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

            Section("Intent") {
                IntentAffordanceRow(store: store, selectedItemId: selectedItemId)
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
        return TreeWalk.find(id: id, in: store.manifest.structure)
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
        draftTags = item.tags ?? []
        draftWordTarget = item.wordTarget ?? 0
        draftLinks = item.links ?? []
        loadedItemId = item.id
        draftPageTarget = store.manifest.targets?.pageTarget ?? 0
    }

    /// The ladder's write — named rather than inline so a test can drive the
    /// production body: this Form's pass menus build their `NSMenu` only when
    /// they are opened for real (measured — `itemTitles` is empty at mount and
    /// stays empty through `menu.update()`, a taller window and a second of
    /// pumping), so the menu-item route that drives `PieceInspector`'s ladder
    /// reaches nothing here.
    ///
    /// **It deliberately does not call `scheduleSave()`** — see the call site
    /// for why the debounced whole-draft path is wrong for a discrete choice.
    func setPass(_ passId: String, to state: PassState?, on itemId: String) {
        Task { [weak store] in
            guard let store else { return }
            try? await store.setPassState(id: itemId, passId: passId, state)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let id = loadedItemId
        let synopsis = draftSynopsis
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
                tags: tags,
                wordTarget: wordTarget,
                links: links)
        }
    }

    private var tagSuggestions: [String] {
        var pool = Set<String>()
        for item in TreeWalk.collect(in: store.manifest.structure, where: { _ in true }) {
            for t in item.tags ?? [] { pool.insert(t) }
        }
        return Array(pool).sorted()
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
