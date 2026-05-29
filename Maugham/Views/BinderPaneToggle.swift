import SwiftUI
import MaughamCore

struct BinderPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: BinderSegment
    @Binding var selectedItemId: String?
    @Binding var selectedResearchId: String?
    let projectType: ProjectType
    let lastParsedScript: FountainScript?
    @Binding var findActive: Bool

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
                if !store.trashEntries.isEmpty {
                    Text("Trash").tag(BinderSegment.trash)
                }
                if findActive {
                    Text("Find").tag(BinderSegment.find)
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
                case .trash:
                    TrashView(store: store)
                case .find:
                    ProjectSearchView(store: store, isActive: $findActive)
                }
            }
            // Show the Exports footer alongside manuscript / scenes only —
            // it's a publishing-pipeline surface, not relevant to Research /
            // Trash / Find.
            if (segment == .manuscript || segment == .scenes)
                && PublishStarter.isInitialized(in: store.url) {
                Divider()
                ExportsListView(projectURL: store.url)
            }
        }
        .onChange(of: store.trashEntries.count) { _, newValue in
            if newValue == 0 && segment == .trash {
                segment = projectType == .screenplay ? .scenes : .manuscript
            }
        }
        .onChange(of: findActive) { _, newValue in
            if !newValue && segment == .find {
                segment = projectType == .screenplay ? .scenes : .manuscript
            }
        }
    }
}
