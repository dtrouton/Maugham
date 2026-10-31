import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Every save of a Research table keeps the previous version** (report plan
/// 9d Task 2, spec §10.1): `ResearchTableHost.write(_:by:)` — the one door —
/// keeps the bytes on disk before each save, a writer's run keeping one
/// (`ResearchSaveRun`), every assistant save one, an outside change the one
/// kept. The run rule's clock is the host's `now`, never the wall.
@MainActor
final class ResearchTableVersionTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []
    private var lockedFolders: [URL] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("researchversions-\(UUID().uuidString)")
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
        for folder in lockedFolders {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        lockedFolders = []
        ResearchTableHost.wroteForTesting = nil
        for observer in noticeObservers { NotificationCenter.default.removeObserver(observer) }
        noticeObservers = []
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

    private func key(_ host: ResearchTableHost, _ column: Int, _ row: Int) -> CellKey {
        let table = host.state.table
        return CellKey(row: table.rows[row - 1], column: table.columns[column - 1])
    }

    private func number(_ value: Double) -> Cell { Cell(content: .value(.number(value))) }

    /// A host whose run-rule clock is `clock`'s.
    private func open(_ item: ResearchItem, _ store: DocumentStore, clock: Clock) async throws -> ResearchTableHost {
        let host = try await store.openResearchTable(itemId: item.id)
        host.now = { clock.date }
        return host
    }

    private final class Clock {
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func advance(minutes: Double) { date = date.addingTimeInterval(minutes * 60) }
    }

    /// The writer types `value` into B2 and the save lands.
    private func writerSaves(_ value: Double, _ host: ResearchTableHost) async throws {
        try await host.setCell(number(value), at: key(host, 2, 2), undoManager: nil)
        await host.flush()
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

    /// `folder` made read-only until the test ends (a save into it fails).
    private func lock(_ folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        lockedFolders.append(folder)
    }

    private func unlock(_ folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        lockedFolders.removeAll { $0 == folder }
    }

    // MARK: - Review Focus 1: a run keeps one, an assistant write one

    /// **Twenty minutes of typing, then the assistant writes**: one version
    /// from before the run (the imported file, no author said), one from
    /// before the assistant's write (the writer's bytes, marked so) — not
    /// twenty. The writer's next save keeps the assistant's bytes, marked
    /// assistant.
    func test_aWritersRunKeepsOneVersion_andAnAssistantWriteKeepsOneMarkedByThePriorAuthor() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let clock = Clock()
        let host = try await open(item, store, clock: clock)

        for minute in 1...20 {
            clock.advance(minutes: 1)
            try await writerSaves(Double(minute), host)
        }
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "20"]], "every save landed")
        var kept = versions(of: item)
        XCTAssertEqual(kept.count, 1, "a run keeps one version, the state before it: \(kept)")
        XCTAssertEqual(try versionRows(kept[0]), [["Year", "Revenue"], ["2025", "10"]])
        XCTAssertNil(kept[0].writtenBy, "the imported file's sidecar names no author")

        clock.advance(minutes: 1)
        try await host.assistantEdit { table in
            table.setCell(Cell(content: .value(.number(99))), at: CellKey(row: table.rows[1], column: table.columns[1]))
        }
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "99"]])
        kept = versions(of: item)
        XCTAssertEqual(kept.count, 2, "the assistant's write keeps one: \(kept)")
        XCTAssertEqual(kept[0].writtenBy, .writer, "the version before the assistant's write is the writer's bytes")
        XCTAssertEqual(try versionRows(kept[0]), [["Year", "Revenue"], ["2025", "20"]])
        let (_, keptSidecar) = try ResearchVersionStore(projectURL: projectURL).read(kept[0])
        XCTAssertEqual(keptSidecar?.writtenBy, .writer, "the sidecar that described those bytes is kept with them")
        XCTAssertEqual(try ResearchTableSidecar.read(forItem: item.id, in: projectURL)?.writtenBy, .assistant,
                       "the save stamps its author on the sidecar")

        clock.advance(minutes: 1)
        try await writerSaves(21, host)
        kept = versions(of: item)
        XCTAssertEqual(kept.count, 3, "the assistant's write ended the run: \(kept)")
        XCTAssertEqual(kept[0].writtenBy, .assistant)
        XCTAssertEqual(try versionRows(kept[0]), [["Year", "Revenue"], ["2025", "99"]])
        XCTAssertEqual(try ResearchTableSidecar.read(forItem: item.id, in: projectURL)?.writtenBy, .writer)
        await store.releaseResearchTable(host)
    }

    /// A pause of more than ten minutes begins a new run; exactly ten does not.
    func test_aPauseOverTenMinutesBeginsANewRun() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let clock = Clock()
        let host = try await open(item, store, clock: clock)

        try await writerSaves(11, host)
        clock.advance(minutes: 10)
        try await writerSaves(12, host)
        XCTAssertEqual(versions(of: item).count, 1, "ten minutes is inside the run")
        clock.advance(minutes: 10.5)
        try await writerSaves(13, host)
        let kept = versions(of: item)
        XCTAssertEqual(kept.count, 2, "past ten minutes, a new run: \(kept)")
        XCTAssertEqual(try versionRows(kept[0]), [["Year", "Revenue"], ["2025", "12"]], "the state before the new run")
        await store.releaseResearchTable(host)
    }

    /// The run is one grid session: the table let go and opened again begins another.
    func test_aNewGridSessionBeginsANewRun() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let clock = Clock()
        let first = try await open(item, store, clock: clock)
        try await writerSaves(11, first)
        await store.releaseResearchTable(first)

        clock.advance(minutes: 1)
        let second = try await open(item, store, clock: clock)
        XCTAssertFalse(first === second, "precondition: a new host")
        try await writerSaves(12, second)
        XCTAssertEqual(versions(of: item).count, 2)
        await store.releaseResearchTable(second)
    }

    /// **An assistant edit writes the writer's pending edit first, as the
    /// writer's own save**: the two never share one, so the version before
    /// the assistant's write holds the writer's edit and not the assistant's.
    func test_anAssistantEditWritesTheWritersPendingEditFirst_asItsOwnSave() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue,Cost\n2025,10,1\n", in: projectStore)
        var written: [String] = []
        ResearchTableHost.wroteForTesting = { written.append($0) }
        let host = try await open(item, store, clock: Clock())
        host.saveDelay = .seconds(600)   // the writer's edit is still pending when the assistant writes
        try await host.setCell(number(11), at: key(host, 2, 2), undoManager: nil)

        try await host.assistantEdit { table in
            table.setCell(Cell(content: .value(.number(7))), at: CellKey(row: table.rows[1], column: table.columns[2]))
        }

        XCTAssertEqual(written.count, 2, "two saves: the writer's, then the assistant's")
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue", "Cost"], ["2025", "11", "7"]])
        let kept = versions(of: item)
        XCTAssertEqual(kept.count, 2, "\(kept)")
        XCTAssertEqual(kept[0].writtenBy, .writer)
        XCTAssertEqual(try versionRows(kept[0]), [["Year", "Revenue", "Cost"], ["2025", "11", "1"]],
                       "the writer's edit alone: the assistant's is not in the writer's save")
        XCTAssertEqual(try versionRows(kept[1]), [["Year", "Revenue", "Cost"], ["2025", "10", "1"]])
        XCTAssertFalse(host.isDirty)
        await store.releaseResearchTable(host)
    }

    // MARK: - What is on disk is what is kept

    /// **An outside change is the version kept**, even inside a writer's run:
    /// the bytes on disk are not the host's own last write. It keeps no
    /// author — the sidecar was not written for those bytes. The conflict
    /// backup stays as it was.
    func test_anOutsideChangeIsTheVersionKept_evenInsideARun() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let clock = Clock()
        let host = try await open(item, store, clock: clock)
        try await writerSaves(11, host)
        clock.advance(minutes: 1)

        try await host.setCell(number(12), at: key(host, 2, 2), undoManager: nil)
        let outside = "Year,Revenue\n2025,40\n"
        try Data(outside.utf8).write(to: file(try XCTUnwrap(item.path)))
        await host.flush()

        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "12"]], "the grid's version is saved")
        let kept = versions(of: item)
        XCTAssertEqual(kept.count, 2, "\(kept)")
        XCTAssertEqual(try ResearchVersionStore(projectURL: projectURL).read(kept[0]).0, Data(outside.utf8),
                       "the outside bytes, exactly")
        XCTAssertNil(kept[0].writtenBy, "nobody here wrote them")
        let backups = try FileManager.default.contentsOfDirectory(atPath: file(".maugham/conflicts").path)
        XCTAssertEqual(backups.filter { $0.contains(item.id) }.count, 1, "the conflict backup stays")
        await store.releaseResearchTable(host)
    }

    /// An outside change a clean grid read again ends the run: the writer's
    /// next save keeps it.
    func test_anOutsideChangeReadAgainIsKeptByTheNextSave() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let clock = Clock()
        let host = try await open(item, store, clock: clock)
        try await writerSaves(11, host)
        let outside = "Year,Revenue\n2025,40\n"
        try Data(outside.utf8).write(to: file(try XCTUnwrap(item.path)))
        await host.fileMayHaveChanged()
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(40)), "precondition: read again")

        clock.advance(minutes: 1)
        try await writerSaves(41, host)
        let kept = versions(of: item)
        XCTAssertEqual(kept.count, 2, "\(kept)")
        XCTAssertEqual(try ResearchVersionStore(projectURL: projectURL).read(kept[0]).0, Data(outside.utf8))
        await store.releaseResearchTable(host)
    }

    // MARK: - Review Focus 2: a failed save keeps no misleading version

    /// **Keep, then save**: a save that fails leaves the one version it kept,
    /// and that version is the bytes still on disk — a state the table is
    /// in, never one it did not reach. Its retry is the same run: no second.
    func test_aFailedSaveKeepsOnlyTheTrueStateOnDisk_andItsRetryKeepsNoSecond() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let folder = file(try XCTUnwrap(item.path)).deletingLastPathComponent()
        try lock(folder)

        try await writerSaves(11, host)

        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "the save failed")
        XCTAssertTrue(host.isDirty, "the edit waits to be saved")
        XCTAssertTrue(heard.notices.contains { $0.hasPrefix("Couldn’t save “model”") }, "\(heard.notices)")
        var kept = versions(of: item)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try ResearchVersionStore(projectURL: projectURL).read(kept[0]).0, try bytes(of: item),
                       "the version kept is what is on disk")

        try unlock(folder)
        await host.flush()
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "11"]])
        kept = versions(of: item)
        XCTAssertEqual(kept.count, 1, "the retry is the run whose start is kept: \(kept)")
        await store.releaseResearchTable(host)
    }

    /// A version that cannot be kept writes nothing over the file, and says so.
    func test_aVersionThatCannotBeKeptWritesNothing() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        // A file where the versions' folder goes: nothing can be kept there.
        try FileManager.default.createDirectory(at: file(".maugham"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file(ResearchVersionStore.folder))

        try await writerSaves(11, host)

        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "not saved over")
        XCTAssertTrue(host.isDirty)
        XCTAssertTrue(heard.notices.contains("“model”’s previous version couldn’t be kept, so your edits weren’t saved over it."),
                      "\(heard.notices)")
        await store.releaseResearchTable(host)
    }

    /// An assistant write whose save fails is not made: the table is put back
    /// and nothing waits to be saved under the writer's name.
    func test_aFailedAssistantWriteIsPutBack() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let host = try await open(item, store, clock: Clock())
        let before = host.state.table
        try lock(file(try XCTUnwrap(item.path)).deletingLastPathComponent())

        do {
            try await host.assistantEdit { table in
                table.setCell(Cell(content: .value(.number(99))), at: CellKey(row: table.rows[1], column: table.columns[1]))
            }
            XCTFail("the write should not have been made")
        } catch is ResearchTableHost.NotSaved {}

        XCTAssertEqual(host.state.table, before)
        XCTAssertFalse(host.isDirty)
        XCTAssertEqual(try bytes(of: item), Data(original.utf8))
        await store.releaseResearchTable(host)
    }

    /// A writer's pending edit that cannot be saved stops an assistant write
    /// (refused, not hung, and never folded into the assistant's save).
    func test_anAssistantWriteRefusesWhenTheWritersPendingEditCannotBeSaved() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let host = try await open(item, store, clock: Clock())
        host.saveDelay = .seconds(600)
        try await host.setCell(number(11), at: key(host, 2, 2), undoManager: nil)
        try lock(file(try XCTUnwrap(item.path)).deletingLastPathComponent())

        do {
            try await host.assistantEdit { table in
                table.setCell(Cell(content: .value(.number(99))), at: CellKey(row: table.rows[1], column: table.columns[1]))
            }
            XCTFail("the write should not have been made")
        } catch is ResearchTableHost.NotSaved {}

        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(11)), "the writer's edit, alone")
        XCTAssertTrue(host.isDirty, "the writer's edit still waits to be saved")
        XCTAssertEqual(try bytes(of: item), Data(original.utf8))
        await store.releaseResearchTable(host)
    }

    // MARK: - Fix round 1

    /// **M1 — a retry over the same bytes keeps no second version and no
    /// second backup**, however long after (here past the run's ten minutes),
    /// and the writer is told the outside version was kept only once the
    /// save lands.
    func test_aRetryOverTheSameOutsideBytesKeepsNoSecondVersionOrBackup() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let clock = Clock()
        let host = try await open(item, store, clock: clock)
        let outside = "Year,Revenue\n2025,40\n"
        try Data(outside.utf8).write(to: file(try XCTUnwrap(item.path)))
        let folder = file(try XCTUnwrap(item.path)).deletingLastPathComponent()
        try lock(folder)

        try await writerSaves(12, host)
        clock.advance(minutes: 11)
        await host.flush()

        func backups() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: file(".maugham/conflicts").path)
                .filter { $0.contains(item.id) }
        }
        XCTAssertEqual(versions(of: item).count, 1, "two failed saves over the same bytes keep one")
        XCTAssertEqual(try backups().count, 1)
        XCTAssertFalse(heard.notices.contains { $0.contains("yours was saved") }, "nothing claims a save: \(heard.notices)")

        try unlock(folder)
        await host.flush()
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "12"]])
        let kept = versions(of: item)
        XCTAssertEqual(kept.count, 1, "\(kept)")
        XCTAssertEqual(try ResearchVersionStore(projectURL: projectURL).read(kept[0]).0, Data(outside.utf8))
        XCTAssertEqual(try backups().count, 1)
        let told = heard.notices.filter { $0.contains("yours was saved") }
        XCTAssertEqual(told.count, 1, "\(heard.notices)")
        XCTAssertTrue(told[0].contains(try XCTUnwrap(try backups().first)), "it names the backup")
        await store.releaseResearchTable(host)
    }

    /// M1 — an assistant write retried after a failed save keeps one version.
    func test_aRetriedAssistantWriteKeepsOneVersion() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let host = try await open(item, store, clock: Clock())
        try lock(file(try XCTUnwrap(item.path)).deletingLastPathComponent())
        for _ in 1...2 {
            do {
                try await host.assistantEdit { table in
                    table.setCell(Cell(content: .value(.number(99))), at: CellKey(row: table.rows[1], column: table.columns[1]))
                }
                XCTFail("the write should not have been made")
            } catch is ResearchTableHost.NotSaved {}
        }
        XCTAssertEqual(versions(of: item).count, 1)
        await store.releaseResearchTable(host)
    }

    /// **M2 — a failed assistant write takes back only its own cells**: the
    /// writer's typing meanwhile stays; an added row the writer left empty
    /// goes, one the writer typed in stays without the assistant's cells.
    func test_theAssistantsRevertTakesBackOnlyItsOwnCells() throws {
        var prior = FigureTable(rows: 2, columns: 3)
        let b2 = CellKey(row: prior.rows[1], column: prior.columns[1])
        let c2 = CellKey(row: prior.rows[1], column: prior.columns[2])
        let a2 = CellKey(row: prior.rows[1], column: prior.columns[0])
        prior.setCell(number(10), at: b2)
        prior.setCell(number(1), at: c2)

        var next = prior
        next.setCell(number(99), at: b2)                     // the assistant's cell
        next.setCell(number(98), at: a2)                     // and another, overwritten below
        let empty = next.insertRow(after: next.rows[1])      // a row left empty by the writer
        next.setCell(number(5), at: CellKey(row: empty, column: next.columns[0]))
        let typed = next.insertRow(after: empty)             // a row the writer types in
        next.setCell(number(6), at: CellKey(row: typed, column: next.columns[0]))
        next.headerRows = 1

        XCTAssertEqual(ResearchAssistantRevert.reverted(next, prior: prior, next: next), prior,
                       "nothing typed since: exactly as it was")

        var current = next
        current.setCell(number(2), at: c2)                                               // the writer elsewhere
        current.setCell(number(7), at: a2)                                               // over the assistant's cell
        current.setCell(number(8), at: CellKey(row: typed, column: current.columns[1]))  // in the added row
        let back = try XCTUnwrap(ResearchAssistantRevert.reverted(current, prior: prior, next: next))

        XCTAssertEqual(back[b2], number(10), "the assistant's cell goes back")
        XCTAssertEqual(back[c2], number(2), "the writer's typing stays")
        XCTAssertEqual(back[a2], number(7), "a cell the writer typed over stays the writer's")
        XCTAssertNil(back.rowIndex(of: empty), "the empty added row goes")
        XCTAssertNotNil(back.rowIndex(of: typed), "the row the writer typed in stays")
        XCTAssertNil(back[CellKey(row: typed, column: back.columns[0])], "without the assistant's cell")
        XCTAssertEqual(back[CellKey(row: typed, column: back.columns[1])], number(8))
        XCTAssertEqual(back.headerRows, 0)

        var moved = prior
        moved.moveRow(prior.rows[1], after: nil)
        XCTAssertNil(ResearchAssistantRevert.reverted(moved, prior: prior, next: moved), "a reorder is not taken back")
        var deleted = prior
        deleted.deleteRow(prior.rows[1])
        XCTAssertNil(ResearchAssistantRevert.reverted(deleted, prior: prior, next: deleted), "nor a delete")
    }

    /// **M3 — a file that is there but will not read is not written over**:
    /// its previous version cannot be kept, so the save refuses and says so.
    func test_aFileThatWillNotReadIsNotSavedOver() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let path = file(try XCTUnwrap(item.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }

        try await writerSaves(11, host)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "not saved over")
        XCTAssertTrue(host.isDirty)
        XCTAssertEqual(versions(of: item).count, 0)
        XCTAssertTrue(heard.notices.contains(
            "Maugham couldn’t read “model” to keep its previous version, so your edits weren’t saved over it."),
            "\(heard.notices)")
        await store.releaseResearchTable(host)
    }

    /// **M4 — the writer's ⌘Z after an assistant write is declined**: a step
    /// never takes back what it did not make.
    func test_theWritersUndoAfterAnAssistantWriteIsDeclined() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let um = UndoManager()
        um.groupsByEvent = false
        um.beginUndoGrouping()
        try await host.setCell(number(11), at: key(host, 2, 2), undoManager: um)
        um.endUndoGrouping()
        await host.flush()
        try await host.assistantEdit { table in
            table.setCell(Cell(content: .value(.number(99))), at: CellKey(row: table.rows[1], column: table.columns[1]))
        }

        XCTAssertTrue(um.canUndo)
        um.undo()
        await host.flush()

        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(99)), "the assistant's write stays")
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "99"]])
        XCTAssertTrue(heard.notices.contains("Couldn’t undo “Edit Cell”: the table has changed since."), "\(heard.notices)")
        await store.releaseResearchTable(host)
    }

    /// M5 — a refused assistant save speaks of the assistant's change, not the writer's edits.
    func test_aRefusedAssistantSaveSpeaksOfTheAssistantsChange() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        try FileManager.default.createDirectory(at: file(".maugham"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file(ResearchVersionStore.folder))

        do {
            try await host.assistantEdit { table in
                table.setCell(Cell(content: .value(.number(99))), at: CellKey(row: table.rows[1], column: table.columns[1]))
            }
            XCTFail("the write should not have been made")
        } catch is ResearchTableHost.NotSaved {}

        XCTAssertTrue(heard.notices.contains(
            "“model”’s previous version couldn’t be kept, so the assistant’s change wasn’t saved over it."),
            "\(heard.notices)")
        await store.releaseResearchTable(host)
    }

    // MARK: - The rule

    func test_theRunRule() {
        var run = ResearchSaveRun()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertTrue(run.keepsAVersion(by: .writer, at: t0, overOwnBytes: true), "the first save of a run")
        run.saved(by: .writer, at: t0)
        XCTAssertFalse(run.keepsAVersion(by: .writer, at: t0 + 600, overOwnBytes: true))
        XCTAssertTrue(run.keepsAVersion(by: .writer, at: t0 + 601, overOwnBytes: true))
        XCTAssertTrue(run.keepsAVersion(by: .writer, at: t0 + 1, overOwnBytes: false), "bytes not ours")
        XCTAssertTrue(run.keepsAVersion(by: .assistant, at: t0 + 1, overOwnBytes: true), "every assistant save")
        run.saved(by: .assistant, at: t0 + 1)
        XCTAssertTrue(run.keepsAVersion(by: .writer, at: t0 + 2, overOwnBytes: true), "the assistant ended the run")
        run.saved(by: .writer, at: t0 + 2)
        run.end()
        XCTAssertTrue(run.keepsAVersion(by: .writer, at: t0 + 3, overOwnBytes: true), "ended")
    }
}
