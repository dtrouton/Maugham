import XCTest
import MaughamCore
@testable import Maugham

/// **An intent that will not read says so** (shell p3 final wave, I2;
/// RULING-54's throwing readers). `BriefReader` names a statement whose read
/// threw in `BriefSnapshot.unreadable`; until this wave no view read it, so
/// Going for drew "No intent yet." or the empty prompt over a file it could
/// not read, and Decided drew nothing.
@MainActor
final class BriefUnreadableTests: XCTestCase {

    private let docId = "doc-unread"
    private let statementId = "stmt-unread"

    private var statements: [Statement] {
        [Statement(id: statementId, kind: .intent, scope: .document(docId),
                   path: "intent/unread.md")]
    }

    private func snapshot(unreadable: [String]) -> BriefSnapshot {
        BriefSnapshot(scope: .piece(docId: docId), line: nil, intentText: nil, intentEssay: nil,
                      decisions: [], bookIntentEssay: nil, bookDecisions: [],
                      unconfirmedReadings: 0, unreadable: unreadable)
    }

    func test_anUnreadableIntentIsNamedNeverDrawnEmpty() {
        XCTAssertTrue(BriefPane.statementIsUnreadable(
            kind: .intent, scope: .document(docId),
            snapshot: snapshot(unreadable: [statementId]), statements: statements))
        XCTAssertFalse(BriefPane.statementIsUnreadable(
            kind: .intent, scope: .document(docId),
            snapshot: snapshot(unreadable: []), statements: statements))

        // Every input but the centre's cover: one line, no editor, no prompt.
        for hasMarks in [true, false] {
            for editing in [true, false] {
                for mayEdit in [true, false] {
                    let mode = GoingForView.mode(
                        hasMarks: hasMarks, editingRequested: editing, inTheCentre: false,
                        hasIntent: false, mayEdit: mayEdit, isUnreadable: true)
                    XCTAssertEqual(mode, .unreadable)
                    let face = GoingForView.face(mode)
                    XCTAssertFalse(face.editor, "the editor is not offered over a file that won't read")
                    XCTAssertFalse(face.reading, "and \u{201C}No intent yet.\u{201D} is never drawn")
                }
            }
        }
        XCTAssertNotEqual(GoingForView.unreadableLine, GoingForView.noIntentLine)
        XCTAssertNotEqual(GoingForView.unreadableLine, GoingForView.emptyPrompt(.chapter))
        XCTAssertTrue(GoingForView.unreadableLine.contains("can\u{2019}t be read")
                      || GoingForView.unreadableLine.contains("can't be read"))
    }

    func test_decidedSaysItsStatementWouldNotRead() {
        XCTAssertFalse(BriefDecidedSection.unreadableLine.isEmpty)
        XCTAssertTrue(BriefDecidedSection.shows(decisions: [], isUnreadable: true),
                      "Decided draws its line even with no decision to draw")
        XCTAssertFalse(BriefDecidedSection.shows(decisions: [], isUnreadable: false),
                       "and nothing at all for a statement that read and holds none")

        // A Part: the chapter whose intent would not read keeps a section.
        let structure = [StructureItem(id: docId, title: "Chapter Nine", type: .document,
                                       path: "manuscript/nine.md")]
        let sections = BriefPartView.sections(docIds: [docId], decisions: [],
                                              structure: structure, unreadable: [docId])
        XCTAssertEqual(sections.map(\.title), ["Chapter Nine"])
        XCTAssertEqual(sections.map(\.unreadable), [true])

        // The Book: its origins that would not read, named in one line.
        let titles = BriefBookView.unreadableTitles(
            snapshot: snapshot(unreadable: [statementId]), statements: statements,
            structure: structure)
        XCTAssertEqual(titles, ["Chapter Nine"])
        XCTAssertNotNil(BriefBookView.unreadableLine(titles: titles))
        XCTAssertNil(BriefBookView.unreadableLine(titles: []))
    }

    /// The three Brief views read the snapshot's list.
    func test_everyBriefViewReadsTheUnreadableList() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/Brief")
        for file in ["BriefPieceView.swift", "BriefBookView.swift", "BriefPartView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("unreadable"), "\(file) never reads the unreadable list")
        }
    }
}
