import XCTest
@testable import Maugham
import MaughamCore

/// **Which column shows what, asked over the whole product rather than the one
/// path a plan named** — every kind of subject `open` can be, on every project
/// type.
///
/// `inspectorRoute` and `editorRoute` both ask whether the centre column is
/// the board before they ask anything else, and both have shipped a defect by
/// asking it second.
///
/// **The smoke-found defect, 2026-07-28.** `RightColumn.inspectorPane` split
/// on project type *before* it consulted the canvas at all, and a Collection
/// took a branch with no canvas arm — so a Collection writer selecting a region
/// got the piece inspector for whatever manuscript item was last selected.
///
/// **`ProjectType.allCases`, never a hand-written list**, and
/// `SubjectSamples.everyOpen`, which its own census keeps whole.
final class CanvasRouteTests: XCTestCase {

    // MARK: - The right column

    func test_theCanvasReachesTheRegionInspectorOnEveryProjectType() {
        for type in ProjectType.allCases {
            XCTAssertEqual(
                ProjectWindow.inspectorRoute(subject: SubjectSamples.opened(.canvas),
                                             projectType: type),
                .canvas,
                "the canvas is the centre in a \(type) — there is ONE canvas per "
                + "project regardless of type (spec §2), so the type cannot be "
                + "allowed to decide this first")
        }
    }

    /// **The faces moving to a piece leave the region inspector in place**:
    /// the canvas is still the centre.
    func test_theRegionInspectorStaysWhenTheFacesMoveToAPiece() {
        let subject = WindowSubject(open: .canvas, faces: .item(SubjectSamples.pieceID))
        for type in ProjectType.allCases {
            XCTAssertEqual(ProjectWindow.inspectorRoute(subject: subject, projectType: type),
                           .canvas)
        }
    }

    /// **The control**: every subject whose centre is NOT the canvas still
    /// routes by project type. Without it, `inspectorRoute` returning `.canvas`
    /// unconditionally would pass the tests above.
    func test_everyOtherSubjectStillRoutesByProjectType() {
        for subject in Self.subjectsThatDoNotCentreTheCanvas {
            XCTAssertEqual(
                ProjectWindow.inspectorRoute(subject: subject, projectType: .collection),
                .collectionPiece,
                "a Collection still gets its piece inspector with \(subject.open) open")
            XCTAssertEqual(
                ProjectWindow.inspectorRoute(subject: subject, projectType: .novel),
                .document,
                "and a novel still shows the document's own inspector with \(subject.open) open")
        }
    }

    // MARK: - The centre column

    /// The sibling defect: `editorPane` showed a Collection's reference
    /// placeholder whenever a reference piece was selected, with no reference to
    /// the canvas at all. A click on a reference piece while the canvas is open
    /// moves the faces to it — the canvas keeps the centre.
    func test_theCanvasDrawsEvenWithAReferencePieceInTheFaces() {
        let subject = WindowSubject(open: .canvas, faces: .item(SubjectSamples.pieceID))
        XCTAssertEqual(
            ProjectWindow.editorRoute(subject: subject, projectType: .collection,
                                      selectedPieceIsReference: true),
            .canvas,
            "the canvas owns the centre column; a piece the faces are on does not "
            + "get to take it")
        XCTAssertEqual(
            ProjectWindow.editorRoute(subject: subject, projectType: .collection,
                                      selectedPieceIsReference: false),
            .canvas)
    }

    /// Its control: wherever the canvas is not open, a reference piece still
    /// takes the editor column.
    func test_aReferencePieceStillTakesTheEditorColumnWhereverTheCanvasIsNotOpen() {
        for subject in Self.subjectsThatDoNotCentreTheCanvas {
            XCTAssertEqual(
                ProjectWindow.editorRoute(subject: subject, projectType: .collection,
                                          selectedPieceIsReference: true),
                .collectionReference,
                "a reference piece still shows its placeholder with \(subject.open) open")
            XCTAssertEqual(
                ProjectWindow.editorRoute(subject: subject, projectType: .collection,
                                          selectedPieceIsReference: false),
                .editor,
                "and a non-reference piece never did")
        }
    }

    // MARK: - The exclusion

    /// Every sample subject whose centre is not the board.
    ///
    /// **The control's own control.** A filter that had gone empty — or one that
    /// excluded everything — would make both loops above pass in silence.
    static let subjectsThatDoNotCentreTheCanvas: [WindowSubject] =
        SubjectSamples.everySubject.filter { $0.open != .canvas }

    func test_theExclusionIsNeitherEmptyNorEverything() {
        XCTAssertFalse(Self.subjectsThatDoNotCentreTheCanvas.isEmpty)
        XCTAssertLessThan(Self.subjectsThatDoNotCentreTheCanvas.count,
                          SubjectSamples.everySubject.count)
    }
}
