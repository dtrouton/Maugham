import SwiftUI

struct DetailPaneToggle<Inspector: View>: View {
    @Bindable var store: ProjectStore
    @Binding var segment: DetailSegment
    @Binding var outlineLayout: OutlineLayout
    @Binding var selectedItemId: String?
    let activeManuscriptItemId: String?
    @ViewBuilder var inspectorContent: () -> Inspector

    var body: some View {
        VStack(spacing: 0) {
            Picker("Right pane", selection: $segment) {
                Image(systemName: "info.circle").tag(DetailSegment.inspector)
                Image(systemName: "doc.text.magnifyingglass").tag(DetailSegment.research)
                Image(systemName: "list.bullet.indent").tag(DetailSegment.outline)
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
                    OutlinePane(
                        store: store,
                        layout: $outlineLayout,
                        selectedItemId: $selectedItemId)
                }
            }
        }
        .onChange(of: segment) { _, newValue in
            store.documentStore?.updateUIState { $0.detailSegment = newValue }
        }
    }
}
