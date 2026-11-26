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
            scope: scope, structure: structure, sceneIndex: nil, sceneTitles: [], figureNames: [:], book: PieceNoun.Book(type: .novel))
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
    /// sidecar. A typed to-do and a note on the open piece move only the
    /// cheap half (`openTodos`, `openNotes`), never the read key.
    func test_theRefreshKeyMovesOnEveryInputThatChangesTheList() async throws {
        let (doc, store, documentStore) = try await openDocument()
        let diagnostics = DiagnosticsStore(projectRoot: store.url, device: DeviceSlug.make(from: "test-mac"))
        let scope = ResolveScope.piece(docId: doc.docId, includesBookLevel: false)
        func read(_ token: Int) -> ResolveReadKey {
            ResolvePane.readKey(scope: scope, annotationsToken: token, store: store,
                                documentStore: documentStore, diagnostics: diagnostics,
                                localName: "Me", figureChanges: [])
        }
        func key(_ token: Int) -> ResolveListKey {
            ResolvePane.listKey(scope: scope, annotationsToken: token, store: store,
                                documentStore: documentStore, diagnostics: diagnostics,
                                localName: "Me", script: nil, figureChanges: [])
        }
        let start = key(0)
        XCTAssertEqual(key(0), start, "premise: nothing moved, nothing moves")

        XCTAssertNotEqual(read(1), read(0), "the annotations event's token moves the read")

        let pid = try XCTUnwrap(doc.sequence.first)
        try await doc.addAnnotation(kind: .comment, paragraphId: pid, body: "a note")
        let afterNote = key(0)
        XCTAssertNotEqual(afterNote, start, "a note on the open piece")
        XCTAssertEqual(afterNote.regroup.read, start.regroup.read,
                       "and only the live half moved: no walk for the open piece's note (review C1)")

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
                                documentStore: documentStore, diagnostics: diagnostics, localName: "Me", figureChanges: []),
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
                    documentStore: documentStore, diagnostics: nil, localName: "Me", figureChanges: []), script: nil),
                openTodos: ResolvePane.openTodoVersion(scope: scope, documentStore: documentStore))
        }
        var held = refreshed(.empty, step: .read, scope: scope, store: store, documentStore: documentStore)
        XCTAssertEqual(todoBodies(held), [], "premise: no to-do yet")
        let before = key()

        // The editor's binding setter is `doc.setFullText` (EditorHost).
        doc.setFullText("Hello.\n\n- [ ] fix the dock")

        let after = key()
        XCTAssertNotEqual(after, before, "the typed to-do moves the key with no burst flush")
        let step = ResolvePane.refreshStep(after, last: before)
        held = refreshed(held, step: step, scope: scope, store: store, documentStore: documentStore)
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
                        documentStore: documentStore, diagnostics: nil, localName: "Me", figureChanges: []), script: nil),
                    openTodos: ResolvePane.openTodoVersion(scope: scope, documentStore: documentStore))
            }
            var held = refreshed(.empty, step: .read, scope: scope, store: store, documentStore: documentStore)
            var last = key()
            let rebuilds = store._debugTasksRebuildCount
            var typed = "- [ ] fix"
            for letter in [" t", "h", "e", " dock"] {
                typed += letter
                doc.setFullText("Hello.\n\n" + typed)
                let now = key()
                let step = ResolvePane.refreshStep(now, last: last)
                XCTAssertEqual(step, .live, "\(scope): a keystroke on a to-do line is the cheap step")
                held = refreshed(held, step: step, scope: scope, store: store, documentStore: documentStore)
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

    /// One refresh step as the view runs it, over a fresh walk hold.
    private func refreshed(_ held: ResolveSnapshot, step: ResolveRefreshStep, scope: ResolveScope,
                           store: ProjectStore, documentStore: DocumentStore) -> ResolveSnapshot {
        var walks = ResolveWalkHold()
        return ResolvePane.refreshed(
            held, step: step,
            key: ResolvePane.readKey(scope: scope, annotationsToken: 0, store: store,
                                     documentStore: documentStore, diagnostics: nil, localName: "Me", figureChanges: []),
            walks: &walks, store: store, documentStore: documentStore, diagnostics: nil)
    }

    private func todoBodies(_ snapshot: ResolveSnapshot) -> [String] {
        snapshot.items.compactMap { if case .todo(let task) = $0 { return task.body } else { return nil } }
    }

    /// **Carried item 2.** When the read key moves, the walks run (the read
    /// already reads the piece's text); a script-only change re-reads the
    /// text; open to-dos alone splice; the first build reads.
    func test_aReadRunsBeforeARegroupAndAScriptAloneOnlyRereads() {
        let read = ResolveReadKey(scope: .piece(docId: "doc-a", includesBookLevel: false),
                                  annotationsToken: 0, openPieces: [], projectTasksVersion: 0,
                                  diagnosticsVersion: 0, passes: [], localName: "Me", figureChanges: [])
        let moved = ResolveReadKey(scope: .piece(docId: "doc-a", includesBookLevel: false),
                                   annotationsToken: 1, openPieces: [], projectTasksVersion: 0,
                                   diagnosticsVersion: 0, passes: [], localName: "Me", figureChanges: [])
        let script = WindowScript(docId: "doc-a", script: FountainTokenizer().parse("INT. KITCHEN - DAY\n\nShe waits."))
        let key = ResolveListKey(regroup: ResolveRegroupKey(read: read, script: nil), openTodos: 0)
        XCTAssertEqual(ResolvePane.refreshStep(key, last: nil), .read, "the first build reads")
        XCTAssertEqual(ResolvePane.refreshStep(
            ResolveListKey(regroup: ResolveRegroupKey(read: read, script: script), openTodos: 0), last: key),
            .reread, "the read key held, the script moved: re-read the text, regroup")
        XCTAssertEqual(ResolvePane.refreshStep(
            ResolveListKey(regroup: ResolveRegroupKey(read: read, script: nil), openTodos: 3), last: key),
            .live, "only the open to-dos moved: splice them")
        XCTAssertEqual(ResolvePane.refreshStep(
            ResolveListKey(regroup: ResolveRegroupKey(read: moved, script: script), openTodos: 3), last: key),
            .read, "everything moved: the read, whose text and to-dos the regroup then uses")
    }

    // MARK: - The stet flourish (controller ruling)

    func test_aStettedNoteIsHeldForItsFlourish() throws {
        let at = t
        XCTAssertEqual(ResolveStetHold.seconds, 2.5, "the old queue's flourish")
        XCTAssertTrue(ResolveStetHold.holds(stettedAt: at, now: at))
        XCTAssertTrue(ResolveStetHold.holds(stettedAt: at, now: at.addingTimeInterval(2.4)))
        XCTAssertFalse(ResolveStetHold.holds(stettedAt: at, now: at.addingTimeInterval(2.5)))

        let previous = ResolveSnapshot(items: [note("n1"), note("n2")], sequences: [:],
                                       paragraphText: [:], unreadableDocIds: [])
        let fresh = ResolveSnapshot(items: [note("n2")], sequences: [:],
                                    paragraphText: [:], unreadableDocIds: [])
        let stetted = stettedNote("n1")
        let live = [note("n1").id: stetted]
        let inside = ResolveStetHold.keeping(fresh, previous: previous, stettedAt: ["n1": at],
                                             now: at.addingTimeInterval(1), live: live)
        XCTAssertEqual(Set(inside.snapshot.items.map(\.id)), Set(previous.items.map(\.id)),
                       "inside the flourish the stetted note stays through the read")
        XCTAssertEqual(inside.kept, ["n1"])
        let held = try XCTUnwrap(inside.snapshot.items.compactMap { item -> Annotation? in
            if case .note(let n) = item, n.annotation.id == "n1" { return n.annotation }
            return nil
        }.first)
        XCTAssertEqual(held.status, .stetted, "the held row is the LIVE stetted note, not the stale open copy")
        let after = ResolveStetHold.keeping(fresh, previous: previous, stettedAt: ["n1": at],
                                            now: at.addingTimeInterval(3), live: live)
        XCTAssertEqual(after.snapshot, fresh, "after it, the note is gone")
        let notStetted = ResolveStetHold.keeping(fresh, previous: previous, stettedAt: [:], now: at,
                                                 live: live)
        XCTAssertEqual(notStetted.snapshot, fresh, "a note that left for any other reason leaves")
        let unknown = ResolveStetHold.keeping(fresh, previous: previous, stettedAt: ["n1": at], now: at,
                                              live: [:])
        XCTAssertEqual(unknown.snapshot, fresh, "a note the walk does not know is never held stale")
        let stillOpen = ResolveStetHold.keeping(previous, previous: previous, stettedAt: ["n1": at], now: at,
                                                live: live)
        XCTAssertEqual(stillOpen.snapshot, previous, "never duplicated while the read still lists it")
        XCTAssertEqual(stillOpen.kept, [])
    }

    private func stettedNote(_ id: String, on docId: String = "doc-a") -> ProjectAnnotation {
        ProjectAnnotation(docId: docId, annotation: Annotation(
            id: id, kind: .comment, paragraphId: "aa11", body: id, suggestedText: nil, priorText: nil,
            createdAt: t, createdBySession: nil, status: .stetted, userResponse: nil,
            resolvedAt: t, isStale: false))
    }

    /// **The held row offers Reopen alone**, as the old queue's live stetted
    /// row did, and no Stet (nor Accept, Archive, triage, a ruling, a choice,
    /// a lesson, Edit or Delete) is reachable during the hold — not even in
    /// the frame before the read, while the row's status is still open.
    func test_aHeldStetRowOffersReopenAlone() {
        let everything = AnnotationRowVerbs.unrestricted(isOwn: true)
        let stetted = ResolveStetHold.heldVerbs(everything, status: .stetted)
        XCTAssertEqual(stetted, AnnotationRowVerbs(
            acceptOrReject: false, dispose: true, answerAsRuling: false,
            makeChoice: false, keepAsLesson: false, ownNote: false),
            "dispose alone, which a stetted row draws as Reopen (showsReopen), not as Stet")
        XCTAssertFalse(AnnotationRow.offersTriage(status: .stetted), "and no triage menu on a stetted row")
        XCTAssertTrue(AnnotationRow.offersTriage(status: .open), "control: an open note is triaged")
        let beforeTheRead = ResolveStetHold.heldVerbs(everything, status: .open)
        XCTAssertFalse(beforeTheRead.dispose, "still open in the frame before the read: no Stet, no Archive")
        XCTAssertFalse(beforeTheRead.acceptOrReject)
        XCTAssertFalse(beforeTheRead.ownNote)
        XCTAssertFalse(ResolveStetHold.heldVerbs(
            AnnotationRowVerbs(acceptOrReject: false, dispose: false, answerAsRuling: false,
                               makeChoice: false, keepAsLesson: false, ownNote: false),
            status: .stetted).dispose, "the hold only removes: a posture without dispose gets no Reopen")
    }

    /// **Review N1.** Return (no task markup, no refresh), then `- [ ]` in the
    /// new paragraph: the `.live` splice refreshes the piece's paragraph
    /// order from its live document, so the to-do groups under its new
    /// paragraph and never under "No longer in the text".
    func test_aTodoTypedIntoANewParagraphGroupsUnderIt() async throws {
        let (doc, store, documentStore) = try await openDocument()
        let scope = ResolveScope.piece(docId: doc.docId, includesBookLevel: false)
        func key() -> ResolveListKey {
            ResolveListKey(
                regroup: ResolveRegroupKey(read: ResolvePane.readKey(
                    scope: scope, annotationsToken: 0, store: store,
                    documentStore: documentStore, diagnostics: nil, localName: "Me", figureChanges: []), script: nil),
                openTodos: ResolvePane.openTodoVersion(scope: scope, documentStore: documentStore))
        }
        var held = refreshed(.empty, step: .read, scope: scope, store: store, documentStore: documentStore)
        let before = key()
        doc.setFullText("Hello.\n\n")
        doc.setFullText("Hello.\n\n- [ ] fix the dock")
        let after = key()
        let step = ResolvePane.refreshStep(after, last: before)
        XCTAssertEqual(step, .live, "premise: the cheap step, no walk")
        held = refreshed(held, step: step, scope: scope, store: store, documentStore: documentStore)
        let newPid = try XCTUnwrap(doc.sequence.last)
        XCTAssertNotEqual(newPid, doc.sequence.first, "premise: the to-do is in a new paragraph")
        let groups = ResolveGrouping.groups(held, scope: scope, structure: store.manifest.structure,
                                            sceneIndex: nil, sceneTitles: [], figureNames: [:], book: PieceNoun.Book(type: .novel))
        let home = groups.first { group in
            group.items.contains { if case .todo(let task) = $0 { return task.body == "fix the dock" }; return false }
        }
        XCTAssertEqual(home?.key, .paragraph(docId: doc.docId, paragraphId: newPid),
                       "the typed to-do groups under its new paragraph")
        XCTAssertEqual(held.sequences[doc.docId], doc.sequence, "the piece's live order")
    }

    /// **Review N4.** A Book Archive all done whose every append the stream's
    /// door would refuse opens no undo group (no empty ⌘Z step).
    func test_archiveAllDoneOnTheBookOpensNoEmptyUndoGroup() {
        XCTAssertTrue(ResolveTaskVerbs.opensBookArchiveGroup(doneCount: 2, refusal: nil))
        XCTAssertFalse(ResolveTaskVerbs.opensBookArchiveGroup(
            doneCount: 2, refusal: ProjectStore.projectTaskNotPermittedRefusal), "every append refused")
        XCTAssertFalse(ResolveTaskVerbs.opensBookArchiveGroup(doneCount: 0, refusal: nil), "nothing done")
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

    /// **Archived to-dos have a surface, and Unarchive lands** (controller
    /// ruling, shell plan 2 Task 7 fix): the open piece's Settled lists its
    /// archived to-dos, the Book's Settled the Book's, and Unarchive opens
    /// each again — on the piece through its live `Document`, on the Book
    /// through the project stream.
    func test_archivedTodosAreSettledAndUnarchiveLands() async throws {
        let (doc, store, documentStore) = try await openDocument()
        let verbs = ResolveTaskVerbs(store: store, documentStore: documentStore,
                                     openDocId: doc.docId, undoManager: nil)
        let piece = doc.createPaneTask(body: "check the dates", parentTaskId: nil)
        doc.archiveTask(id: piece.id)
        let archived = try XCTUnwrap(ResolveSettled.contents(of: doc).archived.first { $0.id == piece.id },
                                     "the piece's Settled lists its archived to-do")
        XCTAssertTrue(ResolveTaskVerbs.offersUnarchive(archived, verbs: verbs.offered(archived)))
        verbs.unarchive(archived)
        XCTAssertEqual(doc.tasks(filter: TaskFilter(scope: .document(docId: doc.docId),
                                                    statuses: Set(TaskStatus.allCases)))
                        .first { $0.id == piece.id }?.status, .open, "Unarchive lands on the piece")
        XCTAssertFalse(ResolveSettled.contents(of: doc).archived.contains { $0.id == piece.id })

        let bookTask = store.createProjectPaneTask(body: "index", undoManager: nil)
        verbs.archive(bookTask)
        let bookArchived = try XCTUnwrap(ResolveSettled.bookArchived(store: store).first { $0.id == bookTask.id },
                                         "the Book's Settled lists its archived to-do")
        verbs.unarchive(bookArchived)
        XCTAssertEqual(ResolveTaskVerbs.bookTasks(store: store).first { $0.id == bookTask.id }?.status, .open,
                       "Unarchive lands on the Book")
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
            .focus(groupOwnerId: "doc-b"), groups: built, sceneIndex: nil, chips: [.others],
            activePassId: nil, dense: true, selection: [.others], choices: [:])
        XCTAssertEqual(outcome.scrollTo, .piece(docId: "doc-b"))
        XCTAssertEqual(ResolveFilter.expanded(built, cursor: nil, dense: true, choices: outcome.choices),
                       [.piece(docId: "doc-b")], "that piece's group opens, and only it")
        XCTAssertEqual(outcome.selection, [.others], "a focus leaves the filter alone")

        let absent = ResolvePane.apply(
            .focus(groupOwnerId: "doc-z"), groups: built, sceneIndex: nil, chips: [.others],
            activePassId: nil, dense: true, selection: [.others], choices: [:])
        XCTAssertNil(absent.scrollTo, "a piece with no group here: nothing moves")
        XCTAssertEqual(absent.choices, [:])
    }

    /// **Review M1.** A board count click on a piece whose open notes are all
    /// on its figures focuses that figure's group; and a focus whose group the
    /// filter hides gives the filter way, so the scroll target is shown.
    func test_aFocusFallsBackToThePiecesFigureAndUnhidesItsGroup() {
        let book = ResolveScope.pieces(docIds: ["doc-a", "doc-b"], includesBookLevel: true)
        let built = groups([note("a1"), note("f1", on: "fig-aaaa1111", pid: nil),
                            finding("s1", on: "doc-a")], book)
        let owners: [String: String?] = ["fig-aaaa1111": "doc-b"]
        XCTAssertEqual(ResolvePane.focusKey(ownerId: "doc-b", in: built, figureOwners: owners),
                       .figure(id: "fig-aaaa1111"), "the piece's owned figure's group")
        let outcome = ResolvePane.apply(.focus(groupOwnerId: "doc-b"), groups: built,
                                        sceneIndex: nil, chips: [.checks, .others], activePassId: nil, dense: false,
                                        selection: [.checks], choices: [:], figureOwners: owners)
        XCTAssertEqual(outcome.scrollTo, .figure(id: "fig-aaaa1111"))
        XCTAssertEqual(outcome.selection, [], "small: Checks hid the figure's note, so everything shows")
        let dense = ResolvePane.apply(.focus(groupOwnerId: "doc-b"), groups: built,
                                      sceneIndex: nil, chips: [.checks, .others], activePassId: nil, dense: true,
                                      selection: [.checks], choices: [:], figureOwners: owners)
        XCTAssertEqual(dense.selection, [.others], "dense: the group's own source")
        let kept = ResolvePane.apply(.focus(groupOwnerId: "doc-a"), groups: built,
                                     sceneIndex: nil, chips: [.checks, .others], activePassId: nil, dense: false,
                                     selection: [.checks], choices: [:], figureOwners: owners)
        XCTAssertEqual(kept.selection, [.checks], "a group the filter shows: the filter stands")
    }

    /// **Review M6.** A row held only for its stet flourish is settled: bulk
    /// acts over it no more than its own row would.
    func test_bulkSkipsARowHeldForItsFlourish() {
        let rows = ResolvePane.bulkRows([note("n1"), note("n2"), note("n3", on: "doc-b")],
                                        pieceDocId: "doc-a", heldForFlourish: ["n2"])
        XCTAssertEqual(rows.map(\.id), ["n1"])
    }

    func test_aFilterRequestSelectsItsChipOrIsInert() {
        let built = groups([note("n1"), finding("f1")], .piece(docId: "doc-a", includesBookLevel: false))
        let chips: [ResolveSource] = [.checks, .others]
        let checks = ResolvePane.apply(.filter(.checks), groups: built, sceneIndex: nil, chips: chips,
                                       activePassId: nil, dense: false, selection: [.others], choices: [:])
        XCTAssertEqual(checks.selection, [.checks])
        let mine = ResolvePane.apply(.filter(.mine), groups: built, sceneIndex: nil, chips: chips,
                                     activePassId: nil, dense: false, selection: [.others], choices: [:])
        XCTAssertEqual(mine.selection, [.others], "no Mine chip: the writer's filter stands")
        XCTAssertNil(mine.scrollTo)
    }

    // MARK: - A margin mark's click (shell p5 Task 2)

    /// **The event's receiver sets the caret group**: a margin mark's click
    /// makes its paragraph's group the list's caret group, opens it and
    /// scrolls there — the editor's caret is not asked. A paragraph the list
    /// has nothing on changes nothing.
    func test_aMarginClickMakesItsParagraphsGroupTheCaretGroup() throws {
        let piece = ResolveScope.piece(docId: "doc-a", includesBookLevel: false)
        let items = (0..<14).map { note("n\($0)") } + [finding("s1", pid: "bb22")]
        let built = groups(items, piece)
        XCTAssertTrue(ResolveFilter.isDense(items), "premise: dense, so nothing is open by default")
        let paragraph = ResolveGroup.Key.paragraph(docId: "doc-a", paragraphId: "bb22")
        XCTAssertTrue(built.contains { $0.key == paragraph }, "premise: bb22 has a group")

        let outcome = ResolvePane.apply(
            .showParagraph(docId: "doc-a", paragraphId: "bb22"), groups: built,
            sceneIndex: nil, chips: [.checks, .others], activePassId: nil, dense: true,
            selection: [.checks], choices: [:])
        XCTAssertEqual(outcome.scrollTo, paragraph, "the paragraph's group is the target, and the caret group")
        XCTAssertEqual(outcome.scrollTo, paragraph)
        XCTAssertEqual(ResolveFilter.expanded(built, cursor: outcome.scrollTo, dense: true,
                                              choices: outcome.choices), [paragraph])
        XCTAssertEqual(outcome.selection, [.checks], "the tick's own filter stands")

        let nothing = ResolvePane.apply(
            .showParagraph(docId: "doc-a", paragraphId: "zz99"), groups: built,
            sceneIndex: nil, chips: [.checks, .others], activePassId: nil, dense: true,
            selection: [.checks], choices: [:])
        XCTAssertNil(nothing.scrollTo)
        XCTAssertEqual(nothing.selection, [.checks])
    }

    /// **M5 (closing round B) — a clicked mark always shows its note.** A
    /// dense list filtered to Mine hides both notes on ¶bb22; the dot
    /// clicked is the one that is NOT the group's first. The filter gives
    /// way to that note's own source (a dense list always has one chip —
    /// never the group's first item's), its collapsed group opens, and its
    /// row is the marked one. Small, the filter gives way to everything.
    func test_aClickedMarkAlwaysShowsItsNote() throws {
        let piece = ResolveScope.piece(docId: "doc-a", includesBookLevel: false)
        let items = (0..<14).map { todo("t\($0)") }
            + [note("n-check", pid: "bb22", runId: "run-1"), note("n-other", pid: "bb22")]
        let built = groups(items, piece)
        let paragraph = ResolveGroup.Key.paragraph(docId: "doc-a", paragraphId: "bb22")
        let group = try XCTUnwrap(built.first { $0.key == paragraph })
        let first = try XCTUnwrap(group.items.first)
        let clicked = try XCTUnwrap(group.items.first { $0.id != first.id })
        guard case .note(let clickedNote) = clicked else { return XCTFail("premise: a note") }
        let chips: [ResolveSource] = [.mine, .checks, .others]
        XCTAssertNotEqual(ResolveFilter.source(of: first, localName: ""),
                          ResolveFilter.source(of: clicked, localName: ""),
                          "premise: the group's first item is of another source")

        let dense = ResolvePane.apply(
            .showParagraph(docId: "doc-a", paragraphId: "bb22", annotationId: clickedNote.annotation.id),
            groups: built, sceneIndex: nil, chips: chips, activePassId: nil, dense: true,
            selection: [.mine], choices: [paragraph: false])
        XCTAssertEqual(dense.selection, [ResolveFilter.source(of: clicked, localName: "")],
                       "the filter gives way to the clicked note's source")
        XCTAssertFalse(ResolveFilter.visible([clicked], selection: dense.selection, localName: "").isEmpty)
        XCTAssertEqual(dense.choices[paragraph], true, "a collapsed group opens")
        XCTAssertEqual(dense.scrollTo, paragraph)
        XCTAssertEqual(dense.marked, clicked.id, "its row is the marked one")

        let small = ResolvePane.apply(
            .showParagraph(docId: "doc-a", paragraphId: "bb22", annotationId: clickedNote.annotation.id),
            groups: built, sceneIndex: nil, chips: chips, activePassId: nil, dense: false,
            selection: [.mine], choices: [:])
        XCTAssertEqual(small.selection, [], "small: the filter gives way to everything")
        XCTAssertEqual(small.marked, clicked.id)

        // A tick (no note named) marks the paragraph's first item; a filter
        // that already shows it stands.
        let tick = ResolvePane.apply(
            .showParagraph(docId: "doc-a", paragraphId: "bb22"), groups: built, sceneIndex: nil,
            chips: chips, activePassId: nil, dense: true,
            selection: [ResolveFilter.source(of: first, localName: "")], choices: [:])
        XCTAssertEqual(tick.marked, first.id)
        XCTAssertEqual(tick.selection, [ResolveFilter.source(of: first, localName: "")])
    }

    /// **M5 — the click's delivery carries the dot's note**: the event the
    /// overlay posts names it, and the window's answer reveals the column on
    /// To resolve with the note in the request.
    func test_theClicksDeliveryCarriesTheDotsNote() throws {
        let payload: [AnyHashable: Any] = [MaughamEvent.annotationDocIdKey: "doc-a",
                                           MaughamEvent.marginParagraphIdKey: "bb22",
                                           MaughamEvent.marginAnnotationIdKey: "n-other"]
        let answer = try XCTUnwrap(MarginMirrorModifier.paragraphJump(
            payload, subject: WindowSubject(open: .item("doc-a"), faces: .item("doc-a")), structure: structure))
        XCTAssertEqual(answer.jump, ProjectWindow.StrainJump(
            showInspector: true, position: .resolve,
            request: .showParagraph(docId: "doc-a", paragraphId: "bb22", annotationId: "n-other")),
            "a hidden column is revealed on To resolve, holding the note")
    }

    /// **I2** — a click's group holds as the caret group while the caret
    /// stays in its paragraph (the groups arriving after the read are not a
    /// caret move); the caret moving lets its own group back.
    func test_aClicksGroupHoldsUntilTheCaretMoves() {
        let clicked = ResolveGroup.Key.paragraph(docId: "doc-a", paragraphId: "bb22")
        let caret = ResolveGroup.Key.paragraph(docId: "doc-a", paragraphId: "aa11")
        let pin = ResolveCaretPin(key: clicked, caretLocation: 3)
        let held = ResolveCaretPin.decide(caretLocation: 3, caretKey: caret, pin: pin)
        XCTAssertEqual(held.group, clicked)
        XCTAssertEqual(held.pin, pin)
        let moved = ResolveCaretPin.decide(caretLocation: 40, caretKey: nil, pin: pin)
        XCTAssertNil(moved.group)
        XCTAssertNil(moved.pin, "the caret moved: the pin is gone")
        let nudged = ResolveCaretPin.decide(caretLocation: 4, caretKey: caret, pin: pin)
        XCTAssertEqual(nudged.group, caret, "N2: a move within the same paragraph releases it too")
        XCTAssertEqual(ResolveCaretPin.decide(caretLocation: 3, caretKey: caret, pin: nil).group, caret)
    }

    /// **M7** — in a screenplay the clicked paragraph's group is its
    /// scene's, by the caret's own rule (production always passes the pane's
    /// `sceneIndex`).
    func test_aMarginClickInAScreenplayOpensItsScene() throws {
        let piece = ResolveScope.piece(docId: "doc-a", includesBookLevel: false)
        let sceneIndex = ["aa11": 0, "bb22": 0]
        let built = ResolveGrouping.groups(
            ResolveSnapshot(items: [note("n1", pid: "bb22")], sequences: ["doc-a": ["aa11", "bb22"]],
                            paragraphText: [:], unreadableDocIds: []),
            scope: piece, structure: structure, sceneIndex: sceneIndex, sceneTitles: ["INT. KITCHEN"],
            figureNames: [:], book: PieceNoun.Book(type: .screenplay))
        let scene = try XCTUnwrap(built.first { if case .scene = $0.key { return true } else { return false } })
        let outcome = ResolvePane.apply(
            .showParagraph(docId: "doc-a", paragraphId: "bb22"), groups: built,
            sceneIndex: sceneIndex, chips: [.others], activePassId: nil, dense: false,
            selection: [], choices: [:])
        XCTAssertEqual(outcome.scrollTo, scene.key, "the scene's group is the target")
        XCTAssertEqual(outcome.scrollTo, scene.key)
    }

    /// The click reveals the column on To resolve holding the request — the
    /// strain jump's one mechanism.
    func test_aMarginClickRevealsToResolve() {
        let request = ResolveRequest.showParagraph(docId: "doc-a", paragraphId: "bb22")
        XCTAssertEqual(ProjectWindow.strainJump(request),
                       ProjectWindow.StrainJump(showInspector: true, position: .resolve, request: request))
        let payload: [AnyHashable: Any] = [MaughamEvent.annotationDocIdKey: "doc-a",
                                           MaughamEvent.marginParagraphIdKey: "bb22"]
        let asked = MaughamEvent.paragraphInResolve(of: payload)
        XCTAssertEqual(asked?.docId, "doc-a")
        XCTAssertEqual(asked?.paragraphId, "bb22")
    }

    // MARK: - A strain mark's jump (shell plan 3 Task 6)

    /// A solid mark asks for its finding by the finding's own item id: the
    /// group holding it opens, the list scrolls there and the row is marked;
    /// a filter hiding the row gives way.
    func test_aStrainFocusOpensItsFindingsGroup() throws {
        let piece = ResolveScope.piece(docId: "doc-a", includesBookLevel: false)
        let strain = finding("s1", pid: "bb22")
        let items = (0..<14).map { note("n\($0)") } + [strain]
        let built = groups(items, piece)
        XCTAssertTrue(ResolveFilter.isDense(items), "premise: dense, so nothing is open by default")
        let holding = try XCTUnwrap(built.first { $0.items.contains(strain) })

        let outcome = ResolvePane.apply(
            .focusFinding(docId: "doc-a", itemId: strain.id), groups: built,
            sceneIndex: nil, chips: [.checks, .others], activePassId: nil, dense: true,
            selection: [.others], choices: [:])
        XCTAssertEqual(outcome.marked, strain.id, "the row is marked")
        XCTAssertFalse(outcome.settled)
        XCTAssertEqual(outcome.scrollTo, holding.key)
        XCTAssertEqual(ResolveFilter.expanded(built, cursor: nil, dense: true, choices: outcome.choices),
                       [holding.key], "its group opens, and only it")
        XCTAssertEqual(outcome.selection, [.checks], "dense: Others hid it, so its own source shows")

        let small = ResolvePane.apply(
            .focusFinding(docId: "doc-a", itemId: strain.id), groups: groups([note("n1"), strain], piece),
            sceneIndex: nil, chips: [.checks, .others], activePassId: nil, dense: false,
            selection: [.others], choices: [:])
        XCTAssertEqual(small.selection, [], "small: the filter gives way to everything")
        XCTAssertEqual(small.marked, strain.id)
    }

    /// A strain the list no longer holds — answered, replaced by a newer
    /// check, or dropped when its anchor text changed — or one that never had
    /// an item is settled: the Checks chip on that piece, and the line.
    func test_aStrainWithNoFindingFallsBackToChecks() {
        let book = ResolveScope.pieces(docIds: ["doc-a", "doc-b"], includesBookLevel: true)
        let built = groups([note("a1"), finding("other", on: "doc-b", pid: "cc33")], book)
        let gone = ResolveItem.finding(docId: "doc-b", Diagnostic(
            id: "answered", docId: "doc-b", anchor: nil, body: "x", category: nil,
            runId: "run-1", kind: .conformanceStrain)).id
        for itemId in [gone, nil] as [String?] {
            let outcome = ResolvePane.apply(
                .focusFinding(docId: "doc-b", itemId: itemId), groups: built,
                sceneIndex: nil, chips: [.checks, .others], activePassId: nil, dense: false,
                selection: [.others], choices: [:])
            if itemId == nil {
                // **Review I1.** A strain that never had an item was not
                // settled: the check still flags the sentence.
                XCTAssertFalse(outcome.settled, "a strain with no item is not settled")
                XCTAssertEqual(outcome.line,
                               "The last check flagged this sentence. There is nothing to act on here.")
            } else {
                XCTAssertTrue(outcome.settled, "answered or replaced: settled")
                XCTAssertEqual(outcome.line, ResolvePane.settledFindingLine)
            }
            XCTAssertNil(outcome.marked, "no row is marked")
            XCTAssertEqual(outcome.selection, [.checks], "the Checks filter")
            XCTAssertEqual(outcome.scrollTo, .piece(docId: "doc-b"), "on that piece's group")
            XCTAssertEqual(outcome.choices[.piece(docId: "doc-b")], true)
        }
        let noChecks = ResolvePane.apply(
            .focusFinding(docId: "doc-a", itemId: gone), groups: groups([note("a1")], book),
            sceneIndex: nil, chips: [.others], activePassId: nil, dense: false, selection: [.others], choices: [:])
        XCTAssertEqual(noChecks.selection, [.others], "no Checks chip: the writer's filter stands")
        XCTAssertTrue(noChecks.settled)
        XCTAssertFalse(ResolvePane.settledFindingLine.isEmpty)
        let found = ResolvePane.apply(
            .focusFinding(docId: "doc-b", itemId: finding("other", on: "doc-b", pid: "cc33").id),
            groups: built, sceneIndex: nil, chips: [.checks, .others], activePassId: nil, dense: false,
            selection: [.others], choices: [:])
        XCTAssertNil(found.line, "a listed finding says nothing: its row is marked")
    }

    /// **Review M4.** The mark's jump, as `ProjectWindow.showStrain` writes
    /// it: the column shown, on To resolve, holding the request.
    func test_aStrainJumpShowsToResolveWithTheRequest() throws {
        let request = ResolveRequest.focusFinding(docId: "doc-a", itemId: "finding:doc-a/d-1")
        XCTAssertEqual(ProjectWindow.strainJump(request),
                       ProjectWindow.StrainJump(showInspector: true, position: .resolve,
                                                request: request))
        let window = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/ProjectWindow.swift"), encoding: .utf8)
        let flat = window.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(flat.contains("let jump = Self.strainJump(request) showInspector = jump.showInspector "
                                    + "rightColumnPosition = jump.position resolveRequest = jump.request"),
                      "showStrain writes exactly the jump's three values")
        // And Brief's marks reach it: the window hands the column its verb,
        // the column hands it to Brief.
        XCTAssertTrue(flat.contains("showStrain: { showStrain($0) },"), "the window's hand-off is gone")
        let column = try SourceTree.sourceOfType("RightColumn", under: ["Maugham"])
        XCTAssertTrue(column.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .contains("onShowStrain: showStrain,"), "Brief's marks reach no one")
    }

    // MARK: - Bulk inside a Book or Part list (carried from plan 2)

    /// With the Book or a Part on the faces and a piece open in the centre,
    /// bulk is offered over the OPENED piece's notes, as at piece scope.
    func test_theBulkBarIsOfferedOverTheOpenPieceInsideABookList() {
        let book = ResolveScope.pieces(docIds: ["doc-a", "doc-b"], includesBookLevel: true)
        let part = ResolveScope.pieces(docIds: ["doc-b"], includesBookLevel: false)
        let registered: (String) -> Bool = { $0 == "doc-b" }
        XCTAssertEqual(ResolveVerbGate.bulkDocId(scope: book, openDocId: "doc-b", isRegistered: registered),
                       "doc-b")
        XCTAssertEqual(ResolveVerbGate.bulkDocId(scope: part, openDocId: "doc-b", isRegistered: registered),
                       "doc-b")
        XCTAssertEqual(ResolveVerbGate.bulkDocId(
            scope: .piece(docId: "doc-b", includesBookLevel: false), openDocId: "doc-b",
            isRegistered: registered), "doc-b", "and at the piece's own scope, as before")
        let visible = [note("a1"), note("b1", on: "doc-b", pid: "cc33"), note("b2", on: "doc-b", pid: "cc33"),
                       finding("s1", on: "doc-b", pid: "cc33")]
        XCTAssertEqual(ResolvePane.bulkRows(visible, pieceDocId: "doc-b", heldForFlourish: []).map(\.id),
                       ["b1", "b2"], "the opened piece's notes, and only its notes")
    }

    /// Bulk never reaches a piece that is not the open one, through any
    /// path: no bulk piece off the open one; the bar is drawn only over the
    /// open piece's `Document`; and the verb drops any id that is not that
    /// document's own note before acting.
    func test_theBulkBarNeverActsOnAPieceThatIsNotOpen() async throws {
        let book = ResolveScope.pieces(docIds: ["doc-a", "doc-b"], includesBookLevel: true)
        let all: (String) -> Bool = { _ in true }
        XCTAssertNil(ResolveVerbGate.bulkDocId(scope: book, openDocId: nil, isRegistered: all),
                     "the canvas in the centre: no piece is open")
        XCTAssertNil(ResolveVerbGate.bulkDocId(scope: book, openDocId: "doc-z", isRegistered: all),
                     "a piece open outside the list")
        XCTAssertNil(ResolveVerbGate.bulkDocId(scope: book, openDocId: "doc-a", isRegistered: { _ in false }),
                     "a piece whose document has not loaded")
        XCTAssertNil(ResolveVerbGate.bulkDocId(
            scope: .piece(docId: "doc-a", includesBookLevel: false), openDocId: "doc-b",
            isRegistered: all), "the faces' piece while another is open")
        XCTAssertEqual(ResolveNoteVerbs.ownIds(["b1", "a1", "b2"], among: ["b1", "b2"]), ["b1", "b2"])

        // The verb's own guard, over a real document.
        let (doc, _, _) = try await openDocument()
        let pid = try XCTUnwrap(doc.sequence.first)
        try await doc.addAnnotation(kind: .comment, paragraphId: pid, body: "Mine.")
        let own = try XCTUnwrap(doc.annotations().first).id
        XCTAssertEqual(ResolveNoteVerbs.ownIds([own, "on-another-piece"], of: doc), [own])

        // Every path to a bulk act goes through the bar, and the bar is
        // drawn only over the bulk piece's own `Document`.
        let pane = try Self.paneSource()
        XCTAssertTrue(pane.contains("if selectionModeOn, let bulk, let acting, acting.docId == bulk,"),
                      "the bar is drawn only over the open piece's document")
        XCTAssertEqual(pane.components(separatedBy: "AnnotationsBulkBar(").count - 1, 1,
                       "one bar, at one place")
        XCTAssertFalse(pane.contains("runBulk("), "no other path into a bulk act in the list")
        XCTAssertTrue(pane.contains("isSelectable: selectionModeOn && note.docId == bulk,"),
                      "only the open piece's rows can be ticked")
    }

    private static func paneSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Maugham/Views/Resolve/ResolvePane.swift"),
                          encoding: .utf8)
    }

    // MARK: - The caret (carried item 9)

    /// Only the open piece has a caret group: off it the caret is never even
    /// read. Inside a Book or Part list that holds the open piece (review I1)
    /// it is read, and the caret's group is that piece's.
    func test_theCaretIsReadOnlyOnTheOpenPieceWhereTheScopeHoldsIt() {
        var asked = 0
        let reader: () -> String? = { asked += 1; return "aa11" }
        let piece = ResolveScope.piece(docId: "doc-a", includesBookLevel: false)
        let book = ResolveScope.pieces(docIds: ["doc-a", "doc-b"], includesBookLevel: true)
        XCTAssertNil(ResolvePane.caretParagraph(scope: piece, openDocId: "doc-a", mayAct: false, read: reader))
        XCTAssertNil(ResolvePane.caretParagraph(scope: piece, openDocId: nil, mayAct: true, read: reader))
        XCTAssertNil(ResolvePane.caretParagraph(
            scope: .pieces(docIds: ["doc-b"], includesBookLevel: false), openDocId: "doc-a",
            mayAct: true, read: reader), "a Part that does not hold the open piece")
        XCTAssertNil(ResolvePane.caretParagraph(scope: .outside, openDocId: "doc-a", mayAct: true, read: reader))
        XCTAssertEqual(asked, 0, "the caret is read only where the scope holds the open piece")
        XCTAssertEqual(ResolvePane.caretParagraph(scope: piece, openDocId: "doc-a", mayAct: true, read: reader),
                       "aa11")
        XCTAssertEqual(ResolvePane.caretParagraph(scope: book, openDocId: "doc-a", mayAct: true, read: reader),
                       "aa11", "the Book list follows the piece opened inside it")

        // Marked and scrolled to once per group change.
        let built = groups([note("n1"), note("n2", on: "doc-b", pid: "cc33")], book)
        let caret = ResolveFilter.cursorGroup(paragraphId: "aa11", docId: "doc-a", sceneIndex: nil, groups: built)
        XCTAssertEqual(caret, .piece(docId: "doc-a"))
        XCTAssertEqual(ResolvePane.scrollTarget(from: nil, to: caret), caret, "arriving scrolls to the piece")
        let moved = ResolveFilter.cursorGroup(paragraphId: "bb22", docId: "doc-a", sceneIndex: nil, groups: built)
        XCTAssertNil(ResolvePane.scrollTarget(from: caret, to: moved), "a move inside the piece does not")
        XCTAssertEqual(ResolveFilter.expanded(built, cursor: caret, dense: true), [.piece(docId: "doc-a")],
                       "dense: the open piece's group is the one open")
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
                                            statementDoor: { _, _ in .author }, durable: true)
        XCTAssertTrue(off.answer, "Answer files a ruling: offered on any piece")
        XCTAssertFalse(off.promote, "Promote writes the piece's Document: hidden off it")
        let on = ResolvePane.findingOffers(finding("f"), mayAct: true, posture: author,
                                           statementDoor: { _, _ in .author }, durable: true)
        XCTAssertTrue(on.answer)
        XCTAssertTrue(on.promote)
        let running = ResolvePane.findingOffers(finding("f"), mayAct: true, posture: author,
                                                statementDoor: { _, _ in .author }, durable: false)
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
                       + "notes, checks, to-dos and questions. Choose one in the binder.")
        XCTAssertEqual(ResolvePane.emptyState(scope: .elsewhere(docId: "doc-x"), hasItems: false,
                                              hasVisible: false, offersColdStart: false), .elsewhere)
        XCTAssertEqual(ResolvePane.EmptyState.elsewhere.sentence,
                       "It belongs to another project. Open that project to see what it raises.")
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
