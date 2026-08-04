import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

/// The rendered page is `CanvasPage` from `CanvasRasterPage.swift` — one buffer
/// for the whole directory. The alias keeps this suite's own signatures reading
/// as they did when the struct was private here.
private typealias Page = CanvasPage

final class CanvasRendererTests: XCTestCase {

    /// A card to ask for an angle. `seededRotation` and `drawnAngle` take the
    /// NODE since 1C-c3, because the author is what decides whether a thing
    /// leans at all — see `CanvasRenderer.seededRotation(for:)`.
    private func card(_ id: String,
                      author: AnnotationAuthor.SourceKind? = nil) -> CanvasNode {
        CanvasNode(id: CanvasNodeID(id), kind: .scrap, origin: .zero,
                   width: 240, cachedHeight: 80, author: author)
    }

    func test_seededRotation_isStableForTheSameID() {
        let a = CanvasRenderer.seededRotation(for: card("s1"))
        let b = CanvasRenderer.seededRotation(for: card("s1"))
        XCTAssertEqual(a.degrees, b.degrees, accuracy: 1e-12,
                       "a card that shimmers between renders is the failure §7.2 forbids")
    }

    func test_seededRotation_differsAcrossIDs() {
        let angles = (0..<40).map { CanvasRenderer.seededRotation(for: card("s\($0)")).degrees }
        XCTAssertGreaterThan(Set(angles.map { Int($0 * 1_000_000) }).count, 30,
                             "rotation must actually vary, or nothing was put down by hand")
    }

    /// The tilt is a calibrated number now (`CanvasMaterial.maximumTiltDegrees`),
    /// not a literal, so this pins two different things: that every card lands
    /// inside whatever it is set to, and that the setting itself stays inside a
    /// band where §7.2 still holds.
    ///
    /// The band replaces a flat `< 1.0`, which the writer's doubling to 1.2°
    /// would have failed. "A seeded fraction of a degree" was a description of
    /// the first calibration, not the requirement; the requirement is that a
    /// scrap reads as *put down by hand* rather than as snapped to a grid at one
    /// end or knocked over at the other. A degree or two is the honest reading of
    /// that, and the ceiling is what stops a calibration round drifting into
    /// cards that look broken.
    func test_seededRotation_staysWithinTheCalibratedTilt() {
        XCTAssertGreaterThan(CanvasMaterial.maximumTiltDegrees, 0,
                             "a zero tilt snaps every card to the grid, which is the one "
                             + "thing §7.2 names")
        XCTAssertLessThanOrEqual(CanvasMaterial.maximumTiltDegrees, 3.0,
                                 "past a few degrees a scrap reads as knocked over rather "
                                 + "than put down, and the hit-test mismatch band (r·θ) "
                                 + "grows past the pointer slop that absorbs it")
        for i in 0..<400 {
            let d = CanvasRenderer.seededRotation(for: card("node-\(i)")).degrees
            XCTAssertLessThanOrEqual(abs(d), CanvasMaterial.maximumTiltDegrees,
                                     "a card leaned further than the calibrated maximum")
        }
    }

    /// **Straight means Claude, and only a dead band makes that reliable** (spec
    /// §8A.2 constraint 1). Before `minimumTiltDegrees` a seed landing near the
    /// middle of the range drew a writer's own card essentially level, so the
    /// signal was usually-right — and the failure a usually-right provenance
    /// signal invites is the writer trusting a card is theirs when it is not.
    ///
    /// Asserted over 400 ids rather than on the constants, because the band is a
    /// property of the mapping and a mapping can ignore its own floor. The
    /// constants get their own assertion here too: a minimum at or above the
    /// maximum gives every card the same lean, which is the grid §7.2 rejects.
    func test_theTiltBandLeavesTrueZeroToClaude() {
        XCTAssertGreaterThan(CanvasMaterial.minimumTiltDegrees, 0,
                             "a zero floor is no dead band at all, and straight stops "
                             + "meaning anything")
        XCTAssertLessThan(CanvasMaterial.minimumTiltDegrees, CanvasMaterial.maximumTiltDegrees,
                          "a floor that meets the ceiling gives every card one lean")
        for i in 0..<400 {
            let d = CanvasRenderer.seededRotation(for: card("node-\(i)")).degrees
            XCTAssertGreaterThanOrEqual(
                abs(d), CanvasMaterial.minimumTiltDegrees,
                "node-\(i) leans \(d)°, inside the band reserved for Claude — a card the "
                + "writer made must never draw straight, or the writer cannot trust that "
                + "a straight card is not theirs")
        }
    }

    /// The other half, and the two are not the same claim: the band above says a
    /// human thing never draws straight, and this says Claude's thing always
    /// does. **Both primitives**, because a region is the one Claude creates on
    /// every call.
    ///
    /// Exactly zero, not nearly — the whole reading is "this is the one thing on
    /// the canvas that was not put down by hand".
    func test_claudesCardsAndRegionsAreDrawnExactlyStraight() {
        for i in 0..<40 {
            XCTAssertEqual(
                CanvasRenderer.seededRotation(for: card("node-\(i)", author: .claude)).degrees,
                0, accuracy: 0,
                "a card Claude put down leaned")
            let region = CanvasRegion(id: CanvasRegionID("r-\(i)"), label: "",
                                      frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                      author: .claude)
            XCTAssertEqual(CanvasRenderer.seededRotation(for: region).degrees, 0, accuracy: 0,
                           "a region Claude swept leaned")
        }
    }

    /// A region the WRITER swept leans, and leans by its own seed rather than by
    /// its cards'. Regions did not lean at all before 1C-c3, so without this the
    /// provenance signal would say nothing about the primitive Claude creates
    /// most often — and a region that never leaned would read as Claude's.
    func test_theWritersRegionsLeanTooAndEachByItsOwnSeed() {
        func region(_ id: String) -> CanvasRegion {
            CanvasRegion(id: CanvasRegionID(id), label: "",
                         frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let degrees = (0..<40).map { CanvasRenderer.seededRotation(for: region("r-\($0)")).degrees }
        XCTAssertEqual(degrees.count, 40, "the fixture must actually produce 40 angles")
        for (index, d) in degrees.enumerated() {
            XCTAssertGreaterThanOrEqual(abs(d), CanvasMaterial.minimumTiltDegrees,
                                        "region r-\(index) drew straight, which reads as "
                                        + "Claude's")
            XCTAssertLessThanOrEqual(abs(d), CanvasMaterial.maximumTiltDegrees,
                                     "region r-\(index) leaned past the calibrated maximum")
        }
        XCTAssertGreaterThan(Set(degrees.map { Int($0 * 1_000_000) }).count, 30,
                             "every region got the same angle — the seed is not being read")
    }

    /// A region has no size ceiling and a card effectively does, so the flat
    /// `cullingBleed` cannot serve both once regions lean. A region round twenty
    /// cards has a half-diagonal past 700 pt, where 1° swings a corner more than
    /// 12 pt outside the frame — and a region culled on its bare frame would
    /// blink out with a corner still on screen.
    func test_aBigTiltedRegionIsNotCulledWithACornerStillOnScreen() {
        let viewSize = CGSize(width: 800, height: 600)
        let side: CGFloat = 1_400
        let overhang = CanvasRenderer.rotationOverhang(of: CGSize(width: side, height: side))
        XCTAssertGreaterThan(overhang, CanvasRenderer.cullingBleed,
                             "the fixture is too small to discriminate: at \(side)² the "
                             + "overhang is \(overhang) pt, inside the flat bleed")

        // Placed so the frame clears the inflated viewport by less than its own
        // overhang — the exact window in which the corner is visible and the
        // bare frame is not.
        let gap = CanvasRenderer.cullingBleed + (overhang - CanvasRenderer.cullingBleed) / 2
        var scene = CanvasScene()
        scene.insertRegion(CanvasRegion(id: CanvasRegionID("big"), label: "",
                                        frame: CGRect(x: -side - gap, y: 0,
                                                      width: side, height: side)))
        XCTAssertEqual(
            CanvasRenderer.visibleRegions(in: scene, camera: CanvasCamera(),
                                          viewSize: viewSize).count, 1,
            "a region whose rotated corner reaches the viewport was culled")

        // The control: pushed clear of even the overhang, it IS culled — so the
        // assertion above is the inflation working and not the cull switched off.
        var far = CanvasScene()
        far.insertRegion(CanvasRegion(id: CanvasRegionID("far"), label: "",
                                      frame: CGRect(x: -side - overhang - 40, y: 0,
                                                    width: side, height: side)))
        XCTAssertEqual(
            CanvasRenderer.visibleRegions(in: far, camera: CanvasCamera(),
                                          viewSize: viewSize).count, 0,
            "culling is not happening at all")
    }

    /// The seeded angles must SPREAD across the calibrated range, not huddle near
    /// zero. Without this, `maximumTiltDegrees` could be raised to any number and
    /// the canvas would look identical — the writer would be calibrating a knob
    /// that does nothing, and every test above would still pass.
    func test_theSeededTiltActuallyUsesTheCalibratedRange() {
        let degrees = (0..<400).map {
            CanvasRenderer.seededRotation(for: card("node-\($0)")).degrees
        }
        let extreme = CanvasMaterial.maximumTiltDegrees * 0.9
        XCTAssertTrue(degrees.contains { $0 > extreme },
                      "no card leans near the positive limit")
        XCTAssertTrue(degrees.contains { $0 < -extreme },
                      "no card leans near the negative limit")
    }

    // MARK: - §7A.5, focus straightens the card

    func test_anUnfocusedCardIsDrawnAtItsFullSeededAngle() {
        let straighten = CanvasFocusStraighten()
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: card("s1"), straighten: straighten).degrees,
                       CanvasRenderer.seededRotation(for: card("s1")).degrees,
                       accuracy: 1e-12)
    }

    func test_theFocusedCardEndsUpExactlyLevel() {
        var straighten = CanvasFocusStraighten()
        straighten.focus(CanvasNodeID("s1"))
        while straighten.step(elapsed: 1.0 / 60) { }
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: card("s1"), straighten: straighten).degrees,
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
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: card("s1"), straighten: straighten).degrees,
                       CanvasRenderer.seededRotation(for: card("s1")).degrees,
                       accuracy: 1e-12)
        XCTAssertTrue(straighten.isSettled, "a settled canvas must pause its clock")
    }

    /// The gate Task 10 REVEALS the editor behind. The editor is mounted and
    /// taking keystrokes well before this; `isLevel` is when it becomes the
    /// VISIBLE text and the renderer stops drawing that card's own. §7A.5
    /// requirement 1 orders it: caret, then animate, then hand the text over.
    /// Showing the editor at progress 0 puts axis-aligned glyphs on a card that
    /// is still up to `CanvasMaterial.maximumTiltDegrees` off level, at the
    /// unrotated text origin, with the
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
        XCTAssertEqual(CanvasRenderer.drawnAngle(for: card("s1"), straighten: straighten).degrees,
                       0, accuracy: 1e-12,
                       "isLevel must not be able to be true while the card is tilted")
    }

    /// A paused-then-resumed `TimelineView` hands `step` a zero or negative
    /// delta, and Task 10 owns that clock. Zero is a wasted frame; NEGATIVE is
    /// the damaging one — without a guard the `abs(target - current) <= delta`
    /// test can never be true, so every entry takes the moving branch and walks
    /// away from its target instead of toward it.
    func test_aNonPositiveFrameNeitherAdvancesNorRewindsTheStraighten() {
        var straighten = CanvasFocusStraighten()
        let id = CanvasNodeID("s1")
        straighten.focus(id)
        straighten.step(elapsed: 1.0 / 60)
        let afterOneFrame = straighten.progress(for: id)
        XCTAssertGreaterThan(afterOneFrame, 0)

        XCTAssertTrue(straighten.step(elapsed: 0),
                      "a zero-length frame must still report the card in flight — "
                      + "reporting settled pauses the clock on a half-straightened card")
        XCTAssertEqual(straighten.progress(for: id), afterOneFrame, accuracy: 1e-12,
                       "a zero-length frame advanced the straighten")

        straighten.step(elapsed: -1.0 / 60)
        XCTAssertEqual(straighten.progress(for: id), afterOneFrame, accuracy: 1e-12,
                       "a negative frame ran the straighten backwards — the card is "
                       + "now further from level than it was and will never settle")
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
        for line in try Self.canvasSourceLines() {
            // Comments may NAME it; `code` has them stripped.
            if line.code.contains(".rotate(by:") || line.code.contains("rotationEffect(") {
                offenders.append(line.description)
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

    /// The culling bleed must cover the drop shadow AND the rotation overhang at
    /// whatever tilt the canvas is calibrated to — the arithmetic, re-done in
    /// code, so a calibration round cannot quietly invalidate it.
    ///
    /// The overhang is `r·θ` and `r` is half the card's diagonal, so it scales
    /// with the card as well as with the angle. It is measured here against a
    /// **generously wide** card rather than the default 240×80: a writer widens a
    /// scrap by dragging its corner, and the failure this guards — a card culled
    /// while a corner of it is still on screen, so the card blinks out at the
    /// window edge as they pan — bites the widest card on the canvas first.
    ///
    /// At the original θ = 0.6° a bleed of 8 pt cleared this by a wide margin;
    /// doubling the tilt to 1.2° without touching the bleed would have left a
    /// 480-wide card overhanging 5.3 pt against a 3 pt allowance over the shadow.
    func test_theCullingBleedCoversTheRotationOverhangAtTheCalibratedTilt() {
        // `drawCard`'s shadow: radius 3 at offset (1, 2).
        let shadowReach: CGFloat = 5
        let card = CGSize(width: 480, height: 160)
        let radius = (card.width * card.width + card.height * card.height).squareRoot() / 2
        let overhang = radius * CGFloat(CanvasMaterial.maximumTiltDegrees * .pi / 180)

        XCTAssertGreaterThan(
            CanvasRenderer.cullingBleed, shadowReach + overhang,
            "at \(CanvasMaterial.maximumTiltDegrees)° a \(Int(card.width))×"
            + "\(Int(card.height)) card's corner swings \(overhang) pt outside its own "
            + "frame, and the drop shadow reaches \(shadowReach) pt — but the bleed is "
            + "only \(CanvasRenderer.cullingBleed) pt, so a card still partly on screen "
            + "can be culled and blink out at the window edge. Raise "
            + "CanvasRenderer.cullingBleed to match the tilt.")
    }

    /// A card paints outside its own frame — `drawCard`'s shadow reaches ~5 pt
    /// past the edge, and the seeded rotation carries a corner further still — so
    /// culling on the bare frame drops a card whose shadow would still have
    /// fallen inside the viewport. The writer sees shadows appear and vanish at
    /// the window edge as they pan, which reads as the surface flickering.
    func test_visibleNodes_keepsACardWhoseShadowStillFallsInsideTheViewport() {
        let viewSize = CGSize(width: 800, height: 600)
        func isVisible(atX x: CGFloat) -> Bool {
            var node = CanvasNode(id: CanvasNodeID("n1"), kind: .scrap,
                                  origin: CGPoint(x: x, y: 0), width: 240)
            node.cachedHeight = 100
            var scene = CanvasScene()
            scene.insert(node)
            return !CanvasRenderer.visibleNodes(in: scene, camera: CanvasCamera(),
                                                viewSize: viewSize).isEmpty
        }
        // Frame entirely off the right edge, but by less than the bleed.
        XCTAssertTrue(isVisible(atX: viewSize.width + CanvasRenderer.cullingBleed / 2),
                      "a card just past the edge was culled with its shadow, so the "
                      + "shadow pops in rather than sliding in")
        XCTAssertFalse(isVisible(atX: viewSize.width + CanvasRenderer.cullingBleed * 4),
                       "the bleed must not become a licence to draw the whole scene")
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

    /// **An item node's label names the THING and never its reference id.**
    ///
    /// `CanvasRenderer.placeholderLabel` was the 1C-a spelling — `Item · res-3f2a`
    /// — and it is gone: a code is not something the writer can read, and §8A.2's
    /// corollary asks that a photographed page and the scraps read off it be
    /// comparable by looking. What draws the label now is `CanvasItemFacts`, so
    /// this asserts the property the old function's test asserted, at the place
    /// that decides it.
    func test_anItemNodesLabelIsATitleAndNeverAReferenceId() {
        let index = CanvasItemIndex(entriesByID: [
            "r-9": .init(title: "Notebook page 3", kind: .researchNote)])
        XCTAssertEqual(CanvasItemFacts.resolve(.project(id: "r-9"), in: index).title,
                       "Notebook page 3")
        // Deleted, which is the arm that used to have nowhere to go but the id.
        XCTAssertFalse(CanvasItemFacts.resolve(.project(id: "r-8"), in: index).title.contains("r-8"),
                       "a reference to something the writer deleted still prints its id "
                       + "on the card")
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
        for line in try Self.canvasSourceLines() {
            // Comments may NAME the hazard; only code may not use it.
            for pat in forbidden where line.code.contains(pat) {
                offenders.append(line.description)
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "the canvas must never derive a raster scale — withCGContext "
                      + "already supplies backingScaleFactor x camera zoom, and a "
                      + "hand-derived scale bakes in AppKit frame rounding and shifts "
                      + "glyphs by a subpixel (spike requirement 3): \(offenders)")
    }

    /// The card's ink is only safe because the paper under it moves with the
    /// appearance, and `test_theCardsInkContrastsWithItsPaperInBothAppearances`
    /// pins those two CONSTANTS against each other. It does not pin the SEAM —
    /// that whoever builds a `ScrapLayout` actually passes `cardInk`.
    ///
    /// That seam is the one likely to break, and the nearest worked examples are
    /// this file's own raster fixtures, which pass a static `.black` because they
    /// are about geometry. A static ink over dynamic paper is exactly the mutation
    /// the contrast test proves is broken — white-on-white in dark mode — and
    /// nothing else here would notice: the contrast test reads the constants, both
    /// raster tests are pinned to `.light`, and `lineGeometrySignature` compares
    /// geometry. So the seam gets a grep rather than another comment.
    ///
    /// Production only, so the test fixtures' `.black` stays legal. The window is
    /// the construction line plus the eight after it, because the argument list
    /// is normally wrapped.
    func test_everyScrapLayoutInProductionNamesTheCardInk() throws {
        let lines = try Self.canvasSourceLines()
        var offenders: [String] = []
        for (index, line) in lines.enumerated() where line.code.contains("ScrapLayout(") {
            let window = lines[index..<min(index + 9, lines.count)]
                .prefix { $0.file == line.file }
                .map(\.code).joined(separator: "\n")
            if !window.contains("textColor: CanvasRenderer.cardInk") {
                offenders.append(line.description)
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "a ScrapLayout built in Maugham/Canvas must name "
                      + "CanvasRenderer.cardInk. Its default is the same colour "
                      + "today, and a literal colour is the same colour in light "
                      + "mode — both go invisible on dark paper, and no other test "
                      + "in this file rasterises dark mode: \(offenders)")
    }

    /// All three greps above walk `Maugham/Canvas/`. If that walk ever silently
    /// found nothing — a moved directory, a renamed area — every offender list
    /// would be empty and all three tests would pass for the wrong reason.
    func test_theCanvasSourceWalkActuallyFindsTheCanvasFiles() throws {
        let names = Set(try Self.canvasSourceLines().map(\.file))
        XCTAssertTrue(names.contains("CanvasRenderer.swift"),
                      "the grep tripwires are scanning the wrong directory: \(names)")
        XCTAssertGreaterThan(names.count, 4)
    }

    /// One line of Swift under `Maugham/Canvas/`.
    private struct SourceLine {
        let file: String
        /// 1-based, so it matches what an editor shows.
        let number: Int
        /// The whole line, trimmed — for the offender message.
        let text: String
        /// The line with comment text removed. The tripwires match on THIS, so a
        /// doc comment may name a banned spelling and a comment may not smuggle
        /// one in either.
        let code: String

        var description: String { "\(file):\(number): \(text)" }
    }

    /// Every Swift line under `Maugham/Canvas/`, in file order.
    private static func canvasSourceLines() throws -> [SourceLine] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MaughamTests/Canvas
            .deletingLastPathComponent()    // MaughamTests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("Maugham/Canvas", isDirectory: true)

        var out: [SourceLine] = []
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        for case let url as URL in walker! where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            var inBlockComment = false
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let (code, stillInBlock) = strippingComments(String(line),
                                                             inBlockComment: inBlockComment)
                inBlockComment = stillInBlock
                out.append(SourceLine(file: url.lastPathComponent,
                                      number: i + 1,
                                      text: line.trimmingCharacters(in: .whitespaces),
                                      code: code))
            }
        }
        return out
    }

    /// The code half of a line, and whether a `/* */` block is still open after
    /// it.
    ///
    /// Skipping only lines that START with `//` — which is all the first version
    /// of these tripwires did — lets a trailing comment or a block comment
    /// naming a banned spelling fail a build against a file that never used it.
    /// A red build for a comment is a worse failure than the one being guarded.
    ///
    /// String literals are not tracked, so a banned spelling inside a literal
    /// containing `//` is missed. That direction is safe: it can only lose a
    /// match, never invent one.
    private static func strippingComments(_ line: String,
                                          inBlockComment: Bool) -> (String, Bool) {
        var code = ""
        var inBlock = inBlockComment
        var i = line.startIndex
        while i < line.endIndex {
            let rest = line[i...]
            if inBlock {
                if rest.hasPrefix("*/") {
                    inBlock = false
                    i = line.index(i, offsetBy: 2)
                    continue
                }
            } else {
                if rest.hasPrefix("//") { break }
                if rest.hasPrefix("/*") {
                    inBlock = true
                    i = line.index(i, offsetBy: 2)
                    continue
                }
                code.append(line[i])
            }
            i = line.index(after: i)
        }
        return (code, inBlock)
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
                                layouts: [node.id: layout],
                                scraps: [:], items: .empty, selection: nil, highlight: .undimmed,
                                pieceTitles: .empty,
                                visibleEditorNodeID: nil,
                                straighten: CanvasFocusStraighten(),
                                pendingRegionDraw: nil, pendingLine: nil, into: &cx)
        }

        let inkRows = page.inkRows(0..<Int(viewSize.height),
                                   columns: Self.textColumns(inCard: frame))

        XCTAssertFalse(inkRows.isEmpty, "the draw pass put no text on the page at all")
        let firstRow = try XCTUnwrap(inkRows.first), lastRow = try XCTUnwrap(inkRows.last)

        let textTop = frame.minY + CanvasCardMetrics.inset
        XCTAssertEqual(CGFloat(firstRow), textTop, accuracy: 8,
                       "the first inked row must be the top of the text box "
                       + "(CanvasCardMetrics.textOrigin), not somewhere else — under a "
                       + "flip the glyphs run upward from the text origin and the clip "
                       + "crops them to the card's top edge, 10 pt higher")
        XCTAssertGreaterThan(CGFloat(lastRow - firstRow), textHeight * 0.6,
                             "only part of the scrap was drawn — under a flip most of "
                             + "it is outside the card and the clip removes it")

        // Nothing may be drawn outside the card at all. This replaces a pair of
        // assertions that could not fire: they tested that `firstRow` was not
        // above `frame.minY` and `lastRow` not below `frame.maxY`, but `drawCard`
        // clips the text layer to the card shape, so a glyph cannot rasterise
        // outside the frame for either of them to catch. Asserting on the rows
        // OUTSIDE the card can fail — a flip plus a lost clip puts the glyphs on
        // the page above the card — and it guards the clip itself, which is the
        // only reason the two lines it replaces were unreachable.
        let fullWidth = 0..<Int(viewSize.width)
        XCTAssertEqual(page.inkPixels(rows: 0..<Int(frame.minY), columns: fullWidth), 0,
                       "something inked the page ABOVE the card — the text is running "
                       + "upward from the text origin, i.e. drawCard and ScrapLayout "
                       + "disagree about which way y runs, and nothing clipped it")
        XCTAssertEqual(page.inkPixels(rows: Int(frame.maxY)..<Int(viewSize.height),
                                      columns: fullWidth), 0,
                       "something inked the page BELOW the card")
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
                                    layouts: [id: layout],
                                    scraps: [:], items: .empty, selection: nil, highlight: .undimmed,
                                    pieceTitles: .empty,
                                    visibleEditorNodeID: visibleEditor,
                                    straighten: CanvasFocusStraighten(),
                                    pendingRegionDraw: nil, pendingLine: nil, into: &cx)
            }
            return page.inkPixels(rows: Int(frame.minY)..<Int(frame.maxY),
                                  columns: Self.textColumns(inCard: frame))
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
        //
        // Because the paper matches the page, what that change consists of is
        // the card's CHROME — border, shadow, resize mark — not its body: 629
        // pixels measured, against a threshold of 200. That is the honest
        // reading of this number, and it is enough, because a card that drew no
        // chrome at all drew nothing at all (verified: 0).
        func page(scene: CanvasScene) throws -> Page {
            try Self.render(size: viewSize) { cx in
                CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: viewSize,
                                    layouts: [id: layout],
                                    scraps: [:], items: .empty, selection: nil, highlight: .undimmed,
                                    pieceTitles: .empty,
                                    visibleEditorNodeID: id,
                                    straighten: CanvasFocusStraighten(),
                                    pendingRegionDraw: nil, pendingLine: nil, into: &cx)
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

    // MARK: - What an item node shows (1C-d)

    /// **The card says what it IS, and that is spec §8A.2's reproduction
    /// corollary being paid rather than promised.** Until 1C-d an item node drew
    /// a dashed card carrying `Item · res-3f2a`, so the page a batch of scraps
    /// was read off and the scraps themselves could not be compared by looking —
    /// the writer had to click through to find out what the reference was. ADR
    /// 0026 §10 records that as "structural here, visible at 1C-d".
    ///
    /// The title is asserted DIFFERENTIALLY, against the identical scene with no
    /// facts resolved: what only a resolved title can produce is ink where the
    /// label goes. Asserting "there is ink" alone would be satisfied by the
    /// card's own chrome.
    @MainActor
    func test_anItemNodeDrawsItsTitleWhereTheMeasurementPutIt() throws {
        let id = CanvasNodeID.item("res-notebook")
        var node = CanvasNode(id: id, kind: .item(.project(id: "res-notebook")),
                              origin: CGPoint(x: 40, y: 90), width: 240)
        node.cachedHeight = CanvasCardMetrics.itemLabelOnlyHeight
        var scene = CanvasScene()
        scene.insert(node)
        let frame = try XCTUnwrap(node.frame)
        let viewSize = CGSize(width: 360, height: 285)
        let index = CanvasItemIndex(entriesByID: [
            "res-notebook": .init(title: "Notebook page 3", kind: .researchNote)])
        let items = CanvasItemPresentation.facts(in: scene, index: index)

        func page(_ items: CanvasItemPresentation) throws -> Page {
            try Self.render(size: viewSize) { cx in
                CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: viewSize,
                                    layouts: [:],
                                    scraps: [:], items: items, selection: nil, highlight: .undimmed,
                                    pieceTitles: .empty,
                                    visibleEditorNodeID: nil,
                                    straighten: CanvasFocusStraighten(),
                                    pendingRegionDraw: nil, pendingLine: nil, into: &cx)
            }
        }
        let resolved = try page(items)
        let unresolved = try page(.empty)

        let body = Int(frame.minY)..<Int(frame.maxY)
        let band = Self.textColumns(inCard: frame)
        XCTAssertGreaterThan(resolved.inkPixels(rows: body, columns: band), 20,
                             "an item node drew no title — nothing on the canvas says "
                             + "what the card points at, and §8A.2's corollary asks "
                             + "that a reproduction and its source be comparable by "
                             + "LOOKING")
        XCTAssertEqual(unresolved.inkPixels(rows: body, columns: band), 0,
                       "a card whose facts have not resolved drew something in its "
                       + "label band — the placeholder id coming back through the "
                       + "unresolved path is exactly what this slice removed")

        // The title sits on the row the measurement reserved for it: the label
        // line's own top, one inset above the card's bottom edge. Bounded rather
        // than pinned with a tolerance — the gap between a text origin and the
        // first inked row is the font's ascent slack, so any tolerance wide
        // enough to survive a font metric change also swallows the 10 pt inset.
        //
        // Read in the TITLE's columns rather than the whole text band, which is
        // the difference between measuring the title and measuring the glyph
        // beside it: a resolved SF Symbol fills its fitted box to the edge and
        // antialiases a pixel past it, so the glyph's first inked row is the
        // reserved one minus a rounding artifact and says nothing about layout.
        let titleStart = Int(CanvasCardMetrics.itemTitleOrigin(inCard: frame).x)
        let titleBand = titleStart..<Int(frame.maxX - CanvasCardMetrics.inset)
        let labelTop = CGFloat(try XCTUnwrap(resolved.inkRows(0..<Int(viewSize.height),
                                                              columns: titleBand).first))
        let reserved = CanvasCardMetrics.itemGlyphBox(inCard: frame).minY
        XCTAssertGreaterThanOrEqual(labelTop, reserved,
                                    "the title is inked ABOVE the row the card was "
                                    + "measured for, so the drawn card and the measured "
                                    + "one are on different rects (§7A.2's failure on "
                                    + "the other content type)")
        XCTAssertLessThan(labelTop, reserved + CanvasCardMetrics.itemLabelLineHeight,
                          "the title is inked below its own line")
    }

    /// **The photograph itself, which is the whole of the corollary.** Two
    /// renders of one scene differing in exactly one fact — whether the item
    /// node's thumbnail has been decoded — must differ inside the rect the
    /// picture is drawn in, and nowhere outside the card.
    ///
    /// The presentation is resolved through the REAL two-verb split (ask, miss,
    /// service, ask again), so a renderer that drew nothing and a cache that
    /// never decoded are both visible here.
    @MainActor
    func test_anItemNodeWithAPictureDrawsIt() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("canvas-item-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "canvas_assets/image-20260730-220430.png"
        try writeCanvasFixtureImage(width: 400, height: 300,
                                    to: root.appendingPathComponent(path))

        let id = CanvasNodeID("owned-1")
        var node = CanvasNode(id: id, kind: .item(.owned(path: path)),
                              origin: CGPoint(x: 40, y: 40), width: 240)
        node.cachedHeight = CanvasCardMetrics.itemCardHeight(forCardWidth: 240,
                                                             pictureAspect: 4.0 / 3.0)
        var scene = CanvasScene()
        scene.insert(node)
        let frame = try XCTUnwrap(node.frame)
        let viewSize = CGSize(width: 360, height: 40 + frame.height + 60)

        let pictured = await resolvedItemPresentation(scene: scene, index: .empty,
                                                      projectRoot: root)
        XCTAssertEqual(pictured.picturedCount, 1,
                       "precondition: the fixture never decoded, so the comparison "
                       + "below is between two identical pages")

        func page(_ items: CanvasItemPresentation) throws -> Page {
            try Self.render(size: viewSize) { cx in
                CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: viewSize,
                                    layouts: [:],
                                    scraps: [:], items: items, selection: nil, highlight: .undimmed,
                                    pieceTitles: .empty,
                                    visibleEditorNodeID: nil,
                                    straighten: CanvasFocusStraighten(),
                                    pendingRegionDraw: nil, pendingLine: nil, into: &cx)
            }
        }
        let withPicture = try page(pictured)
        // The same card, same size, same title — only the picture is missing.
        let withoutPicture = try page(
            CanvasItemPresentation.facts(in: scene, index: .empty))

        let pictureRect = CanvasCardMetrics.itemPictureRect(inCard: frame, aspect: 4.0 / 3.0)
        let changed = withPicture.differingPixels(from: withoutPicture, in: pictureRect)
        XCTAssertGreaterThan(changed, Int(pictureRect.width * pictureRect.height) / 2,
                             "the photograph is not drawn on its card: \(changed) of "
                             + "\(Int(pictureRect.width * pictureRect.height)) pixels in "
                             + "the picture's own rect changed when it resolved. §8A.2's "
                             + "corollary asks that the page and what was read off it be "
                             + "checkable side by side")

        // Nothing outside the card moved — a control that says the count above is
        // the picture and not a page-wide difference.
        XCTAssertEqual(
            withPicture.differingPixels(from: withoutPicture,
                                        in: CGRect(x: 0, y: 0,
                                                   width: viewSize.width, height: frame.minY - 6)),
            0,
            "the picture inked the ground above its card")
    }

    /// **The kind glyph is the one the FACTS name.** Two renders differing only
    /// in the resolved kind must differ inside the glyph's own box — without this
    /// the glyph could be drawn from a constant, or not drawn at all, with the
    /// title fixture above still green.
    @MainActor
    func test_theKindGlyphIsTheOneTheFactsName() throws {
        let id = CanvasNodeID.item("res-thing")
        var node = CanvasNode(id: id, kind: .item(.project(id: "res-thing")),
                              origin: CGPoint(x: 40, y: 90), width: 240)
        node.cachedHeight = CanvasCardMetrics.itemLabelOnlyHeight
        var scene = CanvasScene()
        scene.insert(node)
        let frame = try XCTUnwrap(node.frame)
        let viewSize = CGSize(width: 360, height: 285)

        func page(_ kind: CanvasItemKind) throws -> Page {
            // Same title in both, so any difference is the glyph.
            let index = CanvasItemIndex(entriesByID: [
                "res-thing": .init(title: "The same words", kind: kind)])
            let items = CanvasItemPresentation.facts(in: scene, index: index)
            return try Self.render(size: viewSize) { cx in
                CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: viewSize,
                                    layouts: [:],
                                    scraps: [:], items: items, selection: nil, highlight: .undimmed,
                                    pieceTitles: .empty,
                                    visibleEditorNodeID: nil,
                                    straighten: CanvasFocusStraighten(),
                                    pendingRegionDraw: nil, pendingLine: nil, into: &cx)
            }
        }
        let note = try page(.researchNote)
        let image = try page(.image)

        let box = CanvasCardMetrics.itemGlyphBox(inCard: frame)
        XCTAssertGreaterThan(note.differingPixels(from: image, in: box), 8,
                             "a research note and a photograph draw the same glyph — "
                             + "\(CanvasItemKind.researchNote.glyph) against "
                             + "\(CanvasItemKind.image.glyph) — so the card does not say "
                             + "what kind of thing it points at")
        // Control: the two pages are otherwise identical, so the count above is
        // the glyph rather than a page that differs everywhere.
        XCTAssertEqual(note.differingPixels(from: image,
                                            in: CGRect(x: frame.minX, y: frame.minY,
                                                       width: frame.width,
                                                       height: CanvasCardMetrics.inset)),
                       0,
                       "the two pages differ above the label line as well, so the glyph "
                       + "assertion is measuring something else")
    }

    /// **The dashed border is gone, and the item card takes the SAME border a
    /// scrap does.** The dashes said "unfinished", which was the honest thing to
    /// say while the only content was a reference id; a card that shows a title, a
    /// kind glyph and a photograph and still draws itself as a sketch would
    /// contradict its own content.
    ///
    /// Asserted as pixel equality along the top edge rather than as "no gaps": a
    /// gap test passes for a border that is not drawn at all.
    ///
    /// **And the resize mark is drawn on it too, as of 1C-d Task 6.** This test
    /// asserted the absence of that mark until then, and the inversion is the
    /// point rather than a casualty: the mark and the target are ONE decision
    /// (`CanvasInteraction.begin` and `drawCard` move together, or the surface
    /// draws an affordance that does nothing — or, as it did in 1C-c3, one that
    /// loses the card). Now that an item node's height genuinely follows its
    /// width, the honest end state is the uniform rule this surface had before
    /// the guard: two unconditional marks on every card.
    @MainActor
    func test_anItemNodeTakesTheSameBorderAndResizeMarkAsAScrap() throws {
        let origin = CGPoint(x: 40, y: 90)
        func page(_ kind: CanvasNodeKind) throws -> (Page, CGRect) {
            var node = CanvasNode(id: CanvasNodeID("n1"), kind: kind, origin: origin, width: 240)
            node.cachedHeight = 105
            var scene = CanvasScene()
            scene.insert(node)
            let frame = try XCTUnwrap(node.frame)
            let viewSize = CGSize(width: 360, height: 285)
            return (try Self.render(size: viewSize) { cx in
                CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: viewSize,
                                    layouts: [:],
                                    scraps: [:], items: .empty, selection: nil, highlight: .undimmed,
                                    pieceTitles: .empty,
                                    visibleEditorNodeID: nil,
                                    straighten: CanvasFocusStraighten(),
                                    pendingRegionDraw: nil, pendingLine: nil, into: &cx)
            }, frame)
        }
        let (item, frame) = try page(.item(.project(id: "r-9")))
        let (scrap, _) = try page(.scrap)

        let edge = Int(frame.minY) - 2...Int(frame.minY) + 2
        func topEdge(_ p: Page) -> [Int] {
            (Int(frame.minX) + 6..<Int(frame.maxX) - 6).map { x in
                edge.map { Int(p.value(x: x, y: $0)) }.min() ?? 0
            }
        }
        let itemEdge = topEdge(item), scrapEdge = topEdge(scrap)
        XCTAssertEqual(itemEdge, scrapEdge,
                       "an item node's border is not a scrap's — the dashes that said "
                       + "\"placeholder\" belong to a card that no longer exists")
        // Control: both are genuinely a border rather than both being nothing.
        XCTAssertLessThan(try XCTUnwrap(itemEdge.min()), Int(item.paper) - 8,
                          "neither card drew a top border at all, so the equality above "
                          + "compares two blank strips")

        // And the RESIZE MARK, on both. The mark and the gesture are one
        // decision: `CanvasInteraction.begin` takes the corner of every card, so
        // a page card drawn without the triangle would be silently resizable with
        // nothing on it to say so — the same drift as the 1C-c3 Critical, running
        // the other way.
        //
        // Sampled inside the triangle and ~4 pt clear of the border on both axes,
        // each card against its OWN body pixel, so the two papers cannot decide
        // the answer.
        let mark = CGPoint(x: frame.maxX - CanvasRenderer.resizeHandleSize / 3,
                           y: frame.maxY - CanvasRenderer.resizeHandleSize / 3)
        let body = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertNotEqual(scrap.value(x: Int(mark.x), y: Int(mark.y)),
                          scrap.value(x: Int(body.x), y: Int(body.y)),
                          "precondition: the comparison SCRAP drew no resize mark "
                          + "either, so the assertion below would pass with the mark "
                          + "drawn on nothing at all")
        XCTAssertNotEqual(item.value(x: Int(mark.x), y: Int(mark.y)),
                          item.value(x: Int(body.x), y: Int(body.y)),
                          "the page card is drawn with no resize triangle on it, while "
                          + "CanvasInteraction.begin takes its corner — a card that "
                          + "resizes with no mark to say so")
        // ...and the SAME mark, not merely some ink in the corner: both cards are
        // the same size here, so the triangle's own pixels must agree.
        XCTAssertEqual(item.value(x: Int(mark.x), y: Int(mark.y)),
                       scrap.value(x: Int(mark.x), y: Int(mark.y)),
                       "the two kinds ink their corner differently, so the constant "
                       + "the target is hit-tested from is not the one both are drawn "
                       + "from")
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

    /// The companion to the test above, for the surface's SECOND paper.
    ///
    /// A card Claude put down is drawn on `claudeCardPaper` and its text is drawn
    /// with the same `cardInk` — same ink, same shape, one visual language
    /// (§8A.2). That is only safe while the ink clears the new paper too, and the
    /// new paper is the darker of the two in light mode and the darker of the two
    /// in dark mode: the direction that erodes contrast in dark, where the ink is
    /// white. Nothing else in the suite would say so — the raster fixtures render
    /// no glyphs, and `test_theCardsInkContrastsWithItsPaperInBothAppearances`
    /// reads only the writer's paper.
    func test_theInkContrastsWithClaudesPaperInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                guard let paper = CanvasRenderer.claudeCardPaper.usingColorSpace(.sRGB),
                      let ink = CanvasRenderer.cardInk.usingColorSpace(.sRGB) else {
                    return XCTFail("could not resolve Claude's card colours under "
                                   + name.rawValue)
                }
                // Composite the ink over the paper — labelColor is not opaque.
                let composited = ink.brightnessComponent * ink.alphaComponent
                    + paper.brightnessComponent * (1 - ink.alphaComponent)
                XCTAssertGreaterThan(
                    abs(paper.brightnessComponent - composited), 0.5,
                    "under \(name.rawValue) the ink is \(composited) on Claude's paper of "
                    + "\(paper.brightnessComponent) — the words on a card Claude put down "
                    + "are unreadable. CanvasMaterial's Claude paper pair is the ceiling "
                    + "on how far that card may be darkened to say whose it is.")
            }
        }
    }

    // MARK: - Rasterisation helper

    /// The columns inside a card's text box, clear of the border stroke and of
    /// the resize mark in the bottom-right corner.
    private static func textColumns(inCard frame: CGRect) -> Range<Int> {
        let inset = CanvasCardMetrics.inset
        return Int(frame.minX + inset)..<Int(frame.maxX - CanvasRenderer.resizeHandleSize - inset)
    }

    /// Render a `Canvas` draw closure at scale 1 and read its pixels.
    ///
    /// A one-line forwarder to the shared rasteriser in `CanvasRasterPage.swift`,
    /// now the only definition in this directory of how a `Canvas` becomes a
    /// bitmap. **Its defaults ARE what this function used to hardcode:** `.light`,
    /// so `Color(nsColor:)` resolves on a dark-mode Mac as it does on a light-mode
    /// CI box — the same reason `ScrapLayoutTests` pins `.aqua` — and a nil
    /// backing, which the shared renderer fills with `cardPaper` resolved under
    /// the MATCHING appearance, because this process runs under DarkAqua and
    /// resolving it plainly would paint a dark page behind a light card.
    @MainActor
    private static func render(size: CGSize,
                               _ draw: @escaping (inout GraphicsContext) -> Void) throws -> Page {
        try renderCanvasPage(size: size, scheme: .light, backing: nil, draw)
    }
}

/// **The INK vocabulary**, on the shared `CanvasPage`.
///
/// The buffer, its geometry and the rasteriser live in `CanvasRasterPage.swift` —
/// one copy for the whole directory, because this was the third. These readers
/// stay here because this is the only suite that reasons in ink, and the colour
/// vocabulary in the shared file sits on the other side of the same seam.
///
/// **The two want OPPOSITE answers off the end of the page, which is the clearest
/// reason they are not one reader:** `value(x:y:)` returns the paper so an
/// off-page read can never be mistaken for ink, where `color(at:)` returns a
/// sentinel no rendered pixel can equal so an off-page read can never satisfy an
/// equality.
///
/// The page itself is addressed in POINTS from the top-left — the same
/// coordinates `CanvasRenderer.draw` works in.
///
/// **The page is backed with the card's own paper, and `isInk` means
/// "materially darker than that paper".** That is what "a glyph landed here"
/// looks like, and it is the only thing these fixtures ever ask.
///
/// An earlier version backed the page with magenta, so that "unpainted"
/// could be told from "painted white". It cannot work, and the way it fails
/// is worth writing down: a `Canvas` paints more than glyphs. `drawCard`'s
/// drop shadow reaches ~5 pt beyond every card, and even its faintest
/// pixels, composited over magenta, swing a colour channel by ~190 — so
/// every shadow row above and below the card counts as ink, `firstRow` lands
/// on the shadow instead of the text origin, and the y-flip pin below stops
/// measuring the flip. (That version was green only because it sampled the
/// RED channel while its comment said green, and magenta and white are both
/// 255 in red. Two errors cancelling.) Backing the page with the paper
/// leaves the shadow 54 levels below paper and a glyph 233 below, so the two
/// stop being confusable at all.
///
/// Measured 2026-07-26 in the light appearance, whole page: glyph pixels
/// reach 0–22; the darkest non-glyph pixel anywhere is the drop shadow at
/// 201, the card border sits at 233 and the resize mark at 235.
/// `inkThreshold` at 100 sits in the middle of that gap, and the y-flip
/// pin's `firstRow` is 103 at a threshold of 60, 100 or 140 alike.
private extension CanvasPage {
    /// How much darker than the paper a pixel must be to count as a glyph.
    static var inkThreshold: Int { 100 }

    /// The GREEN channel at `(x, y)`; `paper` outside the page, so an
    /// off-page read can never be mistaken for ink.
    ///
    /// The context is `premultipliedFirst` with the default byte order, so
    /// the bytes run **A, R, G, B** and green is index 2 — measured
    /// 2026-07-26 by filling a known colour and reading the four bytes back,
    /// not inferred. Index 1 is red.
    func value(x: Int, y: Int) -> UInt8 {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return paper }
        return bytes[y * bytesPerRow + x * 4 + 2]
    }

    func isInk(x: Int, y: Int) -> Bool {
        Int(paper) - Int(value(x: x, y: y)) > Self.inkThreshold
    }

    /// Which of `rows` carry any ink in `columns`.
    func inkRows(_ rows: Range<Int>, columns: Range<Int>) -> [Int] {
        rows.filter { y in columns.contains { isInk(x: $0, y: y) } }
    }

    /// How many pixels in the rect carry ink.
    func inkPixels(rows: Range<Int>, columns: Range<Int>) -> Int {
        rows.reduce(into: 0) { total, y in
            total += columns.count { isInk(x: $0, y: y) }
        }
    }
}
