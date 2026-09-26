import Foundation
import XCTest
@testable import MaughamCore

/// **A closed document's held lines, counted without opening it** (signed op
/// log P3 plan 3, carry C4).
///
/// The admission sheet counts what is held across the book. Until C4 it could
/// count only what an OPEN document's load had stamped, so a stranger who had
/// written only in chapters nobody had opened was asked about when one of them
/// was opened and not before. `OpLogStore.provenance(forDocId:in:trust:state:)`
/// is the per-document half of the Mac's closed-document sweep: the same
/// per-file classify a load runs, with the same permit context, summed the
/// same way.
///
/// **Pinned against the load itself**, file by file, over the three reasons a
/// line is held — a stranger's seal, a permit this device cannot yet settle
/// (§4.5, a piece nobody has claimed), and an unsigned stream after the
/// photograph — so a line held by only one of the two paths is a failure in
/// either direction.
@MainActor
final class ClosedProvenanceTests: XCTestCase {

    private let docId = "doc-closed"
    private var projectURL: URL!

    /// This Mac: the root, and the one judging.
    private var root: LocalIdentities!
    private var rootState: OpLogDeviceState!
    /// Sam's Mac: admitted, then narrowed to an author of some OTHER piece.
    private var sam: LocalIdentities!
    private var samState: OpLogDeviceState!
    /// A Mac with no enclave: chained lines, no seal, no record.
    private var ghost: LocalIdentities!
    /// Kim: a key nothing in this book names.
    private var kim: LocalIdentities!
    private var cache: RegistryCache!

    override func setUp() async throws {
        projectURL = TestTemp.root
            .appendingPathComponent("closed-provenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        root = .softwareForTesting()
        sam = .softwareForTesting()
        ghost = .softwareForTesting()
        kim = .softwareForTesting()
        rootState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state-root.json"))
        samState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state-sam.json"))
        cache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: root.author.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private var rootPerson: String { root.author.fingerprint }
    private var samPerson: String { sam.author.fingerprint }

    private func reader() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: root,
                   state: rootState, cache: cache)
    }

    private func op(_ opId: String, by identity: DeviceIdentity) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: identity.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: opId)],
           sequence: ["aaaa"])
    }

    private func writeRegistry() throws {
        try RegistryWriter.write(
            PersonRecord(
                person: rootPerson, label: "Denver", ownName: "Denver’s MacBook",
                admittedAt: Date(timeIntervalSince1970: 10), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: rootPerson, name: "Denver’s MacBook", kind: .mac,
                actors: [DeviceActor.author.rawValue: rootPerson],
                madeAt: Date(timeIntervalSince1970: 1)),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: samPerson, label: "Sam", ownName: "Sam’s Mac",
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: samPerson, name: "Sam’s Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: samPerson],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: sam.author, in: projectURL)
    }

    private func encoded(_ ops: [Op]) throws -> [Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        return try ops.map { try encoder.encode($0) }
    }

    /// The ghost's stream: chained, sealed by nothing.
    private func ghostFile(_ ops: [Op]) throws {
        var bytes = Data()
        var head = OpLogChain.genesis
        for element in try encoded(ops) {
            let line = OpLogChain.chainedLine(elementJSON: element, prev: head)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: ghost.author.slug, in: projectURL)
        try bytes.write(to: url, options: .atomic)
    }

    /// A signed, sealed file written through the production append.
    private func sealedFile(
        _ ids: [String], by who: LocalIdentities, state: OpLogDeviceState
    ) async throws {
        let store = OpLogStore(projectURL: projectURL, identities: who, state: state)
        for id in ids { try await store.append(op(id, by: who.author)) }
        let sealed = try await store.sealChain(docId: docId)
        XCTAssertTrue(sealed)
    }

    /// Sam narrowed to an author of some OTHER piece, through the production
    /// door: the photograph of every unattributable stream is taken here.
    private func narrowSam() async throws {
        let snapshot = try OpLogStore.unattributablePositions(
            in: projectURL, trust: try await reader().trust())
        try RegistryAdmission.changePermit(
            person: samPerson,
            role: Permit.authorRole, scope: Permit.piecesScope,
            pieces: ["doc-some-other-piece"],
            mark: .nothingApplied, unsigned: snapshot,
            in: projectURL, by: root.author, cache: cache,
            now: { Date(timeIntervalSince1970: 60) })
    }

    private var ghostHolder: String {
        HeldLines.unsignedHolder(
            forStreamKey: "\(docId).\(ghost.author.slug.raw)",
            deviceSlug: ghost.author.slug.raw)
    }

    /// Every reason to hold a line, in one closed document.
    private func threeReasonsToHold() async throws {
        try writeRegistry()
        try ghostFile([op("01", by: ghost.author)])
        try await narrowSam()
        // After the photograph: the ghost's second line is held, unsigned.
        try ghostFile([op("01", by: ghost.author), op("02", by: ghost.author)])
        // Sam opens a piece nobody has claimed and that is not in her scope:
        // §4.5 holds it rather than refusing it.
        try await sealedFile(["10"], by: sam, state: samState)
        // Kim: sealed under a key the register cannot name.
        try await sealedFile(
            ["20", "21"], by: kim,
            state: OpLogDeviceState(
                fileURL: projectURL.appendingPathComponent("state-kim.json")))
    }

    // MARK: - The pin

    func test_aClosedDocumentsProvenanceIsTheLoadsFileByFile() async throws {
        try await threeReasonsToHold()
        let table = try await reader().trust()

        // Asked first, before the load has written anything to the state.
        let closed = try OpLogStore.provenance(
            forDocId: docId, in: projectURL, trust: table, state: rootState)
        let loaded = try await reader().loadDiagnosed(docId: docId).provenance
        // And again after the load's own bookkeeping: still the same answer.
        let closedAgain = try OpLogStore.provenance(
            forDocId: docId, in: projectURL, trust: table, state: rootState)

        // The fixture holds a line for every reason, or it pins nothing.
        XCTAssertEqual(loaded.pendingByDevice[kim.author.fingerprint], 2,
                       "a stranger's sealed span is held")
        XCTAssertEqual(loaded.pendingByDevice[samPerson], 1,
                       "a piece nobody has claimed holds Sam's line")
        XCTAssertEqual(loaded.pendingByDevice[ghostHolder], 1,
                       "the unsigned line after the photograph is held")

        // Field by field, both directions: every file the load classified,
        // and no file the load did not.
        XCTAssertEqual(closed.files, loaded.files)
        XCTAssertEqual(closedAgain.files, loaded.files)
        XCTAssertEqual(closed.pendingByDevice, loaded.pendingByDevice)
        XCTAssertEqual(closed.pendingStrangersByDevice, loaded.pendingStrangersByDevice)
        XCTAssertEqual(closed.pendingStreamsByDevice, loaded.pendingStreamsByDevice)
        XCTAssertEqual(closed.pendingWaitingByDevice, loaded.pendingWaitingByDevice)
        // The one field it does not carry, by contract: which streams are
        // THIS device's own is the load's to say, from identities this
        // function is not given. No held-line reader asks it.
        XCTAssertTrue(closed.ownStreams.isEmpty)
    }

    /// **It reads and never writes**: no forensic record, no adopted head, no
    /// remembered digest — the three writes a LOAD makes.
    func test_askingAboutAClosedDocumentWritesNothing() async throws {
        try await threeReasonsToHold()
        let table = try await reader().trust()
        let quarantine = projectURL.appendingPathComponent(
            ".maugham/conflicts/quarantined-ops")
        let before = try? FileManager.default.contentsOfDirectory(atPath: quarantine.path)
        let stateBefore = try? Data(contentsOf: rootState.fileURL)

        _ = try OpLogStore.provenance(
            forDocId: docId, in: projectURL, trust: table, state: rootState)

        XCTAssertEqual(
            try? FileManager.default.contentsOfDirectory(atPath: quarantine.path),
            before)
        XCTAssertEqual(try? Data(contentsOf: rootState.fileURL), stateBefore)
    }

    func test_aDocumentWithNoHistoryHasNoProvenance() throws {
        let table = TrustResolution.keyless(mine: root)
        let none = try OpLogStore.provenance(
            forDocId: "doc-nothing", in: projectURL, trust: table, state: rootState)
        XCTAssertEqual(none, OpLogProvenance())
    }
}
