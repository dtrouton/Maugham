import XCTest
import MaughamCore
@testable import Maugham

/// **To resolve's list** (shell plan 2, Task 6): the decisions the view makes,
/// as pure functions over values the list already holds, plus two reads over
/// real stores (a typed to-do; the Settled section's contents) and a census.
/// Nothing is mounted or pressed (tripwire 33).
///
/// Paragraph ids are 4-char from `ParagraphID`'s alphabet (tripwire 8).
@MainActor
final class ResolvePaneTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Builders

    private let t = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(_ id: String, on docId: String = "doc-a", pid: String? = "aa11",
                      author: AnnotationAuthor? = nil, runId: String? = nil) -> ResolveItem {
        .note(ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .comment, paragraphId: pid, body: id, suggestedText: nil, priorText: nil,
            createdAt: t, createdBySession: nil, status: .open, userResponse: nil,
            resolvedAt: nil, isStale: false, author: author, compilerRunId: runId)))
    }

    private func todo(_ id: String, on docId: String = "doc-a", pid: String? = nil) -> ResolveItem {
        .todo(WriterTask(id: id, kind: .paneCreated,
                         anchor: TaskAnchor(docId: docId, paragraphId: pid),
                         body: id, status: .open, priority: 0, parentTaskId: nil,
                         createdAt: t, createdBySession: nil))
    }

    private func finding(_ id: String, on docId: String = "doc-a", pid: String? = "aa11") -> ResolveItem {
        .finding(docId: docId, Diagnostic(
            id: id, docId: docId,
            anchor: pid.map { .init(paragraphId: $0, anchorText: "x") },
            body: id, category: nil, runId: "run-1", kind: .conformanceStrain))
    }

    private let structure: [StructureItem] = [
        StructureItem(id: "doc-a", title: "Arrival", type: .document, path: "manuscript/a.md"),
        StructureItem(id: "part-1", title: "Part One", type: .group, children: [
            StructureItem(id: "doc-b", title: "Breakfast", type: .document, path: "manuscript/b.md"),
        ]),
    ]

    private func groups(_ items: [ResolveItem], _ scope: ResolveScope,
                        sequences: [String: [String]] = ["doc-a": ["aa11", "bb22"], "doc-b": ["cc33"]])
        -> [ResolveGroup] {
        ResolveGrouping.groups(
            ResolveSnapshot(items: items, sequences: sequences, paragraphText: [:], unreadableDocIds: []),
            scope: scope, structure: structure, sceneIndex: nil, sceneTitles: [], figureNames: [:])
    }

    // MARK: - To-do drag-reorder (carried item 11)

    func test_todosReorderOnlyUnderMineAloneWithinOneOpenPiece() {
        let two = [todo("t1"), todo("t2")]
        XCTAssertTrue(ResolvePane.reordersTodos(visible: two, selection: [.mine], mayAct: true))
        XCTAssertFalse(ResolvePane.reordersTodos(visible: two, selection: [], mayAct: true),
                       "everything shown is not Mine alone")
        XCTAssertFalse(ResolvePane.reordersTodos(visible: two, selection: [.mine, .checks], mayAct: true),
                       "a second chip beside Mine")
        XCTAssertFalse(ResolvePane.reordersTodos(visible: two, selection: [.mine], mayAct: false),
                       "the piece is not the open one")
        XCTAssertFalse(ResolvePane.reordersTodos(
            visible: [todo("t1"), todo("t2", on: "doc-b")], selection: [.mine], mayAct: true),
            "two pieces' to-dos")
        XCTAssertFalse(ResolvePane.reordersTodos(
            visible: [todo("t1"), note("n1", author: AnnotationAuthor(sourceKind: .human, displayName: "Me"))], selection: [.mine], mayAct: true),
            "Mine holds her own note too: not every visible item is a to-do")
        XCTAssertFalse(ResolvePane.reordersTodos(visible: [], selection: [.mine], mayAct: true),
                       "nothing to reorder")
        XCTAssertFalse(ResolvePane.reordersTodos(
            visible: [todo("p1", on: ProjectStore.projectTasksDocId)], selection: [.mine], mayAct: true),
            "the Book's to-dos have no Document to reorder through")
    }

    // MARK: - The refresh key (carried items 2, 3)

    /// Every input that changes what the list shows moves the list's key:
    /// the event token (`.maughamAnnotationsChanged`), a note added to the
    /// open piece, a to-do typed into it, a Book-level to-do and a check's
    /// sidecar. A typed to-do moves only the cheap half (`openTodos`), never
    /// the read key that runs the walks.
    func test_theRefreshKeyMovesOnEveryInputThatChangesTheList() async throws {
        let (doc, store, documentStore) = try await openDocument()
        let diagnostics = DiagnosticsStore(projectRoot: store.url, device: DeviceSlug.make(from: "test-mac"))
        let scope = ResolveScope.piece(docId: doc.docId, includesBookLevel: false)
        func read(_ token: Int) -> ResolveReadKey {
            ResolvePane.readKey(scope: scope, annotationsToken: token, store: store,
                                documentStore: documentStore, diagnostics: diagnostics,
                                localName: "Me")
        }
        func key(_ token: Int) -> ResolveListKey {
            ResolveListKey(regroup: ResolveRegroupKey(read: read(token), script: nil),
                           openTodos: ResolvePane.openTodoVersion(scope: scope, documentStore: documentStore))
        }
        let start = key(0)
        XCTAssertEqual(key(0), start, "premise: nothing moved, nothing moves")

        XCTAssertNotEqual(read(1), read(0), "the annotations event's token moves the read")

        let pid = try XCTUnwrap(doc.sequence.first)
        try await doc.addAnnotation(kind: .comment, paragraphId: pid, body: "a note")
        let afterNote = key(0)
        XCTAssertNotEqual(afterNote.regroup.read, start.regroup.read, "a note on the open piece")

        doc.setFullText("Hello.\n\n- [ ] typed to-do")
        let afterTodo = key(0)
        XCTAssertNotEqual(afterTodo, afterNote, "a to-do typed into the open piece")
        XCTAssertEqual(afterTodo.regroup.read, afterNote.regroup.read,
                       "and only the to-do half moved: no walk for a keystroke")

        _ = store.createProjectPaneTask(body: "book thing", undoManager: nil)
        let afterBook = key(0)
        XCTAssertNotEqual(afterBook.regroup.read, afterTodo.regroup.read, "a Book-level to-do")

        diagnostics.replace(
            run: CompilerRun(id: "run-1", at: t, model: "test-model", lastOpId: "01BBB1",
                             deltaSummary: "1 new", intentSnapshot: nil, passId: nil, round: nil,
                             freshEyes: nil, kind: .check),
            diagnostics: [Diagnostic(id: "d1", docId: doc.docId, anchor: nil, body: "strain",
                                     category: nil, runId: "run-1", kind: .conformanceStrain)],
            docId: doc.docId)
        XCTAssertNotEqual(key(0).regroup.read, afterBook.regroup.read, "a check's sidecar")

        XCTAssertNotEqual(
            ResolvePane.readKey(scope: .outside, annotationsToken: 0, store: store,
                                documentStore: documentStore, diagnostics: diagnostics, localName: "Me"),
            read(0), "the faces' scope")
    }

    /// **Carried item 3.** The old Tasks pane refreshed on the open document's
    /// `tasksVersion`; typing `- [ ]` bumps it at once (`Document.setFullText`'s
    /// inline-task fast path, `changeTouchesTaskMarkup`). The list key carries
    /// the open in-scope pieces' `tasksVersion`, so the typed to-do moves it,
    /// and the step it triggers lists the to-do.
    func test_aTypedTodoReachesTheList() async throws {
        let (doc, store, documentStore) = try await openDocument()
        let scope = ResolveScope.piece(docId: doc.docId, includesBookLevel: false)
        func key() -> ResolveListKey {
            ResolveListKey(
                regroup: ResolveRegroupKey(read: ResolvePane.readKey(
                    scope: scope, annotationsToken: 0, store: store,
                    documentStore: documentStore, diagnostics: nil, localName: "Me"), script: nil),
                openTodos: ResolvePane.openTodoVersion(scope: scope, documentStore: documentStore))
        }
        var held = ResolvePane.refreshed(.empty, step: .read, scope: scope, store: store,
                                         documentStore: documentStore, diagnostics: nil)
        XCTAssertEqual(todoBodies(held), [], "premise: no to-do yet")
        let before = key()

        // The editor's binding setter is `doc.setFullText` (EditorHost).
        doc.setFullText("Hello.\n\n- [ ] fix the dock")

        let after = key()
        XCTAssertNotEqual(after, before, "the typed to-do moves the key with no burst flush")
        let step = ResolvePane.refreshStep(after, last: before)
        held = ResolvePane.refreshed(held, step: step, scope: scope, store: store,
                                     documentStore: documentStore, diagnostics: nil)
        XCTAssertEqual(todoBodies(held), ["fix the dock"], "and the step it triggers lists it")
    }

    /// **Review I1.** Every keystroke on a `- [ ]` line bumps `tasksVersion`.
    /// At a piece and at the Book, that is a splice of the open piece's live
    /// to-dos — never the project's task walk, which re-derives every closed
    /// piece from disk. Counted through the walk's own rebuild counter.
    func test_aKeystrokeInATodoLineRebuildsNoProjectAggregate() async throws {
        let (doc, store, documentStore) = try await openDocument()
        doc.setFullText("Hello.\n\n- [ ] fix")
        for scope in [ResolveScope.piece(docId: doc.docId, includesBookLevel: false),
                      .pieces(docIds: [doc.docId, "doc-closed"], includesBookLevel: true)] {
            func key() -> ResolveListKey {
                ResolveListKey(
                    regroup: ResolveRegroupKey(read: ResolvePane.readKey(
                        scope: scope, annotationsToken: 0, store: store,
                        documentStore: documentStore, diagnostics: nil, localName: "Me"), script: nil),
                    openTodos: ResolvePane.openTodoVersion(scope: scope, documentStore: documentStore))
            }
            var held = ResolvePane.refreshed(.empty, step: .read, scope: scope, store: store,
                                             documentStore: documentStore, diagnostics: nil)
            var last = key()
            let rebuilds = store._debugTasksRebuildCount
            var typed = "- [ ] fix"
            for letter in [" t", "h", "e", " dock"] {
                typed += letter
                doc.setFullText("Hello.\n\n" + typed)
                let now = key()
                let step = ResolvePane.refreshStep(now, last: last)
                XCTAssertEqual(step, .todos, "\(scope): a keystroke on a to-do line is the cheap step")
                held = ResolvePane.refreshed(held, step: step, scope: scope, store: store,
                                             documentStore: documentStore, diagnostics: nil)
                last = now
            }
            XCTAssertEqual(store._debugTasksRebuildCount, rebuilds,
                           "\(scope): no keystroke rebuilt the project's task aggregate")
            XCTAssertTrue(todoBodies(held).contains("fix the dock"),
                          "\(scope): and the list holds the to-do as typed")
            XCTAssertEqual(todoBodies(held).filter { $0.hasPrefix("fix") }.count, 1,
                           "\(scope): spliced, not duplicated")
        }
    }

    private func todoBodies(_ snapshot: ResolveSnapshot) -> [String] {
        snapshot.items.compactMap { if case .todo(let task) = $0 { return task.body } else { return nil } }
    }

    /// **Carried item 2.** When the read key moves, the walks run (the read
    /// already reads the piece's text); a script-only change re-reads the
    /// text; open to-dos alone splice; the first build reads.
    func test_aReadRunsBeforeARegroupAndAScriptAloneOnlyRereads() {
        let read = ResolveReadKey(scope: .piece(docId: "doc-a", includesBookLevel: false),
                                  annotationsToken: 0, openAnnotationVersions: [], projectTasksVersion: 0,
                                  diagnosticsVersion: 0, passes: [], localName: "Me")
        let moved = ResolveReadKey(scope: .piece(docId: "doc-a", includesBookLevel: false),
                                   annotationsToken: 1, openAnnotationVersions: [], projectTasksVersion: 0,
                                   diagnosticsVersion: 0, passes: [], localName: "Me")
        let script = FountainTokenizer().parse("INT. KITCHEN - DAY\n\nShe waits.")
        let key = ResolveListKey(regroup: ResolveRegroupKey(read: read, script: nil), openTodos: 0)
        XCTAssertEqual(ResolvePane.refreshStep(key, last: nil), .read, "the first build reads")
        XCTAssertEqual(ResolvePane.refreshStep(
            ResolveListKey(regroup: ResolveRegroupKey(read: read, script: script), openTodos: 0), last: key),
            .reread, "the read key held, the script moved: re-read the text, regroup")
        XCTAssertEqual(ResolvePane.refreshStep(
            ResolveListKey(regroup: ResolveRegroupKey(read: read, script: nil), openTodos: 3), last: key),
            .todos, "only the open to-dos moved: splice them")
        XCTAssertEqual(ResolvePane.refreshStep(
            ResolveListKey(regroup: ResolveRegroupKey(read: moved, script: script), openTodos: 3), last: key),
            .read, "everything moved: the read, whose text and to-dos the regroup then uses")
    }

    // MARK: - The stet flourish (controller ruling)

    func test_aStettedNoteIsHeldForItsFlourish() {
        let at = t
        XCTAssertEqual(ResolveStetHold.seconds, 2.5, "the old queue's flourish")
        XCTAssertTrue(ResolveStetHold.holds(stettedAt: at, now: at))
        XCTAssertTrue(ResolveStetHold.holds(stettedAt: at, now: at.addingTimeInterval(2.4)))
        XCTAssertFalse(ResolveStetHold.holds(stettedAt: at, now: at.addingTimeInterval(2.5)))

        let previous = ResolveSnapshot(items: [note("n1"), note("n2")], sequences: [:],
                                       paragraphText: [:], unreadableDocIds: [])
        let fresh = ResolveSnapshot(items: [note("n2")], sequences: [:],
                                    paragraphText: [:], unreadableDocIds: [])
        let inside = ResolveStetHold.keeping(fresh, previous: previous, stettedAt: ["n1": at],
                                             now: at.addingTimeInterval(1))
        XCTAssertEqual(Set(inside.snapshot.items.map(\.id)), Set(previous.items.map(\.id)),
                       "inside the flourish the stetted note stays through the read")
        XCTAssertEqual(inside.kept, ["n1"])
        let after = ResolveStetHold.keeping(fresh, previous: previous, stettedAt: ["n1": at],
                                            now: at.addingTimeInterval(3))
        XCTAssertEqual(after.snapshot, fresh, "after it, the note is gone")
        let notStetted = ResolveStetHold.keeping(fresh, previous: previous, stettedAt: [:], now: at)
        XCTAssertEqual(notStetted.snapshot, fresh, "a note that left for any other reason leaves")
        let stillOpen = ResolveStetHold.keeping(previous, previous: previous, stettedAt: ["n1": at], now: at)
        XCTAssertEqual(stillOpen.snapshot, previous, "never duplicated while the read still lists it")
        XCTAssertEqual(stillOpen.kept, [])
    }

    // MARK: - The Book's Settled (review I2)

    /// The Book's done to-dos have a home once the Tasks pane is gone: each
    /// verb is reachable and actually lands on the project stream (un-tick,
    /// archive, delete, Archive all done), with no Document loaded.
    func test_theBooksDoneTodosAreSettledAndEachVerbLands() async throws {
        XCTAssertTrue(ResolveSettled.offersBook(scope: .pieces(docIds: ["doc-a"], includesBookLevel: true)))
        XCTAssertTrue(ResolveSettled.offersBook(scope: .piece(docId: "doc-a", includesBookLevel: true)),
                      "a screenplay's Book")
        XCTAssertFalse(ResolveSettled.offersBook(scope: .pieces(docIds: ["doc-a"], includesBookLevel: false)),
                       "a Part")
        XCTAssertFalse(ResolveSettled.offersBook(scope: .piece(docId: "doc-a", includesBookLevel: false)))
        XCTAssertFalse(ResolveSettled.offersBook(scope: .outside))

        let (_, store, documentStore) = try await openDocument()
        let verbs = ResolveTaskVerbs(store: store, documentStore: documentStore,
                                     openDocId: nil, undoManager: nil)
        func book(_ id: String) -> WriterTask? { ResolveTaskVerbs.bookTasks(store: store).first { $0.id == id } }
        let one = store.createProjectPaneTask(body: "index", undoManager: nil)
        let two = store.createProjectPaneTask(body: "blurb", undoManager: nil)
        let three = store.createProjectPaneTask(body: "dedication", undoManager: nil)
        for task in [one, two, three] {
            XCTAssertTrue(verbs.offered(task).toggle, "premise: the author's Book to-dos offer every verb")
            verbs.toggle(task)
        }
        XCTAssertEqual(Set(ResolveSettled.bookDone(store: store).map(\.id)), [one.id, two.id, three.id],
                       "ticking a Book to-do lands, and Settled on the Book lists it")

        verbs.toggle(try XCTUnwrap(book(one.id)))
        XCTAssertEqual(book(one.id)?.status, .open, "un-tick lands")
        verbs.archive(try XCTUnwrap(book(two.id)))
        XCTAssertEqual(book(two.id)?.status, .archived, "archive lands")
        verbs.toggle(try XCTUnwrap(book(one.id)))
        verbs.delete(try XCTUnwrap(book(one.id)))
        XCTAssertEqual(book(one.id)?.status, .archived, "delete lands (an archive, as for any pane to-do)")
        verbs.archiveAllDoneOnTheBook()
        XCTAssertEqual(book(three.id)?.status, .archived, "Archive all done lands")
        XCTAssertEqual(ResolveSettled.bookDone(store: store), [])
        XCTAssertTrue(documentStore.allOpenDocuments().allSatisfy { $0.docId == "doc-test" },
                      "and no document was loaded for the Book")
    }

    /// Hidden where the posture refuses — never an enabled no-op.
    func test_theBooksVerbsAreHiddenWhereThePostureRefuses() {
        let reviewer = Posture(LocalWritePermit(permit: .reviewer, actor: .author,
                                                documentClass: .piece("doc-a")))
        XCTAssertFalse(reviewer.allows(.task), "premise: a reviewer files no task")
        XCTAssertEqual(TaskRowVerbs.decide(kind: .paneCreated, posture: reviewer),
                       TaskRowVerbs(toggle: false, archive: false, delete: false, move: false))
        XCTAssertFalse(ResolveSettled.offersArchiveAllDone(posture: reviewer, doneCount: 3))
        XCTAssertFalse(ResolveSettled.offersArchiveAllDone(posture: Posture(.unrestricted), doneCount: 0),
                       "nothing done: nothing to press")
        XCTAssertTrue(ResolveSettled.offersArchiveAllDone(posture: Posture(.unrestricted), doneCount: 3))
    }

    // MARK: - Requests

    func test_aFocusRequestOpensThatPiecesGroup() {
        let book = ResolveScope.pieces(docIds: ["doc-a", "doc-b"], includesBookLevel: true)
        // Dense, so nothing is open by default.
        let items = (0..<8).map { note("a\($0)") } + (0..<8).map { note("b\($0)", on: "doc-b", pid: "cc33") }
        let built = groups(items, book)
        XCTAssertTrue(ResolveFilter.isDense(items), "premise: dense, every group closed")
        XCTAssertEqual(ResolveFilter.expanded(built, cursor: nil, dense: true), [], "premise")

        let outcome = ResolvePane.apply(
            .focus(groupOwnerId: "doc-b"), groups: built, chips: [.others],
            activePassId: nil, dense: true, selection: [.others], choices: [:])
        XCTAssertEqual(outcome.scrollTo, .piece(docId: "doc-b"))
        XCTAssertEqual(ResolveFilter.expanded(built, cursor: nil, dense: true, choices: outcome.choices),
                       [.piece(docId: "doc-b")], "that piece's group opens, and only it")
        XCTAssertEqual(outcome.selection, [.others], "a focus leaves the filter alone")

        let absent = ResolvePane.apply(
            .focus(groupOwnerId: "doc-z"), groups: built, chips: [.others],
            activePassId: nil, dense: true, selection: [.others], choices: [:])
        XCTAssertNil(absent.scrollTo, "a piece with no group here: nothing moves")
        XCTAssertEqual(absent.choices, [:])
    }

    func test_aFilterRequestSelectsItsChipOrIsInert() {
        let built = groups([note("n1"), finding("f1")], .piece(docId: "doc-a", includesBookLevel: false))
        let chips: [ResolveSource] = [.checks, .others]
        let checks = ResolvePane.apply(.filter(.checks), groups: built, chips: chips,
                                       activePassId: nil, dense: false, selection: [.others], choices: [:])
        XCTAssertEqual(checks.selection, [.checks])
        let mine = ResolvePane.apply(.filter(.mine), groups: built, chips: chips,
                                     activePassId: nil, dense: false, selection: [.others], choices: [:])
        XCTAssertEqual(mine.selection, [.others], "no Mine chip: the writer's filter stands")
        XCTAssertNil(mine.scrollTo)
    }

    // MARK: - The caret (carried item 9)

    /// Only the open piece has a caret group: off it, or at Book scope, the
    /// caret is never even read.
    func test_noCaretGroupOffTheOpenPieceOrAtBookScope() {
        var asked = 0
        let reader: () -> String? = { asked += 1; return "aa11" }
        let piece = ResolveScope.piece(docId: "doc-a", includesBookLevel: false)
        XCTAssertNil(ResolvePane.caretParagraph(scope: piece, mayAct: false, read: reader))
        XCTAssertNil(ResolvePane.caretParagraph(
            scope: .pieces(docIds: ["doc-a"], includesBookLevel: true), mayAct: true, read: reader))
        XCTAssertNil(ResolvePane.caretParagraph(scope: .outside, mayAct: true, read: reader))
        XCTAssertEqual(asked, 0, "the caret is read only where the faces' piece is the open one")
        XCTAssertEqual(ResolvePane.caretParagraph(scope: piece, mayAct: true, read: reader), "aa11")
    }

    /// Per caret move only the caret function runs, and the list scrolls only
    /// when the caret's GROUP changes — never while it stays in one, so it
    /// does not fight the writer's own scrolling of the list.
    func test_aCaretMoveInsideOneGroupDoesNotScroll() {
        let piece = ResolveScope.piece(docId: "doc-a", includesBookLevel: false)
        let built = groups([note("n1", pid: "aa11"), note("n2", pid: "bb22")], piece)
        let first = ResolveFilter.cursorGroup(paragraphId: "aa11", docId: "doc-a", sceneIndex: nil, groups: built)
        let same = ResolveFilter.cursorGroup(paragraphId: "aa11", docId: "doc-a", sceneIndex: nil, groups: built)
        let other = ResolveFilter.cursorGroup(paragraphId: "bb22", docId: "doc-a", sceneIndex: nil, groups: built)
        XCTAssertEqual(ResolvePane.scrollTarget(from: nil, to: first), first, "arriving in a group scrolls to it")
        XCTAssertNil(ResolvePane.scrollTarget(from: first, to: same), "a move inside the group: no scroll")
        XCTAssertEqual(ResolvePane.scrollTarget(from: first, to: other), other, "a new group: scroll")
        XCTAssertNil(ResolvePane.scrollTarget(from: other, to: nil), "leaving every group scrolls nowhere")
    }

    // MARK: - Captions (carried item 8)

    func test_rowCaptionsNameTheCheckAndTheNextCheck() {
        XCTAssertEqual(ResolvePane.caption(for: note("c", runId: "run-1"), localName: "Me"),
                       ResolvePane.fromTheCheckCaption)
        XCTAssertEqual(ResolvePane.fromTheCheckCaption, "From the check")
        XCTAssertEqual(ResolvePane.caption(for: finding("f"), localName: "Me"),
                       ResolvePane.replacedByTheNextCheckCaption)
        XCTAssertEqual(ResolvePane.replacedByTheNextCheckCaption, "Replaced by the next check")
        XCTAssertNil(ResolvePane.caption(for: note("n"), localName: "Me"), "anyone else's note: no caption")
        XCTAssertNil(ResolvePane.caption(for: todo("t"), localName: "Me"))
    }

    // MARK: - Nothing is an enabled no-op (carried item 6)

    func test_offThePieceTheCheckPromoteAndArchiveAllDoneAreHidden() {
        let author = Posture(.unrestricted)
        let off = ResolvePane.findingOffers(finding("f"), mayAct: false, posture: author,
                                            statementAllowsAnswer: true, durable: true)
        XCTAssertTrue(off.answer, "Answer files a ruling: offered on any piece")
        XCTAssertFalse(off.promote, "Promote writes the piece's Document: hidden off it")
        let on = ResolvePane.findingOffers(finding("f"), mayAct: true, posture: author,
                                           statementAllowsAnswer: true, durable: true)
        XCTAssertTrue(on.answer)
        XCTAssertTrue(on.promote)
        let running = ResolvePane.findingOffers(finding("f"), mayAct: true, posture: author,
                                                statementAllowsAnswer: true, durable: false)
        XCTAssertFalse(running.answer || running.promote, "a run still arriving has no fates")

        XCTAssertFalse(ResolveSettled.offered(
            scope: .piece(docId: "doc-a", includesBookLevel: false), mayAct: false),
            "Archive all done lives in the piece's Settled, which is not drawn off the open piece")
    }

    // MARK: - Settled (carried item 5)

    func test_theSettledSectionIsOfferedOnlyOnTheOpenPiece() async throws {
        let piece = ResolveScope.piece(docId: "doc-a", includesBookLevel: false)
        XCTAssertTrue(ResolveSettled.offered(scope: piece, mayAct: true))
        XCTAssertFalse(ResolveSettled.offered(scope: piece, mayAct: false), "the piece is not open")
        XCTAssertFalse(ResolveSettled.offered(
            scope: .pieces(docIds: ["doc-a"], includesBookLevel: true), mayAct: true), "the Book")
        XCTAssertFalse(ResolveSettled.offered(scope: .figure(id: "fig-aaaa1111"), mayAct: true))
        XCTAssertFalse(ResolveSettled.offered(scope: .outside, mayAct: true))

        // Reopen (RULING-29) and a findable Deleted view (RULING-34) survive
        // the Annotations pane: the open piece's Settled holds both.
        let (doc, _, documentStore) = try await openDocument()
        let pid = try XCTUnwrap(doc.sequence.first)
        let rejected = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: pid, span: nil, body: "settled", authorName: "Me")
        try await doc.rejectAnnotation(id: rejected)
        let deleted = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: pid, span: nil, body: "deleted", authorName: "Me")
        try await doc.withdrawReviewerAnnotation(id: deleted, authorName: "Me")
        let task = doc.createPaneTask(body: "done thing", parentTaskId: nil)
        doc.setTaskStatus(id: task.id, status: .done)

        let contents = ResolveSettled.contents(of: doc)
        XCTAssertEqual(contents.resolved.map(\.id), [rejected], "the resolved note")
        XCTAssertEqual(contents.deleted.map(\.id), [deleted], "the deleted note")
        XCTAssertEqual(contents.done.map(\.id), [task.id], "the done to-do")

        let posture = documentStore.posture(forDocId: doc.docId)
        let offered = ResolveVerbGate.noteVerbs(
            AnnotationRowVerbs.decide(posture: posture, isOwn: true, rulingStatement: nil, lessons: posture),
            mayAct: true)
        XCTAssertTrue(offered.dispose, "Reopen is the dispose group, offered on the open piece")
        XCTAssertTrue(AnnotationRowVerbs.restoresDeleted(
            posture: posture, standing: doc.restoreStanding(annotationId: deleted)),
            "her own deleted note offers Restore")
    }

    // MARK: - Empty states and the incomplete line (carried items 4, 12)

    func test_anOutsideSubjectSaysWhatToResolveIsAbout() {
        XCTAssertEqual(ResolvePane.emptyState(scope: .outside, hasItems: false, hasVisible: false, offersColdStart: false),
                       .outside)
        XCTAssertEqual(ResolvePane.EmptyState.outside.sentence,
                       "To resolve gathers what has been raised about a piece, a Part or the Book: "
                       + "notes, checks, to-dos and questions. Choose one in the tree.")
        XCTAssertEqual(ResolvePane.emptyState(scope: .elsewhere(docId: "doc-x"), hasItems: false,
                                              hasVisible: false, offersColdStart: false), .elsewhere)
        XCTAssertEqual(ResolvePane.EmptyState.elsewhere.sentence,
                       "This piece belongs to another project. Open that project to see what it raises.")
        let piece = ResolveScope.piece(docId: "doc-a", includesBookLevel: false)
        XCTAssertEqual(ResolvePane.emptyState(scope: piece, hasItems: false, hasVisible: false, offersColdStart: true), .coldStart)
        XCTAssertEqual(ResolvePane.emptyState(scope: piece, hasItems: false, hasVisible: false, offersColdStart: false), .nothing)
        XCTAssertEqual(ResolvePane.EmptyState.nothing.sentence, "Nothing to resolve.")
        XCTAssertEqual(ResolvePane.emptyState(scope: piece, hasItems: true, hasVisible: false,
                                              offersColdStart: true), .filteredOut,
                       "items hidden by the filter: one quiet line, never a blank list")
        XCTAssertEqual(ResolvePane.EmptyState.filteredOut.sentence, "Nothing under this filter.")
        XCTAssertNil(ResolvePane.emptyState(scope: piece, hasItems: true, hasVisible: true, offersColdStart: true),
                     "items: no empty state")
    }

    /// RULING-54: any piece that would not read is named above the list, so
    /// the list never looks complete beside a board that says "unknown".
    func test_anUnreadablePieceIsNamedAboveTheList() {
        let read = ResolveSnapshot(items: [note("n1")], sequences: [:], paragraphText: [:],
                                   unreadableDocIds: ["doc-b"])
        XCTAssertEqual(ResolvePane.incompleteLine(read, structure: structure, figureNames: [:]),
                       "This list may be incomplete: Breakfast could not be read.")
        let whole = ResolveSnapshot(items: [], sequences: [:], paragraphText: [:], unreadableDocIds: [])
        XCTAssertNil(ResolvePane.incompleteLine(whole, structure: structure, figureNames: [:]))
    }

    // MARK: - The census (tripwires 9, 4)

    static let sidebarListSpellings = ["List(", ".listStyle(.sidebar)", ".onTapGesture"]

    static func offenders(in sources: [String: String]) -> [String] {
        sources.flatMap { name, text in
            let code = SourceScan.codeLines(of: text).joined(separator: "\n")
            return sidebarListSpellings.filter { code.contains($0) }.map { "\(name): \($0)" }
        }.sorted()
    }

    func test_toResolveIsNotASidebarListAndNoRowTaps() throws {
        let dir = SourceTree.repoRoot.appendingPathComponent("Maugham/Views/Resolve")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(names.contains("ResolvePane.swift"), "the census must read the list itself")
        var sources: [String: String] = [:]
        for name in names {
            sources[name] = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        }
        sources["AnnotationRow.swift"] = try String(
            contentsOf: SourceTree.repoRoot.appendingPathComponent("Maugham/Views/AnnotationRow.swift"),
            encoding: .utf8)
        XCTAssertEqual(Self.offenders(in: sources), [])
        XCTAssertTrue(SourceScan.codeLines(of: sources["ResolvePane.swift"] ?? "")
            .contains { $0.contains("LazyVStack") }, "premise: the list is a lazy stack")

        for spelling in Self.sidebarListSpellings {
            let planted = sources.merging(["Planted.swift": "x\(spelling)y"]) { $1 }
            XCTAssertEqual(Self.offenders(in: planted), ["Planted.swift: \(spelling)"],
                           "the census must catch \(spelling)")
        }
    }

    /// Carried item 7: the round cockpit's model menu and the check header's
    /// bind ONE setting (`compilerModel`), so the head draws it once — the
    /// cockpit's, the check header's hidden.
    func test_theHeadDrawsOneModelMenu() throws {
        let head = try String(contentsOf: SourceTree.repoRoot.appendingPathComponent(
            "Maugham/Views/Resolve/ResolveHead.swift"), encoding: .utf8)
        let code = SourceScan.codeLines(of: head).joined(separator: "\n")
        XCTAssertTrue(code.contains("offersModelMenu: false"),
                      "the check header in the head does not draw a second model menu")
    }

    // MARK: - Fixtures

    /// A one-piece project with its document loaded and registered, as the
    /// editor registers it.
    private func openDocument() async throws -> (Document, ProjectStore, DocumentStore) {
        let url = temp.url.appendingPathComponent("RP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try Data("Hello.".utf8).write(to: url.appendingPathComponent(docPath))
        // A closed piece with a to-do, so the project's walk has real work.
        try Data("Closed.\n\n- [ ] closed thing".utf8).write(
            to: url.appendingPathComponent("manuscript/c2.md"))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-test", title: "C1", type: .document, path: docPath),
                        StructureItem(id: "doc-closed", title: "C2", type: .document,
                                      path: "manuscript/c2.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: url.appendingPathComponent("project.maugham.json"))
        let doc = try await Document.load(
            url: url.appendingPathComponent(docPath), device: "m", session: "s", presenter: nil)
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        documentStore.register(document: doc, for: docPath)
        return (doc, store, documentStore)
    }
}
