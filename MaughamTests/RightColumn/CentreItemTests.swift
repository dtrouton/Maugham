import XCTest
import MaughamCore
@testable import Maugham

/// **A statement or History opened in the centre** (shell plan 3 Task 3): the
/// subject it opens, when it clears, and the cover it draws. Pure values.
final class CentreItemTests: XCTestCase {

    private let structure: [StructureItem] = [
        StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md"),
    ]

    func test_openingTheIntentInTheCentreOpensItsPiece() {
        let from = WindowSubject(open: .canvas, faces: .item("part-1"), beside: .lessons)
        let intent = ProjectWindow.openingInCentre(
            .statement(kind: .intent, scope: .document("ch-1")), subject: from)
        XCTAssertEqual(intent.open, .item("ch-1"))
        XCTAssertEqual(intent.faces, .item("ch-1"))
        XCTAssertEqual(intent.beside, .lessons, "what is pulled up stays")
        XCTAssertEqual(ProjectWindow.openingInCentre(.history(docId: "ch-1"), subject: from).open,
                       .item("ch-1"))
        for kind in [Statement.Kind.intent, .lessons, .firstReader, .visualLanguage] {
            let opened = ProjectWindow.openingInCentre(
                .statement(kind: kind, scope: .project), subject: from)
            XCTAssertEqual(opened.open, .project, "\(kind)")
            XCTAssertEqual(opened.faces, .project, "\(kind)")
        }
        // Two places, one statement: the pulled-up view asks whether the
        // centre holds it.
        let lessons = CentreItem.statement(kind: .lessons, scope: .project)
        XCTAssertTrue(ProjectWindow.statementIsInTheCentre(kind: .lessons, scope: .project,
                                                           centreItem: lessons))
        XCTAssertFalse(ProjectWindow.statementIsInTheCentre(kind: .firstReader, scope: .project,
                                                            centreItem: lessons))
        XCTAssertFalse(ProjectWindow.statementIsInTheCentre(kind: .lessons, scope: .project,
                                                            centreItem: nil))
    }

    func test_aCentreItemClearsWhenTheCentreMoves() {
        let item = CentreItem.history(docId: "ch-1")
        XCTAssertEqual(ProjectWindow.centreItemAfterOpenChange(item, from: .item("ch-1"),
                                                               to: .item("ch-1")), item)
        for moved in [BinderSubject.project, .canvas, .item("ch-2"), .research("r")] {
            XCTAssertNil(ProjectWindow.centreItemAfterOpenChange(item, from: .item("ch-1"),
                                                                 to: moved), "\(moved)")
        }
    }

    private func route(_ subject: WindowSubject, centreItem: CentreItem?) -> CentreRoute {
        ProjectWindow.centreRoute(subject: subject, bookView: .outline, projectType: .novel,
                                  structure: structure, preview: .nothingCompiled,
                                  centreItem: centreItem)
    }

    func test_aPublishCoverWinsOverACentreItem() {
        let lessons = CentreItem.statement(kind: .lessons, scope: .project)
        XCTAssertEqual(route(.book, centreItem: lessons),
                       .editor(altitude: .outline, cover: .centreItem(lessons)))
        let piece = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))
        XCTAssertEqual(route(piece, centreItem: .history(docId: "ch-1")),
                       .editor(altitude: nil, cover: .centreItem(.history(docId: "ch-1"))))
        XCTAssertEqual(route(piece, centreItem: nil), .editor(altitude: nil, cover: nil))
        // An edition's cover (here its no-book notice) stands over the item.
        let edition = WindowSubject(open: .edition(language: "es"), faces: .item("ch-1"))
        let published = route(edition, centreItem: nil)
        guard case .editor(_, let cover?) = published else {
            return XCTFail("premise: the edition draws a publish cover, got \(published)")
        }
        XCTAssertNotEqual(cover, .centreItem(lessons))
        XCTAssertEqual(route(edition, centreItem: lessons), published, "the publish cover wins")
    }
}
