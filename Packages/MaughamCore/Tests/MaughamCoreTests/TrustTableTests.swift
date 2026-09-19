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

    /// A device record that says it has stopped writing.
    private func retiredDeviceRecord(
        _ fingerprint: String, at retiredAt: Date, actors extra: [String: String] = [:],
        name: String = "Denver's iPhone", kind: DeviceKind = .phone
    ) -> DeviceRecord {
        DeviceRecord(
            device: fingerprint, name: name, kind: kind,
            actors: extra.merging([DeviceActor.author.rawValue: fingerprint]) { a, _ in a },
            madeAt: Date(timeIntervalSince1970: 5), retiredAt: retiredAt)
    }

    private func claimRecord(
        _ newRoot: String, adopting adopted: [String], at seconds: TimeInterval = 30
    ) -> ClaimRecord {
        ClaimRecord(
            newRoot: newRoot, adopted: adopted,
            claimedAt: Date(timeIntervalSince1970: seconds))
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

    /// **A retired device is a fact about a DEVICE, and it is dated.** Spec §5:
    /// its past stays verified, its future seals are quarantined. So the
    /// verdict carries the moment rather than deciding on its own — the walk
    /// knows when each seal was made, and this table does not.
    func test_aRetiredDeviceCarriesTheMomentItRetired() {
        let phone = foreignKey()
        let registry = Registry(
            devices: [retiredDeviceRecord(phone, at: Date(timeIntervalSince1970: 99))],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(phone, under: mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(
            table.verdict(forSealKey: phone),
            .retired(device: phone, retiredAt: Date(timeIntervalSince1970: 99)))
    }

    /// Every actor key of a retired device is retired: the machine stopped, not
    /// one of its hands.
    func test_everyActorKeyOfARetiredDeviceIsRetired() {
        let phone = foreignKey()
        let assistant = foreignKey()
        let registry = Registry(
            devices: [retiredDeviceRecord(
                phone, at: Date(timeIntervalSince1970: 99),
                actors: [DeviceActor.assistant.rawValue: assistant])],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(phone, under: mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(
            table.verdict(forSealKey: assistant),
            .retired(device: phone, retiredAt: Date(timeIntervalSince1970: 99)))
    }

    /// **Revocation outranks retirement.** A device that retired itself and was
    /// then revoked is refused whatever the date on its seal says: retirement
    /// is the machine's own orderly stop, revocation is the root's refusal, and
    /// the second is not softened by the first.
    func test_aRevokedDeviceThatAlsoRetiredIsRevoked() {
        let phone = foreignKey()
        let registry = Registry(
            devices: [retiredDeviceRecord(phone, at: Date(timeIntervalSince1970: 50))],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(
                        phone, under: mine.author.fingerprint,
                        revokedAt: Date(timeIntervalSince1970: 99),
                        revokedBy: mine.author.fingerprint,
                        highestOpIdSeen: "01J-SEEN")])

        XCTAssertEqual(
            TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)
                .verdict(forSealKey: phone),
            .revoked(person: phone, highestOpIdSeen: "01J-SEEN"))
    }

    /// **This device's own keys are its own, retired or not.** A Mac that
    /// retired itself still reads its own history as its own word — the
    /// chained write's rewrite judges by `.mine`, and a table that answered
    /// otherwise would have this Mac set aside and truncate the file it wrote
    /// itself. The retirement is a fact every OTHER reader acts on.
    func test_thisDevicesOwnRetirementDoesNotUnmakeItsOwnWord() {
        let registry = Registry(
            devices: [retiredDeviceRecord(
                mine.author.fingerprint, at: Date(timeIntervalSince1970: 99),
                actors: [DeviceActor.assistant.rawValue: mine.assistant.fingerprint])],
            people: [rootRecord(mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: mine.author.fingerprint), .mine)
        XCTAssertEqual(table.verdict(forSealKey: mine.assistant.fingerprint), .mine)
    }

    /// A stranger that says it retired is still a stranger: retirement is
    /// something a device says about itself, and this Mac holds nothing of
    /// theirs either way until it admits them.
    func test_aRetiredStrangerIsStillAStranger() {
        let phone = foreignKey()
        let registry = Registry(
            devices: [retiredDeviceRecord(phone, at: Date(timeIntervalSince1970: 99))],
            people: [rootRecord(mine.author.fingerprint)])

        XCTAssertEqual(
            TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)
                .verdict(forSealKey: phone),
            .stranger(device: phone))
    }

    // MARK: - What a verdict does to a span, over time

    /// The whole of the dated rule, as the walk asks it: a seal made BEFORE the
    /// retirement settles its span exactly as an admitted device's does, and
    /// one made at or after it quarantines.
    func test_aRetiredDevicesSpanSettlesByWhenItsSealWasMade() {
        let phone = foreignKey()
        let verdict = TrustVerdict.retired(
            device: phone, retiredAt: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(
            verdict.settling(sealKey: phone, sealedAt: Date(timeIntervalSince1970: 99)),
            .verified)
        XCTAssertEqual(
            verdict.settling(sealKey: phone, sealedAt: Date(timeIntervalSince1970: 100)),
            .quarantined,
            "at the moment itself is after it: the device said it was done")
        XCTAssertEqual(
            verdict.settling(sealKey: phone, sealedAt: Date(timeIntervalSince1970: 101)),
            .quarantined)
        XCTAssertEqual(verdict.refusal, .afterRetirement(device: phone))
    }

    /// The highest opId the root had applied, asked of the table by the one
    /// reader that splits a revoked span in two.
    func test_theTableAnswersTheLineARevocationDrew() {
        let phone = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(phone)],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(
                        phone, under: mine.author.fingerprint,
                        revokedAt: Date(timeIntervalSince1970: 99),
                        revokedBy: mine.author.fingerprint,
                        highestOpIdSeen: "01J-SEEN")])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.highestOpIdSeen(forPerson: phone), "01J-SEEN")
        XCTAssertNil(table.highestOpIdSeen(forPerson: foreignKey()))
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

    // MARK: - Adoption (P2b, plan decision P2)

    /// The primitive: a claim written by MY root naming another root as adopted
    /// means that root's whole chain is admitted under mine. Its devices' actor
    /// keys stop being another claimant's and answer as people.
    func test_aRootMyRootAdoptedBringsItsWholeChainIntoMine() {
        let otherRoot = foreignKey()
        let theirPhone = foreignKey()
        let itsAssistant = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(
                theirPhone, actors: [DeviceActor.assistant.rawValue: itsAssistant])],
            people: [rootRecord(mine.author.fingerprint), rootRecord(otherRoot),
                     admittedRecord(theirPhone, under: otherRoot)],
            claims: [claimRecord(mine.author.fingerprint, adopting: [otherRoot])])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: otherRoot),
                       .admitted(person: otherRoot))
        XCTAssertEqual(table.verdict(forSealKey: theirPhone),
                       .admitted(person: theirPhone))
        XCTAssertEqual(table.verdict(forSealKey: itsAssistant),
                       .admitted(person: theirPhone),
                       "adopting a root admits every actor of every device on it")
        XCTAssertEqual(table.adoptedRoots, [otherRoot])
    }

    /// The asymmetry that makes adoption safe (B1): somebody adopting ME
    /// changes nothing here. A claim is written by its own root and vouches for
    /// nothing on this Mac, so until this Mac writes its own the other root is
    /// exactly what it was — a claimant.
    func test_aRootThatAdoptedMeWithoutMyAdoptingItIsStillAClaimant() {
        let otherRoot = foreignKey()
        let theirPhone = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(theirPhone)],
            people: [rootRecord(mine.author.fingerprint), rootRecord(otherRoot),
                     admittedRecord(theirPhone, under: otherRoot)],
            claims: [claimRecord(otherRoot, adopting: [mine.author.fingerprint])])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: otherRoot), .otherRoot(root: otherRoot))
        XCTAssertEqual(table.verdict(forSealKey: theirPhone), .otherRoot(root: otherRoot))
        XCTAssertEqual(table.adoptedRoots, [], "nothing widens on someone else's say-so")
    }

    /// Symmetric, once both have written: each Mac verifies the other's chain.
    /// This is the two-roots exit (plan decision P1), at the table.
    func test_mutualAdoptionHasEachRootVerifyingTheOthersChain() {
        let theirs = LocalIdentities.softwareForTesting()
        let myPhone = foreignKey()
        let theirPhone = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(myPhone), deviceRecord(theirPhone)],
            people: [rootRecord(mine.author.fingerprint), rootRecord(theirs.author.fingerprint),
                     admittedRecord(myPhone, under: mine.author.fingerprint),
                     admittedRecord(theirPhone, under: theirs.author.fingerprint)],
            claims: [claimRecord(mine.author.fingerprint,
                                 adopting: [theirs.author.fingerprint]),
                     claimRecord(theirs.author.fingerprint,
                                 adopting: [mine.author.fingerprint])])

        let ours = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)
        let theirTable = TrustTable.resolve(registry: registry, mine: theirs, joinedRoot: nil)

        XCTAssertEqual(ours.verdict(forSealKey: theirPhone), .admitted(person: theirPhone))
        XCTAssertEqual(theirTable.verdict(forSealKey: myPhone), .admitted(person: myPhone))
    }

    /// Adoption composes: a root I adopted may itself have adopted a third, and
    /// its chain is what I took in — the whole of it.
    func test_adoptionIsFollowedThroughTheRootsIAdopted() {
        let second = foreignKey()
        let third = foreignKey()
        let thirdPhone = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(thirdPhone)],
            people: [rootRecord(mine.author.fingerprint), rootRecord(second),
                     rootRecord(third), admittedRecord(thirdPhone, under: third)],
            claims: [claimRecord(mine.author.fingerprint, adopting: [second]),
                     claimRecord(second, adopting: [third])])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: thirdPhone), .admitted(person: thirdPhone))
        XCTAssertEqual(table.adoptedRoots, [second, third].sorted())
    }

    /// A claim by somebody who is not MY root is not my adoption, whoever it
    /// names. Read straight, this is the same rule as the one above stated from
    /// the other end: only my own root's claims widen my chain.
    func test_aClaimByAThirdRootDoesNotWidenMyChain() {
        let second = foreignKey()
        let third = foreignKey()
        let registry = Registry(
            people: [rootRecord(mine.author.fingerprint), rootRecord(second),
                     rootRecord(third)],
            claims: [claimRecord(second, adopting: [third])])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: third), .otherRoot(root: third))
        XCTAssertEqual(table.adoptedRoots, [])
    }

    /// Adoption admits a chain; it does not invent one. A fingerprint in an
    /// `adopted` list that is nobody's root here has no chain to take in, and
    /// the key stays exactly as unknown as it was.
    func test_adoptingAFingerprintThatIsNoRootAdmitsNobody() {
        let stranger = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(stranger)],
            people: [rootRecord(mine.author.fingerprint)],
            claims: [claimRecord(mine.author.fingerprint, adopting: [stranger])])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: stranger), .stranger(device: stranger))
    }

    /// Adoption is about whose history this Mac VERIFIES, and about nothing
    /// else: the root it is on, where that answer came from, and the roots that
    /// admitted it are all untouched (B1).
    func test_adoptionMovesNeitherMyRootNorTheJoinNorTheClaimants() {
        let otherRoot = foreignKey()
        let registry = Registry(
            people: [rootRecord(mine.author.fingerprint), rootRecord(otherRoot),
                     admittedRecord(mine.author.fingerprint, under: otherRoot, at: 6)],
            claims: [claimRecord(mine.author.fingerprint, adopting: [otherRoot])])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.myRoot, mine.author.fingerprint)
        XCTAssertEqual(table.ownRootRecord, mine.author.fingerprint)
        XCTAssertEqual(table.admittingRoots, [otherRoot],
                       "a root that named this device is still recorded as having done so")
    }

    /// A device this Mac has only JOINED adopts nothing of its own: the claims
    /// that count are the ones written by the root it is on, and here that root
    /// is somebody else's.
    func test_theRootIAmOnIsTheOneWhoseAdoptionsCount() {
        let mac = foreignKey()
        let third = foreignKey()
        let thirdPhone = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(mine.author.fingerprint), deviceRecord(thirdPhone)],
            people: [rootRecord(mac), rootRecord(third),
                     admittedRecord(mine.author.fingerprint, under: mac),
                     admittedRecord(thirdPhone, under: third)],
            claims: [claimRecord(mac, adopting: [third])])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: mac)

        XCTAssertEqual(table.myRoot, mac)
        XCTAssertEqual(table.verdict(forSealKey: thirdPhone), .admitted(person: thirdPhone))
    }

    /// With no chain at all there is nothing for an adoption to widen, and B3
    /// still answers everything.
    func test_aClaimChangesNothingForADeviceWithNoChain() {
        let one = foreignKey()
        let two = foreignKey()
        let registry = Registry(
            people: [rootRecord(one), rootRecord(two)],
            claims: [claimRecord(one, adopting: [two])])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertNil(table.myRoot)
        XCTAssertEqual(table.adoptedRoots, [])
        XCTAssertEqual(table.verdict(forSealKey: two), .noChain)
    }

    /// A person adopted this way is a person like any other — revocation still
    /// reads off their own record.
    func test_aRevokedPersonInAnAdoptedChainIsStillRevoked() {
        let otherRoot = foreignKey()
        let theirPhone = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(theirPhone)],
            people: [rootRecord(mine.author.fingerprint), rootRecord(otherRoot),
                     admittedRecord(
                        theirPhone, under: otherRoot,
                        revokedAt: Date(timeIntervalSince1970: 99),
                        revokedBy: otherRoot, highestOpIdSeen: "01J-SEEN")],
            claims: [claimRecord(mine.author.fingerprint, adopting: [otherRoot])])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: theirPhone),
                       .revoked(person: theirPhone, highestOpIdSeen: "01J-SEEN"))
    }

    // MARK: - The reader-side projection

    func test_aRootsAdoptionsAreItsOwnClaimsAndNobodyElses() {
        let one = foreignKey()
        let two = foreignKey()
        let three = foreignKey()
        let registry = Registry(
            claims: [claimRecord(one, adopting: [two, three]),
                     claimRecord(two, adopting: [one])])

        XCTAssertEqual(registry.adopted(by: one), [two, three])
        XCTAssertEqual(registry.adopted(by: two), [one])
        XCTAssertEqual(registry.adopted(by: three), [])
    }

    // MARK: - The permit (P3a Task 3)

    /// The table's second question. `verdict` says whose hand a line is;
    /// `timeline` says what that hand was allowed to write, and `actor` says
    /// which of the four writers on that machine it was.

    private func permitEvent(
        _ id: String, subject: String, by root: String,
        kind: PermitEvent.Kind = .roleChanged,
        role: String = Permit.reviewerRole,
        scope: String = Permit.bookScope,
        pieces: [String] = []
    ) -> PermitEvent {
        PermitEvent(
            event: "\(subject).\(id)", kind: kind, subject: subject,
            role: role, scope: scope, pieces: pieces,
            at: Date(timeIntervalSince1970: 40), by: root)
    }

    /// **Behaviour-neutral for every existing book.** No events anywhere means
    /// everybody — this device, the phone it admitted, a key nobody named — is
    /// an author of the whole book, which is what every P2 admission meant.
    func test_aBookWithNoEventsGivesEverybodyTheWholeBook() {
        let phone = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(mine.author.fingerprint), deviceRecord(phone)],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(phone, under: mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.timeline(forSealKey: phone), .bookAuthor)
        XCTAssertEqual(table.timeline(forSealKey: mine.author.fingerprint), .bookAuthor)
        XCTAssertEqual(table.timeline(forPerson: foreignKey()).current, .author(.book))
        XCTAssertFalse(table.timeline(forSealKey: phone).hasEvents)
    }

    /// A keyless book — no registry at all — is P1's behaviour exactly: this
    /// device's own keys are its own, and the permit is the whole book.
    func test_aKeylessTableGivesThisDeviceTheWholeBook() {
        let table = TrustResolution.keyless(mine: mine)

        XCTAssertEqual(table.verdict(forSealKey: mine.author.fingerprint), .mine)
        XCTAssertEqual(table.timeline(forSealKey: mine.author.fingerprint).current,
                       .author(.book))
        XCTAssertEqual(table.timeline(forSealKey: foreignKey()), .bookAuthor)
    }

    /// **The role check reads the timeline and never the record** (spec §3.4).
    /// A record re-signed in place forgets its own past, so a person record
    /// that says *reviewer* with no event behind it is still read as an author
    /// here — that state is the crash window the write order leaves (event,
    /// then record), and Task 7 detects and re-signs it rather than enforcing
    /// from a field with no history in it.
    func test_aRecordSayingReviewerWithNoEventBehindItIsStillAnAuthor() {
        let phone = foreignKey()
        let saysReviewer = PersonRecord(
            person: phone, label: "Sam", ownName: "Sam’s Mac",
            role: Permit.reviewerRole, scope: Permit.piecesScope, pieces: [],
            admittedAt: Date(timeIntervalSince1970: 20),
            admittedBy: mine.author.fingerprint)
        let registry = Registry(
            devices: [deviceRecord(phone)],
            people: [rootRecord(mine.author.fingerprint), saysReviewer])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: phone), .admitted(person: phone))
        XCTAssertEqual(table.timeline(forSealKey: phone), .bookAuthor,
                       "the history is what decides, and this person has none")
    }

    /// An admitted person's events reach the walk through the table they were
    /// resolved with — one registry read, one table, no second source.
    func test_anAdmittedPersonsEventsBecomeTheirTimeline() {
        let phone = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [deviceRecord(phone)],
            people: [rootRecord(root), admittedRecord(phone, under: root)],
            events: [permitEvent("b", subject: phone, by: root,
                                 kind: .scopeChanged, role: Permit.authorRole,
                                 scope: Permit.piecesScope, pieces: ["d-chapter-4"]),
                     permitEvent("a", subject: phone, by: root, kind: .admitted,
                                 role: Permit.authorRole)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)
        let timeline = table.timeline(forSealKey: phone)

        XCTAssertEqual(timeline.entries.map(\.event), [nil, "\(phone).a", "\(phone).b"])
        XCTAssertEqual(timeline.current, .author(.pieces(["d-chapter-4"])))
    }

    /// The timeline is looked up by PERSON, so every actor key of an admitted
    /// device answers the same history: a device is four writers and one
    /// person.
    func test_everyActorKeyOfOneDeviceAnswersThatPersonsTimeline() {
        let phone = foreignKey()
        let itsAssistant = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [deviceRecord(
                phone, actors: [DeviceActor.assistant.rawValue: itsAssistant])],
            people: [rootRecord(root), admittedRecord(phone, under: root)],
            events: [permitEvent("a", subject: phone, by: root)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.person(forSealKey: itsAssistant), phone)
        XCTAssertEqual(table.timeline(forSealKey: itsAssistant).current, .reviewer)
        XCTAssertEqual(table.timeline(forSealKey: itsAssistant),
                       table.timeline(forSealKey: phone))
    }

    /// **A root is an author of the whole book, unconditionally.** The reader
    /// refuses such an event's FILE; this is the other half, because `resolve`
    /// is pure and takes a registry from wherever the caller got one — a
    /// device must not be talked out of its own root's authority by a value
    /// somebody handed it.
    func test_anEventDemotingARootChangesNothingAboutTheRoot() {
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [deviceRecord(root, name: "Denver’s MacBook", kind: .mac)],
            people: [rootRecord(root)],
            events: [permitEvent("a", subject: root, by: root)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.timeline(forSealKey: root), .bookAuthor)
        XCTAssertEqual(table.timeline(forPerson: root).current, .author(.book))
    }

    // MARK: - Which of the four writers signed

    /// **The actor is recoverable on `.mine`.** The assistant row binds on the
    /// root's own Mac — *the assistant is never the author* is a rule about
    /// this device as much as anybody else's — so a verdict of `.mine` is not
    /// the end of the question.
    func test_everyOneOfMyOwnKeysNamesItsOwnActor() {
        let table = TrustTable.resolve(
            registry: Registry(people: [rootRecord(mine.author.fingerprint)]),
            mine: mine, joinedRoot: nil)

        for actor in mine.existingActors {
            XCTAssertEqual(table.verdict(forSealKey: mine[actor].fingerprint), .mine)
            XCTAssertEqual(table.actor(forSealKey: mine[actor].fingerprint), actor)
        }
        XCTAssertEqual(mine.existingActors, DeviceActor.allCases)
    }

    /// And on `.admitted`: an admitted device's record names its actors, and
    /// the key that signed says which row the line is judged on.
    func test_anAdmittedDevicesActorKeysNameTheirActors() {
        let phone = foreignKey()
        let itsAssistant = foreignKey()
        let itsTranslator = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(phone, actors: [
                DeviceActor.assistant.rawValue: itsAssistant,
                DeviceActor.translator.rawValue: itsTranslator,
            ])],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(phone, under: mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.actor(forSealKey: phone), .author)
        XCTAssertEqual(table.actor(forSealKey: itsAssistant), .assistant)
        XCTAssertEqual(table.actor(forSealKey: itsTranslator), .translator)
        XCTAssertNil(table.actor(forSealKey: foreignKey()),
                     "a key no record names an actor for cannot be narrowed")
    }

    /// An actor word a later build invented is left unmapped rather than
    /// guessed: the permit narrows BY the actor, and a guess would narrow it
    /// on the wrong row.
    func test_anActorWordThisBuildDoesNotKnowIsNotGuessed() {
        let phone = foreignKey()
        let itsFifth = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(phone, actors: ["illustrator": itsFifth])],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(phone, under: mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: itsFifth), .admitted(person: phone),
                       "it is still that device's key and still admitted")
        XCTAssertNil(table.actor(forSealKey: itsFifth))
    }

    /// A foreign device record naming one of MY keys as one of its actors must
    /// not decide what my key is for. What this device's own keys are for is
    /// something it knows first-hand.
    func test_aForeignRecordCannotRenameMyOwnActorKey() {
        let liar = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(
                liar, actors: [DeviceActor.translator.rawValue:
                                mine.assistant.fingerprint])],
            people: [rootRecord(mine.author.fingerprint),
                     admittedRecord(liar, under: mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.actor(forSealKey: mine.assistant.fingerprint), .assistant)
        XCTAssertEqual(table.verdict(forSealKey: mine.assistant.fingerprint), .mine)
    }
}
