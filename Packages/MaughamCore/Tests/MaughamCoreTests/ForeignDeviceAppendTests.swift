import XCTest
@testable import MaughamCore

/// A device chains only its OWN file.
///
/// The Mac mints rebalance ops carrying a SENTINEL device string
/// (`TaskDeriver.rebalanceSentinel`), and `DeviceSlug.make` is deterministic, so
/// every Mac derives the same `<docId>.rebalance-<fnv32>.jsonl` from it. That
/// file is the one production violation of ADR 0012's single-writer premise —
/// and the chained append's rewrite step is licensed by exactly that premise.
/// Chaining it would make two Macs mutually truncate each other's ops and
/// accuse the writer's own second machine of not being Maugham.
///
/// So the rule is a rule about the OP, not about the file: attach the
/// `ChainPolicy` only when `op.device == identity.deviceId`.
@MainActor
final class ForeignDeviceAppendTests: XCTestCase {

    private let docId = "doc-foreign"
    private var projectURL: URL!
    private var identity: DeviceIdentity!
    private var state: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        identity = .softwareForTesting()
        state = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("device-state.json"),
            identity: identity.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// The sentinel `TaskDeriver` stamps on a rebalance op. Spelled here rather
    /// than imported: `TaskDeriver` is the Mac target's, and the rule this file
    /// pins is MaughamCore's — it holds for ANY device string that is not this
    /// device's. There are several on the Mac (`rebalance`, plus the
    /// `Document.load` callers passing `wiki-rename`, `find-replace` and
    /// `mcp`); this one stands for all of them.
    private let sentinel = "rebalance"

    private func makeStore(_ id: DeviceIdentity? = nil) -> OpLogStore {
        OpLogStore(projectURL: projectURL, identity: id ?? identity, state: state)
    }

    private func fileURL(forDevice device: String) -> URL {
        OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: DeviceSlug.make(from: device), in: projectURL)
    }

    private func op(_ opId: String, device: String) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: device, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: "a sentence")],
           sequence: ["aaaa"])
    }

    private func lines(of url: URL) throws -> [Data] {
        let bytes = try Data(contentsOf: url)
        return bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map { Data($0) }
    }

    // MARK: - (a) a foreign device's op is written unchained

    func test_anOpCarryingASentinelDeviceIsWrittenWithNoPrevAndNoSeal() async throws {
        let store = makeStore()
        // Enough appends to cross the seal interval, so "no seal" is a fact
        // about the rule and not about the count.
        for i in 1...(OpLogStore.chainSealInterval + 1) {
            try await store.append(op("op-\(String(format: "%04d", i))", device: sentinel))
        }

        let written = try lines(of: fileURL(forDevice: sentinel))
        XCTAssertEqual(written.count, OpLogStore.chainSealInterval + 1)
        for line in written {
            XCTAssertEqual(OpLogChain.prev(ofLine: line), .some(nil),
                "a sentinel-device line must carry no prev — it is another Mac's "
                + "file as much as this one's")
            XCTAssertFalse(OpLogChain.isSealLine(line),
                "nothing seals a file this device does not own")
        }
    }

    /// The consequence the Critical was about: a SECOND Mac appending to the
    /// same shared sentinel file afterwards truncates nothing and accuses
    /// nobody. Before the rule, its chained append found lines it did not write,
    /// quarantined them, and rewrote the file without them.
    func test_aSecondDeviceAppendingToTheSharedFileTruncatesNothing() async throws {
        try await makeStore().append(op("op-0001", device: sentinel))
        let after = try lines(of: fileURL(forDevice: sentinel))
        XCTAssertEqual(after.count, 1)

        let otherIdentity = DeviceIdentity.softwareForTesting()
        let otherState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("other-state.json"),
            identity: otherIdentity.fingerprint)
        let other = OpLogStore(
            projectURL: projectURL, identity: otherIdentity, state: otherState)
        try await other.append(op("op-0002", device: sentinel))

        let both = try lines(of: fileURL(forDevice: sentinel))
        XCTAssertEqual(both.count, 2,
            "the first Mac's line must still be there — a shared file is "
            + "append-only, never rewritten")
        XCTAssertEqual(both[0], after[0])
        XCTAssertTrue(
            OpLogQuarantine.records(forDocId: docId, in: projectURL).isEmpty,
            "and nothing may be recorded about it: the writer's own second Mac "
            + "is not “something that is not Maugham”")
    }

    // MARK: - (b) the device's own op still chains

    func test_anOpCarryingThisDevicesOwnIdStillChains() async throws {
        let store = makeStore()
        try await store.append(op("op-0001", device: identity.deviceId))
        try await store.append(op("op-0002", device: identity.deviceId))

        let written = try lines(of: fileURL(forDevice: identity.deviceId))
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(OpLogChain.prev(ofLine: written[0]), .some(OpLogChain.genesis))
        XCTAssertEqual(OpLogChain.prev(ofLine: written[1]),
                       .some(OpLogChain.lineHash(written[0])))
    }

    /// M8's residue, retired rather than patched: the seal counter is only ever
    /// keyed on a file this device chains, so the file it counts and the file
    /// `sealChain` seals are the same file by construction. A run of foreign
    /// appends can no longer push the counter over the interval and spend a
    /// seal on somewhere else.
    func test_foreignAppendsNeverTriggerASealOnThisDevicesOwnFile() async throws {
        let store = makeStore()
        try await store.append(op("op-0001", device: identity.deviceId))
        for i in 2...(OpLogStore.chainSealInterval + 1) {
            try await store.append(op("op-\(String(format: "%04d", i))", device: sentinel))
        }

        let own = try lines(of: fileURL(forDevice: identity.deviceId))
        XCTAssertEqual(own.count, 1,
            "one op, no seal: the foreign appends counted for nothing")
        XCTAssertFalse(own.contains(where: OpLogChain.isSealLine))
    }

    // MARK: - (c) the four local actors, each under its own key

    /// The assistant's op belongs to the assistant. It lands in the assistant's
    /// own file, chained onto that file's head, and the seal that closes its run
    /// carries the ASSISTANT's fingerprint — not the author's, which is what a
    /// device with one key would have signed it with.
    func test_anAssistantsOpChainsAndSealsUnderTheAssistantsOwnKey() async throws {
        let quartet = LocalIdentities.softwareForTesting()
        let quartetState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("quartet-state.json"),
            identity: quartet.author.fingerprint)
        let store = OpLogStore(
            projectURL: projectURL, identities: quartet, state: quartetState)

        for i in 1...OpLogStore.chainSealInterval {
            try await store.append(
                op("op-\(String(format: "%04d", i))", device: quartet.assistant.deviceId))
        }

        let written = try lines(of: fileURL(forDevice: quartet.assistant.deviceId))
        XCTAssertEqual(written.count, OpLogStore.chainSealInterval + 1,
                       "every op plus the seal that closes the run")
        XCTAssertEqual(OpLogChain.prev(ofLine: written[0]), .some(OpLogChain.genesis))
        XCTAssertEqual(OpLogChain.prev(ofLine: written[1]),
                       .some(OpLogChain.lineHash(written[0])))

        let seal = try XCTUnwrap(OpLogChain.Seal.parse(try XCTUnwrap(written.last)))
        XCTAssertEqual(seal.key, quartet.assistant.fingerprint,
            "the role is in the key: an op through MCP is sealed by the assistant")
        XCTAssertNotEqual(seal.key, quartet.author.fingerprint)
        XCTAssertTrue(seal.verifies())

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fileURL(forDevice: quartet.author.deviceId).path),
            "the author wrote nothing here and has no file")
    }

    /// The widening is exact: a device string that is none of the four still
    /// takes the plain append. `identity(forDeviceId:)` matches whole ids, so
    /// another Mac's author — same `author-` prefix, different key — is a
    /// stranger like any other.
    func test_aDeviceStringMatchingNoLocalActorStillAppendsPlain() async throws {
        let quartet = LocalIdentities.softwareForTesting()
        let quartetState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("quartet-state.json"),
            identity: quartet.author.fingerprint)
        let store = OpLogStore(
            projectURL: projectURL, identities: quartet, state: quartetState)
        let anotherMac = DeviceIdentity.softwareForTesting(actor: .author)

        try await store.append(op("op-0001", device: sentinel))
        try await store.append(op("op-0002", device: anotherMac.deviceId))

        for device in [sentinel, anotherMac.deviceId] {
            for line in try lines(of: fileURL(forDevice: device)) {
                XCTAssertEqual(OpLogChain.prev(ofLine: line), .some(nil),
                    "\(device) is not one of this device's four writers")
                XCTAssertFalse(OpLogChain.isSealLine(line))
            }
        }
    }
}
