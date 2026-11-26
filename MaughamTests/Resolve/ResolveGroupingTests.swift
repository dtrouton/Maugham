import XCTest
import MaughamCore
@testable import Maugham

/// Shell plan 2, Task 2 — `ResolveGrouping`: a snapshot's items grouped by
/// paragraph (a piece), by scene (a screenplay) or by piece (a Book or Part).
/// Pure: every snapshot is built by hand.
///
/// Paragraph ids are 4-char from `ParagraphID`'s alphabet (tripwire 8).
final class ResolveGroupingTests: XCTestCase {

    // MARK: - Builders

    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(_ id: String, on docId: String = "doc-a", pid: String?,
                      age: TimeInterval = 0, triage: TriageMark? = nil) -> ResolveItem {
        .note(ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .comment, paragraphId: pid, body: id, suggestedText: nil, priorText: nil,
            createdAt: t.addingTimeInterval(-age), createdBySession: nil, status: .open,
            userResponse: nil, resolvedAt: nil, isStale: false, triage: triage)))
    }

    private func todo(_ id: String, on docId: String = "doc-a", pid: String?,
                      priority: Double = 0) -> ResolveItem {
        .todo(WriterTask(id: id, kind: .paneCreated,
                         anchor: TaskAnchor(docId: docId, paragraphId: pid),
                         body: id, status: .open, priority: priority, parentTaskId: nil,
                         createdAt: t, createdBySession: nil))
    }

    private func finding(_ id: String, on docId: String = "doc-a", pid: String?) -> ResolveItem {
        .finding(docId: docId, Diagnostic(
            id: id, docId: docId,
            anchor: pid.map { .init(paragraphId: $0, anchorText: "x") },
            body: id, category: nil, runId: "run-1", kind: .conformanceStrain))
    }

    private func snapshot(_ items: [ResolveItem], sequences: [String: [String]] = [:],
                          text: [String: String] = [:]) -> ResolveSnapshot {
        ResolveSnapshot(items: items, sequences: sequences, paragraphText: text, unreadableDocIds: [])
    }

    private let structure: [StructureItem] = [
        StructureItem(id: "doc-a", title: "Arrival", type: .document, path: "manuscript/a.md"),
        StructureItem(id: "part-1", title: "Part One", type: .group, children: [
            StructureItem(id: "doc-b", title: "Breakfast", type: .document, path: "manuscript/b.md"),
            StructureItem(id: "doc-c", title: "Cellar", type: .document, path: "manuscript/c.md"),
        ]),
    ]

    private func groups(_ snapshot: ResolveSnapshot, _ scope: ResolveScope,
                        sceneIndex: [String: Int]? = nil, sceneTitles: [String] = [],
                        figureNames: [String: String] = [:],
                        projectType: ProjectType = .novel) -> [ResolveGroup] {
        ResolveGrouping.groups(snapshot, scope: scope, structure: structure,
                               sceneIndex: sceneIndex, sceneTitles: sceneTitles,
                               figureNames: figureNames, book: PieceNoun.Book(type: projectType))
    }

    private func itemIds(_ group: ResolveGroup) -> [String] { group.items.map(\.id) }

    // MARK: - A piece

    func test_wholeChapterLeadsThenParagraphsInManuscriptOrder() {
        let read = snapshot([
            note("n-cc", pid: "cc33"),
            todo("t-low", pid: "aa11", priority: 2),
            finding("f-aa", pid: "aa11"),
            note("n-aa-old", pid: "aa11", age: 60),
            todo("t-high", pid: "aa11", priority: 1),
            note("n-aa-new", pid: "aa11"),
            note("n-aa-do", pid: "aa11", age: 120, triage: .do),
            note("n-whole", pid: nil),
            todo("t-bb", pid: "bb22"),
        ], sequences: ["doc-a": ["aa11", "bb22", "cc33", "dd44"]],
           text: ["aa11": "First line. <!--t-aaaaaa-->", "bb22": "Second.", "cc33": "Third.", "dd44": "Quiet."])

        let result = groups(read, .piece(docId: "doc-a", includesBookLevel: false))
        // A Collection calls its piece a piece (controller ruling (c)), so the
        // group agrees with `FiledUnder`'s "this piece's intent".
        XCTAssertEqual(groups(read, .piece(docId: "doc-a", includesBookLevel: false),
                              projectType: .collection).first?.title, "Whole piece")
        XCTAssertEqual(PieceNoun.of(nil, in: PieceNoun.Book(type: .novel)).singular, "chapter")
        XCTAssertEqual(PieceNoun.of(StructureItem(id: "s", title: "S", type: .document, path: "s.fountain"),
                                    in: PieceNoun.Book(type: .collection)).singular, "script",
                       "a script in a Collection is still a script")
        XCTAssertEqual(PieceNoun.of(nil, in: PieceNoun.Book(type: .screenplay)).singular, "script")

        XCTAssertEqual(result.map(\.key), [
            .wholePiece(docId: "doc-a"),
            .paragraph(docId: "doc-a", paragraphId: "aa11"),
            .paragraph(docId: "doc-a", paragraphId: "bb22"),
            .paragraph(docId: "doc-a", paragraphId: "cc33"),
        ], "whole chapter first, then sequence order; dd44 holds nothing, so no group")
        XCTAssertEqual(result.map(\.title), ["Whole chapter", "First line.", "Second.", "Third."],
                       "a paragraph's title is its text as the editor shows it — task anchors stripped")
        XCTAssertEqual(itemIds(result[1]), [
            "note:doc-a/n-aa-do", "note:doc-a/n-aa-new", "note:doc-a/n-aa-old",
            "finding:doc-a/f-aa",
            "todo:doc-a/t-high", "todo:doc-a/t-low",
        ], "notes in queue order (triaged Do first, then newest), then findings, then to-dos by priority")
    }

    func test_aNoteOnADeletedParagraphGroupsUnderNoLongerInTheText() {
        let read = snapshot([
            note("n-gone", pid: "zz99"),
            finding("f-gone", pid: "zz99"),
            note("n-aa", pid: "aa11"),
            note("n-whole", pid: nil),
        ], sequences: ["doc-a": ["aa11"]], text: ["aa11": "Here."])

        let result = groups(read, .piece(docId: "doc-a", includesBookLevel: false))
        XCTAssertEqual(result.map(\.key), [
            .wholePiece(docId: "doc-a"),
            .paragraph(docId: "doc-a", paragraphId: "aa11"),
            .removed(docId: "doc-a"),
        ])
        XCTAssertEqual(result.last?.title, "No longer in the text")
        XCTAssertEqual(itemIds(result.last!), ["note:doc-a/n-gone", "finding:doc-a/f-gone"])
        XCTAssertEqual(itemIds(result[0]), ["note:doc-a/n-whole"],
                       "a deleted paragraph's note is never filed under Whole chapter")

        // A screenplay: still at the end of its piece, after every scene.
        let scenes = groups(read, .piece(docId: "doc-a", includesBookLevel: false),
                            sceneIndex: ["aa11": 0], sceneTitles: ["INT. HALL - DAY"])
        XCTAssertEqual(scenes.map(\.key), [
            .wholePiece(docId: "doc-a"), .scene(docId: "doc-a", headingParagraphId: "aa11"), .removed(docId: "doc-a"),
        ])

        // A Book: inside the piece's group, after its paragraphs.
        let book = groups(read, .pieces(docIds: ["doc-a"], includesBookLevel: true))
        XCTAssertEqual(book.map(\.key), [.piece(docId: "doc-a")])
        XCTAssertEqual(itemIds(book[0]), [
            "note:doc-a/n-whole", "note:doc-a/n-aa", "note:doc-a/n-gone", "finding:doc-a/f-gone",
        ])
    }

    // MARK: - A Book or Part

    func test_aBookGroupsByPieceInManuscriptOrderWithBookLevelTodosFirst() {
        let bookDoc = ProjectStore.projectTasksDocId
        let read = snapshot([
            note("n-c", on: "doc-c", pid: "aa11"),
            note("n-a2", on: "doc-a", pid: "bb22"),
            todo("t-book", on: bookDoc, pid: nil),
            note("n-a-gone", on: "doc-a", pid: "zz99"),
            note("n-a1", on: "doc-a", pid: "aa11"),
            note("n-a-whole", on: "doc-a", pid: nil),
        ], sequences: ["doc-a": ["aa11", "bb22"], "doc-b": ["aa11"], "doc-c": ["aa11"]])

        let result = groups(read, .pieces(docIds: ["doc-a", "doc-b", "doc-c"], includesBookLevel: true))
        XCTAssertEqual(result.map(\.key), [
            .bookLevel, .piece(docId: "doc-a"), .piece(docId: "doc-c"),
        ], "the Book's own to-dos first, then pieces in manuscript order; doc-b is empty")
        XCTAssertEqual(result.map(\.title), ["The book", "Arrival", "Cellar"])
        XCTAssertEqual(itemIds(result[1]), [
            "note:doc-a/n-a-whole", "note:doc-a/n-a1", "note:doc-a/n-a2", "note:doc-a/n-a-gone",
        ], "inside a piece: whole-piece, then paragraph order, then removed")

        // A screenplay's Book is its one script, and its to-dos still lead.
        let script = groups(snapshot([todo("t-book", on: bookDoc, pid: nil), note("n-a1", pid: "aa11")],
                                     sequences: ["doc-a": ["aa11"]], text: ["aa11": "INT. HALL - DAY"]),
                            .piece(docId: "doc-a", includesBookLevel: true),
                            sceneIndex: ["aa11": 0], sceneTitles: ["INT. HALL - DAY"])
        XCTAssertEqual(script.map(\.key), [.bookLevel, .scene(docId: "doc-a", headingParagraphId: "aa11")])
    }

    func test_figureNotesFollowThePiecesAtBookScope() {
        let owned = "fig-bbbb2222", shared = "fig-cccc3333"
        let names = [owned: "cashflow", shared: "ledger"]
        let read = snapshot([
            note("n-shared", on: shared, pid: nil),
            note("n-a", on: "doc-a", pid: "aa11"),
            note("n-own", on: owned, pid: nil),
        ], sequences: ["doc-a": ["aa11"]], text: ["aa11": "Here."])

        let book = groups(read, .pieces(docIds: ["doc-a"], includesBookLevel: true), figureNames: names)
        XCTAssertEqual(book.map(\.key), [.piece(docId: "doc-a"), .figure(id: shared), .figure(id: owned)],
                       "pieces first, then one group per figure with notes, in the reader's order")
        XCTAssertEqual(book.map(\.title), ["Arrival", "ledger", "cashflow"])

        // A piece's own figure: its own group, after the paragraph groups.
        let piece = groups(snapshot([note("n-own", on: owned, pid: nil), note("n-a", pid: "aa11"),
                                     note("n-gone", pid: "zz99")],
                                    sequences: ["doc-a": ["aa11"]], text: ["aa11": "Here."]),
                           .piece(docId: "doc-a", includesBookLevel: false), figureNames: names)
        XCTAssertEqual(piece.map(\.key), [
            .paragraph(docId: "doc-a", paragraphId: "aa11"), .removed(docId: "doc-a"), .figure(id: owned),
        ])
        XCTAssertEqual(piece.last?.title, "cashflow")

        // A figure's own scope: its one group.
        let figure = groups(snapshot([note("n-own", on: owned, pid: nil)]), .figure(id: owned),
                            figureNames: names)
        XCTAssertEqual(figure.map(\.key), [.figure(id: owned)])
        XCTAssertEqual(itemIds(figure[0]), ["note:\(owned)/n-own"])
    }

    // MARK: - A screenplay

    func test_aScreenplayGroupsByScene() {
        let read = snapshot([
            note("n-climb", pid: "dd44"),
            note("n-whole", pid: nil),
            todo("t-sit", pid: "bb22"),
            note("n-kitchen", pid: "aa11"),
        ], sequences: ["doc-a": ["aa11", "bb22", "cc33", "dd44"]],
           text: ["aa11": "INT. KITCHEN - DAY", "bb22": "Larry sits.",
                  "cc33": "EXT. ROOF - NIGHT", "dd44": "He climbs."])

        let result = groups(read, .piece(docId: "doc-a", includesBookLevel: false),
                            sceneIndex: ["aa11": 0, "bb22": 0, "cc33": 1, "dd44": 1],
                            sceneTitles: ["INT. KITCHEN - DAY", "EXT. ROOF - NIGHT"])
        XCTAssertEqual(result.map(\.key), [
            .wholePiece(docId: "doc-a"), .scene(docId: "doc-a", headingParagraphId: "aa11"),
            .scene(docId: "doc-a", headingParagraphId: "cc33"),
        ])
        XCTAssertEqual(result.map(\.title), ["Whole script", "INT. KITCHEN - DAY", "EXT. ROOF - NIGHT"])
        XCTAssertEqual(itemIds(result[1]), ["note:doc-a/n-kitchen", "todo:doc-a/t-sit"])
        XCTAssertEqual(itemIds(result[2]), ["note:doc-a/n-climb"])
    }

    func test_paragraphsBeforeTheFirstSluglineGroupBeforeTheFirstScene() {
        let read = snapshot([
            note("n-scene", pid: "cc33"),
            note("n-open-2", pid: "bb22"),
            note("n-open-1", pid: "aa11", age: 60),
        ], sequences: ["doc-a": ["aa11", "bb22", "cc33"]],
           text: ["aa11": "FADE IN:", "bb22": "Rain.", "cc33": "INT. HALL - DAY"])

        let result = groups(read, .piece(docId: "doc-a", includesBookLevel: false),
                            sceneIndex: ["cc33": 0], sceneTitles: ["INT. HALL - DAY"])
        XCTAssertEqual(result.map(\.key), [
            .beforeFirstScene(docId: "doc-a"), .scene(docId: "doc-a", headingParagraphId: "cc33"),
        ])
        XCTAssertEqual(result.first?.title, "Before the first scene")
        XCTAssertEqual(itemIds(result[0]), ["note:doc-a/n-open-1", "note:doc-a/n-open-2"],
                       "one group for everything before the first slugline, in sequence order")
    }

    /// A scene's key is its slugline's paragraph, not its position: a scene
    /// inserted above leaves the key of every scene below where it was.
    func test_aSceneKeepsItsKeyWhenASceneIsInsertedAbove() {
        let text = ["aa11": "INT. KITCHEN - DAY", "bb22": "Larry sits.",
                    "ee55": "EXT. YARD - DAWN", "ff66": "Birds."]
        let before = groups(snapshot([note("n-sit", pid: "bb22")],
                                     sequences: ["doc-a": ["aa11", "bb22"]], text: text),
                            .piece(docId: "doc-a", includesBookLevel: false),
                            sceneIndex: ["aa11": 0, "bb22": 0], sceneTitles: ["INT. KITCHEN - DAY"])
        let after = groups(snapshot([note("n-sit", pid: "bb22"), note("n-birds", pid: "ff66")],
                                    sequences: ["doc-a": ["ee55", "ff66", "aa11", "bb22"]], text: text),
                           .piece(docId: "doc-a", includesBookLevel: false),
                           sceneIndex: ["ee55": 0, "ff66": 0, "aa11": 1, "bb22": 1],
                           sceneTitles: ["EXT. YARD - DAWN", "INT. KITCHEN - DAY"])
        let kitchen = ResolveGroup.Key.scene(docId: "doc-a", headingParagraphId: "aa11")
        XCTAssertEqual(before.map(\.key), [kitchen])
        XCTAssertEqual(after.map(\.key), [.scene(docId: "doc-a", headingParagraphId: "ee55"), kitchen],
                       "the kitchen is now scene 1, and its key has not moved")
        XCTAssertEqual(after.last?.title, "INT. KITCHEN - DAY")
        XCTAssertEqual(itemIds(after.last!), ["note:doc-a/n-sit"])
    }

    // MARK: - A piece whose order did not read

    /// No sequence: nothing is judged removed and nothing is placed by guess.
    /// Its anchored items list in one Position unknown group after Whole
    /// chapter — in prose and in a screenplay alike, never under "Before the
    /// first scene" nor under an empty heading.
    func test_aPieceWhoseOrderDidNotReadListsItsNotesUnderPositionUnknown() {
        let read = snapshot([
            note("n-bb", pid: "bb22"),
            todo("t-aa", pid: "aa11"),
            note("n-whole", pid: nil),
            finding("f-aa", pid: "aa11"),
        ])  // no sequence, no text

        for sceneIndex in [nil, ["aa11": 0]] as [[String: Int]?] {
            let result = groups(read, .piece(docId: "doc-a", includesBookLevel: false),
                                sceneIndex: sceneIndex, sceneTitles: ["INT. HALL - DAY"])
            XCTAssertEqual(result.map(\.key), [.wholePiece(docId: "doc-a"), .unplaced(docId: "doc-a")],
                           "screenplay: \(sceneIndex != nil)")
            XCTAssertEqual(result.last?.title, "Position unknown")
            XCTAssertEqual(itemIds(result.last!), ["note:doc-a/n-bb", "finding:doc-a/f-aa", "todo:doc-a/t-aa"])
        }

        // A Book: inside the piece's group, nothing dropped.
        let book = groups(read, .pieces(docIds: ["doc-a"], includesBookLevel: true))
        XCTAssertEqual(book.map(\.key), [.piece(docId: "doc-a")])
        XCTAssertEqual(book[0].items.count, 4)
    }

    /// A paragraph heading is never empty: no text reads as a placeholder.
    func test_aParagraphWithNoTextToShowIsTitledByAPlaceholder() {
        let result = groups(snapshot([note("n-aa", pid: "aa11"), note("n-bb", pid: "bb22")],
                                     sequences: ["doc-a": ["aa11", "bb22"]], text: ["bb22": "  "]),
                            .piece(docId: "doc-a", includesBookLevel: false))
        XCTAssertEqual(result.map(\.title), ["Text unavailable", "Empty paragraph"])
    }

    // MARK: - Nothing to group

    func test_outsideAndElsewhereGroupNothing() {
        let read = snapshot([note("n-a", pid: "aa11")], sequences: ["doc-a": ["aa11"]])
        XCTAssertEqual(groups(read, .outside), [])
        XCTAssertEqual(groups(read, .elsewhere(docId: "doc-a")), [])
    }
}
