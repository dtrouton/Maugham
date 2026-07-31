import Foundation

/// **What a thing dropped on the canvas means, and how it lands** (spec §8A.1).
///
/// The binder sits beside the canvas in the Plan persona and its research tree is
/// the natural source, so dropping a research item on the canvas makes an item
/// node at the drop point: the file is untouched, the canvas holds a position
/// (§3.1). Until 1C-d nothing in production made an item node except
/// `CanvasClaudePlacement`, on Claude's behalf; this is the writer's own route.
///
/// **Why the decision is a pure function and the mount is a census.** SwiftUI's
/// drop delivery is not drivable from XCTest — there is no seam to post a drag
/// session into, the way `CanvasEventNSView.applyMouseDown` gives the mouse one.
/// So the *decision* lives somewhere a test can reach exhaustively, and the
/// *wiring* is pinned by
/// `PromotionCommandTests.test_theCanvasWiringCensusNamesEveryProductionSite`
/// instead. That is 1C-b's recorded lesson (routing decisions want a pure
/// function tested over the whole product) applied to a surface where the
/// alternative is not available: a router with no modifier on it would be this
/// area's fifth built-and-unreachable half, and all four previous ones were found
/// by counting callers rather than by a test.
///
/// **The payload is a bare research item id, and the id space is about to have a
/// neighbour.** `ResearchRow.swift:64` sends `item.id` through `.draggable`, which
/// is the app's established pattern — but the binder sends manuscript pieces and
/// tasks with the *same* raw-id payload (`PieceRow.swift`, `TasksPane.swift`), so
/// a string arriving here is not necessarily a research item at all. Everything
/// this router refuses, it refuses by not finding the id in `CanvasItemIndex`;
/// see `decide`. **A second id space must therefore arrive PREFIXED** — an inbox
/// entry's ULID and a research id are not tellable apart, and a bare one would be
/// silently refused by the rule in the paragraph above rather than routed.
@MainActor
enum CanvasDrop {

    /// What the writer's Edit menu reads after a drop.
    ///
    /// One name for the whole act — the card and its membership together — because
    /// it is one gesture and one ⌘Z. Read by the tests as a constant rather than
    /// as a literal, so the assertion and the menu cannot drift apart.
    static let undoStepName = "Add to Canvas"

    /// What a dropped payload means. Three answers, and the middle one is the
    /// whole reason this is a decision rather than an insert.
    enum Decision: Equatable {
        /// The payload names nothing this canvas can hold. Nothing happens, and
        /// the drop is declined so the source shows the writer a refusal.
        case ignored

        /// The item already has a node here. Select it and bring it on screen —
        /// **do not re-create it and do not move it.**
        case reveal(CanvasNodeID)

        /// Make this node. Already carries its origin, its width, its z and a
        /// measured height — see `decide`.
        case create(CanvasNode)
    }

    /// Decide what a payload dropped at `contentPoint` means.
    ///
    /// **Validated against `CanvasItemIndex` before anything is created**, and the
    /// index is already a parameter of `CanvasView`, so this costs no new wiring.
    /// A node created for an id in no manifest draws `CanvasItemFacts.missingTitle`
    /// — *"No longer in the project."* — **from birth**: a card the writer can
    /// neither fix nor explain, made by an act they performed correctly. Refusing
    /// is the only honest answer, and it also disposes of every id space the binder
    /// drags that is not research (a manuscript piece, a task).
    ///
    /// **A research GROUP is accepted**, and the two neighbouring rulings do not
    /// disagree with that even though they read as if they might.
    /// `AddCanvasScrapsTool` *refuses* a group id, because a folder is not a page
    /// Claude can have read a batch of scraps off, and `item:<groupId>` would be a
    /// node minted by no other route. This is the opposite case: the writer is
    /// pointing at a folder they can see in their own binder, `CanvasItemKind.group`
    /// exists for exactly that, and Task 4 already ruled that resolving a group is
    /// right because *"'no longer in the project' said over a folder the writer can
    /// see in the binder is a lie"*. So the glyph, the title and the card all
    /// already work; refusing would be inventing a second rule for the case the
    /// first one was written for.
    ///
    /// **A second drop of an id already on the canvas is `.reveal`, never a second
    /// `.create`.** `CanvasNodeID.item(_:)` derives the id from the reference, so
    /// both drops resolve to one id, and `CanvasScene.insert` is keyed by id — a
    /// re-insert would **overwrite** the existing node, silently discarding its
    /// membership, its promotion mark, its width, its z and its author. Moving it
    /// to the new drop point is not the alternative either: that is a
    /// geometry-driven change to something the writer placed, which is the
    /// transition rule §4.2 exists to eliminate and is why
    /// `CanvasClaudePlacement.PlannedSource` cites an existing page rather than
    /// relocating it.
    ///
    /// **The created node is born MEASURED, at `CanvasCardMetrics.itemLabelOnlyHeight`.**
    /// A node with no `cachedHeight` has no `frame`, and both
    /// `CanvasScene.nodes(intersecting:)` and `topmostNode(at:)` drop one that has
    /// none — neither drawn nor clickable, and persisted that way through a save.
    /// That is 1C-c3's whole-branch Critical, and this is the door it would arrive
    /// through next. The floor is the honest number rather than a placeholder: an
    /// item card's height *is* the label-only floor until its thumbnail decodes, and
    /// the decode is unbounded while the writer is holding a mouse button.
    /// `CanvasClaudePlacement` writes the same constant at creation for the same
    /// reason, and `CanvasView.rebuildLayouts` refines it to the picture's real
    /// shape on the very next pass — inside the same undo bracket, see `apply`.
    ///
    /// The drop point is the card's ORIGIN, exactly as `CanvasInteraction.createScrap`
    /// treats a double-click's point: one rule for where a new card appears.
    static func decide(payload: String,
                       at contentPoint: CGPoint,
                       in scene: CanvasScene,
                       index: CanvasItemIndex) -> Decision {
        guard index.entry(of: payload) != nil else { return .ignored }
        let id = CanvasNodeID.item(payload)
        guard scene.node(id) == nil else { return .reveal(id) }
        return .create(CanvasNode(id: id,
                                  kind: .item(.project(id: payload)),
                                  origin: contentPoint,
                                  width: CanvasInteraction.defaultScrapWidth,
                                  cachedHeight: CanvasCardMetrics.itemLabelOnlyHeight,
                                  z: scene.topZ + 1))
    }

    /// Land a `.create` decision: one undo step, one card, and the membership the
    /// drop point means.
    ///
    /// **`mutateFromInspector` and not `mutate` — tripwire 32, from a fifth
    /// direction.** A drag that starts in the binder never reaches
    /// `CanvasView.handleClick`, and `handleClick` is the only thing that runs
    /// `commitActiveEdit`. So the writer can be inside a scrap with "Edit Scrap"
    /// held open at the moment the drop lands, and *nothing on either side of the
    /// drag closes their bracket*: double-click bare canvas, type, then drag a
    /// research row in without touching the canvas again. Through the inside verbs
    /// this **nests** — `beginGesture` takes no snapshot at depth 2 and
    /// `endGesture` registers nothing above depth 0 — so the card reaches no undo
    /// step of its own and rides into the writer's next sentence, where a ⌘Z aimed
    /// at that sentence takes the card with it. The verb's delivery *site* is the
    /// canvas view; what tripwire 32 turns on is whether the arriving mutation has
    /// a bracket **of its own** to protect, and a drop has none, exactly as an
    /// `add_canvas_scraps` call has none. `CanvasView.deleteSelection`'s refusal is
    /// the other answer and is wrong here: mid-gesture a ⌫ is genuinely ambiguous,
    /// and a drop is not — refusing would make dragging a note in do nothing at
    /// all whenever the writer had a scrap open, silently.
    ///
    /// The accepted cost, which is the same one every other user of this verb
    /// pays: with "Edit Scrap" open, the drop closes the writer's run of typing
    /// into its own step first and reopens the visit afterwards, so they get one
    /// extra ⌘Z boundary in a sentence they were part-way through.
    ///
    /// **Insert and join in ONE body, and there is no ordering to get wrong here
    /// because the node arrives measured.** `joinTarget` reads the node's CENTRE
    /// and returns nil for a node with no `frame`, so a join asked of an
    /// unmeasured node silently joins nothing — on every drop, for ever, with
    /// nothing red. `decide` closes that by construction rather than by an
    /// ordering: the card is born at `CanvasCardMetrics.itemLabelOnlyHeight`, the
    /// same constant `CanvasClaudePlacement` writes at creation for the same
    /// reason. The refinement to the picture's real height arrives on the next
    /// line anyway — `mutateFromInspector` fires `onSceneChangedExternally`, which
    /// `CanvasView` binds to `rebuildLayouts`, **inside this bracket** — so the
    /// re-measure belongs to the step the writer can take back.
    ///
    /// The consequence of measuring at the floor is stated rather than avoided:
    /// the centre the join reads is the label-only card's, so an item whose
    /// photograph has not decoded yet joins by a centre 17 pt below its origin
    /// rather than by the taller card's. Awaiting a decode to make it exact is not
    /// available — the wait is unbounded and the writer is holding a mouse button.
    ///
    /// **The bump is on its own line**, as it is for every writer that reaches the
    /// scene through this verb: a region inspector open in the other column has to
    /// see the card that just joined, or it goes on showing "No cards live in this
    /// region yet" over a card the canvas has already drawn inside it.
    static func apply(_ node: CanvasNode, in model: CanvasModel) {
        model.mutateFromInspector(undoStepName) { scene in
            scene.insert(node)
            // Tripwire 31: this is the drop's ONE geometric reading, it is
            // `CanvasInteraction.joinTarget`'s rather than a second
            // `region.frame.contains(…)` written here, and it reads the node's
            // CENTRE. Creation absorbs; transitions never do.
            if let home = CanvasInteraction.joinTarget(for: node.id, in: scene) {
                CanvasMembership.join(node.id, home: home, in: &scene)
            }
        }
        model.bumpSceneRevision()
    }
}
