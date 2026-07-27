import Foundation

/// The membership rules (spec §4.2–§4.4), as free functions over the scene.
///
/// **Every mutation here is a deliberate act.** There is no entry point that
/// takes a point, a rect or an overlap — the drop gesture in
/// `CanvasInteraction` decides *which* region a drop meant and then calls
/// `join`; deciding is the gesture's job and recording is this file's, and
/// keeping the two apart is what stops geometry leaking into membership.
public enum CanvasMembership {

    /// Make `region` the node's home, taking it out of whatever region it lived
    /// in before. One home, always (§4.3).
    public static func join(_ node: CanvasNodeID,
                            home region: CanvasRegionID,
                            in scene: inout CanvasScene) {
        for other in scene.unorderedRegions where other.id != region && other.livesHere(node) {
            scene.updateRegion(other.id) { $0.forget(node) }
        }
        scene.updateRegion(region) { $0.addHome(node) }
    }

    /// Cite the node in `region` without moving it there. A reference, not a
    /// copy — "copies are rejected outright" (§4.3).
    public static func addAppearance(_ node: CanvasNodeID,
                                     to region: CanvasRegionID,
                                     in scene: inout CanvasScene) {
        scene.updateRegion(region) { $0.addAppearance(node) }
    }

    /// Take the node out of `region` entirely, whichever way it was in.
    /// Removal is always its own act; nothing about a coordinate reaches here.
    public static func leave(_ node: CanvasNodeID,
                             from region: CanvasRegionID,
                             in scene: inout CanvasScene) {
        scene.updateRegion(region) { $0.forget(node) }
    }

    public static func homeRegion(of node: CanvasNodeID,
                                  in scene: CanvasScene) -> CanvasRegionID? {
        scene.unorderedRegions.first { $0.livesHere(node) }?.id
    }

    /// In `regions` order, so the inspector and the renderer list a node's
    /// appearances the same way twice running.
    public static func appearanceRegions(of node: CanvasNodeID,
                                         in scene: CanvasScene) -> [CanvasRegionID] {
        scene.regions.filter { $0.appearsHere(node) }.map(\.id)
    }

    /// What travels when the region is dragged: its residents, and only those
    /// that are still real nodes. Filtering on the scene here is what stops a
    /// stale id — from a hand-edited sidecar, or from a node deleted in a
    /// snapshot the undo has not yet caught up with — reaching the drag loop.
    public static func residents(of region: CanvasRegionID,
                                 in scene: CanvasScene) -> Set<CanvasNodeID> {
        guard let r = scene.region(region) else { return [] }
        return r.homeMembers.filter { scene.node($0) != nil }
    }
}
