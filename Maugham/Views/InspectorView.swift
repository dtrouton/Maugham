import SwiftUI
import MaughamCore

struct InspectorView: View {
    @Bindable var store: ProjectStore
    let selectedItemId: String?
    let metrics: EditorMetrics
    let onOpenProjectSettings: () -> Void
    /// **What this Mac may offer for the selected document** (P3c Task 6) —
    /// the window's drawing door, asked by the host. Required: a host that
    /// forgot it would draw the ladder's menus for a reviewer.
    let posture: Posture

    @State private var draftSynopsis: String = ""
    @State private var draftTags: [String] = []
    @State private var draftWordTarget: Int = 0
    @State private var draftPageTarget: Int = 0
    @State private var draftLinks: [String] = []
    @State private var loadedItemId: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var pageTargetSaveTask: Task<Void, Never>?

    /// **Who writes which piece** (P3b Task 9). Resolved once per project, off
    /// the main actor, and held here — a row asks it a dictionary question and
    /// nothing reads the registry from `body` (tripwire 4). `.none` until the
    /// read comes back, which is also what a book with one writer in it stays.
    @State private var writers: PieceWriters = .none

    var body: some View {
        Form {
            if let item = currentItem, item.type == .document {
                Section("Document") {
                    LabeledContent("Title", value: item.title)
                    // **Whose piece this is** — drawn only where somebody in
                    // this book is an author of PIECES rather than of the
                    // whole of it. A book with one writer in it, and a book
                    // whose co-authors may each write the whole thing, draw no
                    // row here at all: see `PieceWriters` for why that is the
                    // decision rather than an omission.
                    if let by = writers.sentence(for: item.id) {
                        LabeledContent(PieceWriters.rowTitle, value: by)
                            .accessibilityIdentifier(PieceWriters.rowIdentifier)
                    }
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
                        onSet: passLadderWrite(on: item.id))

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
        // Keyed on the PROJECT, not the selection: who may write in this book
        // is a fact about the folder, so moving between chapters must not cost
        // a registry read apiece.
        .task(id: store.url) { await loadWriters() }
    }

    /// The one registry read this surface makes, through the one door
    /// (`PieceWriters.read`, which detaches). Named rather than inlined so a
    /// test can drive it with no window in the way.
    func loadWriters() async {
        writers = await PieceWriters.read(
            projectURL: store.url,
            pieces: PermitControl.pieces(in: store.manifest.structure))
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
    ///
    /// **And it holds the store STRONGLY for the duration of the write**
    /// (P3b carry C15). It used to capture `[weak store]`, which is right for
    /// the debounced text path below — that one cancels, and a view torn down
    /// mid-debounce has nothing the writer is owed. This one is different in
    /// the way that matters: the choice has already been made, the write is
    /// immediate and unconditional, and a `guard let store else { return }`
    /// reached after the inspector went away is a pass state the writer
    /// SELECTED and Maugham silently dropped. Nothing goes red; the row simply
    /// reads what it read before. The window closing, the persona switching
    /// and the subject moving all tear this view down, and all three can land
    /// in the same turn as the click — so the task keeps the store alive until
    /// its own write has landed, and lets go after.
    func setPass(_ passId: String, to state: PassState?, on itemId: String) {
        Task { [store] in
            try? await store.setPassState(id: itemId, passId: passId, state)
        }
    }

    /// **The ladder's write, where this Mac may rule on the piece's passes —
    /// else none** (P3c Task 6, plan ruling R3: a pass state is probed as *may
    /// you write this piece's text*). `nil` draws the ladder read-only. The
    /// write itself stays unguarded at storage — roles guard the words, not
    /// the binder — so this is the whole of the gate, and it is cooperative.
    func passLadderWrite(on itemId: String) -> ((String, PassState?) -> Void)? {
        guard PassLadder.offersRulings(under: posture) else { return nil }
        return { passId, state in setPass(passId, to: state, on: itemId) }
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
