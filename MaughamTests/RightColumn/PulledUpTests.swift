import XCTest
import MaughamCore
@testable import Maugham

/// **The pulled-up thing** (shell plan 3 Task 3): what `beside` holds now, its
/// tree-row bookkeeping, its persistence and its stored shapes. Pure values;
/// nothing is mounted or pressed (tripwire 33).
final class PulledUpTests: XCTestCase {

    private let structure: [StructureItem] = [
        StructureItem(id: "part-1", title: "Part One", type: .group, children: [
            StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md"),
        ]),
        StructureItem(id: "ch-2", title: "Two", type: .document, path: "two.md"),
    ]

    private func click(_ row: BinderSubject, from current: WindowSubject) -> WindowSubject {
        ClickRule.resolve(row, gesture: .click, current: current,
                          structure: structure, projectType: .novel)
    }

    private let everyKind: [PulledUp] = [
        .research("r-1"), .figure("f-1"), .canvasScrap(nodeId: "n-1"),
        .canvasPhoto(path: "canvas_assets/a.png"), .lessons, .firstReader, .visualLanguage,
        .history(docId: "ch-1"),
    ]

    func test_aResearchAndAFigureRoundTripThroughTheTreeSubject() {
        for row in [BinderSubject.research("r-1"), .figure("f-1")] {
            let pulled = PulledUp(treeSubject: row)
            XCTAssertNotNil(pulled, "\(row)")
            XCTAssertEqual(pulled?.treeSubject, row)
        }
        XCTAssertEqual(PulledUp(treeSubject: .research("r-1"))?.researchID, "r-1")
        XCTAssertEqual(PulledUp(treeSubject: .figure("f-1"))?.figureID, "f-1")
        for row in [BinderSubject.project, .item("ch-1"), .inbox, .canvas, .palette,
                    .edition(language: "es")] {
            XCTAssertNil(PulledUp(treeSubject: row), "\(row) opens; it is never pulled up")
        }
    }

    func test_aStatementOrHistoryPulledUpIsNotWhatTheTreeSelects() {
        for pulled in [PulledUp.canvasScrap(nodeId: "n-1"), .canvasPhoto(path: "p.png"),
                       .lessons, .firstReader, .visualLanguage, .history(docId: "ch-1")] {
            XCTAssertNil(pulled.treeSubject, "\(pulled)")
            XCTAssertNil(pulled.researchID)
            XCTAssertNil(pulled.figureID)
            let subject = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"), beside: pulled)
            let shown = BinderTreeSelection.shown([], subject: subject, clickedAt: nil)
            XCTAssertEqual(shown, [.item("ch-1")], "\(pulled): the tree draws the faces")
            XCTAssertEqual(BinderTreeSelection.outlined(shown: [], subject: subject),
                           [], "\(pulled): no row outlined for it")
        }
    }

    /// The canvas lights the part clicked last — never a pulled-up statement.
    func test_lastClickedIgnoresAPulledUpStatement() {
        var subject = WindowSubject(open: .canvas, faces: .item("ch-2"))
        subject = ClickRule.pullUp(.lessons, current: subject)
        XCTAssertTrue(subject.besideIsLatest, "premise: pulled up last")
        XCTAssertEqual(subject.lastClicked, .item("ch-2"))
        subject = ClickRule.pullUp(.history(docId: "ch-2"), current: subject)
        XCTAssertEqual(subject.lastClicked, .item("ch-2"))
        subject = ClickRule.pullUp(.research("r-1"), current: subject)
        XCTAssertEqual(subject.lastClicked, .research("r-1"), "a research row still lights")
    }

    func test_clickingTheRowPulledUpPutsItAway() {
        let withNote = click(.research("r-1"), from: WindowSubject(open: .item("ch-1"),
                                                                    faces: .item("ch-1")))
        XCTAssertEqual(withNote.beside, .research("r-1"))
        let dismissed = click(.research("r-1"), from: withNote)
        XCTAssertNil(dismissed.beside)
        XCTAssertEqual(dismissed.open, .item("ch-1"), "nothing else moves")
        // A pulled-up figure is put away by its row the same way.
        let withFigure = ClickRule.pullUp(.figure("f-1"), current: .book)
        XCTAssertNil(click(.figure("f-1"), from: withFigure).beside)
        // A row that cannot be pulled up never matches nothing beside: it opens.
        XCTAssertEqual(click(.canvas, from: .book).open, .canvas)
        // Close and the explicit pull-up.
        XCTAssertNil(ClickRule.putAway(current: withNote).beside)
        XCTAssertEqual(ClickRule.pullUp(.research("r-1"), current: withNote).beside,
                       .research("r-1"), "pulling up what is there never puts it away")
    }

    func test_aPulledUpThingPersistsAcrossSubjectChanges() {
        for pulled in everyKind {
            var subject = ClickRule.pullUp(pulled, current: .book)
            for row in [BinderSubject.item("ch-2"), .canvas, .item("part-1"), .project,
                        .palette, .inbox, .edition(language: "es")] {
                subject = click(row, from: subject)
                XCTAssertEqual(subject.beside, pulled, "\(pulled) after a click on \(row)")
            }
            subject = ClickRule.navigate(to: .item("ch-1"), current: subject,
                                         structure: structure, projectType: .novel)
            XCTAssertEqual(subject.beside, pulled)
        }
    }

    /// A subject plans 1–2 wrote (`beside` a `BinderSubject`), in that
    /// encoding (`BinderSubject.encode`), inside the `ui-state.json` it was
    /// written in.
    func test_aSubjectSavedByPlan2StillDecodes() throws {
        func state(beside: String) throws -> UIState {
            let raw = #"""
            {"schemaVersion":5,"windowSubject":{"open":{"kind":"canvas"},
             "faces":{"kind":"item","id":"ch-1"},"beside":\#(beside),"besideIsLatest":true},
             "bookView":"status","isNoChromeOn":false,"researchPreviewVisible":false,
             "detailSegment":"inspector","isReviewModeOn":false}
            """#
            return try JSONDecoder().decode(UIState.self, from: Data(raw.utf8))
        }
        let research = try state(beside: #"{"kind":"research","id":"r1"}"#)
        XCTAssertEqual(research.windowSubject.beside, .research("r1"))
        XCTAssertEqual(research.windowSubject.lastClicked, .research("r1"))
        XCTAssertEqual(research.windowSubject.faces, .item("ch-1"))
        XCTAssertEqual(research.bookView, .status, "the rest of the file survives")
        XCTAssertEqual(try state(beside: #"{"kind":"figure","id":"f1"}"#).windowSubject.beside,
                       .figure("f1"))
        // A `BinderSubject` no `PulledUp` spells — never written by plans 1–2's
        // click rule, but a stored value all the same — is nothing beside.
        for other in [#"{"kind":"item","id":"ch-2"}"#, #"{"kind":"canvas"}"#,
                      #"{"kind":"fromANewerBuild","id":"x"}"#, #"{"research":{"_0":"r1"}}"#] {
            let s = try state(beside: other)
            XCTAssertNil(s.windowSubject.beside, other)
            XCTAssertFalse(s.windowSubject.besideIsLatest, other)
            XCTAssertEqual(s.windowSubject.open, .canvas, "\(other): the subject survives")
            XCTAssertEqual(s.windowSubject.lastClicked, .item("ch-1"))
        }
        // The shipped build's file: no `windowSubject`, a legacy selection.
        let shipped = try JSONDecoder().decode(UIState.self, from: Data(#"""
            {"schemaVersion":5,"selectedResearchItemId":"r1","isNoChromeOn":false,
             "binderSegment":"manuscript","researchPreviewVisible":false,
             "detailSegment":"inspector","outlineLayout":"table",
             "isReviewModeOn":false,"persona":"author"}
            """#.utf8))
        XCTAssertEqual(shipped.windowSubject,
                       WindowSubject(open: .research("r1"), faces: .research("r1")))
        XCTAssertEqual(shipped.rightColumnPosition, .resolve)
    }

    func test_everyKindRoundTripsThroughTheStoredSubject() throws {
        for pulled in everyKind {
            var state = UIState.empty
            state.windowSubject = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"),
                                                beside: pulled)
            state.rightColumnPosition = .pulledUp
            let back = try JSONDecoder().decode(UIState.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(back, state, "\(pulled)")
        }
    }

    /// **The downgrade**: the previous commit decodes `beside` as a
    /// `BinderSubject`. A pulled-up tree row is written there in that shape;
    /// anything else goes under `pulledUp`, which that decoder never reads,
    /// so it keeps `open` and `faces` and finds nothing beside.
    func test_whatThePreviousBuildReadsOfTheNewShape() throws {
        struct PreviousSubject: Decodable {
            let open: BinderSubject
            let faces: BinderSubject
            let beside: BinderSubject?
        }
        for pulled in everyKind {
            let subject = WindowSubject(open: .canvas, faces: .item("ch-2"), beside: pulled)
            let old = try JSONDecoder().decode(PreviousSubject.self,
                                               from: JSONEncoder().encode(subject))
            XCTAssertEqual(old.open, .canvas, "\(pulled)")
            XCTAssertEqual(old.faces, .item("ch-2"), "\(pulled)")
            XCTAssertEqual(old.beside, pulled.treeSubject, "\(pulled)")
        }
    }

    func test_historyOfAPieceThatIsGoneIsPutAway() {
        func validated(_ pulled: PulledUp) -> PulledUp? {
            WindowSubject(open: .item("ch-1"), faces: .item("ch-1"), beside: pulled)
                .validated(structure: structure, researchIDs: ["r-1"], figureIDs: ["f-1"],
                           editionLanguages: []).beside
        }
        XCTAssertNil(validated(.history(docId: "gone")))
        XCTAssertNil(validated(.research("gone")))
        XCTAssertNil(validated(.figure("gone")))
        for kept in everyKind {
            XCTAssertEqual(validated(kept), kept, "\(kept) lives")
        }
        // A canvas card is kept: a missing node is the pulled-up view's own
        // empty state.
        XCTAssertEqual(validated(.canvasScrap(nodeId: "not-on-the-canvas")),
                       .canvasScrap(nodeId: "not-on-the-canvas"))
    }

    /// The owner's rule (2026-11-16): research and a palette card are edited
    /// beside, under Lock; a canvas card is read-only beside.
    func test_whatIsEditedBesideIsOneAnswerPerKind() {
        XCTAssertTrue(PulledUp.research("palette-card").isEditableBeside)
        XCTAssertTrue(PulledUp.figure("f-1").isEditableBeside)
        XCTAssertFalse(PulledUp.canvasScrap(nodeId: "n").isEditableBeside)
        XCTAssertFalse(PulledUp.canvasPhoto(path: "p").isEditableBeside)
        XCTAssertFalse(PulledUp.history(docId: "ch-1").isEditableBeside)
        XCTAssertFalse(PulledUp.research("r").refusesEdits(isLocked: false))
        XCTAssertTrue(PulledUp.research("r").refusesEdits(isLocked: true), "Lock covers it")
        XCTAssertTrue(PulledUp.figure("f").refusesEdits(isLocked: true))
        XCTAssertFalse(PulledUp.lessons.refusesEdits(isLocked: true),
                       "a statement answers to its posture, not Lock")
        XCTAssertTrue(PulledUp.canvasScrap(nodeId: "n").refusesEdits(isLocked: false))
        XCTAssertEqual(PulledUp.lessons.statement?.kind, .lessons)
        XCTAssertEqual(PulledUp.lessons.statement?.scope, .project)
        XCTAssertNil(PulledUp.research("r").statement)
    }

    func test_openInCentreOnAThingThatIsNoRow() {
        let canvasCard = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"),
                                       beside: .canvasScrap(nodeId: "n"))
        XCTAssertEqual(ProjectWindow.openingBesideInCentre(canvasCard, structure: structure,
                                                           projectType: .novel),
                       WindowSubject(open: .canvas, faces: .canvas))
        let history = WindowSubject(open: .canvas, faces: .canvas,
                                    beside: .history(docId: "ch-2"))
        XCTAssertEqual(ProjectWindow.openingBesideInCentre(history, structure: structure,
                                                           projectType: .novel),
                       WindowSubject(open: .item("ch-2"), faces: .item("ch-2")))
        XCTAssertEqual(PulledUp.history(docId: "ch-2").centreItem, .history(docId: "ch-2"))
        XCTAssertEqual(PulledUp.firstReader.centreItem,
                       .statement(kind: .firstReader, scope: .project))
        XCTAssertNil(PulledUp.research("r").centreItem)
    }

    func test_aFoldEntryPullsUpWhatItNames() {
        func card(_ kind: PinnedReference.Kind) -> PieceFoldEntry {
            .card(PinnedReference(id: "c", kind: kind, title: "C"), regionTitle: nil)
        }
        XCTAssertEqual(PieceFoldEntry.research(id: "r-1", title: "R", owned: true).pulledUp,
                       .research("r-1"))
        XCTAssertEqual(PieceFoldEntry.palette(id: "p-1", title: "P").pulledUp, .research("p-1"))
        XCTAssertEqual(card(.research(itemId: "r-2")).pulledUp, .research("r-2"))
        XCTAssertEqual(card(.palette(cardId: "p-2")).pulledUp, .research("p-2"))
        XCTAssertEqual(card(.scrap(nodeId: "n-1")).pulledUp, .canvasScrap(nodeId: "n-1"))
        XCTAssertEqual(card(.photo(path: "canvas_assets/a.png")).pulledUp,
                       .canvasPhoto(path: "canvas_assets/a.png"))
        XCTAssertNil(PieceFoldEntry.figure(id: "f-1", name: "F").pulledUp)
        XCTAssertNil(PieceFoldEntry.link(pieceId: "ch-2", title: "Two", incoming: false).pulledUp)
    }

    func test_aRetiredPositionDecodesToToResolve() throws {
        for raw in [#""inspector""#, #""study""#, #"7"#] {
            let s = try JSONDecoder().decode(UIState.self, from: Data(
                #"{"schemaVersion":5,"rightColumnPosition":\#(raw),"isNoChromeOn":true}"#.utf8))
            XCTAssertEqual(s.rightColumnPosition, .resolve, raw)
            XCTAssertTrue(s.isNoChromeOn, "\(raw): the rest of the file survives")
        }
        let brief = try JSONDecoder().decode(UIState.self, from: Data(
            #"{"schemaVersion":5,"rightColumnPosition":"brief"}"#.utf8))
        XCTAssertEqual(brief.rightColumnPosition, .brief)
        XCTAssertEqual(try JSONDecoder().decode(UIState.self, from: Data(
            #"{"schemaVersion":5}"#.utf8)).rightColumnPosition, .resolve)
    }
}
