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
    @discardableResult
    mutating func step(elapsed: TimeInterval) -> Bool {
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
    /// Measured under both appearances on 2026-07-26: `textBackgroundColor` is
    /// 1.00 / 0.12 brightness and `labelColor` is 0.00 / 1.00, so the contrast
    /// survives the switch in both directions.
    ///
    /// **Task 9 and Task 10 must construct every `ScrapLayout` with
    /// `textColor: CanvasRenderer.cardInk`.** Taking `ScrapLayout`'s default
    /// happens to give the same colour today, but naming it here is what keeps
    /// the two ends of the pairing findable from one another — and what
    /// `test_theCardsInkContrastsWithItsPaperInBothAppearances` reads.
    static let cardPaper: NSColor = .textBackgroundColor
    static let cardInk: NSColor = .labelColor

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

        // Map to ±0.6°, comfortably a fraction of a degree.
        let unit = Double(z % 10_000) / 10_000.0        // 0..<1
        return .degrees((unit * 2 - 1) * 0.6)
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
        scene.nodes(intersecting: camera.visibleContentRect(viewSize: viewSize))
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
    static func draw(scene: CanvasScene,
                     camera: CanvasCamera,
                     viewSize: CGSize,
                     layouts: [CanvasNodeID: ScrapLayout],
                     visibleEditorNodeID: CanvasNodeID?,
                     straighten: CanvasFocusStraighten,
                     into cx: inout GraphicsContext) {
        cx.translateBy(x: camera.pan.x, y: camera.pan.y)
        cx.scaleBy(x: camera.zoom, y: camera.zoom)

        for node in visibleNodes(in: scene, camera: camera, viewSize: viewSize) {
            guard let frame = node.frame else { continue }
            let ownText = drawsOwnText(node.id, visibleEditorNodeID: visibleEditorNodeID)
            drawCard(node, frame: frame,
                     layout: ownText ? layouts[node.id] : nil,
                     angle: drawnAngle(for: node.id, straighten: straighten),
                     into: cx)
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
    /// Takes the context BY VALUE. Every card starts from the camera CTM `draw`
    /// set and adds its own rotation to a copy; nothing a card does may leak into
    /// the next one, and `draw` never reads the context back.
    private static func drawCard(_ node: CanvasNode,
                                 frame: CGRect,
                                 layout: ScrapLayout?,
                                 angle: Angle,
                                 into cx: GraphicsContext) {
        let shape = Path(roundedRect: frame, cornerRadius: 3)

        var card = cx
        // ONE definition of the card rotation — the same transform `localPoint`
        // inverts. `concatenating` applies it in the card's space, INSIDE the
        // camera CTM already on the context.
        card.transform = cardTransform(inCard: frame, angle: angle)
            .concatenating(card.transform)

        // Light falls from one corner (§7.1) — a single soft drop, not a glow.
        card.drawLayer { shadow in
            shadow.addFilter(.shadow(color: .black.opacity(0.18), radius: 3, x: 1, y: 2))
            shadow.fill(shape, with: .color(.white))
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
