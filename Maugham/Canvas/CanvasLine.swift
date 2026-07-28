import Foundation

/// Stable identity for a line. Minted by `CanvasInteraction` with a uniqueness
/// loop against the scene, exactly as `createScrap` and `createRegion` mint
/// theirs — never by a bare random call.
public struct CanvasLineID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// A freeform line between two nodes.
///
/// **Untyped, deliberately, and it must not gain a `kind`** (spec §5, §9).
/// Kinopio built author-typed connections, shipped them for years, and removed
/// them in April 2026 because "connection types were confusing for people I
/// observed using the tool for the first time". An untyped edge with an optional
/// free-text label is the empirically supported floor.
///
/// A line carries no semantics and asserts nothing. It costs nothing to draw and
/// nothing to be wrong about, which is what thinking needs. `[[wiki-links]]`
/// remain the durable relationship layer, reached deliberately through promotion
/// — and that precedence is stated in the guide, and in 1C-c2's promotion sheet
/// where it costs the writer something.
public struct CanvasLine: Equatable, Sendable {
    public let id: CanvasLineID
    public var from: CanvasNodeID
    public var to: CanvasNodeID
    /// Optional free text. Not a type, not a vocabulary, not validated.
    public var label: String?

    public init(id: CanvasLineID, from: CanvasNodeID, to: CanvasNodeID, label: String? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
    }

    public func touches(_ node: CanvasNodeID) -> Bool { from == node || to == node }
}

/// Clicking a line. Kept out of `CanvasScene` so the geometry is a pure function
/// with no scene state to get wrong, testable against literal arithmetic rather
/// than against itself.
public enum CanvasLineHit {

    /// Pointer slop. The stroke is far too thin to aim at, so the target is
    /// deliberately much larger than the ink — the same reason the card's resize
    /// TARGET is the whole corner square while its MARK is only the triangle.
    public static let tolerance: CGFloat = 6

    /// Distance from `point` to the SEGMENT `a`–`b`, clamped at BOTH ends.
    /// Without the clamp a click far beyond either card still lands on the
    /// infinite line the segment sits on.
    public static func distance(from point: CGPoint,
                                toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// The NEAREST line within `tolerance`, or nil. Nearest and not first-found:
    /// two lines leaving the same card run within a few points of each other for
    /// their whole first stretch, and picking either would be a coin flip the
    /// writer cannot predict.
    ///
    /// Lines whose endpoints are unmeasured are skipped — they are not drawn,
    /// and an invisible target is a click the writer cannot explain.
    public static func line(at point: CGPoint, in scene: CanvasScene) -> CanvasLineID? {
        var best: (id: CanvasLineID, distance: CGFloat)?
        for line in scene.lines {
            guard let ends = scene.endpoints(of: line) else { continue }
            let d = distance(from: point, toSegment: ends.0, ends.1)
            guard d <= tolerance, best == nil || d < best!.distance else { continue }
            best = (line.id, d)
        }
        return best?.id
    }
}
