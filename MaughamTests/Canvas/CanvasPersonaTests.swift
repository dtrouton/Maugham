import XCTest
@testable import Maugham
import MaughamCore

/// **`ProjectType.allCases`, never a hand-written list.** These loops read
/// `[.novel, .screenplay, .collection]` until 2026-07-28 and `ProjectType` has
/// four cases — `.shortStory` was never asked. Nothing was broken (both
/// functions are total, and Plan offers `.canvas` for every type), but the point
/// of extracting a decision into a pure function is to ask it over *all* its
/// inputs, and a hardcoded list is the sampling that defeats it. A case added to
/// `ProjectType` must arrive here on its own.
final class CanvasPersonaTests: XCTestCase {

    func test_planOffersTheCanvasFirstOnEveryProjectType() {
        for type in ProjectType.allCases {
            let segments = Persona.plan.binderSegments(for: type)
            XCTAssertEqual(segments.first, .canvas,
                           "Plan's centre column is the canvas (umbrella §6.3) — \(type)")
            XCTAssertEqual(Persona.plan.binderHome(for: type), .canvas)
        }
    }

    func test_planStillOffersResearchAndPalette() {
        let segments = Persona.plan.binderSegments(for: .novel)
        XCTAssertTrue(segments.contains(.research))
        XCTAssertTrue(segments.contains(.palette))
    }

    func test_noOtherPersonaOffersTheCanvas() {
        for persona in [Persona.author, .review, .publish] {
            for type in ProjectType.allCases {
                XCTAssertFalse(persona.binderSegments(for: type).contains(.canvas),
                               "\(persona) must not offer the canvas")
            }
        }
    }

    /// **The tree is Plan's, on every project type** — slice 2's deliverable,
    /// asserted as a whole row of the registry rather than as one persona.
    ///
    /// It is offered by nobody else because it CENTRES the canvas: `.tree` in
    /// Author would put the planning canvas where the editor belongs. Author's
    /// tree is `.manuscript` (or `.scenes`), which is the same left pane with
    /// the editor in the middle — that is exactly why `.tree` is a case of its
    /// own and not a reuse of the manuscript home.
    func test_theTreeIsPlansAndNobodyElsesOnEveryProjectType() {
        for type in ProjectType.allCases {
            for persona in Persona.allCases {
                XCTAssertEqual(persona.binderSegments(for: type).contains(.tree),
                               persona == .plan,
                               "\(persona)/\(type)")
            }
            XCTAssertEqual(Persona.plan.binderSegments(for: type),
                           [.canvas, .tree, .research, .palette],
                           "\(type): the canvas still leads, so `binderHome` — "
                           + "which is `.first` — is unmoved")
        }
    }

    func test_switchingAwayFromPlanLeavesTheCanvas() {
        // Author does not offer .canvas, so a coerced segment must land on
        // Author's own home rather than stranding the writer on a blank column.
        let author = Persona.author.binderSegments(for: .novel)
        XCTAssertFalse(author.contains(.canvas))
        XCTAssertEqual(Persona.author.binderHome(for: .novel), .manuscript)
    }


    // MARK: - The canvas segment reaches its column on EVERY project type

    /// **The smoke-found defect, 2026-07-28.** `ProjectWindow.inspectorPane`
    /// split on project type *before* it ever consulted `binderSegment`, and a
    /// Collection took a branch with no `.canvas` arm at all — so a Collection
    /// writer selecting a region got the piece inspector for whatever manuscript
    /// item was last selected. Denver writes in Collections, so the region
    /// inspector was unreachable for the person it was built for.
    ///
    /// Every review of the slice looked at `existingInspectorSwitch`, because
    /// that is the switch the plan named. Nobody asked whether there were two
    /// inspector paths. This test asks the question the reviews could not:
    /// exhaustively, over the product of segment and project type.
    func test_theCanvasSegmentReachesTheRegionInspectorOnEveryProjectType() {
        for type in ProjectType.allCases {
            XCTAssertEqual(
                ProjectWindow.inspectorRoute(binderSegment: .canvas, projectType: type),
                .canvas,
                "the canvas segment must reach the region inspector in a \(type) — "
                + "there is ONE canvas per project regardless of type (spec §2), so "
                + "the type cannot be allowed to decide this first")
        }
    }

    /// **The tree centres the canvas too, so the region inspector must be
    /// reachable from it.** Miss this and the 2026-07-28 smoke defect returns
    /// one segment over: the writer arranges structure in Plan, clicks a region,
    /// and gets the piece inspector for whatever manuscript item was last
    /// selected — in a Collection — or the segment switch's research arm in a
    /// novel.
    ///
    /// **Positive, not just excluded from the loop below.** The exclusion alone
    /// would let `.tree` fall out of the canvas check with nothing red, which is
    /// how a census quietly degrades into an exclusion list.
    func test_theTreeSegmentAlsoReachesTheRegionInspectorOnEveryProjectType() {
        for type in ProjectType.allCases {
            XCTAssertEqual(
                ProjectWindow.inspectorRoute(binderSegment: .tree, projectType: type),
                .canvas,
                "Plan's tree keeps the canvas in the centre (spec §3.1), so the "
                + "right-hand column is the canvas's — \(type)")
        }
    }

    /// The control, and the half that says the hoist did not break anything:
    /// every segment that does NOT centre the canvas still routes by project
    /// type exactly as before. Without this, `inspectorRoute` returning
    /// `.canvas` unconditionally would pass the two tests above.
    ///
    /// The loop excludes by the PREDICATE rather than by naming `.canvas`, so a
    /// future segment that centres the canvas leaves this loop and joins the
    /// positive assertions in one edit instead of silently failing here.
    func test_everyOtherSegmentStillRoutesByProjectType() {
        for segment in BinderSegment.allCases where !segment.centresTheCanvas {
            XCTAssertEqual(
                ProjectWindow.inspectorRoute(binderSegment: segment, projectType: .collection),
                .collectionPiece,
                "a Collection still gets its piece inspector on .\(segment)")
            XCTAssertEqual(
                ProjectWindow.inspectorRoute(binderSegment: segment, projectType: .novel),
                .segment,
                "and a novel still dispatches on the segment for .\(segment)")
        }
    }

    /// The sibling, found by asking the same question of every other
    /// project-type split in the window rather than inferring that the editor
    /// column was fine because "the canvas draws".
    ///
    /// `editorPane` showed a Collection's reference placeholder whenever a
    /// reference piece was selected, with no reference to the segment — and
    /// nothing clears `selectedItemId` but a delete, so it survives the persona
    /// switch. Select a reference piece in Pieces, press ⌘1, and the centre
    /// column showed the placeholder while the canvas never appeared.
    ///
    /// **Both canvas-centring segments, and `.canvas` now answers `.canvas`
    /// rather than `.segment`** — slice 2 gave the route a case of its own so
    /// that one branch of `editorPane` serves both segments and the canvas is
    /// not rebuilt on a flip (`CanvasTreeSegmentMountTests` measures what that
    /// costs). `.tree` is asserted positively for the reason the inspector's
    /// twin is: an exclusion from the control loop alone would let it fall out
    /// with nothing red, and in a Collection with a reference piece selected
    /// that means Plan's tree shows the reference placeholder and the canvas
    /// never appears at all.
    func test_theCanvasDrawsEvenWithAReferencePieceStillSelected() {
        for segment in [BinderSegment.canvas, .tree] {
            XCTAssertEqual(
                ProjectWindow.editorRoute(binderSegment: segment, projectType: .collection,
                                          selectedPieceIsReference: true),
                .canvas,
                ".\(segment) owns the centre column; a piece selected in some "
                + "other segment does not get to keep it")
            XCTAssertEqual(
                ProjectWindow.editorRoute(binderSegment: segment, projectType: .collection,
                                          selectedPieceIsReference: false),
                .canvas)
        }
    }

    /// Its control: on every segment that does not centre the canvas, a selected
    /// reference piece still takes the editor column, which is the behaviour
    /// that was already right.
    func test_aReferencePieceStillTakesTheEditorColumnOnEveryOtherSegment() {
        for segment in BinderSegment.allCases where !segment.centresTheCanvas {
            XCTAssertEqual(
                ProjectWindow.editorRoute(binderSegment: segment, projectType: .collection,
                                          selectedPieceIsReference: true),
                .collectionReference,
                "a reference piece still shows its placeholder on .\(segment)")
            XCTAssertEqual(
                ProjectWindow.editorRoute(binderSegment: segment, projectType: .collection,
                                          selectedPieceIsReference: false),
                .segment,
                "and a non-reference piece never did")
        }
    }
}
