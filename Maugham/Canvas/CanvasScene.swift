import Foundation

/// Every node on one project's canvas, and every region on it. One canvas per
/// project (spec §2); regions do all the dividing.
///
/// Pure value type with no I/O — `CanvasStore` owns persistence. Nodes are held
/// in a dictionary for lookup plus an explicit z-order, because the draw pass
/// walks in z-order and hit testing walks it in reverse.
public struct CanvasScene: Equatable, Sendable {
    private var byID: [CanvasNodeID: CanvasNode]
    private var regionsByID: [CanvasRegionID: CanvasRegion] = [:]
    private var linesByID: [CanvasLineID: CanvasLine] = [:]

    /// Residents of collapsed regions, precomputed.
    ///
    /// Hit testing and culling both consult this, and both run at pointer rate
    /// over the whole scene — asking each node "is any collapsed region my home"
    /// inside those loops is `O(nodes × regions)` per click and per frame. It is
    /// refreshed only when a region changes, which is a gesture, not a frame.
    private var hiddenNodes: Set<CanvasNodeID> = []

    public init(nodes: [CanvasNode] = [], regions: [CanvasRegion] = []) {
        byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        regionsByID = Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        refreshHiddenNodes()
    }

    /// Nodes in draw order — back to front. The id is the tiebreak so the order
    /// is total and stable: two nodes at the same z must not swap places
    /// between frames, or the front-most-wins hit test becomes a coin flip.
    ///
    /// **This sorts on every access.** Nothing that runs per frame — a `body`, a
    /// draw loop, an accessibility rebuild — may reach for it without a reason.
    /// Use `unorderedNodes` when you impose your own order and `count` when you
    /// only want the number.
    public var nodes: [CanvasNode] {
        byID.values.sorted(by: Self.isBehind)
    }

    /// Every node, in NO defined order. For callers that sort by something else
    /// — `CanvasAccessibility` reads the canvas out in rows then columns, so
    /// paying for the draw-order sort first and then re-sorting is pure waste.
    public var unorderedNodes: [CanvasNode] { Array(byID.values) }

    /// The node count, without materialising or sorting the list.
    /// `CanvasAccessibility.summary` is read from `body`.
    public var count: Int { byID.count }

    public var isEmpty: Bool { byID.isEmpty }

    /// The total draw order: z, then id. Factored out so `nodes`,
    /// `topmostNode(at:)` and `nodes(intersecting:)` cannot disagree about which
    /// card is in front.
    private static func isBehind(_ a: CanvasNode, _ b: CanvasNode) -> Bool {
        (a.z, a.id.raw) < (b.z, b.id.raw)
    }

    /// Highest z in the scene, or 0 when empty. `+ 1` is where a new node goes.
    public var topZ: Int { byID.values.map(\.z).max() ?? 0 }

    public func node(_ id: CanvasNodeID) -> CanvasNode? { byID[id] }

    public mutating func insert(_ node: CanvasNode) { byID[node.id] = node }

    /// Removes the node, and every region's record of it. A ghost member would
    /// resurface in the inspector's "lives here" list and in
    /// `RegionBinding.references(forPiece:)` long after the card was gone.
    public mutating func remove(_ id: CanvasNodeID) {
        byID[id] = nil
        for region in regionsByID.values where region.mentions(id) {
            regionsByID[region.id]?.forget(id)
        }
        // A line to a node that is gone would draw into nowhere. `linesByID.keys`
        // is a live view onto the dictionary; writing through `linesByID` while
        // iterating it is the kind of thing copy-on-write happens to make safe
        // rather than the kind of thing that IS safe.
        for lineID in Array(linesByID.keys) where linesByID[lineID]?.touches(id) == true {
            linesByID[lineID] = nil
        }
        refreshHiddenNodes()
    }

    public mutating func move(_ id: CanvasNodeID, to origin: CGPoint) {
        byID[id]?.origin = origin
    }

    public mutating func setWidth(_ width: CGFloat, for id: CanvasNodeID) {
        // A width change invalidates the derived height; the next measure pass
        // refills it. Leaving a stale height here is how a resized scrap would
        // hit-test against its old shape.
        byID[id]?.width = width
        byID[id]?.cachedHeight = nil
    }

    public mutating func setCachedHeight(_ height: CGFloat, for id: CanvasNodeID) {
        byID[id]?.cachedHeight = height
    }

    /// Record (or clear) the artifact a scrap was promoted into.
    ///
    /// A region's mark goes through `updateRegion(_:_:)`, which already exists —
    /// a second spelling would be two ways to write one field.
    public mutating func setPromotedItem(_ itemID: String?, for id: CanvasNodeID) {
        byID[id]?.promotedItemID = itemID
    }

    /// Record (or clear) a scrap's OWN piece association (spec §6.2) — the
    /// override, not the inheritance. Setting a region's `boundPieceID` never
    /// comes through here or any other write to a member's own field: the more
    /// specific setting wins by being read first, never by being written down.
    public mutating func setBoundPiece(_ pieceID: String?, for id: CanvasNodeID) {
        byID[id]?.boundPieceID = pieceID
    }

    /// Record that a promotion folded this card's content into `itemID`
    /// (spec §6.3) — **not** the promotion mark. See
    /// `CanvasNode.contributedToItemIDs`' doc comment for why the two must
    /// never be conflated: this field must never be readable as an Update.
    ///
    /// **Append, never overwrite (RULING-51).** A record the card already
    /// carries is left where it is; another artifact's record is not this
    /// write's to discard — that is exactly how the single-valued field lost
    /// note A's fact when note B was promoted.
    public mutating func addContribution(_ itemID: String, to id: CanvasNodeID) {
        guard let node = byID[id], !node.contributedToItemIDs.contains(itemID)
        else { return }
        byID[id]?.contributedToItemIDs.append(itemID)
    }

    /// Take back ONE artifact's contribution record — the rewrite path's verb,
    /// scoped to the artifact being rewritten. There is deliberately no
    /// clear-all sibling: every caller knows which artifact it is un-recording,
    /// and a whole-record wipe is the overwrite bug with a different spelling.
    public mutating func removeContribution(_ itemID: String, from id: CanvasNodeID) {
        byID[id]?.contributedToItemIDs.removeAll { $0 == itemID }
    }

    /// Point every mark naming `oldID` at `newID` instead, and say how many
    /// moved (M1A adoption; whole-branch review, I4).
    ///
    /// **The artifact is the same object under a new id, so the mark follows
    /// it.** Adoption moves a legacy craft-intent research note's prose into a
    /// `Statement` and trashes the note, which takes its manifest entry with it —
    /// so a card promoted to craft intent under 1C-c2 is left naming an id
    /// `ArtifactIndex.over` can no longer resolve, and every reader of that mark
    /// then says something false: `PromotedArtifactSection` renders
    /// `.artifactMissing`, telling the writer their intent was deleted over
    /// prose sitting in the new pane, and `Promotion.hasDanglingMark` answers
    /// true, so a line promotion between two such cards is refused with "Promote
    /// that card again first" for something that worked.
    ///
    /// Both fields, because both name an artifact and both have a reader that
    /// goes wrong: `promotedItemID` is *"I am this artifact"*, `contributedToItemID`
    /// is *"my words went into it"* (spec §6.3), and clearing rather than
    /// re-pointing either would make a promoted card look and sound un-promoted
    /// — the trap `ArtifactIndex.over` already names.
    ///
    /// Pure and counted so the caller can decide whether a write is needed at
    /// all, and so the rule can be asserted over a scene rather than through a
    /// migration.
    @discardableResult
    public mutating func repointMarks(from oldID: String, to newID: String) -> Int {
        guard oldID != newID else { return 0 }
        var moved = 0
        for (id, node) in byID {
            if node.promotedItemID == oldID {
                byID[id]?.promotedItemID = newID
                moved += 1
            }
            if let index = node.contributedToItemIDs.firstIndex(of: oldID) {
                if node.contributedToItemIDs.contains(newID) {
                    // Both ids on one card can only mean the artifact fed by
                    // both spellings is one artifact; keep the surviving id
                    // once rather than twice.
                    byID[id]?.contributedToItemIDs.remove(at: index)
                } else {
                    byID[id]?.contributedToItemIDs[index] = newID
                }
                moved += 1
            }
        }
        for (id, region) in regionsByID where region.promotedItemID == oldID {
            regionsByID[id]?.promotedItemID = newID
            moved += 1
        }
        return moved
    }

    /// Highest node whose measured frame contains `point`, in content
    /// coordinates. Front-most wins.
    ///
    /// Filter first, then take the maximum — `nodes.reversed().first { … }`
    /// would sort the whole scene on every click for one answer.
    ///
    /// Residents of a collapsed region are skipped, so hit testing agrees with
    /// drawing by construction rather than by a parameter threaded to callers.
    public func topmostNode(at point: CGPoint) -> CanvasNode? {
        byID.values
            .filter { !hiddenNodes.contains($0.id) && $0.frame?.contains(point) == true }
            .max(by: Self.isBehind)
    }

    /// Nodes whose frame intersects `rect`, in draw order. This is the whole of
    /// virtualisation (spec §7A.1): culling is an intersection test in the draw
    /// loop, not a `ForEach` the renderer has to keep view identity for.
    ///
    /// Filter first, then order the survivors. Sorting the scene and then
    /// filtering gives the same answer for `O(scene log scene)` instead of
    /// `O(scene + visible log visible)`, inside the loop Task 16 asserts is
    /// proportional to the viewport.
    ///
    /// Residents of a collapsed region are skipped here too — that is what makes
    /// "collapse hides its residents" one rule in the scene rather than one in
    /// the renderer and another in the hit test. `unorderedNodes` deliberately
    /// still returns them: `CanvasView.rebuildLayouts()` must keep measuring a
    /// hidden scrap, or expanding the region shows unmeasured, unclickable cards.
    public func nodes(intersecting rect: CGRect) -> [CanvasNode] {
        byID.values
            .filter { !hiddenNodes.contains($0.id) && $0.frame?.intersects(rect) == true }
            .sorted(by: Self.isBehind)
    }

    // MARK: - Regions

    /// Regions in a total, stable order. There is no z among regions — they all
    /// draw beneath every card — so id order is enough, and it is what makes the
    /// sidecar byte-identical across a save of an unchanged canvas.
    public var regions: [CanvasRegion] {
        regionsByID.values.sorted { $0.id.raw < $1.id.raw }
    }

    public var unorderedRegions: [CanvasRegion] { Array(regionsByID.values) }
    public var regionCount: Int { regionsByID.count }

    public func region(_ id: CanvasRegionID) -> CanvasRegion? { regionsByID[id] }

    /// Whether this node is a resident of a collapsed region, and therefore not
    /// on screen, not clickable and not in the accessibility tree.
    public func isHidden(_ id: CanvasNodeID) -> Bool { hiddenNodes.contains(id) }

    public mutating func insertRegion(_ region: CanvasRegion) {
        regionsByID[region.id] = region
        refreshHiddenNodes()
    }

    /// Removes the region and nothing else. **Its cards stay on the canvas** —
    /// spec §3.1's rule for items generalised: the canvas owns arrangement, not
    /// existence.
    public mutating func removeRegion(_ id: CanvasRegionID) {
        regionsByID[id] = nil
        refreshHiddenNodes()
    }

    public mutating func updateRegion(_ id: CanvasRegionID,
                                      _ body: (inout CanvasRegion) -> Void) {
        guard regionsByID[id] != nil else { return }
        body(&regionsByID[id]!)
        refreshHiddenNodes()
    }

    public mutating func setRegionFrame(_ frame: CGRect, for id: CanvasRegionID) {
        regionsByID[id]?.frame = frame
        // Deliberately no `refreshHiddenNodes()`: a frame change cannot alter
        // membership, which is the whole of §4.2. Calling it here would be
        // harmless and would still be the wrong shape — the next reader would
        // read it as geometry feeding membership.
    }

    private mutating func refreshHiddenNodes() {
        guard regionsByID.values.contains(where: \.isCollapsed) else {
            hiddenNodes = []
            return
        }
        hiddenNodes = regionsByID.values
            .filter(\.isCollapsed)
            .reduce(into: Set<CanvasNodeID>()) { $0.formUnion($1.homeMembers) }
    }

    // MARK: - Lines

    /// Lines in a total, stable order, id-sorted for the same reason
    /// `regions` is — a total order that makes an unchanged canvas's sidecar
    /// byte-identical across a save.
    ///
    /// **This sorts on every access, and unlike `nodes` that is accepted here.**
    /// The per-frame reader is `CanvasRenderer.visibleLines`, and lines are
    /// bounded by nothing — a writer can draw one per card — so the sort *is*
    /// on the frame path. It is accepted only because the collection is small
    /// in practice and the culling filter runs after it. **If a canvas ever
    /// makes this measurable, the fix is an `unorderedLines` peer, exactly as
    /// `nodes`/`unorderedNodes` split** — the next author should reintroduce
    /// that split rather than `nodes`' original bug.
    public var lines: [CanvasLine] {
        linesByID.values.sorted { $0.id.raw < $1.id.raw }
    }

    /// One line by id — a dictionary lookup, and the peer of `node(_:)` and
    /// `region(_:)`.
    ///
    /// **Reach for this and not `lines.first { … }`**: the ordered accessor
    /// above sorts the whole set on every access, and a single-line lookup is
    /// exactly the reader that ends up inside a `body` evaluation. That is the
    /// `CanvasAccessibility.summary` regression — `scene.nodes.count` read from
    /// `body`, a full sort per render — in a second id space.
    public func line(_ id: CanvasLineID) -> CanvasLine? { linesByID[id] }

    /// Rejects a line from a node to itself — it has nothing to say and draws
    /// as a blob.
    public mutating func insertLine(_ line: CanvasLine) {
        guard line.from != line.to else { return }
        linesByID[line.id] = line
    }

    public mutating func removeLine(_ id: CanvasLineID) {
        linesByID[id] = nil
    }

    public mutating func updateLine(_ id: CanvasLineID, _ body: (inout CanvasLine) -> Void) {
        guard linesByID[id] != nil else { return }
        body(&linesByID[id]!)
    }

    /// The line count, without materialising or sorting the list — the peer of
    /// `count` and for the same reason. `CanvasAccessibility.summary` is read
    /// from `body`, and `lines` above sorts the whole set with a `String`
    /// comparison in its predicate.
    public var lineCount: Int { linesByID.count }

    /// The line's endpoints as node CENTRES — the same reading
    /// `CanvasInteraction.joinTarget` takes for a drop, so the canvas has one
    /// answer to "where is this card". Nil unless BOTH ends are measured: an
    /// unmeasured node has no `frame` at all, and drawing to a guessed
    /// position would twitch the instant the real measurement arrived.
    public func endpoints(of line: CanvasLine) -> (CGPoint, CGPoint)? {
        guard let fromFrame = byID[line.from]?.frame, let toFrame = byID[line.to]?.frame else { return nil }
        return (CGPoint(x: fromFrame.midX, y: fromFrame.midY),
                CGPoint(x: toFrame.midX, y: toFrame.midY))
    }

    /// Every line that is actually ON the canvas, resolved to two points. The
    /// UNCULLED projection: `CanvasRenderer.visibleLines` culls it for the draw
    /// pass, and `CanvasLineHit` walks it whole, because a click always arrives
    /// inside the viewport.
    ///
    /// **Two conditions take a line off the canvas, and they are stated once,
    /// here.** An unmeasured endpoint has no frame, so nothing was drawn to run
    /// a line to — and drawing to a guessed position would twitch the instant
    /// the real measurement arrived. A HIDDEN endpoint (a resident of a
    /// collapsed region) is the one that is easy to miss, because the geometry
    /// says nothing: collapsing keeps the node's frame and hides it through
    /// `hiddenNodes`, so `endpoints(of:)` answers happily and this filter is the
    /// only thing between the writer and a line running into bare ground. It is
    /// the rule `CanvasRenderer.tethers` and `.appearanceChips` already follow.
    ///
    /// **Drawing and hit testing take the identical rule because they read the
    /// identical function.** Spelled twice they would drift, and the failure is
    /// silent in the worse direction: a line the writer can click and cannot see
    /// is worse than one they can see and cannot click.
    ///
    /// Ordered, because `lines` is — see there for why that sort is accepted on
    /// the frame path and what to do if it ever stops being.
    public var drawnLines: [CanvasDrawnLine] {
        lines.compactMap { line in
            guard !isHidden(line.from), !isHidden(line.to),
                  let ends = endpoints(of: line) else { return nil }
            return CanvasDrawnLine(id: line.id, from: ends.0, to: ends.1, label: line.label,
                                   author: line.author)
        }
    }

    // MARK: - What a click selects

    /// What a click at `contentPoint` selects, or nil for bare ground.
    ///
    /// **ONE RULE: cards over lines over regions — and that order is the DRAW
    /// order read backwards.** The thing drawn on top takes the click. Cards come
    /// first and unconditionally, matching `CanvasInteraction.begin`'s own
    /// precedence, so clicking a thing and dragging it never disagree about which
    /// thing it was; lines come next because they draw above every part of a
    /// region — its wash, its chrome bar, its label and its resize triangle.
    /// `CanvasLineGestureTests.test_theClickOrderIsTheDrawOrderReadBackwards`
    /// asserts the two orders against each other rather than each against a
    /// literal, so a change to one that is not made to the other goes red.
    ///
    /// **A draft of this had the chrome bar beat the line**, on the ground that
    /// the bar is a region's only grab handle. It reads perfectly plausible and
    /// it is wrong: it leaves the line drawn OVER the bar while the bar takes the
    /// click, so hit testing disagrees with what is visibly frontmost. Neither
    /// loss is worth a special case — a near-perpendicular crossing costs the
    /// line ~24 pt of a length in the hundreds, and the bar ~12 pt of a width in
    /// the hundreds. If someone re-opens this, the question to put to them is
    /// which package they are proposing WHOLE: draw order and click order move
    /// together, or the defect comes straight back.
    ///
    /// A click on a region's interior selects nothing, for the same reason the
    /// interior is not a grab handle: it belongs to the cards in it.
    ///
    /// **It lives on the SCENE, and it was a `static func` on `CanvasView`.** The
    /// second caller is `CanvasInteraction.begin`, which asks it so that a press
    /// and a click cannot disagree about what was under the pointer — the right
    /// sharing, pointing the wrong way: the gesture state machine had to reach
    /// into a SwiftUI `View` to learn a fact about the scene. One spelling
    /// survives, with every caller above it. Being a plain function of its inputs
    /// is what keeps it reachable from a test that hosts no SwiftUI, and a
    /// routing decision one level above a primitive is exactly where this area
    /// has shipped unreachable halves.
    public func selectionTarget(at contentPoint: CGPoint) -> CanvasSelection? {
        if let node = topmostNode(at: contentPoint) { return .node(node.id) }
        if let line = CanvasLineHit.line(at: contentPoint, in: self) { return .line(line) }
        switch CanvasInteraction.regionHit(at: contentPoint, in: self) {
        case .chrome(let id), .resizeCorner(let id): return .region(id)
        case nil: return nil
        }
    }
}
