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
                    beside: PulledUp? = nil) -> WindowSubject {
        WindowSubject(open: open, faces: faces, beside: beside)
    }

    func test_openInCentreOpensAndFacesTheClickedThing() {
        let r = resolve(.item("ch-1"), .openInCentre,
                        from: ws(.canvas, .item("ch-2"), beside: .research("r-1")))
        XCTAssertEqual(r, WindowSubject(open: .item("ch-1"), faces: .item("ch-1"),
                                        beside: .research("r-1"), besideIsLatest: false))
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

    /// **A click on the row already beside puts it away** (shell p1 Task 3,
    /// controller ruling 2) — the tree's own dismissal; open and faces stay.
    func test_aClickOnTheRowAlreadyBesideDismissesIt() {
        for current in [ws(.item("ch-1"), .item("ch-1"), beside: .research("r-1")),
                        ws(.canvas, .item("ch-2"), beside: .research("r-1"))] {
            let r = resolve(.research("r-1"), .click, from: current)
            XCTAssertEqual(r, ws(current.open, current.faces, beside: nil))
        }
        // Control: a different note replaces it rather than dismissing.
        XCTAssertEqual(
            resolve(.research("r-2"), .click,
                    from: ws(.item("ch-1"), .item("ch-1"), beside: .research("r-1"))).beside,
            .research("r-2"))
    }

    /// **Going to a thing from outside the tree** never puts away what is
    /// beside: a link or a Show naming the note already beside, or the piece
    /// already in the faces, changes nothing; anything else is a click.
    func test_navigateIsAClickThatNeverDismisses() {
        let besideNote = ws(.item("ch-1"), .item("ch-1"), beside: .research("r-1"))
        XCTAssertEqual(ClickRule.navigate(to: .research("r-1"), current: besideNote,
                                          structure: structure, projectType: .novel),
                       besideNote)
        let canvas = ws(.canvas, .item("ch-1"))
        XCTAssertEqual(ClickRule.navigate(to: .item("ch-1"), current: canvas,
                                          structure: structure, projectType: .novel),
                       canvas)
        XCTAssertEqual(ClickRule.navigate(to: .item("ch-2"), current: canvas,
                                          structure: structure, projectType: .novel),
                       resolve(.item("ch-2"), .click, from: canvas))
        XCTAssertEqual(ClickRule.navigate(to: nil, current: canvas,
                                          structure: structure, projectType: .novel),
                       .book, "nil is the Book")
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

    // MARK: - The part clicked last (shell p1 final fix, I1)

    /// **With a note beside, a piece clicked on the canvas lights its region.**
    /// `beside` persists across clicks, so "what is beside, else the faces"
    /// kept the note as the part clicked last and the canvas stayed dimmed
    /// around the note's card. The subject records the order instead.
    func test_aPieceClickedOnTheCanvasLightsItsRegionWithANoteBeside() {
        let research = [ResearchItem(id: "r-1", title: "Note", type: .asset,
                                     kind: .document, path: "research/note.md")]
        let withNote = resolve(.research("r-1"), .click, from: ws(.canvas, .canvas))
        XCTAssertEqual(CanvasSubject.resolve(withNote.lastClicked, in: structure,
                                             research: research),
                       .research("r-1"), "premise: the note's card lights first")
        let clicked = resolve(.item("ch-2"), .click, from: withNote)
        XCTAssertEqual(clicked.beside, .research("r-1"), "premise: the note stays beside")
        XCTAssertEqual(clicked.lastClicked, .item("ch-2"))
        XCTAssertEqual(CanvasSubject.resolve(clicked.lastClicked, in: structure,
                                             research: research),
                       CanvasSubject.resolve(.item("ch-2"), in: structure,
                                             research: research),
                       "the piece clicked after the note is what the canvas lights")
    }

    /// The order follows the clicks either way, a dismissal hands it back to
    /// the faces, and a navigation to what is beside makes it last again
    /// without putting it away.
    func test_lastClickedFollowsTheOrderOfTheClicks() {
        let pieceThenNote = resolve(.research("r-1"), .click,
                                    from: resolve(.item("ch-1"), .click))
        XCTAssertEqual(pieceThenNote.lastClicked, .research("r-1"))
        let noteThenPiece = resolve(.item("ch-2"), .click, from: pieceThenNote)
        XCTAssertEqual(noteThenPiece.lastClicked, .item("ch-2"))
        XCTAssertFalse(noteThenPiece.besideIsLatest)
        let dismissed = resolve(.research("r-1"), .click, from: pieceThenNote)
        XCTAssertNil(dismissed.beside)
        XCTAssertEqual(dismissed.lastClicked, .item("ch-1"))
        let shown = ClickRule.navigate(to: .research("r-1"), current: noteThenPiece,
                                       structure: structure, projectType: .novel)
        XCTAssertEqual(shown.beside, .research("r-1"), "a navigation never puts it away")
        XCTAssertEqual(shown.lastClicked, .research("r-1"))
        XCTAssertTrue(ResearchRevealModifier.isAnArrival(from: noteThenPiece, to: shown),
                      "shown again: the column that previews it is revealed")
        XCTAssertFalse(ResearchRevealModifier.isAnArrival(from: pieceThenNote, to: dismissed),
                       "putting it away is not an arrival")
    }

    /// The order survives the window's save and a validation; a subject saved
    /// before it was recorded decodes as built whole.
    func test_theOrderRoundTripsAndOldStateDecodes() throws {
        let noteThenPiece = resolve(.item("ch-2"), .click,
                                    from: resolve(.research("r-1"), .click))
        let data = try JSONEncoder().encode(noteThenPiece)
        XCTAssertEqual(try JSONDecoder().decode(WindowSubject.self, from: data), noteThenPiece)
        XCTAssertEqual(noteThenPiece.validated(structure: structure, researchIDs: ["r-1"],
                                               figureIDs: [], editionLanguages: []),
                       noteThenPiece)
        let old = Data(#"{"open":{"kind":"project"},"faces":{"kind":"project"},"beside":{"kind":"research","id":"r-1"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WindowSubject.self, from: old).lastClicked,
                       .research("r-1"))
    }
}
