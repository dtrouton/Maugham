import XCTest
@testable import Maugham
@testable import MaughamCore

/// The inbox manifest is chained history like the op log's, on both surfaces
/// (spec §4, task 7). What this suite pins is the MAC's half: every row this
/// Mac appends links to the head it verified and is sealed on the spot, a seal
/// written by another device is invisible to the pane, and a row this Mac did
/// not write is held back and recorded under the inbox's own stream name.
@MainActor
final class InboxChainTests: XCTestCase {

    private var projectURL: URL!
    private var identity: DeviceIdentity!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-chain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        identity = .softwareForTesting()
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-chain-cache-\(UUID().uuidString).json")
        cache = RegistryCache(fileURL: cacheURL, identity: identity.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Fixture

    /// The device's registry memory, per test. `OpLogStore` has taken one
    /// since P2a and `InboxStore` did not, so every Mac test that gave a temp
    /// project a registry read and wrote the DEVELOPER's real
    /// `registry-cache.json` from a parallel worker (whole-branch review, I4).
    private var cacheURL: URL!
    private var cache: RegistryCache!

    private func makeInbox(deviceId: String = "mac") -> InboxStore {
        InboxStore(projectURL: projectURL, deviceId: deviceId, identity: identity,
                   identities: .forTesting(author: identity), cache: cache)
    }

    private func manifestURL(_ deviceId: String) -> URL {
        InboxManifest.inboxManifestURL(
            forDeviceSlug: DeviceSlug.make(from: deviceId), in: projectURL)
    }

    private func entry(_ id: String, at seconds: TimeInterval = 100) -> InboxEntry {
        InboxEntry(id: id, createdAt: Date(timeIntervalSince1970: seconds),
                   deviceId: "phone", kind: .text, inlineText: id)
    }

    /// A chained store standing in for ANOTHER device writing its own manifest
    /// — the phone, on the far side of iCloud.
    private func farSideStore(
        _ deviceId: String, identity: DeviceIdentity
    ) -> JSONLAppendStore<InboxEntry> {
        JSONLAppendStore<InboxEntry>(
            fileURL: manifestURL(deviceId),
            chain: ChainPolicy(
                identity: identity, state: .shared,
                docId: InboxManifest.chainDocId, projectURL: projectURL))
    }

    private func lines(_ deviceId: String) throws -> [Data] {
        let bytes = try Data(contentsOf: manifestURL(deviceId))
        return bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }.map { Data($0) }
    }

    // MARK: - This Mac's own writes

    func test_everyRowThisMacAppendsIsChainedAndSealedOnTheSpot() async throws {
        let seed = farSideStore("mac", identity: identity)
        try await seed.append(entry("id1"))
        try await seed.appendSeal()

        let inbox = makeInbox()
        await inbox.refresh()
        await inbox.updateStatus(id: "id1", to: .trashed)

        let written = try lines("mac")
        XCTAssertEqual(written.count, 4, "the seeded row and its seal, then the transition and its own")

        let row = written[2]
        XCTAssertEqual(OpLogChain.prev(ofLine: row) ?? nil,
                       OpLogChain.lineHash(written[1]),
                       "the transition chains onto the head it verified — the seal before it")

        let seal = try XCTUnwrap(OpLogChain.Seal.parse(written[3]),
                                 "a capture is sealed on the spot; captures are rare")
        XCTAssertTrue(seal.verifies())
        XCTAssertEqual(seal.key, identity.fingerprint)
        XCTAssertEqual(seal.head, OpLogChain.lineHash(row))
    }

    func test_aMacWithNoKeySealsNothingAndStillWritesItsRow() async throws {
        let unsigned = DeviceIdentity.unsignedForTesting(token: Data(repeating: 7, count: 32))
        let inbox = InboxStore(projectURL: projectURL, deviceId: "mac", identity: unsigned,
                               identities: .forTesting(author: unsigned))
        let seed = farSideStore("mac", identity: unsigned)
        try await seed.append(entry("id1"))

        await inbox.refresh()
        await inbox.updateStatus(id: "id1", to: .trashed)

        let written = try lines("mac")
        XCTAssertEqual(written.count, 2, "no seal — an unsigned device is a state, not a failure")
        XCTAssertEqual(OpLogChain.prev(ofLine: written[1]) ?? nil,
                       OpLogChain.lineHash(written[0]))
        XCTAssertTrue(inbox.entries.isEmpty, "and the transition still took")
    }

    // MARK: - What the pane sees

    func test_aSealFromAnotherDeviceIsInvisibleToThePane() async throws {
        let phone = DeviceIdentity.softwareForTesting()
        let store = farSideStore("phone", identity: phone)
        try await store.append(entry("id1", at: 100))
        try await store.appendSeal()
        try await store.append(entry("id2", at: 200))
        try await store.appendSeal()

        let written = try lines("phone")
        XCTAssertEqual(written.count, 4)
        XCTAssertNotNil(OpLogChain.Seal.parse(written[1]), "the fixture really does hold seals")

        let inbox = makeInbox()
        await inbox.refresh()

        XCTAssertEqual(inbox.entries.map(\.id), ["id2", "id1"],
                       "both captures surface; the seals between them are not entries")
        XCTAssertTrue(inbox.unreadableManifests.isEmpty,
                      "a seal must never read as a damaged manifest")
    }

    func test_aRowThisMacDidNotWriteIsHeldBackAndRecordedAsTheInboxs() async throws {
        let store = farSideStore("mac", identity: identity)
        try await store.append(entry("kept"))
        try await store.appendSeal()

        // Something else appends a plain, unchained row after the chain began.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<InboxEntry>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        var bytes = try Data(contentsOf: manifestURL("mac"))
        bytes.append(try encoder.encode(entry("intruder", at: 300)))
        bytes.append(0x0A)
        try bytes.write(to: manifestURL("mac"))

        let inbox = makeInbox()
        await inbox.refresh()

        XCTAssertEqual(inbox.entries.map(\.id), ["kept"],
                       "a capture nothing in this history vouches for is never shown")

        let records = OpLogQuarantine.records(
            forDocId: InboxManifest.chainDocId, in: projectURL)
        XCTAssertEqual(records.count, 1, "and it is on file where the writer can find it")
        XCTAssertEqual(records.first?.docId, "inbox")
        XCTAssertEqual(records.first?.kind, .lines)
        XCTAssertEqual(records.first?.reason, "written by something that is not Maugham")
    }

    /// RULING-54 at the inbox: a registry record that is present and cannot be
    /// read refuses the read by name rather than leaving the inbox judging
    /// nobody. Judging nobody would apply a stranger's captures as this
    /// project's own, silently, which is the failure that ruling forbids.
    func test_anUnreadableRegistryRecordRefusesTheInboxReadByName() async throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file, so nothing is refused")
        let seed = farSideStore("mac", identity: identity)
        try await seed.append(entry("a"))
        try await seed.appendSeal()

        let inbox = makeInbox()
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.map(\.id), ["a"])

        let people = projectURL.appendingPathComponent(".maugham/people", isDirectory: true)
        try FileManager.default.createDirectory(at: people, withIntermediateDirectories: true)
        let record = people.appendingPathComponent("deadbeef.json")
        try Data("{}".utf8).write(to: record)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: record.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: record.path)
        }

        await inbox.refresh()

        let notice = try XCTUnwrap(inbox.unreadableRegistry)
        XCTAssertTrue(notice.contains("deadbeef.json"),
                      "the record that stopped the read is named")
        XCTAssertTrue(notice.contains("registry record"),
                      "in the registry's own words, not the captures' — \(notice)")
        XCTAssertTrue(inbox.unreadableManifests.isEmpty,
                      "no manifest failed; the registry did")
        XCTAssertTrue(inbox.entries.isEmpty,
                      "and nothing is applied under a registry this Mac cannot read")
    }

    /// **The inbox resolves against the cache it is GIVEN** (whole-branch
    /// review, I4). Without the seam its resolution reached
    /// `RegistryCache.shared` — machine-global mutable state written from
    /// seven parallel workers, which is the confounder class the build-flow
    /// notes warn about. Nothing was incorrect (entries self-prune and it is a
    /// cache, not truth), but a test must be able to say which memory it means.
    func test_theInboxResolvesAgainstTheCacheItIsGiven() async throws {
        // A real registry: this device's own root, signed by the test key.
        try RegistryWriter.write(
            PersonRecord(person: identity.fingerprint, label: "Denver",
                         ownName: "Denver's MacBook",
                         admittedAt: Date(timeIntervalSince1970: 10),
                         admittedBy: identity.fingerprint),
            signedBy: identity, in: projectURL)

        let inbox = makeInbox()
        await inbox.refresh()

        XCTAssertNil(inbox.unreadableRegistry, "the planted registry is readable")
        XCTAssertNotNil(cache.cached(for: projectURL),
                        "the injected memory is what the resolution reconciled against")
        XCTAssertNil(RegistryCache.shared.cached(for: projectURL),
                     "and the process-wide one was never touched")
    }

    func test_aManifestWrittenBeforeThisMilestoneStillReadsWhole() async throws {
        // No chain policy at all: every line legacy, exactly what is on the
        // writer's disk today.
        let legacy = JSONLAppendStore<InboxEntry>(fileURL: manifestURL("mac"))
        try await legacy.append(entry("old1", at: 100))
        try await legacy.append(entry("old2", at: 200))

        let inbox = makeInbox()
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.map(\.id), ["old2", "old1"])

        // And this Mac's first chained row lands on top of them without
        // disturbing either.
        await inbox.updateStatus(id: "old1", to: .trashed)
        XCTAssertEqual(inbox.entries.map(\.id), ["old2"])
        XCTAssertTrue(
            OpLogQuarantine.records(forDocId: InboxManifest.chainDocId, in: projectURL).isEmpty,
            "legacy rows are history, not intruders")
    }
}
