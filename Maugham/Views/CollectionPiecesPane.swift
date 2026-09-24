import SwiftUI
import MaughamCore

/// The Pieces segment of a Collection binder. Flat list with kind icons,
/// inline rename support, and a right-click context menu.
struct CollectionPiecesPane: View {
    @Bindable var store: ProjectStore
    @Binding var selectedSubject: BinderSubject?
    @Binding var renamingItemId: String?
    /// The sections' state, owned by the window — see `BinderView.treeState`,
    /// whose doc comment carries the reasoning (stage-3a Task 4).
    let treeState: BinderTreeSectionsState
    /// Threaded to `BinderTreeSections`' Palette header — see its own doc
    /// comment (stage 3b Task 4). Defaulted for the mounted-tree fixtures that
    /// do not care about the wall's door.
    var paletteWallTravels: Bool = false
    var onOpenPaletteWall: () -> Void = {}

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
            // The LABEL LEAF, before `.tag` (tripwire 9), and a mark rather
            // than a gesture — see TreeTravel.swift and BinderView's twin. The
            // project row carries no `.draggable` at all, so there is no
            // drag-interior claim to make here.
            .treeTravelOnDoubleClick(.project)
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
    ///
    /// **And it selects a SET** (stage-2b Task 3): the tree carries the batch
    /// verbs the research panes 2b deletes used to hold. The window's one
    /// subject is derived from that set — see `BinderTreeSelection`.
    private var pieceList: some View {
        // A `ScrollViewReader` around the `List` (stage-3b Task 8) — see
        // `BinderView.body`'s twin comment; the reasoning is not restated here.
        ScrollViewReader { proxy in
            List(selection: BinderTreeSelection.binding(
                    subject: $selectedSubject, state: treeState, store: store)) {
                projectRow
                ForEach(store.manifest.structure) { piece in
                    pieceEntry(for: piece)
                }
                // Below the pieces — furniture at the foot of the column, with
                // the project row still row zero.
                BinderTreeSections(store: store, state: treeState,
                                   selectedSubject: $selectedSubject,
                                   paletteWallTravels: paletteWallTravels,
                                   onOpenPaletteWall: onOpenPaletteWall)
            }
            .listStyle(.sidebar)
            .overlay {
                if store.manifest.structure.isEmpty { emptyState }
            }
            .binderTreeSections(store: store, state: treeState,
                                selectedSubject: $selectedSubject)
            .consumingTreeScrollRequests(proxy, state: treeState)
            // Dev-only diagnostic, inert everywhere else — `TreeScrollProbe.swift`.
            .treeScrollProbe()
        }
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
    /// **The `.tag` AND the inset live on `pieceEntry(for:)`, not here.** Task 6
    /// moved the tag out and left the padding behind, on the reasoning that it
    /// had to be part of the row the List tags rather than a wrapper around it —
    /// and that shipped the indentation bug Denver smoked on 2026-08-08. A
    /// folded piece is a `DisclosureGroup` whose LABEL is this row, and a `List`
    /// propagates a modifier on the GROUP to the rows it unfolds to but not one
    /// on the group's label: with the inset here, the fold's children lost the
    /// piece's 14pt and gained only the outline's 12pt level step, landing 2pt
    /// to the LEFT of the row they belong to. `BinderView.outline` records the
    /// same finding for its structure groups, and `BinderTreeIndentationTests`
    /// is the measurement.
    private func pieceRow(for piece: StructureItem) -> some View {
        PieceRow(
            piece: piece,
            effectiveReviewPasses: store.manifest.effectiveReviewPasses,
            renamingItemId: $renamingItemId,
            onRename: { id, newTitle in
                Task {
                    try? await store.renamePiece(
                        pieceId: id, newTitle: newTitle)
                }
            },
            // **A piece row now receives two kinds of drag** (stage-2a Task 7):
            // another piece, which is this pane's own reorder and unchanged;
            // or a research note, which in a Collection means the note's FILE
            // moves into `pieces/<slug>/research/`. What the drop means is
            // `TreeDropIntent`'s to say, and the row returns its answer — a
            // referenced piece, which keeps research in its own project,
            // bounces the drag rather than swallowing it.
            onDrop: { draggedId, position in
                // A piece the posture may not move is refused by the drop
                // itself (P3c Task 8) — `BinderView`'s rule.
                if let dragged = store.manifest.structure.first(where: { $0.id == draggedId }),
                   !structureVerbs(for: dragged).move {
                    return false
                }
                return treeVerbs.routePieceRowDrop(
                    draggedId: draggedId, documentId: piece.id,
                    structureReorder: {
                        handleDrop(
                            draggedId: draggedId,
                            targetId: piece.id,
                            position: position)
                    })
            },
            // **And a third kind, from outside the app** (stage-2b Task 4): a
            // file dropped on a loose piece is imported into that piece's own
            // `research/`, which is the store verb whose only caller until now
            // was the pane this milestone deletes. A referenced piece bounces.
            onExternalDrop: { providers, position in
                treeVerbs.routeExternalDrop(
                    providers: providers, position: position,
                    target: .pieceRow(piece.id))
            })
            .contextMenu {
                // Only what the posture allows (P3c Task 8) — `BinderView`'s
                // `TreeStructureVerbs`, one decision for both trees. Promoting a
                // piece out of the Collection is structure too.
                let verbs = structureVerbs(for: piece)
                if verbs.rename {
                    Button("Rename") {
                        renamingItemId = piece.id
                    }
                }
                if verbs.move, piece.pieceKind == .loose {
                    Button("Promote to Standalone Project…") {
                        MaughamEvent.post(.maughamPromotePiece, to: .keyWindow, payload: ["piece_id": piece.id])
                    }
                }
                if verbs.delete {
                    Divider()
                    Button("Delete", role: .destructive) {
                        Task {
                            try? await store.deleteStructureItem(id: piece.id)
                        }
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
    ///
    /// **The inset under the project row goes on the whole entry**, so a
    /// folded piece's research moves with the piece it belongs to — see
    /// `pieceRow(for:)` for the measurement, and `BinderView.outline` for the
    /// same shape in the manuscript tree. It is applied here exactly once: a
    /// piece is always at the top level of a Collection, and the fold's own
    /// rows are stepped by the outline's per-level indent on top of this one.
    @ViewBuilder
    private func pieceEntry(for piece: StructureItem) -> some View {
        let fold = TreeSectionDerivation.pieceFold(
            for: piece,
            structure: store.manifest.structure,
            research: store.manifest.research,
            projectType: store.manifest.type)
        if fold.showsDisclosure {
            // Bound for `BinderView.documentEntry`'s reason exactly (stage-3b
            // Task 7): the window's reveal opens a piece's fold, and it can
            // only open a flag it can reach.
            DisclosureGroup(isExpanded: treeState.foldExpansion(of: piece.id)) {
                BinderPieceFold(store: store, state: treeState,
                                selectedSubject: $selectedSubject,
                                documentId: piece.id, fold: fold)
            } label: {
                pieceRow(for: piece)
            }
            .padding(.leading, ProjectRowLabel.childIndent)
            .tag(BinderSubject.item(piece.id))
            // The find manuscript-match scroll target (stage-3b Task 8) —
            // `BinderView.outline`'s comment carries the reasoning.
            .id(BinderSubject.item(piece.id))
        } else {
            pieceRow(for: piece)
                .padding(.leading, ProjectRowLabel.childIndent)
                .tag(BinderSubject.item(piece.id))
                .id(BinderSubject.item(piece.id))
        }
    }

    /// Shown when the Collection holds no pieces — an overlay on the list rather
    /// than a replacement for it (see `pieceList`). Tripwire 15: the full-frame
    /// chain is what stops SwiftUI sizing this to its intrinsic content.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No pieces yet", systemImage: "doc.text")
        } description: {
            Text(Self.emptyDescription(mayStartAPiece: mayStartAPiece))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// **What the empty state tells her she can do** (P3c, controller ruling
    /// AF). The + is drawn only where she may start a piece; pointing at a
    /// button that is not there is the help describing what does not ship.
    /// Where she may not, the pane says where pieces will come from.
    nonisolated static func emptyDescription(mayStartAPiece: Bool) -> String {
        mayStartAPiece
            ? "Add your first piece. Use the + button."
            : "Pieces appear here when the book\u{2019}s author adds them. "
                + "You can read and leave notes on each one."
    }

    // MARK: - Drag-reorder

    /// The tree's research verbs, over this pane's own section state — see
    /// `BinderView.treeVerbs`. One value for the piece rows, the Research
    /// section and every fold, so the three cannot disagree about scope.
    private var treeVerbs: BinderTreeVerbs {
        BinderTreeVerbs(store: store, state: treeState,
                        selectedSubject: $selectedSubject)
    }

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

    /// The pieces' structural verbs, from the window's posture door —
    /// `BinderView.structureVerbs`' twin; no door, no verb (fails closed).
    func structureVerbs(for piece: StructureItem) -> TreeStructureVerbs {
        guard let documentStore = store.documentStore else { return .none }
        return TreeStructureVerbs.decide(
            for: piece, postureOf: { documentStore.posture(forDocId: $0) })
    }

    /// The header's + menu: every item in it starts (or links in) a piece.
    var mayStartAPiece: Bool {
        guard let documentStore = store.documentStore else { return false }
        return TreeStructureVerbs.mayStartAPiece(
            documentStore.posture(forDocId: DocumentClass.projectStreamDocId))
    }

    private var header: some View {
        HStack {
            Text("Pieces").font(.headline)
            Spacer()
            if mayStartAPiece { addMenu }
        }
        .padding(8)
    }

    /// New Prose Story / New Screenplay / Link Existing Project — each adds a
    /// piece, so the menu is the book author's (ruling R3), hidden otherwise.
    private var addMenu: some View {
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
}

// MARK: - Starting a piece from the menu bar (P3c Task 8, ruling X)

/// **The File menu's three piece-adding items and their receiver**, asked the
/// same `.startAPiece` question as the tree's own + (`TreeStructureVerbs`).
enum StartAPieceDoor {

    /// The menu item's enabled state. nil — no project window in front — keeps
    /// the item enabled as it always was: the receiver is already a no-op
    /// there, and greying it would read as broken while a sheet holds focus
    /// (`FocusedRunButtons`' reasoning). Only a window that SAYS it may not
    /// start a piece disables it.
    static func menuIsEnabled(mayStartAPiece: Bool?) -> Bool {
        mayStartAPiece != false
    }

    /// What the window publishes for the menu — the drawing door's answer.
    /// No project store: nil (no window says anything). A store with no door
    /// behind it — the frame between the window dropping its `DocumentStore`
    /// and its `ProjectStore` — says FALSE (fails closed; whole-branch fix
    /// wave, Minor 2).
    @MainActor
    static func drawn(store: ProjectStore?) -> Bool? {
        guard let store else { return nil }
        guard let documentStore = store.documentStore else { return false }
        return TreeStructureVerbs.mayStartAPiece(
            documentStore.posture(forDocId: DocumentClass.projectStreamDocId))
    }

    /// The sentence a refused post is told in.
    static let refusal = "Your part in this book doesn\u{2019}t reach starting a piece "
        + "\u{2014} only an author of the whole book can add one."

    /// **The receiver's door** (ruling I — the SETTLED answer): true where the
    /// piece may be started; otherwise the refusal is posted to the window's
    /// notice channel and false comes back. A stale menu or a keyboard route
    /// reaching the receiver is refused in words, never silently.
    @MainActor
    static func admits(store: ProjectStore) async -> Bool {
        // No door behind the store: nothing is started (fails closed).
        guard let documentStore = store.documentStore else { return false }
        let posture = await documentStore.settledPosture(
            forDocId: DocumentClass.projectStreamDocId)
        guard TreeStructureVerbs.mayStartAPiece(posture) else {
            MaughamEvent.postNotice(refusal, projectURL: store.url)
            return false
        }
        return true
    }
}
