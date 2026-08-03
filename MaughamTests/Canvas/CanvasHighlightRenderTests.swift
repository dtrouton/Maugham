import XCTest
import SwiftUI
import AppKit
@testable import Maugham

/// §4's dim, drawn — and the arithmetic that keeps it a de-emphasis rather than
/// a disappearance.
///
/// **The trap this suite exists for is `CanvasMaterial.tetherOpacity`'s, one
/// slice on.** A dim meets four different starting alphas on this canvas, and a
/// dim applied as a MULTIPLIER takes the two quietest of them to nothing:
/// 0.30 × 0.22 is a tether at 0.066, and 0.07 × 0.22 is a region wash at 0.015.
/// Every test below either measures the pixels or plants that product beside the
/// real rule so the difference is on the record rather than in a comment.
final class CanvasHighlightRenderTests: XCTestCase {

    private let r1 = CanvasRegionID("r1")
    private let r2 = CanvasRegionID("r2")
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")

    private let viewSize = CGSize(width: 800, height: 600)

    /// Two regions, one card each, one bound to `ch1`. The card in the bound
    /// region is the LIT control on the same page as the dimmed one, so a build
    /// that dimmed everything — or nothing — fails on the same render.
    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 40, y: 60),
                            width: 240, cachedHeight: 100))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 440, y: 60),
                            width: 240, cachedHeight: 100))
        s.insertRegion(CanvasRegion(id: r1, label: "Lit",
                                    frame: CGRect(x: 20, y: 40, width: 300, height: 200)))
        s.insertRegion(CanvasRegion(id: r2, label: "Dim",
                                    frame: CGRect(x: 420, y: 40, width: 300, height: 200)))
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.join(b, home: r2, in: &s)
        RegionBinding.bind(r1, toPiece: "ch1", in: &s)
        RegionBinding.bind(r2, toPiece: "ch2", in: &s)
        return s
    }

    private func highlight(_ s: CanvasScene) -> CanvasHighlight {
        CanvasHighlight.resolve(subject: .piece("ch1"), in: s)
    }

    /// A point well inside a card, clear of its border, its resize corner and
    /// the region chrome above it.
    private let insideLitCard = CGPoint(x: 120, y: 120)
    private let insideDimCard = CGPoint(x: 520, y: 120)

    /// **The page's backing is the GROUND here, and the default will not do.**
    /// `renderCanvasPage` backs a page with `cardPaper` so the ink fixtures sit
    /// on the page they measure against — but a translucent white card over a
    /// white backing is a white pixel, so the dim would measure as almost
    /// nothing while being perfectly visible on a real canvas. A mid grey stands
    /// in for the ground the shader draws.
    private let ground = NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)

    // MARK: - The dim, on the page

    @MainActor
    func test_aDimmedCardRecedesAndALitOneIsUntouched() throws {
        let s = scene()
        let plain = try render(scene: s, size: viewSize, backing: ground)
        let filtered = try render(scene: s, size: viewSize, highlight: highlight(s),
                                  backing: ground)

        XCTAssertEqual(filtered.distance(to: plain, at: insideLitCard), 0, accuracy: 0,
                       "a LIT card must draw exactly as it does on an undimmed "
                       + "board — §4 dims everything else, it does not restyle "
                       + "what it lights")
        XCTAssertGreaterThan(filtered.distance(to: plain, at: insideDimCard), 0.10,
                             "the dimmed card's paper did not move — the dim never "
                             + "reached `drawCard`")
    }

    /// De-emphasis, not erasure. The card is still on the page and still
    /// distinguishable from bare ground, because it is still clickable.
    @MainActor
    func test_aDimmedCardIsStillDrawn() throws {
        let s = scene()
        let filtered = try render(scene: s, size: viewSize, highlight: highlight(s),
                                  backing: ground)
        let bareGround = CGPoint(x: 760, y: 560)
        XCTAssertGreaterThan(filtered.difference(between: insideDimCard, and: bareGround), 0.02,
                             "the dimmed card has vanished into the page — a writer "
                             + "cannot click what is not there, and a dimmed card "
                             + "stays clickable and selectable")
    }

    /// The selection ring is chrome about what the WRITER is doing, and it is
    /// never dimmed: a selection they cannot find is worse than no dim at all.
    @MainActor
    func test_aDimmedCardKeepsItsSelectionRingAtFullStrength() throws {
        let s = scene()
        let lit = try render(scene: s, size: viewSize, selection: .node(b), backing: ground)
        let dimmed = try render(scene: s, size: viewSize, selection: .node(b),
                                highlight: highlight(s), backing: ground)

        // **Measured against the ACCENT rather than pixel-for-pixel against the
        // undimmed page.** The ring straddles the card's edge, so its outer half
        // antialiases against the ground and its inner half against paper that
        // has legitimately changed — an exact comparison there measures the
        // paper, not the ring. And every card carries a seeded tilt, so the
        // edge is not on one column: this searches a band for the pixel that
        // came closest to the accent, which is the ring at its most fully
        // covered.
        var accent = SIMD3<Double>(0, 0, 0)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let c = CanvasMaterial.regionSelectedStroke.usingColorSpace(.sRGB)!
            accent = SIMD3(Double(c.redComponent), Double(c.greenComponent),
                           Double(c.blueComponent))
        }
        func distanceToAccent(_ page: CanvasPage) -> Double {
            var best = Double.greatestFiniteMagnitude
            for y in 105...135 {
                for x in 434...446 {
                    let d = page.color(at: CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) - accent
                    best = min(best, max(abs(d.x), max(abs(d.y), abs(d.z))))
                }
            }
            return best
        }

        XCTAssertLessThan(distanceToAccent(lit), 0.05, "the fixture drew no ring at all")
        XCTAssertLessThan(distanceToAccent(dimmed), 0.05,
                          "the selection ring dimmed with the card — the writer's "
                          + "own selection has to survive the filter, or a dimmed "
                          + "card cannot be worked with at all")
    }

    /// The scrap's WORDS, which are drawn by TextKit straight into the CG
    /// context and so are the one thing on this surface a SwiftUI-level opacity
    /// would silently miss.
    @MainActor
    func test_aDimmedCardsWordsDimWithIt() throws {
        var s = CanvasScene()
        let layout = ScrapLayout(text: "the fog came in over the falls and stayed",
                                 width: CanvasCardMetrics.textWidth(forCardWidth: 240),
                                 font: .systemFont(ofSize: 13),
                                 textColor: .black)
        var node = CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 40, y: 60), width: 240)
        node.cachedHeight = CanvasCardMetrics.cardHeight(forTextHeight: layout.measuredHeight)
        s.insert(node)
        let frame = try XCTUnwrap(node.frame)

        func inkedPixels(_ h: CanvasHighlight) throws -> Int {
            let page = try render(scene: s, size: viewSize, highlight: h, layouts: [a: layout])
            var count = 0
            for y in Int(frame.minY)..<Int(frame.maxY) {
                for x in Int(frame.minX)..<Int(frame.maxX) {
                    let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    // Anything meaningfully darker than the card's own paper.
                    if page.color(at: p).x < 0.6 { count += 1 }
                }
            }
            return count
        }

        let dimmedAll = CanvasHighlight.resolve(subject: .piece("nothing-bound"), in: s)
        let lit = try inkedPixels(.undimmed)
        let dim = try inkedPixels(dimmedAll)
        XCTAssertGreaterThan(lit, 50, "the fixture drew no text at all")
        XCTAssertLessThan(dim, lit / 2,
                          "the words did not dim with their card — ghosted paper "
                          + "with full-strength text on it, which reads as a card "
                          + "that has half faded rather than one that has receded. "
                          + "The text path is the one part of a card SwiftUI does "
                          + "not draw (`ScrapLayout.draw` goes through "
                          + "`withCGContext`), so it is the one an implementer can "
                          + "dim everything else and still miss")
    }

    /// The region half of §4 row two, on the page: a bound region draws as it
    /// did and an unbound one recedes.
    @MainActor
    func test_anUnboundRegionsOutlineRecedesAndTheBoundOnesDoesNot() throws {
        let s = scene()
        let plain = try render(scene: s, size: viewSize, backing: ground)
        let filtered = try render(scene: s, size: viewSize, highlight: highlight(s),
                                  backing: ground)
        // The regions' label rows, which carry the outline, the chrome bar and
        // the title — the parts of a region a writer actually reads.
        let litChrome = CGRect(x: 20, y: 40, width: 300, height: 24)
        let dimChrome = CGRect(x: 420, y: 40, width: 300, height: 24)
        XCTAssertEqual(filtered.differingPixels(from: plain, in: litChrome), 0,
                       "the BOUND region was dimmed — it is what the tree named")
        XCTAssertGreaterThan(filtered.differingPixels(from: plain, in: dimChrome), 50,
                             "the unbound region drew identically — the dim never "
                             + "reached `drawRegion`")
    }

    // MARK: - The four starting alphas
    //
    // Each of these is one product away from invisible, and the product is
    // planted beside the rule so a reader can see the difference rather than
    // take it on trust.

    func test_theDimIsAReplacementAndNotAProductAtEveryDosageItMeets() {
        let dim = CanvasMaterial.dimmedOpacity
        let dosages: [(String, CGFloat)] = [("card paper", 1),
                                            ("a chip", CanvasMaterial.chipOpacity),
                                            ("a tether", CanvasMaterial.tetherOpacity),
                                            ("a line", CanvasMaterial.lineOpacity),
                                            ("the promoted stripe",
                                             CanvasMaterial.promotedMarkOpacity)]
        for (what, lit) in dosages {
            XCTAssertEqual(CanvasMaterial.dimmedAlpha(lit: lit), dim, accuracy: 1e-9,
                           "\(what) is louder than the dim when lit, so the dim "
                           + "REPLACES its dosage")
        }

        // The planted counterfactual: what the lazy dim — one multiplied opacity
        // over everything — would have drawn instead. **Card paper is excluded
        // and that exclusion is the finding**: at a lit alpha of 1 the product
        // and the replacement are the same number, so a canvas judged on its
        // cards alone cannot tell the two implementations apart at all. Every
        // dosage that CAN tell them apart is quieter than the card.
        for (what, lit) in dosages where lit < 1 {
            XCTAssertGreaterThan(CanvasMaterial.dimmedAlpha(lit: lit), lit * dim,
                                 "\(what) at \(lit) × \(dim) is \(lit * dim) — the "
                                 + "shipped `0.35 × 0.30` bug wearing a different "
                                 + "number")
            XCTAssertLessThan(lit * dim, 0.17,
                              "the product for \(what) is no longer materially "
                              + "quieter than the replacement, so this plant has "
                              + "stopped demonstrating anything")
        }
    }

    /// The one dosage on this canvas that is already quieter than the dim. The
    /// `min` is what stops the dim RAISING it, and the answer is that a dimmed
    /// region keeps the area it draws while its outline, its title and its cards
    /// recede.
    func test_theRegionWashIsAlreadyQuieterThanTheDimAndIsLeftAlone() {
        for (name, wash) in [("light", CanvasMaterial.lightRegionWash),
                             ("dark", CanvasMaterial.darkRegionWash)] {
            XCTAssertLessThan(wash.alphaComponent, CanvasMaterial.dimmedOpacity,
                              "\(name): if the wash ever rises above the dim this "
                              + "test is the warning that the min starts biting")
            XCTAssertEqual(CanvasMaterial.dimmedAlpha(lit: wash.alphaComponent),
                           wash.alphaComponent, accuracy: 1e-9,
                           "\(name): a bare replacement would make the dimmed wash "
                           + "LOUDER than the lit one — the signal running backwards")
        }
        // …and the resolved pair says the same thing where the renderer reads it.
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: scheme)!.performAsCurrentDrawingAppearance {
                let lit = CanvasRenderer.regionWash.usingColorSpace(.sRGB)!
                let dim = CanvasRenderer.dimmedRegionWash.usingColorSpace(.sRGB)!
                XCTAssertEqual(dim.alphaComponent, lit.alphaComponent, accuracy: 1e-6)
                XCTAssertEqual(dim.redComponent, lit.redComponent, accuracy: 1e-6,
                               "the dimmed pair lost its per-appearance resolution")
            }
        }
    }

    /// The region OUTLINE does move, and by the replacement rather than by a
    /// product — the other half of the pair above, and the reason the pair is a
    /// pair rather than one value: light and dark carry different alphas.
    func test_theRegionStrokeIsReplacedInBothAppearances() {
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: scheme)!.performAsCurrentDrawingAppearance {
                let lit = CanvasRenderer.regionStroke.usingColorSpace(.sRGB)!
                let dim = CanvasRenderer.dimmedRegionStroke.usingColorSpace(.sRGB)!
                XCTAssertEqual(dim.alphaComponent, CanvasMaterial.dimmedOpacity, accuracy: 1e-6)
                XCTAssertLessThan(dim.alphaComponent, lit.alphaComponent)
                XCTAssertGreaterThan(dim.alphaComponent,
                                     lit.alphaComponent * CanvasMaterial.dimmedOpacity,
                                     "the planted product, resolved: this is what a "
                                     + "multiplied dim would have drawn")
            }
        }
    }

    /// `textInk` replaces a label colour's own alpha, and the replacement is
    /// only a replacement while the dim sits below those alphas. Measured off
    /// the system colours rather than assumed, because they are not ours.
    func test_theDimSitsBelowEverySystemLabelDosageItReplaces() {
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: scheme)!.performAsCurrentDrawingAppearance {
                for (name, color) in [("secondaryLabel", NSColor.secondaryLabelColor),
                                      ("tertiaryLabel", NSColor.tertiaryLabelColor)] {
                    let alpha = color.usingColorSpace(.sRGB)!.alphaComponent
                    XCTAssertGreaterThan(alpha, CanvasMaterial.dimmedOpacity,
                                         "\(name) has fallen below the dim, so "
                                         + "`textInk` now AMPLIFIES it when dimming")
                }
                // `separatorColor` is the other way round, and the card border
                // is deliberately left undimmed on the strength of it.
                XCTAssertLessThan(
                    NSColor.separatorColor.usingColorSpace(.sRGB)!.alphaComponent,
                    CanvasMaterial.dimmedOpacity,
                    "the card border is no longer quieter than the dim — "
                    + "`drawCard` leaves it alone on exactly this measurement")
            }
        }
    }

}
