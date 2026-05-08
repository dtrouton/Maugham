import SwiftUI

struct BinderPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: BinderSegment
    @Binding var selectedItemId: String?
    @Binding var selectedResearchId: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Segment", selection: $segment) {
                Text("Manuscript").tag(BinderSegment.manuscript)
                Text("Research").tag(BinderSegment.research)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            Group {
                switch segment {
                case .manuscript:
                    BinderView(store: store, selectedItemId: $selectedItemId)
                case .research:
                    ResearchView(store: store, selectedResearchId: $selectedResearchId)
                }
            }
        }
    }
}
