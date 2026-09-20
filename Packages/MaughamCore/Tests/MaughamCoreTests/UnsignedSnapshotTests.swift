import Foundation
import XCTest
@testable import MaughamCore

/// **The first narrowing photographs the book's unsigned streams** (P3b Task 1;
/// Denver's ruling of 2026-09-20, option B).
///
/// The hole this closes is P1's by design: a file no seal and no device record
/// can name is applied unjudged, so a client that simply never seals walks past
/// every rung of the ladder. Closing it by REFUSING such lines would reach
/// backwards through an enclave-less Mac's whole history the day the root first
/// made somebody a reviewer — narrowing must not reach back — so the first
/// narrowing takes a photograph instead, and everything at or before it stays
/// exactly as P1 applied it.
///
/// Both directions are asserted throughout: a narrowing event carries a
/// complete snapshot or the verb refuses and writes nothing; a non-narrowing
/// one carries no field at all, sweeps nothing and leaves a P3a-era event's
/// bytes untouched.
final class UnsignedSnapshotTests: XCTestCase {

    private var projectURL: URL!
    private var cacheURL: URL!
    private var memoryURL: URL!
    /// This Mac, which roots the book.
    private var mine: LocalIdentities!
    /// A second machine, admitted as a person.
    private var sam: LocalIdentities!
    private let docId = "d-one"

    override func setUp() {
        super.setUp()
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsigned-snapshot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        cacheURL = projectURL.appendingPathComponent("registry-cache.json")
        memoryURL = projectURL.appendingPathComponent("admission-memory.json")
        mine = .softwareForTesting()
        sam = .softwareForTesting()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeCache() -> RegistryCache {
        RegistryCache(fileURL: cacheURL, identity: mine.author.fingerprint)
    }

    private func makeMemory() -> AdmissionMemory {
        AdmissionMemory(fileURL: memoryURL, identity: mine.author.fingerprint)
    }

    @discardableResult
    private func becomeRoot() throws -> String {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac,
            now: { Date(timeIntervalSince1970: 1) })
        try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: mine, writerName: "Denver",
            now: { Date(timeIntervalSince1970: 2) })
        return mine.author.fingerprint
    }

    @discardableResult
    private func admitSam(permit: Permit = .bookAuthor, unsigned: PermitMark? = nil)
    throws -> PersonRecord {
        try RegistryAdmission.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
            role: permit.wireRole, scope: permit.wireScope,
            pieces: permit.wirePieces, unsigned: unsigned,
            in: projectURL, by: mine.author,
            cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 10) })
    }

    @discardableResult
    private func changeSam(
        to permit: Permit, unsigned: PermitMark? = nil,
        at when: Date = Date(timeIntervalSince1970: 50)
    ) throws -> PersonRecord {
        try RegistryAdmission.changePermit(
            person: sam.author.fingerprint,
            role: permit.wireRole, scope: permit.wireScope,
            pieces: permit.wirePieces, mark: .nothingApplied, unsigned: unsigned,
            in: projectURL, by: mine.author, cache: makeCache(),
            now: { when })
    }

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    private func table() throws -> TrustTable {
        try TrustResolution.resolveVerified(
            projectURL: projectURL, identities: mine, cache: makeCache()).table
    }

    private func events(about subject: String) throws -> [PermitEvent] {
        try registry().events
            .filter { $0.subject == subject }
            .sorted { $0.event < $1.event }
    }

    private func op(_ opId: String, device: String) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: device, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: opId)],
           sequence: ["aaaa"])
    }

    private func encoded(_ ops: [Op]) throws -> [Data] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        return try ops.map { try encoder.encode($0) }
    }

    /// A stream that is CHAINED and that nothing seals — the shape a Mac with
    /// no Secure Enclave writes, and the shape this whole milestone is about.
    @discardableResult
    private func writeUnsealedStream(slug: DeviceSlug, ops: [Op]) throws -> URL {
        var bytes = Data()
        var head: String?
        for element in try encoded(ops) {
            let line = OpLogChain.chainedLine(
                elementJSON: element, prev: head ?? OpLogChain.genesis)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: slug, in: projectURL)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// The same stream SEALED by a key the register can name.
    @discardableResult
    private func writeSealedStream(by identity: DeviceIdentity, ops: [Op]) throws -> URL {
        var bytes = Data()
        var head: String?
        for element in try encoded(ops) {
            let line = OpLogChain.chainedLine(
                elementJSON: element, prev: head ?? OpLogChain.genesis)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        let seal = try OpLogChain.Seal.line(
            head: try XCTUnwrap(head), identity: identity,
            at: Date(timeIntervalSince1970: 40))
        bytes.append(seal)
        bytes.append(0x0A)
        let url = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// The legacy unsuffixed `<docId>.jsonl` — unchained, unsealed, and
    /// belonging to no device in particular (ADR 0012 predates it).
    @discardableResult
    private func writeLegacyFile(ops: [Op]) throws -> URL {
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

    private func lastLineHash(of url: URL) throws -> String {
        let lines = try Data(contentsOf: url)
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { Data($0) }
        return OpLogChain.lineHash(try XCTUnwrap(lines.last))
    }

    private var ghost: DeviceSlug { DeviceSlug.unsafeForTesting("ghostmac") }

    // MARK: - The field is invisible until something narrows

    /// **A P3a-era event's signed bytes are untouched.**
    ///
    /// The digest a signature is made over is `RegistryCanonical`'s of the
    /// FILE's own object with `"sig"` removed, so a field that appears in the
    /// encoding would change the digest of every event ever written and no
    /// record from before this build would verify again. A synthesized encoder
    /// writes an absent optional with `encodeIfPresent`; this pins that it
    /// does.
    func test_anEventWithNoSnapshotEncodesExactlyAsItDidBeforeTheField() throws {
        let event = PermitEvent(
            event: "abc.01JABCDEFGHJKMNPQRSTVWXYZ", kind: .admitted,
            subject: "abc", role: Permit.authorRole, scope: Permit.bookScope,
            pieces: [], mark: [:],
            at: Date(timeIntervalSince1970: 10), by: "root")
        let bytes = try RegistryCanonical.bytes(of: event)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bytes) as? [String: Any])

        XCTAssertNil(object["unsigned"], "an absent optional writes no key")
        XCTAssertEqual(
            Set(object.keys),
            ["at", "by", "event", "kind", "mark", "pieces", "role", "scope", "subject"],
            "the P3a key set, exactly")

        // The digest the signature is made over, against the same object
        // spelled by hand as a build that never heard of `unsigned` would
        // spell it.
        let p3a = try JSONSerialization.data(
            withJSONObject: [
                "at": try RegistryCanonical.dateString(
                    Date(timeIntervalSince1970: 10)),
                "by": "root",
                "event": "abc.01JABCDEFGHJKMNPQRSTVWXYZ", "kind": "admitted",
                "mark": [String: Any](), "pieces": [String](),
                "role": "author", "scope": "book", "subject": "abc",
            ],
            options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertEqual(
            try RegistryCanonical.digestHex(ofJSON: bytes),
            try RegistryCanonical.digestHex(ofJSON: p3a))
    }

    /// A file written by a build that never heard of the field decodes with
    /// `unsigned == nil`, which `UnsignedSnapshot` reads as an EMPTY snapshot:
    /// everything unattributable is *after*. Tripwire 11 — do not migrate.
    func test_aNarrowedBookWhoseGoverningEventHasNoSnapshotReadsAsEmpty() throws {
        let event = PermitEvent(
            event: "abc.01JABCDEFGHJKMNPQRSTVWXYZ", kind: .roleChanged,
            subject: "abc", role: Permit.reviewerRole, scope: Permit.bookScope,
            pieces: [], mark: [:],
            at: Date(timeIntervalSince1970: 10), by: "root")
        XCTAssertNil(event.unsigned)
        let snapshot = try XCTUnwrap(UnsignedSnapshot.governing(events: [event]))
        XCTAssertTrue(snapshot.mark.isEmpty)
        XCTAssertEqual(
            snapshot.side(
                streamKey: "d-one.ghostmac", fileIsSegmentWithDigest: nil,
                lines: [Data("a".utf8)]),
            .allNew(count: 1))
    }

    /// **A book-author admission narrows nothing**: no field on the event, and
    /// — the half that costs something — not one extra directory listing.
    func test_anOrdinaryAdmissionWritesNoSnapshotAndSweepsNothing() async throws {
        try becomeRoot()
        try writeUnsealedStream(slug: ghost, ops: [op("o1", device: "ghost")])

        try admitSam()

        let event = try XCTUnwrap(try events(about: sam.author.fingerprint).last)
        XCTAssertEqual(event.kind, .admitted)
        XCTAssertNil(event.unsigned, "an admission changes nothing about who may write what")

        let raw = try Data(contentsOf: RegistryWriter.url(
            .events, fingerprint: event.event, in: projectURL))
        XCTAssertFalse(
            String(decoding: raw, as: UTF8.self).contains("unsigned"),
            "and the bytes say so")
    }

    // MARK: - The sweep

    /// The three shapes the photograph has to cover, and the two it must not.
    func test_theSweepNamesEveryUnattributableStreamAndNobodyElses() throws {
        try becomeRoot()
        try admitSam()

        let legacy = try writeLegacyFile(ops: [op("o1", device: "old")])
        let unsigned = try writeUnsealedStream(
            slug: ghost, ops: [op("o2", device: "ghost")])
        // Attributable, both ways a file can be: sealed by a key the register
        // names, and named by a slug the register can join to a key.
        let sealed = try writeSealedStream(
            by: sam.author, ops: [op("o3", device: sam.author.deviceId)])
        let mineUnsealed = try writeUnsealedStream(
            slug: mine.author.slug, ops: [op("o4", device: mine.author.deviceId)])

        let mark = try OpLogStore.unattributablePositions(
            in: projectURL, trust: try table())

        XCTAssertEqual(
            Set(mark.streams.keys), [docId, "\(docId).ghostmac"],
            "the legacy file under its bare docId, the ghost under its slug")
        XCTAssertEqual(mark[docId]?.line, try lastLineHash(of: legacy))
        XCTAssertEqual(
            mark["\(docId).ghostmac"]?.line, try lastLineHash(of: unsigned))
        XCTAssertNil(
            mark[try XCTUnwrap(PermitMark.streamKey(of: sealed))],
            "a seal the register can name is not the unsigned door")
        XCTAssertNil(
            mark[try XCTUnwrap(PermitMark.streamKey(of: mineUnsealed))],
            "and neither is a slug it can join to a key")
    }

    /// **A book with no op log at all photographs nothing**, and answers so
    /// without refusing.
    ///
    /// This is the premise every registry-only fixture in this package rests
    /// on: a suite that narrows a book it wrote no history into passes
    /// `.nothingApplied` because that is what a sweep of it would return, not
    /// because the value is convenient.
    func test_aBookWithNoHistoryPhotographsNothing() throws {
        try becomeRoot()
        try admitSam()
        XCTAssertEqual(
            try OpLogStore.unattributablePositions(in: projectURL, trust: try table()),
            .nothingApplied)
    }

    /// **A short snapshot is the reach-back this ruling exists to prevent**, so
    /// a folder that exists and will not list refuses the sweep rather than
    /// answering with what it happened to see.
    func test_anUnreadableStreamFolderRefusesTheSweep() throws {
        try becomeRoot()
        try admitSam()
        try writeUnsealedStream(slug: ghost, ops: [op("o1", device: "ghost")])

        let translations = projectURL.appendingPathComponent(".maugham/translations")
        try FileManager.default.createDirectory(
            at: translations, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: translations.path)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: translations.path)

        XCTAssertThrowsError(
            try OpLogStore.unattributablePositions(in: projectURL, trust: try table())
        ) { error in
            guard case OpLogStore.ReadError.unlistableStreamDirectory = error else {
                return XCTFail("expected the sweep's own refusal, got \(error)")
            }
        }
    }

    // MARK: - The verbs

    /// A narrowing `changePermit` writes the photograph, and it covers all
    /// three unattributable shapes.
    func test_aNarrowingChangeWritesTheSnapshotOverEveryUnsignedStream() throws {
        try becomeRoot()
        try admitSam()
        let legacy = try writeLegacyFile(ops: [op("o1", device: "old")])
        let unsigned = try writeUnsealedStream(
            slug: ghost, ops: [op("o2", device: "ghost")])

        let swept = try OpLogStore.unattributablePositions(
            in: projectURL, trust: try table())
        try changeSam(to: .reviewer, unsigned: swept)

        let event = try XCTUnwrap(try events(about: sam.author.fingerprint).last)
        XCTAssertEqual(event.kind, .roleChanged)
        let written = try XCTUnwrap(event.unsigned)
        XCTAssertEqual(Set(written.keys), [docId, "\(docId).ghostmac"])
        XCTAssertEqual(written[docId]?.line, try lastLineHash(of: legacy))
        XCTAssertEqual(written["\(docId).ghostmac"]?.line, try lastLineHash(of: unsigned))
    }

    /// The same, admitting a stranger straight in as a reviewer: letting
    /// somebody in below the top rung narrows the book exactly as a demotion
    /// does.
    func test_aNarrowingAdmissionWritesTheSnapshotToo() throws {
        try becomeRoot()
        let unsigned = try writeUnsealedStream(
            slug: ghost, ops: [op("o1", device: "ghost")])

        let swept = try OpLogStore.unattributablePositions(
            in: projectURL, trust: try table())
        try admitSam(permit: .reviewer, unsigned: swept)

        let event = try XCTUnwrap(try events(about: sam.author.fingerprint).last)
        XCTAssertEqual(event.kind, .admitted)
        XCTAssertEqual(
            try XCTUnwrap(event.unsigned)["\(docId).ghostmac"]?.line,
            try lastLineHash(of: unsigned))
    }

    /// **The door.** A narrowing permit with no photograph is refused, and
    /// nothing is written — no event, no re-signed record.
    func test_aNarrowingWithNoSnapshotIsRefusedAndWritesNothing() throws {
        try becomeRoot()
        try admitSam()
        let before = try events(about: sam.author.fingerprint)

        XCTAssertThrowsError(try changeSam(to: .reviewer)) { error in
            XCTAssertEqual(
                error as? RegistryAdmissionError,
                .narrowingWithoutASnapshot(fingerprint: sam.author.fingerprint))
        }
        XCTAssertEqual(
            try events(about: sam.author.fingerprint).map(\.event),
            before.map(\.event),
            "no event")
        XCTAssertEqual(
            try registry().person(sam.author.fingerprint)?.role, Permit.authorRole,
            "and no re-signed record")
    }

    /// The other direction, so the door cannot be a blanket refusal: a
    /// book-author change needs no photograph and is not refused.
    func test_aChangeThatNarrowsNothingNeedsNoSnapshot() throws {
        try becomeRoot()
        try admitSam(permit: .reviewer, unsigned: .nothingApplied)

        XCTAssertNoThrow(try changeSam(to: .bookAuthor))
        XCTAssertEqual(
            try registry().person(sam.author.fingerprint)?.role, Permit.authorRole)
    }

    // MARK: - Which snapshot governs

    /// **The EARLIEST narrowing event governs.** A second narrowing must not
    /// move the cliff: forward it applies lines that had been held, backward it
    /// withdraws lines that had been applied.
    func test_theEarliestNarrowingGovernsAndALaterOneDoesNotSupersedeIt() throws {
        let first = PermitEvent(
            event: "aaa.01JAAAAAAAAAAAAAAAAAAAAAAA", kind: .roleChanged,
            subject: "aaa", role: Permit.reviewerRole, scope: Permit.bookScope,
            pieces: [], mark: [:], unsigned: ["s": .init(line: "first")],
            at: Date(timeIntervalSince1970: 10), by: "root")
        let later = PermitEvent(
            event: "aaa.01JZZZZZZZZZZZZZZZZZZZZZZZ", kind: .scopeChanged,
            subject: "aaa", role: Permit.authorRole, scope: Permit.piecesScope,
            pieces: ["d-one"], mark: [:], unsigned: ["s": .init(line: "later")],
            at: Date(timeIntervalSince1970: 20), by: "root")

        let snapshot = try XCTUnwrap(
            UnsignedSnapshot.governing(events: [later, first]))
        XCTAssertEqual(snapshot.event, first.event)
        XCTAssertEqual(snapshot.mark["s"]?.line, "first")
    }

    /// **Earliest means earliest IN TIME**, and here the two orders disagree
    /// (fix round 1, the controller's ruling).
    ///
    /// The shape two roots that adopted each other produce: neither's events
    /// are the other's, and an event id is `<subject>.<ULID>`, so ordering by
    /// id alone sorts by whichever PERSON FINGERPRINT is lower — which is not
    /// *earliest* in any sense the writer would recognise. `aaa…` sorts first
    /// and happened second; the one that happened FIRST governs.
    func test_theEarliestGovernsByDateEvenWhereTheIdOrderDisagrees() throws {
        let second = PermitEvent(
            event: "aaa.01JAAAAAAAAAAAAAAAAAAAAAAA", kind: .roleChanged,
            subject: "aaa", role: Permit.reviewerRole, scope: Permit.bookScope,
            pieces: [], mark: [:], unsigned: ["s": .init(line: "aaa")],
            at: Date(timeIntervalSince1970: 10), by: "rootA")
        let first = PermitEvent(
            event: "bbb.01JAAAAAAAAAAAAAAAAAAAAAAA", kind: .roleChanged,
            subject: "bbb", role: Permit.reviewerRole, scope: Permit.bookScope,
            pieces: [], mark: [:], unsigned: ["s": .init(line: "bbb")],
            at: Date(timeIntervalSince1970: 5), by: "rootB")
        XCTAssertLessThan(
            second.event, first.event, "the id order is the other way round")

        let snapshot = try XCTUnwrap(
            UnsignedSnapshot.governing(events: [second, first]))
        XCTAssertEqual(snapshot.event, first.event)
        XCTAssertEqual(snapshot.mark["s"]?.line, "bbb")
        XCTAssertEqual(
            UnsignedSnapshot.governing(events: [first, second])?.event,
            snapshot.event,
            "and the listing order cannot change it")
    }

    /// **The other direction: the id is the tie-break, so two Macs still agree
    /// from the same bytes.** Two narrowings in one millisecond are ordered by
    /// the id, which is unique — `at` alone would leave the answer to whatever
    /// order the folder was listed in.
    func test_twoNarrowingsInOneMomentAreOrderedByTheirIds() throws {
        let moment = Date(timeIntervalSince1970: 7)
        let lower = PermitEvent(
            event: "aaa.01JAAAAAAAAAAAAAAAAAAAAAAA", kind: .roleChanged,
            subject: "aaa", role: Permit.reviewerRole, scope: Permit.bookScope,
            pieces: [], mark: [:], unsigned: ["s": .init(line: "aaa")],
            at: moment, by: "rootA")
        let higher = PermitEvent(
            event: "bbb.01JAAAAAAAAAAAAAAAAAAAAAAA", kind: .roleChanged,
            subject: "bbb", role: Permit.reviewerRole, scope: Permit.bookScope,
            pieces: [], mark: [:], unsigned: ["s": .init(line: "bbb")],
            at: moment, by: "rootB")

        for listing in [[lower, higher], [higher, lower]] {
            XCTAssertEqual(
                UnsignedSnapshot.governing(events: listing)?.event, lower.event,
                "the same answer whatever order the folder was read in")
        }
    }

    /// A non-narrowing event is never a candidate, however narrow the role it
    /// carries: a revocation installs no permit at all.
    func test_aRevocationIsNeverTheGoverningEvent() throws {
        let revocation = PermitEvent(
            event: "aaa.01JAAAAAAAAAAAAAAAAAAAAAAA", kind: .revoked,
            subject: "aaa", role: Permit.reviewerRole, scope: Permit.bookScope,
            pieces: [], mark: [:], unsigned: ["s": .init(line: "revocation")],
            at: Date(timeIntervalSince1970: 10), by: "root")
        XCTAssertFalse(PermitTimeline.narrows(revocation))
        XCTAssertNil(UnsignedSnapshot.governing(events: [revocation]))
    }

    // MARK: - The table

    /// **Nil exactly when nothing narrows.** Both are derived from the one
    /// root-filtered collection of events, and a book narrowed according to one
    /// and un-narrowed according to the other holds every unsigned line ever
    /// written in it.
    func test_theTableCarriesASnapshotExactlyWhenTheBookIsNarrowed() throws {
        try becomeRoot()
        try admitSam()

        XCTAssertFalse(try table().hasNarrowingPermits)
        XCTAssertNil(try table().unsignedSnapshot)

        try writeUnsealedStream(slug: ghost, ops: [op("o1", device: "ghost")])
        let swept = try OpLogStore.unattributablePositions(
            in: projectURL, trust: try table())
        try changeSam(to: .reviewer, unsigned: swept)

        let after = try table()
        XCTAssertTrue(after.hasNarrowingPermits)
        let snapshot = try XCTUnwrap(after.unsignedSnapshot)
        XCTAssertEqual(
            snapshot.event,
            try XCTUnwrap(try events(about: sam.author.fingerprint).last).event)
        XCTAssertEqual(Set(snapshot.mark.streams.keys), ["\(docId).ghostmac"])
    }

    /// The equivalence the table rests on, asked of the permit layer directly:
    /// a person's timeline narrows exactly when one of their events does.
    func test_aTimelineNarrowsExactlyWhenOneOfItsEventsDoes() throws {
        func timeline(_ events: [PermitEvent]) -> PermitTimeline {
            PermitTimeline(events: events)
        }
        func event(
            _ id: String, _ kind: PermitEvent.Kind, _ permit: Permit
        ) -> PermitEvent {
            PermitEvent(
                event: "aaa.\(id)", kind: kind, subject: "aaa",
                role: permit.wireRole, scope: permit.wireScope,
                pieces: permit.wirePieces, mark: [:],
                at: Date(timeIntervalSince1970: 1), by: "root")
        }
        let cases: [[PermitEvent]] = [
            [],
            [event("01JA", .admitted, .bookAuthor)],
            [event("01JA", .admitted, .reviewer)],
            [event("01JA", .admitted, .bookAuthor),
             event("01JB", .roleChanged, .reviewer)],
            [event("01JA", .admitted, .bookAuthor),
             event("01JB", .roleChanged, .reviewer),
             event("01JC", .roleChanged, .bookAuthor)],
            [event("01JA", .admitted, .bookAuthor),
             event("01JB", .revoked, .reviewer)],
            [event("01JA", .unknown("sideways"), .bookAuthor)],
        ]
        for events in cases {
            XCTAssertEqual(
                timeline(events).narrows,
                events.contains { PermitTimeline.narrows($0) },
                "for \(events.map(\.event))")
        }
    }

    // MARK: - Only a root of MY chain narrows MY book (Task 2, ruling A)

    /// A second self-signed root this device has nothing to do with — a
    /// CLAIMANT, in P2b's vocabulary, whose every seal this table answers
    /// `.otherRoot` about.
    private func writeClaimantRoot(_ who: LocalIdentities) throws {
        try RegistryWriter.write(
            PersonRecord(
                person: who.author.fingerprint, label: "Somebody",
                ownName: "Somebody's Mac",
                admittedAt: Date(timeIntervalSince1970: 3),
                admittedBy: who.author.fingerprint),
            signedBy: who.author, in: projectURL)
    }

    /// The one event `RegistryReader.entitled` lets any root in the folder
    /// write: a narrowing about a subject this registry holds NO person record
    /// for, which is the spec's own write-order crash window.
    @discardableResult
    private func claimantNarrowing(
        by who: LocalIdentities, subject: String,
        at when: Date = Date(timeIntervalSince1970: 0)
    ) throws -> PermitEvent {
        let event = PermitEvent(
            event: "\(subject).01JAAAAAAAAAAAAAAAAAAAAAAA", kind: .roleChanged,
            subject: subject, role: Permit.reviewerRole,
            scope: Permit.bookScope, pieces: [], mark: [:], unsigned: [:],
            at: when, by: who.author.fingerprint)
        try RegistryWriter.write(event, signedBy: who.author, in: projectURL)
        return event
    }

    /// **A claimant's narrowing narrows nothing here** (Task 1's review,
    /// Important 1).
    ///
    /// Left unfiltered, one event signed by a root this device refuses as
    /// `.otherRoot`, about a fingerprint nobody here has a record for, would
    /// build a timeline, count in `hasNarrowingPermits` and — dated 1970 and
    /// carrying an EMPTY snapshot — become the GOVERNING photograph, which
    /// holds every unsigned Mac's whole history in a book that never trusted
    /// the device that said so.
    func test_aClaimantRootsNarrowingIsNotHeardInThisBook() throws {
        try becomeRoot()
        let claimant = LocalIdentities.softwareForTesting()
        try writeClaimantRoot(claimant)
        let stranger = LocalIdentities.softwareForTesting().author.fingerprint
        try claimantNarrowing(by: claimant, subject: stranger)

        let judged = try table()
        XCTAssertNotNil(
            try registry().events.first { $0.subject == stranger },
            "the reader admits the record — it is the TABLE that must not hear it")
        XCTAssertFalse(
            judged.hasNarrowingPermits,
            "a root this device is not on cannot narrow this book")
        XCTAssertNil(judged.unsignedSnapshot, "and photographs nothing")
        XCTAssertEqual(
            judged.timeline(forPerson: stranger).current, .bookAuthor,
            "the timeline is the default it would have been with no event at all")
    }

    /// Its other direction: the moment MY root ADOPTS that root, its events are
    /// heard — which is what makes the two-roots exit work at all.
    func test_adoptingThatRootMakesItsNarrowingCountFromTheSameBytes() throws {
        try becomeRoot()
        let claimant = LocalIdentities.softwareForTesting()
        try writeClaimantRoot(claimant)
        let stranger = LocalIdentities.softwareForTesting().author.fingerprint
        let event = try claimantNarrowing(by: claimant, subject: stranger)

        XCTAssertFalse(try table().hasNarrowingPermits)

        try RegistryWriter.write(
            ClaimRecord(
                newRoot: mine.author.fingerprint,
                adopted: [claimant.author.fingerprint],
                claimedAt: Date(timeIntervalSince1970: 60)),
            signedBy: mine.author, in: projectURL)

        let judged = try table()
        XCTAssertTrue(
            judged.adoptedRoots.contains(claimant.author.fingerprint))
        XCTAssertTrue(judged.hasNarrowingPermits, "now it is my chain's word")
        XCTAssertEqual(judged.unsignedSnapshot?.event, event.event)
        XCTAssertEqual(judged.timeline(forPerson: stranger).current, .reviewer)
    }

    /// **The equivalence survives the filter**, which is the half that fails
    /// silently and in the worst direction: a book that counts as narrowed
    /// while no event names a governing photograph holds every unsigned line
    /// ever written in it.
    func test_theFilteredPopulationKeepsTheNilIffNotNarrowedEquivalence() throws {
        try becomeRoot()
        let claimant = LocalIdentities.softwareForTesting()
        try writeClaimantRoot(claimant)
        let stranger = LocalIdentities.softwareForTesting().author.fingerprint
        try claimantNarrowing(by: claimant, subject: stranger)

        let before = try table()
        XCTAssertEqual(before.unsignedSnapshot == nil, !before.hasNarrowingPermits)

        try admitSam(permit: .reviewer, unsigned: .nothingApplied)
        let after = try table()
        XCTAssertEqual(after.unsignedSnapshot == nil, !after.hasNarrowingPermits)
        XCTAssertTrue(after.hasNarrowingPermits, "my own root's narrowing IS heard")
        XCTAssertEqual(
            after.unsignedSnapshot?.event,
            try events(about: sam.author.fingerprint).last?.event,
            "and it governs, because the claimant's is not in the population")
    }

    /// A retirement keeps `RegistryReader.entitled`'s own rule — the device's
    /// word about itself, signed by the subject rather than by a root — and it
    /// installs no permit, so it narrows nothing whoever this device is on a
    /// chain with.
    ///
    /// **What this can and cannot see.** `PermitTimeline.init` installs no
    /// entry for a retirement (`installedPermit` answers nil: it is the
    /// VERDICT's business, and `retiredAtByDevice` is read off the DEVICE
    /// record), so the signer carve-out has no observable effect on the table
    /// today. It is written as a contract rather than as behaviour: the filter
    /// must not turn a self-signed retirement into something only a root can
    /// say, because the day a reader gives retirement a timeline entry the
    /// difference would be a device that could never be retired at all.
    func test_aSelfSignedRetirementIsStillHeardAndNarrowsNothing() throws {
        try becomeRoot()
        let elsewhere = LocalIdentities.softwareForTesting()
        try RegistryWriter.write(
            PermitEvent(
                event: "\(elsewhere.author.fingerprint).01JBBBBBBBBBBBBBBBBBBBBBBB",
                kind: .retired, subject: elsewhere.author.fingerprint,
                role: Permit.reviewerRole, scope: Permit.bookScope,
                pieces: [], mark: [:],
                at: Date(timeIntervalSince1970: 70),
                by: elsewhere.author.fingerprint),
            signedBy: elsewhere.author, in: projectURL)

        XCTAssertNotNil(
            try registry().events.first {
                $0.subject == elsewhere.author.fingerprint
            },
            "the reader accepts a self-signed retirement from anybody")
        let judged = try table()
        XCTAssertFalse(judged.hasNarrowingPermits, "a retirement installs no permit")
        XCTAssertNil(judged.unsignedSnapshot)
        XCTAssertEqual(
            judged.timeline(forPerson: elsewhere.author.fingerprint)
                .entries.compactMap(\.kind), [],
            "and installs no timeline entry — see the note above")
    }

    // MARK: - The stream that went missing (Task 2, ruling B)

    /// **A remembered unsigned stream that is gone refuses the act** (Task 1's
    /// review, Important 2).
    ///
    /// `unattributablePositions` took no `expecting:`, so a stream evicted by
    /// iCloud or caught halfway through a sync was simply absent — and a stream
    /// the snapshot does not NAME judges wholly new, which holds the whole
    /// applied history of the very Mac this photograph exists to leave alone.
    /// The memory `ForeignStreamWatch` keeps is keyed by STREAM and does
    /// remember an unsigned device's, so it is asked here through the same
    /// predicate `seenPositions` asks.
    func test_aRememberedUnsignedStreamThatIsGoneRefusesTheSnapshot() throws {
        try becomeRoot()
        let url = try writeUnsealedStream(
            slug: ghost, ops: [op("o1", device: "ghost")])
        let key = try XCTUnwrap(PermitMark.streamKey(of: url))
        let remembered = [key: OpLogDeviceState.ForeignStreamMemory(
            deviceSlug: ghost.raw,
            head: try lastLineHash(of: url), segmentDigests: [])]

        // Present: the sweep answers, and names the stream.
        let mark = try OpLogStore.unattributablePositions(
            in: projectURL, trust: try table(), expecting: remembered)
        XCTAssertEqual(mark[key]?.line, try lastLineHash(of: url))

        try FileManager.default.removeItem(at: url)
        do {
            _ = try OpLogStore.unattributablePositions(
                in: projectURL, trust: try table(), expecting: remembered)
            XCTFail("a stream this Mac had applied from is gone")
        } catch let error as OpLogStore.ReadError {
            guard case .streamMissingFromSweep(let missing) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(missing, key)
            XCTAssertEqual(OpLogStore.unreadableName(error), key)
        }
    }

    /// And the verb refuses in its own words, with NOTHING written: no event,
    /// no record, no remembered label.
    func test_aNarrowingOverAMissingUnsignedStreamWritesNothing() throws {
        try becomeRoot()
        try admitSam()
        let url = try writeUnsealedStream(
            slug: ghost, ops: [op("o1", device: "ghost")])
        let key = try XCTUnwrap(PermitMark.streamKey(of: url))
        let remembered = [key: OpLogDeviceState.ForeignStreamMemory(
            deviceSlug: ghost.raw,
            head: try lastLineHash(of: url), segmentDigests: [])]
        try FileManager.default.removeItem(at: url)

        let before = try events(about: sam.author.fingerprint).map(\.event)
        XCTAssertThrowsError(
            try OpLogStore.unattributablePositions(
                in: projectURL, trust: try table(), expecting: remembered))
        XCTAssertEqual(
            try events(about: sam.author.fingerprint).map(\.event), before,
            "the sweep refused, so the verb was never reached and nothing moved")
        XCTAssertEqual(
            try registry().person(sam.author.fingerprint)?.role,
            Permit.authorRole)
    }

    /// The other direction, and the one that must not become a standing
    /// refusal: a stream this Mac has never applied from is not expected at
    /// all, and a stream that merely GREW is not a loss.
    func test_anUnrememberedOrGrownStreamDoesNotRefuseTheSnapshot() throws {
        try becomeRoot()
        let url = try writeUnsealedStream(
            slug: ghost, ops: [op("o1", device: "ghost")])
        let key = try XCTUnwrap(PermitMark.streamKey(of: url))
        let firstLine = try lastLineHash(of: url)

        // Never seen: nothing is expected of it.
        XCTAssertNoThrow(
            try OpLogStore.unattributablePositions(
                in: projectURL, trust: try table(), expecting: [:]))

        // Grown: the remembered line is still in the file, further back.
        try writeUnsealedStream(
            slug: ghost,
            ops: [op("o1", device: "ghost"), op("o2", device: "ghost")])
        let remembered = [key: OpLogDeviceState.ForeignStreamMemory(
            deviceSlug: ghost.raw, head: firstLine, segmentDigests: [])]
        let mark = try OpLogStore.unattributablePositions(
            in: projectURL, trust: try table(), expecting: remembered)
        XCTAssertEqual(mark[key]?.line, try lastLineHash(of: url),
                       "and the photograph names where it stands NOW")
    }
}
