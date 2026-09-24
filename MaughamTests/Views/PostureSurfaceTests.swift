import XCTest
import SwiftUI
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **Dispositions are offered where the permit allows them, and refused at the
/// Document's own door** (signed op log P3c Task 5).
///
/// Three surfaces draw a disposition — a queue row, the bulk bar and the
/// margin card — and each asks the POSTURE of the document the verb would act
/// on. Behind them, every `Document` disposition mutator asks its own stamp
/// (`requireDispositionPermitted`) and throws `PostureRefusal` before it
/// writes anything, so a verb drawn a frame before a demotion landed, or a ⌘Z
/// registered while this Mac could still write, appends nothing.
///
/// Both directions: a reviewer sees no disposition and keeps Edit/Delete on
/// her own note; an author of piece A sees A's verbs and none of B's in one
/// queue; a promotion brings them back with no reopen.
@MainActor
final class PostureSurfaceTests: XCTestCase {

    private var roots: [URL] = []
    private var windows: [NSWindow] = []

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    // MARK: - Postures (tests may build one; the surfaces may not)

    private func posture(_ permit: Permit, in cls: DocumentClass) -> Posture {
        Posture(LocalWritePermit(permit: permit, actor: .author, documentClass: cls))
    }

    private var reviewer: Posture { posture(.reviewer, in: .piece("doc-a")) }
    private var bookAuthor: Posture { Posture(.unrestricted) }
    private var piecesAuthorInA: Posture {
        posture(.author(.pieces(["doc-a"])), in: .piece("doc-a"))
    }
    private var piecesAuthorInB: Posture {
        posture(.author(.pieces(["doc-a"])), in: .piece("doc-b"))
    }
    private var piecesAuthorOnTheLedger: Posture {
        posture(.author(.pieces(["doc-a"])), in: .projectStatement)
    }

    // MARK: - The row decision, pure

    func test_aReviewersRowOffersNoDispositionAndKeepsHerOwnNotesEditAndDelete() {
        let verbs = AnnotationRowVerbs.decide(
            posture: reviewer, isOwn: true,
            rulingStatement: posture(.reviewer, in: .projectStatement),
            lessons: posture(.reviewer, in: .projectStatement))
        XCTAssertFalse(verbs.acceptOrReject, "no Accept, Got it, Reply, Reject or Revert")
        XCTAssertFalse(verbs.dispose, "no Stet, Archive, triage, Reopen or Restore")
        XCTAssertFalse(verbs.answerAsRuling)
        XCTAssertFalse(verbs.makeChoice)
        XCTAssertFalse(verbs.keepAsLesson)
        XCTAssertTrue(verbs.ownNote, "Edit and Delete of HER note are the reviewer row")

        let notHers = AnnotationRowVerbs.decide(
            posture: reviewer, isOwn: false,
            rulingStatement: nil, lessons: posture(.reviewer, in: .projectStatement))
        XCTAssertFalse(notHers.ownNote, "…and only of her own")
    }

    func test_aBookAuthorsRowOffersEveryVerb() {
        let verbs = AnnotationRowVerbs.decide(
            posture: bookAuthor, isOwn: false,
            rulingStatement: bookAuthor, lessons: bookAuthor)
        XCTAssertEqual(verbs, AnnotationRowVerbs.unrestricted(isOwn: false),
                       "behaviour-neutral: the whole book offers what P1 offered")
    }

    /// Her own piece's notes are hers to answer; the project's statements are
    /// the book author's, so every verb that also writes one stays hidden.
    func test_aPiecesAuthorAnswersNotesInHerPieceAndNoneOutsideIt() {
        let inA = AnnotationRowVerbs.decide(
            posture: piecesAuthorInA, isOwn: false,
            rulingStatement: piecesAuthorOnTheLedger, lessons: piecesAuthorOnTheLedger)
        XCTAssertTrue(inA.acceptOrReject)
        XCTAssertTrue(inA.dispose)
        XCTAssertFalse(inA.answerAsRuling, "the ruling half is a project statement")
        XCTAssertFalse(inA.makeChoice, "the ledger half is a project statement")
        XCTAssertFalse(inA.keepAsLesson)

        let inB = AnnotationRowVerbs.decide(
            posture: piecesAuthorInB, isOwn: false,
            rulingStatement: piecesAuthorOnTheLedger, lessons: piecesAuthorOnTheLedger)
        XCTAssertFalse(inB.acceptOrReject)
        XCTAssertFalse(inB.dispose)
    }

    /// Nothing decided yet offers the reviewer row alone — a disposition
    /// appearing a frame late is fine, one appearing that must not is not.
    func test_aSettlingPostureOffersNoDisposition() {
        let verbs = AnnotationRowVerbs.decide(
            posture: .settling, isOwn: true, rulingStatement: .settling, lessons: .settling)
        XCTAssertFalse(verbs.acceptOrReject)
        XCTAssertFalse(verbs.dispose)
        XCTAssertTrue(verbs.ownNote)
    }

    // MARK: - The bulk bar's plan

    private func note(_ kind: AnnotationKind, id: String) -> Annotation {
        Annotation(
            id: id, kind: kind, paragraphId: "p0a1", body: "b",
            suggestedText: kind == .suggestedChange ? "x" : nil, priorText: nil,
            createdAt: Date(), createdBySession: nil,
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false)
    }

    func test_theBulkPlanDropsWhatThePostureForbids() {
        let notes = [note(.comment, id: "n1"), note(.suggestedChange, id: "n2")]
        let verbs: [AnnotationBulkActions.BulkVerb] = [.accept, .stet, .triage(.do), .triage(nil)]

        for verb in verbs {
            XCTAssertFalse(AnnotationBulkActions.offers(verb, under: reviewer),
                           "\(verb) is not drawn for a reviewer")
            XCTAssertEqual(AnnotationBulkActions.plan(notes, verb: verb, posture: reviewer), [],
                           "\(verb): the posture empties the plan")
            XCTAssertFalse(AnnotationBulkActions.offers(verb, under: piecesAuthorInB))
            XCTAssertTrue(AnnotationBulkActions.offers(verb, under: piecesAuthorInA))
            XCTAssertEqual(
                AnnotationBulkActions.plan(notes, verb: verb, posture: piecesAuthorInA),
                AnnotationBulkActions.plan(notes, verb: verb),
                "\(verb): in her own piece the posture drops nothing")
        }
    }

    // MARK: - The door

    private struct Harness {
        let doc: Document
        let pid: String
    }

    private func makeHarness(prefix: String) async throws -> Harness {
        let (dir, docURL) = try makeTestProject(
            prefix: prefix, initialMd: "A paragraph with a word.\n")
        roots.append(dir)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        return Harness(doc: doc, pid: try XCTUnwrap(doc.sequence.first))
    }

    private func annotation(_ doc: Document, _ id: String) -> Annotation? {
        doc.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    private func beAReviewer(_ doc: Document) {
        doc.stamp(localWritePermit: LocalWritePermit(
            permit: .reviewer, actor: .author, documentClass: .piece(doc.docId)))
    }

    private func assertRefused(
        _ doc: Document, _ label: String,
        _ act: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let before = doc._opLogMirror.count
        let text = doc.displayText
        do {
            try await act()
            XCTFail("\(label) was not refused", file: file, line: line)
        } catch is Document.PostureRefusal {
        } catch {
            XCTFail("\(label) threw \(error), not PostureRefusal", file: file, line: line)
        }
        XCTAssertEqual(doc._opLogMirror.count, before,
                       "\(label) appended nothing", file: file, line: line)
        XCTAssertEqual(doc.displayText, text,
                       "\(label) moved no words", file: file, line: line)
    }

    func test_aReviewersDispositionsAreRefusedAtTheDocumentsDoor() async throws {
        let h = try await makeHarness(prefix: "PostureDoor")
        let comment = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "a note")
        let suggestion = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, body: "tighter",
            suggestedText: "A paragraph.")
        let archived = try await h.doc.addAnnotation(
            kind: .query, paragraphId: h.pid, body: "why?")
        try await h.doc.archiveAnnotation(id: archived)
        let accepted = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, body: "swap",
            suggestedText: "A paragraph with one word.")
        try await h.doc.acceptAnnotation(id: accepted)

        beAReviewer(h.doc)

        await assertRefused(h.doc, "accept a comment") {
            try await h.doc.acceptAnnotation(id: comment)
        }
        await assertRefused(h.doc, "accept a suggestion") {
            try await h.doc.acceptAnnotation(id: suggestion)
        }
        await assertRefused(h.doc, "reply") {
            try await h.doc.acceptAnnotation(id: comment, userResponse: "yes")
        }
        await assertRefused(h.doc, "reject") {
            try await h.doc.rejectAnnotation(id: suggestion)
        }
        await assertRefused(h.doc, "stet") {
            try await h.doc.stetAnnotation(id: comment)
        }
        await assertRefused(h.doc, "archive") {
            try await h.doc.archiveAnnotation(id: comment)
        }
        await assertRefused(h.doc, "triage") {
            try await h.doc.triageAnnotation(id: comment, mark: .do)
        }
        await assertRefused(h.doc, "reopen") {
            try await h.doc.reopenAnnotation(id: archived, undoManager: nil)
        }
        await assertRefused(h.doc, "revert") {
            try await h.doc.revertAcceptedAnnotation(id: accepted)
        }

        XCTAssertEqual(annotation(h.doc, comment)?.status, .open)
        XCTAssertNil(annotation(h.doc, comment)?.triage)
        XCTAssertEqual(annotation(h.doc, suggestion)?.status, .open)
        XCTAssertEqual(annotation(h.doc, archived)?.status, .archived)
        XCTAssertEqual(annotation(h.doc, accepted)?.status, .accepted)
    }

    /// The reviewer row stays: she may still leave a note, and edit and
    /// delete her own.
    func test_aReviewerStillAnnotatesAndEditsAndDeletesHerOwnNote() async throws {
        let h = try await makeHarness(prefix: "PostureDoor-Own")
        beAReviewer(h.doc)

        let mine = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil, body: "mine",
            authorName: "Sam")
        try await h.doc.editReviewerAnnotation(
            id: mine, newBody: "mine, better", newSuggestedText: nil, authorName: "Sam")
        XCTAssertEqual(annotation(h.doc, mine)?.body, "mine, better")
        try await h.doc.withdrawReviewerAnnotation(id: mine, authorName: "Sam")
        XCTAssertNil(annotation(h.doc, mine), "withdrawn")
    }

    /// The other direction: the stamp a promotion re-writes opens the door
    /// again, on the same document, with no reopen.
    func test_aPromotionReopensTheDoor() async throws {
        let h = try await makeHarness(prefix: "PostureDoor-Promote")
        let comment = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "a note")
        beAReviewer(h.doc)
        await assertRefused(h.doc, "accept while a reviewer") {
            try await h.doc.acceptAnnotation(id: comment)
        }

        h.doc.stamp(localWritePermit: .unrestricted)
        try await h.doc.acceptAnnotation(id: comment)
        XCTAssertEqual(annotation(h.doc, comment)?.status, .accepted)
    }

    // MARK: - ⌘Z after a demotion

    private func notices(during body: () async throws -> Void) async rethrows -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let m = note.userInfo?[MaughamEvent.noticeMessageKey] as? String {
                seen.append(m)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    /// An accept made while she could, undone after she can't: the
    /// compensating reopen is refused at the door, and the refusal is SAID —
    /// the Edit menu named the act and the writer pressed it.
    func test_anUndoAfterADemotionIsRefusedAndSaysSo() async throws {
        let h = try await makeHarness(prefix: "PostureDoor-Undo")
        let comment = try await h.doc.addAnnotation(
            kind: .comment, paragraphId: h.pid, body: "a note")
        let um = UndoManager()
        try await h.doc.acceptAnnotation(id: comment, undoManager: um)
        beAReviewer(h.doc)
        let before = h.doc._opLogMirror.count

        let said = await notices {
            um.undo()
            await h.doc.awaitPendingUndoWork()
        }

        XCTAssertEqual(said, [
            "Couldn't change that note — this Mac can no longer answer notes in this piece."])
        XCTAssertEqual(h.doc._opLogMirror.count, before, "the undo appended nothing")
        XCTAssertEqual(annotation(h.doc, comment)?.status, .accepted)

        // NSUndoManager moved the action to the redo stack as the undo fired —
        // the platform's own bookkeeping, as for every drift decline. The redo
        // it now offers is refused and said the same way, never a silent
        // re-accept of a note that was never reopened.
        XCTAssertTrue(um.canRedo)
        let saidOnRedo = await notices {
            um.redo()
            await h.doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(saidOnRedo, [
            "Couldn't change that note — this Mac can no longer answer notes in this piece."])
        XCTAssertEqual(h.doc._opLogMirror.count, before, "the redo appended nothing")
    }

    /// The suggestion arm, which moves words: its undo is a text-restoring
    /// revert, refused the same way, and the accepted text stays.
    func test_aSuggestionAcceptUndoneAfterADemotionLeavesTheWords() async throws {
        let h = try await makeHarness(prefix: "PostureDoor-UndoSuggestion")
        let suggestion = try await h.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, body: "tighter",
            suggestedText: "A paragraph.")
        let um = UndoManager()
        try await h.doc.acceptAnnotation(id: suggestion, undoManager: um)
        let accepted = h.doc.displayText
        beAReviewer(h.doc)
        let before = h.doc._opLogMirror.count

        let said = await notices {
            um.undo()
            await h.doc.awaitPendingUndoWork()
        }

        XCTAssertEqual(said, [
            "Couldn't change that note — this Mac can no longer answer notes in this piece."])
        XCTAssertEqual(h.doc._opLogMirror.count, before)
        XCTAssertEqual(h.doc.displayText, accepted, "the accepted words stay")
        XCTAssertEqual(annotation(h.doc, suggestion)?.status, .accepted)
    }

    // MARK: - One queue, two documents, each by its own posture

    private func beASigningMac(_ projectURL: URL) -> LocalIdentities {
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
        return identities
    }

    /// Another Mac roots the book and admits this one as an author of the
    /// whole book (`DocumentStorePostureTests.makeForeignRoot`'s shape).
    private func makeForeignRoot(
        _ projectURL: URL, identities: LocalIdentities
    ) throws -> DeviceIdentity {
        let root = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: root.fingerprint, name: "The other Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: root.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1_000)),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: root.fingerprint, label: "Sam", ownName: "The other Mac",
                role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: identities.author.fingerprint, name: "This Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, identities[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 2_000)),
            signedBy: identities.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver",
                ownName: "This Mac", role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 2_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        return root
    }

    /// P3b's `changePermit`, signed by the test root and delivered to this
    /// window through the presenter's registry route.
    private func rootChangesMyPermit(
        to permit: Permit, root: DeviceIdentity, identities: LocalIdentities,
        projectURL: URL, store: DocumentStore
    ) async throws {
        let mark = try OpLogStore.appliedPositions(
            ofDeviceIds: Set(identities.all.map(\.deviceId)),
            in: projectURL,
            trust: try TrustResolution.resolve(
                projectURL: projectURL, identities: identities))
        let rootCache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("root-cache.json"),
            identity: root.fingerprint)
        _ = try RegistryAdmission.changePermit(
            person: identities.author.fingerprint,
            role: permit.wireRole, scope: permit.wireScope, pieces: permit.wirePieces,
            mark: mark,
            unsigned: permit.narrows ? .nothingApplied : nil,
            in: projectURL, by: root, cache: rootCache)
        store.presenterDidChangeSubitem(at: RegistryWriter.url(
            .people, fingerprint: identities.author.fingerprint, in: projectURL))
        await store.flushRegistryChangeForTesting()
        await store.postureSettled()
    }

    /// A book of two chapters, `doc-a` and `doc-b`, each with one open note.
    private func makeTwoPieceProject() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostureSurface-\(UUID().uuidString)")
        roots.append(dir)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try "Chapter A.\n".write(
            to: dir.appendingPathComponent("manuscript/a.md"), atomically: true, encoding: .utf8)
        try "Chapter B.\n".write(
            to: dir.appendingPathComponent("manuscript/b.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md"),
                StructureItem(id: "doc-b", title: "B", type: .document, path: "manuscript/b.md"),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: dir.appendingPathComponent("project.maugham.json"))
        return dir
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    /// How many buttons labelled `label` the hosted pane draws.
    private func buttons(labelled label: String, in window: NSWindow) throws -> Int {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip("no assistive client could be attached to this process, so "
                + "SwiftUI never built the tree this test reads")
        }
        return axElements(under: try XCTUnwrap(window.contentView)).filter {
            (axAttribute($0, "accessibilityRole") as? String) == "AXButton"
                && (axAttribute($0, "accessibilityLabel") as? String) == label
        }.count
    }

    /// Poll the drawn tree (not a press: the change is the permit's).
    private func waitForButtons(
        labelled label: String, count: Int, in window: NSWindow
    ) throws -> Int {
        var seen = -1
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            seen = try buttons(labelled: label, in: window)
            if seen == count { return seen }
            pump(0.05)
        }
        return seen
    }

    /// **Review focus #2.** An author of piece A, looking at B in the window,
    /// sees A's note carry its verbs and B's carry none — side by side in the
    /// cross-document queue — and a promotion brings B's back with no reopen.
    func test_theProjectQueueJudgesEachRowByItsOwnDocument() async throws {
        let projectURL = try makeTwoPieceProject()
        let identities = beASigningMac(projectURL)
        let root = try makeForeignRoot(projectURL, identities: identities)
        let documentStore = try await DocumentStore.open(url: projectURL)
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = documentStore

        var docs: [Document] = []
        for (id, path) in [("doc-a", "manuscript/a.md"), ("doc-b", "manuscript/b.md")] {
            let doc = try await Document.load(
                url: projectURL.appendingPathComponent(path), actor: .author,
                session: "s", presenter: nil,
                burstIdle: .seconds(3600), burstMax: .seconds(3600))
            documentStore.register(document: doc, for: path)
            _ = try await doc.addAnnotation(
                kind: .comment, paragraphId: try XCTUnwrap(doc.sequence.first),
                body: "note on \(id)")
            docs.append(doc)
            XCTAssertEqual(doc.docId, id, "premise: the manifest's ids")
        }
        await documentStore.postureSettled()

        try await rootChangesMyPermit(
            to: .author(.pieces(["doc-a"])), root: root, identities: identities,
            projectURL: projectURL, store: documentStore)
        XCTAssertTrue(documentStore.posture(forDocId: "doc-a").allows(.acceptOrReject),
                      "premise: her piece")
        XCTAssertFalse(documentStore.posture(forDocId: "doc-b").allows(.acceptOrReject),
                       "premise: not her piece")

        // The window shows B — the piece she may NOT answer — so a row judged
        // by the window's posture would lose A's verbs too.
        let view = AnnotationsPane(
            document: docs[1], store: store, documentStore: documentStore,
            scope: .constant(.project(focusPiece: nil)),
            onTravel: { _ in }, orchestrator: nil, diagnostics: nil,
            onSetActivePass: { _, _ in }, onSetPassState: { _, _, _ in })
            .environment(UserPreferences(
                defaults: UserDefaults(suiteName: "PostureSurface-\(UUID())")!))
        let window = TestWindow.mount(AnyView(view), size: CGSize(width: 360, height: 700))
        windows.append(window)
        pump()

        XCTAssertEqual(try waitForButtons(labelled: "Got it", count: 1, in: window), 1,
                       "A's note is answerable and B's is not, in one queue")

        try await rootChangesMyPermit(
            to: .bookAuthor, root: root, identities: identities,
            projectURL: projectURL, store: documentStore)
        XCTAssertEqual(try waitForButtons(labelled: "Got it", count: 2, in: window), 2,
                       "the promotion brings B's verbs back with no reopen")

        for doc in docs { await doc.close() }
    }

    // MARK: - Pass state and the round (P3c Task 6)

    private let boardPass = ReviewPass(id: "line", name: "Line")

    private func boardVerbs(_ writes: Box<Int>) -> ReviewBoardChipVerbs {
        ReviewBoardChipVerbs(
            onSetState: { _, _, _ in writes.value += 1 },
            onRunRound: { _, _ in writes.value += 1 })
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// **The chip menu, as a pure function of the cell's posture.** A reviewer
    /// is offered neither the round nor a ruling; a book author both; a
    /// pieces-author both on her piece and neither on somebody else's.
    func test_theChipMenuFollowsTheCellsPosture() {
        let verbs = boardVerbs(Box(0))
        func menu(_ posture: Posture) -> ReviewBoardChipVerbs.ChipMenu {
            verbs.chipMenu(for: "doc-a", pass: boardPass, current: .inProgress,
                           posture: posture)
        }
        XCTAssertNil(menu(reviewer).run, "a reviewer is offered no round")
        XCTAssertTrue(menu(reviewer).states.isEmpty, "…and no ruling on a pass")
        XCTAssertNotNil(menu(bookAuthor).run)
        XCTAssertEqual(menu(bookAuthor).states.map(\.state),
                       ReviewBoardChipVerbs.offeredStates)
        XCTAssertNotNil(menu(piecesAuthorInA).run, "her piece: the round")
        XCTAssertEqual(menu(piecesAuthorInA).states.count, 4, "…and the rulings")
        XCTAssertNil(menu(piecesAuthorInB).run, "somebody else's: no round")
        XCTAssertTrue(menu(piecesAuthorInB).states.isEmpty, "…and no ruling")
        XCTAssertNil(menu(.settling).run, "nothing is offered before it is decided")
        XCTAssertTrue(menu(.settling).states.isEmpty)
    }

    /// **The ladder's write is withheld where the posture forbids a ruling**,
    /// in both inspector arms — `nil` is what draws the ladder read-only.
    func test_theInspectorsLadderWriteFollowsThePosture() async throws {
        let projectURL = try makeTwoPieceProject()
        let store = try await ProjectStore.load(from: projectURL)
        let metrics = EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0)
        for (posture, offered, why) in [
            (reviewer, false, "a reviewer"),
            (piecesAuthorInB, false, "a pieces-author outside her piece"),
            (Posture.settling, false, "an undecided posture"),
            (piecesAuthorInA, true, "a pieces-author in her piece"),
            (bookAuthor, true, "a book author"),
        ] {
            let document = InspectorView(
                store: store, selectedItemId: "doc-a", metrics: metrics,
                onOpenProjectSettings: {}, posture: posture)
            let piece = PieceInspector(
                store: store, pieceId: "doc-a", kind: .prose, posture: posture)
            XCTAssertEqual(document.passLadderWrite(on: "doc-a") != nil, offered,
                           "InspectorView, \(why)")
            XCTAssertEqual(piece.passLadderWrite(on: "doc-a") != nil, offered,
                           "PieceInspector, \(why)")
        }
    }

    private func controls(role: String, in window: NSWindow) throws -> [AnyObject] {
        var probe: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &probe)
        guard error == .success, probe != nil else {
            throw XCTSkip("no assistive client could be attached to this process, so "
                + "SwiftUI never built the tree this test reads")
        }
        return axElements(under: try XCTUnwrap(window.contentView)).filter {
            (axAttribute($0, "accessibilityRole") as? String) == role
        }
    }

    private func mountedCount(
        role: String, in window: NSWindow, where match: (AnyObject) -> Bool = { _ in true }
    ) throws -> Int {
        var seen = 0
        let deadline = Date().addingTimeInterval(2)
        repeat {
            seen = try controls(role: role, in: window).filter(match).count
            if seen > 0 { return seen }
            pump(0.05)
        } while Date() < deadline
        return seen
    }

    /// **The ladder draws its state, and no menu, without a write** — the
    /// reviewer still sees where the piece stands. Drawn/absent only (tripwire
    /// 33): nothing is pressed.
    func test_aLadderWithNoWriteDrawsNoMenus() throws {
        let item = StructureItem(id: "doc-a", title: "A", type: .document,
                                 path: "manuscript/a.md",
                                 passStates: ["line": .done])
        let passes = [ReviewPass(id: "structural", name: "Structural"), boardPass]
        func mount(_ onSet: ((String, PassState?) -> Void)?) -> NSWindow {
            let window = TestWindow.mount(
                AnyView(Form { PassLadder(item: item, passes: passes, onSet: onSet) }),
                size: CGSize(width: 360, height: 300))
            windows.append(window)
            pump()
            return window
        }
        let live = mount({ _, _ in })
        XCTAssertEqual(try mountedCount(role: "AXPopUpButton", in: live), 2,
                       "control: a ladder with a write draws one menu per pass")
        let readOnly = mount(nil)
        _ = try mountedCount(role: "AXStaticText", in: readOnly)
        XCTAssertEqual(try controls(role: "AXPopUpButton", in: readOnly).count, 0,
                       "without a write, no pass is a menu")
        XCTAssertTrue(
            try controls(role: "AXStaticText", in: readOnly).contains {
                (axAttribute($0, "accessibilityLabel") as? String) == PassLadder.doneTitle
                    || (axAttribute($0, "accessibilityValue") as? String) == PassLadder.doneTitle
            },
            "…and the state is still drawn: the reviewer sees where it stands")
    }

    /// **The nudge's verbs follow the posture; its caption does not.**
    func test_theNudgeDrawsItsVerbsOnlyWhereAPassMayBeRuled() throws {
        XCTAssertFalse(PassLadder.offersRulings(under: reviewer))
        XCTAssertFalse(PassLadder.offersRulings(under: piecesAuthorInB))
        XCTAssertFalse(PassLadder.offersRulings(under: .settling))
        XCTAssertTrue(PassLadder.offersRulings(under: piecesAuthorInA))
        XCTAssertTrue(PassLadder.offersRulings(under: bookAuthor))

        func mount(_ verbs: Bool) -> NSWindow {
            let window = TestWindow.mount(AnyView(PassOrderNudgeRow(
                pass: ReviewPass(id: "structural", name: "Structural"),
                onMarkDone: verbs ? {} : nil, onSkip: verbs ? {} : nil)),
                size: CGSize(width: 360, height: 80))
            windows.append(window)
            pump()
            return window
        }
        let offered = mount(true)
        XCTAssertEqual(try waitForButtons(labelled: "Mark done", count: 1, in: offered), 1,
                       "control: the verbs draw where they are offered")
        let withheld = mount(false)
        _ = try mountedCount(role: "AXStaticText", in: withheld)
        XCTAssertEqual(try buttons(labelled: "Mark done", in: withheld), 0)
        XCTAssertEqual(try buttons(labelled: "Skip", in: withheld), 0)
    }

    /// **The board's chips DRAW for a reviewer** — the board is how she sees
    /// where the book stands. Only the menu is hers to be refused.
    func test_theBoardsChipsDrawForAReviewer() throws {
        let structure = [
            StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md"),
        ]
        let window = TestWindow.mount(AnyView(ReviewBoardPane(
            title: "T", structure: structure, passes: [boardPass],
            openNotes: [:], unreadableDocIds: [],
            onOpenNotes: { _ in }, onNavigate: { _, _ in },
            onSetState: { _, _, _ in }, onRunRound: { _, _ in },
            posture: { _ in self.reviewer })),
            size: CGSize(width: 700, height: 300))
        windows.append(window)
        pump()
        let label = ReviewBoardChip.label(piece: "A", pass: boardPass, state: nil)
        XCTAssertEqual(try waitForButtons(labelled: label, count: 1, in: window), 1,
                       "the reviewer's board still draws the chip")
    }

    /// **The production round door, asked of the SETTLED posture, per piece.**
    /// An author of A may run A's round and not B's; a check is not asked at
    /// all (`CompilerRunCommandTests`). And the answer is the settled one: a
    /// demotion whose refresh has not landed is already refused, where the
    /// drawing door may still be giving its last answer.
    func test_theProductionRoundDoorFollowsTheSettledPosturePerPiece() async throws {
        let projectURL = try makeTwoPieceProject()
        let identities = beASigningMac(projectURL)
        let root = try makeForeignRoot(projectURL, identities: identities)
        let documentStore = try await DocumentStore.open(url: projectURL)
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = documentStore
        let device = DeviceSlug.make(from: "test-mac")
        let environment = CompilerOrchestrator.Environment.production(
            store: store, documentStore: documentStore, projectURL: projectURL,
            declaredWorld: DeclaredWorldStore(projectRoot: projectURL, device: device),
            bible: BibleStore(projectRoot: projectURL, device: device),
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "PostureSurface-\(UUID())")!),
            onRunAcknowledged: { _ in })
        await documentStore.postureSettled()

        let asBookAuthorA = await environment.mayRunRound("doc-a")
        let asBookAuthorB = await environment.mayRunRound("doc-b")
        XCTAssertTrue(asBookAuthorA, "a whole-book author may run any round")
        XCTAssertTrue(asBookAuthorB)

        try await rootChangesMyPermit(
            to: .author(.pieces(["doc-a"])), root: root, identities: identities,
            projectURL: projectURL, store: documentStore)
        let piecesA = await environment.mayRunRound("doc-a")
        let piecesB = await environment.mayRunRound("doc-b")
        XCTAssertTrue(piecesA, "her piece: her round")
        XCTAssertFalse(piecesB, "somebody else's piece: not her round")

        try await rootChangesMyPermit(
            to: .reviewer, root: root, identities: identities,
            projectURL: projectURL, store: documentStore)
        let reviewerA = await environment.mayRunRound("doc-a")
        XCTAssertFalse(reviewerA, "a reviewer runs no round, on any piece")
    }

    /// **The settled door, not the drawing one** (controller ruling I): a
    /// demotion delivered and not yet refreshed is refused at once.
    func test_theRoundDoorRefusesADemotionBeforeItsRefreshLands() async throws {
        let projectURL = try makeTwoPieceProject()
        let identities = beASigningMac(projectURL)
        let root = try makeForeignRoot(projectURL, identities: identities)
        let documentStore = try await DocumentStore.open(url: projectURL)
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = documentStore
        let device = DeviceSlug.make(from: "test-mac")
        let environment = CompilerOrchestrator.Environment.production(
            store: store, documentStore: documentStore, projectURL: projectURL,
            declaredWorld: DeclaredWorldStore(projectRoot: projectURL, device: device),
            bible: BibleStore(projectRoot: projectURL, device: device),
            preferences: UserPreferences(
                defaults: UserDefaults(suiteName: "PostureSurface-\(UUID())")!),
            onRunAcknowledged: { _ in })
        await documentStore.postureSettled()
        XCTAssertTrue(documentStore.posture(forDocId: "doc-b").allows(.runRound),
                      "premise: the drawing door has answered yes on B")

        // The demotion, delivered, with NO wait for the posture refresh.
        let mark = try OpLogStore.appliedPositions(
            ofDeviceIds: Set(identities.all.map(\.deviceId)), in: projectURL,
            trust: try TrustResolution.resolve(projectURL: projectURL, identities: identities))
        let rootCache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("root-cache.json"),
            identity: root.fingerprint)
        let permit = Permit.reviewer
        _ = try RegistryAdmission.changePermit(
            person: identities.author.fingerprint,
            role: permit.wireRole, scope: permit.wireScope, pieces: permit.wirePieces,
            mark: mark, unsigned: permit.narrows ? .nothingApplied : nil,
            in: projectURL, by: root, cache: rootCache)
        store.documentStore = documentStore
        documentStore.presenterDidChangeSubitem(at: RegistryWriter.url(
            .people, fingerprint: identities.author.fingerprint, in: projectURL))
        await documentStore.flushRegistryChangeForTesting()

        let mayRun = await environment.mayRunRound("doc-b")
        XCTAssertFalse(mayRun, "the round's door waits for the settled answer")
    }

    /// **The cockpit's Run follows the SHOWN piece's posture**: an author of
    /// A sees Run on A's cockpit and none on B's — absent, not greyed — and a
    /// promotion brings B's back with no reopen. Drawn/absent only.
    func test_theCockpitDrawsRunOnlyWhereARoundMayBeRun() async throws {
        let projectURL = try makeTwoPieceProject()
        let identities = beASigningMac(projectURL)
        let root = try makeForeignRoot(projectURL, identities: identities)
        let documentStore = try await DocumentStore.open(url: projectURL)
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = documentStore
        var docs: [Document] = []
        for (id, path) in [("doc-a", "manuscript/a.md"), ("doc-b", "manuscript/b.md")] {
            let doc = try await Document.load(
                url: projectURL.appendingPathComponent(path), actor: .author,
                session: "s", presenter: nil,
                burstIdle: .seconds(3600), burstMax: .seconds(3600))
            documentStore.register(document: doc, for: path)
            docs.append(doc)
            XCTAssertEqual(doc.docId, id, "premise: the manifest's ids")
        }
        await documentStore.postureSettled()
        try await rootChangesMyPermit(
            to: .author(.pieces(["doc-a"])), root: root, identities: identities,
            projectURL: projectURL, store: documentStore)

        let diagnostics = DiagnosticsStore(
            projectRoot: projectURL, device: DeviceSlug.make(from: "test-mac"))
        func mount(_ doc: Document) -> NSWindow {
            let view = AnnotationsPane(
                document: doc, store: store, documentStore: documentStore,
                scope: .constant(.document),
                onTravel: { _ in }, orchestrator: CompilerOrchestrator(),
                diagnostics: diagnostics,
                onSetActivePass: { _, _ in }, onSetPassState: { _, _, _ in })
                .environment(UserPreferences(
                    defaults: UserDefaults(suiteName: "PostureSurface-\(UUID())")!))
            let window = TestWindow.mount(AnyView(view), size: CGSize(width: 360, height: 700))
            windows.append(window)
            pump()
            return window
        }
        let hers = mount(docs[0])
        XCTAssertEqual(
            try waitForButtons(labelled: ReviewRoundCockpit.runTitle, count: 1, in: hers), 1,
            "control: her piece's cockpit draws Run")
        let theirs = mount(docs[1])
        XCTAssertEqual(
            try waitForButtons(labelled: ReviewRoundCockpit.freshEyesTitle, count: 0,
                               in: theirs), 0)
        XCTAssertEqual(try buttons(labelled: ReviewRoundCockpit.runTitle, in: theirs), 0,
                       "somebody else's piece: no Run, not a greyed one")

        try await rootChangesMyPermit(
            to: .bookAuthor, root: root, identities: identities,
            projectURL: projectURL, store: documentStore)
        XCTAssertEqual(
            try waitForButtons(labelled: ReviewRoundCockpit.runTitle, count: 1, in: theirs), 1,
            "a promotion draws it with no reopen")

        for doc in docs { await doc.close() }
    }

    // MARK: - Statements: the ruling door and its surfaces (P3c Task 7)

    private var reviewerOnAPieceStatement: Posture {
        posture(.reviewer, in: .pieceStatement(piece: "doc-a"))
    }
    private var piecesAuthorOnHerPieceStatement: Posture {
        posture(.author(.pieces(["doc-a"])), in: .pieceStatement(piece: "doc-a"))
    }
    private var piecesAuthorOnAnotherPieceStatement: Posture {
        posture(.author(.pieces(["doc-a"])), in: .pieceStatement(piece: "doc-b"))
    }

    /// **Every statement surface asks one rule** — `.editStatement` of the
    /// statement itself — in both directions: the reviewer and the author of
    /// some pieces outside hers are offered nothing, her own piece's statement
    /// and a whole-book author's every statement are offered everything, and
    /// the project's statements are the book author's alone.
    func test_theStatementVerbsFollowTheStatementsOwnPosture() {
        let refused = [reviewer, reviewerOnAPieceStatement,
                       piecesAuthorOnAnotherPieceStatement, piecesAuthorOnTheLedger,
                       Posture.settling]
        let offered = [bookAuthor, piecesAuthorOnHerPieceStatement]
        for (posture, expected) in refused.map({ ($0, false) }) + offered.map({ ($0, true) }) {
            XCTAssertEqual(RulingsStratumView.offersVerbs(posture), expected, "\(posture)")
            XCTAssertEqual(StatementProposalBanner.offersVerbs(posture), expected, "\(posture)")
            XCTAssertEqual(BibleStratumView.offersGraduation(posture), expected, "\(posture)")
        }
    }

    /// **The letter's statement-writing offers ask the DESTINATION** — the
    /// intent the clause would land in and the project's ledger — never the
    /// piece the letter is about.
    func test_theLettersOffersAskTheStatementTheyWouldWrite() {
        func table(_ piece: Posture, _ project: Posture)
            -> (Statement.Kind, Statement.Scope) -> Posture {
            { _, scope in
                if case .document = scope { return piece }
                return project
            }
        }
        let piecesAuthor = table(piecesAuthorOnHerPieceStatement, piecesAuthorOnTheLedger)
        XCTAssertTrue(TurnClauseOffer.mayFile(at: .document("doc-a"), piecesAuthor),
                      "her piece's own intent is hers")
        XCTAssertFalse(TurnClauseOffer.mayFile(at: .project, piecesAuthor),
                       "the book's intent is not, though the letter is about her piece")
        XCTAssertFalse(LessonOffer.mayWriteTheLedger(piecesAuthor),
                       "the ledger is a project statement")
        let reviewers = table(reviewerOnAPieceStatement, reviewer)
        XCTAssertFalse(TurnClauseOffer.mayFile(at: .document("doc-a"), reviewers))
        XCTAssertFalse(LessonOffer.mayWriteTheLedger(reviewers))
        let author = table(bookAuthor, bookAuthor)
        XCTAssertTrue(TurnClauseOffer.mayFile(at: .project, author))
        XCTAssertTrue(LessonOffer.mayWriteTheLedger(author))
    }

    /// **Author's Diagnostics pane (controller ruling Q)**: Got it / Not this
    /// follow the piece's `.acceptOrReject`, Answer the piece intent's
    /// `.editStatement`, both directions.
    func test_theDiagnosticsPanesVerbsFollowThePosture() {
        func pane(_ document: Posture, _ statement: Posture) -> DiagnosticsPostures {
            DiagnosticsPostures(document: document, statement: { _, _ in statement })
        }
        let theReviewer = pane(reviewer, reviewerOnAPieceStatement)
        XCTAssertFalse(DiagnosticsPane.offersDisposal(theReviewer))
        XCTAssertFalse(DiagnosticsPane.offersAnAnswer(docId: "doc-a", posture: theReviewer))
        let herPiece = pane(piecesAuthorInA, piecesAuthorOnHerPieceStatement)
        XCTAssertTrue(DiagnosticsPane.offersDisposal(herPiece))
        XCTAssertTrue(DiagnosticsPane.offersAnAnswer(docId: "doc-a", posture: herPiece))
        let theirPiece = pane(piecesAuthorInB, piecesAuthorOnAnotherPieceStatement)
        XCTAssertFalse(DiagnosticsPane.offersDisposal(theirPiece))
        XCTAssertFalse(DiagnosticsPane.offersAnAnswer(docId: "doc-b", posture: theirPiece))
        let author = pane(bookAuthor, bookAuthor)
        XCTAssertTrue(DiagnosticsPane.offersDisposal(author))
        XCTAssertTrue(DiagnosticsPane.offersAnAnswer(docId: "doc-a", posture: author))

        // The answer asks the statement it WRITES — `.document(docId)`'s
        // intent — and nothing else.
        var asked: [String] = []
        let recording = DiagnosticsPostures(document: bookAuthor, statement: { kind, scope in
            asked.append("\(kind.rawValue)|\(scope.rawValue)")
            return self.bookAuthor
        })
        _ = DiagnosticsPane.offersAnAnswer(docId: "doc-a", posture: recording)
        XCTAssertEqual(asked, ["intent|\(Statement.Scope.document("doc-a").rawValue)"])
    }

    /// **The rulings are drawn for a reviewer; their verbs are not** — drawn
    /// or absent, never pressed (tripwire 33).
    func test_theRulingsStratumDrawsItsRowsAndHidesItsVerbs() async throws {
        let fixture = try await StatementMountFixture.novel(named: "posture-rulings")
        defer { fixture.tearDown() }
        let rulings = [Ruling(id: "r1", text: "No flashbacks.", ruledOn: nil,
                              provenance: nil)]
        func mount(_ posture: Posture) -> NSWindow {
            let window = TestWindow.mount(
                AnyView(RulingsStratumView(
                    rulings: rulings, kind: .intent, scope: .project,
                    store: fixture.store, world: nil, posture: posture)),
                size: CGSize(width: 420, height: 200))
            windows.append(window)
            pump()
            return window
        }
        let writer = mount(bookAuthor)
        XCTAssertEqual(try waitForButtons(labelled: "Revoke", count: 1, in: writer), 1,
                       "control: the writer's row draws Revoke")
        XCTAssertEqual(try buttons(labelled: "Edit", in: writer), 1)
        let reader = mount(reviewer)
        XCTAssertGreaterThan(try mountedCount(role: "AXStaticText", in: reader) {
            (self.axAttribute($0, "accessibilityLabel") as? String) == "No flashbacks."
                || (self.axAttribute($0, "accessibilityValue") as? String) == "No flashbacks."
        }, 0, "the reviewer still reads the ruling")
        XCTAssertEqual(try buttons(labelled: "Revoke", in: reader), 0)
        XCTAssertEqual(try buttons(labelled: "Edit", in: reader), 0)
    }

    /// **A reviewer reads a proposal; Adopt and Discard are not hers.**
    func test_theProposalBannerDrawsForAReviewerWithoutItsVerbs() throws {
        let proposal = StatementProposalStore.Proposal(
            kind: .editionBrief("es"), markdown: "Register: usted.",
            rationale: "the doctor is formal", proposedAt: Date(), author: "the assistant")
        func mount(_ posture: Posture) -> NSWindow {
            let window = TestWindow.mount(
                AnyView(StatementProposalBanner(
                    proposal: proposal, current: "Register: tú.", statementExists: true,
                    now: Date(), notice: nil, busy: false, posture: posture,
                    onAdopt: {}, onDiscard: {})),
                size: CGSize(width: 480, height: 320))
            windows.append(window)
            pump()
            return window
        }
        let writer = mount(bookAuthor)
        XCTAssertEqual(
            try waitForButtons(
                labelled: StatementProposalCopy.adoptAccessibilityLabel(.editionBrief("es")),
                count: 1, in: writer), 1,
            "control: the writer is offered Adopt")
        let reader = mount(reviewer)
        XCTAssertGreaterThan(try mountedCount(role: "AXStaticText", in: reader), 0,
                             "the banner still draws")
        XCTAssertEqual(try buttons(
            labelled: StatementProposalCopy.adoptAccessibilityLabel(.editionBrief("es")),
            in: reader), 0)
        XCTAssertEqual(try buttons(
            labelled: StatementProposalCopy.discardAccessibilityLabel(.editionBrief("es")),
            in: reader), 0)
    }

    // MARK: The door itself, over a real register

    private struct StatementHarness {
        let projectURL: URL
        let identities: LocalIdentities
        let root: DeviceIdentity
        let documentStore: DocumentStore
        let store: ProjectStore
    }

    private func makeStatementHarness() async throws -> StatementHarness {
        let projectURL = try makeTwoPieceProject()
        let identities = beASigningMac(projectURL)
        let root = try makeForeignRoot(projectURL, identities: identities)
        let documentStore = try await DocumentStore.open(url: projectURL)
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = documentStore
        await documentStore.postureSettled()
        return StatementHarness(projectURL: projectURL, identities: identities, root: root,
                                documentStore: documentStore, store: store)
    }

    private func become(_ permit: Permit, _ h: StatementHarness) async throws {
        try await rootChangesMyPermit(
            to: permit, root: h.root, identities: h.identities,
            projectURL: h.projectURL, store: h.documentStore)
    }

    /// Every byte of a statement's op log, so "appended nothing" is measured
    /// on disk rather than inferred from the text.
    private func opLogBytes(_ kind: Statement.Kind, _ scope: Statement.Scope,
                            _ store: ProjectStore) -> Int {
        guard let statement = store.statement(kind: kind, scope: scope) else { return 0 }
        return OpLogStore.opLogFileURLs(forDocId: statement.id, in: store.url)
            .map { (try? Data(contentsOf: $0).count) ?? 0 }  // adr-0018-ok: a test measuring op-log bytes, not reading manuscript text
            .reduce(0, +)
    }

    private func text(_ kind: Statement.Kind, _ scope: Statement.Scope,
                      _ store: ProjectStore) -> String? {
        store.statement(kind: kind, scope: scope).flatMap { try? store.statementText(of: $0) }
    }

    /// Assert the act is refused as NOT YOURS and leaves the statement exactly
    /// as it was — no op, no mint, no moved word.
    private func assertNotYours(
        _ label: String, _ kind: Statement.Kind, _ scope: Statement.Scope,
        _ store: ProjectStore, _ act: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let existed = store.statement(kind: kind, scope: scope) != nil
        let bytes = opLogBytes(kind, scope, store)
        let before = text(kind, scope, store)
        do {
            try await act()
            XCTFail("\(label) was not refused", file: file, line: line)
        } catch let refusal as RulingRefusal {
            XCTAssertEqual(refusal, .notYours(statement: kind), file: file, line: line)
        } catch {
            XCTFail("\(label) threw \(error), not RulingRefusal", file: file, line: line)
        }
        XCTAssertEqual(store.statement(kind: kind, scope: scope) != nil, existed,
                       "\(label) minted nothing", file: file, line: line)
        XCTAssertEqual(opLogBytes(kind, scope, store), bytes,
                       "\(label) appended nothing", file: file, line: line)
        XCTAssertEqual(text(kind, scope, store), before,
                       "\(label) moved no words", file: file, line: line)
    }

    private func rule(_ words: String, _ kind: Statement.Kind, _ scope: Statement.Scope,
                      _ store: ProjectStore) async throws {
        try await RulingPerformer.rule(
            words, provenance: "a test", kind: kind, forScope: scope,
            store: store, world: nil)
    }

    /// **All four verbs, refused at `RulingPerformer`'s own door**, across the
    /// ladder and back: the whole book rules anywhere; an author of `doc-a`
    /// rules on her piece's statement and on neither the book's intent nor
    /// `doc-b`'s; a reviewer rules on nothing; a promotion reopens it all with
    /// no reopen of anything.
    func test_aRulingIsMadeOnlyByWhoeverMayWriteTheStatement() async throws {
        let h = try await makeStatementHarness()
        let store = h.store
        let pieceA = Statement.Scope.document("doc-a")
        let pieceB = Statement.Scope.document("doc-b")

        // The whole book: every statement.
        try await rule("The book holds to one winter.", .intent, .project, store)
        try await rule("A stays in the kitchen.", .intent, pieceA, store)
        XCTAssertEqual(RulingsStratum.currentRows(
            kind: .intent, forScope: .project, store: store).count, 1)

        // An author of doc-a: her piece's statement, and nothing of the book's.
        try await become(.author(.pieces(["doc-a"])), h)
        try await rule("A ends at dawn.", .intent, pieceA, store)
        XCTAssertEqual(RulingsStratum.currentRows(
            kind: .intent, forScope: pieceA, store: store).count, 2,
            "her own piece's statement is hers to rule on")
        await assertNotYours("rule on the book's intent", .intent, .project, store) {
            try await self.rule("Two winters.", .intent, .project, store)
        }
        await assertNotYours("rule on doc-b (minting it)", .intent, pieceB, store) {
            try await self.rule("B is somebody else's.", .intent, pieceB, store)
        }
        await assertNotYours("rule on the lessons ledger", .lessons, .project, store) {
            try await self.rule("Cut adverbs.", .lessons, .project, store)
        }
        let bookRuling = try XCTUnwrap(RulingsStratum.currentRows(
            kind: .intent, forScope: .project, store: store).first)
        await assertNotYours("revoke on the book's intent", .intent, .project, store) {
            try await RulingPerformer.revoke(
                rulingId: bookRuling.id, kind: .intent, forScope: .project,
                store: store, world: nil)
        }
        await assertNotYours("edit on the book's intent", .intent, .project, store) {
            try await RulingPerformer.edit(
                rulingId: bookRuling.id, newText: "Two winters.", kind: .intent,
                forScope: .project, store: store, world: nil)
        }
        await assertNotYours("restore on the book's intent", .intent, .project, store) {
            try await RulingPerformer.restore(
                bookRuling, at: 0, kind: .intent, forScope: .project,
                store: store, world: nil)
        }

        // A reviewer: nothing, anywhere — though she still reads it all.
        try await become(.reviewer, h)
        let pieceRuling = try XCTUnwrap(RulingsStratum.currentRows(
            kind: .intent, forScope: pieceA, store: store).first)
        await assertNotYours("a reviewer's rule", .intent, pieceA, store) {
            try await self.rule("A is mine now.", .intent, pieceA, store)
        }
        await assertNotYours("a reviewer's revoke", .intent, pieceA, store) {
            try await RulingPerformer.revoke(
                rulingId: pieceRuling.id, kind: .intent, forScope: pieceA,
                store: store, world: nil)
        }
        await assertNotYours("a reviewer's edit", .intent, pieceA, store) {
            try await RulingPerformer.edit(
                rulingId: pieceRuling.id, newText: "Changed.", kind: .intent,
                forScope: pieceA, store: store, world: nil)
        }
        await assertNotYours("a reviewer's restore", .intent, pieceA, store) {
            try await RulingPerformer.restore(
                pieceRuling, at: 0, kind: .intent, forScope: pieceA,
                store: store, world: nil)
        }
        XCTAssertEqual(RulingsStratum.currentRows(
            kind: .intent, forScope: pieceA, store: store).count, 2,
            "the reviewer still reads every ruling")

        // A promotion back: every verb again, with nothing reopened.
        try await become(.bookAuthor, h)
        try await RulingPerformer.revoke(
            rulingId: bookRuling.id, kind: .intent, forScope: .project,
            store: store, world: nil)
        XCTAssertTrue(RulingsStratum.currentRows(
            kind: .intent, forScope: .project, store: store).isEmpty)
        try await rule("Two winters.", .intent, .project, store)
    }

    /// **The door does not depend on a window**: a `ProjectStore` no window
    /// holds builds the posture from the one builder and refuses the same.
    func test_theRulingDoorRefusesWithoutAWindowToAsk() async throws {
        let h = try await makeStatementHarness()
        try await become(.reviewer, h)
        let headless = try await ProjectStore.load(from: h.projectURL)
        XCTAssertNil(headless.documentStore, "premise: no window adopted this store")
        await assertNotYours("a windowless reviewer's rule", .intent, .project, headless) {
            try await self.rule("Two winters.", .intent, .project, headless)
        }
    }

    /// **A refused Adopt writes nothing** — not the essay-then-rollback the
    /// glossary's own door would have left, and no minted brief.
    func test_aProposalIsAdoptedOnlyByWhoeverMayWriteTheStatement() async throws {
        let h = try await makeStatementHarness()
        let proposal = try StatementProposalStore(projectURL: h.projectURL).stage(
            StatementProposalStore.Proposal(
                kind: .editionBrief("es"),
                markdown: "Register: usted.\n\n## Rulings\n\n- «October» → «Octubre»\n",
                rationale: nil, proposedAt: Date(), author: "the assistant"))
        try await become(.author(.pieces(["doc-a"])), h)
        await assertNotYours("a pieces-author's Adopt", .editionBrief("es"), .project, h.store) {
            _ = try await StatementProposalGate.adopt(
                proposal, store: h.store, world: nil, undoManager: nil,
                workTaskSink: { _ in })
        }
        XCTAssertNotNil(StatementProposalStore(projectURL: h.projectURL)
            .pending(for: .editionBrief("es")), "the proposal still stands")

        try await become(.bookAuthor, h)
        let adoption = try await StatementProposalGate.adopt(
            proposal, store: h.store, world: nil, undoManager: nil, workTaskSink: { _ in })
        XCTAssertEqual(adoption.glossaryAppended, 1, "the book author adopts it whole")
    }

    /// **A refused revoke from the row is SAID** — and its ⌘Z, registered while
    /// she could, is refused and said too, rather than doing nothing.
    func test_aRefusedRowVerbAndItsUndoAreSaid() async throws {
        let h = try await makeStatementHarness()
        let store = h.store
        try await rule("Keep it spare.", .intent, .project, store)
        try await rule("One winter.", .intent, .project, store)
        let rows = RulingsStratum.currentRows(kind: .intent, forScope: .project, store: store)
        let um = UndoManager()
        var work: [Task<Void, Never>] = []
        await RulingsStratum.revoke(
            rows[0], at: 0, kind: .intent, forScope: .project, store: store,
            world: nil, undoManager: um, workTaskSink: { work.append($0) })
        XCTAssertTrue(um.canUndo, "premise: the writer's revoke registered its ⌘Z")

        try await become(.reviewer, h)
        let refusal = RulingRefusal.notYours(statement: .intent).localizedDescription
        let saidOnPress = await notices {
            await RulingsStratum.revoke(
                rows[1], at: 0, kind: .intent, forScope: .project, store: store,
                world: nil, undoManager: um, workTaskSink: { work.append($0) })
        }
        XCTAssertEqual(saidOnPress, [refusal], "the refused press is said")
        let saidOnUndo = await notices {
            um.undo()
            for task in work { await task.value }
        }
        XCTAssertEqual(saidOnUndo, [refusal], "the refused undo is said")
        XCTAssertEqual(RulingsStratum.currentRows(
            kind: .intent, forScope: .project, store: store).map(\.text), ["One winter."],
            "the undo restored nothing")
    }

    // MARK: - P3c Task 8: the tree, tasks and translations

    /// A posture table keyed by document id, for the pure decisions: the
    /// project stream by its own id, every piece by its own.
    private func postures(
        _ permit: Permit, pieces: [String] = ["doc-a", "doc-b"]
    ) -> (String) -> Posture {
        { id in
            let cls: DocumentClass = id == DocumentClass.projectStreamDocId
                ? .projectStream : .piece(id)
            return self.posture(permit, in: cls)
        }
    }

    private var treeFixture: (a: StructureItem, b: StructureItem, groupA: StructureItem,
                              groupAB: StructureItem, empty: StructureItem) {
        let a = StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")
        let b = StructureItem(id: "doc-b", title: "B", type: .document, path: "manuscript/b.md")
        var groupA = StructureItem(id: "grp-a", title: "Part A", type: .group, path: nil)
        groupA.children = [a]
        var nested = StructureItem(id: "grp-n", title: "Inner", type: .group, path: nil)
        nested.children = [b]
        var groupAB = StructureItem(id: "grp-ab", title: "Part AB", type: .group, path: nil)
        groupAB.children = [a, nested]
        var empty = StructureItem(id: "grp-e", title: "Empty", type: .group, path: nil)
        empty.children = []
        return (a, b, groupA, groupAB, empty)
    }

    /// **The tree offers structure only where the posture allows it, and a
    /// group only where EVERY piece in it does** — both directions, pure.
    func test_theTreesStructuralVerbsFollowEveryPieceTheRowIsAbout() {
        let t = treeFixture
        let none = TreeStructureVerbs(
            newInside: false, duplicate: false, rename: false, delete: false,
            move: false, linkResearch: false, tidy: false)

        // A reviewer: no structural verb on any row, and no New at the root.
        let reviewer = postures(.reviewer)
        for item in [t.a, t.b, t.groupA, t.groupAB, t.empty] {
            XCTAssertEqual(TreeStructureVerbs.decide(for: item, postureOf: reviewer), none,
                           "a reviewer restructures nothing: \(item.id)")
        }
        XCTAssertFalse(TreeStructureVerbs.mayStartAPiece(
            reviewer(DocumentClass.projectStreamDocId)))

        // The whole-book author: every verb its row kind has.
        let book = postures(.bookAuthor)
        XCTAssertEqual(TreeStructureVerbs.decide(for: t.a, postureOf: book),
                       TreeStructureVerbs(newInside: true, duplicate: true, rename: true,
                                          delete: true, move: true, linkResearch: true,
                                          tidy: false))
        XCTAssertEqual(TreeStructureVerbs.decide(for: t.groupAB, postureOf: book),
                       TreeStructureVerbs(newInside: true, duplicate: true, rename: true,
                                          delete: true, move: true, linkResearch: false,
                                          tidy: true))
        XCTAssertTrue(TreeStructureVerbs.decide(for: t.empty, postureOf: book).delete,
                      "an empty group is the book's own structure — hers")
        XCTAssertTrue(TreeStructureVerbs.mayStartAPiece(book(DocumentClass.projectStreamDocId)))

        // An author of A: A's row, and a group holding only A — never B's,
        // never a group holding B however deep, never an empty group, and
        // never a new piece (ruling R3) — so no Duplicate either.
        let pieces = postures(.author(.pieces(["doc-a"])))
        XCTAssertEqual(TreeStructureVerbs.decide(for: t.a, postureOf: pieces),
                       TreeStructureVerbs(newInside: false, duplicate: false, rename: true,
                                          delete: true, move: true, linkResearch: true,
                                          tidy: false))
        XCTAssertEqual(TreeStructureVerbs.decide(for: t.b, postureOf: pieces), none)
        XCTAssertEqual(TreeStructureVerbs.decide(for: t.groupA, postureOf: pieces),
                       TreeStructureVerbs(newInside: false, duplicate: false, rename: true,
                                          delete: true, move: true, linkResearch: false,
                                          tidy: true))
        XCTAssertEqual(TreeStructureVerbs.decide(for: t.groupAB, postureOf: pieces), none,
                       "a pieces-author may not delete a group holding somebody else's chapter")
        XCTAssertEqual(TreeStructureVerbs.decide(for: t.empty, postureOf: pieces), none)
        XCTAssertFalse(TreeStructureVerbs.mayStartAPiece(
            pieces(DocumentClass.projectStreamDocId)), "ruling R3")

        // Settling offers the reviewer row alone — no structure.
        XCTAssertEqual(TreeStructureVerbs.decide(for: t.a, postureOf: { _ in .settling }), none)
    }

    /// **Both trees ask the window's door, and a permit change moves them in
    /// both directions with no reopen** — BinderView's and the Collection
    /// pane's own decisions, over a real register.
    func test_theTreesAskTheWindowsDoorInBothDirections() async throws {
        let h = try await makeStatementHarness()
        let a = try XCTUnwrap(TreeWalk.find(id: "doc-a", in: h.store.manifest.structure))
        let b = try XCTUnwrap(TreeWalk.find(id: "doc-b", in: h.store.manifest.structure))
        let binder = BinderView(store: h.store, selectedSubject: .constant(nil),
                                treeState: BinderTreeSectionsState())
        let pieces = CollectionPiecesPane(store: h.store, selectedSubject: .constant(nil),
                                          renamingItemId: .constant(nil),
                                          treeState: BinderTreeSectionsState())

        XCTAssertTrue(binder.structureVerbs(for: b).delete, "premise: the whole book is hers")
        XCTAssertTrue(binder.mayStartAPiece)

        try await become(.author(.pieces(["doc-a"])), h)
        XCTAssertTrue(binder.structureVerbs(for: a).rename, "her piece: her row's verbs")
        XCTAssertTrue(binder.structureVerbs(for: a).move)
        XCTAssertFalse(binder.structureVerbs(for: b).rename, "not hers: no verbs")
        XCTAssertFalse(binder.structureVerbs(for: b).move, "the drop refuses B")
        XCTAssertFalse(binder.mayStartAPiece, "no New Document at the root (R3)")
        XCTAssertFalse(pieces.structureVerbs(for: b).delete)
        XCTAssertFalse(pieces.mayStartAPiece)

        try await become(.reviewer, h)
        XCTAssertFalse(binder.structureVerbs(for: a).offersAny, "a reviewer: nothing")
        XCTAssertFalse(pieces.structureVerbs(for: a).offersAny)

        try await become(.bookAuthor, h)
        XCTAssertTrue(binder.structureVerbs(for: b).delete, "promotion: back, no reopen")
        XCTAssertTrue(binder.mayStartAPiece)
        XCTAssertTrue(pieces.mayStartAPiece)
    }

    /// **A task is judged by ITS document**: the project's tasks by the
    /// project stream, a chapter's by the chapter — and an inline task's toggle
    /// or archive, which edits the manuscript, needs the words as well.
    func test_theTasksPaneOffersTaskVerbsByTheTasksOwnDocument() {
        let none = TaskRowVerbs(toggle: false, archive: false, delete: false, move: false)
        for kind in [TaskKind.paneCreated, .inlineMarkdown, .fountainBoneyard] {
            XCTAssertEqual(TaskRowVerbs.decide(kind: kind, posture: reviewer), none,
                           "a reviewer's tasks pane is read-only: \(kind)")
            XCTAssertEqual(TaskRowVerbs.decide(kind: kind, posture: bookAuthor), .unrestricted)
            XCTAssertEqual(TaskRowVerbs.decide(kind: kind, posture: piecesAuthorInA),
                           .unrestricted, "her piece: \(kind)")
            XCTAssertEqual(TaskRowVerbs.decide(kind: kind, posture: piecesAuthorInB), none,
                           "not her piece: \(kind)")
        }
        // The project stream takes her tasks but not her words: a pane task
        // is hers there, and anything that would edit text is not.
        let projectStream = posture(.author(.pieces(["doc-a"])), in: .projectStream)
        XCTAssertEqual(TaskRowVerbs.decide(kind: .paneCreated, posture: projectStream),
                       .unrestricted, "task create on __project__ is allowed (R3's pair)")
        XCTAssertEqual(TaskRowVerbs.decide(kind: .inlineMarkdown, posture: projectStream),
                       TaskRowVerbs(toggle: false, archive: false, delete: true, move: true),
                       "an inline toggle also needs .writeText")

        XCTAssertEqual(TaskCreationScopes.decide(document: reviewer, project: reviewer),
                       TaskCreationScopes(document: false, project: false))
        XCTAssertEqual(TaskCreationScopes.decide(document: piecesAuthorInB, project: projectStream),
                       TaskCreationScopes(document: false, project: true))
        XCTAssertEqual(TaskCreationScopes.decide(document: piecesAuthorInA, project: projectStream),
                       TaskCreationScopes(document: true, project: true))
        XCTAssertEqual(TaskCreationScopes.decide(document: nil, project: bookAuthor),
                       TaskCreationScopes(document: false, project: true))

        // Ruling U: Promote to Task and Accept as task ask `.task` of THIS
        // document.
        let pane = { (doc: Posture) in DiagnosticsPostures(document: doc, statement: { _, _ in doc }) }
        XCTAssertFalse(DiagnosticsPane.offersATask(pane(reviewer)))
        XCTAssertFalse(DiagnosticsPane.offersATask(pane(piecesAuthorInB)))
        XCTAssertTrue(DiagnosticsPane.offersATask(pane(piecesAuthorInA)))
        XCTAssertTrue(DiagnosticsPane.offersATask(pane(bookAuthor)))
    }

    /// **The task door**: a task op the stamp refuses is never appended, and
    /// the refusal is said — a pane task, a status change, and an inline
    /// archive, which would otherwise splice the manuscript. Promotion opens it.
    func test_aRefusedTaskIsNeverAppendedAndIsSaid() async throws {
        let (dir, docURL) = try makeTestProject(
            prefix: "PostureTaskDoor", initialMd: "Intro.\n\n- [ ] ring the printer\n")
        roots.append(dir)
        let doc = try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
        let inline = try XCTUnwrap(doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId), statuses: [.open])).first,
            "premise: the inline task derived and its anchor minted while she could write")
        let pane = doc.createPaneTask(body: "a pane task", parentTaskId: nil)
        beAReviewer(doc)

        let ops = doc._opLogMirror.count
        let text = doc.displayText
        let said = await notices {
            doc.createPaneTask(body: "refused", parentTaskId: nil)
            doc.setTaskStatus(id: pane.id, status: .done)
            doc.archiveTask(id: inline.id)
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(doc._opLogMirror.count, ops, "nothing appended")
        XCTAssertEqual(doc.displayText, text, "the inline archive spliced nothing")
        XCTAssertEqual(said, [
            "Couldn't change 3 tasks — this Mac can no longer file tasks in this piece."])

        doc.stamp(localWritePermit: .unrestricted)
        doc.setTaskStatus(id: pane.id, status: .done)
        XCTAssertEqual(doc._opLogMirror.count, ops + 1, "promotion: the door opens")
    }

    // MARK: Translations

    private func translationBytes(_ docId: String, _ projectURL: URL) -> Int {
        TranslationStore.fileURLs(forDocId: docId, language: "es", in: projectURL)
            .map { (try? Data(contentsOf: $0).count) ?? 0 }  // adr-0018-ok: a test measuring translation-file bytes, not reading manuscript text
            .reduce(0, +)
    }

    /// Open and close both chapters while this Mac writes the whole book, so
    /// each has an op log (a bootstrap) a later permit's reads derive from.
    private func bootstrapBothChapters(_ h: StatementHarness) async throws {
        for path in ["manuscript/a.md", "manuscript/b.md"] {
            let doc = try await Document.load(
                url: h.projectURL.appendingPathComponent(path), actor: .author,
                session: "s", presenter: nil)
            await doc.close()
        }
    }

    private func writeTranslation(
        _ docId: String, _ h: StatementHarness, actor: DeviceActor = .translator
    ) async throws {
        let state = try currentParagraphState(
            documentId: docId, store: h.store, documentStore: h.documentStore,
            projectURL: h.projectURL)
        let pid = try XCTUnwrap(state.sequence.first)
        try await TranslationWritePipeline.perform(
            entries: [.init(paragraphId: pid, text: "Capítulo.")],
            language: "es", documentId: docId, state: state, actor: actor,
            identities: h.identities,
            deviceState: try XCTUnwrap(Document.deviceStateForTesting))
    }

    private func assertTranslationRefused(
        _ label: String, _ docId: String, _ h: StatementHarness,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let before = translationBytes(docId, h.projectURL)
        do {
            try await writeTranslation(docId, h)
            XCTFail("\(label) was not refused", file: file, line: line)
        } catch MCPError.toolError(let payload) {
            XCTAssertEqual(payload.error, "translation_not_permitted", file: file, line: line)
            XCTAssertEqual(payload.fields["document_id"], .string(docId),
                           "the refusal names the piece", file: file, line: line)
        } catch {
            XCTFail("\(label) threw \(error)", file: file, line: line)
        }
        XCTAssertEqual(translationBytes(docId, h.projectURL), before,
                       "\(label) appended nothing", file: file, line: line)
    }

    /// **`write_translation`'s pipeline refuses per piece, as the TRANSLATOR,
    /// before any append** — an author of A translates A and not B; a
    /// reviewer translates nothing; a promotion brings B back.
    func test_theTranslationPipelineRefusesPerPieceBeforeAnyAppend() async throws {
        let h = try await makeStatementHarness()
        try await bootstrapBothChapters(h)

        try await become(.author(.pieces(["doc-a"])), h)
        let a0 = translationBytes("doc-a", h.projectURL)
        try await writeTranslation("doc-a", h)
        XCTAssertGreaterThan(translationBytes("doc-a", h.projectURL), a0, "her piece: written")
        await assertTranslationRefused("a pieces-author's translation of B", "doc-b", h)

        try await become(.reviewer, h)
        await assertTranslationRefused("a reviewer's translation of A", "doc-a", h)

        try await become(.bookAuthor, h)
        let b0 = translationBytes("doc-b", h.projectURL)
        try await writeTranslation("doc-b", h)
        XCTAssertGreaterThan(translationBytes("doc-b", h.projectURL), b0, "promotion: written")
    }

    /// **Removing an orphan is the author's own translation write** and asks
    /// the author's key the same door: refused, nothing appended.
    func test_anOrphanPurgeIsRefusedWhereTheAuthorMayNotTranslate() async throws {
        let h = try await makeStatementHarness()
        try await bootstrapBothChapters(h)
        try await writeTranslation("doc-b", h)  // an edition of B exists
        try await become(.author(.pieces(["doc-a"])), h)
        try await writeTranslation("doc-a", h)  // and of her own A
        let before = translationBytes("doc-b", h.projectURL)
        do {
            try await TranslationReviewPaneLogic.purgeOrphans(
                ["zz99"], docId: "doc-b", language: "es", identities: h.identities,
                deviceState: try XCTUnwrap(Document.deviceStateForTesting),
                projectURL: h.projectURL)
            XCTFail("a purge of B was not refused")
        } catch MCPError.toolError(let payload) {
            XCTAssertEqual(payload.error, "translation_not_permitted")
        }
        XCTAssertEqual(translationBytes("doc-b", h.projectURL), before)
        let aBefore = translationBytes("doc-a", h.projectURL)
        try await TranslationReviewPaneLogic.purgeOrphans(
            ["zz99"], docId: "doc-a", language: "es", identities: h.identities,
            deviceState: try XCTUnwrap(Document.deviceStateForTesting),
            projectURL: h.projectURL)
        XCTAssertGreaterThan(translationBytes("doc-a", h.projectURL), aBefore,
                             "her piece: the tombstone is written")
    }

    /// **The desk draws Run only where its translator may translate** — per
    /// piece, the same answer for every language.
    func test_theDeskDrawsRunOnlyWhereItsTranslatorMay() {
        func offers(_ permit: Permit, target: String?, book: [String] = ["doc-a", "doc-b"])
            -> DepartmentTranslationOffers {
            let p = postures(permit)
            return DepartmentTranslationOffers.decide(
                target: target, book: book, mayTranslate: { p($0).allows(.translate) })
        }
        let none = DepartmentTranslationOffers(run: false, runBook: false)
        XCTAssertEqual(offers(.reviewer, target: "doc-a"), none, "a reviewer: no Run at all")
        XCTAssertEqual(offers(.reviewer, target: nil), none)
        XCTAssertEqual(offers(.reviewer, target: nil, book: []), none)
        XCTAssertEqual(offers(.bookAuthor, target: "doc-b"), .unrestricted)
        XCTAssertEqual(offers(.bookAuthor, target: nil, book: []), .unrestricted,
                       "nothing to judge: the book's own stream answers, and it is hers")
        let pieces = Permit.author(.pieces(["doc-a"]))
        XCTAssertEqual(offers(pieces, target: "doc-a"),
                       DepartmentTranslationOffers(run: true, runBook: true))
        XCTAssertEqual(offers(pieces, target: "doc-b"),
                       DepartmentTranslationOffers(run: false, runBook: true),
                       "B is not hers; the book run will leave B out and say so")
        XCTAssertEqual(offers(pieces, target: nil, book: ["doc-b"]), none)
        XCTAssertEqual(
            DepartmentPaneHost.notTranslatable(titles: ["B"]),
            "Your part in this book doesn\u{2019}t reach \u{201C}B\u{201D}, so it was not translated.")
        XCTAssertEqual(
            DepartmentPaneHost.notTranslatable(titles: ["B", "C"]),
            "Your part in this book doesn\u{2019}t reach \u{201C}B\u{201D} and \u{201C}C\u{201D}, "
                + "so they were not translated.")
    }

    /// **Translation is judged as the TRANSLATOR, never the writer's hand** —
    /// and on the root's own Mac the two differ: the root yielding to Sam on
    /// Sam's piece has lowered HER HAND there (cooperatively), not her
    /// translator's. The desk asks the translator, so its Run stays.
    ///
    /// Also the translation half of controller ruling H, pinned as it is BUILT:
    /// no document id resolves to `.translation` — a translation stream's id IS
    /// its piece's (`PermitJudge.translation`) — so the translation surfaces
    /// ask the piece's id, and the writer's-hand posture on that id yields
    /// with the piece by construction; the translator's never does.
    func test_translationIsJudgedAsTheTranslatorNotTheYieldedHand() async throws {
        let projectURL = try makeTwoPieceProject()
        let identities = beASigningMac(projectURL)
        _ = identities
        let store = try await DocumentStore.open(url: projectURL)  // this Mac roots the book
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam\u{2019}s Mac",
            permit: .author(.pieces(["doc-a"])))
        await store.postureSettled()

        XCTAssertEqual(DocumentClass.resolve(docId: "doc-a", statements: []), .piece("doc-a"),
                       "a translation's document id resolves to its piece, never .translation")
        let hand = store.posture(forDocId: "doc-a")
        XCTAssertEqual(hand.yieldingTo, "Sam", "premise: the root yields on Sam's piece")
        XCTAssertFalse(hand.allows(.translate),
                       "ruling H: the writer's hand yields on the piece's translation too")

        let translator = DepartmentPaneHost.postureOfTheTranslator(forPiece: "doc-a", in: store)
        XCTAssertNil(translator.yieldingTo)
        XCTAssertTrue(translator.allows(.translate), "the translator is not yielded")
        XCTAssertEqual(
            DepartmentTranslationOffers.decide(
                target: "doc-a", book: ["doc-a", "doc-b"],
                mayTranslate: {
                    DepartmentPaneHost.postureOfTheTranslator(forPiece: $0, in: store)
                        .allows(.translate)
                }),
            .unrestricted, "the root's desk keeps Run over Sam's chapter")
    }

    /// **A reply to a translator's query that the door refuses is SAID**, not
    /// swallowed with the sheet closing as if it worked (ruling Q) — and the
    /// verbs themselves follow the document's and the edition brief's postures.
    func test_aRefusedTranslatorReplyIsSaidAndTheVerbsFollowThePosture() async throws {
        let h = try await makeHarness(prefix: "PostureTranslationReply")
        let query = try await h.doc.addAnnotation(
            kind: .query, paragraphId: h.pid, body: "¿tú o usted?")
        beAReviewer(h.doc)
        var returned: String?
        let said = await notices {
            returned = await TranslationReviewPaneLogic.reply(
                to: query, with: "usted", in: h.doc, undoManager: nil)
        }
        let sentence = try XCTUnwrap(returned, "the refusal comes back")
        XCTAssertEqual(said, [sentence], "and is said to the window")
        XCTAssertEqual(annotation(h.doc, query)?.status, .open, "the query still stands")

        h.doc.stamp(localWritePermit: .unrestricted)
        let accepted = await TranslationReviewPaneLogic.reply(
            to: query, with: "usted", in: h.doc, undoManager: nil)
        XCTAssertNil(accepted, "promotion: the reply files")
        XCTAssertEqual(annotation(h.doc, query)?.status, .accepted)

        // The verbs, pure: a reviewer answers nothing; an author of A answers
        // A's translator but files no edition-brief ruling (a project
        // statement); the book author does everything.
        let none = TranslationAuthorVerbs.decide(document: reviewer, editionBrief: reviewer)
        XCTAssertFalse(none.answer)
        XCTAssertFalse(none.answerAsRuling)
        XCTAssertFalse(none.rule)
        XCTAssertFalse(none.sideWithTheNote(hasQuery: false))
        let pieces = TranslationAuthorVerbs.decide(
            document: piecesAuthorInA, editionBrief: piecesAuthorOnTheLedger)
        XCTAssertTrue(pieces.answer)
        XCTAssertFalse(pieces.answerAsRuling)
        XCTAssertFalse(pieces.rule)
        XCTAssertFalse(pieces.sideWithTheNote(hasQuery: true))
        XCTAssertEqual(TranslationAuthorVerbs.decide(document: bookAuthor, editionBrief: bookAuthor),
                       .unrestricted)
        let ruleOnly = TranslationAuthorVerbs.decide(
            document: piecesAuthorInB, editionBrief: bookAuthor)
        XCTAssertTrue(ruleOnly.sideWithTheNote(hasQuery: false), "a ruling with no reply to file")
        XCTAssertFalse(ruleOnly.sideWithTheNote(hasQuery: true),
                       "never a ruling whose reply the door would then refuse")
    }

    // MARK: - Task 8 fix round

    /// **The desk's own acting door** (review I1; ruling I): `run`/`runBook`
    /// start a round only over the pieces the translator's SETTLED posture
    /// allows, and name the rest — windowless, nothing pressed (tripwire 33).
    func test_theDesksActingDoorStartsOnlyWhatItsTranslatorMay() async throws {
        let h = try await makeStatementHarness()
        let structure = h.store.manifest.structure
        func start(_ ids: [String]) async -> (started: [[String]], notice: String?) {
            var started: [[String]] = []
            let notice = await DepartmentPaneHost.startTranslating(
                ids, in: h.documentStore, structure: structure) { started.append($0) }
            return (started, notice)
        }

        try await become(.author(.pieces(["doc-a"])), h)
        let refused = await start(["doc-b"])
        XCTAssertEqual(refused.started, [], "a refused piece starts nothing")
        XCTAssertEqual(refused.notice, DepartmentPaneHost.notTranslatable(titles: ["B"]),
                       "and is named")
        let allowed = await start(["doc-a"])
        XCTAssertEqual(allowed.started, [["doc-a"]], "her piece starts")
        XCTAssertNil(allowed.notice)
        let book = await start(["doc-a", "doc-b"])
        XCTAssertEqual(book.started, [["doc-a"]], "the book run leaves B out")
        XCTAssertEqual(book.notice, DepartmentPaneHost.notTranslatable(titles: ["B"]))

        try await become(.reviewer, h)
        let reviewer = await start(["doc-a", "doc-b"])
        XCTAssertEqual(reviewer.started, [], "a reviewer starts nothing")
        XCTAssertEqual(reviewer.notice, DepartmentPaneHost.notTranslatable(titles: ["A", "B"]))

        try await become(.bookAuthor, h)
        let promoted = await start(["doc-a", "doc-b"])
        XCTAssertEqual(promoted.started, [["doc-a", "doc-b"]], "promotion: the whole book runs")
        XCTAssertNil(promoted.notice)
    }

    /// **The File menu's piece items follow `.startAPiece`** (ruling X):
    /// disabled where the focused window says no, and a post that arrives
    /// anyway is refused at the receiver, in words.
    func test_theFileMenusPieceItemsFollowStartAPieceAndTheReceiverRefuses() async throws {
        XCTAssertTrue(StartAPieceDoor.menuIsEnabled(mayStartAPiece: nil),
                      "no project window in front: as before")
        XCTAssertTrue(StartAPieceDoor.menuIsEnabled(mayStartAPiece: true))
        XCTAssertFalse(StartAPieceDoor.menuIsEnabled(mayStartAPiece: false))

        let h = try await makeStatementHarness()
        XCTAssertEqual(StartAPieceDoor.drawn(store: h.store), true)
        let admittedAsAuthor = await StartAPieceDoor.admits(store: h.store)
        XCTAssertTrue(admittedAsAuthor)

        try await become(.author(.pieces(["doc-a"])), h)
        XCTAssertEqual(StartAPieceDoor.drawn(store: h.store), false, "R3: not hers to start")
        var admitted = true
        let said = await notices { admitted = await StartAPieceDoor.admits(store: h.store) }
        XCTAssertFalse(admitted, "the receiver refuses a post that arrives anyway")
        XCTAssertEqual(said, [StartAPieceDoor.refusal], "and says so")

        try await become(.reviewer, h)
        XCTAssertEqual(StartAPieceDoor.drawn(store: h.store), false)

        try await become(.bookAuthor, h)
        XCTAssertEqual(StartAPieceDoor.drawn(store: h.store), true, "promotion: enabled again")
        let saidAfter = await notices { admitted = await StartAPieceDoor.admits(store: h.store) }
        XCTAssertTrue(admitted)
        XCTAssertEqual(saidAfter, [])
    }
}
