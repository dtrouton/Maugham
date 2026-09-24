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
}
