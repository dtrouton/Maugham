import Foundation
import XCTest
@testable import MaughamCore

/// **The recognition decision** (your devices are you, plan 1 Task 5): may the
/// root's Mac admit a newly seen device without asking?
///
/// A wrong `.ownDevice`/`.knownPerson` is a stranger admitted silently, so
/// every silent row below has a negative twin that must `.ask`. Registries are
/// built in memory (the verified claims are a function of `devices` alone);
/// person keys come from `InMemoryPersonKeyStore`, never a real keychain.
final class TrustRecognitionTests: XCTestCase {

    private let rootFP = "root-denver"
    private let samFP = "sam-mac"
    private var denverKey: PersonKey!
    private var samKey: PersonKey!
    private var root: PersonRecord!
    private var sam: PersonRecord!

    override func setUpWithError() throws {
        try super.setUpWithError()
        denverKey = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver Trouton"))
        samKey = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Sam"))
        root = person(rootFP, label: "Denver", by: rootFP, key: nil)
        sam = person(samFP, label: "Sam", by: rootFP, key: nil)
    }

    // MARK: - Helpers

    private func person(
        _ fp: String, label: String, by admitter: String, key: PersonKey?,
        revoked: Bool = false
    ) -> PersonRecord {
        PersonRecord(
            person: fp, label: label, ownName: "\(label)'s machine",
            admittedAt: Date(timeIntervalSince1970: 10), admittedBy: admitter,
            revokedAt: revoked ? Date(timeIntervalSince1970: 20) : nil,
            revokedBy: revoked ? admitter : nil,
            personKey: key?.fingerprint)
    }

    private func linked(_ record: PersonRecord, _ key: PersonKey) -> PersonRecord {
        PersonRecord(
            person: record.person, label: record.label, ownName: record.ownName,
            admittedAt: record.admittedAt, admittedBy: record.admittedBy,
            revokedAt: record.revokedAt, revokedBy: record.revokedBy,
            personKey: key.fingerprint)
    }

    private func device(
        claimBy key: PersonKey?, name: String = "New iPhone", retired: Bool = false
    ) throws -> DeviceRecord {
        let fp = DeviceIdentity.softwareForTesting().fingerprint
        let claim = try key.map { try RegistryWriter.personClaim(forDevice: fp, signedBy: $0) }
        return DeviceRecord(
            device: fp, name: name, kind: .phone,
            actors: [DeviceActor.author.rawValue: fp],
            madeAt: Date(timeIntervalSince1970: 30),
            retiredAt: retired ? Date(timeIntervalSince1970: 40) : nil,
            personClaim: claim)
    }

    /// The caller's shape exactly: the claim is the registry's verified answer.
    private func decide(
        _ device: DeviceRecord, people: [PersonRecord],
        otherDevices: [DeviceRecord] = [], malformed: [MalformedRecord] = [],
        claims: [ClaimRecord] = [], thisRoot: String? = nil
    ) -> Recognition {
        let registry = Registry(
            devices: [device] + otherDevices, people: people, claims: claims,
            malformed: malformed)
        return Recognition.recognise(
            device: device, verifiedClaim: registry.verifiedPersonClaims[device.device],
            registry: registry, thisRoot: thisRoot ?? rootFP)
    }

    private func hint(
        _ person: String, _ device: String = "New iPhone", elsewhere: Bool = false
    ) -> Recognition {
        .ask(hint: ClaimHint(personName: person, deviceName: device, linkedElsewhere: elsewhere))
    }

    private func unreadablePerson(_ fp: String) -> MalformedRecord {
        MalformedRecord(
            url: URL(fileURLWithPath: "/book/x")
                .appendingPathComponent(RegistryDirectory.people.rawValue)
                .appendingPathComponent("\(fp).json"),
            reason: .signatureDoesNotVerify)
    }

    // MARK: - No claim / unknown key

    func test_noClaimAsksWithNoHint() throws {
        let d = try device(claimBy: nil)
        XCTAssertEqual(decide(d, people: [linked(root, denverKey)]), .ask(hint: nil))
    }

    /// Review Focus 2: a collaborator mints her own key named "Denver Trouton".
    /// It is linked to nobody, so it is a HINT, never an identity — even though
    /// the name matches the root's own person exactly.
    func test_aSelfGeneratedKeyNamingTheRootAsksAndNeverAdmitsAsTheRoot() throws {
        let impostor = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver Trouton"))
        let d = try device(claimBy: impostor)
        let rootNamedExactly = person(rootFP, label: "Denver Trouton", by: rootFP, key: denverKey)
        XCTAssertEqual(decide(d, people: [rootNamedExactly, sam]), hint("Denver Trouton"))
        // The converse: the root's REAL key, same name, is its own device.
        let mine = try device(claimBy: denverKey)
        XCTAssertEqual(decide(mine, people: [rootNamedExactly, sam]),
                       .ownDevice(root: rootNamedExactly))
    }

    func test_anUnknownKeyAsksWithTheClaimedNames() throws {
        let d = try device(claimBy: samKey, name: "Sam's iPhone")
        XCTAssertEqual(decide(d, people: [linked(root, denverKey), sam]),
                       hint("Sam", "Sam's iPhone"))
    }

    // MARK: - The claim must be the registry's verified one

    /// Review Focus 1 at this layer: Denver's claim copied onto a stranger's
    /// record does not verify for it, and a caller passing the RAW field is
    /// treated as having no claim.
    func test_aRawClaimThatIsNotTheRegistrysVerifiedOneIsNoClaim() throws {
        let denversPhone = try device(claimBy: denverKey)
        let strangerFP = DeviceIdentity.softwareForTesting().fingerprint
        let stranger = DeviceRecord(
            device: strangerFP, name: "Stranger", kind: .phone,
            actors: [DeviceActor.author.rawValue: strangerFP],
            madeAt: Date(timeIntervalSince1970: 30), personClaim: denversPhone.personClaim)
        let registry = Registry(devices: [stranger], people: [linked(root, denverKey)])
        XCTAssertNil(registry.verifiedPersonClaims[strangerFP])
        XCTAssertEqual(Recognition.recognise(
            device: stranger, verifiedClaim: stranger.personClaim,
            registry: registry, thisRoot: rootFP), .ask(hint: nil))
    }

    func test_aDeviceRecordThatIsNotTheRegistrysAsks() throws {
        let real = try device(claimBy: denverKey)
        let registry = Registry(devices: [real], people: [linked(root, denverKey)])
        let renamed = DeviceRecord(
            device: real.device, name: "Renamed", kind: real.kind, actors: real.actors,
            madeAt: real.madeAt, personClaim: real.personClaim)
        XCTAssertEqual(Recognition.recognise(
            device: renamed, verifiedClaim: registry.verifiedPersonClaims[real.device],
            registry: registry, thisRoot: rootFP), .ask(hint: nil))
        XCTAssertEqual(Recognition.recognise(
            device: real, verifiedClaim: registry.verifiedPersonClaims[real.device],
            registry: registry, thisRoot: rootFP), .ownDevice(root: linked(root, denverKey)))
    }

    // MARK: - Own device

    func test_theRootRecordHoldingTheKeyIsOwnDevice() throws {
        let r = linked(root, denverKey)
        XCTAssertEqual(decide(try device(claimBy: denverKey), people: [r, sam]), .ownDevice(root: r))
    }

    /// One person is a label: the key may sit on the root's phone record
    /// alone, under the root's label.
    func test_aRecordSharingTheRootsLabelHoldingTheKeyIsOwnDevice() throws {
        let phone = person("denver-phone", label: "Denver", by: rootFP, key: denverKey)
        XCTAssertEqual(decide(try device(claimBy: denverKey), people: [root, phone, sam]),
                       .ownDevice(root: root))
        // The converse: the same key on a record under ANOTHER label is not own.
        let other = person("denver-phone", label: "Dee", by: rootFP, key: denverKey)
        XCTAssertNotEqual(decide(try device(claimBy: denverKey), people: [root, other, sam]),
                          .ownDevice(root: root))
    }

    func test_onAMacThatIsNotTheBooksRootNothingIsSilent() throws {
        let r = linked(root, denverKey)
        let d = try device(claimBy: denverKey)
        XCTAssertEqual(decide(d, people: [r, sam], thisRoot: samFP), hint("Denver Trouton"))
        XCTAssertEqual(decide(d, people: [r, sam], thisRoot: "nobody"), hint("Denver Trouton"))
    }

    /// Review Focus 2's sharper form: a collaborator on a read-write share
    /// SELF-SIGNS a root record under the root's label and links her own key
    /// to it. Records another root signed are never evidence.
    func test_aForeignRootsRecordUnderTheRootsLabelIsLinkedElsewhere() throws {
        let eveKey = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver"))
        let eve = person("eve-root", label: "Denver", by: "eve-root", key: eveKey)
        XCTAssertEqual(decide(try device(claimBy: eveKey), people: [root, eve, sam]),
                       hint("Denver", elsewhere: true))
    }

    // MARK: - Known person

    func test_aKeyLinkedToOneOtherPersonIsThatPerson() throws {
        let s = linked(sam, samKey)
        XCTAssertEqual(decide(try device(claimBy: samKey), people: [root, s]), .knownPerson(s))
    }

    func test_aKnownPersonsRepresentativeIsTheLowestFingerprintHolder() throws {
        let mac = person("sam-b", label: "Sam", by: rootFP, key: samKey)
        let phone = person("sam-a", label: "Sam", by: rootFP, key: samKey)
        XCTAssertEqual(decide(try device(claimBy: samKey), people: [root, mac, phone]),
                       .knownPerson(phone))
        XCTAssertEqual(decide(try device(claimBy: samKey), people: [root, phone, mac]),
                       .knownPerson(phone))
    }

    func test_aKeyUnderTwoLabelsAsksLinkedElsewhere() throws {
        let s = linked(sam, samKey)
        let alex = person("alex", label: "Alex", by: rootFP, key: samKey)
        XCTAssertEqual(decide(try device(claimBy: samKey), people: [root, s, alex]),
                       hint("Sam", elsewhere: true))
    }

    func test_aKeyOnTheRootAndAnotherLabelAsksLinkedElsewhere() throws {
        let r = linked(root, denverKey)
        let s = linked(sam, denverKey)
        XCTAssertEqual(decide(try device(claimBy: denverKey), people: [r, s]),
                       hint("Denver Trouton", elsewhere: true))
    }

    func test_aKeyWhoseEveryHolderIsRevokedAsks() throws {
        let s = person(samFP, label: "Sam", by: rootFP, key: samKey, revoked: true)
        XCTAssertEqual(decide(try device(claimBy: samKey), people: [root, s]),
                       hint("Sam", elsewhere: true))
    }

    /// Revoking a device says the DEVICE is gone, not that the key is
    /// compromised: Denver's lost phone (same label, holds his key) revoked,
    /// and his new device is still his own.
    func test_aRevokedRecordUnderTheRootsLabelDoesNotBlockOwnDevice() throws {
        let lostPhone = person("denver-phone", label: "Denver", by: rootFP, key: denverKey,
                               revoked: true)
        XCTAssertEqual(decide(try device(claimBy: denverKey), people: [root, lostPhone, sam]),
                       .ownDevice(root: root))
    }

    /// A revoked record of Sam's label neither helps nor blocks: one standing
    /// holder is Sam, and the representative is never the revoked record.
    func test_aRevokedHolderBesideAStandingOneIsStillThatPerson() throws {
        let lost = person("sam-a", label: "Sam", by: rootFP, key: samKey, revoked: true)
        let standing = person("sam-b", label: "Sam", by: rootFP, key: samKey)
        XCTAssertEqual(decide(try device(claimBy: samKey), people: [root, lost, standing]),
                       .knownPerson(standing))
    }

    /// The only holder revoked, but Sam's label still stands on an unlinked
    /// record: Sam, represented by the STANDING record.
    func test_aRevokedHolderWithAStandingUnlinkedRecordOfTheLabelIsThatPerson() throws {
        let lost = person("sam-a", label: "Sam", by: rootFP, key: samKey, revoked: true)
        let phone = person("sam-b", label: "Sam", by: rootFP, key: nil)
        XCTAssertEqual(decide(try device(claimBy: samKey), people: [root, lost, phone]),
                       .knownPerson(phone))
    }

    func test_everyRecordOfTheLabelRevokedAsks() throws {
        let mac = person("sam-a", label: "Sam", by: rootFP, key: samKey, revoked: true)
        let phone = person("sam-b", label: "Sam", by: rootFP, key: nil, revoked: true)
        XCTAssertEqual(decide(try device(claimBy: samKey), people: [root, mac, phone]),
                       hint("Sam", elsewhere: true))
    }

    // MARK: - Adopted roots are this book's chain

    /// A record signed by a root THIS root adopted is in `TrustTable.myChain`,
    /// so it is evidence; the same record under a root nobody adopted is not.
    func test_aRecordUnderAnAdoptedRootCountsAndUnderAnUnadoptedOneDoesNot() throws {
        let other = person("other-root", label: "Denver", by: "other-root", key: nil)
        let samUnderOther = person(samFP, label: "Sam", by: "other-root", key: samKey)
        let adoption = ClaimRecord(
            newRoot: rootFP, adopted: ["other-root"], claimedAt: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(
            decide(try device(claimBy: samKey), people: [root, other, samUnderOther],
                   claims: [adoption]),
            .knownPerson(samUnderOther))
        XCTAssertEqual(
            decide(try device(claimBy: samKey), people: [root, other, samUnderOther]),
            hint("Sam", elsewhere: true))
        // A claim the OTHER root wrote adopting this one widens nothing here.
        let reverse = ClaimRecord(
            newRoot: "other-root", adopted: [rootFP], claimedAt: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(
            decide(try device(claimBy: samKey), people: [root, other, samUnderOther],
                   claims: [reverse]),
            hint("Sam", elsewhere: true))
    }

    func test_anUnnamedHolderIsNobodyToBeRecognisedAs() throws {
        let unnamed = person(samFP, label: "", by: rootFP, key: samKey)
        XCTAssertEqual(decide(try device(claimBy: samKey), people: [root, unnamed]), hint("Sam"))
    }

    // MARK: - Review Focus 3: the key says Sam, the claim says Denver

    func test_aKeyLinkedToSamWhoseClaimNamesTheRootAsks() throws {
        let samsKeyNamedDenver = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver"))
        let s = linked(sam, samsKeyNamedDenver)
        XCTAssertEqual(decide(try device(claimBy: samsKeyNamedDenver), people: [root, s]),
                       hint("Denver", elsewhere: true))
    }

    /// The root's label need not be the name its key carries: the root
    /// device's own verified claim names the person too.
    func test_aClaimNamingAnotherPersonsOwnClaimedNameAsks() throws {
        let rootDevice = try deviceRecord(fp: rootFP, claimBy: denverKey)
        let samsKeyNamedDenver = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver Trouton"))
        let s = linked(sam, samsKeyNamedDenver)
        XCTAssertEqual(
            decide(try device(claimBy: samsKeyNamedDenver), people: [root, s],
                   otherDevices: [rootDevice]),
            hint("Denver Trouton", elsewhere: true))
    }

    func test_theRootsKeyWhoseClaimNamesAnotherPersonAsks() throws {
        let denverKeyNamedSam = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Sam"))
        let r = linked(root, denverKeyNamedSam)
        XCTAssertEqual(decide(try device(claimBy: denverKeyNamedSam), people: [r, sam]),
                       hint("Sam", elsewhere: true))
        // Converse: nobody here is called Sam, so it is the root's own device.
        XCTAssertEqual(decide(try device(claimBy: denverKeyNamedSam), people: [r]),
                       .ownDevice(root: r))
    }

    // MARK: - Unreadable, already known, retired

    func test_anUnreadablePersonRecordMakesEveryAnswerAQuestion() throws {
        let s = linked(sam, samKey)
        let bad = [unreadablePerson("someone-else")]
        XCTAssertEqual(decide(try device(claimBy: samKey), people: [root, s], malformed: bad),
                       hint("Sam"))
        let r = linked(root, denverKey)
        XCTAssertEqual(decide(try device(claimBy: denverKey), people: [r, sam], malformed: bad),
                       hint("Denver Trouton"))
    }

    func test_aDeviceWithAPersonRecordIsNeverSilentlyAdmittedAgain() throws {
        let r = linked(root, denverKey)
        let d = try device(claimBy: denverKey)
        let revokedDevice = person(d.device, label: "Denver", by: rootFP, key: nil, revoked: true)
        XCTAssertEqual(decide(d, people: [r, revokedDevice]), hint("Denver Trouton"))
    }

    func test_aRetiredDeviceAsks() throws {
        let r = linked(root, denverKey)
        XCTAssertEqual(decide(try device(claimBy: denverKey, retired: true), people: [r]),
                       hint("Denver Trouton"))
    }

    private func deviceRecord(fp: String, claimBy key: PersonKey) throws -> DeviceRecord {
        DeviceRecord(
            device: fp, name: "Denver's Mac", kind: .mac,
            actors: [DeviceActor.author.rawValue: fp],
            madeAt: Date(timeIntervalSince1970: 1),
            personClaim: try RegistryWriter.personClaim(forDevice: fp, signedBy: key))
    }
}
