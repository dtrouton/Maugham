import CryptoKit
import Foundation
import XCTest
@testable import MaughamCore

/// **The fourth record kind: the book's history of who could write what**
/// (P3a Task 1, spec §3.1–§3.2).
///
/// Three things are pinned here and each fails silently if it is wrong.
///
/// **The authority.** An event is what a later reader will judge somebody's
/// lines by, so a well-formed, correctly-signed event from the wrong key is
/// the most dangerous file in the registry: anybody who can write the folder
/// could mint a key, sign *she is an author of the whole book*, and have every
/// device apply what she wrote. Entitlement is one of two things — a root of
/// the chain the subject is on, or, for a retirement, the subject itself — and
/// everything else is LISTED (RULING-54: listed, never thrown over, never
/// silently dropped).
///
/// **The bytes P2 wrote.** `scope` and `pieces` are new on `PersonRecord` and
/// are absent while nil, so a record written before P3 hashes to exactly what
/// it hashed to then. If they were not, every P2-era record on shared storage
/// would stop verifying the moment one device upgraded — a silent, permanent
/// un-admission, and the exact failure the canonical form exists to forbid.
///
/// **Behaviour-neutral for every existing book.** No events means every
/// admitted person is author, book, from the start; a P2 folder reads an empty
/// history and nothing else moves.
final class PermitEventTests: XCTestCase {

    private var projectURL: URL!
    private var cacheURL: URL!
    /// The root: the Mac this book was started on.
    private var root: DeviceIdentity!
    /// Somebody the root admitted — the subject of most events here.
    private var sam: DeviceIdentity!
    /// A key in nobody's chain.
    private var outsider: DeviceIdentity!
    /// A second root, with a chain of its own.
    private var otherRoot: DeviceIdentity!
    /// Somebody on THAT root's chain.
    private var tina: DeviceIdentity!

    override func setUp() {
        super.setUp()
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("permit-event-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("permit-event-cache-\(UUID().uuidString).json")
        root = .softwareForTesting()
        sam = .softwareForTesting()
        outsider = .softwareForTesting()
        otherRoot = .softwareForTesting()
        tina = .softwareForTesting()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// `identity` admits itself: the self-signed record that makes it a root.
    private func writeRoot(_ identity: DeviceIdentity, label: String = "Denver") throws {
        try RegistryWriter.write(
            PersonRecord(
                person: identity.fingerprint, label: label,
                ownName: "\(label)’s MacBook",
                admittedAt: Date(timeIntervalSince1970: 10),
                admittedBy: identity.fingerprint),
            signedBy: identity, in: projectURL)
    }

    /// `identity` admitted under `rootIdentity`'s chain.
    private func writeAdmitted(
        _ identity: DeviceIdentity, under rootIdentity: DeviceIdentity,
        label: String = "Sam"
    ) throws {
        try RegistryWriter.write(
            PersonRecord(
                person: identity.fingerprint, label: label,
                ownName: "\(label)’s Mac",
                admittedAt: Date(timeIntervalSince1970: 20),
                admittedBy: rootIdentity.fingerprint),
            signedBy: rootIdentity, in: projectURL)
    }

    /// The book as it stands after P2: a root and one admitted person.
    private func writeChain() throws {
        try writeRoot(root)
        try writeAdmitted(sam, under: root)
    }

    private func event(
        kind: PermitEvent.Kind = .scopeChanged,
        subject: DeviceIdentity? = nil,
        by: DeviceIdentity? = nil,
        role: String = "author",
        scope: String = "pieces",
        pieces: [String] = ["d-chapter-4"],
        mark: [String: PermitEvent.StreamMark] = [:],
        id: String? = nil
    ) -> PermitEvent {
        let subjectKey = (subject ?? sam!).fingerprint
        return PermitEvent(
            event: id ?? PermitEvent.mintID(subject: subjectKey),
            kind: kind, subject: subjectKey,
            role: role, scope: scope, pieces: pieces, mark: mark,
            at: Date(timeIntervalSince1970: 30),
            by: (by ?? root!).fingerprint)
    }

    @discardableResult
    private func write(_ record: PermitEvent, signedBy identity: DeviceIdentity) throws -> URL {
        try RegistryWriter.writeUnchecked(record, signedBy: identity, in: projectURL)
    }

    private func makeCache() -> RegistryCache {
        RegistryCache(fileURL: cacheURL, identity: root.fingerprint)
    }

    // MARK: - Where it lives

    /// The path is spelled in `RegistryWriter.directoryURL` and asked for
    /// everywhere else (tripwire 40). This is the one assertion about it.
    func test_anEventLivesUnderPeopleSlashEvents() {
        XCTAssertEqual(
            RegistryWriter.directoryURL(.events, in: projectURL).path,
            projectURL.appendingPathComponent(".maugham/people/events").path)
        XCTAssertEqual(
            RegistryWriter.url(.events, fingerprint: "abcd.01ABC", in: projectURL)
                .lastPathComponent,
            "abcd.01ABC.json")
    }

    /// A subject's events sort together and in order, which is the whole reason
    /// the id is two parts rather than one.
    func test_anEventIdIsItsSubjectAndAMonotonicId() {
        let first = PermitEvent.mintID(subject: "aaaa")
        let second = PermitEvent.mintID(subject: "aaaa")
        XCTAssertTrue(first.hasPrefix("aaaa."))
        XCTAssertLessThan(first, second, "ULIDs are monotonic within the process")
        XCTAssertEqual(PermitEvent.subject(ofID: first), "aaaa")
        XCTAssertNil(PermitEvent.subject(ofID: "nodothere"))
    }

    // MARK: - Round trip

    func test_anEventSurvivesTheTripThroughDisk() throws {
        try writeChain()
        let written = event(
            kind: .scopeChanged,
            mark: [
                "d-chapter-4.mac-a": .init(
                    segments: ["seg-one-digest", "seg-two-digest"], line: "linehash-9"),
                "__project__.mac-a": .init(segments: [], line: nil),
            ])
        let url = try write(written, signedBy: root)
        XCTAssertEqual(url.lastPathComponent, "\(written.event).json")

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.malformed, [])
        let read = try XCTUnwrap(registry.events.first)
        XCTAssertEqual(registry.events.count, 1)
        XCTAssertEqual(read.event, written.event)
        XCTAssertEqual(read.kind, .scopeChanged)
        XCTAssertEqual(read.subject, sam.fingerprint)
        XCTAssertEqual(read.role, "author")
        XCTAssertEqual(read.scope, "pieces")
        XCTAssertEqual(read.pieces, ["d-chapter-4"])
        XCTAssertEqual(read.at, written.at)
        XCTAssertEqual(read.by, root.fingerprint)
        XCTAssertEqual(read.sig?.key, root.fingerprint)
        XCTAssertEqual(read.mark["d-chapter-4.mac-a"]?.segments,
                       ["seg-one-digest", "seg-two-digest"])
        XCTAssertEqual(read.mark["d-chapter-4.mac-a"]?.line, "linehash-9")
        XCTAssertEqual(read.mark["__project__.mac-a"]?.segments, [])
        XCTAssertNil(read.mark["__project__.mac-a"]?.line,
                     "a stream with no applied line carries no line, not an empty one")
    }

    /// ADR 0015 in its strictest form: a kind a later build wrote comes back
    /// under its own name. Degrading it would either invalidate a signature
    /// this build is only carrying, or — worse — decide somebody's permit from
    /// a kind nobody wrote.
    func test_aKindALaterBuildWroteComesBackUnderItsOwnName() throws {
        try writeChain()
        let written = event(kind: .unknown("delegatedToTheEditor"))
        try write(written, signedBy: root)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.malformed, [])
        XCTAssertEqual(registry.events.first?.kind, .unknown("delegatedToTheEditor"))

        for kind in PermitEvent.Kind.known {
            XCTAssertEqual(PermitEvent.Kind(rawValue: kind.rawValue), kind,
                           "\(kind.rawValue) round-trips through its raw value")
        }
        XCTAssertEqual(PermitEvent.Kind.known.count, 8)
        XCTAssertFalse(PermitEvent.Kind.known.contains(.unknown("x")))
    }

    /// The signature is made over the FILE's bytes with `sig` removed, so a
    /// field this build has no property for is part of what was signed. An
    /// event from a later build verifies here rather than failing.
    func test_anEventFromALaterBuildStillVerifies() throws {
        try writeChain()
        let url = try write(event(), signedBy: root)
        try addFieldAndResign(at: url, key: "delegatedUntil", value: "2027-01-01", by: root)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.malformed, [],
                       "an unknown field is part of what was signed, not a fault")
        XCTAssertEqual(registry.events.count, 1)
    }

    // MARK: - A book with no events

    /// **Behaviour-neutral.** Every project written before P3 has no events
    /// directory at all, and reading one must cost nothing and say nothing.
    func test_aBookWrittenBeforeP3ReadsAnEmptyHistory() throws {
        try writeChain()
        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.events, [])
        XCTAssertEqual(registry.malformed, [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: RegistryWriter.directoryURL(.events, in: projectURL).path),
            "nothing creates the directory by reading for it")
    }

    // MARK: - The two new person fields

    /// **The bytes a P2 build wrote, pinned as a literal.**
    ///
    /// Not a round trip — a round trip through this build's own encoder would
    /// agree with itself whatever the format did. This is the canonical form a
    /// record written before `scope` and `pieces` existed had, and it is what
    /// every P2-era signature on shared storage was made over.
    func test_aP2EraPersonRecordsBytesAreUnchangedByTheTwoNewFields() throws {
        let p2 = PersonRecord(
            person: "aaaa1111", label: "Denver", ownName: "Denver’s MacBook",
            admittedAt: Date(timeIntervalSince1970: 1_600_000_000),
            admittedBy: "aaaa1111")
        XCTAssertNil(p2.scope)
        XCTAssertNil(p2.pieces)

        let expected = #"""
            {"admittedAt":"2020-09-13T12:26:40.000Z","admittedBy":"aaaa1111","label":"Denver","ownName":"Denver’s MacBook","person":"aaaa1111","role":"author"}
            """#
        XCTAssertEqual(
            String(data: try RegistryCanonical.bytes(of: p2), encoding: .utf8), expected,
            """
            A P2-era person record must encode to exactly the bytes it encoded \
            to before `scope` and `pieces` existed. If this moved, every record \
            on shared storage stops verifying the moment one device upgrades.
            """)

        // And the census is not vacuous: a record that DOES carry them says so.
        let p3 = PersonRecord(
            person: "aaaa1111", label: "Denver", ownName: "Denver’s MacBook",
            scope: "pieces", pieces: ["d-one"],
            admittedAt: Date(timeIntervalSince1970: 1_600_000_000),
            admittedBy: "aaaa1111")
        let p3Bytes = try XCTUnwrap(
            String(data: try RegistryCanonical.bytes(of: p3), encoding: .utf8))
        XCTAssertTrue(p3Bytes.contains("\"scope\":\"pieces\""))
        XCTAssertTrue(p3Bytes.contains("\"pieces\":[\"d-one\"]"))
        XCTAssertNotEqual(p3Bytes, expected)
    }

    /// The two fields survive the trip, and a record without them reads nil —
    /// which is what `"book"` means and what every P2 admission meant.
    func test_scopeAndPiecesSurviveTheTripAndAbsenceReadsAsNil() throws {
        try writeRoot(root)
        try RegistryWriter.write(
            PersonRecord(
                person: sam.fingerprint, label: "Sam", ownName: "Sam’s Mac",
                role: "reviewer", scope: "pieces", pieces: ["d-four", "d-five"],
                admittedAt: Date(timeIntervalSince1970: 20),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.malformed, [])
        let read = try XCTUnwrap(registry.person(sam.fingerprint))
        XCTAssertEqual(read.role, "reviewer")
        XCTAssertEqual(read.scope, "pieces")
        XCTAssertEqual(read.pieces, ["d-four", "d-five"])

        let rootRead = try XCTUnwrap(registry.person(root.fingerprint))
        XCTAssertNil(rootRead.scope, "absent means book; it is never invented")
        XCTAssertNil(rootRead.pieces)
    }

    // MARK: - What the reader refuses

    /// The file was renamed: it no longer carries the id that names it. Listed,
    /// and it contributes no event.
    func test_aRenamedEventIsListedAndContributesNothing() throws {
        try writeChain()
        let url = try write(event(), signedBy: root)
        let moved = url.deletingLastPathComponent()
            .appendingPathComponent("\(sam.fingerprint).01SOMETHINGELSE.json")
        try FileManager.default.moveItem(at: url, to: moved)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.events, [])
        XCTAssertEqual(registry.malformed.count, 1)
        let listed = try XCTUnwrap(registry.malformed.first)
        guard case .filenameMismatch = listed.reason else {
            return XCTFail("expected a filename mismatch, got \(listed.reason)")
        }
    }

    /// Edited after it was signed. The digest is over the file's own bytes, so
    /// changing a word changes the answer.
    func test_anEventEditedAfterItWasSignedIsListed() throws {
        try writeChain()
        let url = try write(event(scope: "pieces"), signedBy: root)
        let tampered = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"scope\":\"pieces\"", with: "\"scope\":\"book\"")
        try tampered.write(to: url, atomically: true, encoding: .utf8)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.events, [])
        XCTAssertEqual(registry.malformed.map(\.reason), [.signatureDoesNotVerify],
                       "a permit promoted by hand is not a permit")
    }

    /// **A key in nobody's chain.** The signature holds; the signer has no
    /// standing. This is the one that matters: an event read from here would
    /// let anybody who can write the folder decide what anybody may write.
    func test_anEventSignedBySomebodyWhoIsNotARootIsListed() throws {
        try writeChain()
        try write(event(by: outsider), signedBy: outsider)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.events, [], "not read, at any cost")
        XCTAssertEqual(registry.malformed.count, 1)
        let listed = try XCTUnwrap(registry.malformed.first)
        guard case .eventSignerHasNoAuthority(let kind, let subject, let signer)
                = listed.reason else {
            return XCTFail("expected no authority, got \(listed.reason)")
        }
        XCTAssertEqual(kind, "scopeChanged")
        XCTAssertEqual(subject, sam.fingerprint)
        XCTAssertEqual(signer, outsider.fingerprint)
        XCTAssertFalse(listed.reason.sentence.isEmpty)
    }

    /// **An ADMITTED device is not a root**, and this is the likelier of the
    /// two: the key verifies, the person is really in this book's chain, and
    /// they are still not the one who decides what anybody may write. A
    /// reviewer who could sign a `roleChanged` about a colleague could sign one
    /// about herself.
    func test_anAdmittedNonRootCannotSignAnEventAboutAnybody() throws {
        try writeChain()
        try writeAdmitted(tina, under: root, label: "Tina")
        try write(
            event(kind: .roleChanged, subject: tina, by: sam, role: "author"),
            signedBy: sam)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.events, [], "admitted is not entitled")
        XCTAssertEqual(registry.malformed.count, 1)
        let listed = try XCTUnwrap(registry.malformed.first)
        guard case .eventSignerHasNoAuthority(let kind, let subject, let signer)
                = listed.reason else {
            return XCTFail("expected no authority, got \(listed.reason)")
        }
        XCTAssertEqual(kind, "roleChanged")
        XCTAssertEqual(subject, tina.fingerprint)
        XCTAssertEqual(signer, sam.fingerprint)
    }

    /// **A real root of this registry, reaching into another root's chain.**
    /// Being a root is not enough; being a root of the chain the subject is on
    /// is the rule, and the difference is a second claimant quietly rewriting
    /// the first one's people.
    func test_aRootOfAnotherChainCannotSpeakForSomebodyElsesPerson() throws {
        try writeChain()
        try writeRoot(otherRoot, label: "Somebody else")
        try write(event(by: otherRoot), signedBy: otherRoot)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.events, [])
        XCTAssertEqual(registry.malformed.count, 1)
        let listed = try XCTUnwrap(registry.malformed.first)
        guard case .eventSignerHasNoAuthority = listed.reason else {
            return XCTFail("expected no authority, got \(listed.reason)")
        }
    }

    /// A retirement is the device's own word about itself. A root retiring
    /// somebody else's Mac would be a way to say *she stopped writing on the
    /// 4th* about a Mac that did not.
    func test_aRetirementSignedBySomebodyElseIsListed() throws {
        try writeChain()
        try write(event(kind: .retired, by: root), signedBy: root)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.events, [])
        XCTAssertEqual(registry.malformed.count, 1)
        let listed = try XCTUnwrap(registry.malformed.first)
        guard case .eventSignerHasNoAuthority(let kind, _, let signer)
                = listed.reason else {
            return XCTFail("expected no authority, got \(listed.reason)")
        }
        XCTAssertEqual(kind, "retired")
        XCTAssertEqual(signer, root.fingerprint, "even the root")
    }

    /// The converse, so the rule above is a rule and not a ban: the device's
    /// own retirement is read.
    func test_aDeviceRetiresItselfAndTheEventIsRead() throws {
        try writeChain()
        try write(event(kind: .retired, by: sam), signedBy: sam)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.malformed, [])
        XCTAssertEqual(registry.events.count, 1)
        XCTAssertEqual(registry.events[0].kind, .retired)
    }

    /// The write order the spec fixes — the event, then the record — leaves a
    /// window in which an admission's event exists and its person record does
    /// not. A root's word stands there; refusing it would turn a one-step gap
    /// into a permanent hole in the history.
    func test_anAdmissionEventThatArrivedBeforeItsRecordIsRead() throws {
        try writeRoot(root)
        try write(event(kind: .admitted, scope: "book", pieces: []), signedBy: root)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.malformed, [])
        XCTAssertEqual(registry.events.count, 1)
        XCTAssertNil(registry.person(sam.fingerprint),
                     "the record is the thing that is one step behind")
    }

    /// One bad event must not cost the book its history: the others are read.
    func test_oneRefusedEventDoesNotTakeTheRestWithIt() throws {
        try writeChain()
        let good = event(kind: .roleChanged, role: "reviewer")
        try write(good, signedBy: root)
        try write(event(by: outsider), signedBy: outsider)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.events.map(\.event), [good.event])
        XCTAssertEqual(registry.malformed.count, 1)
    }

    /// RULING-54: a record that is PRESENT and cannot be READ stops the read
    /// rather than shrinking the registry in silence.
    func test_anUnreadableEventsDirectoryThrowsByName() throws {
        try writeChain()
        try write(event(), signedBy: root)
        let dir = RegistryWriter.directoryURL(.events, in: projectURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }

        XCTAssertThrowsError(try RegistryReader.load(projectURL: projectURL)) { error in
            guard case OpLogStore.ReadError.unreadableFile(_, _, let kind) = error else {
                return XCTFail("expected an unreadable-file error, got \(error)")
            }
            XCTAssertEqual(kind, .registry)
        }
    }

    // MARK: - The cache remembers events like any other record

    func test_aDeletedEventIsRestoredByteIdenticalAndReported() throws {
        try writeChain()
        let written = event(mark: ["d-chapter-4.mac-a": .init(segments: ["s1"], line: "l1")])
        let url = try write(written, signedBy: root)
        let before = try Data(contentsOf: url)

        let cache = makeCache()
        cache.remember(try RegistryReader.load(projectURL: projectURL), for: projectURL)
        XCTAssertEqual(cache.cached(for: projectURL)?.events.map(\.event), [written.event],
                       "the memory holds the event, not only the people")
        XCTAssertEqual(
            cache.rawBytes(of: RecordRef(directory: .events, fingerprint: written.event),
                           for: projectURL),
            before,
            "and it holds the FILE's bytes, not a re-encode")

        try FileManager.default.removeItem(at: url)
        let folder = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(folder.events, [])

        let outcome = try cache.reconcile(
            folder: folder, cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(outcome.removedBySomeone,
                       [RecordRef(directory: .events, fingerprint: written.event)])
        XCTAssertEqual(outcome.restored, [url])
        XCTAssertEqual(try Data(contentsOf: url), before,
                       "restored byte for byte — the bytes were already signed")
        XCTAssertEqual(outcome.registry.events.map(\.event), [written.event])

        let reread = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(reread.malformed, [], "and the restored event still verifies")
        XCTAssertEqual(reread.events.map(\.event), [written.event])
        XCTAssertEqual(
            cache.restores(for: projectURL).map(\.ref),
            [RecordRef(directory: .events, fingerprint: written.event)])
    }

    /// `reconcile`'s same-authority rule, one record down: an event the folder
    /// now holds under a DIFFERENT key than the one this device verified is
    /// listed and the remembered one stands. Without it, a second root could
    /// rewrite the permit history of a book it does not own.
    func test_anEventThatChangedHandsIsListedAndTheRememberedOneStands() throws {
        try writeChain()
        try writeRoot(otherRoot, label: "Somebody else")
        try writeAdmitted(tina, under: otherRoot, label: "Tina")
        let id = PermitEvent.mintID(subject: sam.fingerprint)
        try write(event(id: id), signedBy: root)

        let cache = makeCache()
        let first = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(first.events.map(\.by), [root.fingerprint])
        cache.remember(first, for: projectURL)

        // The other root writes an event of its OWN — entitled, because Tina is
        // on its chain — into the file this device already verified.
        try write(event(subject: tina, by: otherRoot, scope: "book", pieces: [], id: id),
                  signedBy: otherRoot)

        let folder = try RegistryReader.load(projectURL: projectURL)
        let outcome = try cache.reconcile(
            folder: folder, cached: cache.cached(for: projectURL), in: projectURL)

        XCTAssertEqual(outcome.registry.events.map(\.by), [root.fingerprint],
                       "the remembered event stands")
        XCTAssertTrue(outcome.registry.malformed.contains {
            if case .signerChanged = $0.reason { return true }
            return false
        })
    }

    // MARK: - Helpers

    /// Add a field a later build might have written, and re-sign the FILE's
    /// object. States the format rather than restating the code under test.
    private func addFieldAndResign(
        at url: URL, key: String, value: Any, by identity: DeviceIdentity
    ) throws {
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
                as? [String: Any])
        object[key] = value
        object.removeValue(forKey: "sig")
        let unsigned = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let credentials = try OpLogChain.credentials(
            signing: Hex.encode(Data(SHA256.hash(data: unsigned))), identity: identity)
        object["sig"] = ["key": credentials.key, "pub": credentials.pub,
                         "sig": credentials.sig]
        try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            .write(to: url)
    }
}
