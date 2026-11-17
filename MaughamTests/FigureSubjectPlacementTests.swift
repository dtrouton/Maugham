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
                       .besideTheCanvas("f1"))
        // Only a figure moves anything: every other kind, in either place.
        for open in SubjectSamples.everyOpen where open.figureID == nil {
            XCTAssertEqual(ProjectWindow.figureSubjectPlacement(
                subject: SubjectSamples.opened(open)), .nothingMoves, "\(open)")
            XCTAssertEqual(ProjectWindow.figureSubjectPlacement(
                subject: WindowSubject(open: .project, faces: .project, beside: open)),
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
        var segment = DetailSegment.tasks
        ProjectWindow.revealResearchColumn(
            subject: WindowSubject(open: .canvas, faces: .canvas, beside: .figure("f1")),
            showInspector: &show, detailSegment: &segment)
        XCTAssertTrue(show)
        XCTAssertEqual(segment, .inspector)
        show = false; segment = .tasks
        ProjectWindow.revealResearchColumn(subject: SubjectSamples.opened(.figure("f1")),
                                           showInspector: &show, detailSegment: &segment)
        XCTAssertFalse(show, "the centre already shows it")
        XCTAssertEqual(segment, .tasks)
    }

    func test_theStatusFooterIsHiddenWhereAFigureTakesTheCentre() {
        XCTAssertFalse(ProjectWindow.showsStatusFooter(
            subject: SubjectSamples.opened(.figure("f1")),
            structure: CentreRouteTests.structure))
    }
}
