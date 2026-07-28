import Foundation

/// Stable identity for a canvas node. A scrap's id is minted here; an item
/// node's id is derived from the thing it points at, so the same research
/// note can never appear twice on the canvas by accident.
public struct CanvasNodeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }

    /// Item nodes are identified by what they reference. Two adds of the same
    /// research item resolve to one node.
    ///
    /// 1C-a does not create item nodes — 1C-d owns the drag-in route (spec
    /// §8A.1) — but this spelling is consumed by 1C-b and 1C-c and by the
    /// sidecar codec, so it lives here and is pinned by test.
    public static func item(_ referenceId: String) -> CanvasNodeID {
        CanvasNodeID("item:\(referenceId)")
    }
}

/// What a node *is*. The distinction is the whole data model (spec §3):
/// items already exist and the canvas holds only their position; scraps exist
/// only here.
public enum CanvasNodeKind: Equatable, Sendable {
    /// A loose thought typed straight onto the canvas. Text lives in
    /// `canvas.md`, keyed by the node id. This is the ONLY kind 1C-a creates.
    case scrap
    /// Something that already exists in the project. `referenceId` is the
    /// research item id / palette card id. The canvas NEVER writes to it.
    ///
    /// In 1C-a an item node draws as a PLACEHOLDER card carrying its reference
    /// id. 1C-d adds the drop target, the real title, the kind glyph and the
    /// thumbnail path. Do not build any of that here.
    case item(referenceId: String)
}

/// One node. `width` is authoritative; the text reflows to fit and the height
/// is derived (spec §7A.3). `cachedHeight` is the last measured height, held so
/// layout is stable until something forces a re-measure.
public struct CanvasNode: Equatable, Sendable {
    public let id: CanvasNodeID
    public var kind: CanvasNodeKind
    public var origin: CGPoint
    /// The CARD's width, not the text box's — see `CanvasCardMetrics`.
    public var width: CGFloat
    public var cachedHeight: CGFloat?
    public var z: Int
    /// The durable artifact this scrap has been promoted into, if any (spec §6).
    ///
    /// **Provenance, not a live link.** A promotion is a SNAPSHOT taken by an
    /// explicit act and it never syncs — edit the card afterwards and the note
    /// does not change, edit the note and the card does not. Spec §6's table is
    /// what makes a region promote to a palette card while its members stay on
    /// the canvas; §6.1's 2026-07-28 amendment rules that a scrap must follow
    /// the same snapshot rule, so one verb does not end up with two behaviours.
    ///
    /// **Nothing here validates it against the manifest, and nothing can** —
    /// the scene has never seen one. A writer who deletes the note leaves an id
    /// that resolves to nothing; a promoted id is resolved against the project
    /// manifest by its READERS rather than trusted here, and the index that
    /// does that arrives with the promotion model (this slice's Task 2).
    public var promotedItemID: String?

    public init(id: CanvasNodeID,
                kind: CanvasNodeKind,
                origin: CGPoint,
                width: CGFloat,
                cachedHeight: CGFloat? = nil,
                z: Int = 0,
                promotedItemID: String? = nil) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.width = width
        self.cachedHeight = cachedHeight
        self.z = z
        self.promotedItemID = promotedItemID
    }

    /// The node's rect in canvas content coordinates, or nil if it has never
    /// been measured. A node with no measured height must not be hit-testable —
    /// guessing a height would let an unmeasured node swallow clicks.
    public var frame: CGRect? {
        guard let h = cachedHeight else { return nil }
        return CGRect(origin: origin, size: CGSize(width: width, height: h))
    }
}

/// Card geometry, in ONE place.
///
/// `CanvasNode.width` is the CARD width; the text box inside it is inset on all
/// four sides, and the card's height is the measured text height plus the same
/// inset twice. Both `CanvasRenderer` (which draws the text) and `CanvasView`
/// (which mounts the editor over it) read these functions.
///
/// A second spelling of the inset anywhere would put the drawn glyphs and the
/// edited glyphs on different rects — which is precisely the §7A.2 "text jumps
/// on focus" failure, arriving by the back door.
public enum CanvasCardMetrics {
    /// Text flush to a card edge reads as broken. 10pt is the same breathing
    /// room `PaletteCardTile` gives its content.
    public static let inset: CGFloat = 10
    /// Below this a scrap wraps to one word per line and the measured height
    /// runs away.
    public static let minimumTextWidth: CGFloat = 40

    public static func textWidth(forCardWidth width: CGFloat) -> CGFloat {
        max(minimumTextWidth, width - inset * 2)
    }

    public static func cardHeight(forTextHeight height: CGFloat) -> CGFloat {
        height + inset * 2
    }

    public static func textOrigin(inCard frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + inset, y: frame.minY + inset)
    }

    public static func textSize(inCard frame: CGRect) -> CGSize {
        CGSize(width: textWidth(forCardWidth: frame.width),
               height: max(0, frame.height - inset * 2))
    }
}
