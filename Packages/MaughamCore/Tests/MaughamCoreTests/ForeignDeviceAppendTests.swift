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
            fileURL: projectURL.appendingPathComponent("device-state.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// The sentinel `TaskDeriver` stamps on a rebalance op. Spelled here rather
    /// than imported: `TaskDeriver` is the Mac target's, and the rule this file
    /// pins is MaughamCore's — it holds for ANY device string that is not this
    /// device's, of which the sentinel is the one production instance.
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
            fileURL: projectURL.appendingPathComponent("other-state.json"))
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
}
