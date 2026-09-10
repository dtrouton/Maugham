import Foundation
import XCTest
@testable import MaughamCore

/// Who a seal's key is to THIS device — one pure function over a verified
/// registry, six answers, no I/O and no clock.
///
/// Every fixture here builds a `Registry` value directly. That is deliberate:
/// the reader has already decided which records are records, and this function
/// is asked only what those facts MEAN to the device holding these keys. A test
/// that had to write and re-read files would be testing the reader twice and
/// this function once.
final class TrustTableTests: XCTestCase {

    private var mine: LocalIdentities!

    override func setUp() {
        super.setUp()
        mine = .softwareForTesting()
    }

    // MARK: - Fixtures

    /// A fresh key's fingerprint, for a device that is not this one.
    private func foreignKey() -> String { DeviceIdentity.softwareForTesting().fingerprint }

    private func rootRecord(_ fingerprint: String, at seconds: TimeInterval = 10) -> PersonRecord {
        PersonRecord(
            person: fingerprint, label: "Denver", ownName: "Denver's MacBook",
            admittedAt: Date(timeIntervalSince1970: seconds), admittedBy: fingerprint)
    }

    private func admittedRecord(
        _ fingerprint: String, under root: String, at seconds: TimeInterval = 20,
        label: String = "Denver", ownName: String = "Denver's iPhone",
        revokedAt: Date? = nil, revokedBy: String? = nil, highestOpIdSeen: String? = nil
    ) -> PersonRecord {
        PersonRecord(
            person: fingerprint, label: label, ownName: ownName,
            admittedAt: Date(timeIntervalSince1970: seconds), admittedBy: root,
            revokedAt: revokedAt, revokedBy: revokedBy, highestOpIdSeen: highestOpIdSeen)
    }

    private func deviceRecord(
        _ fingerprint: String, actors extra: [String: String] = [:],
        name: String = "Denver's iPhone", kind: DeviceKind = .phone
    ) -> DeviceRecord {
        DeviceRecord(
            device: fingerprint, name: name, kind: kind,
            actors: extra.merging([DeviceActor.author.rawValue: fingerprint]) { a, _ in a },
            madeAt: Date(timeIntervalSince1970: 5))
    }

    // MARK: - `.mine`

    func test_everyActorKeyThisDeviceHoldsIsMine() {
        let table = TrustTable.resolve(
            registry: Registry(people: [rootRecord(mine.author.fingerprint)]),
            mine: mine, joinedRoot: nil)

        for identity in mine.all {
            XCTAssertEqual(table.verdict(forSealKey: identity.fingerprint), .mine,
                           "\(identity.deviceId) is this device's own writer")
        }
    }

    /// `.mine` is answered before the chain is consulted at all: a device with
    /// no registry still knows its own hand.
    func test_myOwnKeysAreMineEvenWithNoChainWhatever() {
        let table = TrustTable.resolve(registry: Registry(), mine: mine, joinedRoot: nil)

        XCTAssertNil(table.myRoot)
        XCTAssertEqual(table.verdict(forSealKey: mine.assistant.fingerprint), .mine)
    }

    // MARK: - `.noChain` (decision B3)

    func test_anEmptyRegistryLeavesThisDeviceWithNoChain() {
        let table = TrustTable.resolve(registry: Registry(), mine: mine, joinedRoot: nil)

        XCTAssertNil(table.myRoot)
        XCTAssertEqual(table.verdict(forSealKey: foreignKey()), .noChain)
    }

    /// The claim case (P2b): a registry exists, it names none of this device's
    /// keys, and this device has no root record of its own. There is no chain
    /// to judge by, so every foreign seal reads as P1's unsigned history —
    /// including one from a device with a full record under someone else's root.
    func test_aRegistryNamingNoneOfMineWithNoRootOfMyOwnIsNoChain() {
        let otherRoot = foreignKey()
        let otherPhone = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(otherRoot, name: "Someone's MacBook", kind: .mac),
                      deviceRecord(otherPhone)],
            people: [rootRecord(otherRoot), admittedRecord(otherPhone, under: otherRoot)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertNil(table.myRoot)
        XCTAssertEqual(table.verdict(forSealKey: otherRoot), .noChain)
        XCTAssertEqual(table.verdict(forSealKey: otherPhone), .noChain)
    }

    // MARK: - Which root is mine

    func test_aSelfSignedRootRecordForMyAuthorKeyMakesMeMyOwnRoot() {
        let registry = Registry(people: [rootRecord(mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.myRoot, mine.author.fingerprint)
    }

    /// The phone's case: a Mac's chain names this device, so this device is on
    /// that chain (B1) and the caller persists it as `joinedRoot`.
    func test_theRootWhoseChainNamesMeIsMyRoot() {
        let mac = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(mine.author.fingerprint)],
            people: [rootRecord(mac),
                     admittedRecord(mine.author.fingerprint, under: mac)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.myRoot, mac)
        XCTAssertEqual(table.verdict(forSealKey: mac), .admitted(person: mac))
    }

    /// B1, the strong form: a self-signed root record for MY key can only have
    /// been written by my key, so it outranks anybody else's claim to have
    /// admitted me. A device never switches roots on its own.
    func test_myOwnRootRecordOutranksAForeignRootThatAdmittedMe() {
        let claimant = foreignKey()
        let registry = Registry(
            people: [rootRecord(mine.author.fingerprint, at: 10),
                     rootRecord(claimant, at: 5),
                     admittedRecord(mine.author.fingerprint, under: claimant, at: 6)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.myRoot, mine.author.fingerprint)
        XCTAssertEqual(table.verdict(forSealKey: claimant), .otherRoot(root: claimant))
    }

    /// B1: joined once, stays. The caller's remembered root wins over a root
    /// record of this device's own.
    func test_theJoinedRootWinsOverASelfSignedRecordOfMyOwn() {
        let mac = foreignKey()
        let registry = Registry(
            people: [rootRecord(mac), rootRecord(mine.author.fingerprint),
                     admittedRecord(mine.author.fingerprint, under: mac)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: mac)

        XCTAssertEqual(table.myRoot, mac)
        XCTAssertEqual(table.verdict(forSealKey: mac), .admitted(person: mac))
    }

    // MARK: - `.admitted`

    func test_aDeviceAdmittedUnderMyRootIsAdmitted() {
        let phone = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(phone)],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(phone, under: mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: phone), .admitted(person: phone))
    }

    /// Admitting a device admits every actor its record lists (spec §4.4), and
    /// each of them answers as that device's PERSON — which is how what Claude
    /// wrote on another Mac reads as that Mac's, rather than as a stranger.
    func test_anActorKeyOfAnAdmittedDeviceIsAdmittedAsThatDevicesPerson() {
        let mac = foreignKey()
        let itsAssistant = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(
                mac, actors: [DeviceActor.assistant.rawValue: itsAssistant],
                name: "Denver's other MacBook", kind: .mac)],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(mac, under: mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: itsAssistant), .admitted(person: mac))
    }

    // MARK: - `.stranger`

    func test_aDeviceWithARecordButNoAdmissionIsAStrangerNamingItsDevice() {
        let phone = foreignKey()
        let itsTranslator = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(
                phone, actors: [DeviceActor.translator.rawValue: itsTranslator])],
            people: [rootRecord(mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: phone), .stranger(device: phone))
        XCTAssertEqual(table.verdict(forSealKey: itsTranslator), .stranger(device: phone))
    }

    func test_aKeyWithNoRecordAtAllIsAStrangerNamingNoDevice() {
        let registry = Registry(people: [rootRecord(mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: foreignKey()), .stranger(device: nil))
    }

    // MARK: - `.revoked`

    func test_aRevokedPersonIsRevokedWithTheOpIdTheRootHadSeen() {
        let phone = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(phone)],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(
                        phone, under: mine.author.fingerprint,
                        revokedAt: Date(timeIntervalSince1970: 99),
                        revokedBy: mine.author.fingerprint,
                        highestOpIdSeen: "01J0000000000000000000000A")])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(
            table.verdict(forSealKey: phone),
            .revoked(person: phone, highestOpIdSeen: "01J0000000000000000000000A"))
    }

    // MARK: - `.otherRoot`

    func test_aSecondSelfSignedRootIsAnotherClaimant() {
        let claimant = foreignKey()
        let registry = Registry(
            people: [rootRecord(mine.author.fingerprint), rootRecord(claimant)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: claimant), .otherRoot(root: claimant))
    }

    func test_aDeviceAdmittedUnderAnotherRootBelongsToThatRoot() {
        let claimant = foreignKey()
        let theirPhone = foreignKey()
        let itsMaugham = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(
                theirPhone, actors: [DeviceActor.maugham.rawValue: itsMaugham])],
            people: [rootRecord(mine.author.fingerprint), rootRecord(claimant),
                     admittedRecord(theirPhone, under: claimant)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: theirPhone), .otherRoot(root: claimant))
        XCTAssertEqual(table.verdict(forSealKey: itsMaugham), .otherRoot(root: claimant))
    }

    // MARK: - The transitions

    func test_admittingAStrangerTurnsItIntoAdmittedOnReResolve() {
        let phone = foreignKey()
        let devices = [deviceRecord(phone)]
        let before = Registry(devices: devices, people: [rootRecord(mine.author.fingerprint)])

        XCTAssertEqual(
            TrustTable.resolve(registry: before, mine: mine, joinedRoot: nil)
                .verdict(forSealKey: phone),
            .stranger(device: phone))

        let after = Registry(
            devices: devices,
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(phone, under: mine.author.fingerprint)])

        XCTAssertEqual(
            TrustTable.resolve(registry: after, mine: mine, joinedRoot: nil)
                .verdict(forSealKey: phone),
            .admitted(person: phone))
    }

    func test_revokingAnAdmittedPersonTurnsItIntoRevokedOnReResolve() {
        let phone = foreignKey()
        let devices = [deviceRecord(phone)]
        let before = Registry(
            devices: devices,
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(phone, under: mine.author.fingerprint)])

        XCTAssertEqual(
            TrustTable.resolve(registry: before, mine: mine, joinedRoot: nil)
                .verdict(forSealKey: phone),
            .admitted(person: phone))

        let after = Registry(
            devices: devices,
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(
                        phone, under: mine.author.fingerprint,
                        revokedAt: Date(timeIntervalSince1970: 99),
                        revokedBy: mine.author.fingerprint, highestOpIdSeen: "01J-SEEN")])

        XCTAssertEqual(
            TrustTable.resolve(registry: after, mine: mine, joinedRoot: nil)
                .verdict(forSealKey: phone),
            .revoked(person: phone, highestOpIdSeen: "01J-SEEN"))
    }

    /// A revoked person is still IN the chain — the reason the reader keeps
    /// them there is so this answer can be `.revoked` rather than `.stranger`,
    /// which is what lets the walk say *after revocation* about a late op.
    func test_aRevokedPersonIsNotDemotedToAStranger() {
        let phone = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(phone)],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(
                        phone, under: mine.author.fingerprint,
                        revokedAt: Date(timeIntervalSince1970: 99),
                        revokedBy: mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(
            table.verdict(forSealKey: phone),
            .revoked(person: phone, highestOpIdSeen: nil))
    }
}
