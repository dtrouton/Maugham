import SwiftUI

/// One item node, in the inspector: what it points at, whose hand put it there,
/// and the way to reach the thing itself.
///
/// **The fourth arm, and it exists because the third one is right to refuse.**
/// A selected page card drew the selected stroke and the connect dot while the
/// pane said *"Select something on the canvas."* — recorded in ADR 0026 §10 as a
/// decision rather than a bug, because every sentence in `ScrapInspector` is
/// wrong for a reference: "The words live on the card" and "Promoting takes a
/// copy" describe a scrap, and an item node cannot be promoted at all. So
/// `RegionInspectorPane`'s `.scrap` ruling stands and this arm is what it was
/// waiting for.
///
/// **Small on purpose: the title, one act, and the provenance row.** The card is
/// a *pointer*, so there is nothing here to edit — its title, its kind and its
/// picture are the manifest's, and the canvas never writes to them
/// (`CanvasItemReference.project`). This arm therefore **mutates nothing at
/// all**, which is why tripwire 32's verb is absent rather than applied: with no
/// mutation there is no undo bracket to close. Anything added here that *does*
/// write to the scene must go through `CanvasModel.mutateFromInspector` — the
/// right-hand column has no gesture of its own to protect and a focused scrap
/// holds "Edit Scrap" open behind it.
///
/// **There is no Delete button and no Promote button**, and neither is an
/// oversight. ⌫ remains the only route to deleting a node (`ScrapInspector`'s
/// standing note: adding one for symmetry with the region and line arms is a
/// design change wearing a tidy-up's clothes), and an item node already exists
/// as itself — `Promotion.itemNodeReason` is the sentence, and making an *owned*
/// node promotable is Task 8's.
struct ItemInspector: View {

    let model: CanvasModel
    let nodeID: CanvasNodeID
    /// What this node points at — **destructured by the pane rather than read
    /// back out of the node here.** `CanvasItemReference`'s doc comment asks
    /// exactly that of the sites that genuinely differ between the two
    /// provenances, and the pane has already destructured it to choose this arm.
    /// A node's kind never changes, so there is no staleness to inherit; what
    /// *can* change is whether the node is in the scene at all, and
    /// `CanvasModel.selectedNode` resolves that one selection earlier.
    let reference: CanvasItemReference
    /// The index every item node on the canvas resolves through — built once per
    /// manifest change in `ProjectWindow` and handed down (`CanvasItemIndex`).
    ///
    /// **No default**, deliberately, and not for `RegionInspectorPane.itemIndex`'s
    /// reason. `.empty` is a real state there and the census guards the argument;
    /// here a default would make the *whole arm* read "No longer in the project."
    /// over a note sitting in the writer's binder, and offer nothing to open, with
    /// nothing red. The compiler asks instead.
    let itemIndex: CanvasItemIndex
    /// The pane's existing closure, and **this arm is its third caller** — it was
    /// reached only from the two arms that do not render for an item node, which
    /// is what made a page card a dead end. It has no default on the pane for the
    /// reason `artifactTitle` has none: a default is how the section goes missing
    /// again with nothing red.
    let onOpenResearchItem: (String) -> Void

    /// One spelling of "what is this node called", shared with the card the
    /// writer is looking at. A title resolved here instead would drift from the
    /// drawn one, which is `PromotedArtifactSection`'s own history on the
    /// neighbouring field.
    ///
    /// **Cheap enough to leave in `body`, and that is a measured shape rather
    /// than an accepted risk**: `CanvasItemFacts.resolve` is a switch and one
    /// dictionary lookup. It walks nothing, unlike `CanvasAuthorLine` below and
    /// unlike `ScrapInspector.association`, both of which are disclosed in their
    /// own files as scene-proportional work on a frame path.
    private var facts: CanvasItemFacts {
        CanvasItemFacts.resolve(reference, in: itemIndex)
    }

    var body: some View {
        Form {
            Section {
                // The glyph as well as the words: the same `CanvasItemKind.glyph`
                // the card draws, so a note, a palette card and a photograph are
                // as tellable apart here as they are on the canvas.
                Label(facts.title, systemImage: facts.glyph)
                    .lineLimit(2)
                // **Whose hand put this card here** — the third arm of the one
                // implementation the other two are handed (`CanvasAuthorLine`).
                // A page `CanvasClaudePlacement` created is drawn at exactly 0°
                // and announced with `CanvasAccessibility.claudeTerm`, and a lean
                // is not something a pane can show. Spelling the sentence here
                // instead would be a fifth wording of one fact; the census in
                // `RegionBindingTests` forbids it and now names three arms.
                //
                // `forItem` and not `forCard`: the page IS the source, and the
                // card resolver would have it say it was read from itself.
                CanvasAuthorLineRow(line: CanvasAuthorLine.forItem(nodeID, in: model.scene))
            } header: {
                Text(Self.header)
            }

            Section { openControl }
        }
        .formStyle(.grouped)
    }

    /// **The same word VoiceOver says** (`CanvasAccessibility.itemKind`), not a
    /// second noun for one primitive. A writer who hears "Reference, from Claude"
    /// and then reads a pane headed "Item" has met two names for the card in
    /// front of them.
    static let header = CanvasAccessibility.itemKind

    /// The one act this arm offers, or the sentence saying why there isn't one.
    ///
    /// Handed a value rather than deciding in place, for this directory's
    /// standing reason: `_ConditionalContent` is branch-invariant and a `Form`'s
    /// contents are not inspectable, so an `if` here would put the decision
    /// beyond any test that does not host SwiftUI.
    /// `RegionInspector.CiteAffordance` is the same shape.
    @ViewBuilder
    private var openControl: some View {
        switch Self.openAffordance(for: reference, in: itemIndex) {
        case .open(let itemID):
            Button("Open in Research") { onOpenResearchItem(itemID) }
        case .explanation(let why):
            Text(why).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - What there is to open (spec §8A.1)

    /// Whether this card can be followed anywhere, and what to say when it
    /// cannot.
    ///
    /// **No live control onto nothing** — `CiteAffordance`'s rule, arriving on
    /// the other provenance: a button that says a thing is possible and then does
    /// nothing is worse than its absence.
    enum OpenAffordance: Equatable {
        /// A research item that is still in the project.
        case open(itemID: String)
        /// Nothing to open, and the sentence that says why.
        case explanation(String)
    }

    /// **The index is what knows, and the title is never read back for this.**
    /// `CanvasItemFacts` carries three facts and no fourth on purpose, and its
    /// own doc comment names this caller: *"a caller that needs to act
    /// differently on a deleted reference — to withhold an Open in Research
    /// button, say — asks `CanvasItemIndex`"*. A `title == missingTitle`
    /// comparison would tie a control to a sentence somebody may reword, and
    /// would withhold the button from a real note the writer happened to title
    /// "No longer in the project.". So no fourth field was added: the question is
    /// asked of the thing that already answers it.
    ///
    /// Static, so a test drives exactly what the view does.
    static func openAffordance(for reference: CanvasItemReference,
                               in index: CanvasItemIndex) -> OpenAffordance {
        switch reference {
        case .owned:
            return .explanation(ownedHasNothingToOpen)
        case .project(let id):
            guard index.entry(of: id) != nil else { return .explanation(referenceIsGone) }
            return .open(itemID: id)
        }
    }

    /// **An owned picture has no research item behind it, and Reveal in Finder is
    /// not the substitute.** The canvas ingested the file under a minted name —
    /// `ImagePasteHandler.destination` writes `image-yyyyMMdd-HHmmss.<ext>` and
    /// the writer's own filename is discarded — so revealing it answers a
    /// question about content with a clock reading in a folder they never chose,
    /// which is the failure `CanvasItemFacts.ownedTitle` names for the *title*
    /// arriving the same way. Nothing is offered, and the sentence says why.
    ///
    /// *Falsification:* if an owned image ever gains a home in the project the
    /// writer can navigate to, this is a link rather than a sentence.
    static let ownedHasNothingToOpen =
        "This picture lives on the canvas. There's nothing in Research to open."

    /// **A dangling reference is not an error state** — the writer deleted the
    /// note, and the card is still theirs. `CanvasItemFacts.missingTitle` has
    /// already said what became of it in the title above, so this says only what
    /// changed about the act, and it carries **no id**:
    /// `PromotedArtifactSection.contributionArtifactMissing`'s precedent, whose
    /// reason is that an id is not something the writer can read.
    static let referenceIsGone =
        "There's nothing left to open. The card stays until you delete it."
}
