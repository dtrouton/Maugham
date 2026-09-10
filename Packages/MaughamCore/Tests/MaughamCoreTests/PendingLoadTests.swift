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
        stranger = .softwareForTesting()
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

    // MARK: - Resolving

    /// B1: the first root that names this device is the one it is on, and a
    /// second claimant arriving later does not move it. `RegistryCache.join`
    /// owns the write-once rule; what this pins is that the resolution asks it
    /// only when nothing is joined, so a second resolve cannot re-decide.
    func test_theRootThisDeviceJoinedIsRecordedOnceAndStands() throws {
        try writeRootRecord()

        let first = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)
        XCTAssertEqual(first.myRoot, root.author.fingerprint)
        XCTAssertEqual(cache.joinedRoot(for: projectURL), root.author.fingerprint,
                       "the root this device settled on is remembered")

        // A second claimant admits this device under a root of its own.
        let claimant = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            PersonRecord(
                person: claimant.fingerprint, label: "Someone", ownName: "Another Mac",
                admittedAt: Date(timeIntervalSince1970: 40),
                admittedBy: claimant.fingerprint),
            signedBy: claimant, in: projectURL)

        let second = try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)
        XCTAssertEqual(second.myRoot, root.author.fingerprint,
                       "a device never switches roots on its own (B1)")
        XCTAssertEqual(second.verdict(forSealKey: claimant.fingerprint),
                       .otherRoot(root: claimant.fingerprint),
                       "the second root is listed as a claimant, never merged")
        XCTAssertEqual(cache.claimants(for: projectURL), [],
                       "nothing here admits this device under the second root")
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
