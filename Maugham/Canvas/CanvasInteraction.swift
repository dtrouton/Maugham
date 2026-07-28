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
        /// The residents are captured at `.began` because membership cannot
        /// change during a drag (§4.2: only a deliberate act moves it), and
        /// re-deriving them per frame is a set-union over every region in the
        /// scene at pointer rate.
        case movingRegion(CanvasRegionID, grabOffset: CGSize, residents: Set<CanvasNodeID>)
        /// The START frame, not the live one: a resize accumulated frame by
        /// frame drifts, and one clamped at `minimumSide` accumulates the clamp
        /// as well — drag past the floor and back and the region never returns
        /// to the size it was.
        case resizingRegion(CanvasRegionID, startFrame: CGRect, startPoint: CGPoint)
        case drawingRegion(start: CGPoint, current: CGPoint)
    }

    /// What this gesture is, for callers that need to name it without knowing
    /// how the machine stores it — `CanvasView` titles the undo bracket from
    /// this, and reads it at `.ended` to tell a card drop from a region sweep.
    enum Kind: Equatable {
        case movingNode, resizingNode, movingRegion, resizingRegion, drawingRegion
    }

    /// Where a press on a region landed.
    ///
    /// There is deliberately no `.interior` case. The interior is not a grab
    /// handle at all — see `regionHit(at:in:)`.
    enum RegionHit: Equatable {
        case chrome(CanvasRegionID)
        case resizeCorner(CanvasRegionID)
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
        case .movingRegion, .resizingRegion, .drawingRegion: return nil
        }
    }

    var activeRegionID: CanvasRegionID? {
        switch mode {
        case .movingRegion(let id, _, _), .resizingRegion(let id, _, _): return id
        case .idle, .moving, .resizing, .drawingRegion: return nil
        }
    }

    var kind: Kind? {
        switch mode {
        case .idle: return nil
        case .moving: return .movingNode
        case .resizing: return .resizingNode
        case .movingRegion: return .movingRegion
        case .resizingRegion: return .resizingRegion
        case .drawingRegion: return .drawingRegion
        }
    }

    /// A NODE resize, and only that. `CanvasView` reads it to re-measure the
    /// card under the pointer and to take the `.ended` branch that rebuilds
    /// layouts; a region has no text to rewrap and no height to re-derive, so
    /// widening this to cover `.resizingRegion` would measure every scrap on the
    /// canvas for a gesture that touched none of them.
    var isResizing: Bool {
        if case .resizing = mode { return true }
        return false
    }

    /// The rect a `.drawingRegion` gesture has swept, normalised so a drag up
    /// and to the left is the same region as a drag down and to the right.
    /// `nil` in every other mode — `CanvasView` reads it at `.ended` to decide
    /// whether this gesture was a sweep at all.
    var pendingRegionDraw: CGRect? {
        guard case .drawingRegion(let start, let current) = mode else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    /// A press inside the card's bottom-right corner square starts a resize;
    /// anywhere else starts a move. The square's side is
    /// `CanvasRenderer.resizeHandleSize`, the same constant the mark is drawn
    /// from, so the two cannot drift apart in SIZE. They are not the same SHAPE:
    /// the mark is the triangle below the square's hypotenuse, so the upper-left
    /// half of this target is live but uninked — deliberately, because a target
    /// larger than its mark forgives a near miss and the reverse swallows drags
    /// the writer aimed at the card. See `CanvasRenderer.resizeHandle`.
    /// The precedence, in one place: **card, then a region's resize corner, then
    /// a region's label bar, then nothing, then a sweep.**
    ///
    /// Cards are hit-tested FIRST and unconditionally, so a card overlapping a
    /// region's chrome is still picked up by a press on it — most cards live in
    /// a region, and a region that stole them would make the ones near its top
    /// edge unmovable.
    ///
    /// A press inside a region's INTERIOR that missed every card leaves this
    /// idle rather than starting a sweep: nested regions are out of scope (§9)
    /// and silently making one is worse than refusing.
    mutating func begin(at contentPoint: CGPoint, in scene: CanvasScene) {
        lastSample = nil
        previousSample = nil
        startPoint = contentPoint
        hasMoved = false
        if let node = scene.topmostNode(at: contentPoint), let frame = node.frame {
            let handle = CanvasRenderer.resizeHandleSize
            if contentPoint.x >= frame.maxX - handle && contentPoint.y >= frame.maxY - handle {
                beginResize(node.id, at: contentPoint, in: scene)
            } else {
                mode = .moving(node.id, grabOffset: CGSize(width: contentPoint.x - node.origin.x,
                                                           height: contentPoint.y - node.origin.y))
            }
            return
        }

        switch Self.regionHit(at: contentPoint, in: scene) {
        case .resizeCorner(let id):
            guard let frame = scene.region(id)?.frame else { mode = .idle; return }
            mode = .resizingRegion(id, startFrame: frame, startPoint: contentPoint)
        case .chrome(let id):
            guard let frame = scene.region(id)?.frame else { mode = .idle; return }
            mode = .movingRegion(id,
                                 grabOffset: CGSize(width: contentPoint.x - frame.minX,
                                                    height: contentPoint.y - frame.minY),
                                 residents: CanvasMembership.residents(of: id, in: scene))
        case nil:
            mode = scene.unorderedRegions.contains { $0.frame.contains(contentPoint) }
                ? .idle
                : .drawingRegion(start: contentPoint, current: contentPoint)
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
        case .movingRegion(let id, let grab, let residents):
            // §4.1: the region and its residents travel together, by the SAME
            // delta — derived from where the frame actually is rather than from
            // the pointer, so a frame the clamp or another writer moved cannot
            // send the cards somewhere the region did not go.
            guard let frame = scene.region(id)?.frame else { break }
            let origin = CGPoint(x: contentPoint.x - grab.width,
                                 y: contentPoint.y - grab.height)
            let delta = CGSize(width: origin.x - frame.minX, height: origin.y - frame.minY)
            scene.setRegionFrame(CGRect(origin: origin, size: frame.size), for: id)
            // Residents only. An appearance is a reference, not a copy (§4.3),
            // and dragging the region it is cited in must not move the card it
            // cites — `CanvasMembership.residents` is what draws that line.
            for resident in residents {
                guard let at = scene.node(resident)?.origin else { continue }
                scene.move(resident, to: CGPoint(x: at.x + delta.width,
                                                 y: at.y + delta.height))
            }
        case .resizingRegion(let id, let startFrame, let startPoint):
            // The ORIGIN is held: the corner the writer has hold of moves and
            // the opposite one stays. Nothing here touches membership — §4.2's
            // whole point is that geometry never adds or removes a member, and
            // a resize that ejected the cards it no longer covers is tldraw's
            // #6017.
            let size = CGSize(
                width: max(CanvasRegionMetrics.minimumSide,
                           startFrame.width + (contentPoint.x - startPoint.x)),
                height: max(CanvasRegionMetrics.minimumSide,
                            startFrame.height + (contentPoint.y - startPoint.y)))
            scene.setRegionFrame(CGRect(origin: startFrame.origin, size: size), for: id)
        case .drawingRegion(let start, _):
            mode = .drawingRegion(start: start, current: contentPoint)
        }
    }

    /// Ends the gesture and reports the flick, if there was one: the node that
    /// moved and its final per-frame velocity. A resize never flicks — rewrapping
    /// a scrap must not send it skating.
    ///
    /// **Neither does anything a region does.** A region full of cards skating
    /// away from where the writer put it is not §7.3's "objects coming to rest",
    /// and a sweep has nothing to throw at all — so all three region modes fall
    /// out of the `case .moving` guard below with `nil`.
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

    // MARK: - Regions

    /// The label bar moves a region; the bottom-right corner resizes it. The
    /// INTERIOR is deliberately neither: grabbing anywhere inside would make it
    /// impossible to pick up a card that sits in a region, which is most of them.
    ///
    /// Both rects come from `CanvasRegionMetrics`, the same functions
    /// `CanvasRenderer.drawRegion` draws from. A second spelling puts the mark
    /// and the target on different geometry — the failure `CanvasCardMetrics`
    /// exists to prevent for cards, in a second place.
    ///
    /// The corner is tested before the chrome so a region short enough for the
    /// two to meet still resizes; and the target is the whole 14pt square while
    /// the mark is the triangle below its hypotenuse, because a target larger
    /// than its mark forgives a near miss where the reverse swallows drags the
    /// writer aimed at the region.
    ///
    /// **Smallest region first**, so a small region overlapping a large one is
    /// reachable — nested regions are out of scope, overlapping ones are not.
    /// The id is the tiebreak because `Array.sorted` is not stable: on area
    /// alone, two equal-sized regions would answer differently between two runs
    /// of the same click.
    static func regionHit(at point: CGPoint, in scene: CanvasScene) -> RegionHit? {
        let candidates = scene.unorderedRegions.sorted {
            ($0.frame.width * $0.frame.height, $0.id.raw)
                < ($1.frame.width * $1.frame.height, $1.id.raw)
        }
        for r in candidates
        where CanvasRegionMetrics.resizeHandleRect(in: r.frame).contains(point) {
            return .resizeCorner(r.id)
        }
        for r in candidates where CanvasRegionMetrics.chromeRect(in: r.frame).contains(point) {
            return .chrome(r.id)
        }
        return nil
    }

    /// Which region a DROP meant. Deciding lives here; recording lives in
    /// `CanvasMembership`, and keeping the two apart is what stops geometry
    /// leaking into membership.
    ///
    /// The node's CENTRE must be inside the region — predictable, and
    /// explainable in one sentence to a writer ("drop it so its middle is
    /// inside"), where corner-based targeting is the one-pixel absurdity §4.2
    /// cites against Obsidian.
    ///
    /// **A COLLAPSED region is never a target.** Its residents are not drawn, so
    /// the writer cannot see what they would be joining — and the card would
    /// vanish into `hiddenNodes` in the same gesture that dropped it. A thing
    /// disappearing on drop is the worst failure available on a spatial surface,
    /// because the writer is left with no account of what happened. Refusing
    /// leaves the card where they put it, which is legible.
    ///
    /// **Ties are broken the way `regionHit` breaks them: the SMALLER region
    /// wins.** Overlap decides first, but two regions that both contain the card
    /// overlap it identically, and then the two rules must not disagree — the
    /// grab rule is the one the writer can see, so a card must join the region a
    /// click at that spot would have picked up. The id is last and is there only
    /// so the answer is the same twice running.
    ///
    /// An unmeasured node has no frame and so joins nothing: it has no centre
    /// to test, and `CGRect.null`'s is not a place.
    static func joinTarget(for node: CanvasNodeID, in scene: CanvasScene) -> CanvasRegionID? {
        guard let frame = scene.node(node)?.frame else { return nil }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        // `min` over a key whose first term is NEGATED overlap: largest overlap,
        // then smallest region, then smallest id. One total order, so there is
        // no stability to depend on.
        return scene.regions
            .filter { !$0.isCollapsed && $0.frame.contains(centre) }
            .min { lhs, rhs in
                let l = lhs.frame.intersection(frame), r = rhs.frame.intersection(frame)
                return (-(l.width * l.height), lhs.frame.width * lhs.frame.height, lhs.id.raw)
                    < (-(r.width * r.height), rhs.frame.width * rhs.frame.height, rhs.id.raw)
            }?.id
    }

    /// Mint a region for a swept rect, or nothing if the sweep was a twitch —
    /// which is what makes a stray drag on bare canvas cost nothing.
    ///
    /// **A rect that overlaps or entirely contains another region is fine, and
    /// nothing here refuses it.** §9 rules out *nested regions* — a containment
    /// relationship in the model — and this model has none: membership is
    /// explicit and geometry means nothing, so one frame enclosing another
    /// implies precisely nothing about either. Two regions that overlap a lot
    /// are two regions that overlap a lot. `begin` declines to START a sweep
    /// inside a region because a press there is far more likely to be aimed at
    /// something in it, and that is a pointer-precedence rule rather than a
    /// statement about what regions may look like; refusing at RELEASE instead
    /// would sweep out a large area and give back nothing, with no signal why.
    ///
    /// Ids get the same uniqueness loop `createScrap` uses, never a bare random
    /// call (tripwire 23's lesson in a second id space).
    static func createRegion(_ rect: CGRect, in scene: inout CanvasScene) -> CanvasRegionID? {
        guard rect.width >= CanvasRegionMetrics.minimumSide,
              rect.height >= CanvasRegionMetrics.minimumSide else { return nil }
        var id = CanvasRegionID(UUID().uuidString.prefix(8).lowercased())
        while scene.region(id) != nil {
            id = CanvasRegionID(UUID().uuidString.prefix(8).lowercased())
        }
        // Deliberately EMPTY, and deliberately unlabelled. §4.2: drawing a
        // region around cards absorbs none of them — the writer drops in what
        // belongs, and `CanvasRegion.untitledLabel` carries the name until they
        // give it one.
        scene.insertRegion(CanvasRegion(id: id, label: "", frame: rect))
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
