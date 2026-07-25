import XCTest
import SwiftUI
import AppKit
@testable import Maugham

final class CanvasRendererTests: XCTestCase {

    func test_seededRotation_isStableForTheSameID() {
        let a = CanvasRenderer.seededRotation(for: CanvasNodeID("s1"))
        let b = CanvasRenderer.seededRotation(for: CanvasNodeID("s1"))
        XCTAssertEqual(a.degrees, b.degrees, accuracy: 1e-12,
                       "a card that shimmers between renders is the failure §7.2 forbids")
    }

    func test_seededRotation_differsAcrossIDs() {
        let angles = (0..<40).map { CanvasRenderer.seededRotation(for: CanvasNodeID("s\($0)")).degrees }
        XCTAssertGreaterThan(Set(angles.map { Int($0 * 1_000_000) }).count, 30,
                             "rotation must actually vary, or nothing was put down by hand")
    }

    func test_seededRotation_staysUnderOneDegree() {
        for i in 0..<400 {
            let d = CanvasRenderer.seededRotation(for: CanvasNodeID("node-\(i)")).degrees
            XCTAssertLessThan(abs(d), 1.0, "§7.2 says a seeded FRACTION of a degree")
        }
    }

    // MARK: - §7A.5, focus straightens the card

    func test_anUnfocusedCardIsDrawnAtItsFullSeededAngle() {
        let straighten = CanvasFocusStraighten()
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: CanvasNodeID("s1"), straighten: straighten).degrees,
                       CanvasRenderer.seededRotation(for: CanvasNodeID("s1")).degrees,
                       accuracy: 1e-12)
    }

    func test_theFocusedCardEndsUpExactlyLevel() {
        var straighten = CanvasFocusStraighten()
        straighten.focus(CanvasNodeID("s1"))
        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: CanvasNodeID("s1"), straighten: straighten).degrees,
                       0, accuracy: 1e-12,
                       "the editor mounts on this card — anything but level and the "
                       + "glyph-origin pin is comparing a rotated layout to a flat one")
    }

    /// §7A.5 requirement 2: an instant jump reads as a rendering bug.
    func test_straighteningIsAnimatedRatherThanSnapped() {
        var straighten = CanvasFocusStraighten()
        straighten.focus(CanvasNodeID("s1"))
        XCTAssertTrue(straighten.step(elapsed: 1.0 / 60), "still animating after one frame")
        let p = straighten.progress(for: CanvasNodeID("s1"))
        XCTAssertGreaterThan(p, 0)
        XCTAssertLessThan(p, 1, "one frame must not complete the straighten")
    }

    func test_straighteningTakesAboutTheSpecifiedTime() {
        var straighten = CanvasFocusStraighten()
        straighten.focus(CanvasNodeID("s1"))
        var elapsed: TimeInterval = 0
        while straighten.step(elapsed: 1.0 / 60) { elapsed += 1.0 / 60 }
        XCTAssertEqual(elapsed, CanvasFocusStraighten.secondsToLevel, accuracy: 1.0 / 30,
                       "~120ms reads as the card responding; much longer reads as lag")
    }

    /// `isSettled` gates the `TimelineView`'s clock, so it must mean "every card
    /// is at ITS target", not "every progress value is 1". A completed focus
    /// leaves the entry at 1; blur clears `focusedNodeID` and that entry's target
    /// becomes 0 — but an `allSatisfy { $0.value >= 1 }` reads it as settled, the
    /// clock pauses on the spot, `step` is never called again, and the card stays
    /// level forever. Click in, click out onto empty canvas — the commonest path
    /// there is — and "the card being edited is the only square one on the canvas"
    /// is simply false.
    func test_blurSettlesTheCardBackToItsSeededAngle() {
        var straighten = CanvasFocusStraighten()
        straighten.focus(CanvasNodeID("s1"))
        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertTrue(straighten.isSettled, "a completed focus must pause the clock")

        straighten.focus(nil)
        XCTAssertFalse(straighten.isSettled, "blur must animate back, not snap back")
        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: CanvasNodeID("s1"), straighten: straighten).degrees,
                       CanvasRenderer.seededRotation(for: CanvasNodeID("s1")).degrees,
                       accuracy: 1e-12)
        XCTAssertTrue(straighten.isSettled, "a settled canvas must pause its clock")
    }

    /// The gate Task 10 REVEALS the editor behind. The editor is mounted and
    /// taking keystrokes well before this; `isLevel` is when it becomes the
    /// VISIBLE text and the renderer stops drawing that card's own. §7A.5
    /// requirement 1 orders it: caret, then animate, then hand the text over.
    /// Showing the editor at progress 0 puts axis-aligned glyphs on a card that
    /// is still up to 0.6° off level, at the unrotated text origin, with the
    /// drawn text already suppressed — the glyphs jump straight the instant the
    /// writer clicks and the card catches up afterwards, which is precisely the
    /// §7A.2 failure.
    func test_aCardIsNotLevelUntilTheStraightenCompletes() {
        var straighten = CanvasFocusStraighten()
        let id = CanvasNodeID("s1")
        XCTAssertFalse(straighten.isLevel(id), "an untouched card is at its seeded angle")

        straighten.focus(id)
        XCTAssertFalse(straighten.isLevel(id), "the animation has not started yet")
        straighten.step(elapsed: 1.0 / 60)
        XCTAssertFalse(straighten.isLevel(id), "one frame in, the card is still tilted")

        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertTrue(straighten.isLevel(id))
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: id, straighten: straighten).degrees,
                       0, accuracy: 1e-12,
                       "isLevel must not be able to be true while the card is tilted")
    }

    func test_blurStopsTheCardBeingLevelImmediately() {
        var straighten = CanvasFocusStraighten()
        let id = CanvasNodeID("s1")
        straighten.focus(id)
        while straighten.step(elapsed: 1.0 / 60) { }
        straighten.focus(nil)
        XCTAssertFalse(straighten.isLevel(id),
                       "focus has left, so the editor must not still be the "
                       + "visible text on a card that is on its way back to its angle")
    }

    func test_onlyTheFocusedCardIsEverLevel() {
        var straighten = CanvasFocusStraighten()
        straighten.focus(CanvasNodeID("s1"))
        while straighten.step(elapsed: 1.0 / 60) { }
        straighten.focus(CanvasNodeID("s2"))
        XCTAssertFalse(straighten.isLevel(CanvasNodeID("s1")),
                       "s1 is settling back and must not report level")
        XCTAssertFalse(straighten.isLevel(CanvasNodeID("s2")), "s2 has only just started")
        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertTrue(straighten.isLevel(CanvasNodeID("s2")))
        XCTAssertFalse(straighten.isLevel(CanvasNodeID("s1")))
    }

    // MARK: - The handover from drawn text to editor

    /// The half of the swap the renderer owns. While the card is straightening
    /// its editor is mounted but invisible, so the words on screen are the ones
    /// this pass draws — and they are drawn from the shared `NSTextStorage` the
    /// editor is mutating, so they update as the writer types. The renderer
    /// stops only when the editor becomes visible, at `isLevel`.
    ///
    /// Both halves flip on the same value — `CanvasView.visibleEditorNodeID` —
    /// so there is never a frame with both drawing and never a frame with
    /// neither. A card blank for a tenth of a second and then full of straight
    /// glyphs is the §7A.2 jump.
    func test_theCardKeepsDrawingItsOwnTextUntilTheEditorIsVisible() {
        var straighten = CanvasFocusStraighten()
        let id = CanvasNodeID("s1")
        straighten.focus(id)
        straighten.step(elapsed: 1.0 / 60)

        // Mid-straighten: nothing is visible-editing, so the card draws its own.
        XCTAssertFalse(straighten.isLevel(id))
        XCTAssertTrue(CanvasRenderer.drawsOwnText(id, visibleEditorNodeID: nil),
                      "the card stopped drawing its text while the editor was "
                      + "still invisible — the words vanish for ~120ms")

        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertTrue(straighten.isLevel(id))
        XCTAssertFalse(CanvasRenderer.drawsOwnText(id, visibleEditorNodeID: id),
                       "the editor is the visible text now; drawing it again "
                       + "double-draws every glyph (spec §7A.2, the Excalidraw rule)")
    }

    /// Click from scrap A straight to scrap B while A is still settling back and
    /// both `isLevel` values are false — so NEITHER is suppressed. At most one
    /// node is ever suppressed, because the suppression is keyed on a single
    /// optional rather than on a per-node predicate.
    func test_atMostOneNodeEverStopsDrawingItsOwnText() {
        let a = CanvasNodeID("s1")
        let b = CanvasNodeID("s2")
        var straighten = CanvasFocusStraighten()
        straighten.focus(a)
        while straighten.step(elapsed: 1.0 / 60) { }
        straighten.focus(b)
        straighten.step(elapsed: 1.0 / 60)

        XCTAssertFalse(straighten.isLevel(a))
        XCTAssertFalse(straighten.isLevel(b))
        XCTAssertTrue(CanvasRenderer.drawsOwnText(a, visibleEditorNodeID: nil),
                      "A is settling back with no editor on it — it must draw "
                      + "its own text again the frame focus leaves")
        XCTAssertTrue(CanvasRenderer.drawsOwnText(b, visibleEditorNodeID: nil))

        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertTrue(CanvasRenderer.drawsOwnText(a, visibleEditorNodeID: b))
        XCTAssertFalse(CanvasRenderer.drawsOwnText(b, visibleEditorNodeID: b))
    }

    /// The sign of the card rotation, pinned against literal trigonometry.
    ///
    /// A round-trip test cannot catch a flipped convention: if `cardTransform`
    /// and `localPoint` both flipped, the round trip would still close, and the
    /// caret error at a card corner would silently double instead of vanishing.
    /// This asserts the transform's actual matrix, at an exaggerated angle where
    /// a flip is unmissable.
    func test_cardTransformRotatesInTheDirectionTheRendererDraws() {
        let frame = CGRect(x: 100, y: 100, width: 240, height: 80)
        let angle = Angle.degrees(30)
        let t = CanvasRenderer.cardTransform(inCard: frame, angle: angle)
        XCTAssertEqual(t.a, cos(angle.radians), accuracy: 1e-9)
        XCTAssertEqual(t.b, sin(angle.radians), accuracy: 1e-9)
        XCTAssertEqual(t.c, -sin(angle.radians), accuracy: 1e-9)
        XCTAssertEqual(t.d, cos(angle.radians), accuracy: 1e-9)

        XCTAssertEqual(CGPoint(x: frame.midX, y: frame.midY).applying(t).x,
                       frame.midX, accuracy: 1e-9, "the centre is the fixed point")
        XCTAssertEqual(CGPoint(x: frame.midX, y: frame.midY).applying(t).y,
                       frame.midY, accuracy: 1e-9)
        XCTAssertGreaterThan(CGPoint(x: frame.midX + 10, y: frame.midY).applying(t).y,
                             frame.midY,
                             "in the canvas's flipped, y-down space a positive "
                             + "angle carries the right-hand edge downward")
    }

    /// There must be exactly ONE definition of a card's rotation. A second one —
    /// `GraphicsContext.rotate(by:)` in the draw pass, say — is a convention the
    /// caret inverse has no way to check itself against.
    func test_noFileInTheCanvasAreaRotatesOutsideCardTransform() throws {
        var offenders: [String] = []
        for (name, i, trimmed, raw) in try Self.canvasSourceLines() {
            if trimmed.hasPrefix("//") { continue }     // doc comments may NAME it
            if raw.contains(".rotate(by:") || raw.contains("rotationEffect(") {
                offenders.append("\(name):\(i + 1): \(trimmed)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "a card's rotation has one definition — CanvasRenderer."
                      + "cardTransform — which localPoint inverts. A second "
                      + "rotation is a sign convention nothing checks: \(offenders)")
    }

    /// §7A.5 requirement 1: resolve the caret in the card's own unrotated space,
    /// at click time. Straightening first moves the click point out from under
    /// the cursor.
    func test_localPointInvertsTheCardsRotation() {
        let frame = CGRect(x: 100, y: 100, width: 240, height: 80)
        let angle = Angle.degrees(0.6)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(CanvasRenderer.localPoint(centre, inCard: frame, angle: angle).x,
                       centre.x, accuracy: 1e-9, "the centre is the fixed point")
        XCTAssertEqual(CanvasRenderer.localPoint(centre, inCard: frame, angle: angle).y,
                       centre.y, accuracy: 1e-9)

        // A corner of the drawn (rotated) card maps back onto the corner of the
        // unrotated one.
        let corner = CGPoint(x: frame.maxX, y: frame.maxY)
        let rotated = CGPoint(
            x: centre.x + (corner.x - centre.x) * cos(angle.radians) - (corner.y - centre.y) * sin(angle.radians),
            y: centre.y + (corner.x - centre.x) * sin(angle.radians) + (corner.y - centre.y) * cos(angle.radians))
        let back = CanvasRenderer.localPoint(rotated, inCard: frame, angle: angle)
        XCTAssertEqual(back.x, corner.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, corner.y, accuracy: 1e-6)

        // And it is the inverse of the transform the renderer actually applies,
        // not of a second hand-written one.
        let drawn = corner.applying(CanvasRenderer.cardTransform(inCard: frame, angle: angle))
        XCTAssertEqual(drawn.x, rotated.x, accuracy: 1e-9)
        XCTAssertEqual(drawn.y, rotated.y, accuracy: 1e-9)
    }

    func test_visibleNodes_cullsOffscreenNodes() {
        var scene = CanvasScene()
        for i in 0..<50 {
            var n = CanvasNode(id: CanvasNodeID("n\(i)"), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i) * 1000, y: 0), width: 240)
            n.cachedHeight = 100
            scene.insert(n)
        }
        let visible = CanvasRenderer.visibleNodes(in: scene, camera: CanvasCamera(),
                                                  viewSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.id, CanvasNodeID("n0"))
    }

    func test_visibleNodes_growsAsYouZoomOut() {
        var scene = CanvasScene()
        for i in 0..<50 {
            var n = CanvasNode(id: CanvasNodeID("n\(i)"), kind: .scrap,
                               origin: CGPoint(x: CGFloat(i) * 300, y: 0), width: 240)
            n.cachedHeight = 100
            scene.insert(n)
        }
        var wide = CanvasCamera(); wide.zoom = 0.15
        XCTAssertGreaterThan(
            CanvasRenderer.visibleNodes(in: scene, camera: wide,
                                        viewSize: CGSize(width: 800, height: 600)).count,
            CanvasRenderer.visibleNodes(in: scene, camera: CanvasCamera(),
                                        viewSize: CGSize(width: 800, height: 600)).count)
    }

    /// Asserted against the literal `[1, 3, 5]` rather than against `zs.sorted()`.
    /// A self-comparison here is green on the empty array, so a culling bug that
    /// dropped every node — the one failure this test sits next to — would pass
    /// it. The literal pins the count and the order together.
    func test_visibleNodes_returnsDrawOrderBackToFront() {
        var scene = CanvasScene()
        for (i, z) in [5, 1, 3].enumerated() {
            var n = CanvasNode(id: CanvasNodeID("n\(i)"), kind: .scrap,
                               origin: .zero, width: 240, z: z)
            n.cachedHeight = 100
            scene.insert(n)
        }
        let zs = CanvasRenderer.visibleNodes(in: scene, camera: CanvasCamera(),
                                             viewSize: CGSize(width: 800, height: 600)).map(\.z)
        XCTAssertEqual(zs, [1, 3, 5])
    }

    /// 1C-a draws item nodes as placeholders; 1C-d gives them titles and
    /// thumbnails (spec §8A.1). The label must name the reference so a writer
    /// looking at a canvas from a newer build can tell what is on it.
    func test_itemPlaceholderLabelNamesItsReference() {
        XCTAssertTrue(CanvasRenderer.placeholderLabel(forReference: "r-9").contains("r-9"))
    }

    /// Spike requirement 3: draw at the window's true backingScaleFactor ×
    /// camera zoom, and NEVER derive that scale. `GraphicsContext.withCGContext`
    /// already supplies exactly that product, so the correct implementation
    /// computes nothing — and this test says so out loud, because "helpfully"
    /// adding a scale is the shape of the bug.
    func test_noFileInTheCanvasAreaDerivesItsOwnRasterScale() throws {
        let forbidden = ["backingScaleFactor", "convertToBacking", "convertFromBacking",
                         "NSScreen.main?.backingScaleFactor", "pixelsWide", "pixelsHigh"]
        var offenders: [String] = []
        for (name, i, trimmed, raw) in try Self.canvasSourceLines() {
            // Doc comments may NAME the hazard; only code may not use it.
            if trimmed.hasPrefix("//") { continue }
            for pat in forbidden where raw.contains(pat) {
                offenders.append("\(name):\(i + 1): \(trimmed)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "the canvas must never derive a raster scale — withCGContext "
                      + "already supplies backingScaleFactor x camera zoom, and a "
                      + "hand-derived scale bakes in AppKit frame rounding and shifts "
                      + "glyphs by a subpixel (spike requirement 3): \(offenders)")
    }

    /// Both greps above walk `Maugham/Canvas/`. If that walk ever silently found
    /// nothing — a moved directory, a renamed area — every offender list would be
    /// empty and both tests would pass for the wrong reason.
    func test_theCanvasSourceWalkActuallyFindsTheCanvasFiles() throws {
        let names = Set(try Self.canvasSourceLines().map(\.0))
        XCTAssertTrue(names.contains("CanvasRenderer.swift"),
                      "the grep tripwires are scanning the wrong directory: \(names)")
        XCTAssertGreaterThan(names.count, 4)
    }

    /// (file name, 0-based line index, trimmed line, raw line) for every Swift
    /// line under `Maugham/Canvas/`.
    private static func canvasSourceLines() throws -> [(String, Int, String, String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MaughamTests/Canvas
            .deletingLastPathComponent()    // MaughamTests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("Maugham/Canvas", isDirectory: true)

        var out: [(String, Int, String, String)] = []
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        for case let url as URL in walker! where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                out.append((url.lastPathComponent, i,
                            line.trimmingCharacters(in: .whitespaces), String(line)))
            }
        }
        return out
    }

    // MARK: - What the draw pass actually puts on the page

    private static let sample = "The falls at night: sodium light on the spray, and "
        + "nobody there but the man selling ponchos. October says the doctor "
        + "was kind about it, which is not the same as being right."

    /// THE Y-FLIP PIN, and the only test in this file that runs the draw loop.
    ///
    /// `ScrapLayout.draw(into:at:)` requires a context in TOP-LEFT, y-downward
    /// text coordinates — its own bitmap test builds that by hand with
    /// `translateBy(0, h)` then `scaleBy(1, -1)`. `drawCard` applies no flip of
    /// its own, which is correct only because `GraphicsContext.withCGContext`
    /// hands back a context that is already y-down. The spike never measured
    /// that step: it drew into a bitmap it constructed itself.
    ///
    /// Measured on 2026-07-26: a `withCGContext` fill of `CGRect(0, 0, 100, 10)`
    /// inks the TOP ten rows of the rendered image, identical to a
    /// `GraphicsContext.fill` of the same rect. So no flip belongs here. If that
    /// ever changes, the fix belongs in `drawCard` and NOT in `ScrapLayout` —
    /// changing `ScrapLayout` would move the §7A.2 glyph-origin pin out from
    /// under the mounted editor it exists to compare against.
    ///
    /// The scrap is five-ish lines tall and its card sits 90 pt down the page, so
    /// a spurious flip is unmissable rather than marginal: the glyphs would run
    /// UPWARD from the text origin and most of them would land above the card
    /// entirely. Asserting "ink exists" would not catch that; this asserts where.
    @MainActor
    func test_theDrawnTextRunsDownwardFromTheTextOriginInsideItsCard() throws {
        let layout = ScrapLayout(
            text: Self.sample,
            width: CanvasCardMetrics.textWidth(forCardWidth: 240),
            font: NSFont(name: "Iowan Old Style", size: 13) ?? .systemFont(ofSize: 13),
            // Static ink and a light colour scheme below: this test is about
            // GEOMETRY, and the appearance pairing is pinned separately by
            // test_theCardsInkContrastsWithItsPaperInBothAppearances.
            textColor: .black)
        let textHeight = layout.measuredHeight
        XCTAssertGreaterThan(textHeight, 60, "the fixture must wrap to several lines")

        let cardOrigin = CGPoint(x: 40, y: 90)
        var node = CanvasNode(id: CanvasNodeID("s1"), kind: .scrap,
                              origin: cardOrigin, width: 240)
        node.cachedHeight = CanvasCardMetrics.cardHeight(forTextHeight: textHeight)
        var scene = CanvasScene()
        scene.insert(node)
        let frame = try XCTUnwrap(node.frame)

        let viewSize = CGSize(width: 360, height: 90 + frame.height + 90)
        let page = try Self.render(size: viewSize) { cx in
            CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: viewSize,
                                layouts: [node.id: layout], visibleEditorNodeID: nil,
                                straighten: CanvasFocusStraighten(), into: &cx)
        }

        // Sample a column band that is inside the text box and clear of the card
        // border stroke and of the resize handle in the bottom-right corner.
        let x0 = Int(frame.minX + CanvasCardMetrics.inset)
        let x1 = Int(frame.maxX - CanvasRenderer.resizeHandleSize - CanvasCardMetrics.inset)
        // Paper, sampled from the card itself rather than assumed, so "ink" means
        // "differs from this card's fill" under any appearance.
        let paper = page.value(x: Int(frame.midX), y: Int(frame.maxY - 3))
        let inkRows = (0..<Int(viewSize.height)).filter { y in
            (x0..<x1).contains { abs(Int(page.value(x: $0, y: y)) - Int(paper)) > 60 }
        }

        XCTAssertFalse(inkRows.isEmpty, "the draw pass put no text on the page at all")
        let firstRow = try XCTUnwrap(inkRows.first), lastRow = try XCTUnwrap(inkRows.last)

        let textTop = frame.minY + CanvasCardMetrics.inset
        XCTAssertGreaterThanOrEqual(CGFloat(firstRow), frame.minY,
                                    "glyphs landed ABOVE the card — the text is being "
                                    + "drawn upward from the text origin, i.e. drawCard "
                                    + "and ScrapLayout disagree about which way y runs")
        XCTAssertEqual(CGFloat(firstRow), textTop, accuracy: 8,
                       "the first inked row must be the top of the text box "
                       + "(CanvasCardMetrics.textOrigin), not somewhere else")
        XCTAssertLessThanOrEqual(CGFloat(lastRow), frame.maxY,
                                 "glyphs ran off the bottom of the card")
        XCTAssertGreaterThan(CGFloat(lastRow - firstRow), textHeight * 0.6,
                             "only part of the scrap was drawn")
    }

    /// The other half of the draw pass: `visibleEditorNodeID` suppresses that
    /// node's TEXT and nothing else. Its CARD must still be drawn — §7A.5 makes
    /// the focused card the only square one on the canvas, and there is nothing
    /// to be square if the card vanishes the moment it is clicked.
    @MainActor
    func test_theEditedNodeLosesItsTextButKeepsItsCard() throws {
        let layout = ScrapLayout(
            text: Self.sample,
            width: CanvasCardMetrics.textWidth(forCardWidth: 240),
            font: NSFont(name: "Iowan Old Style", size: 13) ?? .systemFont(ofSize: 13),
            textColor: .black)
        let id = CanvasNodeID("s1")
        var node = CanvasNode(id: id, kind: .scrap, origin: CGPoint(x: 40, y: 90), width: 240)
        node.cachedHeight = CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight)
        var scene = CanvasScene()
        scene.insert(node)
        let frame = try XCTUnwrap(node.frame)
        let viewSize = CGSize(width: 360, height: 90 + frame.height + 90)

        func inkCount(visibleEditor: CanvasNodeID?) throws -> Int {
            let page = try Self.render(size: viewSize) { cx in
                CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: viewSize,
                                    layouts: [id: layout], visibleEditorNodeID: visibleEditor,
                                    straighten: CanvasFocusStraighten(), into: &cx)
            }
            let paper = page.value(x: Int(frame.midX), y: Int(frame.maxY - 3))
            let x0 = Int(frame.minX + CanvasCardMetrics.inset)
            let x1 = Int(frame.maxX - CanvasRenderer.resizeHandleSize - CanvasCardMetrics.inset)
            var n = 0
            for y in Int(frame.minY)..<Int(frame.maxY) {
                for x in x0..<x1 where abs(Int(page.value(x: x, y: y)) - Int(paper)) > 60 {
                    n += 1
                }
            }
            return n
        }

        XCTAssertGreaterThan(try inkCount(visibleEditor: nil), 300)
        XCTAssertEqual(try inkCount(visibleEditor: id), 0,
                       "the editor is the visible text now — drawing the scrap's own "
                       + "text as well double-draws every glyph (§7A.2)")

        // …and the card itself survives. Asserted DIFFERENTIALLY, against the
        // same viewport with the node absent from the scene altogether. Sampling
        // one pixel inside the card and comparing it to one outside does not
        // work and is worth recording: in light mode the card's paper is
        // `textBackgroundColor`, pure white, and so is the page behind it — the
        // comparison is 255 against 255 whether or not a card was ever drawn.
        // What only a drawn card can produce is a CHANGE where the card is.
        func page(scene: CanvasScene) throws -> Page {
            try Self.render(size: viewSize) { cx in
                CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: viewSize,
                                    layouts: [id: layout], visibleEditorNodeID: id,
                                    straighten: CanvasFocusStraighten(), into: &cx)
            }
        }
        let drawn = try page(scene: scene)
        let blank = try page(scene: CanvasScene())

        var differing = 0
        for y in Int(frame.minY)..<Int(frame.maxY) {
            for x in Int(frame.minX)..<Int(frame.maxX)
            where drawn.value(x: x, y: y) != blank.value(x: x, y: y) {
                differing += 1
            }
        }
        XCTAssertGreaterThan(differing, 200,
                             "the focused card was not drawn at all — §7A.5 needs it "
                             + "there to be the one square card on the canvas")

        // Specifically at the resize mark, which is chrome nothing else paints.
        let handle = CGPoint(x: frame.maxX - CanvasRenderer.resizeHandleSize / 3,
                             y: frame.maxY - CanvasRenderer.resizeHandleSize / 3)
        XCTAssertNotEqual(drawn.value(x: Int(handle.x), y: Int(handle.y)),
                          blank.value(x: Int(handle.x), y: Int(handle.y)),
                          "the card's resize mark is missing from the focused card")
    }

    /// FINDING 3, pinned. `ScrapLayout`'s ink defaults to `NSColor.labelColor`,
    /// which resolves against whatever appearance is current when the glyphs
    /// rasterise. That default is right ONLY because the paper under it is
    /// appearance-dynamic too. Make the card paper-coloured in both appearances
    /// and every scrap is white-on-paper in dark mode — and nothing else in the
    /// suite would say so, because `lineGeometrySignature` compares geometry and
    /// the one test that rasterises glyphs is deliberately pinned to `.aqua`.
    ///
    /// Fails in both directions: static paper with dynamic ink loses the gap in
    /// dark mode, and static ink with dynamic paper loses it too.
    func test_theCardsInkContrastsWithItsPaperInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                guard let paper = CanvasRenderer.cardPaper.usingColorSpace(.sRGB),
                      let ink = CanvasRenderer.cardInk.usingColorSpace(.sRGB) else {
                    return XCTFail("could not resolve the card colours under \(name.rawValue)")
                }
                // Composite the ink over the paper — labelColor is not opaque.
                let composited = ink.brightnessComponent * ink.alphaComponent
                    + paper.brightnessComponent * (1 - ink.alphaComponent)
                XCTAssertGreaterThan(
                    abs(paper.brightnessComponent - composited), 0.5,
                    "under \(name.rawValue) the ink is \(composited) on paper of "
                    + "\(paper.brightnessComponent) — a scrap's text is unreadable. "
                    + "CanvasRenderer.cardInk and cardPaper must track the same "
                    + "appearance signal; Task 9/10 pass cardInk into ScrapLayout.")
            }
        }
    }

    // MARK: - Rasterisation helper

    /// One rendered page, addressed in POINTS from the top-left — the same
    /// coordinates `CanvasRenderer.draw` works in.
    private struct Page {
        let bytes: [UInt8]
        let bytesPerRow: Int
        let width: Int
        let height: Int
        /// The green channel at `(x, y)`; 0 outside the page.
        func value(x: Int, y: Int) -> UInt8 {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return 0 }
            return bytes[y * bytesPerRow + x * 4 + 1]
        }
    }

    /// Render a `Canvas` draw closure at scale 1 and read its pixels.
    ///
    /// The colour scheme is pinned to `.light` so `Color(nsColor:)` resolves the
    /// same way on a dark-mode Mac as on a light-mode CI box — the same reason
    /// `ScrapLayoutTests` pins its bitmap comparison to `.aqua`.
    @MainActor
    private static func render(size: CGSize,
                               _ draw: @escaping (inout GraphicsContext) -> Void) throws -> Page {
        let renderer = ImageRenderer(
            content: Canvas { cx, _ in draw(&cx) }
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .light))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")

        let w = image.width, h = image.height
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        // Magenta backing: the Canvas is transparent outside what it draws, and a
        // colour nothing in the palette resembles keeps "unpainted" distinguishable
        // from "painted white".
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let count = ctx.bytesPerRow * h
        // Row 0 of a CGBitmapContext's buffer is the TOP row of the drawn image,
        // so buffer row == point y. Verified against a GraphicsContext fill at
        // y = 0, which inks buffer rows 0...9.
        let bytes = Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self,
                                                                         capacity: count),
                                              count: count))
        return Page(bytes: bytes, bytesPerRow: ctx.bytesPerRow, width: w, height: h)
    }
}
