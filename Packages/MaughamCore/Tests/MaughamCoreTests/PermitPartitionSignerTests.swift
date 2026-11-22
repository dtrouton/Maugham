import Foundation
import XCTest
@testable import MaughamCore

/// **Who sealed a note** (shell p5 Task 1): which of the four writers' keys
/// sealed each annotation creation a load applied, read off the seal and
/// through the one trust table — never off the op's own stamp, its `device`
/// string or the file's name.
///
/// Two kinds of fixture, because the reading has two homes. A store writing
/// real chained, sealed files and loading them back covers the registerless
/// book (where the partition judges nothing and the signer is still read) and
/// the settled segment; a hand-chained file classified against a resolved
/// table covers a book with a register (an admitted peer, an unrecorded key).
@MainActor
final class PermitPartitionSignerTests: XCTestCase {

    private let docId = "doc-signer"
    private var projectURL: URL!
    private var identities: LocalIdentities!
    private var state: OpLogDeviceState!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("signer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        // Software signers: CI's runner has no enclave, and a seal is what
        // these tests are about (tripwire 36's named exception).
        identities = .softwareForTesting()
        state = OpLogDeviceState(fileURL: projectURL.appendingPathComponent("state.json"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixtures

    /// An annotation creation, stamped by its writer as `stamp` — a field any
    /// writer of a line may set, which is the whole reason it is never read.
    private func note(
        _ opId: String, by identity: DeviceIdentity, stamp: String = "human"
    ) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 1),
           device: identity.deviceId, session: "s", kind: .claudeComment,
           changes: [], sequence: nil,
           provenance: .init(annotationBody: "a note", authorSourceKind: stamp))
    }

    private func store(_ who: LocalIdentities? = nil) -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: who ?? identities, state: state)
    }

    /// A fresh load's signers, as `Document.load` collects them.
    private func signers(_ store: OpLogStore) async throws -> LineSigners {
        let signers = LineSigners()
        _ = try await store.loadDiagnosed(docId: docId, lineSigners: signers)
        return signers
    }

    // MARK: - The four actors, read off the seal

    func test_aLineSealedByTheAuthorKeyIsTheAuthors() async throws {
        let store = store()
        try await store.append(note("01AUTHOR", by: identities.author))
        _ = try await store.sealChain(docId: docId)

        let read = try await signers(self.store())
        XCTAssertEqual(read.actor(ofOp: "01AUTHOR"), .author)
    }

    /// The op's stamp says human; the key says assistant. The key wins, and
    /// the stamp is not consulted at all.
    func test_aLineSealedByTheAssistantKeyIsTheAssistants() async throws {
        let store = store()
        try await store.append(note("01ASSIST", by: identities.assistant, stamp: "human"))
        _ = try await store.sealChain(docId: docId)

        let read = try await signers(self.store())
        XCTAssertEqual(read.actor(ofOp: "01ASSIST"), .assistant)
    }

    func test_eachOfTheFourKeysNamesItsOwnWriter() async throws {
        let store = store()
        let writers: [(String, DeviceIdentity, DeviceActor)] = [
            ("01W1", identities.author, .author),
            ("01W2", identities.assistant, .assistant),
            ("01W3", identities.translator, .translator),
            ("01W4", identities.maugham, .maugham),
        ]
        for (id, identity, _) in writers { try await store.append(note(id, by: identity)) }
        _ = try await store.sealChain(docId: docId)

        let read = try await signers(self.store())
        for (id, _, actor) in writers {
            XCTAssertEqual(read.actor(ofOp: id), actor, id)
        }
    }

    // MARK: - What has no signer

    /// The span after the last seal is applied — it is the ordinary shape of
    /// a live file — but nothing has signed it yet, so it names nobody. The
    /// permit lends such a line the key before it, which is conservative for
    /// a permit and a guess for a person.
    func test_anUnsealedTailHasNoSigner() async throws {
        let store = store()
        try await store.append(note("01SEALED", by: identities.author))
        _ = try await store.sealChain(docId: docId)
        try await store.append(note("01UNSEALED", by: identities.author))

        let read = try await signers(self.store())
        XCTAssertEqual(read.actor(ofOp: "01SEALED"), .author)
        XCTAssertNil(read.actor(ofOp: "01UNSEALED"),
                     "an applied line no seal covers has no signer")
    }

    /// A file nothing ever sealed: applied, and nobody's.
    func test_aNeverSealedFileHasNoSigner() async throws {
        let store = store()
        try await store.append(note("01NEVER", by: identities.author))

        let read = try await signers(self.store())
        XCTAssertNil(read.actor(ofOp: "01NEVER"))
    }

    /// A book with a register: Sam is admitted as a person, but no device
    /// record names his key's actor and his file's name does not carry his
    /// key — so nothing on disk says which of his writers this is. The seal
    /// covering his line names nobody; and the partition, which cannot judge
    /// a line whose actor it cannot name, holds it, so no note appears.
    func test_anUnrecordedKeyHasNoSigner() throws {
        let sam = LocalIdentities.softwareForTesting()
        let samKey = sam.author.fingerprint
        let table = TrustTable.resolve(
            registry: Registry(
                devices: [rootRecord()],
                people: [
                    rootPerson(),
                    PersonRecord(
                        person: samKey, label: "Sam", ownName: "Sam’s Mac",
                        admittedAt: Date(timeIntervalSince1970: 3), admittedBy: root),
                ]),
            mine: identities, joinedRoot: nil)
        XCTAssertEqual(table.verdict(forSealKey: samKey), .admitted(person: samKey))
        XCTAssertNil(table.actor(forSealKey: samKey), "the premise: no record names it")

        var file = Chained()
        try file.append(json(note("01SAMS", by: sam.author)))
        try file.seal(by: sam.author)
        let slug = DeviceSlug.make(from: "sams-mac")

        let walked = OpLogChain.verify(
            bytes: file.bytes, trust: { table.verdict(forSealKey: $0) },
            rememberedHead: nil)
        XCTAssertEqual(walked.lines[0].state, .verified, "the premise: his seal holds")
        XCTAssertEqual(
            PermitPartition.signers(
                of: walked, atLines: [0], trust: table, deviceSlug: slug.raw),
            [:])
        XCTAssertNil(PermitPartition.signingActor(
            ofSealKey: samKey, trust: table, deviceSlug: slug.raw))

        let read = classify(file, named: slug, trust: table)
        XCTAssertEqual(read.applied, [], "held: the partition cannot judge it")
        XCTAssertNil(read.signers.actor(ofOp: "01SAMS"))
    }

    /// A registerless book: another device's sealed file is applied as
    /// unsigned history (`.noChain`), and its key vouches for nobody here —
    /// even though its own file name says `author-…`.
    func test_aKeyNoChainVouchesForHasNoSigner() async throws {
        let other = LocalIdentities.softwareForTesting()
        let theirs = OpLogStore(
            projectURL: projectURL, identities: other,
            state: OpLogDeviceState(fileURL: projectURL.appendingPathComponent("other.json")))
        try await theirs.append(note("01THEIRS", by: other.author))
        _ = try await theirs.sealChain(docId: docId)

        let loaded = LineSigners()
        let ops = try await store().loadDiagnosed(docId: docId, lineSigners: loaded).ops
        XCTAssertEqual(ops.map(\.opId), ["01THEIRS"], "the premise: applied as history")
        XCTAssertNil(loaded.actor(ofOp: "01THEIRS"))
    }

    /// Sam's line is held (a stranger's): not applied, and no signer.
    func test_aStrangersHeldNoteHasNoSigner() throws {
        let sam = LocalIdentities.softwareForTesting()
        let table = TrustTable.resolve(
            registry: Registry(devices: [rootRecord()], people: [rootPerson()]),
            mine: identities, joinedRoot: nil)
        var file = Chained()
        try file.append(json(note("01HELD", by: sam.author)))
        try file.seal(by: sam.author)
        let read = classify(file, named: sam.author.slug, trust: table)
        XCTAssertEqual(read.applied, [])
        XCTAssertNil(read.signers.actor(ofOp: "01HELD"))
    }

    // MARK: - Through the table

    /// An admitted peer's assistant, named by its device record: the partition
    /// judges this book, and the signer is read exactly as it reads the actor.
    func test_anAdmittedPeersAssistantIsTheAssistant() throws {
        let sam = LocalIdentities.softwareForTesting()
        let samKey = sam.author.fingerprint
        let table = TrustTable.resolve(
            registry: Registry(
                devices: [
                    rootRecord(),
                    DeviceRecord(
                        device: samKey, name: "Sam’s Mac", kind: .mac,
                        actors: [
                            DeviceActor.author.rawValue: samKey,
                            DeviceActor.assistant.rawValue: sam.assistant.fingerprint,
                        ],
                        madeAt: Date(timeIntervalSince1970: 5)),
                ],
                people: [
                    rootPerson(),
                    PersonRecord(
                        person: samKey, label: "Sam", ownName: "Sam’s Mac",
                        admittedAt: Date(timeIntervalSince1970: 3), admittedBy: root),
                ]),
            mine: identities, joinedRoot: nil)

        var file = Chained()
        try file.append(json(note("01SAMAI", by: sam.assistant, stamp: "human")))
        try file.seal(by: sam.assistant)
        try file.append(json(note("01SAMLATE", by: sam.assistant)))
        let read = classify(file, named: sam.assistant.slug, trust: table)

        XCTAssertEqual(read.applied, ["01SAMAI", "01SAMLATE"])
        XCTAssertEqual(read.signers.actor(ofOp: "01SAMAI"), .assistant)
        XCTAssertNil(read.signers.actor(ofOp: "01SAMLATE"),
                     "his unsealed tail is applied and names nobody")
    }

    // MARK: - A settled segment

    /// A rotated segment is never walked: its signature settles it whole, and
    /// the key that made the signature is the key over every line in it —
    /// the first load (which reads the `.sig`) and the second (which settles
    /// from memory, carrying no key) alike.
    func test_aSettledSegmentNamesItsKeysActor() async throws {
        let store = store()
        let filler = String(repeating: "x", count: 2_000)
        for id in ["01SEG1", "01SEG2"] {
            var op = note(id, by: identities.assistant)
            op = Op(opId: op.opId, docId: op.docId, at: op.at, device: op.device,
                    session: op.session, kind: op.kind, changes: [], sequence: nil,
                    provenance: .init(annotationBody: filler, authorSourceKind: "human"))
            try await store.append(op)
        }
        _ = try await store.sealChain(docId: docId)
        let segment = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: identities.assistant.slug, threshold: 1_000)
        XCTAssertNotNil(segment, "the premise: the tail rotated")

        let first = try await signers(self.store())
        XCTAssertEqual(first.actor(ofOp: "01SEG1"), .assistant)
        XCTAssertEqual(first.actor(ofOp: "01SEG2"), .assistant)
        XCTAssertTrue(
            state.isVerified(segmentDigest: try XCTUnwrap(
                OpLogSegment.decodeVerifying(try Data(contentsOf: try XCTUnwrap(segment))).digest)),
            "the premise: the second load settles from memory")

        let second = try await signers(self.store())
        XCTAssertEqual(second.actor(ofOp: "01SEG1"), .assistant)
    }

    /// The same, at the partition's own door: `settledByKey` names every line.
    func test_aSettledVerificationNamesItsKeysActorAtEveryLine() throws {
        let table = TrustResolution.keyless(mine: identities)
        let lines = [Data("{}".utf8), Data("{}".utf8)].map {
            OpLogChain.Line(bytes: $0, kind: .op, state: .verified)
        }
        let verification = OpLogChain.Verification(
            lines: lines, head: nil, legacyCount: 0, verifiedCount: 2,
            unsealedCount: 0, foreignSealCount: 0, quarantined: [], breakReason: nil)
        XCTAssertEqual(
            PermitPartition.signers(
                of: verification, atLines: [0, 1], trust: table,
                deviceSlug: nil, settledByKey: identities.translator.fingerprint),
            [0: .translator, 1: .translator])
    }

    // MARK: - The recorder

    /// Two copies of one op sealed by two different writers name nobody,
    /// whichever file was read first.
    func test_twoCopiesSealedByTwoWritersNameNobody() {
        for order in [[DeviceActor.author, .assistant], [.assistant, .author]] {
            let signers = LineSigners()
            for actor in order { signers.record("01DUP", actor) }
            signers.record("01DUP", .author)
            XCTAssertNil(signers.actor(ofOp: "01DUP"), "\(order)")
        }
        let agreeing = LineSigners()
        agreeing.record("01SAME", .author)
        agreeing.record("01SAME", .author)
        XCTAssertEqual(agreeing.actor(ofOp: "01SAME"), .author)
    }

    // MARK: - Hand-chained files

    private var root: String { identities.author.fingerprint }

    private func rootRecord() -> DeviceRecord {
        DeviceRecord(
            device: root, name: "Denver’s MacBook", kind: .mac,
            actors: [DeviceActor.author.rawValue: root],
            madeAt: Date(timeIntervalSince1970: 1))
    }

    private func rootPerson() -> PersonRecord {
        PersonRecord(
            person: root, label: "Denver", ownName: "Denver’s MacBook",
            admittedAt: Date(timeIntervalSince1970: 2), admittedBy: root)
    }

    private struct Chained {
        private(set) var bytes = Data()
        private var head: String?

        mutating func append(_ json: Data) {
            let line = OpLogChain.chainedLine(elementJSON: json, prev: head ?? OpLogChain.genesis)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }

        mutating func seal(by identity: DeviceIdentity) throws {
            let line = try OpLogChain.Seal.line(
                head: try XCTUnwrap(head), identity: identity,
                at: Date(timeIntervalSince1970: 9))
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
    }

    private func json(_ op: Op) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        return try encoder.encode(op)
    }

    /// One file classified as a load classifies it, with a recorder.
    private func classify(
        _ file: Chained, named slug: DeviceSlug, trust: TrustTable
    ) -> (applied: [String], signers: LineSigners) {
        let signers = LineSigners()
        let url = try! OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: slug, in: projectURL)
        let result = OpLogClassifier.classify(
            url: url, bytes: file.bytes, state: nil, trust: trust,
            permit: PermitContext(
                documentClass: { .piece("doc-signer") },
                unowned: { .aBookAuthorHasWrittenItsText },
                signers: signers))
        return (result.ops.map(\.opId), signers)
    }
}
