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

    private func content(_ position: RightColumnPosition, _ subject: WindowSubject) -> RightColumnContent {
        RightColumnContent.of(position: position, subject: subject, structure: structure,
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
        XCTAssertEqual(content(.resolve, ws(.edition(language: "es"))), .resolve,
                       "an edition's To resolve is To resolve's own list (shell p4 Task 6)")
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

    /// Shell p4 Task 6 (re-made from the desk's rule): an edition on the
    /// faces is To resolve's own list, on either side of the window — there
    /// is no desk answer left.
    func test_anEditionOnTheFacesIsToResolvesOwnList() {
        XCTAssertEqual(content(.resolve, ws(.edition(language: "sr"))), .resolve)
        XCTAssertEqual(content(.resolve, ws(.edition(language: "sr"), .item("ch-1"))), .resolve,
                       "a piece clicked under the edition: its To resolve")
        XCTAssertEqual(content(.resolve, ws(.item("ch-1"), .edition(language: "sr"))), .resolve)
        XCTAssertEqual(content(.brief, ws(.edition(language: "sr"))),
                       .brief(.edition(language: "sr")))
    }

    /// **The reading language scopes To resolve; it is no pane of its own**
    /// (shell p4 Task 9, re-made from the translation review's table row):
    /// the column shows To resolve on every subject, and a piece faced while
    /// it is read in a language — switched on the open piece, or clicked
    /// while its edition is open — is that language's list. A Part, the Book,
    /// a piece faced over the canvas and Brief are not.
    func test_theReadingLanguageScopesToResolveAndIsNoPaneOfItsOwn() {
        func scope(_ subject: WindowSubject, switched: String?) -> ResolveScope {
            ResolveScope.of(subject.faces,
                            readIn: ReadingLanguage.of(subject: subject, switched: switched,
                                                       sourceLanguage: "en"),
                            sourceLanguage: "en", structure: structure, projectType: .novel)
        }
        for subject in [ws(.item("ch-1")), ws(.canvas, .item("ch-1")), ws(.item("part-1")), .book,
                        ws(.edition(language: "es"), .item("ch-1"))] {
            XCTAssertEqual(content(.resolve, subject), .resolve, "\(subject)")
        }
        XCTAssertEqual(scope(ws(.item("ch-1")), switched: "es"),
                       .pieceInLanguage(docId: "ch-1", language: "es"))
        XCTAssertEqual(scope(ws(.edition(language: "es"), .item("ch-1")), switched: nil),
                       .pieceInLanguage(docId: "ch-1", language: "es"),
                       "an edition open, a chapter faced: that chapter in that language")
        XCTAssertEqual(scope(ws(.canvas, .item("ch-1")), switched: "es"),
                       .piece(docId: "ch-1", includesBookLevel: false),
                       "the faces' piece is not the one read in a language")
        XCTAssertEqual(scope(ws(.item("part-1")), switched: "es"),
                       .pieces(docIds: ["ch-1"], includesBookLevel: false), "a Part is no piece")
        XCTAssertEqual(scope(ws(.edition(language: "es"), .project), switched: nil),
                       .pieces(docIds: ["ch-1", "ch-2"], includesBookLevel: true),
                       "the Book faced under an edition is the Book")
        XCTAssertEqual(scope(ws(.item("ref-1")), switched: "es"), .elsewhere(docId: "ref-1"))
        XCTAssertEqual(content(.brief, ws(.item("ch-1"))), .brief(.piece(docId: "ch-1")),
                       "Brief stays the piece's")
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
        // "Show me this" on the note already pulled up, after a piece was
        // clicked: it is the part clicked last again, and the column shows it.
        let pieceAfter = ClickRule.resolve(.item("ch-2"), gesture: .click, current: withNote,
                                           structure: structure, projectType: .novel)
        XCTAssertFalse(pieceAfter.besideIsLatest, "premise: the piece was clicked last")
        let shown = ClickRule.navigate(to: .research("r-1"), current: pieceAfter,
                                       structure: structure, projectType: .novel)
        XCTAssertEqual(shown.beside, .research("r-1"), "premise: still the same note")
        XCTAssertEqual(after(.brief, from: pieceAfter, to: shown), .pulledUp)
        XCTAssertEqual(after(.brief, from: pieceAfter,
                             to: ClickRule.pullUp(.research("r-1"), current: pieceAfter)),
                       .pulledUp, "a key on what is already there")
        // Agrees with the reveal it replaces.
        XCTAssertTrue(ResearchRevealModifier.isAnArrival(from: pieceAfter, to: shown))
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

    /// **The canvas's details cover what is pulled up while the canvas has a
    /// selection** (owner, 2026-11-20: a region selected under a pulled-up
    /// note, and ⌘3 "did nothing"). Only all three together cover; the
    /// column's answer is still the pulled-up thing, which nothing closes.
    func test_theCanvasSelectionCoversThePulledUpThingOnlyWhileTheCanvasIsTheCentre() {
        for canvas in [true, false] {
            for pulled in [true, false] {
                for selection in [true, false] {
                    XCTAssertEqual(
                        RightColumnContent.canvasDetailsCover(
                            canvasIsTheCentre: canvas, somethingIsPulledUp: pulled,
                            canvasHasASelection: selection, selectionIsNewerThanPullUp: true),
                        canvas && pulled && selection,
                        "canvas \(canvas), pulled up \(pulled), selection \(selection)")
                }
            }
        }
        // Drawing only: the answer and the subject are what they were.
        let covered = ws(.canvas, beside: .research("r-1"))
        XCTAssertEqual(content(.pulledUp, covered), .pulledUp(.research("r-1")))
        XCTAssertEqual(covered.beside, .research("r-1"))
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
        func history(_ subject: WindowSubject) -> PulledUp {
            RightColumnContent.pulledUp(for: .historyOfTheFaces, subject: subject,
                                        structure: structure)
        }
        XCTAssertEqual(history(ws(.canvas, .item("ch-2"))), .history(docId: "ch-2"))
        XCTAssertEqual(history(ws(.item("ch-1"), .item("part-1"))), .history(docId: "ch-1"),
                       "a Part in the faces: the open piece")
        XCTAssertEqual(history(ws(.item("ch-1"), .project)), .history(docId: "ch-1"))
        // No piece in the faces or the centre: the PROJECT's History — its
        // checkpoints, what the old History pane showed on the Book.
        XCTAssertEqual(history(ws(.canvas)), .projectHistory)
        XCTAssertEqual(history(.book), .projectHistory)
        XCTAssertEqual(history(ws(.item("part-1"))), .projectHistory, "a Part is not a piece")
        XCTAssertTrue(PulledUp.projectHistory.isProjectHistory)
        XCTAssertFalse(PulledUp.history(docId: "ch-1").isProjectHistory)
        XCTAssertEqual(PulledUp.projectHistory, .history(docId: BinderSubject.noDocumentSubject),
                       "the id `HistoryPane` already reads as no document")
        // It names no piece, so nothing can put it away on a restore; a
        // piece's History whose piece is gone still goes.
        var held = ws(.item("ch-1"))
        held.beside = .projectHistory
        XCTAssertEqual(held.validated(structure: structure, researchIDs: [], figureIDs: [],
                                      editionLanguages: []).beside, .projectHistory)
        held.beside = .history(docId: "gone")
        XCTAssertNil(held.validated(structure: structure, researchIDs: [], figureIDs: [],
                                    editionLanguages: []).beside)
        // Open in Centre puts it over the Book, and it is titled as itself.
        XCTAssertEqual(ProjectWindow.openingInCentre(
            .history(docId: BinderSubject.noDocumentSubject), subject: held).open, .project)
        XCTAssertEqual(CentreItemCover.title(
            of: .history(docId: BinderSubject.noDocumentSubject), structure: structure),
            CentreItemCover.projectHistoryTitle)
        XCTAssertEqual(RightColumnContent.facesPiece(ws(.canvas, .item("ch-2")), structure: structure), "ch-2")
        XCTAssertNil(RightColumnContent.facesPiece(.book, structure: structure))
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
                       "Pulled up — the one thing you pulled up from the binder (⌘3)")
    }
}
