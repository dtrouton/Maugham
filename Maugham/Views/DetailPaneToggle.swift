import SwiftUI

struct DetailPaneToggle<Inspector: View>: View {
    @Bindable var store: ProjectStore
    @Binding var segment: DetailSegment
    @Binding var outlineLayout: OutlineLayout
    @Binding var selectedItemId: String?
    let activeManuscriptItemId: String?
    let hideOutline: Bool
    // History pane props — optional so callers that don't need history can omit them.
    let projectURL: URL?
    let activeDocId: String?
    let allDocIds: [String]
    let device: String
    let session: String
    let docPaths: [String: String]
    let documentStore: DocumentStore?
    @ViewBuilder var inspectorContent: () -> Inspector

    init(
        store: ProjectStore,
        segment: Binding<DetailSegment>,
        outlineLayout: Binding<OutlineLayout>,
        selectedItemId: Binding<String?>,
        activeManuscriptItemId: String?,
        hideOutline: Bool = false,
        projectURL: URL? = nil,
        activeDocId: String? = nil,
        allDocIds: [String] = [],
        device: String = "",
        session: String = "",
        docPaths: [String: String] = [:],
        documentStore: DocumentStore? = nil,
        @ViewBuilder inspectorContent: @escaping () -> Inspector
    ) {
        self.store = store
        self._segment = segment
        self._outlineLayout = outlineLayout
        self._selectedItemId = selectedItemId
        self.activeManuscriptItemId = activeManuscriptItemId
        self.hideOutline = hideOutline
        self.projectURL = projectURL
        self.activeDocId = activeDocId
        self.allDocIds = allDocIds
        self.device = device
        self.session = session
        self.docPaths = docPaths
        self.documentStore = documentStore
        self.inspectorContent = inspectorContent
    }

    var body: some View {
        VStack(spacing: 0) {
            segmentPicker
            Divider()
            segmentContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: segment) { _, newValue in
            store.documentStore?.updateUIState { $0.detailSegment = newValue }
        }
        .onAppear {
            // If we land on outline in a hide-outline context, coerce to inspector.
            if hideOutline && segment == .outline {
                segment = .inspector
            }
        }
    }

    // MARK: - Picker

    @ViewBuilder
    private var segmentPicker: some View {
        Picker("Right pane", selection: $segment) {
            Image(systemName: "info.circle")
                .tag(DetailSegment.inspector)
                .help("Inspector — document metadata, tags, links (⌘⌥1)")
            Image(systemName: "text.bubble")
                .tag(DetailSegment.annotations)
                .help("Annotations — review Claude's comments and suggested edits (⌘⌥A)")
            Image(systemName: "doc.text.magnifyingglass")
                .tag(DetailSegment.research)
                .help("Linked Research — research notes attached to this document (⌘⌥2)")
            if !hideOutline {
                Image(systemName: "list.bullet.indent")
                    .tag(DetailSegment.outline)
                    .help("Outline — table or corkboard structure view (⌘⌥3)")
            }
            Image(systemName: "clock.arrow.circlepath")
                .tag(DetailSegment.history)
                .help("History — read-only timeline of edits, annotations, and checkpoints (⌘⌥4)")
                .keyboardShortcut("4", modifiers: [.command, .option])
            Image(systemName: "checklist.checked")
                .tag(DetailSegment.tasks)
                .help("Tasks — todos in this document and across the project (⌘⌥5)")
                .keyboardShortcut("5", modifiers: [.command, .option])
            Image(systemName: "tray")
                .tag(DetailSegment.inbox)
                .help("Inbox — triage captures from MaughamPhone (⌘⌥6)")
                .keyboardShortcut("6", modifiers: [.command, .option])
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Content routing

    @ViewBuilder
    private var segmentContent: some View {
        switch segment {
        case .inspector:
            inspectorContent()
        case .annotations:
            annotationsPane
        case .research:
            LinkedResearchPane(
                store: store,
                activeDocumentId: activeManuscriptItemId)
        case .outline:
            if hideOutline {
                inspectorContent()
            } else {
                OutlinePane(
                    store: store,
                    layout: $outlineLayout,
                    selectedItemId: $selectedItemId)
            }
        case .history:
            historyPane
        case .tasks:
            tasksPane
        case .inbox:
            inboxPane
        }
    }

    @ViewBuilder
    private var inboxPane: some View {
        if let ds = documentStore {
            InboxPane(store: ds.inboxStore, projectStore: store)
        } else {
            ContentUnavailableView(
                "Open a project",
                systemImage: "tray",
                description: Text("Captures from MaughamPhone appear here."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var historyPane: some View {
        if let url = projectURL {
            HistoryPane(
                projectURL: url,
                activeDocId: activeDocId ?? "__no-selection__",
                allDocIds: allDocIds,
                device: device,
                session: session,
                docPaths: docPaths,
                documentStore: documentStore
            )
        } else {
            ContentUnavailableView(
                "History unavailable",
                systemImage: "clock.arrow.circlepath"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var annotationsPane: some View {
        if let ds = documentStore,
           let docId = activeDocId,
           docId != "__no-selection__",
           let doc = ds.document(forDocId: docId) {
            AnnotationsPane(document: doc)
        } else {
            ContentUnavailableView(
                "Select a document",
                systemImage: "doc.text",
                description: Text("Open a manuscript to see and act on annotations."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var tasksPane: some View {
        if let ds = documentStore {
            TasksPane(
                store: store,
                documentStore: ds,
                activeDocId: activeDocId,
                projectURL: projectURL)
        } else {
            ContentUnavailableView(
                "Open a project",
                systemImage: "checklist",
                description: Text("Tasks track todos across a project."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
