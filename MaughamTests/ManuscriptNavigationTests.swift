import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Going to a place opens its piece** (shell p1 Task 4).
///
/// An annotation row, a history row, a task row, a diagnostic, a figure's
/// Used-in link, a find result, a `[[wiki-link]]` and a slugline all end with
/// `open = faces = .item(docId)`, whatever the centre was — the canvas, an
/// edition, the Inbox, the Book — and `beside` left as it was. This replaces
/// the persona rule it is named after (Denver's 2026-08-02 *"if I'm moving to
/// the manuscript I'm moving to Author"*): with no persona, the centre is what
/// moves.
@MainActor
final class ManuscriptNavigationTests: XCTestCase {

    private let piece = SubjectSamples.pieceID
    private let other = "pc02"

    /// **The rule, from every centre.** Whatever is open and whatever the faces
    /// are on, going to a paragraph in a piece opens that piece and puts the
    /// faces on it; what is beside stays.
    func test_goingToAParagraphOpensItsPiece() {
        for open in SubjectSamples.everyOpen {
            for beside in [nil, BinderSubject.research(SubjectSamples.researchID)] {
                let current = WindowSubject(open: open, faces: open, beside: beside)
                let next = ManuscriptNavigation.destination(toDocument: other, current: current)
                XCTAssertEqual(next, WindowSubject(open: .item(other), faces: .item(other),
                                                   beside: beside, besideIsLatest: false),
                               "\(open) open, \(String(describing: beside)) beside")
                XCTAssertEqual(ProjectWindow.centreRoute(
                    subject: next, bookView: .outline, projectType: .novel,
                    structure: SubjectSamples.structure, preview: .nothingCompiled),
                               ProjectWindow.centreRoute(
                    subject: SubjectSamples.opened(.item(other)), bookView: .outline,
                    projectType: .novel, structure: SubjectSamples.structure,
                    preview: .nothingCompiled),
                               "\(open): the centre is the piece's editor")
            }
        }
    }

    /// **And it is not the click.** The click rule leaves the canvas and an
    /// edition in the centre and moves only the faces; going to a place does
    /// not — the discriminating pair, so the two rules cannot be one.
    func test_aPlaceIsNotAClickOverTheCanvasOrAnEdition() {
        for open in [BinderSubject.canvas, .edition(language: "es")] {
            let current = SubjectSamples.opened(open)
            let clicked = ClickRule.resolve(.item(other), gesture: .click, current: current,
                                            structure: SubjectSamples.structure,
                                            projectType: .novel)
            XCTAssertEqual(clicked.open, open, "precondition: a click keeps \(open)")
            XCTAssertEqual(ManuscriptNavigation.destination(toDocument: other,
                                                            current: current).open,
                           .item(other), "\(open): a place opens its piece")
        }
    }

    /// **Which document a paragraph is in**: the payload's `doc_id` wins; with
    /// none, the faces' piece; with the faces on a Part, the Book or anything
    /// not a document, nothing — and nothing then moves.
    func test_aParagraphsDocumentIsThePayloadsElseTheFacesPiece() {
        let onPiece = WindowSubject(open: .canvas, faces: .item(piece))
        XCTAssertEqual(ManuscriptNavigation.paragraphDocId(
            payload: [ManuscriptNavigation.docIdKey: other, "paragraph_id": "p001"],
            current: onPiece, structure: SubjectSamples.structure), other)
        XCTAssertEqual(ManuscriptNavigation.paragraphDocId(
            payload: ["paragraph_id": "p001"],
            current: onPiece, structure: SubjectSamples.structure), piece)
        for faces in [BinderSubject.project, .item(SubjectSamples.partID), .canvas,
                      .research(SubjectSamples.researchID), .inbox] {
            let current = WindowSubject(open: .canvas, faces: faces)
            let docId = ManuscriptNavigation.paragraphDocId(
                payload: ["paragraph_id": "p001"], current: current,
                structure: SubjectSamples.structure)
            XCTAssertNil(docId, "\(faces) names no paragraph's document")
            XCTAssertEqual(ManuscriptNavigation.destination(toDocument: docId, current: current),
                           current, "\(faces): nothing moves")
        }
    }

    /// **The posters that know their document name it** — a history row's op
    /// and a figure's Used-in reveal — so the piece that opens is never a
    /// guess from the faces.
    func test_thePostersThatKnowTheirDocumentNameIt() throws {
        let reveal = TranslationReveal(docId: other, language: nil, paragraphId: "p001")
        XCTAssertEqual(TranslationReveal.navigatePayload(reveal)[ManuscriptNavigation.docIdKey]
                        as? String, other)
        let history = try SourceTree.read("Maugham/Views/HistoryPaneVerbs.swift")
        XCTAssertTrue(history.contains("ManuscriptNavigation.docIdKey: op.docId"),
                      "a history row names its op's document")
        let tasks = try SourceTree.read("Maugham/Views/TasksPane.swift")
        XCTAssertTrue(tasks.contains("\"doc_id\": anchor.docId"),
                      "a task row names its anchor's document under the same key")
        XCTAssertEqual(ManuscriptNavigation.docIdKey, "doc_id")
    }

    /// **A right-column pane travelling to a piece opens it** (an annotation
    /// row about another piece, a figure's use); anything else is the click
    /// rule's `navigate`.
    func test_aRightColumnTravelToAPieceOpensIt() {
        let current = SubjectSamples.opened(.canvas)
        XCTAssertEqual(ManuscriptNavigation.travel(
            to: .item(other), current: current,
            structure: SubjectSamples.structure, projectType: .novel),
                       WindowSubject(open: .item(other), faces: .item(other)))
        for target in [BinderSubject.figure(SubjectSamples.figureID), .item(SubjectSamples.partID),
                       .project] {
            XCTAssertEqual(ManuscriptNavigation.travel(
                to: target, current: current,
                structure: SubjectSamples.structure, projectType: .novel),
                           ClickRule.navigate(to: target, current: current,
                                              structure: SubjectSamples.structure,
                                              projectType: .novel), "\(target)")
        }
    }

    /// **Applied once, and only when it changes** — a navigation to the piece
    /// already open writes nothing, so the editor's reload triggers do not
    /// churn.
    func test_goWritesTheSubjectOnlyWhenItChanges() {
        var writes = 0
        var stored = SubjectSamples.opened(.item(piece))
        let binding = Binding(get: { stored }, set: { stored = $0; writes += 1 })
        ManuscriptNavigation.go(to: stored, subject: binding)
        XCTAssertEqual(writes, 0)
        ManuscriptNavigation.go(
            to: ManuscriptNavigation.destination(toDocument: other, current: stored),
            subject: binding)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(stored.open, .item(other))
    }
}
