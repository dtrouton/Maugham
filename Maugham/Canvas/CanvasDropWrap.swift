import Foundation

/// **A drop on bare canvas while a chapter is selected arrives in a region
/// bound to that chapter** (spec §2, Denver's decision). Pure: the drop paths
/// (`CanvasDrop.apply`, `CanvasExternalDrop.apply`, `CanvasCapture.apply`)
/// call it inside their own undo bracket, after each item has joined any
/// region its centre landed in.
///
/// An item node carries no chapter of its own (`Promotion.piece(for:in:)`:
/// an owned item inherits and never carries), so the region is how a dropped
/// photograph or research card comes to belong to the chapter.
///
/// **The region joins only the dropped items, never bystanders.** It is the
/// drop's container, not a sweep, so it never asks `absorbedNodes`.
enum CanvasDropWrap {

    /// The chapter a drop is wrapped in under `subject`, or nil (the book, a
    /// group or a research item leaves the drop loose). Read at drop time.
    static func piece(for subject: CanvasSubject) -> String? {
        if case .piece(let piece) = subject { return piece }
        return nil
    }

    /// Wrap those of `ids` that live in no region in one new region bound to
    /// `piece`, and return it; nil when every item already found a home.
    ///
    /// The items must be measured (an unmeasured node has no frame and is
    /// left out). Membership goes through `CanvasMembership.join`.
    @discardableResult
    static func wrap(_ ids: [CanvasNodeID], toPiece piece: String,
                     in scene: inout CanvasScene) -> CanvasRegionID? {
        var members: [CanvasNodeID] = []
        var frames: [CGRect] = []
        for id in ids where CanvasMembership.homeRegion(of: id, in: scene) == nil {
            guard let frame = scene.node(id)?.frame else { continue }
            members.append(id)
            frames.append(frame)
        }
        guard !members.isEmpty else { return nil }
        let region = CanvasInteraction.newRegionID(in: scene)
        // Unlabelled, as a sweep's is: the title opens for typing (Task 8).
        scene.insertRegion(CanvasRegion(id: region, label: "",
                                        frame: frame(around: frames),
                                        boundPieceID: piece))
        for id in members { CanvasMembership.join(id, home: region, in: &scene) }
        return region
    }

    /// The union of `frames`, padded by `CanvasClaudePlacement.padding` with
    /// the chrome bar above, and at least `CanvasRegionMetrics.minimumSide`
    /// on each side (grown right and down, so the chrome stays where it is).
    static func frame(around frames: [CGRect]) -> CGRect {
        guard let first = frames.first else { return .null }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        let pad = CanvasClaudePlacement.padding
        let chrome = CanvasRegionMetrics.chromeHeight
        let side = CanvasRegionMetrics.minimumSide
        return CGRect(x: union.minX - pad,
                      y: union.minY - chrome - pad,
                      width: max(union.width + 2 * pad, side),
                      height: max(union.height + chrome + 2 * pad, side))
    }
}
