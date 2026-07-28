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

    /// `omittingEmptySubsequences` drops `""` but not `"   "`, so taking the
    /// first line and *then* trimming makes a scrap that opens with an indented
    /// blank line announce itself as empty while carrying text.
    func test_aChipSkipsALeadingBlankLineRatherThanCallingTheScrapEmpty() {
        var s = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        XCTAssertEqual(CanvasRenderer.chipTitle(for: b, in: s,
                                                scraps: [b: "   \n\t\nthe falls at night"]),
                       "the falls at night")
    }

    /// A chip is clamped on the vertical axis and was not on the horizontal one.
    /// `chipWidth` is 150 and `CanvasRegionMetrics.minimumSide` is 80, so a
    /// region at its own minimum got a chip hanging 80 pt outside it — over bare
    /// ground and over whatever cards happened to be there, which is exactly
    /// what the vertical guard exists to prevent.
    func test_aChipNeverHangsOutsideANarrowRegion() {
        let side = CanvasRegionMetrics.minimumSide
        var s = CanvasScene()
        s.insert(CanvasNode(id: b, kind: .scrap, origin: CGPoint(x: 900, y: 50),
                            width: 240, cachedHeight: 80))
        s.insertRegion(CanvasRegion(id: r1, label: "Tight",
                                    frame: CGRect(x: 0, y: 0, width: side, height: side)))
        CanvasMembership.addAppearance(b, to: r1, in: &s)

        let chips = CanvasRenderer.appearanceChips(in: s)
        XCTAssertEqual(chips.count, 1, "a region at its minimum still shows its visitors")
        XCTAssertTrue(s.region(r1)!.frame.contains(chips[0].frame),
                      "the chip is \(chips[0].frame) in a region of \(s.region(r1)!.frame)")
        XCTAssertGreaterThan(CanvasRenderer.chipWidth, side,
                             "control: the unclamped width really is wider than this "
                             + "region, so the containment above is not free")
    }

    /// The argument `tethers` already makes — "the resident is not drawn, so a
    /// line to it lands on nothing" — applied to chips, where it was missing.
    ///
    /// Reachable rather than theoretical: `join` forgets a node only in regions
    /// where it *lives*, so a node can be an appearance in an expanded region and
    /// a resident of a collapsed one at the same time.
    func test_aNodeHiddenByAnotherRegionsCollapseGetsNoChip() {
        let r2 = CanvasRegionID("r2")
        var s = scene()
        s.insertRegion(CanvasRegion(id: r2, label: "Cut",
                                    frame: CGRect(x: 800, y: 0, width: 400, height: 300)))
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        CanvasMembership.join(b, home: r2, in: &s)
        XCTAssertTrue(s.region(r1)!.appearsHere(b),
                      "control: joining another region as HOME must leave the "
                      + "appearance in place, or this fixture proves nothing")

        XCTAssertEqual(CanvasRenderer.appearanceChips(in: s).map(\.node), [b],
                       "control: while r2 is expanded the chip is there")
        s.updateRegion(r2) { $0.isCollapsed = true }
        XCTAssertTrue(s.isHidden(b))
        XCTAssertTrue(CanvasRenderer.appearanceChips(in: s).isEmpty,
                      "b's card is not drawn, so its chip's hairline would run to "
                      + "bare ground")
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
    ///
    /// **Backed with `lightBase`, not with the card paper.** This is a test about
    /// what the wash does to the GROUND, and the ground is 0.930, not 1.000 —
    /// measuring against white reported 0.039 where the writer's canvas gives
    /// 0.031. The default backing is right for the occlusion test above, which
    /// compares a card to itself, and wrong here.
    ///
    /// The FLOOR is the half that was missing. `XCTAssertNotEqual` alone accepts
    /// one 8-bit level as "visible", so a wash faded almost to nothing passed a
    /// test whose message says it is about visibility.
    @MainActor
    func test_theRegionWashIsFeltRatherThanSeen() throws {
        let size = CGSize(width: 700, height: 500)
        let plain = try render(scene: CanvasScene(), size: size,
                               backing: CanvasMaterial.lightBase)
        let washed = try render(scene: scene(), size: size,
                                backing: CanvasMaterial.lightBase)
        let bare = CGPoint(x: 450, y: 300)
        let moved = plain.distance(to: washed, at: bare)

        XCTAssertGreaterThan(moved, CanvasMaterial.lightRegionWashFloor,
                             "the light region wash moves a bare pixel by \(moved) of "
                             + "full scale, under the floor of "
                             + "\(CanvasMaterial.lightRegionWashFloor) — a region the "
                             + "writer cannot see. Raise CanvasMaterial."
                             + "lightRegionWash's alpha, or lower the floor with it.")
        XCTAssertLessThan(moved, CanvasMaterial.regionWashCeiling,
                          "the light region wash moves a bare pixel by \(moved), over "
                          + "the felt-not-seen ceiling — it reads as a filled panel "
                          + "and the cards stop being the objects")
    }

    /// **Step 8 of the brief: the same measurement in the OTHER appearance.**
    ///
    /// 1C-a shipped a flat-black dark canvas with the whole suite green, because
    /// every raster fixture pinned light. The wash is a pair of constants and
    /// dark's is the one nothing else here would look at.
    ///
    /// Measured 2026-07-28 at 700×500 scale 1, against a page backed with
    /// `CanvasMaterial.darkBase` — the ground the wash actually lands on: dark
    /// moves a bare pixel **0.0588** of full scale in its strongest channel
    /// (15 of 255: 0.094/0.102/0.114 → 0.153/0.149/0.145), where light over its
    /// own ground moves **0.031**.
    ///
    /// **`darkRegionWashFloor` is 0.045, and that number is chosen, not
    /// rounded.** The LIGHT wash over this same dark ground moves 0.032 — so a
    /// floor anywhere between 0.032 and 0.059 makes this test fail when the pair
    /// is collapsed and dark is drawn with light-mode values. Without it the
    /// test passes at 0.032 (above any quantisation floor, under the ceiling,
    /// still lifting), which is 1C-a's failure mode exactly: a green suite over
    /// a dark surface drawn light.
    @MainActor
    func test_theDarkRegionWashClearsTheDarkGroundWithoutBecomingAPanel() throws {
        let size = CGSize(width: 700, height: 500)
        let bare = CGPoint(x: 450, y: 300)
        let plain = try render(scene: CanvasScene(), size: size,
                               scheme: .dark, backing: CanvasMaterial.darkBase)
        let washed = try render(scene: scene(), size: size,
                                scheme: .dark, backing: CanvasMaterial.darkBase)
        let moved = plain.distance(to: washed, at: bare)

        XCTAssertGreaterThan(moved, CanvasMaterial.darkRegionWashFloor,
                             "the dark region wash moves a bare pixel by \(moved) of "
                             + "full scale, under the floor of "
                             + "\(CanvasMaterial.darkRegionWashFloor). Either the wash "
                             + "is too faint to see on the dark ground, or the dark "
                             + "appearance is resolving the LIGHT constant — which "
                             + "measures 0.032 here and is what this floor is set to "
                             + "catch.")
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

    /// The structural half of the same guard, and the one that survives a
    /// recalibration.
    ///
    /// The floor above catches "dark resolves the light constant" only because
    /// of where today's two dosages happen to sit; move either and the floor may
    /// stop separating them. This asks the question directly — render the SAME
    /// scene over the SAME backing under each appearance, and require the two to
    /// differ by more than quantisation. Collapse the pair to one colour and the
    /// two renders become byte-identical.
    ///
    /// It also covers the light side, where a floor cannot: the dark wash over
    /// the LIGHT ground moves 0.036, *more* than light's own 0.031, so no floor
    /// separates them and a ceiling tight enough to would freeze a constant the
    /// writer tunes by eye.
    ///
    /// Measured 2026-07-28 over `darkBase`: light 0.126/0.132/0.138, dark
    /// 0.153/0.149/0.145 — a 0.027 gap, seven 8-bit levels.
    @MainActor
    func test_theTwoAppearancesRenderDifferentWashes() throws {
        let size = CGSize(width: 700, height: 500)
        let bare = CGPoint(x: 450, y: 300)
        let asLight = try render(scene: scene(), size: size,
                                 scheme: .light, backing: CanvasMaterial.darkBase)
        let asDark = try render(scene: scene(), size: size,
                                scheme: .dark, backing: CanvasMaterial.darkBase)
        let gap = asLight.distance(to: asDark, at: bare)
        XCTAssertGreaterThan(gap, 0.008,
                             "the two appearances render the region wash within "
                             + "\(gap) of each other — under two 8-bit levels, i.e. "
                             + "CanvasRenderer.regionWash is not resolving per "
                             + "appearance and one material is being drawn on both. "
                             + "§7.1: light and dark are two materials, not one "
                             + "texture inverted.")
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

    // MARK: - Drawn output, rasterised
    //
    // Every one of these exists because the first round of this task pinned
    // tethers, chips, the label, the resize mark and the collapsed summary at
    // the GEOMETRY level only. Deleting the two loops at the foot of
    // `CanvasRenderer.draw` left the whole suite green: no raster fixture had a
    // resident outside its region, an appearance anywhere, or a collapsed
    // region at all, so `tethers` and `appearanceChips` returned `[]` in every
    // rendered scene. A structure that computes the right rectangle and draws
    // nothing in it is the failure these close.
    //
    // They compare two renders differing in exactly ONE model fact and count
    // pixels that changed. That is exact, needs no colour threshold, and cannot
    // be satisfied by antialiasing — the control regions assert *zero* changed
    // pixels where nothing should have moved.

    /// §4.2's relationship, actually drawn. The two scenes differ only in
    /// whether `a` is a member of `r1`; every pixel that changes is tether.
    @MainActor
    func test_aTetherIsActuallyDrawnBetweenTheCardAndTheRegion() throws {
        let size = CGSize(width: 900, height: 500)
        var tethered = scene()
        tethered.move(a, to: CGPoint(x: 620, y: 300))          // clear of the region
        CanvasMembership.join(a, home: r1, in: &tethered)
        var loose = tethered
        CanvasMembership.leave(a, from: r1, in: &loose)

        XCTAssertEqual(CanvasRenderer.tethers(in: tethered).count, 1)
        XCTAssertTrue(CanvasRenderer.tethers(in: loose).isEmpty,
                      "control: the two fixtures must differ in exactly the tether")

        let withLine = try render(scene: tethered, size: size)
        let without = try render(scene: loose, size: size)

        // The segment runs (740, 340) → (300, 200). This window is the strip
        // between the region's right edge and the card's left one, so it is
        // bare ground in both renders and anything in it is the line itself.
        let onTheRun = CGRect(x: 601, y: 292, width: 18, height: 15)
        XCTAssertGreaterThan(withLine.differingPixels(from: without, in: onTheRun), 0,
                             "no ink appeared between the card and the region — the "
                             + "tether is computed and never drawn")
        XCTAssertGreaterThan(withLine.differingPixels(from: without,
                                                      in: CGRect(origin: .zero, size: size)),
                             100,
                             "a handful of pixels changed over the whole page: that is "
                             + "a speck, not a line four hundred points long")
        XCTAssertEqual(withLine.differingPixels(from: without,
                                                in: CGRect(x: 100, y: 420,
                                                           width: 100, height: 60)),
                       0,
                       "control: pixels changed far from the segment, so the count "
                       + "above is not measuring the whole page shifting")
    }

    /// §4.3's reference, actually drawn — and actually carrying the title, which
    /// is the half a rectangle-shaped assertion cannot see.
    @MainActor
    func test_aChipIsActuallyDrawnInsideTheRegionAndCarriesItsTitle() throws {
        let size = CGSize(width: 700, height: 500)
        var visited = scene()
        CanvasMembership.addAppearance(b, to: r1, in: &visited)
        let chip = try XCTUnwrap(CanvasRenderer.appearanceChips(in: visited).first)

        let withChip = try render(scene: visited, size: size)
        let without = try render(scene: scene(), size: size)
        XCTAssertGreaterThan(withChip.differingPixels(from: without, in: chip.frame), 500,
                             "the chip's own rectangle is unchanged by adding the "
                             + "appearance — appearanceChips computes a frame nothing "
                             + "draws into")

        // …and the pill is not blank. Two different titles in the same chip.
        let named = try render(scene: visited, size: size,
                               scraps: [b: "the falls at night"])
        XCTAssertGreaterThan(named.differingPixels(from: withChip, in: chip.frame), 0,
                             "the chip renders identically whatever the scrap says — "
                             + "drawChip is ignoring its title, so every reference "
                             + "reads as the same blank pill")
    }

    /// A collapsed region is the one state no raster fixture covered, and it is
    /// the state with the most drawn chrome of its own.
    @MainActor
    func test_aCollapsedRegionDrawsItsSummaryInItsChromeBar() throws {
        let size = CGSize(width: 700, height: 500)
        var expanded = scene()
        expanded.move(a, to: CGPoint(x: 50, y: 200))          // clear of the chrome bar
        CanvasMembership.join(a, home: r1, in: &expanded)
        var collapsed = expanded
        collapsed.updateRegion(r1) { $0.isCollapsed = true }

        let open = try render(scene: expanded, size: size)
        let shut = try render(scene: collapsed, size: size)
        let chrome = CanvasRegionMetrics.chromeRect(in: expanded.region(r1)!.frame)

        // The drawn label is `displayLabel` in both, so the ONLY thing that can
        // change inside the chrome bar is the summary.
        XCTAssertGreaterThan(shut.differingPixels(from: open, in: chrome), 0,
                             "nothing changed in the chrome bar when the region "
                             + "collapsed — collapsedSummary is computed and never "
                             + "drawn, so a collapsed region reads as an empty one")
        XCTAssertGreaterThan(shut.differingPixels(from: open,
                                                  in: CGRect(x: 0, y: 150,
                                                             width: 600, height: 150)),
                             0,
                             "control: the resident did not disappear, so this "
                             + "fixture is not comparing a region to itself")
    }

    /// The label is a region's whole identity. Two scenes differing only in the
    /// text of it.
    @MainActor
    func test_theRegionLabelIsActuallyDrawn() throws {
        let size = CGSize(width: 700, height: 500)
        var renamed = scene()
        renamed.updateRegion(r1) { $0.label = "Zzzzzzzzzzzzz" }
        let first = try render(scene: scene(), size: size)
        let second = try render(scene: renamed, size: size)
        let chrome = CanvasRegionMetrics.chromeRect(in: scene().region(r1)!.frame)
        XCTAssertGreaterThan(second.differingPixels(from: first, in: chrome), 0,
                             "the region's label renders identically whatever it says "
                             + "— it is not being drawn at all, and every region on "
                             + "the canvas is an unnamed rectangle")
    }

    /// The resize mark is the affordance Task 5 hit-tests. A target with no mark
    /// is a target the writer cannot find.
    @MainActor
    func test_theRegionResizeMarkIsActuallyDrawn() throws {
        let page = try render(scene: scene(), size: CGSize(width: 700, height: 500),
                              backing: CanvasMaterial.lightBase)
        let corner = CanvasRegionMetrics.resizeHandleRect(in: scene().region(r1)!.frame)
        // Below the hypotenuse of the corner square, where the triangle is inked.
        let onTheMark = CGPoint(x: corner.maxX - 4, y: corner.maxY - 4)
        let bareWash = CGPoint(x: 500, y: corner.maxY - 4)
        XCTAssertGreaterThan(page.difference(between: onTheMark, and: bareWash), 0.05,
                             "the region's bottom-right corner is indistinguishable "
                             + "from the wash beside it — the resize mark is not drawn")
    }

    // MARK: - The sweep, drawn
    //
    // The rubber band under the pointer while a region is being drawn. It is the
    // one thing the renderer draws that is not in the scene, so these are the
    // only fixtures here whose two renders differ in something other than a
    // model fact — they differ in exactly one ARGUMENT, which is the same
    // discipline.
    //
    // A gesture with no feedback is not a gesture: with nothing drawn there is
    // no way for the writer to tell a drag that is sweeping out a region from a
    // drag that is doing nothing at all.

    /// Ink appears along the swept rectangle's edge, and nowhere else.
    @MainActor
    func test_theSweptRectIsDrawnWhileTheWriterIsSweepingIt() throws {
        let size = CGSize(width: 900, height: 500)
        // Clear of the fixture's region (0,0)–(600,400) and of both cards, so
        // every pixel that changes is the sweep itself.
        let swept = CGRect(x: 650, y: 200, width: 200, height: 150)

        let during = try render(scene: scene(), size: size, sweep: swept)
        let before = try render(scene: scene(), size: size)

        let topEdge = CGRect(x: swept.minX + 20, y: swept.minY - 2,
                             width: swept.width - 40, height: 4)
        XCTAssertGreaterThan(during.differingPixels(from: before, in: topEdge), 0,
                             "nothing is drawn along the rectangle the writer is "
                             + "sweeping out — the gesture computes a rect and shows "
                             + "no sign of it, so a drag that is drawing a region and "
                             + "a drag that is doing nothing look identical")
        XCTAssertGreaterThan(during.differingPixels(from: before,
                                                    in: CGRect(origin: .zero, size: size)),
                             300,
                             "a handful of pixels changed over the whole page: that is "
                             + "a speck, not an outline seven hundred points around")
        XCTAssertEqual(during.differingPixels(from: before,
                                              in: CGRect(x: 660, y: 250, width: 180, height: 90)),
                       0,
                       "control: pixels changed INSIDE the swept rectangle. It is an "
                       + "outline, not a fill — a wash would say the area is already "
                       + "claimed, and this rect is the interior with the stroke "
                       + "excluded on all four sides")
        XCTAssertEqual(during.differingPixels(from: before,
                                              in: CGRect(x: 0, y: 420, width: 200, height: 60)),
                       0,
                       "control: pixels changed far from the sweep, so the count above "
                       + "is not measuring the whole page shifting")
    }

    /// **Dashed, not solid**, because nothing has been made yet — a solid
    /// outline is what a region has once it exists.
    ///
    /// Read along a one-pixel strip inside the top edge, clear of both rounded
    /// corners. A solid line inks every column of it; a dash pattern of 6 on and
    /// 4 off inks about six in ten. Both bounds are load-bearing: without the
    /// upper one a solid outline passes, and without the lower one an outline
    /// that vanished passes.
    @MainActor
    func test_theSweepIsDashedRatherThanSolid() throws {
        let size = CGSize(width: 900, height: 500)
        let swept = CGRect(x: 650, y: 200, width: 200, height: 150)
        let during = try render(scene: scene(), size: size, sweep: swept)
        let before = try render(scene: scene(), size: size)

        let run = CGRect(x: swept.minX + 20, y: swept.minY, width: swept.width - 40, height: 1)
        let inked = during.differingPixels(from: before, in: run)
        XCTAssertGreaterThan(inked, Int(run.width * 0.25),
                             "\(inked) of \(Int(run.width)) columns along the top edge "
                             + "carry ink — that is not a line at all")
        XCTAssertLessThan(inked, Int(run.width * 0.9),
                          "\(inked) of \(Int(run.width)) columns are inked, i.e. the "
                          + "sweep is a SOLID outline. A solid rectangle is what a "
                          + "region looks like once it exists, so a sweep drawn that "
                          + "way shows the writer a region that is not there yet")
    }

    /// **Above everything**, including the cards it is dragged across.
    ///
    /// A sweep can only START on bare canvas, but it is then dragged freely over
    /// whatever is there — so passing over cards is the ordinary case. Drawn
    /// under them, the outline is chewed into pieces by every card it crosses
    /// and reads as being *behind* the canvas.
    ///
    /// The sample point is on the sweep's top edge where it crosses the middle
    /// of card `a` at (50,50)–(290,130): under the cards, that pixel is card
    /// paper in both renders and nothing changes there at all.
    @MainActor
    func test_theSweepIsDrawnOverTheCardsItIsDraggedAcross() throws {
        let size = CGSize(width: 900, height: 500)
        // The top edge runs through the card's interior, well inside it on both
        // axes so the ~1° seeded tilt cannot move the edge off the card.
        let swept = CGRect(x: 120, y: 90, width: 400, height: 300)
        let during = try render(scene: scene(), size: size, sweep: swept)
        let before = try render(scene: scene(), size: size)

        let overTheCard = CGRect(x: 150, y: 88, width: 100, height: 5)
        XCTAssertGreaterThan(during.differingPixels(from: before, in: overTheCard), 0,
                             "the sweep vanishes where it crosses a card, so it is "
                             + "drawn UNDER the cards: the writer's rubber band is cut "
                             + "into pieces by everything already on the canvas")
    }

    /// The two appearances are two materials (§7.1), here as everywhere else.
    /// Rendering the identical sweep under each must not give the identical
    /// pixels — which is what a single hardcoded colour, or a `dynamic` pair
    /// collapsed to one value, would give.
    @MainActor
    func test_theSweepIsCalibratedSeparatelyForLightAndDark() throws {
        let size = CGSize(width: 900, height: 500)
        let swept = CGRect(x: 650, y: 200, width: 200, height: 150)
        // The same backing in both, so the only thing that can differ is how the
        // sweep's own colour resolved.
        let asLight = try render(scene: CanvasScene(), size: size, sweep: swept,
                                 scheme: .light, backing: CanvasMaterial.darkBase)
        let asDark = try render(scene: CanvasScene(), size: size, sweep: swept,
                                scheme: .dark, backing: CanvasMaterial.darkBase)

        let onTheEdge = CGRect(x: swept.minX + 20, y: swept.minY - 2,
                               width: swept.width - 40, height: 4)
        XCTAssertGreaterThan(asLight.differingPixels(from: asDark, in: onTheEdge), 0,
                             "the sweep renders identically under both appearances — "
                             + "CanvasRenderer.sweepStroke is not resolving per "
                             + "appearance, so one material is being drawn on both")
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

        /// The largest per-channel difference between two points on THIS page.
        func difference(between p: CGPoint, and q: CGPoint) -> Double {
            let d = color(at: p) - color(at: q)
            return max(abs(d.x), max(abs(d.y), abs(d.z)))
        }

        /// How many pixels inside `rect` differ from the other page's.
        ///
        /// The unit the drawn-output fixtures are built on: render two scenes
        /// that differ in exactly one model fact and every changed pixel is that
        /// fact, drawn. Exact — no colour threshold to tune, and a control rect
        /// asserting *zero* is a real assertion rather than a rounding allowance.
        func differingPixels(from other: Page, in rect: CGRect) -> Int {
            var count = 0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    // + 0.5 lands in the middle of the pixel; `color(at:)`
                    // truncates, so this addresses pixel (x, y) exactly.
                    let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    if color(at: p) != other.color(at: p) { count += 1 }
                }
            }
            return count
        }
    }

    @MainActor
    private func render(scene: CanvasScene,
                        size: CGSize,
                        selection: CanvasSelection? = nil,
                        scraps: [CanvasNodeID: String] = [:],
                        sweep: CGRect? = nil,
                        scheme: ColorScheme = .light,
                        backing: NSColor? = nil) throws -> Page {
        try Self.render(size: size, scheme: scheme, backing: backing) { cx in
            CanvasRenderer.draw(scene: scene, camera: CanvasCamera(), viewSize: size,
                                layouts: [:], scraps: scraps, selection: selection,
                                visibleEditorNodeID: nil,
                                straighten: CanvasFocusStraighten(),
                                pendingRegionDraw: sweep, into: &cx)
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
