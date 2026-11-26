import XCTest
import MaughamCore
@testable import Maugham

/// **A figure subject's placement and centre route** (report plan 8a Task 5),
/// asked of the window's subject: a figure in `open` takes the centre, one in
/// `beside` shows in the right column, and the centre is otherwise untouched.
@MainActor
final class FigureSubjectPlacementTests: XCTestCase {

    private func route(_ subject: WindowSubject) -> CentreRoute {
        ProjectWindow.centreRoute(
            subject: subject, bookView: .outline, projectType: .novel,
            structure: CentreRouteTests.structure, preview: .nothingCompiled)
    }

    func test_placementPerPlace() {
        XCTAssertEqual(ProjectWindow.figureSubjectPlacement(
            subject: SubjectSamples.opened(.figure("f1"))), .takesTheCentre("f1"))
        XCTAssertEqual(ProjectWindow.figureSubjectPlacement(
            subject: WindowSubject(open: .canvas, faces: .canvas, beside: .figure("f1"))),
                       .pulledUp("f1"))
        // Only a figure moves anything: every other kind, in either place.
        for open in SubjectSamples.everyOpen where open.figureID == nil {
            XCTAssertEqual(ProjectWindow.figureSubjectPlacement(
                subject: SubjectSamples.opened(open)), .nothingMoves, "\(open)")
            XCTAssertEqual(ProjectWindow.figureSubjectPlacement(
                subject: WindowSubject(open: .project, faces: .project,
                                       beside: PulledUp(treeSubject: open))),
                           .nothingMoves, "\(open) beside")
        }
    }

    /// **The click rule gives a clicked figure the centre** — a figure is
    /// manuscript content — and the route shows it, whatever was open.
    func test_aClickedFigureTakesTheCentreWhateverWasOpen() {
        for open in SubjectSamples.everyOpen {
            let clicked = ClickRule.resolve(.figure("f1"), gesture: .click,
                                            current: SubjectSamples.opened(open),
                                            structure: CentreRouteTests.structure,
                                            projectType: .novel)
            XCTAssertEqual(route(clicked), .figure(id: "f1"), "from \(open)")
        }
    }

    func test_aFigureBesideRevealsTheRightColumnAndOneInTheCentreDoesNot() {
        var show = false
        var position = RightColumnPosition.brief
        ProjectWindow.revealPulledUp(
            subject: WindowSubject(open: .canvas, faces: .canvas, beside: .figure("f1")),
            showInspector: &show, position: &position)
        XCTAssertTrue(show)
        XCTAssertEqual(position, .pulledUp)
        // The subject's observer answers the same for the figure arriving.
        XCTAssertEqual(RightColumnContent.positionAfterSubjectChange(
            .brief, from: SubjectSamples.opened(.canvas),
            to: WindowSubject(open: .canvas, faces: .canvas, beside: .figure("f1")),
            previousFace: .brief, structure: CentreRouteTests.structure, projectType: .novel),
            .pulledUp)
        show = false; position = .brief
        ProjectWindow.revealPulledUp(subject: SubjectSamples.opened(.figure("f1")),
                                     showInspector: &show, position: &position)
        XCTAssertFalse(show, "the centre already shows it")
        XCTAssertEqual(position, .brief)
    }

    func test_theStatusFooterIsHiddenWhereAFigureTakesTheCentre() {
        XCTAssertFalse(ProjectWindow.showsStatusFooter(
            subject: SubjectSamples.opened(.figure("f1")),
            structure: CentreRouteTests.structure))
    }
}
