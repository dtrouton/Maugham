import SwiftUI

struct BinderPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: BinderSegment
    @Binding var selectedItemId: String?
    @Binding var selectedResearchId: String?
    let projectType: ProjectType
    let lastParsedScript: FountainScript?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Segment", selection: $segment) {
                if projectType == .screenplay {
                    Text("Scenes").tag(BinderSegment.scenes)
                    Text("Research").tag(BinderSegment.research)
                } else {
                    Text("Manuscript").tag(BinderSegment.manuscript)
                    Text("Research").tag(BinderSegment.research)
                }
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
                case .scenes:
                    SceneNavigatorPane(
                        script: lastParsedScript,
                        onSelect: { lineLocation in
                            NotificationCenter.default.post(
                                name: .maughamNavigateToScene,
                                object: nil,
                                userInfo: ["lineLocation": lineLocation])
                        })
                }
            }
        }
    }
}
