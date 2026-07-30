import Foundation
import MaughamCore

/// Where Claude's nodes go (spec §8A.2) — **pure**, and that is the whole point
/// of the file.
///
/// Claude sends words and, optionally, the research item it read them off. It
/// sends no id, no coordinate and no size: *where* they land is the canvas's
/// decision, which is the structural guarantee behind the write tool's
/// signature. This type is that decision, taken once, so the two persistence
/// routes in Task 5 — the attached `CanvasModel` and a transient `CanvasStore`
/// over the sidecar — cannot place the same request differently.
///
/// **`plan` never mutates and `apply` is the only writer of a `Plan`.** That is
/// `Promotion`/`PromotionPerformer`'s split, and `Maugham/Canvas/AREA.md` calls
/// the line between them load-bearing: a planner that mutated as it decided
/// could not be asked twice and could not be tested without a scene to inspect
/// afterwards. Here `plan` takes the scene by value, so the compiler enforces
/// it; `test_planningNeverMutatesTheScene` guards the day someone reaches for
/// `inout` to save a copy.
///
/// **Creation reads geometry; membership does not.** The region's frame is
/// chosen by looking at what is already on the canvas, which is legitimate —
/// creation has no prior relationship to contradict (§4.2's amendment, ADR 0026
/// §8). But nothing here decides *membership* from a rect: the scraps join the
/// region because this call made them inside it, which is a fact about the
/// request. There is no `region.frame.contains(…)` in this file and there must
/// never be one; `CanvasMembership` records, and no function in it takes a
/// point, a rect or an overlap (tripwire 31).
enum CanvasClaudePlacement {

    // MARK: - Calibration
    //
    // Placement numbers, not look numbers — `CanvasMaterial` owns the values
    // Denver tunes by eye. These decide where a batch lands, and every one of
    // them is free to change: no test pins a coordinate, because Claude cannot
    // express one and so nothing outside this file depends on the answer.

    /// Clear air between the writer's work and Claude's region.
    ///
    /// **Not decoration.** `CGRect.intersects` is false for rects that merely
    /// touch, so without this term the region would still "not overlap" anything
    /// while abutting the writer's rightmost card — which on screen reads as a
    /// card wedged into a region's edge.
    /// `test_theRegionLandsClearOfEverythingAlreadyOnTheCanvas` asks for
    /// clearance rather than non-overlap for exactly that reason.
    static let gutter: CGFloat = 60

    /// Where the first batch lands on a canvas with nothing measured on it. Off
    /// the origin, so the region's chrome bar is not flush against the corner the
    /// camera starts at.
    static let emptyCanvasOrigin = CGPoint(x: 40, y: 40)

    /// Breathing room between the region's edge and the column inside it — the
    /// same 10-plus room `CanvasCardMetrics` and `CanvasRegionMetrics` give their
    /// contents, widened because a card has a drawn edge of its own.
    static let padding: CGFloat = 16

    /// Vertical air between one card and the next.
    static let cardGap: CGFloat = 12

    /// What a region is called when the caller named nothing.
    ///
    /// Plan ruling 5: every add lands in a region and the region is *labelled* —
    /// nothing Claude adds is ever loose, and a batch arriving as
    /// `CanvasRegion.untitledLabel` would be indistinguishable from a region the
    /// writer swept and has not named yet.
    ///
    /// **Task 8 is expected to announce a Claude card as "from Claude"**, so this
    /// wording is chosen to be that phrase rather than a second one. It is a
    /// claim about a file that does not exist yet: if Task 8 lands a different
    /// spelling, one of the two must move, or the writer meets two names for one
    /// fact.
    static let defaultRegionLabel = "From Claude"

    // MARK: - Request

    /// One `add_canvas_scraps` call, with the parts the placer needs.
    ///
    /// **`plan` may assume this is already valid.** Empty and whitespace-only
    /// scraps, an unresolvable `sourceReferenceID`, and a `connections` pair that
    /// is out of range or names one index twice are all the *tool's* refusals —
    /// they fail loudly there, with a sentence that teaches, because a silently
    /// dropped line is a caller believing something exists that does not.
    struct Request {
        /// In reading order. The column is laid out in this order, and
        /// `connections` indexes it.
        var scraps: [String]
        /// The research item the words were read off, if any — a *reference id*,
        /// not a node id and not an inbox entry id (spec §8A.4 records why the
        /// asymmetry with the writer's own route exists).
        var sourceReferenceID: String?
        /// Resolved by the caller, which is the layer that can read a title out
        /// of the manifest.
        var regionLabel: String?
        /// Pairs of indices into `scraps` — this call's own array, so Claude can
        /// draw the arrows it read off a page and can reach nothing the writer
        /// made.
        var connections: [(Int, Int)]

        init(scraps: [String],
             sourceReferenceID: String? = nil,
             regionLabel: String? = nil,
             connections: [(Int, Int)] = []) {
            self.scraps = scraps
            self.sourceReferenceID = sourceReferenceID
            self.regionLabel = regionLabel
            self.connections = connections
        }
    }

    // MARK: - Plan

    /// A card to be created, **with its words**.
    ///
    /// The pairing is the point. The applier writes the sidecar and `canvas.md`
    /// from one value; a text array handed alongside the plan would be a second
    /// chance for the nodes and the words to disagree about which scrap is which,
    /// and nothing downstream could tell.
    struct PlannedScrap: Equatable {
        let node: CanvasNode
        let text: String
    }

    /// What to do about the page the scraps were read off.
    ///
    /// Three cases and not two booleans, because "insert it" and "home it here"
    /// are separate decisions that must not be able to disagree.
    ///
    /// **An existing node is never moved.** Relocating the writer's card into a
    /// new region would be a geometry-driven *transition* changing membership —
    /// the bug class Obsidian, Scapple and tldraw each ship a different version
    /// of, and the one tldraw has *despite* storing membership explicitly. One
    /// home, many appearances (§4.3): a second batch off the same page cites it
    /// where it already lives.
    enum PlannedSource: Equatable {
        /// Not on the canvas yet. `apply` inserts it and the new region homes it.
        case created(CanvasNode)
        /// On the canvas with nowhere to live — nothing is inserted and nothing
        /// moves, but the new region becomes its home, because it had none to
        /// take away.
        case adopted(CanvasNodeID)
        /// On the canvas with a home already. Cited here, left exactly where the
        /// writer put it.
        case cited(CanvasNodeID)

        var id: CanvasNodeID {
            switch self {
            case .created(let node): return node.id
            case .adopted(let id), .cited(let id): return id
            }
        }

        /// The node this plan would insert, or nil when the page is already on
        /// the canvas and only its membership is changing.
        var createdNode: CanvasNode? {
            if case .created(let node) = self { return node }
            return nil
        }
    }

    /// Everything to be written, and nothing that has been written.
    ///
    /// **Carries no `CanvasScene`.** It is a description of an addition, so the
    /// live route and the sidecar route can each apply it to their own scene and
    /// arrive at the same place.
    struct Plan: Equatable {
        let regionID: CanvasRegionID
        let regionLabel: String
        let regionFrame: CGRect
        /// nil when the call named no source. The region is still there and still
        /// labelled — nothing Claude adds is loose (§8A.2 constraint 2).
        let source: PlannedSource?
        /// In the request's order, top to bottom down the column.
        let scraps: [PlannedScrap]
        let lines: [CanvasLine]

        /// The words, keyed by the node that will hold them — what
        /// `CanvasModel.setScrapText` and `CanvasStore.save(scene:scraps:)` both
        /// want. Derived from `scraps`, so it cannot drift from the cards.
        ///
        /// `uniquingKeysWith` rather than `uniqueKeysWithValues`, which traps on
        /// a duplicate key. `plan`'s minter cannot produce one — but this is
        /// reached from an MCP call, and the reasoning that keeps a bad
        /// `connections` pair from trapping applies here or it applies nowhere.
        var scrapTexts: [CanvasNodeID: String] {
            Dictionary(scraps.map { ($0.node.id, $0.text) },
                       uniquingKeysWith: { _, later in later })
        }
    }

    // MARK: - Planning

    /// Decide where a validated request lands, without touching the scene.
    static func plan(_ request: Request, in scene: CanvasScene) -> Plan {
        let origin = regionOrigin(in: scene)
        let cardX = origin.x + padding
        // The column starts under the chrome bar, or the first card would cover
        // the label. `columnBottom` trails it and only moves when a card is
        // actually placed — deriving it as `y - cardGap` instead subtracts a gap
        // that was never added on a request that places nothing.
        var y = origin.y + CanvasRegionMetrics.chromeHeight + padding
        var columnBottom = y
        var z = scene.topZ

        // `apply` needs this before any member exists, and both the region and
        // its members are built from one `Plan`. (It is NOT a collision concern:
        // regions and nodes are separate id spaces and `newRegionID` checks only
        // `scene.region(_:)`, so minting order means nothing here.)
        let regionID = newRegionID(in: scene)

        // The page goes at the TOP of the column, so reading order puts it above
        // what was read off it (§8A.2's reproduction corollary). A page already
        // on the canvas reserves no column space: it stays where it is.
        var source: PlannedSource?
        if let reference = request.sourceReferenceID {
            let id = CanvasNodeID.item(reference)
            if scene.node(id) != nil {
                source = CanvasMembership.homeRegion(of: id, in: scene) == nil
                    ? .adopted(id) : .cited(id)
            } else {
                z += 1
                // **`author: .claude`, and the earlier `nil` here was wrong.**
                //
                // This comment used to say the opposite, with a reason that was
                // sound while the tint was the only signal: the tint means *these
                // words came off a machine*, and a photographed page's words are
                // the writer's, so tinting this node would say Claude took the
                // photograph. That is still true, and `CanvasRenderer.paper(for:)`
                // still refuses to tint an item node for exactly it.
                //
                // What changed is that there are now TWO signals and they answer
                // different questions. The tint asks *whose words are these*; the
                // TILT asks *who put this here*, and Claude did — it minted this
                // node, chose its place and its region. `author` is the field
                // `CanvasNode.author`'s own doc comment defines as "who made this
                // card", so nil was recording something false in order to get a
                // colour decision the renderer now makes on its own.
                //
                // The result is the honest reading of both: the source page is
                // drawn STRAIGHT (Claude placed it) and UNTINTED (the words are
                // the writer's). The rule is not deleted, it is relocated — to
                // `paper(for:)`, where the question it answers is actually asked.
                source = .created(CanvasNode(id: id,
                                             kind: .item(.project(id: reference)),
                                             origin: CGPoint(x: cardX, y: y),
                                             width: CanvasInteraction.defaultScrapWidth,
                                             cachedHeight: CanvasCardMetrics.itemLabelOnlyHeight,
                                             z: z,
                                             author: .claude))
                columnBottom = y + CanvasCardMetrics.itemLabelOnlyHeight
                y = columnBottom + cardGap
            }
        }

        // A real measured height on every card, or the card has no `frame` — and
        // `CanvasScene.nodes(intersecting:)` and `.topmostNode(at:)` both drop a
        // node with no frame, so it is neither drawn nor clickable. On the
        // sidecar route nothing would ever measure it.
        var mintedNodeIDs: Set<CanvasNodeID> = []
        var scraps: [PlannedScrap] = []
        for text in request.scraps {
            let id = newNodeID(in: scene, excluding: mintedNodeIDs)
            mintedNodeIDs.insert(id)
            let height = CanvasScrapMeasure.height(
                text: text, cardWidth: CanvasInteraction.defaultScrapWidth)
            z += 1
            scraps.append(PlannedScrap(
                node: CanvasNode(id: id,
                                 kind: .scrap,
                                 origin: CGPoint(x: cardX, y: y),
                                 width: CanvasInteraction.defaultScrapWidth,
                                 cachedHeight: height,
                                 z: z,
                                 author: .claude),
                text: text))
            columnBottom = y + height
            y = columnBottom + cardGap
        }

        // A region the writer could not have swept is a region the canvas must
        // not mint either — `CanvasInteraction.createRegion` refuses anything
        // under `minimumSide`, and a floor here is cheaper than discovering the
        // two disagree.
        //
        // **The two clamps are not both live, and saying so is the point.** The
        // width is `240 + 32` unconditionally, so its `max` can never fire; it is
        // folded in anyway because the rule is about the region, not about one
        // axis, and splitting them would invite tuning one past the floor. The
        // HEIGHT clamp does fire: a request placing nothing at all is
        // `24 + 16 + 16 = 56` against a floor of 80. Nothing reaches that today
        // — the tool refuses an empty `scraps` array before `plan` is called —
        // so this is a guard held up by an upstream assumption rather than dead
        // arithmetic, and `test_aRegionIsNeverSmallerThanOneTheWriterCouldSweep`
        // exercises it directly rather than trusting that assumption to hold.
        let frame = CGRect(
            x: origin.x,
            y: origin.y,
            width: max(CanvasRegionMetrics.minimumSide,
                       CanvasInteraction.defaultScrapWidth + padding * 2),
            height: max(CanvasRegionMetrics.minimumSide,
                        columnBottom + padding - origin.y))

        return Plan(regionID: regionID,
                    regionLabel: label(for: request),
                    regionFrame: frame,
                    source: source,
                    scraps: scraps,
                    lines: lines(for: request, over: scraps, in: scene))
    }

    /// The only writer of a `Plan`, so Task 5's two routes produce identical
    /// scenes rather than similar ones.
    ///
    /// Membership is recorded through `CanvasMembership` and nowhere else — the
    /// region is inserted with empty member sets and the joins follow, rather
    /// than the members being handed to `CanvasRegion.init`. That keeps one
    /// mutation surface for membership even on a creation path where the answer
    /// is never in doubt.
    ///
    /// **A `Plan` is only valid against the scene it was planned against.** Its
    /// ids are unique against *that* scene and its frame was computed from *that*
    /// scene's occupancy, so applying one to a different scene can drop Claude's
    /// region on top of the writer's work and can overwrite a node by id. Task 5
    /// has two persistence routes and that is exactly the shape that invites
    /// "plan once, apply twice": each route must call `plan` against the scene it
    /// is about to write.
    static func apply(_ plan: Plan, to scene: inout CanvasScene) {
        // `author: .claude` — the region is the one primitive every call creates,
        // so it is where "straight means Claude" earns most of its keep. A region
        // carries no tint (it has no paper, only a wash felt rather than seen);
        // the angle is the whole of its provenance. See `CanvasRegion.author`.
        scene.insertRegion(CanvasRegion(id: plan.regionID,
                                        label: plan.regionLabel,
                                        frame: plan.regionFrame,
                                        author: .claude))

        if let source = plan.source {
            switch source {
            case .created(let node):
                scene.insert(node)
                CanvasMembership.join(node.id, home: plan.regionID, in: &scene)
            case .adopted(let id):
                CanvasMembership.join(id, home: plan.regionID, in: &scene)
            case .cited(let id):
                // Never `join`: that moves the home, and moving the writer's card
                // is the transition membership never is.
                CanvasMembership.addAppearance(id, to: plan.regionID, in: &scene)
            }
        }

        for planned in plan.scraps {
            scene.insert(planned.node)
            CanvasMembership.join(planned.node.id, home: plan.regionID, in: &scene)
        }

        for line in plan.lines { scene.insertLine(line) }
    }

    // MARK: - Pieces of the decision

    /// The top-left corner of the new region: to the right of the bounding box of
    /// everything measured on the canvas, plus the gutter.
    ///
    /// Unmeasured nodes are skipped because they have no geometry to keep off —
    /// they are not drawn either. The union is order-independent, which is what
    /// makes the answer the same twice running.
    private static func regionOrigin(in scene: CanvasScene) -> CGPoint {
        var occupied: CGRect?
        for frame in scene.unorderedNodes.compactMap(\.frame) + scene.regions.map(\.frame) {
            occupied = occupied.map { $0.union(frame) } ?? frame
        }
        guard let occupied else { return emptyCanvasOrigin }
        return CGPoint(x: occupied.maxX + gutter, y: occupied.minY)
    }

    private static func label(for request: Request) -> String {
        let named = request.regionLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return named.isEmpty ? defaultRegionLabel : named
    }

    /// Lines among the cards this call is creating, and nothing else.
    ///
    /// The `guard` is a floor rather than a refusal: an out-of-range or
    /// self-naming pair is the tool's to reject, loudly, before `plan` is ever
    /// called. It is here so a gap in that validation cannot trap on an index —
    /// the alternative to skipping is a crash inside an MCP call.
    private static func lines(for request: Request,
                              over scraps: [PlannedScrap],
                              in scene: CanvasScene) -> [CanvasLine] {
        var minted: Set<CanvasLineID> = []
        var lines: [CanvasLine] = []
        for (from, to) in request.connections {
            guard from != to,
                  scraps.indices.contains(from),
                  scraps.indices.contains(to) else { continue }
            let id = newLineID(in: scene, excluding: minted)
            minted.insert(id)
            // No label: a label from Claude on an edge is the nearest thing to
            // the typed edge §5 spends its length rejecting. The writer names it
            // in the inspector in a second.
            lines.append(CanvasLine(id: id,
                                    from: scraps[from].node.id,
                                    to: scraps[to].node.id,
                                    label: nil,
                                    author: .claude))
        }
        return lines
    }

    // MARK: - Ids
    //
    // The uniqueness loop `CanvasInteraction.createScrap`, `newLineID(in:)` and
    // `createRegion` all use — never a bare mint (tripwire 23). Four random
    // characters over ~1.05M collide at manuscript scale, and a bare mint cost
    // this codebase a paste crash.
    //
    // These take an `excluding` set as well as the scene, which the gesture
    // versions do not need: those insert into the scene as they go, and this
    // plans a whole batch against a scene it must not touch.

    private static func newNodeID(in scene: CanvasScene,
                                  excluding minted: Set<CanvasNodeID>) -> CanvasNodeID {
        var id = CanvasNodeID(UUID().uuidString.prefix(8).lowercased())
        while scene.node(id) != nil || minted.contains(id) {
            id = CanvasNodeID(UUID().uuidString.prefix(8).lowercased())
        }
        return id
    }

    private static func newRegionID(in scene: CanvasScene) -> CanvasRegionID {
        var id = CanvasRegionID(UUID().uuidString.prefix(8).lowercased())
        while scene.region(id) != nil {
            id = CanvasRegionID(UUID().uuidString.prefix(8).lowercased())
        }
        return id
    }

    private static func newLineID(in scene: CanvasScene,
                                  excluding minted: Set<CanvasLineID>) -> CanvasLineID {
        var id = CanvasLineID(UUID().uuidString.prefix(8).lowercased())
        while scene.line(id) != nil || minted.contains(id) {
            id = CanvasLineID(UUID().uuidString.prefix(8).lowercased())
        }
        return id
    }
}
