import XCTest
import MaughamCore
@testable import Maugham

/// **What each right-column position shows** (shell plan 3, the table), the
/// position a subject change leaves, and the keys' and the strip's answers.
/// Pure functions; nothing is mounted or pressed (tripwire 33).
final class RightColumnContentTests: XCTestCase {

    private let structure: [StructureItem] = [
        StructureItem(id: "part-1", title: "Part One", type: .group, children: [
            StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md"),
        ]),
        StructureItem(id: "ch-2", title: "Two", type: .document, path: "two.md"),
        StructureItem(id: "ref-1", title: "Elsewhere", type: .document, path: "ref.md",
                      pieceKind: .reference),
    ]

    private func content(_ position: RightColumnPosition, _ subject: WindowSubject,
                         translating: String? = nil) -> RightColumnContent {
        RightColumnContent.of(position: position, subject: subject,
                              translationLanguage: translating, structure: structure,
                              projectType: .novel)
    }

    private func after(_ position: RightColumnPosition, from old: WindowSubject,
                       to new: WindowSubject,
                       previousFace: RightColumnPosition = .brief) -> RightColumnPosition {
        RightColumnContent.positionAfterSubjectChange(position, from: old, to: new,
                                                      previousFace: previousFace,
                                                      structure: structure,
                                                      projectType: .novel)
    }

    private func ws(_ open: BinderSubject, _ faces: BinderSubject? = nil,
                    beside: PulledUp? = nil) -> WindowSubject {
        WindowSubject(open: open, faces: faces ?? open, beside: beside)
    }

    func test_eachPositionShowsWhatTheTableSays() {
        // To resolve.
        XCTAssertEqual(content(.resolve, ws(.item("ch-1")), translating: "es"),
                       .translationReview)
        XCTAssertEqual(content(.resolve, ws(.edition(language: "es"))),
                       .desk(language: "es"))
        XCTAssertEqual(content(.resolve, ws(.item("ch-1"))), .resolve)
        XCTAssertEqual(content(.resolve, .book), .resolve)
        // Brief: the faces' scope, whatever it is.
        XCTAssertEqual(content(.brief, ws(.item("ch-1"))), .brief(.piece(docId: "ch-1")))
        XCTAssertEqual(content(.brief, ws(.item("part-1"))),
                       .brief(.part(groupId: "part-1", docIds: ["ch-1"])))
        XCTAssertEqual(content(.brief, .book), .brief(.book))
        XCTAssertEqual(content(.brief, ws(.edition(language: "es"))),
                       .brief(.edition(language: "es")))
        XCTAssertEqual(content(.brief, ws(.item("ref-1"))), .brief(.elsewhere(docId: "ref-1")))
        XCTAssertEqual(content(.brief, ws(.canvas)), .brief(.outside))
        XCTAssertEqual(content(.brief, ws(.canvas, .item("ch-2"))),
                       .brief(.piece(docId: "ch-2")), "the faces, not the centre")
        // Pulled up: the thing, over whatever the centre holds.
        XCTAssertEqual(content(.pulledUp, ws(.canvas, beside: .lessons)), .pulledUp(.lessons))
        XCTAssertEqual(content(.pulledUp, ws(.item("ch-1"), beside: .research("r-1"))),
                       .pulledUp(.research("r-1")))
        // Nothing pulled up: the centre's details.
        XCTAssertEqual(content(.pulledUp, ws(.canvas)), .centreDetails(.canvas))
        XCTAssertEqual(content(.pulledUp, ws(.canvas, .item("ch-2"))), .centreDetails(.canvas))
        XCTAssertEqual(content(.pulledUp, ws(.figure("f-1"))), .centreDetails(.figure("f-1")))
        XCTAssertEqual(content(.pulledUp, ws(.research("r-1"))),
                       .centreDetails(.research("r-1")))
        XCTAssertEqual(content(.pulledUp, ws(.item("ref-1"))),
                       .centreDetails(.referencePiece("ref-1")))
        // Nothing of the above.
        for open in [BinderSubject.item("ch-1"), .item("part-1"), .project, .inbox, .palette,
                     .edition(language: "es")] {
            XCTAssertEqual(content(.pulledUp, ws(open)), .nothingPulledUp, "\(open)")
            XCTAssertFalse(RightColumnContent.offersPulledUp(ws(open), structure: structure,
                                                             projectType: .novel),
                           "\(open): the position is hidden")
        }
        XCTAssertTrue(RightColumnContent.offersPulledUp(ws(.item("ch-1"), beside: .lessons),
                                                        structure: structure,
                                                        projectType: .novel))
    }

    func test_theDeskShowsOnlyWhileAnEditionIsTheFaces() {
        XCTAssertEqual(content(.resolve, ws(.edition(language: "sr"))), .desk(language: "sr"))
        XCTAssertEqual(content(.resolve, ws(.edition(language: "sr"), .item("ch-1"))), .resolve,
                       "a piece clicked under the edition: its To resolve")
        XCTAssertEqual(content(.resolve, ws(.item("ch-1"), .edition(language: "sr"))),
                       .desk(language: "sr"))
        XCTAssertEqual(content(.brief, ws(.edition(language: "sr"))),
                       .brief(.edition(language: "sr")), "only To resolve is the desk")
    }

    func test_translationReviewShowsOnlyOnTheOpenPiece() {
        XCTAssertEqual(content(.resolve, ws(.item("ch-1")), translating: "es"),
                       .translationReview)
        XCTAssertEqual(content(.resolve, ws(.canvas, .item("ch-1")), translating: "es"),
                       .resolve, "the faces' piece is not open")
        XCTAssertEqual(content(.resolve, ws(.item("ch-2"), .item("ch-1")), translating: "es"),
                       .resolve, "the faces are not what is open")
        XCTAssertEqual(content(.resolve, ws(.item("part-1")), translating: "es"), .resolve,
                       "a Part is no piece")
        XCTAssertEqual(content(.resolve, .book, translating: "es"), .resolve)
        XCTAssertEqual(content(.brief, ws(.item("ch-1")), translating: "es"),
                       .brief(.piece(docId: "ch-1")), "only To resolve is the review")
    }

    func test_pullingSomethingUpMovesTheColumnToIt() {
        let before = ws(.item("ch-1"))
        for position in RightColumnPosition.allCases {
            XCTAssertEqual(after(position, from: before,
                                 to: ClickRule.pullUp(.firstReader, current: before)),
                           .pulledUp)
        }
        let withNote = ClickRule.pullUp(.research("r-1"), current: before)
        XCTAssertEqual(after(.brief, from: withNote,
                             to: ClickRule.pullUp(.research("r-2"), current: withNote)),
                       .pulledUp, "a different thing")
        // The same thing staying beside across a click is no arrival.
        let moved = ClickRule.resolve(.item("ch-2"), gesture: .click, current: withNote,
                                      structure: structure, projectType: .novel)
        XCTAssertEqual(after(.brief, from: withNote, to: moved), .brief)
    }

    func test_closingItReturnsToTheFaceBefore() {
        let withNote = ws(.item("ch-1"), beside: .research("r-1"))
        let closed = ClickRule.putAway(current: withNote)
        XCTAssertEqual(after(.pulledUp, from: withNote, to: closed, previousFace: .brief), .brief)
        XCTAssertEqual(after(.pulledUp, from: withNote, to: closed, previousFace: .resolve),
                       .resolve)
        XCTAssertEqual(after(.pulledUp, from: withNote, to: closed, previousFace: .pulledUp),
                       .resolve, "never back onto an empty position")
        XCTAssertEqual(after(.brief, from: withNote, to: closed), .brief,
                       "closed while another face shows: nothing moves")
    }

    func test_closingItOverTheCanvasKeepsTheCanvasDetails() {
        let withNote = ws(.canvas, beside: .research("r-1"))
        let closed = ClickRule.putAway(current: withNote)
        XCTAssertEqual(after(.pulledUp, from: withNote, to: closed), .pulledUp)
        XCTAssertEqual(content(.pulledUp, closed), .centreDetails(.canvas))
    }

    func test_clickingTheCanvasRowShowsItsDetails() {
        let piece = ws(.item("ch-1"))
        let canvas = ClickRule.resolve(.canvas, gesture: .click, current: piece,
                                       structure: structure, projectType: .novel)
        XCTAssertEqual(after(.resolve, from: piece, to: canvas), .pulledUp)
        XCTAssertEqual(after(.brief, from: piece, to: canvas), .pulledUp)
        XCTAssertEqual(content(.pulledUp, canvas), .centreDetails(.canvas))
        // A piece clicked on the canvas moves the faces off it: the details
        // stay (the canvas is still the centre) and the position with them.
        let pieceOnCanvas = ClickRule.resolve(.item("ch-2"), gesture: .click, current: canvas,
                                              structure: structure, projectType: .novel)
        XCTAssertEqual(after(.pulledUp, from: canvas, to: pieceOnCanvas), .pulledUp)
        // Leaving the canvas for a piece leaves the empty position.
        let left = ClickRule.resolve(.item("ch-2"), gesture: .openInCentre, current: canvas,
                                     structure: structure, projectType: .novel)
        XCTAssertEqual(after(.pulledUp, from: canvas, to: left, previousFace: .brief), .brief)
    }

    func test_historyKeyPullsUpTheFacesPieceElseTheOpenOne() {
        func history(_ subject: WindowSubject) -> PulledUp? {
            RightColumnContent.pulledUp(for: .historyOfTheFaces, subject: subject,
                                        structure: structure)
        }
        XCTAssertEqual(history(ws(.canvas, .item("ch-2"))), .history(docId: "ch-2"))
        XCTAssertEqual(history(ws(.item("ch-1"), .item("part-1"))), .history(docId: "ch-1"),
                       "a Part in the faces: the open piece")
        XCTAssertEqual(history(ws(.item("ch-1"), .project)), .history(docId: "ch-1"))
        XCTAssertNil(history(ws(.canvas)), "nothing is a piece: the key is inert")
        XCTAssertNil(history(.book))
        XCTAssertEqual(RightColumnContent.pulledUp(for: .lessons, subject: .book,
                                                   structure: structure), .lessons)
        XCTAssertEqual(RightColumnContent.pulledUp(for: .firstReader, subject: .book,
                                                   structure: structure), .firstReader)
        XCTAssertEqual(RightColumnContent.pulledUp(for: .visualLanguage, subject: .book,
                                                   structure: structure), .visualLanguage)
    }

    func test_theStripClickPutsTheFacesOnTheOpenPiece() {
        let underPart = ws(.item("ch-1"), .item("part-1"), beside: .lessons)
        let clicked = RightColumnContent.facesForTheStrip(underPart, structure: structure)
        XCTAssertEqual(clicked.faces, .item("ch-1"))
        XCTAssertEqual(clicked.open, .item("ch-1"))
        XCTAssertEqual(clicked.beside, .lessons, "what is pulled up stays")
        XCTAssertEqual(content(.brief, clicked), .brief(.piece(docId: "ch-1")))
        for unmoved in [ws(.canvas, .item("ch-2")), .book, ws(.item("part-1"))] {
            XCTAssertEqual(RightColumnContent.facesForTheStrip(unmoved, structure: structure),
                           unmoved, "\(unmoved.open) is no piece")
        }
    }

    func test_thePositionsSpellTheirKeysAndHelp() {
        XCTAssertEqual(RightColumnPosition.allCases.map(\.keyEquivalent), ["1", "2", "3"])
        XCTAssertEqual(RightColumnPosition.allCases.map(\.systemImageName),
                       ["tray", "target", "pin"])
        XCTAssertEqual(RightColumnPosition.pulledUp.helpText,
                       "Pulled up — the one thing you pulled up from the tree (⌘3)")
    }
}
