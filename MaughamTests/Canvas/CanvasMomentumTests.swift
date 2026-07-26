import XCTest
@testable import Maugham

final class CanvasMomentumTests: XCTestCase {

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        var n = CanvasNode(id: CanvasNodeID("a"), kind: .scrap,
                           origin: .zero, width: 240)
        n.cachedHeight = 80
        s.insert(n)
        return s
    }

    func test_aFreshMomentumIsAtRest() {
        XCTAssertTrue(CanvasMomentum().isAtRest)
    }

    func test_aFlickBelowTheRestSpeedNeverStarts() {
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("a"), velocity: CGSize(width: 0.2, height: 0.1))
        XCTAssertTrue(m.isAtRest, "a nudge is a placement, not a throw")
    }

    /// §7.3's whole claim, measured: the card carries, and each frame carries it
    /// less far than the last.
    ///
    /// **The strict `>` is the point of this test.** The plan asserted
    /// `displacements == displacements.sorted(by: >)`, which a decay of 1.0 — no
    /// decay at all — passes: `sorted(by: >)` leaves equal elements where they
    /// are. What would have failed under no decay is the `while` loop, by never
    /// terminating, and a hang is not a test result.
    func test_steppingMovesTheNodeAndDecays() {
        var s = scene()
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("a"), velocity: CGSize(width: 20, height: 0))

        var displacements: [CGFloat] = []
        var previous = s.node(CanvasNodeID("a"))!.origin.x
        var guardRail = 0
        while m.step(&s) {
            let now = s.node(CanvasNodeID("a"))!.origin.x
            displacements.append(now - previous)
            previous = now
            guardRail += 1
            if guardRail > 600 { break }
        }
        XCTAssertGreaterThan(displacements.count, 3)
        XCTAssertEqual(displacements.first, 20,
                       "the first frame carries the card at the speed it was let "
                       + "go at; decaying before the first step swallows a fifth "
                       + "of the throw")
        XCTAssertTrue(zip(displacements, displacements.dropFirst()).allSatisfy { $0 > $1 },
                      "each frame must carry the card STRICTLY less far than the "
                      + "last — equal displacements are a card that does not slow "
                      + "down, which is the one thing §7.3 asks for")
        XCTAssertTrue(m.isAtRest)
    }

    func test_momentumComesToRestQuicklyEnoughToFeelLikeAnObject() {
        var s = scene()
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("a"), velocity: CGSize(width: 999, height: 0))
        var frames = 0
        while m.step(&s) { frames += 1; if frames > 600 { break } }
        XCTAssertLessThan(frames, 60, "a card still coasting after a second is a bug")
        XCTAssertLessThan(s.node(CanvasNodeID("a"))!.origin.x, 400,
                          "a flick must not launch the card off the canvas")
    }

    func test_launchSpeedIsCappedSoAJitteryTrackpadCannotFireACard() {
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("a"), velocity: CGSize(width: 5_000, height: 0))
        XCTAssertLessThanOrEqual(hypot(m.velocity.width, m.velocity.height),
                                 CanvasMomentum.maximumLaunchSpeed + 0.0001)
    }

    /// The cap scales the vector rather than clamping its components, so a
    /// diagonal flick coasts along the line the writer threw it down.
    func test_cappingAFlickKeepsItsDirection() {
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("a"), velocity: CGSize(width: 300, height: 400))
        XCTAssertEqual(m.velocity.height / m.velocity.width, 4.0 / 3.0, accuracy: 0.0001,
                       "a capped flick that changes direction sends the card "
                       + "somewhere the writer did not throw it")
        XCTAssertEqual(hypot(m.velocity.width, m.velocity.height),
                       CanvasMomentum.maximumLaunchSpeed, accuracy: 0.0001)
    }

    func test_steppingANodeThatVanishedStopsRatherThanCrashing() {
        var s = CanvasScene()
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("gone"), velocity: CGSize(width: 20, height: 0))
        XCTAssertFalse(m.step(&s))
        XCTAssertTrue(m.isAtRest)
    }

    func test_stopHaltsACoastingCard() {
        var s = scene()
        var m = CanvasMomentum()
        m.launch(CanvasNodeID("a"), velocity: CGSize(width: 20, height: 0))
        m.stop()
        XCTAssertTrue(m.isAtRest)
        XCTAssertFalse(m.step(&s))
        XCTAssertEqual(s.node(CanvasNodeID("a"))?.origin, .zero,
                       "a stopped card must not travel one more frame — the writer "
                       + "caught it")
    }
}
