import XCTest
import MaughamCore
@testable import Maugham

/// Spec §4 and §4.1 — what the tree's selection lights on the canvas, and the
/// one thing about it that no assertion on its MEMBERS can see: that it is
/// derived once per structural change rather than once per frame.
final class CanvasHighlightTests: XCTestCase {

    private let r1 = CanvasRegionID("r1")
    private let r2 = CanvasRegionID("r2")
    private let r3 = CanvasRegionID("r3")
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let c = CanvasNodeID("c")
    private let d = CanvasNodeID("d")

    private func scene() -> CanvasScene {
        var s = CanvasScene()
        for id in [a, b, c, d] {
            s.insert(CanvasNode(id: id, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
        }
        for (i, id) in [r1, r2, r3].enumerated() {
            s.insertRegion(CanvasRegion(id: id, label: "R\(i)",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
        }
        return s
    }

    // MARK: - What the tree names (`CanvasSubject`)

    /// `Part One` holds `ch1` and a nested group holding `ch2`; `loose` sits
    /// outside it. The nesting is the point — §4.1's *"everything bound to any
    /// chapter beneath it"* is a subtree, not a child list.
    private func structure() -> [StructureItem] {
        [StructureItem(id: "part-1", title: "Part One", type: .group, children: [
            StructureItem(id: "ch1", title: "One", type: .document, path: "One.md"),
            StructureItem(id: "inner", title: "Inner", type: .group, children: [
                StructureItem(id: "ch2", title: "Two", type: .document, path: "Two.md")
            ])
         ]),
         StructureItem(id: "loose", title: "Loose", type: .document, path: "Loose.md")]
    }

    func test_theProjectRowAndNoSelectionBothMeanTheWholeBoard() {
        XCTAssertEqual(CanvasSubject.resolve(.project, in: structure()), .wholeProject)
        XCTAssertEqual(CanvasSubject.resolve(nil, in: structure()), .wholeProject,
                       "a window nobody has clicked in has not entered the dim")
        XCTAssertFalse(CanvasSubject.wholeProject.dimsTheBoard)
    }

    func test_aDocumentResolvesToItsOwnPiece() {
        XCTAssertEqual(CanvasSubject.resolve(.item("ch2"), in: structure()), .piece("ch2"))
        XCTAssertTrue(CanvasSubject.resolve(.item("ch2"), in: structure()).dimsTheBoard)
    }

    /// §4.1: a group is the union of its children's bindings, and the union has
    /// to reach a chapter that is a grandchild.
    func test_aGroupResolvesToEveryDocumentBeneathItIncludingNestedOnes() {
        XCTAssertEqual(CanvasSubject.resolve(.item("part-1"), in: structure()),
                       .group(["ch1", "ch2"]),
                       "`inner`'s chapter is under Part One and must light with it; "
                       + "a child-list walk finds only `ch1`")
        XCTAssertEqual(CanvasSubject.resolve(.item("inner"), in: structure()),
                       .group(["ch2"]),
                       "control: the nested group on its own names only its own child")
    }

    /// The group carries no group ids — `boundPieceID` can only ever hold a
    /// document id, so a group id in this list would be a piece nothing can
    /// match and the union would be silently wrong rather than empty.
    func test_aGroupNamesNoGroups() {
        XCTAssertFalse(CanvasSubject.resolve(.item("part-1"), in: structure())
            .pieces.contains("inner"))
    }

    /// **An id that resolves to NOTHING is not a subject.**
    ///
    /// This asserted `.group([])` and a dimmed board for slice 3, and that was
    /// wrong for the same reason `ProjectWindow.restoredSubject`'s document
    /// fallback was: a deletion is not a deliberate entry into the dim. Delete
    /// the chapter the canvas is filtered on and the board went dark with no lit
    /// set, no offer — `CanvasBindingOffer.isOffered` guards `case .piece` and
    /// correctly refuses a group — and nothing on screen saying why.
    ///
    /// The two cases the old answer conflated are now apart, and the split is
    /// what makes `.group`'s own doc comment true again: a group that really
    /// holds no documents still dims (below), because the tree names something
    /// that exists.
    func test_anIdTheTreeCannotFindIsNoSubjectAtAllAndDimsNothing() {
        let subject = CanvasSubject.resolve(.item("gone"), in: structure())
        XCTAssertEqual(subject, .wholeProject)
        XCTAssertFalse(subject.dimsTheBoard,
                       "the id names nothing, so nobody chose this filter — a "
                       + "dimmed board with no lit set and no offer is a dead end "
                       + "the writer cannot read or leave")
    }

    /// The control, and the half that must NOT move: a group that resolves and
    /// holds no manuscript document still dims. The tree names something real,
    /// the writer clicked it, and §4.1's *"everything under Part One"* is an
    /// honest answer even when the answer is nothing.
    func test_aGroupThatRESOLVESAndHoldsNoDocumentsStillDimsTheBoard() {
        let empty = [StructureItem(id: "empty", title: "Part Two",
                                   type: .group, children: [])]
        let subject = CanvasSubject.resolve(.item("empty"), in: empty)
        XCTAssertEqual(subject, .group([]))
        XCTAssertTrue(subject.dimsTheBoard,
                      "an empty group is a selection the writer made; collapsing it "
                      + "into the unresolvable case would undim a board they "
                      + "deliberately filtered")
    }

    // MARK: - What lights (`CanvasHighlight`)

    func test_theProjectRowDimsNothingAtAll() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "ch1", in: &s)
        let h = CanvasHighlight.resolve(subject: .wholeProject, in: s)
        XCTAssertFalse(h.isFiltering)
        XCTAssertFalse(h.isDimmed(node: b), "a card nothing binds is still not dimmed")
        XCTAssertFalse(h.isDimmed(region: r2))
        XCTAssertFalse(h.litNothing, "the project row is not the empty state")
    }

    /// §4 row two, both halves — and the second half is the one the projection
    /// cannot give you.
    func test_aBoundChapterLightsItsRegionsAndTheirResidents() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.addAppearance(b, to: r1, in: &s)
        CanvasMembership.join(c, home: r2, in: &s)
        RegionBinding.bind(r1, toPiece: "ch1", in: &s)

        let h = CanvasHighlight.resolve(subject: .piece("ch1"), in: s)
        XCTAssertFalse(h.isDimmed(node: a), "a resident of the bound region is lit")
        XCTAssertFalse(h.isDimmed(region: r1), "the bound REGION lights too — the "
                       + "projection returns cards only, so this half is a second "
                       + "derivation and is the one that goes missing")
        XCTAssertTrue(h.isDimmed(node: b), "a VISITOR is cited, not owned (§4.4)")
        XCTAssertTrue(h.isDimmed(node: c), "control: another region's resident")
        XCTAssertTrue(h.isDimmed(region: r2))
        XCTAssertFalse(h.litNothing)
    }

    func test_aChapterWithNothingBoundDimsEverythingAndSaysSo() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "ch1", in: &s)

        let h = CanvasHighlight.resolve(subject: .piece("ch2"), in: s)
        XCTAssertTrue(h.isDimmed(node: a))
        XCTAssertTrue(h.isDimmed(region: r1))
        XCTAssertTrue(h.litNothing, "§4 row three — the state that offers the next move")
    }

    /// A bound region with no residents is still something the subject owns, so
    /// it is NOT the offer-to-bind state — offering a fresh region while one is
    /// already bound and lit would be the offer contradicting the board.
    func test_aBoundButEmptyRegionIsNotTheNothingBoundState() {
        var s = scene()
        RegionBinding.bind(r1, toPiece: "ch1", in: &s)
        let h = CanvasHighlight.resolve(subject: .piece("ch1"), in: s)
        XCTAssertTrue(h.nodes.isEmpty)
        XCTAssertFalse(h.litNothing)
        XCTAssertFalse(h.isDimmed(region: r1))
    }

    /// §4.1's group rule, over the derivation rather than over the resolution:
    /// two chapters, two regions, one selection.
    func test_aGroupLightsTheUnionOfItsChildrensBindings() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.join(b, home: r2, in: &s)
        CanvasMembership.join(c, home: r3, in: &s)
        RegionBinding.bind(r1, toPiece: "ch1", in: &s)
        RegionBinding.bind(r2, toPiece: "ch2", in: &s)
        RegionBinding.bind(r3, toPiece: "loose", in: &s)

        let h = CanvasHighlight.resolve(
            subject: CanvasSubject.resolve(.item("part-1"), in: structure()), in: s)
        XCTAssertEqual(h.nodes, [a, b], "the nested chapter's card lights with the group's")
        XCTAssertEqual(h.regions, [r1, r2])
        XCTAssertTrue(h.isDimmed(node: c), "control: a chapter OUTSIDE the group stays dimmed")
        XCTAssertTrue(h.isDimmed(region: r3))
    }

    /// Two regions bound to the same piece union, which is the projection's own
    /// rule reaching the dim rather than being re-derived here.
    func test_twoRegionsBoundToOneChapterBothLight() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.join(b, home: r2, in: &s)
        RegionBinding.bind(r1, toPiece: "ch1", in: &s)
        RegionBinding.bind(r2, toPiece: "ch1", in: &s)
        let h = CanvasHighlight.resolve(subject: .piece("ch1"), in: s)
        XCTAssertEqual(h.nodes, [a, b])
        XCTAssertEqual(h.regions, [r1, r2])
    }

    // MARK: - Lines

    func test_aLineLightsOnlyWhenBothOfItsEndsDo() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        CanvasMembership.join(b, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "ch1", in: &s)
        s.insertLine(CanvasLine(id: CanvasLineID("inside"), from: a, to: b))
        s.insertLine(CanvasLine(id: CanvasLineID("leaving"), from: a, to: c))
        s.insertLine(CanvasLine(id: CanvasLineID("outside"), from: c, to: d))

        let h = CanvasHighlight.resolve(subject: .piece("ch1"), in: s)
        XCTAssertFalse(h.isDimmed(line: CanvasLineID("inside")),
                       "a dimmed line between two lit cards cuts the lit cluster in two")
        XCTAssertTrue(h.isDimmed(line: CanvasLineID("leaving")),
                      "one end outside the subject's context")
        XCTAssertTrue(h.isDimmed(line: CanvasLineID("outside")))
    }

    // MARK: - Hidden residents (recon §7)

    /// The projection counts a collapsed region's residents; the draw culls
    /// them. Nothing needs special-casing — but the two disagree, which is why
    /// nothing in this slice puts a COUNT of the lit set on screen.
    func test_theLitSetIncludesTheResidentsOfACollapsedRegion() {
        var s = scene()
        CanvasMembership.join(a, home: r1, in: &s)
        RegionBinding.bind(r1, toPiece: "ch1", in: &s)
        s.updateRegion(r1) { $0.isCollapsed = true }

        let h = CanvasHighlight.resolve(subject: .piece("ch1"), in: s)
        XCTAssertTrue(h.nodes.contains(a))
        XCTAssertTrue(s.isHidden(a), "…and the draw never sees it, which is the disagreement")
    }

    // MARK: - Tripwire 30: derived once per structural change, never per frame
    //
    // The members above are all a `Set.contains` away from being right whether
    // the set is built once or 120 times a second, so no assertion on them can
    // see this. `CanvasAccessibility`'s cached element list is the precedent and
    // its own guard is the shape these follow.

    private func canvasViewSource() throws -> String {
        try CanvasSourceCensus.source(at: "Maugham/Canvas/CanvasView.swift")
    }

    /// The offender, planted: what the lazy version of this looks like. If the
    /// predicates below cannot catch it written out, they are not guarding
    /// anything.
    private let plantedOffender = """
        var body: some View {
            TimelineView(.animation) { context in
                Canvas { cx, size in
                    let highlight = CanvasHighlight.resolve(subject: subject, in: model.scene)
                    CanvasRenderer.draw(scene: model.scene, highlight: highlight, into: &cx)
                }
            }
        }
        """

    /// Everything between `Canvas {` and the end of that closure runs at
    /// 60–120 Hz through every straighten, coast and drag.
    func test_theLitSetIsNotDerivedInsideTheDrawClosure() throws {
        XCTAssertFalse(try drawClosure(of: canvasViewSource()).contains("CanvasHighlight.resolve"),
                       "the lit set walks every region and unions every region's "
                       + "homeMembers — derived here it does that once per frame")

        // The companion, and it is the whole point: the same predicate over the
        // lazy version has to come back positive, or the assertion above passes
        // for any file at all.
        XCTAssertTrue(drawClosure(of: plantedOffender).contains("CanvasHighlight.resolve"),
                      "the slicer is not reading the draw closure — this test cannot fail")
    }

    /// …and it is rebuilt from the STRUCTURAL counter, never the redraw one.
    func test_theLitSetIsRebuiltOnTheStructuralCounterAndTheSubject() throws {
        let src = CanvasSourceCensus.commentsStripped(try canvasViewSource())
        XCTAssertTrue(
            src.contains(".onChange(of: sceneRevision) { _, _ in rebuildHighlightAndTree() }"),
            "the bindings and the membership move with the scene")
        XCTAssertTrue(src.contains(".onChange(of: subject, initial: true) "
                                   + "{ _, _ in rebuildHighlightAndTree() }"),
                      "…and what the tree names moves with a click. Without this "
                      + "trigger the dim is right once and then stale for the "
                      + "rest of the session")
        XCTAssertFalse(src.contains(".onChange(of: revision"),
                       "`revision` ticks once per animation frame — keying the lit "
                       + "set on it is the same defect with an extra step")
    }

    /// One writer. A third call site on a per-frame path would be invisible on
    /// screen, because the answer would be right every time.
    func test_theLitSetHasExactlyOneWriter() throws {
        let src = CanvasSourceCensus.commentsStripped(try canvasViewSource())
        XCTAssertEqual(
            src.components(separatedBy: "CanvasHighlight.resolve").count - 1, 1,
            "`highlight` is resolved somewhere other than `rebuildHighlightAndTree()`")
        XCTAssertEqual(src.components(separatedBy: "rebuildHighlightAndTree()").count - 1, 4,
                       "the declaration and exactly THREE callers — the two "
                       + "`.onChange`s above and `.onChange(of: pieceTitles"
                       + ".fingerprint)`. A fourth is a per-frame path or a "
                       + "second answer to when the dim changes. **It was two "
                       + "callers until §4.2 (2026-08-04)**: a region bound "
                       + "elsewhere now speaks a piece TITLE, and a manifest "
                       + "rename moves neither the scene nor the subject, so "
                       + "nothing else can refresh the cached tree — see "
                       + "`CanvasBoundPieceTests"
                       + ".test_theSpokenTreeIsRebuiltWhenAPieceIsRenamed`")
    }

    // MARK: - …and the tree that SPEAKS it is derived from the same value
    //
    // Task 7. `CanvasAccessibility.label` now carries `dimmedTerm`, so every
    // label on this surface depends on the dim — which means the accessibility
    // rebuild depends on the SUBJECT, which it never did before.

    /// **The stale-read shape, ruled out structurally rather than hoped against.**
    ///
    /// The available two-function shape is: leave the tree on its own
    /// `.onChange`, give that trigger the subject as well, and let it read the
    /// `@State` `highlight`. It is one line smaller and it has a hole with no
    /// symptom — SwiftUI orders no two handlers on one update pass, so the tree
    /// can be built from the highlight as it stood **before** the click that
    /// triggered it, and nothing rebuilds it again until the scene next moves.
    /// The labels would then describe the previous selection for the rest of the
    /// session, silently, on a surface whose whole visible behaviour is correct.
    ///
    /// So the assertion is that the resolution is a LOCAL handed to both, and the
    /// discriminator is the one thing the broken shape must contain: the tree's
    /// call reading the property. `highlight: highlight` is legitimate at the
    /// DRAW site — `body` reading `@State` is what `body` is for — so the scan is
    /// of the `elements(…)` call's own arguments and not of the file.
    func test_theTreeAndTheDimAreDerivedFromOneResolvedValue() throws {
        let src = CanvasSourceCensus.commentsStripped(try canvasViewSource())
        XCTAssertEqual(src.components(separatedBy: "axElements = ").count - 1, 1,
                       "the accessibility tree has more than one writer, so one of "
                       + "them is deriving the dim a second time")

        let call = try elementsCall(in: src)
        XCTAssertTrue(call.contains("highlight:"),
                      "the tree is built without the dim at all — `elements` takes it "
                      + "with an `.undimmed` DEFAULT, so dropping the argument "
                      + "compiles, runs, and announces every card on a filtered board "
                      + "as though nothing were dimmed")
        XCTAssertFalse(call.contains("highlight: highlight"),
                       "the tree reads the `@State` rather than the value just "
                       + "resolved beside it: on the pass where the subject changes "
                       + "that property may still hold the previous board, and no "
                       + "later trigger corrects it")
    }

    /// The companion, and it is the whole point of the assertion above: the same
    /// slicer over the lazy version has to come back with the property read, or
    /// the test passes for any file at all.
    func test_theOneValueScanCatchesTheStaleReadWrittenOut() throws {
        let planted = """
            .onChange(of: sceneRevision) { _, _ in rebuildHighlight() }
            .onChange(of: subject, initial: true) { _, _ in rebuildHighlight() }
            private func rebuildTree() {
                axElements = CanvasAccessibility.elements(scene: model.scene,
                                                          scraps: model.scraps,
                                                          items: itemPresentation,
                                                          highlight: highlight)
            }
            """
        XCTAssertTrue(try elementsCall(in: planted).contains("highlight: highlight"),
                      "the slicer is not reading the call's arguments — the "
                      + "assertion it serves cannot fail")
    }

    /// The arguments of the one `CanvasAccessibility.elements(…)` call.
    ///
    /// Naive to the first `)` on purpose: this call has no nested parentheses,
    /// and a slicer that balanced them would be more code than the thing it
    /// guards. If an argument ever grows a call of its own, this is what has to
    /// be taught about it — a slice that ran short would fail quietly in the
    /// direction that passes.
    private func elementsCall(in source: String) throws -> String {
        let opening = try XCTUnwrap(source.range(of: "CanvasAccessibility.elements("),
                                    "nothing builds the accessibility tree at all")
        let rest = source[opening.upperBound...]
        let close = try XCTUnwrap(rest.range(of: ")"), "the call never closes")
        return String(rest[..<close.lowerBound])
    }

    /// The cost, measured rather than asserted about — this is why the two
    /// source guards above are worth their weight. A canvas at the probe's
    /// supported size, derived once.
    func test_theDerivationIsScenePropertionalAndSoMustNotRideAFrame() {
        var s = CanvasScene()
        let regionCount = 40
        let perRegion = CanvasPerformanceProbeTests.supportedNodeCount / regionCount
        for r in 0..<regionCount {
            let region = CanvasRegionID("r\(r)")
            s.insertRegion(CanvasRegion(id: region, label: "R\(r)",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 400)))
            for n in 0..<perRegion {
                let id = CanvasNodeID("n\(r)-\(n)")
                s.insert(CanvasNode(id: id, kind: .scrap, origin: .zero,
                                    width: 240, cachedHeight: 80))
                CanvasMembership.join(id, home: region, in: &s)
            }
            RegionBinding.bind(region, toPiece: "ch\(r)", in: &s)
        }

        let start = Date()
        let h = CanvasHighlight.resolve(
            subject: .group((0..<regionCount).map { "ch\($0)" }), in: s)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(h.nodes.count, regionCount * perRegion)
        // Not a performance bound — a statement of the shape. Once per gesture
        // this is nothing; once per frame at 120 Hz it is the whole budget.
        XCTAssertGreaterThan(elapsed, 0,
                             "if this ever measures as free, the derivation has "
                             + "stopped walking the scene and this fixture is lying")
    }

    // MARK: - The way out (§4.1)

    /// **Escape and the project row must produce the same state, not two states
    /// that look alike** — and this is where that can be seen, because it is a
    /// claim about two files and no runtime test in this repo hosts the real
    /// `ProjectWindow`.
    ///
    /// §4.1 does not say Escape produces something equivalent to the project
    /// row; it says it *is* that row. So the assertion is value identity at the
    /// source: `BinderView`'s row carries `BinderSubject.project` on its `.tag`
    /// and the window's Escape wiring writes `BinderSubject.project` into the
    /// same `@State` through the same synchronous path. Everything downstream —
    /// the canvas's `CanvasSubject`, the persisted UI state, the tree's own
    /// highlight, the metrics zeroing in that `.onChange` — then agrees by
    /// construction rather than by two implementations resembling each other.
    ///
    /// The behavioural half is one line and is asserted below it: whatever else
    /// changes, that value must resolve to the undimmed board.
    func test_escapeWritesTheSameSubjectTheProjectRowDoes() throws {
        let row = CanvasSourceCensus.commentsStripped(
            try CanvasSourceCensus.source(at: "Maugham/Views/BinderView.swift"))
        XCTAssertTrue(row.contains(".tag(BinderSubject.project)"),
                      "the project row no longer tags `BinderSubject.project`, so "
                      + "the value Escape writes is no longer the row's value — "
                      + "whichever of the two moved, they have to move together")

        let window = CanvasSourceCensus.commentsStripped(
            try CanvasSourceCensus.source(at: "Maugham/Views/ProjectWindow.swift"))
        XCTAssertTrue(window.contains("selectTheProjectRow: { selectedSubject = .project }"),
                      "the canvas's way out of the dim does not write "
                      + "`.project` into the window's subject. §4.1: Escape IS the "
                      + "keyboard spelling of the project row — a second value that "
                      + "merely undims would leave the tree still showing a chapter "
                      + "selected while the board says otherwise")

        XCTAssertEqual(CanvasSubject.resolve(.project, in: structure()), .wholeProject,
                       "and the value both of them write is the undimmed board")
    }

    // MARK: -

    /// The text between `Canvas {` and the matching close brace — the per-frame
    /// region of `body`. Brace-counted rather than line-sliced so an added
    /// modifier cannot move the boundary.
    private func drawClosure(of source: String) -> String {
        guard let open = source.range(of: "Canvas { cx, size in") else { return "" }
        var depth = 1
        var out = ""
        for ch in source[open.upperBound...] {
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            out.append(ch)
        }
        return out
    }
}
