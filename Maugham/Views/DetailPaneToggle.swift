import SwiftUI

struct DetailPaneToggle<Inspector: View>: View {
    @Bindable var store: ProjectStore
    @Binding var segment: DetailSegment
    @Binding var outlineLayout: OutlineLayout
    @Binding var selectedItemId: String?
    let activeManuscriptItemId: String?
    let hideOutline: Bool
    @ViewBuilder var inspectorContent: () -> Inspector

    init(
        store: ProjectStore,
        segment: Binding<DetailSegment>,
        outlineLayout: Binding<OutlineLayout>,
        selectedItemId: Binding<String?>,
        activeManuscriptItemId: String?,
        hideOutline: Bool = false,
        @ViewBuilder inspectorContent: @escaping () -> Inspector
    ) {
        self.store = store
        self._segment = segment
        self._outlineLayout = outlineLayout
        self._selectedItemId = selectedItemId
        self.activeManuscriptItemId = activeManuscriptItemId
        self.hideOutline = hideOutline
        self.inspectorContent = inspectorContent
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Right pane", selection: $segment) {
                Image(systemName: "info.circle").tag(DetailSegment.inspector)
                Image(systemName: "doc.text.magnifyingglass").tag(DetailSegment.research)
                if !hideOutline {
                    Image(systemName: "list.bullet.indent").tag(DetailSegment.outline)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            Group {
                switch segment {
                case .inspector:
                    inspectorContent()
                case .research:
                    LinkedResearchPane(
                        store: store,
                        activeDocumentId: activeManuscriptItemId)
                case .outline:
                    if hideOutline {
                        // Stale outline selection in a hide-outline context — fall back.
                        inspectorContent()
                    } else {
                        OutlinePane(
                            store: store,
                            layout: $outlineLayout,
                            selectedItemId: $selectedItemId)
                    }
                }
            }
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
}
