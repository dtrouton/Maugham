import Foundation
import XCTest
@testable import MaughamCore

/// **What the seal over a note says, and whose note it is** (shell p5 Task 1
/// and its fix round 1): each annotation creation a load applied is read as
/// `.sealed` (a seal this device stands behind names its writer), `.uncovered`
/// (no seal to judge by — every pre-signing book) or `.notOurs`; `NoteOwner`
/// turns that into the margin's one answer, reading the note's stamp only on
/// the uncovered arm. Never the op's `device` string or the file's name.
///
/// Two kinds of fixture, because the reading has two homes. A store writing
/// real chained, sealed files and loading them back covers the registerless
/// book (where the partition judges nothing and the reading is still made),
/// the legacy files old builds wrote, and the settled segment; a hand-chained
/// file classified against a resolved table covers a book with a register
/// (an admitted peer, an unrecorded key, retirement, revocation).
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
    /// writer of a line may set.
    private func note(
        _ opId: String, by device: String, stamp: String = "human", body: String = "a note"
    ) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 1),
           device: device, session: "s", kind: .claudeComment,
           changes: [], sequence: nil,
           provenance: .init(annotationBody: body, authorSourceKind: stamp))
    }

    private func note(_ opId: String, by identity: DeviceIdentity, stamp: String = "human") -> Op {
        note(opId, by: identity.deviceId, stamp: stamp)
    }

    private func store(_ who: LocalIdentities? = nil) -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: who ?? identities, state: state)
    }

    /// A fresh load's readings, as `Document.load` collects them.
    private func readings(_ store: OpLogStore) async throws -> LineSigners {
        let signers = LineSigners()
        _ = try await store.loadDiagnosed(docId: docId, lineSigners: signers)
        return signers
    }

    private let human = AnnotationAuthor(sourceKind: .human, displayName: "Denver")
    private let claude = AnnotationAuthor(sourceKind: .claude, displayName: "Claude")

    // MARK: - The four actors, read off the seal

    func test_aLineSealedByTheAuthorKeyIsTheAuthors() async throws {
        let store = store()
        try await store.append(note("01AUTHOR", by: identities.author))
        _ = try await store.sealChain(docId: docId)

        let read = try await readings(self.store())
        XCTAssertEqual(read.reading(ofOp: "01AUTHOR"), .sealed(.author, ofThisWriter: true))
    }

    /// The op's stamp says human; the key says assistant. The key wins.
    func test_aLineSealedByTheAssistantKeyIsTheAssistants() async throws {
        let store = store()
        try await store.append(note("01ASSIST", by: identities.assistant, stamp: "human"))
        _ = try await store.sealChain(docId: docId)

        let read = try await readings(self.store())
        XCTAssertEqual(read.reading(ofOp: "01ASSIST"), .sealed(.assistant, ofThisWriter: true))
        XCTAssertEqual(NoteOwner.of(read.reading(ofOp: "01ASSIST"), stampedBy: human),
                       .verified(.assistant, ofThisWriter: true),
                       "a stamp saying human under the assistant's seal answers assistant")
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

        let read = try await readings(self.store())
        for (id, _, actor) in writers {
            XCTAssertEqual(read.reading(ofOp: id), .sealed(actor, ofThisWriter: true), id)
        }
    }

    // MARK: - No covering seal: the stamp is all there is

    /// The span after the last seal is applied — the ordinary shape of a live
    /// file — and nothing has sealed it yet. The permit lends such a line the
    /// key before it, which is conservative for a permit and a guess for a
    /// person, so it is `.uncovered` and its owner is its (unverified) stamp.
    func test_anUnsealedTailHasNoSigner() async throws {
        let store = store()
        try await store.append(note("01SEALED", by: identities.author))
        _ = try await store.sealChain(docId: docId)
        try await store.append(note("01UNSEALED", by: identities.author))

        let read = try await readings(self.store())
        XCTAssertEqual(read.reading(ofOp: "01SEALED"), .sealed(.author, ofThisWriter: true))
        XCTAssertEqual(read.reading(ofOp: "01UNSEALED"), .uncovered,
                       "an applied line no seal covers has no signer")
        XCTAssertEqual(NoteOwner.of(read.reading(ofOp: "01UNSEALED"), stampedBy: human),
                       .stamped(.human))
    }

    func test_aNeverSealedFileHasNoSigner() async throws {
        let store = store()
        try await store.append(note("01NEVER", by: identities.author))

        let read = try await readings(self.store())
        XCTAssertEqual(read.reading(ofOp: "01NEVER"), .uncovered)
    }

    /// **The files old builds wrote** — the unsuffixed legacy file and a
    /// host-name-slug file: plain JSON lines, no `prev`, no seal. Every note
    /// in every book older than the signed op log is here, and the margin
    /// must not hide the writer's own: the stamp is the answer, unverified.
    func test_aLegacyFileNoteIsStampedNotHidden() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let ops = projectURL.appendingPathComponent(".maugham/ops")
        let files: [(String, Op)] = [
            ("\(docId).jsonl", note("01LEGACY", by: "denvers-macbook-pro", stamp: "human")),
            ("\(docId).denvers-macbook-pro.jsonl",
             note("01HOSTSLUG", by: "denvers-macbook-pro", stamp: "claude")),
        ]
        for (name, op) in files {
            var bytes = try encoder.encode(op)
            bytes.append(0x0A)
            try bytes.write(to: ops.appendingPathComponent(name))
        }

        let signers = LineSigners()
        let loaded = try await store().loadDiagnosed(docId: docId, lineSigners: signers)
        XCTAssertEqual(Set(loaded.ops.map(\.opId)), ["01LEGACY", "01HOSTSLUG"],
                       "the premise: old history is applied")
        XCTAssertEqual(signers.reading(ofOp: "01LEGACY"), .uncovered)
        XCTAssertEqual(signers.reading(ofOp: "01HOSTSLUG"), .uncovered)
        XCTAssertEqual(NoteOwner.of(signers.reading(ofOp: "01LEGACY"), stampedBy: human),
                       .stamped(.human))
        XCTAssertEqual(NoteOwner.of(signers.reading(ofOp: "01HOSTSLUG"), stampedBy: claude),
                       .stamped(.claude))
    }

    /// A registerless book: another device's sealed file is applied as
    /// unsigned history (`.noChain`) and its key vouches for nobody here —
    /// even though its file name says `author-…`. No seal this device can
    /// judge by covers it: `.uncovered`, so its stamp is its owner.
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
        XCTAssertEqual(loaded.reading(ofOp: "01THEIRS"), .uncovered)
    }

    // MARK: - A seal that is not ours: no owner

    /// Sam is admitted as a person, but no device record names his key's
    /// actor and his file's name does not carry his key — nothing says which
    /// of his writers this is. The seal over his line is `.notOurs`; and the
    /// partition, which cannot judge an unnamed actor, holds the line.
    func test_anUnrecordedKeyHasNoSigner() throws {
        let sam = LocalIdentities.softwareForTesting()
        let samKey = sam.author.fingerprint
        let table = book(sam: sam, samsDevice: nil)
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
            PermitPartition.sealReadings(
                of: walked, atLines: [0], trust: table, deviceSlug: slug.raw),
            [0: .notOurs])

        let read = classify(file, named: slug, trust: table)
        XCTAssertEqual(read.applied, [], "held: the partition cannot judge it")
        XCTAssertNil(read.signers.reading(ofOp: "01SAMS"))
    }

    /// A stranger's line is held: not applied, nothing recorded.
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
        XCTAssertNil(read.signers.reading(ofOp: "01HELD"))
        XCTAssertEqual(
            PermitPartition.sealReading(
                ofSealKey: sam.author.fingerprint, sealedAt: Date(timeIntervalSince1970: 9),
                trust: table, deviceSlug: sam.author.slug.raw),
            .notOurs)
    }

    /// **A revocation's kept notes are nobody's.** The root revoked Sam after
    /// this Mac had applied his note; the revocation keeps it in the book,
    /// and the seal over it is a key this device no longer stands behind.
    func test_aRevokedPersonsKeptNoteHasNoOwner() throws {
        let sam = LocalIdentities.softwareForTesting()
        let table = book(sam: sam, samsDevice: samsDevice(sam), revokedAt: Date(timeIntervalSince1970: 30),
                         highestOpIdSeen: "01SAMZ")
        var file = Chained()
        try file.append(json(note("01SAMA", by: sam.author)))
        try file.seal(by: sam.author)
        let read = classify(file, named: sam.author.slug, trust: table)

        XCTAssertEqual(read.applied, ["01SAMA"], "the premise: the revocation keeps it")
        XCTAssertEqual(read.signers.reading(ofOp: "01SAMA"), .notOurs)
        XCTAssertEqual(NoteOwner.of(read.signers.reading(ofOp: "01SAMA"), stampedBy: human),
                       .unknown, "a disowning seal outranks the stamp")
    }

    /// **A note sealed before its device retired keeps its signer** (fix
    /// round 1, ruling B): retirement is the writer tidying her own devices,
    /// and the walk already stands behind those seals. A seal made AFTER the
    /// retirement is not this device's word.
    func test_aRetiredDevicesEarlierNoteKeepsItsSigner() throws {
        let sam = LocalIdentities.softwareForTesting()
        let sealedAt = Date(timeIntervalSince1970: 9)

        let retiredLater = book(sam: sam, samsDevice: samsDevice(sam, retiredAt: Date(timeIntervalSince1970: 20)))
        XCTAssertEqual(retiredLater.verdict(forSealKey: sam.author.fingerprint),
                       .retired(device: sam.author.fingerprint, retiredAt: Date(timeIntervalSince1970: 20)),
                       "the premise: his device is retired")
        var file = Chained()
        try file.append(json(note("01BEFORE", by: sam.author)))
        try file.seal(by: sam.author, at: sealedAt)
        let read = classify(file, named: sam.author.slug, trust: retiredLater)
        XCTAssertEqual(read.applied, ["01BEFORE"])
        XCTAssertEqual(read.signers.reading(ofOp: "01BEFORE"), .sealed(.author, ofThisWriter: false))

        let retiredEarlier = book(sam: sam, samsDevice: samsDevice(sam, retiredAt: Date(timeIntervalSince1970: 5)))
        XCTAssertEqual(
            PermitPartition.sealReading(
                ofSealKey: sam.author.fingerprint, sealedAt: sealedAt,
                trust: retiredEarlier, deviceSlug: sam.author.slug.raw),
            .notOurs, "sealed after the retirement")
        XCTAssertNil(classify(file, named: sam.author.slug, trust: retiredEarlier)
            .signers.reading(ofOp: "01BEFORE"), "and the walk refuses the line")
    }

    // MARK: - Through the table

    /// An admitted peer's assistant, named by its device record: the
    /// partition judges this book, and the reading names it — not this
    /// writer's. His unsealed tail is applied and uncovered.
    func test_anAdmittedPeersAssistantIsTheAssistant() throws {
        let sam = LocalIdentities.softwareForTesting()
        let table = book(sam: sam, samsDevice: samsDevice(sam))

        var file = Chained()
        try file.append(json(note("01SAMAI", by: sam.assistant, stamp: "human")))
        try file.seal(by: sam.assistant)
        try file.append(json(note("01SAMLATE", by: sam.assistant)))
        let read = classify(file, named: sam.assistant.slug, trust: table)

        XCTAssertEqual(read.applied, ["01SAMAI", "01SAMLATE"])
        XCTAssertEqual(read.signers.reading(ofOp: "01SAMAI"), .sealed(.assistant, ofThisWriter: false))
        XCTAssertEqual(read.signers.reading(ofOp: "01SAMLATE"), .uncovered,
                       "his unsealed tail is applied and no seal says whose")
    }

    /// M-4's question answered from the table: an admitted reviewer's AUTHOR
    /// key is `.author` and not this writer's; this writer's other Mac,
    /// labelled as hers, is both.
    func test_anAuthorKeyIsThisWritersOnlyWhenTheTableSaysSo() throws {
        let sam = LocalIdentities.softwareForTesting()
        let samsOwnLabel = book(sam: sam, samsDevice: samsDevice(sam))
        XCTAssertEqual(
            PermitPartition.sealReading(
                ofSealKey: sam.author.fingerprint, sealedAt: Date(timeIntervalSince1970: 9),
                trust: samsOwnLabel, deviceSlug: sam.author.slug.raw),
            .sealed(.author, ofThisWriter: false))
        let herOtherMac = book(sam: sam, samsDevice: samsDevice(sam), samsLabel: "Denver")
        XCTAssertEqual(
            PermitPartition.sealReading(
                ofSealKey: sam.author.fingerprint, sealedAt: Date(timeIntervalSince1970: 9),
                trust: herOtherMac, deviceSlug: sam.author.slug.raw),
            .sealed(.author, ofThisWriter: true))
    }

    // MARK: - A settled segment

    /// A rotated segment is never walked: its signature settles it whole, and
    /// the key that made it is over every line in it — the first load (which
    /// reads the `.sig`) and the second (which settles from memory) alike.
    func test_aSettledSegmentNamesItsKeysActor() async throws {
        let store = store()
        let filler = String(repeating: "x", count: 2_000)
        for id in ["01SEG1", "01SEG2"] {
            try await store.append(note(id, by: identities.assistant.deviceId, body: filler))
        }
        _ = try await store.sealChain(docId: docId)
        let segment = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: identities.assistant.slug, threshold: 1_000)
        let segURL = try XCTUnwrap(segment, "the premise: the tail rotated")

        let first = try await readings(self.store())
        XCTAssertEqual(first.reading(ofOp: "01SEG1"), .sealed(.assistant, ofThisWriter: true))
        XCTAssertEqual(first.reading(ofOp: "01SEG2"), .sealed(.assistant, ofThisWriter: true))
        XCTAssertTrue(
            state.isVerified(segmentDigest: try XCTUnwrap(
                OpLogSegment.decodeVerifying(try Data(contentsOf: segURL)).digest)),
            "the premise: the second load settles from memory")

        // M-2: the second load reads no signature — the digest's verified
        // signer is remembered — so removing the `.sig` changes nothing now.
        try FileManager.default.removeItem(at: OpLogStore.segmentSignatureURL(for: segURL))
        let second = try await readings(self.store())
        XCTAssertEqual(second.reading(ofOp: "01SEG1"), .sealed(.assistant, ofThisWriter: true))
    }

    /// **A settled segment the partition narrows records nothing for the
    /// lines it holds** (fix round 1, M-3). Sam's rotated segment, signed by
    /// his key, under a file name that does not carry it: with no device
    /// record the partition cannot name his writer and holds the line; with
    /// one, the line applies and the signature names him.
    func test_aSettledSegmentsHeldLineRecordsNoReading() throws {
        let sam = LocalIdentities.softwareForTesting()
        var file = Chained()
        try file.append(json(note("01SEGSAM", by: sam.author)))
        try file.seal(by: sam.author)
        let segURL = try OpLogStore.segmentFileURL(
            forDocId: docId, deviceSlug: DeviceSlug.make(from: "sams-mac"), index: 1, in: projectURL)
        try OpLogSegment.encode(jsonl: file.bytes).write(to: segURL)
        try SegmentSealer.writeSegmentSignature(for: segURL, jsonl: file.bytes, identity: sam.author)
        let container = try Data(contentsOf: segURL)

        func read(_ table: TrustTable) -> (applied: [String], reading: SealReading?) {
            let signers = LineSigners()
            let result = OpLogClassifier.classify(
                url: segURL, bytes: container, state: nil, trust: table,
                permit: PermitContext(
                    documentClass: { .piece("doc-signer") },
                    unowned: { .aBookAuthorHasWrittenItsText },
                    signers: signers))
            return (result.ops.map(\.opId), signers.reading(ofOp: "01SEGSAM"))
        }

        let held = read(book(sam: sam, samsDevice: nil))
        XCTAssertEqual(held.applied, [], "the premise: the partition holds it")
        XCTAssertNil(held.reading)

        let applied = read(book(sam: sam, samsDevice: samsDevice(sam)))
        XCTAssertEqual(applied.applied, ["01SEGSAM"])
        XCTAssertEqual(applied.reading, .sealed(.author, ofThisWriter: false))
    }

    /// A segment with NO signature anywhere — settled from memory in a book
    /// that judges nothing, its `.sig` gone before this process read it — is
    /// uncovered: there is no seal to believe and none to disbelieve.
    func test_aSettledSegmentWithNoSignatureIsUncovered() throws {
        let table = TrustResolution.keyless(mine: identities)
        let lines = [Data("{}".utf8)].map { OpLogChain.Line(bytes: $0, kind: .op, state: .verified) }
        let verification = OpLogChain.Verification(
            lines: lines, head: nil, legacyCount: 0, verifiedCount: 1,
            unsealedCount: 0, foreignSealCount: 0, quarantined: [], breakReason: nil)
        XCTAssertEqual(
            PermitPartition.sealReadings(
                of: verification, atLines: [0], trust: table, deviceSlug: nil,
                settledBy: (identities.translator.fingerprint, Date(timeIntervalSince1970: 9))),
            [0: .sealed(.translator, ofThisWriter: true)])
        XCTAssertEqual(
            PermitPartition.sealReadings(
                of: verification, atLines: [0], trust: table, deviceSlug: nil),
            [0: .uncovered], "no seal line and no settling signature")
    }

    // MARK: - Many notes, no seal (M-1)

    /// A legacy-sized unsealed file with many notes is read in one pass: every
    /// wanted line answers, and the answer is the same as for one.
    func test_aLargeUnsealedFileReadsEveryNoteInOnePass() throws {
        let table = TrustResolution.keyless(mine: identities)
        let lines = (0..<100_000).map { _ in
            OpLogChain.Line(bytes: Data("{}".utf8), kind: .op, state: .legacy)
        }
        let verification = OpLogChain.Verification(
            lines: lines, head: nil, legacyCount: lines.count, verifiedCount: 0,
            unsealedCount: 0, foreignSealCount: 0, quarantined: [], breakReason: nil)
        let wanted = Array(stride(from: 0, to: 100_000, by: 10))
        let started = Date()
        let read = PermitPartition.sealReadings(
            of: verification, atLines: wanted, trust: table, deviceSlug: nil)
        XCTAssertEqual(read.count, wanted.count)
        XCTAssertTrue(read.values.allSatisfy { $0 == .uncovered })
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "one backward pass, not a forward scan per note")
    }

    // MARK: - The recorder

    /// Two copies of one op read as one answer whatever order the files were
    /// listed in: a seal outranks no seal, a disowning seal outranks an owning
    /// one, and two seals naming different writers name nobody.
    func test_twoCopiesReadAsOneAnswerInEitherOrder() {
        let cases: [([SealReading], SealReading)] = [
            ([.uncovered, .sealed(.author, ofThisWriter: true)], .sealed(.author, ofThisWriter: true)),
            ([.sealed(.author, ofThisWriter: true), .sealed(.assistant, ofThisWriter: true)], .notOurs),
            ([.sealed(.author, ofThisWriter: true), .notOurs], .notOurs),
            ([.sealed(.author, ofThisWriter: true), .sealed(.author, ofThisWriter: true)],
             .sealed(.author, ofThisWriter: true)),
        ]
        for (pair, expected) in cases {
            for order in [pair, pair.reversed()] {
                let signers = LineSigners()
                for reading in order { signers.record("01DUP", reading) }
                XCTAssertEqual(signers.reading(ofOp: "01DUP"), expected, "\(order)")
            }
        }
    }

    /// `NoteOwner.of`'s three arms.
    func test_theOwnerHasThreeHonestAnswers() {
        XCTAssertEqual(NoteOwner.of(.sealed(.author, ofThisWriter: true), stampedBy: claude),
                       .verified(.author, ofThisWriter: true), "a seal always wins")
        XCTAssertEqual(NoteOwner.of(.uncovered, stampedBy: human), .stamped(.human))
        XCTAssertEqual(NoteOwner.of(.uncovered, stampedBy: nil), .unknown,
                       "no seal and no stamp: nothing is known")
        XCTAssertEqual(NoteOwner.of(.notOurs, stampedBy: human), .unknown)
        XCTAssertEqual(NoteOwner.of(nil, stampedBy: human), .unknown,
                       "a note the load never read is nobody's")
    }

    /// **A person's note** (shell p5 Task 2): any person's author key, or a
    /// human stamp where no seal covers the line — and nothing else.
    func test_aPersonIsTheAuthorKeyOrAnUncoveredHumanStamp() {
        XCTAssertTrue(NoteOwner.verified(.author, ofThisWriter: true).isAPersons)
        XCTAssertTrue(NoteOwner.verified(.author, ofThisWriter: false).isAPersons,
                      "an admitted reviewer's author key is a person's")
        for machine in [DeviceActor.assistant, .translator, .maugham] {
            XCTAssertFalse(NoteOwner.verified(machine, ofThisWriter: true).isAPersons, "\(machine)")
        }
        XCTAssertTrue(NoteOwner.of(.uncovered, stampedBy: human).isAPersons,
                      "the writer's unsigned history is not hidden")
        XCTAssertFalse(NoteOwner.of(.uncovered, stampedBy: claude).isAPersons)
        XCTAssertFalse(NoteOwner.of(.sealed(.assistant, ofThisWriter: true), stampedBy: human).isAPersons,
                       "a human stamp under the assistant's seal is the assistant's")
        XCTAssertFalse(NoteOwner.unknown.isAPersons)
    }

    // MARK: - The census (M-5)

    /// A note's seal is read only through the named functions: the readings
    /// are asked and recorded by `OpLogClassifier` alone, and `NoteOwner.of`
    /// is asked by the Mac's `Document` alone.
    func test_aNotesSealIsReadOnlyThroughTheNamedFunctions() throws {
        let offenders = try Self.productionFiles().flatMap { path, code in
            Self.offences(in: code, path: path)
        }
        XCTAssertEqual(offenders, [])

        let planted = "let r = PermitPartition.sealReading(ofSealKey: k, sealedAt: d, trust: t, deviceSlug: nil)"
        XCTAssertFalse(Self.offences(in: planted, path: "Maugham/Views/Margin.swift").isEmpty,
                       "the planted offender is caught")
        XCTAssertTrue(Self.offences(in: planted, path: "Packages/MaughamCore/Sources/MaughamCore/OpLogClassifier.swift").isEmpty,
                      "the control: the classifier may ask")
    }

    /// Each token, and the one file (besides its definition) allowed it.
    private static let namedReaders: [(token: String, home: String, allowed: String)] = [
        ("PermitPartition.sealReading", "PermitPartition.swift", "OpLogClassifier.swift"),
        ("signers.record(", "OpLogPermitContext.swift", "OpLogClassifier.swift"),
        ("NoteOwner.of(", "OpLogPermitContext.swift", "Maugham/OpLog/Document.swift"),
    ]

    private static func offences(in code: String, path: String) -> [String] {
        namedReaders.compactMap { reader in
            guard code.contains(reader.token),
                  !path.hasSuffix(reader.home), !path.hasSuffix(reader.allowed)
            else { return nil }
            return "\(path): \(reader.token)"
        }
    }

    /// Every production Swift file, with `//` comment lines dropped.
    private static func productionFiles() throws -> [(String, String)] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var out: [(String, String)] = []
        for root in ["Packages/MaughamCore/Sources", "Maugham", "MaughamPhone"] {
            let dir = repo.appendingPathComponent(root)
            guard let walk = FileManager.default.enumerator(atPath: dir.path) else { continue }
            while let next = walk.nextObject() as? String {
                guard next.hasSuffix(".swift") else { continue }
                let text = try String(contentsOf: dir.appendingPathComponent(next), encoding: .utf8)
                let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                out.append(("\(root)/\(next)", code))
            }
        }
        XCTAssertGreaterThan(out.count, 100, "the census reads the real tree")
        return out
    }

    // MARK: - Hand-chained files and books

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

    private func samsDevice(_ sam: LocalIdentities, retiredAt: Date? = nil) -> DeviceRecord {
        DeviceRecord(
            device: sam.author.fingerprint, name: "Sam’s Mac", kind: .mac,
            actors: [
                DeviceActor.author.rawValue: sam.author.fingerprint,
                DeviceActor.assistant.rawValue: sam.assistant.fingerprint,
            ],
            madeAt: Date(timeIntervalSince1970: 5), retiredAt: retiredAt)
    }

    /// This Mac is the root; Sam is admitted under `samsLabel`.
    private func book(
        sam: LocalIdentities, samsDevice: DeviceRecord?, samsLabel: String = "Sam",
        revokedAt: Date? = nil, highestOpIdSeen: String? = nil
    ) -> TrustTable {
        TrustTable.resolve(
            registry: Registry(
                devices: [rootRecord()] + (samsDevice.map { [$0] } ?? []),
                people: [
                    rootPerson(),
                    PersonRecord(
                        person: sam.author.fingerprint, label: samsLabel, ownName: "Sam’s Mac",
                        admittedAt: Date(timeIntervalSince1970: 3), admittedBy: root,
                        revokedAt: revokedAt, revokedBy: revokedAt.map { _ in root },
                        highestOpIdSeen: highestOpIdSeen),
                ]),
            mine: identities, joinedRoot: nil)
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

        mutating func seal(by identity: DeviceIdentity, at: Date = Date(timeIntervalSince1970: 9)) throws {
            let line = try OpLogChain.Seal.line(
                head: try XCTUnwrap(head), identity: identity, at: at)
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
