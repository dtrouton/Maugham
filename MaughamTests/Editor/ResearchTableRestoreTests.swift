import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **A Research table put back to a kept version** (report plan 9d Task 3,
/// spec §10.1's "Restore previous version"): `DocumentStore.restoreResearchTable`
/// reaches the item's host whether or not a grid has it open, and
/// `ResearchTableHost.restore` replaces the whole table as one save through
/// the one door — stamped `.writer`, always keeping the state it replaces,
/// even inside the writer's run. A kept sidecar written for other bytes is
/// never laid on (the review's M6). No control is pressed (tripwire 33).
@MainActor
final class ResearchTableRestoreTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []
    private var mounts: [ResearchTableMount] = []

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // the mounted grid styles its cells through production typography
    }

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("researchrestore-\(UUID().uuidString)")
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
        for observer in noticeObservers { NotificationCenter.default.removeObserver(observer) }
        noticeObservers = []
        for mount in mounts {
            mount.leave()
            await mount.finishing?.value
        }
        mounts = []
        for store in stores { await store.close() }
        stores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

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

    private func researchTable(_ text: String, in projectStore: ProjectStore) async throws -> ResearchItem {
        let folder = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("model.csv")
        try Data(text.utf8).write(to: url)
        let item = try await projectStore.addResearchAsset(parentId: nil, fromURL: url)
        XCTAssertEqual(item.kind, .table, "precondition: a Research table")
        return item
    }

    private func bytes(of item: ResearchItem) throws -> Data {
        try Data(contentsOf: file(try XCTUnwrap(item.path)))
    }

    private func rows(of item: ResearchItem) throws -> [[String]] {
        TableCSV.rows(String(decoding: try bytes(of: item), as: UTF8.self)).rows
    }

    private func versions(of item: ResearchItem) -> [ResearchVersion] {
        ResearchVersionStore(projectURL: projectURL).versions(itemId: item.id)
    }

    private func versionRows(_ version: ResearchVersion) throws -> [[String]] {
        let (data, _) = try ResearchVersionStore(projectURL: projectURL).read(version)
        return TableCSV.rows(String(decoding: data, as: UTF8.self)).rows
    }

    private func key(_ host: any FigureGridHost, _ column: Int, _ row: Int) -> CellKey {
        let table = host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    private func number(_ value: Double) -> Cell { Cell(content: .value(.number(value))) }

    private final class Clock {
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func advance(minutes: Double) { date = date.addingTimeInterval(minutes * 60) }
    }

    private func open(_ item: ResearchItem, _ store: DocumentStore, clock: Clock) async throws -> ResearchTableHost {
        let host = try await store.openResearchTable(itemId: item.id)
        host.now = { clock.date }
        return host
    }

    /// The writer types `value` into B2 and the save lands.
    private func writerSaves(_ value: Double, _ host: ResearchTableHost) async throws {
        try await host.setCell(number(value), at: key(host, 2, 2), undoManager: nil)
        await host.flush()
    }

    private func mount(_ item: ResearchItem, _ store: DocumentStore, _ projectStore: ProjectStore,
                       shareIsReadOnly: Bool = false) async -> ResearchTableMount {
        let mount = ResearchTableMount(itemId: item.id, readOnly: false, shareIsReadOnly: shareIsReadOnly,
                                       presence: FigureGridPresence())
        mounts.append(mount)
        mount.open(title: item.title, store: store, projectStore: projectStore, typography: .defaults)
        await mount.opening?.value
        return mount
    }

    private final class Heard: @unchecked Sendable { var notices: [String] = [] }   // touched on the main actor only
    private var noticeObservers: [NSObjectProtocol] = []

    private func listen() -> Heard {
        let heard = Heard()
        noticeObservers.append(NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let message = note.userInfo?[MaughamEvent.noticeMessageKey] as? String {
                MainActor.assumeIsolated { heard.notices.append(message) }
            }
        })
        return heard
    }

    /// A version of `item` kept by hand: `bytes`, and `sidecar` beside them.
    private func keepByHand(_ text: String, sidecar: ResearchTableSidecar?, of item: ResearchItem,
                            at date: Date) throws -> ResearchVersion {
        try ResearchVersionStore(projectURL: projectURL).keep(
            priorBytes: Data(text.utf8), priorSidecar: sidecar, writtenBy: nil,
            itemId: item.id, device: DeviceIdentity.author.slug, at: date)
    }

    // MARK: - With no grid open

    /// **Restore with no grid open**: the store opens the table for the
    /// restore and lets it go; the file is the version's again, its sidecar
    /// stamped the writer's, and the state it replaced is a version too.
    func test_restoreWithNoGridOpen_putsTheVersionBack_andKeepsWhatItReplaced() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let host = try await open(item, store, clock: Clock())
        try await writerSaves(20, host)
        await store.releaseResearchTable(host)
        XCTAssertNil(store.researchTables[item.id], "precondition: no grid holds the table")
        let before = versions(of: item)
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(try versionRows(before[0]), [["Year", "Revenue"], ["2025", "10"]])

        let outcome = try await store.restoreResearchTable(itemId: item.id, to: before[0], shareIsReadOnly: false)

        XCTAssertEqual(outcome, .whole)
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "10"]], "the version is the file again")
        let after = versions(of: item)
        XCTAssertEqual(after.count, 2, "the restore keeps the state it replaced: \(after)")
        XCTAssertEqual(try versionRows(after[0]), [["Year", "Revenue"], ["2025", "20"]])
        XCTAssertEqual(after[0].writtenBy, .writer, "the replaced bytes were the writer's")
        let sidecar = try XCTUnwrap(ResearchTableSidecar.read(forItem: item.id, in: projectURL))
        XCTAssertEqual(sidecar.writtenBy, .writer, "a restore is the writer's save")
        XCTAssertEqual(sidecar.contentHash, ContentHash.of(try bytes(of: item)))
        XCTAssertNil(store.researchTables[item.id], "the host opened for the restore was let go")
    }

    /// **Restoring inside the writer's run still keeps the replaced state**
    /// (the plan's ruling: every Restore keeps one) — the run's own saves keep
    /// only the state before it — and ends the run: the writer's next save
    /// keeps the restored table.
    func test_restoringInsideAWritersRunKeepsTheReplacedState_andEndsTheRun() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let clock = Clock()
        let host = try await open(item, store, clock: clock)
        clock.advance(minutes: 1)
        try await writerSaves(11, host)
        clock.advance(minutes: 1)
        try await writerSaves(12, host)
        let original = try XCTUnwrap(versions(of: item).first)
        XCTAssertEqual(versions(of: item).count, 1, "control: the run kept one")

        clock.advance(minutes: 1)
        try await host.restore(original)

        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "10"]])
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(10)), "the host holds the version")
        var kept = versions(of: item)
        XCTAssertEqual(kept.count, 2, "kept inside the run: \(kept)")
        XCTAssertEqual(try versionRows(kept[0]), [["Year", "Revenue"], ["2025", "12"]])

        clock.advance(minutes: 1)
        try await writerSaves(13, host)
        kept = versions(of: item)
        XCTAssertEqual(kept.count, 3, "the restore ended the run: \(kept)")
        XCTAssertEqual(try versionRows(kept[0]), [["Year", "Revenue"], ["2025", "10"]])
        await store.releaseResearchTable(host)
    }

    /// **Restore is not on the grid's ⌘Z**: it registers no step, and the
    /// writer's earlier step declines over it rather than taking it back.
    func test_theWritersUndoDoesNotTakeBackARestore() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let host = try await open(item, store, clock: Clock())
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        try await host.setCell(number(11), at: key(host, 2, 2), undoManager: undo)
        undo.endUndoGrouping()
        await host.flush()
        let original = try XCTUnwrap(versions(of: item).first)
        try await host.setCell(number(12), at: key(host, 2, 2), undoManager: nil)
        await host.flush()

        try await host.restore(original)
        undo.undo()
        await host.flush()

        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(10)), "the restored table stays")
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "10"]])
        await store.releaseResearchTable(host)
    }

    // MARK: - With the grid open

    /// **Restore with the grid open in another window**: the grid shows the
    /// restored cells, and the host stays open for it.
    func test_restoreWithTheGridOpenShowsTheRestoredCells() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let mount = await mount(item, store, projectStore)
        let c = try XCTUnwrap(mount.controller)
        let host = try XCTUnwrap(mount.host)
        try await writerSaves(30, host)
        await c.hostSync?.value
        XCTAssertEqual(c.values.value(at: key(host, 2, 2)), .number(30), "control: the grid shows the edit")
        let original = try XCTUnwrap(versions(of: item).first)

        try await store.restoreResearchTable(itemId: item.id, to: original, shareIsReadOnly: false)
        await c.hostSync?.value

        XCTAssertEqual(c.values.value(at: key(host, 2, 2)), .number(10), "the grid shows the restored cell")
        XCTAssertFalse(host.isClosed, "the open grid still holds its host")
        XCTAssertTrue(store.researchTables[item.id] === host)
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "10"]])
    }

    /// **A figure pinning the table says "changed" after a restore**: the
    /// restore is a save, and every save tells the cards.
    func test_aPinnedFigureSaysChangedAfterARestore() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n2026,20\n", in: projectStore)
        let host = try await open(item, store, clock: Clock())
        try await writerSaves(15, host)
        let original = try XCTUnwrap(versions(of: item).first)
        // The pin is made over the table as it is now (15), so it is calm.
        let summary = try await projectStore.createFigure(kind: .table, name: "summary", piece: nil)
        let figure = try await store.openFigure(figureId: summary.id)
        guard case .success(let f) = FormulaParser.parse(
            "research:model!B2*2", in: figure.state.table, names: FormulaNames(research: [(item.id, item.title)]))
        else { return XCTFail("the formula did not parse") }
        try await figure.setCell(Cell(content: .formula(f)), at: key(figure, 1, 1))
        let calm = await store.figureCardInputs()
        XCTAssertEqual(calm?.pinChanged, [], "control: nothing changed since the pin")

        let revision = store.figureRevision
        try await host.restore(original)

        XCTAssertGreaterThan(store.figureRevision, revision, "the restore told the cards")
        let after = await store.figureCardInputs()
        XCTAssertEqual(after?.pinChanged, [summary.id], "the pinning figure says changed")
        await store.releaseResearchTable(host)
        await store.closeFigure(figureId: summary.id)
    }

    // MARK: - The kept sidecar (review M6)

    /// **A kept sidecar is laid on only while it was written for the
    /// version's bytes**: one for these bytes brings the header, total and
    /// widths back (`.whole`); one written for other bytes — the version was
    /// an outside change — brings the cells back alone, as an outside change
    /// reads, and says so (`.cellsOnly`).
    func test_aKeptSidecarForOtherBytesIsNotLaidOn_andIsSaid() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        XCTAssertFalse(host.state.table.hasTotalRow, "precondition")
        let marked = "Year,Revenue\n2025,10\n2026,20\n"
        let styled = ResearchTableSidecar(contentHash: ContentHash.of(Data(marked.utf8)), headerRows: 1,
                                          totalRow: true, columnWidths: [140, nil])
        let matching = try keepByHand(marked, sidecar: styled, of: item,
                                      at: Date(timeIntervalSinceReferenceDate: 700_000_000))
        let outside = "Year,Revenue\n2025,77\n2026,88\n"
        let stale = try keepByHand(outside, sidecar: styled, of: item,
                                   at: Date(timeIntervalSinceReferenceDate: 700_000_100))

        let whole = try await host.restore(matching)
        XCTAssertEqual(whole, .whole)
        XCTAssertTrue(host.state.table.hasTotalRow, "control: a sidecar for these bytes is laid on")
        XCTAssertEqual(host.state.table.columnWidths[host.state.table.columns[0]], 140)
        XCTAssertTrue(heard.notices.filter { $0.contains("weren’t applied") }.isEmpty)

        let cellsOnly = try await host.restore(stale)

        XCTAssertEqual(cellsOnly, .cellsOnly)
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "77"], ["2026", "88"]], "the cells came back")
        XCTAssertFalse(host.state.table.hasTotalRow, "a sidecar for other bytes is not laid on")
        XCTAssertNil(host.state.table.columnWidths[host.state.table.columns[0]])
        let written = try XCTUnwrap(ResearchTableSidecar.read(forItem: item.id, in: projectURL))
        XCTAssertFalse(written.totalRow, "nor written beside the restored bytes")
        XCTAssertEqual(written.contentHash, ContentHash.of(try bytes(of: item)))
        XCTAssertTrue(heard.notices.contains { $0.contains("weren’t applied") }, "and said: \(heard.notices)")
        await store.releaseResearchTable(host)
    }

    /// **A restore whose save does not land leaves the table as it was**
    /// (`NotSaved`): the host holds what is on disk, nothing to save.
    func test_aRestoreThatCannotSaveLeavesTheTableAsItWas() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let host = try await open(item, store, clock: Clock())
        try await writerSaves(20, host)
        let original = try XCTUnwrap(versions(of: item).first)
        let before = (host.state.table, try bytes(of: item))
        let folder = file(try XCTUnwrap(item.path)).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        do {
            try await host.restore(original)
            XCTFail("the restore should not have been made")
        } catch is ResearchTableHost.NotSaved {}

        XCTAssertEqual(host.state.table, before.0, "the table is as it was")
        XCTAssertFalse(host.isDirty, "nothing left to save over the file")
        XCTAssertEqual(try bytes(of: item), before.1)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        await store.releaseResearchTable(host)
        XCTAssertEqual(try bytes(of: item), before.1, "the close wrote nothing")
    }

    // MARK: - Refusals

    /// **A view-only share refuses a restore**, with or without a grid open:
    /// nothing written, nothing kept.
    func test_aViewOnlyShareRefusesARestore() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let host = try await open(item, store, clock: Clock())
        try await writerSaves(20, host)
        await store.releaseResearchTable(host)
        let original = try XCTUnwrap(versions(of: item).first)
        let before = try bytes(of: item)

        do {
            try await store.restoreResearchTable(itemId: item.id, to: original, shareIsReadOnly: true)
            XCTFail("a view-only share refuses the restore")
        } catch let refused as ResearchTableHost.Refused {
            XCTAssertEqual(refused.reason, .viewOnlyShare)
        }
        let mount = await mount(item, store, projectStore, shareIsReadOnly: true)
        let shared = try XCTUnwrap(mount.host)
        do {
            try await shared.restore(original)
            XCTFail("the shared host refuses under a view-only share")
        } catch let refused as ResearchTableHost.Refused {
            XCTAssertEqual(refused.reason, .viewOnlyShare)
        }

        XCTAssertEqual(try bytes(of: item), before, "nothing written")
        XCTAssertEqual(versions(of: item).count, 1, "nothing kept")
    }
}
