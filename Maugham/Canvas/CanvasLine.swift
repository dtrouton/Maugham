import Foundation
import MaughamCore

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
    /// Who drew this line. **nil means the writer**, and it is written once at
    /// creation and never afterwards — see `CanvasNode.author` for the whole
    /// ruling, including why `CanvasScene` gains no setter for it.
    ///
    /// **`let`, so the compiler is the enforcement** — `CanvasRegion.author`'s
    /// shape, and for `CanvasRegion.author`'s reason. `CanvasScene.updateLine` is
    /// a general block mutator (it is how a label is set and cleared), so while
    /// this was `var` a `$0.author = …` inside it compiled: the one primitive of
    /// the three whose provenance was a convention rather than a guarantee, in a
    /// file whose own doc comment said "written once at creation" as though it
    /// held everywhere. Nothing in production ever reached through it — the only
    /// field any caller writes is `label` — and this is what makes that a fact
    /// rather than a habit. Tripwire 24's argument, one field over.
    ///
    /// A line carries no semantics (see this type's own doc comment) and
    /// provenance does not give it any: this says who drew the line, not what
    /// the line means. That is also why it does not violate §5's no-`kind` rule,
    /// and why `CanvasLineTests.test_aLineCarriesNoTypeOnlyAnOptionalLabel`
    /// lists it.
    public let author: AnnotationAuthor.SourceKind?

    public init(id: CanvasLineID, from: CanvasNodeID, to: CanvasNodeID,
                label: String? = nil, author: AnnotationAuthor.SourceKind? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
        self.author = author
    }

    public func touches(_ node: CanvasNodeID) -> Bool { from == node || to == node }
}

/// A line resolved to two points on the canvas: what the renderer strokes, and
/// what the hit test measures a click against.
///
/// **It lives here, beside the line, and not inside `CanvasRenderer`.** The
/// projection is scene knowledge — it reads node frames and the scene's own
/// hidden set and it applies no camera, no culling and no appearance. Parked on
/// the renderer it was reached for by `CanvasLineHit`, which is a pure geometry
/// enum one layer *below* drawing, so a `public` type came to rest on an
/// `internal` nested one and the dependency pointed the wrong way. See
/// `CanvasScene.drawnLines`.
public struct CanvasDrawnLine: Equatable, Sendable {
    public let id: CanvasLineID
    public let from: CGPoint
    public let to: CGPoint
    public let label: String?
    /// Carried through from `CanvasLine.author` so the renderer can stroke a
    /// line Claude drew in a cooler value (§8A.2). **nil means the writer**, as
    /// it does everywhere else — and the projection carries it rather than the
    /// renderer reaching back into the scene, for the reason every other field
    /// here is carried: `CanvasRenderer.drawLine` is handed geometry and knows
    /// nothing about the scene it came from.
    public let author: AnnotationAuthor.SourceKind?

    public init(id: CanvasLineID, from: CGPoint, to: CGPoint, label: String?,
                author: AnnotationAuthor.SourceKind? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
        self.author = author
    }
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
    /// **What is clickable is exactly what is DRAWN**, and that is why this walks
    /// `CanvasScene.drawnLines` rather than `scene.lines` with an
    /// `endpoints(of:)` of its own. Two conditions take a line off the canvas —
    /// an unmeasured endpoint (no frame, so nothing was drawn) and a hidden one
    /// (a resident of a collapsed region) — and both are already stated there,
    /// once. Spelled again here they would drift, and the failure is silent in
    /// the worst direction: a line the writer can click and cannot see is worse
    /// than one they can see and cannot click.
    ///
    /// **It used to walk `CanvasRenderer.lineGeometry`, and the sharing was right
    /// while the direction was wrong.** The projection is what the renderer
    /// strokes *and* what a click is measured against; parked on the renderer it
    /// pointed this pure geometry enum at the draw layer and left a `public` type
    /// resting on an `internal` nested one. The single spelling survives; it is
    /// now underneath both callers. This is the UNCULLED projection deliberately
    /// — culling is about the viewport, and a click always arrives inside it.
    public static func line(at point: CGPoint, in scene: CanvasScene) -> CanvasLineID? {
        var best: (id: CanvasLineID, distance: CGFloat)?
        for line in scene.drawnLines {
            let d = distance(from: point, toSegment: line.from, line.to)
            guard d <= tolerance, best == nil || d < best!.distance else { continue }
            best = (line.id, d)
        }
        return best?.id
    }
}
