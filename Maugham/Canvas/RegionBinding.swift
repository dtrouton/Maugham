import Foundation

/// §4.4, the bridge: *"the nodes that live in a piece's region become the
/// pinned references beside the editor when you write it, and the context the
/// authoring compiler reads."*
///
/// **Produced here, consumed in 1A.** The reference rail is 1A's work and 1A is
/// unwritten; the binding is the durable half and has to exist before the
/// consumer can be built. `RegionInspector` is what makes it inspectable and
/// changeable today — CLAUDE.md rule 8 is satisfied by that surface, not by a
/// reader, and a field only a test can reach is a field that rots.
enum RegionBinding {

    static func bind(_ region: CanvasRegionID, toPiece piece: String,
                     in scene: inout CanvasScene) {
        scene.updateRegion(region) { $0.boundPieceID = piece }
    }

    static func unbind(_ region: CanvasRegionID, in scene: inout CanvasScene) {
        scene.updateRegion(region) { $0.boundPieceID = nil }
    }

    static func boundPiece(of region: CanvasRegionID, in scene: CanvasScene) -> String? {
        scene.region(region)?.boundPieceID
    }

    /// **Residents only.** A visitor is cited, not owned — bind on appearances
    /// and two regions sharing a card would each claim it as their piece's
    /// context (§4.4). Unioned across regions, because more than one region may
    /// bind to the same piece and each contributes what lives in it.
    ///
    /// `CanvasMembership.residents` rather than `homeMembers` directly, so a
    /// stale id in a hand-edited sidecar cannot become a pinned reference to a
    /// card that is not on the canvas.
    static func references(forPiece piece: String, in scene: CanvasScene) -> Set<CanvasNodeID> {
        scene.unorderedRegions
            .filter { $0.boundPieceID == piece }
            .reduce(into: Set<CanvasNodeID>()) {
                $0.formUnion(CanvasMembership.residents(of: $1.id, in: scene))
            }
    }
}
