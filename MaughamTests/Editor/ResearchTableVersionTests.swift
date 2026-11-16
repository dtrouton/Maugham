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
        ResearchTableHost.outsideBackupForTesting = nil
        ResearchTableHost.duringReloadForTesting = nil
        DocumentStore.beforeCoordinatedWriteForTesting = nil
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

    /// The writer types `value` into B2 and the debounced save runs (no sleep).
    private func writerSavesByTheTimer(_ value: Double, _ host: ResearchTableHost) async throws {
        try await host.setCell(number(value), at: key(host, 2, 2), undoManager: nil)
        await host.saveAsTheTimerForTesting()
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
        XCTAssertEqual(kept[0].replacedBy, .writer, "the writer's save replaced it")

        clock.advance(minutes: 1)
        try await host.assistantEdit { table in
            table.setCell(Cell(content: .value(.number(99))), at: CellKey(row: table.rows[1], column: table.columns[1]))
        }
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "99"]])
        kept = versions(of: item)
        XCTAssertEqual(kept.count, 2, "the assistant's write keeps one: \(kept)")
        XCTAssertEqual(kept[0].writtenBy, .writer, "the version before the assistant's write is the writer's bytes")
        XCTAssertEqual(kept[0].replacedBy, .assistant, "and it is marked as the state before the assistant's change")
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
        XCTAssertEqual(kept[0].replacedBy, .writer)
        XCTAssertEqual(try versionRows(kept[0]), [["Year", "Revenue"], ["2025", "99"]])
        XCTAssertEqual(try ResearchTableSidecar.read(forItem: item.id, in: projectURL)?.writtenBy, .writer)
        await store.releaseResearchTable(host)
    }

    /// **The inspector's list reloads only when a version is kept** (final
    /// review M1): a writer's run of saves keeps one, so it bumps
    /// `researchVersionsRevision` once, not once per autosave; an assistant
    /// write and a restore each bump it. Disable experiment: bump on every
    /// landed save, and the run bumps it twenty times.
    func test_theVersionsRevisionMovesOnlyWhenAVersionIsKept() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let clock = Clock()
        let host = try await open(item, store, clock: clock)
        let start = store.researchVersionsRevision

        for minute in 1...20 {
            clock.advance(minutes: 1)
            try await writerSaves(Double(minute), host)
        }
        XCTAssertEqual(store.researchVersionsRevision - start, 1, "a run keeps one version and reloads the list once")

        clock.advance(minutes: 1)
        try await host.assistantEdit { table in
            table.setCell(Cell(content: .value(.number(99))), at: CellKey(row: table.rows[1], column: table.columns[1]))
        }
        XCTAssertEqual(store.researchVersionsRevision - start, 2, "an assistant write keeps one")

        try await host.restore(try XCTUnwrap(versions(of: item).last))
        XCTAssertEqual(store.researchVersionsRevision - start, 3, "a restore keeps one")
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

        try await writerSavesByTheTimer(11, host)

        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "the save failed")
        XCTAssertTrue(host.isDirty, "the edit waits to be saved")
        XCTAssertEqual(heard.notices.filter { $0.hasPrefix("Couldn’t save “model”") }.count, 1, "\(heard.notices)")
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

    // MARK: - A restore spares the version it restores (#141 N4)

    /// A table with the writer's one version (the original bytes, the oldest)
    /// and fillers up to the retention, all newer, on this device.
    private func tableWithTheRetentionKept(_ store: DocumentStore, _ projectStore: ProjectStore,
                                           clock: Clock) async throws -> (ResearchItem, ResearchTableHost, ResearchVersion) {
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let host = try await open(item, store, clock: clock)
        try await writerSaves(11, host)
        let oldest = try XCTUnwrap(versions(of: item).first)
        let store = ResearchVersionStore(projectURL: projectURL)
        for i in 1..<ResearchVersionStore.retention {
            try store.keep(priorBytes: Data("Year,Revenue\n2025,\(100 + i)\n".utf8), priorSidecar: nil, writtenBy: .writer,
                           itemId: item.id, device: DeviceIdentity.author.slug,
                           at: clock.date.addingTimeInterval(3_600 * Double(i)))
        }
        XCTAssertEqual(versions(of: item).count, ResearchVersionStore.retention)
        XCTAssertTrue(versions(of: item).contains(oldest))
        return (item, host, oldest)
    }

    /// Restoring the oldest of exactly the retention makes one more; its
    /// prune must not remove the version being restored.
    /// Disable experiment: pass no `sparing` for the restored name and the
    /// restored version's file is gone after the restore.
    func test_restoringTheOldestOfFiftyKeepsTheVersionItRestored() async throws {
        let (store, projectStore) = try await openBook()
        let (item, host, oldest) = try await tableWithTheRetentionKept(store, projectStore, clock: Clock())

        try await host.restore(oldest)

        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "10"]])
        XCTAssertTrue(versions(of: item).contains(oldest), "the restored version is still kept")
        XCTAssertLessThanOrEqual(versions(of: item).count, ResearchVersionStore.retention)
        await store.releaseResearchTable(host)
    }

    /// The same, when the write then fails: the restored table is still on disk as a version.
    func test_aFailedRestoreOfTheOldestOfFiftyLeavesItsVersionOnDisk() async throws {
        let (store, projectStore) = try await openBook()
        let (item, host, oldest) = try await tableWithTheRetentionKept(store, projectStore, clock: Clock())
        let path = file(try XCTUnwrap(item.path))
        var left = ["Year,Revenue\n2025,outside 1\n", "Year,Revenue\n2025,outside 2\n"]
        DocumentStore.beforeCoordinatedWriteForTesting = {
            guard !left.isEmpty else { return }
            try? Data(left.removeFirst().utf8).write(to: path)
        }

        do {
            try await host.restore(oldest)
            XCTFail("the write was changed twice, so the restore fails")
        } catch is ResearchTableHost.NotSaved {}

        XCTAssertTrue(versions(of: item).contains(oldest), "the restored version's file still exists")
        XCTAssertEqual(try versionRows(oldest), [["Year", "Revenue"], ["2025", "10"]])
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

        try await writerSavesByTheTimer(11, host)

        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "not saved over")
        XCTAssertTrue(host.isDirty)
        XCTAssertEqual(heard.notices.filter {
            $0 == "“model”’s previous version couldn’t be kept, so your edits weren’t saved over it."
        }.count, 1, "\(heard.notices)")
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

        try await writerSavesByTheTimer(12, host)
        clock.advance(minutes: 11)
        await host.saveAsTheTimerForTesting()
        XCTAssertTrue(host.isDirty, "the edit still waits to be saved")

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

        try await writerSavesByTheTimer(11, host)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "not saved over")
        XCTAssertTrue(host.isDirty)
        XCTAssertEqual(versions(of: item).count, 0)
        XCTAssertEqual(heard.notices.filter {
            $0 == "Maugham couldn’t read “model” to keep its previous version, so your edits weren’t saved over it."
        }.count, 1, "\(heard.notices)")
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


    // MARK: - Hardening 11-11 task 2.1: every refusal stays dirty, and says so once

    /// **The timer's save, refused because the outside version could not be
    /// kept**: nothing is written over the file, the edit waits, said once.
    func test_aTimerSaveWhoseOutsideVersionCannotBeKeptWritesNothingAndStaysDirty() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let outside = "Year,Revenue\n2025,40\n"
        try Data(outside.utf8).write(to: file(try XCTUnwrap(item.path)))
        // A file where the conflicts folder goes: no backup can be made there.
        try FileManager.default.createDirectory(at: file(".maugham"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file(".maugham/conflicts"))

        try await writerSavesByTheTimer(12, host)

        XCTAssertEqual(try bytes(of: item), Data(outside.utf8), "not saved over the outside version")
        XCTAssertTrue(versions(of: item).isEmpty, "no version kept")
        XCTAssertTrue(host.isDirty, "the edit waits to be saved")
        XCTAssertEqual(heard.notices.filter {
            $0 == "“model” changed outside Maugham, and that version couldn’t be kept, so your edits weren’t saved over it."
        }.count, 1, "\(heard.notices)")
        await store.releaseResearchTable(host)
    }

    /// **The timer's save of a table no longer in Research** (another Mac's
    /// manifest removed it): nothing is written, the edit waits, said once.
    func test_aTimerSaveOfATableNoLongerInResearchStaysDirty() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        projectStore.removeResearchItem(id: item.id)

        try await writerSavesByTheTimer(11, host)

        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "nothing written")
        XCTAssertTrue(host.isDirty, "the edit waits to be saved")
        XCTAssertEqual(heard.notices.filter {
            $0 == "A Research table’s edits couldn’t be saved: it is no longer in Research."
        }.count, 1, "\(heard.notices)")
        await store.releaseResearchTable(host)
    }

    /// **The timer's save of a file that has gone** (another Mac trashed
    /// it): the file is not made again, the edit waits, said once.
    func test_aTimerSaveWhoseFileHasGoneMakesNothingAndStaysDirty() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let path = file(try XCTUnwrap(item.path))
        try FileManager.default.removeItem(at: path)

        try await writerSavesByTheTimer(11, host)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "the file was not made again")
        XCTAssertTrue(host.isDirty, "the edit waits to be saved")
        XCTAssertEqual(heard.notices.filter { $0 == "“model” isn’t there any more, so its edits weren’t saved." }.count,
                       1, "\(heard.notices)")
        await store.releaseResearchTable(host)
    }

    /// **An assistant write's pre-flush (`.direct`) that is refused leaves
    /// the writer's edit waiting**, so the assistant's write is refused as
    /// one whose pending edits could not be saved first — never made over
    /// them, never dropped.
    func test_anAssistantWriteWhosePendingEditsTableHasLeftResearchIsRefusedAndTheEditWaits() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let host = try await open(item, store, clock: Clock())
        host.saveDelay = .seconds(600)
        try await host.setCell(number(11), at: key(host, 2, 2), undoManager: nil)
        projectStore.removeResearchItem(id: item.id)

        do {
            try await host.assistantEdit { table in
                table.setCell(Cell(content: .value(.number(99))), at: CellKey(row: table.rows[1], column: table.columns[1]))
            }
            XCTFail("the write should not have been made")
        } catch let notSaved as ResearchTableHost.NotSaved {
            XCTAssertEqual(notSaved.message,
                           "The table’s unsaved edits couldn’t be saved first, so the change wasn’t made. "
                               + "Don’t send it again; ask the writer to save or reopen the table.")
        }

        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(11)), "the writer's edit, alone")
        XCTAssertTrue(host.isDirty, "the writer's edit still waits to be saved")
        XCTAssertEqual(try bytes(of: item), Data(original.utf8))
        await store.releaseResearchTable(host)
    }

    // MARK: - Hardening 11-11 task 2.2: a flush never drops the edits (ruling R-C)

    /// The unsaved-edits backups kept for `item`, oldest first.
    private func unsavedBackups(of item: ResearchItem) -> [URL] {
        let folder = file(".maugham/conflicts")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.contains("-\(item.id)-unsaved-") }.sorted().map { folder.appendingPathComponent($0) }
    }

    private func backupRows(_ backup: URL) throws -> [[String]] {
        TableCSV.rows(String(decoding: try Data(contentsOf: backup), as: UTF8.self)).rows
    }

    private func kept(_ couldNot: String, as backup: URL) -> String {
        "\(couldNot) Your edits were kept in the project’s .maugham/conflicts folder as “\(backup.lastPathComponent)”."
    }

    /// The one backup a flush kept for `item`: the held table's rows, named
    /// `<stem>-<id>-unsaved-<stamp>.csv`.
    private func theOneBackup(of item: ResearchItem, stem: String, rows: [[String]],
                              file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let backups = unsavedBackups(of: item)
        XCTAssertEqual(backups.count, 1, "one backup: \(backups)", file: file, line: line)
        let backup = try XCTUnwrap(backups.first, file: file, line: line)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("\(stem)-\(item.id)-unsaved-"), backup.lastPathComponent,
                      file: file, line: line)
        XCTAssertEqual(backup.pathExtension, "csv", file: file, line: line)
        XCTAssertEqual(try backupRows(backup), rows, "the backup holds the held table", file: file, line: line)
        return backup
    }

    /// **`versionNotKept` on a flush: saved anyway** (the notes' rule,
    /// `ResearchNoteDoor.whenTheKeepFails`), and said; nothing kept aside.
    func test_aFlushWhoseVersionCannotBeKeptSavesAnyway() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        try FileManager.default.createDirectory(at: file(".maugham"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file(ResearchVersionStore.folder))

        try await writerSaves(11, host)

        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "11"]], "saved anyway")
        XCTAssertFalse(host.isDirty)
        XCTAssertEqual(heard.notices, ["“model”’s previous version couldn’t be kept; your edits were saved anyway."])
        XCTAssertTrue(unsavedBackups(of: item).isEmpty)
        await store.releaseResearchTable(host)
    }

    /// **`priorUnreadable` on a flush**: nothing is written over the file;
    /// the edits are kept aside, named, and the host stays dirty (still
    /// unsaved: a later flush or the close tries the file again).
    func test_aFlushOverAFileThatWillNotReadKeepsTheEditsAside() async throws {
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
        XCTAssertTrue(host.isDirty, "kept aside, still unsaved")
        let backup = try theOneBackup(of: item, stem: "model", rows: [["Year", "Revenue"], ["2025", "11"]])
        XCTAssertEqual(heard.notices, [kept("Couldn’t save “model”: Maugham couldn’t read it to keep its previous version.",
                                           as: backup)])
        await store.releaseResearchTable(host)
        XCTAssertEqual(heard.notices.count, 1, "the close keeps no second copy: \(heard.notices)")
    }

    /// **`itemGone` on a flush**: nothing written; the backup is named from
    /// the fallback anchor (`research/table.csv`), since no item names it.
    func test_aFlushOfATableNoLongerInResearchKeepsTheEditsAside() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        projectStore.removeResearchItem(id: item.id)

        try await writerSaves(11, host)

        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "nothing written")
        XCTAssertTrue(host.isDirty, "kept aside, still unsaved")
        let backup = try theOneBackup(of: item, stem: "table", rows: [["Year", "Revenue"], ["2025", "11"]])
        XCTAssertEqual(heard.notices, [kept("Couldn’t save a Research table: it is no longer in Research.", as: backup)])
        await store.releaseResearchTable(host)
    }

    /// **`outsideResearch` on a flush**: nothing written at the stray path;
    /// a non-`.csv` path names the backup from the fallback anchor, a `.csv`
    /// one from itself — always `*-unsaved-*.csv`.
    func test_aFlushOfATableMovedOutsideResearchKeepsTheEditsAside() async throws {
        let (store, projectStore) = try await openBook()
        try FileManager.default.createDirectory(at: file(".maugham/ops"), withIntermediateDirectories: true)
        try Data("Item,Amount\nRent,10\n".utf8).write(to: file(".maugham/ops/stray.csv"))
        for (path, stem) in [("manuscript/a.md", "table"), (".maugham/ops/stray.csv", "stray")] {
            let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
            let heard = listen()
            let host = try await open(item, store, clock: Clock())
            projectStore.mutateResearchItem(id: item.id) { $0.path = path }
            let before = try Data(contentsOf: file(path))

            try await writerSaves(20, host)

            XCTAssertEqual(try Data(contentsOf: file(path)), before, "\(path): nothing written there")
            XCTAssertTrue(versions(of: item).isEmpty, "\(path): no version kept")
            XCTAssertTrue(host.isDirty, "\(path): kept aside, still unsaved")
            let backup = try theOneBackup(of: item, stem: stem, rows: [["Year", "Revenue"], ["2025", "20"]])
            XCTAssertEqual(heard.notices,
                           [kept("Couldn’t save “model”: it isn’t a table inside Research any more.", as: backup)],
                           "\(path)")
            await store.releaseResearchTable(host)
        }
    }

    /// **`outsideVersionNotKept` on a flush**: the outside bytes stay; the
    /// edits are kept aside beside where that backup failed.
    func test_aFlushWhoseOutsideVersionCannotBeKeptKeepsTheEditsAside() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let outside = "Year,Revenue\n2025,40\n"
        try Data(outside.utf8).write(to: file(try XCTUnwrap(item.path)))
        ResearchTableHost.outsideBackupForTesting = { _ in nil }

        try await writerSaves(12, host)

        XCTAssertEqual(try bytes(of: item), Data(outside.utf8), "not saved over the outside version")
        XCTAssertTrue(versions(of: item).isEmpty, "no version kept")
        XCTAssertTrue(host.isDirty, "kept aside, still unsaved")
        let backup = try theOneBackup(of: item, stem: "model", rows: [["Year", "Revenue"], ["2025", "12"]])
        XCTAssertEqual(heard.notices, [kept(
            "Couldn’t save “model”: it changed outside Maugham, and that version couldn’t be kept.", as: backup)])
        await store.releaseResearchTable(host)
    }

    /// **`saveFailed` on a flush**: nothing more is written over the file
    /// (there may be no later retry — ⌘Q); the edits are kept aside, and
    /// the host stays dirty (still unsaved). The timer's failure still waits
    /// (task 2.1's test).
    func test_aFlushWhoseSaveFailsKeepsTheEditsAside() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        try lock(file(try XCTUnwrap(item.path)).deletingLastPathComponent())

        try await writerSaves(11, host)

        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "the save failed")
        XCTAssertTrue(host.isDirty, "kept aside, still unsaved")
        let backup = try theOneBackup(of: item, stem: "model", rows: [["Year", "Revenue"], ["2025", "11"]])
        XCTAssertEqual(heard.notices.count, 1, "\(heard.notices)")
        XCTAssertTrue(heard.notices[0].hasPrefix("Couldn’t save “model”: "), heard.notices[0])
        XCTAssertTrue(heard.notices[0].hasSuffix(
            " Your edits were kept in the project’s .maugham/conflicts folder as “\(backup.lastPathComponent)”."),
            heard.notices[0])
        await store.releaseResearchTable(host)
        XCTAssertEqual(unsavedBackups(of: item).count, 1, "the close keeps no second copy")
        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "and writes nothing more")
    }

    /// **`fileGone` on a flush**: the file is not made again (task 7
    /// re-review R2-2 stands); the edits are kept aside, named from the
    /// item's own path.
    func test_aFlushWhoseFileHasGoneKeepsTheEditsAsideAndMakesNothing() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let path = file(try XCTUnwrap(item.path))
        try FileManager.default.removeItem(at: path)

        try await writerSaves(11, host)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "the file was not made again")
        XCTAssertTrue(host.isDirty, "kept aside, still unsaved")
        let backup = try theOneBackup(of: item, stem: "model", rows: [["Year", "Revenue"], ["2025", "11"]])
        XCTAssertEqual(heard.notices, [kept("Couldn’t save “model”: it isn’t there any more.", as: backup)])
        await store.releaseResearchTable(host)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "nor by the close")
    }

    /// **The backup itself fails**: said in plain words — nothing is silent.
    func test_aFlushWhoseBackupFailsToo_saysTheEditsWereNotKept() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let path = file(try XCTUnwrap(item.path))
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: file(".maugham/conflicts"), withIntermediateDirectories: true)
        try lock(file(".maugham/conflicts"))

        try await writerSaves(11, host)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "the file was not made again")
        XCTAssertTrue(unsavedBackups(of: item).isEmpty)
        XCTAssertTrue(host.isDirty, "not kept, still unsaved")
        XCTAssertEqual(heard.notices, [
            "Couldn’t save “model”: it isn’t there any more. Your edits weren’t saved, and they couldn’t be kept anywhere else."
        ])
        await store.releaseResearchTable(host)
        XCTAssertEqual(heard.notices.count, 1, "\(heard.notices)")
    }

    /// **Review Focus 1 — one backup, one notice on the way out** (⌘Q):
    /// the store's flush, then the release's close, keep one copy and say
    /// it once.
    func test_theStoresFlushThenTheReleaseKeepOneBackupAndSayItOnce() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        host.saveDelay = .seconds(600)
        try await host.setCell(number(11), at: key(host, 2, 2), undoManager: nil)
        try FileManager.default.removeItem(at: file(try XCTUnwrap(item.path)))

        try await store.flushPendingSave(commitOpenEdits: true)
        await store.releaseResearchTable(host)

        let backup = try theOneBackup(of: item, stem: "model", rows: [["Year", "Revenue"], ["2025", "11"]])
        XCTAssertEqual(heard.notices, [kept("Couldn’t save “model”: it isn’t there any more.", as: backup)])
    }

    /// **After a backup the host is still unsaved and holds the edited table**
    /// (the grid shows it): a later edit changes what would be kept, so its
    /// flush keeps a new backup — each holding the table as it was at that
    /// flush (fix round 1, consequence e).
    func test_aLaterEditAfterABackupKeepsASecondBackupAtItsFlush() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let clock = Clock()
        let host = try await open(item, store, clock: clock)
        try FileManager.default.removeItem(at: file(try XCTUnwrap(item.path)))

        try await writerSaves(11, host)
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(11)), "still held")
        clock.advance(minutes: 1)
        try await writerSaves(12, host)

        let backups = unsavedBackups(of: item)
        guard backups.count == 2 else { return XCTFail("two backups: \(backups)") }
        XCTAssertEqual(try backupRows(backups[0]), [["Year", "Revenue"], ["2025", "11"]])
        XCTAssertEqual(try backupRows(backups[1]), [["Year", "Revenue"], ["2025", "12"]])
        XCTAssertEqual(heard.notices, backups.map { kept("Couldn’t save “model”: it isn’t there any more.", as: $0) })
        await store.releaseResearchTable(host)
        XCTAssertEqual(unsavedBackups(of: item).count, 2, "the close keeps no third")
    }

    // MARK: Fix round 1 — a table kept aside stays unsaved, and remembers what it kept

    /// **(b) A transient refusal heals at the next flush**: a flush over a
    /// briefly locked folder keeps the edits aside; once it opens, the next
    /// flush — no new edit — writes them, keeps no second backup and says
    /// nothing more (the earlier backup simply remains).
    func test_aFlushKeptAsideByATransientFailureWritesTheEditsAtTheNextFlush() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let folder = file(try XCTUnwrap(item.path)).deletingLastPathComponent()
        try lock(folder)
        try await writerSaves(11, host)
        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "precondition: the save failed")
        XCTAssertEqual(unsavedBackups(of: item).count, 1, "precondition: kept aside")

        try unlock(folder)
        await host.flush()

        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "11"]], "the edits are on disk")
        XCTAssertFalse(host.isDirty)
        XCTAssertEqual(unsavedBackups(of: item).count, 1, "no second backup")
        XCTAssertEqual(heard.notices.count, 1, "nothing more said: \(heard.notices)")
        await store.releaseResearchTable(host)
    }

    /// **(b) The same through the close** (⌘Q's shape): the release's
    /// `close()` writes the edits a flush kept aside.
    func test_theCloseWritesTheEditsAFlushKeptAsideOnceTheFolderOpens() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        host.saveDelay = .seconds(600)
        let folder = file(try XCTUnwrap(item.path)).deletingLastPathComponent()
        try lock(folder)
        try await host.setCell(number(11), at: key(host, 2, 2), undoManager: nil)
        try await store.flushPendingSave(commitOpenEdits: true)
        XCTAssertEqual(unsavedBackups(of: item).count, 1, "precondition: kept aside")

        try unlock(folder)
        await store.releaseResearchTable(host)

        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "11"]], "the close wrote them")
        XCTAssertFalse(host.isDirty)
        XCTAssertEqual(unsavedBackups(of: item).count, 1, "no second backup")
        XCTAssertEqual(heard.notices.count, 1, "\(heard.notices)")
    }

    /// **(c) An assistant write after a kept-aside flush is refused**: the
    /// writer's edits are still unsaved, so they are never carried to disk
    /// stamped as the assistant's.
    func test_anAssistantWriteAfterAKeptAsideFlushIsRefused() async throws {
        let (store, projectStore) = try await openBook()
        let original = "Year,Revenue\n2025,10\n"
        let item = try await researchTable(original, in: projectStore)
        let host = try await open(item, store, clock: Clock())
        try lock(file(try XCTUnwrap(item.path)).deletingLastPathComponent())
        try await writerSaves(11, host)
        XCTAssertEqual(unsavedBackups(of: item).count, 1, "precondition: kept aside")

        do {
            try await host.assistantEdit { table in
                table.setCell(Cell(content: .value(.number(99))), at: CellKey(row: table.rows[1], column: table.columns[1]))
            }
            XCTFail("the write should not have been made")
        } catch let notSaved as ResearchTableHost.NotSaved {
            XCTAssertEqual(notSaved.message,
                           "The table’s unsaved edits couldn’t be saved first, so the change wasn’t made. "
                               + "Don’t send it again; ask the writer to save or reopen the table.")
        }

        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(11)), "the writer's edit, alone")
        XCTAssertTrue(host.isDirty)
        XCTAssertEqual(try bytes(of: item), Data(original.utf8), "nothing written")
        XCTAssertEqual(unsavedBackups(of: item).count, 1, "the direct pre-flush keeps nothing aside")
        await store.releaseResearchTable(host)
    }

    /// **(d) An outside change does not reload over a kept-aside table**: it
    /// is unsaved, so the grid keeps the writer's edits.
    func test_anOutsideChangeDoesNotReloadOverAKeptAsideTable() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let path = file(try XCTUnwrap(item.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }
        try await writerSaves(11, host)
        XCTAssertEqual(unsavedBackups(of: item).count, 1, "precondition: kept aside")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        try Data("Year,Revenue\n2025,40\n".utf8).write(to: path)

        await host.fileMayHaveChanged()

        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(11)), "the held edit stays")
        XCTAssertTrue(host.isDirty)
        XCTAssertFalse(heard.notices.contains { $0.hasPrefix("Reloaded") }, "\(heard.notices)")
        await store.releaseResearchTable(host)
    }

    /// **(f) A backup that fails is said once and retried silently**: the
    /// next flush of the same table tries the backup again without a word;
    /// when the conflicts folder opens, that flush keeps it and names it.
    func test_aBackupThatFailsIsSaidOnce_andAFlushOnceItCanKeepsItAndSaysWhere() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        try FileManager.default.removeItem(at: file(try XCTUnwrap(item.path)))
        let conflicts = file(".maugham/conflicts")
        try FileManager.default.createDirectory(at: conflicts, withIntermediateDirectories: true)
        try lock(conflicts)
        let notKept = "Couldn’t save “model”: it isn’t there any more. Your edits weren’t saved, and they couldn’t be kept anywhere else."

        try await writerSaves(11, host)
        await host.flush()
        XCTAssertEqual(heard.notices, [notKept], "said once")
        XCTAssertTrue(unsavedBackups(of: item).isEmpty)
        XCTAssertTrue(host.isDirty)

        try unlock(conflicts)
        await host.flush()

        let backup = try theOneBackup(of: item, stem: "model", rows: [["Year", "Revenue"], ["2025", "11"]])
        XCTAssertEqual(heard.notices, [notKept, kept("Couldn’t save “model”: it isn’t there any more.", as: backup)])
        await store.releaseResearchTable(host)
        XCTAssertEqual(heard.notices.count, 2, "the close says nothing more: \(heard.notices)")
        XCTAssertEqual(unsavedBackups(of: item).count, 1)
    }

    /// **Review Focus 2 — a flush on a clean host keeps nothing and says
    /// nothing**, over a gone, an unreadable or a stray file: there is no
    /// edit to keep.
    func test_aFlushOnACleanHostKeepsNothingAndSaysNothing() async throws {
        let (store, projectStore) = try await openBook()
        let heard = listen()

        let gone = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let goneHost = try await open(gone, store, clock: Clock())
        try FileManager.default.removeItem(at: file(try XCTUnwrap(gone.path)))
        await goneHost.flush()
        await store.releaseResearchTable(goneHost)

        let unreadable = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let unreadableHost = try await open(unreadable, store, clock: Clock())
        let path = file(try XCTUnwrap(unreadable.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }
        await unreadableHost.flush()
        await store.releaseResearchTable(unreadableHost)

        let stray = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let strayHost = try await open(stray, store, clock: Clock())
        projectStore.mutateResearchItem(id: stray.id) { $0.path = "manuscript/a.md" }
        await strayHost.flush()
        await store.releaseResearchTable(strayHost)

        for item in [gone, unreadable, stray] {
            XCTAssertTrue(unsavedBackups(of: item).isEmpty, "\(item.id)")
        }
        XCTAssertEqual(heard.notices, [])
    }

    // MARK: - Hardening 11-11 task 2.4: the bytes read are the bytes written over (#138 R3)

    /// Lands each of `landings` in turn on the file at `path` as the save
    /// enters its coordinated write (after the door read it), one per save
    /// attempt; nothing once they run out.
    private func landOutside(_ landings: [String], at path: URL) {
        var left = landings
        DocumentStore.beforeCoordinatedWriteForTesting = {
            guard !left.isEmpty else { return }
            try? Data(left.removeFirst().utf8).write(to: path)
        }
    }

    /// The outside-version backups kept for `item`, oldest first.
    private func outsideBackups(of item: ResearchItem) -> [URL] {
        let folder = file(".maugham/conflicts")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.contains("-\(item.id)-outside-") }.sorted().map { folder.appendingPathComponent($0) }
    }

    private static let changedWhileSaving = "Couldn’t save “model”: it changed outside Maugham while it was being saved."

    /// **Bytes written outside between the door's read and its write are
    /// never written over unseen**: the save finds them inside its
    /// coordinated write, reads again, keeps them (a conflict backup and a
    /// version), then saves — and says so once, naming the backup. Timer
    /// and flush alike.
    func test_bytesWrittenOutsideAfterTheReadAreKeptBeforeTheTimersSave() async throws {
        try await outsideBytesAfterTheReadAreKept(byTheTimer: true)
    }

    func test_bytesWrittenOutsideAfterTheReadAreKeptBeforeAFlushesSave() async throws {
        try await outsideBytesAfterTheReadAreKept(byTheTimer: false)
    }

    private func outsideBytesAfterTheReadAreKept(byTheTimer: Bool) async throws {
        do {
            let (store, projectStore) = try await openBook()
            let original = "Year,Revenue\n2025,10\n"
            let item = try await researchTable(original, in: projectStore)
            let heard = listen()
            let host = try await open(item, store, clock: Clock())
            let outside = "Year,Revenue\n2025,40\n"
            landOutside([outside], at: file(try XCTUnwrap(item.path)))

            if byTheTimer { try await writerSavesByTheTimer(11, host) } else { try await writerSaves(11, host) }

            let label = byTheTimer ? "timer" : "flush"
            XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "11"]], "\(label): the grid's version is saved")
            XCTAssertFalse(host.isDirty, label)
            let backups = outsideBackups(of: item)
            XCTAssertEqual(backups.count, 1, "\(label): one backup of the outside bytes: \(backups)")
            XCTAssertEqual(try backups.first.map { try Data(contentsOf: $0) }, Data(outside.utf8), label)
            XCTAssertEqual(Set(try versions(of: item).map { try ResearchVersionStore(projectURL: projectURL).read($0).0 }),
                           [Data(original.utf8), Data(outside.utf8)],
                           "\(label): the run's start and the outside bytes, each kept once")
            XCTAssertEqual(heard.notices, [
                "“model” changed outside Maugham while you were editing it. That version is kept in "
                    + ".maugham/conflicts/\(try XCTUnwrap(backups.first).lastPathComponent); yours was saved."
            ], label)
            DocumentStore.beforeCoordinatedWriteForTesting = nil
            await store.releaseResearchTable(host)
            XCTAssertEqual(heard.notices.count, 1, "\(label): said once: \(heard.notices)")
        }
    }

    /// **Bytes landed again on the second read are not written over
    /// either**: the timer's save writes nothing, stays dirty and says so
    /// once; the file is as the outside wrote it. Its next save keeps those
    /// bytes too and names both backups.
    func test_aSecondChangeOnTheRetryWritesNothing_theTimerWaits() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let first = "Year,Revenue\n2025,40\n", second = "Year,Revenue\n2025,50\n"
        landOutside([first, second], at: file(try XCTUnwrap(item.path)))

        try await writerSavesByTheTimer(11, host)

        XCTAssertEqual(try bytes(of: item), Data(second.utf8), "the file is as the outside last wrote it")
        XCTAssertTrue(host.isDirty, "the edit waits to be saved")
        XCTAssertEqual(heard.notices, [Self.changedWhileSaving])
        XCTAssertEqual(outsideBackups(of: item).count, 1, "the first change is kept")
        XCTAssertTrue(unsavedBackups(of: item).isEmpty, "the timer keeps nothing aside")

        await host.flush()
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "11"]])
        XCTAssertFalse(host.isDirty)
        let backups = outsideBackups(of: item)
        XCTAssertEqual(backups.count, 2, "\(backups)")
        XCTAssertEqual(Set(try backups.map { try Data(contentsOf: $0) }), [Data(first.utf8), Data(second.utf8)],
                       "each outside version kept once")
        guard heard.notices.count == 2 else { return XCTFail("one more notice: \(heard.notices)") }
        let told = heard.notices[1]
        XCTAssertTrue(told.hasPrefix("“model” changed outside Maugham while you were editing it. Those versions are kept in "), told)
        XCTAssertTrue(backups.allSatisfy { told.contains($0.lastPathComponent) }, "it names both: \(told)")
        DocumentStore.beforeCoordinatedWriteForTesting = nil
        await store.releaseResearchTable(host)
    }

    /// **On a flush, a second change keeps the edits aside** (`saveFailed`'s
    /// flush arm): nothing is written over the outside bytes, the table's
    /// CSV is kept and named, the host stays dirty.
    func test_aSecondChangeOnAFlushesRetryKeepsTheEditsAside() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let first = "Year,Revenue\n2025,40\n", second = "Year,Revenue\n2025,50\n"
        landOutside([first, second], at: file(try XCTUnwrap(item.path)))

        try await writerSaves(11, host)

        XCTAssertEqual(try bytes(of: item), Data(second.utf8), "not saved over the outside version")
        XCTAssertTrue(host.isDirty, "kept aside, still unsaved")
        let outside = outsideBackups(of: item)
        XCTAssertEqual(try outside.map { try Data(contentsOf: $0) }, [Data(first.utf8)],
                       "the first change is kept as a conflict backup")
        XCTAssertEqual(Set(try versions(of: item).map { try ResearchVersionStore(projectURL: projectURL).read($0).0 }),
                       [Data("Year,Revenue\n2025,10\n".utf8), Data(first.utf8)],
                       "and as a version, beside the run's start")
        let backup = try theOneBackup(of: item, stem: "model", rows: [["Year", "Revenue"], ["2025", "11"]])
        XCTAssertEqual(heard.notices, [kept(Self.changedWhileSaving, as: backup)])
        DocumentStore.beforeCoordinatedWriteForTesting = nil
    }

    /// **A kept-aside backup that has gone is kept again** (task 2.2 review,
    /// folded in): the same table flushed again after its backup was
    /// deleted keeps a new one and says where — the old name proves nothing.
    func test_aFlushWhoseEarlierBackupHasGoneKeepsItAgainAndSaysSo() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        try FileManager.default.removeItem(at: file(try XCTUnwrap(item.path)))

        try await writerSaves(11, host)
        let first = try theOneBackup(of: item, stem: "model", rows: [["Year", "Revenue"], ["2025", "11"]])
        try FileManager.default.removeItem(at: first)

        await host.flush()

        let again = try theOneBackup(of: item, stem: "model", rows: [["Year", "Revenue"], ["2025", "11"]])
        let said = kept("Couldn’t save “model”: it isn’t there any more.", as: again)
        XCTAssertEqual(heard.notices, [kept("Couldn’t save “model”: it isn’t there any more.", as: first), said])
        await store.releaseResearchTable(host)
        XCTAssertEqual(heard.notices.count, 2, "the close keeps no third: \(heard.notices)")
    }

    /// **The backup has gone and a new one cannot be kept either** (fix
    /// round 1): said once — the writer heard a file's name that no longer
    /// holds the edits — and the close says nothing more.
    func test_aFlushWhoseEarlierBackupHasGoneAndCannotBeKeptAgainSaysSoOnce() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        try FileManager.default.removeItem(at: file(try XCTUnwrap(item.path)))

        try await writerSaves(11, host)
        let first = try theOneBackup(of: item, stem: "model", rows: [["Year", "Revenue"], ["2025", "11"]])
        try FileManager.default.removeItem(at: first)
        try lock(file(".maugham/conflicts"))

        await host.flush()

        XCTAssertTrue(unsavedBackups(of: item).isEmpty)
        XCTAssertTrue(host.isDirty, "not kept, still unsaved")
        XCTAssertEqual(heard.notices, [
            kept("Couldn’t save “model”: it isn’t there any more.", as: first),
            "Couldn’t save “model”: it isn’t there any more. Your edits weren’t saved, and they couldn’t be kept anywhere else.",
        ])
        await store.releaseResearchTable(host)
        XCTAssertEqual(heard.notices.count, 2, "the close says nothing more: \(heard.notices)")
    }

    // MARK: - Hardening 11-11 final review G4: what the assistant is told

    /// **An assistant's change that could not be saved and cannot be taken
    /// back cell by cell** (it deleted a row) stays in the table, and the
    /// assistant is told it goes with the writer's next save — a flush or the
    /// close saves it too, not only an edit.
    func test_anAssistantChangeThatStaysSaysItGoesWithTheNextSave() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n2026,20\n", in: projectStore)
        let host = try await open(item, store, clock: Clock())
        let folder = file(try XCTUnwrap(item.path)).deletingLastPathComponent()
        try lock(folder)

        do {
            try await host.assistantEdit { table in table.deleteRow(table.rows[2]) }
            XCTFail("the save should not have landed")
        } catch let notSaved as ResearchTableHost.NotSaved {
            XCTAssertEqual(notSaved.message, "The table’s change couldn’t be saved. It is still in the table and "
                + "will be saved with the writer’s next save, so don’t send it again.")
        }

        XCTAssertEqual(host.state.table.rows.count, 2, "the change stays in the table")
        XCTAssertTrue(host.isDirty)
        try unlock(folder)
        await host.flush()
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "10"]], "and the next save writes it")
        await store.releaseResearchTable(host)
    }

    // MARK: - Hardening 11-11 final review G3: no reload while a write is in flight

    /// What the three tests below share: a mutable box the seams write to.
    private final class Interleaving {
        var midWrite: CheckedContinuation<Void, Never>?
        var typed = false
        var saves: [Task<Void, Never>] = []
        var writes = 0
    }

    /// In a reload, after the file is read and before it lands: the writer
    /// types and takes it back (the table is as it was, the host unsaved), and
    /// the debounced save's write begins and is still in flight — it has read
    /// the file and not yet written — when the reload goes on.
    private func typeAndBeginASaveDuringTheReload(_ host: ResearchTableHost, _ steps: Interleaving) {
        let clock = Clock()
        host.now = {
            steps.midWrite?.resume()
            steps.midWrite = nil
            return clock.date
        }
        ResearchTableHost.duringReloadForTesting = { [unowned self] host in
            guard !steps.typed else { return }
            steps.typed = true
            let cell = self.key(host, 2, 2)
            let original = host.state.table[cell]
            try? await host.setCell(self.number(11), at: cell, undoManager: nil)
            try? await host.setCell(original, at: cell, undoManager: nil)
            await withCheckedContinuation { (reached: CheckedContinuation<Void, Never>) in
                steps.midWrite = reached
                steps.saves.append(Task { @MainActor in await host.saveAsTheTimerForTesting() })
            }
        }
    }

    /// **A reload never lands over a write in flight**: the file changes
    /// outside a clean grid; while it is read again the writer types and
    /// undoes, and the debounced save begins. The reload is refused — the
    /// save keeps the outside version and writes the grid's — so the grid
    /// shows what the file holds, not the other version.
    func test_aReloadDoesNotLandWhileAWriteIsInFlight() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let steps = Interleaving()
        typeAndBeginASaveDuringTheReload(host, steps)
        try Data("Year,Revenue\n2025,40\n".utf8).write(to: file(try XCTUnwrap(item.path)))

        await host.fileMayHaveChanged()
        for save in steps.saves { await save.value }

        XCTAssertTrue(steps.typed, "precondition: the reload ran, and the save began inside it")
        XCTAssertEqual(steps.saves.count, 1)
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "10"]], "the writer's table was saved")
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(10)),
                       "the grid shows what the file holds, not the outside version")
        XCTAssertFalse(host.isDirty)
        XCTAssertEqual(host.diskHash, ContentHash.of(try bytes(of: item)), "and knows the file's bytes as its own")
        XCTAssertEqual(outsideBackups(of: item).count, 1, "the outside version is kept by the save")
        XCTAssertFalse(heard.notices.contains { $0.hasPrefix("Reloaded") }, "\(heard.notices)")
        XCTAssertEqual(heard.notices.filter { $0.contains("changed outside Maugham while you were editing it") }.count, 1,
                       "\(heard.notices)")
        await store.releaseResearchTable(host)
    }

    /// **A refused reload is asked again once the write has ended**: an
    /// outside change that lands after that write is read then, and said —
    /// not left until the file changes a third time.
    func test_aReloadRefusedByAWriteInFlightHappensOnceTheWriteEnds() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let steps = Interleaving()
        typeAndBeginASaveDuringTheReload(host, steps)
        let path = file(try XCTUnwrap(item.path))
        ResearchTableHost.wroteForTesting = { _ in
            steps.writes += 1
            if steps.writes == 1 { try? Data("Year,Revenue\n2025,50\n".utf8).write(to: path) }
        }
        try Data("Year,Revenue\n2025,40\n".utf8).write(to: path)

        await host.fileMayHaveChanged()
        for save in steps.saves { await save.value }

        XCTAssertEqual(steps.writes, 1, "precondition: the save landed, and the file changed again after it")
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(50)),
                       "the later outside change is read once the write has ended")
        XCTAssertFalse(host.isDirty)
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "50"]], "nothing was written over it")
        XCTAssertEqual(host.diskHash, ContentHash.of(try bytes(of: item)))
        XCTAssertEqual(heard.notices.filter { $0.hasPrefix("Reloaded") }.count, 1, "said once: \(heard.notices)")
        await store.releaseResearchTable(host)
    }

    /// **The sequence the review named**: save N is in flight when the file
    /// is said to have changed; the writer types and the debounced save N+1
    /// queues behind N; the outside change lands as N ends. Whichever of the
    /// two the runtime wakes first, the grid ends showing the writer's table,
    /// which is what the file holds, with the outside version kept.
    func test_anOutsideChangeBetweenTwoQueuedSavesNeverReplacesTheGridMidWrite() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await researchTable("Year,Revenue\n2025,10\n", in: projectStore)
        let heard = listen()
        let host = try await open(item, store, clock: Clock())
        let path = file(try XCTUnwrap(item.path))
        let steps = Interleaving()
        let clock = Clock()
        host.now = { [unowned self, unowned host] in
            // Inside save N: it has read the file and not yet written it.
            if steps.saves.isEmpty {
                steps.saves.append(Task { @MainActor in await host.fileMayHaveChanged() })
                steps.saves.append(Task { @MainActor in
                    try? await host.setCell(self.number(12), at: self.key(host, 2, 2), undoManager: nil)
                    await host.saveAsTheTimerForTesting()
                })
            }
            return clock.date
        }
        ResearchTableHost.wroteForTesting = { _ in
            steps.writes += 1
            if steps.writes == 1 { try? Data("Year,Revenue\n2025,40\n".utf8).write(to: path) }
        }

        try await writerSavesByTheTimer(11, host)   // save N
        for save in steps.saves { await save.value }

        XCTAssertEqual(steps.saves.count, 2, "precondition: both were asked inside save N")
        XCTAssertEqual(steps.writes, 2, "precondition: N and N+1 both wrote")
        XCTAssertEqual(host.state.table[key(host, 2, 2)]?.content, .value(.number(12)),
                       "the grid shows the writer's table: \(heard.notices)")
        XCTAssertEqual(try rows(of: item), [["Year", "Revenue"], ["2025", "12"]], "which is what the file holds")
        XCTAssertFalse(host.isDirty)
        XCTAssertEqual(host.diskHash, ContentHash.of(try bytes(of: item)))
        XCTAssertEqual(outsideBackups(of: item).count, 1, "the outside version is kept")
        XCTAssertFalse(heard.notices.contains { $0.hasPrefix("Reloaded") }, "\(heard.notices)")
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
