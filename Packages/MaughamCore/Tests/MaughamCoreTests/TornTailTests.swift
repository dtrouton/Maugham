import XCTest
@testable import MaughamCore

/// A torn last line is a crash, not a forgery (the whole-branch review's I8/L62).
///
/// A write interrupted mid-line leaves bytes that are not a complete JSON
/// object. If the tear falls before the `prev` key is closed, the walk saw a
/// line with no `prev` after the chain had begun — `unchainedAfterChain` — and
/// filed it under "written by something that is not Maugham", in a `.lines`
/// record that never clears. A tear PAST that key was harmless: the line was
/// applied and failed in the element decoder, landing in `diagnostics.skipped`.
/// Two outcomes for one accident, and the loud one was wrong.
@MainActor
final class TornTailTests: XCTestCase {

    private let docId = "doc-torn"
    private var projectURL: URL!
    private var theirs: DeviceIdentity!
    private var theirState: OpLogDeviceState!
    private var mine: DeviceIdentity!
    private var myState: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("torn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        mine = .softwareForTesting()
        theirs = .softwareForTesting()
        myState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("mine.json"),
            identity: mine.fingerprint)
        theirState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("theirs.json"),
            identity: theirs.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private func op(_ opId: String, device: DeviceIdentity) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: device.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: "a sentence")],
           sequence: ["aaaa"])
    }

    private var theirFileURL: URL {
        OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: theirs.slug, in: projectURL)
    }

    private func makeReader() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identity: mine, state: myState)
    }

    private func linesRecords() -> [QuarantineRecord] {
        OpLogQuarantine.records(forDocId: docId, in: projectURL)
            .filter { $0.kind == .lines }
    }

    /// Three chained ops in another device's file, its last line then cut at
    /// `byteOffset` — the tear a crash mid-append leaves.
    private func writeTheirFileTearingTheLastLine(at byteOffset: Int) async throws {
        let store = OpLogStore(projectURL: projectURL, identity: theirs, state: theirState)
        for id in ["02A", "02B", "02C"] { try await store.append(op(id, device: theirs)) }

        var lines = try Data(contentsOf: theirFileURL)
            .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
            .map { Data($0) }
        let last = lines.removeLast()
        var bytes = Data()
        for line in lines { bytes.append(line); bytes.append(0x0A) }
        bytes.append(last.prefix(byteOffset))
        bytes.append(0x0A)
        try bytes.write(to: theirFileURL)
    }

    // MARK: - The tear on the last line

    /// Byte 40 is inside the `prev` key's own value, which is the window that
    /// used to break the walk.
    func test_aTearOnTheLastLineIsSkippedRatherThanAccused() async throws {
        try await writeTheirFileTearingTheLastLine(at: 40)

        let loaded = try await makeReader().loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["02A", "02B"],
            "every whole line still applies")
        XCTAssertEqual(loaded.diagnostics.skipped.count, 1,
            "and the torn bytes are reported where a torn line has always been "
            + "reported: the element decoder's skipped list")
        XCTAssertEqual(loaded.provenance.quarantinedLines, 0)
        XCTAssertTrue(linesRecords().isEmpty,
            "no forensic record — nothing wrote into this file, a write stopped")
    }

    /// A tear PAST the `prev` key was always harmless; it must stay harmless,
    /// and by the same route.
    func test_aTearPastThePrevKeyIsStillJustASkippedLine() async throws {
        try await writeTheirFileTearingTheLastLine(at: 120)

        let loaded = try await makeReader().loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["02A", "02B"])
        XCTAssertEqual(loaded.diagnostics.skipped.count, 1)
        XCTAssertTrue(linesRecords().isEmpty)
    }

    /// Only the LAST line may be torn. An incomplete line with something after
    /// it means the write finished, so the damage is not a tear — it breaks the
    /// chain exactly as before.
    func test_anIncompleteLineThatIsNotTheLastStillBreaksTheChain() async throws {
        let store = OpLogStore(projectURL: projectURL, identity: theirs, state: theirState)
        for id in ["02A", "02B"] { try await store.append(op(id, device: theirs)) }

        var lines = try Data(contentsOf: theirFileURL)
            .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
            .map { Data($0) }
        let last = lines.removeLast()
        var bytes = Data()
        for line in lines { bytes.append(line); bytes.append(0x0A) }
        bytes.append(last.prefix(40))
        bytes.append(0x0A)
        bytes.append(Data(#"{"whole":"line"}"#.utf8))
        bytes.append(0x0A)
        try bytes.write(to: theirFileURL)

        let loaded = try await makeReader().loadDiagnosed(docId: docId)
        XCTAssertEqual(loaded.ops.map(\.opId), ["02A"])
        XCTAssertEqual(loaded.provenance.quarantinedLines, 2,
            "the incomplete line and everything after it")
        XCTAssertEqual(linesRecords().count, 1)
    }

    // MARK: - The shape test itself

    func test_isIncompleteObjectReadsTheLastNonBlankByte() {
        XCTAssertFalse(OpLogChain.isIncompleteObject(Data(#"{"a":1}"#.utf8)))
        XCTAssertFalse(OpLogChain.isIncompleteObject(Data("{\"a\":1}  \t".utf8)))
        XCTAssertTrue(OpLogChain.isIncompleteObject(Data(#"{"a":1"#.utf8)))
        XCTAssertTrue(OpLogChain.isIncompleteObject(Data()))
    }
}
