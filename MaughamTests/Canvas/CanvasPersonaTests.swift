import XCTest
@testable import Maugham
import MaughamCore

final class CanvasPersonaTests: XCTestCase {

    func test_planOffersTheCanvasFirstOnEveryProjectType() {
        for type in [ProjectType.novel, .screenplay, .collection] {
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
            for type in [ProjectType.novel, .screenplay, .collection] {
                XCTAssertFalse(persona.binderSegments(for: type).contains(.canvas),
                               "\(persona) must not offer the canvas")
            }
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
        for type in [ProjectType.novel, .screenplay, .collection] {
            XCTAssertEqual(
                ProjectWindow.inspectorRoute(binderSegment: .canvas, projectType: type),
                .canvas,
                "the canvas segment must reach the region inspector in a \(type) — "
                + "there is ONE canvas per project regardless of type (spec §2), so "
                + "the type cannot be allowed to decide this first")
        }
    }

    /// The control, and the half that says the hoist did not break anything:
    /// every OTHER segment still routes by project type exactly as before.
    /// Without this, `inspectorRoute` returning `.canvas` unconditionally would
    /// pass the test above.
    func test_everyOtherSegmentStillRoutesByProjectType() {
        for segment in BinderSegment.allCases where segment != .canvas {
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
    func test_theCanvasDrawsEvenWithAReferencePieceStillSelected() {
        XCTAssertEqual(
            ProjectWindow.editorRoute(binderSegment: .canvas, projectType: .collection,
                                      selectedPieceIsReference: true),
            .segment,
            "the canvas segment owns the centre column; a piece selected in some "
            + "other segment does not get to keep it")
    }

    /// Its control: on every other segment a selected reference piece still
    /// takes the editor column, which is the behaviour that was already right.
    func test_aReferencePieceStillTakesTheEditorColumnOnEveryOtherSegment() {
        for segment in BinderSegment.allCases where segment != .canvas {
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
