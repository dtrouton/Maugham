import Foundation
import MaughamCore

/// Stable identity for a canvas node. A scrap's id is minted; a *referenced*
/// item node's id is derived from the thing it points at, so the same research
/// note can never appear twice on the canvas by accident.
///
/// **An OWNED item node's id is minted too, and that is not an oversight**
/// (1C-d, `CanvasItemReference.owned`). There is nothing to deduplicate — each
/// ingestion writes its own file under `canvas_assets/` — and a filesystem path
/// does not belong in an identity: it would put the whole of tripwire 22's
/// rename hazard into the one field nothing may rewrite. Whoever creates one
/// mints it the way every other id on this surface is minted
/// (`CanvasInteraction.createScrap`'s retry-against-the-scene loop, or
/// `CanvasClaudePlacement.newNodeID` when a whole batch is planned against a
/// scene it must not touch). There is no sixth spelling.
public struct CanvasNodeID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }

    /// Item nodes are identified by what they reference. Two adds of the same
    /// research item resolve to one node.
    ///
    /// **1C-c3 is the first producer**: `CanvasClaudePlacement` mints one for the
    /// page a batch of scraps was read off. Until then nothing in production
    /// called this — the spelling existed for 1C-b, 1C-c and the sidecar codec,
    /// and several comments in this directory rested on "nothing creates item
    /// nodes yet". They no longer can. 1C-d still owns the writer's own drag-in
    /// route (spec §8A.1) and the thumbnail that goes with it.
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
    /// Something the canvas shows as itself rather than as words: a research
    /// item or palette card that already exists in the project, or a photograph
    /// the canvas ingested and owns. `CanvasItemReference` is which, and its own
    /// doc comment carries why that distinction is nested here rather than
    /// standing beside `.scrap` as a third kind.
    ///
    /// An item node still draws as a PLACEHOLDER card carrying its reference id.
    /// 1C-d's later tasks add the drop target, the real title, the kind glyph
    /// and the thumbnail.
    case item(CanvasItemReference)
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

    /// This scrap's own piece association (spec §6.2) — the same field a
    /// region carries (`CanvasRegion.boundPieceID`), set in the inspector.
    ///
    /// **The override, not the inheritance.** `Promotion.piece(for:in:)` reads
    /// this FIRST, before it ever asks what region the node lives in — a
    /// scrap's own choice always wins over its home region's, and a scrap that
    /// merely *appears* in a bound region (§4.3's reference, not luggage)
    /// inherits nothing from either field.
    public var boundPieceID: String?

    /// The artifact a promotion of this card's HOME REGION folded this card's
    /// text into (spec §6.3) — written alongside the region's own
    /// `promotedItemID` mark, in the same undo bracket.
    ///
    /// **This is NOT `promotedItemID`, and the distinction is load-bearing
    /// rather than tidy.** `promotedItemID` means *"I am this artifact"* and
    /// `Promotion.existingArtifact` reads it to offer **Rewrite**. Stamping a
    /// contributor with the same field would let promoting one member
    /// afterwards offer to rewrite the whole joint note with that one card's
    /// text — the 1C-c2 Critical (a mark that did not record the artifact's
    /// *kind*) returning as a mark that does not record its *cardinality*. So
    /// a contribution record must never be read where `promotedItemID` is
    /// read, and re-promoting a contributing card offers only a new artifact.
    ///
    /// A card may carry both, and they say different things: it produced its
    /// own note, *and* its words are in a region's.
    public var contributedToItemID: String?

    /// Who made this card. **nil means the writer**, which is why there is no
    /// `.human` default: every card on every canvas written before 1C-c3 is the
    /// writer's, and inventing a value for them would put an `author` key in
    /// every sidecar for a feature nobody had used.
    ///
    /// **Written once, at creation, and never afterwards** — which is why
    /// `CanvasScene` has no `setAuthor` beside `setPromotedItem`,
    /// `setBoundPiece` and `setContributedItem`. Those three record something
    /// that *happened to* a card and can be undone; this records where the card
    /// came from, and that does not change because the writer edited it. A
    /// setter would make provenance something the canvas can quietly rewrite.
    ///
    /// It reuses the annotation layer's provenance shape by name
    /// (`AnnotationAuthor.SourceKind`, spec §8A.2) rather than minting a second
    /// enum, so "Claude wrote this" means one thing across the whole app.
    public var author: AnnotationAuthor.SourceKind?

    public init(id: CanvasNodeID,
                kind: CanvasNodeKind,
                origin: CGPoint,
                width: CGFloat,
                cachedHeight: CGFloat? = nil,
                z: Int = 0,
                promotedItemID: String? = nil,
                boundPieceID: String? = nil,
                contributedToItemID: String? = nil,
                author: AnnotationAuthor.SourceKind? = nil) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.width = width
        self.cachedHeight = cachedHeight
        self.z = z
        self.promotedItemID = promotedItemID
        self.boundPieceID = boundPieceID
        self.contributedToItemID = contributedToItemID
        self.author = author
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

    /// The size `CanvasRenderer` draws an item node's title at, and the size
    /// `itemLabelLineHeight` measures a line of it with. **One constant because
    /// those two must agree**: the card's height is derived from that line, so a
    /// renderer that drew it a point larger would clip the only thing on a card
    /// with no picture, and nothing about a card that is one point short looks
    /// like a broken measurement.
    public static let itemLabelFontSize: CGFloat = 11

    /// The rest of an item card's geometry — `itemLabelLineHeight`,
    /// `itemLabelOnlyHeight` (the floor), the gaps, and the rects the picture and
    /// the label are drawn in — lives in `CanvasScrapMeasure.swift`, because
    /// measuring a line of text needs `NSFont` and the model types in this
    /// directory are deliberately Foundation-only. They are still members of this
    /// type, because this is where a card's geometry is looked up.

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
