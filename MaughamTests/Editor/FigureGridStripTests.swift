import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **The strip acts** (report plan 9c-2 Task 6): Accept, Got it and Reject
/// from the strip go through the grid controller's verbs — in turn behind
/// every write asked before, an open cell edit committed first, each on the
/// grid's own `gridUndo`. A suggestion whose cell changed since asks first;
/// Reject asks for a reason. Both questions are value seams here — no alert
/// or sheet is shown — and no control is pressed (tripwire 33): the tests
/// call the controller's verbs and await its writes.
@MainActor
final class FigureGridStripTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var projectURL: URL!
    private var window: NSWindow?
    private var controllers: [FigureGridController] = []
    private var stores: [DocumentStore] = []
    private var projectStore: ProjectStore?

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("gridstrip-\(UUID().uuidString)")
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

    /// A book with one chapter, a window's stores, and the visit on a 4×3
    /// table figure, its grid mounted in a key window. The questions answer
    /// "no" and "cancel" unless a test says otherwise, and fail if asked.
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
        let record = try await projectStore.createFigure(kind: .table, name: "t", piece: nil, rows: 4, columns: 3)
        let controller = try await FigureGridController.open(
            figureId: record.id, store: store, projectStore: projectStore, typography: .defaults,
            line: .init(number: "Table 1", caption: "", commitCaption: { _ in true }))
        controllers.append(controller)
        controller.askChangedSince = { _ in
            XCTFail("the changed-since question was asked unexpectedly")
            return false
        }
        controller.askRejectReason = { _ in
            XCTFail("the reject reason was asked unexpectedly")
            return .cancel
        }
        await store.awaitOpenFigureRenderForTesting()
        let grid = controller.gridView
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 520, height: 360))
        grid.frame = CGRect(x: 0, y: 0, width: 520,
                            height: FigureGridLayout.viewportHeight(rows: 4, rowHeight: grid.rowHeight))
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

    private func number(_ n: Double) -> Cell { Cell(content: .value(.number(n))) }

    /// The assistant suggests `cell` for `key` (recording what the cell holds
    /// now), as `suggest_figure_cell` builds it; answers the note's id.
    private func suggest(_ cell: Cell?, at key: CellKey, store: DocumentStore, host: FigureDocument) async throws -> String {
        let op = try FigureAnnotationOps.creation(
            kind: .suggestedChange, anchor: FigureCellAnchor(row: key.row, column: key.column),
            body: "Should be different", suggestedCell: cell, prior: host.state.table[key],
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: host.figureId, device: Document.loadIdentities[.assistant].deviceId))
        try await store.addFigureAnnotation(op)
        return op.opId
    }

    private func comment(on key: CellKey, store: DocumentStore, host: FigureDocument) async throws -> String {
        let op = try FigureAnnotationOps.creation(
            kind: .comment, anchor: FigureCellAnchor(row: key.row, column: key.column),
            body: "Check this", author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: host.figureId, device: Document.loadIdentities[.assistant].deviceId))
        try await store.addFigureAnnotation(op)
        return op.opId
    }

    private func status(_ id: String, _ host: FigureDocument) -> AnnotationStatus? {
        host.annotations().first { $0.id == id }?.status
    }

    /// The controller's writes landed and its catch-up with the host run.
    private func landed(_ c: FigureGridController) async {
        await c.settleWrites()
        await c.host.awaitPendingUndoWork()
        await c.hostSync?.value
    }

    private func notices(during body: () async throws -> Void) async rethrows -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let message = note.userInfo?[MaughamEvent.noticeMessageKey] as? String { seen.append(message) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    // MARK: - Accept

    /// **Accept writes the cell and resolves the note** — one `claudeAccept`
    /// by this Mac's author carrying the note's id — and the strip empties;
    /// ⌘Z in the grid puts the cell back and reopens the note, which the
    /// strip shows again.
    func test_acceptWritesTheCellAndResolves_andTheGridsUndoRestoresAndReopens() async throws {
        let (store, c, host) = try await openGrid()
        let b2 = key(host, "B2")
        try await host.setCell(number(12), at: b2)
        let id = try await suggest(number(14), at: b2, store: store, host: host)
        await landed(c)
        c.handle(.click(b2, extend: false))
        XCTAssertEqual(c.stripPlan.entries.first?.change, "12 \u{2192} 14", "premise: the strip shows it")

        c.stripAccept(id)
        await landed(c)

        XCTAssertEqual(host.state.table[b2], number(14), "the cell is written")
        XCTAssertEqual(status(id, host), .accepted)
        XCTAssertEqual(c.stripPlan, .empty, "no open note on the cell")
        XCTAssertEqual(c.gridUndo.undoActionName, "Accept Suggestion", "on the grid's own stack")

        c.undoInGrid()
        await landed(c)
        XCTAssertEqual(host.state.table[b2], number(12), "⌘Z put the cell back")
        XCTAssertEqual(status(id, host), .open, "and reopened the note")
        XCTAssertEqual(c.stripPlan.entries.map(\.noteId), [id], "the strip shows it again")
    }

    /// **The cell changed since the suggestion: Accept asks.** No writes
    /// nothing; yes accepts over the change.
    func test_aChangedCellAsks_declineWritesNothing_confirmWrites() async throws {
        let (store, c, host) = try await openGrid()
        let b2 = key(host, "B2")
        try await host.setCell(number(12), at: b2)
        let id = try await suggest(number(14), at: b2, store: store, host: host)
        try await host.setCell(number(13), at: b2)
        await landed(c)
        c.handle(.click(b2, extend: false))

        var asked: [FigureGridStrip.ChangedQuestion] = []
        c.askChangedSince = { asked.append($0); return false }
        c.stripAccept(id)
        await landed(c)
        XCTAssertEqual(asked.count, 1, "asked once")
        XCTAssertEqual(asked.first, FigureGridStrip.ChangedQuestion(address: "B2", now: "13", after: "14"))
        XCTAssertEqual(host.state.table[b2], number(13), "declining writes nothing")
        XCTAssertEqual(status(id, host), .open)
        XCTAssertFalse(c.gridUndo.canUndo && c.gridUndo.undoActionName == "Accept Suggestion")

        c.askChangedSince = { asked.append($0); return true }
        c.stripAccept(id)
        await landed(c)
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(host.state.table[b2], number(14), "confirming accepts over the change")
        XCTAssertEqual(status(id, host), .accepted)
    }

    /// **A strip verb commits the open cell edit first**, in turn: the typed
    /// value lands, then the answer.
    func test_aStripVerbCommitsTheOpenCellEditFirst() async throws {
        let (store, c, host) = try await openGrid()
        let id = try await comment(on: key(host, "A1"), store: store, host: host)
        await landed(c)
        let c3 = key(host, "C3")
        c.handle(.click(c3, extend: false))
        c.handle(.type("5"))
        c.handle(.editTextChanged("5"))
        guard case .editing = c.model.edit else { return XCTFail("premise: an edit is open") }

        c.stripGotIt(id)
        await landed(c)
        XCTAssertEqual(c.model.edit, .idle)
        XCTAssertEqual(host.state.table[c3]?.content, .value(.number(5)), "the open edit was committed")
        XCTAssertEqual(status(id, host), .accepted)
    }

    // MARK: - Got it and Reject

    /// **Got it resolves a comment** (status only, no cell); ⌘Z reopens it.
    func test_gotItResolvesAComment_andTheGridsUndoReopensIt() async throws {
        let (store, c, host) = try await openGrid()
        let id = try await comment(on: key(host, "B3"), store: store, host: host)
        await landed(c)
        let table = host.state.table

        c.stripGotIt(id)
        await landed(c)
        XCTAssertEqual(status(id, host), .accepted)
        XCTAssertEqual(host.state.table, table, "no cell moved")

        c.undoInGrid()
        await landed(c)
        XCTAssertEqual(status(id, host), .open)
    }

    /// **Reject keeps its reason**: the sheet's answer is what is kept; a
    /// cancelled sheet rejects nothing.
    func test_rejectKeepsTheReasonTheSheetGave_cancelRejectsNothing() async throws {
        let (store, c, host) = try await openGrid()
        let b2 = key(host, "B2")
        let suggestion = try await suggest(number(9), at: b2, store: store, host: host)
        let note = try await comment(on: key(host, "C1"), store: store, host: host)
        await landed(c)

        var asked: [FigureGridStrip.RejectQuestion] = []
        c.askRejectReason = { asked.append($0); return .cancel }
        await c.askToReject(note).value
        await landed(c)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(status(note, host), .open, "a cancelled sheet rejects nothing")

        c.askRejectReason = { asked.append($0); return .reject(reason: "Wrong year") }
        await c.askToReject(suggestion).value
        await landed(c)
        XCTAssertEqual(status(suggestion, host), .rejected)
        XCTAssertEqual(host.annotations().first { $0.id == suggestion }?.userResponse, "Wrong year")
        XCTAssertNil(host.state.table[b2], "a reject moves no cell")

        c.stripReject(note, reason: nil)
        await landed(c)
        XCTAssertEqual(status(note, host), .rejected)
        XCTAssertEqual(c.gridUndo.undoActionName, "Reject Annotation", "on the grid's stack")
    }

    // MARK: - Refusals

    /// **A refusal is said as a sentence**: a second Accept of an accepted
    /// suggestion is refused by the host, said, and writes nothing.
    func test_aRefusedAnswerIsSaidAsASentence() async throws {
        let (store, c, host) = try await openGrid()
        let b2 = key(host, "B2")
        let id = try await suggest(number(4), at: b2, store: store, host: host)
        await landed(c)
        c.stripAccept(id)
        await landed(c)
        let table = host.state.table

        let said = await notices {
            c.stripAccept(id)
            await landed(c)
        }
        XCTAssertEqual(said, [FigureNoteError.notOpen.errorDescription!])
        XCTAssertEqual(host.state.table, table)
    }
}

/// **The strip in the in-place grid** (report plan 9c-2 Task 6, Review
/// Focus 3): an Accept made from the strip joins the visit, so after the
/// fold ONE ⌘Z on the window's stack puts the cell back and reopens the
/// note; and a figure whose posture refuses opens read-only, the strip's
/// buttons hidden with the reason, its verbs answered with that reason.
@MainActor
final class FigureGridStripInPlaceTests: FigureGridMountedTestCase {

    override func setUp() async throws {
        try await super.setUp()
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: temp.url.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: temp.url.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: temp.url.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        try await super.tearDown()
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
    }

    private func expanded(_ m: Mounted) async throws -> FigureGridController {
        XCTAssertTrue(m.coordinator.expandFigureGrid(lineAt: location(m, "![Cash](")))
        let grid = try await opened(m)
        let c = try XCTUnwrap(grid.controller)
        c.askChangedSince = { _ in
            XCTFail("the changed-since question was asked unexpectedly")
            return false
        }
        return c
    }

    private func suggest(_ cell: Cell?, at key: CellKey, on m: Mounted, host: any FigureGridHost) async throws -> String {
        let op = try FigureAnnotationOps.creation(
            kind: .suggestedChange, anchor: FigureCellAnchor(row: key.row, column: key.column),
            body: "Should be 42", suggestedCell: cell, prior: host.state.table[key],
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"),
            stamp: .init(figureId: host.figureId, device: Document.loadIdentities[.assistant].deviceId))
        try await XCTUnwrap(m.store.documentStore).addFigureAnnotation(op)
        return op.opId
    }

    private func status(_ id: String, _ host: any FigureGridHost) throws -> AnnotationStatus? {
        try XCTUnwrap(host as? FigureDocument).annotations().first { $0.id == id }?.status
    }

    /// **Review Focus 3**: Accept from the strip, fold, ⌘Z in the window —
    /// the cell reverts and the note reopens in one step.
    func test_reviewFocus3_aStripAcceptFoldedIsTakenBackByTheWindowsOneStep() async throws {
        let m = try await mount(rows: 4)
        let undo = try XCTUnwrap(m.textView.undoManager)
        let c = try await expanded(m)
        let table = c.host.state.table
        let b2 = CellKey(row: table.rows[1], column: table.columns[1])
        let id = try await suggest(Cell(content: .value(.number(42))), at: b2, on: m, host: c.host)
        await c.hostSync?.value
        c.handle(.click(b2, extend: false))
        XCTAssertEqual(c.stripPlan.entries.map(\.noteId), [id], "premise: the strip shows it")

        c.stripAccept(id)
        await c.settleWrites()
        XCTAssertEqual(c.host.state.table[b2]?.content, .value(.number(42)))
        XCTAssertEqual(try status(id, c.host), .accepted)

        c.perform(.done)
        XCTAssertNil(m.coordinator.figureGrid, "folded")
        await m.coordinator.figureGridFolding?.value
        await m.coordinator.lastFigureVisitStep?.settled?.value
        XCTAssertEqual(undo.undoActionName, FigureVisitUndo.actionName, "one window step for the visit")

        undo.undo()
        await c.host.awaitPendingUndoWork()
        XCTAssertNil(c.host.state.table[b2], "the cell reverted")
        XCTAssertEqual(try status(id, c.host), .open, "and the note reopened, in the same step")
    }

    /// **A refusing posture says why**: a figure in a piece another author
    /// holds opens read-only — the strip still shows the note, its buttons
    /// hidden with the grid's reason, and a strip verb is answered with that
    /// reason and writes nothing. *Edit Anyway* brings the buttons back.
    func test_aRefusingPostureHidesTheButtonsWithTheReason_andTheVerbsWriteNothing() async throws {
        let m = try await mount(rows: 4)
        let ds = try XCTUnwrap(m.store.documentStore)
        let chapter = try XCTUnwrap(m.store.manifest.structure.first?.id)
        // Planted before Sam is admitted: once the root yields, its notes are Sam's to answer.
        let figureId = try XCTUnwrap(m.figure?.id)
        let host = try await ds.openFigure(figureId: figureId)
        let b2 = CellKey(row: host.state.table.rows[1], column: host.state.table.columns[1])
        let id = try await suggest(Cell(content: .value(.number(42))), at: b2, on: m, host: host)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await ds.admit(device: sam.author.fingerprint, label: "Sam", ownName: "Sam\u{2019}s Mac",
                               permit: .author(.pieces([chapter])))
        await ds.postureSettled()

        let c = try await expanded(m)
        await c.hostSync?.value
        XCTAssertEqual(c.mode, .readOnly(.notYours), "premise: read-only")
        XCTAssertFalse(c.notesMayBeAnswered)
        c.handle(.click(b2, extend: false))
        XCTAssertEqual(c.stripPlan.entries.map(\.noteId), [id], "the note is still shown")
        XCTAssertEqual(c.stripPlan.entries.first?.actions, [], "no buttons")
        XCTAssertEqual(c.stripPlan.reason, FigureGridGate.Reason.notYours.sentence)
        XCTAssertTrue(c.strip.acceptButton.isHidden && c.strip.rejectButton.isHidden)
        XCTAssertEqual(c.strip.reasonLabel.stringValue, FigureGridGate.Reason.notYours.sentence)

        let before = c.host.state
        c.stripAccept(id)
        c.stripReject(id, reason: "no")
        await c.settleWrites()
        XCTAssertEqual(c.host.state, before, "nothing written")
        XCTAssertEqual(try status(id, c.host), .open)
        XCTAssertEqual(c.bars.reasonMessage, FigureGridGate.Reason.notYours.sentence, "answered with the reason")

        try ds.overrideYield(docId: chapter)
        await c.postureChange?.value
        XCTAssertTrue(c.notesMayBeAnswered)
        XCTAssertEqual(c.stripPlan.entries.first?.actions,
                       [.init(verb: .accept, isEnabled: true), .init(verb: .reject, isEnabled: true)],
                       "Edit Anyway brings the buttons back")
        XCTAssertNil(c.stripPlan.reason)
    }
}
