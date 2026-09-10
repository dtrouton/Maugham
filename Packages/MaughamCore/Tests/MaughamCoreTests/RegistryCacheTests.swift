import CryptoKit
import Foundation
import XCTest
@testable import MaughamCore

/// The device's own memory of the registry it last verified — and what it does
/// when the folder no longer agrees with that memory.
///
/// Two things are being pinned here. The first is that a record someone deleted
/// comes BACK, byte for byte, and is reported rather than restored quietly: the
/// bytes are signed, so putting them back cannot forge anything, and a device
/// that silently lost its own admission is a trust decision nobody made. The
/// second is B1 — the root this device joined is written once and never
/// overwritten; a second root is a claimant, listed beside it.
final class RegistryCacheTests: XCTestCase {

    private var projectURL: URL!
    private var cacheURL: URL!
    private var root: DeviceIdentity!
    private var phone: DeviceIdentity!
    private var otherRoot: DeviceIdentity!

    override func setUp() {
        super.setUp()
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-cache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham"),
            withIntermediateDirectories: true)
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-cache-file-\(UUID().uuidString).json")
        root = .softwareForTesting()
        phone = .softwareForTesting()
        otherRoot = .softwareForTesting()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeCache(identity: String = "device-under-test") -> RegistryCache {
        RegistryCache(fileURL: cacheURL, identity: identity)
    }

    private func rootRecord(_ identity: DeviceIdentity) -> PersonRecord {
        PersonRecord(
            person: identity.fingerprint, label: "Denver", ownName: "Denver's MacBook",
            admittedAt: Date(timeIntervalSince1970: 10), admittedBy: identity.fingerprint)
    }

    private func admittedRecord(
        _ identity: DeviceIdentity, under rootIdentity: DeviceIdentity
    ) -> PersonRecord {
        PersonRecord(
            person: identity.fingerprint, label: "Denver", ownName: "Denver's iPhone",
            admittedAt: Date(timeIntervalSince1970: 20),
            admittedBy: rootIdentity.fingerprint)
    }

    private func deviceRecord(
        _ identity: DeviceIdentity, actors: [String: String]? = nil
    ) -> DeviceRecord {
        DeviceRecord(
            device: identity.fingerprint, name: "Denver's MacBook", kind: .mac,
            actors: actors ?? ["author": identity.fingerprint],
            madeAt: Date(timeIntervalSince1970: 5))
    }

    /// A root, a device record for it, and a phone it admitted — the smallest
    /// registry with something in each of the two populated directories.
    @discardableResult
    private func writeASmallRegistry() throws -> Registry {
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        try RegistryWriter.write(deviceRecord(root), signedBy: root, in: projectURL)
        try RegistryWriter.write(admittedRecord(phone, under: root), signedBy: root, in: projectURL)
        return try RegistryReader.load(projectURL: projectURL)
    }

    // MARK: - The key

    func test_theCacheKeysAProjectByTheSameHashTheOpLogHeadsDo() throws {
        let opLogFile = projectURL
            .appendingPathComponent(".maugham/ops/doc.jsonl")
        let headKey = OpLogDeviceState.fileKey(opLogFile)
        let hashHalf = String(headKey.prefix { $0 != "/" })

        XCTAssertEqual(
            RegistryCache.projectKey(projectURL), hashHalf,
            "one project, one hash — the cache must not invent a second key")
    }

    // MARK: - Round trip

    func test_aRememberedRegistrySurvivesAReload() throws {
        let registry = try writeASmallRegistry()
        makeCache().remember(registry, for: projectURL)

        let reloaded = try XCTUnwrap(makeCache().cached(for: projectURL))
        XCTAssertEqual(reloaded.people.map(\.person), registry.people.map(\.person))
        XCTAssertEqual(reloaded.devices.map(\.device), registry.devices.map(\.device))
        XCTAssertEqual(reloaded.people.first?.sig, registry.people.first?.sig,
                       "records are remembered as read, signature included")
    }

    func test_aProjectNeverSeenIsRememberedAsNothing() {
        XCTAssertNil(makeCache().cached(for: projectURL))
    }

    func test_aCacheBelongingToAnotherDeviceStartsEmpty() throws {
        let registry = try writeASmallRegistry()
        makeCache(identity: "one-device").remember(registry, for: projectURL)

        let other = makeCache(identity: "another-device")
        XCTAssertNil(other.cached(for: projectURL),
                     "another device's memory is not this device's word about anything")

        // And it is rewritten, not merely ignored — the first device's memory
        // must not come back the moment anything else opens the file.
        other.remember(registry, for: projectURL)
        XCTAssertNil(makeCache(identity: "one-device").cached(for: projectURL))
    }

    // MARK: - Restoring what someone removed

    func test_aDeletedPersonRecordIsRestoredByteIdenticalAndReported() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)

        let url = RegistryWriter.url(.people, fingerprint: phone.fingerprint, in: projectURL)
        let before = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)

        let folder = try RegistryReader.load(projectURL: projectURL)
        XCTAssertFalse(folder.people.contains { $0.person == self.phone.fingerprint })

        let outcome = try cache.reconcile(
            folder: folder, cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(outcome.removedBySomeone,
                       [RecordRef(directory: .people, fingerprint: phone.fingerprint)])
        XCTAssertEqual(outcome.restored, [url])
        XCTAssertEqual(try Data(contentsOf: url), before,
                       "restored byte for byte — the bytes were already signed")
        XCTAssertTrue(outcome.registry.people.contains { $0.person == self.phone.fingerprint },
                      "the answer reconcile gives already holds the record it put back")

        let reread = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(reread.malformed, [], "and the restored record still verifies")
        XCTAssertTrue(reread.people.contains { $0.person == self.phone.fingerprint })
    }

    func test_aDeletedDeviceRecordIsRestoredToTheDevicesDirectory() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)

        let url = RegistryWriter.url(.devices, fingerprint: root.fingerprint, in: projectURL)
        try FileManager.default.removeItem(at: url)

        let outcome = try cache.reconcile(
            folder: try RegistryReader.load(projectURL: projectURL),
            cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(outcome.removedBySomeone,
                       [RecordRef(directory: .devices, fingerprint: root.fingerprint)])
        XCTAssertEqual(outcome.registry.devices.map(\.device), [root.fingerprint])
    }

    func test_aDeletedClaimIsRestoredToTheClaimsDirectory() throws {
        try RegistryWriter.write(
            ClaimRecord(newRoot: root.fingerprint, adopted: [otherRoot.fingerprint],
                        claimedAt: Date(timeIntervalSince1970: 30)),
            signedBy: root, in: projectURL)
        let cache = makeCache()
        cache.remember(try RegistryReader.load(projectURL: projectURL), for: projectURL)

        let url = RegistryWriter.url(.claims, fingerprint: root.fingerprint, in: projectURL)
        try FileManager.default.removeItem(at: url)

        let outcome = try cache.reconcile(
            folder: try RegistryReader.load(projectURL: projectURL),
            cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(outcome.removedBySomeone,
                       [RecordRef(directory: .claims, fingerprint: root.fingerprint)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_aFolderThatStillHasEverythingRestoresNothing() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)

        let outcome = try cache.reconcile(
            folder: registry, cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(outcome.restored, [])
        XCTAssertEqual(outcome.removedBySomeone, [])
        XCTAssertEqual(outcome.registry.people.map(\.person), registry.people.map(\.person))
    }

    func test_withNothingRememberedTheFolderIsTheAnswer() throws {
        let registry = try writeASmallRegistry()
        let outcome = try makeCache().reconcile(
            folder: registry, cached: nil, in: projectURL)

        XCTAssertEqual(outcome.restored, [])
        XCTAssertEqual(outcome.registry, registry)
    }

    func test_theRestoreDoorWritesTheBytesItIsGivenAndSignsNothing() throws {
        let bytes = Data("not a record at all".utf8)
        let url = try RegistryWriter.restore(
            rawBytes: bytes, to: .people, fingerprint: "abc", in: projectURL)

        XCTAssertEqual(try Data(contentsOf: url), bytes,
                       "the bytes go down as they came up — restoring never re-signs")
        XCTAssertEqual(
            url, RegistryWriter.url(.people, fingerprint: "abc", in: projectURL))
        XCTAssertEqual(try RegistryReader.load(projectURL: projectURL).malformed.count, 1,
                       "and the reader still holds the only opinion about what a record is")
    }

    // MARK: - When the two disagree

    func test_aReSignedDeviceRecordFromTheFolderWins() throws {
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        try RegistryWriter.write(deviceRecord(root), signedBy: root, in: projectURL)
        let cache = makeCache()
        cache.remember(try RegistryReader.load(projectURL: projectURL), for: projectURL)

        // The device mints an assistant key and re-signs its own record.
        let assistant = DeviceIdentity.softwareForTesting(actor: .assistant)
        let widened = deviceRecord(
            root, actors: ["author": root.fingerprint, "assistant": assistant.fingerprint])
        try RegistryWriter.write(widened, signedBy: root, in: projectURL)

        let folder = try RegistryReader.load(projectURL: projectURL)
        let outcome = try cache.reconcile(
            folder: folder, cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(outcome.restored, [], "a legitimate re-sign is not a removal")
        XCTAssertEqual(outcome.registry.devices.first?.actors, widened.actors,
                       "the folder's verified record wins over the remembered one")
        XCTAssertEqual(
            makeCache().cached(for: projectURL)?.devices.first?.actors, widened.actors,
            "and the memory moves on to what it just verified")
    }

    func test_aTamperedFolderRecordIsReplacedFromTheCacheAndListedMalformed() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)

        let url = RegistryWriter.url(.people, fingerprint: phone.fingerprint, in: projectURL)
        let honest = try Data(contentsOf: url)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count / 2] = bytes[bytes.count / 2] == 0x61 ? 0x62 : 0x61
        try bytes.write(to: url)

        let folder = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(folder.malformed.count, 1, "the reader lists what it cannot vouch for")

        let outcome = try cache.reconcile(
            folder: folder, cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(outcome.removedBySomeone,
                       [RecordRef(directory: .people, fingerprint: phone.fingerprint)])
        XCTAssertEqual(try Data(contentsOf: url), honest,
                       "the cache's bytes replace what no longer verifies")
        XCTAssertEqual(outcome.registry.malformed, folder.malformed,
                       "and the malformed listing is carried out, not swallowed")
    }

    func test_reconcileRemembersWhatItResolved() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)

        let url = RegistryWriter.url(.people, fingerprint: phone.fingerprint, in: projectURL)
        try FileManager.default.removeItem(at: url)
        _ = try cache.reconcile(
            folder: try RegistryReader.load(projectURL: projectURL),
            cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(
            makeCache().cached(for: projectURL)?.people.map(\.person).sorted(),
            registry.people.map(\.person).sorted(),
            "the memory reloads holding the registry reconcile settled on")
    }

    // MARK: - B1: the root this device joined

    func test_theJoinedRootSurvivesAReload() {
        let cache = makeCache()
        XCTAssertNil(cache.joinedRoot(for: projectURL))

        XCTAssertEqual(cache.join(root: root.fingerprint, for: projectURL), root.fingerprint)
        XCTAssertEqual(makeCache().joinedRoot(for: projectURL), root.fingerprint)
    }

    func test_aSecondRootIsRecordedAsAClaimantAndTheJoinIsUnchanged() {
        let cache = makeCache()
        cache.join(root: root.fingerprint, for: projectURL)

        let answer = cache.join(root: otherRoot.fingerprint, for: projectURL)

        XCTAssertEqual(answer, root.fingerprint, "first admission wins (B1)")
        XCTAssertEqual(cache.joinedRoot(for: projectURL), root.fingerprint)
        XCTAssertEqual(cache.claimants(for: projectURL), [otherRoot.fingerprint])
        XCTAssertEqual(makeCache().claimants(for: projectURL), [otherRoot.fingerprint],
                       "and the claimant is remembered, not merely reported once")
    }

    func test_joiningTheSameRootTwiceClaimsNothing() {
        let cache = makeCache()
        cache.join(root: root.fingerprint, for: projectURL)
        cache.join(root: root.fingerprint, for: projectURL)

        XCTAssertEqual(cache.claimants(for: projectURL), [])
    }

    func test_theSameClaimantIsListedOnce() {
        let cache = makeCache()
        cache.join(root: root.fingerprint, for: projectURL)
        cache.join(root: otherRoot.fingerprint, for: projectURL)
        cache.join(root: otherRoot.fingerprint, for: projectURL)

        XCTAssertEqual(cache.claimants(for: projectURL), [otherRoot.fingerprint])
    }

    func test_rememberingARegistryLeavesTheJoinAlone() throws {
        let cache = makeCache()
        cache.join(root: root.fingerprint, for: projectURL)
        cache.remember(try writeASmallRegistry(), for: projectURL)

        XCTAssertEqual(cache.joinedRoot(for: projectURL), root.fingerprint)
    }

    // MARK: - Pruning (the same two-clause rule as the op-log heads)

    func test_aProjectDeletedFromASurvivingParentIsForgotten() throws {
        let cache = makeCache()
        cache.remember(try writeASmallRegistry(), for: projectURL)
        cache.join(root: root.fingerprint, for: projectURL)

        try FileManager.default.removeItem(at: projectURL)

        let reloaded = makeCache()
        XCTAssertNil(reloaded.cached(for: projectURL))
        XCTAssertNil(reloaded.joinedRoot(for: projectURL))
    }

    func test_aProjectOnAnUnmountedVolumeKeepsItsMemory() throws {
        let volume = FileManager.default.temporaryDirectory
            .appendingPathComponent("volume-\(UUID().uuidString)")
        let project = volume.appendingPathComponent("Book")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".maugham"), withIntermediateDirectories: true)
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: project)

        let cache = makeCache()
        cache.remember(try RegistryReader.load(projectURL: project), for: project)
        cache.join(root: root.fingerprint, for: project)

        // The whole path goes, parent included — an unmounted volume, not a
        // deleted project.
        try FileManager.default.removeItem(at: volume)

        let reloaded = makeCache()
        XCTAssertNotNil(reloaded.cached(for: project),
                        "an absent volume is not a deleted project (D3′)")
        XCTAssertEqual(reloaded.joinedRoot(for: project), root.fingerprint)
    }
}
