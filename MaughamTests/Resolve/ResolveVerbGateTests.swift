import XCTest
import MaughamCore
@testable import Maugham

/// **Read anywhere, act only on the open piece** (Denver, 2026-11-18; shell
/// plan 2 Task 4).
///
/// A verb that is a `Document` method is offered only on the piece open in
/// the window's centre; every other piece's rows read, offer none of those
/// verbs (hidden, never disabled) and open the piece on a click. Answer (a
/// finding's) and Keep as lesson (a note's) need no `Document` and stay
/// offered everywhere, subject to posture. Pure decisions (tripwire 33), plus
/// two calls into the moved verbs over real stores: Keep as lesson files with
/// no document loaded, and a to-do on a piece that is not open is never
/// written.
@MainActor
final class ResolveVerbGateTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Postures (tests may build one; the surfaces may not)

    private func posture(_ permit: Permit, in cls: DocumentClass) -> Posture {
        Posture(LocalWritePermit(permit: permit, actor: .author, documentClass: cls))
    }

    private var bookAuthor: Posture { Posture(.unrestricted) }
    private var reviewer: Posture { posture(.reviewer, in: .piece("doc-a")) }
    private var reviewerOnTheLedger: Posture { posture(.reviewer, in: .projectStatement) }

    private let registered: (String) -> Bool = { _ in true }
    private let openOnA = WindowSubject(open: .item("doc-a"), faces: .item("doc-a"))

    private let nothing = AnnotationRowVerbs(
        acceptOrReject: false, dispose: false, answerAsRuling: false,
        makeChoice: false, keepAsLesson: false, ownNote: false)

    // MARK: - May this window act on a piece?

    func test_aNoteOnAnotherPieceOffersOnlyKeepAsLesson() {
        let faced = WindowSubject(open: .item("doc-a"), faces: .item("doc-b"))
        let mayAct = ResolveVerbGate.mayAct(onDocId: "doc-b", subject: faced, isRegistered: registered)
        XCTAssertFalse(mayAct, "doc-b is not the open piece, registered or not")

        let decided = AnnotationRowVerbs.unrestricted(isOwn: true)
        let offered = ResolveVerbGate.noteVerbs(decided, mayAct: mayAct)
        XCTAssertEqual(offered, AnnotationRowVerbs(
            acceptOrReject: false, dispose: false, answerAsRuling: false,
            makeChoice: false, keepAsLesson: true, ownNote: false),
            "accept, reject, stet, triage, archive, reopen, the ruling, the choice, "
            + "and Edit/Delete of her own note are Document methods: none is offered")
    }

    func test_aNoteOnTheOpenPieceOffersWhatThePostureDecides() {
        XCTAssertTrue(ResolveVerbGate.mayAct(onDocId: "doc-a", subject: openOnA, isRegistered: registered))
        XCTAssertFalse(ResolveVerbGate.mayAct(onDocId: "doc-a", subject: openOnA, isRegistered: { _ in false }),
                       "the open piece whose document is not registered yet acts on nothing")
        for decided in [AnnotationRowVerbs.unrestricted(isOwn: true),
                        .unrestricted(isOwn: false), nothing] {
            XCTAssertEqual(ResolveVerbGate.noteVerbs(decided, mayAct: true), decided,
                           "the gate only removes; on the open piece the posture's answer stands")
        }
    }

    /// Review Focus 2: a narrowed or shared book's reviewer, on the open piece.
    func test_aNarrowedPostureHidesDispositionsEvenOnTheOpenPiece() {
        let mayAct = ResolveVerbGate.mayAct(onDocId: "doc-a", subject: openOnA, isRegistered: registered)
        XCTAssertTrue(mayAct, "premise: the piece is open and registered")
        let decided = AnnotationRowVerbs.decide(
            posture: reviewer, isOwn: true,
            rulingStatement: reviewerOnTheLedger, lessons: reviewerOnTheLedger)
        let offered = ResolveVerbGate.noteVerbs(decided, mayAct: mayAct)
        XCTAssertFalse(offered.acceptOrReject)
        XCTAssertFalse(offered.dispose)
        XCTAssertFalse(offered.answerAsRuling)
        XCTAssertFalse(offered.makeChoice)
        XCTAssertFalse(offered.keepAsLesson)
        XCTAssertTrue(offered.ownNote, "her own note's Edit and Delete are the reviewer row")
    }

    func test_keepAsLessonFollowsTheLedgersPosture() {
        let refused = AnnotationRowVerbs.decide(
            posture: bookAuthor, isOwn: false, rulingStatement: nil, lessons: reviewerOnTheLedger)
        XCTAssertFalse(ResolveVerbGate.noteVerbs(refused, mayAct: false).keepAsLesson,
                       "off the open piece the ledger's posture still decides")
        XCTAssertFalse(ResolveVerbGate.noteVerbs(refused, mayAct: true).keepAsLesson)

        let allowed = AnnotationRowVerbs.decide(
            posture: reviewer, isOwn: false, rulingStatement: nil, lessons: bookAuthor)
        XCTAssertTrue(ResolveVerbGate.noteVerbs(allowed, mayAct: false).keepAsLesson,
                      "a ledger this Mac may write is offered on any piece — it needs no Document")
    }

    func test_aFindingOnAnotherPieceOffersAnswerButNoTask() {
        let off = ResolveVerbGate.findingVerbs(answer: true, promote: true, mayAct: false)
        XCTAssertTrue(off.answer, "Answer files a ruling and needs no Document")
        XCTAssertFalse(off.promote, "Promote to Task is a Document method")
        let on = ResolveVerbGate.findingVerbs(answer: true, promote: true, mayAct: true)
        XCTAssertTrue(on.answer)
        XCTAssertTrue(on.promote)
        let refused = ResolveVerbGate.findingVerbs(answer: false, promote: false, mayAct: true)
        XCTAssertFalse(refused.answer, "the gate never adds what the posture refused")
        XCTAssertFalse(refused.promote)
    }

    func test_aTodoOnAnotherPieceOffersNothing() {
        XCTAssertEqual(ResolveVerbGate.taskVerbs(.unrestricted, mayAct: false, isBookLevel: false), .none)
        XCTAssertEqual(ResolveVerbGate.taskVerbs(.unrestricted, mayAct: true, isBookLevel: false),
                       .unrestricted)
        let narrowed = TaskRowVerbs.decide(kind: .inlineMarkdown, posture: reviewer)
        XCTAssertEqual(ResolveVerbGate.taskVerbs(narrowed, mayAct: true, isBookLevel: false), narrowed,
                       "on the open piece the posture's answer stands")
    }

    /// The project stream needs no `Document`: a Book-level to-do keeps
    /// exactly today's verbs wherever the window's centre is.
    func test_aBookLevelTodoKeepsTodaysVerbs() {
        let streamOnly = TaskRowVerbs(toggle: false, archive: false, delete: true, move: true)
        for decided in [TaskRowVerbs.unrestricted, .none, streamOnly] {
            XCTAssertEqual(ResolveVerbGate.taskVerbs(decided, mayAct: false, isBookLevel: true), decided)
            XCTAssertEqual(ResolveVerbGate.taskVerbs(decided, mayAct: true, isBookLevel: true), decided)
        }
    }

    /// Review Focus 5: the canvas centred, the faces on a piece.
    func test_withTheCanvasCentredTheFacesPieceIsReadableAndUnactionable() {
        let canvas = WindowSubject(open: .canvas, faces: .item("doc-p"))
        XCTAssertFalse(ResolveVerbGate.mayAct(onDocId: "doc-p", subject: canvas, isRegistered: registered),
                       "the faces' piece is not open in the centre")
        let offered = ResolveVerbGate.noteVerbs(.unrestricted(isOwn: true), mayAct: false)
        XCTAssertEqual(offered, AnnotationRowVerbs(
            acceptOrReject: false, dispose: false, answerAsRuling: false,
            makeChoice: false, keepAsLesson: true, ownNote: false))
        XCTAssertEqual(ResolveVerbGate.findingVerbs(answer: true, promote: true, mayAct: false).promote, false)
        for open in [BinderSubject.project, .palette, .inbox, .edition(language: "es"), .figure("fig-aaaa1111")] {
            XCTAssertFalse(ResolveVerbGate.mayAct(
                onDocId: "doc-p", subject: WindowSubject(open: open, faces: .item("doc-p")),
                isRegistered: registered), "\(open) in the centre acts on no piece")
        }
    }

    /// A to-do dropped onto a row on another piece is refused: the reorder
    /// would set a priority or a parent read off a task its document does
    /// not hold.
    func test_aDropAcrossTwoPiecesIsRefused() {
        func task(_ id: String, on docId: String?) -> WriterTask {
            WriterTask(id: id, kind: .paneCreated,
                       anchor: docId.map { TaskAnchor(docId: $0, paragraphId: nil) },
                       body: id, status: .open, priority: 0, parentTaskId: nil,
                       createdAt: Date(timeIntervalSince1970: 0), createdBySession: nil)
        }
        XCTAssertFalse(ResolveTaskVerbs.acceptsDrop(of: task("a", on: "doc-a"), onto: task("b", on: "doc-b")))
        XCTAssertTrue(ResolveTaskVerbs.acceptsDrop(of: task("a", on: "doc-a"), onto: task("c", on: "doc-a")),
                      "control: one piece's to-dos reorder among themselves")
        XCTAssertFalse(ResolveTaskVerbs.acceptsDrop(
            of: task("a", on: "doc-a"), onto: task("p", on: ProjectStore.projectTasksDocId)))
        XCTAssertTrue(ResolveTaskVerbs.acceptsDrop(of: task("p", on: nil),
                                                   onto: task("q", on: ProjectStore.projectTasksDocId)),
                      "an unanchored to-do is the Book's, like one anchored there")
    }

    // MARK: - Through the moved verbs, over real stores

    /// Keep as lesson needs no `Document`: a closed piece's accepted craft
    /// note files its lesson with nothing loaded and nothing registered.
    func test_keepAsLessonFilesForAClosedPieceWithNoDocument() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "Gate", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        let documentStore = try await DocumentStore.open(url: url)
        let note = Annotation(
            id: "craft-1", kind: .craftNote, paragraphId: "aa11", body: "Vary the opening.",
            suggestedText: nil, priorText: nil, createdAt: Date(timeIntervalSince1970: 0),
            createdBySession: nil, status: .accepted, userResponse: nil,
            resolvedAt: nil, isStale: false)

        await noteVerbs(store, documentStore).keepAsLesson(note, docId: "ch-1", heading: "Vary the opening.").value

        XCTAssertEqual(LessonsLedger.open(in: LessonLedgerVerbs.ledgerText(store: store) ?? ""),
                       ["Vary the opening."], "the lesson is in the ledger")
        XCTAssertTrue(documentStore.allOpenDocuments().isEmpty, "and no document was loaded to file it")
    }

    /// **No to-do verb writes a piece that is not open** (the ruling's third
    /// point): the piece's document is live and registered, its to-do is
    /// toggled, archived and deleted, and nothing lands — until the window's
    /// centre is that piece, where the same archive lands.
    func test_noTaskVerbActsOnAPieceThatIsNotOpen() async throws {
        let (doc, store, documentStore) = try await openDocument()
        let inlinePid = try XCTUnwrap(doc.sequence.first)
        doc.setParagraph(id: inlinePid, text: "- [ ] fix the dock")
        try await doc.flushBurstNow()
        let pane = doc.createPaneTask(body: "pane thing", parentTaskId: nil)
        doc.setTaskStatus(id: pane.id, status: .done)
        let all = { doc.tasks(filter: TaskFilter(scope: .document(docId: doc.docId),
                                                 statuses: Set(TaskStatus.allCases))) }
        let inline = try XCTUnwrap(all().first { $0.kind == .inlineMarkdown })
        let before = doc.opLogMirrorCount
        let text = doc.paragraph(id: inlinePid)

        let elsewhere = ResolveTaskVerbs(store: store, documentStore: documentStore,
                                         openDocId: "doc-elsewhere", undoManager: nil)
        XCTAssertEqual(elsewhere.offered(inline), .none, "premise: nothing is offered off the open piece")
        elsewhere.toggle(inline)
        elsewhere.archive(inline)
        elsewhere.archive(pane)
        elsewhere.delete(pane)
        elsewhere.apply(intent: .nestUnder(parentId: inline.id), dragged: pane, in: doc, allTasks: all())
        elsewhere.archiveAllDone(in: .document)
        elsewhere.archiveAllDone(in: .project)
        XCTAssertEqual(doc.opLogMirrorCount, before, "no op was appended for a piece that is not open")
        XCTAssertEqual(doc.paragraph(id: inlinePid), text, "and the paragraph's checkbox did not move")

        let open = ResolveTaskVerbs(store: store, documentStore: documentStore,
                                    openDocId: doc.docId, undoManager: nil)
        XCTAssertEqual(open.offered(pane), TaskRowVerbs.decide(
            kind: .paneCreated, posture: documentStore.posture(forDocId: doc.docId)))
        open.archive(pane)
        XCTAssertEqual(all().first { $0.id == pane.id }?.status, .archived,
                       "control: on the open piece the same verb lands")
    }

    // MARK: - Fixtures

    private func noteVerbs(_ store: ProjectStore, _ documentStore: DocumentStore) -> ResolveNoteVerbs {
        ResolveNoteVerbs(
            store: store, documentStore: documentStore, world: nil,
            userPreferences: UserPreferences(defaults: UserDefaults(suiteName: "gate-\(UUID().uuidString)")!),
            undoManager: nil, onChoiceOfferChanged: { _ in },
            projectSnapshot: { store.listAnnotationsAcrossProject() },
            visibleAnnotations: { _ in [] }, effectiveSelection: { _ in [] },
            staleConfirm: .constant(nil), anchorLostNotice: .constant(nil),
            revertConfirm: .constant(nil), rulingNotice: .constant(nil),
            ledgerNotice: .constant(nil), choiceOffer: .constant(nil),
            stetFlourishIds: .constant([]), bulkInFlight: .constant(false),
            selectedIds: .constant([]), bulkNotice: .constant(nil),
            letterLedgerRevision: .constant(0), projectRefreshToken: .constant(0))
    }

    /// A one-piece project with its document loaded and registered, as the
    /// editor registers it.
    private func openDocument() async throws
        -> (Document, ProjectStore, DocumentStore) {
        let url = temp.url.appendingPathComponent("GATE-\(UUID().uuidString)")
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
