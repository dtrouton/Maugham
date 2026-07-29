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
    let onOpenResearchItem: (String) -> Void

    private var node: CanvasNode? { model.scene.node(nodeID) }

    private var state: PromotedArtifactSection.ArtifactState {
        let mark = node?.promotedItemID
        return PromotedArtifactSection.artifactState(promotedItemID: mark,
                                                     title: mark.flatMap(artifactTitle))
    }

    var body: some View {
        Form {
            Section {
                Text(CanvasRenderer.chipTitle(for: nodeID, in: model.scene,
                                              scraps: model.scraps))
                    .lineLimit(2)
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
                        // cannot offer — deleted, or converted to a reference
                        // piece. Shown rather than dropped, for
                        // `RegionInspector`'s reason: a `Picker` with no row
                        // matching its selection renders blank, which reads as
                        // "not associated" and invites the writer to fix a
                        // problem they cannot see.
                        if let orphan = ownPieceMissingFromTheOffer {
                            Text("Missing piece · \(orphan)").tag(orphan)
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
                // sorting tens of 4-character region ids is noise, and gating
                // this one call alone would change nothing observable.
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
                                                       pieces: pieces).label)
            } header: {
                Text("Piece")
            } footer: {
                Text(Self.pieceFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PromotedArtifactSection(state: state, subject: .card,
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

    /// The card's own association when the offer holds no piece by that id.
    private var ownPieceMissingFromTheOffer: String? {
        guard let bound = node?.boundPieceID,
              !pieces.contains(where: { $0.id == bound }) else { return nil }
        return bound
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
        /// The association names a piece the offer does not hold: deleted, or
        /// converted to a Collection reference piece. It keeps the id because
        /// that is all there is left to say, and the writer needs to see that
        /// *something* is set before they can clear it.
        /// **`inherited` matters most here, which is the opposite of obvious.**
        /// A card living in a region whose piece was deleted carries nothing
        /// itself, so without this the pane says "Missing piece · gone-9" beside
        /// a Picker reading None — and the writer has nothing to clear and no
        /// idea where the stale value lives. The qualifier is what sends them to
        /// the region.
        case missing(id: String, inherited: Bool)

        /// One spelling of the qualifier, used by both cases that need it.
        static let fromItsRegion = " (from its region)"

        var label: String {
            switch self {
            case .none: return "The project's research"
            case .own(let title): return title
            // The distinction the writer needs: "Chapter Three (from its region)"
            // is why an override would matter, and why the Picker above says None.
            case .inherited(let title): return title + Self.fromItsRegion
            case .missing(let id, let inherited):
                return "Missing piece · \(id)" + (inherited ? Self.fromItsRegion : "")
            }
        }
    }

    /// **Resolved through `Promotion.piece`, never by reading the two fields.**
    /// The precedence is one rule and the performer is its other reader, so a
    /// second walk here would let the pane name a destination the promotion does
    /// not use — including the visitor case, where a card cited in a bound region
    /// inherits nothing (§4.3: home decides and visitors do not).
    ///
    /// Static, so a test drives exactly what the view does.
    static func association(for nodeID: CanvasNodeID, in scene: CanvasScene,
                            pieces: [RegionInspector.PieceChoice]) -> PieceAssociation {
        guard let resolved = Promotion.piece(for: .scrap(nodeID), in: scene) else {
            return .none
        }
        // Asked BEFORE the title lookup, and carried into the missing case too.
        // Resolving it only on the way to `.own`/`.inherited` loses the fact
        // exactly where the writer needs it: a stale piece they cannot clear
        // because it is not theirs.
        let inherited = Promotion.pieceIsInherited(for: .scrap(nodeID), in: scene)
        guard let title = pieces.first(where: { $0.id == resolved })?.title else {
            return .missing(id: resolved, inherited: inherited)
        }
        return inherited ? .inherited(title: title) : .own(title: title)
    }

    /// **`mutateFromInspector`, never `mutate` (tripwire 32).** This Picker is in
    /// the right-hand column and a focused scrap holds "Edit Scrap" open behind
    /// it — nothing on this side of the window closes that bracket. Nested, the
    /// association registers no undo step of its own and rides into the writer's
    /// next sentence, where a ⌘Z aimed at a sentence takes it with them. Repro:
    /// double-click a region's CHROME BAR (click 1 selects it, click 2 mints a
    /// scrap and opens the bracket) — not a card, whose first click reassigns the
    /// selection.
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
