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
        OpLogStore.manifestReadObserverForTesting = nil
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

    /// The same bytes, unwritten — for the one test that puts a file where its
    /// own name does not belong.
    private func fileBytes(by identity: DeviceIdentity, ops: [Op]) throws -> Data {
        let url = try writeFile(by: identity, ops: ops)
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        return bytes
    }

    @discardableResult
    private func samsFile(_ ops: [Op], extraLines: [Data] = []) throws -> URL {
        try writeFile(by: sam.author, ops: ops, extraLines: extraLines)
    }

    /// A counter a `@Sendable` observer can safely increment.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func tick() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// A manifest on disk, so the partition has somewhere to read a stream's
    /// placement from. `statements` is all this decision uses.
    private func writeManifest(statements: [Statement]) throws {
        let manifest = ProjectManifest(
            type: .novel, title: "A book", author: "Denver",
            created: Date(timeIntervalSince1970: 0),
            modified: Date(timeIntervalSince1970: 0),
            structure: [], research: [], statements: statements)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: projectURL.appendingPathComponent(ProjectManifest.fileName),
            options: .atomic)
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

    /// **The mark a PERMIT event records** — through the production door, as
    /// `RegistryAdmission.changePermit` will (fix round 2).
    private func seenMark() async throws -> [String: PermitMark.StreamMark] {
        try OpLogStore.seenPositions(
            ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
            trust: try await reader().trust()).streams
    }

    /// Its revocation-side sibling, for the tests that are about the
    /// difference between the two.
    private func appliedMark() async throws -> [String: PermitMark.StreamMark] {
        try OpLogStore.appliedPositions(
            ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
            trust: try await reader().trust()).streams
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

        let judged = Counter()
        PermitPartition.judgeObserverForTesting = { judged.tick() }
        let applied = try await appliedOpIds()
        let provenance = try await loadedProvenance()

        XCTAssertEqual(applied, ["01", "02", "03"])
        XCTAssertEqual(provenance.quarantinedLines, 0)
        XCTAssertEqual(provenance.pendingLines, 0)
        XCTAssertEqual(provenance.unsignedHistoryLines, 0)
        XCTAssertTrue(linesRecords().isEmpty)
        XCTAssertEqual(judged.count, 0, "a book with no events hashes nothing")
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

        let stream = try XCTUnwrap(PermitMark.stream(of: url))
        let partitioned = PermitPartition.partition(
            of: walked, class: { .piece(self.docId) },
            streamKey: stream.key, deviceSlug: stream.deviceSlug,
            fileSegmentDigest: nil, trust: table,
            unowned: { .aBookAuthorHasWrittenItsText })

        XCTAssertEqual(partitioned, walked)
    }

    /// **A book with no permit events reads no manifest at all** (fix round 1,
    /// I1). The class is asked for only where a line's own (permit, actor)
    /// pair makes the answer turn on it, and in such a book no line's does —
    /// so a load costs neither the file read nor the decode.
    func test_aBookWithNoEventsReadsNoManifest() async throws {
        try writeRootRecord()
        try admitSam()
        try writeManifest(statements: [])
        try writeFile(by: root.author, ops: [op("01", by: root.author)])
        try samsFile([op("02", by: sam.author)])

        let manifestReads = Counter()
        OpLogStore.manifestReadObserverForTesting = { manifestReads.tick() }
        let applied = try await appliedOpIds()

        XCTAssertEqual(applied, ["01", "02"])
        XCTAssertEqual(manifestReads.count, 0,
                       "nothing turned on where the streams sit")
    }

    // MARK: - Where the stream sits (minor (c))

    /// A project statement is the book author's, and an author of some pieces
    /// is refused on it — which is a decision the CLASS makes, so it is also
    /// the case that proves the manifest is read when it matters.
    func test_aScopedAuthorIsRefusedOnAProjectStatementAndTheBookAuthorIsNot() async throws {
        try writeRootRecord()
        try admitSam()
        try writeManifest(statements: [
            Statement(id: docId, kind: .intent, scope: .project, path: "intent.md"),
        ])
        try samsFile([op("hers", by: sam.author)])
        try writeFile(by: root.author, ops: [op("theRoots", by: root.author)])
        try writeEvent("a", kind: .admitted, role: Permit.authorRole,
                       scope: Permit.piecesScope, pieces: ["doc-some-piece"])

        let manifestReads = Counter()
        OpLogStore.manifestReadObserverForTesting = { manifestReads.tick() }
        let applied = try await appliedOpIds()

        XCTAssertEqual(applied, ["theRoots"])
        XCTAssertEqual(
            linesRecords().map(\.reason),
            ["written into this book's own statements by a device that may not write it here"])
        XCTAssertGreaterThan(manifestReads.count, 0,
                             "and here it did turn on the class")
    }

    /// **A manifest that will not read never makes a load refuse, and it
    /// widens** (fix round 1, minor (a)/(c) and R2's other half): no
    /// statements places every stream as a manuscript PIECE, which is the
    /// class an author of some pieces can actually hold.
    func test_anUnreadableManifestWidensAndDoesNotRefuseTheLoad() async throws {
        try writeRootRecord()
        try admitSam()
        try Data("{ this is not a manifest".utf8).write(
            to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        try samsFile([op("hers", by: sam.author)])
        try writeEvent("a", kind: .admitted, role: Permit.authorRole,
                       scope: Permit.piecesScope, pieces: [docId])

        // The stream is a project STATEMENT on disk in the previous test's
        // shape; with no readable manifest it is a piece, and `docId` is one
        // of hers, so her line applies rather than being refused.
        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["hers"])
        XCTAssertTrue(linesRecords().isEmpty)
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

    func test_anUnknownOpKindIsHeldWhereTheLineIsJudged() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(
            by: sam.assistant,
            ops: [op("today", by: sam.assistant, kind: .claudeComment)],
            extraLines: [try futureKindLine("fromTomorrow", by: sam.assistant)])

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["today"])
        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingLines, 1)
        XCTAssertEqual(provenance.quarantinedLines, 0, "nothing is wrong with it")
        XCTAssertTrue(linesRecords().isEmpty)
    }

    /// **A book author's own hand is not judged, so her unknown kind reaches
    /// the parser exactly as it did before P3** (fix round 1, I3's ruling) —
    /// through both readers, which is where a divergence would show.
    func test_aBookAuthorsUnknownKindIsLeftToTheParser() async throws {
        try writeRootRecord()
        try admitSam()
        try samsFile(
            [op("today", by: sam.author)],
            extraLines: [try futureKindLine("fromTomorrow", by: sam.author)])

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied.sorted(), ["fromTomorrow", "today"])
        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingLines, 0)
        XCTAssertEqual(provenance.quarantinedLines, 0)
    }

    /// **D5 — a permit-pending line does not speak the admission vocabulary.**
    /// Sam is ADMITTED; a line of hers this build cannot judge is held, and
    /// nothing counts it as waiting for somebody to be let in.
    func test_anAdmittedPersonsUnjudgeableLineIsNotWaitingForAdmission() async throws {
        try writeRootRecord()
        try admitSam()
        try writeFile(
            by: sam.assistant,
            ops: [op("today", by: sam.assistant, kind: .claudeComment)],
            extraLines: [try futureKindLine("fromTomorrow", by: sam.assistant)])

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

    // MARK: - Which of the four writers a key is (fix round 1, I5)

    /// **A person record written for somebody's ASSISTANT key does not make
    /// that key an author.**
    ///
    /// The window is real: a stranger's held span is keyed on the sealing key
    /// where no device record names it, so before Sam's device record syncs
    /// the writer can be asked about — and admit — her assistant fingerprint.
    /// Reading `.author` off the person record there would apply
    /// assistant-signed manuscript text into the book. The actor comes off the
    /// file's own name instead, which can only ever narrow.
    func test_aPersonRecordOnAnAssistantKeyStillGetsTheAssistantsRow() async throws {
        try writeRootRecord()
        // Sam's ASSISTANT admitted as a person, with NO device record at all.
        try RegistryWriter.write(
            PersonRecord(
                person: sam.assistant.fingerprint, label: "Sam", ownName: "Sam’s Mac",
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try writeFile(
            by: sam.assistant,
            ops: [
                op("aNote", by: sam.assistant, kind: .claudeComment),
                op("aParagraph", by: sam.assistant),
            ])

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["aNote"], "her note is the assistant's row")
        XCTAssertEqual(
            linesRecords().map(\.reason),
            ["written by the assistant, which never changes the manuscript"])
    }

    /// The P2 case, unchanged: a person record on an AUTHOR key, no device
    /// record, everything applies as it always did.
    func test_aPersonRecordOnAnAuthorKeyIsAnAuthorAsItAlwaysWas() async throws {
        try writeRootRecord()
        try RegistryWriter.write(
            PersonRecord(
                person: samPerson, label: "Sam", ownName: "Sam’s Mac",
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try samsFile([op("hers", by: sam.author)])

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, ["hers"])
        XCTAssertTrue(linesRecords().isEmpty)
    }

    /// And a filename that does not describe its own contents narrows nothing:
    /// the line is HELD, because nothing here can say which row it is on.
    func test_aDeviceIdWhoseFingerprintIsNotTheSealsHoldsTheLine() async throws {
        try writeRootRecord()
        try RegistryWriter.write(
            PersonRecord(
                person: samPerson, label: "Sam", ownName: "Sam’s Mac",
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        // Sam's key, sealed by Sam — in a file named for somebody else's slug.
        let bytes = try fileBytes(by: sam.author, ops: [op("hers", by: sam.author)])
        try bytes.write(
            to: OpLogStore.opLogFileURL(
                forDocId: docId, deviceSlug: root.assistant.slug, in: projectURL),
            options: .atomic)

        let applied = try await appliedOpIds()
        XCTAssertEqual(applied, [])
        let provenance = try await loadedProvenance()
        XCTAssertEqual(provenance.pendingOpLines, 1, "held, never refused")
        XCTAssertEqual(provenance.quarantinedLines, 0)
    }

    // MARK: - A mark selects a PERMIT; it blesses nothing (fix round 2)

    /// **A promotion is not a pardon, even when the refused text is the LAST
    /// thing in the file.**
    ///
    /// This is the case that shows why a permit event's position cannot be
    /// *the last line the root APPLIED*. Sam is a reviewer and her file ends
    /// in manuscript text this Mac refused; the last applied line is the note
    /// BEFORE it, so under that rule her text would judge NEW, land under the
    /// author permit she was just given, and be applied. Spec §5 forbids
    /// exactly that. The position is the last line the root SAW and judged —
    /// the seal that closes her refused text — so the text stays old, stays
    /// hers-as-a-reviewer, and stays refused.
    func test_aPromotionIsNotAPardonWhenTheRefusedTextIsLastInTheFile() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent("a", kind: .admitted, role: Permit.reviewerRole)
        try samsFile([
            op("herNote", by: sam.author, kind: .claudeComment),
            op("herText", by: sam.author),
        ])

        let before = try await appliedOpIds("while she is a reviewer")
        XCTAssertEqual(before, ["herNote"], "the fixture really refuses her text")

        // The two positions differ here, and that is the whole point: the
        // applied one stops before her refused text, the seen one takes it in.
        let seen = try await seenMark()
        let applied = try await appliedMark()
        XCTAssertNotEqual(
            seen.values.first?.line, applied.values.first?.line,
            "a refused trailing line is seen and is not applied")

        try writeEvent("b", kind: .roleChanged, role: Permit.authorRole, mark: seen)

        let after = try await appliedOpIds("and after the promotion")
        XCTAssertEqual(after, ["herNote"], "a promotion is not a pardon")
        XCTAssertEqual(
            linesRecords().map(\.reason),
            ["written into the manuscript by a device that may not write it here"])
    }

    /// **A demotion does not reach back into a segment that had one refused
    /// line in it.**
    ///
    /// A segment holding honestly applied lines AND something held back is not
    /// *wholly applied* — and if that were the test for listing its digest, it
    /// would go unlisted, every line in it would judge NEW, and the demotion
    /// would refuse work the writer has been reading for months. The digest
    /// says *the root read this whole file*, which is true, and the lines
    /// inside keep the permits they were written under.
    func test_aDemotionDoesNotReachBackIntoASegmentWithSomethingHeldInIt() async throws {
        try writeRootRecord()
        try admitSam()
        // Narrowed from the start, so an unknown KIND inside her file is
        // genuinely held rather than skipped as a book author's own hand.
        try writeEvent("a", kind: .admitted, role: Permit.authorRole,
                       scope: Permit.piecesScope, pieces: [docId])
        try samsFile(
            [op("t0", by: sam.author), op("t1", by: sam.author)],
            extraLines: [try futureKindLine("fromTomorrow", by: sam.author)])
        let samsStore = OpLogStore(
            projectURL: projectURL, identities: sam, state: samState)
        let rotated = try await samsStore.sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)
        XCTAssertNotNil(rotated, "the fixture really rotated")

        let before = try await appliedOpIds("inside her own piece")
        XCTAssertEqual(before, ["t0", "t1"])
        let held = try await loadedProvenance().pendingOpLines
        XCTAssertEqual(held, 1, "and one line of it is held")

        let seen = try await seenMark()
        XCTAssertEqual(
            seen.values.first?.segments.count, 1,
            "the root read the whole segment, refusals and all")
        try writeEvent("b", kind: .roleChanged, role: Permit.reviewerRole, mark: seen)

        let after = try await appliedOpIds("and after the demotion")
        XCTAssertEqual(after, ["t0", "t1"], "what she wrote before then stays")
        XCTAssertTrue(linesRecords().isEmpty)
    }

    /// **A line held because this build cannot judge it was still SEEN.** The
    /// trailing unsealed span is where the two positions can differ over a
    /// held line, so that is where this is asked.
    func test_aPermitPendingTrailingLineWasSeen() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent("a", kind: .admitted, role: Permit.authorRole,
                       scope: Permit.piecesScope, pieces: [docId])
        // [text, seal, unknown-kind] — the held line is AFTER the seal, so the
        // seal cannot stand in for it as the file's last line.
        let url = try samsFile([op("t0", by: sam.author)])
        var bytes = try Data(contentsOf: url)
        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: true)
            .map(Data.init)
        let held = OpLogChain.chainedLine(
            elementJSON: try futureKindLine("fromTomorrow", by: sam.author),
            prev: OpLogChain.lineHash(lines[lines.count - 1]))
        bytes.append(held)
        bytes.append(0x0A)
        try bytes.write(to: url, options: .atomic)

        let pending = try await loadedProvenance().pendingOpLines
        XCTAssertEqual(pending, 1)
        let seen = try await seenMark()
        let applied = try await appliedMark()
        XCTAssertEqual(
            seen.values.first?.line, OpLogChain.lineHash(held),
            "the held line is the last one the root saw")
        XCTAssertEqual(
            applied.values.first?.line, OpLogChain.lineHash(lines[lines.count - 1]),
            "and it is not the last one it applied")
    }

    /// **A torn tail line was not seen.** Bytes that do not close as an object,
    /// with nothing after them, are a write that stopped mid-line — nobody
    /// finished them, so nobody judged them.
    func test_aTornTailLineWasNotSeen() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try samsFile([op("t0", by: sam.author)])
        var bytes = try Data(contentsOf: url)
        let whole = bytes.split(separator: 0x0A, omittingEmptySubsequences: true)
            .map(Data.init)
        bytes.append(Data(#"{"op_id":"torn","doc_i"#.utf8))
        try bytes.write(to: url, options: .atomic)

        let seen = try await seenMark()
        XCTAssertEqual(
            seen.values.first?.line, OpLogChain.lineHash(whole[whole.count - 1]),
            "the position stops at the last line that closed")
    }

    /// **And the revocation's own question is unchanged**: a segment the root
    /// read whole is still listed for it, so `Revoke, keeping what this Mac
    /// already had` gives back the lines it had applied rather than refusing
    /// them for sitting beside one it did not (fix round 2's analysis).
    func test_appliedPositionsStillListsASegmentItReadWhole() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent("a", kind: .admitted, role: Permit.authorRole,
                       scope: Permit.piecesScope, pieces: [docId])
        try samsFile(
            [op("t0", by: sam.author)],
            extraLines: [try futureKindLine("fromTomorrow", by: sam.author)])
        let samsStore = OpLogStore(
            projectURL: projectURL, identities: sam, state: samState)
        let rotated = try await samsStore.sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)
        XCTAssertNotNil(rotated)

        let applied = try await appliedMark()
        XCTAssertEqual(
            applied.values.first?.segments.count, 1,
            "a partially applied segment is still a segment this Mac read")
    }

    /// **A segment the reader could not get to the end of is listed nowhere.**
    ///
    /// The digest says *the root read this whole file*. Where the chain broke
    /// inside it the root never trusted the bytes after the break, so it did
    /// not read the file whole and must not say it did — and the lines inside
    /// judge NEW later, which is the strict side.
    func test_aSegmentWhoseChainBrokeIsListedNowhere() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try samsFile([op("t0", by: sam.author)])
        // A correctly-shaped line naming a `prev` that is nobody's head.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        var bytes = try Data(contentsOf: url)
        bytes.append(OpLogChain.chainedLine(
            elementJSON: try encoder.encode(op("spliced", by: sam.author)),
            prev: String(repeating: "b", count: 64)))
        bytes.append(0x0A)
        try bytes.write(to: url, options: .atomic)

        let samsStore = OpLogStore(
            projectURL: projectURL, identities: sam, state: samState)
        let segment = try await samsStore.sealTailIfNeeded(
            docId: docId, deviceSlug: sam.author.slug, threshold: 1)
        // Without its signature the container is WALKED, which is the only way
        // an inner break is ever seen at all.
        try FileManager.default.removeItem(
            at: OpLogStore.segmentSignatureURL(for: try XCTUnwrap(segment)))

        let seen = try await seenMark()
        XCTAssertEqual(
            seen.values.first?.segments ?? [], [],
            "the root did not reach the end of it")
        let applied = try await appliedMark()
        XCTAssertEqual(applied.values.first?.segments ?? [], [])
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
