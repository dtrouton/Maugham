import Foundation
import XCTest
@testable import MaughamCore

/// **The unsigned door closes** (P3b Task 2; Denver's ruling of 2026-09-20,
/// option B).
///
/// A file this register can name no key for is applied UNJUDGED — P1's design,
/// and a first-class state (a Mac with no Secure Enclave, a VM, CI's runner).
/// In a book where everybody may write everything nothing turns on it; the
/// moment somebody may NOT, it is the ladder's one open door. Closing it by
/// refusing would withdraw a whole unsigned Mac's history the day the root
/// first makes anybody a reviewer, so the first narrowing takes a PHOTOGRAPH
/// instead.
///
/// Every rule here is asserted in both directions: at or before the
/// photograph everything is exactly as P1 left it (the words stay, and the
/// amendments stay honoured); after it an unattributable line is HELD — never
/// set aside, never refused, no `.lines` record, because nothing is wrong with
/// it.
@MainActor
final class UnsignedDoorTests: XCTestCase {

    private let docId = "doc-unsigned"
    private var projectURL: URL!

    /// This Mac: the root, and the one judging.
    private var root: LocalIdentities!
    private var rootState: OpLogDeviceState!
    /// Sam's Mac: admitted, and the person every narrowing here is about.
    private var sam: LocalIdentities!
    /// A Mac with no enclave: it writes chained lines, seals nothing, and
    /// files no registry record — so nothing here can ever name its key.
    private var ghost: LocalIdentities!
    private var ghostState: OpLogDeviceState!
    private var cache: RegistryCache!
    private var memory: AdmissionMemory!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsigned-door-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        root = .softwareForTesting()
        sam = .softwareForTesting()
        ghost = .softwareForTesting()
        rootState = state("root")
        ghostState = state("ghost")
        cache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: root.author.fingerprint)
        memory = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: root.author.fingerprint)
    }

    override func tearDown() async throws {
        PermitPartition.walkObserverForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func state(_ name: String) -> OpLogDeviceState {
        OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state-\(name).json"))
    }

    // MARK: - Fixtures

    private var rootPerson: String { root.author.fingerprint }
    private var samPerson: String { sam.author.fingerprint }

    private func reader() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: root,
                   state: rootState, cache: cache)
    }

    private func op(
        _ opId: String, by identity: DeviceIdentity, kind: OpKind = .typingBurst
    ) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: identity.deviceId, session: "s", kind: kind,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: opId)],
           sequence: ["aaaa"])
    }

    private func writeRootRecord() throws {
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
    }

    /// Sam, admitted as an author of the whole book — which narrows nothing.
    private func admitSam() throws {
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

    /// **The first narrowing**, through the production door: the real sweep,
    /// the real event, and the real refusal if the folder will not read.
    private func narrowSamToReviewer() async throws {
        let snapshot = try OpLogStore.unattributablePositions(
            in: projectURL, trust: try await reader().trust())
        try RegistryAdmission.changePermit(
            person: samPerson,
            role: Permit.reviewerRole, scope: Permit.bookScope, pieces: [],
            mark: .nothingApplied, unsigned: snapshot,
            in: projectURL, by: root.author, cache: cache,
            now: { Date(timeIntervalSince1970: 60) })
    }

    private func encoded(_ ops: [Op]) throws -> [Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        return try ops.map { try encoder.encode($0) }
    }

    private func chained(_ elements: [Data], from start: String? = nil) -> Data {
        var bytes = Data()
        var head = start
        for element in elements {
            let line = OpLogChain.chainedLine(
                elementJSON: element, prev: head ?? OpLogChain.genesis)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        return bytes
    }

    /// The ghost's own stream: chained, and nothing seals it. Deterministic —
    /// writing `[o1, o2]` produces byte-for-byte the file `[o1]` was, plus a
    /// line, which is how these tests make a stream GROW.
    @discardableResult
    private func ghostFile(_ ops: [Op]) throws -> URL {
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: ghost.author.slug, in: projectURL)
        try chained(try encoded(ops)).write(to: url, options: .atomic)
        return url
    }

    /// A file sealed by a key no device record names — `.stranger(device: nil)`
    /// — with a LEGACY line in front of the chain, which is the one shape that
    /// leaves an applied line in such a file.
    @discardableResult
    private func strangerSealedFileWithALegacyPrefix(
        by identity: DeviceIdentity, legacy: Op, chainedOp: Op
    ) throws -> URL {
        var bytes = Data()
        let elements = try encoded([legacy, chainedOp])
        bytes.append(elements[0])
        bytes.append(0x0A)
        let head = OpLogChain.lineHash(elements[0])
        bytes.append(chained([elements[1]], from: head))
        let last = OpLogChain.lineHash(
            OpLogChain.chainedLine(elementJSON: elements[1], prev: head))
        let seal = try OpLogChain.Seal.line(
            head: last, identity: identity, at: Date(timeIntervalSince1970: 50))
        bytes.append(seal)
        bytes.append(0x0A)
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// The legacy unsuffixed `<docId>.jsonl` — no slug, no chain, no seal.
    @discardableResult
    private func legacyFile(_ ops: [Op]) throws -> URL {
        var bytes = Data()
        for element in try encoded(ops) {
            bytes.append(element)
            bytes.append(0x0A)
        }
        let url = projectURL
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent("\(docId).jsonl")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Rotate the ghost's tail into a sealed-shaped `.mzseg` the way
    /// `sealTailIfNeeded` does for a device that cannot sign: the container is
    /// written, the tail is deleted, and NO `.sig` is written beside it.
    private func rotateGhostTail(index: Int = 1) throws {
        let tail = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: ghost.author.slug, in: projectURL)
        let jsonl = try Data(contentsOf: tail)
        let segment = OpLogStore.segmentFileURL(
            forDocId: docId, deviceSlug: ghost.author.slug,
            index: index, in: projectURL)
        try OpLogSegment.encode(jsonl: jsonl).write(to: segment, options: .atomic)
        try FileManager.default.removeItem(at: tail)
    }

    private func writeGhostSegment(_ bytes: Data, index: Int = 1) throws -> URL {
        let url = OpLogStore.segmentFileURL(
            forDocId: docId, deviceSlug: ghost.author.slug,
            index: index, in: projectURL)
        try OpLogSegment.encode(jsonl: bytes).write(to: url, options: .atomic)
        return url
    }

    // MARK: - Reading a load

    private func appliedOpIds() async throws -> [String] {
        let coordinated = try await reader().loadDiagnosed(docId: docId)
        let sync = try OpLogStore.loadSyncMerged(
            forDocId: docId, in: projectURL, identities: root,
            state: rootState, trust: try await reader().trust())
        XCTAssertEqual(
            sync.map(\.opId), coordinated.ops.map(\.opId),
            "both readers see the same document")
        return coordinated.ops.map(\.opId)
    }

    private func assertApplied(
        _ expected: [String], _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let actual = try await appliedOpIds()
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    private func loadedProvenance() async throws -> OpLogProvenance {
        try await reader().loadDiagnosed(docId: docId).provenance
    }

    private func linesRecords() -> [QuarantineRecord] {
        OpLogQuarantine.records(forDocId: docId, in: projectURL)
            .filter { $0.kind == .lines }
    }

    private var ghostHolder: String {
        HeldLines.unsignedHolder(
            forStreamKey: "\(docId).\(ghost.author.slug.raw)",
            deviceSlug: ghost.author.slug.raw)
    }

    // MARK: - Neutrality: an un-narrowed book is P1

    /// **Nothing narrows this book, so nothing is held.** The ghost's whole
    /// history applies exactly as decision B3 applies it, and the door does
    /// not so much as examine the file.
    func test_anUnNarrowedBookAppliesEveryUnsignedLine() async throws {
        try writeRootRecord()
        try admitSam()
        try ghostFile([op("01", by: ghost.author), op("02", by: ghost.author)])

        let un = try await reader().trust()
        XCTAssertNil(un.unsignedSnapshot)
        try await assertApplied(["01", "02"])
        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingLines, 0)
        XCTAssertEqual(provenance.quarantinedLines, 0)
        XCTAssertTrue(linesRecords().isEmpty)
    }

    /// And a book with no REGISTER at all is untouched too — the door asks
    /// `judgesAnything` first, exactly as the permit partition does.
    func test_aRegisterlessBookHoldsNothing() async throws {
        try ghostFile([op("01", by: ghost.author)])
        let none = try await reader().trust()
        XCTAssertNil(none.myRoot)
        try await assertApplied(["01"])
        let quiet = try await loadedProvenance()
        XCTAssertEqual(quiet.pendingLines, 0)
    }

    // MARK: - The two sides of the photograph

    /// **Inside: exactly what P1 applied. After: held.** The one test the
    /// whole ruling is about.
    func test_whatWasThereStaysAndWhatComesAfterIsHeld() async throws {
        try writeRootRecord()
        try admitSam()
        try ghostFile([op("01", by: ghost.author)])

        try await narrowSamToReviewer()
        let narrowed = try await reader().trust()
        XCTAssertNotNil(narrowed.unsignedSnapshot)

        try await assertApplied(["01"], "narrowing does not reach back through a word of it")

        // The same Mac goes on writing.
        try ghostFile([op("01", by: ghost.author), op("02", by: ghost.author)])

        try await assertApplied(["01"], "and no further")
        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingOpLines, 1)
        XCTAssertEqual(
            provenance.pendingByDevice[ghostHolder], 1,
            "held under a holder that is not, and cannot be, a key")
        XCTAssertEqual(
            provenance.quarantinedLines, 0,
            "held, never refused — nothing is wrong with these bytes")
        XCTAssertTrue(
            linesRecords().isEmpty,
            "and nothing is set aside, so there is no record to write")
    }

    /// **An unsigned holder is never an admission request.** There is no key
    /// to admit: offering the sheet would offer a control that cannot work.
    func test_anUnsignedHolderIsNeverWordedAsWaitingForAdmission() async throws {
        try writeRootRecord()
        try admitSam()
        try ghostFile([op("01", by: ghost.author)])
        try await narrowSamToReviewer()
        try ghostFile([op("01", by: ghost.author), op("02", by: ghost.author)])

        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingOpLines, 1)
        XCTAssertTrue(
            provenance.pendingStrangersByDevice.isEmpty,
            "nobody here is waiting to be let in")
        XCTAssertFalse(provenance.hasPendingAdmission)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertFalse(registry.isStrangerDevice(ghostHolder))
        XCTAssertTrue(
            registry.strangersAwaitingAdmission(among: [ghostHolder: 1]).isEmpty)
        let judged = try await reader().trust()
        XCTAssertFalse(judged.isStrangerDevice(ghostHolder))
    }

    /// **A stream the photograph does not NAME is wholly new**, which is how a
    /// file minted after the narrowing is caught — including one wearing the
    /// legacy unsuffixed name, which is the one shape no slug can be checked
    /// against.
    func test_aLegacyShapedFileMintedAfterTheSnapshotIsWhollyHeld() async throws {
        try writeRootRecord()
        try admitSam()
        try ghostFile([op("01", by: ghost.author)])
        try await narrowSamToReviewer()

        try legacyFile([op("90", by: ghost.author), op("91", by: ghost.author)])

        try await assertApplied(["01"])
        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingOpLines, 2)
        XCTAssertEqual(
            provenance.pendingByDevice[
                HeldLines.unsignedHolder(forStreamKey: docId, deviceSlug: nil)],
            2,
            "a file with no slug is held under its stream")
    }

    /// Its converse: a legacy file that was THERE when the photograph was
    /// taken keeps every line of it.
    func test_aLegacyFileInsideTheSnapshotIsUntouched() async throws {
        try writeRootRecord()
        try admitSam()
        try legacyFile([op("90", by: ghost.author), op("91", by: ghost.author)])
        try await narrowSamToReviewer()

        try await assertApplied(["90", "91"])
        let untouched = try await loadedProvenance()
        XCTAssertEqual(untouched.pendingLines, 0)
    }

    // MARK: - Rotation, and the segments

    /// **A snapshot-listed position survives the rotation that moves it.**
    ///
    /// An unsigned device cannot sign a segment, so its `.mzseg` never settles
    /// and is walked — which is how it reaches the photograph at all. The
    /// marked line moves from the tail into the segment, and the rule that
    /// finds it is `PermitMark.judge`'s second, which reads a LINE HASH and
    /// never a filename.
    func test_aRotationAfterTheSnapshotStillJudgesTheOldLinesOld() async throws {
        try writeRootRecord()
        try admitSam()
        try ghostFile([op("01", by: ghost.author), op("02", by: ghost.author)])
        try await narrowSamToReviewer()

        try rotateGhostTail()
        try await assertApplied(["01", "02"], "the same two lines, one filename later")

        // And the new tail the rotation left room for is after the photograph.
        try ghostFile([op("03", by: ghost.author)])
        try await assertApplied(["01", "02"])
        let after = try await loadedProvenance()
        XCTAssertEqual(after.pendingOpLines, 1)
    }

    /// **A segment whose walk broke contributes no digest and judges NEW.**
    /// The strictness is `seenPositions`' own — a mark can say *this whole
    /// segment* or *up to this line*, and such a segment is neither.
    func test_aSegmentWhoseWalkBrokeIsHeldAfterTheSnapshot() async throws {
        try writeRootRecord()
        try admitSam()
        try ghostFile([op("01", by: ghost.author)])
        // A segment that chains for one line and then does not.
        let elements = try encoded([op("80", by: ghost.author),
                                    op("81", by: ghost.author)])
        var broken = chained([elements[0]])
        broken.append(elements[1])
        broken.append(0x0A)
        _ = try writeGhostSegment(broken)

        let table = try await reader().trust()
        let swept = try OpLogStore.unattributablePositions(
            in: projectURL, trust: table)
        let snapshot = try XCTUnwrap(
            swept.streams["\(docId).\(ghost.author.slug.raw)"])
        XCTAssertTrue(
            snapshot.segments.isEmpty,
            "a walk that broke inside names no digest")

        try await narrowSamToReviewer()

        try await assertApplied(["01"], "the tail is inside the photograph; the broken segment is not")
        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingByDevice[ghostHolder], 1,
                       "its one applied line is held")
        XCTAssertGreaterThan(provenance.quarantinedLines, 0,
                             "and the broken half stays refused for the break")
    }

    /// **A snapshot-listed segment that was REWRITTEN is wholly held.** The
    /// digest is the container's own commitment to its bytes, so rewriting it
    /// changes the digest and the listing stops naming it.
    func test_aRewrittenSegmentStopsBeingInsideThePhotograph() async throws {
        try writeRootRecord()
        try admitSam()
        try ghostFile([op("01", by: ghost.author), op("02", by: ghost.author)])
        try rotateGhostTail()
        try ghostFile([op("03", by: ghost.author)])
        try await narrowSamToReviewer()

        try await assertApplied(["01", "02", "03"])

        _ = try writeGhostSegment(chained(try encoded([
            op("01", by: ghost.author),
            op("02", by: ghost.author),
            op("99", by: ghost.author),
        ])))

        try await assertApplied(["03"], "a rewritten segment is a segment this photograph never saw")
        let held = try await loadedProvenance()
        XCTAssertEqual(held.pendingByDevice[ghostHolder], 3)
    }

    // MARK: - This device's own file

    /// **An enclave-less Mac applies its own lines on its own screen.**
    ///
    /// Typing must never wait on anything. It is structural rather than
    /// guarded: `TrustTable.resolve` puts this device's own actor ids into
    /// `keyByDeviceId` whatever the registry says, so its own file is never
    /// unattributable TO ITSELF — while the root's Mac, reading the same
    /// bytes, holds what it wrote after the photograph.
    func test_aMacWithNoKeyStillAppliesItsOwnWritingOnItsOwnScreen() async throws {
        try writeRootRecord()
        try admitSam()
        try ghostFile([op("01", by: ghost.author)])
        try await narrowSamToReviewer()
        try ghostFile([op("01", by: ghost.author), op("02", by: ghost.author)])

        // The root holds the second line…
        try await assertApplied(["01"])

        // …and the ghost's own Mac does not.
        let itsOwn = try OpLogStore.loadSyncMerged(
            forDocId: docId, in: projectURL, identities: ghost,
            state: ghostState,
            trust: try TrustResolution.resolve(
                projectURL: projectURL, identities: ghost,
                cache: RegistryCache(
                    fileURL: projectURL.appendingPathComponent("ghost-cache.json"),
                    identity: ghost.author.fingerprint)))
        XCTAssertEqual(itsOwn.map(\.opId), ["01", "02"])
    }

    /// **A fresh Mac and the root reach the same answer from the same bytes.**
    /// The photograph is a signed shared event and the judgement is over the
    /// file's own lines, so a machine that remembers nothing agrees.
    func test_aFreshMacAgreesWithTheRootFromTheSameBytes() async throws {
        try writeRootRecord()
        try admitSam()
        try ghostFile([op("01", by: ghost.author)])
        try await narrowSamToReviewer()
        try ghostFile([op("01", by: ghost.author), op("02", by: ghost.author)])

        let fresh = try OpLogStore.loadSyncMerged(
            forDocId: docId, in: projectURL, identities: sam,
            state: state("fresh"),
            trust: try TrustResolution.resolve(
                projectURL: projectURL, identities: sam,
                cache: RegistryCache(
                    fileURL: projectURL.appendingPathComponent("sam-cache.json"),
                    identity: sam.author.fingerprint)))
        let mine = try await appliedOpIds()
        XCTAssertEqual(fresh.map(\.opId), mine)
    }

    // MARK: - A stranger's file is still a stranger's (Task 1's review, minor 1)

    /// **A stranger-sealed file whose device record has not arrived stays held
    /// AS A STRANGER, on both sides of the photograph.**
    ///
    /// It is `unattributable` too — `.stranger(device: nil)` is one of the two
    /// verdicts meaning *the register has nothing to say about this key* — but
    /// it is somebody's file, and that somebody can be ADMITTED, which applies
    /// what they wrote. Filing it under an unsigned holder would put an
    /// admittable person behind a door no admission can open.
    func test_aStrangerSealedFileKeepsItsStrangerOnBothSides() async throws {
        try writeRootRecord()
        try admitSam()
        let kim = LocalIdentities.softwareForTesting()
        try strangerSealedFileWithALegacyPrefix(
            by: kim.author,
            legacy: op("70", by: kim.author), chainedOp: op("71", by: kim.author))

        // Before: the legacy prefix applies, the sealed span is held as Kim's.
        try await assertApplied(["70"])
        let before = try await loadedProvenance()
        XCTAssertEqual(before.pendingByDevice[kim.author.fingerprint], 1)
        XCTAssertTrue(
            before.pendingByDevice.keys.allSatisfy {
                !HeldLines.isUnsignedHolder($0)
            })

        try await narrowSamToReviewer()

        // After: the same file, and the same holder — a fingerprint the writer
        // can be asked to admit, never an unsigned stream.
        let after = try await loadedProvenance()
        XCTAssertTrue(
            after.pendingByDevice.keys.allSatisfy {
                !HeldLines.isUnsignedHolder($0)
            },
            "a stranger's file never becomes an unsigned one")
        XCTAssertEqual(
            after.pendingStrangersByDevice[kim.author.fingerprint], 1,
            "and is still admittable")
        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(
            HeldLines.holder(of: kim.author.fingerprint, registry: registry),
            .stranger(fingerprint: kim.author.fingerprint))
    }

    /// Its sharper half: a line the photograph judges NEW in such a file is
    /// held under KIM, not under a stream — so admitting her brings it in.
    func test_aStrangersLineAfterTheSnapshotIsStillHeldUnderHerKey() async throws {
        try writeRootRecord()
        try admitSam()
        let kim = LocalIdentities.softwareForTesting()
        try ghostFile([op("01", by: ghost.author)])
        try await narrowSamToReviewer()

        try strangerSealedFileWithALegacyPrefix(
            by: kim.author,
            legacy: op("70", by: kim.author), chainedOp: op("71", by: kim.author))

        let after = try await loadedProvenance()
        XCTAssertEqual(
            after.pendingByDevice[kim.author.fingerprint], 2,
            "both her lines are hers — the legacy prefix the photograph now "
            + "judges new, and the span her own seal already held")
        XCTAssertNil(after.pendingByDevice[ghostHolder])
    }

    // MARK: - The amendments (ruling 1's other direction)

    /// **An unsigned Mac's withdrawal survives the book being narrowed.**
    ///
    /// P3a's `unplaced` refused every production-shaped id it could not place
    /// the moment anybody was narrowed, which reached BACK: deleted notes came
    /// back and edits reverted on every signed Mac, silently. The photograph
    /// decides instead, and the side travels by op id through the carrier the
    /// governing permit already travels by.
    func test_anUnsignedMacsWithdrawalInsideThePhotographIsStillHonoured() async throws {
        try writeRootRecord()
        try admitSam()
        try ghostFile([
            op("01", by: ghost.author),
            op("02", by: ghost.author, kind: .annotationWithdraw),
        ])
        try await narrowSamToReviewer()

        let carrier = AmendmentPermits()
        _ = try await reader().loadDiagnosed(
            docId: docId, amendmentPermits: carrier)
        XCTAssertTrue(
            carrier.resolvedInsideTheUnsignedSnapshot.contains("02"),
            "the door recorded which side the amending line fell on")

        let trust = try await reader().trust()
        XCTAssertTrue(trust.hasNarrowingPermits)
        XCTAssertTrue(
            AnnotationOwnership.unplaced(
                ghost.author.deviceId, trust: trust,
                insideTheUnsignedSnapshot: true),
            "inside the photograph, P1's answer stands")
        XCTAssertFalse(
            AnnotationOwnership.unplaced(
                ghost.author.deviceId, trust: trust,
                insideTheUnsignedSnapshot: false),
            "and after it, an id nobody can place is not waved through")
    }

    /// Its neutrality half, unchanged from P3a: in a book nobody is narrowed
    /// in, the same id is honoured whichever side it claims to be on.
    func test_anUnNarrowedBookHonoursTheSameIdEitherWay() async throws {
        try writeRootRecord()
        try admitSam()
        let trust = try await reader().trust()
        XCTAssertFalse(trust.hasNarrowingPermits)
        for inside in [true, false] {
            XCTAssertTrue(AnnotationOwnership.unplaced(
                ghost.author.deviceId, trust: trust,
                insideTheUnsignedSnapshot: inside))
        }
    }

    // MARK: - HeldLines

    /// The three holders, from one classifier, over one registry.
    func test_theThreeHoldersAreToldApartByOneClassifier() throws {
        try writeRootRecord()
        try admitSam()
        let registry = try RegistryReader.load(projectURL: projectURL)
        let stranger = LocalIdentities.softwareForTesting().author.fingerprint

        XCTAssertEqual(
            HeldLines.holder(of: stranger, registry: registry),
            .stranger(fingerprint: stranger))
        XCTAssertEqual(
            HeldLines.holder(of: samPerson, registry: registry),
            .permitPending(person: samPerson))
        XCTAssertEqual(
            HeldLines.holder(of: ghostHolder, registry: registry),
            .unsigned(stream: ghost.author.slug.raw))
    }

    /// The holder string is one no key could be, which is what makes the
    /// classification total rather than a guess.
    func test_anUnsignedHolderCannotBeMistakenForADeviceIdOrAKey() {
        let holder = HeldLines.unsignedHolder(
            forStreamKey: "doc-x.author-abcdef0123456789",
            deviceSlug: "author-abcdef0123456789")
        XCTAssertFalse(DeviceIdentity.looksLikeADeviceId(holder))
        XCTAssertNil(DeviceIdentity.claimedActor(ofDeviceId: holder))
        XCTAssertTrue(HeldLines.isUnsignedHolder(holder))
        XCTAssertEqual(
            HeldLines.streamOfUnsignedHolder(holder), "author-abcdef0123456789")
        XCTAssertNil(HeldLines.streamOfUnsignedHolder("author-abcdef0123456789"))
    }

    /// Three sentences, and none of them is the others'. The unsigned one is
    /// the one that must never say *waiting for admission*.
    func test_eachHolderHasASentenceOfItsOwn() {
        let stranger = HeldLines.sentence(
            .stranger(fingerprint: "ff"), notes: 2, named: "Sam’s Mac")
        XCTAssertEqual(
            stranger, "2 notes from Sam’s Mac are waiting for admission.")

        let pending = try? XCTUnwrap(
            HeldLines.sentence(.permitPending(person: "ff"), notes: 1, named: "Sam"))
        XCTAssertEqual(pending?.hasPrefix("1 note from Sam is waiting."), true)
        XCTAssertEqual(pending?.contains("admission"), false)

        let unsigned = try? XCTUnwrap(
            HeldLines.sentence(.unsigned(stream: "author-aaaa"), notes: 3))
        XCTAssertEqual(unsigned?.contains("admission"), false)
        XCTAssertEqual(unsigned?.contains("signs nothing"), true)
        XCTAssertEqual(unsigned?.contains("Inbox"), true)

        XCTAssertNil(HeldLines.sentence(.unsigned(stream: "x"), notes: 0))
    }

    // MARK: - Cost

    /// A book with no narrowing permit never examines an unattributable file
    /// at all — the door's own early exits, pinned rather than argued.
    func test_anUnNarrowedBookNeverWalksAnUnattributableFile() async throws {
        try writeRootRecord()
        try admitSam()
        try ghostFile([op("01", by: ghost.author)])

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func tick() { lock.lock(); n += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let walked = Counter()
        PermitPartition.walkObserverForTesting = { walked.tick() }
        _ = try await appliedOpIds()
        XCTAssertEqual(walked.count, 0)
    }
}
