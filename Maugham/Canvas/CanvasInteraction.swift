import Foundation
import QuartzCore

/// Drag, resize and create, as a pure state machine so the gestures are
/// testable without a window.
struct CanvasInteraction {

    /// Narrower than this and a scrap wraps to one word per line.
    static let minimumScrapWidth: CGFloat = 120
    static let defaultScrapWidth: CGFloat = 240

    /// How old the last drag sample may be and still count as a throw.
    ///
    /// **`mouseDragged:` is delivered on MOTION, not on a clock.** A pointer the
    /// writer has parked produces no samples at all, so without this the two
    /// retained samples are still the fast ones from before the pause — move a
    /// card quickly, hold it still, let go, and the card the writer had already
    /// put down goes skating. That is the failure §7.3's momentum would be
    /// noticed for first.
    ///
    /// **The band matters more than the number, and it is wide.** The two
    /// failures this sits between are not symmetric:
    ///
    /// - Too LOOSE and a parked card is thrown. The floor on that is human: a
    ///   deliberate stop-then-release is a motor act of roughly 150–200 ms, so
    ///   anything at or above ~0.15 s starts believing pauses.
    /// - Too TIGHT and *nothing ever flicks*, which deletes §7.3 — the one
    ///   behaviour this surface exists to get right. The ceiling on that is not
    ///   one frame: `mouseUp` follows the last `mouseDragged` by a frame plus
    ///   delivery latency, and every drag sample on this surface mutates
    ///   `scene`, recomputes `body` and redraws the renderer, so a release that
    ///   lands a hitched frame or two late is an ORDINARY fast flick.
    ///
    /// 1/10 s is six frames at 60 Hz and twelve at 120: three to six times the
    /// gap a genuine release produces even through a dropped frame, and still
    /// under the shortest pause a hand can make on purpose. It is deliberately
    /// biased towards the loose end — a card that occasionally coasts when the
    /// writer half-meant to park it is a much smaller failure than a canvas
    /// where nothing ever glides.
    ///
    /// **What guards the tight direction is the BAND assertion in
    /// `test_theFlickStalenessBoundaryIsWhereItSaysItIs`, not the live one.**
    /// Measured, not assumed: tightening this to `1.0 / 60` leaves all nine of
    /// `CanvasViewMountingTests` green, and only setting it to `0` makes
    /// `test_aFlickCarriesTheCardOnPastWhereThePointerLetGo` fail. That test
    /// drives `mouseDragged`/`mouseUp` as back-to-back synchronous calls, so the
    /// age it produces is a microsecond, not the frame-plus-latency a real
    /// release produces — it can prove the guard is not absolute and nothing
    /// finer. Do not tighten this on the strength of a green mounting suite.
    static let maximumFlickAge: TimeInterval = 1.0 / 10

    private enum Mode: Equatable {
        case idle
        case moving(CanvasNodeID, grabOffset: CGSize)
        case resizing(CanvasNodeID, startWidth: CGFloat, startX: CGFloat)
    }

    /// One drag sample: where the pointer was, and when.
    ///
    /// The time is what makes the velocity honest. While the pointer is moving
    /// AppKit delivers `mouseDragged:` at roughly one event per frame, so the
    /// difference between two consecutive samples is points-per-frame — the unit
    /// `CanvasMomentum` decays in, and the reason no rate conversion happens
    /// anywhere. But that only holds while the pointer is MOVING, which is what
    /// `maximumFlickAge` checks before the delta is believed.
    private struct Sample {
        var point: CGPoint
        var time: TimeInterval
    }

    private var mode: Mode = .idle
    /// The last two drag samples, for §7.3's flick velocity.
    private var lastSample: Sample?
    private var previousSample: Sample?
    /// Where the press landed, so `hasMoved` can answer without a second copy of
    /// the node's original geometry.
    private var startPoint: CGPoint?

    var isActive: Bool { mode != .idle }

    /// Whether this gesture ever actually moved anything.
    ///
    /// **A press is not a drag.** `CanvasEventNSView.applyMouseDown` opens a drag
    /// session on every mouse-down, including the first mouse-down of a
    /// double-click, so entering a scrap always runs a `begin`/`end` pair with no
    /// `.changed` between them. Without this the canvas cannot tell that apart
    /// from a drag, and every double-click writes the sidecar, rebuilds the
    /// accessibility tree, and (once Task 15 lands) leaves a "Move Scrap" undo
    /// step that undoes nothing — which is exactly what the smoke line "press ⌘Z
    /// a third time; it must undo something real or do nothing" is looking for.
    ///
    /// There is deliberately no *distance* threshold beyond "not the press
    /// point". A writer who moves a card one point meant to; swallowing small
    /// drags is how a surface starts to feel like it is arguing.
    ///
    /// It survives `end()` and is cleared by the next `begin` — a caller reading
    /// it either side of `end()` gets the same answer about the same gesture.
    private(set) var hasMoved = false

    var activeNodeID: CanvasNodeID? {
        switch mode {
        case .idle: return nil
        case .moving(let id, _): return id
        case .resizing(let id, _, _): return id
        }
    }

    var isResizing: Bool {
        if case .resizing = mode { return true }
        return false
    }

    /// A press inside the card's bottom-right corner square starts a resize;
    /// anywhere else starts a move. The square's side is
    /// `CanvasRenderer.resizeHandleSize`, the same constant the mark is drawn
    /// from, so the two cannot drift apart in SIZE. They are not the same SHAPE:
    /// the mark is the triangle below the square's hypotenuse, so the upper-left
    /// half of this target is live but uninked — deliberately, because a target
    /// larger than its mark forgives a near miss and the reverse swallows drags
    /// the writer aimed at the card. See `CanvasRenderer.resizeHandle`.
    mutating func begin(at contentPoint: CGPoint, in scene: CanvasScene) {
        lastSample = nil
        previousSample = nil
        startPoint = contentPoint
        hasMoved = false
        guard let node = scene.topmostNode(at: contentPoint), let frame = node.frame else {
            mode = .idle
            return
        }
        let handle = CanvasRenderer.resizeHandleSize
        if contentPoint.x >= frame.maxX - handle && contentPoint.y >= frame.maxY - handle {
            beginResize(node.id, at: contentPoint, in: scene)
        } else {
            mode = .moving(node.id, grabOffset: CGSize(width: contentPoint.x - node.origin.x,
                                                       height: contentPoint.y - node.origin.y))
        }
    }

    mutating func beginResize(_ id: CanvasNodeID, at contentPoint: CGPoint, in scene: CanvasScene) {
        lastSample = nil
        previousSample = nil
        startPoint = contentPoint
        hasMoved = false
        guard let node = scene.node(id) else { mode = .idle; return }
        mode = .resizing(id, startWidth: node.width, startX: contentPoint.x)
    }

    /// - Parameter now: when this sample arrived. Defaulted to the clock the
    ///   timeline runs on so production callers say nothing about time; tests
    ///   pass it to drive `end(now:)`'s staleness check.
    mutating func update(to contentPoint: CGPoint,
                         in scene: inout CanvasScene,
                         now: TimeInterval = CACurrentMediaTime()) {
        guard mode != .idle else { return }
        previousSample = lastSample
        lastSample = Sample(point: contentPoint, time: now)
        if let startPoint, contentPoint != startPoint { hasMoved = true }

        switch mode {
        case .idle:
            break
        case .moving(let id, let grab):
            scene.move(id, to: CGPoint(x: contentPoint.x - grab.width,
                                       y: contentPoint.y - grab.height))
        case .resizing(let id, let startWidth, let startX):
            // §7A.3: width is authoritative, the text reflows, the height is
            // derived. `setWidth` clears the cached height for exactly that
            // reason — `CanvasView.rebuildLayouts()` refills it when the gesture
            // ends.
            scene.setWidth(max(Self.minimumScrapWidth, startWidth + (contentPoint.x - startX)),
                           for: id)
        }
    }

    /// Ends the gesture and reports the flick, if there was one: the node that
    /// moved and its final per-frame velocity. A resize never flicks — rewrapping
    /// a scrap must not send it skating.
    ///
    /// A drag the writer PAUSED before letting go does not flick either, and
    /// that is what `now` is for: see `maximumFlickAge`. Without it the writer
    /// parks a card, lets go, and watches it slide away.
    ///
    /// - Parameter now: when the button came up. Defaulted to the same clock
    ///   `update(to:in:now:)` stamps its samples with.
    @discardableResult
    mutating func end(now: TimeInterval = CACurrentMediaTime()) -> (id: CanvasNodeID, velocity: CGSize)? {
        defer {
            mode = .idle
            lastSample = nil
            previousSample = nil
            startPoint = nil
            // `hasMoved` is NOT cleared here — see its doc comment.
        }
        guard case .moving(let id, _) = mode else { return nil }
        guard let last = lastSample, let previous = previousSample else {
            // One sample is a placement, not a throw.
            return (id, .zero)
        }
        guard now - last.time <= Self.maximumFlickAge else {
            // The pointer had already stopped. The two samples still held are
            // the fast ones from before the pause, and believing them throws a
            // card the writer had put down.
            return (id, .zero)
        }
        return (id, CGSize(width: last.point.x - previous.point.x,
                           height: last.point.y - previous.point.y))
    }

    /// Mint a scrap at a point. IDs are unique within the scene by construction
    /// rather than by luck — the canvas will accumulate hundreds of these, and
    /// a short random id collides at that scale (tripwire 23's lesson, applied
    /// to a different id space).
    ///
    /// `cachedHeight` is deliberately nil: the new scrap has no text and only
    /// `ScrapLayout` may say how tall that is. `CanvasView` measures it in the
    /// same turn, which is why the create path calls `rebuildLayouts()`.
    static func createScrap(at contentPoint: CGPoint, in scene: inout CanvasScene) -> CanvasNodeID {
        var id = CanvasNodeID(UUID().uuidString.prefix(8).lowercased())
        while scene.node(id) != nil {
            id = CanvasNodeID(UUID().uuidString.prefix(8).lowercased())
        }
        scene.insert(CanvasNode(id: id, kind: .scrap, origin: contentPoint,
                                width: defaultScrapWidth, cachedHeight: nil,
                                z: scene.topZ + 1))
        return id
    }
}

/// §7.3: "Cards carry momentum and come to rest rather than snapping. This is
/// where tools actually acquire feel, it reads as craft rather than theme, and
/// unlike texture it never dates."
///
/// A velocity term plus an EXPLICIT per-frame decay, because `withAnimation`
/// cannot do this job: it interpolates `Animatable` values through the SwiftUI
/// view graph, and a plain model value read inside a `Canvas` draw closure is
/// not in that graph — the card would simply appear at its final position.
/// `CanvasView` drives `step(_:)` from `TimelineView(.animation(paused:))`.
///
/// Velocity is in CONTENT points per frame. While the pointer is moving AppKit
/// delivers drag samples at roughly one per frame, so `CanvasInteraction.end()`'s
/// delta is already in this unit — and when the pointer had STOPPED moving, so
/// that the delta is stale rather than slow, `end` reports `.zero` rather than
/// hand this a velocity nobody threw (`CanvasInteraction.maximumFlickAge`).
struct CanvasMomentum: Equatable {

    /// Per-frame multiplier. 0.80 gives a ~20-frame (⅓ second) coast, which
    /// reads as an object being let go rather than a spring being released.
    static let decayPerFrame: CGFloat = 0.80
    /// Below this the card is at rest. Also the floor a flick must clear.
    static let restSpeed: CGFloat = 0.5
    /// Total travel is roughly `speed / (1 - decay)`, so this caps a flick at
    /// about 200 content points. Uncapped, a trackpad jitter fires the card off
    /// the canvas.
    static let maximumLaunchSpeed: CGFloat = 40

    private(set) var nodeID: CanvasNodeID?
    private(set) var velocity: CGSize = .zero

    var isAtRest: Bool { nodeID == nil }

    /// The cap SCALES the vector rather than clamping its components, so a
    /// capped flick still coasts down the line the writer threw it.
    mutating func launch(_ id: CanvasNodeID, velocity v: CGSize) {
        let speed = hypot(v.width, v.height)
        guard speed >= Self.restSpeed else { stop(); return }
        let scale = min(speed, Self.maximumLaunchSpeed) / speed
        nodeID = id
        velocity = CGSize(width: v.width * scale, height: v.height * scale)
    }

    mutating func stop() {
        nodeID = nil
        velocity = .zero
    }

    /// Advance one frame. Returns `true` while still coasting.
    ///
    /// The first frame carries the card at the speed it was let go at; the decay
    /// is applied after the move, not before it.
    @discardableResult
    mutating func step(_ scene: inout CanvasScene) -> Bool {
        guard let id = nodeID, let node = scene.node(id) else { stop(); return false }
        scene.move(id, to: CGPoint(x: node.origin.x + velocity.width,
                                   y: node.origin.y + velocity.height))
        velocity = CGSize(width: velocity.width * Self.decayPerFrame,
                          height: velocity.height * Self.decayPerFrame)
        if hypot(velocity.width, velocity.height) < Self.restSpeed {
            stop()
            return false
        }
        return true
    }
}
