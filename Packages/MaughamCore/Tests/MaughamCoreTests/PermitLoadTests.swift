import Foundation
import XCTest
@testable import MaughamCore

/// **The permit partition, through a real load** (P3a Task 5 part 2, spec
/// §4.3–§4.5 and the §5 table).
///
/// `PermitPartitionTests` pins the pure function; this pins what the two
/// READERS do with it — a real project directory, a real registry folder with
/// real signed events, real chained-and-sealed files, and both doors:
/// `OpLogStore.loadDiagnosed` (coordinated, the editor's) and
/// `loadSyncMerged` (synchronous, MCP's `read_document` and the Practice
/// walk). Every assertion below is made through both, because the one thing a
/// reader must never do is disagree with the other about what a document is
/// made of.
///
/// Every row of spec §5 appears twice, once per direction. P2's two wrong
/// rulings were each half of a two-sided rule.
@MainActor
final class PermitLoadTests: XCTestCase {

    private let docId = "doc-permit"
    private var projectURL: URL!

    /// This Mac: the root, and the one judging.
    private var root: LocalIdentities!
    private var rootState: OpLogDeviceState!
    /// Sam's Mac: admitted, and the subject of every event here.
    private var sam: LocalIdentities!
    private var samState: OpLogDeviceState!
    /// A registry memory of this suite's own, so nothing reaches the
    /// process-wide cache beside the machine's real keys.
    private var cache: RegistryCache!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("permit-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        root = .softwareForTesting()
        sam = .softwareForTesting()
        rootState = state("root")
        samState = state("sam")
        cache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: root.author.fingerprint)
    }

    override func tearDown() async throws {
        PermitPartition.judgeObserverForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func state(_ name: String) -> OpLogDeviceState {
        OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("state-\(name).json"))
    }

    // MARK: - Fixtures

    private var rootPerson: String { root.author.fingerprint }
    private var samPerson: String { sam.author.fingerprint }

    private func op(
        _ opId: String, by identity: DeviceIdentity, kind: OpKind = .typingBurst
    ) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: identity.deviceId, session: "s", kind: kind,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: opId)],
           sequence: ["aaaa"])
    }

    /// An op whose `kind` this build has never heard of — a later build's line.
    private func futureKindLine(_ opId: String, by identity: DeviceIdentity) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "op_id": opId, "doc_id": docId, "at": "1970-01-01T00:00:00Z",
                "device": identity.deviceId, "session": "s",
                "kind": "epigraph_moved", "changes": [],
            ],
            options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func reader() -> OpLogStore {
        OpLogStore(projectURL: projectURL, identities: root,
                   state: rootState, cache: cache)
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
                actors: [
                    DeviceActor.author.rawValue: rootPerson,
                    DeviceActor.assistant.rawValue: root.assistant.fingerprint,
                ],
                madeAt: Date(timeIntervalSince1970: 1)),
            signedBy: root.author, in: projectURL)
    }

    private func admitSam() throws {
        try RegistryWriter.write(
            PersonRecord(
                person: samPerson, label: "Sam", ownName: "Sam’s Mac",
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: samPerson, name: "Sam’s Mac", kind: .mac,
                actors: [
                    DeviceActor.author.rawValue: samPerson,
                    DeviceActor.assistant.rawValue: sam.assistant.fingerprint,
                ],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: sam.author, in: projectURL)
    }

    private func writeEvent(
        _ id: String, kind: PermitEvent.Kind,
        role: String = Permit.authorRole,
        scope: String = Permit.bookScope,
        pieces: [String] = [],
        mark: [String: PermitMark.StreamMark] = [:]
    ) throws {
        try RegistryWriter.write(
            PermitEvent(
                event: "\(samPerson).\(id)", kind: kind, subject: samPerson,
                role: role, scope: scope, pieces: pieces, mark: mark,
                at: Date(timeIntervalSince1970: 40), by: rootPerson),
            signedBy: root.author, in: projectURL)
    }

    /// One device's own file: chained and sealed under the key that wrote it.
    ///
    /// Built by hand rather than through `OpLogStore.append`, because two of
    /// the tests below need a line whose `kind` this build cannot decode and
    /// there is no production door for writing one. Same bytes either way: the
    /// chain is `OpLogChain`'s own, and the seal is the real signature.
    @discardableResult
    private func writeFile(
        by identity: DeviceIdentity, ops: [Op], extraLines: [Data] = []
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        var elements = try ops.map { try encoder.encode($0) }
        elements.append(contentsOf: extraLines)

        var bytes = Data()
        var head: String?
        for element in elements {
            let line = OpLogChain.chainedLine(
                elementJSON: element, prev: head ?? OpLogChain.genesis)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        let seal = try OpLogChain.Seal.line(
            head: try XCTUnwrap(head), identity: identity,
            at: Date(timeIntervalSince1970: 50))
        bytes.append(seal)
        bytes.append(0x0A)

        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    private func samsFile(_ ops: [Op], extraLines: [Data] = []) throws -> URL {
        try writeFile(by: sam.author, ops: ops, extraLines: extraLines)
    }

    /// Everything in the `.lines` archive, as text — what the writer keeps.
    private func archivedLines() throws -> String {
        let dir = projectURL
            .appendingPathComponent(".maugham/conflicts/quarantined-ops")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return try names.filter { $0.hasSuffix(".lines") }.sorted().map {
            try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)
        }.joined()
    }

    /// The chain hash of the line at `index` of a file — what a mark records.
    private func mark(of url: URL, cuttingAfterLineAt index: Int) throws
        -> [String: PermitMark.StreamMark]
    {
        let bytes = try Data(contentsOf: url)
        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: true)
            .map(Data.init)
        let key = try XCTUnwrap(PermitMark.streamKey(of: url))
        return [key: .init(line: OpLogChain.lineHash(lines[index]))]
    }

    // MARK: - Reading a load, through BOTH doors

    /// The op ids each reader applies. They must agree; the helper asserts it,
    /// so every test below is a test of both.
    private func appliedOpIds(
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) async throws -> [String] {
        let coordinated = try await reader().loadDiagnosed(docId: docId)
        let sync = try OpLogStore.loadSyncMerged(
            forDocId: docId, in: projectURL, identities: root,
            state: rootState, trust: try await reader().trust())
        XCTAssertEqual(
            sync.map(\.opId), coordinated.ops.map(\.opId),
            "both readers see the same document\(message.isEmpty ? "" : " — \(message)")",
            file: file, line: line)
        return coordinated.ops.map(\.opId)
    }

    private func loadedProvenance() async throws -> OpLogProvenance {
        try await reader().loadDiagnosed(docId: docId).provenance
    }

    private func linesRecords() -> [QuarantineRecord] {
        OpLogQuarantine.records(forDocId: docId, in: projectURL)
            .filter { $0.kind == .lines }
    }

    // MARK: - Neutrality (the gate)

    /// **A P2-era book — a registry with devices and people and no events —
    /// loads exactly as it did.** Byte-identical `Verification`, every op
    /// applied, nothing held, nothing refused, and **nothing hashed**: with no
    /// events every timeline is one entry, that entry has no mark, and
    /// `PermitMark.judge` is never called at all.
    func test_aBookWithNoEventsLoadsExactlyAsItDid() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(by: root.author, ops: [op("01", by: root.author)])
        try samsFile([op("02", by: sam.author), op("03", by: sam.author)])

        var judged = 0
        PermitPartition.judgeObserverForTesting = { judged += 1 }
        let applied = try await appliedOpIds()
        let provenance = try await loadedProvenance()

        XCTAssertEqual(applied, ["01", "02", "03"])
        XCTAssertEqual(provenance.quarantinedLines, 0)
        XCTAssertEqual(provenance.pendingLines, 0)
        XCTAssertEqual(provenance.unsignedHistoryLines, 0)
        XCTAssertTrue(linesRecords().isEmpty)
        XCTAssertEqual(judged, 0, "a book with no events hashes nothing")
    }

    /// And the partition really is the identity function there: the walk the
    /// classifier hands back is the same VALUE it was given.
    func test_withNoEventsThePartitionIsTheIdentity() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try samsFile([op("02", by: sam.author)])
        let table = try await reader().trust()
        let bytes = try Data(contentsOf: url)
        let walked = OpLogChain.verify(
            bytes: bytes, trust: { table.verdict(forSealKey: $0) },
            rememberedHead: nil)

        let partitioned = PermitPartition.partition(
            of: walked, class: .piece(docId),
            streamKey: try XCTUnwrap(PermitMark.streamKey(of: url)),
            fileSegmentDigest: nil, trust: table,
            unowned: { .aBookAuthorHasWrittenItsText })

        XCTAssertEqual(partitioned, walked)
    }

    // MARK: - §5 row 1 — demotion, both directions

    func test_aDemotionLeavesWhatCameBeforeItAndTakesWhatCameAfter() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try samsFile([
            op("before1", by: sam.author), op("before2", by: sam.author),
            op("after1", by: sam.author), op("after2", by: sam.author),
        ])
        try writeEvent("a", kind: .admitted, role: Permit.authorRole)
        try writeEvent("b", kind: .roleChanged, role: Permit.reviewerRole,
                       mark: try mark(of: url, cuttingAfterLineAt: 1))

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["before1", "before2"],
                       "what she wrote before then stays in the book")
        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.quarantinedLines, 3,
                       "two ops after the mark, and the seal that travels with the last")
        XCTAssertEqual(
            linesRecords().map(\.reason),
            ["written into the manuscript by a device after its permission here changed"])
    }

    /// The same demotion applies what a reviewer MAY write. **Line by line.**
    func test_aDemotedAuthorsNotesAfterTheMarkAreStillApplied() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try samsFile([
            op("before", by: sam.author),
            op("note", by: sam.author, kind: .claudeComment),
            op("text", by: sam.author),
        ])
        try writeEvent("a", kind: .admitted, role: Permit.authorRole)
        try writeEvent("b", kind: .roleChanged, role: Permit.reviewerRole,
                       mark: try mark(of: url, cuttingAfterLineAt: 0))

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["before", "note"],
                       "a note is something a reviewer may write")
    }

    // MARK: - §5 row 2 — promotion, both directions

    func test_aPromotionAppliesWhatComesAfterItAndPardonsNothingBefore() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try samsFile([
            op("asReviewer", by: sam.author), op("asAuthor", by: sam.author),
        ])
        try writeEvent("a", kind: .admitted, role: Permit.reviewerRole)
        try writeEvent("b", kind: .roleChanged, role: Permit.authorRole,
                       mark: try mark(of: url, cuttingAfterLineAt: 0))

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["asAuthor"],
                       "a promotion is not a pardon")
        XCTAssertEqual(
            linesRecords().map(\.reason),
            ["written into the manuscript by a device that may not write it here"],
            "written under the permit she was admitted with — nothing changed first")
    }

    // MARK: - §5 row 1's scope half, both directions

    func test_aPieceLeavingHerScopeKeepsWhatCameBeforeTheMark() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try samsFile([
            op("hers", by: sam.author), op("notHersAnyMore", by: sam.author),
        ])
        try writeEvent("a", kind: .admitted, role: Permit.authorRole,
                       scope: Permit.piecesScope, pieces: [docId])
        try writeEvent("b", kind: .scopeChanged, role: Permit.authorRole,
                       scope: Permit.piecesScope, pieces: ["doc-other"],
                       mark: try mark(of: url, cuttingAfterLineAt: 0))

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["hers"])
    }

    func test_aPieceJoiningHerScopeAppliesWhatComesAfterTheMark() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try samsFile([
            op("tooEarly", by: sam.author), op("hersNow", by: sam.author),
        ])
        try writeEvent("a", kind: .admitted, role: Permit.authorRole,
                       scope: Permit.piecesScope, pieces: ["doc-other"])
        try writeEvent("b", kind: .scopeChanged, role: Permit.authorRole,
                       scope: Permit.piecesScope, pieces: ["doc-other", docId],
                       mark: try mark(of: url, cuttingAfterLineAt: 0))

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["hersNow"])
    }

    // MARK: - §5 row 6 — the root on her piece

    func test_theRootWritingInHerPieceIsApplied() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(by: root.author, ops: [op("rootsEdit", by: root.author)])
        try writeEvent("a", kind: .admitted, role: Permit.authorRole,
                       scope: Permit.piecesScope, pieces: [docId])

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["rootsEdit"])
        XCTAssertTrue(linesRecords().isEmpty)
    }

    // MARK: - The actor rows, on this device's own hand

    /// **`.mine` lines are partitioned too**, and the words are KEPT: the line
    /// leaves the document and lands in a `.lines` record with the sentence
    /// that says why (spec §5 — *set aside in her name*).
    func test_theAssistantsManuscriptLineIsRefusedInThisDevicesOwnFile() async throws {
        try writeRootRecord()
        try writeFile(
            by: root.assistant,
            ops: [
                op("aNote", by: root.assistant, kind: .claudeComment),
                op("aParagraph", by: root.assistant),
            ])

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["aNote"],
                       "a note is the assistant's row; a paragraph is not")
        XCTAssertEqual(
            linesRecords().map(\.reason),
            ["written by the assistant, which never changes the manuscript"])
        // **The words are in the backup**, which is what makes this a set-aside
        // rather than a loss (item 5 of the wiring brief).
        XCTAssertTrue(try archivedLines().contains("aParagraph"),
                      "the refused line is kept in backup")
    }

    // MARK: - Pending, never set aside

    func test_anUnknownOpKindIsHeldAndNeverSetAside() async throws {
        try writeRootRecord()
        try admitSam()
        try samsFile(
            [op("today", by: sam.author)],
            extraLines: [try futureKindLine("fromTomorrow", by: sam.author)])

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["today"])
        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingLines, 1)
        XCTAssertEqual(provenance.quarantinedLines, 0, "nothing is wrong with it")
        XCTAssertTrue(linesRecords().isEmpty)
    }

    /// **D5 — a permit-pending line does not speak the admission vocabulary.**
    /// Sam is ADMITTED; a line of hers this build cannot judge is held, and
    /// nothing counts it as waiting for somebody to be let in.
    func test_anAdmittedPersonsUnjudgeableLineIsNotWaitingForAdmission() async throws {
        try writeRootRecord()
        try admitSam()
        try samsFile(
            [op("today", by: sam.author)],
            extraLines: [try futureKindLine("fromTomorrow", by: sam.author)])

        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingOpLines, 1, "it IS held")
        XCTAssertEqual(provenance.pendingStrangerOpLines, 0,
                       "and she is already in the book")
        XCTAssertFalse(provenance.hasPendingAdmission)
        XCTAssertTrue(provenance.pendingStrangersByDevice.isEmpty)
    }

    /// The converse, in the same shape: a device with NO person record IS
    /// waiting, and the narrowing has not made the P2 sentence disappear.
    func test_aStrangersHeldLinesAreStillWaitingForAdmission() async throws {
        try writeRootRecord()
        try samsFile([op("02", by: sam.author)])

        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingStrangerOpLines, 1)
        XCTAssertTrue(provenance.hasPendingAdmission)
        XCTAssertEqual(
            Array(provenance.pendingStrangersByDevice.keys), [samPerson])
    }

    // MARK: - §4.5 — her new piece

    func test_herLinesInAPieceNobodyHasWrittenArePendingAndHardenOnce() async throws {
        try writeRootRecord()
        try admitSam()
        try samsFile([op("herOpening", by: sam.author)])
        try writeEvent("a", kind: .admitted, role: Permit.authorRole,
                       scope: Permit.piecesScope, pieces: ["doc-hers"])

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, [])
        var provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingOpLines, 1, "a question, not a violation")
        XCTAssertEqual(provenance.quarantinedLines, 0)
        XCTAssertTrue(linesRecords().isEmpty)
        XCTAssertEqual(provenance.pendingStrangerOpLines, 0,
                       "and not an admission question either")

        // The root writes the piece's text: it is theirs now, and her opening
        // hardens from held to set aside. **Only this direction.**
        try writeFile(by: root.author, ops: [op("rootsText", by: root.author)])

        let afterwards = try await appliedOpIds()
        XCTAssertEqual(afterwards, ["rootsText"])
        provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.quarantinedLines, 2,
                       "her opening and the seal that travels with it")
        XCTAssertEqual(provenance.pendingOpLines, 0)
        XCTAssertEqual(
            linesRecords().map(\.reason),
            ["written into the manuscript by a device that may not write it here"])
    }

    /// **One rule, two access points.** The TABLE answers the stranger
    /// question off the set `resolve` took from the same registry, so the load
    /// can stamp the split without keeping a registry and the sheet cannot
    /// disagree with the sentence (D5).
    func test_theTableAndTheRegistryAgreeAboutWhoIsAStranger() async throws {
        try writeRootRecord()
        try admitSam()
        let registry = try XCTUnwrap(
            try TrustResolution.verifiedRegistry(projectURL: projectURL, cache: cache))
        let table = try await reader().trust()
        let outsider = LocalIdentities.softwareForTesting().author.fingerprint

        for fingerprint in [rootPerson, samPerson, outsider] {
            XCTAssertEqual(
                table.isStrangerDevice(fingerprint),
                registry.isStrangerDevice(fingerprint),
                "one rule for \(DeviceCode.short(fingerprint))")
        }
        XCTAssertFalse(table.isStrangerDevice(samPerson))
        XCTAssertTrue(table.isStrangerDevice(outsider))
    }

    // MARK: - A rotated segment costs what its tail costs

    /// **A settled segment is partitioned too.** A container whose signature
    /// this device stands behind is normally applied WHOLE without being
    /// walked — so without this, a demoted device could escape the permit by
    /// ROTATING, which is maintenance it performs on itself. That is P2b Task
    /// 10's live-tail-versus-segment asymmetry one rule along.
    func test_aDemotedDevicesRotatedSegmentIsRefusedAsItsTailWouldBe() async throws {
        try writeRootRecord()
        try admitSam()
        let tail = try samsFile([
            op("before", by: sam.author), op("after", by: sam.author),
        ])
        let cut = try mark(of: tail, cuttingAfterLineAt: 0)

        // Rotate Sam's whole tail into a signed `.mzseg` — the file the
        // partition must still reach. `threshold: 1` makes any tail oversized.
        let samsStore = OpLogStore(
            projectURL: projectURL, identities: sam, state: samState)
        let segment = try await samsStore.sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)
        XCTAssertNotNil(segment, "the fixture really rotated")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tail.path),
            "rotation deletes the tail it sealed")

        // Before the demotion, the settled segment applies whole.
        let whole = try await appliedOpIds("a settled segment")
        XCTAssertEqual(whole, ["after", "before"].sorted())

        try writeEvent("a", kind: .admitted, role: Permit.authorRole)
        try writeEvent("b", kind: .roleChanged, role: Permit.reviewerRole, mark: cut)

        let partitioned = try await appliedOpIds("after the demotion")
        XCTAssertEqual(partitioned, ["before"],
                       "the mark cuts inside the segment, exactly as in the tail")
    }

    // MARK: - The revocation runs first, and its answer survives

    /// The two are never folded: a revocation cuts on its own mark, and the
    /// permit judges what it left applied.
    func test_aRevocationAndAPermitBothApplyInOrder() async throws {
        try writeRootRecord()
        try samsFile([
            op("01kept", by: sam.author), op("02after", by: sam.author),
        ])
        try RegistryWriter.write(
            PersonRecord(
                person: samPerson, label: "Sam", ownName: "Sam’s Mac",
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson,
                revokedAt: Date(timeIntervalSince1970: 30), revokedBy: rootPerson,
                highestOpIdSeen: "01kept"),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: samPerson, name: "Sam’s Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: samPerson],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: sam.author, in: projectURL)

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["01kept"])
        XCTAssertEqual(
            linesRecords().map(\.reason),
            ["written after this device's access was withdrawn"],
            "the revocation's own sentence, not the permit's")
    }
}
