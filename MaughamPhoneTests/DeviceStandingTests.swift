import XCTest
@testable import MaughamCore
@testable import MaughamPhone

/// **What this device says about itself in one book** (P2 spec §4.3, §4.11).
///
/// The phone's Settings row and the Mac's People & Devices draw the same fact
/// from the same value, so the two surfaces cannot disagree about whether this
/// device is on a chain (tripwire 19). Everything here is pure: a registry
/// built in memory, a memory in a temp file, and no folder read at all.
@MainActor
final class DeviceStandingTests: XCTestCase {

    private var cacheFile: URL!
    /// The phone's own key, and the Mac that admits it. Software signers: the
    /// simulator has no enclave, and an unsigned device signs no record.
    private var phone: DeviceIdentity!
    private var mac: DeviceIdentity!
    private var projectURL: URL!

    override func setUp() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("standing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        projectURL = temp.appendingPathComponent("Book", isDirectory: true)
        cacheFile = temp.appendingPathComponent("registry-cache.json")
        phone = .softwareForTesting()
        mac = .softwareForTesting()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheFile.deletingLastPathComponent())
    }

    private func cache() -> RegistryCache {
        RegistryCache(fileURL: cacheFile, identity: phone.fingerprint)
    }

    private var mine: LocalIdentities { .forAuthor(phone) }

    /// A registry in which `mac` is the root and, when `label` is given, the
    /// phone has been admitted under it.
    private func registry(admittingPhoneAs label: String?) -> Registry {
        var people = [PersonRecord(
            person: mac.fingerprint, label: "Denver's MacBook",
            ownName: "Denver's MacBook",
            role: "author", admittedAt: Date(timeIntervalSince1970: 1_000_000),
            admittedBy: mac.fingerprint)]
        if let label {
            people.append(PersonRecord(
                person: phone.fingerprint, label: label, ownName: "Denver's iPhone",
                role: "author", admittedAt: Date(timeIntervalSince1970: 2_000_000),
                admittedBy: mac.fingerprint))
        }
        return Registry(
            devices: [DeviceRecord(
                device: phone.fingerprint, name: "Denver's iPhone", kind: .phone,
                actors: [DeviceActor.author.rawValue: phone.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1_500_000))],
            people: people)
    }

    // MARK: - The code

    /// The code is this device's own, whatever the folder says — it exists to
    /// be read off one screen and compared with another.
    func test_theCodeIsThisDevicesOwnEvenWithNoRegistryAtAll() {
        let standing = DeviceStanding.resolve(
            registry: Registry(), cache: cache(), mine: mine, for: projectURL)

        XCTAssertEqual(standing.code, DeviceCode.short(phone.fingerprint))
        XCTAssertFalse(standing.admitted)
    }

    // MARK: - Not yet admitted

    func test_aDeviceNoRecordNamesIsNotYetAdmitted() {
        let standing = DeviceStanding.resolve(
            registry: registry(admittingPhoneAs: nil), cache: cache(),
            mine: mine, for: projectURL)

        XCTAssertFalse(standing.admitted)
        XCTAssertNil(standing.label)
        XCTAssertEqual(standing.sentence, "Not yet admitted — the Mac will ask")
    }

    // MARK: - Admitted

    func test_anAdmittedDeviceNamesItsLabelAndTheRootsChain() {
        let standing = DeviceStanding.resolve(
            registry: registry(admittingPhoneAs: "Denver"), cache: cache(),
            mine: mine, for: projectURL)

        XCTAssertTrue(standing.admitted)
        XCTAssertEqual(standing.label, "Denver")
        XCTAssertEqual(standing.rootLabel, "Denver's MacBook")
        XCTAssertNil(standing.joinedAt, "nothing joined: the folder alone admitted it")
        XCTAssertEqual(standing.sentence, "Denver on Denver's MacBook’s chain")
    }

    /// A P2a join stamped the date, so the sentence carries it.
    func test_aJoinedChainSaysSinceWhen() {
        let memory = cache()
        _ = memory.join(root: mac.fingerprint, for: projectURL,
                        at: Date(timeIntervalSince1970: 1_757_376_000))  // 9 Sep 2025

        let standing = DeviceStanding.resolve(
            registry: registry(admittingPhoneAs: "Denver"), cache: memory,
            mine: mine, for: projectURL)

        XCTAssertTrue(standing.admitted)
        XCTAssertEqual(standing.joinedAt, Date(timeIntervalSince1970: 1_757_376_000))
        XCTAssertTrue(standing.sentence.hasPrefix("Denver on Denver's MacBook’s chain since "),
                      "got: \(standing.sentence)")
    }

    /// The root device itself is on nobody else's chain — saying *X on X's
    /// chain* would read as an admission it never needed.
    func test_theRootSaysSoRatherThanNamingItsOwnChain() {
        let macMine = LocalIdentities.forAuthor(mac)
        let macCache = RegistryCache(fileURL: cacheFile, identity: mac.fingerprint)

        let standing = DeviceStanding.resolve(
            registry: registry(admittingPhoneAs: "Denver"), cache: macCache,
            mine: macMine, for: projectURL)

        XCTAssertTrue(standing.admitted)
        XCTAssertTrue(standing.isRoot)
        XCTAssertEqual(standing.sentence, "Denver's MacBook, the root of this book’s chain")
    }

    // MARK: - Revoked

    /// A revoked device is IN the chain and must not read as admitted — the
    /// writer would otherwise wait for notes that will never be applied.
    func test_arevokedDeviceIsNotAdmittedAndSaysWhy() {
        let base = registry(admittingPhoneAs: "Denver")
        let revoked = PersonRecord(
            person: phone.fingerprint, label: "Denver", ownName: "Denver's iPhone",
            role: "author", admittedAt: Date(timeIntervalSince1970: 2_000_000),
            admittedBy: mac.fingerprint,
            revokedAt: Date(timeIntervalSince1970: 3_000_000),
            revokedBy: mac.fingerprint, highestOpIdSeen: nil)
        let registry = Registry(
            devices: base.devices,
            people: base.people.filter { $0.person != phone.fingerprint } + [revoked])

        let standing = DeviceStanding.resolve(
            registry: registry, cache: cache(), mine: mine, for: projectURL)

        XCTAssertFalse(standing.admitted)
        XCTAssertTrue(standing.revoked)
        XCTAssertEqual(standing.sentence, "No longer admitted to Denver's MacBook’s chain")
    }

    // MARK: - The refusal

    /// A registry record present and unreadable is never answered *not yet
    /// admitted* (RULING-54): the writer would read a permissions error as a
    /// Mac that has not got round to it.
    func test_anUnreadableRegistrySaysWhatItRefused() {
        let error = OpLogStore.ReadError.unreadableFile(
            name: "abc.json", underlying: "permission denied", kind: .registry)

        let standing = DeviceStanding.refused(mine: mine, error: error)

        XCTAssertFalse(standing.admitted)
        XCTAssertEqual(standing.code, DeviceCode.short(phone.fingerprint))
        XCTAssertEqual(standing.sentence, error.localizedDescription)
        XCTAssertNotEqual(standing.sentence, "Not yet admitted — the Mac will ask")
    }
}
