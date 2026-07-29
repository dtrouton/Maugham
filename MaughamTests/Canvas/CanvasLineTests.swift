import XCTest
@testable import Maugham

/// Fixture nodes match the brief: `a` at (0,0,240,80) → centre (120,40),
/// `b` at (400,0,240,80) → centre (520,40), `c` at (800,0,240,80) → centre (920,40).
final class CanvasLineTests: XCTestCase {

    private func measuredNode(_ id: String, x: CGFloat, y: CGFloat,
                               width: CGFloat = 240, height: CGFloat = 80) -> CanvasNode {
        CanvasNode(id: CanvasNodeID(id), kind: .scrap,
                   origin: CGPoint(x: x, y: y), width: width, cachedHeight: height)
    }

    private func unmeasuredNode(_ id: String, x: CGFloat, y: CGFloat, width: CGFloat = 240) -> CanvasNode {
        CanvasNode(id: CanvasNodeID(id), kind: .scrap, origin: CGPoint(x: x, y: y), width: width)
    }

    // MARK: - No kind

    func test_aLineCarriesNoTypeOnlyAnOptionalLabel() {
        let line = CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b"))
        XCTAssertNil(line.label, "a fresh line has nothing to say")
        XCTAssertNil(line.author, "a fresh line is the writer's")
        let fieldNames = Mirror(reflecting: line).children.compactMap { $0.label }.sorted()
        // `author` (1C-c3) is on this list and `kind` may never be, and the
        // difference is not a matter of degree: provenance says WHO DREW the
        // line, which asserts nothing about the two cards' relationship, while a
        // kind says what the line MEANS. A field that would make the writer pick
        // from a vocabulary before the line can exist is the thing §5 refuses.
        XCTAssertEqual(fieldNames, ["author", "from", "id", "label", "to"],
                        "CanvasLine must carry no `kind` — Kinopio shipped typed connections for " +
                        "years and removed them in April 2026 because typed connections confused " +
                        "first-time users; re-read spec §5 before adding one back")
    }

    func test_labelCanBeSetAndCleared() {
        var scene = CanvasScene()
        scene.insert(measuredNode("a", x: 0, y: 0))
        scene.insert(measuredNode("b", x: 400, y: 0))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))

        scene.updateLine(CanvasLineID("l1")) { $0.label = "leads to" }
        XCTAssertEqual(scene.lines.first?.label, "leads to")

        scene.updateLine(CanvasLineID("l1")) { $0.label = nil }
        XCTAssertNil(scene.lines.first?.label)
    }

    // MARK: - Storage and ordering

    func test_linesAreOrderedStablyByID() {
        var scene = CanvasScene()
        scene.insert(measuredNode("a", x: 0, y: 0))
        scene.insert(measuredNode("b", x: 400, y: 0))
        scene.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))

        XCTAssertEqual(scene.lines.map { $0.id.raw }, ["l1", "l2"],
                        "dictionary order must reach neither the draw pass nor the sidecar")
    }

    /// **`CanvasScene.lines(touching:)` was deleted in Task 7 and this is what
    /// is left of its test.** The accessor shipped 1C-c1 with zero production
    /// callers, censused three times, and its one plausible caller — naming a
    /// card's connections in the accessibility tree — wants an index built in one
    /// pass rather than a filter per node. What survives is the predicate, which
    /// has two production callers: `CanvasScene.remove`, which scrubs a deleted
    /// node's lines, and `CanvasAccessibility.connections`.
    func test_aLineTouchesBothOfItsEnds() {
        let ab = CanvasLine(id: CanvasLineID("ab"), from: CanvasNodeID("a"), to: CanvasNodeID("b"))
        XCTAssertTrue(ab.touches(CanvasNodeID("a")), "a line does not touch its `from`")
        XCTAssertTrue(ab.touches(CanvasNodeID("b")),
                       "a line does not touch its `to` — a predicate that read one "
                       + "end only would take half a deleted card's lines with it and "
                       + "leave the rest drawing into nowhere")
        XCTAssertFalse(ab.touches(CanvasNodeID("c")),
                        "control: it must not touch a node at neither end")
    }

    func test_aSelfLineIsRejected() {
        var scene = CanvasScene()
        scene.insert(measuredNode("a", x: 0, y: 0))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("a")))

        XCTAssertTrue(scene.lines.isEmpty,
                       "a line from a node to itself has nothing to say and draws as a blob")
    }

    func test_duplicateLinesBetweenTheSamePairAreAllowed() {
        var scene = CanvasScene()
        scene.insert(measuredNode("a", x: 0, y: 0))
        scene.insert(measuredNode("b", x: 400, y: 0))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"),
                                     to: CanvasNodeID("b"), label: "causes"))
        scene.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("a"),
                                     to: CanvasNodeID("b"), label: "echoes"))

        XCTAssertEqual(scene.lines.count, 2,
                        "two differently-labelled thoughts about one pair are both legitimate — a line costs nothing to be wrong about")
    }

    func test_deletingANodeDeletesItsLines() {
        var scene = CanvasScene()
        scene.insert(measuredNode("a", x: 0, y: 0))
        scene.insert(measuredNode("b", x: 400, y: 0))
        scene.insert(measuredNode("c", x: 800, y: 0))
        scene.insertLine(CanvasLine(id: CanvasLineID("ab"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        scene.insertLine(CanvasLine(id: CanvasLineID("bc"), from: CanvasNodeID("b"), to: CanvasNodeID("c")))

        scene.remove(CanvasNodeID("a"))

        XCTAssertEqual(scene.lines.map { $0.id.raw }, ["bc"],
                        "a line to a node that is gone would draw into nowhere")
    }

    // MARK: - Endpoints

    func test_endpointsAreNodeCentres() {
        var scene = CanvasScene()
        scene.insert(measuredNode("a", x: 0, y: 0))
        scene.insert(measuredNode("b", x: 400, y: 0))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))

        let ends = scene.endpoints(of: scene.lines[0])
        XCTAssertEqual(ends?.0, CGPoint(x: 120, y: 40))
        XCTAssertEqual(ends?.1, CGPoint(x: 520, y: 40))
    }

    func test_endpointsAreNilWhenAnEndIsUnmeasured() {
        var scene = CanvasScene()
        scene.insert(measuredNode("a", x: 0, y: 0))
        scene.insert(unmeasuredNode("b", x: 400, y: 0))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))

        XCTAssertNil(scene.endpoints(of: scene.lines[0]),
                     "an unmeasured end has no frame at all — drawing to a guessed position would twitch when the real measurement arrived")
    }

    // MARK: - Hit testing geometry

    func test_distanceToSegmentIsPerpendicularInsideTheSpan() {
        let d = CanvasLineHit.distance(from: CGPoint(x: 300, y: 44),
                                        toSegment: CGPoint(x: 120, y: 40), CGPoint(x: 520, y: 40))
        XCTAssertEqual(d, 4, accuracy: 0.001)
    }

    func test_distanceToSegmentClampsAtBothEndpoints() {
        let a = CGPoint(x: 120, y: 40)
        let b = CGPoint(x: 520, y: 40)

        let atA = CanvasLineHit.distance(from: CGPoint(x: 120, y: 140), toSegment: a, b)
        XCTAssertEqual(atA, 100, accuracy: 0.001, "clamped at the `a` end")

        // Projects to t = -0.25 on the infinite line, which would read as
        // distance 0 (it sits exactly on the line's extension past `a`).
        // Without the clamp a click a mile past the card lands on the
        // infinite line the segment sits on; clamped to t=0 the true
        // distance to the segment's `a` end is 100.
        let pastA = CanvasLineHit.distance(from: CGPoint(x: 20, y: 40), toSegment: a, b)
        XCTAssertEqual(pastA, 100, accuracy: 0.001,
                        "unclamped this point lies ON the infinite line and would wrongly score 0")
    }

    func test_lineAtPointHitsWithinToleranceAndMissesOutside() {
        XCTAssertEqual(CanvasLineHit.tolerance, 6)

        var scene = CanvasScene()
        scene.insert(measuredNode("a", x: 0, y: 0))
        scene.insert(measuredNode("b", x: 400, y: 0))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))

        XCTAssertEqual(CanvasLineHit.line(at: CGPoint(x: 300, y: 44), in: scene), CanvasLineID("l1"),
                        "4pt off the segment is inside the 6pt tolerance")
        XCTAssertNil(CanvasLineHit.line(at: CGPoint(x: 300, y: 50), in: scene),
                     "10pt off the segment is outside the 6pt tolerance")
    }

    func test_lineAtPointTakesTheNearestOfTwoOverlappingLines() {
        var scene = CanvasScene()
        // l1: a–b, distance from the probe point is 4.
        scene.insert(measuredNode("a", x: 0, y: 0))
        scene.insert(measuredNode("b", x: 400, y: 0))
        // l2: e–f, distance from the probe point is 2, but "l2" sorts after
        // "l1" so a first-found scan would answer l1 — the wrong, farther line.
        scene.insert(measuredNode("e", x: -20, y: 2))
        scene.insert(measuredNode("f", x: 380, y: 2))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))
        scene.insertLine(CanvasLine(id: CanvasLineID("l2"), from: CanvasNodeID("e"), to: CanvasNodeID("f")))

        let hit = CanvasLineHit.line(at: CGPoint(x: 300, y: 44), in: scene)
        XCTAssertEqual(hit, CanvasLineID("l2"),
                        "l1 is scanned first and is still within tolerance; a first-found implementation would return it instead of the nearer l2")
    }

    func test_lineAtPointIgnoresUnmeasuredLines() {
        var scene = CanvasScene()
        scene.insert(measuredNode("a", x: 0, y: 0))
        scene.insert(unmeasuredNode("b", x: 400, y: 0))
        scene.insertLine(CanvasLine(id: CanvasLineID("l1"), from: CanvasNodeID("a"), to: CanvasNodeID("b")))

        XCTAssertNil(CanvasLineHit.line(at: CGPoint(x: 300, y: 44), in: scene),
                     "a line whose ends have no frame is not drawn, and an invisible target is a click the writer cannot explain")
    }
}
