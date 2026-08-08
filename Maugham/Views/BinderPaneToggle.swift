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
            // The divider beneath the strip is the picker's own, not this
            // caller's — see `BinderSegmentPicker.body`'s fix-round-1 note.
            // Placing one here too is exactly the ghost-divider defect that
            // fix caught.
            BinderSegmentPicker(
                segment: $segment,
                persona: persona,
                projectType: projectType,
                hasTrash: !store.trashEntries.isEmpty,
                findActive: findActive)
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
            // The Exports footer belongs under the project's manuscript tree and
            // nowhere else — it's a publishing-pipeline surface, not relevant to
            // Research / Palette / Trash / Find.
            //
            // **`documentHome(for:)`, not the `.manuscript || .scenes` union
            // this used to spell.** The union is that helper's answer over two
            // project types at once, so on a screenplay it accepted a segment
            // the screenplay picker does not offer and on a novel it accepted
            // `.scenes` — and a fifth project type would have needed this line
            // edited to stay right. Asking the helper makes that automatic.
            //
            // **Deliberately NOT `BinderSegment.showsManuscriptStatusFooter`**,
            // which reads the same set today. That one is about the CENTRE
            // column and is a switch, because a future segment centring the
            // editor must be asked whether the footer follows. This one is
            // about the LEFT column, and "no Exports list" is the right answer
            // for any segment that is not the manuscript tree — including
            // `.tree`, which IS the manuscript tree but sits in Plan, where a
            // compile-output list is not what the writer is doing.
            if segment == .documentHome(for: projectType)
                && PublishStarter.isInitialized(in: store.url) {
                Divider()
                ExportsListView(projectURL: store.url)
            }
        }
        // **Leaving a transient segment returns the writer to THIS PERSONA's
        // home, not to the manuscript's.**
        //
        // Both of these fire when a state the writer was passing through ends —
        // the trash emptied under them, find closed — and neither names a
        // document. `.documentHome(for:)` was the same value in Author, Review
        // and Publish, whose binder home IS the document home, and in Plan it
        // put a text editor in the centre column of the persona §2 says does not
        // draft: `⌘⌥F`, escape, and the writer is writing the manuscript in
        // Plan. That is Denver's 2026-08-02 ruling, arrived at from the other
        // side — and the answer here is to stop forcing the manuscript rather
        // than to follow it with a persona switch, because a writer who opened
        // find and changed their mind navigated to nothing.
        //
        // `ProjectWindow`'s `.maughamCloseFind` handler carries the same rule:
        // the ✕ button posts it AND clears the flag below, so the two routes out
        // of find must agree.
        .onChange(of: store.trashEntries.count) { _, newValue in
            if newValue == 0 && segment == .trash {
                segment = persona.binderHome(for: projectType)
            }
        }
        .onChange(of: findActive) { _, newValue in
            if !newValue && segment == .find {
                segment = persona.binderHome(for: projectType)
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
