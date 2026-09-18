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

    /// The same registry with the phone's own device record saying it has
    /// stopped writing.
    private func registry(
        admittingPhoneAs label: String?, retiredAt: Date
    ) -> Registry {
        let base = registry(admittingPhoneAs: label)
        return Registry(
            devices: base.devices.map { device in
                DeviceRecord(
                    device: device.device, name: device.name, kind: device.kind,
                    actors: device.actors, madeAt: device.madeAt,
                    retiredAt: retiredAt)
            },
            people: base.people)
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
        XCTAssertFalse(standing.ownRecordUnverified)
    }

    /// **Nobody is going to ask** (P2 smoke find 1). A record naming this
    /// device that is PRESENT and will not verify contributes nothing to the
    /// registry, so this device falls out of every chain and used to read *not
    /// yet admitted* — the worst possible answer, because the record is there
    /// and no sheet is coming. Present and unreadable is not absent, here as
    /// everywhere (RULING-54).
    func test_adeviceWhoseOwnRecordDoesNotVerifyIsNotToldToWait() {
        let base = registry(admittingPhoneAs: nil)
        let damaged = Registry(
            devices: base.devices, people: base.people,
            malformed: [MalformedRecord(
                url: RegistryWriter.url(
                    .people, fingerprint: phone.fingerprint, in: projectURL),
                reason: .signatureDoesNotVerify)])

        let standing = DeviceStanding.resolve(
            registry: damaged, cache: cache(), mine: mine, for: projectURL)

        XCTAssertFalse(standing.admitted)
        XCTAssertTrue(standing.ownRecordUnverified)
        XCTAssertEqual(
            standing.sentence,
            "This book’s file about this device doesn’t check out, "
            + "so nothing here confirms it")
    }

    /// Somebody ELSE's unverifiable record says nothing about this device: it
    /// is still simply waiting to be asked about.
    func test_anotherDevicesUnverifiableRecordLeavesThisOneWaiting() {
        let base = registry(admittingPhoneAs: nil)
        let damaged = Registry(
            devices: base.devices, people: base.people,
            malformed: [MalformedRecord(
                url: RegistryWriter.url(
                    .people, fingerprint: mac.fingerprint, in: projectURL),
                reason: .unsigned)])

        let standing = DeviceStanding.resolve(
            registry: damaged, cache: cache(), mine: mine, for: projectURL)

        XCTAssertFalse(standing.ownRecordUnverified)
        XCTAssertEqual(standing.sentence, "Not yet admitted — the Mac will ask")
    }

    // MARK: - Admitted

    func test_anAdmittedDeviceNamesItsLabelAndTheMacTheBookWasStartedOn() {
        let standing = DeviceStanding.resolve(
            registry: registry(admittingPhoneAs: "Denver"), cache: cache(),
            mine: mine, for: projectURL)

        XCTAssertTrue(standing.admitted)
        XCTAssertEqual(standing.label, "Denver")
        XCTAssertEqual(standing.rootLabel, "Denver's MacBook")
        XCTAssertNil(standing.joinedAt, "nothing joined: the folder alone admitted it")
        // **Started on, not rooted** (Denver's wording ruling, 2026-09-18).
        // Two facts, because the second is what says which Mac to go to and a
        // phone with several books needs it.
        XCTAssertEqual(standing.sentence,
                       "In this book as Denver. Started on Denver's MacBook.")
    }

    /// A P2a join stamped the date, so the sentence carries it.
    func test_adeviceTakenInOnAKnownDaySaysSinceWhen() {
        let memory = cache()
        _ = memory.join(root: mac.fingerprint, for: projectURL,
                        at: Date(timeIntervalSince1970: 1_757_376_000))  // 9 Sep 2025

        let standing = DeviceStanding.resolve(
            registry: registry(admittingPhoneAs: "Denver"), cache: memory,
            mine: mine, for: projectURL)

        XCTAssertTrue(standing.admitted)
        XCTAssertEqual(standing.joinedAt, Date(timeIntervalSince1970: 1_757_376_000))
        XCTAssertTrue(standing.sentence.hasPrefix("In this book as Denver since "),
                      "got: \(standing.sentence)")
        XCTAssertTrue(standing.sentence.hasSuffix("Started on Denver's MacBook."),
                      "and still says where that was decided: \(standing.sentence)")
    }

    /// The Mac a book was started on was taken in by nobody — saying *X in
    /// this book as X* would read as an admission it never needed.
    func test_theStartingMacSaysSoRatherThanNamingAnAdmission() {
        let macMine = LocalIdentities.forAuthor(mac)
        let macCache = RegistryCache(fileURL: cacheFile, identity: mac.fingerprint)

        let standing = DeviceStanding.resolve(
            registry: registry(admittingPhoneAs: "Denver"), cache: macCache,
            mine: macMine, for: projectURL)

        XCTAssertTrue(standing.admitted)
        XCTAssertTrue(standing.isRoot)
        // **And names no machine** (P2 smoke find 2). The Mac draws this at the
        // head of a list where its own person row and device row already name
        // it, and a third naming had one machine read as three. A phone never
        // starts a book, so this arm is the Mac's alone whatever surface asks.
        XCTAssertEqual(standing.sentence, "This book was started on this Mac")
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
        XCTAssertEqual(standing.sentence,
                       "No longer admitted — this book was started on Denver's MacBook")
    }

    // MARK: - Retirement (fix round 1, Important 2)

    /// **The machine that retired is the one machine that must be told what
    /// retirement means.** Its key removes its own future authority and not its
    /// ability to write: it goes on appending and goes on applying its own
    /// lines, while every peer sets them aside. Nothing else on either screen
    /// says so.
    func test_aretiredDeviceCarriesTheDateAndSaysWhatItMeans() {
        let standing = DeviceStanding.resolve(
            registry: registry(admittingPhoneAs: "Denver",
                               retiredAt: Date(timeIntervalSince1970: 1_757_000_000)),
            cache: cache(), mine: mine, for: projectURL)

        XCTAssertEqual(standing.retiredAt, Date(timeIntervalSince1970: 1_757_000_000))
        let notice = try? XCTUnwrap(standing.retirementNotice(device: "iPhone"))
        XCTAssertTrue(notice?.hasPrefix("This iPhone retired on ") == true, "\(notice ?? "nil")")
        XCTAssertTrue(
            notice?.contains(
                "what it writes now stays on this iPhone and is set aside everywhere else")
                == true,
            "\(notice ?? "nil")")
    }

    /// A device still at work says nothing about retirement — the notice is a
    /// fact's absence, not an empty string.
    func test_adeviceStillAtWorkHasNoRetirementNotice() {
        let standing = DeviceStanding.resolve(
            registry: registry(admittingPhoneAs: "Denver"), cache: cache(),
            mine: mine, for: projectURL)

        XCTAssertNil(standing.retiredAt)
        XCTAssertNil(standing.retirementNotice(device: "iPhone"))
    }

    /// **A retirement is this device's word about ITSELF**, signed by its own
    /// key, and it is true whether or not anybody admitted it: a device dropped
    /// from every chain has still stopped, and the sentence it is owed does not
    /// depend on a root.
    func test_aretirementSurvivesHavingNoChainAtAll() {
        let standing = DeviceStanding.resolve(
            registry: registry(admittingPhoneAs: nil,
                               retiredAt: Date(timeIntervalSince1970: 1_757_000_000)),
            cache: cache(), mine: mine, for: projectURL)

        XCTAssertFalse(standing.admitted)
        XCTAssertNotNil(standing.retiredAt)
        XCTAssertNotNil(standing.retirementNotice(device: "iPhone"))
    }

    /// **The noun is the machine's own** (tripwire 19): a phone saying *this
    /// Mac* about itself is the comparison between two screens failing.
    func test_thedeviceNounIsTheMachinesOwnInBothHalvesOfTheSentence() {
        let mac = DeviceStanding.retirementNotice(
            device: "Mac", retiredAt: Date(timeIntervalSince1970: 1_757_000_000))

        XCTAssertTrue(mac.hasPrefix("This Mac retired on "), mac)
        XCTAssertTrue(mac.contains("stays on this Mac"), mac)
        XCTAssertFalse(mac.contains("iPhone"), mac)
    }

    /// The warning the writer meets BEFORE the act carries the same
    /// consequence as the notice they meet after it, and says there is no way
    /// back — the two are built from one clause so they cannot drift.
    func test_theconfirmationSaysTheSameConsequenceAndThatThereIsNoWayBack() {
        let consequence = DeviceStanding.retirementConsequence(device: "Mac")
        let notice = DeviceStanding.retirementNotice(
            device: "Mac", retiredAt: Date(timeIntervalSince1970: 1_757_000_000))
        let tail = DeviceStanding.retirementTail(device: "Mac")

        XCTAssertTrue(consequence.contains(tail), consequence)
        XCTAssertTrue(notice.contains(tail), notice)
        XCTAssertTrue(consequence.contains("can’t be un-retired"), consequence)
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
