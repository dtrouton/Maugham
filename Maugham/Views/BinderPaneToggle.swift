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
    /// **Find, as an overlay of this column** (shell-finish stage 2b Task 1).
    /// `ProjectWindow.treeFindActive` — window state, not segment state, which
    /// is why ⌘⌥F no longer writes `segment` and why the overlay rides through
    /// a persona switch untouched. While it is up, the search panel is the whole
    /// left column; `ProjectSearchView.close()` is the only way down.
    @Binding var treeFindActive: Bool
    /// The window's working mode — decides which segments the picker offers.
    /// Coercion onto this persona's list happens once, centrally, in
    /// `PersonaModifier`; this view only renders.
    let persona: Persona
    /// Opens the palette wall in the centre column — `ProjectWindow`'s
    /// `showsPaletteWall = true` (stage 2b Task 5). Defaulted so tests that
    /// mount this toggle without caring about the wall's door keep compiling.
    var onOpenPaletteWall: () -> Void = {}
    /// The foot disclosure's own expand/collapse flag (shell-finish stage 2b
    /// Task 2) — collapsed by default, private to this view. It is `@State`
    /// rather than threaded in from `ProjectWindow` because nothing outside
    /// this column needs to know or drive it; `TrashDisclosure`'s own
    /// initializer still takes it as a `Binding` so a test can.
    @State private var trashExpanded = false

    var body: some View {
        if treeFindActive {
            // **The overlay REPLACES the column, strip included** (spec: the
            // results replace the tree; Escape restores it — the canvas-dim
            // posture, deliberately entered and deliberately left). Not layered
            // over it: find is no longer a segment, so a strip left visible
            // underneath would offer the writer a way to change what is behind
            // the panel while the panel is what they are looking at.
            ProjectSearchView(store: store)
        } else {
            tree
        }
    }

    private var tree: some View {
        VStack(spacing: 0) {
            // The divider beneath the strip is the picker's own, not this
            // caller's — see `BinderSegmentPicker.body`'s fix-round-1 note.
            // Placing one here too is exactly the ghost-divider defect that
            // fix caught.
            // **`hasTrash` is always `false` since stage 2b Task 2** — Trash is
            // a foot disclosure now, not a segment, so the picker never offers
            // it. `BinderSegmentPicker`'s own `hasTrash` parameter retires with
            // the rest of `BinderSegment` in the kill task; this call site just
            // stops asking it to do anything.
            BinderSegmentPicker(
                segment: $segment,
                persona: persona,
                projectType: projectType,
                hasTrash: false)
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
                    // **Unreachable since stage 2b Task 1** — nothing selects
                    // `.find` any more; find is the overlay above. The arm
                    // stays only because the case is still in the enum, and it
                    // shows the tree rather than an `EmptyView` so a
                    // mis-wiring would show a writer their manuscript rather
                    // than a blank column. Both go in the kill task, with the
                    // case.
                    binderTree
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
            // **The tree's foot** (shell-finish stage 2b Task 2): below the
            // sections, below the Exports footer, below everything — present
            // only while there is something in it. This is Trash's whole home
            // now; the picker never offers it and nothing selects `.trash` any
            // more, so the transient-exit arm that used to live here (return to
            // `persona.binderHome` when the last item left the trash) has
            // nothing left to guard. Find's twin of that arm went the same way
            // in stage 2b Task 1, for the same reason: there is no longer a
            // segment to be ejected FROM.
            if !store.trashEntries.isEmpty {
                Divider()
                TrashDisclosure(store: store, isExpanded: $trashExpanded)
            }
        }
    }

    /// The manuscript tree, shared by `.manuscript` and `.tree`. Extracted
    /// because two arms render it and a second literal is how the two would
    /// come to differ.
    private var binderTree: some View {
        BinderView(store: store, selectedSubject: $selectedSubject,
                   canOpenPaletteWall: canOpenPaletteWall,
                   onOpenPaletteWall: onOpenPaletteWall)
    }

    /// A screenplay's tree, shared by `.scenes` and `.tree` for `binderTree`'s
    /// reason.
    private var sceneNavigator: some View {
        SceneNavigatorPane(
            store: store,
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
            },
            canOpenPaletteWall: canOpenPaletteWall,
            onOpenPaletteWall: onOpenPaletteWall)
    }

    /// The wall's own door, guarded on the PERSONA being Plan (stage 2b Task
    /// 5's contract) rather than the segment — `Persona.centresTheCanvas`
    /// doesn't exist yet (Task 6), and `persona` is directly in scope here, so
    /// there is no need for the `binderSegment.centresTheCanvas` proxy a site
    /// without it would have to fall back on.
    private var canOpenPaletteWall: Bool { persona != .plan }
}
