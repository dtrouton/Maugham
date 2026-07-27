import XCTest
import SwiftUI
@testable import Maugham

/// Regions, drawn: the wash beneath the cards, the tethers §4.2 accepts as the
/// cost of free positioning, and the reference chips §4.3 requires so that "an
/// appearance must not render identically to the thing itself".
final class CanvasRegionRenderTests: XCTestCase {

    private let r1 = CanvasRegionID("r1")
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        s.insert(CanvasNode(id: a, kind: .scrap, origin: CGPoint(x: 50, y: 50),
                            width: 240, cachedHeight: 80))
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 900, y: 50),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                    frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        return s
    }

    // MARK: - Culling

    func test_visibleRegionsAreCulledToTheViewport() {
        var s = scene()
        s.insertRegion(CanvasRegion(id: CanvasRegionID("far"), label: "Far",
                                    frame: CGRect(x: 90_000, y: 0, width: 100, height: 100)))
        XCTAssertEqual(CanvasRenderer.visibleRegions(in: s, camera: CanvasCamera(),
                                                     viewSize: CGSize(width: 800, height: 600))
                        .map(\.id),
                       [r1],
                       "and note the far region is genuinely in the scene, so an "
                       + "implementation that returned everything would fail here")
    }

    // MARK: - Tethers (§4.2's accepted cost, paid)

    func test_aResidentOutsideItsRegionGetsATetherToIt() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.move(a, to: CGPoint(x: 5_000, y: 5_000))
        let tethers = CanvasRenderer.tethers(in: s)
        XCTAssertEqual(tethers.map(\.node), [a])
        XCTAssertEqual(tethers.first?.from, CGPoint(x: 5_120, y: 5_040),
                       "anchored on the card's MIDPOINT, which cardTransform maps "
                       + "to itself at any tilt")
        XCTAssertEqual(tethers.first?.to, CGPoint(x: 300, y: 200))
    }

    func test_aResidentInsideItsRegionGetsNoTether() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        XCTAssertTrue(CanvasRenderer.tethers(in: s).isEmpty)
    }

    /// A card straddling the boundary is still visibly IN the region. Tethering
    /// on non-containment would fire a line to the centre for one pixel of
    /// overhang — the same one-pixel absurdity the design cites against
    /// Obsidian, inverted. Tether only when the frames do not meet at all.
    func test_aResidentStraddlingTheEdgeGetsNoTether() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.move(a, to: CGPoint(x: 599, y: 100))
        XCTAssertTrue(CanvasRenderer.tethers(in: s).isEmpty)
    }

    func test_aVisitorOutsideARegionGetsNoTether() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        XCTAssertTrue(CanvasRenderer.tethers(in: s).isEmpty,
                      "a visitor is not owned, so there is no 'it moves with that' "
                      + "relationship for a tether to explain")
    }

    func test_aCollapsedRegionTethersNothing() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.move(a, to: CGPoint(x: 5_000, y: 5_000))
        s.updateRegion(r1) { $0.isCollapsed = true }
        XCTAssertTrue(CanvasRenderer.tethers(in: s).isEmpty,
                      "the resident is not drawn, so a line to it lands on nothing")
    }

    // MARK: - Appearance chips (§4.3)

    func test_aVisitorGetsAChipInsideTheRegionAndKeepsItsOwnCard() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        let chips = CanvasRenderer.appearanceChips(in: s)
        XCTAssertEqual(chips.map(\.node), [b])
        XCTAssertTrue(s.region(r1)!.frame.contains(chips[0].frame))
        XCTAssertLessThan(chips[0].frame.height, s.node(b)!.frame!.height,
                          "§4.3: an appearance must not render identically to the "
                          + "thing itself")
        XCTAssertEqual(CanvasRenderer.visibleNodes(in: s, camera: CanvasCamera(),
                                                   viewSize: CGSize(width: 2_000, height: 2_000))
                        .map(\.id).sorted { $0.raw < $1.raw },
                       [a, b],
                       "the real card is still drawn where it actually is — a chip "
                       + "is a reference, never a copy")
    }

    func test_aChipsHairlineRunsToTheRealCard() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        let chip = CanvasRenderer.appearanceChips(in: s)[0]
        XCTAssertEqual(chip.homeAnchor, CGPoint(x: 1_020, y: 90),
                       "the midpoint of b's own card — 'where is the real one'")
    }

    func test_chipsStackRatherThanOverlapping() {
        var s = scene()
        s.insert(CanvasNode(id: CanvasNodeID("c"), kind: .scrap,
                            origin: CGPoint(x: 900, y: 400), width: 240, cachedHeight: 80))
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        CanvasMembership.addAppearance(CanvasNodeID("c"), to: r1, in: &s)
        let chips = CanvasRenderer.appearanceChips(in: s)
        XCTAssertEqual(chips.count, 2)
        XCTAssertFalse(chips[0].frame.intersects(chips[1].frame))
    }

    func test_aChipCarriesTheFirstLineOfTheScrapItStandsFor() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        let title = CanvasRenderer.chipTitle(for: b, in: s,
                                             scraps: [b: "the falls at night\nand the lit bridge"])
        XCTAssertEqual(title, "the falls at night")
        XCTAssertEqual(CanvasRenderer.chipTitle(for: b, in: s, scraps: [:]),
                       CanvasAccessibility.emptyScrapValue,
                       "a blank chip is indistinguishable from a rendering bug")
    }

    // MARK: - Collapse

    func test_aCollapsedRegionSaysHowManyCardsItIsHiding() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        s.updateRegion(r1) { $0.isCollapsed = true }
        XCTAssertEqual(CanvasRenderer.collapsedSummary(for: r1, in: s), "1 card")
        s.insert(CanvasNode(id: CanvasNodeID("c"), kind: .scrap, origin: .zero,
                            width: 240, cachedHeight: 80))
        CanvasMembership.join(CanvasNodeID("c"), home: r1, in: &s)
        XCTAssertEqual(CanvasRenderer.collapsedSummary(for: r1, in: s), "2 cards")
    }

    // MARK: - The draw pass, rasterised

    /// **A region must never occlude the cards it holds.** Asserted by drawing
    /// and reading pixels rather than by comparing two layer-depth constants to
    /// each other, which is a test that cannot fail for the reason it exists.
    ///
    /// **It compares the card against ITSELF WITHOUT the region, not against the
    /// washed ground beside it**, and the difference is not stylistic. The brief
    /// asked for the second, and drawing the region pass *after* the card pass —
    /// the exact defect this test names — leaves it GREEN: at the card's centre
    /// the wash-over-paper and the wash-over-backing composites agree in two
    /// channels and differ by ONE 8-bit level in the third, so `XCTAssertNotEqual`
    /// passes on quantisation noise. Measured 2026-07-27 under that mutation:
    /// card centre 0.9686/0.9686/0.9608 against bare 0.9686/0.9647/0.9608.
    /// Comparing the card to an unwashed render of the same card is exact, needs
    /// no threshold, and goes red the moment anything paints over the card.
    @MainActor
    func test_aRegionDoesNotPaintOverTheCardsInsideIt() throws {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        var cardsOnly = s
        cardsOnly.removeRegion(r1)

        let size = CGSize(width: 700, height: 500)
        let withRegion = try render(scene: s, size: size)
        let withoutRegion = try render(scene: cardsOnly, size: size)
        let centre = CGPoint(x: 170, y: 90)

        XCTAssertEqual(withRegion.color(at: centre), withoutRegion.color(at: centre),
                       "the card's paper must survive at its own centre UNCHANGED — "
                       + "a region is where the cards are, not a panel over them")
        XCTAssertEqual(withRegion.color(at: centre),
                       withRegion.color(at: CGPoint(x: 170, y: 95)),
                       "sanity: the sample is inside a flat area of the card")
        XCTAssertNotEqual(withRegion.color(at: centre),
                          withRegion.color(at: CGPoint(x: 450, y: 300)),
                          "control: the region really is washing the ground beside "
                          + "the card, so the equality above is not two blank pages")
    }

    /// §4: a region is *where the cards are*, not a panel they sit on. The wash
    /// has to be visible at all, and has to stay under the dosage at which the
    /// region becomes the object and the cards its decoration.
    @MainActor
    func test_theRegionWashIsFeltRatherThanSeen() throws {
        let plain = try render(scene: CanvasScene(), size: CGSize(width: 700, height: 500))
        let washed = try render(scene: scene(), size: CGSize(width: 700, height: 500))
        let bare = CGPoint(x: 450, y: 300)
        XCTAssertNotEqual(plain.color(at: bare), washed.color(at: bare),
                          "the region has to be visible at all")
        XCTAssertLessThan(plain.distance(to: washed, at: bare), CanvasMaterial.regionWashCeiling,
                          "and it must not read as a filled panel — the cards are "
                          + "the objects; the region is where they are")
    }

    /// **Step 8 of the brief: the same measurement in the OTHER appearance.**
    ///
    /// 1C-a shipped a flat-black dark canvas with the whole suite green, because
    /// every raster fixture pinned light. The wash is a pair of constants and
    /// dark's is the one nothing else here would look at.
    ///
    /// Measured 2026-07-27 at 700×500 scale 1, against a page backed with
    /// `CanvasMaterial.darkBase` — the ground the wash actually lands on:
    /// dark moves a bare pixel **0.0588** of full scale in its strongest
    /// channel (15 of 255: 0.094/0.102/0.114 → 0.153/0.149/0.145), where light
    /// moves **0.0392** (10 of 255: 1.000 → 0.969/0.965/0.961). Both clear the
    /// floor by a factor of seven and both sit comfortably under the 0.10
    /// ceiling. The floor is 0.008, which is two 8-bit levels: below that the
    /// "wash" is quantisation.
    ///
    /// **What this test cannot see, and what does:** collapsing the pair —
    /// giving dark the light wash — still moves 0.032 here and would pass. That
    /// tidy-up is `CanvasGroundTests.test_theTwoAppearancesAreCalibratedSeparately`'s
    /// job, and it now covers the region pair too. This one owns "the wash the
    /// dark appearance actually resolves is visible on the dark ground, is not a
    /// panel, and lifts it rather than sinking it".
    @MainActor
    func test_theDarkRegionWashClearsTheDarkGroundWithoutBecomingAPanel() throws {
        let size = CGSize(width: 700, height: 500)
        let bare = CGPoint(x: 450, y: 300)
        let plain = try render(scene: CanvasScene(), size: size,
                               scheme: .dark, backing: CanvasMaterial.darkBase)
        let washed = try render(scene: scene(), size: size,
                                scheme: .dark, backing: CanvasMaterial.darkBase)
        let moved = plain.distance(to: washed, at: bare)

        XCTAssertGreaterThan(moved, 0.008,
                             "the dark region wash moves a bare pixel by \(moved) of "
                             + "full scale — under two 8-bit levels, i.e. a region a "
                             + "writer cannot see on the dark ground. Raise "
                             + "CanvasMaterial.darkRegionWash's alpha.")
        XCTAssertLessThan(moved, CanvasMaterial.regionWashCeiling,
                          "the dark region wash moves a bare pixel by \(moved), over "
                          + "the felt-not-seen ceiling of "
                          + "\(CanvasMaterial.regionWashCeiling) — it reads as a "
                          + "filled panel and the cards stop being the objects")

        // §7.2's rule, applied to the region: a wash that DARKENED the slate
        // would read as a hole cut in the ground rather than as an area of it,
        // which is the same failure `darkCardPaper` exists to prevent.
        XCTAssertGreaterThan(washed.color(at: bare).x, plain.color(at: bare).x,
                             "the dark region wash sinks the ground instead of "
                             + "lifting it — a region reads as a hole, not an area")
    }

    /// Selection is drawn, not merely modelled. This samples the region's own
    /// left edge, where the outline is the only thing on the page.
    @MainActor
    func test_theSelectedRegionIsDrawnDifferentlyFromAnUnselectedOne() throws {
        let s = scene()
        let unselected = try render(scene: s, size: CGSize(width: 700, height: 500))
        let selected = try render(scene: s, size: CGSize(width: 700, height: 500),
                                  selection: .region(r1))
        let onTheStroke = CGPoint(x: 0.5, y: 200)
        XCTAssertNotEqual(unselected.color(at: onTheStroke), selected.color(at: onTheStroke))
    }

    // MARK: - Rasterisation helper

    /// Mirrors `CanvasRendererTests`' own `Page` — same bitmap layout, same
    /// byte order, same reasoning — with the two readers this task needs added:
    /// a whole-colour probe and a per-channel distance. It reads COLOUR rather
    /// than ink, because a region wash is not a glyph and the "is this darker
    /// than paper by 100 levels" question those fixtures ask cannot see it.
    private struct Page {
        let bytes: [UInt8]
        let bytesPerRow: Int
        let width: Int
        let height: Int

        /// R, G, B at `point`, in 0–1.
        ///
        /// The context is `premultipliedFirst` with the default byte order, so
        /// the bytes run **A, R, G, B** — measured in `CanvasRendererTests` by
        /// filling a known colour and reading the four bytes back, not inferred.
        /// A point outside the page returns a sentinel that no rendered pixel
        /// can equal, so an off-page read can never pass an equality assertion
        /// by accident.
        func color(at point: CGPoint) -> SIMD3<Double> {
            let x = Int(point.x), y = Int(point.y)
            guard (0..<width).contains(x), (0..<height).contains(y) else {
                return SIMD3<Double>(-1, -1, -1)
            }
            let o = y * bytesPerRow + x * 4
            return SIMD3<Double>(Double(bytes[o + 1]) / 255,
                                 Double(bytes[o + 2]) / 255,
                                 Double(bytes[o + 3]) / 255)
        }

        /// The largest per-channel difference at `point`, in 0–1.
        func distance(to other: Page, at point: CGPoint) -> Double {
            let d = color(at: point) - other.color(at: point)
            return max(abs(d.x), max(abs(d.y), abs(d.z)))
        }
    }

    @MainActor
    private func render(scene: CanvasScene,
                        size: CGSize,
                        selection: CanvasSelection? = nil,
                        scraps: [CanvasNodeID: String] = [:],
                        scheme: ColorScheme = .light,
                        backing: NSColor? = nil) throws -> Page {
        try Self.render(size: size, scheme: scheme, backing: backing) { cx in
            CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: size,
                                layouts: [:], scraps: scraps, selection: selection,
                                visibleEditorNodeID: nil,
                                straighten: CanvasFocusStraighten(), into: &cx)
        }
    }

    /// Render a `Canvas` draw closure at scale 1 and read its pixels.
    ///
    /// The colour scheme is pinned rather than inherited, for the same reason
    /// `CanvasRendererTests` pins its own: this test process runs under
    /// DarkAqua, so an unpinned dynamic `NSColor` would resolve dark inside a
    /// light render. The BACKING is resolved under the matching appearance for
    /// the same reason — and it defaults to the card paper so the light
    /// fixtures sit on exactly the page `CanvasRendererTests` measures against.
    @MainActor
    private static func render(size: CGSize,
                               scheme: ColorScheme,
                               backing: NSColor?,
                               _ draw: @escaping (inout GraphicsContext) -> Void) throws -> Page {
        let renderer = ImageRenderer(
            content: Canvas { cx, _ in draw(&cx) }
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")

        let w = image.width, h = image.height
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        var backingColor: CGColor?
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
            .performAsCurrentDrawingAppearance {
                backingColor = (backing ?? CanvasRenderer.cardPaper)
                    .usingColorSpace(.sRGB)?.cgColor
            }
        ctx.setFillColor(try XCTUnwrap(backingColor, "could not resolve the page backing"))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let count = ctx.bytesPerRow * h
        // Row 0 of a CGBitmapContext's buffer is the TOP row of the drawn image,
        // so buffer row == point y — verified in `CanvasRendererTests` against a
        // GraphicsContext fill at y = 0.
        let bytes = Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self,
                                                                         capacity: count),
                                              count: count))
        return Page(bytes: bytes, bytesPerRow: ctx.bytesPerRow, width: w, height: h)
    }
}
