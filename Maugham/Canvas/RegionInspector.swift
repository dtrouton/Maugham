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
/// path — one column over. **`selectedLine` joined it in 1C-c1 and is resolved
/// in the same place, for the same reason.**
///
/// **Three arms, resolved through the model's two resolvers rather than by
/// switching on `selection` directly.** A selection is an id and the scene is
/// what says whether it still names anything — `selectedRegion` and
/// `selectedLine` both answer nil for a stale one, so a switch on the raw case
/// would need an else of its own on every arm to say the same thing.
/// **`selectedNode` joined them in 1C-c2** — a card's dedicated arm,
/// `ScrapInspector`.
struct RegionInspectorPane: View {

    let model: CanvasModel
    let pieces: [RegionInspector.PieceChoice]
    /// Deferred manifest lookups for the two arms that name an artifact — see
    /// `PromotedArtifactSection`. Both the card arm and the region arm take
    /// them: a region's mark had no surface at all for one slice.
    let artifactTitle: (String) -> String?
    /// What the writer's binder calls a piece, over the WHOLE structure — the
    /// lookup that tells a piece which is gone from one which is simply not
    /// routable. Both piece-bearing arms take it; see
    /// `ScrapInspector.association`.
    let pieceTitle: (String) -> String?
    let onOpenResearchItem: (String) -> Void

    var body: some View {
        if let region = model.selectedRegion {
            RegionInspector(model: model, regionID: region.id, pieces: pieces,
                            artifactTitle: artifactTitle, pieceTitle: pieceTitle,
                            onOpenResearchItem: onOpenResearchItem)
        } else if let line = model.selectedLine {
            LineInspector(model: model, lineID: line.id)
        } else if let node = model.selectedNode, case .scrap = node.kind {
            // 1C-c2's arm. A card used to land in the empty state below, which
            // was right while a scrap had nothing to say about itself — the
            // promoted mark is what changed that.
            //
            // **The `.scrap` guard is not decoration.** Nothing creates item
            // nodes yet (1C-d owns the drag-in route), but this pane routed
            // EVERY `selectedNode` here, and every sentence in that arm is
            // wrong for a reference: "The words live on the card" and
            // "Promoting takes a copy" describe a scrap, and an item node
            // cannot be promoted at all. An item node falls to the empty state
            // below until 1C-d gives it an arm of its own.
            // The SAME offer the region arm gets — already filtered to the pieces
            // a promotion can be routed to, so the two pickers cannot disagree
            // about what a writer may choose.
            ScrapInspector(model: model, nodeID: node.id, pieces: pieces,
                           artifactTitle: artifactTitle, pieceTitle: pieceTitle,
                           onOpenResearchItem: onOpenResearchItem)
        } else {
            // Tripwire 15: the full-frame chain is required, and so is the
            // enclosing stack's top alignment — `DetailPaneToggle` supplies the
            // second half (`.frame(…, alignment: .top)` on its own VStack).
            // Without both, SwiftUI sizes to intrinsic content, the stack
            // collapses, and the segment picker floats to the middle of the
            // window. It has recurred four or more times; `HistoryPane` is the
            // canonical example.
            ContentUnavailableView("Select something on the canvas",
                                   systemImage: "square.dashed")
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
    ///
    /// **Shared with `ScrapInspector`'s picker**, which is the same control over
    /// the same field one level down the precedence. A second spelling would be
    /// two definitions of "no piece" that a tidy-up could move apart.
    static let noPieceTag = "\u{0}none"

    let model: CanvasModel
    let regionID: CanvasRegionID
    let pieces: [PieceChoice]
    /// Deferred, like the card arm's: it walks the manifest and is called only
    /// when a promoted region is selected. **No default**, deliberately — this
    /// section was missing from this arm for a whole slice, and a default that
    /// answered nil would let it go missing again without a compile error.
    let artifactTitle: (String) -> String?
    /// Deferred, and asked only when the binding names a piece the offer does
    /// not hold. See `ScrapInspector.association` — this is the lookup that
    /// stops the pane calling a piece in the writer's binder "missing".
    let pieceTitle: (String) -> String?
    let onOpenResearchItem: (String) -> Void

    /// What the writer has typed but not yet committed. Local, so one rename is
    /// one undo step rather than one per keystroke.
    @State private var draftLabel = ""
    @FocusState private var labelFocused: Bool

    /// The member lists, recomputed only when the STRUCTURAL counter moves.
    /// See `MemberRows` for what that costs and why it is not computed in
    /// `body`.
    @State private var memberRows = MemberRows()

    private var region: CanvasRegion? { model.scene.region(regionID) }

    /// A region's mark can name a research note **or** a palette card as of
    /// 1C-c2a (spec §6's 2026-07-29 amendment), so the section is handed
    /// `.region` for the NOUN alone and names no kind — see
    /// `PromotedArtifactSection.Subject`, whose region arm said "the palette
    /// card" for a slice after the row had already gained `.researchNote`.
    ///
    /// **`contribution: .none`, named rather than defaulted.** A region has no
    /// contribution record and cannot get one: spec §6.3 puts a record on the
    /// CARDS whose text a promotion folded in, and this is the thing that folds
    /// them. Naming the absence here is what keeps the card arm's half from
    /// going missing behind a default with nothing red — the reason
    /// `artifactTitle` and `onOpenResearchItem` have no defaults either.
    private var provenance: PromotedArtifactSection.Provenance {
        let mark = region?.promotedItemID
        return PromotedArtifactSection.Provenance(
            artifact: PromotedArtifactSection.artifactState(
                promotedItemID: mark, title: mark.flatMap(artifactTitle)),
            contribution: .none)
    }

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
                        // A binding whose piece the offer does not hold — gone
                        // from the project, or in the binder and keeping no
                        // research of its own. Shown rather than dropped: a
                        // `Picker` with no row matching its selection renders
                        // blank, which reads as "not bound" and invites the
                        // writer to fix a problem they cannot see.
                        if let orphan = boundPieceThePickerCannotOffer {
                            Text(orphan.label).tag(orphan.id)
                        }
                    }
            } header: {
                Text("Region")
            } footer: {
                Text(Self.pieceFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            memberSection("Lives here", rows: memberRows.residents,
                          empty: "No cards live in this region yet.")

            // The one section with an add control, because it is the one
            // membership a writer can *declare*. Living here is decided by where
            // the card was dropped (§4.2's deliberate act, and the drop is it);
            // appearing here is a claim about meaning that no gesture can infer.
            Section("Appears here") {
                memberRowsOrEmpty(memberRows.visitors,
                                  empty: "No cards are referenced here.")
                citeControl
            }

            // Above the Promote section, matching the card arm's order: what it
            // already became, then the way to promote it again.
            PromotedArtifactSection(state: provenance, subject: .region,
                                    onOpen: onOpenResearchItem)

            Section {
                Button("Promote…") {
                    // The SAME command the menu item and ⌘⇧↩ post, so the
                    // button and the keystroke cannot drift into behaving
                    // differently. A closure of our own would be a second path.
                    //
                    // Safe from this column, and the reason is worth knowing:
                    // a `.keyWindow` post made from inside a SHEET is dropped,
                    // because the sheet's own window holds key status (the
                    // v0.24.0 "enter does nothing" bug, `TranslationReviewModifier`).
                    // This button is in the project window itself.
                    MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
                }
                Text(Self.promoteCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        // **The candidate list rides the same gate and needs it more**: it is
        // the same work over EVERY node in the scene rather than one region's
        // members, so it grows with the canvas instead of with the region. It is
        // in `MemberRows` for that reason — a second cache with a second key is
        // how a control comes to offer a card that is already listed above it.
        //
        // `CanvasModel.sceneRevision` exists for this, and membership cannot
        // change except at a structural boundary. **The counter this gate reads
        // is the MODEL's**, which is the only one the other column can reach —
        // `CanvasView` keeps a `@State` mirror of it for the accessibility tree
        // and writes that mirror in exactly one place. A structural change on the
        // canvas that bumped only the view's copy would leave these lists frozen,
        // and five of them did for one commit — including the drop-to-join at
        // `handleDrag(.ended)`.
        // `CanvasViewMountingTests.test_aDropIntoARegionReachesThatRegionsInspector`
        // is that premise test; the gate itself is pinned in `RegionBindingTests`,
        // which drives the bump by hand and so cannot see it.
        //
        // **What the writer actually met is below, and it is not the drop.** A
        // card drag opens with a `clickCount: 1` mouse-down, which reassigns
        // `selection` to the card — so the drop tears this pane down and the next
        // one is built with fresh state. The reachable one is the chrome-bar
        // route.
        //
        // `regionID` is the second key because selecting a DIFFERENT region is
        // not a structural change and would otherwise leave the previous
        // region's members on screen.
        //
        // **What goes stale in exchange, on the record:** a row's title is the
        // first line of its scrap, so typing into a card that is a member of the
        // selected region leaves that row's title showing the text as of the last
        // structural bump. It refreshes when the writer leaves the scrap —
        // `CanvasView.commitActiveEdit` bumps the model's counter, so that claim
        // is about the counter this gate actually reads, and
        // `CanvasViewMountingTests.test_leavingAScrapRefreshesTheRegionInspectorItIsSittingBeside`
        // is what makes it a claim rather than a hope.
        //
        // It was neither for one commit: that bump went to the view's copy, and
        // the writer met it through tripwire 32's own repro — double-click a
        // region's CHROME BAR and click 2 mints a scrap and opens "Edit Scrap"
        // without reassigning `selection`, so this pane and its cached rows are
        // still what they are looking at while they type. Every title here froze
        // where it stood when the region was selected. **Not a double-click on a
        // card**: AppKit sends `clickCount: 1` first and that click selects the
        // card, which is what `test_aDoubleClickOnACardDeselectsTheRegion` says.
        //
        // Membership, which is what these lists are actually for, cannot go
        // stale at all.
        .onChange(of: currentRowsKey, initial: true) { _, _ in
            memberRows = refreshedRows(from: memberRows)
        }
    }

    /// **The association has two readers, and the footer used to name only the
    /// one that does not exist yet.** 1A's reference rail is unbuilt (§4.4, and
    /// `RegionBinding.references(forPiece:)` still has no production caller), so
    /// for a whole slice this sentence described nothing the writer could
    /// observe — which is why the smoke report was "I don't see it doing
    /// anything". Since 1C-c2a the same field also decides where a promotion
    /// lands (§6.2), and that half is visible today.
    ///
    /// Held as a constant for `CanvasAccessibility.regionKind`'s reason: a
    /// `Form`'s contents are not inspectable, so this is the only way a test can
    /// read what ships.
    static let pieceFooter =
        "The cards that live in this region become the pinned references beside "
        + "the piece when you write it — and a note promoted from here, or from "
        + "a card that lives here, lands in that piece's research."

    /// **A piece binding stopped being a promotion target in this milestone**
    /// (spec §6's 2026-07-29 amendment: it produces no artifact, and this pane's
    /// own Picker already set the field), and this sentence went on offering it.
    static let promoteCaption =
        "Make a research note or a palette card from what lives here."

    @ViewBuilder
    private func memberSection(_ title: String, rows: [Row], empty: String) -> some View {
        Section(title) { memberRowsOrEmpty(rows, empty: empty) }
    }

    /// Factored out of `memberSection` so the "Appears here" section can put its
    /// add control after the same rows. A second copy of the row body is how the
    /// two lists would drift apart.
    @ViewBuilder
    private func memberRowsOrEmpty(_ rows: [Row], empty: String) -> some View {
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

    /// **The other half of the minus button**, and the only way anything ever
    /// enters "Appears here".
    ///
    /// A `Menu` rather than a `Picker` or a sheet. A `Picker` is the wrong verb:
    /// its binding says *which one is chosen*, and there is no such state here —
    /// citing is an action that happens repeatedly and leaves nothing selected,
    /// so a `Picker` would need a write-only binding with a sentinel it snaps
    /// back to, which is the shape of a bug rather than a control. A sheet is the
    /// right answer when the choice needs search, multi-select or preview, and
    /// none of those is true of a list of card titles on one canvas. A `Menu` is
    /// a button that happens to offer a list — which is exactly the act.
    ///
    /// **It is handed the gated snapshot; it never reads `candidates`.** That
    /// property walks the whole scene, and this is `body` — see `candidates`.
    @ViewBuilder
    private var citeControl: some View {
        switch citeAffordance(from: memberRows) {
        case .explanation(let why):
            Text(why).font(.caption).foregroundStyle(.secondary)
        case .menu(let offer):
            Menu {
                ForEach(offer) { row in
                    Button(row.title) { cite(row.node) }
                }
            } label: {
                Label("Cite a Card", systemImage: "plus.circle")
            }
            .help("Reference a card here without moving it — it keeps its home region")
            // The label carries text, so this is not the icon-only case the
            // remove button is. It is here anyway because "Cite a Card" alone
            // does not say *where*, and this menu is one of two controls in the
            // section that read identically out of context.
            .accessibilityLabel("Cite a card in this region")
        }
    }

    /// What the add control is, right now — a live menu or a sentence saying why
    /// there isn't one.
    ///
    /// **A decision, lifted out of the view so it can be tested.** The rule it
    /// carries is that there must be **no live control onto an empty list**: a
    /// `Menu` that opens on nothing is worse than absent, because it says a thing
    /// is possible and then shows the writer a blank rectangle they cannot tell
    /// from a bug. Left as an `if` inside `citeControl` that rule would be
    /// unreachable from any test that does not host SwiftUI.
    enum CiteAffordance: Equatable {
        case menu([Row])
        case explanation(String)
    }

    /// Takes the snapshot rather than reading `memberRows`, for the same reason
    /// `refreshedRows` does: the one function the view and the test both drive,
    /// so what ships is what is pinned.
    func citeAffordance(from rows: MemberRows) -> CiteAffordance {
        guard !rows.candidates.isEmpty else {
            // The two reasons are different acts for the writer — make a card,
            // or accept that this region already holds the lot — and one message
            // covering both would be wrong half the time.
            return .explanation(model.scene.isEmpty
                ? "There are no cards on the canvas to cite."
                : "Every card on the canvas is already in this region.")
        }
        return .menu(rows.candidates)
    }

    /// The two member lists and the candidate list, plus the key they were
    /// computed at.
    ///
    /// A named type rather than three `@State` arrays so a refresh cannot update
    /// one and forget the others, and so the gate has something to test. The
    /// candidates ride in the same box on purpose: they are the complement of
    /// the other two over the same scene, and a second cache with a second key
    /// is how a control comes to offer a card that is already listed above it.
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
        /// What the add control offers: every card not already in either list.
        var candidates: [Row] = []
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
        return MemberRows(key: key, residents: residents, visitors: visitors,
                          candidates: candidates)
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

    /// Every card that is not already in this region — what the add control
    /// offers, and nothing else.
    ///
    /// **This is `residents`' shape and strictly larger.** Those two walk one
    /// region's member sets; this walks *every node in the scene*, and then pays
    /// the same `chipTitle` per card — which splits that card's whole scrap text
    /// on newlines and trims each line — and the same `localizedStandardCompare`
    /// per comparison. It is behind the same `(sceneRevision, regionID)` gate for
    /// exactly that reason: read from `body` it would run on every drag, coast
    /// and straighten frame, and unlike the member lists it gets *more*
    /// expensive as the canvas fills rather than as the region does.
    ///
    /// `unorderedNodes`, not `nodes`: `rows` imposes its own title order, and
    /// `CanvasScene.nodes` sorts the whole scene on every access and says in its
    /// own doc not to be reached for by anyone who is about to re-sort.
    ///
    /// **A card hidden inside another, collapsed region is still offered.**
    /// Excluding it would make a collapsed region's residents permanently
    /// uncitable — collapse is a view state, not a quarantine — and the renderer
    /// already declines to draw a chip for a hidden node, so the citation is
    /// simply recorded and the chip appears when that region is expanded.
    var candidates: [Row] {
        guard let region else { return [] }
        let alreadyHere = region.homeMembers.union(region.appearances)
        return rows(Set(model.scene.unorderedNodes.map(\.id)).subtracting(alreadyHere))
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

    /// The bound piece, and the row that stands for it, when the OFFER holds no
    /// piece by that id.
    ///
    /// **It used to be called `boundPieceMissingFromTheManuscript`, and after
    /// Task 4 that name was literally false.** The offer narrowed from every
    /// `.document` to `researchScopeTargets()`, so a Collection reference piece
    /// — present in the writer's binder, right in front of them — fell out of it
    /// and rendered as "Missing piece · ref-1", while `PromotionPiece.resolve`
    /// found its title in `manifest.structure` and refused with *"Elsewhere"
    /// cannot keep research of its own*. The row is built through
    /// `ScrapInspector.PieceAssociation` so this picker, the card arm's picker
    /// and that refusal are one story.
    ///
    /// Never inherited: a region has no home to inherit from.
    private var boundPieceThePickerCannotOffer: (id: String, label: String)? {
        guard let bound = region?.boundPieceID,
              !pieces.contains(where: { $0.id == bound }) else { return nil }
        return (bound, ScrapInspector.unoffered(bound, pieceTitle: pieceTitle,
                                                inherited: false).label)
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

    /// Cite a card here without moving it — §4.3's *one home, many appearances*,
    /// and the act that makes this a planning surface rather than a filing one.
    /// The street photo belongs to the piece it illustrates **and** to the book's
    /// visual language; without this the writer is pushed back into the premature
    /// single choice the design exists to avoid.
    ///
    /// **Inspector-only, deliberately.** The alternative — a modifier-held drop —
    /// would put a modifier flag through `CanvasEventNSView`'s callbacks, which
    /// is the signature this slice has kept stable throughout, for a gesture
    /// nobody would discover. `CanvasRegion.addAppearance` refuses a node that
    /// already lives here, so the disjointness of the two sets survives a caller
    /// that has not thought about it; the guard below is not relying on that.
    ///
    /// **The guard is `remove`'s, in the mirror, and it is not decoration.** The
    /// candidate list is a gated snapshot, so between the menu opening and the
    /// writer choosing a row, an undo can put that card into this region — and a
    /// citation of a card already here would push an undo step that changes
    /// nothing. `scene.node(node) != nil` covers the same window closing the
    /// other way: an undo that took the card off the canvas entirely.
    func cite(_ node: CanvasNodeID) {
        guard let region, model.scene.node(node) != nil,
              !region.mentions(node) else { return }
        model.mutateFromInspector("Cite in Region") {
            CanvasMembership.addAppearance(node, to: regionID, in: &$0)
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
