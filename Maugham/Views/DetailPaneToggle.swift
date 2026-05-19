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
            Image(systemName: "info.circle").tag(DetailSegment.inspector)
            Image(systemName: "checklist").tag(DetailSegment.annotations)
            Image(systemName: "doc.text.magnifyingglass").tag(DetailSegment.research)
            if !hideOutline {
                Image(systemName: "list.bullet.indent").tag(DetailSegment.outline)
            }
            Image(systemName: "clock.arrow.circlepath").tag(DetailSegment.history)
                .keyboardShortcut("4", modifiers: [.command, .option])
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
            ContentUnavailableView(
                "Annotations pane coming online",
                systemImage: "checklist")
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
        }
    }

    @ViewBuilder
    private var historyPane: some View {
        if let url = projectURL {
            CheckpointBrowserPane(
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
        }
    }
}
