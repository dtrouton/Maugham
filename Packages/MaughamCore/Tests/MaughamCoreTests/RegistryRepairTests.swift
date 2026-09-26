import Foundation
import XCTest
@testable import MaughamCore

/// **Putting a registry record right** (signed op log P3b Task 5).
///
/// Two repairs, both pressed deliberately by the writer and neither performed
/// at an open, because each writes over a file the reader has something to say
/// about.
///
/// 1. `RegistryAdmission.resignFromTimeline` — a person's record is a step
///    behind their history, which is the crash window of spec §3.2's
///    event-then-record order. Nothing about what is APPLIED is wrong (the role
///    check reads the timeline), so nothing refuses; what is wrong is that
///    every surface draws a permit the book is not enforcing.
/// 2. `RegistryPresence.writeOwnRecordAgain` — this device's own record will
///    not verify and this Mac holds no earlier bytes to Restore (audit PR #65's
///    F4, a cold `RegistryCache`). A device signing its own record is its
///    authority; a PERSON record is narrower, because re-writing one
///    self-signed makes this Mac a root.
final class RegistryRepairTests: XCTestCase {

    private var projectURL: URL!
    private var cacheURL: URL!
    private var memoryURL: URL!
    private var mine: LocalIdentities!
    private var phone: LocalIdentities!
    private var otherRoot: LocalIdentities!

    override func setUp() {
        super.setUp()
        projectURL = TestTemp.root
            .appendingPathComponent("repair-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        cacheURL = TestTemp.root
            .appendingPathComponent("repair-cache-\(UUID().uuidString).json")
        memoryURL = TestTemp.root
            .appendingPathComponent("repair-memory-\(UUID().uuidString).json")
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

    // MARK: - Fixture

    private func makeCache() -> RegistryCache {
        RegistryCache(fileURL: cacheURL, identity: mine.author.fingerprint)
    }

    private func makeMemory() -> AdmissionMemory {
        AdmissionMemory(fileURL: memoryURL, identity: mine.author.fingerprint)
    }

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    @discardableResult
    private func becomeRoot(_ identities: LocalIdentities, name: String) throws -> String {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: identities, name: name, kind: .mac,
            now: { Date(timeIntervalSince1970: 1) })
        try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: identities, writerName: name,
            now: { Date(timeIntervalSince1970: 2) })
        return identities.author.fingerprint
    }

    @discardableResult
    private func declare(
        _ identities: LocalIdentities, name: String, kind: DeviceKind = .phone
    ) throws -> String {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: identities, name: name, kind: kind,
            now: { Date(timeIntervalSince1970: 3) })
        return identities.author.fingerprint
    }

    @discardableResult
    private func admitThePhone() throws -> PersonRecord {
        try RegistryAdmission.admit(
            device: phone.author.fingerprint, label: "Denver",
            ownName: "Denver's iPhone", in: projectURL, by: mine.author,
            cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 10) })
    }

    /// A signed event with no matching record write — exactly what a crash
    /// between spec §3.2's two writes leaves behind.
    @discardableResult
    private func plantEvent(
        _ kind: PermitEvent.Kind, about subject: String, permit: Permit
    ) throws -> PermitEvent {
        let event = PermitEvent(
            event: PermitEvent.mintID(subject: subject), kind: kind,
            subject: subject, role: permit.wireRole, scope: permit.wireScope,
            pieces: permit.wirePieces, mark: [:],
            at: Date(timeIntervalSince1970: 40), by: mine.author.fingerprint)
        try RegistryWriter.write(event, signedBy: mine.author, in: projectURL)
        return event
    }

    private func eventKinds(about subject: String) throws -> [PermitEvent.Kind] {
        try registry().events
            .filter { $0.subject == subject }
            .sorted { $0.event < $1.event }
            .map(\.kind)
    }

    private func file(_ directory: RegistryDirectory, _ fingerprint: String) -> URL {
        RegistryWriter.url(directory, fingerprint: fingerprint, in: projectURL)
    }

    /// Bytes a reader refuses, at a path a reader looks in: the record is
    /// PRESENT and will not verify, which is not the same as absent
    /// (RULING-54) and is the whole premise of `writeOwnRecordAgain`.
    private func tamper(_ directory: RegistryDirectory, _ fingerprint: String) throws {
        let url = file(directory, fingerprint)
        var object = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: url)) as! [String: Any]
        object["name"] = "tampered"
        object["label"] = "tampered"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url)
    }

    // MARK: - resignFromTimeline

    /// **The crash window, closed by a press.** The event says reviewer and the
    /// record still says author; nothing is refused and nothing is wrong about
    /// what is applied, so no load and no other verb ever corrects it.
    func test_aRecordAStepBehindItsHistoryIsBroughtUpToIt() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try plantEvent(.roleChanged, about: phone.author.fingerprint, permit: .reviewer)
        XCTAssertTrue(RegistryAdmission.recordBehindEvents(
            person: phone.author.fingerprint, in: try registry()))

        let record = try RegistryAdmission.resignFromTimeline(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            cache: makeCache())

        XCTAssertEqual(Permit.permit(recordedIn: record), .reviewer)
        XCTAssertFalse(RegistryAdmission.recordBehindEvents(
            person: phone.author.fingerprint, in: try registry()))
        XCTAssertEqual(try eventKinds(about: phone.author.fingerprint),
                       [.admitted, .roleChanged],
                       "it writes a RECORD and never an event")
    }

    /// The piece list travels with the rung: a record behind a `scopeChanged`
    /// comes up to the pieces the history names, not to a bare role word.
    func test_theRecordComesUpToThePiecesTheHistoryNames() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try plantEvent(.scopeChanged, about: phone.author.fingerprint,
                       permit: .author(.pieces(["ch2", "ch1"])))

        let record = try RegistryAdmission.resignFromTimeline(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            cache: makeCache())

        XCTAssertEqual(Permit.permit(recordedIn: record),
                       .author(.pieces(["ch1", "ch2"])))
        XCTAssertEqual(record.pieces, ["ch1", "ch2"], "sorted, as a signed record is")
    }

    /// A record already agreeing with its history is answered unchanged and no
    /// file is touched — a re-signed record is a file for iCloud to carry and a
    /// signature for every peer to check, for no change at all.
    func test_aRecordThatAlreadyAgreesIsNotResigned() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        let before = try Data(contentsOf: file(.people, phone.author.fingerprint))

        try RegistryAdmission.resignFromTimeline(
            person: phone.author.fingerprint, in: projectURL, by: mine.author,
            cache: makeCache())

        XCTAssertEqual(
            try Data(contentsOf: file(.people, phone.author.fingerprint)), before)
    }

    /// **Its authority is `changePermit`'s exactly**, because re-signing the
    /// record IS the second half of a permit change: a Mac that may not perform
    /// one may not perform half of one.
    func test_aMacThatIsNoRootHereCannotResignAnybodysRecord() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try admitThePhone()
        try plantEvent(.roleChanged, about: phone.author.fingerprint, permit: .reviewer)
        let before = try Data(contentsOf: file(.people, phone.author.fingerprint))

        XCTAssertThrowsError(try RegistryAdmission.resignFromTimeline(
            person: phone.author.fingerprint, in: projectURL, by: phone.author,
            cache: makeCache())
        ) { XCTAssertEqual($0 as? RegistryAdmissionError, .notARoot) }
        XCTAssertEqual(
            try Data(contentsOf: file(.people, phone.author.fingerprint)), before)
    }

    /// A root answers to itself and a book must not end up with no author, so
    /// the one record this never re-signs is the root's own.
    func test_aRootsOwnRecordIsNeverResignedFromATimeline() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        XCTAssertThrowsError(try RegistryAdmission.resignFromTimeline(
            person: mine.author.fingerprint, in: projectURL, by: mine.author,
            cache: makeCache())
        ) {
            XCTAssertEqual($0 as? RegistryAdmissionError,
                           .cannotChangeARoot(fingerprint: mine.author.fingerprint))
        }
    }

    // MARK: - writeOwnRecordAgain (audit F4)

    /// **A device signing its own record is its authority.** The record on disk
    /// will not verify and this Mac remembers no earlier bytes, so Restore has
    /// nothing to put back; writing it again is the one way out.
    func test_thisMacWritesItsOwnDeviceRecordAgainOverOneThatWillNotVerify() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try tamper(.devices, mine.author.fingerprint)
        XCTAssertEqual(try registry().malformed.compactMap(\.ref),
                       [RecordRef(directory: .devices,
                                  fingerprint: mine.author.fingerprint)])

        try RegistryPresence.writeOwnRecordAgain(
            RecordRef(directory: .devices, fingerprint: mine.author.fingerprint),
            in: projectURL, identities: mine, name: "Denver's MacBook",
            writerName: "Denver", kind: .mac,
            now: { Date(timeIntervalSince1970: 500) })

        let reread = try registry()
        XCTAssertTrue(reread.malformed.isEmpty, "the reader accepts it now")
        let record = try XCTUnwrap(
            reread.devices.first { $0.device == mine.author.fingerprint })
        XCTAssertEqual(record.name, "Denver's MacBook")
        XCTAssertEqual(record.actors[DeviceActor.author.rawValue],
                       mine.author.fingerprint)
    }

    /// **Never for another device's record.** A device record is signed by the
    /// machine it describes, so a Mac writing somebody else's would produce a
    /// file every reader lists as malformed — the state this repairs.
    func test_thisMacNeverWritesAnotherDevicesRecord() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try declare(phone, name: "Denver's iPhone")
        try tamper(.devices, phone.author.fingerprint)
        let before = try Data(contentsOf: file(.devices, phone.author.fingerprint))

        XCTAssertThrowsError(try RegistryPresence.writeOwnRecordAgain(
            RecordRef(directory: .devices, fingerprint: phone.author.fingerprint),
            in: projectURL, identities: mine, name: "Denver's MacBook",
            writerName: "Denver", kind: .mac)
        ) {
            XCTAssertEqual($0 as? RegistryPresence.RegistryPresenceError,
                           .notThisDevicesRecord)
        }
        XCTAssertEqual(
            try Data(contentsOf: file(.devices, phone.author.fingerprint)), before)
    }

    /// **Never over a record that verifies.** The registry is re-read here, so
    /// a row the pane drew from a stale read — or one another Mac repaired
    /// while the writer was looking at it — is refused rather than replaced
    /// with a guess.
    func test_aRecordThatVerifiesIsNeverWrittenOver() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        let before = try Data(contentsOf: file(.devices, mine.author.fingerprint))

        XCTAssertThrowsError(try RegistryPresence.writeOwnRecordAgain(
            RecordRef(directory: .devices, fingerprint: mine.author.fingerprint),
            in: projectURL, identities: mine, name: "Renamed Mac",
            writerName: "Denver", kind: .mac)
        ) {
            XCTAssertEqual($0 as? RegistryPresence.RegistryPresenceError,
                           .theRecordVerifies)
        }
        XCTAssertEqual(
            try Data(contentsOf: file(.devices, mine.author.fingerprint)), before,
            "not one byte")
    }

    /// **Audit F4 itself** — the sole root record tampered with, on a Mac whose
    /// cache never verified it. There is no other root to ask, and this Mac's
    /// own root record is the whole of what is wrong.
    func test_theSoleRootRecordIsWrittenAgainByTheMacItNames() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try tamper(.people, mine.author.fingerprint)
        XCTAssertTrue(try registry().roots.isEmpty, "nobody is a root here now")

        try RegistryPresence.writeOwnRecordAgain(
            RecordRef(directory: .people, fingerprint: mine.author.fingerprint),
            in: projectURL, identities: mine, name: "Denver's MacBook",
            writerName: "Denver", kind: .mac,
            now: { Date(timeIntervalSince1970: 600) })

        let reread = try registry()
        XCTAssertTrue(reread.malformed.isEmpty)
        let record = try XCTUnwrap(reread.person(mine.author.fingerprint))
        XCTAssertTrue(record.isRoot)
        XCTAssertEqual(record.label, "Denver")
        XCTAssertEqual(record.ownName, "Denver's MacBook",
                       "the machine's name is the device record's, decided once")
    }

    /// **The person arm's own refusal, and the reason it is narrower than the
    /// device arm's.** Re-writing a person record self-signed makes this Mac a
    /// root; where the book still HAS a verified root, that would be a second
    /// root made out of a damaged file — and that root is also the only Mac
    /// that can re-sign the record, so the refusal names it.
    func test_aDamagedRecordInSomebodyElsesBookNamesTheMacThatDecides() throws {
        try becomeRoot(otherRoot, name: "Amelia's iMac")
        try declare(mine, name: "Denver's MacBook", kind: .mac)
        try RegistryAdmission.admit(
            device: mine.author.fingerprint, label: "Denver",
            ownName: "Denver's MacBook", in: projectURL, by: otherRoot.author,
            cache: RegistryCache(fileURL: cacheURL,
                                 identity: otherRoot.author.fingerprint),
            memory: makeMemory(), now: { Date(timeIntervalSince1970: 10) })
        try tamper(.people, mine.author.fingerprint)
        let before = try Data(contentsOf: file(.people, mine.author.fingerprint))

        XCTAssertThrowsError(try RegistryPresence.writeOwnRecordAgain(
            RecordRef(directory: .people, fingerprint: mine.author.fingerprint),
            in: projectURL, identities: mine, name: "Denver's MacBook",
            writerName: "Denver", kind: .mac)
        ) { error in
            XCTAssertEqual(
                error as? RegistryPresence.RegistryPresenceError,
                .anotherMacDecidesWhoIsInThisBook(rootLabel: "Amelia's iMac"))
            XCTAssertTrue(
                (error as? LocalizedError)?.errorDescription?
                    .contains("Amelia's iMac") == true,
                "and the sentence says which Mac to open the book on")
        }
        XCTAssertEqual(
            try Data(contentsOf: file(.people, mine.author.fingerprint)), before)
    }

    /// A claim and a permit event are records this device does not write about
    /// itself at all; both have verbs of their own.
    func test_aClaimOrAnEventIsNotARecordThisMacWritesAboutItself() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        for directory in [RegistryDirectory.claims, .events] {
            XCTAssertThrowsError(try RegistryPresence.writeOwnRecordAgain(
                RecordRef(directory: directory,
                          fingerprint: mine.author.fingerprint),
                in: projectURL, identities: mine, name: "Denver's MacBook",
                writerName: "Denver", kind: .mac)
            ) {
                // The verify guard runs first and is the honest answer for a
                // directory with no malformed record in it at all; where one
                // exists, the directory refusal is what it meets.
                XCTAssertNotNil($0 as? RegistryPresence.RegistryPresenceError,
                                "\(directory): \($0)")
            }
        }
    }
}
