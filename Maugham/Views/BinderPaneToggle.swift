import SwiftUI
import MaughamCore

/// **The left column, for every project type but a Collection.**
///
/// One tree, an Exports footer and the trash's foot — which is the whole of it
/// since shell-finish stage 2b Task 7 took the segment strip. What used to be a
/// picker over `BinderSegment` and a six-arm switch beneath it is now
/// `TreePane(for:)`: Research and Palette are sections at the foot of the tree
/// (`BinderTreeSections`), Trash is the disclosure below them, and Find is an
/// overlay of the whole column.
struct BinderPaneToggle: View {
    @Bindable var store: ProjectStore
    @Binding var selectedSubject: BinderSubject?
    let projectType: ProjectType
    let lastParsedScript: FountainScript?
    /// **Find, as an overlay of this column** (shell-finish stage 2b Task 1).
    /// `ProjectWindow.treeFindActive` — window state, not segment state, which
    /// is why ⌘⌥F moves nothing else and why the overlay rides through a persona
    /// switch untouched. While it is up, the search panel is the whole left
    /// column; `ProjectSearchView.close()` is the only way down.
    @Binding var treeFindActive: Bool
    /// The window's working mode. It no longer decides which SURFACE this
    /// column shows — every persona gets the project's own tree — only whether
    /// the Exports footer and the palette wall's door belong here.
    let persona: Persona
    /// Opens the palette wall in the centre column — `ProjectWindow`'s
    /// `showsPaletteWall = true` (stage 2b Task 5). Defaulted so tests that
    /// mount this toggle without caring about the wall's door keep compiling.
    var onOpenPaletteWall: () -> Void = {}
    /// What a restore in the foot disclosure has to say (RULING-40/42), on its
    /// way to `ProjectWindow.restoreOutcome` — see `TrashView.onRestoreOutcome`
    /// for why the message cannot be shown down here. Defaulted for
    /// `onOpenPaletteWall`'s reason.
    var onRestoreOutcome: (String) -> Void = { _ in }
    /// The foot disclosure's own expand/collapse flag (shell-finish stage 2b
    /// Task 2) — collapsed by default, private to this view. It is `@State`
    /// rather than threaded in from `ProjectWindow` because nothing outside
    /// this column needs to know or drive it; `TrashDisclosure`'s own
    /// initializer still takes it as a `Binding` so a test can.
    @State private var trashExpanded = false

    var body: some View {
        if treeFindActive {
            // **The overlay REPLACES the column** (spec: the results replace the
            // tree; Escape restores it — the canvas-dim posture, deliberately
            // entered and deliberately left).
            ProjectSearchView(store: store)
        } else {
            tree
        }
    }

    private var tree: some View {
        VStack(spacing: 0) {
            Group {
                // Which tree fans out by project type through the ONE
                // derivation — `type == .screenplay` inline here is the
                // re-derivation that shipped the 2026-07-02 bug, and there are
                // two toggles.
                switch TreePane(for: projectType) {
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
            }
            // The Exports footer belongs under the project's manuscript tree in
            // a persona that publishes, and nowhere else — it's a
            // publishing-pipeline surface, not part of arranging structure.
            //
            // **A persona NAME here, where nearly every other gate in this
            // milestone refuses one.** The reason is that the question this gate
            // asks has no derived answer left: the Exports list is about the
            // LEFT column, and since Task 7 all four personas have the same left
            // column, so nothing about the tree can tell them apart. What is
            // left is what the writer is *doing* — a compile-output list is not
            // part of planning — and that is what the persona names. Deriving it
            // from `centresTheCanvas` would say the Exports list is a fact about
            // the centre column, which it is not.
            if persona != .plan && PublishStarter.isInitialized(in: store.url) {
                Divider()
                ExportsListView(projectURL: store.url)
            }
            // **The tree's foot** (shell-finish stage 2b Task 2): below the
            // sections, below the Exports footer, below everything — present
            // only while there is something in it. This is Trash's whole home
            // now; nothing selects a Trash surface any more, so the
            // transient-exit arm that used to live here (return to the persona's
            // binder home when the last item left the trash) has nothing left to
            // guard. Find's twin of that arm went the same way in stage 2b Task
            // 1, for the same reason: there is no longer a segment to be ejected
            // FROM.
            if !store.trashEntries.isEmpty {
                Divider()
                TrashDisclosure(store: store, isExpanded: $trashExpanded,
                                onRestoreOutcome: onRestoreOutcome)
            }
        }
    }

    /// The manuscript tree. Extracted because two arms render it and a second
    /// literal is how the two would come to differ.
    private var binderTree: some View {
        BinderView(store: store, selectedSubject: $selectedSubject,
                   canOpenPaletteWall: canOpenPaletteWall,
                   onOpenPaletteWall: onOpenPaletteWall)
    }

    /// A screenplay's tree.
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
    /// 5's contract): Plan's centre column is the canvas, and the wall taking it
    /// over there is stage 3's call.
    private var canOpenPaletteWall: Bool { persona != .plan }
}
