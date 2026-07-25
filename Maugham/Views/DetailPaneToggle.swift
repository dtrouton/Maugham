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
    /// Editor control model — supplies the active translation language and the
    /// per-paragraph freshness entries the Translation segment reads (ADR 0017).
    /// Optional so callers that don't surface translation review can omit it.
    let editorControl: EditorControl?
    @ViewBuilder var inspectorContent: () -> Inspector

    /// Local transcription exists only on Apple Silicon (see DocumentStore.makeTranscriber).
    private static var localTranscriptionAvailable: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

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
        editorControl: EditorControl? = nil,
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
        self.editorControl = editorControl
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
        .task {
            // Populate the inbox count so the unread badge is live from window
            // open, before the writer ever visits the inbox segment. Presenter
            // changes (.inbox arm) keep it fresh thereafter.
            await store.documentStore?.inboxStore.refresh()
        }
        .onAppear {
            // If we land on outline in a hide-outline context, coerce to inspector.
            if hideOutline && segment == .outline {
                segment = .inspector
            }
        }
    }

    /// New (`.new`) inbox captures awaiting triage — drives the picker badge.
    /// The unread badge is the discoverability signal for the async phone→Mac
    /// capture loop: without it, captures that sync in while the writer is
    /// heads-down go unnoticed in a six-segment picker.
    private var inboxCount: Int {
        store.documentStore?.inboxStore.entries.count ?? 0
    }

    // MARK: - Picker

    @ViewBuilder
    private var segmentPicker: some View {
        Picker("Right pane", selection: $segment) {
            Image(systemName: "info.circle")
                .tag(DetailSegment.inspector)
                .help("Inspector — document metadata, tags, links (⌘⌥I)")
            Image(systemName: "text.bubble")
                .tag(DetailSegment.annotations)
                .help("Annotations — review Claude's comments and suggested edits (⌘⌥A)")
            Image(systemName: "doc.text.magnifyingglass")
                .tag(DetailSegment.research)
                .help("Research — this document's own and linked research (⌘⌥R)")
            if !hideOutline {
                Image(systemName: "list.bullet.indent")
                    .tag(DetailSegment.outline)
                    .help("Outline — table or corkboard structure view (⌘⌥O)")
            }
            Image(systemName: "clock.arrow.circlepath")
                .tag(DetailSegment.history)
                .help("History — read-only timeline of edits, annotations, and checkpoints (⌘⌥H)")
            Image(systemName: "checklist.checked")
                .tag(DetailSegment.tasks)
                .help("Tasks — todos in this document and across the project (⌘⌥T)")
            Image(systemName: "tray")
                .tag(DetailSegment.inbox)
                .help("Inbox — triage captures from MaughamPhone (⌘⌥B)")
            Image(systemName: "paintpalette")
                .tag(DetailSegment.palette)
                .help("Palette Card (⌘⌥P)")
            Image(systemName: "character.book.closed")
                .tag(DetailSegment.translation)
                .help("Translation — source text and translator queries (⌘⌥L)")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // Unread badge over the inbox segment. SwiftUI's segmented Picker can't
        // badge a segment directly, so we overlay top-trailing and shift left by
        // TWO equal-width segments: inbox is the THIRD-to-last tab (palette
        // and translation follow it). Anchored on the bare picker (before
        // padding) so the width the GeometryReader measures divides evenly across
        // the segments. Hidden at zero; capped at 99+.
        .overlay(alignment: .topTrailing) {
            if inboxCount > 0 {
                GeometryReader { geo in
                    let segmentCount = hideOutline ? 8 : 9
                    let segmentWidth = geo.size.width / CGFloat(segmentCount)
                    inboxBadge
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: -2 * segmentWidth)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var inboxBadge: some View {
        Text(inboxCount > 99 ? "99+" : "\(inboxCount)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.red, in: Capsule())
            .padding(.trailing, 10)
            .padding(.top, 2)
            .allowsHitTesting(false)
            .help("\(inboxCount) new capture\(inboxCount == 1 ? "" : "s") in the inbox (⌘⌥B)")
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
        case .palette:
            PalettePane(store: store)
        case .translation:
            translationPane
        }
    }

    @ViewBuilder
    private var translationPane: some View {
        if let ds = documentStore,
           let control = editorControl,
           let docId = activeDocId,
           docId != "__no-selection__",
           let doc = ds.document(forDocId: docId) {
            TranslationReviewPane(document: doc, control: control)
        } else {
            ContentUnavailableView(
                "Select a document",
                systemImage: "character.book.closed",
                description: Text("Open a manuscript and enter translation review to reply to translator queries."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var inboxPane: some View {
        if let ds = documentStore {
            InboxPane(store: ds.inboxStore, projectStore: store,
                      activeDocumentId: activeManuscriptItemId,
                      canTranscribe: Self.localTranscriptionAvailable,
                      retranscribe: { entry in Task { await ds.retranscribe(entry) } })
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
