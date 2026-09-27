// MaughamTests/PeopleAndDevicesPersonKeyTests.swift
import XCTest
@testable import Maugham
@testable import MaughamCore

/// **People & Devices' person-key line and Forget** (your devices are you,
/// plan 1 Task 7), and Revoke's sentence about the key it leaves behind.
///
/// Everything is a value over a registry built in memory — nothing mounted,
/// nothing pressed (tripwire 33).
@MainActor
final class PeopleAndDevicesPersonKeyTests: XCTestCase {

    private var mac: DeviceIdentity!
    private var phone: DeviceIdentity!
    private var samMac: DeviceIdentity!
    private var otherRoot: DeviceIdentity!
    private let key = "person-key-denver"
    private let samKey = "person-key-sam"

    override func setUp() async throws {
        mac = .softwareForTesting()
        phone = .softwareForTesting()
        samMac = .softwareForTesting()
        otherRoot = .softwareForTesting()
    }

    // MARK: - Fixture

    private let admitted = Date(timeIntervalSince1970: 1_757_000_000)

    private func deviceRecord(_ identity: DeviceIdentity, name: String) -> DeviceRecord {
        DeviceRecord(
            device: identity.fingerprint, name: name, kind: .phone,
            actors: [DeviceActor.author.rawValue: identity.fingerprint],
            madeAt: admitted)
    }

    private func person(
        _ identity: DeviceIdentity, label: String, admittedBy: DeviceIdentity,
        key: String? = nil, revoked: Bool = false
    ) -> PersonRecord {
        PersonRecord(
            person: identity.fingerprint, label: label, ownName: label,
            admittedAt: admitted, admittedBy: admittedBy.fingerprint,
            revokedAt: revoked ? admitted.addingTimeInterval(60) : nil,
            revokedBy: revoked ? admittedBy.fingerprint : nil,
            personKey: key)
    }

    /// Denver's Mac (the root) and his iPhone, both linked to his key; Sam's
    /// Mac with no key.
    private func registry(
        linked: Bool = true, phoneRevoked: Bool = false, samKeyed: Bool = false,
        samRevoked: Bool = false
    ) -> Registry {
        Registry(
            devices: [
                deviceRecord(mac, name: "Denver’s MacBook Pro"),
                deviceRecord(phone, name: "Denver’s iPhone"),
                deviceRecord(samMac, name: "Sam’s MacBook Air"),
            ],
            people: [
                person(mac, label: "Denver Trouton", admittedBy: mac,
                       key: linked ? key : nil),
                person(phone, label: "Denver Trouton", admittedBy: mac,
                       key: linked ? key : nil, revoked: phoneRevoked),
                person(samMac, label: "Sam", admittedBy: mac,
                       key: samKeyed ? samKey : nil, revoked: samRevoked),
            ])
    }

    private func model(
        _ registry: Registry, me: DeviceIdentity? = nil
    ) -> PeopleAndDevicesModel {
        let me = me ?? mac!
        let table = TrustTable.resolve(
            registry: registry, mine: .forAuthor(me), joinedRoot: nil)
        return PeopleAndDevicesModel.make(
            registry: registry, table: table, remembered: [:],
            requests: [], claimants: [],
            standing: DeviceStanding(
                code: DeviceCode.short(me.fingerprint), label: "Denver Trouton",
                rootLabel: "Denver Trouton", admitted: true,
                isRoot: me.fingerprint == mac.fingerprint),
            me: me.fingerprint)
    }

    private func group(_ model: PeopleAndDevicesModel, _ label: String) throws
        -> PeopleAndDevicesModel.PersonGroup
    {
        try XCTUnwrap(model.groups.first { $0.label == label })
    }

    // MARK: - The line

    func test_aLinkedPersonSaysTheyAreRecognisedAndTheRootIsOfferedForget() throws {
        let denver = try group(model(registry()), "Denver Trouton")

        XCTAssertEqual(denver.personKeyLine,
                       "Recognised on every device signed into this person’s Apple ID.")
        XCTAssertEqual(denver.personKeyLine,
                       PeopleAndDevicesModel.PersonGroup.recognisedSentence)
        XCTAssertTrue(denver.offersForgetPersonKey)
        XCTAssertNotNil(denver.forgetSubject)
    }

    func test_aPersonWithNoLinkedKeySaysNothingAndOffersNoForget() throws {
        let model = model(registry(linked: false))
        let denver = try group(model, "Denver Trouton")
        let sam = try group(model, "Sam")

        for group in [denver, sam] {
            XCTAssertNil(group.personKeyLine, group.label)
            XCTAssertFalse(group.offersForgetPersonKey, group.label)
            XCTAssertNil(group.forgetSubject, group.label)
        }
    }

    /// **Root only, and HIDDEN elsewhere**: an admitted Mac that is not the
    /// root still says the fact, and draws no Forget at all.
    func test_onAMacThatIsNotTheRootTheLineStandsAndForgetIsHidden() throws {
        let denver = try group(model(registry(), me: phone), "Denver Trouton")

        XCTAssertEqual(denver.personKeyLine,
                       PeopleAndDevicesModel.PersonGroup.recognisedSentence)
        XCTAssertFalse(denver.offersForgetPersonKey)
    }

    /// Forget is label-wide, so it is offered only where THIS Mac may re-sign
    /// every record holding the key — the verb's own `renameOutcome`, asked of
    /// every holder. One holder another root admitted refuses the whole act.
    func test_forgetIsNotOfferedWhereAnyHolderIsAnotherRootsToReSign() throws {
        let foreign = person(otherRoot, label: "Sam", admittedBy: otherRoot, key: samKey)
        var reg = registry(samKeyed: true)
        reg = Registry(devices: reg.devices, people: reg.people + [foreign])

        let sam = try group(model(reg), "Sam")

        XCTAssertEqual(sam.personKeyLine,
                       PeopleAndDevicesModel.PersonGroup.recognisedSentence)
        XCTAssertFalse(sam.offersForgetPersonKey,
                       "the verb would refuse: one holder is not this Mac's to re-sign")
        let alone = try group(model(registry(samKeyed: true)), "Sam")
        XCTAssertTrue(alone.offersForgetPersonKey, "the control")
    }

    /// Every record of the label revoked: recognition asks (Task 5's ruling),
    /// so the line does not claim they are recognised — and Forget is still
    /// offered, because it is the one way to release a revoked person's key.
    func test_aLinkedPersonWhoseEveryDeviceIsRevokedIsNotSaidToBeRecognised() throws {
        let sam = try group(model(registry(samKeyed: true, samRevoked: true)), "Sam")

        XCTAssertEqual(sam.personKeyLine,
                       PeopleAndDevicesModel.PersonGroup.linkedButRevokedSentence)
        XCTAssertTrue(sam.offersForgetPersonKey)
    }

    /// One revoked phone does not stop the rest of the person being recognised.
    func test_aRevokedPhoneBesideAStandingMacIsStillRecognised() throws {
        let denver = try group(model(registry(phoneRevoked: true)), "Denver Trouton")

        XCTAssertEqual(denver.personKeyLine,
                       PeopleAndDevicesModel.PersonGroup.recognisedSentence)
    }

    // MARK: - Forget's confirmation

    func test_forgetAsksFirstAndSaysWhatItCostsAndWhatItKeeps() {
        let confirmation = PeopleAndDevicesConfirmation.forgetPersonKey(
            person: mac.fingerprint, label: "Denver Trouton")

        XCTAssertEqual(confirmation.verb, .forgetPersonKey)
        XCTAssertEqual(confirmation.fingerprint, mac.fingerprint)
        XCTAssertEqual(confirmation.confirmTitle, "Forget")
        XCTAssertTrue(confirmation.message.contains("asked about again"),
                      confirmation.message)
        XCTAssertTrue(confirmation.message.contains("already let in stay"),
                      confirmation.message)
        XCTAssertNil(confirmation.alternate)
    }

    // MARK: - Forget that did not finish, in words

    func test_aForgetThatDidNotFinishNamesTheDevicesClearedAndNotCleared() {
        let model = model(registry())
        let error = PersonKeyForgetIncomplete(
            cleared: [mac.fingerprint], notCleared: [phone.fingerprint],
            underlying: CocoaError(.fileWriteNoPermission))

        let sentence = model.forgetIncompleteSentence(error)

        XCTAssertTrue(sentence.contains(
            "no longer linked on Denver’s MacBook Pro (\(DeviceCode.short(mac.fingerprint)))"),
            sentence)
        XCTAssertTrue(sentence.contains(
            "still linked on Denver’s iPhone (\(DeviceCode.short(phone.fingerprint)))"),
            sentence)
        XCTAssertTrue(sentence.contains("Press Forget again"), sentence)
    }

    func test_aForgetThatClearedNothingSaysSo() {
        let model = model(registry())
        let error = PersonKeyForgetIncomplete(
            cleared: [], notCleared: [mac.fingerprint, phone.fingerprint],
            underlying: nil)

        let sentence = model.forgetIncompleteSentence(error)

        XCTAssertTrue(sentence.hasPrefix("Nothing was forgotten."), sentence)
        XCTAssertTrue(sentence.contains("Denver’s MacBook Pro"), sentence)
        XCTAssertTrue(sentence.contains("Denver’s iPhone"), sentence)
        XCTAssertFalse(sentence.contains("no longer linked"), sentence)
    }

    // MARK: - Revoke says Forget is the verb for a compromised key (Task 5's carry)

    func test_revokingADeviceOfALinkedPersonSaysForgetIsTheVerbForACompromisedKey() throws {
        let denver = try group(model(registry()), "Denver Trouton")

        let confirmation = PeopleAndDevicesConfirmation.revoke(
            person: phone.fingerprint, named: "Denver’s iPhone",
            personKey: denver.personKeyAfterRevoking(phone.fingerprint))

        XCTAssertTrue(confirmation.message.contains(
            PeopleAndDevicesConfirmation.revokeKeepsTheKeyRecognised), confirmation.message)
    }

    func test_revokingTheLastStandingDeviceSaysTheKeyStaysLinked() throws {
        let sam = try group(model(registry(samKeyed: true)), "Sam")

        XCTAssertEqual(sam.personKeyAfterRevoking(samMac.fingerprint), .staysLinked)
        let confirmation = PeopleAndDevicesConfirmation.revoke(
            person: samMac.fingerprint, named: "Sam",
            personKey: sam.personKeyAfterRevoking(samMac.fingerprint))
        XCTAssertTrue(confirmation.message.contains(
            PeopleAndDevicesConfirmation.revokeLeavesTheKeyLinked), confirmation.message)
        XCTAssertFalse(confirmation.message.contains(
            PeopleAndDevicesConfirmation.revokeKeepsTheKeyRecognised))
    }

    func test_revokingSomebodyWithNoLinkedKeySaysNothingAboutKeys() throws {
        let sam = try group(model(registry()), "Sam")

        XCTAssertEqual(sam.personKeyAfterRevoking(samMac.fingerprint), .noKey)
        let confirmation = PeopleAndDevicesConfirmation.revoke(
            person: samMac.fingerprint, named: "Sam",
            personKey: sam.personKeyAfterRevoking(samMac.fingerprint))
        XCTAssertFalse(confirmation.message.contains("Apple ID"), confirmation.message)
        XCTAssertEqual(confirmation.message, PeopleAndDevicesConfirmation.revoke(
            person: samMac.fingerprint, named: "Sam").message,
            "exactly today's sentence")
    }
}
