import SwiftUI
import MaughamCore

struct BinderPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var segment: BinderSegment
    @Binding var selectedSubject: BinderSubject?
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
                    binderTree
                case .tree:
                    // Plan's structure segment (spec §3.1): the project's own
                    // manuscript tree, with the canvas still in the centre. Which
                    // tree that is fans out by project type through the ONE
                    // derivation — `type == .screenplay` inline here is the
                    // re-derivation that shipped the 2026-07-02 bug.
                    switch BinderSegment.treePane(for: projectType) {
                    case .binder, .collectionPieces:
                        // `.collectionPieces` cannot arrive: a Collection window
                        // mounts `CollectionBinderPaneToggle` instead. It shares
                        // this arm rather than taking an `EmptyView` so that a
                        // future mis-wiring shows the writer a tree rather than a
                        // blank column.
                        binderTree
                    case .sceneNavigator:
                        sceneNavigator
                    }
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
                    sceneNavigator
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

    /// The manuscript tree, shared by `.manuscript` and `.tree`. Extracted
    /// because two arms render it and a second literal is how the two would
    /// come to differ.
    private var binderTree: some View {
        BinderView(store: store, selectedSubject: $selectedSubject)
    }

    /// A screenplay's tree, shared by `.scenes` and `.tree` for `binderTree`'s
    /// reason.
    private var sceneNavigator: some View {
        SceneNavigatorPane(
            script: lastParsedScript,
            projectTitle: store.manifest.title,
            selectedSubject: $selectedSubject,
            // A screenplay is one `.fountain` (the Phase 3d invariant), so the
            // document its sluglines live in is the project's one document.
            // Derived here, once per render of the pane rather than once per row
            // (tripwire 4), and used only when the subject is the project — a
            // subject that already names an item is left alone.
            documentID: TreeWalk.first(
                in: store.manifest.structure,
                where: { $0.type == .document })?.id,
            onSelect: { lineLocation in
                MaughamEvent.post(
                    .maughamNavigateToScene, to: .keyWindow,
                    payload: ["lineLocation": lineLocation])
            })
    }
}
