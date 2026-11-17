import XCTest
import MaughamCore
@testable import Maugham

/// The click rule: one table, one test per row
/// (`docs/superpowers/specs/2026-11-16-subject-resolve-brief-shell-design.md`).
final class ClickRuleTests: XCTestCase {

    private let structure: [StructureItem] = [
        StructureItem(id: "part-1", title: "Part One", type: .group, children: [
            StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md"),
        ]),
        StructureItem(id: "ch-2", title: "Two", type: .document, path: "two.md"),
    ]

    private func resolve(_ clicked: BinderSubject, _ gesture: ClickRule.Gesture,
                         from current: WindowSubject = .book) -> WindowSubject {
        ClickRule.resolve(clicked, gesture: gesture, current: current,
                          structure: structure, projectType: .novel)
    }

    private func ws(_ open: BinderSubject, _ faces: BinderSubject,
                    beside: BinderSubject? = nil) -> WindowSubject {
        WindowSubject(open: open, faces: faces, beside: beside)
    }

    func test_openInCentreOpensAndFacesTheClickedThing() {
        let r = resolve(.item("ch-1"), .openInCentre,
                        from: ws(.canvas, .item("ch-2"), beside: .research("r-1")))
        XCTAssertEqual(r, ws(.item("ch-1"), .item("ch-1"), beside: .research("r-1")))
    }

    func test_openInCentreOnTheBesideItemClearsBeside() {
        let r = resolve(.research("r-1"), .openInCentre,
                        from: ws(.item("ch-1"), .item("ch-1"), beside: .research("r-1")))
        XCTAssertEqual(r, ws(.research("r-1"), .research("r-1"), beside: nil))
    }

    func test_aPieceClickedOverTheCanvasOnlyMovesTheFaces() {
        let r = resolve(.item("ch-1"), .click, from: ws(.canvas, .project))
        XCTAssertEqual(r, ws(.canvas, .item("ch-1")))
    }

    func test_aPieceClickedOverAnEditionOnlyMovesTheFaces() {
        let r = resolve(.item("ch-1"), .click, from: ws(.edition(language: "es"), .project))
        XCTAssertEqual(r, ws(.edition(language: "es"), .item("ch-1")))
    }

    func test_aPieceClickedOverAPieceOpensIt() {
        let r = resolve(.item("ch-2"), .click, from: ws(.item("ch-1"), .item("ch-1")))
        XCTAssertEqual(r, ws(.item("ch-2"), .item("ch-2")))
    }

    func test_aPieceClickedOverTheBooksCardsOpensThePiece() {
        let r = resolve(.item("ch-1"), .click, from: .book)
        XCTAssertEqual(r, ws(.item("ch-1"), .item("ch-1")))
    }

    func test_aResearchClickBesidesAndLeavesOpenAndFaces() {
        let r = resolve(.research("r-2"), .click,
                        from: ws(.item("ch-1"), .item("ch-1"), beside: .research("r-1")))
        XCTAssertEqual(r, ws(.item("ch-1"), .item("ch-1"), beside: .research("r-2")))
    }

    func test_aResearchClickNeverMovesTheFaces() {
        for current in [WindowSubject.book, ws(.canvas, .item("ch-1")),
                        ws(.edition(language: "es"), .figure("f-1"))] {
            let r = resolve(.research("r-1"), .click, from: current)
            XCTAssertEqual(r.open, current.open)
            XCTAssertEqual(r.faces, current.faces)
            XCTAssertEqual(r.beside, .research("r-1"))
        }
    }

    func test_aFigureOpensAndFaces() {
        XCTAssertEqual(resolve(.figure("f-1"), .click, from: ws(.canvas, .project)),
                       ws(.figure("f-1"), .figure("f-1")))
    }

    func test_theProjectRowOpensTheBook() {
        XCTAssertEqual(resolve(.project, .click, from: ws(.item("ch-1"), .item("ch-1"))),
                       .book)
    }

    func test_aPartOpensAndFaces() {
        XCTAssertEqual(resolve(.item("part-1"), .click, from: ws(.canvas, .project)),
                       ws(.item("part-1"), .item("part-1")))
    }

    func test_inboxCanvasPaletteAndEditionOpenAndFace() {
        for s in [BinderSubject.inbox, .canvas, .palette, .edition(language: "sr")] {
            XCTAssertEqual(resolve(s, .click, from: ws(.item("ch-1"), .item("ch-1"))),
                           ws(s, s))
        }
    }

    func test_anItemNotInStructureIsTreatedAsAPiece() {
        XCTAssertEqual(resolve(.item("ghost"), .click, from: ws(.canvas, .project)),
                       ws(.canvas, .item("ghost")))
    }
}
