import XCTest
import AppKit
import SwiftUI
@testable import Maugham
@testable import MaughamCore

/// **A Research table in the grid** (report plan 8b Task 7, ruling D8-3): a
/// Research CSV opens in the table figures' grid (`ResearchTableHost` under a
/// `FigureGridController`, mounted by `ResearchTableMount`) and saves back to
/// its file — only on an edit, in its own separator, formulas as `=` cells,
/// the sidecar's hash following, a pinning figure told. Edits go through the
/// controller's own key and bar paths (the grid's delivery); no control is
/// pressed and no click synthesised (tripwire 33).
@MainActor
final class ResearchTableGridTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []
    private var mounts: [ResearchTableMount] = []
    private var windows: [NSWindow] = []

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // the grid styles its cells through production typography
    }

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("researchgrid-\(UUID().uuidString)")
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
        ResearchTableHost.wroteForTesting = nil
        for mount in mounts {
            mount.leave()
            await mount.finishing?.value
        }
        mounts = []
        for window in windows {
            window.contentView = NSView(frame: .zero)
            window.close()
        }
        windows = []
        for store in stores { await store.close() }
        stores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// A novel with one chapter and a window's stores.
    private func openBook() async throws -> (DocumentStore, ProjectStore) {
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
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    /// A Research table made from `text`, the way a writer drags a CSV in.
    private func researchTable(_ name: String, _ text: String, in projectStore: ProjectStore) async throws -> ResearchItem {
        let folder = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let item = try await projectStore.addResearchAsset(parentId: nil, fromURL: url)
        XCTAssertEqual(item.kind, .table, "precondition: a Research table")
        return item
    }

    private func bytes(of item: ResearchItem) throws -> Data {
        try Data(contentsOf: file(try XCTUnwrap(item.path)))
    }

    private func text(of item: ResearchItem) throws -> String {
        try XCTUnwrap(String(data: try bytes(of: item), encoding: .utf8))
    }

    private func key(_ host: any FigureGridHost, _ column: Int, _ row: Int) -> CellKey {
        let table = host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    /// Counts the host's writes.
    private func countWrites() -> () -> Int {
        var count = 0
        ResearchTableHost.wroteForTesting = { _ in count += 1 }
        return { count }
    }

    /// The scheduled save, waited out: its debounce, then its write.
    private func awaitTheSave(_ host: ResearchTableHost) async {
        await host.scheduledSave?.value
        await host.saving?.value
    }

    /// A mounted visit on `item`, opened.
    private func mount(_ item: ResearchItem, _ store: DocumentStore, _ projectStore: ProjectStore,
                       readOnly: Bool = false, shareIsReadOnly: Bool = false) async -> ResearchTableMount {
        let mount = ResearchTableMount(itemId: item.id, readOnly: readOnly, shareIsReadOnly: shareIsReadOnly,
                                       presence: FigureGridPresence())
        mounts.append(mount)
        mount.open(title: item.title, store: store, projectStore: projectStore, typography: .defaults)
        await mount.opening?.value
        return mount
    }

    /// `text` typed into the cell at (`column`, `row`) and committed with
    /// Return, through the controller's key path.
    private func type(_ text: String, at column: Int, _ row: Int, in c: FigureGridController) async {
        c.handle(.click(key(c.host, column, row), extend: false))
        c.handle(.type(String(text.prefix(1))))
        c.handle(.editTextChanged(text))
        c.handle(.returnKey(backward: false))
        await c.settleWrites()
    }

    // MARK: - Writes only on an edit

    /// **Opening reads and writes nothing**: the file's bytes, and no sidecar,
    /// after the open, a flush and the mount leaving.
    func test_openingWritesNothing_evenWhenTheVisitEnds() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("rates.csv", "Name;Rate\nA;1,5\n", in: projectStore)
        let before = try bytes(of: item)
        let writes = countWrites()

        let mount = await mount(item, store, projectStore)
        let host = try XCTUnwrap(mount.host, "the table opened")
        XCTAssertEqual(mount.phase, .open)
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(1.5)), "read as a ';' file reads")
        try await store.flushPendingSave()
        mount.leave()
        await mount.finishing?.value

        XCTAssertEqual(writes(), 0)
        XCTAssertEqual(try bytes(of: item), before, "the file is as it was")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try ResearchTableSidecar.fileURL(forItem: item.id, in: projectURL).path), "and no sidecar was written")
    }

    /// **An edit saves once, after the debounce**: two edits, one write, the
    /// file still a ";" file with a decimal comma and the formula an `=` cell.
    func test_anEditSavesOnceAfterTheDebounce_inTheFilesSeparator_withFormulasAsCells() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("rates.csv", "Name;Rate;Double\nA;1,5;\n", in: projectStore)
        let writes = countWrites()
        let host = try await ResearchTableHost.open(itemId: item.id, store: store)
        host.saveDelay = .milliseconds(50)
        let um = UndoManager()

        try await host.setCell(Cell(content: .value(.number(2.5))), at: key(host, 2, 2), undoManager: um)
        guard case .success(let f) = FormulaParser.parse("B2*2", in: host.state.table) else { return XCTFail() }
        try await host.setCell(Cell(content: .formula(f)), at: key(host, 3, 2), undoManager: um)
        XCTAssertEqual(writes(), 0, "nothing is written before the debounce")
        await awaitTheSave(host)

        XCTAssertEqual(writes(), 1, "two edits, one write")
        let written = try text(of: item)
        XCTAssertEqual(TableCSV.rows(written).separator, ";", "the file keeps its separator: \(written)")
        XCTAssertEqual(TableCSV.rows(written).rows, [["Name", "Rate", "Double"], ["A", "2,5", "=B2*2"]])
        await host.close()
    }

    // MARK: - The sidecar and the pins

    /// **The sidecar's hash follows the new bytes**, and who the table was —
    /// its figure, name and caption — is kept, with its header row.
    func test_theSidecarFollowsTheSave_keepingTheFigureItWasAndItsHeader() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("q3.csv", "Quarter,Revenue\nQ3,10\n", in: projectStore)
        let hash = ContentHash.of(try bytes(of: item))
        try ResearchTableSidecar.write(
            ResearchTableSidecar(figureId: "fig-q3", contentHash: hash, name: "Q3", caption: "Third quarter",
                                 headerRows: 1),
            forItem: item.id, in: projectURL)
        let host = try await ResearchTableHost.open(itemId: item.id, store: store)
        XCTAssertEqual(host.state.table.headerRows, 1, "the sidecar was laid on: it was written for these bytes")

        try await host.setCell(Cell(content: .value(.number(12))), at: key(host, 2, 2), undoManager: nil)
        await host.flush()

        let sidecar = try XCTUnwrap(ResearchTableSidecar.read(forItem: item.id, in: projectURL))
        XCTAssertEqual(sidecar.contentHash, ContentHash.of(try bytes(of: item)), "the hash is the new file's")
        XCTAssertNotEqual(sidecar.contentHash, hash)
        XCTAssertEqual([sidecar.figureId, sidecar.name, sidecar.caption], ["fig-q3", "Q3", "Third quarter"])
        XCTAssertEqual(sidecar.headerRows, 1)
        await host.close()
    }

    /// **A figure pinning the table says "changed" once the grid's save
    /// lands**, with no other edit: the save tells the window's cards.
    func test_aFigurePinningTheTableSaysChangedAfterTheSave() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("model.csv", "Year,Revenue\n2025,10\n2026,20\n", in: projectStore)
        let summary = try await projectStore.createFigure(kind: .table, name: "summary", piece: nil)
        let figure = try await store.openFigure(figureId: summary.id)
        guard case .success(let f) = FormulaParser.parse(
            "research:model!B2*2", in: figure.state.table, names: FormulaNames(research: [(item.id, item.title)]))
        else { return XCTFail("the formula did not parse") }
        try await figure.setCell(Cell(content: .formula(f)), at: key(figure, 1, 1))
        let calm = await store.figureCardInputs()
        XCTAssertEqual(calm?.pinChanged, [], "control: nothing changed yet")

        let host = try await ResearchTableHost.open(itemId: item.id, store: store)
        let revision = store.figureRevision
        try await host.setCell(Cell(content: .value(.number(15))), at: key(host, 2, 2), undoManager: nil)
        await host.flush()

        XCTAssertGreaterThan(store.figureRevision, revision, "the save told the cards")
        let after = await store.figureCardInputs()
        XCTAssertEqual(after?.pinChanged, [summary.id], "the pinning figure says changed")
        await host.close()
        await store.closeFigure(figureId: summary.id)
    }

    // MARK: - Undo in the grid, flushed on leaving

    /// **⌘Z and ⇧⌘Z run the grid's own stack**, and leaving the subject
    /// writes what the grid holds — an edit still open in a cell included —
    /// before the debounce would have.
    func test_undoRunsTheGridsStack_andLeavingWritesTheOpenEdit() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("model.csv", "Year,Revenue\n2025,10\n", in: projectStore)
        let writes = countWrites()
        let mount = await mount(item, store, projectStore)
        let c = try XCTUnwrap(mount.controller)
        let host = try XCTUnwrap(mount.host)

        await type("11", at: 2, 2, in: c)
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(11)))
        XCTAssertTrue(c.gridUndo.canUndo, "the edit is on the grid's stack")
        c.undoInGrid()
        await c.settleWrites()
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(10)), "⌘Z put it back")
        c.redoInGrid()
        await c.settleWrites()
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(11)), "⇧⌘Z made it again")

        // Typing left open in A2, then the subject moves on.
        c.handle(.click(key(host, 1, 2), extend: false))
        c.handle(.type("2"))
        c.handle(.editTextChanged("2030"))
        XCTAssertEqual(writes(), 0, "nothing written yet (the debounce is 750 ms)")
        mount.leave()
        await mount.finishing?.value

        XCTAssertEqual(writes(), 1, "leaving wrote once")
        XCTAssertEqual(TableCSV.rows(try text(of: item)).rows, [["Year", "Revenue"], ["2030", "11"]])
        XCTAssertTrue(host.isClosed)
        XCTAssertFalse(store.researchTables.allObjects.contains { $0 === host }, "and the store let it go")
    }

    /// **⌘S (the store's flush) writes a pending edit** — the path the
    /// typed mover's pre-move flush and the store's close at ⌘Q share.
    func test_theStoresFlushWritesAPendingEdit() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("model.csv", "Year,Revenue\n2025,10\n", in: projectStore)
        let host = try await ResearchTableHost.open(itemId: item.id, store: store)
        try await host.setCell(Cell(content: .value(.number(12))), at: key(host, 2, 2), undoManager: nil)
        XCTAssertTrue(host.isDirty)

        try await store.flushPendingSave()

        XCTAssertFalse(host.isDirty)
        XCTAssertEqual(TableCSV.rows(try text(of: item)).rows, [["Year", "Revenue"], ["2025", "12"]])
        await host.close()
    }

    // MARK: - A file that can't be read

    /// **A file that can't be read says so — never an empty grid** (RULING-7's
    /// precedent): a missing file and a folder where the file should be each
    /// leave the mount unreadable with its reason, and nothing is written.
    func test_aFileThatCannotBeReadShowsTheErrorAndNeverAnEmptyGrid() async throws {
        let (store, projectStore) = try await openBook()
        let gone = try await researchTable("gone.csv", "a,b\n1,2\n", in: projectStore)
        try FileManager.default.removeItem(at: file(try XCTUnwrap(gone.path)))
        let folder = try await researchTable("folder.csv", "a,b\n1,2\n", in: projectStore)
        let folderURL = file(try XCTUnwrap(folder.path))
        try FileManager.default.removeItem(at: folderURL)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let writes = countWrites()

        for item in [gone, folder] {
            let mount = await mount(item, store, projectStore)
            guard case .unreadable(let message) = mount.phase else {
                return XCTFail("\(item.title) opened as \(mount.phase)")
            }
            XCTAssertFalse(message.isEmpty)
            XCTAssertNil(mount.controller, "no grid over a file that did not read")
            XCTAssertNil(mount.host)
        }
        XCTAssertEqual(writes(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(try XCTUnwrap(gone.path)).path),
                       "the missing file was not made")
    }

    // MARK: - Read-only

    /// **Review reads the table, never edits it**: the grid opens read-only
    /// with the review reason, typing writes nothing, and the host itself
    /// refuses.
    func test_reviewOpensTheTableReadOnly() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("model.csv", "Year,Revenue\n2025,10\n", in: projectStore)
        let before = try bytes(of: item)
        let mount = await mount(item, store, projectStore, readOnly: !Persona.review.editsResearchInTheCentre)
        let c = try XCTUnwrap(mount.controller)
        let host = try XCTUnwrap(mount.host)
        XCTAssertEqual(c.mode, .readOnly(.reviewMode))

        await type("99", at: 2, 2, in: c)
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(10)), "typing wrote nothing")
        do {
            try await host.setCell(nil, at: key(host, 2, 2), undoManager: nil)
            XCTFail("the host refuses a read-only edit")
        } catch let refused as ResearchTableHost.Refused {
            XCTAssertEqual(refused.reason, .reviewMode)
        }
        mount.leave()
        await mount.finishing?.value
        XCTAssertEqual(try bytes(of: item), before)
    }

    /// **A view-only share reads the table**; the share becoming writable
    /// lets the grid edit (the gate asked again).
    func test_aViewOnlyShareOpensTheTableReadOnly_untilItIsNot() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("model.csv", "Year,Revenue\n2025,10\n", in: projectStore)
        let mount = await mount(item, store, projectStore, shareIsReadOnly: true)
        let c = try XCTUnwrap(mount.controller)
        let host = try XCTUnwrap(mount.host)
        XCTAssertEqual(c.mode, .readOnly(.viewOnlyShare))
        await type("99", at: 2, 2, in: c)
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(10)))

        mount.update(readOnly: false, shareIsReadOnly: false)
        XCTAssertEqual(c.mode, .editable)
        await type("99", at: 2, 2, in: c)
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(99)))
    }

    // MARK: - Not a figure

    /// **The grid offers none of a figure's own commands** over a Research
    /// table: no name or caption field, no ⤢, Send to Research disabled in
    /// Format ▸ Table and the right-click menu, no Refresh from Research, and
    /// a name sent through the bar renames nothing.
    func test_theGridOffersNoFigureCommandOverAResearchTable() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("model.csv", "Year,Revenue\n2025,10\n", in: projectStore)
        let mount = await mount(item, store, projectStore)
        let c = try XCTUnwrap(mount.controller)
        XCTAssertEqual(c.host.offers, .none)

        XCTAssertTrue(c.bars.nameField.isHidden, "no name field")
        XCTAssertTrue(c.bars.captionField.isHidden, "no caption field")
        XCTAssertEqual(c.bars.numberLabel.stringValue, item.title, "the bar names the table")
        var openedAWindow = false
        c.onOpenInWindow = { openedAWindow = true }
        XCTAssertTrue(c.bars.openInWindow.isHidden, "no ⤢, even with a window to open")
        c.perform(.openInWindow)
        XCTAssertFalse(openedAWindow)

        c.handle(.click(key(c.host, 2, 2), extend: false))
        c.researchPiece = "doc-a"
        for destination in FigureResearchDestination.allCases {
            XCTAssertFalse(c.menuState.isEnabled(.sendTo(destination)), "Format ▸ Table: no \(destination) send")
        }
        let menu = c.contextMenu(at: key(c.host, 2, 2))
        let send = try XCTUnwrap(menu.items.first { $0.title == FigureTableMenu.sendToResearchTitle })
        XCTAssertFalse(send.isEnabled, "right-click: Send to Research disabled")
        XCTAssertNil(c.refreshPinsFromResearch(), "no Refresh from Research")

        c.perform(.name("Renamed"))
        await c.settleWrites()
        XCTAssertNil(projectStore.manifest.figures?.first { $0.name == "Renamed" })
        XCTAssertEqual(projectStore.manifest.research.first { $0.id == item.id }?.title, item.title)
    }

    // MARK: - The route

    /// **The centre mounts the grid** for a Research table subject, through
    /// production's `ResearchSubjectCentre` (the route's `.table` arm).
    func test_theCentreMountsTheGridForAResearchTable() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("model.csv", "Year,Revenue\n2025,10\n", in: projectStore)
        XCTAssertEqual(ProjectWindow.researchCentreRoute(id: item.id, in: projectStore.manifest.research),
                       .table(item: item, path: try XCTUnwrap(item.path)))
        let window = TestWindow.mount(
            ResearchSubjectCentre(store: projectStore, documentStore: store, itemID: item.id,
                                  previewVisible: false, readOnly: false),
            size: CGSize(width: 640, height: 420))
        windows.append(window)
        let up = await RunLoopPump.until(deadline: 5) { Self.gridView(in: window.contentView) != nil }
        XCTAssertTrue(up, "the centre's grid mounted")
        let c = try XCTUnwrap(Self.gridView(in: window.contentView)?.delegate as? FigureGridController)
        XCTAssertTrue(c.host is ResearchTableHost)
    }

    /// **Plan's right column shows the same grid** beside the canvas
    /// (`ResearchSubjectInspector`'s preview, through the same route).
    func test_planPreviewsTheTableInTheSameGridBesideTheCanvas() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("model.csv", "Year,Revenue\n2025,10\n", in: projectStore)
        let placement = ProjectWindow.researchSubjectPlacement(persona: .plan, subject: .research(item.id))
        XCTAssertTrue(placement.previewsInTheRightColumn, "precondition: Plan previews beside the canvas")
        let window = TestWindow.mount(
            ResearchSubjectInspector(store: projectStore, itemID: item.id,
                                     showsPreview: placement.previewsInTheRightColumn,
                                     documentStore: store, readOnly: !Persona.plan.editsResearchInTheCentre),
            size: CGSize(width: 420, height: 640))
        windows.append(window)
        let up = await RunLoopPump.until(deadline: 5) { Self.gridView(in: window.contentView) != nil }
        XCTAssertTrue(up, "the right column's grid mounted")
        let c = try XCTUnwrap(Self.gridView(in: window.contentView)?.delegate as? FigureGridController)
        XCTAssertTrue(c.host is ResearchTableHost)
        XCTAssertEqual(c.mode, .editable, "Plan edits Research")
    }

    private static func gridView(in view: NSView?) -> FigureGridView? {
        guard let view else { return nil }
        if let grid = view as? FigureGridView { return grid }
        for sub in view.subviews { if let grid = gridView(in: sub) { return grid } }
        return nil
    }
}
