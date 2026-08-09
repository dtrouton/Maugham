import SwiftUI

/// One item node, in the inspector: what it points at, whose hand put it there,
/// and the way to reach the thing itself.
///
/// **The fourth arm, and it exists because the third one is right to refuse.**
/// A selected page card drew the selected stroke and the connect dot while the
/// pane said *"Select something on the canvas."* — recorded in ADR 0026 §10 as a
/// decision rather than a bug, because every sentence in `ScrapInspector` is
/// wrong for an item node: "The words live on the card" describes a scrap, its
/// Piece picker associates something a photograph does not have, and a reference
/// cannot be promoted at all. So `RegionInspectorPane`'s `.scrap` ruling stands
/// and this arm is what it was waiting for. (That last clause read "an item node
/// cannot be promoted at all" until Task 8, when an *owned* one could — the arm's
/// copy is what differs, not the verb.)
///
/// **Small on purpose: the title, one act, and the provenance row.** A
/// *referenced* card is a pointer, so there is nothing here to edit — its title,
/// its kind and its picture are the manifest's, and the canvas never writes to
/// them (`CanvasItemReference.project`). This arm **mutates nothing at all**,
/// which is why tripwire 32's verb is absent rather than applied: with no
/// mutation there is no undo bracket to close. That survives Task 8's promote
/// button, which *posts a command* and writes nothing — the scene change is
/// `PromotionPerformer`'s, through `mutateFromInspector`, which is why that file
/// and not this one is in the census. Anything added here that does write to the
/// scene must go through `CanvasModel.mutateFromInspector` — the right-hand
/// column has no gesture of its own to protect and a focused scrap holds "Edit
/// Scrap" open behind it.
///
/// **There is no Delete button**, and that is not an oversight: ⌫ remains the
/// only route to deleting a node (`ScrapInspector`'s standing note — adding one
/// for symmetry with the region and line arms is a design change wearing a
/// tidy-up's clothes).
///
/// **The Promote… button is offered on ONE of the two provenances** (spec §6's
/// 2026-07-30 amendment, Task 8). A referenced item already exists as itself, so
/// it still cannot be promoted and `Promotion.itemNodeReason` is still the
/// sentence; an owned picture exists nowhere but the canvas, and the inbox entry
/// it arrived from is `.promoted` and gone — refusing it strands the photograph
/// the writer just sent there.
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
    /// The deferred manifest lookup the other two mark-bearing arms already
    /// take, and **this arm needs it for the same reason they do**: an owned
    /// picture can produce a research asset and can be added to a palette card,
    /// so it carries a mark and a contribution record, and both are ids until
    /// something resolves them. No default, matching `RegionInspectorPane`'s
    /// own two — a default is how the section goes missing again with nothing
    /// red.
    ///
    /// **Not `itemIndex` doing double duty.** That index answers "what glyph and
    /// what picture" over every research item; this answers "what is this
    /// artifact called" and is the same closure `ScrapInspector` and
    /// `RegionInspector` are handed, so the three arms cannot come to name one
    /// artifact three ways.
    let artifactTitle: (String) -> String?
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

            // **Only an owned picture, and the compiler is not what says so** —
            // this is a `Bool` on a value rather than a `switch` in `body`,
            // because a `Form`'s contents are not inspectable and
            // `_ConditionalContent` is branch-invariant, so a decision left here
            // is beyond any test that hosts no SwiftUI. `RegionInspector`'s
            // `CiteAffordance` and `openAffordance` above are the same shape.
            if Self.promotes(reference) {
                PromotedArtifactSection(state: provenance, subject: .picture,
                                        onOpen: onOpenResearchItem)
                Section {
                    Button("Promote…") {
                        // The SAME command the File item and ⌘⇧↩ post — see
                        // `RegionInspector` for why a closure of our own would be
                        // a second path that can drift from the keystroke, and
                        // why posting is safe from this column and not from
                        // inside a sheet.
                        MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
                    }
                    Text(Self.promoteFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let contributions = Self.referencedContributions(provenance) {
                // **A reference cannot be promoted and CAN have contributed**
                // (1C-d Task 12a, spec §6.3's 2026-07-31 amendment). A region's
                // palette promotion copies the pictures in it onto the card
                // whatever their provenance, so a research image dragged onto
                // the canvas ends up genuinely inside that card — and with the
                // section gated on `promotes` alone, its pane said nothing at
                // all about it. That is §6.3's own reported defect (*"some think
                // they weren't"*) arriving on the arm the ruling reached last,
                // and CLAUDE.md rule 8 is the rule it breaks.
                //
                // The MARK half is withheld rather than rendered empty: a
                // reference produced nothing, and `.notPromoted` beside a
                // contribution suppresses "Not promoted yet." by
                // `Provenance.saysNotPromotedYet`'s own rule.
                PromotedArtifactSection(
                    state: .init(artifact: .notPromoted, contributions: contributions),
                    subject: .referencedPicture, onOpen: onOpenResearchItem)
            }
        }
        .formStyle(.grouped)
    }

    /// The contribution half of a REFERENCED node's provenance, or nil when
    /// there is nothing to show.
    ///
    /// **A value rather than an `if` in `body`**, this arm's standing reason: a
    /// `Form`'s contents are not inspectable and `_ConditionalContent` is
    /// branch-invariant, so the decision would otherwise be beyond any test that
    /// hosts no SwiftUI. `Self.promotes` and `openAffordance` are the same shape.
    ///
    /// It answers nil for no records at all — a reference with none mounts
    /// **no section**, rather than one saying "Not promoted yet." about a card
    /// that can never be promoted.
    static func referencedContributions(
        _ provenance: PromotedArtifactSection.Provenance
    ) -> [PromotedArtifactSection.ContributionState]? {
        provenance.contributions.isEmpty ? nil : provenance.contributions
    }

    /// Both records, resolved through the one artifact lookup — `ScrapInspector`'s
    /// shape and its reason (spec §6.3): the mark says what this picture
    /// *produced*, the contribution record says which palette card it is *in*,
    /// and a picture can carry both.
    ///
    /// Gated on a non-nil id by `provenance`'s own `flatMap`s, so a picture
    /// carrying neither — every picture until it is promoted — asks nothing.
    private var provenance: PromotedArtifactSection.Provenance {
        let node = model.scene.node(nodeID)
        return PromotedArtifactSection.provenance(
            promotedItemID: node?.promotedItemID,
            contributedToItemIDs: node?.contributedToItemIDs ?? [],
            title: artifactTitle)
    }

    /// Whether this card can be promoted at all — **the provenance, and it is the
    /// same rule `Promotion.targets` and `CanvasPromotionModifier.isPromotable`
    /// apply.** Three spellings of one fact is the drift this directory keeps
    /// paying for, so this one is static and tested against
    /// `Promotion.targets(for:in:artifacts:)` rather than trusted.
    static func promotes(_ reference: CanvasItemReference) -> Bool {
        switch reference {
        case .owned: return true
        case .project: return false
        }
    }

    /// **It says COPY, twice over**, because both are facts a writer will test:
    /// the picture stays on the canvas, and the file stays in the project's
    /// canvas well. `ScrapInspector`'s footer says the same thing about words.
    static let promoteFooter =
        "Promoting copies the picture into research, or onto a palette card. It "
        + "stays here either way, and changing what it made afterwards doesn't "
        + "change this card."

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
            return .explanation(ownedLivesOnTheCanvas)
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
    ///
    /// **It read "There's nothing in Research to open." until Task 8 made that
    /// half false on the same screen.** A promoted picture's own section, three
    /// rows down, says *Became “…”* over an **Open** that goes straight to
    /// Research — so the pane asserted there was nothing to open directly above
    /// the button that opens it. What stays true in both states is the fact this
    /// row is actually about: the *card* is not a research item, and promoting is
    /// what puts a copy there. (The section below is the one that names the copy;
    /// this sentence deliberately does not, or the two would drift.)
    static let ownedLivesOnTheCanvas =
        "This picture lives on the canvas. Promoting it is what puts a copy in "
        + "Research."

    /// **A dangling reference is not an error state** — the writer deleted the
    /// note, and the card is still theirs. `CanvasItemFacts.missingTitle` has
    /// already said what became of it in the title above, so this says only what
    /// changed about the act, and it carries **no id**:
    /// `PromotedArtifactSection.contributionArtifactMissing`'s precedent, whose
    /// reason is that an id is not something the writer can read.
    static let referenceIsGone =
        "There's nothing left to open. The card stays until you delete it."
}
