import Foundation

/// Stable identity for a region. Minted by `CanvasInteraction.createRegion`
/// with a uniqueness loop against the scene — never by a bare random call
/// (tripwire 23's lesson, applied to a second id space).
public struct CanvasRegionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// What the canvas has selected. ONE selection covers every primitive, so ⌫
/// has a single meaning and the inspector has a single thing to read.
///
/// **A new case is added at the RENDERER's request, not at the click handler's**
/// — the renderer is the first consumer that needs one, and adding the case makes
/// the compiler enumerate every reader at once. In this area a caller count is
/// what has found every unreachable half; here the compiler does it for free.
public enum CanvasSelection: Equatable, Sendable {
    case node(CanvasNodeID)
    case region(CanvasRegionID)
    case line(CanvasLineID)
}

/// A labelled area drawn on the canvas — the canvas's only grouping primitive
/// (spec §4).
///
/// **Membership is stored here and is changed only by a deliberate act.**
/// **CREATION ABSORBS; TRANSITIONS DO NOT** (Denver, 2026-07-28 — spec §4.2
/// amendment, ADR 0026 §8). Moving or resizing a region never adds or removes a
/// member; a sweep takes in every card whose **centre** it was drawn around, a
/// scrap made inside a region joins it, and a card dropped so its centre lands
/// inside joins. The transition half is the load-bearing one — all three tools
/// `AREA.md` cites were bitten deciding whether an *existing* relationship
/// survives a geometry change, which creation cannot be.
///
/// See `CanvasMembership` for the mutations, `CanvasInteraction.absorbedNodes`
/// and `.joinTarget` for the two places geometry is legitimately read, and
/// `AREA.md` for the three tools.
///
/// The two sets are disjoint by construction — `addHome` drops the node from
/// `appearances` and `addAppearance` declines when the node already lives here.
/// A node in both would draw as a card and as a reference chip at once, which is
/// exactly the "you cannot tell which is real" failure §4.3 forbids.
public struct CanvasRegion: Equatable, Sendable {

    /// Shown wherever the label would be blank. A region drawn by a drag starts
    /// unlabelled and is named in the inspector, so this is the common case for
    /// the first few seconds of every region's life — it must not read as empty
    /// chrome.
    public static let untitledLabel = "Untitled region"

    public let id: CanvasRegionID
    public var label: String
    public var frame: CGRect
    /// Nodes that LIVE here. Only these travel when the region is dragged, and
    /// only these are bound to the region's piece (§4.4).
    public private(set) var homeMembers: Set<CanvasNodeID>
    /// Nodes that merely APPEAR here — references, never copies (§4.3).
    public private(set) var appearances: Set<CanvasNodeID>
    /// §4.4's bridge. Produced here, consumed by 1A's reference rail.
    public var boundPieceID: String?
    /// §7/§10: crowding at Playlist scale is answered by collapsing, not by
    /// minting more canvases.
    public var isCollapsed: Bool
    /// The palette card this region has been promoted into, if any (spec §6).
    /// Same provenance-not-a-link rule as `CanvasNode.promotedItemID`, and the
    /// same absence of validation — see there.
    ///
    /// Deliberately NOT `boundPieceID`'s sibling in meaning: a binding is a live
    /// relationship 1A's reference rail reads every time it draws, and this is a
    /// record of something that happened once.
    public var promotedItemID: String?

    public init(id: CanvasRegionID,
                label: String,
                frame: CGRect,
                homeMembers: Set<CanvasNodeID> = [],
                appearances: Set<CanvasNodeID> = [],
                boundPieceID: String? = nil,
                isCollapsed: Bool = false,
                promotedItemID: String? = nil) {
        self.id = id
        self.label = label
        self.frame = frame
        self.homeMembers = homeMembers
        // Enforced at the initialiser too, because the codec builds regions
        // through it and a hand-edited sidecar is not obliged to be coherent.
        self.appearances = appearances.subtracting(homeMembers)
        self.boundPieceID = boundPieceID
        self.isCollapsed = isCollapsed
        self.promotedItemID = promotedItemID
    }

    public var displayLabel: String { label.isEmpty ? Self.untitledLabel : label }

    public func livesHere(_ id: CanvasNodeID) -> Bool { homeMembers.contains(id) }
    public func appearsHere(_ id: CanvasNodeID) -> Bool { appearances.contains(id) }
    public func mentions(_ id: CanvasNodeID) -> Bool { livesHere(id) || appearsHere(id) }

    public mutating func addHome(_ id: CanvasNodeID) {
        appearances.remove(id)
        homeMembers.insert(id)
    }

    public mutating func addAppearance(_ id: CanvasNodeID) {
        guard !homeMembers.contains(id) else { return }
        appearances.insert(id)
    }

    public mutating func forget(_ id: CanvasNodeID) {
        homeMembers.remove(id)
        appearances.remove(id)
    }
}

/// Region geometry, in ONE place — the same discipline `CanvasCardMetrics`
/// applies to cards, and for the same reason: `CanvasRenderer` draws the chrome
/// bar and the resize corner, `CanvasInteraction` hit-tests them, and a second
/// spelling puts the mark and the target on different rects.
public enum CanvasRegionMetrics {
    /// The label bar along the top — the only part of a region a writer can
    /// grab. The interior belongs to the cards in it: grabbing anywhere inside
    /// would make it impossible to pick up a card that sits in a region, which
    /// is most of them.
    public static let chromeHeight: CGFloat = 24
    /// Matches `CanvasRenderer.resizeHandleSize` in intent, not by reference:
    /// the two targets are on different objects and either may be tuned without
    /// the other.
    public static let resizeHandleSide: CGFloat = 14
    /// Below this a region has no interior left to hold anything, and its two
    /// grab targets would meet.
    public static let minimumSide: CGFloat = 80
    /// Breathing room for the label inside the chrome bar. Same 10pt
    /// `CanvasCardMetrics` gives a card's text.
    public static let labelInset: CGFloat = 10

    public static func chromeRect(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY,
               width: frame.width, height: min(chromeHeight, frame.height))
    }

    public static func resizeHandleRect(in frame: CGRect) -> CGRect {
        CGRect(x: frame.maxX - resizeHandleSide, y: frame.maxY - resizeHandleSide,
               width: resizeHandleSide, height: resizeHandleSide)
    }

    public static func labelOrigin(in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + labelInset, y: frame.minY + labelInset / 2)
    }
}
