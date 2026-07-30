import Foundation
import MaughamCore

/// The on-disk shape of `.maugham/canvas.json`.
///
/// Derived UI state (spec §8): positions, geometry and seeds. Deletable without
/// loss of content — the words live in `canvas.md`. Kept separate from
/// `CanvasScene` so the in-memory model is free to change shape without
/// rewriting every writer's sidecar.
struct CanvasSceneDTO: Codable {
    static let currentSchemaVersion = 8   // was 7 (author, 1C-c3)

    var schemaVersion: Int
    var nodes: [NodeDTO]
    /// Optional so a schema-1 sidecar — every canvas 1C-a wrote — decodes
    /// unchanged rather than throwing on a missing key.
    var regions: [RegionDTO]?
    /// Optional so a schema-3 sidecar — every canvas 1C-c1 wrote — decodes
    /// unchanged. **1C-c2 added `promotedItemID` to nodes and regions rather
    /// than a key of its own here**, which is why this bump has no new
    /// top-level collection: the mark belongs to the thing it marks. **1C-c2a
    /// added `boundPieceID` to `NodeDTO` the same way** — a scrap's own piece
    /// association (spec §6.2) belongs to the node, not to a collection here.
    /// **1C-c2b added `contributedToItemID` to `NodeDTO`, same shape again** —
    /// spec §6.3's contribution record belongs to the card it describes.
    /// **1C-c3 added `author` to `NodeDTO`, `LineDTO` and `RegionDTO`, same shape
    /// once more** — who made a card belongs to the card, who drew a line to the
    /// line, and who swept a region to the region. All three arrived inside
    /// schema 7 rather than taking a bump each: they are one slice's one fact
    /// about provenance, they are optional so every older file still decodes, and
    /// no build outside this branch has ever written a 7. **1C-d added
    /// `ownedPath` to `NodeDTO`, same shape a fifth time** — which of the two
    /// provenances an item node has belongs to the node.
    var lines: [LineDTO]?

    struct NodeDTO: Codable {
        var id: String
        var kind: String            // "scrap" | "item"
        /// Set when `kind == "item"` and the item is a PROJECT reference — a
        /// research item or palette card id, which the canvas never writes to.
        var referenceId: String?
        /// Set when `kind == "item"` and the canvas OWNS the file (schema 8).
        ///
        /// **A project-relative path, and it is never written into
        /// `referenceId`.** The two fields are the two arms of
        /// `CanvasItemReference` and they are different kinds of claim: an id is
        /// resolved against the project manifest, a path against the project
        /// directory. Smearing a path into the id field would draw
        /// `Item · canvas_assets/photo-….png` on the card and dangle every
        /// reader that resolves a reference id.
        var ownedPath: String?
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var cachedHeight: CGFloat?
        var z: Int
        var promotedItemID: String?
        var boundPieceID: String?
        var contributedToItemID: String?
        /// `AnnotationAuthor.SourceKind.rawValue`, absent for the writer's own
        /// cards. Stored as a `String?` rather than the enum so an unrecognised
        /// value is a decision this file makes (see `authorKind`) instead of a
        /// throw that costs the whole sidecar.
        var author: String?
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
        /// See `NodeDTO.author`. A region carries one because a region is drawn
        /// with a seeded lean too, and straight is how the surface says Claude
        /// swept it — see `CanvasRegion.author`.
        var author: String?
    }

    struct LineDTO: Codable {
        var id, from, to: String
        var label: String?
        /// See `NodeDTO.author`.
        var author: String?
    }

    /// `author` off disk.
    ///
    /// **An unrecognised value reads as `.claude`, never as nil.** nil means the
    /// writer, and the mark means *not your words* — so over-marking a card is a
    /// question the writer can answer, while telling them they wrote a sentence
    /// they did not is one they cannot. This is the only asymmetric decode in
    /// this file: everywhere else an unreadable value is dropped (an unknown node
    /// `kind`, a line naming a missing node), because there the safe direction is
    /// to show less.
    ///
    /// **This is a floor, not a place to add author kinds.** A genuine third
    /// author wants its own `AnnotationAuthor.SourceKind` case — reached here it
    /// would be flattened into Claude's and lose its identity for good, since the
    /// sidecar is the only record.
    private static func authorKind(_ raw: String?) -> AnnotationAuthor.SourceKind? {
        guard let raw else { return nil }
        return AnnotationAuthor.SourceKind(rawValue: raw) ?? .claude
    }

    init(scene: CanvasScene) {
        schemaVersion = Self.currentSchemaVersion
        nodes = scene.nodes.map { n in
            switch n.kind {
            case .scrap:
                return NodeDTO(id: n.id.raw, kind: "scrap",
                               referenceId: nil, ownedPath: nil,
                               x: n.origin.x, y: n.origin.y, width: n.width,
                               cachedHeight: n.cachedHeight, z: n.z,
                               promotedItemID: n.promotedItemID,
                               boundPieceID: n.boundPieceID,
                               contributedToItemID: n.contributedToItemID,
                               author: n.author?.rawValue)
            case .item(.project(let id)):
                return NodeDTO(id: n.id.raw, kind: "item",
                               referenceId: id, ownedPath: nil,
                               x: n.origin.x, y: n.origin.y, width: n.width,
                               cachedHeight: n.cachedHeight, z: n.z,
                               promotedItemID: n.promotedItemID,
                               boundPieceID: n.boundPieceID,
                               contributedToItemID: n.contributedToItemID,
                               author: n.author?.rawValue)
            case .item(.owned(let path)):
                // The two arms write DISJOINT fields, which is what makes the
                // both-fields case below a hand edit rather than something this
                // encoder can produce.
                return NodeDTO(id: n.id.raw, kind: "item",
                               referenceId: nil, ownedPath: path,
                               x: n.origin.x, y: n.origin.y, width: n.width,
                               cachedHeight: n.cachedHeight, z: n.z,
                               promotedItemID: n.promotedItemID,
                               boundPieceID: n.boundPieceID,
                               contributedToItemID: n.contributedToItemID,
                               author: n.author?.rawValue)
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
                      promotedItemID: r.promotedItemID,
                      author: r.author?.rawValue)
        }
        // `scene.lines` is already id-sorted (that's its own doc comment's
        // reason); a second `.sorted()` here would be a second opinion about
        // the order.
        lines = scene.lines.map {
            LineDTO(id: $0.id.raw, from: $0.from.raw, to: $0.to.raw,
                    label: $0.label, author: $0.author?.rawValue)
        }
    }

    /// Unknown node kinds are DROPPED, not fatal (ADR 0015's spirit): a canvas
    /// written by a newer build still opens, minus the nodes this build cannot
    /// draw. Losing the whole canvas because one node is from the future is the
    /// worse failure.
    ///
    /// **An item node carrying BOTH provenances keeps the node, and the OWNED
    /// PATH WINS.** The encoder above writes disjoint fields, so only a
    /// hand-edited sidecar can say both — and this is the one place that can
    /// answer, because it cannot ask. Three reasons, and the third is why the
    /// answer is not "drop the contradictory node":
    ///
    /// - An owned path is a claim about a file **this project owns**, so
    ///   honouring it cannot dangle outside the project; honouring `referenceId`
    ///   instead points the card at an id this file gives no evidence for.
    /// - It is the precedent one loop down. The other contradiction a hand edit
    ///   can hand us — a node claimed as home by two regions — **demotes** the
    ///   loser rather than dropping it, because inventing a relationship and
    ///   discarding a true one are both worse than recording the weaker one.
    /// - Dropping loses a card the writer can see, and a card that disappears is
    ///   the worst failure available on a spatial surface.
    ///
    /// An item carrying NEITHER is still dropped: there is nothing to draw and
    /// nothing to point at, which is the pre-existing rule and not a casualty of
    /// this one.
    var scene: CanvasScene {
        var s = CanvasScene()
        for dto in nodes {
            let kind: CanvasNodeKind?
            switch dto.kind {
            case "scrap": kind = .scrap
            case "item":
                if let path = dto.ownedPath {
                    kind = .item(.owned(path: path))
                } else {
                    kind = dto.referenceId.map { CanvasNodeKind.item(.project(id: $0)) }
                }
            default: kind = nil
            }
            guard let kind else { continue }
            s.insert(CanvasNode(id: CanvasNodeID(dto.id), kind: kind,
                                origin: CGPoint(x: dto.x, y: dto.y),
                                width: dto.width, cachedHeight: dto.cachedHeight, z: dto.z,
                                promotedItemID: dto.promotedItemID,
                                boundPieceID: dto.boundPieceID,
                                contributedToItemID: dto.contributedToItemID,
                                author: Self.authorKind(dto.author)))
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
                promotedItemID: dto.promotedItemID,
                author: Self.authorKind(dto.author)))
        }

        // Endpoint validation, the same shape the region loader applies to
        // memberships: a line naming a node that is not in this file would draw
        // into nowhere. Through `insertLine` rather than the dictionary, so the
        // self-line rule has exactly one definition.
        for dto in lines ?? [] {
            let from = CanvasNodeID(dto.from), to = CanvasNodeID(dto.to)
            guard s.node(from) != nil, s.node(to) != nil else { continue }
            s.insertLine(CanvasLine(id: CanvasLineID(dto.id), from: from, to: to,
                                    label: dto.label, author: Self.authorKind(dto.author)))
        }
        return s
    }
}
