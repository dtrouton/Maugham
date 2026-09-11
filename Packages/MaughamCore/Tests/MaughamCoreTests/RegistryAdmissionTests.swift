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
        memoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("admission-memory-\(UUID().uuidString).json")
        mine = .softwareForTesting()
        phone = .softwareForTesting()
        otherRoot = .softwareForTesting()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
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
        try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: identities,
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
}
