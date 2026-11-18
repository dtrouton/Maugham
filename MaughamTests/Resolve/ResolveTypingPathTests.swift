import XCTest
import MaughamCore
@testable import Maugham

/// **To resolve stays off the typing path** (shell plan 2 final review, C1).
///
/// The list's refresh is the pane's `.task(id: listKey)`: `listKey` → `refreshStep`
/// → `refreshed`. These tests drive that chain exactly as the view does, over a
/// book of closed pieces that hold notes, and count the project walks through
/// the store's own rebuild counters. No mount, no press, no timing assertion.
@MainActor
final class ResolveTypingPathTests: XCTestCase {

    private var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    static let closedCount = 30

    struct Book {
        let doc: Document
        let store: ProjectStore
        let documentStore: DocumentStore
        let closedIds: [String]
    }

    /// One open piece and `closedCount` closed pieces, each closed piece with
    /// one open note in its op log, so a walk miss re-derives every one.
    private func book() async throws -> Book {
        let url = temp.url.appendingPathComponent("TP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        var structure = [StructureItem(id: "doc-open", title: "Open", type: .document,
                                       path: "manuscript/open.md")]
        try Data("Hello.\n\nSecond.".utf8).write(to: url.appendingPathComponent("manuscript/open.md"))
        var closedIds: [String] = []
        for index in 0..<Self.closedCount {
            let id = String(format: "doc-c%02d", index)
            let path = "manuscript/\(id).md"
            try Data("Closed \(index).\n\nMore words here.".utf8).write(to: url.appendingPathComponent(path))
            structure.append(StructureItem(id: id, title: "C\(index)", type: .document, path: path))
            closedIds.append(id)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: structure, research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: url.appendingPathComponent("project.maugham.json"))
        for id in closedIds {
            let doc = try await Document.load(
                url: url.appendingPathComponent("manuscript/\(id).md"), actor: .author,
                session: "boot", presenter: nil)
            let pid = try XCTUnwrap(doc.sequence.first)
            _ = try await doc.addAnnotation(kind: .comment, paragraphId: pid, body: "note on \(id)")
            await doc.close()
        }
        let doc = try await Document.load(
            url: url.appendingPathComponent("manuscript/open.md"), actor: .author,
            session: "s", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        _ = try await doc.addAnnotation(kind: .comment, paragraphId: pid, body: "a note on the open piece")
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        documentStore.projectStore = store
        documentStore.register(document: doc, for: "manuscript/open.md")
        return Book(doc: doc, store: store, documentStore: documentStore, closedIds: closedIds)
    }

    /// The pane's refresh chain, held between calls as the view holds it.
    private final class Pane {
        let book: Book
        let scope: ResolveScope
        var token = 0
        var held: ResolveSnapshot = .empty
        var last: ResolveListKey?
        var walks = ResolveWalkHold()
        private(set) var reads = 0

        init(_ book: Book, scope: ResolveScope) {
            self.book = book
            self.scope = scope
        }

        @MainActor var key: ResolveListKey {
            ResolvePane.listKey(scope: scope, annotationsToken: token, store: book.store,
                                documentStore: book.documentStore, diagnostics: nil,
                                localName: "Me", script: nil)
        }

        /// What `.task(id: listKey)` does when the key moved.
        @MainActor func refresh() {
            let now = key
            guard now != last else { return }
            let step = ResolvePane.refreshStep(now, last: last)
            if step == .read { reads += 1 }
            held = ResolvePane.refreshed(held, step: step, key: now.regroup.read, walks: &walks,
                                         store: book.store, documentStore: book.documentStore,
                                         diagnostics: nil)
            last = now
        }

        /// What the pane's `.maughamAnnotationsChanged` receiver does.
        @MainActor func heard(docId: String) {
            if ResolvePane.annotationsEventMovesTheWalk(docId: docId, documentStore: book.documentStore) {
                token &+= 1
            }
        }

        var noteBodies: [String] {
            held.items.compactMap { if case .note(let n) = $0 { return n.annotation.body } else { return nil } }
        }
    }

    private func counts(_ store: ProjectStore) -> (Int, Int) {
        (store._debugAnnotationsRebuildCount, store._debugTasksRebuildCount)
    }

    // MARK: - C1

    /// Typing (a burst flush), a note minted on the open piece and a verb on
    /// it rebuild neither project aggregate, at the piece, its Part and the
    /// Book; each still reaches the list.
    func test_aNoteOnTheOpenPieceRebuildsNoProjectAggregate() async throws {
        let book = try await book()
        let observer = AnnotationEventRecorder(projectURL: book.store.url)
        for scope in [ResolveScope.piece(docId: "doc-open", includesBookLevel: false),
                      .pieces(docIds: ["doc-open"] + book.closedIds, includesBookLevel: true)] {
            let pane = Pane(book, scope: scope)
            pane.refresh()
            XCTAssertTrue(pane.noteBodies.contains("note on doc-c07") || scope.docIds.count == 1,
                          "\(scope): premise: the closed pieces' notes list at the Book")
            let before = counts(book.store)

            // Typing, then the burst flush.
            book.doc.setFullText("Hello there.\n\nSecond.")
            pane.refresh()
            try await book.doc.flushBurstNow()
            pane.refresh()

            // A note minted on the open piece (a round's arrival, MCP add_note).
            let pid = try XCTUnwrap(book.doc.sequence.first)
            observer.clear()
            let minted = try await book.doc.addAnnotation(kind: .comment, paragraphId: pid,
                                                          body: "minted \(scope.docIds.count)")
            for docId in observer.docIds { pane.heard(docId: docId) }
            pane.refresh()
            XCTAssertTrue(pane.noteBodies.contains("minted \(scope.docIds.count)"),
                          "\(scope): the minted note reaches the list")

            // A verb on the open piece.
            observer.clear()
            try await book.doc.archiveAnnotation(id: minted)
            for docId in observer.docIds { pane.heard(docId: docId) }
            pane.refresh()
            XCTAssertFalse(pane.noteBodies.contains("minted \(scope.docIds.count)"),
                           "\(scope): the archived note leaves the list")

            let after = counts(book.store)
            XCTAssertEqual(after.0, before.0, "\(scope): no annotation walk on the typing path")
            XCTAssertEqual(after.1, before.1, "\(scope): no task walk on the typing path")
        }
    }

    /// A note arriving on a CLOSED piece (its op-log event) still reaches a
    /// Book-scope list: the one signal that runs the walk.
    func test_aNoteOnAClosedPieceStillReachesTheBookList() async throws {
        let book = try await book()
        let pane = Pane(book, scope: .pieces(docIds: ["doc-open"] + book.closedIds, includesBookLevel: true))
        pane.refresh()
        let closedId = book.closedIds[3]
        let doc = try await Document.load(
            url: book.store.url.appendingPathComponent("manuscript/\(closedId).md"), actor: .author,
            session: "peer", presenter: nil)
        let pid = try XCTUnwrap(doc.sequence.first)
        _ = try await doc.addAnnotation(kind: .comment, paragraphId: pid, body: "arrived elsewhere")
        await doc.close()
        XCTAssertFalse(pane.noteBodies.contains("arrived elsewhere"), "premise: not yet heard")

        let walks = book.store._debugAnnotationsRebuildCount
        pane.heard(docId: closedId)
        pane.refresh()
        XCTAssertTrue(pane.noteBodies.contains("arrived elsewhere"), "the closed piece's note reaches the Book")
        XCTAssertEqual(book.store._debugAnnotationsRebuildCount, walks + 1, "by one walk")
    }

    /// A piece opening or closing is a walk signal: once closed, its notes come
    /// from the walk again, never from a stale splice.
    func test_aPieceClosingReadsItsNotesFromTheWalk() async throws {
        let book = try await book()
        let pane = Pane(book, scope: .pieces(docIds: ["doc-open"] + book.closedIds, includesBookLevel: true))
        pane.refresh()
        XCTAssertTrue(pane.noteBodies.contains("a note on the open piece"))
        book.documentStore.unregister(path: "manuscript/open.md")
        await book.doc.close()
        let reads = pane.reads
        pane.refresh()
        XCTAssertEqual(pane.reads, reads + 1, "closing the piece is a read")
        XCTAssertTrue(pane.noteBodies.contains("a note on the open piece"), "its notes still list, from the walk")
    }
}

/// Records `.maughamAnnotationsChanged` posts for one project, synchronously.
@MainActor
final class AnnotationEventRecorder {
    private(set) var docIds: [String] = []
    private var token: NSObjectProtocol?

    init(projectURL: URL) {
        token = NotificationCenter.default.addObserver( // adr-0021-ok: a test's synchronous recorder of what was posted, in post order
            forName: .maughamAnnotationsChanged, object: nil, queue: nil) { [weak self] note in
            guard let docId = note.userInfo?[MaughamEvent.annotationDocIdKey] as? String else { return }
            MainActor.assumeIsolated { self?.docIds.append(docId) }
        }
    }

    func clear() { docIds = [] }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}
