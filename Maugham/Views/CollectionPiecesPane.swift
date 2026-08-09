import SwiftUI
import MaughamCore

/// The Pieces segment of a Collection binder. Flat list with kind icons,
/// inline rename support, and a right-click context menu.
struct CollectionPiecesPane: View {
    @Bindable var store: ProjectStore
    @Binding var selectedSubject: BinderSubject?
    @Binding var renamingItemId: String?
    /// The Research and Palette sections' own state (stage-2a Task 4). Owned
    /// here because their presentations hang off this pane, outside the `List`.
    @State private var treeState = BinderTreeSectionsState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pieceList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The row at the head of the pieces list naming the Collection itself
    /// (spec §3.3), and in a Collection the **only** thing that constructs
    /// `BinderSubject.project`: `ProjectWindow.binderColumn` mounts `BinderView`
    /// — which carries the other one — for non-collection projects only.
    ///
    /// **It is a row, not a control**, for the same reason `BinderView`'s is:
    /// its whole implementation is a label and a `.tag`, so `List(selection:)`
    /// matches it against the binding exactly as it matches a piece. Tripwire 9
    /// is why it is neither a `Button` nor an `.onTapGesture` — hit-testing for
    /// either is unreliable inside `List(.sidebar)`.
    ///
    /// **Deliberately none of this pane's own row idioms.** A `PieceRow` is
    /// renamable inline (tripwire 16's focus dance), is a drag source and a drop
    /// target for reordering, and carries a context menu with Rename / Promote /
    /// Delete. The project row is a label: there is no piece order for it to
    /// take part in, and nothing a piece dropped on it could mean.
    private var projectRow: some View {
        ProjectRowLabel(title: store.manifest.title)
            .tag(BinderSubject.project)
    }

    /// One `List`, always — including when the Collection has no pieces.
    ///
    /// **The empty state is an OVERLAY, not a replacement.** It used to replace
    /// the list outright, and with a project row at the list's head that would
    /// mean a Collection with no pieces has no subject it can be given at all —
    /// which is not the rare deleted-the-last-one case it is in a novel:
    /// `ProjectFactory.createCollectionProject` writes an **empty structure**,
    /// so it is what every new Collection opens on, and project-scoped intent is
    /// exactly what a writer wants there first.
    ///
    /// `BinderView` measured the two obvious alternatives on macOS 26.5 and both
    /// failed — a `selectionDisabled()` message row is selected anyway and, with
    /// no `.tag`, writes `nil` through the binding; a `Section` costs a leading
    /// row that moves every index beneath it. Not re-spent here. What was
    /// measured here, because `ContentUnavailableView` is a system view chained
    /// to a full frame rather than `BinderView`'s hand-built `VStack` of glyphs:
    /// the overlay does not take the project row's clicks
    /// (`CollectionProjectRowTests.test_theEmptyStateOverlayDoesNotSwallowAnyRowBeneathIt`
    /// hit-tests it).
    ///
    /// **The selection is a projection, not the binding itself** (stage-2a Task
    /// 4): the sections at the foot of the list carry untagged placeholder rows
    /// when they are empty, and an untagged row writes `nil` through the
    /// binding — the same measurement this pane's empty state is shaped by.
    /// `BinderTreeSelection` refuses that `nil`; every tagged row is unaffected.
    private var pieceList: some View {
        List(selection: BinderTreeSelection.binding($selectedSubject)) {
            projectRow
            ForEach(store.manifest.structure) { piece in
                pieceEntry(for: piece)
            }
            // Below the pieces — furniture at the foot of the column, with the
            // project row still row zero.
            BinderTreeSections(store: store, state: treeState,
                               selectedSubject: $selectedSubject)
        }
        .listStyle(.sidebar)
        .overlay {
            if store.manifest.structure.isEmpty { emptyState }
        }
        .binderTreeSections(store: store, state: treeState,
                            selectedSubject: $selectedSubject)
    }

    /// One piece's row, whole — the modifier chain is unchanged from when it was
    /// written inline inside `pieceList`'s `ForEach`.
    ///
    /// **Extracted for headroom, NOT because the ceiling was reached** — and the
    /// distinction is recorded because a SourceKit report said otherwise
    /// (stage-2a Task 4). After the sections went into `pieceList`, SourceKit
    /// reported *"the compiler is unable to type-check this expression in
    /// reasonable time"* here — the one diagnostic class CLAUDE.md says to heed
    /// rather than triage as noise, since ignoring it shipped a Release-only
    /// build failure on v0.8.0. **`xcodebuild` was then asked directly and did
    /// not agree.** With `-warn-long-expression-type-checking` /
    /// `-warn-long-function-bodies` at 400ms, a Release build of the inline
    /// shape reported nothing anywhere in the app; at 100ms the only two bodies
    /// over the limit were `EditorHost.body` (151ms) and `ProjectWindow.body`
    /// (114ms), and nothing in this file appeared at all. So the report was a
    /// stale index, and the extraction is kept on its own merits: it is
    /// `BinderView.row(for:)`'s shape, and Task 6 grows this same `ForEach`
    /// again with the per-piece research fold.
    ///
    /// **The `.tag` moved out to `pieceEntry(for:)` in Task 6, and only the
    /// tag.** The padding stays inside — it has to be part of the row the List
    /// tags rather than a wrapper around it, which is what the extraction was
    /// careful about — but a folded piece is a `DisclosureGroup` whose LABEL is
    /// this row, and the tag has to be on the group so its children move with
    /// the row they belong to (`BinderView.outline` reached the same shape for
    /// its structure groups). Tagging both would be two names for one row.
    private func pieceRow(for piece: StructureItem) -> some View {
        PieceRow(
            piece: piece,
            renamingItemId: $renamingItemId,
            onRename: { id, newTitle in
                Task {
                    try? await store.renamePiece(
                        pieceId: id, newTitle: newTitle)
                }
            },
            onDrop: { draggedId, position in
                handleDrop(
                    draggedId: draggedId,
                    targetId: piece.id,
                    position: position)
            })
            // Inset under the project row above. Part of the row rather than a
            // wrapper around it, so the List tags a row that is already inset.
            .padding(.leading, ProjectRowLabel.childIndent)
            .contextMenu {
                Button("Rename") {
                    renamingItemId = piece.id
                }
                if piece.pieceKind == .loose {
                    Button("Promote to Standalone Project…") {
                        MaughamEvent.post(.maughamPromotePiece, to: .keyWindow, payload: ["piece_id": piece.id])
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    Task {
                        try? await store.deleteStructureItem(id: piece.id)
                    }
                }
            }
    }

    /// A piece's row, and — when the piece has research of its own — the fold
    /// that research hangs in (stage-2a Task 6).
    ///
    /// **A loose piece's fold is CONTAINMENT**: those items live under
    /// `pieces/<slug>/research/`, so a group in there is a group of this
    /// piece's research and expands like one. A *reference* piece never folds —
    /// its research lives in its own project — and that is not decided here:
    /// `TreeSectionDerivation.pieceFold` asks `ProjectStore.researchRouting`,
    /// the one rule, which refuses a reference piece outright.
    ///
    /// **An empty fold gets no chevron** (`PieceFold.showsDisclosure`) — a
    /// triangle onto nothing on every piece of a new Collection. The row is
    /// still where the first item lands (Task 7's drop target).
    ///
    /// Derived per render from the manifest, never cached (tripwire 4): the
    /// cost is a manifest walk, not a read, and a cached fold would be a second
    /// answer to what a piece's research is.
    @ViewBuilder
    private func pieceEntry(for piece: StructureItem) -> some View {
        let fold = TreeSectionDerivation.pieceFold(
            for: piece,
            structure: store.manifest.structure,
            research: store.manifest.research,
            projectType: store.manifest.type)
        if fold.showsDisclosure {
            DisclosureGroup {
                BinderPieceFold(store: store, state: treeState,
                                selectedSubject: $selectedSubject,
                                documentId: piece.id, fold: fold)
            } label: {
                pieceRow(for: piece)
            }
            .tag(BinderSubject.item(piece.id))
        } else {
            pieceRow(for: piece)
                .tag(BinderSubject.item(piece.id))
        }
    }

    /// Shown when the Collection holds no pieces — an overlay on the list rather
    /// than a replacement for it (see `pieceList`). Tripwire 15: the full-frame
    /// chain is what stops SwiftUI sizing this to its intrinsic content.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No pieces yet", systemImage: "doc.text")
        } description: {
            Text("Add your first piece. Use the + button.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drag-reorder

    private func handleDrop(
        draggedId: String,
        targetId: String,
        position: DropIntent.Position
    ) {
        guard let sourceIdx = store.manifest.structure.firstIndex(where: { $0.id == draggedId }),
              let targetIdx = store.manifest.structure.firstIndex(where: { $0.id == targetId }) else {
            return
        }
        // .top = before target; .bottom/.middle = after target.
        // Pieces don't have children so .middle is treated as .top (just above).
        var destIdx = (position == .bottom) ? targetIdx + 1 : targetIdx
        // If the source is before the target, removing it shifts indices down
        // by 1, so the effective destination index decreases by 1.
        if sourceIdx < destIdx { destIdx -= 1 }
        Task {
            try? await store.movePiece(pieceId: draggedId, toIndex: destIdx)
        }
    }

    private var header: some View {
        HStack {
            Text("Pieces").font(.headline)
            Spacer()
            Menu {
                Button("New Prose Story") {
                    MaughamEvent.post(.maughamAddLoosePiece, to: .keyWindow)
                }
                Button("New Screenplay") {
                    MaughamEvent.post(.maughamAddScreenplayPiece, to: .keyWindow)
                }
                Button("Link Existing Project…") {
                    MaughamEvent.post(.maughamLinkProject, to: .keyWindow)
                }
            } label: {
                Image(systemName: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a piece")
        }
        .padding(8)
    }
}
