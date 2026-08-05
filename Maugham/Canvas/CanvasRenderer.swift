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
    static let sweepStroke: NSColor = CanvasMaterial.dynamic(light: CanvasMaterial.lightSweepStroke,
                                                             dark: CanvasMaterial.darkSweepStroke)

    /// The region's two materials when the region is dimmed (§4).
    ///
    /// **A pair apiece, built from the same literals by the same rule**, because
    /// these are the two colours on this surface that carry their own alpha —
    /// and a pair, not a single value, so `dimmedAlpha`'s `min` is applied to
    /// each appearance's OWN dosage rather than to whichever one a reader
    /// happened to have in mind. That is what makes the wash's outcome a
    /// measurement instead of a special case: 0.07 and 0.09 are both under the
    /// dim, so `dimmedRegionWash` resolves to exactly `regionWash` in both
    /// appearances and a dimmed region keeps the area it draws — while the
    /// outline, the label and the cards inside it recede.
    static let dimmedRegionWash: NSColor = CanvasMaterial.dynamic(
        light: CanvasMaterial.lightRegionWash.withAlphaComponent(
            CanvasMaterial.dimmedAlpha(lit: CanvasMaterial.lightRegionWash.alphaComponent)),
        dark: CanvasMaterial.darkRegionWash.withAlphaComponent(
            CanvasMaterial.dimmedAlpha(lit: CanvasMaterial.darkRegionWash.alphaComponent)))
    static let dimmedRegionStroke: NSColor = CanvasMaterial.dynamic(
        light: CanvasMaterial.lightRegionStroke.withAlphaComponent(
            CanvasMaterial.dimmedAlpha(lit: CanvasMaterial.lightRegionStroke.alphaComponent)),
        dark: CanvasMaterial.darkRegionStroke.withAlphaComponent(
            CanvasMaterial.dimmedAlpha(lit: CanvasMaterial.darkRegionStroke.alphaComponent)))

    static func regionWash(dimmed: Bool) -> NSColor { dimmed ? dimmedRegionWash : regionWash }
    static func regionStroke(dimmed: Bool) -> NSColor { dimmed ? dimmedRegionStroke : regionStroke }

    /// The alpha to draw at, given the dosage this thing carries when lit.
    ///
    /// **Every dimmed alpha on this surface goes through here**, so there is one
    /// answer to "how is the dim applied" rather than one per primitive — and so
    /// that the thing the answer must never be (a product; see
    /// `CanvasMaterial.dimmedOpacity`) is unspellable at the call sites.
    static func alpha(_ lit: CGFloat, dimmed: Bool) -> CGFloat {
        dimmed ? CanvasMaterial.dimmedAlpha(lit: lit) : lit
    }

    /// Secondary text — a region's label, a chip's title, an item's caption, a
    /// line's label — dimmed or not.
    ///
    /// **`withAlphaComponent` and never `.opacity()`, and that is the whole
    /// point of this helper.** These label colours carry their own alpha —
    /// measured 0.498 / 0.549 for secondary and 0.259 / 0.247 for tertiary,
    /// light and dark — so `.opacity(dimmedOpacity)` on either is a PRODUCT and
    /// lands at 0.11 or 0.06: text the writer cannot read on a card they can
    /// still click. `withAlphaComponent` REPLACES the alpha and keeps the
    /// colour's per-appearance resolution, so this is `dimmedAlpha(lit:)`'s
    /// answer for both — both dosages are above the dim, which
    /// `CanvasHighlightRenderTests` pins so a system change cannot quietly turn
    /// the replacement into an amplification.
    static func textInk(_ lit: NSColor, dimmed: Bool) -> Color {
        Color(nsColor: dimmed ? lit.withAlphaComponent(CanvasMaterial.dimmedOpacity) : lit)
    }

    /// A line's ink, resolved per appearance from the pair in `CanvasMaterial`.
    /// Authored at full alpha there so `lineOpacity` is applied once, here.
    static let lineStroke: NSColor = CanvasMaterial.dynamic(light: CanvasMaterial.lightLineStroke,
                                                            dark: CanvasMaterial.darkLineStroke)

    /// **Whose hand made this** (spec §8A.2 constraint 1), resolved per
    /// appearance from the two pairs in `CanvasMaterial`. A card Claude put down
    /// takes a cooler, slightly darker paper; a line Claude drew strokes in a
    /// correspondingly cooler value. Same ink, same shape, same hairline weight —
    /// see `CanvasMaterial.lightClaudeCardPaper` for the whole reasoning,
    /// including why this is not a fourth card mark and where the light pair's
    /// ceiling comes from.
    static let claudeCardPaper: NSColor =
        CanvasMaterial.dynamic(light: CanvasMaterial.lightClaudeCardPaper,
                               dark: CanvasMaterial.darkClaudeCardPaper)
    static let claudeLineStroke: NSColor =
        CanvasMaterial.dynamic(light: CanvasMaterial.lightClaudeLineStroke,
                               dark: CanvasMaterial.darkClaudeLineStroke)

    /// Which paper a card is drawn on — **one definition**, so the shadow caster
    /// and the fill under it cannot disagree. They antialias independently and a
    /// sliver of the caster survives in every rounded-rect edge pixel, so two
    /// answers here would put a fringe of the wrong author's paper around the
    /// card.
    ///
    /// **An item node is never tinted, and the renderer refuses it rather than
    /// trusting the model.** An item node is the page the words were read *off*:
    /// it already exists as itself, and tinting it would say Claude took the
    /// photograph.
    ///
    /// **This is the NORMAL path, not a defence against hand-editing.** Since
    /// 2026-07-30 `CanvasClaudePlacement` writes `author: .claude` on every
    /// source page it creates — the only item node the product creates at all —
    /// because Claude did mint the node and choose its place. So the guard below
    /// fires on the ordinary case, and the whole reason `paper(for:)` asks about
    /// `kind` and not only about `author` is that the two provenance signals
    /// answer different questions: the tint says *whose words these are* and the
    /// tilt (`seededRotation(for:)`, which keys on the author alone) says *who
    /// put this here*. A source page is the one node where those differ, so it is
    /// drawn straight and untinted. An `author = nil` recorded here to obtain the
    /// colour decision was the shape until then, and it put a falsehood in a
    /// field meaning "who made this card".
    ///
    /// `CanvasAuthorRenderTests.test_anItemNodeIsNeverTinted` holds both halves.
    ///
    /// **`CanvasAccessibility` deliberately does NOT mirror this refusal**, and
    /// that is not drift. It speaks `claudeTerm` on an item node whose author is
    /// `.claude`, because the spoken label is the only channel a VoiceOver user
    /// has for *either* signal and the tilt's answer — Claude placed this — is
    /// true here and inaudible otherwise. Denver ruled on 2026-07-30 that one
    /// phrase covers all three primitives rather than two the listener has to
    /// keep apart. So this function refuses the tint on the tint's terms, and
    /// that arm speaks on the tilt's; anyone changing one should read the other
    /// rather than making them agree.
    static func paper(for node: CanvasNode) -> NSColor {
        guard case .scrap = node.kind, node.author == .claude else { return cardPaper }
        return claudeCardPaper
    }

    /// §7.2: everything the writer put down sits at a seeded fraction of a
    /// degree — nothing is rough, but everything was *put down* rather than
    /// snapped to a grid.
    ///
    /// **The lean is also the provenance signal (spec §8A.2 constraint 1), and
    /// that is why the band excludes zero.** The magnitude lands in
    /// `minimumTiltDegrees ... maximumTiltDegrees` and the sign comes off a bit
    /// the magnitude does not use, so a human thing is never drawn straight and
    /// **straight means Claude**. Before the dead band a seed near the middle of
    /// the range gave a writer's own card an essentially level draw, which made
    /// the signal usually-right — see `CanvasMaterial.minimumTiltDegrees` for why
    /// that is worse than no signal.
    ///
    /// Deterministic from the id. A card must never shimmer or shift between
    /// renders, so this cannot be `Double.random` and cannot depend on anything
    /// that varies per frame. SplitMix64 over a stable string hash — note
    /// `String.hashValue` is seeded per process and would give a card a different
    /// tilt on every launch.
    ///
    /// Private, and reached only through the two `seededRotation` overloads
    /// below: they are where the author is consulted, and a caller that could
    /// take the raw lean would be a second place deciding whether a thing tilts.
    private static func seededTilt(fromID raw: String) -> Angle {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a offset basis
        for byte in raw.utf8 {
            h = (h ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        // SplitMix64 finaliser — cheap, and well distributed in the low bits.
        var z = h &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        z = z ^ (z >> 31)

        // Magnitude from the low bits, sign from the TOP bit — two independent
        // draws off one hash, so the sign is not a function of where in the band
        // the magnitude landed.
        let unit = Double(z % 10_000) / 10_000.0        // 0..<1
        let magnitude = CanvasMaterial.minimumTiltDegrees
            + unit * (CanvasMaterial.maximumTiltDegrees - CanvasMaterial.minimumTiltDegrees)
        return .degrees((z >> 63) & 1 == 0 ? -magnitude : magnitude)
    }

    /// A card's seeded lean. **Claude's cards are drawn at exactly 0°.**
    ///
    /// It takes the NODE rather than the id, and that is the whole guard: the
    /// author is read here, in the one function `drawnAngle`, `drawCard` and the
    /// caret's inverse transform all descend from, so the draw pass and the hit
    /// test cannot disagree about whether a card is tilted. An id-only overload
    /// would be a way to get the lean without the question.
    ///
    /// **An item node is included, and that is the point of keying on `author`
    /// alone** rather than on `paper(for:)`'s rule. The two signals say different
    /// things: the tint says *whose words these are*, and a photographed page's
    /// words are the writer's; the tilt says *who put this here*, and Claude did.
    /// So the source page is straight and untinted, which is the honest reading
    /// of both.
    static func seededRotation(for node: CanvasNode) -> Angle {
        node.author == .claude ? .zero : seededTilt(fromID: node.id.raw)
    }

    /// A region's seeded lean, on the same rule and off the same seed function.
    /// **Claude's regions are drawn at exactly 0°.**
    ///
    /// Regions did not lean at all before 1C-c3, and giving them one is what
    /// makes "straight means Claude" true of the primitive Claude creates on
    /// every call rather than only of the cards inside it.
    static func seededRotation(for region: CanvasRegion) -> Angle {
        region.author == .claude ? .zero : seededTilt(fromID: region.id.raw)
    }

    /// The angle a card is ACTUALLY drawn at right now: its seeded angle, scaled
    /// down toward zero as it straightens (spec §7A.5). At full straighten it is
    /// exactly level, which is what lets the editor take over the text
    /// axis-aligned and the §7A.2 glyph-origin pin compare two unrotated layouts.
    ///
    /// A Claude card is already at zero, so it has nothing to straighten and the
    /// focus affordance is invisible on one. That is accepted rather than worked
    /// around: §7A.5's promise is that the card being edited is the only *square*
    /// one, and inventing a lean to take away would undo the provenance signal
    /// for the duration of every visit.
    static func drawnAngle(for node: CanvasNode, straighten: CanvasFocusStraighten) -> Angle {
        .degrees(seededRotation(for: node).degrees
                 * (1 - Double(straighten.progress(for: node.id))))
    }

    /// The rotation a card — or, since 1C-c3, a region — is drawn under, about
    /// its own centre. **The only definition of it.** The parameter keeps a
    /// card's name because a card is the case with an inverse
    /// (`localPoint(_:inCard:angle:)` for the caret); a region's grab is
    /// deliberately unrotated, so it never asks for one.
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
    /// moves.** At the calibrated θ = 1.0° a default 240×80 card overhangs
    /// ~2.2 pt (r = 126.5) and a generous 480×160 card ~4.4 pt (r = 253) — so
    /// 12 pt covers the shadow and a wide card together with room left. At the
    /// original θ = 0.6° the same arithmetic gave 1.4 pt and 8 pt sufficed; the
    /// 2026-07-27 doubling to 1.2° (settled back to 1.0° the same day) would
    /// have let a wide card's corner be culled while it was still on screen if
    /// this had not been re-done with it.
    ///
    /// **A REGION does not use this budget alone** — it has no size ceiling, so
    /// `visibleRegions` widens the shared bleed per region by
    /// `rotationOverhang(of:)`. See there.
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

    /// How far a rotated rect's corner swings outside the rect, at the calibrated
    /// tilt. `r·θ`, with `r` the half-diagonal — the same arithmetic
    /// `cullingBleed`'s doc comment does by hand for a card.
    ///
    /// It exists because **a region is unbounded in size and a card is not.**
    /// `cullingBleed` is a flat 12 pt sized against a generous 480×160 card; a
    /// region drawn round twenty cards can have a half-diagonal past 700 pt,
    /// where 1° is over 12 pt and the flat budget would cull a region whose
    /// corner was still on screen. Per-region and O(1), so the cull stays
    /// viewport-proportional.
    static func rotationOverhang(of size: CGSize) -> CGFloat {
        let radius = (size.width * size.width + size.height * size.height).squareRoot() / 2
        return radius * CGFloat(CanvasMaterial.maximumTiltDegrees * .pi / 180)
    }

    /// The regions the viewport can see, culled exactly as the nodes are.
    ///
    /// A region carries no shadow, but **since 1C-c3 it carries a seeded angle**,
    /// so the shared `cullingBleed` is widened per region by its own
    /// `rotationOverhang` — see there for why a flat budget cannot serve a
    /// primitive with no size ceiling.
    static func visibleRegions(in scene: CanvasScene,
                               camera: CanvasCamera,
                               viewSize: CGSize) -> [CanvasRegion] {
        visibleRegions(scene.regions, camera: camera, viewSize: viewSize)
    }

    /// The same, over a region list the caller has already ordered.
    ///
    /// `CanvasScene.regions` SORTS on every access, and `draw` needs the list
    /// three times a frame — for the cull, for the tethers and for the chips.
    /// Three calls is three sorts of the whole region set per frame, which is the
    /// `CanvasScene.nodes` mistake in a second id space; `draw` takes it once and
    /// hands it down.
    private static func visibleRegions(_ regions: [CanvasRegion],
                                       camera: CanvasCamera,
                                       viewSize: CGSize) -> [CanvasRegion] {
        let viewport = camera.visibleContentRect(viewSize: viewSize)
            .insetBy(dx: -cullingBleed, dy: -cullingBleed)
        return regions.filter {
            let overhang = rotationOverhang(of: $0.frame.size)
            return $0.frame.insetBy(dx: -overhang, dy: -overhang).intersects(viewport)
        }
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
        tethers(in: scene, regions: scene.regions)
    }

    private static func tethers(in scene: CanvasScene,
                                regions: [CanvasRegion]) -> [Tether] {
        // A collapsed region draws none of its residents, so a line to one
        // lands on empty ground.
        regions.filter { !$0.isCollapsed }.flatMap { region -> [Tether] in
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
        appearanceChips(in: scene, regions: scene.regions)
    }

    private static func appearanceChips(in scene: CanvasScene,
                                        regions: [CanvasRegion]) -> [AppearanceChip] {
        regions.filter { !$0.isCollapsed }.flatMap { region -> [AppearanceChip] in
            // Filtered BEFORE `enumerated()`, not inside it: the index is the
            // chip's place in the stack, and skipping a member mid-walk would
            // leave a gap in the column where the skipped one would have been.
            //
            // A hidden node is skipped for the reason `tethers` skips a
            // collapsed region's residents — the card is not drawn, so the
            // hairline points at bare ground. It is reachable rather than
            // theoretical: a node can be an appearance in an expanded region and
            // a resident of a collapsed one at the same time, because `join`
            // only forgets it where it lives.
            region.appearances
                .sorted { $0.raw < $1.raw }
                .filter { !scene.isHidden($0) && scene.node($0)?.frame != nil }
                .enumerated().compactMap { index, id in
                    guard let card = scene.node(id)?.frame else { return nil }
                    let top = region.frame.minY + CanvasRegionMetrics.chromeHeight
                        + CGFloat(index) * (chipHeight + chipSpacing)
                    // Chips stack down the region's inside edge and stop at its
                    // bottom; a region too short to hold them all shows what fits
                    // rather than spilling references onto the ground outside it.
                    guard top + chipHeight <= region.frame.maxY else { return nil }
                    // …and the same guard on the OTHER axis, which is the one it
                    // is easy to forget. `chipWidth` is 150 and
                    // `CanvasRegionMetrics.minimumSide` is 80, so an unclamped
                    // chip in a region at its own minimum hangs 80 pt outside it,
                    // over bare ground and over whatever cards are there.
                    let width = min(chipWidth,
                                    region.frame.width - CanvasRegionMetrics.labelInset * 2)
                    guard width > 0 else { return nil }
                    return AppearanceChip(
                        node: id, region: region.id,
                        frame: CGRect(x: region.frame.minX + CanvasRegionMetrics.labelInset,
                                      y: top, width: width, height: chipHeight),
                        homeAnchor: CGPoint(x: card.midX, y: card.midY))
                }
        }
    }

    // MARK: - Lines

    /// The lines whose bounding box meets the viewport, and only those.
    ///
    /// **The projection itself is `CanvasScene.drawnLines`, not a pass of this
    /// file's.** It reads node frames and the scene's hidden set and applies no
    /// camera and no appearance, so it is scene knowledge — and it has a second
    /// caller in `CanvasLineHit`, which is a pure geometry enum one layer below
    /// drawing. Kept here it left a `public` type resting on an `internal` nested
    /// one. What stays here is the part that is genuinely the renderer's: the
    /// culling, which is about a viewport.
    ///
    /// Per-frame work on this surface is viewport-proportional by design — the
    /// rule `visibleNodes` and `visibleRegions` follow, and the reason the
    /// 2,000-node probe passes. Lines are the one collection nothing bounds: a
    /// writer can draw one for every card, so "there are fewer lines than nodes"
    /// is not an argument. AREA.md's Scale section already names tethers and
    /// chips as the known unbounded per-frame work; lines joining that list
    /// uncounted would be a regression on the one number this surface defends.
    ///
    /// Bounding box rather than exact segment/rect intersection: the false
    /// positives are long diagonals whose box straddles the viewport, which are
    /// cheap to stroke and correct to draw.
    ///
    /// **The hairline inset is not a rounding nicety**, and the reason is not
    /// quite the one this was written with. A horizontal or vertical line has a
    /// zero-height or zero-width box — two cards side by side is the ordinary
    /// case, not the corner one — and a degenerate box is at the mercy of
    /// whichever emptiness rule the cull happens to be spelled with.
    ///
    /// **Measured 2026-07-28 on macOS 26.5, because the obvious claim is wrong:**
    /// `CGRect.intersects` is false only for a NULL rect, not for an empty one,
    /// so `CGRect(x: 100, y: 20, width: 440, height: 0).intersects(viewport)` is
    /// `true` today and this call as written would survive without the inset. The
    /// trap is one spelling over: `intersection(viewport)` of that same box is
    /// **not null and IS empty**, so a tidy-up to `!box.intersection(viewport)
    /// .isEmpty` — which reads as a synonym — silently stops drawing every
    /// axis-aligned line on the canvas. The inset removes the whole question by
    /// giving the box area.
    ///
    /// `CanvasLineRenderTests.test_anAxisAlignedLineIsNotCulledByItsZeroHeightBox`
    /// asserts against `boundingBox` directly for exactly that reason: an
    /// assertion on `visibleLines`'s output alone cannot see this inset today.
    static func visibleLines(in scene: CanvasScene,
                             camera: CanvasCamera,
                             viewSize: CGSize) -> [CanvasDrawnLine] {
        let viewport = camera.visibleContentRect(viewSize: viewSize)
            .insetBy(dx: -cullingBleed, dy: -cullingBleed)
        return scene.drawnLines.filter { boundingBox(of: $0).intersects(viewport) }
    }

    /// Half a point on every side — enough to give an axis-aligned segment a
    /// non-empty box, and small enough to change nothing else.
    private static let lineBoxInset: CGFloat = 0.5

    /// The rect `visibleLines` culls against — internal rather than private
    /// because it is the only place the inset above is observable. See there.
    static func boundingBox(of line: CanvasDrawnLine) -> CGRect {
        CGRect(x: min(line.from.x, line.to.x),
               y: min(line.from.y, line.to.y),
               width: abs(line.to.x - line.from.x),
               height: abs(line.to.y - line.from.y))
            .insetBy(dx: -lineBoxInset, dy: -lineBoxInset)
    }

    /// The label pill, centred on the segment's midpoint. Empty when there is no
    /// label — an unlabelled line must not reserve a pill of empty ground.
    ///
    /// The pill measures its text by a per-character advance rather than through
    /// a TextKit stack, and that is legitimate HERE and nowhere near a card:
    /// §7A.2's same-stack rule exists because a card's drawn text has to agree
    /// with a mounted editor's, and no editor ever mounts on a line. The pill is
    /// clipped to itself when it draws, so an under-estimate costs a truncated
    /// label rather than text spilling onto the ground.
    ///
    /// **The trim is `.whitespacesAndNewlines`, which is the same set
    /// `LineInspector.normalise` and `CanvasAccessibility.connectionPhrase` trim**
    /// *(widened 1C-c3)*. It was `.whitespaces` — space and tab only — so a label
    /// of `"\n"` drew a pill with nothing in it while the inspector called the
    /// same string no name and the accessibility layer said nothing about it:
    /// three readings of one question, and the drawn one was the odd one out.
    /// The route in is a hand-edited `.maugham/canvas.json` — `CanvasSceneCodec`
    /// does not normalise labels on load and `normalise` guards only the
    /// inspector — and it stays that way after 1C-c3, because
    /// `add_canvas_scraps`' `connect` carries no label at all. Narrow, real, and
    /// a one-word fix over a value: `test_aWhitespaceOnlyLabelDrawsNoPill`.
    static func lineLabelBox(for geometry: CanvasDrawnLine) -> CGRect {
        guard let label = geometry.label,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .null }
        let width = CGFloat(label.count) * CanvasMaterial.lineLabelFontSize * labelAdvanceRatio
            + CanvasMaterial.lineLabelPadding * 2
        let midpoint = CGPoint(x: (geometry.from.x + geometry.to.x) / 2,
                               y: (geometry.from.y + geometry.to.y) / 2)
        return CGRect(x: midpoint.x - width / 2,
                      y: midpoint.y - CanvasMaterial.lineLabelHeight / 2,
                      width: width, height: CanvasMaterial.lineLabelHeight)
    }

    /// A rough mean advance for the system font, as a fraction of its point size.
    /// Geometry, so it lives here rather than in `CanvasMaterial` — nobody tunes
    /// this by eye.
    private static let labelAdvanceRatio: CGFloat = 0.62

    /// The size of the connect affordance on a selected card's right edge — the
    /// side of the square Task 4 hit-tests, and the box the mark is centred in.
    ///
    /// One constant fixes both, exactly as `resizeHandleSize` does for the resize
    /// corner, so the mark and its target cannot drift apart.
    static let connectHandleSize: CGFloat = 14

    /// The TARGET a line is dragged from: a `connectHandleSize` square on the
    /// card's right edge, vertically centred, **clamped to stay above the resize
    /// square** — and empty on a card too short for both.
    ///
    /// On a short card **the corner belongs to resize**: it is the permanent
    /// mark, and a connect target that moved depending on the card's height would
    /// be worse than one that is sometimes absent. A writer can always still make
    /// a line with ⇧-drag, which has no chrome to collide with.
    static func connectHandleRect(inCard frame: CGRect) -> CGRect {
        let ceiling = frame.maxY - resizeHandleSize - connectHandleSize
        guard ceiling >= frame.minY else { return .null }
        return CGRect(x: frame.maxX - connectHandleSize,
                      y: min(frame.midY - connectHandleSize / 2, ceiling),
                      width: connectHandleSize, height: connectHandleSize)
    }

    /// The MARK inside that target: a dot, centred, strictly smaller. See
    /// `resizeHandle` for why a target larger than its ink is the right way
    /// round.
    static func connectMarkRect(inCard frame: CGRect) -> CGRect {
        let target = connectHandleRect(inCard: frame)
        guard !target.isEmpty else { return .null }
        let d = CanvasMaterial.connectMarkDiameter
        return CGRect(x: target.midX - d / 2, y: target.midY - d / 2, width: d, height: d)
    }

    /// The promoted stripe's rect, inside the card's own rounded rect. Clipped
    /// to the card by the caller, so the rounded corners cut it rather than the
    /// stripe squaring them off.
    static func promotedMarkRect(inCard frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY,
               width: CanvasMaterial.promotedMarkWidth, height: frame.height)
    }

    /// The same stripe on a region's chrome bar — the only part of a region that
    /// is reliably on screen when it is collapsed.
    static func promotedMarkRect(inRegionChrome frame: CGRect) -> CGRect {
        let chrome = CanvasRegionMetrics.chromeRect(in: frame)
        return CGRect(x: chrome.minX, y: chrome.minY,
                      width: CanvasMaterial.promotedMarkWidth, height: chrome.height)
    }

    /// The first non-empty line of the scrap, so a chip says WHICH card it
    /// stands for. A blank chip is indistinguishable from a rendering bug.
    ///
    /// "Non-empty" is judged AFTER trimming, and the difference is a real scrap:
    /// `omittingEmptySubsequences` drops `""` but not `"   "`, so a scrap that
    /// opens with an indented blank line would take that line, trim it to
    /// nothing, and announce itself as empty while carrying text.
    ///
    /// **An item node's chip says what the CARD says**, which since 1C-d is its
    /// resolved title rather than its reference id — one fact, one wording, in the
    /// two places a writer can meet the same node. A chip for an item whose facts
    /// have not resolved says nothing at all rather than falling back to an id: a
    /// blank moment is a state the surface is already in for its card, and a code
    /// is not something the writer can read.
    static func chipTitle(for id: CanvasNodeID,
                          in scene: CanvasScene,
                          scraps: [CanvasNodeID: String],
                          items: CanvasItemPresentation) -> String {
        if case .item? = scene.node(id)?.kind {
            return items.item(for: id)?.facts.title ?? ""
        }
        let line = ScrapText.firstLine(of: scraps[id] ?? "")
        return line.isEmpty ? CanvasAccessibility.emptyScrapValue : line
    }

    /// What separates a region's own label from the name of the piece it belongs
    /// to (§4.2). A mark rather than a gap: at the same size and the same ink,
    /// "Act II fog Chapter Two" reads as one title the writer never typed.
    static let borrowedNameSeparator = "· "

    /// The mark an elided run ends with. A constant so the tests assert what
    /// ships, exactly as `CanvasAccessibility`'s terms are.
    static let ellipsis = "…"

    /// **Shorten `string` until it fits `width`, and mark that it was shortened.**
    ///
    /// **A truncated STRING and never a clipped context, and that is measured
    /// rather than preferred.** Two spellings were tried first and both were
    /// abandoned on the same evidence (2026-08-04): drawing a `ResolvedText`
    /// `in:` a narrow rect **wraps** to a second line rather than eliding, and a
    /// second line of 11 pt does not fit in a 24 pt bar; and clipping the context
    /// the text is drawn on — whether through `drawLayer` or by clipping a copy —
    /// makes two renders of the SAME region differ by two pixels, reproducibly,
    /// which `CanvasAuthorRenderTests.test_aClaudeRegionIsDrawnSquareAndTheWriters
    /// IsNot`'s control caught. Every drawn-output fixture on this surface is a
    /// diff between two renders, so clipped text would put a permanent noise
    /// floor under all of them. An ellipsis is also simply better than a sliced
    /// glyph.
    ///
    /// A binary search rather than a walk, so a long label costs a handful of
    /// measurements rather than one per character — and `measuring` is injected so
    /// this can be tested as arithmetic, with nothing rendering.
    static func elide(_ string: String, to width: CGFloat,
                      measuring: (String) -> CGFloat) -> String {
        guard measuring(string) > width else { return string }
        guard width > 0 else { return "" }
        // The largest prefix whose elided form still fits. `lo` is known to fit
        // (the empty prefix plus the mark is the smallest thing this can return,
        // and a bar too narrow even for that gets the mark alone rather than a
        // fragment that reads as a word).
        var lo = 0, hi = string.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let candidate = String(string.prefix(mid)) + ellipsis
            if measuring(candidate) <= width { lo = mid } else { hi = mid - 1 }
        }
        return String(string.prefix(lo)) + ellipsis
    }

    /// **How much of the chrome bar the region's OWN label may use, given what
    /// the borrowed name needs beside it.**
    ///
    /// The rule this expresses is §4.2's truncation decision, and the runs are
    /// ordered by what the writer cannot recover elsewhere: a narrow region loses
    /// its card count before the name of the piece it belongs to (the count comes
    /// back by expanding it, and VoiceOver says it in the value), and never that
    /// name before its own label (the label the writer chose and can read in the
    /// inspector; the borrowed name is available nowhere else at the moment the
    /// gesture is being aimed). So **the region's own label yields and the
    /// borrowed name does not.**
    ///
    /// It is a `static func` over its inputs for this directory's stated reason —
    /// a decision one level above a primitive is exactly where unreachable halves
    /// have shipped here before — and it is the only place the two insets are
    /// arithmetic rather than a draw position.
    ///
    /// With nothing borrowed the label keeps the whole bar, which is what it has
    /// always had. With something borrowed, the leftover is the bar minus that
    /// name minus one inset between them; clamped at zero, because a negative
    /// width flips the clip rect and draws the label straight over the name it
    /// was supposed to yield to.
    static func regionLabelWidthBudget(in frame: CGRect, borrowedWidth: CGFloat) -> CGFloat {
        let bar = frame.width - 2 * CanvasRegionMetrics.labelInset
        guard borrowedWidth > 0 else { return max(0, bar) }
        return max(0, bar - borrowedWidth - CanvasRegionMetrics.labelInset)
    }

    /// What a collapsed region says it is holding. §7/§10 answer crowding by
    /// collapsing rather than by minting more canvases — so a collapsed region
    /// that showed an empty interior would read as an empty region.
    static func collapsedSummary(for id: CanvasRegionID, in scene: CanvasScene) -> String {
        let n = CanvasMembership.residents(of: id, in: scene).count
        return n == 1 ? "1 card" : "\(n) cards"
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
    /// `highlight` is spec §4's dim, and it is a parameter here for exactly
    /// `selection`'s reason: a non-scene, non-camera fact the VIEW resolves and
    /// hands down, with this file deriving nothing from it. It is asked per
    /// object and answered by set membership — the derivation is
    /// scene-proportional and lives in `CanvasHighlight.resolve`, cached on the
    /// structural counter (tripwire 30). **The dim is de-emphasis and never
    /// disabling**: a dimmed card is still hit-tested, still selectable, and its
    /// selection chrome is drawn at full strength on purpose, because a
    /// selection the writer cannot find is worse than no dim at all. The sweep
    /// and the pending line are never dimmed either — they are the writer's live
    /// gesture rather than part of the scene being filtered.
    ///
    /// `pieceTitles` is §4.2's answer and arrives on `highlight`'s exact terms: a
    /// resolved, non-scene fact the VIEW is handed and this file derives nothing
    /// from. It is asked once per visible region and answered by a dictionary
    /// lookup — the manifest walk behind it is `ProjectWindow`'s, on a body that
    /// re-evaluates per manifest change rather than per frame (tripwire 4). Only
    /// `drawRegion` reads it, and only for a region the dim has already marked.
    ///
    /// Five passes, and the order is the design:
    ///
    /// 1. **Regions, BENEATH everything.** §4 makes a region *where the cards
    ///    are*, not a panel they sit on — a wash that painted over a card would
    ///    make the region the object and the cards its decoration.
    /// 2. **Lines, above the WHOLE region pass and beneath the cards.** Above
    ///    the region because a line running into a region's area must not
    ///    vanish under it — and above *every part* of it, the bar and the label
    ///    and the resize mark as well as the wash, because `drawRegion` is one
    ///    pass and **the thing drawn on top takes the click**: Task 5 hit-tests
    ///    in this order, so a line that inked over a region's title while the
    ///    title silently took the click would be hit-testing disagreeing with
    ///    what is visibly frontmost. What one rule buys is that a writer can
    ///    state it and never be surprised. Beneath the cards because a line's
    ///    job is to connect cards, and a line crossing over one reads as damage.
    /// 3. **Cards.**
    /// 4. **Tethers and chips, ABOVE the cards.** A reference the writer cannot
    ///    see is not a reference, and both of these are lines and labels that
    ///    would otherwise be buried under the very card they point at.
    /// 5. **The sweep and the pending line, ABOVE EVERYTHING.** They are
    ///    transient chrome rather than part of the scene — the only two things
    ///    drawn here that do not exist in the model — and a sweep the cards drew
    ///    over would read as being *behind* the canvas. That is not a corner
    ///    case: a sweep can only START on bare canvas but is dragged freely
    ///    across whatever is there, so passing over cards is the ordinary case,
    ///    not the exception. The same is true of a line being pulled from one
    ///    card to another, which by definition ends over a card.
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
                     items: CanvasItemPresentation,
                     selection: CanvasSelection?,
                     highlight: CanvasHighlight,
                     pieceTitles: CanvasPieceTitles,
                     visibleEditorNodeID: CanvasNodeID?,
                     straighten: CanvasFocusStraighten,
                     pendingRegionDraw: CGRect?,
                     pendingLine: (from: CGPoint, to: CGPoint)?,
                     into cx: inout GraphicsContext) {
        cx.translateBy(x: camera.pan.x, y: camera.pan.y)
        cx.scaleBy(x: camera.zoom, y: camera.zoom)

        // Ordered ONCE and handed to all three region passes — `regions` sorts
        // the whole set on every access, and this runs per frame.
        let regions = scene.regions

        for region in visibleRegions(regions, camera: camera, viewSize: viewSize) {
            let isDimmed = highlight.isDimmed(region: region.id)
            drawRegion(region, in: scene, isSelected: selection == .region(region.id),
                       isDimmed: isDimmed,
                       // §4.2. Resolved through the ONE predicate the spoken
                       // label also calls, so the drawn region and the announced
                       // region cannot disagree about whose it is.
                       boundElsewhere: pieceTitles.boundElsewhere(region, isDimmed: isDimmed),
                       on: cx)
        }

        for line in visibleLines(in: scene, camera: camera, viewSize: viewSize) {
            drawLine(line, isSelected: selection == .line(line.id),
                     isDimmed: highlight.isDimmed(line: line.id), on: cx)
        }

        for node in visibleNodes(in: scene, camera: camera, viewSize: viewSize) {
            guard let frame = node.frame else { continue }
            let ownText = drawsOwnText(node.id, visibleEditorNodeID: visibleEditorNodeID)
            drawCard(node, frame: frame,
                     layout: ownText ? layouts[node.id] : nil,
                     item: items.item(for: node.id),
                     angle: drawnAngle(for: node, straighten: straighten),
                     isSelected: selection == .node(node.id),
                     isDimmed: highlight.isDimmed(node: node.id),
                     on: cx)
        }

        // A tether explains that this card lives in that region, so it is lit
        // only when both ends are — and since every resident of a lit region is
        // itself lit, asking both is belt and braces rather than two rules.
        for tether in tethers(in: scene, regions: regions) {
            drawTether(tether,
                       isDimmed: highlight.isDimmed(region: tether.region)
                           || highlight.isDimmed(node: tether.node),
                       on: cx)
        }
        // A chip follows the CARD it stands for and not the region it is drawn
        // in: a chip is a reference to a card living elsewhere, and drawing the
        // reference dimmed while the card itself is lit would say the same card
        // is two things at once.
        for chip in appearanceChips(in: scene, regions: regions) {
            drawChip(chip,
                     title: chipTitle(for: chip.node, in: scene, scraps: scraps, items: items),
                     isDimmed: highlight.isDimmed(node: chip.node),
                     on: cx)
        }

        if let pendingRegionDraw { drawSweep(pendingRegionDraw, on: cx) }
        if let pendingLine { drawPendingLine(from: pendingLine.from, to: pendingLine.to, on: cx) }
    }

    /// A line the writer made: a stroke between two card centres, with its label
    /// on a pill at the midpoint if it has one.
    ///
    /// **Selection draws heavier and fully opaque rather than in an accent
    /// colour.** The canvas already spends its colour budget on the region ring
    /// and the palette wash (§7.1), and a line is thin enough that weight reads
    /// faster than hue.
    ///
    /// Takes the context BY VALUE, exactly as `drawCard`, `drawRegion`,
    /// `drawTether` and `drawChip` do — nothing a pass does may leak into the
    /// next thing drawn.
    private static func drawLine(_ line: CanvasDrawnLine,
                                 isSelected: Bool,
                                 isDimmed: Bool,
                                 on cx: GraphicsContext) {
        var path = Path()
        path.move(to: line.from)
        path.addLine(to: line.to)
        // **Whose hand drew it is in the STROKE and nowhere else** (§8A.2): same
        // weight, same opacity, same shape, a cooler value. The label pill below
        // deliberately keeps the writer's `cardPaper` — it is a legibility
        // backing rather than a statement about the line, an unlabelled line has
        // none at all, and tinting it would make a labelled Claude line say so
        // twice while an unlabelled one said it once.
        // The dim REPLACES the line's own dosage rather than scaling it — a
        // selected line is at 1 and an unselected one at 0.6, and a product
        // would put the two at different depths of the same dim.
        cx.stroke(path,
                  with: .color(Color(nsColor: line.author == .claude ? claudeLineStroke
                                                                     : lineStroke)
                      .opacity(alpha(isSelected ? 1 : CanvasMaterial.lineOpacity,
                                     dimmed: isDimmed))),
                  lineWidth: isSelected ? CanvasMaterial.selectedLineWidth
                                        : CanvasMaterial.lineWidth)

        // `.null` for an unlabelled line, so an unlabelled one reserves no pill
        // of empty ground — see `lineLabelBox`.
        let box = lineLabelBox(for: line)
        guard let label = line.label, !box.isEmpty else { return }
        let pill = Path(roundedRect: box, cornerRadius: box.height / 2)
        cx.fill(pill, with: .color(Color(nsColor: cardPaper)
            .opacity(alpha(CanvasMaterial.lineLabelOpacity, dimmed: isDimmed))))

        var text = cx.resolve(Text(label)
            .font(.system(size: CanvasMaterial.lineLabelFontSize)))
        text.shading = .color(textInk(.secondaryLabelColor, dimmed: isDimmed))
        cx.drawLayer { inner in
            // Clipped, so a label the per-character estimate under-measured is
            // truncated rather than spilling onto the ground beside the pill.
            //
            // **This is the surviving instance of the thing `elide`'s doc comment
            // measured, and it is left deliberately rather than overlooked**
            // (2026-08-04). Clipping the context text is drawn on makes two
            // renders of the same content differ by two pixels, reproducibly —
            // so any future drawn-output fixture that diffs two renders of a
            // LABELLED LINE carries a noise floor, and would read as a real
            // difference. Nothing compares two such renders today, which is the
            // only reason this is not already failing. §4.2's region bar took the
            // string-elision route instead; if a fixture ever needs a stable line
            // label, this is the site to convert, and `elide` is the shape.
            inner.clip(to: pill)
            inner.draw(text, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
        }
    }

    /// The line under the pointer, before it is a line.
    ///
    /// **Dashed and drawn last**, for the two reasons `drawSweep` is: nothing has
    /// been made yet, and chrome that the scene draws over stops being chrome.
    /// A pending line ends under the pointer, which is usually over the card it
    /// is about to reach, so being drawn over the cards is the ordinary case.
    ///
    /// It takes two points rather than reaching into `CanvasInteraction`: the
    /// renderer knows nothing about gestures, and `pendingRegionDraw: CGRect?`
    /// is the precedent one parameter over.
    private static func drawPendingLine(from: CGPoint, to: CGPoint, on cx: GraphicsContext) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        cx.stroke(path,
                  with: .color(Color(nsColor: sweepStroke)),
                  style: StrokeStyle(lineWidth: CanvasMaterial.pendingLineWidth,
                                     dash: CanvasMaterial.pendingLineDash))
    }

    /// The rectangle the writer is sweeping out, before it is a region.
    ///
    /// **Dashed, unfilled, and drawn last.** Unfilled because a wash would say
    /// the area is already claimed; dashed because nothing has been made yet;
    /// last because it is the one thing on this surface that is not in the
    /// model, and chrome that the scene draws over stops being chrome.
    ///
    /// `regionCornerRadius`, so the shape the writer is dragging out is the
    /// shape they get. Deliberately NOT gated on `minimumSide`: an outline that
    /// only appeared once the sweep was large enough would pop into existence
    /// mid-gesture, which reads as a glitch — and the sweeps it would hide are
    /// the ones too small to see anyway.
    ///
    /// Every length here is in CONTENT points, under the camera CTM the caller
    /// has already applied, exactly like the region outline this becomes.
    private static func drawSweep(_ rect: CGRect, on cx: GraphicsContext) {
        // Every bare-canvas mouse-down opens a sweep and ends it again with a
        // 0×0 rect — `applyMouseDown` fires `onDrag(.began)` on every press — so
        // a degenerate rect arrives here on every click the writer makes. What a
        // zero-area rounded rect inks under a miter join is not a question worth
        // leaving open when one line closes it.
        guard rect.width > 0 || rect.height > 0 else { return }
        cx.stroke(Path(roundedRect: rect, cornerRadius: CanvasMaterial.regionCornerRadius),
                  with: .color(Color(nsColor: sweepStroke)),
                  style: StrokeStyle(lineWidth: CanvasMaterial.sweepLineWidth,
                                     dash: CanvasMaterial.sweepDash))
    }

    /// The wash, the outline, the chrome bar and its label, and the resize mark.
    ///
    /// Takes the context BY VALUE for the same reason `drawCard` does — nothing
    /// a region does may leak into the next thing drawn.
    ///
    /// **Since 1C-c3 a region leans, and ONLY its drawing does** (spec §8A.2
    /// constraint 1). `seededRotation(for: region)` gives the writer's regions the
    /// same put-down-by-hand lean the cards have and leaves Claude's at exactly
    /// 0°, so the provenance signal covers the primitive Claude creates on every
    /// call. The transform goes on a COPY of the context and covers the wash, the
    /// chrome bar, the label, the promoted stripe and the resize mark — everything
    /// drawn inside the rect, so the interior stays coherent.
    ///
    /// **The GRAB is unrotated and stays that way.** `CanvasInteraction` and
    /// `CanvasScene.hitTest` test `CanvasRegionMetrics`' plain rects, unchanged.
    /// The cost is stated rather than hidden: on a large region the ink and the
    /// target diverge by up to `rotationOverhang(of:)` at the corners — a few
    /// points, more than a card's because a region is bigger — and that is
    /// accepted, because rotating the hit test would put a second geometry in the
    /// file and grow the r·θ band `maximumTiltDegrees` has a ceiling to bound.
    /// The chrome bar is 24 pt tall against a corner error of ~6 pt on a
    /// 500 × 500 region (`r·θ`, r = 353.6 pt, θ = `maximumTiltDegrees`), so the
    /// bar a writer aims at is still under the bar they see — against a card's
    /// 2.2 pt at 240 × 80. **A TETHER is not rotated either** — one end of it is on a card
    /// outside the region, so there is no one transform it belongs in; its region
    /// end sits up to the same few points off the tilted edge.
    ///
    /// The chrome geometry comes from `CanvasRegionMetrics`, never spelled again
    /// here: Task 5 hit-tests the same rects, and a second spelling puts the mark
    /// and the target on different geometry.
    private static func drawRegion(_ region: CanvasRegion,
                                   in scene: CanvasScene,
                                   isSelected: Bool,
                                   isDimmed: Bool,
                                   boundElsewhere: String?,
                                   on context: GraphicsContext) {
        var cx = context
        // ONE definition of the rotation, shared with the card — about the rect's
        // own centre, inside the camera CTM already on the context.
        cx.transform = cardTransform(inCard: region.frame,
                                     angle: seededRotation(for: region))
            .concatenating(cx.transform)

        let shape = Path(roundedRect: region.frame,
                         cornerRadius: CanvasMaterial.regionCornerRadius)
        let wash = regionWash(dimmed: isDimmed)
        cx.fill(shape, with: .color(Color(nsColor: wash)))

        // The chrome bar is the only part of a region a writer can grab, so it
        // is the only part that is drawn as a surface rather than as an area —
        // a second coat of the same wash, not a different colour.
        let chrome = CanvasRegionMetrics.chromeRect(in: region.frame)
        cx.drawLayer { bar in
            bar.clip(to: shape)
            bar.fill(Path(chrome), with: .color(Color(nsColor: wash)))

            // The promoted stripe, on the chrome bar because that is the only
            // part of a region reliably on screen when it is collapsed. It is
            // PERMANENT chrome for the reason the card's is — a durable fact
            // about the region, not a passing one about the selection.
            //
            // Drawn inside the BAR's layer rather than in one of its own, so it
            // takes the same `clip(to: shape)`: `chromeRect` is a square rect
            // and the region is a rounded one, so an unclipped 3 pt stripe at
            // the top-left squares off the corner the wash just rounded. Same
            // reason `promotedMarkRect(inCard:)`'s own doc comment gives for the
            // card's clip, and one clip rather than two composites per region.
            if region.promotedItemID != nil {
                bar.fill(Path(promotedMarkRect(inRegionChrome: region.frame)),
                         with: .color(Color(nsColor: cardInk)
                                          .opacity(alpha(CanvasMaterial.promotedMarkOpacity,
                                                         dimmed: isDimmed))))
            }
        }

        // The SELECTED stroke is never dimmed — see `draw`: a de-emphasis that
        // hides the selection is a de-emphasis the writer cannot work through.
        cx.stroke(shape,
                  with: .color(Color(nsColor: isSelected
                                     ? CanvasMaterial.regionSelectedStroke
                                     : regionStroke(dimmed: isDimmed))),
                  lineWidth: isSelected ? 2 : 1)

        let labelFont = Font.system(size: 11, weight: .medium)
        let runFont = Font.system(size: 11)
        var label = cx.resolve(Text(region.displayLabel).font(labelFont))
        label.shading = .color(textInk(.secondaryLabelColor, dimmed: isDimmed))
        let labelOrigin = CanvasRegionMetrics.labelOrigin(in: region.frame)

        // **The ordinary region — nothing borrowed, not collapsed — draws its
        // label on exactly the path it always took**: one draw, no measure, no
        // elision, and no behaviour changed for a board that is not filtered.
        // Everything below is for a bar carrying MORE than one run.
        if boundElsewhere == nil && !region.isCollapsed {
            cx.draw(label, at: labelOrigin, anchor: .topLeading)
        } else {
            // Measuring one candidate string. Only ever called for a bar with two
            // or three runs on it, and inside `elide` only while a run overflows.
            func width(_ string: String, _ font: Font) -> CGFloat {
                cx.resolve(Text(string).font(font)).measure(in: chrome.size).width
            }

            // §4.2's borrowed name, resolved before the label is placed because it
            // is what decides how much of the bar the label gets. **Drawn in the
            // label's own ink and never a step fainter**: it is the one thing on a
            // dimmed region that has to be READ, and `CanvasHighlightRenderTests`
            // exists because the two quietest dosages on this surface are one
            // product away from nothing.
            //
            // The name is elided against the WHOLE bar, and the label against
            // what is left — which is the yield, and `regionLabelWidthBudget` is
            // the arithmetic.
            let bar = region.frame.width - 2 * CanvasRegionMetrics.labelInset
            let borrowed = boundElsewhere.map {
                elide("\(borrowedNameSeparator)\($0)", to: bar) { width($0, runFont) }
            }
            let borrowedWidth = borrowed.map { width($0, runFont) } ?? 0
            let budget = regionLabelWidthBudget(in: region.frame,
                                                borrowedWidth: borrowedWidth)

            var labelWidth = width(region.displayLabel, labelFont)
            if labelWidth > budget {
                let short = elide(region.displayLabel, to: budget) { width($0, labelFont) }
                label = cx.resolve(Text(short).font(labelFont))
                label.shading = .color(textInk(.secondaryLabelColor, dimmed: isDimmed))
                labelWidth = width(short, labelFont)
            }
            cx.draw(label, at: labelOrigin, anchor: .topLeading)

            var x = labelOrigin.x + labelWidth
            if let borrowed {
                x += CanvasRegionMetrics.labelInset
                var text = cx.resolve(Text(borrowed).font(runFont))
                text.shading = .color(textInk(.secondaryLabelColor, dimmed: isDimmed))
                cx.draw(text, at: CGPoint(x: x, y: labelOrigin.y), anchor: .topLeading)
                x += borrowedWidth
            }

            if region.isCollapsed {
                // A collapsed region's interior is empty by design, so the count
                // goes BESIDE the label rather than in the middle of nothing.
                var summary = cx.resolve(Text(collapsedSummary(for: region.id, in: scene))
                    .font(runFont))
                summary.shading = .color(textInk(.tertiaryLabelColor, dimmed: isDimmed))
                cx.draw(summary,
                        at: CGPoint(x: x + CanvasRegionMetrics.labelInset, y: labelOrigin.y),
                        anchor: .topLeading)
            }
        }

        cx.fill(regionResizeHandle(in: region.frame),
                with: .color(Color(nsColor: regionStroke(dimmed: isDimmed))))
    }

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
    private static func drawTether(_ tether: Tether, isDimmed: Bool, on cx: GraphicsContext) {
        var path = Path()
        path.move(to: tether.from)
        path.addLine(to: tether.to)
        // The dim replaces `tetherOpacity` for the reason the comment above
        // gives for `tetherOpacity` replacing the stroke's own alpha: this is
        // the faintest line on the canvas, and it is one product away from
        // nothing at all.
        cx.stroke(path,
                  with: .color(Color(nsColor: regionStroke.withAlphaComponent(
                      alpha(CanvasMaterial.tetherOpacity, dimmed: isDimmed)))),
                  style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    /// §4.3's reference: a small chip carrying the title, with a hairline to the
    /// real card. Smaller than the thing it stands for, and drawn on the card's
    /// own paper at `chipOpacity` so it reads as lighter than a card without
    /// reading as a different material.
    ///
    /// **A chip carries NEITHER provenance signal, and that is a decision rather
    /// than an omission** (spec §8A.2; reviewed 2026-07-30).
    ///
    /// - *No tint.* A chip is a reference, not the card. It is already the one
    ///   thing on this surface deliberately drawn as "same paper, less of it", so
    ///   that "which of these live here and which are visiting" is answerable at
    ///   a glance without reading a word — a second material distinction stacked
    ///   on that is two questions in one mark. The card itself IS tinted, where
    ///   it lives, which is where the writer goes to read it.
    /// - *No lean.* A chip is drawn in the host region's interior but its
    ///   hairline ends on a card OUTSIDE that region, so there is no single
    ///   transform it belongs in — the tether's problem exactly, and `drawRegion`
    ///   declines to rotate a tether for the same reason. The consequence is
    ///   honest and small: on a large tilted region a chip sits a few points off
    ///   the tilted inside edge it hugs. Rotating the pill and not the hairline
    ///   would trade a visible misalignment for an invisible one and add a second
    ///   geometry to keep in step.
    private static func drawChip(_ chip: AppearanceChip,
                                 title: String,
                                 isDimmed: Bool,
                                 on cx: GraphicsContext) {
        var hairline = Path()
        hairline.move(to: CGPoint(x: chip.frame.midX, y: chip.frame.midY))
        hairline.addLine(to: chip.homeAnchor)
        cx.stroke(hairline,
                  with: .color(Color(nsColor: regionStroke.withAlphaComponent(
                      alpha(CanvasMaterial.tetherOpacity, dimmed: isDimmed)))),
                  style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

        let shape = Path(roundedRect: chip.frame, cornerRadius: chipHeight / 2)
        // 0.75 REPLACED and not scaled: a chip is already "same paper, less of
        // it", and the two dosages multiplied would put a dimmed chip below the
        // dimmed card it stands for.
        cx.fill(shape, with: .color(Color(nsColor: cardPaper)
            .opacity(alpha(CanvasMaterial.chipOpacity, dimmed: isDimmed))))
        cx.stroke(shape, with: .color(Color(nsColor: regionStroke(dimmed: isDimmed))),
                  lineWidth: 0.5)

        var text = cx.resolve(Text(title).font(.system(size: 10)))
        text.shading = .color(textInk(.secondaryLabelColor, dimmed: isDimmed))
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
                                 item: CanvasItemPresentation.Item?,
                                 angle: Angle,
                                 isSelected: Bool,
                                 isDimmed: Bool,
                                 on cx: GraphicsContext) {
        let shape = Path(roundedRect: frame, cornerRadius: 3)
        // Resolved once — see `paper(for:)`. The caster below and the fill under
        // it must be the same colour or every card carries a fringe of the other.
        let paper = paper(for: node)

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
        // §4's dim, applied by REPLACING the paper's alpha rather than scaling
        // anything — every card's paper is opaque, so the dimmed card is drawn
        // at exactly `dimmedOpacity` whether it is the writer's paper or
        // Claude's cooler one, and the two stay distinguishable at the dim.
        let paperAlpha = alpha(1, dimmed: isDimmed)
        card.drawLayer { shadow in
            // The drop scales with the card: a full-strength shadow under a
            // ghosted card is a hole with nothing over it.
            shadow.addFilter(.shadow(color: .black.opacity(alpha(0.18, dimmed: isDimmed)),
                                     radius: 3, x: 1, y: 2))
            shadow.fill(shape, with: .color(Color(nsColor: paper).opacity(paperAlpha)))
        }
        card.fill(shape, with: .color(Color(nsColor: paper).opacity(paperAlpha)))

        // ONE border for both kinds since 1C-d, and the dashes are gone with the
        // placeholder they belonged to. An item node drew a dashed 1 pt stroke to
        // say "unfinished" while the only thing on it was a reference id; it now
        // shows a title, a kind glyph and — when there is one — the picture
        // itself, so what it is is legible from its content and a border saying
        // "not really a card" would contradict it. Spec §8A.2's reproduction
        // corollary is the reason this had to become a real card: a photographed
        // page and the scraps read off it have to be comparable **by looking**.
        // **Not dimmed, and that is the `min` rule's answer rather than an
        // omission** (`CanvasMaterial.dimmedAlpha`): `separatorColor` resolves
        // to alpha 0.098 in both appearances, already less than half the dim, so
        // a dimmed thing drawn in it is left where it is. The card's paper is
        // what recedes; its outline was never loud enough to.
        card.stroke(shape, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)

        // Drawn OVER the kind's own border rather than replacing it.
        //
        // The three marks below sit adjacent and two of them mean the OPPOSITE
        // of the third, so read the conditions and not the order.
        //
        // 1. The CONNECT DOT is SELECTION chrome — inside this block, gone the
        //    moment the card is deselected — because it is the discoverable half
        //    of a gesture whose fast route (⇧-drag) has no chrome at all, and a
        //    second always-on mark would overstate what §5 calls a thing that
        //    "costs nothing to draw and nothing to be wrong about".
        // 2. The PROMOTED STRIPE below is UNCONDITIONAL: it states a durable
        //    fact about the card — this one produced something — rather than a
        //    passing one about the selection.
        // 3. The RESIZE TRIANGLE below that is this surface's established
        //    permanent card chrome — unconditional on the selection AND on the
        //    kind. **The mark and the target are ONE decision**:
        //    `CanvasInteraction.begin` takes the corner of every card, and these
        //    two move together or the surface draws an affordance that does
        //    nothing — or resizes with nothing on it to say so.
        //
        //    It was a `.scrap`'s alone between 1C-c3 and 1C-d, and that was a fix
        //    for a missing measurement rather than a ruling: nothing re-measured
        //    an item node while `CanvasScene.setWidth` cleared `cachedHeight` by
        //    design, so a resize left the card with no frame — not drawn, not
        //    clickable, persisted that way. 1C-d measures an item card from its
        //    picture's aspect ratio, per frame, so the uniform rule is back and
        //    the stripe above is now the only kind-conditional mark here.
        //
        // Moving any of the three across the SELECTION line is a design change,
        // not a tidy-up. So is moving the triangle back across the KIND line —
        // it is the same decision as the corner test in `CanvasInteraction`.
        //
        // All three are drawn inside the card's rotated transform, like
        // everything else here, so they tilt with the card and straighten with
        // it — a mark that stayed level while its card leaned would read as
        // chrome belonging to the canvas rather than to the card.
        if isSelected {
            card.stroke(shape, with: .color(Color(nsColor: CanvasMaterial.regionSelectedStroke)),
                        lineWidth: 2)
            let mark = connectMarkRect(inCard: frame)
            if !mark.isEmpty {
                card.fill(Path(ellipseIn: mark),
                          with: .color(Color(nsColor: CanvasMaterial.regionSelectedStroke)))
            }
        }

        // PERMANENT chrome, like the resize triangle below and unlike the connect
        // dot above — it states a durable fact about the card rather than a
        // passing one about the selection.
        //
        // **A REFERENCED item node never gets one, an owned one does** (1C-d
        // Task 8). The refusal's reason was "it already exists as itself, so a
        // mark on one is meaningless", which is exactly true of a reference and
        // stopped being true of an owned picture the moment it could produce a
        // research asset — a hand-edited sidecar can still put the field on a
        // reference, and that is what this refuses. A picture appended to a
        // palette card gets no stripe either, and by the same standing rule: that
        // is a *contribution*, and a second identical stripe for "this went into
        // that" would say on the canvas the thing §6.3 spends its length
        // separating.
        if node.promotedItemID != nil, node.kind.carriesAMark {
            card.drawLayer { inner in
                inner.clip(to: shape)
                inner.fill(Path(promotedMarkRect(inCard: frame)),
                           with: .color(Color(nsColor: cardInk)
                                            .opacity(alpha(CanvasMaterial.promotedMarkOpacity,
                                                           dimmed: isDimmed))))
            }
        }

        // PERMANENT chrome like the stripe above — and, UNLIKE it, on every kind.
        // See mark 3 in the block above: this and `CanvasInteraction.begin`'s
        // corner test are one decision, so a kind test here needs one there.
        card.fill(resizeHandle(in: frame),
                  with: .color(Color(nsColor: .separatorColor)
                      .opacity(alpha(0.8, dimmed: isDimmed))))

        switch node.kind {
        case .scrap:
            // nil = this scrap's editor is mounted and IS its visible text.
            guard let layout else { return }
            let origin = CanvasCardMetrics.textOrigin(inCard: frame)
            card.drawLayer { inner in
                inner.clip(to: shape)
                inner.withCGContext { cg in
                    // The words are drawn by TextKit straight into this CG
                    // context (`ScrapLayout.draw`), so the alpha is set on the
                    // thing that actually strokes the glyphs. The ink is
                    // `cardInk` at full strength, so this is a replacement like
                    // every other dim on this surface and not a product.
                    //
                    // **`inner.opacity = …` on the enclosing layer works too —
                    // measured, not assumed** (2026-08-03: planted as the
                    // counterfactual and `test_aDimmedCardsWordsDimWithIt` stayed
                    // green, so the plant is recorded here rather than as a
                    // warning that would have been false). This spelling is kept
                    // because it names the context the glyphs are actually drawn
                    // into; the two are interchangeable at this call site and
                    // neither is a trap.
                    cg.saveGState()
                    cg.setAlpha(alpha(1, dimmed: isDimmed))
                    cg.translateBy(x: origin.x, y: origin.y)
                    layout.draw(into: cg, at: .zero)
                    cg.restoreGState()
                }
            }
        case .item:
            drawItemContent(item, inCard: frame, clippedTo: shape,
                            isDimmed: isDimmed, on: card)
        }
    }

    /// What an item node shows: the picture at the top when one has arrived, and
    /// under it a line of kind glyph and title (spec §8A.1).
    ///
    /// **A nil `item` draws the card and nothing on it, and that is a real state
    /// rather than a guard.** `CanvasThumbnails.resolved` never decodes, so the
    /// pass that first asks for a photograph always misses it; the card is drawn,
    /// measured to `CanvasCardMetrics.itemLabelOnlyHeight` and clickable through
    /// that window, and the picture arrives when `servicePending()` has run. A
    /// fallback label reading the reference id would be the placeholder coming
    /// back through the error path.
    ///
    /// **Everything is laid out from `CanvasCardMetrics`**, which is also what
    /// `CanvasView.rebuildLayouts` measured the card with — so the picture's rect
    /// and the card's height are two readings of one arithmetic rather than two
    /// arithmetics that happen to agree (`Maugham/Canvas/AREA.md`, "Card metrics
    /// live in `CanvasCardMetrics`, and nowhere else").
    ///
    /// The label takes `secondaryLabelColor` rather than the card's own ink,
    /// because it is a caption for a thing that exists elsewhere and not the
    /// writer's words — the same reading `drawChip` takes of the same question.
    private static func drawItemContent(_ item: CanvasItemPresentation.Item?,
                                        inCard frame: CGRect,
                                        clippedTo shape: Path,
                                        isDimmed: Bool,
                                        on card: GraphicsContext) {
        guard let item else { return }

        if let picture = item.picture, let aspect = item.pictureAspect {
            let rect = CanvasCardMetrics.itemPictureRect(inCard: frame, aspect: aspect)
            card.drawLayer { inner in
                // Clipped to the CARD, so a card being drawn at the floor height
                // while its picture decodes never leaks pixels onto the ground.
                inner.clip(to: shape)
                // The one place on this surface a LAYER's opacity is the right
                // instrument: a photograph carries no dosage of its own to
                // replace, so setting the layer to the dim is a replacement in
                // the only sense available to a bitmap.
                inner.opacity = alpha(1, dimmed: isDimmed)
                inner.draw(Image(decorative: picture, scale: 1), in: rect)
            }
        }

        // Resolved for its natural SIZE, then fitted: an SF Symbol is not square,
        // and drawing one into a square box stretches every glyph that is not.
        var glyphContext = card
        glyphContext.opacity = alpha(1, dimmed: isDimmed)
        let glyph = glyphContext.resolve(Image(systemName: item.facts.glyph))
        glyphContext.draw(glyph,
                          in: CanvasCardMetrics.fit(
                            glyph.size,
                            in: CanvasCardMetrics.itemGlyphBox(inCard: frame)))

        var title = card.resolve(
            Text(item.facts.title).font(.system(size: CanvasCardMetrics.itemLabelFontSize)))
        title.shading = .color(textInk(.secondaryLabelColor, dimmed: isDimmed))
        card.drawLayer { inner in
            // A title longer than the card is truncated by the card's own edge
            // rather than running onto the ground beside it.
            inner.clip(to: shape)
            inner.draw(title, at: CanvasCardMetrics.itemTitleOrigin(inCard: frame),
                       anchor: .topLeading)
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
