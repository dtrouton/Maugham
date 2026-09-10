import Foundation
import XCTest
@testable import MaughamCore

/// **Pending** — what a load does with a sealed span whose key this device's
/// chain says nothing about (spec §3).
///
/// The four states a foreign seal can be in, all four exercised end to end
/// through a real project directory, a real registry folder and the real
/// `OpLogStore` load:
///
/// | The registry says | The lines are | Applied? | Recorded? |
/// |---|---|---|---|
/// | nothing about this key, and there IS a chain | `pending` | no | no |
/// | that key is admitted | `verified` | yes | — |
/// | there is no chain here at all (B3) | `unsignedHistory` | yes | — |
/// | that key was admitted and revoked | `quarantined` | no | a `.lines` record |
///
/// The middle two are P1's behaviour, and the third is the arm every existing
/// suite in this package runs on: a project with no `.maugham/people` resolves
/// to `.noChain`, so nothing in P1 moved.
@MainActor
final class PendingLoadTests: XCTestCase {

    private let docId = "doc-pending"
    private var projectURL: URL!

    /// The root: this device, and the one that judges.
    private var root: LocalIdentities!
    private var rootState: OpLogDeviceState!
    /// A second device, unknown to the registry until a test says otherwise.
    /// Four actors, because one of the tests below is about a device that has
    /// written as two of them.
    private var strangerDevice: LocalIdentities!
    private var stranger: DeviceIdentity!
    private var strangerState: OpLogDeviceState!
    /// A third device in nobody's chain, used to read the same project.
    private var outsider: LocalIdentities!
    private var outsiderState: OpLogDeviceState!

    /// A registry memory of this suite's own, so nothing here reaches the
    /// process-wide cache beside the machine's real keys.
    private var cache: RegistryCache!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        root = .softwareForTesting()
        strangerDevice = .softwareForTesting()
        stranger = strangerDevice.author
        outsider = .softwareForTesting()
        rootState = state("root")
        strangerState = state("stranger")
        outsiderState = state("outsider")
        cache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: root.author.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func state(_ name: String) -> OpLogDeviceState {
        OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state-\(name).json"))
    }

    // MARK: - Fixtures

    private func op(_ opId: String, device: DeviceIdentity) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: device.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: opId)],
           sequence: ["aaaa"])
    }

    /// The root's own self-signed person record: this device admitted itself,
    /// which is what gives it a chain to judge by at all.
    private func writeRootRecord() throws {
        let record = PersonRecord(
            person: root.author.fingerprint, label: "Denver",
            ownName: "Denver's MacBook",
            admittedAt: Date(timeIntervalSince1970: 10),
            admittedBy: root.author.fingerprint)
        try RegistryWriter.write(record, signedBy: root.author, in: projectURL)
    }

    /// The root's word about the stranger — admitted, or admitted and revoked.
    private func writeStrangerRecord(
        revokedAt: Date? = nil, highestOpIdSeen: String? = nil
    ) throws {
        let record = PersonRecord(
            person: stranger.fingerprint, label: "Denver",
            ownName: "Denver's other Mac",
            admittedAt: Date(timeIntervalSince1970: 20),
            admittedBy: root.author.fingerprint,
            revokedAt: revokedAt,
            revokedBy: revokedAt == nil ? nil : root.author.fingerprint,
            highestOpIdSeen: highestOpIdSeen)
        try RegistryWriter.write(record, signedBy: root.author, in: projectURL)
    }

    /// `person` admitted under `rootIdentity`'s chain — self-signed when the
    /// two are the same key, which is what makes `rootIdentity` a root.
    private func admit(
        _ person: String, under rootIdentity: DeviceIdentity, at seconds: TimeInterval
    ) throws {
        try RegistryWriter.write(
            PersonRecord(
                person: person, label: "Denver", ownName: "A Mac",
                admittedAt: Date(timeIntervalSince1970: seconds),
                admittedBy: rootIdentity.fingerprint),
            signedBy: rootIdentity, in: projectURL)
    }

    /// The stranger's own per-device file: chained and sealed under its key.
    @discardableResult
    private func writeStrangerFile(_ opIds: [String]) async throws -> Int {
        let store = OpLogStore(
            projectURL: projectURL, identity: stranger, state: strangerState)
        for id in opIds { try await store.append(op(id, device: stranger)) }
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed, "the stranger's file is sealed")
        return opIds.count + 1   // the ops, plus the one seal line
    }

    /// This device's own file, chained and sealed under its author key.
    private func writeMyOwnFile(_ opIds: [String]) async throws {
        let store = reader()
        for id in opIds { try await store.append(op(id, device: root.author)) }
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed, "this device's own file is sealed")
    }

    private func reader() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: root,
                   state: rootState, cache: cache)
    }

    private func linesRecords() -> [QuarantineRecord] {
        OpLogQuarantine.records(forDocId: docId, in: projectURL)
            .filter { $0.kind == .lines }
    }

    // MARK: - A stranger's span is HELD

    func test_aStrangersSealedSpanIsHeldRatherThanApplied() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        let strangerLines = try await writeStrangerFile(["02", "03"])

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01"],
                       "only this device's own op is applied")
        XCTAssertEqual(load.provenance.pendingLines, strangerLines,
                       "every line of the stranger's file is held")
        XCTAssertEqual(load.provenance.quarantinedLines, 0,
                       "held is not quarantined — nothing broke")
        XCTAssertEqual(load.provenance.unsignedHistoryLines, 0,
                       "there IS a chain here, so nothing falls back to B3")

        let strangersFile = load.provenance.files.first {
            $0.name.contains(stranger.slug.raw)
        }
        XCTAssertEqual(strangersFile?.pendingByDevice[stranger.fingerprint],
                       strangerLines,
                       "held lines are counted under the key that sealed them")
    }

    func test_holdingALineRecordsNothingAnywhere() async throws {
        try writeRootRecord()
        try await writeStrangerFile(["02"])

        _ = try await reader().loadDiagnosed(docId: docId)

        XCTAssertTrue(linesRecords().isEmpty,
                      "a held line is not forensics — the writer admits the device or does not")
    }

    // MARK: - Admitting applies what was held

    func test_admittingTheStrangerAppliesEverythingItHeld() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        try await writeStrangerFile(["02", "03"])

        let before = try await reader().loadDiagnosed(docId: docId)
        XCTAssertEqual(before.ops.map(\.opId), ["01"])

        try writeStrangerRecord()

        let after = try await reader().loadDiagnosed(docId: docId)
        XCTAssertEqual(after.ops.map(\.opId), ["01", "02", "03"],
                       "admission re-reads; nothing was rewritten to make it apply")
        XCTAssertEqual(after.provenance.pendingLines, 0)
        XCTAssertEqual(after.provenance.quarantinedLines, 0)
        XCTAssertEqual(after.provenance.unsignedHistoryLines, 0,
                       "an admitted device's word is verified, not history")
    }

    // MARK: - No chain at all (decision B3)

    func test_withNoChainOfItsOwnAReaderAppliesEveryonesLinesAsUnsignedHistory() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        try await writeStrangerFile(["02", "03"])

        // A third device: not the root, not admitted, and with a memory of its
        // own that has never joined anything.
        let outsiderCache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("outsider-cache.json"),
            identity: outsider.author.fingerprint)
        let load = try await OpLogStore(
            projectURL: projectURL, identities: outsider,
            state: outsiderState, cache: outsiderCache
        ).loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01", "02", "03"],
                       "a device that judges nobody applies everything (B3)")
        XCTAssertEqual(load.provenance.pendingLines, 0,
                       "nothing is held by a reader with no chain")
        XCTAssertEqual(load.provenance.quarantinedLines, 0)
        XCTAssertGreaterThan(load.provenance.unsignedHistoryLines, 0)
        XCTAssertEqual(load.provenance.verifiedLines, 0,
                       "none of these keys is the outsider's own")
    }

    // MARK: - Revoked

    func test_aRevokedDevicesSpanIsQuarantinedInTheRevocationsOwnWords() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        let strangerLines = try await writeStrangerFile(["02", "03"])
        try writeStrangerRecord(
            revokedAt: Date(timeIntervalSince1970: 30), highestOpIdSeen: "01")

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01"],
                       "a revoked device's ops are refused, not held")
        XCTAssertEqual(load.provenance.quarantinedLines, strangerLines)
        XCTAssertEqual(load.provenance.pendingLines, 0,
                       "revocation is a fact about a key, never a silence about it")

        let record = linesRecords().first
        XCTAssertEqual(record?.reason, "written after this device's access was withdrawn")
    }

    // MARK: - Held lines are counted per DEVICE

    /// A device holds four actor keys. A phone that has written as both its
    /// author and its assistant is ONE device waiting for admission, and a
    /// count keyed on the seal's key would say two.
    func test_twoActorKeysOfOneDeviceAreOneDeviceWaiting() async throws {
        try writeRootRecord()
        // The stranger's own device record, which is what maps its assistant
        // key back to it. Self-signed by its author key, as the reader requires.
        try RegistryWriter.write(
            DeviceRecord(
                device: stranger.fingerprint, name: "Denver's iPhone", kind: .phone,
                actors: [
                    DeviceActor.author.rawValue: stranger.fingerprint,
                    DeviceActor.assistant.rawValue: strangerDevice.assistant.fingerprint,
                ],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: stranger, in: projectURL)

        let store = OpLogStore(
            projectURL: projectURL, identities: strangerDevice, state: strangerState)
        try await store.append(op("02", device: strangerDevice.author))
        try await store.append(op("03", device: strangerDevice.assistant))
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed, "both of the stranger's actor files are sealed")

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.count, 0, "nothing the stranger wrote is applied")
        XCTAssertEqual(load.provenance.pendingLines, 4,
                       "two ops and two seals, over two files")
        XCTAssertEqual(load.provenance.pendingByDevice,
                       [stranger.fingerprint: 4],
                       "one device is waiting, not two")
    }

    // MARK: - Resolving

    /// A Mac that is its own root joins nothing: there is no chain of anybody
    /// else's for it to be on, and a join recorded here would have every
    /// surface that reads it say *this Mac joined its own chain*.
    func test_aDeviceThatIsItsOwnRootJoinsNothing() throws {
        try writeRootRecord()

        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertEqual(table.myRoot, root.author.fingerprint)
        XCTAssertEqual(table.rootSource, .ownRecord)
        XCTAssertEqual(table.admittingRoots, [])
        XCTAssertNil(cache.joinedRoot(for: projectURL),
                     "being your own root is not joining one")
    }

    /// B1, both halves: the FOREIGN root that first names this device is
    /// joined, and a second one arriving later is recorded as a claimant while
    /// the join stands.
    func test_theFirstForeignRootIsJoinedAndTheSecondIsAClaimant() throws {
        // This device is nobody's root here; two other Macs each admit it.
        let first = DeviceIdentity.softwareForTesting()
        let second = DeviceIdentity.softwareForTesting()
        try admit(first.fingerprint, under: first, at: 10)     // the first root itself
        try admit(root.author.fingerprint, under: first, at: 20)

        let joined = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)
        XCTAssertEqual(joined.rootSource, .admitted)
        XCTAssertEqual(joined.myRoot, first.fingerprint)
        XCTAssertEqual(cache.joinedRoot(for: projectURL), first.fingerprint,
                       "the root that took this device in is the one it is on")
        XCTAssertEqual(cache.claimants(for: projectURL), [])

        // Now a second root sets itself up and claims this device too.
        try admit(second.fingerprint, under: second, at: 30)   // the second root itself
        try admit(root.author.fingerprint, under: second, at: 40)

        let claimed = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)
        XCTAssertEqual(claimed.myRoot, first.fingerprint,
                       "a device never switches roots on its own (B1)")
        XCTAssertEqual(claimed.rootSource, .joined)
        XCTAssertEqual(cache.claimants(for: projectURL), [second.fingerprint],
                       "the second claimant is recorded, loudly, and never merged")
    }

    /// The registry folder deleted wholesale is a vanished chain, not the
    /// absence of one: this device's memory puts the records back.
    func test_aRegistryDeletedWholesaleIsRestoredRatherThanBelieved() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        try await writeStrangerFile(["02"])
        _ = try await reader().loadDiagnosed(docId: docId)   // remembers the registry

        for directory in RegistryDirectory.allCases {
            try? FileManager.default.removeItem(
                at: RegistryWriter.directoryURL(directory, in: projectURL))
        }
        XCTAssertFalse(TrustResolution.hasRegistry(in: projectURL))

        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertEqual(table.myRoot, root.author.fingerprint,
                       "the chain is what it was; deleting a folder does not end it")
        XCTAssertEqual(table.verdict(forSealKey: stranger.fingerprint),
                       .stranger(device: nil),
                       "and the stranger is still held, not applied as unsigned history")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: RegistryWriter.url(
                    .people, fingerprint: root.author.fingerprint,
                    in: projectURL).path),
            "the record is put back where it was")
    }

    /// A project with no registry folder at all answers `.noChain` and touches
    /// nothing: no read, and no cache entry minted for having been opened. That
    /// is every project written before this milestone, so it is also the arm
    /// every other suite in this package runs on.
    func test_aProjectWithNoRegistryResolvesToNoChainAndRemembersNothing() throws {
        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)

        XCTAssertNil(table.myRoot)
        XCTAssertEqual(table.verdict(forSealKey: stranger.fingerprint), .noChain,
                       "with no chain, nobody is judged (B3)")
        XCTAssertEqual(table.verdict(forSealKey: root.assistant.fingerprint), .mine,
                       "a device still knows its own hand")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path),
                       "opening a project that never joined a chain writes nothing")
    }

    /// Spec §4.1: admitting a device applies what it was holding on the next
    /// READ, not on the next window. The store re-resolves when the registry
    /// folder has changed under it.
    func test_admittingOnALiveStoreAppliesTheHeldOpsOnTheNextRead() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        try await writeStrangerFile(["02", "03"])

        let store = reader()
        let before = try await store.loadDiagnosed(docId: docId)
        XCTAssertEqual(before.ops.map(\.opId), ["01"])

        try writeStrangerRecord()

        let after = try await store.loadDiagnosed(docId: docId)
        XCTAssertEqual(after.ops.map(\.opId), ["01", "02", "03"],
                       "the same store, re-resolved because the registry changed")
        XCTAssertEqual(after.provenance.pendingLines, 0)
    }

    /// And the explicit door, for the caller that just wrote the record itself
    /// and should not have to hope a modification time moved far enough.
    func test_invalidatingTheTableMakesTheNextReadResolveAfresh() async throws {
        try writeRootRecord()
        try await writeStrangerFile(["02"])

        let store = reader()
        _ = try await store.loadDiagnosed(docId: docId)
        try writeStrangerRecord()
        store.invalidateTrust()

        let after = try await store.loadDiagnosed(docId: docId)
        XCTAssertEqual(after.ops.map(\.opId), ["02"])
    }

    // MARK: - An unreadable registry record (RULING-54)

    /// A record that is present and cannot be read refuses the load by name.
    /// Judging nobody instead would apply a stranger's whole history as this
    /// project's own, silently — the shape RULING-54 exists to forbid.
    func test_anUnreadableRegistryRecordRefusesTheLoadByName() async throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file, so nothing is refused")
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        let record = RegistryWriter.url(
            .people, fingerprint: root.author.fingerprint, in: projectURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: record.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: record.path)
        }

        do {
            _ = try await reader().loadDiagnosed(docId: docId)
            XCTFail("an unreadable registry record must refuse the load")
        } catch let error as OpLogStore.ReadError {
            guard case let .unreadableFile(name, _, kind) = error else {
                return XCTFail("the wrong ReadError: \(error)")
            }
            XCTAssertEqual(name, record.lastPathComponent)
            XCTAssertEqual(kind, .registry)
        }

        XCTAssertThrowsError(
            try OpLogStore.loadSyncMerged(
                forDocId: docId, in: projectURL, identities: root, state: rootState),
            "the synchronous reader refuses it too")
    }

    /// The read-only recovery rung does not refuse the whole document over it —
    /// but it does not swallow it either. The record is NAMED beside whatever
    /// op-log files could not be opened.
    func test_theReadOnlyRungNamesTheUnreadableRecordRatherThanSwallowingIt() async throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file, so nothing is refused")
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        let record = RegistryWriter.url(
            .people, fingerprint: root.author.fingerprint, in: projectURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: record.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: record.path)
        }

        let partial = await reader().loadDiagnosedPartial(docId: docId)

        XCTAssertEqual(partial.ops.map(\.opId), ["01"],
                       "the rung applies what it can read")
        XCTAssertTrue(
            partial.unreadableFiles.contains { $0.name == record.lastPathComponent },
            "and names the record that stopped it judging anyone")
    }

    // MARK: - Another claimant's

    func test_aSecondClaimantsSpanIsQuarantinedInItsOwnWords() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        let strangerLines = try await writeStrangerFile(["02"])

        // A second root, which admitted the stranger into ITS chain.
        let claimant = DeviceIdentity.softwareForTesting()
        try admit(claimant.fingerprint, under: claimant, at: 30)
        try admit(stranger.fingerprint, under: claimant, at: 40)

        let load = try await reader().loadDiagnosed(docId: docId)

        XCTAssertEqual(load.ops.map(\.opId), ["01"])
        XCTAssertEqual(load.provenance.quarantinedLines, strangerLines)
        XCTAssertEqual(load.provenance.pendingLines, 0,
                       "a claimant's chain is refused, never merely held")
        XCTAssertEqual(linesRecords().first?.reason,
                       "written under another claimant's copy of this book")
    }

    // MARK: - The two readers agree

    func test_theSynchronousReaderHoldsExactlyWhatTheCoordinatedOneHeld() async throws {
        try writeRootRecord()
        try await writeMyOwnFile(["01"])
        try await writeStrangerFile(["02", "03"])

        let coordinated = try await reader().loadDiagnosed(docId: docId)
        let synchronous = try OpLogStore.loadSyncMerged(
            forDocId: docId, in: projectURL,
            identities: root, state: rootState,
            trust: try TrustResolution.resolve(
                projectURL: projectURL, identities: root, cache: cache))

        XCTAssertEqual(synchronous.map(\.opId), coordinated.ops.map(\.opId))
    }
}
