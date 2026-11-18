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

    /// Every input that changes what the list shows moves the read key: the
    /// event token (`.maughamAnnotationsChanged`), a note added to the open
    /// piece, a to-do typed into it, a Book-level to-do and a check's sidecar.
    func test_theRefreshKeyMovesOnEveryInputThatChangesTheList() async throws {
        let (doc, store, documentStore) = try await openDocument()
        let diagnostics = DiagnosticsStore(projectRoot: store.url, device: DeviceSlug.make(from: "test-mac"))
        let scope = ResolveScope.piece(docId: doc.docId, includesBookLevel: false)
        func key(_ token: Int) -> ResolveReadKey {
            ResolvePane.readKey(scope: scope, annotationsToken: token, store: store,
                                documentStore: documentStore, diagnostics: diagnostics,
                                localName: "Me")
        }
        let start = key(0)
        XCTAssertEqual(key(0), start, "premise: nothing moved, nothing moves")

        XCTAssertNotEqual(key(1), start, "the annotations event's token")

        let pid = try XCTUnwrap(doc.sequence.first)
        try await doc.addAnnotation(kind: .comment, paragraphId: pid, body: "a note")
        let afterNote = key(0)
        XCTAssertNotEqual(afterNote, start, "a note on the open piece")

        doc.setFullText("Hello.\n\n- [ ] typed to-do")
        let afterTodo = key(0)
        XCTAssertNotEqual(afterTodo, afterNote, "a to-do typed into the open piece")

        _ = store.createProjectPaneTask(body: "book thing", undoManager: nil)
        let afterBook = key(0)
        XCTAssertNotEqual(afterBook, afterTodo, "a Book-level to-do")

        diagnostics.replace(
            run: CompilerRun(id: "run-1", at: t, model: "test-model", lastOpId: "01BBB1",
                             deltaSummary: "1 new", intentSnapshot: nil, passId: nil, round: nil,
                             freshEyes: nil, kind: .check),
            diagnostics: [Diagnostic(id: "d1", docId: doc.docId, anchor: nil, body: "strain",
                                     category: nil, runId: "run-1", kind: .conformanceStrain)],
            docId: doc.docId)
        XCTAssertNotEqual(key(0), afterBook, "a check's sidecar")

        XCTAssertNotEqual(
            ResolvePane.readKey(scope: .outside, annotationsToken: 0, store: store,
                                documentStore: documentStore, diagnostics: diagnostics, localName: "Me"),
            key(0), "the faces' scope")
    }

    /// **Carried item 3.** The old Tasks pane refreshed on the open document's
    /// `tasksVersion`; typing `- [ ]` bumps it at once (`Document.setFullText`'s
    /// inline-task fast path, `changeTouchesTaskMarkup`). The read key sums
    /// every open document's `tasksVersion`, so the typed to-do moves the key
    /// and the one read the key triggers lists it.
    func test_aTypedTodoReachesTheList() async throws {
        let (doc, store, documentStore) = try await openDocument()
        let scope = ResolveScope.piece(docId: doc.docId, includesBookLevel: false)
        func key() -> ResolveReadKey {
            ResolvePane.readKey(scope: scope, annotationsToken: 0, store: store,
                                documentStore: documentStore, diagnostics: nil, localName: "Me")
        }
        func todos() -> [String] {
            ResolveReader.read(scope: scope, store: store, documentStore: documentStore, diagnostics: nil)
                .items.compactMap { if case .todo(let task) = $0 { return task.body } else { return nil } }
        }
        XCTAssertEqual(todos(), [], "premise: no to-do yet")
        let before = key()

        // The editor's binding setter is `doc.setFullText` (EditorHost).
        doc.setFullText("Hello.\n\n- [ ] fix the dock")

        XCTAssertNotEqual(key(), before, "the typed to-do moves the read key with no burst flush")
        XCTAssertEqual(todos(), ["fix the dock"], "and the read it triggers lists it")
    }

    /// **Carried item 2.** When both keys move, the walks run (the read
    /// already reads the piece's text); a script-only change re-reads the
    /// text and regroups, without the walks; nothing moved, nothing runs.
    func test_aReadRunsBeforeARegroupAndAScriptAloneOnlyRereads() {
        let read = ResolveReadKey(scope: .piece(docId: "doc-a", includesBookLevel: false),
                                  annotationsToken: 0, openVersions: [], projectTasksVersion: 0,
                                  diagnosticsVersion: 0, passes: [], localName: "Me")
        let moved = ResolveReadKey(scope: .piece(docId: "doc-a", includesBookLevel: false),
                                   annotationsToken: 1, openVersions: [], projectTasksVersion: 0,
                                   diagnosticsVersion: 0, passes: [], localName: "Me")
        let key = ResolveRegroupKey(read: read, script: nil)
        XCTAssertEqual(ResolvePane.refreshStep(key, lastRead: nil), .read, "the first build reads")
        XCTAssertEqual(ResolvePane.refreshStep(key, lastRead: read), .reread,
                       "the read key held, so only the script moved: re-read the text, regroup")
        XCTAssertEqual(ResolvePane.refreshStep(ResolveRegroupKey(read: moved, script: nil), lastRead: read),
                       .read, "both moved: the read, whose text the regroup then uses")
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

        XCTAssertFalse(ResolveSettled.offersArchiveAllDone(mayAct: false, posture: author, doneCount: 3),
                       "Archive all done is hidden off the open piece")
        XCTAssertFalse(ResolveSettled.offersArchiveAllDone(mayAct: true, posture: author, doneCount: 0),
                       "and with nothing done")
        XCTAssertTrue(ResolveSettled.offersArchiveAllDone(mayAct: true, posture: author, doneCount: 3))
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
        XCTAssertEqual(ResolvePane.emptyState(scope: .outside, hasItems: false, offersColdStart: false),
                       .outside)
        XCTAssertEqual(ResolvePane.EmptyState.outside.sentence,
                       "To resolve gathers what has been raised about a piece, a Part or the Book: "
                       + "notes, checks, to-dos and questions. Choose one in the tree.")
        XCTAssertEqual(ResolvePane.emptyState(scope: .elsewhere(docId: "doc-x"), hasItems: false,
                                              offersColdStart: false), .elsewhere)
        XCTAssertEqual(ResolvePane.EmptyState.elsewhere.sentence,
                       "This piece belongs to another project. Open that project to see what it raises.")
        let piece = ResolveScope.piece(docId: "doc-a", includesBookLevel: false)
        XCTAssertEqual(ResolvePane.emptyState(scope: piece, hasItems: false, offersColdStart: true), .coldStart)
        XCTAssertEqual(ResolvePane.emptyState(scope: piece, hasItems: false, offersColdStart: false), .nothing)
        XCTAssertEqual(ResolvePane.EmptyState.nothing.sentence, "Nothing to resolve.")
        XCTAssertNil(ResolvePane.emptyState(scope: piece, hasItems: true, offersColdStart: true),
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
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-test", title: "C1", type: .document, path: docPath)],
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
