import SwiftUI

/// One card, in the inspector: what it says, what it became, and the way to
/// promote it.
///
/// **A card had no pane at all until 1C-c2, and this exists because of the
/// field that slice added.** A drawn mark can say *that* a card was promoted
/// and can never say *what it became*; CLAUDE.md rule 8 asks every new data
/// type for a surface that can inspect and act on it. The section that says so
/// is `PromotedArtifactSection`, shared with the region arm — for one slice
/// only this one had it, which is the same rule failing for the other half of
/// the field.
///
/// **There is no Delete button, deliberately.** ⌫ remains the only route to
/// deleting a scrap (ADR 0026's standing consequence). Adding one here for
/// symmetry with the region and line arms would be a design change wearing a
/// tidy-up's clothes.
///
/// **Promotion goes through the one command** — the same `.keyWindow` post the
/// File-menu item and ⌘⇧↩ make. A closure of its own would be a second path
/// that can drift from the keystroke.
struct ScrapInspector: View {

    let model: CanvasModel
    let nodeID: CanvasNodeID
    /// The same list the region arm is handed, and already filtered to the
    /// pieces a promotion can be routed to — see `ProjectWindow.pieceChoices`.
    let pieces: [RegionInspector.PieceChoice]
    /// Deferred: it walks the manifest, and it is called only when a promoted
    /// card is selected. Same rule as `CanvasView.paletteSwatchHexes`.
    let artifactTitle: (String) -> String?
    /// What the writer's BINDER calls a piece — the whole structure, not the
    /// routable subset in `pieces`. See `association` for why the two are not
    /// the same lookup.
    ///
    /// Deferred for `artifactTitle`'s reason, and asked even less often: only
    /// when an association names a piece `pieces` does not hold.
    let pieceTitle: (String) -> String?
    let onOpenResearchItem: (String) -> Void

    private var node: CanvasNode? { model.scene.node(nodeID) }

    /// **Both records, resolved through the one artifact index** (spec §6.3).
    ///
    /// The card's own mark says what it *became*; the contribution record says
    /// its words are *in* something a region's promotion produced. Two different
    /// facts, and a card may carry both — the pane shows both rather than
    /// choosing, and `Provenance.saysNotPromotedYet` is the one place they
    /// interact.
    ///
    /// **The record is resolved through `artifactTitle` and never shown raw**,
    /// which is what makes a deleted note say so instead of printing an id.
    ///
    /// **Two lookups on a card carrying both, and the cost is stated rather than
    /// gated.** This body is on screen at 60–120 Hz while a writer drags a card,
    /// and `artifactTitle` walks the research tree. What this adds is **one
    /// duplicate of a lookup already accepted on this body** for the mark: both
    /// calls are `flatMap`-gated on a non-nil id, so a card carrying neither
    /// record — most of them — asks nothing at all, and `TreeWalk.find` exits at
    /// the hit rather than walking the whole tree. Nothing here was measured, and
    /// this file does not use that word without a figure and a date beside it.
    /// The gate, if it is ever wanted, is `RegionInspector`'s
    /// `(sceneRevision, id)` cache — every writer of both fields bumps that
    /// counter, so the key would be correct.
    private var provenance: PromotedArtifactSection.Provenance {
        PromotedArtifactSection.provenance(promotedItemID: node?.promotedItemID,
                                           contributedToItemID: node?.contributedToItemID,
                                           title: artifactTitle)
    }

    var body: some View {
        Form {
            Section {
                Text(CanvasRenderer.chipTitle(for: nodeID, in: model.scene,
                                              scraps: model.scraps))
                    .lineLimit(2)
                // **Whose card this is** — the third fact this pane states, and
                // the one CLAUDE.md rule 8 asks for on `CanvasNode.author`. The
                // tint and the 0° lean say it to a writer who is already looking
                // at the canvas; this is where it is inspectable, beside the words
                // themselves rather than under "Promotion", because a card being
                // Claude's is not something that has happened *to* it.
                //
                // Nothing at all for the writer's own cards, which is every card
                // on every canvas made before this slice. **The same row the
                // region arm renders** — `CanvasAuthorLine` is one implementation
                // both arms are handed, for the reason `PromotedArtifactSection`
                // is: this line lived here alone for one round, which is the same
                // rule failing for the other half of the same field.
                CanvasAuthorLineRow(
                    line: CanvasAuthorLine.forCard(nodeID, in: model.scene,
                                                   title: artifactTitle))
            } header: {
                Text("Card")
            } footer: {
                Text("The words live on the card. Editing them here isn't a thing "
                     + "— click into it on the canvas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Piece", selection: Binding(
                    get: { node?.boundPieceID ?? RegionInspector.noPieceTag },
                    set: { commitPiece($0 == RegionInspector.noPieceTag ? nil : $0) })) {
                        Text("None").tag(RegionInspector.noPieceTag)
                        ForEach(pieces) { Text($0.title).tag($0.id) }
                        // The card's own association naming a piece the picker
                        // cannot offer — deleted, or a reference piece that
                        // keeps its research in its own project. Shown rather
                        // than dropped, for `RegionInspector`'s reason: a
                        // `Picker` with no row matching its selection renders
                        // blank, which reads as "not associated" and invites the
                        // writer to fix a problem they cannot see.
                        if let orphan = ownPieceThePickerCannotOffer {
                            Text(orphan.label).tag(orphan.id)
                        }
                    }
                // **The resolved answer, and where it came from.** The Picker
                // above shows only what this card carries ITSELF, so a card
                // inheriting from its region shows "None" there while its
                // promotions land somewhere — which is the precedence being
                // invisible at exactly the moment it decides something.
                //
                // **Ungated, and on the frame path — recorded rather than
                // papered over.** This body reads `model.scene`, and a card drag
                // opens with a `clickCount: 1` mouse-down that selects the card,
                // so this pane IS what is on screen at 60–120 Hz while a writer
                // drags. `association` reaches `CanvasMembership.homeRegion`,
                // which walks `scene.regions` — a sort with `String` compares —
                // so this is scene-proportional work on a frame path, which is
                // tripwire 30's shape.
                //
                // It is left ungated on three REASONED terms — nothing here was
                // measured, and this file does not use that word without a figure
                // and a date beside it (tripwire 25 is what one looks like).
                //
                // (1) **It is not the leading term in its own body.** Two larger
                // things already run per frame here: `CanvasRenderer.chipTitle`
                // splits the ENTIRE scrap string (a non-lazy `split` with
                // `omittingEmptySubsequences: false`), and the `ForEach(pieces)`
                // above builds a row per manuscript document. Against those,
                // sorting tens of 4-character region ids is noise — TWICE, which
                // is what it actually costs: `association` asks
                // `Promotion.piece` and then `pieceIsInherited` asks it again.
                // That is one walk per frame more than this comment claimed
                // before the whole-branch review counted them, and the ruling is
                // unchanged: gating these two calls alone would change nothing
                // observable.
                // (2) It is proportional to the REGION count — not the node count
                // and not any text — where the lists `RegionInspector` gates pay
                // a whole-scrap-text split per member plus
                // `localizedStandardCompare`.
                // (3) A `@State` cache is not free here: five of them froze for a
                // commit in this area when a bump went to the view's counter
                // instead of the model's, and a stale destination is worse than a
                // slow one. Tripwire 30's actual failure was scene-proportional
                // work keyed on the REDRAW counter; this is neither cached nor
                // keyed on anything.
                //
                // **If it ever measures, the gate exists one file over** —
                // `RegionInspector.MemberRows` keyed on
                // `(model.sceneRevision, id)`, and the key would be correct here
                // because every writer of this value (`commitPiece`,
                // `RegionInspector.commitBinding`, the undo apply) bumps that
                // counter. Do not record this as "there is no gated way".
                LabeledContent("Promotions go to",
                               value: Self.association(for: nodeID, in: model.scene,
                                                       pieces: pieces,
                                                       pieceTitle: pieceTitle).label)
            } header: {
                Text("Piece")
            } footer: {
                Text(Self.pieceFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PromotedArtifactSection(state: provenance, subject: .card,
                                    onOpen: onOpenResearchItem)

            Section {
                Button("Promote…") {
                    // The SAME command the menu item and ⌘⇧↩ post — see
                    // `RegionInspector` for why a closure of our own would be
                    // a second path, and why posting is safe from this column.
                    MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
                }
                Text("Promoting takes a copy. The card stays here with its words, "
                     + "and changing it afterwards doesn't change what it made.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - The piece association (spec §6.2)

    static let pieceFooter =
        "A note promoted from this card lands in this piece's research. Leave it "
        + "as None and the card follows the region it lives in — or the project's "
        + "own research, if it lives in none."

    /// The card's own association when the offer holds no piece by that id, and
    /// the row that stands for it — built through `PieceAssociation` so the
    /// Picker's row and "Promotions go to" cannot tell two stories about one
    /// state. Never inherited: this reads the card's OWN field.
    private var ownPieceThePickerCannotOffer: (id: String, label: String)? {
        guard let bound = node?.boundPieceID,
              !pieces.contains(where: { $0.id == bound }) else { return nil }
        return (bound, Self.unoffered(bound, pieceTitle: pieceTitle,
                                      inherited: false).label)
    }

    /// What piece a promotion from this card would land in, and **where that
    /// answer came from** — §6.2's precedence made visible.
    ///
    /// A value rather than an `if` inside the view, because which arm a
    /// `_ConditionalContent` renders cannot be asserted and a `Form`'s contents
    /// are not inspectable: left in `body` this distinction would be unreachable
    /// from any test that does not host SwiftUI. `RegionInspector.CiteAffordance`
    /// is the same shape for the same reason.
    enum PieceAssociation: Equatable {
        case none
        case own(title: String)
        case inherited(title: String)
        /// The association names a piece that is **not in the project at all**.
        /// It keeps the id because that is all there is left to say, and the
        /// writer needs to see that *something* is set before they can clear it.
        /// **`inherited` matters most here, which is the opposite of obvious.**
        /// A card living in a region whose piece was deleted carries nothing
        /// itself, so without this the pane says "Missing piece · gone-9" beside
        /// a Picker reading None — and the writer has nothing to clear and no
        /// idea where the stale value lives. The qualifier is what sends them to
        /// the region.
        case gone(id: String, inherited: Bool)

        /// The association names a piece that is **in the writer's binder** and
        /// keeps no research of its own — a Collection reference piece, or a
        /// group `researchRouting` throws on.
        ///
        /// **This case exists because the pane and the refusal told two stories
        /// about one state.** Task 4 narrowed the offer to
        /// `researchScopeTargets()`, correctly; the label resolved its title out
        /// of that same narrowed list, so anything the filter excluded rendered
        /// as "Missing piece · ref-1" — while `PromotionPiece.resolve` looked the
        /// title up in `manifest.structure`, found it, and refused with
        /// *"Elsewhere" cannot keep research of its own*. One is in the binder in
        /// front of the writer; "missing" sent them hunting for it.
        case keepsNoResearch(title: String, inherited: Bool)

        /// One spelling of the qualifier, used by every case that needs it.
        static let fromItsRegion = " (from its region)"

        var label: String {
            switch self {
            case .none: return "The project's research"
            case .own(let title): return title
            // The distinction the writer needs: "Chapter Three (from its region)"
            // is why an override would matter, and why the Picker above says None.
            case .inherited(let title): return title + Self.fromItsRegion
            case .gone(let id, let inherited):
                return "Missing piece · \(id)" + (inherited ? Self.fromItsRegion : "")
            case .keepsNoResearch(let title, let inherited):
                // The refusal's own halves, in the pane's voice — see
                // `PromotionFailure.pieceIsNotAResearchTarget`, which says
                // "“\(title)” cannot keep research of its own".
                return "\(title) · keeps no research of its own"
                    + (inherited ? Self.fromItsRegion : "")
            }
        }
    }

    /// The two states an association the picker cannot offer can be in, told
    /// apart by the BINDER rather than by the offer.
    ///
    /// **One lookup, two callers** — the Picker's orphan row and "Promotions go
    /// to" — because those two surfaces describing one state differently is the
    /// defect this exists to fix.
    static func unoffered(_ id: String, pieceTitle: (String) -> String?,
                          inherited: Bool) -> PieceAssociation {
        guard let title = pieceTitle(id) else { return .gone(id: id, inherited: inherited) }
        return .keepsNoResearch(title: title, inherited: inherited)
    }

    /// **Resolved through `Promotion.piece`, never by reading the two fields.**
    /// The precedence is one rule and the performer is its other reader, so a
    /// second walk here would let the pane name a destination the promotion does
    /// not use — including the visitor case, where a card cited in a bound region
    /// inherits nothing (§4.3: home decides and visitors do not).
    ///
    /// **Two lookups, and they are not the same question.** `pieces` is the
    /// routable offer (`researchScopeTargets()`), so a hit there means the
    /// promotion will land somewhere and the label is just the title.
    /// `pieceTitle` is the whole structure, and it is what tells a piece that is
    /// GONE from one sitting in the writer's binder that simply keeps no
    /// research — the second of which read "Missing piece · ref-1" for a slice,
    /// while the refusal one layer down named it and said what was wrong with
    /// it. It is asked only on the miss, so the ordinary path walks nothing.
    ///
    /// Static, so a test drives exactly what the view does.
    static func association(for nodeID: CanvasNodeID, in scene: CanvasScene,
                            pieces: [RegionInspector.PieceChoice],
                            pieceTitle: (String) -> String?) -> PieceAssociation {
        guard let resolved = Promotion.piece(for: .scrap(nodeID), in: scene) else {
            return .none
        }
        // Asked BEFORE the title lookup, and carried into both unoffered cases
        // too. Resolving it only on the way to `.own`/`.inherited` loses the fact
        // exactly where the writer needs it: a stale piece they cannot clear
        // because it is not theirs.
        let inherited = Promotion.pieceIsInherited(for: .scrap(nodeID), in: scene)
        guard let title = pieces.first(where: { $0.id == resolved })?.title else {
            return unoffered(resolved, pieceTitle: pieceTitle, inherited: inherited)
        }
        return inherited ? .inherited(title: title) : .own(title: title)
    }

    // MARK: - Where the card came from (spec §8A.2)
    //
    // `CanvasAuthorLine` is the whole of it, and it is deliberately not a member of
    // this type. It lived here — as `ScrapInspector.Origin` — for one round, while
    // a Claude REGION's pane said nothing about being Claude's: the same field, the
    // same drawn signal, the same spoken term, and a surface for one half of it.
    // The frame-path cost is stated in that file's class doc, under "What this
    // costs on the frame path, honestly" — which covers both arms. **That pointer
    // was false for one commit**: the extraction dropped the paragraph and left
    // this sentence aimed at nothing, which is how a disclosure a review relied on
    // stops holding without anything going red. What is worth repeating here is
    // that it costs **nothing at all for the writer's own cards**, because the
    // author check is one dictionary lookup and returns before any walk.

    /// **`mutateFromInspector`, never `mutate` (tripwire 32).** This Picker is in
    /// the right-hand column and a focused scrap holds "Edit Scrap" open behind
    /// it — nothing on this side of the window closes that bracket. Nested, the
    /// association registers no undo step of its own and rides into the writer's
    /// next sentence, where a ⌘Z aimed at a sentence takes it with them.
    ///
    /// **This arm's repro is a double-click on the CARD**, which is the most
    /// ordinary gesture on the canvas: click 1 selects the node and puts this
    /// pane on screen, click 2 opens "Edit Scrap" without touching the selection
    /// (`handleClick` assigns `model.selection` inside the `clickCount < 2`
    /// branch), so the Picker is live over a bracket nothing on this side of the
    /// window closes. **It is NOT the chrome-bar double-click** — that leaves the
    /// *region* selected, so `RegionInspectorPane` renders the region arm and
    /// this pane is not on screen at all. This comment cited the chrome bar
    /// until the whole-branch review, which understated the exposure: each arm
    /// has its own repro, and neither one's is the other's.
    ///
    /// **Two names, because clearing reaches a genuinely different state** —
    /// `LineInspector.commitBinding`'s Bind/Unbind precedent, and not
    /// `RegionInspector.commitLabel`'s, which says "Rename Region" both ways
    /// because a label is non-optional and has no clear-state to name.
    ///
    /// The guard is every one of these panes': a `Picker` set to what it already
    /// shows must buy no snapshot, no queued disk write and no redraw.
    func commitPiece(_ piece: String?) {
        guard let node, node.boundPieceID != piece else { return }
        model.mutateFromInspector(
            piece == nil ? "Clear Card's Piece" : "Associate Card with Piece") {
                $0.setBoundPiece(piece, for: nodeID)
            }
        model.bumpSceneRevision()
    }
}
