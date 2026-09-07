import XCTest
@testable import MaughamCore

/// The writer's side of the signed op log: every append links to the head this
/// device verified, anything it did not write is set aside first, and a seal
/// signs the run every `chainSealInterval` lines.
@MainActor
final class ChainedAppendTests: XCTestCase {

    private let docId = "doc-chain"
    private var projectURL: URL!
    private var identity: DeviceIdentity!
    private var state: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chain-\(UUID().uuidString)")
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

    private func makeStore() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identity: identity, state: state)
    }

    private var fileURL: URL {
        OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL)
    }

    private func op(_ opId: String, next: String = "a sentence") -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: identity.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: next)],
           sequence: ["aaaa"])
    }

    /// Raw lines, straight off disk — never through `loadDiagnosed`, which is
    /// Task 5's read path and does not know about `prev` or seals yet.
    private func lines(of url: URL? = nil) throws -> [Data] {
        let bytes = try Data(contentsOf: url ?? fileURL)
        return bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map { Data($0) }
    }

    private func encoded(_ op: Op) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(op)
    }

    private func appendByHand(_ line: Data) throws {
        var bytes = try Data(contentsOf: fileURL)
        bytes.append(line)
        bytes.append(0x0A)
        try bytes.write(to: fileURL)
    }

    private func linesRecords() -> [QuarantineRecord] {
        OpLogQuarantine.records(forDocId: docId, in: projectURL)
            .filter { $0.kind == .lines }
    }

    // MARK: - (a) the chain itself

    /// Every line names the one before it, and the first names `genesis` — not
    /// nothing, because a first line with no `prev` is indistinguishable from a
    /// pre-P1 legacy line and no seal would ever settle it.
    func test_everyAppendChainsOntoTheLineBeforeIt() async throws {
        let store = makeStore()
        for i in 1...3 { try await store.append(op("op-\(i)")) }

        let written = try lines()
        XCTAssertEqual(written.count, 3)
        XCTAssertEqual(OpLogChain.prev(ofLine: written[0]), .some(OpLogChain.genesis))
        XCTAssertEqual(OpLogChain.prev(ofLine: written[1]),
                       .some(OpLogChain.lineHash(written[0])))
        XCTAssertEqual(OpLogChain.prev(ofLine: written[2]),
                       .some(OpLogChain.lineHash(written[1])))

        let verification = OpLogChain.verify(
            bytes: try Data(contentsOf: fileURL),
            trusted: { [identity] in $0 == identity!.fingerprint },
            rememberedHead: state.head(for: OpLogDeviceState.fileKey(fileURL)))
        XCTAssertTrue(verification.quarantined.isEmpty)
        XCTAssertEqual(verification.unsealedCount, 3)
        XCTAssertEqual(verification.head, OpLogChain.lineHash(written[2]))
    }

    /// The head is remembered BEFORE the line is written, and it is the hash of
    /// the line that was written — that is what makes the next append link and
    /// what makes a stranger's line detectable.
    func test_theRememberedHeadIsTheLastLineThisDeviceWrote() async throws {
        let store = makeStore()
        try await store.append(op("op-1"))
        try await store.append(op("op-2"))
        let written = try lines()
        XCTAssertEqual(state.head(for: OpLogDeviceState.fileKey(fileURL)),
                       OpLogChain.lineHash(written[1]))
    }

    // MARK: - (b) a legacy file

    /// History written before this milestone is not disturbed: the first
    /// chained line links onto the last legacy line's hash and nothing is set
    /// aside. That file is unsigned history up to here, and it stays.
    func test_aLegacyFileIsChainedOntoRatherThanQuarantined() async throws {
        var legacy = Data()
        for i in 1...2 {
            legacy.append(try encoded(op("legacy-\(i)")))
            legacy.append(0x0A)
        }
        try legacy.write(to: fileURL)
        let legacyLines = try lines()

        try await makeStore().append(op("op-3"))

        let written = try lines()
        XCTAssertEqual(written.count, 3, "nothing was rewritten away")
        XCTAssertEqual(written[0], legacyLines[0])
        XCTAssertEqual(written[1], legacyLines[1])
        XCTAssertEqual(OpLogChain.prev(ofLine: written[2]),
                       .some(OpLogChain.lineHash(legacyLines[1])))
        XCTAssertTrue(linesRecords().isEmpty, "nothing set aside")
    }

    // MARK: - (c) a line this device did not write

    /// The case the whole milestone is for: something appended a line into this
    /// device's own file. The next append sets those bytes aside, rewrites the
    /// tail without them, and chains onto the last line it does recognise.
    func test_anUnchainedForeignLineIsSetAsideAndTheTailRewritten() async throws {
        let store = makeStore()
        try await store.append(op("op-1"))
        try await store.append(op("op-2"))
        let ours = try lines()

        let intruder = try encoded(op("intruder", next: "not mine"))
        try appendByHand(intruder)

        try await store.append(op("op-3"))

        let written = try lines()
        XCTAssertEqual(written.count, 3, "the foreign line is gone from the tail")
        XCTAssertEqual(written[0], ours[0])
        XCTAssertEqual(written[1], ours[1])
        XCTAssertFalse(written.contains(intruder))
        XCTAssertEqual(OpLogChain.prev(ofLine: written[2]),
                       .some(OpLogChain.lineHash(ours[1])),
                       "chained onto the last line this device kept")

        let records = linesRecords()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.kind, .lines)
        XCTAssertEqual(record.docId, docId)
        XCTAssertEqual(record.originalName, fileURL.lastPathComponent)
        XCTAssertEqual(record.reason, "written by something that is not Maugham")
        let archive = OpLogQuarantine.quarantinedFileURL(for: record, in: projectURL)
        XCTAssertEqual(try lines(of: archive), [intruder], "the bytes verbatim")
    }

    // MARK: - (d) a forged prev

    /// A line that chains CORRECTLY is still not this device's. The chain alone
    /// cannot tell them apart — the remembered head can, because it names the
    /// last line this device actually wrote.
    func test_aCorrectlyChainedForeignLineIsStillSetAside() async throws {
        let store = makeStore()
        try await store.append(op("op-1"))
        try await store.append(op("op-2"))
        let ours = try lines()

        let forged = OpLogChain.chainedLine(
            elementJSON: try encoded(op("forged", next: "computed the right prev")),
            prev: OpLogChain.lineHash(ours[1]))
        try appendByHand(forged)
        XCTAssertEqual(OpLogChain.prev(ofLine: forged), .some(OpLogChain.lineHash(ours[1])),
                       "the premise: this line's prev is correct")

        try await store.append(op("op-3"))

        let written = try lines()
        XCTAssertEqual(written.count, 3)
        XCTAssertFalse(written.contains(forged))
        XCTAssertEqual(OpLogChain.prev(ofLine: written[2]),
                       .some(OpLogChain.lineHash(ours[1])))
        let records = linesRecords()
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.reason, "written by something that is not Maugham")
        let archive = OpLogQuarantine.quarantinedFileURL(for: record, in: projectURL)
        XCTAssertEqual(try lines(of: archive), [forged])
    }

    /// A break that is neither of those — a line naming a `prev` that is simply
    /// wrong — is reported in the writer's other words: the chain is broken,
    /// not that something else wrote here.
    func test_abrokenChainIsReportedAsABrokenChain() async throws {
        let store = makeStore()
        try await store.append(op("op-1"))
        let ours = try lines()
        state.remember(head: nil, for: OpLogDeviceState.fileKey(fileURL))

        let wrong = OpLogChain.chainedLine(
            elementJSON: try encoded(op("wrong")),
            prev: String(repeating: "0", count: 64))
        try appendByHand(wrong)

        try await store.append(op("op-2"))

        XCTAssertEqual(try lines().count, 2)
        let records = linesRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try XCTUnwrap(records.first).reason, "the history's chain is broken")
        _ = ours
    }

    // MARK: - (e) the seal cadence

    /// `chainSealInterval` lines produce exactly one seal, it holds together on
    /// its own terms, and the key it names is this device's.
    func test_theSealArrivesEveryIntervalLinesAndVerifies() async throws {
        let store = makeStore()
        for i in 1...OpLogStore.chainSealInterval {
            try await store.append(op(String(format: "op-%04d", i)))
        }

        let written = try lines()
        let seals = written.filter { OpLogChain.isSealLine($0) }
        XCTAssertEqual(seals.count, 1, "one seal, not one per line and not none")
        XCTAssertEqual(written.count, OpLogStore.chainSealInterval + 1)
        XCTAssertEqual(written.last, seals[0], "the seal closes the run")

        let seal = try XCTUnwrap(OpLogChain.Seal.parse(seals[0]))
        XCTAssertTrue(seal.verifies())
        XCTAssertEqual(seal.key, identity.fingerprint)
        XCTAssertEqual(seal.head, OpLogChain.lineHash(written[written.count - 2]))

        let verification = OpLogChain.verify(
            bytes: try Data(contentsOf: fileURL),
            trusted: { [identity] in $0 == identity!.fingerprint },
            rememberedHead: state.head(for: OpLogDeviceState.fileKey(fileURL)))
        XCTAssertNil(verification.breakReason)
        XCTAssertEqual(verification.verifiedCount, OpLogStore.chainSealInterval + 1,
                       "the seal settles every line it covers, itself included")
    }

    // MARK: - (f) sealing when there is nothing to seal

    /// A seal commits to something new or it does not happen: an empty file, and
    /// a file already sealed to its head, both answer false and write nothing.
    func test_sealChainWritesNothingWhenThereIsNothingUnsealed() async throws {
        let store = makeStore()
        let onEmpty = try await store.sealChain(docId: docId)
        XCTAssertFalse(onEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        try await store.append(op("op-1"))
        let sealedFirst = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealedFirst, "one unsealed line seals")
        let afterFirst = try lines()

        let sealedAgain = try await store.sealChain(docId: docId)
        XCTAssertFalse(sealedAgain, "nothing new to commit to")
        XCTAssertEqual(try lines(), afterFirst, "and nothing was written")
    }

    /// A device with no key writes chained lines that nothing seals. That is a
    /// state, not an error — it answers false and throws nothing.
    func test_anUnsignedDeviceSealsNothingAndThrowsNothing() async throws {
        let unsigned = DeviceIdentity.unsignedForTesting(token: Data(repeating: 7, count: 32))
        let store = OpLogStore(projectURL: projectURL, identity: unsigned, state: state)
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: unsigned.slug, in: projectURL)
        try await store.append(
            Op(opId: "op-1", docId: docId, at: Date(timeIntervalSince1970: 0),
               device: unsigned.deviceId, session: "s", kind: .typingBurst,
               changes: [.init(paragraphId: "aaaa", prior: nil, next: "x")],
               sequence: ["aaaa"]))

        let sealed = try await store.sealChain(docId: docId)
        XCTAssertFalse(sealed)
        let written = try lines(of: url)
        XCTAssertEqual(written.count, 1, "the op is there; no seal is")
        XCTAssertFalse(OpLogChain.isSealLine(written[0]))
        XCTAssertEqual(OpLogChain.prev(ofLine: written[0]), .some(OpLogChain.genesis),
                       "an unsigned device still chains")
    }

    // MARK: - Stores with no chain

    /// Every other store — publications, tasks, checkpoints — keeps the plain
    /// append it has always had. A `prev` in one of those files would be a
    /// format change nothing asked for.
    func test_aStoreWithNoChainPolicyWritesUnchainedLines() async throws {
        let url = projectURL.appendingPathComponent("plain.jsonl")
        let store = JSONLAppendStore<Op>(fileURL: url)
        try await store.append(op("op-1"))
        XCTAssertEqual(OpLogChain.prev(ofLine: try lines(of: url)[0]), .some(nil))
        let sealed = try await store.appendSeal()
        XCTAssertFalse(sealed, "and it cannot be sealed")
    }
}
