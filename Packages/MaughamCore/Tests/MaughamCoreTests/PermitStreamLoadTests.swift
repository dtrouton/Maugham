import Foundation
import XCTest
@testable import MaughamCore

/// **The permit, over the two streams that are not the op log** (P3a Task 6,
/// spec §4.3's first bullet and §9's first line).
///
/// A translation record and an inbox row are signed lines another person's
/// device writes and this one applies, exactly as an op is — so they answer to
/// the same ladder, through the same partition, in their own readers:
/// `TranslationStore.loadMerged` and `JSONLAppendStore.loadVerifiedStrict`.
///
/// The fixtures are `PermitLoadTests`' — a real project directory, a real
/// registry folder with real signed records and events, real chained-and-sealed
/// files, software signers only (tripwire 36) and every root removed in
/// `tearDown`.
@MainActor
final class PermitStreamLoadTests: XCTestCase {

    private let docId = "doc-stream"
    private let otherDocId = "doc-other"
    private let language = "es"
    private var projectURL: URL!

    /// This Mac: the root, and the one judging.
    private var root: LocalIdentities!
    private var rootState: OpLogDeviceState!
    /// Sam's Mac: admitted, and the subject of every event here.
    private var sam: LocalIdentities!
    private var samState: OpLogDeviceState!
    private var cache: RegistryCache!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("permit-stream-\(UUID().uuidString)")
        for sub in [".maugham/ops", ".maugham/translations", ".maugham/inbox"] {
            try FileManager.default.createDirectory(
                at: projectURL.appendingPathComponent(sub),
                withIntermediateDirectories: true)
        }
        root = .softwareForTesting()
        sam = .softwareForTesting()
        rootState = state("root")
        samState = state("sam")
        cache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
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

    // MARK: - Registry fixtures

    private var rootPerson: String { root.author.fingerprint }
    private var samPerson: String { sam.author.fingerprint }

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
                    DeviceActor.translator.rawValue: root.translator.fingerprint,
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
                    DeviceActor.translator.rawValue: sam.translator.fingerprint,
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

    private func table() throws -> TrustTable {
        try TrustResolution.resolve(
            projectURL: projectURL, identities: root, cache: cache)
    }

    // MARK: - Stream fixtures

    /// A chained, sealed file of arbitrary JSONL elements — the shape both
    /// streams share, because both are `JSONLAppendStore`s under a
    /// `ChainPolicy`.
    @discardableResult
    private func writeChained(
        at url: URL, by identity: DeviceIdentity, elements: [Data]
    ) throws -> URL {
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
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// The same file with **no seal on the end of it** — a stream mid-burst,
    /// which is what every fixture above seals past (Task 11, audit PR #65's
    /// F2).
    @discardableResult
    private func writeChainedUnsealed(at url: URL, elements: [Data]) throws -> URL {
        var bytes = Data()
        var head: String?
        for element in elements {
            let line = OpLogChain.chainedLine(
                elementJSON: element, prev: head ?? OpLogChain.genesis)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Sam's own device record and nothing else: a machine that has declared
    /// itself (`RegistryPresence.ensureDeviceRecord` does this at every open)
    /// and that nobody has admitted. The realistic stranger, and the one whose
    /// key a filename can be matched to.
    private func samsDeviceRecordOnly() throws {
        try RegistryWriter.write(
            DeviceRecord(
                device: samPerson, name: "Sam’s Mac", kind: .mac,
                actors: [
                    DeviceActor.author.rawValue: samPerson,
                    DeviceActor.assistant.rawValue: sam.assistant.fingerprint,
                    DeviceActor.translator.rawValue: sam.translator.fingerprint,
                ],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: sam.author, in: projectURL)
    }

    /// A second run of lines chained onto what the file already holds, then
    /// sealed again — what a device's next write actually does. A rewrite from
    /// genesis would move the seal the mark points at, which is the one thing
    /// an append never does.
    private func appendChained(
        at url: URL, by identity: DeviceIdentity, elements: [Data]
    ) throws {
        var bytes = try Data(contentsOf: url)
        var head = OpLogChain.lineHash(try XCTUnwrap(
            bytes.split(separator: 0x0A, omittingEmptySubsequences: true).last
                .map(Data.init)))
        for element in elements {
            let line = OpLogChain.chainedLine(elementJSON: element, prev: head)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        let seal = try OpLogChain.Seal.line(
            head: head, identity: identity, at: Date(timeIntervalSince1970: 60))
        bytes.append(seal)
        bytes.append(0x0A)
        try bytes.write(to: url, options: .atomic)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        return try encoder.encode(value)
    }

    private func record(_ opId: String, paragraph: String = "aaaa") -> TranslationRecord {
        TranslationRecord(
            opId: opId, paragraphId: paragraph, language: language,
            text: "traducción \(opId)", sourceHash: "h",
            at: Date(timeIntervalSince1970: 30))
    }

    @discardableResult
    private func samsTranslation(
        _ records: [TranslationRecord], by identity: DeviceIdentity? = nil,
        forDocId id: String? = nil
    ) throws -> URL {
        let identity = identity ?? sam.author
        return try writeChained(
            at: TranslationStore.fileURL(
                forDocId: id ?? docId, language: language,
                deviceSlug: identity.slug, in: projectURL),
            by: identity, elements: try records.map { try encoded($0) })
    }

    private func entry(_ id: String, by identity: DeviceIdentity) -> InboxEntry {
        InboxEntry(
            id: id, createdAt: Date(timeIntervalSince1970: 30),
            writtenAt: Date(timeIntervalSince1970: 30),
            deviceId: identity.deviceId, kind: .text, inlineText: "note \(id)")
    }

    @discardableResult
    private func samsInbox(
        _ entries: [InboxEntry], by identity: DeviceIdentity? = nil
    ) throws -> URL {
        let identity = identity ?? sam.author
        return try writeChained(
            at: InboxManifest.inboxManifestURL(
                forDeviceSlug: identity.slug, in: projectURL),
            by: identity, elements: try entries.map { try encoded($0) })
    }

    // MARK: - Reading

    private func translations(forDocId id: String? = nil) throws -> [String] {
        try TranslationStore.loadMerged(
            forDocId: id ?? docId, language: language, in: projectURL,
            identities: root, state: rootState, trust: try table())
            .map(\.opId).sorted()
    }

    private func inboxRows(
        by identity: DeviceIdentity? = nil, slug: DeviceSlug? = nil
    ) async throws -> [String] {
        let identity = identity ?? sam.author
        let table = try table()
        let store = JSONLAppendStore<InboxEntry>(
            fileURL: InboxManifest.inboxManifestURL(
                forDeviceSlug: slug ?? identity.slug, in: projectURL),
            chain: ChainPolicy(
                identity: root.author, state: rootState,
                docId: InboxManifest.chainDocId, projectURL: projectURL,
                trust: { table.verdict(forSealKey: $0) }))
        return try await store.loadVerifiedStrict(permit: .inbox(trust: table))
            .elements.map(\.id).sorted()
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

    private func seenMark() throws -> [String: PermitMark.StreamMark] {
        try OpLogStore.seenPositions(
            ofDeviceIds: Set(sam.all.map(\.deviceId)), in: projectURL,
            trust: try table()).streams
    }

    // MARK: - Neutrality

    /// **A registered book with no events walks neither stream** (fix round 2,
    /// R3's cost).
    ///
    /// `TranslationStore.loadMerged` is read from around thirty synchronous
    /// call sites — the publish AST, the coverage gate, the editor's translated
    /// surface — and the inbox re-reads on every refresh. Paying
    /// `attributableKeys` (a `Seal.parse` per seal line) on each of those, in a
    /// book where every admitted person is an author of the whole book and
    /// every line these two streams can carry is `.yes` on that rung, is work
    /// whose only possible product is *yes*.
    ///
    /// The op log is deliberately NOT given this exit and is not asserted here:
    /// its lines are a dozen kinds and the actor rows narrow several of them,
    /// so its exit is per line (`Permit.allowsEverything`).
    func test_aRegisteredBookWithNoEventsWalksNeitherStream() async throws {
        try writeRootRecord()
        try admitSam()
        try samsTranslation([record("t1")])
        try samsInbox([entry("i1", by: sam.author)])

        let walks = Counter()
        PermitPartition.walkObserverForTesting = { walks.tick() }
        defer { PermitPartition.walkObserverForTesting = nil }

        XCTAssertEqual(try translations(), ["t1"])
        let rows = try await inboxRows()
        XCTAssertEqual(rows, ["i1"])
        XCTAssertEqual(walks.count, 0, "nothing here can be refused, so nothing is walked")
    }

    /// **The pipeline's own key takes the exit too**, which is the other
    /// direction of §2's census: a translation record is what the `translator`
    /// row is FOR, so an eventless book answers its file whole.
    func test_theTranslationPipelinesOwnFileTakesTheExit() async throws {
        try writeRootRecord()
        try admitSam()
        try samsTranslation([record("t1")], by: sam.translator)

        let walks = Counter()
        PermitPartition.walkObserverForTesting = { walks.tick() }
        defer { PermitPartition.walkObserverForTesting = nil }

        XCTAssertEqual(try translations(), ["t1"])
        XCTAssertEqual(walks.count, 0)
    }

    /// **But the ASSISTANT's key does not, and its record is refused — in a
    /// book with no events at all** (fix round 3).
    ///
    /// *MCP never mutates the manuscript* is a sentence of the constitution,
    /// not a thing that waits for a book to have permit events. Round 2's exit
    /// was unconditional on the actor and applied this line; the narrowed one
    /// falls through to the walk, which refuses it exactly as it always did.
    func test_anAssistantSignedTranslationIsRefusedEvenWithNoEvents() async throws {
        try writeRootRecord()
        try admitSam()
        try samsTranslation([record("t1")], by: sam.assistant)

        let walks = Counter()
        PermitPartition.walkObserverForTesting = { walks.tick() }
        defer { PermitPartition.walkObserverForTesting = nil }

        XCTAssertEqual(try translations(), [],
                       "the assistant never writes a translation, on any book")
        XCTAssertEqual(walks.count, 1, "so this file IS walked")
        XCTAssertTrue(try archivedLines().contains("traducción t1"))
    }

    /// And an actor the register cannot name is walked and HELD, not waved
    /// through — the same answer the evented case already gives.
    func test_anUnnameableActorsInboxFileIsWalkedAndHeldWithNoEvents() async throws {
        try writeRootRecord()
        // Admitted as a person, with no device record to say what her key is
        // for, writing under a slug that names no actor either.
        try RegistryWriter.write(
            PersonRecord(
                person: samPerson, label: "Sam", ownName: "Sam’s Mac",
                admittedAt: Date(timeIntervalSince1970: 20), admittedBy: rootPerson),
            signedBy: root.author, in: projectURL)
        try writeChained(
            at: InboxManifest.inboxManifestURL(
                forDeviceSlug: DeviceSlug.make(from: "a-phone"), in: projectURL),
            by: sam.author, elements: [try encoded(entry("i1", by: sam.author))])

        let walks = Counter()
        PermitPartition.walkObserverForTesting = { walks.tick() }
        defer { PermitPartition.walkObserverForTesting = nil }

        let rows = try await inboxRows(slug: DeviceSlug.make(from: "a-phone"))
        XCTAssertEqual(rows, [], "nothing can say which of the four wrote it")
        XCTAssertEqual(walks.count, 1)
        XCTAssertEqual(try archivedLines(), "", "held, never set aside")
    }

    /// Its converse, so the exit is not simply *never judge these streams*: one
    /// permit event in the book and both are walked again.
    func test_oneEventInTheBookAndBothStreamsAreWalkedAgain() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent("01", kind: .admitted, role: Permit.authorRole)
        try samsTranslation([record("t1")])
        try samsInbox([entry("i1", by: sam.author)])

        let walks = Counter()
        PermitPartition.walkObserverForTesting = { walks.tick() }
        defer { PermitPartition.walkObserverForTesting = nil }

        _ = try translations()
        _ = try await inboxRows()
        XCTAssertEqual(walks.count, 2, "one translation sidecar, one inbox manifest")
    }

    /// A counter a `@Sendable` observer can safely increment.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func tick() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// A book with no permit events reads both streams exactly as it did
    /// before P3a — the whole milestone's first promise.
    func test_aBookWithNoEventsReadsBothStreamsAsItAlwaysDid() async throws {
        try writeRootRecord()
        try admitSam()
        try samsTranslation([record("t1"), record("t2", paragraph: "bbbb")])
        try samsInbox([entry("i1", by: sam.author)])

        XCTAssertEqual(try translations(), ["t1", "t2"],
                       "every admitted person is an author of the whole book")
        let rows = try await inboxRows()
        XCTAssertEqual(rows, ["i1"])
        XCTAssertEqual(try archivedLines(), "", "nothing was set aside")
    }

    /// And a book with no REGISTER at all — P1's world — is untouched too.
    func test_aBookWithNoRegisterJudgesNeitherStream() async throws {
        try samsTranslation([record("t1")])
        try samsInbox([entry("i1", by: sam.author)])

        XCTAssertEqual(try translations(), ["t1"])
        let rows = try await inboxRows()
        XCTAssertEqual(rows, ["i1"])
    }

    // MARK: - An unsealed span answers to its file's verdict (Task 11)

    /// **A stranger's unsealed translation sidecar is held**, exactly as her
    /// sealed one is.
    ///
    /// Before Task 11 trust was consulted only at a SEAL, so a whole edition
    /// arrived in the book by never being signed: on unchanged code this reads
    /// `["t1", "t2"]`.
    func test_aStrangersUnsealedTranslationSidecarIsHeld() async throws {
        try writeRootRecord()
        try samsDeviceRecordOnly()
        try writeChainedUnsealed(
            at: TranslationStore.fileURL(
                forDocId: docId, language: language,
                deviceSlug: sam.author.slug, in: projectURL),
            elements: [try encoded(record("t1")),
                       try encoded(record("t2", paragraph: "bbbb"))])

        XCTAssertEqual(try translations(), [],
                       "nobody admitted Sam, and not sealing is not a way in")
        XCTAssertEqual(try archivedLines(), "",
                       "held is not refused: nothing is recorded, because "
                           + "nothing is wrong with it")
    }

    /// **A stranger's unsealed inbox manifest is held** — the same rule on the
    /// third chained stream.
    func test_aStrangersUnsealedInboxManifestIsHeld() async throws {
        try writeRootRecord()
        try samsDeviceRecordOnly()
        try writeChainedUnsealed(
            at: InboxManifest.inboxManifestURL(
                forDeviceSlug: sam.author.slug, in: projectURL),
            elements: [try encoded(entry("i1", by: sam.author))])

        let rows = try await inboxRows()
        XCTAssertEqual(rows, [], "a capture waits for admission like a note")
        XCTAssertEqual(try archivedLines(), "")
    }

    /// And the neutrality half on both streams: **admitted, unsealed, applied.**
    func test_anAdmittedDevicesUnsealedStreamsAreBothApplied() async throws {
        try writeRootRecord()
        try admitSam()
        try writeChainedUnsealed(
            at: TranslationStore.fileURL(
                forDocId: docId, language: language,
                deviceSlug: sam.author.slug, in: projectURL),
            elements: [try encoded(record("t1"))])
        try writeChainedUnsealed(
            at: InboxManifest.inboxManifestURL(
                forDeviceSlug: sam.author.slug, in: projectURL),
            elements: [try encoded(entry("i1", by: sam.author))])

        XCTAssertEqual(try translations(), ["t1"])
        let rows = try await inboxRows()
        XCTAssertEqual(rows, ["i1"])
        XCTAssertEqual(try archivedLines(), "")
    }

    // MARK: - What the load writes down about amendments (fix round 1)

    /// One device's op-log file, chained and sealed by the key that wrote it.
    @discardableResult
    private func opsFile(by identity: DeviceIdentity, ops: [Op]) throws -> URL {
        try writeChained(
            at: OpLogStore.opLogFileURL(
                forDocId: docId, deviceSlug: identity.slug, in: projectURL),
            by: identity, elements: try ops.map { try encoded($0) })
    }

    private func amendment(_ opId: String, by identity: DeviceIdentity) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 30),
           device: identity.deviceId, session: "s", kind: .annotationWithdraw,
           changes: [], provenance: .init(sourceAnnotationId: "whatever"))
    }

    private func collectedPermits() async throws -> [String: Permit] {
        let permits = AmendmentPermits()
        _ = try await OpLogStore(
            projectURL: projectURL, identities: root,
            state: rootState, cache: cache)
            .loadDiagnosed(docId: docId, amendmentPermits: permits)
        return permits.resolved
    }

    /// **A book with no permit events writes down nothing**, which is what
    /// keeps the new decode off every existing book's load: with one entry in
    /// every timeline, as-of-the-line and as-of-today are the same permit, so
    /// there is nothing a map could tell a deriver that the table cannot.
    func test_aBookWithNoEventsRecordsNoAmendmentPermitAtAll() async throws {
        try writeRootRecord()
        try admitSam()
        try opsFile(by: sam.author, ops: [amendment("w1", by: sam.author)])

        let permits = try await collectedPermits()
        XCTAssertTrue(permits.isEmpty, "nothing to say, so nothing is decoded")
    }

    /// And a book WITH events writes down the permit that governed the line —
    /// the one the deriver is owed, and never today's.
    func test_aBookWithEventsRecordsTheAmendmentsGoverningPermit() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent("01", kind: .admitted, role: Permit.reviewerRole)
        try opsFile(by: sam.author, ops: [amendment("w1", by: sam.author)])

        let permits = try await collectedPermits()
        XCTAssertEqual(permits, ["w1": .reviewer])
    }

    // MARK: - Translations

    /// A reviewer may not translate at all: the ladder gives her annotations
    /// and inbox rows, and a translation is neither.
    func test_aReviewersTranslationRecordIsRefused() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent("01", kind: .admitted, role: Permit.reviewerRole)
        try samsTranslation([record("t1")])

        XCTAssertEqual(try translations(), [],
                       "a reviewer writes no translations")
        XCTAssertTrue(
            try archivedLines().contains("traducción t1"),
            "and the words she wrote are kept in backup")
    }

    /// An author of some pieces translates HERS, and only hers. Both halves in
    /// one test, because the rule is two-sided (constraints: every direction
    /// names both).
    func test_aScopedAuthorTranslatesHerOwnPieceAndNotAnotherS() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent(
            "01", kind: .admitted, role: Permit.authorRole,
            scope: Permit.piecesScope, pieces: [docId])
        try samsTranslation([record("mine")])
        try samsTranslation([record("theirs")], forDocId: otherDocId)

        XCTAssertEqual(try translations(), ["mine"],
                       "her own piece's translation is applied")
        XCTAssertEqual(try translations(forDocId: otherDocId), [],
                       "and a piece that is not hers is refused")
    }

    /// The `translator` actor is the one key whose whole row is translations —
    /// so under a book author's permit its records apply.
    func test_theTranslatorActorsRecordUnderABookAuthorIsApplied() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent("01", kind: .admitted, role: Permit.authorRole)
        try samsTranslation([record("t1")], by: sam.translator)

        XCTAssertEqual(try translations(), ["t1"])
    }

    /// And the same key under a reviewer writes nothing: the actor narrows
    /// *within* the person's permit and never widens it.
    func test_theTranslatorActorsRecordUnderAReviewerIsRefused() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent("01", kind: .admitted, role: Permit.reviewerRole)
        try samsTranslation([record("t1")], by: sam.translator)

        XCTAssertEqual(try translations(), [])
    }

    /// **Line by line** (spec §1): a span carrying a record she may not write
    /// loses that record and keeps the rest. Here the scope is one piece, and
    /// the same sealed span holds one record for each document's stream — so
    /// the discriminator is inside ONE file: a reviewer's own file holding a
    /// tombstone beside a translation is not expressible, so the line-by-line
    /// pin is made where it can be, on the piece boundary inside one span.
    func test_oneSpanKeepsWhatSheMayWriteAndLosesWhatSheMayNot() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent(
            "01", kind: .admitted, role: Permit.authorRole,
            scope: Permit.piecesScope, pieces: [docId])
        // Two records in ONE sealed span of ONE file of the piece that is NOT
        // hers, plus a span of the piece that is.
        try samsTranslation([record("a"), record("b", paragraph: "bbbb")])
        try samsTranslation(
            [record("x"), record("y", paragraph: "bbbb")], forDocId: otherDocId)

        XCTAssertEqual(try translations(), ["a", "b"])
        XCTAssertEqual(try translations(forDocId: otherDocId), [],
                       "both lines of the span she may not write are refused")
    }

    // MARK: - The mark names the translation stream

    /// **What the positions extension buys.** A demotion's mark names Sam's
    /// translation stream, so everything she translated before it stays
    /// applied — a demotion does not reach back (spec §5).
    ///
    /// Without the extension the mark would name her op streams alone, the
    /// translation stream would be judged wholly NEW, and every translation she
    /// had ever written would be refused retroactively.
    func test_aDemotionsMarkNamesHerTranslationStreamSoWhatCameBeforeStays() async throws {
        try writeRootRecord()
        try admitSam()
        try samsTranslation([record("before")])

        let mark = try seenMark()
        let key = try XCTUnwrap(PermitMark.streamKey(of: TranslationStore.fileURL(
            forDocId: docId, language: language,
            deviceSlug: sam.author.slug, in: projectURL)))
        XCTAssertNotNil(mark[key], "the mark names her translation stream")

        try writeEvent("01", kind: .roleChanged, role: Permit.reviewerRole, mark: mark)
        XCTAssertEqual(try translations(), ["before"],
                       "what she translated before then stays in the book")
    }

    /// Its other half: what she translates AFTER the mark is refused.
    func test_whatSheTranslatesAfterTheMarkIsRefused() async throws {
        try writeRootRecord()
        try admitSam()
        let url = try samsTranslation([record("before")])
        let mark = try seenMark()
        try writeEvent("01", kind: .roleChanged, role: Permit.reviewerRole, mark: mark)

        // She goes on appending to her own file, which is what a device does:
        // the lines the mark named are untouched and the new ones chain onto
        // the seal above them.
        try appendChained(
            at: url, by: sam.author,
            elements: [try encoded(record("after", paragraph: "bbbb"))])

        XCTAssertEqual(try translations(), ["before"])
        XCTAssertTrue(try archivedLines().contains("traducción after"))
    }

    // MARK: - The inbox

    /// A reviewer's captures are applied — the inbox is the one class whose
    /// whole content is the reviewer row (spec §2's first rung).
    func test_aReviewersInboxRowIsApplied() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent("01", kind: .admitted, role: Permit.reviewerRole)
        try samsInbox([entry("i1", by: sam.author)])

        let rows = try await inboxRows()
        XCTAssertEqual(rows, ["i1"], "capture is always offered")
        XCTAssertEqual(try archivedLines(), "")
    }

    /// **What the table says about an assistant-signed row, pinned.** The
    /// reviewer row grants inbox rows to every rung and to every actor, so an
    /// assistant-signed capture is applied — the assistant's narrowing costs it
    /// the manuscript, not the inbox.
    func test_anAssistantSignedInboxRowIsApplied() async throws {
        try writeRootRecord()
        try admitSam()
        try writeEvent("01", kind: .admitted, role: Permit.reviewerRole)
        try samsInbox([entry("i1", by: sam.assistant)], by: sam.assistant)

        let rows = try await inboxRows(by: sam.assistant)
        XCTAssertEqual(rows, ["i1"])
    }

    /// And the mark names her inbox stream too, for the same reason it names
    /// her translations.
    func test_aMarkNamesHerInboxStream() async throws {
        try writeRootRecord()
        try admitSam()
        try samsInbox([entry("i1", by: sam.author)])

        let key = try XCTUnwrap(PermitMark.streamKey(of:
            InboxManifest.inboxManifestURL(
                forDeviceSlug: sam.author.slug, in: projectURL)))
        XCTAssertNotNil(try seenMark()[key])
    }
}
