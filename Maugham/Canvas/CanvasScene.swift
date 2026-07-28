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
}
