import Foundation
import XCTest
@testable import MaughamCore

/// **Declaring yourself.** What a device writes about itself the first time it
/// opens a project, and what it deliberately does not write.
///
/// Two acts, and the order between them is load-bearing: a device says who it
/// is (`ensureDeviceRecord`), and only a Mac in a book with nobody in it yet
/// says that it is the root (`ensureRootIfEmpty`). Both are idempotent, both
/// refuse on a device with no key, and both are silent about everything they
/// decline to do — a second root, a phone's root, a stranger's book.
final class RegistryPresenceTests: XCTestCase {

    private var projectURL: URL!
    /// This device: four software keys, so `existingActors` is all four.
    private var mine: LocalIdentities!
    /// Somebody else's Mac, used to plant a registry this device is not in.
    private var stranger: DeviceIdentity!
    /// Every device-local file a test in the B2 section made, swept together.
    private var memoryFiles: [URL] = []

    override func setUp() {
        super.setUp()
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        mine = .softwareForTesting()
        stranger = .softwareForTesting()
        memoryFiles = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
        for url in memoryFiles { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    // MARK: - Helpers

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    private func myDeviceRecord() throws -> DeviceRecord? {
        try registry().devices.first { $0.device == mine.author.fingerprint }
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - The device record

    func test_aDeviceWithNoRecordWritesOne() throws {
        let url = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac,
            now: { Date(timeIntervalSince1970: 100) })

        XCTAssertEqual(url?.lastPathComponent, "\(mine.author.fingerprint).json")
        let record = try XCTUnwrap(myDeviceRecord())
        XCTAssertEqual(record.name, "Denver's MacBook")
        XCTAssertEqual(record.kind, .mac)
        XCTAssertEqual(record.madeAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(record.retiredAt)
        XCTAssertEqual(
            record.actors[DeviceActor.author.rawValue], mine.author.fingerprint,
            "the author entry IS the device — the reader refuses a record that says otherwise")
        XCTAssertEqual(
            Set(record.actors.keys), Set(DeviceActor.allCases.map(\.rawValue)),
            "every actor key this device holds is listed, so admitting the device admits them")
        XCTAssertTrue(try registry().malformed.isEmpty,
                      "and the record it wrote is one its own reader can vouch for")
    }

    func test_asecondCallWithTheSameFactsWritesNothing() throws {
        let url = try XCTUnwrap(try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac))
        let firstWrite = modified(url)

        let again = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac)

        XCTAssertNil(again, "nothing was written, and the answer says so")
        XCTAssertEqual(modified(url), firstWrite,
                       "the file on disk was not touched")
    }

    /// **The lazy boundary itself**, which is the whole reason this is *ensure*
    /// rather than *write once*: the assistant's key does not exist until MCP
    /// first writes, and on the day it does the record has to grow to say so —
    /// otherwise every seal that key makes reads on the other Mac as a
    /// stranger's (spec §4.4).
    ///
    /// The device here is `lazySoftwareForTesting`, whose `existingActors`
    /// genuinely GROWS between the calls below. A `.fixed` fixture cannot stand
    /// here: it reports all four actors from its first call, so the transition
    /// this test is about would never happen.
    func test_anActorMintedBetweenTwoCallsIsReSignedIntoTheRecord() throws {
        let device = LocalIdentities.lazySoftwareForTesting()
        let author = device.author  // the first actor this device ever names

        let first = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: device, name: "Denver's MacBook", kind: .mac,
            now: { Date(timeIntervalSince1970: 10) })
        XCTAssertNotNil(first)
        let asWritten = try XCTUnwrap(
            try registry().devices.first { $0.device == author.fingerprint })
        XCTAssertEqual(asWritten.actors, [DeviceActor.author.rawValue: author.fingerprint],
                       "a device that has named one actor lists one actor")

        // MCP writes for the first time: naming the assistant is what mints it.
        let assistant = device.assistant

        let second = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: device, name: "Denver's MacBook", kind: .mac,
            now: { Date(timeIntervalSince1970: 999) })

        XCTAssertNotNil(second, "the key that did not exist last time is re-signed in")
        let grown = try XCTUnwrap(
            try registry().devices.first { $0.device == author.fingerprint })
        XCTAssertEqual(grown.actors, [
            DeviceActor.author.rawValue: author.fingerprint,
            DeviceActor.assistant.rawValue: assistant.fingerprint,
        ])
        XCTAssertEqual(grown.madeAt, Date(timeIntervalSince1970: 10),
                       "and it is the same device: `madeAt` is when it declared itself, "
                       + "not when it last re-signed")
        XCTAssertTrue(try registry().malformed.isEmpty,
                      "the re-signed record verifies under the same author key")

        XCTAssertNil(
            try RegistryPresence.ensureDeviceRecord(
                in: projectURL, identities: device, name: "Denver's MacBook", kind: .mac),
            "and with nothing new to say, a third call writes nothing")
    }

    /// A device that has retired is left alone (spec §5): its record carries
    /// its own signed `retiredAt`, and re-declaring it here would un-retire it.
    /// Retirement is the device's own act and nothing else's — not even its own
    /// next open's.
    func test_aRetiredDeviceIsNotReDeclaredEvenWhenItsActorsDiffer() throws {
        let author = mine.author
        let retired = DeviceRecord(
            device: author.fingerprint, name: "An old MacBook", kind: .mac,
            actors: [DeviceActor.author.rawValue: author.fingerprint],
            madeAt: Date(timeIntervalSince1970: 10),
            retiredAt: Date(timeIntervalSince1970: 50))
        let file = try RegistryWriter.write(retired, signedBy: author, in: projectURL)
        let written = modified(file)

        let url = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "A new name", kind: .mac)

        XCTAssertNil(url)
        XCTAssertEqual(modified(file), written, "the file was not touched")
        let record = try XCTUnwrap(myDeviceRecord())
        XCTAssertEqual(record.retiredAt, Date(timeIntervalSince1970: 50),
                       "it is still retired")
        XCTAssertEqual(record.actors.count, 1)
        XCTAssertEqual(record.name, "An old MacBook")
    }

    func test_aRenamedDeviceReSignsItsOwnRecord() throws {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Old name", kind: .mac)

        let url = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac)

        XCTAssertNotNil(url)
        XCTAssertEqual(try myDeviceRecord()?.name, "Denver's MacBook")
    }

    /// A device with no enclave key is a first-class state (parent spec §4.1):
    /// it writes nothing at all rather than an unsigned record, which every
    /// reader would list as malformed anyway.
    func test_aDeviceWithNoKeyWritesNothing() throws {
        let unsigned = LocalIdentities.forTesting(
            author: .unsignedForTesting(token: Data([1, 2, 3])))

        let device = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: unsigned, name: "A VM", kind: .mac)
        let root = try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: unsigned)

        XCTAssertNil(device)
        XCTAssertNil(root)
        XCTAssertFalse(
            TrustResolution.hasRegistry(in: projectURL),
            "an unsigned device leaves no registry behind — not even an empty folder")
    }

    // MARK: - The root

    func test_theFirstMacInAnEmptyBookIsItsRoot() throws {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac)

        let url = try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: mine,
            now: { Date(timeIntervalSince1970: 200) })

        XCTAssertEqual(url?.lastPathComponent, "\(mine.author.fingerprint).json")
        let root = try XCTUnwrap(try registry().roots.first)
        XCTAssertEqual(root.person, mine.author.fingerprint)
        XCTAssertTrue(root.isRoot, "self-signed: it admitted itself")
        XCTAssertEqual(root.label, "Denver's MacBook")
        XCTAssertEqual(root.ownName, "Denver's MacBook",
                       "the label and the device's own name are one thing until "
                       + "somebody types another")
        XCTAssertEqual(root.role, "author")
        XCTAssertEqual(root.admittedAt, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    /// The read side of the same act (Task 7's arm 2): what this device wrote
    /// about itself is what `TrustTable.resolve` recognises as its own root.
    func test_theRootItWritesIsTheRootItThenResolvesTo() throws {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac)
        try RegistryPresence.ensureRootIfEmpty(in: projectURL, identities: mine)

        let cache = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: mine.author.fingerprint)
        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: mine, cache: cache)

        XCTAssertEqual(table.myRoot, mine.author.fingerprint)
        XCTAssertEqual(table.rootSource, .ownRecord)
        // Task 7's fix round, on the controller's ruling: the JOIN records only
        // a foreign root that took this device in (B1). Being your own root is
        // not joining one — a Mac that joined itself would have every surface
        // reading the join say "this Mac joined its own chain", and, because
        // `join` is write-once, would file the first root that really did admit
        // it as a claimant of a join nobody made.
        XCTAssertNil(cache.joinedRoot(for: projectURL),
                     "there is no chain of anybody else's for it to be on")
    }

    func test_asecondCallWritesNoSecondRoot() throws {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac)
        let url = try XCTUnwrap(try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: mine))
        let firstWrite = modified(url)

        let again = try RegistryPresence.ensureRootIfEmpty(in: projectURL, identities: mine)

        XCTAssertNil(again)
        XCTAssertEqual(modified(url), firstWrite)
        XCTAssertEqual(try registry().roots.count, 1)
    }

    /// A book that already has people in it is somebody's. This device says who
    /// it is and stops — the claim is a decision the writer makes, not one an
    /// open makes for them.
    func test_aBookThatAlreadyHasARootGetsADeviceRecordAndNoRoot() throws {
        let theirs = PersonRecord(
            person: stranger.fingerprint, label: "Sam", ownName: "Sam's iMac",
            admittedAt: Date(timeIntervalSince1970: 1), admittedBy: stranger.fingerprint)
        try RegistryWriter.write(theirs, signedBy: stranger, in: projectURL)

        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac)
        let root = try RegistryPresence.ensureRootIfEmpty(in: projectURL, identities: mine)

        XCTAssertNil(root, "it never writes a second root silently")
        XCTAssertNotNil(try myDeviceRecord(), "but it does say who it is")
        XCTAssertEqual(try registry().roots.map(\.person), [stranger.fingerprint])
    }

    /// **A book whose only person record cannot be read is not an empty book**
    /// (Denver, 2026-09-10). Rooting beside a tampered or half-written root
    /// would put a second self-signed root next to a damaged original, and
    /// nothing on the folder would say which came first. Present-and-unreadable
    /// is not absent — RULING-54's distinction, kept here too.
    func test_aBookWhoseOnlyPersonRecordIsMalformedGetsNoRoot() throws {
        let theirs = PersonRecord(
            person: stranger.fingerprint, label: "Sam", ownName: "Sam's iMac",
            admittedAt: Date(timeIntervalSince1970: 1), admittedBy: stranger.fingerprint)
        let file = try RegistryWriter.write(theirs, signedBy: stranger, in: projectURL)
        // Somebody edited it after it was signed.
        var bytes = try XCTUnwrap(String(data: try Data(contentsOf: file), encoding: .utf8))
        bytes = bytes.replacingOccurrences(of: "\"Sam\"", with: "\"Sammm\"")
        try Data(bytes.utf8).write(to: file)
        XCTAssertTrue(try registry().people.isEmpty, "precondition: it verifies for nobody")
        XCTAssertFalse(try registry().malformed.isEmpty, "precondition: and it is listed")

        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac)
        let root = try RegistryPresence.ensureRootIfEmpty(in: projectURL, identities: mine)

        XCTAssertNil(root, "no root beside a person record this device cannot vouch for")
        XCTAssertTrue(try registry().roots.isEmpty)
        XCTAssertNotNil(try myDeviceRecord(),
                        "but the device record is this device's own statement, "
                        + "and it is written regardless")
    }

    /// The root is the MAC's to write (spec §3). A phone waits to be admitted,
    /// and a phone that made itself a root would be a second claimant on a book
    /// it cannot even see the folder of.
    func test_aPhoneWritesItsDeviceRecordAndNeverARoot() throws {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's iPhone", kind: .phone)

        let root = try RegistryPresence.ensureRootIfEmpty(in: projectURL, identities: mine)

        XCTAssertNil(root)
        XCTAssertTrue(try registry().roots.isEmpty)
        XCTAssertEqual(try myDeviceRecord()?.kind, .phone)
    }

    /// The order is the contract: the root's name comes from the device record,
    /// so there is exactly one place this device's own name is decided.
    func test_aDeviceThatHasNotSaidWhoItIsWritesNoRoot() throws {
        let root = try RegistryPresence.ensureRootIfEmpty(in: projectURL, identities: mine)

        XCTAssertNil(root)
        XCTAssertTrue(try registry().people.isEmpty)
    }

    // MARK: - One given author key (the phone's shape)

    /// `LocalIdentities.forAuthor` exists so the phone can hand over the key it
    /// already holds and have the record built from THAT key rather than from a
    /// second lookup. One spelling: the signer and the record's author entry
    /// cannot disagree, which is a refusal at `RegistryWriter`'s door and a
    /// malformed listing at every reader's.
    func test_aGivenAuthorKeyIsTheOneTheRecordNamesAndTheOneThatSignsIt() throws {
        let phone = DeviceIdentity.softwareForTesting()
        let identities = LocalIdentities.forAuthor(phone)

        XCTAssertEqual(identities.author.fingerprint, phone.fingerprint)
        XCTAssertEqual(identities.existingActors.first, .author,
                       "the author is always among the keys such a device holds")

        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: identities,
            name: "Denver's iPhone", kind: .phone)

        let record = try XCTUnwrap(
            try registry().devices.first { $0.device == phone.fingerprint })
        XCTAssertEqual(record.actors[DeviceActor.author.rawValue], phone.fingerprint)
        XCTAssertTrue(try registry().malformed.isEmpty,
                      "and the signature over it verifies under that same key")
    }

    // MARK: - Silent admission at open (decision B2)

    /// A device this writer has already named once is never asked about again.
    /// `admitRemembered` is that promise at every project open: for each
    /// stranger whose fingerprint is in admission memory, the Mac writes the
    /// person record with the remembered label and says so in History, rather
    /// than putting the same sheet up in every book the phone reaches.
    ///
    /// It admits nobody unless this device is a root here — an admission signed
    /// by a non-root is a file every reader lists as malformed — and it never
    /// touches a device the folder already has a record for.

    private func rememberingMemory() -> AdmissionMemory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-memory-\(UUID().uuidString).json")
        memoryFiles.append(url)
        return AdmissionMemory(fileURL: url, identity: mine.author.fingerprint)
    }

    private func presenceCache() -> RegistryCache {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-cache-\(UUID().uuidString).json")
        memoryFiles.append(url)
        return RegistryCache(fileURL: url, identity: mine.author.fingerprint)
    }

    /// This Mac declares itself and roots the empty book.
    private func rootHere() throws {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac)
        try RegistryPresence.ensureRootIfEmpty(in: projectURL, identities: mine)
    }

    @discardableResult
    private func declarePhone(named name: String = "Denver's iPhone") throws -> LocalIdentities {
        let phone = LocalIdentities.softwareForTesting()
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: phone, name: name, kind: .phone)
        return phone
    }

    func test_aRememberedStrangerIsAdmittedAtOpenWithoutAsking() throws {
        try rootHere()
        let phone = try declarePhone()
        let memory = rememberingMemory()
        memory.remember(phone.author.fingerprint, label: "Denver",
                        ownName: "Denver's iPhone",
                        at: Date(timeIntervalSince1970: 100))

        let admitted = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: presenceCache(), memory: memory,
            now: { Date(timeIntervalSince1970: 500) })

        XCTAssertEqual(admitted.map(\.person), [phone.author.fingerprint])
        let record = try XCTUnwrap(try registry().person(phone.author.fingerprint))
        XCTAssertEqual(record.label, "Denver")
        XCTAssertEqual(record.admittedBy, mine.author.fingerprint)
        XCTAssertEqual(record.admittedAt, Date(timeIntervalSince1970: 500),
                       "the label is remembered; the admission happens now")
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    func test_silentAdmissionDoesNotRestampTheWritersDecision() throws {
        try rootHere()
        let phone = try declarePhone()
        let memory = rememberingMemory()
        memory.remember(phone.author.fingerprint, label: "Denver",
                        ownName: "Denver's iPhone",
                        at: Date(timeIntervalSince1970: 100))

        try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: presenceCache(), memory: memory,
            now: { Date(timeIntervalSince1970: 500) })

        XCTAssertEqual(
            memory.label(for: phone.author.fingerprint)?.labelledAt,
            Date(timeIntervalSince1970: 100),
            """
            The writer decided in September. Using that decision in a new book             is not making it again, and History's *remembered from Playlist*             would be lying about when if it were.
            """)
    }

    func test_anUnrememberedStrangerIsLeftForTheSheet() throws {
        try rootHere()
        let phone = try declarePhone()

        let admitted = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: presenceCache(),
            memory: rememberingMemory())

        XCTAssertTrue(admitted.isEmpty)
        XCTAssertNil(try registry().person(phone.author.fingerprint),
                     "an empty memory admits nobody — the sheet is where a new name is decided")
    }

    func test_adeviceAlreadyAdmittedIsNotAdmittedAgain() throws {
        try rootHere()
        let phone = try declarePhone()
        let memory = rememberingMemory()
        memory.remember(phone.author.fingerprint, label: "Denver",
                        ownName: "Denver's iPhone")
        try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: presenceCache(), memory: memory)
        let bytes = try Data(contentsOf: RegistryWriter.url(
            .people, fingerprint: phone.author.fingerprint, in: projectURL))

        let again = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: presenceCache(), memory: memory)

        XCTAssertTrue(again.isEmpty, "the second open has nothing to admit and says so")
        XCTAssertEqual(
            try Data(contentsOf: RegistryWriter.url(
                .people, fingerprint: phone.author.fingerprint, in: projectURL)),
            bytes,
            "and every open after the first leaves the folder alone")
    }

    func test_aDeviceThatIsNotARootHereAdmitsNobodySilently() throws {
        // Somebody else's book: they are the root, this Mac merely declared
        // itself. A remembered label is still this writer's word — it is not
        // authority over a chain they are not the root of.
        let owner = LocalIdentities.softwareForTesting()
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: owner, name: "Their MacBook", kind: .mac)
        try RegistryPresence.ensureRootIfEmpty(in: projectURL, identities: owner)
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac)
        let phone = try declarePhone()
        let memory = rememberingMemory()
        memory.remember(phone.author.fingerprint, label: "Denver",
                        ownName: "Denver's iPhone")

        let admitted = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: presenceCache(), memory: memory)

        XCTAssertTrue(admitted.isEmpty)
        XCTAssertNil(try registry().person(phone.author.fingerprint))
    }

    func test_theSilentAdmissionCarriesTheDevicesOwnNameAsItIsNow() throws {
        try rootHere()
        let phone = try declarePhone(named: "Denver's iPhone 17")
        let memory = rememberingMemory()
        memory.remember(phone.author.fingerprint, label: "Denver",
                        ownName: "Denver's iPhone")

        try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: presenceCache(), memory: memory)

        XCTAssertEqual(
            try registry().person(phone.author.fingerprint)?.ownName,
            "Denver's iPhone 17",
            """
            `ownName` is the device's own name at admission, and the device             record in this folder is the device saying it. The memory's copy is             what a surface shows for a device whose record is not here at all.
            """)
    }

    func test_aDeviceUnderAnotherRootIsNotSilentlyTakenOver() throws {
        try rootHere()
        let other = LocalIdentities.softwareForTesting()
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: other, name: "Their MacBook", kind: .mac)
        try RegistryWriter.write(
            PersonRecord(
                person: other.author.fingerprint, label: "Them", ownName: "Their MacBook",
                admittedAt: Date(timeIntervalSince1970: 3),
                admittedBy: other.author.fingerprint),
            signedBy: other.author, in: projectURL)
        let phone = try declarePhone()
        try RegistryWriter.write(
            PersonRecord(
                person: phone.author.fingerprint, label: "Their word",
                ownName: "Denver's iPhone",
                admittedAt: Date(timeIntervalSince1970: 4),
                admittedBy: other.author.fingerprint),
            signedBy: other.author, in: projectURL)
        let memory = rememberingMemory()
        memory.remember(phone.author.fingerprint, label: "Denver",
                        ownName: "Denver's iPhone")

        let admitted = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: presenceCache(), memory: memory)

        XCTAssertTrue(
            admitted.isEmpty,
            """
            A silent open must not throw on somebody else's admission, and must             not take it over: that is a second claimant, and merging chains is             the writer's own act at a surface.
            """)
        XCTAssertEqual(try registry().person(phone.author.fingerprint)?.admittedBy,
                       other.author.fingerprint)
    }

    /// Fix round 1, I1 — the silent path is where this matters most, because
    /// nobody is watching. A person record present on disk that did not verify
    /// reads as absent through `Registry.person(_:)`, and writing over it at an
    /// open would destroy another root's admission over a sync ordering.
    func test_aPersonRecordPresentAndUnreadableIsSkippedRatherThanOverwritten() throws {
        try rootHere()
        let phone = try declarePhone()
        let impostor = LocalIdentities.softwareForTesting()
        try RegistryWriter.writeUnchecked(
            PersonRecord(
                person: phone.author.fingerprint, label: "Somebody's word",
                ownName: "Denver's iPhone",
                admittedAt: Date(timeIntervalSince1970: 6),
                admittedBy: impostor.author.fingerprint),
            signedBy: impostor.author, in: projectURL)
        let bytes = try Data(contentsOf: RegistryWriter.url(
            .people, fingerprint: phone.author.fingerprint, in: projectURL))
        let memory = rememberingMemory()
        memory.remember(phone.author.fingerprint, label: "Denver",
                        ownName: "Denver's iPhone")

        let admitted = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: presenceCache(), memory: memory)

        XCTAssertTrue(admitted.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: RegistryWriter.url(
                .people, fingerprint: phone.author.fingerprint, in: projectURL)),
            bytes,
            "present and unreadable is not absent — the same rule ensureRootIfEmpty keeps")
    }
}
