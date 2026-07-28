import Foundation

/// The on-disk shape of `.maugham/canvas.json`.
///
/// Derived UI state (spec §8): positions, geometry and seeds. Deletable without
/// loss of content — the words live in `canvas.md`. Kept separate from
/// `CanvasScene` so the in-memory model is free to change shape without
/// rewriting every writer's sidecar.
struct CanvasSceneDTO: Codable {
    static let currentSchemaVersion = 4   // was 3 (lines, 1C-c1)

    var schemaVersion: Int
    var nodes: [NodeDTO]
    /// Optional so a schema-1 sidecar — every canvas 1C-a wrote — decodes
    /// unchanged rather than throwing on a missing key.
    var regions: [RegionDTO]?
    /// Optional so a schema-3 sidecar — every canvas 1C-c1 wrote — decodes
    /// unchanged. **1C-c2 added `promotedItemID` to nodes and regions rather
    /// than a key of its own here**, which is why this bump has no new
    /// top-level collection: the mark belongs to the thing it marks.
    var lines: [LineDTO]?

    struct NodeDTO: Codable {
        var id: String
        var kind: String            // "scrap" | "item"
        var referenceId: String?    // set when kind == "item"
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var cachedHeight: CGFloat?
        var z: Int
        var promotedItemID: String?
    }

    struct RegionDTO: Codable {
        var id: String
        var label: String
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        /// Sorted on the way out. `Set` iteration order is not stable across
        /// runs, and an unsorted array here makes saving an unchanged canvas
        /// produce a different file every time.
        var homeMembers: [String]
        var appearances: [String]
        var boundPieceID: String?
        var isCollapsed: Bool
        var promotedItemID: String?
    }

    struct LineDTO: Codable {
        var id, from, to: String
        var label: String?
    }

    init(scene: CanvasScene) {
        schemaVersion = Self.currentSchemaVersion
        nodes = scene.nodes.map { n in
            switch n.kind {
            case .scrap:
                return NodeDTO(id: n.id.raw, kind: "scrap", referenceId: nil,
                               x: n.origin.x, y: n.origin.y, width: n.width,
                               cachedHeight: n.cachedHeight, z: n.z,
                               promotedItemID: n.promotedItemID)
            case .item(let ref):
                return NodeDTO(id: n.id.raw, kind: "item", referenceId: ref,
                               x: n.origin.x, y: n.origin.y, width: n.width,
                               cachedHeight: n.cachedHeight, z: n.z,
                               promotedItemID: n.promotedItemID)
            }
        }
        regions = scene.regions.map { r in
            RegionDTO(id: r.id.raw, label: r.label,
                      x: r.frame.minX, y: r.frame.minY,
                      width: r.frame.width, height: r.frame.height,
                      homeMembers: r.homeMembers.map(\.raw).sorted(),
                      appearances: r.appearances.map(\.raw).sorted(),
                      boundPieceID: r.boundPieceID,
                      isCollapsed: r.isCollapsed,
                      promotedItemID: r.promotedItemID)
        }
        // `scene.lines` is already id-sorted (that's its own doc comment's
        // reason); a second `.sorted()` here would be a second opinion about
        // the order.
        lines = scene.lines.map { LineDTO(id: $0.id.raw, from: $0.from.raw, to: $0.to.raw, label: $0.label) }
    }

    /// Unknown node kinds are DROPPED, not fatal (ADR 0015's spirit): a canvas
    /// written by a newer build still opens, minus the nodes this build cannot
    /// draw. Losing the whole canvas because one node is from the future is the
    /// worse failure.
    var scene: CanvasScene {
        var s = CanvasScene()
        for dto in nodes {
            let kind: CanvasNodeKind?
            switch dto.kind {
            case "scrap": kind = .scrap
            case "item": kind = dto.referenceId.map { CanvasNodeKind.item(referenceId: $0) }
            default: kind = nil
            }
            guard let kind else { continue }
            s.insert(CanvasNode(id: CanvasNodeID(dto.id), kind: kind,
                                origin: CGPoint(x: dto.x, y: dto.y),
                                width: dto.width, cachedHeight: dto.cachedHeight, z: dto.z,
                                promotedItemID: dto.promotedItemID))
        }

        // AFTER the nodes, and the order is the whole of the scrub: a node of an
        // unknown kind has already been dropped by the loop above, so a region
        // naming it must lose that member too. Ordered by id so the one-home
        // repair below is deterministic rather than dependent on how the file
        // happened to be written.
        var claimedHomes: Set<CanvasNodeID> = []
        for dto in (regions ?? []).sorted(by: { $0.id < $1.id }) {
            let real = { (raws: [String]) -> Set<CanvasNodeID> in
                Set(raws.map(CanvasNodeID.init).filter { s.node($0) != nil })
            }
            var homes = real(dto.homeMembers)
            // One home per node (§4.3). A node already claimed by an earlier
            // region is demoted here rather than dropped — that region really
            // did cite it, and inventing or discarding a relationship are both
            // worse than recording the weaker true one.
            let contested = homes.intersection(claimedHomes)
            homes.subtract(contested)
            claimedHomes.formUnion(homes)

            s.insertRegion(CanvasRegion(
                id: CanvasRegionID(dto.id), label: dto.label,
                frame: CGRect(x: dto.x, y: dto.y, width: dto.width, height: dto.height),
                homeMembers: homes,
                appearances: real(dto.appearances).union(contested),
                boundPieceID: dto.boundPieceID,
                isCollapsed: dto.isCollapsed,
                promotedItemID: dto.promotedItemID))
        }

        // Endpoint validation, the same shape the region loader applies to
        // memberships: a line naming a node that is not in this file would draw
        // into nowhere. Through `insertLine` rather than the dictionary, so the
        // self-line rule has exactly one definition.
        for dto in lines ?? [] {
            let from = CanvasNodeID(dto.from), to = CanvasNodeID(dto.to)
            guard s.node(from) != nil, s.node(to) != nil else { continue }
            s.insertLine(CanvasLine(id: CanvasLineID(dto.id), from: from, to: to, label: dto.label))
        }
        return s
    }
}
