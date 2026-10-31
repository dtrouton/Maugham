import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **The grid's dots** (report plan 9c-2 Task 4): the open figure host keeps
/// an observed projection of its open notes on live cells
/// (`FigureDocument.openCellNotes`), rebuilt once per change that can move
/// it and never per draw or per selection; the grid's controller keeps it
/// and marks each note's top-left cell. Driven through the store's and the
/// host's verbs and the controller's key path — no control is pressed
/// (tripwire 33).
@MainActor
final class FigureGridCellNotesTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var projectURL: URL!
    private var projectStore: ProjectStore?
    private var window: NSWindow?
    private var controllers: [FigureGridController] = []
    private var stores: [DocumentStore] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("gridnotes-\(UUID().uuidString)")
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
        for c in controllers {
            await c.settleWrites()
            c.close()
        }
        controllers = []
        for store in stores { await store.close() }
        stores = []
        window?.close()
        window = nil
        projectStore = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// A book with one chapter, a window's stores, and the visit on a 6×3
    /// table figure, its grid mounted in a key window.
    private func openGrid() async throws -> (DocumentStore, FigureGridController, FigureDocument) {
        try "Words.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "A", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        stores.append(store)
        let doc = try await Document.load(
            url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        self.projectStore = projectStore
        let record = try await projectStore.createFigure(kind: .table, name: "t", piece: nil, rows: 6, columns: 3)
        let controller = try await FigureGridController.open(
            figureId: record.id, store: store, projectStore: projectStore, typography: .defaults,
            line: .init(number: "Table 1", caption: "", commitCaption: { _ in true }))
        controllers.append(controller)
        await store.awaitOpenFigureRenderForTesting()
        let grid = controller.gridView
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 520, height: 360))
        grid.frame = CGRect(x: 0, y: 0, width: 520,
                            height: FigureGridLayout.viewportHeight(rows: 6, rowHeight: grid.rowHeight))
        container.addSubview(grid)
        window = TestWindow.make(KeyTestWindow.self, contentRect: container.frame, contentView: container)
        grid.reloadData()
        let host = try XCTUnwrap(controller.host as? FigureDocument)
        return (store, controller, host)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func key(_ host: any FigureGridHost, _ a1: String) -> CellKey {
        let p = A1.parse(a1)!
        let table = host.state.table
        return CellKey(row: table.rows[p.row], column: table.columns[p.column])
    }

    /// The assistant's comment on `key` (to `end`, a range), as `add_figure_comment` builds it.
    private func comment(on key: CellKey, to end: CellKey? = nil, figureId: String) throws -> Op {
        try FigureAnnotationOps.creation(
            kind: .comment,
            anchor: FigureCellAnchor(row: key.row, rowEnd: end?.row, column: key.column, columnEnd: end?.column),
            body: "Check this", author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: figureId, device: Document.loadIdentities[.assistant].deviceId))
    }

    /// The controller's catch-up with the host, landed.
    private func caughtUp(_ c: FigureGridController) async {
        await c.hostSync?.value
    }

    // MARK: - A note lands, a note is answered

    /// **An MCP note landing on an open host marks its cell**, with no change
    /// to the table: the host's projection moves (observed), the controller
    /// catches up and the grid's plan draws one dot in that cell's top-right.
    /// Rejecting it takes the dot away.
    func test_aNoteLandingOnTheOpenHostMarksItsCell_andRejectingItUnmarks() async throws {
        let (store, c, host) = try await openGrid()
        let b2 = key(host, "B2")
        XCTAssertEqual(host.openCellNotes, .none, "premise: no note")
        XCTAssertFalse(c.figureGridIsMarked(b2))
        let stateBefore = host.state

        let note = try comment(on: b2, figureId: host.figureId)
        try await store.addFigureAnnotation(note)
        await caughtUp(c)

        XCTAssertEqual(host.state, stateBefore, "a note changes no table state")
        XCTAssertEqual(host.openCellNotes.marked, [b2])
        XCTAssertTrue(c.figureGridIsMarked(b2), "the grid caught up with a note-only change")
        let plan = try XCTUnwrap(c.gridView.currentPlan())
        let r = try XCTUnwrap(host.state.table.rowIndex(of: b2.row))
        let col = try XCTUnwrap(host.state.table.columnIndex(of: b2.column))
        XCTAssertEqual(plan.marks, [FigureCardDrawing.markRect(inCell: c.gridView.layout.cellFrame(row: r, column: col))],
                       "one dot, in the cell's top-right corner")

        try await host.rejectAnnotation(id: note.opId)
        await caughtUp(c)
        XCTAssertEqual(host.openCellNotes, .none, "the rejected note counts for nothing")
        XCTAssertFalse(c.figureGridIsMarked(b2))
        XCTAssertEqual(try XCTUnwrap(c.gridView.currentPlan()).marks, [])
    }

    /// **A range note's dot sits on its top-left cell** — and only there.
    func test_aRangeNoteMarksItsTopLeftCellOnly() async throws {
        let (store, c, host) = try await openGrid()
        try await store.addFigureAnnotation(
            try comment(on: key(host, "C4"), to: key(host, "B2"), figureId: host.figureId))
        await caughtUp(c)
        XCTAssertTrue(c.figureGridIsMarked(key(host, "B2")))
        for other in ["C4", "B4", "C2", "B3"] {
            XCTAssertFalse(c.figureGridIsMarked(key(host, other)), other)
        }
        XCTAssertEqual(try XCTUnwrap(c.gridView.currentPlan()).marks.count, 1)
    }

    // MARK: - When it is rebuilt

    /// **The projection follows the table**: deleting the note's row unmarks
    /// it (orphaned) with no note line, and the delete's ⌘Z — a compensation
    /// with no note in it — brings the dot back, rebuilt once.
    func test_deletingTheNotesRowUnmarksIt_andItsUndoMarksItAgain() async throws {
        let (store, c, host) = try await openGrid()
        let b3 = key(host, "B3")
        try await store.addFigureAnnotation(try comment(on: b3, figureId: host.figureId))
        await caughtUp(c)
        XCTAssertTrue(c.figureGridIsMarked(b3), "premise")

        let um = UndoManager()
        try await host.deleteRow(b3.row, undoManager: um)
        await caughtUp(c)
        XCTAssertEqual(host.openCellNotes, .none, "its cell is gone: orphaned, no dot")
        XCTAssertFalse(c.figureGridIsMarked(b3))

        let rebuilds = host.openCellNotesRebuildCount
        um.undo()
        await host.awaitPendingUndoWork()
        await caughtUp(c)
        XCTAssertEqual(host.openCellNotes.marked, [b3], "the row revived, the dot is back")
        XCTAssertTrue(c.figureGridIsMarked(b3))
        XCTAssertEqual(host.openCellNotesRebuildCount - rebuilds, 1, "the compensation rebuilt it once")
    }

    /// **Never per draw, per selection or per cell edit**: arrow keys, plans
    /// and a typed value leave the projection as it was, not re-derived.
    func test_selectionDrawsAndCellEditsNeverRebuildTheProjection() async throws {
        let (store, c, host) = try await openGrid()
        try await store.addFigureAnnotation(try comment(on: key(host, "B2"), figureId: host.figureId))
        await caughtUp(c)
        let rebuilds = host.openCellNotesRebuildCount

        c.handle(.click(key(host, "A1"), extend: false))
        for _ in 0..<6 { c.handle(.arrow(.down, extend: false)) }
        for _ in 0..<3 { _ = c.gridView.currentPlan() }
        c.handle(.click(key(host, "C5"), extend: false))
        c.handle(.type("7"))
        c.handle(.editTextChanged("7"))
        c.handle(.returnKey(backward: false))
        await c.settleWrites()
        await caughtUp(c)

        XCTAssertEqual(host.state.table[key(host, "C5")]?.content, .value(.number(7)), "premise: the edit landed")
        XCTAssertEqual(host.openCellNotesRebuildCount, rebuilds, "nothing re-derived the notes")
        XCTAssertTrue(c.figureGridIsMarked(key(host, "B2")))
    }
}
