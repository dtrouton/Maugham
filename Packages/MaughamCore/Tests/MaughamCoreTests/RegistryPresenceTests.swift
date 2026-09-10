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

    override func setUp() {
        super.setUp()
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        mine = .softwareForTesting()
        stranger = .softwareForTesting()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
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

    /// The lazy-key case, which is the whole reason this is *ensure* rather
    /// than *write once*: the assistant's key exists only once MCP has written
    /// something, and the record has to grow to say so.
    func test_anActorThisDeviceDidNotHaveBeforeIsReSignedIntoTheRecord() throws {
        let author = mine.author
        let earlier = DeviceRecord(
            device: author.fingerprint, name: "Denver's MacBook", kind: .mac,
            actors: [DeviceActor.author.rawValue: author.fingerprint],
            madeAt: Date(timeIntervalSince1970: 10))
        try RegistryWriter.write(earlier, signedBy: author, in: projectURL)

        let url = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac,
            now: { Date(timeIntervalSince1970: 999) })

        XCTAssertNotNil(url, "a record missing an actor this device holds is re-signed")
        let record = try XCTUnwrap(myDeviceRecord())
        XCTAssertEqual(
            Set(record.actors.keys), Set(DeviceActor.allCases.map(\.rawValue)))
        XCTAssertEqual(record.madeAt, Date(timeIntervalSince1970: 10),
                       "and it is the same device: `madeAt` is when it declared itself, "
                       + "not when it last re-signed")
        XCTAssertTrue(try registry().malformed.isEmpty)
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
        XCTAssertEqual(cache.joinedRoot(for: projectURL), mine.author.fingerprint,
                       "and it joined its own chain, once")
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
}
