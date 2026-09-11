import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Who may write in this book, on which devices, and what is waiting**
/// (signed op log P2, spec §6).
///
/// Everything the section shows is decided here, as a value over a registry,
/// a trust table, this device's memory and the held-line counts — so the rows,
/// the marks and the refusal are all assertable with nothing mounted. The
/// section's own suite asserts only that they reach the screen.
@MainActor
final class PeopleAndDevicesModelTests: XCTestCase {

    private var mac: DeviceIdentity!
    private var phone: DeviceIdentity!
    private var stranger: DeviceIdentity!
    private var otherRoot: DeviceIdentity!

    override func setUp() async throws {
        mac = .softwareForTesting()
        phone = .softwareForTesting()
        stranger = .softwareForTesting()
        otherRoot = .softwareForTesting()
    }

    // MARK: - Fixture

    private let admitted = Date(timeIntervalSince1970: 1_757_000_000)
    private let made = Date(timeIntervalSince1970: 1_756_000_000)

    private func deviceRecord(
        _ identity: DeviceIdentity, name: String, kind: DeviceKind = .phone,
        actors: [DeviceActor] = [.author], retiredAt: Date? = nil
    ) -> DeviceRecord {
        var keys: [String: String] = [:]
        for actor in actors {
            keys[actor.rawValue] = actor == .author
                ? identity.fingerprint
                : "\(actor.rawValue)-key-\(identity.fingerprint.prefix(8))"
        }
        return DeviceRecord(
            device: identity.fingerprint, name: name, kind: kind,
            actors: keys, madeAt: made, retiredAt: retiredAt)
    }

    private func person(
        _ identity: DeviceIdentity, label: String, ownName: String,
        admittedBy: DeviceIdentity, revoked: Bool = false
    ) -> PersonRecord {
        PersonRecord(
            person: identity.fingerprint, label: label, ownName: ownName,
            role: "author", admittedAt: admitted, admittedBy: admittedBy.fingerprint,
            revokedAt: revoked ? admitted.addingTimeInterval(86_400) : nil,
            revokedBy: revoked ? mac.fingerprint : nil)
    }

    /// This Mac is the root and has admitted the phone; a stranger has a
    /// device record and no admission.
    private func registry(revoked: Bool = false) -> Registry {
        Registry(
            devices: [
                deviceRecord(mac, name: "Denver's MacBook", kind: .mac,
                             actors: [.author, .assistant]),
                deviceRecord(phone, name: "Denver's iPhone"),
                deviceRecord(stranger, name: "The old iPhone"),
            ],
            people: [
                person(mac, label: "Denver", ownName: "Denver's MacBook", admittedBy: mac),
                person(phone, label: "Denver", ownName: "Denver's iPhone",
                       admittedBy: mac, revoked: revoked),
            ])
    }

    private func table(_ registry: Registry) -> TrustTable {
        TrustTable.resolve(registry: registry, mine: .forAuthor(mac), joinedRoot: nil)
    }

    private func standing() -> DeviceStanding {
        DeviceStanding(
            code: DeviceCode.short(mac.fingerprint), label: "Denver",
            rootLabel: "Denver", admitted: true, isRoot: true)
    }

    private func model(
        _ registry: Registry,
        remembered: [String: AdmissionMemory.Label] = [:],
        pending: [String: Int] = [:],
        claimants: [String] = [],
        table overrideTable: TrustTable? = nil
    ) -> PeopleAndDevicesModel {
        let table = overrideTable ?? table(registry)
        return PeopleAndDevicesModel.make(
            registry: registry, table: table,
            remembered: remembered,
            // The counts go through the SAME derivation the admission sheet
            // queues (Task 7): who is a stranger with lines waiting is decided
            // once, and this pane draws that decision rather than a second one.
            requests: AdmissionDecision.requests(
                pending: pending, registry: registry,
                memory: remembered, myRoot: table.myRoot),
            claimants: claimants,
            standing: standing(), me: mac.fingerprint)
    }

    // MARK: - Pending requests come first

    /// The one row that asks the writer for something, and it is at the top
    /// because everything below it is a fact and this is a question.
    func test_apendingDeviceIsListedFirstWithWhatItIsWaitingOn() throws {
        let model = model(registry(), pending: [stranger.fingerprint: 14])

        XCTAssertEqual(model.pending.count, 1)
        let request = try XCTUnwrap(model.pending.first)
        XCTAssertEqual(request.name, "The old iPhone")
        XCTAssertEqual(request.code, DeviceCode.short(stranger.fingerprint))
        XCTAssertEqual(request.heldLines, 14)
        XCTAssertTrue(request.sentence.contains("14"),
                      "the count is in the sentence: \(request.sentence)")
    }

    /// A device with nothing on disk to describe it is named by its code — the
    /// four characters its own Settings screen shows, which is the whole of
    /// how an admission is checked.
    func test_apendingDeviceWithNoRecordIsNamedByItsCode() {
        let unknown = DeviceIdentity.softwareForTesting()
        let model = model(registry(), pending: [unknown.fingerprint: 3])

        XCTAssertEqual(model.pending.first?.name, DeviceCode.short(unknown.fingerprint))
    }

    /// **An admitted device is never pending, whatever a stale count says.**
    /// The counts come from the last read; the verdicts come from the registry
    /// as it stands now, and admitting somebody must take their row away rather
    /// than leave the writer a button that would do nothing.
    func test_acountForAnAdmittedDeviceRaisesNoRequest() {
        let model = model(registry(), pending: [phone.fingerprint: 9,
                                                mac.fingerprint: 2])

        XCTAssertTrue(model.pending.isEmpty,
                      "the phone is admitted and the Mac is this device: \(model.pending)")
    }

    // MARK: - One row per person, devices nested

    func test_eachAdmittedPersonIsOneRowCarryingTheirDevices() throws {
        let model = model(registry())

        XCTAssertEqual(model.people.map(\.label), ["Denver", "Denver"])
        let phoneRow = try XCTUnwrap(
            model.people.first { $0.fingerprint == phone.fingerprint })
        XCTAssertEqual(phoneRow.role, "author")
        XCTAssertEqual(phoneRow.devices.map(\.name), ["Denver's iPhone"])
        XCTAssertEqual(phoneRow.devices.first?.kind, "iPhone")
    }

    /// The device's own name is shown beside the label whenever the two differ
    /// — a writer who called both machines "Denver" needs to know which is
    /// which before they revoke one.
    func test_thedeviceSownNameIsShownWhenItDiffersFromTheLabel() throws {
        let model = model(registry())
        let phoneRow = try XCTUnwrap(
            model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertEqual(phoneRow.ownName, "Denver's iPhone")
        XCTAssertTrue(phoneRow.title.contains("Denver"))
        XCTAssertTrue(phoneRow.title.contains("Denver's iPhone"))
    }

    func test_alabelThatAlreadyIsTheDevicesOwnNameIsNotRepeated() throws {
        let same = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac)],
            people: [person(mac, label: "Denver's MacBook",
                            ownName: "Denver's MacBook", admittedBy: mac)])
        let model = model(same)

        XCTAssertNil(model.people.first?.ownName)
        XCTAssertEqual(model.people.first?.title, "Denver's MacBook")
    }

    /// Every actor the device holds, as words. A writer looking at what a
    /// machine may write in their book is owed the four writers by name, not a
    /// count of keys.
    func test_adeviceListsTheActorsItHoldsAsWords() throws {
        let model = model(registry())
        let macRow = try XCTUnwrap(model.people.first { $0.fingerprint == mac.fingerprint })

        XCTAssertEqual(macRow.devices.first?.actors, ["author", "assistant"],
                       "in the order the enum declares them")
    }

    func test_thisMacsOwnDeviceIsMarked() throws {
        let model = model(registry())
        let macRow = try XCTUnwrap(model.people.first { $0.fingerprint == mac.fingerprint })
        let phoneRow = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertTrue(macRow.devices.first?.isThisMac == true)
        XCTAssertFalse(phoneRow.devices.first?.isThisMac == true)
    }

    func test_therootIsMarkedThisMacWhenItIsThisMac() throws {
        let model = model(registry())
        let macRow = try XCTUnwrap(model.people.first { $0.fingerprint == mac.fingerprint })

        XCTAssertEqual(macRow.mark, "this Mac")
        XCTAssertNil(model.people.first { $0.fingerprint == phone.fingerprint }?.mark)
    }

    /// A root somebody else owns, whose chain this device joined: it is still
    /// the root, and saying "this Mac" of it would be a lie about whose machine
    /// holds the book.
    func test_aforeignRootIsMarkedByWhoseMacItIs() throws {
        let joined = Registry(
            devices: [deviceRecord(otherRoot, name: "Amelia's MacBook", kind: .mac),
                      deviceRecord(mac, name: "Denver's MacBook", kind: .mac)],
            people: [person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                            admittedBy: otherRoot),
                     person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: otherRoot)])
        let model = model(joined)

        let rootRow = try XCTUnwrap(
            model.people.first { $0.fingerprint == otherRoot.fingerprint })
        XCTAssertEqual(rootRow.mark, "Amelia\u{2019}s Mac")
    }

    func test_arevokedPersonSaysSoAndKeepsTheirRow() throws {
        let model = model(registry(revoked: true))
        let phoneRow = try XCTUnwrap(
            model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertNotNil(phoneRow.revokedAt)
        XCTAssertTrue(phoneRow.detail.lowercased().contains("revoked"),
                      "the row says what happened: \(phoneRow.detail)")
    }

    // MARK: - Who may revoke, and who may retire (P2b Task 7, spec §5)

    /// **Only the root that admitted them.** A person record is signed by the
    /// root it names, so a Mac that is not that root would write a file every
    /// reader lists as malformed — a device un-admitted in silence rather than
    /// revoked.
    func test_thedeviceThisMacAdmittedMayBeRevoked() throws {
        let model = model(registry())
        let person = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertTrue(person.canRevoke)
        XCTAssertNil(person.whyNotRevocable)
    }

    /// A root answers to itself: it is claimed over, never revoked (spec §5).
    func test_arootIsNotRevocableAndSaysWhy() throws {
        let model = model(registry())
        let root = try XCTUnwrap(model.people.first { $0.fingerprint == mac.fingerprint })

        XCTAssertFalse(root.canRevoke)
        XCTAssertEqual(root.whyNotRevocable, PeopleAndDevicesModel.revokeARoot)
    }

    /// Revoking twice would move the line the first revocation drew, so the
    /// second press is refused before it is offered.
    func test_analreadyRevokedPersonIsNotRevokedAgain() throws {
        let model = model(registry(revoked: true))
        let person = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertFalse(person.canRevoke)
        XCTAssertEqual(person.whyNotRevocable, PeopleAndDevicesModel.alreadyRevoked)
    }

    /// **A person somebody else's root admitted is their record to change.**
    ///
    /// The case is this Mac having JOINED another root's chain: everyone on it
    /// is listed here, because they are who may write in this book, and the
    /// records are signed by the root that admitted them — so revoking one from
    /// here would write a file every reader lists as malformed. A person under
    /// a root this Mac is NOT on is a different thing again: they are not in
    /// this Mac's chain, so they are not a row at all, and the claimant line
    /// above is what says so.
    func test_apersonAdmittedByAnotherRootIsNotThisMacsToRevoke() throws {
        let registry = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(phone, name: "Denver's iPhone")],
            people: [person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                            admittedBy: otherRoot),
                     person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: otherRoot),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: otherRoot)])
        let table = TrustTable.resolve(
            registry: registry, mine: .forAuthor(mac), joinedRoot: nil)
        XCTAssertEqual(table.myRoot, otherRoot.fingerprint,
                       "this Mac is on somebody else's chain")

        let model = PeopleAndDevicesModel.make(
            registry: registry, table: table, remembered: [:], requests: [],
            claimants: [], standing: standing(), me: mac.fingerprint)

        let theirs = try XCTUnwrap(
            model.people.first { $0.fingerprint == phone.fingerprint },
            "everyone on the chain this Mac judges by is listed")
        XCTAssertFalse(theirs.canRevoke)
        XCTAssertEqual(theirs.whyNotRevocable, PeopleAndDevicesModel.revokeNotMine)
    }

    /// **A device signs its own retirement** (spec §5), so exactly one row
    /// offers it: this Mac's.
    func test_onlyThisMacsOwnRowMayRetire() throws {
        let model = model(registry())
        let devices = model.people.flatMap(\.devices)

        let mine = try XCTUnwrap(devices.first { $0.fingerprint == mac.fingerprint })
        XCTAssertTrue(mine.canRetire)
        XCTAssertNil(mine.whyNotRetirable)

        let theirs = try XCTUnwrap(devices.first { $0.fingerprint == phone.fingerprint })
        XCTAssertFalse(theirs.canRetire)
        XCTAssertEqual(theirs.whyNotRetirable, PeopleAndDevicesModel.retireNotThisDevice)
    }

    // MARK: - The way back, and what retirement means (fix round 1)

    /// **The inverse of a revocation is an admission by the same authority**
    /// (Important 3b), so the row that revoked them offers it — and only that
    /// row: `RegistryAdmission.admit` refuses anybody else's record, and a
    /// button that cannot act is worse than none.
    func test_arevokedRowOffersTheWayBack() throws {
        let model = model(registry(revoked: true))
        let person = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertTrue(person.canReadmit)
        XCTAssertFalse(person.canRevoke, "there is nothing left to revoke")
        XCTAssertEqual(person.recordedOwnName, "Denver's iPhone",
                       "and a re-admission writes the name the record holds, not a rename")
    }

    /// A person who is not revoked is not offered a way back into a room they
    /// are standing in.
    func test_anadmittedRowOffersNoReadmission() throws {
        let model = model(registry())
        let person = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })

        XCTAssertFalse(person.canReadmit)
        XCTAssertTrue(person.canRevoke)
    }

    /// A revoked person under somebody ELSE's root is not this Mac's to let
    /// back in, for the reason they were not this Mac's to revoke.
    func test_arevokedPersonOfAnotherRootIsNotThisMacsToReadmit() throws {
        let registry = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(phone, name: "Denver's iPhone")],
            people: [person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                            admittedBy: otherRoot),
                     person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: otherRoot),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: otherRoot, revoked: true)])
        let table = TrustTable.resolve(
            registry: registry, mine: .forAuthor(mac), joinedRoot: nil)

        let model = PeopleAndDevicesModel.make(
            registry: registry, table: table, remembered: [:], requests: [],
            claimants: [], standing: standing(), me: mac.fingerprint)

        let theirs = try XCTUnwrap(model.people.first { $0.fingerprint == phone.fingerprint })
        XCTAssertFalse(theirs.canReadmit)
    }

    /// **The machine that retired is told what retirement means** (Important
    /// 2): its key removed its own future authority and not its ability to
    /// write, so it goes on applying its own lines while every peer sets them
    /// aside — and nothing else on this screen says so.
    func test_thismacsOwnRetiredRowSaysWhatRetirementMeans() throws {
        let retired = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac,
                                   retiredAt: Date(timeIntervalSince1970: 1_757_000_000)),
                      deviceRecord(phone, name: "Denver's iPhone")],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: mac)])
        let model = PeopleAndDevicesModel.make(
            registry: retired,
            table: TrustTable.resolve(
                registry: retired, mine: .forAuthor(mac), joinedRoot: nil),
            remembered: [:], requests: [], claimants: [],
            standing: standing(), me: mac.fingerprint)

        let mine = try XCTUnwrap(
            model.people.flatMap(\.devices).first { $0.fingerprint == mac.fingerprint })
        let notice = try XCTUnwrap(mine.retirementNotice)
        XCTAssertTrue(notice.hasPrefix("This Mac retired on "), notice)
        XCTAssertTrue(
            notice.contains(
                "what it writes now stays on this Mac and is set aside everywhere else"),
            notice)
        XCTAssertFalse(mine.canRetire, "and it cannot retire twice")
    }

    /// **A peer's retirement is a fact about a machine the writer is not
    /// sitting at.** The date is on the row; the sentence about what is still
    /// being applied is not, because it would be a claim about somebody else's
    /// desk.
    func test_apeersRetiredRowCarriesTheDateAndNotTheSentence() throws {
        let retired = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(phone, name: "Denver's iPhone",
                                   retiredAt: Date(timeIntervalSince1970: 1_757_000_000))],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: mac)])
        let model = PeopleAndDevicesModel.make(
            registry: retired,
            table: TrustTable.resolve(
                registry: retired, mine: .forAuthor(mac), joinedRoot: nil),
            remembered: [:], requests: [], claimants: [],
            standing: standing(), me: mac.fingerprint)

        let theirs = try XCTUnwrap(
            model.people.flatMap(\.devices).first { $0.fingerprint == phone.fingerprint })
        XCTAssertNil(theirs.retirementNotice)
        XCTAssertTrue(theirs.detail.contains("retired"), theirs.detail)
    }

    // MARK: - Claimants and merged roots

    /// Somebody claiming a book this device already belongs to another copy of.
    /// Listed, never merged — and the one control on the row is disabled until
    /// merging ships.
    func test_aclaimantIsListedWithNothingToPressYet() {
        let model = model(registry(), claimants: [otherRoot.fingerprint])

        XCTAssertEqual(model.claimants.map(\.fingerprint), [otherRoot.fingerprint])
        XCTAssertEqual(model.claimants.first?.code,
                       DeviceCode.short(otherRoot.fingerprint))
        XCTAssertFalse(PeopleAndDevicesModel.mergeSoon.isEmpty)
    }

    /// **A claimant this device has adopted is MERGED, not a claimant** (Task
    /// 2's carry). Listing it in both places would ask the writer to answer a
    /// question they have already answered.
    func test_aclaimantThisDeviceAdoptedIsDrawnAsMerged() {
        let claimed = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac)],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     person(otherRoot, label: "Amelia", ownName: "Amelia's MacBook",
                            admittedBy: otherRoot)],
            claims: [ClaimRecord(newRoot: mac.fingerprint,
                                 adopted: [otherRoot.fingerprint],
                                 claimedAt: admitted)])
        let model = model(claimed, claimants: [otherRoot.fingerprint])

        XCTAssertEqual(model.merged.map(\.fingerprint), [otherRoot.fingerprint])
        XCTAssertTrue(model.claimants.isEmpty,
                      "adopted is answered; it is not still asking: \(model.claimants)")
    }

    // MARK: - What this device remembers

    /// A device this Mac gave a label to, whose record is no longer in the
    /// folder: the memory is the only thing left naming it, and **Forget this
    /// device** is what clears it.
    func test_adeviceRememberedButAbsentCanBeForgotten() {
        let gone = DeviceIdentity.softwareForTesting()
        let model = model(
            registry(),
            remembered: [gone.fingerprint: .init(label: "Amelia",
                                                 ownName: "Amelia's iPhone",
                                                 labelledAt: admitted)])

        XCTAssertEqual(model.absent.map(\.fingerprint), [gone.fingerprint])
        XCTAssertEqual(model.absent.first?.name, "Amelia")
    }

    func test_adeviceRememberedAndStillOnDiskIsNotOfferedForForgetting() {
        let model = model(
            registry(),
            remembered: [phone.fingerprint: .init(label: "Denver",
                                                  ownName: "Denver's iPhone",
                                                  labelledAt: admitted)])

        XCTAssertTrue(model.absent.isEmpty,
                      "its record is right there: \(model.absent)")
    }

    // MARK: - The share sentence

    /// The one sentence that says what this section can and cannot do. Removing
    /// a device stops Maugham applying its writes; it does not take the folder
    /// away from it.
    func test_theShareSentenceIsSaidOnce() {
        XCTAssertTrue(PeopleAndDevicesModel.shareSentence.contains("iCloud share"))
        XCTAssertTrue(PeopleAndDevicesModel.shareSentence.contains("stops Maugham applying"))
    }

    // MARK: - A registry that cannot be read

    /// **RULING-54.** A registry record present and unreadable answers with the
    /// read's own sentence, never with an empty list: empty rows would say
    /// *nobody may write in this book*, which is a trust decision nobody made.
    func test_anUnreadableRegistryShowsItsRefusalRatherThanEmptyRows() {
        let refusal = DeviceStanding.refused(
            mine: .forAuthor(mac),
            error: NSError(domain: "test", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "people/deadbeef.json is present and unreadable"]))
        let model = PeopleAndDevicesModel.make(
            registry: registry(), table: table(registry()), remembered: [:],
            requests: AdmissionDecision.requests(
                pending: [stranger.fingerprint: 4], registry: registry(),
                memory: [:], myRoot: mac.fingerprint),
            claimants: [otherRoot.fingerprint],
            standing: refusal, me: mac.fingerprint)

        XCTAssertEqual(model.refusal, refusal.sentence)
        XCTAssertTrue(model.people.isEmpty)
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(model.claimants.isEmpty)
        XCTAssertTrue(model.absent.isEmpty)
    }

    // MARK: - No chain at all

    /// B3: a book this device is on no chain of judges nobody, so there is
    /// nobody to list. The standing sentence is what says so.
    func test_abookWithNoChainListsNobody() {
        let empty = Registry()
        let model = PeopleAndDevicesModel.make(
            registry: empty,
            table: TrustTable.resolve(registry: empty, mine: .forAuthor(mac),
                                      joinedRoot: nil),
            remembered: [:], requests: [], claimants: [],
            standing: DeviceStanding(code: DeviceCode.short(mac.fingerprint)),
            me: mac.fingerprint)

        XCTAssertTrue(model.people.isEmpty)
        XCTAssertEqual(model.standing, "Not yet admitted — the Mac will ask")
    }

    // MARK: - Purity

    /// It reads no folder, no clock and no shared memory: the same inputs
    /// answer the same model, twice.
    func test_theModelIsAPureFunctionOfItsInputs() {
        let first = model(registry(), pending: [stranger.fingerprint: 2],
                          claimants: [otherRoot.fingerprint])
        let second = model(registry(), pending: [stranger.fingerprint: 2],
                           claimants: [otherRoot.fingerprint])

        XCTAssertEqual(first, second)
    }
}
