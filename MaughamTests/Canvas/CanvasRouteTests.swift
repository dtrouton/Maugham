import XCTest
@testable import Maugham
import MaughamCore

/// **Which column shows what, asked over the whole product rather than the one
/// path a plan named.**
///
/// This is `CanvasPersonaTests` minus its two binder-registry halves, which died
/// with `BinderSegment` in shell-finish stage 2b Task 7. What survives is the
/// part that was never about the strip: `inspectorRoute` and `editorRoute` both
/// ask whether the centre column is the board before they ask anything else, and
/// both have shipped a defect by asking it second.
///
/// **The smoke-found defect, 2026-07-28.** `ProjectWindow.inspectorPane` split
/// on project type *before* it consulted the canvas at all, and a Collection
/// took a branch with no canvas arm — so a Collection writer selecting a region
/// got the piece inspector for whatever manuscript item was last selected.
/// Denver writes in Collections, so the region inspector was unreachable for the
/// person it was built for. Every review of the slice looked at the switch the
/// plan named; nobody asked whether there were two inspector paths.
///
/// **`ProjectType.allCases`, never a hand-written list.** These loops read
/// `[.novel, .screenplay, .collection]` until 2026-07-28 and `ProjectType` has
/// four cases — `.shortStory` was never asked. Nothing was broken, but the point
/// of extracting a decision into a pure function is to ask it over *all* its
/// inputs, and a hardcoded list is the sampling that defeats it.
final class CanvasRouteTests: XCTestCase {

    // MARK: - The right column

    func test_planReachesTheRegionInspectorOnEveryProjectType() {
        for type in ProjectType.allCases {
            XCTAssertEqual(
                ProjectWindow.inspectorRoute(persona: .plan, projectType: type),
                .canvas,
                "Plan's centre column is the board in a \(type) — there is ONE "
                + "canvas per project regardless of type (spec §2), so the type "
                + "cannot be allowed to decide this first")
        }
    }

    /// **The control, and the half that says the hoist did not break anything:**
    /// every persona that does NOT centre the board still routes by project type
    /// exactly as before. Without it, `inspectorRoute` returning `.canvas`
    /// unconditionally would pass the test above.
    ///
    /// The loop excludes by the PREDICATE rather than by naming Plan, so a
    /// future persona that centres the board leaves this loop and joins the
    /// positive assertion in one edit instead of silently failing here.
    func test_everyOtherPersonaStillRoutesByProjectType() {
        for persona in Self.personasThatDoNotCentreTheCanvas {
            XCTAssertEqual(
                ProjectWindow.inspectorRoute(persona: persona, projectType: .collection),
                .collectionPiece,
                "a Collection still gets its piece inspector in \(persona)")
            XCTAssertEqual(
                ProjectWindow.inspectorRoute(persona: persona, projectType: .novel),
                .document,
                "and a novel still shows the document's own inspector in \(persona)")
        }
    }

    // MARK: - The centre column

    /// The sibling defect, found by asking the same question of every other
    /// project-type split in the window rather than inferring that the editor
    /// column was fine because "the canvas draws".
    ///
    /// `editorPane` showed a Collection's reference placeholder whenever a
    /// reference piece was selected, with no reference to the canvas at all —
    /// and nothing clears the subject but a delete, so it survives a persona
    /// switch. Select a reference piece in Pieces, press ⌘1, and the centre
    /// column showed the placeholder while the canvas never appeared.
    func test_theCanvasDrawsEvenWithAReferencePieceStillSelected() {
        XCTAssertEqual(
            ProjectWindow.editorRoute(persona: .plan, projectType: .collection,
                                      selectedPieceIsReference: true),
            .canvas,
            "Plan owns the centre column; a piece selected in the tree does not "
            + "get to keep it")
        XCTAssertEqual(
            ProjectWindow.editorRoute(persona: .plan, projectType: .collection,
                                      selectedPieceIsReference: false),
            .canvas)
    }

    /// Its control: in every persona that does not centre the board, a selected
    /// reference piece still takes the editor column, which is the behaviour
    /// that was already right.
    func test_aReferencePieceStillTakesTheEditorColumnInEveryOtherPersona() {
        for persona in Self.personasThatDoNotCentreTheCanvas {
            XCTAssertEqual(
                ProjectWindow.editorRoute(persona: persona, projectType: .collection,
                                          selectedPieceIsReference: true),
                .collectionReference,
                "a reference piece still shows its placeholder in \(persona)")
            XCTAssertEqual(
                ProjectWindow.editorRoute(persona: persona, projectType: .collection,
                                          selectedPieceIsReference: false),
                .editor,
                "and a non-reference piece never did")
        }
    }

    // MARK: - The exclusion

    /// Every persona whose centre column is not the board.
    ///
    /// **The control's own control.** A filter that had gone empty — or one that
    /// excluded everything — would make both loops above pass in silence, which
    /// is how a census degrades into an exclusion list.
    static let personasThatDoNotCentreTheCanvas: [Persona] =
        Persona.allCases.filter { !$0.centresTheCanvas }

    func test_theExclusionIsNeitherEmptyNorEverything() {
        XCTAssertFalse(Self.personasThatDoNotCentreTheCanvas.isEmpty,
                       "every persona centres the canvas — both control loops "
                       + "above would be vacuous")
        XCTAssertLessThan(
            Self.personasThatDoNotCentreTheCanvas.count, Persona.allCases.count,
            "no persona centres the canvas — the positive assertions above are "
            + "asserting something the control loops also cover")
    }
}
