import XCTest
@testable import MaughamCore

/// The READ half of the chain, at the level every stream shares it
/// (`JSONLAppendStore.loadVerifiedStrict`). The element here is `InboxEntry`
/// rather than `Op` on purpose: the three steps — verify the bytes, set aside
/// what broke, hand the KEPT bytes to the parser — belong to the store, not to
/// the op log, and Task 8's annotation stream will ask them the same way.
@MainActor
final class JSONLVerifiedReadTests: XCTestCase {

    private var projectURL: URL!
    private var identity: DeviceIdentity!
    private var state: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("verified-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        identity = .softwareForTesting()
        state = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("device-state.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    private var fileURL: URL {
        InboxManifest.inboxManifestURL(forDeviceSlug: identity.slug, in: projectURL)
    }

    private func makeStore(_ identity: DeviceIdentity? = nil) -> JSONLAppendStore<InboxEntry> {
        JSONLAppendStore<InboxEntry>(
            fileURL: fileURL,
            chain: ChainPolicy(
                identity: identity ?? self.identity, state: state,
                docId: InboxManifest.chainDocId, projectURL: projectURL))
    }

    private func entry(_ id: String) -> InboxEntry {
        InboxEntry(id: id, createdAt: Date(timeIntervalSince1970: 100),
                   deviceId: identity.deviceId, kind: .text, inlineText: id)
    }

    private func lines() throws -> [Data] {
        let bytes = try Data(contentsOf: fileURL)
        return bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }.map { Data($0) }
    }

    private func appendByHand(_ line: Data) throws {
        var bytes = try Data(contentsOf: fileURL)
        bytes.append(line)
        bytes.append(0x0A)
        try bytes.write(to: fileURL)
    }

    // MARK: - The kept bytes

    func test_chainedRowsAndTheirSealsReadBackAsElements() async throws {
        let store = makeStore()
        try await store.append(entry("a"))
        try await store.appendSeal()
        try await store.append(entry("b"))
        try await store.appendSeal()

        XCTAssertEqual(try lines().count, 4, "two rows, each with a seal of its own")

        let read = try await store.loadVerifiedStrict()
        XCTAssertEqual(read.elements.map(\.id), ["a", "b"])
        XCTAssertTrue(read.diagnostics.skipped.isEmpty,
                      "a seal is a line of the chain's own kind, never a damaged element")
    }

    func test_aStoreWithNoChainPolicyReadsExactlyAsTheStrictLoadAlwaysDid() async throws {
        let plain = JSONLAppendStore<InboxEntry>(fileURL: fileURL)
        try await plain.append(entry("a"))
        try await plain.append(entry("b"))

        let read = try await plain.loadVerifiedStrict()
        XCTAssertEqual(read.elements.map(\.id), ["a", "b"])
        for line in try lines() {
            XCTAssertNil(OpLogChain.prev(ofLine: line) ?? nil,
                         "an unchained store still writes unchained lines")
        }
    }

    func test_anUnreadableFileThrowsRatherThanReadingEmpty() async throws {
        try await makeStore().append(entry("a"))
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)

        do {
            _ = try await makeStore().loadVerifiedStrict()
            XCTFail("an unreadable-yet-present file must throw (RULING-54)")
        } catch {}
    }

    // MARK: - What it holds back

    func test_aLineThisDeviceDidNotWriteIsHeldBackAndRecordedUnderTheStreamsOwnDocId() async throws {
        let store = makeStore()
        try await store.append(entry("a"))
        try await store.appendSeal()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<InboxEntry>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        try appendByHand(try encoder.encode(entry("intruder")))

        let read = try await store.loadVerifiedStrict()
        XCTAssertEqual(read.elements.map(\.id), ["a"],
                       "the unchained line arrived after the chain began — never applied")

        let records = OpLogQuarantine.records(
            forDocId: InboxManifest.chainDocId, in: projectURL)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.kind, .lines)
        XCTAssertEqual(records.first?.reason, "written by something that is not Maugham")
        XCTAssertEqual(records.first?.originalName, fileURL.lastPathComponent)
    }

    func test_theSameBrokenBytesAreRecordedOnceHoweverOftenTheyAreRead() async throws {
        let store = makeStore()
        try await store.append(entry("a"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<InboxEntry>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        try appendByHand(try encoder.encode(entry("intruder")))

        _ = try await store.loadVerifiedStrict()
        _ = try await store.loadVerifiedStrict()
        _ = try await store.loadVerifiedStrict()

        XCTAssertEqual(
            OpLogQuarantine.records(forDocId: InboxManifest.chainDocId, in: projectURL).count, 1,
            "a read reports; it must not file the same lines again on every refresh")
    }

    func test_theReadNeverAdoptsAHeadOfItsOwn() async throws {
        let store = makeStore()
        try await store.append(entry("a"))
        let key = OpLogDeviceState.fileKey(fileURL)
        let remembered = state.head(for: key)

        state.remember(head: OpLogChain.lineHash(Data("nothing hashes to this".utf8)), for: key)
        _ = try await store.loadVerifiedStrict()

        XCTAssertNotEqual(state.head(for: key), remembered,
                          "the read wrote nothing; the planted head is still there")
        XCTAssertEqual(state.head(for: key),
                       OpLogChain.lineHash(Data("nothing hashes to this".utf8)),
                       "adopting a head is the op log's own decision, not the read's")
    }
}
