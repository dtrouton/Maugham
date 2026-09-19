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

    // MARK: - The deliberate restore (P2 smoke find 1)

    /// **`reconcile` leaves a tampered record exactly where it is, and that was
    /// the whole problem.** A device cannot tell *tampered with* from *damaged
    /// in transit*, so it must not overwrite somebody's signed record on its own
    /// initiative — which left the record with no way back at all, and this Mac
    /// reading as *not yet admitted* on its own book. A writer looking at the
    /// row, told in words what is wrong with it, is a different thing: this is
    /// the press.
    func test_awriterPutsBackARecordThatWillNotVerify() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)

        let ref = RecordRef(directory: .people, fingerprint: root.fingerprint)
        let url = RegistryWriter.url(.people, fingerprint: root.fingerprint, in: projectURL)
        let before = try Data(contentsOf: url)

        // Somebody edits the label after it was signed.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: before) as? [String: Any])
        object["label"] = "Somebody else"
        try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        ).write(to: url, options: .atomic)
        // The reader refuses it — and, because it is the ROOT, everyone it
        // admitted goes with it: a chain hangs off one signature, which is why
        // an unverifiable record with no way back was worth a surface.
        let refused = try RegistryReader.load(projectURL: projectURL).malformed
        XCTAssertTrue(
            refused.contains { $0.ref == ref && $0.reason == .signatureDoesNotVerify },
            "the edited root: \(refused.map(\.reason))")
        XCTAssertTrue(try RegistryReader.load(projectURL: projectURL).roots.isEmpty,
                      "and the book has no root at all while it stands")

        let written = try cache.restore(
            ref, in: projectURL, at: Date(timeIntervalSince1970: 900))

        XCTAssertEqual(written, url)
        XCTAssertEqual(try Data(contentsOf: url), before, "byte for byte")
        let reread = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(reread.malformed, [], "and what went back verifies")
        XCTAssertEqual(reread.person(root.fingerprint)?.label, "Denver")
    }

    /// It is recorded with the automatic ones, because a restoration leaves
    /// nothing in the folder afterwards: the row says *put back* and History
    /// dates the event off this one list.
    func test_thedeliberateRestoreIsDatedLikeEveryOther() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)
        let ref = RecordRef(directory: .people, fingerprint: phone.fingerprint)

        try cache.restore(ref, in: projectURL, at: Date(timeIntervalSince1970: 900))

        XCTAssertEqual(cache.restores(for: projectURL),
                       [RestoredRecord(ref: ref, restoredAt: Date(timeIntervalSince1970: 900))])
        XCTAssertEqual(makeCache().restores(for: projectURL).count, 1,
                       "and it survives the launch that draws it")
    }

    /// Nothing remembered is a refusal with a sentence in it, not a silent
    /// no-op: a writer who pressed a button is owed an answer either way
    /// (RULING-7), and this error travels to the surface through the ordinary
    /// fallback, which has nothing of its own to add.
    func test_arestoreWithNothingRememberedRefusesInWords() throws {
        try writeASmallRegistry()
        let cache = makeCache()
        let ref = RecordRef(directory: .people, fingerprint: phone.fingerprint)

        XCTAssertThrowsError(try cache.restore(ref, in: projectURL)) { error in
            XCTAssertEqual(error as? RegistryCache.RestoreError, .nothingRemembered(ref))
            XCTAssertTrue(
                ((error as? LocalizedError)?.errorDescription ?? "")
                    .contains("nothing to put back"),
                "and it says so: \(String(describing: (error as? LocalizedError)?.errorDescription))")
        }
        XCTAssertEqual(cache.restores(for: projectURL), [],
                       "a restore that did not happen is not dated")
    }

    // MARK: - The dated restore list (P2b Task 10)

    /// **A restoration leaves a trace that outlives it.** Once the record is
    /// back, the folder looks exactly as it did before somebody deleted it —
    /// so the only place the fact can live is the memory that noticed it.
    /// History dates its `.recordRestored` from this list, and People &
    /// Devices marks the row from the same one.
    func test_aRestorationIsRememberedWithTheDayItHappened() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)
        XCTAssertEqual(cache.restores(for: projectURL), [],
                       "nothing has been put back yet")

        let url = RegistryWriter.url(.people, fingerprint: phone.fingerprint, in: projectURL)
        try FileManager.default.removeItem(at: url)
        let when = Date(timeIntervalSince1970: 900)
        _ = try cache.reconcile(
            folder: try RegistryReader.load(projectURL: projectURL),
            cached: cache.cached(for: projectURL), in: projectURL, at: when)

        XCTAssertEqual(
            cache.restores(for: projectURL),
            [RestoredRecord(
                ref: RecordRef(directory: .people, fingerprint: phone.fingerprint),
                restoredAt: when)])
    }

    /// **Twice deleted is twice listed.** The second deletion is the news, and
    /// collapsing the two would leave a surface showing a month-old date for
    /// something that happened this morning.
    func test_aRecordDeletedTwiceIsListedTwice() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)
        let url = RegistryWriter.url(.people, fingerprint: phone.fingerprint, in: projectURL)

        for seconds in [900.0, 1_900.0] {
            try FileManager.default.removeItem(at: url)
            _ = try cache.reconcile(
                folder: try RegistryReader.load(projectURL: projectURL),
                cached: cache.cached(for: projectURL), in: projectURL,
                at: Date(timeIntervalSince1970: seconds))
        }

        XCTAssertEqual(cache.restores(for: projectURL).map(\.restoredAt),
                       [Date(timeIntervalSince1970: 900),
                        Date(timeIntervalSince1970: 1_900)],
                       "oldest first, both kept")
    }

    /// The list is bounded: a folder that comes back empty over and over is one
    /// event repeated, and this is a memory rather than an audit log.
    func test_theRestoreListIsCappedAtTheLimit() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)
        let url = RegistryWriter.url(.people, fingerprint: phone.fingerprint, in: projectURL)

        for i in 0..<(RegistryCache.restoreLimit + 10) {
            try FileManager.default.removeItem(at: url)
            _ = try cache.reconcile(
                folder: try RegistryReader.load(projectURL: projectURL),
                cached: cache.cached(for: projectURL), in: projectURL,
                at: Date(timeIntervalSince1970: TimeInterval(1_000 + i)))
        }

        let restores = cache.restores(for: projectURL)
        XCTAssertEqual(restores.count, RegistryCache.restoreLimit)
        XCTAssertEqual(restores.last?.restoredAt,
                       Date(timeIntervalSince1970: TimeInterval(1_000 + RegistryCache.restoreLimit + 9)),
                       "the newest is kept; the oldest go")
    }

    func test_theRestoreListSurvivesAReload() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)
        let url = RegistryWriter.url(.people, fingerprint: phone.fingerprint, in: projectURL)
        try FileManager.default.removeItem(at: url)
        _ = try cache.reconcile(
            folder: try RegistryReader.load(projectURL: projectURL),
            cached: cache.cached(for: projectURL), in: projectURL,
            at: Date(timeIntervalSince1970: 900))

        XCTAssertEqual(makeCache().restores(for: projectURL),
                       cache.restores(for: projectURL),
                       "it is persisted, like every other thing this remembers")
    }

    /// A reconcile that put nothing back records nothing.
    func test_aFolderThatLostNothingRecordsNoRestoration() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)
        _ = try cache.reconcile(
            folder: try RegistryReader.load(projectURL: projectURL),
            cached: cache.cached(for: projectURL), in: projectURL)
        XCTAssertEqual(cache.restores(for: projectURL), [])
    }

    // MARK: - The shared memory is lazy about the enclave (P2b Task 10)

    /// **A project with no registry and no cache file resolves no identity.**
    ///
    /// `TrustResolution` reaches for the shared memory on the way past every
    /// project it opens, and the identity behind it is this device's author
    /// fingerprint — asking for which MINTS an enclave key if there is not one.
    /// Most projects have no registry and never will, so the ordinary open must
    /// cost nothing: the file is read first, and the identity is asked for only
    /// where the answer turns on it.
    func test_aProjectWithNoRegistryNeverReachesForTheEnclave() throws {
        let counter = IdentityCounter()
        let cache = RegistryCache(fileURL: cacheURL, resolvingIdentity: counter.next)
        XCTAssertEqual(counter.count, 0, "constructing it asks nothing")

        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: .softwareForTesting(), cache: cache)

        XCTAssertNil(table.myRoot, "there is no chain here")
        XCTAssertEqual(counter.count, 0,
                       """
                       and resolving a project with no registry and no cache \
                       file asked the enclave nothing at all
                       """)
    }

    /// The converse, so the seam above cannot pass by being inert: a memory
    /// that is WRITTEN to stamps itself, which is exactly when this device has
    /// to say whose memory it is.
    func test_writingToTheMemoryDoesResolveTheIdentity() throws {
        let counter = IdentityCounter()
        let cache = RegistryCache(fileURL: cacheURL, resolvingIdentity: counter.next)
        cache.join(root: "a-root", for: projectURL)

        XCTAssertGreaterThan(counter.count, 0,
                             "a file written under no name would be read back by anybody")
        XCTAssertEqual(counter.count, 1, "and it is asked once, then remembered")
    }

    /// Counts how often the identity behind a cache is actually asked for.
    private final class IdentityCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return asked
        }
        func next() -> String {
            lock.lock(); defer { lock.unlock() }
            asked += 1
            return "device-under-test"
        }
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
        // The root's own record beside the claim: a claim is a root's act, so a
        // claim whose `newRoot` is nobody's root here is refused by the reader
        // and would never have been remembered (P2b Task 2).
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
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

    /// **A record that is PRESENT is never overwritten from this device's
    /// memory** — not even one that no longer verifies (whole-branch review,
    /// C2 fix 1).
    ///
    /// The device cannot tell *tampered with* from *damaged in transit*, and
    /// replacing the file would silently downgrade another device's signed
    /// record on shared storage, across devices, with nothing said anywhere.
    /// The defence it bought was redundant anyway: a malformed record already
    /// contributes nothing to the registry. So the file is left exactly as it
    /// is, listed malformed, and Integrity shows it.
    ///
    /// (P2b Task 1 narrowed the population this protects. The original
    /// rationale was that a record from a LATER build failed to verify here at
    /// all, because the digest was taken over a re-encode of the decoded
    /// record; the digest is now over the file's own bytes, so such a record
    /// verifies and is not malformed. The rule stands for the case it was
    /// always really about: bytes this device cannot vouch for stay where they
    /// are.)
    func test_aTamperedFolderRecordIsListedMalformedAndLeftOnDisk() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)

        let url = RegistryWriter.url(.people, fingerprint: phone.fingerprint, in: projectURL)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count / 2] = bytes[bytes.count / 2] == 0x61 ? 0x62 : 0x61
        let tampered = bytes
        try bytes.write(to: url)

        let folder = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(folder.malformed.count, 1, "the reader lists what it cannot vouch for")

        let outcome = try cache.reconcile(
            folder: folder, cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertTrue(outcome.removedBySomeone.isEmpty,
                      "nothing was REMOVED — the file is right there")
        XCTAssertTrue(outcome.restored.isEmpty, "so nothing is put back over it")
        XCTAssertEqual(try Data(contentsOf: url), tampered,
                       "and the bytes on disk are untouched")
        XCTAssertEqual(outcome.registry.malformed, folder.malformed,
                       "the malformed listing is carried out, not swallowed")
        XCTAssertFalse(outcome.registry.people.contains { $0.person == phone.fingerprint },
                       "a record that does not verify contributes nothing either way")
    }

    /// **And the bytes it once verified stay in the memory** (smoke find,
    /// 2026-09-19) — the half the rule above was missing, and the one the
    /// writer meets.
    ///
    /// A malformed record is in no registry, correctly; what was remembered was
    /// derived from the settled registry; so the read that NOTICED the
    /// tampering threw away the only copy of the good bytes. People & Devices
    /// then listed the record under *Records that don't verify* and said this
    /// Mac remembered no earlier version of it — over the very case Restore was
    /// built for. Denver's re-smoke found it on Smoke-P2's own root record, and
    /// the cache file confirmed it: the device record was remembered and the
    /// person record was not.
    ///
    /// End to end, because every step of it is the claim: verified, tampered,
    /// reconciled, and the bytes still answer — then put back, and verifying.
    func test_thebytesOfATamperedRecordSurviveTheReadThatNoticesIt() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)

        let ref = RecordRef(directory: .people, fingerprint: root.fingerprint)
        let url = RegistryWriter.url(.people, fingerprint: root.fingerprint, in: projectURL)
        let honest = try Data(contentsOf: url)
        XCTAssertEqual(cache.rawBytes(of: ref, for: projectURL), honest,
                       "premise: this device verified it and kept the bytes")

        // Somebody edits the label after it was signed — the smoke's own case.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: honest) as? [String: Any])
        object["label"] = "Somebody else"
        try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        ).write(to: url, options: .atomic)

        let folder = try RegistryReader.load(projectURL: projectURL)
        let outcome = try cache.reconcile(
            folder: folder, cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertFalse(outcome.registry.people.contains { $0.person == self.root.fingerprint },
                       "it still vouches for nobody")
        XCTAssertTrue(outcome.registry.malformed.contains { $0.ref == ref },
                      "and it is still listed")
        XCTAssertEqual(cache.rawBytes(of: ref, for: projectURL), honest,
                       "but the way back survived the read that noticed")
        XCTAssertEqual(makeCache().rawBytes(of: ref, for: projectURL), honest,
                       "and survives the launch that draws the Restore button")

        // Which is the whole point: the press now works.
        try cache.restore(ref, in: projectURL, at: Date(timeIntervalSince1970: 900))

        XCTAssertEqual(try Data(contentsOf: url), honest, "byte for byte")
        let reread = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(reread.malformed, [], "and what went back verifies")
        XCTAssertEqual(reread.person(root.fingerprint)?.label, "Denver")
    }

    /// **The control: a record this device never verified has no way back**,
    /// and says so in the sentence it already had. Preserving bytes is a
    /// memory of having vouched for something — a stranger's record arriving
    /// already tampered was never vouched for, so there is nothing to keep and
    /// nothing to offer.
    func test_atamperedRecordThisDeviceNeverVerifiedIsRememberedByNothing() throws {
        try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(try RegistryReader.load(projectURL: projectURL), for: projectURL)

        // A record for a fingerprint this device has never verified, arriving
        // already tampered: written well-formed, then edited after signing, and
        // never remembered in between — which is what *never verified here*
        // means.
        let stranger = DeviceIdentity.softwareForTesting()
        let ref = RecordRef(directory: .people, fingerprint: stranger.fingerprint)
        let url = try RegistryWriter.write(
            admittedRecord(stranger, under: root), signedBy: root, in: projectURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        object["label"] = "Somebody else"
        try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        ).write(to: url, options: .atomic)

        let folder = try RegistryReader.load(projectURL: projectURL)
        XCTAssertTrue(folder.malformed.contains { $0.ref == ref },
                      "premise: present, and this device cannot vouch for it")

        _ = try cache.reconcile(
            folder: folder, cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertNil(cache.rawBytes(of: ref, for: projectURL),
                     "nothing was ever verified for it, so nothing is kept")
        XCTAssertThrowsError(try cache.restore(ref, in: projectURL)) { error in
            XCTAssertEqual(error as? RegistryCache.RestoreError, .nothingRemembered(ref))
        }
    }

    /// **B1's own branch is untouched** (spec §2.4 P4). A record the folder now
    /// shows under a DIFFERENT key verified on its own terms, so it never
    /// reaches the preserve branch above: the remembered record stands IN the
    /// registry, the displacing copy is listed `signerChanged`, and the bytes
    /// are remembered as they always were. The two cases keep the memory for
    /// one reason and differ in what they keep it FOR, which is why they are
    /// two branches rather than one.
    func test_adisplacedRecordStillStandsAndIsStillRemembered() throws {
        try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(try RegistryReader.load(projectURL: projectURL), for: projectURL)

        let ref = RecordRef(directory: .people, fingerprint: phone.fingerprint)
        let honest = try Data(contentsOf: RegistryWriter.url(
            .people, fingerprint: phone.fingerprint, in: projectURL))

        // A second root writes its own admission over the same person record.
        try RegistryWriter.write(rootRecord(otherRoot), signedBy: otherRoot, in: projectURL)
        try RegistryWriter.write(
            admittedRecord(phone, under: otherRoot), signedBy: otherRoot, in: projectURL)

        let outcome = try cache.reconcile(
            folder: try RegistryReader.load(projectURL: projectURL),
            cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertTrue(
            outcome.registry.malformed.contains {
                $0.ref == ref && $0.reason == .signerChanged(
                    expected: self.root.fingerprint, found: self.otherRoot.fingerprint)
            },
            "the takeover is refused and listed")
        XCTAssertEqual(
            outcome.registry.people.first { $0.person == self.phone.fingerprint }?.admittedBy,
            root.fingerprint,
            "and the record this device verified is the one that stands")
        XCTAssertEqual(cache.rawBytes(of: ref, for: projectURL), honest,
                       "remembered as it always was")
    }

    /// The other half of the same predicate: a record whose FILE is gone still
    /// comes back, and it comes back even while another record beside it is
    /// present-and-malformed. Absence is the one thing restore answers.
    func test_aDeletedRecordIsStillRestoredBesideAMalformedOne() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)

        let deleted = RegistryWriter.url(.devices, fingerprint: root.fingerprint, in: projectURL)
        let honest = try Data(contentsOf: deleted)
        try FileManager.default.removeItem(at: deleted)

        let tamperedURL = RegistryWriter.url(
            .people, fingerprint: phone.fingerprint, in: projectURL)
        var bytes = try Data(contentsOf: tamperedURL)
        bytes[bytes.count / 2] = bytes[bytes.count / 2] == 0x61 ? 0x62 : 0x61
        try bytes.write(to: tamperedURL)

        let outcome = try cache.reconcile(
            folder: try RegistryReader.load(projectURL: projectURL),
            cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(outcome.removedBySomeone,
                       [RecordRef(directory: .devices, fingerprint: root.fingerprint)],
                       "the absent record is reported, and only it")
        XCTAssertEqual(try Data(contentsOf: deleted), honest,
                       "and put back byte for byte")
        XCTAssertTrue(outcome.registry.devices.contains { $0.device == root.fingerprint },
                      "so the resolved registry holds it again")
    }

    /// A repeated `remember` of the same registry writes nothing (whole-branch
    /// review, I1). Since Task 8 every opened project HAS a registry, so a
    /// walk that resolves per document paid a whole-file atomic write of the
    /// shared memory per iteration — the file is deleted here and its absence
    /// afterwards is the observation that nothing was written.
    func test_rememberingWhatIsAlreadyStoredWritesNothing() throws {
        let registry = try writeASmallRegistry()
        let cache = makeCache()
        cache.remember(registry, for: projectURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path),
                      "the first remember persists")

        try FileManager.default.removeItem(at: cacheURL)
        cache.remember(registry, for: projectURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path),
                       "nothing moved, so nothing is written")

        // And a real change still lands.
        cache.remember(Registry(), for: projectURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path),
                      "a memory that DID move is persisted")
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

    // MARK: - The same-authority rule (P2b Task 1)

    /// **A record changes hands only under the same key.** A cached record is
    /// displaced by the folder's copy when the folder's copy was signed by the
    /// key that signed the one this device remembers — a device re-signing its
    /// own record, a root re-signing a person's. A folder record for the same
    /// fingerprint signed by SOMEBODY ELSE is not a newer version of that
    /// record; it is another key's claim over it, and it is listed rather than
    /// applied.
    func test_aFolderRecordSignedByAnotherKeyDoesNotDisplaceTheRememberedOne() throws {
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        try RegistryWriter.write(admittedRecord(phone, under: root), signedBy: root, in: projectURL)
        let cache = makeCache()
        cache.remember(try RegistryReader.load(projectURL: projectURL), for: projectURL)

        // A second root arrives and writes its own admission of the same
        // person. It is a well-formed record — the reader verifies it, because
        // a person record's expected signer is the root it NAMES — so nothing
        // short of this rule stands between it and the remembered one.
        try RegistryWriter.write(rootRecord(otherRoot), signedBy: otherRoot, in: projectURL)
        let url = RegistryWriter.url(.people, fingerprint: phone.fingerprint, in: projectURL)
        try RegistryWriter.write(
            admittedRecord(phone, under: otherRoot), signedBy: otherRoot, in: projectURL)
        let plantedBytes = try Data(contentsOf: url)

        let folder = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(folder.malformed, [], "the reader has no quarrel with it on its own terms")

        let outcome = try cache.reconcile(
            folder: folder, cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(
            outcome.registry.malformed.map(\.reason),
            [.signerChanged(expected: root.fingerprint, found: otherRoot.fingerprint)],
            "the folder's copy is listed, and says which key it expected")
        XCTAssertEqual(
            outcome.registry.people.first { $0.person == self.phone.fingerprint }?.admittedBy,
            root.fingerprint,
            "and the record this device verified is the one that stands")
        XCTAssertEqual(outcome.restored, [], "nothing is put back — the file is right there")
        XCTAssertEqual(outcome.removedBySomeone, [])
        XCTAssertEqual(try Data(contentsOf: url), plantedBytes,
                       "and the folder's bytes are not overwritten from this device's memory")

        XCTAssertEqual(
            makeCache().cached(for: projectURL)?
                .people.first { $0.person == self.phone.fingerprint }?.admittedBy,
            root.fingerprint,
            "the memory keeps what it kept")
    }

    /// **The concrete hole this closes.** A root's own record is self-signed:
    /// it is that person saying who they are. Another root can write a
    /// perfectly valid person record for the same fingerprint — an ADMISSION,
    /// signed by itself — and before this rule the folder's copy simply won,
    /// so the second Mac to open the book took over the first one's identity
    /// record and the whole chain hanging off it. It cannot.
    func test_aRootsOwnRecordCannotBeDisplacedByAnotherRootsAdmissionOfIt() throws {
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        let cache = makeCache()
        cache.remember(try RegistryReader.load(projectURL: projectURL), for: projectURL)

        // A second root arrives and admits the first as one of ITS people.
        try RegistryWriter.write(rootRecord(otherRoot), signedBy: otherRoot, in: projectURL)
        try RegistryWriter.write(
            admittedRecord(root, under: otherRoot), signedBy: otherRoot, in: projectURL)

        let folder = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(folder.malformed, [],
                       "the admission is a well-formed record — the reader has no quarrel with it")
        XCTAssertEqual(folder.roots.map(\.person), [otherRoot.fingerprint],
                       "and on the folder's word alone the first root is no longer a root")

        let outcome = try cache.reconcile(
            folder: folder, cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(
            outcome.registry.malformed.map(\.reason),
            [.signerChanged(expected: root.fingerprint, found: otherRoot.fingerprint)])
        XCTAssertTrue(
            outcome.registry.people.contains { $0.person == self.root.fingerprint && $0.isRoot },
            "this device keeps the self-signed record it verified")
        XCTAssertEqual(
            Set(outcome.registry.roots.map(\.person)),
            [root.fingerprint, otherRoot.fingerprint],
            "the second claimant is listed beside it, never merged (B1)")
    }

    /// The rule's other half, stated on a person record so it is not only the
    /// device case: the SAME key re-signing its own record still wins.
    func test_aRecordReSignedByTheSameKeyStillWins() throws {
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        try RegistryWriter.write(admittedRecord(phone, under: root), signedBy: root, in: projectURL)
        let cache = makeCache()
        cache.remember(try RegistryReader.load(projectURL: projectURL), for: projectURL)

        var revoked = admittedRecord(phone, under: root)
        revoked = PersonRecord(
            person: phone.fingerprint, label: "Denver", ownName: "Denver's iPhone",
            admittedAt: revoked.admittedAt, admittedBy: root.fingerprint,
            revokedAt: Date(timeIntervalSince1970: 99), revokedBy: root.fingerprint)
        try RegistryWriter.write(revoked, signedBy: root, in: projectURL)

        let outcome = try cache.reconcile(
            folder: try RegistryReader.load(projectURL: projectURL),
            cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(outcome.registry.malformed, [], "a re-sign under the same key is ordinary")
        XCTAssertTrue(
            outcome.registry.people.first { $0.person == self.phone.fingerprint }?.isRevoked
                == true,
            "the root's own revocation lands")
    }

    // MARK: - The memory is byte-faithful about a record it cannot re-encode

    /// A record carrying a field this build has no property for is remembered
    /// as the BYTES that were on disk, so restoring it puts the unknown field
    /// back too. Remembering the decoded fields instead would have this device
    /// quietly rewrite another build's record into its own vocabulary, and the
    /// signature it restored would then verify nowhere.
    func test_aRecordFromALaterBuildIsRememberedAndRestoredByteIdentical() throws {
        let url = try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)

        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
                as? [String: Any])
        object["future"] = 1
        object.removeValue(forKey: "sig")
        let unsigned = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let credentials = try OpLogChain.credentials(
            signing: Hex.encode(Data(SHA256.hash(data: unsigned))), identity: root)
        object["sig"] = ["key": credentials.key, "pub": credentials.pub, "sig": credentials.sig]
        try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            .write(to: url)
        let onDisk = try Data(contentsOf: url)

        let cache = makeCache()
        cache.remember(try RegistryReader.load(projectURL: projectURL), for: projectURL)
        XCTAssertEqual(
            cache.rawBytes(of: RecordRef(directory: .people, fingerprint: root.fingerprint),
                           for: projectURL),
            onDisk,
            "the memory keeps the file's own bytes, unknown field and all")

        try FileManager.default.removeItem(at: url)
        let outcome = try cache.reconcile(
            folder: try RegistryReader.load(projectURL: projectURL),
            cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(outcome.restored, [url])
        XCTAssertEqual(try Data(contentsOf: url), onDisk, "restored byte for byte")
        XCTAssertEqual(try RegistryReader.load(projectURL: projectURL).malformed, [],
                       "and what was put back still verifies")
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

    // MARK: - When the join happened (P2b Task 2)

    /// The join's date is what History's *on this Mac since 9 Sep* sentence is
    /// made of, so it has to survive the launch that draws it.
    func test_theJoinStampSurvivesAReload() {
        let cache = makeCache()
        XCTAssertNil(cache.joinedAt(for: projectURL))

        let when = Date(timeIntervalSince1970: 1_757_000_000)
        cache.join(root: root.fingerprint, for: projectURL, at: when)

        XCTAssertEqual(cache.joinedAt(for: projectURL), when)
        XCTAssertEqual(makeCache().joinedAt(for: projectURL), when)
    }

    /// Write-once, exactly like the root it stamps: the FIRST join is the one
    /// that happened. A second root is a claimant, and a claimant's arrival is
    /// not the day this Mac joined anybody.
    func test_theJoinStampIsTheFirstJoinsAndNeverMoves() {
        let cache = makeCache()
        let first = Date(timeIntervalSince1970: 1_757_000_000)
        cache.join(root: root.fingerprint, for: projectURL, at: first)

        cache.join(root: root.fingerprint, for: projectURL,
                   at: Date(timeIntervalSince1970: 1_758_000_000))
        cache.join(root: otherRoot.fingerprint, for: projectURL,
                   at: Date(timeIntervalSince1970: 1_759_000_000))

        XCTAssertEqual(cache.joinedRoot(for: projectURL), root.fingerprint)
        XCTAssertEqual(cache.joinedAt(for: projectURL), first)
        XCTAssertEqual(cache.claimants(for: projectURL), [otherRoot.fingerprint])
    }

    /// A device that has joined nobody has no date either — the two are one
    /// fact, and a surface asks whichever half it needs.
    func test_aProjectWithNoJoinHasNoStamp() {
        let cache = makeCache()
        cache.recordClaimant(root: otherRoot.fingerprint, for: projectURL)

        XCTAssertNil(cache.joinedRoot(for: projectURL))
        XCTAssertNil(cache.joinedAt(for: projectURL))
    }

    /// A memory written before this field existed still loads: the join it
    /// remembers stands, and only the date is missing. The alternative — a
    /// decode that fails on the absent key — would drop the whole cache, and
    /// with it every record this device could restore.
    func test_aMemoryFromBeforeTheStampKeepsItsJoinAndAnswersNoDate() throws {
        let legacy = """
            {"identity":"device-under-test","projects":{"\(RegistryCache.projectKey(projectURL))":\
            {"root":"\(projectURL.standardizedFileURL.path)","records":[],\
            "joinedRoot":"\(root.fingerprint)","claimants":[]}}}
            """
        try Data(legacy.utf8).write(to: cacheURL)

        let cache = makeCache()

        XCTAssertEqual(cache.joinedRoot(for: projectURL), root.fingerprint)
        XCTAssertNil(cache.joinedAt(for: projectURL))
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
