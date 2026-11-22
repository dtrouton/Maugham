import XCTest
@testable import Maugham
@testable import MaughamCore

/// Shell plan 2, Task 1 fix — **a piece's To resolve notes agree with the
/// review board's open-notes count for that piece**: both read the one walk
/// and file a figure's notes on its owning piece by the same rule
/// (`ProjectStore.figureNoteOwners` + `countsOn`). A real project: a closed
/// chapter with a paragraph note, a table it owns, and a whole-book table.
@MainActor
final class ResolveBoardCountTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("resolve-board-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
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
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    /// Two chapters; `doc-a` gets one open paragraph note, then is closed.
    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        for path in ["manuscript/a.md", "manuscript/b.md"] {
            try "Words.\n".write(to: projectURL.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [
                StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md"),
                StructureItem(id: "doc-b", title: "B", type: .document, path: "manuscript/b.md"),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        for path in ["manuscript/a.md", "manuscript/b.md"] {
            let doc = try await Document.load(
                url: projectURL.appendingPathComponent(path), actor: .author, session: "boot", presenter: nil)
            if path.hasSuffix("a.md"), let pid = doc.sequence.first {
                _ = try await doc.addAnnotation(kind: .comment, paragraphId: pid, body: "paragraph note")
            }
            await doc.close()
        }
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private let claude = AnnotationAuthor(sourceKind: .claude, displayName: "Claude")

    @discardableResult
    private func note(_ kind: AnnotationKind, on figure: FigureRecord, store: DocumentStore) async throws -> Op {
        let table = try await store.withFigureHost(figure.id) { $0.state.table }
        let key = CellKey(row: table.rows[0], column: table.columns[0])
        let op = try FigureAnnotationOps.creation(
            kind: kind, anchor: FigureCellAnchor(row: key.row, column: key.column),
            body: "Look", suggestedCell: nil, prior: table[key], author: claude,
            stamp: .init(figureId: figure.id, device: Document.loadIdentities[.assistant].deviceId))
        try await store.addFigureAnnotation(op)
        return op
    }

    func test_aPiecesNoteCountEqualsTheBoardsCount() async throws {
        let (store, projectStore) = try await openBook()
        let owned = try await projectStore.createFigure(kind: .table, name: "cash", piece: "doc-a")
        let wholeBook = try await projectStore.createFigure(kind: .table, name: "ledger", piece: nil)
        try await note(.comment, on: owned, store: store)
        let settled = try await note(.query, on: owned, store: store)
        try await note(.comment, on: wholeBook, store: store)
        try await store.withFigureHost(owned.id) { try await $0.archiveAnnotation(id: settled.opId) }

        let board = projectStore.openNotesSummaries()
        let read = ResolveReader.read(scope: .piece(docId: "doc-a", includesBookLevel: false), store: projectStore,
                                      documentStore: store, diagnostics: nil, figureChanges: [])
        let notes = read.items.filter { if case .note = $0 { return true } else { return false } }

        XCTAssertEqual(board["doc-a"]?.total, 2, "premise: the board counts the paragraph note and the table's")
        XCTAssertEqual(notes.count, board["doc-a"]?.total, "To resolve agrees with the board")
        XCTAssertEqual(notes.map(\.docId), ["doc-a", owned.id], "the paragraph note first, then the table's")
        XCTAssertFalse(notes.contains { $0.docId == wholeBook.id }, "a whole-book table stays at Book scope")
        XCTAssertNil(store.document(forDocId: "doc-a"), "reading registered no document")
    }

    /// **Review I2 (RULING-29).** A stetted note on a table can be reopened:
    /// it is settled at the figure's own scope and at its owning piece's, its
    /// row offers Reopen by the figure's posture, and the figure verb lands.
    func test_aSettledFigureNoteIsReopenableAtItsFigureAndItsPiece() async throws {
        let (store, projectStore) = try await openBook()
        let owned = try await projectStore.createFigure(kind: .table, name: "cash", piece: "doc-a")
        let op = try await note(.comment, on: owned, store: store)
        try await store.withFigureHost(owned.id) { try await $0.stetAnnotation(id: op.opId) }
        let owners = ProjectStore.figureNoteOwners(projectStore.manifest.figures ?? [])
        let walk = projectStore.listAnnotationsAcrossProject()

        for scope in [ResolveScope.figure(id: owned.id), .piece(docId: "doc-a", includesBookLevel: false)] {
            XCTAssertTrue(ResolveSettled.offersFigures(scope: scope), "\(scope)")
            XCTAssertEqual(ResolveSettled.figureNotes(in: walk, scope: scope, figureOwners: owners)
                            .map(\.annotation.id), [op.opId], "\(scope): the stetted note is settled here")
        }
        XCTAssertEqual(ResolveSettled.figureNotes(in: walk, scope: .piece(docId: "doc-b", includesBookLevel: false),
                                                  figureOwners: owners), [], "not on a piece that does not own it")
        XCTAssertFalse(ResolveSettled.offersFigures(scope: .pieces(docIds: ["doc-a"], includesBookLevel: true)))
        XCTAssertEqual(ResolveFigureSettledSection.title(for: .figure(id: owned.id)), "Settled")
        XCTAssertEqual(ResolveFigureSettledSection.title(for: .piece(docId: "doc-a", includesBookLevel: false)),
                       "Settled on its figures")

        let posture = store.posture(forDocId: owned.id)
        let offered = FigureRowGate.verbs(AnnotationRowVerbs.decide(
            posture: posture, isOwn: false, rulingStatement: nil, lessons: posture))
        XCTAssertTrue(offered.dispose, "Reopen is offered (the dispose group on a settled row)")

        let verbs = ResolveNoteVerbs(
            store: projectStore, documentStore: store, world: nil,
            userPreferences: UserPreferences(defaults: UserDefaults(suiteName: "figsettled-\(UUID().uuidString)")!),
            undoManager: nil, onChoiceOfferChanged: { _ in },
            projectSnapshot: { projectStore.listAnnotationsAcrossProject() },
            visibleAnnotations: { _ in [] }, effectiveSelection: { _ in [] },
            staleConfirm: .constant(nil), anchorLostNotice: .constant(nil),
            revertConfirm: .constant(nil), rulingNotice: .constant(nil),
            ledgerNotice: .constant(nil), choiceOffer: .constant(nil),
            stetFlourishIds: .constant([]), bulkInFlight: .constant(false),
            selectedIds: .constant([]), bulkNotice: .constant(nil),
            letterLedgerRevision: .constant(0), projectRefreshToken: .constant(0))
        let settled = try XCTUnwrap(walk.annotations.first { $0.annotation.id == op.opId })
        await verbs.figureReopen(owned.id, settled.annotation).value
        let after = projectStore.listAnnotationsAcrossProject()
        XCTAssertEqual(after.annotations.first { $0.annotation.id == op.opId }?.annotation.status, .open,
                       "Reopen lands through the figure's host")
        XCTAssertEqual(ResolveSettled.figureNotes(in: after, scope: .figure(id: owned.id), figureOwners: owners), [])
    }
}
