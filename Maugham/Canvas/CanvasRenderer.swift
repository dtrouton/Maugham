import SwiftUI
import AppKit

/// How level each card is drawn, per spec §7A.5.
///
/// **The card that takes focus animates to level over ~120 ms, and settles back
/// to its seeded angle on blur. That is the focus affordance** — the card being
/// edited is the only square one on the canvas, and everything else stays
/// tilted, so the signal costs nothing.
///
/// It is a plain interpolated value stepped once per frame, NOT `withAnimation`:
/// a model value read inside a `Canvas` draw closure is not in SwiftUI's
/// animation graph and would jump straight to its final value. `CanvasView`
/// drives `step(elapsed:)` from the same `TimelineView` that drives
/// `CanvasMomentum` — the same per-frame shape, so no new machinery.
///
/// Two cards can be in flight at once: the one being left settles back while the
/// one being entered straightens. Hence a dictionary rather than a single value.
/// Entries at zero are dropped, so `isSettled` is cheap and an idle canvas pauses
/// its clock.
struct CanvasFocusStraighten: Equatable {

    /// §7A.5: "over ~120 ms". Long enough to read as the card responding, short
    /// enough that the beat before the caret appears reads as responsiveness
    /// rather than lag.
    static let secondsToLevel: TimeInterval = 0.12

    private(set) var focusedNodeID: CanvasNodeID?
    private var progressByNode: [CanvasNodeID: CGFloat] = [:]

    init() {}

    /// True when every entry is at ITS OWN target — the clock may be paused.
    ///
    /// **"At its target", not "at 1".** Only the focused card's target is 1;
    /// every other card's is 0, and `step` deletes an entry the moment it gets
    /// there, so an empty dictionary satisfies this rule for free. Writing it as
    /// `allSatisfy { $0.value >= 1 }` looks equivalent and is not: after a
    /// completed focus the dictionary holds `[s1: 1]`, and `focus(nil)` clears
    /// `focusedNodeID` without touching that entry — so the naive version reports
    /// settled the instant the writer clicks away, `TimelineView` pauses, `step`
    /// is never called again, and **the card stays level until something
    /// unrelated restarts the clock.** Click in, click out onto empty canvas is
    /// the commonest path on the surface, and §7A.5's "the card being edited is
    /// the only square one on the canvas" is false for the rest of the session.
    var isSettled: Bool {
        progressByNode.allSatisfy { $0.key == focusedNodeID && $0.value >= 1 }
    }

    /// 0 = the card's full seeded angle, 1 = level.
    func progress(for id: CanvasNodeID) -> CGFloat { progressByNode[id] ?? 0 }

    /// True only when this card is the focused one AND has finished
    /// straightening — i.e. it is drawn at exactly 0°.
    ///
    /// **This is the gate `CanvasView` REVEALS the editor behind** (§7A.5
    /// requirement 1: caret, then animate, then hand the text over). It gates
    /// visibility, NOT existence: the editor is mounted and first responder from
    /// the instant the writer clicks, or the first characters of a
    /// double-click-and-type would reach nothing. Both halves matter: the
    /// `focusedNodeID` check is what hides the editor again on blur, and the
    /// progress check is what keeps it hidden during the ~120 ms straighten,
    /// when axis-aligned glyphs over a still-tilted card would snap straight —
    /// the §7A.2 failure §7A.5 exists to close.
    func isLevel(_ id: CanvasNodeID) -> Bool {
        focusedNodeID == id && progress(for: id) >= 1
    }

    mutating func focus(_ id: CanvasNodeID?) {
        guard id != focusedNodeID else { return }
        focusedNodeID = id
        if let id, progressByNode[id] == nil { progressByNode[id] = 0 }
    }

    /// Advance one frame. Returns `true` while anything is still moving.
    ///
    /// A non-positive `elapsed` advances nothing and reports what is still in
    /// flight. Task 10 owns the `TimelineView` clock, and a paused-then-resumed
    /// timeline is exactly where a zero or negative delta arrives.
    ///
    /// Ungoverned, a NEGATIVE delta runs the interpolation backwards: the
    /// `abs(target - current) <= delta` test can never be true, so every entry
    /// takes the moving branch and walks AWAY from its target, out of 0...1, and
    /// the card never settles. A zero delta is merely a wasted frame.
    ///
    /// It returns `!isSettled` rather than `false` deliberately. `false` would
    /// make `while step(elapsed: 0) { }` terminate, but it would also tell the
    /// clock that a card mid-straighten had finished — and a paused clock that
    /// strands a card between angles is the failure `isSettled` is written to
    /// avoid, traded for a convenience no production caller wants.
    @discardableResult
    mutating func step(elapsed: TimeInterval) -> Bool {
        guard elapsed > 0 else { return !isSettled }
        let delta = CGFloat(elapsed / Self.secondsToLevel)
        var moving = false
        for (id, current) in progressByNode {
            let target: CGFloat = (id == focusedNodeID) ? 1 : 0
            if abs(target - current) <= delta {
                if target == 0 {
                    progressByNode.removeValue(forKey: id)
                } else {
                    progressByNode[id] = target
                }
            } else {
                progressByNode[id] = current + (target > current ? delta : -delta)
                moving = true
            }
        }
        return moving
    }
}

/// The draw pass. Everything on the canvas is drawn — there are ~2 views on
/// screen rather than 300 (spec §7A.1), which is what keeps the surface out of
/// the macOS 15 `_hitTestForEvent` regression and away from SwiftUI's missing
/// lazy 2D container.
///
/// SCALE: this file derives none. The `GraphicsContext` handed to `draw` is
/// already at the window's `backingScaleFactor`, and `withCGContext` preserves
/// it under the camera CTM we set — so the product spike requirement 3 asks for
/// is what we already have. Computing a scale from pixel width instead bakes in
/// AppKit's frame rounding and shifts glyphs by a subpixel, which is the "text
/// jumps" failure wearing a measurement-artifact disguise.
/// `CanvasRendererTests.test_noFileInTheCanvasAreaDerivesItsOwnRasterScale` pins it.
///
/// Y AXIS: none either. `ScrapLayout.draw(into:at:)` needs a top-left-origin,
/// y-downward context, and measurement on 2026-07-26 confirmed
/// `GraphicsContext.withCGContext` hands back exactly that: a `withCGContext`
/// fill of `CGRect(0, 0, 100, 10)` inks the same rows as a `GraphicsContext`
/// fill of the same rect. So `drawCard` applies no flip. If a future macOS
/// changes that, **the flip belongs here, not in `ScrapLayout`** — `ScrapLayout`
/// is the shared stack the mounted `NSTextView` also draws through, and moving
/// its origin would slide the §7A.2 glyph-origin pin out from under the editor
/// it exists to compare against.
/// `CanvasRendererTests.test_theDrawnTextRunsDownwardFromTheTextOriginInsideItsCard`
/// pins it.
enum CanvasRenderer {

    /// The size of the resize affordance in the card's bottom-right corner —
    /// the side of the square `CanvasInteraction.begin` tests, and the legs of
    /// the triangle `resizeHandle` draws. See `resizeHandle` for why the two
    /// shapes differ deliberately.
    static let resizeHandleSize: CGFloat = 14

    /// The card's paper, and the ink that goes on it.
    ///
    /// **Both are appearance-dynamic, and that pairing is the decision.**
    /// `ScrapLayout` bakes its text colour into an `NSTextStorage` at
    /// construction, but a dynamic `NSColor` still resolves against whatever
    /// appearance is current when the glyphs rasterise — so a dynamic ink is
    /// only safe over a paper that moves with it. The alternative was a card
    /// that is paper-white in both appearances with a static dark ink; it was
    /// rejected because a white card is the one thing on this surface that would
    /// not sit under the textured ground in dark mode, and because §7.2 wants
    /// honest objects rather than a light-mode skeuomorph pasted into the dark.
    ///
    /// **The paper is `textBackgroundColor` in light and a dedicated value in
    /// dark** — see `CanvasMaterial.darkCardPaper` for why the split, which is a
    /// real departure from Task 7's single semantic colour and not a drift. The
    /// short version: `textBackgroundColor` is 0.118 in dark, which sat 0.058
    /// above the old ground and vanishes entirely against the raised one.
    /// `labelColor` is 0.00 / 1.00, so the ink survives the switch in both
    /// directions either way — `test_theCardsInkContrastsWithItsPaperInBothAppearances`
    /// is what says so, and it is the ceiling on how light the dark paper may go.
    ///
    /// **Task 9 and Task 10 must construct every `ScrapLayout` with
    /// `textColor: CanvasRenderer.cardInk`.** Taking `ScrapLayout`'s default
    /// happens to give the same colour today, but naming it here is what keeps
    /// the two ends of the pairing findable from one another — and what
    /// `test_theCardsInkContrastsWithItsPaperInBothAppearances` reads.
    static let cardPaper: NSColor = CanvasMaterial.dynamic(light: CanvasMaterial.lightCardPaper,
                                                           dark: CanvasMaterial.darkCardPaper)
    static let cardInk: NSColor = .labelColor

    /// A region's wash and its outline, resolved per appearance from the pair in
    /// `CanvasMaterial` — the same shape as `cardPaper`, and for the same
    /// reason: light and dark are two materials, not one inverted (§7.1).
    static let regionWash: NSColor = CanvasMaterial.dynamic(light: CanvasMaterial.lightRegionWash,
                                                            dark: CanvasMaterial.darkRegionWash)
    static let regionStroke: NSColor = CanvasMaterial.dynamic(light: CanvasMaterial.lightRegionStroke,
                                                              dark: CanvasMaterial.darkRegionStroke)

    /// §7.2: each card sits at a seeded fraction of a degree — nothing is rough,
    /// but everything was *put down* rather than snapped to a grid.
    ///
    /// Deterministic from the node id. A card must never shimmer or shift
    /// between renders, so this cannot be `Double.random` and cannot depend on
    /// anything that varies per frame. SplitMix64 over a stable string hash —
    /// note `String.hashValue` is seeded per process and would give a card a
    /// different tilt on every launch.
    static func seededRotation(for id: CanvasNodeID) -> Angle {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a offset basis
        for byte in id.raw.utf8 {
            h = (h ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        // SplitMix64 finaliser — cheap, and well distributed in the low bits.
        var z = h &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        z = z ^ (z >> 31)

        // Map into ±CanvasMaterial.maximumTiltDegrees — the ONE definition of how
        // far a card may lean. Everything downstream derives from it, including
        // `cullingBleed`'s overhang budget.
        let unit = Double(z % 10_000) / 10_000.0        // 0..<1
        return .degrees((unit * 2 - 1) * CanvasMaterial.maximumTiltDegrees)
    }

    /// The angle a card is ACTUALLY drawn at right now: its seeded angle, scaled
    /// down toward zero as it straightens (spec §7A.5). At full straighten it is
    /// exactly level, which is what lets the editor take over the text
    /// axis-aligned and the §7A.2 glyph-origin pin compare two unrotated layouts.
    static func drawnAngle(for id: CanvasNodeID, straighten: CanvasFocusStraighten) -> Angle {
        .degrees(seededRotation(for: id).degrees * (1 - Double(straighten.progress(for: id))))
    }

    /// The rotation a card is drawn under, about its own centre. **The only
    /// definition of it.**
    ///
    /// `drawCard` concatenates this onto the graphics context and `localPoint`
    /// inverts it, so the draw pass and the caret hit test cannot disagree about
    /// which way positive is. An earlier draft called `GraphicsContext.rotate(by:)`
    /// in one place and hand-wrote `R(−θ)` in the other, and nothing checked that
    /// they matched — a flipped convention would have DOUBLED the caret error at
    /// a card corner rather than removing it, and a round-trip test passes under
    /// either convention so nothing would have said so.
    /// `CanvasRendererTests.test_cardTransformRotatesInTheDirectionTheRendererDraws`
    /// pins the matrix against literal trigonometry.
    static func cardTransform(inCard frame: CGRect, angle: Angle) -> CGAffineTransform {
        CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: angle.radians)
            .translatedBy(x: -frame.midX, y: -frame.midY)
    }

    /// Map a canvas-space point into a card's own unrotated space — the inverse
    /// of `cardTransform`.
    ///
    /// §7A.5 requirement 1: resolve the caret index at CLICK TIME in this space,
    /// then animate, then mount with the target already known. Straightening
    /// first would move the click point out from under the cursor and the caret
    /// would land somewhere the writer did not aim.
    static func localPoint(_ contentPoint: CGPoint, inCard frame: CGRect, angle: Angle) -> CGPoint {
        contentPoint.applying(cardTransform(inCard: frame, angle: angle).inverted())
    }

    /// How far outside its own frame a card paints, in content points.
    ///
    /// Two things reach past `CanvasNode.frame`: `drawCard`'s drop shadow, which
    /// is radius 3 at offset (1, 2) and so extends ~5 pt past the edge it falls
    /// from; and the seeded rotation, which swings a corner out by `r·θ`.
    ///
    /// **The rotation term scales with the tilt AND with the card's diagonal, so
    /// this budget is re-done whenever `CanvasMaterial.maximumTiltDegrees`
    /// moves.** At θ = 1.2° a default 240×80 card overhangs ~2.6 pt (r = 126.5)
    /// and a generous 480×160 card ~5.3 pt (r = 253) — so 12 pt covers the
    /// shadow and a wide card together with room left. At the original θ = 0.6°
    /// the same arithmetic gave 1.4 pt and 8 pt sufficed; doubling the tilt
    /// without re-doing this would let a wide card's corner be culled while it
    /// was still on screen.
    /// `CanvasRendererTests.test_theCullingBleedCoversTheRotationOverhangAtTheCalibratedTilt`
    /// recomputes it, so a further tilt increase fails loudly rather than
    /// clipping a corner at the window edge.
    ///
    /// Culling on the bare frame drops a card whose frame is 1 pt off-screen
    /// while up to 4 pt of its shadow would still have landed inside the
    /// viewport — so shadows pop in and out at the edge as the writer pans,
    /// which reads as the surface flickering rather than as objects on a ground.
    static let cullingBleed: CGFloat = 12

    /// Virtualisation, entire (spec §7A.1): an intersection test in the draw
    /// loop. No `ForEach` identity to preserve, so culling cannot destroy focus
    /// or an in-progress edit.
    ///
    /// `CanvasScene.nodes(intersecting:)` filters before it orders, so the work
    /// is proportional to the VIEWPORT and not to the scene — which is what
    /// Task 16 asserts. Nothing per frame may reach for `CanvasScene.nodes`,
    /// which sorts the whole scene on every access.
    static func visibleNodes(in scene: CanvasScene,
                             camera: CanvasCamera,
                             viewSize: CGSize) -> [CanvasNode] {
        scene.nodes(intersecting: camera.visibleContentRect(viewSize: viewSize)
            .insetBy(dx: -cullingBleed, dy: -cullingBleed))
    }

    /// The regions the viewport can see, culled exactly as the nodes are.
    ///
    /// A region carries no seeded angle and no shadow, so the `cullingBleed`
    /// budget is generous here rather than tight — it is shared with the node
    /// cull so the two passes cannot disagree about where the viewport ends.
    static func visibleRegions(in scene: CanvasScene,
                               camera: CanvasCamera,
                               viewSize: CGSize) -> [CanvasRegion] {
        let viewport = camera.visibleContentRect(viewSize: viewSize)
            .insetBy(dx: -cullingBleed, dy: -cullingBleed)
        return scene.regions.filter { $0.frame.intersects(viewport) }
    }

    /// The line drawn from a resident that has wandered out of the region that
    /// owns it, to that region.
    ///
    /// §4.2 accepts that "a node can sit visually outside the region that owns
    /// it. That is a rendering problem (draw the relationship), not a
    /// correctness one." This is that relationship, drawn.
    ///
    /// **Both ends are MIDPOINTS.** `cardTransform` translates to `(midX, midY)`,
    /// rotates and translates back, so a card's midpoint maps to itself at any
    /// angle — a tether meets a tilted card exactly where it meets a level one
    /// and no straighten value can make it drift. Anchor either end on a corner
    /// and the line visibly slides for the 120 ms of every focus change.
    ///
    /// **Cost, stated rather than left to be found:** `tethers` and
    /// `appearanceChips` both run per frame and both walk every region's member
    /// sets, so together they are `O(members)` with a sort per region — the same
    /// order as `visibleNodes`, which already scans the whole scene because
    /// there is no spatial index (see `AREA.md`, "Scale"). Neither is culled to
    /// the viewport: a tether's two ends are usually in different places and
    /// clipping it correctly means testing the segment, not either endpoint.
    /// If a canvas ever arrives where this shows, cull the SEGMENT against the
    /// viewport — do not cull on the region, which is what hides the line
    /// telling the writer where their card went.
    struct Tether: Equatable {
        let node: CanvasNodeID
        let region: CanvasRegionID
        let from: CGPoint
        let to: CGPoint
    }

    static func tethers(in scene: CanvasScene) -> [Tether] {
        // A collapsed region draws none of its residents, so a line to one
        // lands on empty ground.
        scene.regions.filter { !$0.isCollapsed }.flatMap { region -> [Tether] in
            region.homeMembers.sorted { $0.raw < $1.raw }.compactMap { id in
                guard let frame = scene.node(id)?.frame,
                      // Only when the frames do not meet AT ALL. Tethering on
                      // non-containment would fire a full line to the centre for
                      // one pixel of overhang — a card straddling the edge is
                      // still visibly IN the region.
                      !frame.intersects(region.frame) else { return nil }
                return Tether(node: id, region: region.id,
                              from: CGPoint(x: frame.midX, y: frame.midY),
                              to: CGPoint(x: region.frame.midX, y: region.frame.midY))
            }
        }
    }

    /// §4.3: "An appearance must not render identically to the thing itself…
    /// An appearance reads as a reference: smaller, or a chip carrying the title
    /// with a hairline to its home."
    ///
    /// The chip is the reference; the card stays where the writer put it. A copy
    /// would make "which of these is the real one" unanswerable, which is the
    /// failure §4.3 names.
    struct AppearanceChip: Equatable {
        let node: CanvasNodeID
        let region: CanvasRegionID
        let frame: CGRect
        /// The midpoint of the node's own card — "where is the real one". A
        /// midpoint for the same reason a tether's ends are: it is the one point
        /// on a card that `cardTransform` fixes.
        let homeAnchor: CGPoint
    }

    static let chipHeight: CGFloat = 18
    static let chipWidth: CGFloat = 150
    /// The gap between stacked chips. Small enough that a column of them reads
    /// as one list, large enough that two chips never touch.
    static let chipSpacing: CGFloat = 4
    /// Breathing room for a chip's title inside its pill.
    /// `CanvasRegionMetrics.labelInset`'s 10 is a card's number and swallows an
    /// eighth of a chip.
    static let chipTextInset: CGFloat = 6

    static func appearanceChips(in scene: CanvasScene) -> [AppearanceChip] {
        scene.regions.filter { !$0.isCollapsed }.flatMap { region -> [AppearanceChip] in
            region.appearances.sorted { $0.raw < $1.raw }.enumerated().compactMap { index, id in
                guard let card = scene.node(id)?.frame else { return nil }
                let top = region.frame.minY + CanvasRegionMetrics.chromeHeight
                    + CGFloat(index) * (chipHeight + chipSpacing)
                // Chips stack down the region's inside edge and stop at its
                // bottom; a region too short to hold them all shows what fits
                // rather than spilling references onto the ground outside it.
                guard top + chipHeight <= region.frame.maxY else { return nil }
                return AppearanceChip(
                    node: id, region: region.id,
                    frame: CGRect(x: region.frame.minX + CanvasRegionMetrics.labelInset,
                                  y: top, width: chipWidth, height: chipHeight),
                    homeAnchor: CGPoint(x: card.midX, y: card.midY))
            }
        }
    }

    /// The first non-empty line of the scrap, so a chip says WHICH card it
    /// stands for. A blank chip is indistinguishable from a rendering bug.
    static func chipTitle(for id: CanvasNodeID,
                          in scene: CanvasScene,
                          scraps: [CanvasNodeID: String]) -> String {
        if case .item(let reference)? = scene.node(id)?.kind {
            return placeholderLabel(forReference: reference)
        }
        let line = (scraps[id] ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? CanvasAccessibility.emptyScrapValue : line
    }

    /// What a collapsed region says it is holding. §7/§10 answer crowding by
    /// collapsing rather than by minting more canvases — so a collapsed region
    /// that showed an empty interior would read as an empty region.
    static func collapsedSummary(for id: CanvasRegionID, in scene: CanvasScene) -> String {
        let n = CanvasMembership.residents(of: id, in: scene).count
        return n == 1 ? "1 card" : "\(n) cards"
    }

    /// 1C-a draws item nodes as placeholders. 1C-d resolves the real title,
    /// kind glyph and thumbnail (spec §8A.1) — do not do it here.
    static func placeholderLabel(forReference referenceId: String) -> String {
        "Item · \(referenceId)"
    }

    /// Whether this pass draws a node's own text, or leaves it to the editor.
    ///
    /// The rule is Excalidraw's (spec §7A.2): while a scrap's editor is the
    /// VISIBLE text, drawing the text too would double-draw it. The converse is
    /// the half that has been got wrong twice — while the editor is *not*
    /// visible, this pass must draw, whether or not an editor exists.
    ///
    /// A single optional, not a per-node predicate, so at most one node on the
    /// canvas can ever stop drawing its own text.
    static func drawsOwnText(_ id: CanvasNodeID, visibleEditorNodeID: CanvasNodeID?) -> Bool {
        id != visibleEditorNodeID
    }

    /// Draw every visible node under the camera's CTM.
    ///
    /// `visibleEditorNodeID` suppresses that node's TEXT only — see
    /// `drawsOwnText`. Its CARD is still drawn: §7A.5 makes the focused card the
    /// only square one on the canvas, and there is nothing to be square if the
    /// card disappears the moment it is clicked.
    ///
    /// **It is the node whose editor is VISIBLE — neither the node being edited
    /// nor the node whose editor merely exists.** All three differ for the
    /// ~120 ms of the straighten: the writer's click sets
    /// `CanvasView.editingNodeID` and mounts the editor immediately, so no
    /// keystroke is lost, but the editor stays invisible until the card is
    /// level. Through that window this pass keeps drawing the card's text — and
    /// it is live text, because the layout wraps the same `NSTextStorage` the
    /// invisible editor is mutating, and `CanvasView.syncActiveEdit` bumps
    /// `revision` on every keystroke. Blanking it on the click instead would
    /// leave the card empty for that beat and then fill it with axis-aligned
    /// glyphs — the jump §7A.5 was written to prevent. `CanvasView` derives this
    /// argument and the editor's own visibility from ONE property, so they
    /// cannot flip on different frames.
    /// Three passes, and the order is the design:
    ///
    /// 1. **Regions, BENEATH everything.** §4 makes a region *where the cards
    ///    are*, not a panel they sit on — a wash that painted over a card would
    ///    make the region the object and the cards its decoration.
    /// 2. **Cards.**
    /// 3. **Tethers and chips, ABOVE the cards.** A reference the writer cannot
    ///    see is not a reference, and both of these are lines and labels that
    ///    would otherwise be buried under the very card they point at.
    ///
    /// Regions draw in CANVAS space, outside any card transform, and that is
    /// exactly right: `cardTransform` is concatenated onto a *local copy* of the
    /// context inside `drawCard`, so it never leaks, and a region is not a card
    /// — it has no seeded angle and never tilts.
    static func draw(scene: CanvasScene,
                     camera: CanvasCamera,
                     viewSize: CGSize,
                     layouts: [CanvasNodeID: ScrapLayout],
                     scraps: [CanvasNodeID: String],
                     selection: CanvasSelection?,
                     visibleEditorNodeID: CanvasNodeID?,
                     straighten: CanvasFocusStraighten,
                     into cx: inout GraphicsContext) {
        cx.translateBy(x: camera.pan.x, y: camera.pan.y)
        cx.scaleBy(x: camera.zoom, y: camera.zoom)

        for region in visibleRegions(in: scene, camera: camera, viewSize: viewSize) {
            drawRegion(region, in: scene, isSelected: selection == .region(region.id), on: cx)
        }

        for node in visibleNodes(in: scene, camera: camera, viewSize: viewSize) {
            guard let frame = node.frame else { continue }
            let ownText = drawsOwnText(node.id, visibleEditorNodeID: visibleEditorNodeID)
            drawCard(node, frame: frame,
                     layout: ownText ? layouts[node.id] : nil,
                     angle: drawnAngle(for: node.id, straighten: straighten),
                     isSelected: selection == .node(node.id),
                     on: cx)
        }

        for tether in tethers(in: scene) { drawTether(tether, on: cx) }
        for chip in appearanceChips(in: scene) {
            drawChip(chip, title: chipTitle(for: chip.node, in: scene, scraps: scraps), on: cx)
        }
    }

    /// The wash, the outline, the chrome bar and its label, and the resize mark.
    ///
    /// Takes the context BY VALUE for the same reason `drawCard` does — nothing
    /// a region does may leak into the next thing drawn. Unlike a card it adds
    /// no transform of its own: a region is an area on the ground, not an object
    /// put down on it, so it never tilts.
    ///
    /// The chrome geometry comes from `CanvasRegionMetrics`, never spelled again
    /// here: Task 5 hit-tests the same rects, and a second spelling puts the mark
    /// and the target on different geometry.
    private static func drawRegion(_ region: CanvasRegion,
                                   in scene: CanvasScene,
                                   isSelected: Bool,
                                   on cx: GraphicsContext) {
        let shape = Path(roundedRect: region.frame, cornerRadius: regionCornerRadius)
        cx.fill(shape, with: .color(Color(nsColor: regionWash)))

        // The chrome bar is the only part of a region a writer can grab, so it
        // is the only part that is drawn as a surface rather than as an area —
        // a second coat of the same wash, not a different colour.
        let chrome = CanvasRegionMetrics.chromeRect(in: region.frame)
        cx.drawLayer { bar in
            bar.clip(to: shape)
            bar.fill(Path(chrome), with: .color(Color(nsColor: regionWash)))
        }

        cx.stroke(shape,
                  with: .color(Color(nsColor: isSelected
                                     ? CanvasMaterial.regionSelectedStroke
                                     : regionStroke)),
                  lineWidth: isSelected ? 2 : 1)

        var label = cx.resolve(Text(region.displayLabel).font(.system(size: 11, weight: .medium)))
        label.shading = .color(Color(nsColor: .secondaryLabelColor))
        let labelOrigin = CanvasRegionMetrics.labelOrigin(in: region.frame)
        cx.draw(label, at: labelOrigin, anchor: .topLeading)

        if region.isCollapsed {
            // A collapsed region's interior is empty by design, so the count
            // goes BESIDE the label rather than in the middle of nothing.
            var summary = cx.resolve(Text(collapsedSummary(for: region.id, in: scene))
                .font(.system(size: 11)))
            summary.shading = .color(Color(nsColor: .tertiaryLabelColor))
            cx.draw(summary,
                    at: CGPoint(x: labelOrigin.x + label.measure(in: chrome.size).width
                                + CanvasRegionMetrics.labelInset,
                                y: labelOrigin.y),
                    anchor: .topLeading)
        }

        cx.fill(regionResizeHandle(in: region.frame),
                with: .color(Color(nsColor: regionStroke)))
    }

    /// Softer than a card's 3: a region is an area, and a tight corner on an
    /// area reads as a panel.
    private static let regionCornerRadius: CGFloat = 6

    /// The region's resize mark — the triangle below the hypotenuse of
    /// `CanvasRegionMetrics.resizeHandleRect`, exactly as a card's mark sits
    /// inside its own corner square. The TARGET is the whole square; Task 5
    /// tests against `resizeHandleRect` and this only inks part of it, which is
    /// the right way round (see `resizeHandle`).
    private static func regionResizeHandle(in frame: CGRect) -> Path {
        let corner = CanvasRegionMetrics.resizeHandleRect(in: frame)
        var p = Path()
        p.move(to: CGPoint(x: corner.minX, y: corner.maxY))
        p.addLine(to: CGPoint(x: corner.maxX, y: corner.maxY))
        p.addLine(to: CGPoint(x: corner.maxX, y: corner.minY))
        p.closeSubpath()
        return p
    }

    /// §4.2's accepted cost, paid: a dashed hairline from the wandering card to
    /// the region that owns it.
    ///
    /// The alpha is REPLACED rather than multiplied — `regionStroke` already
    /// carries 0.30–0.35, and multiplying by `tetherOpacity` would give ~0.10,
    /// which is a line the writer cannot see at all.
    private static func drawTether(_ tether: Tether, on cx: GraphicsContext) {
        var path = Path()
        path.move(to: tether.from)
        path.addLine(to: tether.to)
        cx.stroke(path,
                  with: .color(Color(nsColor: regionStroke
                      .withAlphaComponent(CanvasMaterial.tetherOpacity))),
                  style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    /// §4.3's reference: a small chip carrying the title, with a hairline to the
    /// real card. Smaller than the thing it stands for, and drawn on the card's
    /// own paper at `chipOpacity` so it reads as lighter than a card without
    /// reading as a different material.
    private static func drawChip(_ chip: AppearanceChip,
                                 title: String,
                                 on cx: GraphicsContext) {
        var hairline = Path()
        hairline.move(to: CGPoint(x: chip.frame.midX, y: chip.frame.midY))
        hairline.addLine(to: chip.homeAnchor)
        cx.stroke(hairline,
                  with: .color(Color(nsColor: regionStroke
                      .withAlphaComponent(CanvasMaterial.tetherOpacity))),
                  style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

        let shape = Path(roundedRect: chip.frame, cornerRadius: chipHeight / 2)
        cx.fill(shape, with: .color(Color(nsColor: cardPaper)
            .opacity(CanvasMaterial.chipOpacity)))
        cx.stroke(shape, with: .color(Color(nsColor: regionStroke)), lineWidth: 0.5)

        var text = cx.resolve(Text(title).font(.system(size: 10)))
        text.shading = .color(Color(nsColor: .secondaryLabelColor))
        cx.drawLayer { inner in
            inner.clip(to: shape)
            inner.draw(text,
                       at: CGPoint(x: chip.frame.minX + chipTextInset, y: chip.frame.midY),
                       anchor: .leading)
        }
    }

    /// §7.2: crisp edges, honest objects sitting on the textured ground. The
    /// real/manufactured line runs between the ground and the cards, not through
    /// each card — so no paper fibre here.
    ///
    /// The rotation applies to the WHOLE card, chrome and text together (spec
    /// §7A.5). `angle` is already interpolated by `CanvasFocusStraighten`, so the
    /// card the editor is about to take over arrives here at 0°. A `nil` layout
    /// means "the editor is VISIBLE on this scrap and is drawing its text".
    ///
    /// Takes the context BY VALUE, and the label says so: this draws ON a
    /// context rather than INTO an `inout` one. Every card starts from the
    /// camera CTM `draw` set and adds its own rotation to a copy; nothing a card
    /// does may leak into the next one, and `draw` never reads the context back.
    private static func drawCard(_ node: CanvasNode,
                                 frame: CGRect,
                                 layout: ScrapLayout?,
                                 angle: Angle,
                                 isSelected: Bool,
                                 on cx: GraphicsContext) {
        let shape = Path(roundedRect: frame, cornerRadius: 3)

        var card = cx
        // ONE definition of the card rotation — the same transform `localPoint`
        // inverts. `concatenating` applies it in the card's space, INSIDE the
        // camera CTM already on the context.
        card.transform = cardTransform(inCard: frame, angle: angle)
            .concatenating(card.transform)

        // Light falls from one corner (§7.1) — a single soft drop, not a glow.
        // The caster is filled with the card's own paper, not with white: the
        // caster and the paper fill below antialias independently, so a sliver
        // of the caster's colour survives in the rounded-rect edge pixels. A
        // white caster is invisible in light mode and a faint light fringe
        // around every card in dark mode — the light-mode skeuomorph pasted
        // into the dark that `cardPaper` exists to avoid.
        card.drawLayer { shadow in
            shadow.addFilter(.shadow(color: .black.opacity(0.18), radius: 3, x: 1, y: 2))
            shadow.fill(shape, with: .color(Color(nsColor: cardPaper)))
        }
        card.fill(shape, with: .color(Color(nsColor: cardPaper)))

        switch node.kind {
        case .scrap:
            card.stroke(shape, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)
        case .item:
            // A placeholder reads as unfinished on purpose — 1C-d fills it in.
            card.stroke(shape, with: .color(Color(nsColor: .separatorColor)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        // Drawn OVER the kind's own border rather than replacing it, so a
        // selected item node keeps the dashes that say it is a placeholder.
        if isSelected {
            card.stroke(shape, with: .color(Color(nsColor: CanvasMaterial.regionSelectedStroke)),
                        lineWidth: 2)
        }

        card.fill(resizeHandle(in: frame),
                  with: .color(Color(nsColor: .separatorColor).opacity(0.8)))

        switch node.kind {
        case .scrap:
            // nil = this scrap's editor is mounted and IS its visible text.
            guard let layout else { return }
            let origin = CanvasCardMetrics.textOrigin(inCard: frame)
            card.drawLayer { inner in
                inner.clip(to: shape)
                inner.withCGContext { cg in
                    cg.saveGState()
                    cg.translateBy(x: origin.x, y: origin.y)
                    layout.draw(into: cg, at: .zero)
                    cg.restoreGState()
                }
            }
        case .item(let referenceId):
            var text = card.resolve(
                Text(placeholderLabel(forReference: referenceId))
                    .font(.system(size: 11)))
            text.shading = .color(Color(nsColor: .secondaryLabelColor))
            card.draw(text, at: CanvasCardMetrics.textOrigin(inCard: frame), anchor: .topLeading)
        }
    }

    /// The corner mark a writer aims at to rewrap a scrap.
    ///
    /// **The MARK is a triangle; the TARGET is the whole square**, and that is
    /// deliberate rather than a drift. `CanvasInteraction.begin` tests
    /// `x >= maxX - resizeHandleSize && y >= maxY - resizeHandleSize`, so the
    /// upper-left half of the square — above the triangle's hypotenuse — resizes
    /// without being inked. A target slightly larger than its mark is the right
    /// way round: it forgives a near miss, where the reverse would swallow drags
    /// the writer aimed at the card. One constant fixes the SIZE of both, so the
    /// two cannot drift apart; the shapes are not the same shape and this plan
    /// no longer claims they are.
    /// `CanvasInteractionTests.test_theUnmarkedHalfOfTheCornerSquareStillResizes`
    /// pins the over-size so a future tidy-up cannot quietly shrink the target
    /// to the ink.
    private static func resizeHandle(in frame: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: frame.maxX - resizeHandleSize, y: frame.maxY))
        p.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
        p.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - resizeHandleSize))
        p.closeSubpath()
        return p
    }
}
