import Foundation

/// §4.4, the bridge: *"the nodes that live in a piece's region become the
/// pinned references beside the editor when you write it, and the context the
/// authoring compiler reads."* As with every bare § in this directory, that is
/// the **planning-canvas** design's §4.4 (*"Regions bind to pieces — this is the
/// bridge"*), which quotes the sentence from the umbrella design's §8 and says
/// so. M1A's brief for this file read the § against the umbrella spec, found no
/// §4.4 there, and concluded the citation was wrong; it is not, and the
/// disambiguation is here so the next reader does not repeat the check.
///
/// **Consumed by `list_canvas`, and the reference rail is M2's** (M1A Task 10).
/// This comment used to say *"Produced here, consumed in 1A. The reference rail
/// is 1A's work"* — but umbrella §10 assigns the intent strip, pinned references
/// and the assistant column to **M2**, and always did. What 1A gave the
/// projection is a *reader* rather than a rail: `ListCanvasTool` reports it as
/// `piece_references`, so the two rules below are on the wire instead of being
/// re-derived — wrongly, as `home ∪ appearances` — by whoever reads
/// `bound_piece_id` raw. `RegionBindingTests.test_theProjectionHasAProduction
/// Caller` is the census that keeps that the one call site.
///
/// `RegionInspector` is what makes the binding inspectable and changeable —
/// CLAUDE.md rule 8 is satisfied by that surface, not by a reader — and §6.2's
/// promotion destination is its other reader.
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

    /// **Residents only, for a REGION's binding.** A visitor is cited, not
    /// owned — bind on appearances and two regions sharing a card would each
    /// claim it as their piece's context (§4.4). Unioned across regions,
    /// because more than one region may bind to the same piece and each
    /// contributes what lives in it.
    ///
    /// `CanvasMembership.residents` rather than `homeMembers` directly, so a
    /// stale id in a hand-edited sidecar cannot become a pinned reference to a
    /// card that is not on the canvas.
    ///
    /// **M2 widening: a card's OWN `boundPieceID` (§6.2's association) is a
    /// second source**, unioned in alongside the region-residency source
    /// above — a card the writer has explicitly tied to a piece is that
    /// piece's context whether or not it lives inside a region bound to the
    /// same piece. This does not touch the region rule: a card merely
    /// *visiting* a bound region still owes its presence to nothing but its
    /// own `boundPieceID`, so `test_aVisitingCardIsNotOneOfThePiecesReferences`
    /// stays green untouched.
    static func references(forPiece piece: String, in scene: CanvasScene) -> Set<CanvasNodeID> {
        let fromRegions = scene.unorderedRegions
            .filter { $0.boundPieceID == piece }
            .reduce(into: Set<CanvasNodeID>()) {
                $0.formUnion(CanvasMembership.residents(of: $1.id, in: scene))
            }
        let selfBound = scene.unorderedNodes
            .filter { $0.boundPieceID == piece }
            .map(\.id)
        return fromRegions.union(selfBound)
    }
}
