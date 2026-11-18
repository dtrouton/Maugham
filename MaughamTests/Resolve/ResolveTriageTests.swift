import XCTest
import SwiftUI
import MaughamCore
@testable import Maugham

/// **To resolve's triage control** (shell plan 2 Task 7b): a second filter,
/// about notes, ANDed with the source chips, offered only while a note in
/// scope carries a mark. Pure functions and censuses (tripwire 33).
@MainActor
final class ResolveTriageTests: XCTestCase {

    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(_ id: String, on docId: String = "doc-a", triage: TriageMark? = nil,
                      pass: String? = nil, status: AnnotationStatus = .open) -> ResolveItem {
        .note(ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .comment, paragraphId: "aa11", body: id, suggestedText: nil,
            priorText: nil, createdAt: t, createdBySession: nil, status: status,
            userResponse: nil, resolvedAt: nil, isStale: false, triage: triage,
            reviewPassId: pass)))
    }

    private func todo(_ id: String) -> ResolveItem {
        .todo(WriterTask(id: id, kind: .paneCreated, anchor: TaskAnchor(docId: "doc-a", paragraphId: nil),
                         body: id, status: .open, priority: 0, parentTaskId: nil,
                         createdAt: t, createdBySession: nil))
    }

    private func finding(_ id: String) -> ResolveItem {
        .finding(docId: "doc-a", Diagnostic(
            id: id, docId: "doc-a", anchor: nil, body: id, category: nil, runId: "run-1",
            kind: .conformanceStrain))
    }

    private func ids(_ items: [ResolveItem], _ choice: ResolveTriageChoice,
                     selection: Set<ResolveSource> = []) -> [String] {
        ResolveFilter.visible(items, selection: selection, triage: choice, localName: "Denver").map(raw)
    }

    /// An item's own id (the annotation's, the to-do's, the finding's).
    private func raw(_ item: ResolveItem) -> String {
        switch item {
        case .note(let note): return note.annotation.id
        case .todo(let task): return task.id
        case .finding(_, let finding): return finding.id
        }
    }

    private lazy var mixed: [ResolveItem] = [
        note("do-1", triage: .do), note("discuss-1", triage: .discuss),
        note("decline-1", triage: .decline), note("plain-1"),
        finding("strain-1"), todo("todo-1"),
    ]

    func test_theTriageControlIsOfferedOnlyWhenANoteCarriesAMark() throws {
        XCTAssertFalse(ResolveTriage.offered([note("plain"), finding("f"), todo("t")]),
                       "a quiet chapter gains no furniture")
        XCTAssertTrue(ResolveTriage.offered([note("plain"), note("marked", triage: .discuss)]))
        XCTAssertFalse(ResolveTriage.offered([]))
        // The bar draws the control only when handed a choice.
        let bar = try SourceTree.read("Maugham/Views/Resolve/ResolveFilterBar.swift")
        XCTAssertTrue(bar.contains("if let triage {"))
        let pane = try SourceTree.read("Maugham/Views/Resolve/ResolvePane.swift")
        XCTAssertTrue(pane.contains("triage: triageOffered ? triageChoice : nil,"))
    }

    func test_doShowsOnlyNotesMarkedDo() {
        XCTAssertEqual(ids(mixed, .doThis), ["do-1"])
        XCTAssertEqual(ids(mixed, .discuss), ["discuss-1"])
        XCTAssertEqual(ids(mixed, .decline), ["decline-1"],
                       "a declined note stays in the list as an open note")
    }

    func test_untriagedShowsOnlyUntriagedNotes() {
        XCTAssertEqual(ids(mixed, .untriaged), ["plain-1"])
    }

    func test_findingsAndTodosShowOnlyUnderAll() {
        XCTAssertEqual(ids(mixed, .all), mixed.map(raw))
        for choice in ResolveTriageChoice.allCases where choice != .all {
            XCTAssertFalse(ids(mixed, choice).contains("strain-1"), "\(choice)")
            XCTAssertFalse(ids(mixed, choice).contains("todo-1"), "\(choice)")
        }
    }

    func test_triageAndSourceCombine() {
        let items = [note("lish-do", triage: .do, pass: "line"),
                     note("lish-plain", pass: "line"),
                     note("gould-do", triage: .do, pass: "copy")]
        XCTAssertEqual(ids(items, .doThis, selection: [.pass("line")]), ["lish-do"],
                       "Lish's notes I marked Do")
        XCTAssertEqual(ids(items, .doThis), ["lish-do", "gould-do"])
        XCTAssertEqual(ids(items, .all, selection: [.pass("line")]), ["lish-do", "lish-plain"])
        XCTAssertEqual(ids(items, .untriaged, selection: [.pass("copy")]), [],
                       "nothing left: the list says \"\(ResolvePane.EmptyState.filteredOut.sentence)\"")
        XCTAssertEqual(ResolvePane.emptyState(scope: .piece(docId: "doc-a", includesBookLevel: false),
                                              hasItems: true, hasVisible: false, offersColdStart: false),
                       .filteredOut)
    }

    func test_clearingTheLastMarkReturnsTheChoiceToAll() throws {
        let unmarked = [note("plain"), finding("f")]
        let offered = ResolveTriage.offered(unmarked)
        XCTAssertEqual(ResolveTriage.effective(.doThis, offered: offered), .all,
                       "a hidden control may not keep narrowing the list")
        XCTAssertEqual(ResolveTriage.effective(.doThis, offered: true), .doThis)
        let pane = try SourceTree.read("Maugham/Views/Resolve/ResolvePane.swift")
        XCTAssertTrue(pane.contains("if !triageOffered, triageChoice != .all { triageChoice = .all }"),
                      "the view's choice returns to All with the control")
    }

    func test_theTriageControlWorksAtBookScope() throws {
        let book = [note("a-do", on: "doc-a", triage: .do), note("a-plain", on: "doc-a"),
                    note("b-do", on: "doc-b", triage: .do), note("b-discuss", on: "doc-b", triage: .discuss)]
        XCTAssertTrue(ResolveTriage.offered(book))
        XCTAssertEqual(ids(book, .doThis), ["a-do", "b-do"], "every Do across the book")
        // The Book's count line reads the held snapshot, never the filtered list.
        let pane = try SourceTree.read("Maugham/Views/Resolve/ResolvePane.swift")
        XCTAssertTrue(pane.contains("scope: scope, snapshot: held,"),
                      "the head is handed the unfiltered snapshot")
        let head = try SourceTree.read("Maugham/Views/Resolve/ResolveHead.swift")
        XCTAssertTrue(head.contains("ResolveHead.bookLines(ResolveHead.bookCount(\n                    snapshot.items"),
                      "the count answers what needs the writer, unfiltered")
    }

    func test_theTriageMarkShowsReadOnlyOnAStettedRow() throws {
        XCTAssertFalse(AnnotationRow.offersTriage(status: .stetted), "premise: no menu on a stetted row")
        XCTAssertEqual(AnnotationRow.readOnlyMark(.do, menuDrawn: false), .do)
        XCTAssertNil(AnnotationRow.readOnlyMark(.do, menuDrawn: true), "the menu itself shows the mark")
        XCTAssertNil(AnnotationRow.readOnlyMark(nil, menuDrawn: false))
        for settled in [AnnotationStatus.accepted, .rejected, .archived, .stetted] {
            XCTAssertFalse(AnnotationRow.offersTriage(status: settled), "\(settled): the menu stays hidden")
        }
        let row = try SourceTree.read("Maugham/Views/AnnotationRow.swift")
        XCTAssertTrue(row.contains("else if let mark = Self.readOnlyMark(annotation.triage, menuDrawn: false) {"),
                      "the row draws the read-only mark wherever the menu is not drawn")
    }

    /// The quiet line under an archived inline to-do (Task 7 fix ruling).
    func test_anArchivedInlineTodoSaysWhyItCannotBeUnarchived() {
        func task(_ kind: TaskKind) -> WriterTask {
            WriterTask(id: "t", kind: kind, anchor: TaskAnchor(docId: "doc-a", paragraphId: nil),
                       body: "b", status: .archived, priority: 0, parentTaskId: nil,
                       createdAt: t, createdBySession: nil)
        }
        let all = TaskRowVerbs.unrestricted
        let none = TaskRowVerbs(toggle: false, archive: false, delete: false, move: false)
        XCTAssertEqual(ResolveArchivedTodos.whyNotUnarchived(task(.inlineMarkdown), verbs: all),
                       ResolveArchivedTodos.inlineArchivedLine)
        XCTAssertEqual(ResolveArchivedTodos.whyNotUnarchived(task(.fountainBoneyard), verbs: all),
                       ResolveArchivedTodos.inlineArchivedLine)
        XCTAssertNil(ResolveArchivedTodos.whyNotUnarchived(task(.paneCreated), verbs: all),
                     "Unarchive is offered: nothing to explain")
        XCTAssertEqual(ResolveArchivedTodos.whyNotUnarchived(task(.paneCreated), verbs: none),
                       ResolveArchivedTodos.refusedArchivedLine,
                       "hidden by the posture, and it says so")
        XCTAssertEqual(ResolveBookSettledSection.doneHeading(done: 0, archived: 2), "",
                       "no 'nothing done' line over an Archived list")
        XCTAssertEqual(ResolveBookSettledSection.doneHeading(done: 1, archived: 2), "Done")
    }

    /// **The active choice is named on the control** (Task 7b fix).
    func test_anActiveTriageChoiceIsNamedOnTheControl() throws {
        XCTAssertNil(ResolveFilterBar.triageWord(.all), "under All the bare flag")
        XCTAssertEqual(ResolveFilterBar.triageWord(.doThis), "Do")
        XCTAssertEqual(ResolveFilterBar.triageWord(.discuss), "Discuss")
        XCTAssertEqual(ResolveFilterBar.triageWord(.decline), "Decline")
        XCTAssertEqual(ResolveFilterBar.triageWord(.untriaged), "Untriaged")
        XCTAssertEqual(ResolveFilterBar.triageSymbol(.all), "flag")
        XCTAssertEqual(ResolveFilterBar.triageSymbol(.discuss), "flag.fill")
        let bar = try SourceTree.read("Maugham/Views/Resolve/ResolveFilterBar.swift")
        XCTAssertTrue(bar.contains("if let word = Self.triageWord(choice) {"),
                      "the control draws the word whenever there is one")
    }

    /// **Density counts what the triage choice leaves** (controller ruling).
    func test_aListNarrowedByTriageToAFewNotesIsNotDense() throws {
        let many = (0..<15).map { note("plain-\($0)") } + (0..<5).map { note("do-\($0)", triage: .do) }
        XCTAssertTrue(ResolveFilter.isDense(many), "premise: twenty items is dense")
        XCTAssertTrue(ResolveTriage.isDense(many, choice: .all))
        XCTAssertFalse(ResolveTriage.isDense(many, choice: .doThis),
                       "five Do notes are a small list: their groups show open")
        XCTAssertTrue(ResolveTriage.isDense(many, choice: .untriaged), "fifteen untriaged stay dense")
        let unmarked = (0..<20).map { note("p-\($0)") }
        XCTAssertTrue(ResolveTriage.isDense(unmarked, choice: .doThis),
                      "no mark, no control: the choice is All, and twenty is dense")
        let pane = try SourceTree.read("Maugham/Views/Resolve/ResolvePane.swift")
        XCTAssertTrue(pane.contains("dense = ResolveTriage.isDense(held.items, choice: triageChoice)"))
        XCTAssertTrue(pane.contains("dense = ResolveTriage.isDense(held.items, choice: new)"))
    }

}
