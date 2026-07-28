import SwiftUI

/// The right-hand column's `.canvas` arm: the selected region, or the empty
/// state.
///
/// **This exists so `ProjectWindow.body` does not read the model.** Resolving
/// `selectedRegion` in `ProjectWindow`'s helper would put the largest body in
/// the app on the drag loop: `CanvasModel` is `@Observable`, `scene` is one
/// stored property, and every drag frame and every coast frame writes it
/// (`withScene(persist: false)`). Read there, the whole window re-evaluates at
/// 60–120 Hz for the length of every drag. Read *here*, the dependency stops at
/// this leaf. It is tripwire 30's rule — nothing scene-proportional on the frame
/// path — one column over.
struct RegionInspectorPane: View {

    let model: CanvasModel
    let pieces: [RegionInspector.PieceChoice]

    var body: some View {
        if let region = model.selectedRegion {
            RegionInspector(model: model, regionID: region.id, pieces: pieces)
        } else {
            // Tripwire 15: the full-frame chain is required, and so is the
            // enclosing stack's top alignment — `DetailPaneToggle` supplies the
            // second half (`.frame(…, alignment: .top)` on its own VStack).
            // Without both, SwiftUI sizes to intrinsic content, the stack
            // collapses, and the segment picker floats to the middle of the
            // window. It has recurred four or more times; `HistoryPane` is the
            // canonical example.
            ContentUnavailableView("Select a region", systemImage: "square.dashed")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One region, in the inspector: its name, whether it is collapsed, the piece it
/// is bound to, who lives in it and who is only visiting, and the way to delete
/// it.
///
/// **Two data types reach a writer for the first time here** —
/// `CanvasRegion.boundPieceID` (§4.4's bridge, whose consumer is 1A's reference
/// rail and does not exist yet) and `CanvasRegion.isCollapsed` (drawn by the
/// renderer, round-tripped by the codec, and until now settable only by a test).
///
/// **Every commit checks that the value actually moved before mutating.** The
/// label field commits on focus loss as well as on ⌘↩, so the no-op commit is
/// the common case, not the rare one. `CanvasUndo.endGesture` already declines
/// to register an unchanged gesture, so what these guards buy is the rest of it:
/// no snapshot, no queued disk write, and no redraw of the canvas.
///
/// **Tripwire 16 does not apply.** That rule is about an inline rename
/// `TextField` that *appears* inside a `List(selection:)` row and has to win a
/// focus race against the list's own focus pass. This field is always present in
/// a static form; `BinderRow.claimFocus()` has no business here.
struct RegionInspector: View {

    /// A piece the region may be bound to. Ids, not paths — the binding must
    /// survive a rename (tripwire 22's rule, applied to a reference rather than
    /// to a reload trigger).
    struct PieceChoice: Identifiable, Hashable {
        let id: String
        let title: String

        init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// A member of the region, with the title the canvas shows for it — so the
    /// list and the reference chips beside the region name the same cards the
    /// same way.
    struct Row: Identifiable, Hashable {
        let node: CanvasNodeID
        let title: String
        var id: CanvasNodeID { node }
    }

    /// The `Picker` tag standing for "no piece". A sentinel rather than an
    /// optional selection, because a `Picker` whose selection type is `String?`
    /// needs every tag optional-typed and one un-tagged row silently selects
    /// nothing.
    private static let noPieceTag = "\u{0}none"

    let model: CanvasModel
    let regionID: CanvasRegionID
    let pieces: [PieceChoice]

    /// What the writer has typed but not yet committed. Local, so one rename is
    /// one undo step rather than one per keystroke.
    @State private var draftLabel = ""
    @FocusState private var labelFocused: Bool

    /// The member lists, recomputed only when the STRUCTURAL counter moves.
    /// See `MemberRows` for what that costs and why it is not computed in
    /// `body`.
    @State private var memberRows = MemberRows()

    private var region: CanvasRegion? { model.scene.region(regionID) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draftLabel, prompt: Text(CanvasRegion.untitledLabel))
                    .focused($labelFocused)
                    .onSubmit { commitLabel(draftLabel) }
                Toggle("Collapsed", isOn: Binding(
                    get: { region?.isCollapsed ?? false },
                    set: { commitCollapsed($0) }))
                Picker("Piece", selection: Binding(
                    get: { region?.boundPieceID ?? Self.noPieceTag },
                    set: { commitBinding($0 == Self.noPieceTag ? nil : $0) })) {
                        Text("None").tag(Self.noPieceTag)
                        ForEach(pieces) { Text($0.title).tag($0.id) }
                        // A binding whose piece has since been deleted or moved
                        // out of the manuscript. Shown rather than dropped: a
                        // `Picker` with no row matching its selection renders
                        // blank, which reads as "not bound" and invites the
                        // writer to fix a problem they cannot see.
                        if let orphan = boundPieceMissingFromTheManuscript {
                            Text("Missing piece · \(orphan)").tag(orphan)
                        }
                    }
            } header: {
                Text("Region")
            } footer: {
                Text("The cards that live in this region become the pinned "
                     + "references beside the piece when you write it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            memberSection("Lives here", rows: memberRows.residents,
                          empty: "No cards live in this region yet.")
            memberSection("Appears here", rows: memberRows.visitors,
                          empty: "No cards are referenced here.")

            Section {
                Button("Delete Region", role: .destructive) { deleteRegion() }
                Text("The cards stay on the canvas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { draftLabel = region?.label ?? "" }
        // The selection moved to a different region while this view kept its
        // identity — without the re-seed the new region opens showing the old
        // one's name, and the first focus loss renames it to that.
        //
        // The commit above it is belt and braces against an ordering this view
        // does not control. Clicking another region on the canvas both resigns
        // this field's first responder and moves the selection; AppKit resigns
        // synchronously in `mouseDown`, so the focus-loss commit below should
        // already have run against the old id — but if it has not, the re-seed
        // on the next line would overwrite the writer's uncommitted rename and
        // the guard inside `commitLabel` would then swallow it in silence. It
        // commits to `old` for the same reason: by the time this runs,
        // `regionID` is already the region the writer moved TO. Committing
        // twice is free — the second is a no-op.
        .onChange(of: regionID) { old, _ in
            commitLabel(draftLabel, to: old)
            draftLabel = region?.label ?? ""
        }
        // The model's label changed under us: a ⌘Z, or a rename arriving from
        // anywhere else. Skipped while the field has focus, or the re-seed would
        // fight the writer mid-word.
        .onChange(of: region?.label) { _, new in
            guard !labelFocused else { return }
            draftLabel = new ?? ""
        }
        .onChange(of: labelFocused) { _, focused in
            if !focused { commitLabel(draftLabel) }
        }
        // **Tripwire 30's rule, one column over.** Building the member lists is
        // scene-proportional: a `Set` filter over the scene twice, one
        // `chipTitle` per member — which splits that member's WHOLE scrap text
        // on newlines and trims each line — and a sort whose comparator is
        // `localizedStandardCompare`. Computed in `body` it ran on every drag,
        // coast and straighten frame, because `body` reads `model.scene` and
        // every one of those frames writes it. A 30-card region is ~30 whole-text
        // splits and ~150 localized comparisons at 60–120 Hz, and a region drag
        // is exactly when the list is longest.
        //
        // `sceneRevision` exists for this, and membership cannot change except
        // at a structural boundary — a drop bumps it at `.ended`, and every
        // inspector commit bumps it too. `regionID` is the second key because
        // selecting a DIFFERENT region is not a structural change and would
        // otherwise leave the previous region's members on screen.
        //
        // **What goes stale in exchange, on the record:** a row's title is the
        // first line of its scrap, so typing into a card that is a member of the
        // selected region leaves that row's title showing the text as of the last
        // structural bump. It refreshes when the writer leaves the scrap, which
        // is itself a bump (`commitActiveEdit`). Membership, which is what these
        // lists are actually for, cannot go stale at all.
        .onChange(of: currentRowsKey, initial: true) { _, _ in
            memberRows = refreshedRows(from: memberRows)
        }
    }

    @ViewBuilder
    private func memberSection(_ title: String, rows: [Row], empty: String) -> some View {
        Section(title) {
            if rows.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text(row.title).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Button {
                            remove(row.node)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from this region — the card stays on the canvas")
                        // `.help` is a tooltip, not an accessibility label, and
                        // this button's only content is a glyph. Without this a
                        // VoiceOver user meets an unnamed button per row — on a
                        // surface that owns its whole accessibility tree by hand
                        // precisely because §7A.6 calls one non-optional in a
                        // writing tool.
                        .accessibilityLabel("Remove \(row.title) from this region")
                    }
                }
            }
        }
    }

    /// The two member lists, plus the key they were computed at.
    ///
    /// A named type rather than two `@State` arrays so a refresh cannot update
    /// one and forget the other, and so the gate has something to test.
    struct MemberRows: Equatable {
        /// What the rows are keyed on. Both terms are needed: `revision` alone
        /// misses a change of selected region (selection is not structural),
        /// `region` alone misses a drop.
        struct Key: Equatable {
            let revision: Int
            let region: CanvasRegionID
        }

        var key: Key?
        var residents: [Row] = []
        var visitors: [Row] = []
    }

    /// What the rows would be keyed on right now. Read in `body`, which is what
    /// registers `sceneRevision` as a dependency.
    var currentRowsKey: MemberRows.Key {
        MemberRows.Key(revision: model.sceneRevision, region: regionID)
    }

    /// Rebuild the member lists — **but only if the key has moved.**
    ///
    /// The one function both the view and the test drive, so the gate that ships
    /// is the gate that is pinned. The internal check is not redundant with the
    /// `.onChange` that calls it: it is what makes the rule testable without a
    /// SwiftUI host, and it is what a second, careless caller would run into.
    func refreshedRows(from current: MemberRows) -> MemberRows {
        let key = currentRowsKey
        guard current.key != key else { return current }
        return MemberRows(key: key, residents: residents, visitors: visitors)
    }

    // MARK: - What the region holds

    /// §4.3: any region should answer *"which of these live here and which are
    /// visiting"* at a glance. Two lists, because the two are different things —
    /// only residents travel with the region and only residents are bound to its
    /// piece.
    var residents: [Row] {
        rows(CanvasMembership.residents(of: regionID, in: model.scene))
    }

    var visitors: [Row] {
        rows(region?.appearances ?? [])
    }

    /// Ordered by the title the canvas shows, then by id.
    ///
    /// The id tiebreak is not decoration: every empty scrap answers
    /// `chipTitle` with the same placeholder, so title alone leaves a `Set`'s
    /// iteration order deciding the list — a different order on every launch.
    /// Same discipline as `CanvasScene.isBehind`.
    private func rows(_ ids: Set<CanvasNodeID>) -> [Row] {
        ids
            .filter { model.scene.node($0) != nil }
            .map { Row(node: $0,
                       title: CanvasRenderer.chipTitle(for: $0, in: model.scene,
                                                       scraps: model.scraps)) }
            .sorted { a, b in
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return order == .orderedAscending }
                return a.node.raw < b.node.raw
            }
    }

    /// The bound piece id when nothing in the manuscript answers to it.
    private var boundPieceMissingFromTheManuscript: String? {
        guard let bound = region?.boundPieceID,
              !pieces.contains(where: { $0.id == bound }) else { return nil }
        return bound
    }

    // MARK: - Commits

    /// Every one of these goes through `mutateFromInspector`, never `mutate`:
    /// the canvas may be holding "Edit Scrap" open behind us, and a nested
    /// gesture registers nothing at all. Reached by double-clicking a region's
    /// CHROME BAR — which selects the region on click 1 and opens the bracket on
    /// click 2 — and NOT by double-clicking a card, which deselects the region on
    /// its own first click. `CanvasUndo.mutateFromOutsideTheCanvas` has the
    /// mechanism at length.
    ///
    /// Every one of them also bumps the STRUCTURAL counter afterwards. The
    /// canvas draws the region's label, its collapsed state and its members from
    /// inside a `Canvas` draw closure, where a model value is not in SwiftUI's
    /// dependency graph — the counter is mirrored into `CanvasView` and is what
    /// gets the redraw. Nothing else here would: the writer never touched the
    /// canvas, so no `@State` over there moved.
    func commitLabel(_ new: String) {
        commitLabel(new, to: regionID)
    }

    /// Named explicitly, because the one caller that needs it is committing a
    /// rename to the region the writer typed it into *after* `regionID` has
    /// already moved on to the next one.
    func commitLabel(_ new: String, to target: CanvasRegionID) {
        guard let region = model.scene.region(target), region.label != new else { return }
        model.mutateFromInspector("Rename Region") {
            $0.updateRegion(target) { $0.label = new }
        }
        model.bumpSceneRevision()
    }

    func commitCollapsed(_ collapsed: Bool) {
        guard let region, region.isCollapsed != collapsed else { return }
        model.mutateFromInspector(collapsed ? "Collapse Region" : "Expand Region") {
            $0.updateRegion(regionID) { $0.isCollapsed = collapsed }
        }
        model.bumpSceneRevision()
    }

    func commitBinding(_ piece: String?) {
        guard let region, region.boundPieceID != piece else { return }
        model.mutateFromInspector(piece == nil ? "Unbind Region" : "Bind Region") { scene in
            if let piece {
                RegionBinding.bind(regionID, toPiece: piece, in: &scene)
            } else {
                RegionBinding.unbind(regionID, in: &scene)
            }
        }
        model.bumpSceneRevision()
    }

    /// Membership changes only by a deliberate act (§4.2) — this is one, and it
    /// never deletes the card. The canvas owns arrangement, not existence.
    func remove(_ node: CanvasNodeID) {
        guard region?.mentions(node) == true else { return }
        model.mutateFromInspector("Remove from Region") {
            CanvasMembership.leave(node, from: regionID, in: &$0)
        }
        model.bumpSceneRevision()
    }

    /// The same rule ⌫ follows: the region goes and its cards stay (§3.1,
    /// generalised). No `isInGesture` refusal like `CanvasView.deleteSelection`'s
    /// — that guard exists because a KEY can reach the event view mid-drag, and
    /// this button cannot be clicked while the mouse is down on the canvas.
    /// `mutateFromInspector` covers the gesture that *can* be open here.
    func deleteRegion() {
        guard region != nil else { return }
        model.mutateFromInspector("Delete Region") { $0.removeRegion(regionID) }
        // The selection named a region that is no longer in the scene, and every
        // reader resolves it — `CanvasModel.selectedRegion` above all, which is
        // what decides whether this view is on screen at all.
        model.selection = nil
        model.bumpSceneRevision()
    }
}
