import SwiftUI
import MaughamCore

struct BinderPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: BinderSegment
    @Binding var selectedItemId: String?
    @Binding var selectedResearchId: String?
    @Binding var selectedPaletteCardId: String?
    let projectType: ProjectType
    let lastParsedScript: FountainScript?
    @Binding var findActive: Bool
    /// The window's working mode — decides which segments the picker offers.
    /// Coercion onto this persona's list happens once, centrally, in
    /// `PersonaModifier`; this view only renders.
    let persona: Persona

    var body: some View {
        VStack(spacing: 0) {
            BinderSegmentPicker(
                segment: $segment,
                persona: persona,
                projectType: projectType,
                hasTrash: !store.trashEntries.isEmpty,
                findActive: findActive)
            Divider()
            Group {
                switch segment {
                case .manuscript:
                    BinderView(store: store, selectedItemId: $selectedItemId)
                case .research, .canvas:
                    // Spec §10: the canvas segment shows the RESEARCH TREE.
                    // Umbrella §6.3 gives Plan a Left surface of "Research
                    // tree", and §8A.1's drag-in route (1C-d) needs the tree
                    // beside the canvas to drag from. The two segments share a
                    // left pane on purpose; the centre column is what differs.
                    ResearchView(store: store, selectedResearchId: $selectedResearchId)
                case .palette:
                    PaletteBinderList(store: store, selectedCardId: $selectedPaletteCardId)
                case .scenes:
                    SceneNavigatorPane(
                        script: lastParsedScript,
                        onSelect: { lineLocation in
                            MaughamEvent.post(
                                .maughamNavigateToScene, to: .keyWindow,
                                payload: ["lineLocation": lineLocation])
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
                segment = .documentHome(for: projectType)
            }
        }
        .onChange(of: findActive) { _, newValue in
            if !newValue && segment == .find {
                segment = .documentHome(for: projectType)
            }
        }
    }
}
