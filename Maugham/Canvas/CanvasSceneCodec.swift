import Foundation

/// The on-disk shape of `.maugham/canvas.json`.
///
/// Derived UI state (spec §8): positions, geometry and seeds. Deletable without
/// loss of content — the words live in `canvas.md`. Kept separate from
/// `CanvasScene` so the in-memory model is free to change shape without
/// rewriting every writer's sidecar.
struct CanvasSceneDTO: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var nodes: [NodeDTO]

    struct NodeDTO: Codable {
        var id: String
        var kind: String            // "scrap" | "item"
        var referenceId: String?    // set when kind == "item"
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var cachedHeight: CGFloat?
        var z: Int
    }

    init(scene: CanvasScene) {
        schemaVersion = Self.currentSchemaVersion
        nodes = scene.nodes.map { n in
            switch n.kind {
            case .scrap:
                return NodeDTO(id: n.id.raw, kind: "scrap", referenceId: nil,
                               x: n.origin.x, y: n.origin.y, width: n.width,
                               cachedHeight: n.cachedHeight, z: n.z)
            case .item(let ref):
                return NodeDTO(id: n.id.raw, kind: "item", referenceId: ref,
                               x: n.origin.x, y: n.origin.y, width: n.width,
                               cachedHeight: n.cachedHeight, z: n.z)
            }
        }
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
                                width: dto.width, cachedHeight: dto.cachedHeight, z: dto.z))
        }
        return s
    }
}
