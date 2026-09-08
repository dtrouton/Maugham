import XCTest
@testable import MaughamCore

/// What a clean walk means when the head this device REMEMBERS is nowhere in
/// the file (the whole-branch review's I2).
///
/// The remembered head catches an agent that APPENDS. It caught nothing at all
/// against one that TRUNCATES: cut the file back to its last seal line, append
/// correctly-chained lines of your own, and the walk finds no break, our own
/// seals, and a head we have never seen — which the load used to ADOPT, and
/// then remember, so the next append chained onto the forgery.
///
/// Three branches now, and the fourth is a deliberate refusal to act.
@MainActor
final class AbsentRememberedHeadTests: XCTestCase {

    private let docId = "doc-absent"
    private var projectURL: URL!
    private var mine: DeviceIdentity!
    private var myState: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        mine = .softwareForTesting()
        myState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state.json"),
            identity: mine.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private func op(_ opId: String, next: String = "a sentence") -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: mine.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: next)],
           sequence: ["aaaa"])
    }

    private var fileURL: URL {
        OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: mine.slug, in: projectURL)
    }

    private var fileKey: String { OpLogDeviceState.fileKey(fileURL) }

    private func makeStore() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identity: mine, state: myState)
    }

    private func encoded(_ op: Op) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(op)
    }

    private func lines(of url: URL) throws -> [Data] {
        try Data(contentsOf: url)
            .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
            .map { Data($0) }
    }

    /// Two ops and a seal, all this device's own.
    private func writeMyOwnSealedFile(_ opIds: [String]) async throws {
        let store = makeStore()
        for id in opIds { try await store.append(op(id)) }
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed)
    }

    private func linesRecords() -> [QuarantineRecord] {
        OpLogQuarantine.records(forDocId: docId, in: projectURL)
            .filter { $0.kind == .lines }
    }

    // MARK: - Branch 1: no memory at all

    /// A moved project, a fresh identity, the first run after this upgrade —
    /// the device has no head for this file, so there is nothing to be absent
    /// and nothing to decide. Everything applies; nothing is held back.
    func test_withNoRememberedHeadEveryLineStillApplies() async throws {
        try await writeMyOwnSealedFile(["01A", "01B"])
        myState.remember(head: nil, for: fileKey)

        let loaded = try await makeStore().loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["01A", "01B"])
        XCTAssertEqual(loaded.provenance.quarantinedLines, 0)
        XCTAssertTrue(linesRecords().isEmpty)
        XCTAssertNil(myState.head(for: fileKey), "and nothing is adopted")
    }

    // MARK: - Branch 2: the crash window

    /// `chainedAppend` persists the new head BEFORE writing the line that hashes
    /// to it, so a crash between the two leaves a remembered head no line
    /// carries — and the file's own head is the one remembered LAST time. That
    /// signature, and only that one, is adopted.
    func test_theCrashWindowsHeadIsAdopted() async throws {
        try await writeMyOwnSealedFile(["01A", "01B"])
        let trueHead = try XCTUnwrap(myState.head(for: fileKey))
        // The crash: a head persisted for a line that was never written.
        myState.remember(head: String(repeating: "b", count: 64), for: fileKey)
        XCTAssertEqual(myState.previousHead(for: fileKey), trueHead)

        let loaded = try await makeStore().loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["01A", "01B"],
            "a device's own crash never costs it its own history")
        XCTAssertEqual(loaded.provenance.quarantinedLines, 0)
        XCTAssertEqual(myState.head(for: fileKey), trueHead, "the file's head is adopted")
    }

    // MARK: - Branch 3: the truncation

    /// The attack the remembered head used to miss: truncate to the last seal,
    /// append correctly-chained lines. The walk cannot fault them — they chain,
    /// the seals before them are ours — so the ONLY fact left is that the head
    /// we remember is gone and the head the file has is not the crash window's.
    /// Everything after the last seal this device signed is held back.
    func test_aFileTruncatedToItsSealAndForgedOnIsNotAdoptedAndNotApplied() async throws {
        try await writeMyOwnSealedFile(["01A", "01B"])
        let sealed = try lines(of: fileURL)
        XCTAssertTrue(OpLogChain.isSealLine(sealed[2]), "the fixture ends on a seal")
        let rememberedBefore = try XCTUnwrap(myState.head(for: fileKey))

        // Two more of the writer's own ops, so the remembered head moves on and
        // there is something for the truncation to remove.
        try await makeStore().append(op("01C"))
        try await makeStore().append(op("01D"))
        let rememberedAfter = try XCTUnwrap(myState.head(for: fileKey))
        XCTAssertNotEqual(rememberedAfter, rememberedBefore)

        // The agent: cut back to the seal, chain its own lines onto it.
        var forged = Data()
        for line in sealed { forged.append(line); forged.append(0x0A) }
        var head = OpLogChain.lineHash(sealed[2])
        for id in ["09Y", "09Z"] {
            let line = OpLogChain.chainedLine(
                elementJSON: try encoded(op(id, next: "not the writer's")), prev: head)
            forged.append(line)
            forged.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        try forged.write(to: fileURL)

        let loaded = try await makeStore().loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["01A", "01B"],
            "the sealed prefix applies and the forged suffix does not")
        XCTAssertEqual(loaded.provenance.quarantinedLines, 2)
        XCTAssertEqual(myState.head(for: fileKey), rememberedAfter,
            "and this device does not take the forged head as its own word")
        XCTAssertEqual(linesRecords().first?.reason, "the history's chain is broken")
    }

    /// And the writer keeps writing: the next append truncates the forgery,
    /// files it, and chains onto the seal — so their new op is applied rather
    /// than stranded on the far side of a permanent break.
    func test_theNextAppendClearsTheForgeryRatherThanChainingOntoIt() async throws {
        try await writeMyOwnSealedFile(["01A"])
        let sealed = try lines(of: fileURL)
        try await makeStore().append(op("01C"))

        var forged = Data()
        for line in sealed { forged.append(line); forged.append(0x0A) }
        let line = OpLogChain.chainedLine(
            elementJSON: try encoded(op("09Z", next: "not the writer's")),
            prev: OpLogChain.lineHash(sealed[1]))
        forged.append(line)
        forged.append(0x0A)
        try forged.write(to: fileURL)

        try await makeStore().append(op("01E"))
        let loaded = try await makeStore().loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["01A", "01E"])
        XCTAssertEqual(loaded.provenance.quarantinedLines, 0,
            "the file is whole again — the forgery is in the archive, not the tail")
    }

    // MARK: - Branch 4: nothing signed, nothing to anchor on

    /// A device with no key signs nothing, so there is no trusted seal to fall
    /// back to. Quarantining the whole file over a missing head would cost the
    /// writer their manuscript and catch nobody — its tail is unsigned history
    /// by definition (ADR 0032 §3).
    func test_anUnsignedDevicesTailIsLeftExactlyAsTheWalkFoundIt() async throws {
        let unsigned = DeviceIdentity.unsignedForTesting(
            token: Data(repeating: 7, count: 32))
        let state = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("unsigned-state.json"),
            identity: unsigned.fingerprint)
        let store = OpLogStore(projectURL: projectURL, identity: unsigned, state: state)
        let unsignedOp = { (id: String) in
            Op(opId: id, docId: self.docId, at: Date(timeIntervalSince1970: 0),
               device: unsigned.deviceId, session: "s", kind: .typingBurst,
               changes: [.init(paragraphId: "aaaa", prior: nil, next: "x")],
               sequence: ["aaaa"])
        }
        try await store.append(unsignedOp("01A"))
        try await store.append(unsignedOp("01B"))

        let key = OpLogDeviceState.fileKey(
            OpLogStore.opLogFileURL(
                forDocId: docId, deviceSlug: unsigned.slug, in: projectURL))
        state.remember(head: String(repeating: "c", count: 64), for: key)
        state.remember(head: String(repeating: "d", count: 64), for: key)

        let loaded = try await store.loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["01A", "01B"])
        XCTAssertEqual(loaded.provenance.quarantinedLines, 0)
    }
}
