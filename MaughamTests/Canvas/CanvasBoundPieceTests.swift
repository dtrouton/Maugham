import XCTest
import SwiftUI
import AppKit
import MaughamCore
@testable import Maugham

/// **§4.2, 2026-08-04 — a dimmed region says whose it is.**
///
/// The dim conflates two states whose behaviour under the sweep is opposite: an
/// *unbound* region, where a sweep creates and binds, and one *bound to a
/// different piece*, where the never-re-bind ruling makes the sweep do nothing at
/// all. The name is what tells them apart, and the rule that falls out of it is
/// the one every assertion here is really guarding:
///
/// > **On a dimmed board, no name on a region means a sweep there will work.**
///
/// That is a biconditional, so it takes assertions in both directions, and the
/// direction that fails silently is the second: a region whose piece has been
/// DELETED still refuses the sweep, so a label that went quiet there would be
/// lying in the one case it matters most.
final class CanvasBoundPieceTests: XCTestCase {

    private let r1 = CanvasRegionID("r1")
    private let r2 = CanvasRegionID("r2")

    private func region(_ id: CanvasRegionID, label: String = "Act II fog",
                        boundTo piece: String? = nil,
                        frame: CGRect = CGRect(x: 20, y: 40, width: 320, height: 200),
                        collapsed: Bool = false) -> CanvasRegion {
        CanvasRegion(id: id, label: label, frame: frame,
                     boundPieceID: piece, isCollapsed: collapsed)
    }

    /// A binder holding one ordinary chapter, one chapter inside a group, and a
    /// group of its own — the shape `ProjectWindow.pieceTitle` walks.
    private func structure() -> [StructureItem] {
        [
            StructureItem(id: "ch1", title: "Chapter One", type: .document),
            StructureItem(id: "ch2", title: "Chapter Two", type: .document),
            StructureItem(id: "part1", title: "Part One", type: .group, children: [
                StructureItem(id: "ch3", title: "Chapter Three", type: .document),
            ]),
        ]
    }

    private func titles() -> CanvasPieceTitles {
        CanvasPieceTitles.over(structure: structure())
    }

    // MARK: - The resolution

    /// The whole point: the writer can see which document the rectangle under
    /// their cursor already belongs to.
    func test_aDimmedRegionBoundElsewhereNamesItsPiece() {
        XCTAssertEqual(titles().boundElsewhere(region(r1, boundTo: "ch2"), isDimmed: true),
                       "Chapter Two")
    }

    /// **Only the regions bound ELSEWHERE** (Denver's second ruling). A lit
    /// region is bound to the piece the tree already names, so naming it here
    /// repeats the binder — and it would destroy the rule the feature exists to
    /// create, because a name would then mean nothing about the gesture.
    func test_aLitRegionNamesNothing() {
        XCTAssertNil(titles().boundElsewhere(region(r1, boundTo: "ch2"), isDimmed: false),
                     "a lit region carries a name, so the absence of a name no "
                     + "longer means a sweep will work")
    }

    /// The other half of the biconditional, and the one the writer relies on
    /// every time they sweep.
    func test_anUnboundDimmedRegionNamesNothing() {
        XCTAssertNil(titles().boundElsewhere(region(r1, boundTo: nil), isDimmed: true))
    }

    /// **A deleted chapter must have an answer** — this is the case where a quiet
    /// label is a lie rather than an omission. The region still refuses the
    /// sweep, so it must still say it belongs to something.
    func test_aRegionBoundToADeletedPieceStillNamesSomething() {
        let name = titles().boundElsewhere(region(r1, boundTo: "gone-9"), isDimmed: true)
        XCTAssertNotNil(name,
                        "a region whose chapter was deleted reads as unbound — and "
                        + "a sweep there does nothing, which is the exact confusion "
                        + "§4.2 exists to close")
        XCTAssertEqual(name, CanvasPieceTitles.missingPieceName)
    }

    /// **The map is over the WHOLE structure and never over the routable offer.**
    ///
    /// `ProjectWindow.pieceChoices` narrows to `researchScopeTargets()`, which
    /// drops a Collection reference piece sitting in the writer's binder. Built
    /// from that list, this label would call a piece the writer is looking at
    /// "Missing piece" — which is exactly the defect
    /// `ScrapInspector.PieceAssociation.keepsNoResearch` was minted to fix, one
    /// surface over, and the reason this resolution reads the same tree
    /// `ProjectWindow.pieceTitle` does.
    func test_aPieceTheRoutableOfferExcludesIsStillNamed() {
        // `ch3` lives under a group, so a walk that stopped at the top level —
        // or a map built from a narrowed offer — would miss it.
        XCTAssertEqual(titles().boundElsewhere(region(r1, boundTo: "ch3"), isDimmed: true),
                       "Chapter Three")
    }

    /// A group is in the map too, for parity with `ProjectWindow.pieceTitle`'s
    /// own walk: `boundPieceID` should only ever hold a document, and a sidecar
    /// that disagrees must not turn a row in the binder into "Missing piece".
    func test_aGroupResolvesRatherThanReadingAsDeleted() {
        XCTAssertEqual(titles().title(of: "part1"), "Part One")
    }

    /// **Tripwire 22, applied to a name rather than a path.** A chapter renamed
    /// while the canvas is filtered must change the fingerprint, or the cached
    /// accessibility tree keeps announcing the old title for the rest of the
    /// session.
    func test_theFingerprintMovesWithATitleAndIsStableOtherwise() {
        XCTAssertEqual(titles().fingerprint, titles().fingerprint,
                       "the same binder fingerprints differently twice — a "
                       + "process-seeded hash, which makes every cache key useless")

        var renamed = structure()
        renamed[1].title = "Chapter Two, revised"
        XCTAssertNotEqual(CanvasPieceTitles.over(structure: renamed).fingerprint,
                          titles().fingerprint,
                          "a rename does not move the fingerprint, so nothing "
                          + "rebuilds the spoken tree and it names the old title")
    }

    func test_theEmptyMapNamesNothingItCannotResolve() {
        XCTAssertNil(CanvasPieceTitles.empty.title(of: "ch1"))
        XCTAssertEqual(CanvasPieceTitles.empty.boundElsewhere(region(r1, boundTo: "ch1"),
                                                              isDimmed: true),
                       CanvasPieceTitles.missingPieceName)
    }

    // MARK: - Drawn (§4.2: on the region, not in an overlay)

    private let viewSize = CGSize(width: 800, height: 300)
    /// The ground `CanvasHighlightRenderTests` uses, and for its reason: a
    /// translucent card over a white backing is a white pixel.
    private let ground = NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)

    private func scene(bound: String?) -> CanvasScene {
        var s = CanvasScene()
        s.insertRegion(region(r1, boundTo: bound))
        return s
    }

    /// The chrome bar's text row, minus the label's own start — where a borrowed
    /// name can appear and nothing else does.
    private var chromeBar: CGRect {
        CGRect(x: 20, y: 40, width: 320, height: CanvasRegionMetrics.chromeHeight)
    }

    /// The region's interior: the control. A change here means something other
    /// than the chrome text moved, and the fixture is measuring the wrong thing.
    private var interior: CGRect {
        CGRect(x: 25, y: 70, width: 300, height: 160)
    }

    @MainActor
    func test_aDimmedRegionBoundElsewhereDrawsTheNameOnItsChromeBar() throws {
        let dim = CanvasHighlight.resolve(subject: .piece("ch1"), in: scene(bound: "ch2"))
        let unbound = try render(scene: scene(bound: nil), size: viewSize,
                                 highlight: dim, pieceTitles: titles(), backing: ground)
        let bound = try render(scene: scene(bound: "ch2"), size: viewSize,
                               highlight: dim, pieceTitles: titles(), backing: ground)

        XCTAssertGreaterThan(bound.differingPixels(from: unbound, in: chromeBar), 0,
                             "the piece's name is not drawn on the chrome bar at all")
        XCTAssertEqual(bound.differingPixels(from: unbound, in: interior), 0,
                       "the binding changed something other than the chrome text")
    }

    /// **No name on an undimmed board.** The plant this fires on is the obvious
    /// one — drawing the name whenever a region is bound — and it is the plant
    /// that a lit-versus-lit comparison cannot see, because both sides would
    /// draw it.
    @MainActor
    func test_anUndimmedBoardDrawsNoNameAtAll() throws {
        let unbound = try render(scene: scene(bound: nil), size: viewSize,
                                 pieceTitles: titles(), backing: ground)
        let bound = try render(scene: scene(bound: "ch2"), size: viewSize,
                               pieceTitles: titles(), backing: ground)

        XCTAssertEqual(bound.differingPixels(from: unbound, in: chromeBar), 0,
                       "a binding is visible on an undimmed board — §4.2 puts the "
                       + "name on the dim and nowhere else, and a name drawn here "
                       + "says nothing about any gesture")
    }

    /// **The `tetherOpacity` trap, one primitive over.** The borrowed name is the
    /// one thing on a dimmed region that has to be READ, so it may not be drawn
    /// fainter than the region's own label beside it. Measured as ink rather than
    /// asserted about in a comment.
    @MainActor
    func test_theNameIsDrawnNoFainterThanTheRegionsOwnLabel() throws {
        let dim = CanvasHighlight.resolve(subject: .piece("ch1"), in: scene(bound: "ch2"))
        let bound = try render(scene: scene(bound: "ch2"), size: viewSize,
                               highlight: dim, pieceTitles: titles(), backing: ground)
        let blank = try render(scene: CanvasScene(), size: viewSize,
                               highlight: dim, pieceTitles: titles(), backing: ground)

        // The label sits at the start of the bar and the name after it. Both are
        // measured against a page with no region at all, so what is counted is
        // the glyphs and not the wash.
        let ownLabel = CGRect(x: 28, y: 42, width: 60, height: 18)
        let borrowed = CGRect(x: 92, y: 42, width: 100, height: 18)
        let labelInk = bound.differingPixels(from: blank, in: ownLabel)
        let nameInk = bound.differingPixels(from: blank, in: borrowed)
        XCTAssertGreaterThan(labelInk, 0, "the region's own label did not draw — "
                             + "this fixture's geometry is wrong, not the ink")
        XCTAssertGreaterThan(nameInk, 0,
                             "the borrowed name drew no pixels beside the label — "
                             + "either it is not there or it has been dimmed into "
                             + "the wash, which is `tetherOpacity`'s defect exactly")
    }

    // MARK: - The truncation rule, which is a decision

    /// **A narrow region loses its card count before it loses the name of the
    /// piece it belongs to, and never loses that name before its own label.**
    ///
    /// The runs are ordered by what the writer cannot recover elsewhere. Their
    /// own label they chose and can read in the inspector; the count they can get
    /// by expanding the region and VoiceOver says it in the value; the borrowed
    /// name is available nowhere else at the moment the gesture is being aimed.
    /// So when the bar is too narrow for both, the region's OWN label is the run
    /// that yields.
    func test_theRegionsOwnLabelYieldsToTheBorrowedName() {
        let wide = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(CanvasRenderer.regionLabelWidthBudget(in: wide, borrowedWidth: 80),
                       400 - 10 - 10 - 80 - 10, accuracy: 0.001)

        // With nothing borrowed the label keeps the whole bar, which is what it
        // has today.
        XCTAssertEqual(CanvasRenderer.regionLabelWidthBudget(in: wide, borrowedWidth: 0),
                       400 - 20, accuracy: 0.001)
    }

    /// It never goes negative, and a region at its minimum side still leaves the
    /// borrowed name its space rather than handing the bar to a long label.
    func test_theBudgetNeverGoesNegative() {
        let narrow = CGRect(x: 0, y: 0, width: CanvasRegionMetrics.minimumSide,
                            height: CanvasRegionMetrics.minimumSide)
        XCTAssertEqual(CanvasRenderer.regionLabelWidthBudget(in: narrow, borrowedWidth: 400), 0,
                       "a negative budget hands the label room it does not have "
                       + "and draws it over the name it was supposed to yield to")
    }

    /// One unit per character, so the elision is arithmetic a reader can check.
    private func perCharacter(_ s: String) -> CGFloat { CGFloat(s.count) }

    func test_aRunThatFitsIsNotTouched() {
        XCTAssertEqual(CanvasRenderer.elide("Chapter Two", to: 40, measuring: perCharacter),
                       "Chapter Two")
    }

    /// **An ellipsis rather than a sliced glyph, and it is a decision made under
    /// a measured constraint** — see `CanvasRenderer.elide`: the two clipping
    /// spellings each cost something worse, one of them pixel determinism across
    /// every drawn-output fixture on this surface.
    func test_aRunThatDoesNotFitIsShortenedAndSaysSo() {
        let out = CanvasRenderer.elide("Chapter Two", to: 5, measuring: perCharacter)
        XCTAssertEqual(out, "Chap" + CanvasRenderer.ellipsis)
        XCTAssertLessThanOrEqual(perCharacter(out), 5,
                                 "the result overflows the width it was elided to")
    }

    /// The largest prefix that fits, not merely *a* prefix — an implementation
    /// that always returned the mark alone would pass a width assertion.
    func test_itKeepsAsMuchAsWillFit() {
        XCTAssertEqual(CanvasRenderer.elide("Chapter Two", to: 10, measuring: perCharacter),
                       "Chapter T" + CanvasRenderer.ellipsis)
    }

    /// **Zero room draws nothing at all**, which is what makes the yield total: a
    /// region whose bar the borrowed name fills entirely gives up its own label
    /// rather than printing a fragment of it over the name.
    func test_noRoomAtAllDrawsNothingRatherThanAFragment() {
        XCTAssertEqual(CanvasRenderer.elide("Act II fog", to: 0, measuring: perCharacter), "")
    }

    /// Room for less than the mark still gets the mark: *something was cut here*
    /// is true and readable, and a one-glyph fragment of a word is neither.
    func test_roomForLessThanTheMarkStillGetsTheMark() {
        XCTAssertEqual(CanvasRenderer.elide("Act II fog", to: 0.5, measuring: perCharacter),
                       CanvasRenderer.ellipsis)
    }

    /// The narrow case end to end, on pixels: a region at its minimum side has no
    /// room for both runs, and the one that survives is the borrowed name.
    @MainActor
    func test_aNarrowRegionStillDrawsTheName() throws {
        let narrow = CGRect(x: 20, y: 40, width: CanvasRegionMetrics.minimumSide, height: 120)
        func page(bound: String?) throws -> CanvasPage {
            var s = CanvasScene()
            s.insertRegion(region(r1, label: "Act II fog", boundTo: bound, frame: narrow))
            return try render(scene: s, size: viewSize,
                              highlight: CanvasHighlight.resolve(subject: .piece("ch1"), in: s),
                              pieceTitles: titles(), backing: ground)
        }
        let blank = try render(scene: CanvasScene(), size: viewSize,
                               pieceTitles: titles(), backing: ground)
        let bar = CGRect(x: 20, y: 40, width: CanvasRegionMetrics.minimumSide,
                         height: CanvasRegionMetrics.chromeHeight)

        XCTAssertGreaterThan(try page(bound: nil).differingPixels(from: blank, in: bar), 0,
                             "the control: a narrow region draws SOMETHING on its "
                             + "bar, so the assertion below is about the name")
        XCTAssertGreaterThan(try page(bound: "ch2").differingPixels(from: blank, in: bar), 0,
                             "a region too narrow for both runs drew nothing at all "
                             + "— the yield went past the name it exists to protect")
    }

    // MARK: - Spoken (§4.2: it must be audible)

    private func regionLabel(bound: String?, subject: CanvasSubject,
                             collapsed: Bool = false) -> String {
        var s = CanvasScene()
        s.insertRegion(region(r1, boundTo: bound, collapsed: collapsed))
        let elements = CanvasAccessibility.elements(
            scene: s, scraps: [:],
            highlight: CanvasHighlight.resolve(subject: subject, in: s),
            pieceTitles: titles())
        return elements.first { $0.id == .region(r1) }?.label ?? ""
    }

    /// A lean is inaudible and so is a drawn name — and this one carries the
    /// reason a gesture will refuse, so without it a VoiceOver user gets a sweep
    /// that silently does nothing and no way to discover why.
    func test_aDimmedRegionBoundElsewhereSaysWhoseItIs() {
        XCTAssertTrue(regionLabel(bound: "ch2", subject: .piece("ch1"))
            .contains(CanvasAccessibility.boundElsewhereTerm("Chapter Two")),
                      "the spoken label says nothing about the binding, so the "
                      + "drawn surface and the spoken one disagree about the one "
                      + "fact that predicts the gesture")
    }

    /// **It is spoken with the dim and ahead of the kind**, on `dimmedTerm`'s own
    /// argument: everything after the kind is variable in length — a name, a
    /// provenance, a mark, a list of line labels, then the writer's whole
    /// sentence — and a listener skimming a filtered board for "where can I
    /// sweep" is listening for exactly these two clauses.
    func test_theBindingIsSpokenBesideTheDimAndAheadOfTheKind() {
        let label = regionLabel(bound: "ch2", subject: .piece("ch1"))
        let dim = try! XCTUnwrap(label.range(of: CanvasAccessibility.dimmedTerm))
        let bound = try! XCTUnwrap(
            label.range(of: CanvasAccessibility.boundElsewhereTerm("Chapter Two")))
        let kind = try! XCTUnwrap(label.range(of: CanvasAccessibility.regionKind))

        XCTAssertLessThan(dim.lowerBound, bound.lowerBound,
                          "the binding is spoken before the dim it qualifies")
        XCTAssertLessThan(bound.lowerBound, kind.lowerBound,
                          "the binding arrives after the kind and the name, where "
                          + "a listener skimming for it has to hear the whole "
                          + "element out to reach it")
    }

    func test_aLitRegionSaysNothingAboutItsBinding() {
        let label = regionLabel(bound: "ch2", subject: .piece("ch2"))
        XCTAssertFalse(label.contains("bound to"),
                       "a lit region names its piece aloud, which repeats the "
                       + "binder and destroys the rule that silence means a sweep "
                       + "will work")
        XCTAssertTrue(label.contains(CanvasAccessibility.regionKind),
                      "the control: this fixture must produce a real region label")
    }

    func test_anUnboundDimmedRegionSaysNothingAboutItsBinding() {
        let label = regionLabel(bound: nil, subject: .piece("ch1"))
        XCTAssertTrue(label.contains(CanvasAccessibility.dimmedTerm),
                      "the control: this region must be dimmed, or the assertion "
                      + "below passes for the wrong reason")
        XCTAssertFalse(label.contains("bound to"))
    }

    func test_aDeletedPieceIsSpokenToo() {
        XCTAssertTrue(regionLabel(bound: "gone-9", subject: .piece("ch1"))
            .contains(CanvasAccessibility.boundElsewhereTerm(
                CanvasPieceTitles.missingPieceName)))
    }

    /// The durable facts keep their order behind it — the binding is window
    /// state and takes no place in that sequence.
    func test_theCollapsedTermStillComesLast() {
        let label = regionLabel(bound: "ch2", subject: .piece("ch1"), collapsed: true)
        let bound = try! XCTUnwrap(
            label.range(of: CanvasAccessibility.boundElsewhereTerm("Chapter Two")))
        let collapsed = try! XCTUnwrap(label.range(of: CanvasAccessibility.collapsedTerm))
        XCTAssertLessThan(bound.lowerBound, collapsed.lowerBound)
    }

    // MARK: - Wiring
    //
    // Every one of these guards a DEFAULT. `CanvasPieceTitles.empty` is a real
    // state — a canvas hosted without a window — so a dropped argument compiles,
    // runs, and names every bound region "Missing piece" on the writer's canvas
    // while the binder shows the chapter in front of them.

    private func canvasViewSource() throws -> String {
        CanvasSourceCensus.commentsStripped(
            try CanvasSourceCensus.source(at: "Maugham/Canvas/CanvasView.swift"))
    }

    func test_theViewHandsThePieceTitlesToBothConsumers() throws {
        let src = try canvasViewSource()
        XCTAssertEqual(src.components(separatedBy: "pieceTitles: pieceTitles").count - 1, 2,
                       "the drawn region and the spoken region must be handed the "
                       + "SAME map — one of them missing is a drawn/spoken "
                       + "divergence nobody decided, and both take it with an "
                       + "`.empty` default so nothing red says so")
    }

    /// **Tripwire 22's shape, and `itemIndex.fingerprint` is the precedent.** The
    /// drawn label follows a rename for free — the map is a property of this
    /// view, so a new value re-runs `body`. The spoken one does not: the tree is
    /// cached in `@State`, and without this trigger a chapter renamed while the
    /// canvas is filtered is announced under its old title for the rest of the
    /// session.
    func test_theSpokenTreeIsRebuiltWhenAPieceIsRenamed() throws {
        XCTAssertTrue(try canvasViewSource().contains(
            ".onChange(of: pieceTitles.fingerprint) { _, _ in rebuildHighlightAndTree() }"),
                      "nothing rebuilds the accessibility tree when a piece's "
                      + "title changes")
    }

    /// Tripwire 30: the map is built where the manifest already is, and this view
    /// never builds one of its own.
    func test_theMapIsNeverBuiltOnTheCanvasSideAtAll() throws {
        XCTAssertFalse(try canvasViewSource().contains("CanvasPieceTitles.over("),
                       "the canvas walks the manifest itself — that walk belongs on "
                       + "`ProjectWindow`'s body, which re-evaluates per manifest "
                       + "change, and not on this one, which re-evaluates per drag "
                       + "frame")
    }

    /// **One walk, one table, one answer.** `RegionInspector` resolves a bound
    /// piece the picker cannot offer through `ScrapInspector.unoffered`, which is
    /// a function of exactly this lookup — so the pane and the canvas must read
    /// the same table or they can disagree about whether a chapter still exists.
    func test_theInspectorsTitleLookupReadsTheSameTable() throws {
        let src = CanvasSourceCensus.commentsStripped(
            try CanvasSourceCensus.source(at: "Maugham/Views/ProjectWindow.swift"))
        XCTAssertTrue(src.contains("pieceTitle: { Self.canvasPieceTitles(in: store).title(of: $0) }"),
                      "the region inspector walks the structure on its own, so the "
                      + "canvas and the pane hold two answers to \"does this piece "
                      + "still exist\" and nothing keeps them together")
    }
}
