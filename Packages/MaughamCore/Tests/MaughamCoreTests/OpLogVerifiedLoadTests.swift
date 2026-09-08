import CryptoKit
import XCTest
@testable import MaughamCore

/// The reader's side of the signed op log: every line of every file in the glob
/// is classified before anything is applied, the lines that cannot be shown to
/// follow from what came before them are set aside instead of applied, and the
/// two readers — the coordinated async one and the synchronous heuristic one —
/// agree about which ops a document is made of.
@MainActor
final class OpLogVerifiedLoadTests: XCTestCase {

    private let docId = "doc-verified"
    private var projectURL: URL!
    /// This device.
    private var mine: DeviceIdentity!
    private var myState: OpLogDeviceState!
    /// Another device whose seals this device does not trust.
    private var theirs: DeviceIdentity!
    private var theirState: OpLogDeviceState!
    /// A third device, whose file is broken.
    private var broken: DeviceIdentity!
    private var brokenState: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("verified-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        mine = .softwareForTesting()
        theirs = .softwareForTesting()
        broken = .softwareForTesting()
        myState = makeState("mine")
        theirState = makeState("theirs")
        brokenState = makeState("broken")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func makeState(_ name: String) -> OpLogDeviceState {
        OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state-\(name).json"))
    }

    // MARK: - Fixture

    private func op(_ opId: String, device: DeviceIdentity, next: String = "a sentence") -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: device.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: next)],
           sequence: ["aaaa"])
    }

    private func fileURL(of identity: DeviceIdentity) -> URL {
        OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL)
    }

    private var legacyURL: URL {
        projectURL.appendingPathComponent(".maugham/ops/\(docId).jsonl")
    }

    private func encoded(_ op: Op) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(op)
    }

    private func lineCount(of url: URL) throws -> Int {
        try Data(contentsOf: url)
            .split(separator: 0x0A, omittingEmptySubsequences: true).count
    }

    /// This device's own file: chained lines, sealed by this device's key.
    @discardableResult
    private func writeMyOwnSealedFile(_ opIds: [String]) async throws -> [String] {
        let store = OpLogStore(projectURL: projectURL, identity: mine, state: myState)
        for id in opIds { try await store.append(op(id, device: mine)) }
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed, "the fixture's own file is sealed")
        return opIds
    }

    /// Another device's file: chained and sealed by a key this device has never
    /// seen. Every line is history — applied, never claimed as our own word.
    @discardableResult
    private func writeForeignSealedFile(_ opIds: [String]) async throws -> [String] {
        let store = OpLogStore(projectURL: projectURL, identity: theirs, state: theirState)
        for id in opIds { try await store.append(op(id, device: theirs)) }
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed)
        return opIds
    }

    /// A file written before this milestone: no `prev` anywhere, no seal.
    @discardableResult
    private func writeLegacyFile(_ opIds: [String]) throws -> [String] {
        var bytes = Data()
        for id in opIds {
            bytes.append(try encoded(op(id, device: mine)))
            bytes.append(0x0A)
        }
        try bytes.write(to: legacyURL)
        return opIds
    }

    /// A third device's file whose chain breaks: two good chained lines, then a
    /// line naming a `prev` that is not the head. The break's line is the only
    /// one that must not be applied.
    private func writeBrokenForeignFile(
        keptOpIds: [String], brokenOpId: String
    ) async throws {
        let store = OpLogStore(projectURL: projectURL, identity: broken, state: brokenState)
        for id in keptOpIds { try await store.append(op(id, device: broken)) }
        let url = fileURL(of: broken)
        var bytes = try Data(contentsOf: url)
        bytes.append(OpLogChain.chainedLine(
            elementJSON: try encoded(op(brokenOpId, device: broken)),
            prev: String(repeating: "0", count: 64)))
        bytes.append(0x0A)
        try bytes.write(to: url)
    }

    private var linesRecords: [QuarantineRecord] {
        OpLogQuarantine.records(forDocId: docId, in: projectURL)
            .filter { $0.kind == .lines }
    }

    private func makeReader() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identity: mine, state: myState)
    }

    // MARK: - (a) the whole glob, classified

    /// The merged ops are the union of every line that was allowed to be
    /// applied — and exactly that. The broken file's last line is missing; every
    /// other file's every op is present, whoever wrote it.
    func test_theMergedOpsAreTheUnionOfEveryAppliedLine() async throws {
        try await writeMyOwnSealedFile(["01A", "01B"])
        try await writeForeignSealedFile(["02A", "02B"])
        try writeLegacyFile(["03A"])
        try await writeBrokenForeignFile(keptOpIds: ["04A", "04B"], brokenOpId: "04C")

        let loaded = try await makeReader().loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["01A", "01B", "02A", "02B", "03A", "04A", "04B"])
        XCTAssertFalse(loaded.ops.contains { $0.opId == "04C" },
                       "the line after the break is never applied")
    }

    /// A seal is a line of its own kind, not a torn op. Before this task it
    /// reached the `Op` decoder and landed in `diagnostics.skipped` as if the
    /// file were corrupt.
    func test_aSealIsNeverReportedAsATornLine() async throws {
        try await writeMyOwnSealedFile(["01A", "01B"])
        let loaded = try await makeReader().loadDiagnosed(docId: docId)
        XCTAssertTrue(loaded.diagnostics.skipped.isEmpty,
                      "a sealed file is not a damaged one: \(loaded.diagnostics.skipped)")
    }

    /// Every class of line is counted, per file and in the sum.
    func test_provenanceCountsEveryClassOfLine() async throws {
        try await writeMyOwnSealedFile(["01A", "01B"])
        try await writeForeignSealedFile(["02A", "02B"])
        try writeLegacyFile(["03A"])
        try await writeBrokenForeignFile(keptOpIds: ["04A", "04B"], brokenOpId: "04C")

        let provenance = try await makeReader().loadDiagnosed(docId: docId).provenance
        func file(_ url: URL) throws -> FileProvenance {
            let name = url.lastPathComponent
            return try XCTUnwrap(provenance.files.first { $0.name == name }, name)
        }

        // Our own: two ops plus the seal that covers them, all verified.
        let ours = try file(fileURL(of: mine))
        XCTAssertEqual(ours.verified, 3)
        XCTAssertEqual(ours.unsignedHistory, 0)
        XCTAssertEqual(ours.quarantined, 0)
        XCTAssertFalse(ours.isSealedSegment)

        // Theirs: the same shape under a key we do not trust.
        let foreign = try file(fileURL(of: theirs))
        XCTAssertEqual(foreign.verified, 0)
        XCTAssertEqual(foreign.unsignedHistory, 3)

        // Legacy: one line, no prev, no seal.
        XCTAssertEqual(try file(legacyURL).legacy, 1)

        // Broken: two chained-but-unsealed lines kept, one set aside.
        let brokenFile = try file(fileURL(of: broken))
        XCTAssertEqual(brokenFile.unsealed, 2)
        XCTAssertEqual(brokenFile.quarantined, 1)

        XCTAssertEqual(provenance.verifiedLines, 3)
        XCTAssertEqual(provenance.unsignedHistoryLines, 3)
        XCTAssertEqual(provenance.legacyLines, 1)
        XCTAssertEqual(provenance.quarantinedLines, 1)
        XCTAssertTrue(provenance.hasLegacyHistory)
        XCTAssertTrue(provenance.hasUnsignedForeignHistory)
    }

    /// A clean project of this device's own sealed history claims neither.
    func test_ourOwnSealedHistoryIsNeitherLegacyNorForeign() async throws {
        try await writeMyOwnSealedFile(["01A", "01B"])
        let provenance = try await makeReader().loadDiagnosed(docId: docId).provenance
        XCTAssertFalse(provenance.hasLegacyHistory)
        XCTAssertFalse(provenance.hasUnsignedForeignHistory)
        XCTAssertEqual(provenance.quarantinedLines, 0)
    }

    // MARK: - (b) the set-aside record

    /// The bytes of the break are on disk, as a `.lines` record, and the file
    /// they came from is untouched — a load reads; it does not rewrite.
    func test_theBreaksLinesAreSetAsideOnDisk() async throws {
        try await writeBrokenForeignFile(keptOpIds: ["04A", "04B"], brokenOpId: "04C")
        let before = try lineCount(of: fileURL(of: broken))

        _ = try await makeReader().loadDiagnosed(docId: docId)

        let records = linesRecords
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.reason, "the history's chain is broken")
        XCTAssertEqual(records.first?.originalName, fileURL(of: broken).lastPathComponent)
        let archive = OpLogQuarantine.quarantinedFileURL(
            for: try XCTUnwrap(records.first), in: projectURL)
        let archived = try String(contentsOf: archive, encoding: .utf8)
        XCTAssertTrue(archived.contains("04C"), "the set-aside bytes are the break's own")
        XCTAssertEqual(try lineCount(of: fileURL(of: broken)), before,
                       "reading sets nothing aside by rewriting the file")
    }

    /// The same break found again on the next open is the same event, not a
    /// second one — the record is content-deduped.
    func test_aSecondLoadWritesNoSecondRecord() async throws {
        try await writeBrokenForeignFile(keptOpIds: ["04A"], brokenOpId: "04C")
        let reader = makeReader()
        _ = try await reader.loadDiagnosed(docId: docId)
        _ = try await reader.loadDiagnosed(docId: docId)
        XCTAssertEqual(linesRecords.count, 1)
    }

    // MARK: - (c) the two readers agree

    /// The synchronous reader and the coordinated one must be made of the same
    /// ops. `loadSyncMerged` is what MCP's `read_document` and the Practice
    /// walk read a CLOSED document through; if it applied a line the editor
    /// quarantines, Claude and the writer would be looking at two manuscripts.
    func test_theTwoReadersApplyTheSameOps() async throws {
        try await writeMyOwnSealedFile(["01A", "01B"])
        try await writeForeignSealedFile(["02A"])
        try writeLegacyFile(["03A"])
        try await writeBrokenForeignFile(keptOpIds: ["04A", "04B"], brokenOpId: "04C")

        let async = try await makeReader().loadDiagnosed(docId: docId).ops.map(\.opId)
        let sync = try OpLogStore.loadSyncMerged(
            forDocId: docId, in: projectURL, identity: mine, state: myState).map(\.opId)
        XCTAssertEqual(sync, async)
        XCTAssertFalse(sync.contains("04C"))
    }

    /// The sync reader is a reader: it omits what it will not apply and writes
    /// no forensic record of its own.
    func test_theSyncReaderWritesNoQuarantineRecord() async throws {
        try await writeBrokenForeignFile(keptOpIds: ["04A"], brokenOpId: "04C")
        _ = try OpLogStore.loadSyncMerged(
            forDocId: docId, in: projectURL, identity: mine, state: myState)
        XCTAssertTrue(linesRecords.isEmpty)
    }

    /// The remembered-head rule reaches the sync reader too: a line that chains
    /// perfectly but arrived after the head this device wrote is not ours.
    func test_bothReadersRefuseALineForgedAfterTheRememberedHead() async throws {
        try await writeMyOwnSealedFile(["01A"])
        // Something else reads the file, computes the head correctly, and
        // appends a well-formed op of its own.
        let url = fileURL(of: mine)
        var bytes = try Data(contentsOf: url)
        let head = OpLogChain.lineHash(Data(
            bytes.split(separator: 0x0A, omittingEmptySubsequences: true).last!))
        bytes.append(OpLogChain.chainedLine(
            elementJSON: try encoded(op("09Z", device: mine, next: "not mine")),
            prev: head))
        bytes.append(0x0A)
        try bytes.write(to: url)

        let async = try await makeReader().loadDiagnosed(docId: docId)
        XCTAssertFalse(async.ops.contains { $0.opId == "09Z" },
                       "a correctly-chained stranger is still a stranger")
        XCTAssertEqual(async.provenance.quarantinedLines, 1)

        let sync = try OpLogStore.loadSyncMerged(
            forDocId: docId, in: projectURL, identity: mine, state: myState).map(\.opId)
        XCTAssertEqual(sync, async.ops.map(\.opId))
        XCTAssertEqual(linesRecords.first?.reason,
                       "written by something that is not Maugham")
    }

    // MARK: - (d) the adopt rule

    /// The crash window: the device remembered a head and died before the line
    /// that would have hashed to it was written. Nothing in the file is wrong —
    /// no break, every seal ours — so the device adopts the file's head rather
    /// than quarantining its own history forever.
    func test_aRememberedHeadTheFileLacksIsAdopted() async throws {
        try await writeMyOwnSealedFile(["01A", "01B"])
        let url = fileURL(of: mine)
        let key = OpLogDeviceState.fileKey(url)
        let trueHead = try XCTUnwrap(myState.head(for: key))
        myState.remember(head: String(repeating: "b", count: 64), for: key)

        let loaded = try await makeReader().loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["01A", "01B"],
                       "the device's own history is not quarantined by its own crash")
        XCTAssertEqual(myState.head(for: key), trueHead,
                       "the file's head is adopted")
    }

    /// Adoption is for a file that holds together. A file with a break keeps
    /// the head the device remembers — adopting there would bless the break.
    func test_aBrokenFileIsNotAdopted() async throws {
        try await writeMyOwnSealedFile(["01A"])
        let url = fileURL(of: mine)
        var bytes = try Data(contentsOf: url)
        bytes.append(OpLogChain.chainedLine(
            elementJSON: try encoded(op("09Z", device: mine)),
            prev: String(repeating: "f", count: 64)))
        bytes.append(0x0A)
        try bytes.write(to: url)

        let key = OpLogDeviceState.fileKey(url)
        let stranger = String(repeating: "b", count: 64)
        myState.remember(head: stranger, for: key)
        _ = try await makeReader().loadDiagnosed(docId: docId)
        XCTAssertEqual(myState.head(for: key), stranger,
                       "a break is never adopted")
    }

    /// And a file whose seals are someone else's is not this device's history
    /// to adopt a head from.
    func test_aForeignSealedFileIsNotAdopted() async throws {
        try await writeForeignSealedFile(["02A"])
        let key = OpLogDeviceState.fileKey(fileURL(of: theirs))
        let stranger = String(repeating: "b", count: 64)
        myState.remember(head: stranger, for: key)
        _ = try await makeReader().loadDiagnosed(docId: docId)
        XCTAssertEqual(myState.head(for: key), stranger)
    }

    // MARK: - (e) the recovery reader

    /// `loadDiagnosedPartial` is the same classification with the same answer —
    /// the read-only recovery rung must not see a different manuscript.
    func test_thePartialReaderClassifiesTheSameWay() async throws {
        try await writeMyOwnSealedFile(["01A"])
        try await writeBrokenForeignFile(keptOpIds: ["04A"], brokenOpId: "04C")
        let reader = makeReader()
        let strict = try await reader.loadDiagnosed(docId: docId)
        let partial = await reader.loadDiagnosedPartial(docId: docId)
        XCTAssertEqual(partial.ops.map(\.opId), strict.ops.map(\.opId))
        XCTAssertEqual(partial.provenance.quarantinedLines, 1)
    }
}
