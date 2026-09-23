import Foundation
import XCTest
@testable import MaughamCore

/// **The author's key names a device.**
///
/// Admission is one act with one signature behind it: this Mac's root key
/// writes a person record for somebody else's fingerprint, and every reader
/// that verifies the root verifies the admission. There is no person key in
/// this milestone — "Denver" is a label the root attaches — so the whole of
/// *who is allowed to write in this book* is which fingerprints my root has
/// signed a record for.
///
/// Three refusals are pinned here, and each is a different kind of wrong. A
/// device that is not a root cannot admit anybody: its record would name a
/// signer no reader accepts, and the device it "admitted" would stay a stranger
/// with nothing on screen to say so. A fingerprint already admitted under
/// ANOTHER root is not mine to take: that is a second claimant on a book, and
/// merging the two chains is adoption's own verb with its own claim record.
/// And admitting the same device twice with the same label writes nothing —
/// re-signing a record that already says what it should would make a new file
/// for iCloud to carry and a new signature for every peer to re-verify, for no
/// change at all.
final class RegistryAdmissionTests: XCTestCase {

    private var projectURL: URL!
    private var cacheURL: URL!
    /// A second Mac's memory of the same folder — the two-roots exit is two
    /// devices, and one cache file holding both would be one device pretending
    /// to be two.
    private var otherCacheURL: URL!
    private var memoryURL: URL!
    /// This Mac: four software keys, so a device record lists four actors.
    private var mine: LocalIdentities!
    /// The phone asking to be let in, with actor keys of its own.
    private var phone: LocalIdentities!
    /// Somebody else's Mac, for the two-roots cases.
    private var otherRoot: LocalIdentities!

    override func setUp() {
        super.setUp()
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-cache-\(UUID().uuidString).json")
        otherCacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-cache-other-\(UUID().uuidString).json")
        memoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-memory-\(UUID().uuidString).json")
        mine = .softwareForTesting()
        phone = .softwareForTesting()
        otherRoot = .softwareForTesting()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: otherCacheURL)
        try? FileManager.default.removeItem(at: memoryURL)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeCache() -> RegistryCache {
        RegistryCache(fileURL: cacheURL, identity: mine.author.fingerprint)
    }

    private func makeMemory() -> AdmissionMemory {
        AdmissionMemory(fileURL: memoryURL, identity: mine.author.fingerprint)
    }

    /// This Mac declares itself and, finding nobody, becomes the root.
    @discardableResult
    private func becomeRoot(_ identities: LocalIdentities, name: String) throws -> String {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: identities, name: name, kind: .mac,
            now: { Date(timeIntervalSince1970: 1) })
        // The writer's name stated rather than defaulted: the default is the
        // account's own full name (smoke find 2), and a suite whose root label
        // depended on whose Mac ran it would pass here and fail on the next
        // machine.
        try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: identities, writerName: name,
            now: { Date(timeIntervalSince1970: 2) })
        return identities.author.fingerprint
    }

    /// A device that has said who it is and nothing more — a stranger.
    @discardableResult
    private func declare(
        _ identities: LocalIdentities, name: String, kind: DeviceKind = .phone
    ) throws -> String {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: identities, name: name, kind: kind,
            now: { Date(timeIntervalSince1970: 3) })
        return identities.author.fingerprint
    }

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    private func personFile(_ fingerprint: String) -> URL {
        RegistryWriter.url(.people, fingerprint: fingerprint, in: projectURL)
    }

    private func bytesOfPersonFile(_ fingerprint: String) throws -> Data {
        try Data(contentsOf: personFile(fingerprint))
    }

    private func claimFile(_ fingerprint: String) -> URL {
        RegistryWriter.url(.claims, fingerprint: fingerprint, in: projectURL)
    }

    @discardableResult
    private func admitThePhone(
        label: String = "Denver", ownName: String = "Denver's iPhone",
        at when: Date = Date(timeIntervalSince1970: 10),
        cache: RegistryCache? = nil, memory: AdmissionMemory? = nil
    ) throws -> PersonRecord {
        try RegistryAdmission.admit(
            device: phone.author.fingerprint, label: label, ownName: ownName,
            in: projectURL, by: mine.author,
            cache: cache ?? makeCache(), memory: memory ?? makeMemory(),
            now: { when })
    }

    // MARK: - The admission itself

    func test_admittingWritesAPersonRecordSignedByMyRoot() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")

        let record = try admitThePhone()

        XCTAssertEqual(record.person, phone.author.fingerprint)
        XCTAssertEqual(record.label, "Denver")
        XCTAssertEqual(record.ownName, "Denver's iPhone")
        XCTAssertEqual(record.role, "author")
        XCTAssertEqual(record.admittedBy, mine.author.fingerprint)
        XCTAssertEqual(record.admittedAt, Date(timeIntervalSince1970: 10))
        XCTAssertNil(record.revokedAt)

        let onDisk = try XCTUnwrap(try registry().person(phone.author.fingerprint))
        XCTAssertEqual(onDisk, record, "and what came back is what a reader verifies")
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    func test_theAdmittedDeviceIsInMyChainForEveryActorKeyItHolds() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")

        try admitThePhone()

        let table = TrustTable.resolve(
            registry: try registry(), mine: mine, joinedRoot: nil)
        for actor in DeviceActor.allCases {
            XCTAssertEqual(
                table.verdict(forSealKey: phone[actor].fingerprint),
                .admitted(person: phone.author.fingerprint),
                """
                Admitting a device admits every actor key its record lists — \
                \(actor.rawValue) is that phone, not a stranger (spec §4.4).
                """)
        }
    }

    func test_beforeAdmissionThatSameDeviceIsAStranger() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")

        let table = TrustTable.resolve(
            registry: try registry(), mine: mine, joinedRoot: nil)

        XCTAssertEqual(
            table.verdict(forSealKey: phone.author.fingerprint),
            .stranger(device: phone.author.fingerprint),
            "otherwise the test above proves nothing about admission")
    }

    // MARK: - Idempotence

    func test_admittingTwiceWithTheSameLabelWritesNothingTheSecondTime() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let first = try admitThePhone()
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        let again = try admitThePhone(at: Date(timeIntervalSince1970: 5_000))

        XCTAssertEqual(again, first, "the record is the one already there")
        XCTAssertEqual(
            try bytesOfPersonFile(phone.author.fingerprint), bytes,
            """
            A re-signature is a new file for iCloud to carry and a new signature \
            for every peer to check. Nothing changed, so nothing is written.
            """)
    }

    func test_aChangedLabelReSignsTheRecordAndKeepsTheAdmissionDate() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone(label: "Denver")
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        let relabelled = try admitThePhone(
            label: "The editor", at: Date(timeIntervalSince1970: 5_000))

        XCTAssertEqual(relabelled.label, "The editor")
        XCTAssertEqual(
            relabelled.admittedAt, Date(timeIntervalSince1970: 10),
            "renaming somebody is not admitting them again")
        XCTAssertNotEqual(try bytesOfPersonFile(phone.author.fingerprint), bytes)
        XCTAssertTrue(try registry().malformed.isEmpty,
                      "and the re-signed record still verifies")
    }

    // MARK: - The two refusals

    func test_aDeviceThatIsNotARootHereAdmitsNobody() throws {
        try becomeRoot(otherRoot, name: "Somebody else's MacBook")
        try declare(mine, name: "Denver's MacBook", kind: .mac)
        try declare(phone, name: "Denver's iPhone")

        XCTAssertThrowsError(try admitThePhone()) { error in
            XCTAssertEqual(error as? RegistryAdmissionError, .notARoot)
        }
        XCTAssertNil(try registry().person(phone.author.fingerprint),
                     "and it wrote nothing on the way to refusing")
        XCTAssertNil(makeMemory().label(for: phone.author.fingerprint),
                     "nor remembered a decision it did not make")
    }

    func test_aPersonAlreadyAdmittedUnderAnotherRootIsAdoptionsJob() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try becomeRootBeside(otherRoot, name: "Somebody else's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try RegistryWriter.write(
            PersonRecord(
                person: phone.author.fingerprint, label: "Their word",
                ownName: "Denver's iPhone",
                admittedAt: Date(timeIntervalSince1970: 4),
                admittedBy: otherRoot.author.fingerprint),
            signedBy: otherRoot.author, in: projectURL)
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        XCTAssertThrowsError(try admitThePhone()) { error in
            XCTAssertEqual(
                error as? RegistryAdmissionError,
                .alreadyAdmittedElsewhere(root: otherRoot.author.fingerprint))
        }
        XCTAssertEqual(
            try bytesOfPersonFile(phone.author.fingerprint), bytes,
            """
            Taking over another root's person record is exactly the change of \
            hands the cache refuses one layer down. Merging two chains is \
            adoption's own act, with a claim record to say who did it.
            """)
    }

    /// A second self-signed root beside the first — `ensureRootIfEmpty` refuses
    /// once a book has people, and it is right to.
    private func becomeRootBeside(_ identities: LocalIdentities, name: String) throws {
        try declare(identities, name: name, kind: .mac)
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: name, ownName: name,
                admittedAt: Date(timeIntervalSince1970: 3),
                admittedBy: identities.author.fingerprint),
            signedBy: identities.author, in: projectURL)
    }

    // MARK: - What the Mac remembers

    func test_theLabelIsRememberedSoNoBookAsksAboutThisPhoneAgain() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let memory = makeMemory()

        try admitThePhone(memory: memory)

        let remembered = try XCTUnwrap(memory.label(for: phone.author.fingerprint))
        XCTAssertEqual(remembered.label, "Denver")
        XCTAssertEqual(remembered.ownName, "Denver's iPhone")
        XCTAssertEqual(remembered.labelledAt, Date(timeIntervalSince1970: 10))
    }

    func test_theRegistryItJustWroteIsWhatThisDeviceRemembersVerifying() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let cache = makeCache()

        try admitThePhone(cache: cache)

        let cached = try XCTUnwrap(cache.cached(for: projectURL))
        XCTAssertNotNil(
            cached.person(phone.author.fingerprint),
            """
            An admission nobody remembers is one a dropped file can undo in \
            silence — the cache is what puts a deleted record back.
            """)
    }

    // MARK: - A typed label that matches an existing one

    func test_twoDevicesUnderOneLabelAreTwoRecordsSayingTheSameName() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let tablet = LocalIdentities.softwareForTesting()
        try declare(tablet, name: "Denver's iPad")

        try admitThePhone(label: "Denver")
        try RegistryAdmission.admit(
            device: tablet.author.fingerprint, label: "Denver",
            ownName: "Denver's iPad", in: projectURL, by: mine.author,
            cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 20) })

        let people = try registry().people
        XCTAssertEqual(
            Set(people.filter { $0.label == "Denver" && !$0.isRoot }.map(\.person)),
            [phone.author.fingerprint, tablet.author.fingerprint],
            """
            A label is the author's word, not an identity: two devices under \
            one label are two person records that happen to agree. Nobody is \
            admitted AS an existing person by typing their name.
            """)
    }

    // MARK: - It reads this device's memory of the folder, never the raw folder

    /// Fix round 1, C1. The cache exists because absence is not proof: a signed
    /// record proves who wrote it and nothing stops somebody deleting it.
    /// Admission that read the folder raw would refuse the writer their own
    /// book over a file iCloud has not brought down yet.
    func test_aRootRecordSomebodyDeletedIsRestoredRatherThanRefusingTheWritersOwnBook() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let cache = makeCache()
        cache.remember(try registry(), for: projectURL)
        try FileManager.default.removeItem(at: personFile(mine.author.fingerprint))

        let record = try admitThePhone(cache: cache)

        XCTAssertEqual(record.admittedBy, mine.author.fingerprint)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: personFile(mine.author.fingerprint).path),
            "and the deleted root record is put back, byte for byte, on the way through")
    }

    /// The other half of C1: another root writing over a record this device
    /// already verified is a takeover the cache REFUSES, and remembering the
    /// raw folder would store their bytes as this device's verified copy —
    /// after which the same-authority rule has nothing left to compare and B1's
    /// claimant line is gone for that record.
    func test_anotherRootsTakeoverIsNotLaunderedIntoThisDevicesMemory() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try becomeRootBeside(otherRoot, name: "Somebody else's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let cache = makeCache()
        try admitThePhone(cache: cache)
        try RegistryWriter.write(
            PersonRecord(
                person: phone.author.fingerprint, label: "Their word",
                ownName: "Denver's iPhone",
                admittedAt: Date(timeIntervalSince1970: 40),
                admittedBy: otherRoot.author.fingerprint),
            signedBy: otherRoot.author, in: projectURL)

        let again = try admitThePhone(at: Date(timeIntervalSince1970: 50), cache: cache)

        XCTAssertEqual(again.admittedBy, mine.author.fingerprint,
                       "the record this device verified still stands")
        XCTAssertEqual(
            cache.cached(for: projectURL)?.person(phone.author.fingerprint)?.admittedBy,
            mine.author.fingerprint,
            """
            and their copy was never remembered as mine — the next reconcile can             still tell that a record changed hands.
            """)
    }

    // MARK: - Present and unreadable is not absent

    /// Fix round 1, I1 — the distinction `ensureRootIfEmpty` makes in the same
    /// file, under Denver's 2026-09-10 ruling. A person record that is on disk
    /// and did not verify is not one that is missing, and overwriting it would
    /// destroy another root's admission over a sync ordering.
    func test_aPersonRecordThatIsPresentAndUnreadableIsRefusedRatherThanOverwritten() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try plantUnreadablePersonRecord(for: phone)
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        XCTAssertThrowsError(try admitThePhone()) { error in
            XCTAssertEqual(
                error as? RegistryAdmissionError,
                .recordUnreadable(fingerprint: phone.author.fingerprint))
        }
        XCTAssertEqual(try bytesOfPersonFile(phone.author.fingerprint), bytes)
    }

    /// A record signed by somebody who is not a root here: the reader lists it
    /// `signerIsNotARoot`, so it is absent from `people` while its FILE is very
    /// much present. That is the reachable shape — another Mac admitted the
    /// phone and its own root record has not landed yet.
    private func plantUnreadablePersonRecord(for device: LocalIdentities) throws {
        let impostor = LocalIdentities.softwareForTesting()
        try RegistryWriter.writeUnchecked(
            PersonRecord(
                person: device.author.fingerprint, label: "Somebody's word",
                ownName: "Denver's iPhone",
                admittedAt: Date(timeIntervalSince1970: 6),
                admittedBy: impostor.author.fingerprint),
            signedBy: impostor.author, in: projectURL)
    }

    // MARK: - A root is not somebody I can admit

    /// Minor 1 — P2a's hole, pinned on the write side. The refusal already
    /// travels the already-admitted-elsewhere branch, because a root's
    /// `admittedBy` is itself; nothing said so.
    func test_aSelfSignedRootIsNotAFingerprintThisDeviceCanAdmit() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try becomeRootBeside(otherRoot, name: "Somebody else's MacBook")
        let bytes = try bytesOfPersonFile(otherRoot.author.fingerprint)

        XCTAssertThrowsError(try RegistryAdmission.admit(
            device: otherRoot.author.fingerprint, label: "Denver",
            ownName: "Somebody else's MacBook", in: projectURL, by: mine.author,
            cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 30) })
        ) { error in
            XCTAssertEqual(
                error as? RegistryAdmissionError,
                .alreadyAdmittedElsewhere(root: otherRoot.author.fingerprint))
        }
        XCTAssertEqual(
            try bytesOfPersonFile(otherRoot.author.fingerprint), bytes,
            "a root answers to itself, and admitting one would be re-signing their own record")
    }

    // MARK: - The device's own name stays current

    /// Minor 6. Idempotence keys on the label, so a phone that renamed itself
    /// would otherwise keep its old `ownName` in the person record forever
    /// while every surface reading that record showed a name nobody uses.
    func test_aRenamedDeviceGetsItsNewNameIntoTheRecord() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone(ownName: "Denver's iPhone")

        let renamed = try admitThePhone(
            ownName: "Denver's iPhone 17", at: Date(timeIntervalSince1970: 900))

        XCTAssertEqual(renamed.ownName, "Denver's iPhone 17")
        XCTAssertEqual(
            renamed.admittedAt, Date(timeIntervalSince1970: 10),
            "which is a re-signing, not a re-admission")
    }

    // MARK: - Revocation is the root's (spec §5)

    /// The shape of the act: the person record keeps everything it said and
    /// gains three facts — when, by whom, and where the line falls between what
    /// this Mac had already applied and what arrived after.
    func test_revokingRewritesThePersonRecordWithTheRootsOwnSignature() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()

        let record = try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01J0000000000000000000000A",
            cache: makeCache(), now: { Date(timeIntervalSince1970: 100) })

        XCTAssertEqual(record.revokedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(record.revokedBy, mine.author.fingerprint)
        XCTAssertEqual(record.highestOpIdSeen, "01J0000000000000000000000A")
        XCTAssertEqual(record.label, "Denver", "a revocation is not a rename")
        XCTAssertEqual(record.admittedAt, Date(timeIntervalSince1970: 10),
                       "nor a re-admission")

        let onDisk = try XCTUnwrap(try registry().person(phone.author.fingerprint))
        XCTAssertEqual(onDisk, record,
                       "and what a reader verifies is what came back")
        XCTAssertTrue(try registry().malformed.isEmpty,
                      "the re-signed record still verifies")
    }

    /// `highestOpIdSeen` is genuinely optional: a device admitted whose ops
    /// this Mac has never applied is revoked with no line at all, and every
    /// line it wrote is *after revocation* (the split's own rule).
    func test_revokingWithNothingApplledYetRecordsNoLine() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()

        let record = try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: nil, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })

        XCTAssertNil(record.highestOpIdSeen)
        XCTAssertEqual(record.revokedAt, Date(timeIntervalSince1970: 100))
    }

    /// **Only a root revokes.** A device that is not this book's root can
    /// produce a perfectly well-formed record, and no reader will take it —
    /// the writer would watch themselves shut a device out that goes on
    /// writing everywhere.
    func test_aDeviceThatIsNotTheRootCannotRevokeAnybody() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        XCTAssertThrowsError(try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: otherRoot.author,
            highestOpIdSeen: nil, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })
        ) { error in
            XCTAssertEqual(error as? RegistryAdmissionError, .notARoot)
        }
        XCTAssertEqual(try bytesOfPersonFile(phone.author.fingerprint), bytes,
                       "and nothing was written")
    }

    /// **A root is claimed over, never revoked** (spec §5). Its record is
    /// self-signed, so revoking one would be this Mac re-signing somebody
    /// else's own word about themselves.
    func test_aRootIsNotSomebodyThisMacCanRevoke() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try becomeRootBeside(otherRoot, name: "Somebody else's MacBook")
        let bytes = try bytesOfPersonFile(otherRoot.author.fingerprint)

        XCTAssertThrowsError(try RegistryAdmission.revoke(
            person: otherRoot.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: nil, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })
        ) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .cannotRevokeARoot(fingerprint: otherRoot.author.fingerprint))
        }
        XCTAssertEqual(try bytesOfPersonFile(otherRoot.author.fingerprint), bytes)
    }

    /// Present and unreadable is not absent (RULING-54, and `admit`'s own
    /// rule): a record this Mac could not verify is one it must not write over.
    func test_revokingRefusesOverARecordThisMacCannotRead() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try plantUnreadablePersonRecord(for: phone)
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        XCTAssertThrowsError(try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: nil, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })
        ) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .recordUnreadable(fingerprint: phone.author.fingerprint))
        }
        XCTAssertEqual(try bytesOfPersonFile(phone.author.fingerprint), bytes)
    }

    /// Nobody to revoke is its own refusal rather than a record minted out of
    /// nothing: writing one would admit the device in the act of shutting it
    /// out.
    func test_revokingSomebodyNeverAdmittedRefuses() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")

        XCTAssertThrowsError(try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: nil, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })
        ) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .notAdmitted(fingerprint: phone.author.fingerprint))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: personFile(phone.author.fingerprint).path),
            "and no record was minted for them")
    }

    /// Revoking twice writes once. A second press would re-sign the record with
    /// a later date, moving the line the first revocation drew.
    func test_revokingTwiceKeepsTheFirstRevocationsOwnWords() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01J0000000000000000000000A",
            cache: makeCache(), now: { Date(timeIntervalSince1970: 100) })
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        let again = try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01J0000000000000000000000Z",
            cache: makeCache(), now: { Date(timeIntervalSince1970: 900) })

        XCTAssertEqual(again.revokedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(again.highestOpIdSeen, "01J0000000000000000000000A")
        XCTAssertEqual(try bytesOfPersonFile(phone.author.fingerprint), bytes,
                       "the file was not touched")
    }

    /// **A re-sign canonicalizes the FILE's object, not this build's decoded
    /// copy.** A record a later build wrote carries fields this one has no
    /// property for; a digest over what this build decoded would drop them, and
    /// the record would fail to verify on every device that understands them —
    /// a silent, permanent un-admission the moment anybody upgrades.
    func test_aRevocationKeepsAFieldThisBuildHasNoNameFor() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try plantUnknownField("future", 1, inPersonRecordOf: phone)

        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: nil, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })

        let object = try jsonObjectOfPersonFile(phone.author.fingerprint)
        XCTAssertEqual(object["future"] as? Int, 1,
                       "the unknown field survived the re-sign")
        XCTAssertNotNil(object["revokedAt"])
        XCTAssertTrue(try registry().malformed.isEmpty,
                      "and the signature still covers the whole object")
        XCTAssertTrue(try registry().person(phone.author.fingerprint)?.isRevoked == true)
    }

    // MARK: - Re-admission is the revocation's inverse (fix round 1, Important 3b)

    /// **The root that revoked them can let them back in**, and the record it
    /// writes says nothing about the revocation: the three fields are cleared,
    /// because the same authority is saying the opposite thing and a record
    /// carrying both would leave every reader quarantining a device the writer
    /// has just re-admitted.
    func test_readmittingClearsTheRevocationItReverses() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01J0000000000000000000000A",
            cache: makeCache(), now: { Date(timeIntervalSince1970: 100) })

        let readmitted = try admitThePhone(at: Date(timeIntervalSince1970: 900))

        XCTAssertNil(readmitted.revokedAt)
        XCTAssertNil(readmitted.revokedBy)
        XCTAssertNil(readmitted.highestOpIdSeen)
        XCTAssertFalse(readmitted.isRevoked)
        XCTAssertEqual(
            readmitted.admittedAt, Date(timeIntervalSince1970: 10),
            "they were admitted the day they were admitted; the return is a second fact")
        let onDisk = try XCTUnwrap(try registry().person(phone.author.fingerprint))
        XCTAssertEqual(onDisk, readmitted, "and a reader verifies it")
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    /// The idempotent arm must not swallow a re-admission. Same label, same own
    /// name, and a revoked record: the old rule answered "nothing to write" and
    /// left the writer pressing Re-admit at a device that stayed shut out.
    func test_areadmissionWithTheSameLabelStillWrites() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone(label: "Denver", ownName: "Denver's iPhone")
        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: nil, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })

        let readmitted = try admitThePhone(
            label: "Denver", ownName: "Denver's iPhone",
            at: Date(timeIntervalSince1970: 900))

        XCTAssertFalse(readmitted.isRevoked, "the same words are a different act now")
    }

    /// And an ordinary admission is still idempotent: nothing revoked, nothing
    /// renamed, nothing written.
    func test_anadmissionThatChangesNothingStillWritesNothing() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        try admitThePhone(at: Date(timeIntervalSince1970: 900))

        XCTAssertEqual(try bytesOfPersonFile(phone.author.fingerprint), bytes)
    }

    /// Re-admission is the ADMITTING root's to perform. Another Mac's root is
    /// refused exactly as it is refused for a first admission — the record is
    /// not theirs to sign.
    func test_anotherRootCannotReadmitSomebodyMyRootRevoked() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try becomeRootBeside(otherRoot, name: "Somebody else's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: nil, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })

        XCTAssertThrowsError(try RegistryAdmission.admit(
            device: phone.author.fingerprint, label: "Theirs",
            ownName: "Denver's iPhone", in: projectURL, by: otherRoot.author,
            cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 900) })
        ) { error in
            XCTAssertEqual(
                error as? RegistryAdmissionError,
                .alreadyAdmittedElsewhere(root: mine.author.fingerprint))
        }
        XCTAssertTrue(
            try registry().person(phone.author.fingerprint)?.isRevoked == true,
            "and they stay revoked")
    }

    // MARK: - The re-sign door refuses an edit that changes WHO (Minor 2)

    /// The URL and the signer check are both decided from the record handed in,
    /// so an edit that moves the identity would write a well-signed file under
    /// a name that no longer describes it — and the reader would refuse it in
    /// the un-admitting direction.
    func test_aresignThatMovesTheFingerprintIsRefused() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let admitted = try admitThePhone()
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        XCTAssertThrowsError(try RegistryWriter.resign(
            admitted, signedBy: mine.author, in: projectURL
        ) { object in
            object["person"] = otherRoot.author.fingerprint
        }) { error in
            XCTAssertEqual(
                error as? RegistryWriteError,
                .identityChanged(fingerprint: phone.author.fingerprint))
        }
        XCTAssertEqual(try bytesOfPersonFile(phone.author.fingerprint), bytes,
                       "and nothing was written")
    }

    func test_aresignThatMovesTheSignerIsRefused() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let admitted = try admitThePhone()

        XCTAssertThrowsError(try RegistryWriter.resign(
            admitted, signedBy: mine.author, in: projectURL
        ) { object in
            object["admittedBy"] = otherRoot.author.fingerprint
        }) { error in
            XCTAssertEqual(
                error as? RegistryWriteError,
                .identityChanged(fingerprint: phone.author.fingerprint))
        }
    }

    /// And the door still passes the edits the two verbs make — the guard is
    /// about identity, not about change.
    func test_aresignThatChangesAFactIsAllowed() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let admitted = try admitThePhone()

        try RegistryWriter.resign(
            admitted, signedBy: mine.author, in: projectURL
        ) { object in
            object["label"] = "Amelia"
        }

        XCTAssertEqual(try registry().person(phone.author.fingerprint)?.label, "Amelia")
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    // MARK: - Retirement is the device's own (spec §5)

    func test_aDeviceRetiresItself() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        let record = try RegistryAdmission.retire(
            device: mine.author.fingerprint, in: projectURL, by: mine.author,
            cache: makeCache(), now: { Date(timeIntervalSince1970: 100) })

        XCTAssertEqual(record.retiredAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(record.device, mine.author.fingerprint)
        let onDisk = try XCTUnwrap(
            try registry().devices.first { $0.device == mine.author.fingerprint })
        XCTAssertEqual(onDisk, record)
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    /// **A device signs its own retirement.** The root cannot retire the
    /// phone: the device record is signed by the device, so a root's signature
    /// on one is a record every reader lists as malformed — the device's whole
    /// history left unattributable by an act meant to be orderly.
    func test_aRootCannotRetireSomebodyElsesDevice() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        let bytes = try Data(contentsOf: RegistryWriter.url(
            .devices, fingerprint: phone.author.fingerprint, in: projectURL))

        XCTAssertThrowsError(try RegistryAdmission.retire(
            device: phone.author.fingerprint, in: projectURL, by: mine.author,
            cache: makeCache(), now: { Date(timeIntervalSince1970: 100) })
        ) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .notThatDevice(device: phone.author.fingerprint))
        }
        XCTAssertEqual(
            try Data(contentsOf: RegistryWriter.url(
                .devices, fingerprint: phone.author.fingerprint, in: projectURL)),
            bytes)
    }

    func test_retiringADeviceWithNoRecordHereRefuses() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        XCTAssertThrowsError(try RegistryAdmission.retire(
            device: phone.author.fingerprint, in: projectURL, by: phone.author,
            cache: makeCache(), now: { Date(timeIntervalSince1970: 100) })
        ) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .notAdmitted(fingerprint: phone.author.fingerprint))
        }
    }

    func test_retiringTwiceKeepsTheFirstRetirementsDate() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try RegistryAdmission.retire(
            device: mine.author.fingerprint, in: projectURL, by: mine.author,
            cache: makeCache(), now: { Date(timeIntervalSince1970: 100) })
        let bytes = try Data(contentsOf: RegistryWriter.url(
            .devices, fingerprint: mine.author.fingerprint, in: projectURL))

        let again = try RegistryAdmission.retire(
            device: mine.author.fingerprint, in: projectURL, by: mine.author,
            cache: makeCache(), now: { Date(timeIntervalSince1970: 900) })

        XCTAssertEqual(again.retiredAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(
            try Data(contentsOf: RegistryWriter.url(
                .devices, fingerprint: mine.author.fingerprint, in: projectURL)),
            bytes)
    }

    func test_aRetirementKeepsAFieldThisBuildHasNoNameFor() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try plantUnknownField("future", 1, inDeviceRecordOf: mine)

        try RegistryAdmission.retire(
            device: mine.author.fingerprint, in: projectURL, by: mine.author,
            cache: makeCache(), now: { Date(timeIntervalSince1970: 100) })

        let object = try jsonObject(at: RegistryWriter.url(
            .devices, fingerprint: mine.author.fingerprint, in: projectURL))
        XCTAssertEqual(object["future"] as? Int, 1)
        XCTAssertNotNil(object["retiredAt"])
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    // MARK: - The claim, and the two-roots exit (spec §5, plan decision P2)

    /// **A Mac holding a book it has no key in claims it — and the ORDER of the
    /// two writes is the contract.**
    ///
    /// The root record goes down first, because `RegistryReader` refuses a
    /// claim whose `newRoot` is not a verified root here (Task 2): a claim
    /// written first would be listed malformed, the adoption would never
    /// happen, and the writer would be looking at a book that had accepted
    /// their claim and gone on quarantining everything in it.
    func test_aKeylessMacClaimsTheBookByRootingItselfFirst() throws {
        try becomeRootBeside(otherRoot, name: "The old MacBook")
        try declare(mine, name: "Denver's new MacBook", kind: .mac)

        let claim = try RegistryAdmission.claim(
            adopting: [otherRoot.author.fingerprint], in: projectURL,
            by: mine.author, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })

        let registry = try self.registry()
        let root = try XCTUnwrap(registry.person(mine.author.fingerprint))
        XCTAssertTrue(root.isRoot, "this Mac vouched for itself")
        XCTAssertEqual(root.label, "Denver's new MacBook")
        XCTAssertEqual(root.ownName, "Denver's new MacBook")
        XCTAssertEqual(claim.newRoot, mine.author.fingerprint)
        XCTAssertEqual(claim.adopted, [otherRoot.author.fingerprint])
        XCTAssertEqual(claim.claimedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(
            registry.claims.map(\.newRoot), [mine.author.fingerprint],
            "and the claim VERIFIED, which is only true of a claim written after the root record")
        XCTAssertTrue(registry.malformed.isEmpty, "\(registry.malformed)")
    }

    /// What the claim is FOR: the history this Mac was holding stops being
    /// unsigned prose it cannot judge and becomes somebody's, attributed.
    func test_whatWasAdoptedIsVerifiedAndAttributedAfterwards() throws {
        try becomeRootBeside(otherRoot, name: "The old MacBook")
        try declare(phone, name: "Denver's iPhone")
        try RegistryWriter.write(
            PersonRecord(
                person: phone.author.fingerprint, label: "Denver",
                ownName: "Denver's iPhone",
                admittedAt: Date(timeIntervalSince1970: 5),
                admittedBy: otherRoot.author.fingerprint),
            signedBy: otherRoot.author, in: projectURL)
        try declare(mine, name: "Denver's new MacBook", kind: .mac)
        let cache = makeCache()

        let before = try TrustResolution.resolve(
            projectURL: projectURL, identities: mine, cache: cache)
        XCTAssertNil(before.myRoot, "no key of this Mac's is named anywhere (B3)")
        XCTAssertEqual(before.verdict(forSealKey: phone.author.fingerprint), .noChain)

        try RegistryAdmission.claim(
            adopting: [otherRoot.author.fingerprint], in: projectURL,
            by: mine.author, cache: cache, now: { Date(timeIntervalSince1970: 100) })

        let after = try TrustResolution.resolve(
            projectURL: projectURL, identities: mine, cache: cache)
        XCTAssertEqual(after.myRoot, mine.author.fingerprint)
        XCTAssertEqual(after.adoptedRoots, [otherRoot.author.fingerprint])
        XCTAssertEqual(
            after.verdict(forSealKey: phone.author.fingerprint),
            .admitted(person: phone.author.fingerprint),
            "the old chain's devices are the writer's own, and their history is theirs")
    }

    /// A `roots` list naming this device is a claim that adopts itself: it
    /// would write a record saying nothing, and the writer pressing Merge on
    /// their own row is a question about a row that should never have offered
    /// it.
    func test_thisMacCannotAdoptItself() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        XCTAssertThrowsError(try RegistryAdmission.claim(
            adopting: [otherRoot.author.fingerprint, mine.author.fingerprint],
            in: projectURL, by: mine.author, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })
        ) { error in
            XCTAssertEqual(
                error as? RegistryAdmissionError,
                .cannotAdoptItself(root: mine.author.fingerprint))
        }
        XCTAssertTrue(try registry().claims.isEmpty,
                      "and the whole act is refused — not the offending half of it")
    }

    /// Idempotent for admission's reason, one directory over: re-signing a
    /// claim that already says what it should is a new file for iCloud to carry
    /// and a new signature for every peer to check, for no change at all.
    func test_adoptingARootThisMacAlreadyAdoptedWritesNothing() throws {
        try becomeRootBeside(otherRoot, name: "The old MacBook")
        try declare(mine, name: "Denver's new MacBook", kind: .mac)
        let cache = makeCache()
        try RegistryAdmission.claim(
            adopting: [otherRoot.author.fingerprint], in: projectURL,
            by: mine.author, cache: cache, now: { Date(timeIntervalSince1970: 100) })
        let bytes = try Data(contentsOf: claimFile(mine.author.fingerprint))

        let again = try RegistryAdmission.claim(
            adopting: [otherRoot.author.fingerprint], in: projectURL,
            by: mine.author, cache: cache, now: { Date(timeIntervalSince1970: 200) })

        XCTAssertEqual(try Data(contentsOf: claimFile(mine.author.fingerprint)), bytes)
        XCTAssertEqual(again.claimedAt, Date(timeIntervalSince1970: 100))
    }

    /// A second root adopted later joins the claim this Mac already wrote — one
    /// claim record per root, because the file is named by the root — and the
    /// day the book was claimed does not move.
    func test_adoptingASecondRootKeepsTheDayTheBookWasClaimed() throws {
        let borrowed = LocalIdentities.softwareForTesting()
        try becomeRootBeside(otherRoot, name: "The old MacBook")
        try becomeRootBeside(borrowed, name: "A borrowed Mac")
        try declare(mine, name: "Denver's new MacBook", kind: .mac)
        let cache = makeCache()
        try RegistryAdmission.claim(
            adopting: [otherRoot.author.fingerprint], in: projectURL,
            by: mine.author, cache: cache, now: { Date(timeIntervalSince1970: 100) })

        let claim = try RegistryAdmission.claim(
            adopting: [borrowed.author.fingerprint], in: projectURL,
            by: mine.author, cache: cache, now: { Date(timeIntervalSince1970: 200) })

        XCTAssertEqual(
            claim.adopted,
            [otherRoot.author.fingerprint, borrowed.author.fingerprint].sorted())
        XCTAssertEqual(claim.claimedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try registry().claims.count, 1)
    }

    /// **The two-roots exit, end to end** (P2a review I3, plan decision P1).
    ///
    /// Two Macs both opened this book before sync converged and each wrote
    /// itself a root. Nothing may overwrite either record — that is the change
    /// of hands the whole layer refuses — so they quarantine each other, and
    /// the way out is each saying *this is also me*. Adoption is symmetric and
    /// the reciprocal half is THIS SAME CALL, made on the other Mac.
    func test_twoRootsLeaveMutualQuarantineByAdoptingEachOther() throws {
        try becomeRootBeside(mine, name: "Denver's MacBook")
        try becomeRootBeside(otherRoot, name: "The studio Mac")
        let cacheA = makeCache()
        let cacheB = RegistryCache(
            fileURL: otherCacheURL, identity: otherRoot.author.fingerprint)

        let beforeA = try TrustResolution.resolve(
            projectURL: projectURL, identities: mine, cache: cacheA)
        let beforeB = try TrustResolution.resolve(
            projectURL: projectURL, identities: otherRoot, cache: cacheB)
        XCTAssertEqual(
            beforeA.verdict(forSealKey: otherRoot.author.fingerprint),
            .otherRoot(root: otherRoot.author.fingerprint))
        XCTAssertEqual(
            beforeB.verdict(forSealKey: mine.author.fingerprint),
            .otherRoot(root: mine.author.fingerprint))

        try RegistryAdmission.claim(
            adopting: [otherRoot.author.fingerprint], in: projectURL,
            by: mine.author, cache: cacheA, now: { Date(timeIntervalSince1970: 100) })
        try RegistryAdmission.claim(
            adopting: [mine.author.fingerprint], in: projectURL,
            by: otherRoot.author, cache: cacheB,
            now: { Date(timeIntervalSince1970: 101) })

        let afterA = try TrustResolution.resolve(
            projectURL: projectURL, identities: mine, cache: cacheA)
        let afterB = try TrustResolution.resolve(
            projectURL: projectURL, identities: otherRoot, cache: cacheB)
        XCTAssertEqual(
            afterA.verdict(forSealKey: otherRoot.author.fingerprint),
            .admitted(person: otherRoot.author.fingerprint))
        XCTAssertEqual(
            afterB.verdict(forSealKey: mine.author.fingerprint),
            .admitted(person: mine.author.fingerprint))
        XCTAssertEqual(afterA.adoptedRoots, [otherRoot.author.fingerprint])
        XCTAssertEqual(afterB.adoptedRoots, [mine.author.fingerprint])
        XCTAssertEqual(afterA.myRoot, mine.author.fingerprint)
        XCTAssertEqual(afterB.myRoot, otherRoot.author.fingerprint)
        XCTAssertNil(
            cacheA.joinedRoot(for: projectURL),
            "B1: a merge widens whose history I verify and moves nobody's root")
        XCTAssertNil(cacheB.joinedRoot(for: projectURL))
    }

    /// A Mac already on somebody's chain has no root record of its own to
    /// write, and the one the claim would write would go straight over the
    /// record that admitted it. Refused where the takeover is refused
    /// everywhere else in this layer.
    func test_aMacSomebodyElseAdmittedDoesNotRootItselfOverTheirRecord() throws {
        try becomeRootBeside(otherRoot, name: "The old MacBook")
        try declare(mine, name: "Denver's other Mac", kind: .mac)
        try RegistryWriter.write(
            PersonRecord(
                person: mine.author.fingerprint, label: "Denver",
                ownName: "Denver's other Mac",
                admittedAt: Date(timeIntervalSince1970: 4),
                admittedBy: otherRoot.author.fingerprint),
            signedBy: otherRoot.author, in: projectURL)
        let bytes = try bytesOfPersonFile(mine.author.fingerprint)

        XCTAssertThrowsError(try RegistryAdmission.claim(
            adopting: [otherRoot.author.fingerprint], in: projectURL,
            by: mine.author, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })
        ) { error in
            XCTAssertEqual(
                error as? RegistryAdmissionError,
                .alreadyAdmittedElsewhere(root: otherRoot.author.fingerprint))
        }
        XCTAssertEqual(try bytesOfPersonFile(mine.author.fingerprint), bytes)
    }

    /// RULING-54 at the claim, for the reason it holds at every other write
    /// here: a person record for this device that is PRESENT and did not verify
    /// is not one that is absent, and rooting over it would destroy somebody's
    /// admission over a sync ordering that fixes itself.
    func test_theClaimRefusesOverARecordOfItsOwnThatWillNotRead() throws {
        try becomeRootBeside(otherRoot, name: "The old MacBook")
        try declare(mine, name: "Denver's new MacBook", kind: .mac)
        try plantUnreadablePersonRecord(for: mine)
        let bytes = try bytesOfPersonFile(mine.author.fingerprint)

        XCTAssertThrowsError(try RegistryAdmission.claim(
            adopting: [otherRoot.author.fingerprint], in: projectURL,
            by: mine.author, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })
        ) { error in
            XCTAssertEqual(
                error as? RegistryAdmissionError,
                .recordUnreadable(fingerprint: mine.author.fingerprint))
        }
        XCTAssertEqual(try bytesOfPersonFile(mine.author.fingerprint), bytes)
        XCTAssertTrue(try registry().claims.isEmpty)
    }

    // MARK: - Rename (P2 smoke find 3)

    /// **A label is a word, and until now it could only be chosen once.** A
    /// writer who mistyped a name at the admission sheet, or who let a first
    /// root be called whatever the Mac was called, had no way back.
    func test_theRootRenamesSomebodyItAdmitted() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone(label: "Denvre")

        let renamed = try RegistryAdmission.rename(
            person: phone.author.fingerprint, to: "Denver", in: projectURL,
            by: mine.author, cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 500) })

        XCTAssertEqual(renamed.label, "Denver")
        XCTAssertEqual(try registry().person(phone.author.fingerprint)?.label, "Denver")
        XCTAssertTrue(try registry().malformed.isEmpty,
                      "and the re-signed record still verifies")
    }

    /// It changes a WORD and nothing else: not when they were admitted, not
    /// who admitted them, not the device's own name, and not a revocation.
    /// A rename that moved any of those would be a change of authority wearing
    /// a text field.
    func test_arenameChangesTheLabelAndNothingElse() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let admitted = try admitThePhone(label: "Denvre")
        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01J0000000000000000000000A", cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })

        let renamed = try RegistryAdmission.rename(
            person: phone.author.fingerprint, to: "Denver", in: projectURL,
            by: mine.author, cache: makeCache(), memory: makeMemory())

        XCTAssertEqual(renamed.label, "Denver")
        XCTAssertEqual(renamed.admittedAt, admitted.admittedAt)
        XCTAssertEqual(renamed.admittedBy, mine.author.fingerprint)
        XCTAssertEqual(renamed.ownName, "Denver's iPhone",
                       "the device's own name is the device's word, not the writer's")
        XCTAssertEqual(renamed.revokedAt, Date(timeIntervalSince1970: 100),
                       "a revoked person may be renamed and stays revoked")
        XCTAssertEqual(renamed.highestOpIdSeen, "01J0000000000000000000000A")
    }

    /// **A root renames itself**, which is the case the smoke found: the first
    /// root was labelled with the machine's name, and the row that needed
    /// correcting was the writer's own. A root record names ITSELF as its
    /// admitter, so the rule below lets it through without a clause of its own.
    func test_arootMayRenameItself() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        let renamed = try RegistryAdmission.rename(
            person: mine.author.fingerprint, to: "Denver", in: projectURL,
            by: mine.author, cache: makeCache(), memory: makeMemory())

        XCTAssertEqual(renamed.label, "Denver")
        XCTAssertTrue(renamed.isRoot, "and it is still the root")
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    /// Somebody ELSE's root is not this Mac's to re-sign — the same refusal
    /// revocation makes, for the same reason: the file would be one every
    /// reader lists as malformed.
    func test_anotherRootIsNotThisMacsToRename() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try becomeRootBeside(otherRoot, name: "Amelia's MacBook")

        XCTAssertThrowsError(try RegistryAdmission.rename(
            person: otherRoot.author.fingerprint, to: "Amelia", in: projectURL,
            by: mine.author, cache: makeCache(), memory: makeMemory())
        ) { error in
            XCTAssertEqual(
                error as? RegistryAdmissionError,
                .alreadyAdmittedElsewhere(root: otherRoot.author.fingerprint))
        }
        XCTAssertEqual(try registry().person(otherRoot.author.fingerprint)?.label,
                       "Amelia's MacBook", "untouched")
    }

    /// A device that is not a root here signs nothing any reader takes, so it
    /// is refused at the door rather than left writing a file that would
    /// silently un-admit somebody.
    func test_adeviceThatIsNotARootRenamesNobody() throws {
        try becomeRoot(otherRoot, name: "Amelia's MacBook")
        try declare(mine, name: "Denver's MacBook", kind: .mac)

        XCTAssertThrowsError(try RegistryAdmission.rename(
            person: otherRoot.author.fingerprint, to: "Amelia", in: projectURL,
            by: mine.author, cache: makeCache(), memory: makeMemory())
        ) { error in
            XCTAssertEqual(error as? RegistryAdmissionError, .notARoot)
        }
    }

    func test_renamingSomebodyThisBookHasNoRecordOfIsRefused() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        XCTAssertThrowsError(try RegistryAdmission.rename(
            person: phone.author.fingerprint, to: "Denver", in: projectURL,
            by: mine.author, cache: makeCache(), memory: makeMemory())
        ) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .notAdmitted(fingerprint: phone.author.fingerprint))
        }
    }

    /// Idempotent, for admission's reason: re-signing a record that already
    /// says this would make a new file for iCloud to carry and a new signature
    /// for every peer to check, for no change at all.
    func test_renamingToTheNameAlreadyThereWritesNothing() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone(label: "Denver")
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        let same = try RegistryAdmission.rename(
            person: phone.author.fingerprint, to: "  Denver  ", in: projectURL,
            by: mine.author, cache: makeCache(), memory: makeMemory())

        XCTAssertEqual(same.label, "Denver")
        XCTAssertEqual(try bytesOfPersonFile(phone.author.fingerprint), bytes,
                       "the file was not touched — a trailing space is a typo, "
                       + "not a second person")
    }

    /// An empty label is a cleared field, not a rename: nothing here writes a
    /// person with no name, and the surface that offers this disables its
    /// button on one.
    func test_anEmptyLabelRenamesNobody() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone(label: "Denver")
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        let same = try RegistryAdmission.rename(
            person: phone.author.fingerprint, to: "   ", in: projectURL,
            by: mine.author, cache: makeCache(), memory: makeMemory())

        XCTAssertEqual(same.label, "Denver")
        XCTAssertEqual(try bytesOfPersonFile(phone.author.fingerprint), bytes)
    }

    /// The re-sign is over the FILE's object (P2b Task 1), so a record a LATER
    /// build wrote keeps the fields this one has no property for. Renaming is
    /// the likeliest verb to be pointed at a peer's record, and a rename that
    /// dropped an unknown field would un-admit that device everywhere that
    /// understands it.
    func test_arenameKeepsAFieldThisBuildHasNoNameFor() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone(label: "Denvre")
        try plantUnknownField("future", 1, inPersonRecordOf: phone)

        try RegistryAdmission.rename(
            person: phone.author.fingerprint, to: "Denver", in: projectURL,
            by: mine.author, cache: makeCache(), memory: makeMemory())

        let object = try jsonObjectOfPersonFile(phone.author.fingerprint)
        XCTAssertEqual(object["future"] as? Int, 1,
                       "the unknown field survived the re-sign")
        XCTAssertEqual(object["label"] as? String, "Denver")
        XCTAssertTrue(try registry().malformed.isEmpty,
                      "and the signature still covers the whole object")
    }

    /// **The memory follows the new label** (smoke find 3). It is what decides
    /// who is admitted silently in the next book this device syncs into, so a
    /// rename it did not hear would have the writer correct a name here and
    /// meet the old one there.
    func test_therenameIsRememberedForEveryLaterBook() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let memory = makeMemory()
        try admitThePhone(label: "Denvre", memory: memory)
        XCTAssertEqual(memory.label(for: phone.author.fingerprint)?.label, "Denvre")

        try RegistryAdmission.rename(
            person: phone.author.fingerprint, to: "Denver", in: projectURL,
            by: mine.author, cache: makeCache(), memory: memory,
            now: { Date(timeIntervalSince1970: 500) })

        XCTAssertEqual(memory.label(for: phone.author.fingerprint)?.label, "Denver")
        XCTAssertEqual(memory.label(for: phone.author.fingerprint)?.labelledAt,
                       Date(timeIntervalSince1970: 500),
                       "and the day the writer decided is the day they renamed")
    }

    // MARK: - Fixtures for the two verbs

    /// Put a field this build has no property for into a record already on
    /// disk, and re-sign it the way the later build that wrote it would have —
    /// over the whole object, unknown field included.
    private func plantUnknownField(
        _ key: String, _ value: Int, inPersonRecordOf device: LocalIdentities
    ) throws {
        try plantUnknownField(
            key, value,
            at: personFile(device.author.fingerprint), signedBy: mine.author)
    }

    private func plantUnknownField(
        _ key: String, _ value: Int, inDeviceRecordOf device: LocalIdentities
    ) throws {
        try plantUnknownField(
            key, value,
            at: RegistryWriter.url(
                .devices, fingerprint: device.author.fingerprint, in: projectURL),
            signedBy: device.author)
    }

    private func plantUnknownField(
        _ key: String, _ value: Int, at url: URL, signedBy identity: DeviceIdentity
    ) throws {
        var object = try jsonObject(at: url)
        object[key] = value
        object.removeValue(forKey: "sig")
        let unsigned = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let credentials = try OpLogChain.credentials(
            signing: try RegistryCanonical.digestHex(ofJSON: unsigned),
            identity: identity)
        object["sig"] = try JSONSerialization.jsonObject(
            with: try RegistryCanonical.bytes(of: credentials))
        try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        ).write(to: url, options: .atomic)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url))
                as? [String: Any])
    }

    private func jsonObjectOfPersonFile(_ fingerprint: String) throws -> [String: Any] {
        try jsonObject(at: personFile(fingerprint))
    }

    // MARK: - The permit verbs (P3a Task 7, spec §6)

    /// Every event this folder holds about one subject, oldest first.
    private func events(about subject: String) throws -> [PermitEvent] {
        try registry().events
            .filter { $0.subject == subject }
            .sorted { $0.event < $1.event }
    }

    private func kinds(about subject: String) throws -> [PermitEvent.Kind] {
        try events(about: subject).map(\.kind)
    }

    private func mark(_ key: String, line: String) -> PermitMark {
        PermitMark([key: .init(line: line)])
    }

    // MARK: Admission writes its own kind

    /// A stranger nobody has heard of is `admitted`, and the event carries the
    /// rung the writer chose — which is the whole of what makes the
    /// admission's permit govern everything she wrote while she was held
    /// (`PermitTimeline.opening(before:)`).
    func test_admittingAStrangerWritesAnAdmittedEventCarryingTheRung() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")

        try RegistryAdmission.admit(
            device: phone.author.fingerprint, label: "Sam",
            ownName: "Denver's iPhone",
            role: Permit.reviewerRole, scope: Permit.bookScope,
            mark: mark("d-one.slug", line: "hash-1"),
            // A narrowing admission carries the photograph; this fixture
            // writes no op log, so a sweep of it answers empty (P3b Task 1).
            unsigned: .nothingApplied,
            in: projectURL, by: mine.author,
            cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 10) })

        let written = try events(about: phone.author.fingerprint)
        XCTAssertEqual(written.map(\.kind), [.admitted])
        XCTAssertEqual(Permit(event: try XCTUnwrap(written.first)), .reviewer)
        XCTAssertEqual(written.first?.by, mine.author.fingerprint)
        XCTAssertEqual(written.first?.mark["d-one.slug"]?.line, "hash-1")
        XCTAssertEqual(
            try registry().person(phone.author.fingerprint)?.role,
            Permit.reviewerRole)
    }

    /// **A re-admission is `readmitted`, never `admitted`** (Task 7's first
    /// ruling). The difference is not cosmetic: an `admitted` event's permit
    /// governs everything the person ever wrote, so a P2 author let back in as
    /// a reviewer would have her old chapters refused retroactively.
    func test_readmittingSomebodyRevokedWritesReadmittedAndNotAdmitted() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01AAAAAAAAAAAAAAAAAAAAAAAA", cache: makeCache(),
            now: { Date(timeIntervalSince1970: 20) })

        try RegistryAdmission.admit(
            device: phone.author.fingerprint, label: "Denver",
            ownName: "Denver's iPhone",
            role: Permit.reviewerRole,
            mark: mark("d-one.slug", line: "hash-2"),
            unsigned: .nothingApplied,
            in: projectURL, by: mine.author,
            cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 30) })

        XCTAssertEqual(
            try kinds(about: phone.author.fingerprint),
            [.admitted, .revoked, .readmitted],
            "the revocation survives the clearing of its own record fields")
        let last = try XCTUnwrap(try events(about: phone.author.fingerprint).last)
        XCTAssertEqual(Permit(event: last), .reviewer)
        XCTAssertEqual(last.mark["d-one.slug"]?.line, "hash-2")
    }

    /// The memory path's word (C11). `silentlyAdmitted` has existed on
    /// `TrustEvent.Kind` since P2b with nothing to write it; this is its
    /// writer, and it is what History reads to say *let in because you had
    /// already named this machine* rather than *you were asked*.
    func test_theRememberedAdmissionWritesSilentlyAdmitted() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let memory = makeMemory()
        memory.remember(
            phone.author.fingerprint, label: "Denver",
            ownName: "Denver's iPhone", at: Date(timeIntervalSince1970: 1))

        let admitted = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: makeCache(), memory: memory,
            mark: { _ in self.mark("d-one.slug", line: "hash-3") },
            now: { Date(timeIntervalSince1970: 10) })

        XCTAssertEqual(admitted.count, 1)
        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.silentlyAdmitted])
        XCTAssertEqual(
            try events(about: phone.author.fingerprint).first?.mark["d-one.slug"]?.line,
            "hash-3",
            "the mark is asked per device actually admitted, and used")
    }

    /// The converse of both: admitting the same device twice under the same
    /// label writes no SECOND event, for the reason it writes no second record.
    func test_anIdempotentAdmissionWritesNoSecondEvent() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try admitThePhone()

        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted])
    }

    /// And a LABEL correction through `admit` moves no permit and writes no
    /// event: renaming somebody is not admitting them again, and it is
    /// certainly not demoting them. Without this, a sheet that pre-filled
    /// *author* over a reviewer's corrected name would have rewritten what she
    /// may write with nothing in the history to say so.
    func test_correctingALabelThroughAdmitMovesNoPermitAndWritesNoEvent() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try RegistryAdmission.admit(
            device: phone.author.fingerprint, label: "Sam",
            ownName: "Denver's iPhone", role: Permit.reviewerRole,
            unsigned: .nothingApplied,
            in: projectURL, by: mine.author,
            cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 10) })

        try RegistryAdmission.admit(
            device: phone.author.fingerprint, label: "Samantha",
            ownName: "Denver's iPhone",
            in: projectURL, by: mine.author,
            cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 20) })

        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted])
        let record = try XCTUnwrap(try registry().person(phone.author.fingerprint))
        XCTAssertEqual(record.label, "Samantha")
        XCTAssertEqual(record.role, Permit.reviewerRole, "the rename moved no permit")
    }

    /// A plain author-of-the-whole-book admission writes neither `scope` nor
    /// `pieces` onto the record — the format's own rule is that a missing
    /// scope MEANS the whole book, and a P3 build stating it would move the
    /// bytes of every record for a fact they already state.
    func test_anOrdinaryAdmissionsRecordCarriesNeitherScopeNorPieces() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()

        let object = try jsonObjectOfPersonFile(phone.author.fingerprint)
        XCTAssertNil(object["scope"])
        XCTAssertNil(object["pieces"])
        XCTAssertEqual(
            try registry().person(phone.author.fingerprint).map {
                Permit.parse(role: $0.role, scope: $0.scope, pieces: $0.pieces)
            },
            .bookAuthor)
    }

    // MARK: changePermit

    private func changeThePhone(
        to permit: Permit, mark: PermitMark = .nothingApplied,
        at when: Date = Date(timeIntervalSince1970: 50),
        by root: DeviceIdentity? = nil
    ) throws -> PersonRecord {
        try RegistryAdmission.changePermit(
            person: phone.author.fingerprint,
            role: permit.wireRole, scope: permit.wireScope,
            pieces: permit.wirePieces, mark: mark,
            // **The photograph a narrowing carries** (P3b Task 1). These
            // fixtures write no op log at all, so a real sweep of them answers
            // exactly this — pinned by
            // `UnsignedSnapshotTests.test_aBookWithNoHistoryPhotographsNothing`
            // rather than assumed here.
            unsigned: .nothingApplied,
            in: projectURL, by: root ?? mine.author, cache: makeCache(),
            now: { when })
    }

    /// The verb, whole: an event carrying the new permit and the mark, then a
    /// re-signed record that says the same thing.
    func test_changingAPermitWritesTheEventAndThenTheRecord() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()

        let record = try changeThePhone(
            to: .reviewer, mark: mark("d-one.slug", line: "hash-9"))

        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted, .roleChanged])
        let event = try XCTUnwrap(try events(about: phone.author.fingerprint).last)
        XCTAssertEqual(Permit(event: event), .reviewer)
        XCTAssertEqual(event.mark["d-one.slug"]?.line, "hash-9")
        XCTAssertEqual(event.by, mine.author.fingerprint)
        XCTAssertEqual(record.role, Permit.reviewerRole)
        XCTAssertEqual(record.scope, Permit.bookScope)
        XCTAssertEqual(record.pieces, [])
        XCTAssertFalse(
            RegistryAdmission.recordBehindEvents(
                person: phone.author.fingerprint, in: try registry()),
            "both writes landed, so nothing is behind anything")
    }

    /// A change of SCOPE is `scopeChanged`, not `roleChanged`, so History says
    /// *became an author of two pieces* rather than *became an author*.
    func test_narrowingToPiecesIsScopeChangedAndWritesTheList() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()

        let record = try changeThePhone(to: .author(.pieces(["d-two", "d-one"])))

        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted, .scopeChanged])
        XCTAssertEqual(record.scope, Permit.piecesScope)
        XCTAssertEqual(record.pieces, ["d-one", "d-two"], "sorted, so two Macs agree")
        XCTAssertEqual(
            Permit.parse(role: record.role, scope: record.scope, pieces: record.pieces),
            .author(.pieces(["d-one", "d-two"])))
    }

    /// **An author of NO pieces yet is legal** (spec §3.1) — *she may write
    /// what she starts* — so an empty list is not a refusal and not a nil.
    func test_anAuthorOfNoPiecesYetIsAPermitAndNotARefusal() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()

        let record = try changeThePhone(to: .author(.pieces([])))

        XCTAssertEqual(record.scope, Permit.piecesScope)
        XCTAssertEqual(record.pieces, [])
        XCTAssertEqual(
            Permit.parse(role: record.role, scope: record.scope, pieces: record.pieces),
            .author(.pieces([])))
    }

    /// **Idempotent against the TIMELINE** (Task 7's fifth ruling): the permit
    /// somebody already holds writes no event and no record.
    func test_changingToThePermitAlreadyHeldWritesNothing() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try changeThePhone(to: .reviewer, at: Date(timeIntervalSince1970: 50))
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        try changeThePhone(to: .reviewer, at: Date(timeIntervalSince1970: 60))

        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted, .roleChanged])
        XCTAssertEqual(try bytesOfPersonFile(phone.author.fingerprint), bytes)
    }

    /// And the P2-era half of the same rule: somebody with NO events is an
    /// author of the whole book, so asking for that writes nothing at all.
    func test_changingAP2PersonToWhatTheyAlreadyAreWritesNothing() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        try changeThePhone(to: .bookAuthor)

        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted])
        XCTAssertEqual(try bytesOfPersonFile(phone.author.fingerprint), bytes)
    }

    /// **A root may not be narrowed** — a book must not end up with no author.
    func test_aRootsPermitCannotBeChanged() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        XCTAssertThrowsError(try RegistryAdmission.changePermit(
            person: mine.author.fingerprint,
            role: Permit.reviewerRole, scope: Permit.bookScope, pieces: [],
            mark: .nothingApplied, in: projectURL, by: mine.author,
            cache: makeCache())
        ) { error in
            XCTAssertEqual(
                error as? RegistryAdmissionError,
                .cannotChangeARoot(fingerprint: mine.author.fingerprint))
        }
        XCTAssertTrue(try events(about: mine.author.fingerprint).isEmpty)
    }

    /// A Mac that is no root here changes nothing, whoever it is about.
    func test_aNonRootCannotChangeAPermit() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()

        XCTAssertThrowsError(try changeThePhone(to: .reviewer, by: otherRoot.author)) {
            XCTAssertEqual($0 as? RegistryAdmissionError, .notARoot)
        }
        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted])
    }

    /// Somebody this book has never heard of.
    func test_changingThePermitOfSomebodyUnknownRefuses() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        XCTAssertThrowsError(try changeThePhone(to: .reviewer)) {
            XCTAssertEqual(
                $0 as? RegistryAdmissionError,
                .notAdmitted(fingerprint: phone.author.fingerprint))
        }
    }

    /// Somebody another root let in. Their record is not mine to re-sign, and
    /// their permit is not mine to move.
    func test_changingAPermitUnderAnotherRootRefuses() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try becomeRootBeside(otherRoot, name: "The other MacBook")
        try declare(phone, name: "Denver's iPhone")
        try RegistryAdmission.admit(
            device: phone.author.fingerprint, label: "Sam", ownName: "Denver's iPhone",
            in: projectURL, by: otherRoot.author,
            cache: RegistryCache(
                fileURL: otherCacheURL, identity: otherRoot.author.fingerprint),
            memory: makeMemory(), now: { Date(timeIntervalSince1970: 10) })

        XCTAssertThrowsError(try changeThePhone(to: .reviewer)) {
            XCTAssertEqual(
                $0 as? RegistryAdmissionError,
                .alreadyAdmittedElsewhere(root: otherRoot.author.fingerprint))
        }
        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted])
    }

    /// A record present on disk and unreadable is not a record that is absent
    /// (RULING-54): the change refuses rather than writing over somebody
    /// else's half-synced admission.
    func test_changingAPermitOverAnUnreadableRecordRefuses() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try plantUnreadablePersonRecord(for: phone)

        XCTAssertThrowsError(try changeThePhone(to: .reviewer)) {
            XCTAssertEqual(
                $0 as? RegistryAdmissionError,
                .recordUnreadable(fingerprint: phone.author.fingerprint))
        }
        XCTAssertTrue(try events(about: phone.author.fingerprint).isEmpty)
    }

    // MARK: The mark's monotonicity (Task 7's third ruling)

    /// **A stream the new mark does not name keeps the position an older event
    /// gave it.** The two marks are both *everything this root has read*, so
    /// the new one is a superset by construction — unless this Mac's copy of
    /// the folder has LOST a file, and then dropping the stream would judge
    /// the whole of it NEW under the new permit, which for a demotion is a
    /// reach-back through every line of it.
    func test_aStreamMissingFromANewMarkKeepsItsOlderPosition() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try changeThePhone(
            to: .author(.pieces(["d-one"])),
            mark: PermitMark([
                "d-one.slug": .init(line: "one-1"),
                "d-two.slug": .init(line: "two-1"),
            ]),
            at: Date(timeIntervalSince1970: 50))

        try changeThePhone(
            to: .reviewer,
            mark: PermitMark(["d-one.slug": .init(line: "one-2")]),
            at: Date(timeIntervalSince1970: 60))

        let latest = try XCTUnwrap(try events(about: phone.author.fingerprint).last)
        XCTAssertEqual(latest.mark["d-one.slug"]?.line, "one-2", "its own answer stands")
        XCTAssertEqual(
            latest.mark["d-two.slug"]?.line, "two-1",
            "a stream the sweep could not reach keeps where the root had got to")
    }

    /// The newest older position is the one carried, not the first one found.
    func test_theCarriedPositionIsTheNewestTheRootEverRecorded() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try changeThePhone(
            to: .author(.pieces(["d-one"])),
            mark: PermitMark(["d-two.slug": .init(line: "two-1")]),
            at: Date(timeIntervalSince1970: 50))
        try changeThePhone(
            to: .author(.pieces(["d-one", "d-two"])),
            mark: PermitMark(["d-two.slug": .init(line: "two-2")]),
            at: Date(timeIntervalSince1970: 60))

        try changeThePhone(
            to: .reviewer, mark: .nothingApplied,
            at: Date(timeIntervalSince1970: 70))

        XCTAssertEqual(
            try XCTUnwrap(try events(about: phone.author.fingerprint).last)
                .mark["d-two.slug"]?.line,
            "two-2")
    }

    /// **A stream that came back NAMED and SHORT keeps the segments an older
    /// event listed** (final fix wave, W2).
    ///
    /// The carry-forward used to be per KEY — it filled in whole streams and
    /// stopped there — so a sweep that answered a stream with its new tail's
    /// line and none of its digests recorded a position that had FORGOTTEN
    /// segments an earlier event already listed. Every line inside them then
    /// judged NEW under the permit this event installs, which for a demotion is
    /// the reach-back the per-key rule was written to prevent, arriving one
    /// field lower down. These marks only ever grow, so the union is the
    /// honest merge; the LINE is a single position in the live tail, so an
    /// older one is kept only where the new sweep found none.
    func test_aStreamAnsweringShortKeepsTheSegmentsAnOlderEventListed() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try changeThePhone(
            to: .author(.pieces(["d-one"])),
            mark: PermitMark([
                "d-one.slug": .init(segments: ["seg-a", "seg-b"], line: "one-1"),
            ]),
            at: Date(timeIntervalSince1970: 50))

        // The sweep answers the same stream, with the new tail and without the
        // segments — the rotation-mid-sync shape.
        try changeThePhone(
            to: .reviewer,
            mark: PermitMark(["d-one.slug": .init(segments: [], line: "one-2")]),
            at: Date(timeIntervalSince1970: 60))

        let latest = try XCTUnwrap(try events(about: phone.author.fingerprint).last)
        XCTAssertEqual(latest.mark["d-one.slug"]?.line, "one-2",
                       "its own line stands")
        XCTAssertEqual(latest.mark["d-one.slug"]?.segments, ["seg-a", "seg-b"],
                       "and the segments the root had already read are kept")
    }

    /// **The union is a UNION**: segments this sweep found and segments an
    /// older event listed, sorted, with no duplicate.
    func test_theSegmentsOfTwoEventsAreUnionedAndSorted() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try changeThePhone(
            to: .author(.pieces(["d-one"])),
            mark: PermitMark(["d-one.slug": .init(segments: ["seg-b", "seg-a"])]),
            at: Date(timeIntervalSince1970: 50))
        try changeThePhone(
            to: .reviewer,
            mark: PermitMark(["d-one.slug": .init(segments: ["seg-c", "seg-a"])]),
            at: Date(timeIntervalSince1970: 60))

        XCTAssertEqual(
            try XCTUnwrap(try events(about: phone.author.fingerprint).last)
                .mark["d-one.slug"]?.segments,
            ["seg-a", "seg-b", "seg-c"])
    }

    /// **And a REVOCATION carries nothing forward, in this field either.**
    /// *Set aside everything it wrote* is an empty mark on purpose, and a
    /// union that filled it in would keep the whole of the history the writer
    /// had just asked to have taken out — the same reason `carriesForward`
    /// excludes it per key.
    func test_aRevocationsEmptyMarkIsNotFilledInByTheUnionEither() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try changeThePhone(
            to: .author(.pieces(["d-one"])),
            mark: PermitMark(["d-one.slug": .init(segments: ["seg-a"], line: "one-1")]),
            at: Date(timeIntervalSince1970: 50))

        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: nil, mark: .nothingApplied, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 60) })

        let latest = try XCTUnwrap(try events(about: phone.author.fingerprint).last)
        XCTAssertEqual(latest.kind, .revokedEntirely)
        XCTAssertTrue(latest.mark.isEmpty,
                      "nothing kept: that is what the writer asked for")
    }

    // MARK: recordBehindEvents (spec §3.2's crash window)

    /// Nobody in a book written before P3 is behind anything.
    func test_aPersonWithNoEventsIsNotBehindTheirHistory() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()

        XCTAssertFalse(RegistryAdmission.recordBehindEvents(
            person: phone.author.fingerprint, in: try registry()))
    }

    /// The window itself: the event landed and the record did not. Enforcement
    /// is already correct — the role check reads the timeline — and this is
    /// the fact P3b's pane states and offers to re-sign.
    func test_anEventWithNoRecordBehindItIsDetected() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try changeThePhone(to: .reviewer)
        // The record that landed second, removed: the crash, after the fact.
        try FileManager.default.removeItem(
            at: personFile(phone.author.fingerprint))

        XCTAssertTrue(RegistryAdmission.recordBehindEvents(
            person: phone.author.fingerprint, in: try registry()))
    }

    /// And the other direction, which is the same disagreement: a record
    /// naming a permit no event installed.
    func test_aRecordSayingSomethingNoEventInstalledIsDetected() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try changeThePhone(to: .reviewer)
        try RegistryWriter.resign(
            try XCTUnwrap(try registry().person(phone.author.fingerprint)),
            signedBy: mine.author, in: projectURL
        ) { object in
            object["role"] = Permit.authorRole
        }

        XCTAssertTrue(RegistryAdmission.recordBehindEvents(
            person: phone.author.fingerprint, in: try registry()))
    }

    /// A revocation installs no permit, so there is nothing for a record to be
    /// behind — and a person revoked in a P2-era book must not light up a
    /// *your record is out of date* notice for the rest of time.
    func test_aRevocationAloneLeavesNothingBehind() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01AAAAAAAAAAAAAAAAAAAAAAAA", cache: makeCache(),
            now: { Date(timeIntervalSince1970: 20) })

        XCTAssertFalse(RegistryAdmission.recordBehindEvents(
            person: phone.author.fingerprint, in: try registry()))
    }

    // MARK: Revocation and retirement write their own events

    /// The default revocation: an event carrying the positions this Mac had
    /// APPLIED, beside the opId the record has always carried.
    func test_revokingWritesARevokedEventCarryingItsPositions() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()

        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01AAAAAAAAAAAAAAAAAAAAAAAA",
            mark: mark("d-one.slug", line: "hash-r"), cache: makeCache(),
            now: { Date(timeIntervalSince1970: 20) })

        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted, .revoked])
        let event = try XCTUnwrap(try events(about: phone.author.fingerprint).last)
        XCTAssertEqual(event.mark["d-one.slug"]?.line, "hash-r")
        XCTAssertEqual(
            try registry().person(phone.author.fingerprint)?.highestOpIdSeen,
            "01AAAAAAAAAAAAAAAAAAAAAAAA",
            "the P2 wire form is written exactly as it was")
    }

    /// *Set aside everything it wrote* is `revokedEntirely` with an EMPTY
    /// mark, which judges every line new — `nothingAppliedMark`'s meaning said
    /// in positions.
    func test_revokingEntirelyWritesAnEmptyMark() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()

        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: nil, mark: .nothingApplied, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 20) })

        XCTAssertEqual(
            try kinds(about: phone.author.fingerprint), [.admitted, .revokedEntirely])
        XCTAssertTrue(
            try XCTUnwrap(try events(about: phone.author.fingerprint).last).mark.isEmpty)
    }

    /// A retirement is the one event a DEVICE signs for itself, which is why
    /// `RegistryReader` lets it through on `subject == by` alone.
    func test_retiringWritesAnEventSignedByTheDeviceItself() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        try RegistryAdmission.retire(
            device: mine.author.fingerprint, in: projectURL, by: mine.author,
            mark: mark("d-one.mine", line: "hash-t"), cache: makeCache(),
            now: { Date(timeIntervalSince1970: 30) })

        let written = try events(about: mine.author.fingerprint)
        XCTAssertEqual(written.map(\.kind), [.retired])
        XCTAssertEqual(written.first?.by, mine.author.fingerprint)
        XCTAssertEqual(written.first?.mark["d-one.mine"]?.line, "hash-t")
        XCTAssertEqual(
            written.first.map(Permit.init), .bookAuthor,
            "a root's own retirement must carry the root's own permit, or the "
                + "reader lists it malformed")
    }

    /// A second press on either writes no second event, for the reason it
    /// writes no second record: the date, and now the position, is the line.
    func test_asecondRevocationOrRetirementWritesNoSecondEvent() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        for when in [20.0, 25.0] {
            try RegistryAdmission.revoke(
                person: phone.author.fingerprint, in: projectURL, by: mine.author,
                highestOpIdSeen: "01AAAAAAAAAAAAAAAAAAAAAAAA", cache: makeCache(),
                now: { Date(timeIntervalSince1970: when) })
        }
        for when in [30.0, 35.0] {
            try RegistryAdmission.retire(
                device: mine.author.fingerprint, in: projectURL, by: mine.author,
                cache: makeCache(), now: { Date(timeIntervalSince1970: when) })
        }

        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted, .revoked])
        XCTAssertEqual(try kinds(about: mine.author.fingerprint), [.retired])
    }

    /// **Every event this milestone writes is read back by the reader that
    /// judges it.** Nothing above is worth anything if the folder holds files
    /// `RegistryReader` lists as malformed, and the authority check it applies
    /// is not one these verbs can see.
    func test_everyEventTheseVerbsWriteVerifies() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try changeThePhone(to: .author(.pieces(["d-one"])))
        try changeThePhone(to: .reviewer, at: Date(timeIntervalSince1970: 60))
        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01AAAAAAAAAAAAAAAAAAAAAAAA", cache: makeCache(),
            now: { Date(timeIntervalSince1970: 70) })
        try RegistryAdmission.admit(
            device: phone.author.fingerprint, label: "Denver",
            ownName: "Denver's iPhone", in: projectURL, by: mine.author,
            cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 80) })
        try RegistryAdmission.retire(
            device: mine.author.fingerprint, in: projectURL, by: mine.author,
            cache: makeCache(), now: { Date(timeIntervalSince1970: 90) })

        let read = try registry()
        XCTAssertEqual(read.events.count, 6)
        XCTAssertTrue(
            read.malformed.isEmpty,
            "listed malformed: \(read.malformed.map { $0.url.lastPathComponent })")
        XCTAssertEqual(
            try kinds(about: phone.author.fingerprint),
            [.admitted, .scopeChanged, .roleChanged, .revoked, .readmitted])
    }

    // MARK: - The claim's five minors (C8)

    /// **The root write is gated on MY ROOT, not on the folder.** A device
    /// that has JOINED somebody's chain and whose person record has not come
    /// down yet reads as absent from the registry, and used to be written a
    /// self-signed root of its own — a second root in a book it is already on
    /// somebody else's chain in.
    func test_aDeviceThatJoinedAChainDoesNotRootItselfByClaiming() throws {
        try becomeRootBeside(otherRoot, name: "The old MacBook")
        try declare(mine, name: "Denver's new MacBook", kind: .mac)
        let cache = makeCache()
        _ = cache.join(root: otherRoot.author.fingerprint, for: projectURL)

        XCTAssertThrowsError(try RegistryAdmission.claim(
            adopting: [otherRoot.author.fingerprint], in: projectURL,
            by: mine.author, cache: cache, now: { Date(timeIntervalSince1970: 100) })
        ) {
            XCTAssertEqual(
                $0 as? RegistryAdmissionError,
                .alreadyAdmittedElsewhere(root: otherRoot.author.fingerprint))
        }
        XCTAssertNil(try registry().person(mine.author.fingerprint))
    }

    /// **A claim file present and unverifiable is LISTED, never written over.**
    /// The `else` branch used to write a fresh claim straight across it,
    /// silently dropping every root the unreadable one had taken in.
    func test_anUnverifiableClaimFileIsNotWrittenOver() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try becomeRootBeside(otherRoot, name: "The old MacBook")
        try RegistryWriter.writeUnchecked(
            ClaimRecord(
                newRoot: mine.author.fingerprint,
                adopted: [otherRoot.author.fingerprint],
                claimedAt: Date(timeIntervalSince1970: 100)),
            signedBy: phone.author, in: projectURL)
        let bytes = try Data(contentsOf: claimFile(mine.author.fingerprint))

        XCTAssertThrowsError(try RegistryAdmission.claim(
            adopting: [otherRoot.author.fingerprint], in: projectURL,
            by: mine.author, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 200) })
        ) {
            XCTAssertEqual(
                $0 as? RegistryAdmissionError,
                .recordUnreadable(fingerprint: mine.author.fingerprint))
        }
        XCTAssertEqual(
            try Data(contentsOf: claimFile(mine.author.fingerprint)), bytes)
    }

    /// **A root taken in has to BE one.** `chain(underRoot:)` answers empty
    /// for anything else, so such a claim was written, verified and adopted
    /// nobody — a merge the book accepted and that changed nothing.
    func test_adoptingSomethingThatIsNoRootRefuses() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")

        XCTAssertThrowsError(try RegistryAdmission.claim(
            adopting: [phone.author.fingerprint], in: projectURL,
            by: mine.author, cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })
        ) {
            XCTAssertEqual(
                $0 as? RegistryAdmissionError,
                .cannotAdoptANonRoot(fingerprint: phone.author.fingerprint))
        }
        XCTAssertTrue(try registry().claims.isEmpty)
    }

    // MARK: - The crash window: event landed, record did not (fix round 1, I1)

    /// Plants the event a verb would write, WITHOUT its record — the state the
    /// write order leaves behind when `resign`/`write` throws. Signed by the
    /// root, so the reader verifies it exactly as the verb's own would be.
    @discardableResult
    private func plantEvent(
        _ kind: PermitEvent.Kind, about subject: String,
        permit: Permit = .bookAuthor,
        by signer: DeviceIdentity? = nil,
        at when: Date = Date(timeIntervalSince1970: 40),
        id: String? = nil
    ) throws -> PermitEvent {
        let event = PermitEvent(
            event: id ?? PermitEvent.mintID(subject: subject), kind: kind,
            subject: subject, role: permit.wireRole, scope: permit.wireScope,
            pieces: permit.wirePieces, mark: [:], at: when,
            by: signer?.fingerprint ?? mine.author.fingerprint)
        try RegistryWriter.write(
            event, signedBy: signer ?? mine.author, in: projectURL)
        return event
    }

    /// **The retry HEALS the record and writes no second event** (I1).
    ///
    /// Before this, `changePermit`'s only question was the timeline's, and it
    /// ran before the record write — so a press after the event had landed
    /// found the history already saying *reviewer*, returned the STALE author
    /// record with no error and no write, and left P3b's pane drawing *author*
    /// over a person every reader enforces as a reviewer, forever.
    func test_changePermitAfterTheEventLandedWritesTheRecordAndNoSecondEvent() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try plantEvent(.roleChanged, about: phone.author.fingerprint, permit: .reviewer)
        XCTAssertTrue(
            RegistryAdmission.recordBehindEvents(
                person: phone.author.fingerprint, in: try registry()),
            "the crash window, as the next press finds it")

        let record = try changeThePhone(to: .reviewer)

        XCTAssertEqual(record.role, Permit.reviewerRole, "the record caught up")
        XCTAssertEqual(
            try kinds(about: phone.author.fingerprint), [.admitted, .roleChanged],
            "and no second event was written")
        XCTAssertFalse(RegistryAdmission.recordBehindEvents(
            person: phone.author.fingerprint, in: try registry()))
    }

    /// The other half of the same two-part question: where the RECORD is the
    /// one already saying it and no event installed it, the event is written
    /// and the record is left alone.
    func test_changePermitOverARecordAheadOfItsHistoryWritesTheEventOnly() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try RegistryWriter.resign(
            try XCTUnwrap(try registry().person(phone.author.fingerprint)),
            signedBy: mine.author, in: projectURL
        ) { object in
            object["role"] = Permit.reviewerRole
            object["scope"] = Permit.bookScope
            object["pieces"] = [String]()
        }
        let bytes = try bytesOfPersonFile(phone.author.fingerprint)

        try changeThePhone(to: .reviewer)

        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted, .roleChanged])
        XCTAssertEqual(
            try bytesOfPersonFile(phone.author.fingerprint), bytes,
            "a record that already says it is not re-signed for nothing")
    }

    /// **A retry after an ADMISSION's event landed writes one event, not two**
    /// (minor 2). For the silent path this state is re-entered at every
    /// project OPEN, so the duplicate was per open for as long as it lasted.
    func test_theSilentAdmissionAfterItsEventLandedWritesNoSecondEvent() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        let memory = makeMemory()
        memory.remember(
            phone.author.fingerprint, label: "Denver",
            ownName: "Denver's iPhone", at: Date(timeIntervalSince1970: 1))
        try plantEvent(.silentlyAdmitted, about: phone.author.fingerprint)

        try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: makeCache(), memory: memory,
            now: { Date(timeIntervalSince1970: 10) })

        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.silentlyAdmitted])
        XCTAssertNotNil(
            try registry().person(phone.author.fingerprint),
            "and the record it was missing is written")
    }

    /// The revocation's twin, and the sharper of the two: a second event would
    /// draw a second line, at a LATER position than the writer ever chose.
    func test_revokingAfterItsEventLandedWritesNoSecondEvent() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try plantEvent(.revoked, about: phone.author.fingerprint)

        try RegistryAdmission.revoke(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01AAAAAAAAAAAAAAAAAAAAAAAA", cache: makeCache(),
            now: { Date(timeIntervalSince1970: 20) })

        XCTAssertEqual(try kinds(about: phone.author.fingerprint), [.admitted, .revoked])
        XCTAssertTrue(try XCTUnwrap(try registry().person(phone.author.fingerprint)).isRevoked)
    }

    /// And the retirement's.
    func test_retiringAfterItsEventLandedWritesNoSecondEvent() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try plantEvent(
            .retired, about: mine.author.fingerprint, by: mine.author)

        try RegistryAdmission.retire(
            device: mine.author.fingerprint, in: projectURL, by: mine.author,
            cache: makeCache(), now: { Date(timeIntervalSince1970: 30) })

        XCTAssertEqual(try kinds(about: mine.author.fingerprint), [.retired])
        XCTAssertNotNil(
            try registry().devices.first { $0.device == mine.author.fingerprint }?.retiredAt)
    }

    // MARK: - Event ids never go backwards (fix round 1, minor 6)

    /// **A clock that stepped back does not reorder the history.** A ULID is
    /// monotonic within a PROCESS only, and everything that reads these events
    /// reads them in id order: the timeline's newest permit, and the
    /// revocation mark. Both decide what a reader APPLIES, and neither goes
    /// red when they are read backwards.
    ///
    /// The falsification is a planted event dated far in the FUTURE, which is
    /// the same condition seen from the other side and needs no clock to
    /// arrange.
    func test_anEventMintedUnderAStaleClockStillSortsAfterTheLatest() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        // An id whose ULID timestamp is thousands of years out — what a Mac
        // whose clock ran fast wrote, and what this Mac's honest clock now
        // sorts before. Not the MAXIMUM timestamp: 50 bits of milliseconds has
        // a ceiling and nothing can be minted past it (`ULID.maxMillis`),
        // which is a limit of the format rather than of the guard.
        let future = "\(phone.author.fingerprint).9ZZZZZZZZZ0000000000000000"
        try plantEvent(
            .roleChanged, about: phone.author.fingerprint, permit: .reviewer,
            id: future)

        try changeThePhone(to: .author(.pieces(["d-one"])))

        let written = try events(about: phone.author.fingerprint)
        let newest = try XCTUnwrap(written.last)
        // A role change rather than a scope one, because the planted event has
        // already made her a reviewer — which is the point: the verb read the
        // planted event as the CURRENT permit, so the id it mints must sort
        // after it or the next reader will read the two the other way round.
        XCTAssertEqual(
            written.map(\.kind), [.admitted, .roleChanged, .roleChanged])
        XCTAssertGreaterThan(
            newest.event, future,
            "a fresh id that did not sort after the latest is re-minted past it")
        XCTAssertEqual(
            PermitTimeline(events: written).current, .author(.pieces(["d-one"])),
            "so the timeline's newest permit is the one just written")
    }

    // MARK: - Every machine of one writer (fix round 1, I3)

    /// Two records under one label are one writer, and the label rule is
    /// `TrustTable.sharesLabel`'s — the same one the ownership join uses.
    func test_recordsSharingALabelAreFoundAndTheSubjectLeads() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Sam's iPhone")
        let second = LocalIdentities.softwareForTesting()
        try declare(second, name: "Sam's iPad")
        try admitThePhone(label: "Sam", ownName: "Sam's iPhone")
        try RegistryAdmission.admit(
            device: second.author.fingerprint, label: "Sam", ownName: "Sam's iPad",
            in: projectURL, by: mine.author, cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 12) })

        let found = RegistryAdmission.records(
            sharingLabelWith: phone.author.fingerprint, in: try registry())

        XCTAssertEqual(found.first?.person, phone.author.fingerprint, "the subject leads")
        XCTAssertEqual(
            Set(found.map(\.person)),
            [phone.author.fingerprint, second.author.fingerprint])
    }

    /// **An unnamed machine shares with nobody**, because folding two empty
    /// labels together would make *unnamed* an identity — and for a permit
    /// that means a demotion reaching a device the writer never named.
    func test_anUnnamedRecordSharesWithNobody() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "A phone")
        let second = LocalIdentities.softwareForTesting()
        try declare(second, name: "Another phone")
        let both: [LocalIdentities] = [phone, second]
        for device in both {
            try RegistryWriter.write(
                PersonRecord(
                    person: device.author.fingerprint, label: "", ownName: "",
                    admittedAt: Date(timeIntervalSince1970: 10),
                    admittedBy: mine.author.fingerprint),
                signedBy: mine.author, in: projectURL)
        }

        let found = RegistryAdmission.records(
            sharingLabelWith: phone.author.fingerprint, in: try registry())

        XCTAssertEqual(found.map(\.person), [phone.author.fingerprint])
        XCTAssertFalse(TrustTable.sharesLabel("", ""))
        XCTAssertFalse(TrustTable.sharesLabel("Sam", nil))
        XCTAssertTrue(TrustTable.sharesLabel("Sam", "Sam"))
        XCTAssertFalse(TrustTable.sharesLabel("Sam", "sam"), "the root's own spelling")
    }

    /// The up-front refusal: a set holding a ROOT is refused entire, so the
    /// writer never lands half a demotion.
    func test_changePermitOutcomeRefusesARootBeforeAnythingIsWritten() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        guard case .failure(let error) = RegistryAdmission.changePermitOutcome(
            person: mine.author.fingerprint, by: mine.author.fingerprint,
            in: try registry())
        else { return XCTFail("a root's permit is not the root's to narrow") }
        XCTAssertEqual(error, .cannotChangeARoot(fingerprint: mine.author.fingerprint))
    }
}
