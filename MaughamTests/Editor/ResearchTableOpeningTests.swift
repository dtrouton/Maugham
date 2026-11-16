import XCTest
@testable import Maugham
@testable import MaughamCore

/// **A Research table's opening, shared** (#138 R2): callers that arrive while
/// the table is being read share the store's one opening
/// (`DocumentStore.openResearchTable`), and whatever comes and goes while it
/// is held, a caller is handed only the one live registered host, a closing
/// or closed host is never registered, and the use count is the number of
/// callers holding it. Each interleaving is driven by holding the load in
/// `ResearchTableHost.duringLoadForTesting` on a continuation the test
/// resumes — no sleep, no polling (tripwire 33).
@MainActor
final class ResearchTableOpeningTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []
    private var projectStores: [ProjectStore] = []   // the store holds its project weakly

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("researchopening-\(UUID().uuidString)")
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
        ResearchTableHost.duringLoadForTesting = nil
        for store in stores { await store.close() }
        stores = []
        projectStores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// A novel with one chapter, a window's stores, and one Research table.
    private func openBookWithATable() async throws -> (DocumentStore, ResearchItem) {
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
        projectStores.append(projectStore)
        projectStore.documentStore = store
        store.projectStore = projectStore

        let folder = TestTemp.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("model.csv")
        try Data("Year,Revenue\n2025,10\n".utf8).write(to: url)
        let item = try await projectStore.addResearchAsset(parentId: nil, fromURL: url)
        XCTAssertEqual(item.kind, .table, "precondition: a Research table")
        return (store, item)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    /// A caller that opens the table and keeps it. Finishing, it tells
    /// `gate` (when given) to stop waiting for a held load.
    private func holder(_ store: DocumentStore, _ id: String, _ gate: LoadGate? = nil) -> Task<ResearchTableHost, Error> {
        Task { @MainActor in
            defer { gate?.stop() }
            return try await store.openResearchTable(itemId: id)
        }
    }

    /// A caller that opens the table and lets it go the moment it has it —
    /// a grid left during its own load (`ResearchTableMount.open`).
    private func leaver(_ store: DocumentStore, _ id: String, _ gate: LoadGate? = nil) -> Task<ResearchTableHost, Error> {
        Task { @MainActor in
            defer { gate?.stop() }
            let host = try await store.openResearchTable(itemId: id)
            await store.releaseResearchTable(host)
            return host
        }
    }

    // MARK: - (a), (b) a host let go while a caller waited is not handed back

    /// **(a) A caller still waiting on the shared opening when the caller
    /// ahead of it let the host go gets a live, registered host** — and the
    /// host let go, closed meanwhile, is never registered again (b).
    ///
    /// Which waiter on one opening is back first is the runtime's choice
    /// (each hops back to the main actor through the shared pool), so the
    /// same opening is driven in trials: every trial must hold the
    /// invariants, and the leaver must be back first, letting the host go
    /// under the holder, in at least one.
    func test_aCallerWaitingOnTheOpeningGetsALiveRegisteredHostWhenTheOtherLetItGo() async throws {
        let (store, item) = try await openBookWithATable()
        var letGoUnderTheHolder = 0
        for trial in 1...Self.trials {
            let gate = LoadGate(holds: 1)
            ResearchTableHost.duringLoadForTesting = { await gate.duringLoad() }
            // Both wait on one opening, held in the load.
            let held = holder(store, item.id, gate)
            let left = leaver(store, item.id, gate)
            await gate.untilHeld(1)
            gate.release()

            let host = try await held.value
            let letGo = try await left.value
            try await store.flushPendingSave()   // every closing landed

            XCTAssertFalse(host.isClosed, "trial \(trial): the holder's host is live")
            XCTAssertTrue(store.researchTables[item.id] === host,
                          "trial \(trial): the holder's host is the registered one")
            XCTAssertEqual(store.researchTableUses[item.id], 1, "trial \(trial): one holder, one use")
            if letGo !== host {
                // The leaver was back first and let its host go under the holder.
                letGoUnderTheHolder += 1
                XCTAssertTrue(letGo.isClosed, "trial \(trial)")
                XCTAssertEqual(gate.loads, 2, "trial \(trial): the table was read again after it was let go")
            }

            ResearchTableHost.duringLoadForTesting = nil
            await store.releaseResearchTable(host)
            XCTAssertNil(store.researchTables[item.id])
            XCTAssertNil(store.researchTableUses[item.id])
            XCTAssertTrue(host.isClosed)
            if letGoUnderTheHolder > 0 { break }
        }
        XCTAssertGreaterThan(letGoUnderTheHolder, 0,
                             "premise: in \(Self.trials) trials the leaver was never back first")
    }

    /// How many times an interleaving is tried for the order it needs.
    private static let trials = 50

    /// **(b) A closed host found in the registry is replaced, never handed
    /// back**; its use count goes with it, and giving it back is a no-op.
    func test_aClosedEntryInTheRegistryIsReplacedAndNotHandedBack() async throws {
        let (store, item) = try await openBookWithATable()
        let stale = try await store.openResearchTable(itemId: item.id)
        await stale.close()   // closed while still the registered entry
        XCTAssertTrue(store.researchTables[item.id] === stale, "precondition: a closed entry")

        let gate = LoadGate(holds: 1)
        ResearchTableHost.duringLoadForTesting = { await gate.duringLoad() }
        let first = holder(store, item.id, gate)
        let second = holder(store, item.id, gate)
        await gate.untilHeld(1)
        gate.release()
        let a = try await first.value
        let b = try await second.value

        XCTAssertTrue(a === b, "both callers of the one opening get one host")
        XCTAssertFalse(a === stale, "the closed entry is not handed back")
        XCTAssertFalse(a.isClosed)
        XCTAssertTrue(store.researchTables[item.id] === a, "the closed entry was replaced")
        XCTAssertEqual(store.researchTableUses[item.id], 2, "two holders; the closed entry's use is gone")

        await store.releaseResearchTable(stale)
        XCTAssertTrue(store.researchTables[item.id] === a, "giving back the closed host is a no-op")
        XCTAssertEqual(store.researchTableUses[item.id], 2)
        await store.releaseResearchTable(a)
        await store.releaseResearchTable(b)
        XCTAssertNil(store.researchTables[item.id])
        XCTAssertNil(store.researchTableUses[item.id])
    }

    // MARK: - (c) one instance, exact counts

    /// **(c) Every caller of one opening gets the identical instance**, and
    /// its use count is the number of callers still holding it at each step.
    func test_everyCallerOfOneOpeningGetsOneHostAndTheCountIsItsHolders() async throws {
        let (store, item) = try await openBookWithATable()
        let gate = LoadGate(holds: 1)
        ResearchTableHost.duringLoadForTesting = { await gate.duringLoad() }
        let callers = (0..<3).map { _ in holder(store, item.id, gate) }
        await gate.untilHeld(1)
        gate.release()
        var hosts: [ResearchTableHost] = []
        for caller in callers { hosts.append(try await caller.value) }

        XCTAssertEqual(gate.loads, 1, "one opening, one read")
        XCTAssertTrue(hosts.allSatisfy { $0 === hosts[0] }, "the identical instance")
        XCTAssertTrue(store.researchTables[item.id] === hosts[0])
        XCTAssertEqual(store.researchTableUses[item.id], 3)

        let fourth = try await store.openResearchTable(itemId: item.id)
        XCTAssertTrue(fourth === hosts[0], "a later caller gets the registered host")
        XCTAssertEqual(store.researchTableUses[item.id], 4)
        hosts.append(fourth)

        for (index, host) in hosts.enumerated() {
            await store.releaseResearchTable(host)
            let holding = hosts.count - index - 1
            if holding > 0 {
                XCTAssertEqual(store.researchTableUses[item.id], holding)
                XCTAssertFalse(host.isClosed, "\(holding) still hold it")
            }
        }
        XCTAssertNil(store.researchTables[item.id])
        XCTAssertNil(store.researchTableUses[item.id])
        XCTAssertTrue(hosts[0].isClosed, "the last let go closes it")
    }

    // MARK: - (d) an opening that throws

    /// **(d) An opening that throws leaves no entry and no use count**, and
    /// is not kept: the next open reads the file again.
    func test_anOpeningThatThrowsLeavesNoEntryAndNoUse() async throws {
        let (store, item) = try await openBookWithATable()
        let path = file(try XCTUnwrap(item.path))
        let bytes = try Data(contentsOf: path)
        try FileManager.default.removeItem(at: path)

        // Both callers wait on the one opening, which throws.
        let first = holder(store, item.id)
        let second = holder(store, item.id)
        for caller in [first, second] {
            do {
                _ = try await caller.value
                XCTFail("the opening reads no file and throws")
            } catch {
                XCTAssertTrue(error is ResearchTableHost.Unreadable, "\(error)")
            }
        }
        XCTAssertNil(store.researchTables[item.id], "no entry")
        XCTAssertNil(store.researchTableUses[item.id], "no use count")

        try bytes.write(to: path)
        let host = try await store.openResearchTable(itemId: item.id)
        XCTAssertTrue(store.researchTables[item.id] === host, "the failed opening was not kept")
        XCTAssertEqual(store.researchTableUses[item.id], 1)
        await store.releaseResearchTable(host)
    }

    // MARK: - The bound

    /// **A table let go before the caller is back, twice, throws** rather
    /// than open it a third time for that caller: the second opening is let
    /// go too. The holder
    /// asks between two leavers on each side, and trials run until it is
    /// back behind a leaver from both openings (see (a) on the order).
    func test_anOpeningLetGoTwiceBeforeTheCallerIsBackThrows() async throws {
        let (store, item) = try await openBookWithATable()
        var thrown = 0
        for trial in 1...Self.trials {
            let gate = LoadGate(holds: 2)
            ResearchTableHost.duringLoadForTesting = { await gate.duringLoad() }
            let before = [leaver(store, item.id), leaver(store, item.id)]
            let held = holder(store, item.id, gate)
            let leavers = before + [leaver(store, item.id), leaver(store, item.id)]
            await gate.untilHeld(1)
            gate.release()
            await gate.untilHeld(2)
            gate.release()

            var host: ResearchTableHost?
            do {
                host = try await held.value
            } catch {
                XCTAssertTrue(error is ResearchTableHost.ClosedWhileOpening, "trial \(trial): \(error)")
                thrown += 1
            }
            for leaver in leavers { _ = try? await leaver.value }
            try await store.flushPendingSave()
            if let host {
                XCTAssertFalse(host.isClosed, "trial \(trial): a host handed back is live")
                XCTAssertTrue(store.researchTables[item.id] === host, "trial \(trial)")
                XCTAssertEqual(store.researchTableUses[item.id], 1, "trial \(trial)")
                await store.releaseResearchTable(host)
            } else {
                XCTAssertGreaterThanOrEqual(gate.loads, 2, "trial \(trial): opened twice before it threw")
            }
            XCTAssertNil(store.researchTables[item.id], "trial \(trial): every host was let go")
            XCTAssertNil(store.researchTableUses[item.id], "trial \(trial)")
            if thrown > 0 { break }
        }
        XCTAssertGreaterThan(thrown, 0, "premise: in \(Self.trials) trials the holder was never back last twice")

        ResearchTableHost.duringLoadForTesting = nil
        let host = try await store.openResearchTable(itemId: item.id)
        XCTAssertFalse(host.isClosed)
        XCTAssertEqual(store.researchTableUses[item.id], 1)
        await store.releaseResearchTable(host)
    }
}

/// Holds the first `holds` loads in `ResearchTableHost.load` (its
/// `duringLoadForTesting` seam) until the test lets them go; later loads
/// pass straight through.
@MainActor
private final class LoadGate {
    let holds: Int
    /// Loads that reached the seam.
    private(set) var loads = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldEver = 0
    private var stopped = false
    private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    init(holds: Int) { self.holds = holds }

    func duringLoad() async {
        loads += 1
        guard loads <= holds else { return }
        await withCheckedContinuation { continuation in
            held.append(continuation)
            heldEver += 1
            wakeIfDue()
        }
    }

    /// Returns once `count` loads have been held — or once `stop()` says
    /// nothing more will reach the seam.
    func untilHeld(_ count: Int) async {
        guard heldEver < count, !stopped else { return }
        await withCheckedContinuation { waiter = (count, $0) }
    }

    /// Lets every held load go on.
    func release() {
        let going = held
        held = []
        for continuation in going { continuation.resume() }
    }

    /// The subject finished: stop waiting for a load that will not come.
    func stop() {
        stopped = true
        if let waiter { self.waiter = nil; waiter.continuation.resume() }
    }

    private func wakeIfDue() {
        guard let waiter, heldEver >= waiter.count else { return }
        self.waiter = nil
        waiter.continuation.resume()
    }
}
