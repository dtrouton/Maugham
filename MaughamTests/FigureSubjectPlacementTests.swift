import XCTest
import MaughamCore
@testable import Maugham

/// **A figure subject's placement and centre route** (report plan 8a Task 5).
@MainActor
final class FigureSubjectPlacementTests: XCTestCase {

    private func route(_ persona: Persona, _ subject: BinderSubject?) -> CentreRoute {
        ProjectWindow.centreRoute(
            persona: persona, subject: subject, projectType: .novel,
            structure: CentreRouteTests.structure, showsPaletteWall: false,
            preview: .nothingCompiled)
    }

    func test_placementPerPersona() {
        let subject = BinderSubject.figure("f1")
        XCTAssertEqual(ProjectWindow.figureSubjectPlacement(persona: .author, subject: subject),
                       .takesTheCentre("f1"))
        XCTAssertEqual(ProjectWindow.figureSubjectPlacement(persona: .review, subject: subject),
                       .takesTheCentre("f1"))
        XCTAssertEqual(ProjectWindow.figureSubjectPlacement(persona: .plan, subject: subject),
                       .besideTheCanvas("f1"))
        XCTAssertEqual(ProjectWindow.figureSubjectPlacement(persona: .publish, subject: subject),
                       .nothingMoves)
        for persona in Persona.allCases {
            XCTAssertEqual(ProjectWindow.figureSubjectPlacement(persona: persona, subject: .project),
                           .nothingMoves)
            XCTAssertEqual(ProjectWindow.figureSubjectPlacement(persona: persona, subject: .research("r")),
                           .nothingMoves)
        }
    }

    func test_centreRoutePerPersona() {
        let subject = BinderSubject.figure("f1")
        XCTAssertEqual(route(.author, subject), .figure(id: "f1"))
        XCTAssertEqual(route(.review, subject), .figure(id: "f1"))
        // Plan: the canvas stays the single mount.
        XCTAssertEqual(route(.plan, subject), .canvas)
        // Publish: nothing moves — the project at altitude, as for `.project`.
        XCTAssertEqual(route(.publish, subject), route(.publish, .project))
    }

    func test_planRevealsTheRightColumnForAFigure() {
        var show = false
        var segment = DetailSegment.inbox
        ProjectWindow.revealResearchColumn(persona: .plan, subject: .figure("f1"),
                                           showInspector: &show, detailSegment: &segment)
        XCTAssertTrue(show)
        XCTAssertEqual(segment, .inspector)
        for persona in [Persona.author, .review, .publish] {
            show = false; segment = .inbox
            ProjectWindow.revealResearchColumn(persona: persona, subject: .figure("f1"),
                                               showInspector: &show, detailSegment: &segment)
            XCTAssertFalse(show, "\(persona)")
            XCTAssertEqual(segment, .inbox, "\(persona)")
        }
    }

    func test_theStatusFooterIsHiddenWhereAFigureTakesTheCentre() {
        XCTAssertFalse(ProjectWindow.showsStatusFooter(
            persona: .author, subject: .figure("f1"), showsPaletteWall: false,
            structure: CentreRouteTests.structure))
    }
}
