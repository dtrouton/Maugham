import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The board counts a figure's notes on the piece that owns it** (report
/// plan 9c-1 Task 7, ruling: `FigureRecord.piece`): a chapter's open-notes
/// count includes the open notes on its tables; a whole-book figure's notes
/// count on no piece (they stay in the project queue); no count is keyed by a
/// figure's id. The walk also reads each figure suggestion's cells as text,
/// for the queue's row (`ProjectAnnotationsSnapshot.figureCells`).
@MainActor
final class OpenNotesFigureCountTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("fignote-count-\(UUID().uuidString)")
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

    // MARK: - Fixture

    /// A book of two chapters with a window over it.
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
            await doc.close()
        }
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private var assistantDevice: String { Document.loadIdentities[.assistant].deviceId }
    private let claude = AnnotationAuthor(sourceKind: .claude, displayName: "Claude")

    /// The assistant notes `kind` on figure `figure`'s first cell (a
    /// suggestion proposes `suggested` there).
    @discardableResult
    private func note(
        _ kind: AnnotationKind, on figure: FigureRecord, store: DocumentStore,
        suggested: Cell? = nil
    ) async throws -> Op {
        let table = try await store.withFigureHost(figure.id) { $0.state.table }
        let key = CellKey(row: table.rows[0], column: table.columns[0])
        let op = try FigureAnnotationOps.creation(
            kind: kind, anchor: FigureCellAnchor(row: key.row, column: key.column),
            body: "Look", suggestedCell: suggested, prior: table[key], author: claude,
            stamp: .init(figureId: figure.id, device: assistantDevice))
        try await store.addFigureAnnotation(op)
        return op
    }

    // MARK: - Tests

    /// A piece-owned figure's open notes count on that piece; a whole-book
    /// figure's count nowhere; a figure's id keys no count; a settled note
    /// counts nowhere.
    func test_aFiguresOpenNotesCountOnItsPiece_andAWholeBookFiguresNowhere() async throws {
        let (store, projectStore) = try await openBook()
        let owned = try await projectStore.createFigure(kind: .table, name: "cash", piece: "doc-a")
        let wholeBook = try await projectStore.createFigure(kind: .table, name: "ledger", piece: nil)
        try await note(.comment, on: owned, store: store)
        let settled = try await note(.query, on: owned, store: store)
        try await note(.comment, on: wholeBook, store: store)
        try await store.withFigureHost(owned.id) { try await $0.archiveAnnotation(id: settled.opId) }

        let summaries = projectStore.openNotesSummaries()

        XCTAssertEqual(summaries["doc-a"]?.total, 1, "the owned figure's one open note counts on its piece")
        XCTAssertNil(summaries["doc-b"], "a piece owning no annotated figure has no count")
        XCTAssertNil(summaries[owned.id], "no count is keyed by a figure's id")
        XCTAssertNil(summaries[wholeBook.id], "a whole-book figure's notes count on no piece")
        XCTAssertEqual(summaries.count, 1)
        // The queue still lists every figure note under its figure.
        let docIds = Set(projectStore.listAnnotationsAcrossProject().annotations.map(\.docId))
        XCTAssertEqual(docIds, [owned.id, wholeBook.id])
    }

    /// The pure rule: a document counts on itself, a figure on its piece, a
    /// whole-book or unregistered figure nowhere.
    func test_countsOn() {
        let owners = ProjectStore.figureNoteOwners([
            FigureRecord(id: "fig-aaaa1111", name: "a", kind: .table, piece: "doc-a", path: "figures/a.csv"),
            FigureRecord(id: "fig-bbbb2222", name: "b", kind: .table, piece: nil, path: "figures/b.csv"),
        ])
        XCTAssertEqual(ProjectStore.countsOn("doc-z", owners: owners), "doc-z")
        XCTAssertEqual(ProjectStore.countsOn("fig-aaaa1111", owners: owners), "doc-a")
        XCTAssertNil(ProjectStore.countsOn("fig-bbbb2222", owners: owners))
        XCTAssertNil(ProjectStore.countsOn("fig-cccc3333", owners: owners))
    }

    /// The walk reads a figure suggestion's cells as text, by note id — the
    /// cell as it stands and the proposal — and nothing for a comment.
    func test_theWalkReadsASuggestionsCellsForTheQueueRow() async throws {
        let (store, projectStore) = try await openBook()
        let figure = try await projectStore.createFigure(kind: .table, name: "cash", piece: "doc-a")
        try await store.withFigureHost(figure.id) { host in
            let a1 = CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
            try await host.setCell(Cell(content: .value(.text("draft"))), at: a1)
        }
        let suggestion = try await note(
            .suggestedChange, on: figure, store: store, suggested: Cell(content: .value(.text("final"))))
        let comment = try await note(.comment, on: figure, store: store)

        let snapshot = projectStore.listAnnotationsAcrossProject()

        XCTAssertEqual(snapshot.figureCells[suggestion.opId], .init(before: "draft", after: "final"))
        XCTAssertNil(snapshot.figureCells[comment.opId])
        XCTAssertEqual(snapshot.annotations.first { $0.annotation.id == suggestion.opId }?.annotation.figureAddress, "A1")
    }
}
