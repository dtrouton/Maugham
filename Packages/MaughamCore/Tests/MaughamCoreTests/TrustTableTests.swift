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

    /// **A foreign record cannot make one of my keys somebody else's PERSON**
    /// (fix round 1, Critical).
    ///
    /// A device record vouches for its own author key and nothing else: the
    /// reader checks `actors["author"] == device`, and the other three actor
    /// fingerprints are unsigned strings any record may list. So an admitted
    /// device can name one of MY actor keys among its own and — with my device
    /// record not yet written, or its fingerprint sorting first — win the
    /// key→device join. `verdict` was always safe, because it asks `mine`
    /// first; a permit lookup that did the bare join was not, and it would
    /// have handed Task 5's partition and Task 8's bootstrap gate somebody
    /// else's permit history to judge THIS device's own lines by.
    func test_aForeignRecordCannotMakeMyOwnKeySomebodyElsesPerson() {
        let liar = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [deviceRecord(
                liar, actors: [DeviceActor.translator.rawValue:
                                mine.assistant.fingerprint])],
            people: [rootRecord(root), admittedRecord(liar, under: root)],
            events: [permitEvent("a", subject: liar, by: root)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.timeline(forPerson: liar).current, .reviewer,
                       "the liar really is a reviewer — that is what makes this bite")
        XCTAssertEqual(table.verdict(forSealKey: mine.assistant.fingerprint), .mine)
        XCTAssertEqual(table.person(forSealKey: mine.assistant.fingerprint), root,
                       "my key is my person, whatever a record says")
        XCTAssertEqual(table.timeline(forSealKey: mine.assistant.fingerprint),
                       .bookAuthor,
                       "and so my own lines are judged under my own permit")
    }

    /// The verdict and the permit lookup cannot disagree about who a key is,
    /// because they are one resolution: every key this device holds answers
    /// `.mine` AND this device's own person, in the same book as the liar.
    func test_theVerdictAndTheLookupAgreeAboutEveryKeyIHold() {
        let liar = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [deviceRecord(liar, actors: Dictionary(
                uniqueKeysWithValues: mine.existingActors.map {
                    ($0 == .author ? "illustrator" : $0.rawValue, mine[$0].fingerprint)
                }))],
            people: [rootRecord(root), admittedRecord(liar, under: root)],
            events: [permitEvent("a", subject: liar, by: root)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        for actor in mine.existingActors {
            let key = mine[actor].fingerprint
            XCTAssertEqual(table.verdict(forSealKey: key), .mine, "\(actor)")
            XCTAssertEqual(table.person(forSealKey: key), root, "\(actor)")
            XCTAssertEqual(table.timeline(forSealKey: key), .bookAuthor, "\(actor)")
        }
    }

    // MARK: - A disputed actor key belongs to nobody, for good (fix round 3)

    /// A device record is signed once, by its own author key, and its
    /// `assistant`/`translator`/`maugham` fingerprints are unsigned strings any
    /// record may list. Two records claiming one key is therefore a real state
    /// with **no honest tie-break** — possession is unprovable from these
    /// records — and since P3 it would decide which person's permit history
    /// judges those lines.
    ///
    /// **Nobody owns it**: it resolves to itself, answers `.stranger(device:
    /// nil)` and is held PENDING. Nothing applied under a guessed permit,
    /// nothing set aside.
    func test_anActorKeyTwoRecordsClaimBelongsToNobody() {
        let honest = foreignKey()
        let liar = foreignKey()
        let contested = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [deviceRecord(honest, actors: [DeviceActor.translator.rawValue: contested]),
                      deviceRecord(liar, actors: [DeviceActor.translator.rawValue: contested])],
            people: [rootRecord(root), admittedRecord(honest, under: root),
                     admittedRecord(liar, under: root)],
            events: [permitEvent("a", subject: liar, by: root),
                     permitEvent("a", subject: honest, by: root,
                                 kind: .scopeChanged, role: Permit.authorRole,
                                 scope: Permit.piecesScope, pieces: ["d-chapter-4"])])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: contested), .stranger(device: nil))
        XCTAssertEqual(table.person(forSealKey: contested), contested,
                       "it stands for itself — neither claimant's person")
        XCTAssertEqual(table.timeline(forSealKey: contested), .bookAuthor,
                       "and borrows neither claimant's history")
        XCTAssertNotEqual(table.timeline(forSealKey: contested),
                          table.timeline(forPerson: liar))
        XCTAssertNotEqual(table.timeline(forSealKey: contested),
                          table.timeline(forPerson: honest))
        XCTAssertNil(table.actor(forSealKey: contested),
                     "and no record may say what a key it does not own is for")
        XCTAssertNil(registry.device(withActorFingerprint: contested))
        XCTAssertNil(registry.actorKeyOwners[contested])
        // The honest device's own keys are untouched by the argument.
        XCTAssertEqual(table.verdict(forSealKey: honest), .admitted(person: honest))
    }

    /// **The author slot is proven.** A device's author key IS its `device`
    /// fingerprint and is the key that signed the record, so a second record
    /// listing it as one of ITS actors claims nothing: the signature decides,
    /// whoever sorts first.
    func test_aRecordCannotClaimAnotherDevicesAuthorKey() {
        let honest = foreignKey()
        let liar = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [deviceRecord(honest),
                      deviceRecord(liar, actors: [DeviceActor.translator.rawValue: honest])],
            people: [rootRecord(root), admittedRecord(honest, under: root),
                     admittedRecord(liar, under: root)],
            events: [permitEvent("a", subject: liar, by: root)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.person(forSealKey: honest), honest)
        XCTAssertEqual(table.verdict(forSealKey: honest), .admitted(person: honest))
        XCTAssertEqual(table.timeline(forSealKey: honest), .bookAuthor,
                       "not the liar's reviewer history")
        XCTAssertEqual(table.actor(forSealKey: honest), .author)
        XCTAssertEqual(registry.device(withActorFingerprint: honest)?.device, honest)
        XCTAssertEqual(registry.actorKeyOwners[honest], honest)
    }

    /// **A dispute is never resolved by a revocation — in EITHER direction.**
    ///
    /// Two devices list one key; the root revokes one of them. It is tempting
    /// to read that as the argument being settled, and the temptation is a
    /// two-sided rule with only one side looked at (fix round 3; the round-2
    /// test this replaces, `test_aRevokedClaimantContestsNothing`, pinned the
    /// clause this round removes — it was never a P2 test).
    ///
    /// This is the reading's *good* direction — the liar revoked — and even
    /// here the key stays nobody's, because nothing in these records ever said
    /// which of the two was the liar.
    func test_revokingAClaimantDoesNotAwardTheDisputedKey() {
        let honest = foreignKey()
        let liar = foreignKey()
        let disputed = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [
                deviceRecord(honest, actors: [DeviceActor.assistant.rawValue: disputed]),
                deviceRecord(liar, actors: [DeviceActor.assistant.rawValue: disputed]),
            ],
            people: [rootRecord(root), admittedRecord(honest, under: root),
                     admittedRecord(liar, under: root,
                                    revokedAt: Date(timeIntervalSince1970: 50),
                                    revokedBy: root)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: disputed), .stranger(device: nil))
        XCTAssertEqual(table.person(forSealKey: disputed), disputed,
                       "still nobody's — not the surviving claimant's")
        XCTAssertNil(table.actor(forSealKey: disputed))
        XCTAssertNil(registry.actorKeyOwners[disputed])
        XCTAssertNil(registry.device(withActorFingerprint: disputed))
    }

    /// **And the direction that makes the amendment necessary.** Revoke the
    /// OWNER and the liar would be the sole standing claimant, so a line the
    /// revoked owner signs with that key would read `.admitted(person: liar)`
    /// instead of `.revoked(person: owner, …)`: a revoked person's writing
    /// APPLIED, under somebody else's name. The hostage costs availability;
    /// this costs integrity, which is why a disputed key is awarded to nobody
    /// whatever anybody's standing.
    func test_revokingTheOwnerDoesNotAwardTheDisputedKeyToTheClaimant() {
        let owner = foreignKey()
        let liar = foreignKey()
        let disputed = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [
                deviceRecord(owner, actors: [DeviceActor.assistant.rawValue: disputed]),
                deviceRecord(liar, actors: [DeviceActor.assistant.rawValue: disputed]),
            ],
            people: [rootRecord(root), admittedRecord(liar, under: root),
                     admittedRecord(owner, under: root,
                                    revokedAt: Date(timeIntervalSince1970: 50),
                                    revokedBy: root)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: disputed), .stranger(device: nil))
        XCTAssertNotEqual(table.verdict(forSealKey: disputed), .admitted(person: liar),
                          "never the claimant's — that is the integrity failure")
        XCTAssertNotEqual(table.verdict(forSealKey: disputed),
                          .revoked(person: owner, highestOpIdSeen: nil),
                          "and never the owner's either: nothing proved it was theirs")
        XCTAssertEqual(table.timeline(forSealKey: disputed), .bookAuthor)
        XCTAssertNil(registry.actorKeyOwners[disputed])
    }

    /// The same pair for RETIREMENT — the claimant retires.
    func test_retiringAClaimantDoesNotAwardTheDisputedKey() {
        let honest = foreignKey()
        let retiree = foreignKey()
        let disputed = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [
                deviceRecord(honest, actors: [DeviceActor.assistant.rawValue: disputed]),
                retiredDeviceRecord(
                    retiree, at: Date(timeIntervalSince1970: 60),
                    actors: [DeviceActor.assistant.rawValue: disputed]),
            ],
            people: [rootRecord(root), admittedRecord(honest, under: root),
                     admittedRecord(retiree, under: root)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: disputed), .stranger(device: nil))
        XCTAssertEqual(table.person(forSealKey: disputed), disputed)
        XCTAssertNil(registry.actorKeyOwners[disputed])
    }

    /// And the owner retires: the surviving claimant must not inherit the key,
    /// or a line the retired owner signed after it stopped would read
    /// `.admitted` rather than `.retired`.
    func test_retiringTheOwnerDoesNotAwardTheDisputedKeyToTheClaimant() {
        let owner = foreignKey()
        let liar = foreignKey()
        let disputed = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [
                retiredDeviceRecord(
                    owner, at: Date(timeIntervalSince1970: 60),
                    actors: [DeviceActor.assistant.rawValue: disputed]),
                deviceRecord(liar, actors: [DeviceActor.assistant.rawValue: disputed]),
            ],
            people: [rootRecord(root), admittedRecord(owner, under: root),
                     admittedRecord(liar, under: root)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.verdict(forSealKey: disputed), .stranger(device: nil))
        XCTAssertNotEqual(table.verdict(forSealKey: disputed), .admitted(person: liar))
        XCTAssertNil(registry.actorKeyOwners[disputed])
    }

    /// **A device keeps its own UNCONTESTED keys whatever its standing** — the
    /// half of the round-2 test that survives the amendment, and the half that
    /// keeps every P2 retirement verdict landing on the right device.
    func test_aRetiredDeviceKeepsItsOwnUncontestedKeys() {
        let retiree = foreignKey()
        let itsOwn = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [retiredDeviceRecord(
                retiree, at: Date(timeIntervalSince1970: 60),
                actors: [DeviceActor.translator.rawValue: itsOwn])],
            people: [rootRecord(root), admittedRecord(retiree, under: root)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.person(forSealKey: itsOwn), retiree)
        XCTAssertEqual(table.actor(forSealKey: itsOwn), .translator)
        XCTAssertEqual(table.verdict(forSealKey: itsOwn),
                       .retired(device: retiree,
                                retiredAt: Date(timeIntervalSince1970: 60)))
        XCTAssertEqual(registry.actorKeyOwners[itsOwn], retiree)
    }

    /// The revocation twin of the same half: a revoked device's sole claim on
    /// its own key stands, so what it wrote is `.revoked` in its OWN name
    /// rather than a stranger's. (P2's verdict, unchanged.)
    func test_aRevokedDeviceKeepsItsOwnUncontestedKeys() {
        let phone = foreignKey()
        let itsAssistant = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [deviceRecord(
                phone, actors: [DeviceActor.assistant.rawValue: itsAssistant])],
            people: [rootRecord(root),
                     admittedRecord(phone, under: root,
                                    revokedAt: Date(timeIntervalSince1970: 50),
                                    revokedBy: root, highestOpIdSeen: "op-9")])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        XCTAssertEqual(table.person(forSealKey: itsAssistant), phone)
        XCTAssertEqual(table.verdict(forSealKey: itsAssistant),
                       .revoked(person: phone, highestOpIdSeen: "op-9"))
        XCTAssertEqual(registry.actorKeyOwners[itsAssistant], phone)
    }

    /// An honest book has no contested key, so the rule never fires: every
    /// listed actor key is owned by the record that lists it, and the registry
    /// and the table say the same thing about all of them.
    func test_anHonestBooksKeysAreAllOwnedAndBothSpellingsAgree() {
        let phone = foreignKey()
        let itsAssistant = foreignKey()
        let root = mine.author.fingerprint
        let registry = Registry(
            devices: [deviceRecord(root, name: "Denver’s MacBook", kind: .mac),
                      deviceRecord(phone,
                                   actors: [DeviceActor.assistant.rawValue: itsAssistant])],
            people: [rootRecord(root), admittedRecord(phone, under: root)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        for key in [root, phone, itsAssistant] {
            XCTAssertEqual(registry.actorKeyOwners[key],
                           registry.device(withActorFingerprint: key)?.device,
                           "the registry agrees with itself about \(key)")
            XCTAssertEqual(table.person(forSealKey: key),
                           registry.device(withActorFingerprint: key)?.device,
                           "and the table agrees with the registry about \(key)")
        }
        XCTAssertEqual(table.actor(forSealKey: itsAssistant), .assistant)
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

    // MARK: - Which keys this book has heard of (P3b Task 4)

    /// **A key two verified device records both claim is nobody's, and the
    /// registry says so in one place.** `Registry.actorKeyOwners` already drops
    /// such a key; this is the question a surface asks about it — and it is
    /// *the register has an opinion and the opinion is nobody* rather than
    /// *nothing here has heard of this key*, which is the ordinary stranger.
    func test_aKeyTwoRecordsClaimIsContestedAndOneRecordsIsNot() {
        let sam = foreignKey()
        let liar = foreignKey()
        let shared = foreignKey()
        let hers = foreignKey()
        let registry = Registry(
            devices: [
                deviceRecord(sam, actors: [DeviceActor.assistant.rawValue: shared]),
                deviceRecord(liar, actors: [DeviceActor.assistant.rawValue: shared]),
                deviceRecord(hers, actors: [DeviceActor.translator.rawValue: hers + "x"]),
            ],
            people: [rootRecord(mine.author.fingerprint)])

        XCTAssertTrue(registry.isContestedActorKey(shared))
        XCTAssertFalse(registry.isContestedActorKey(hers + "x"),
                       "one claimant owns it, whatever its standing")
        XCTAssertFalse(registry.isContestedActorKey(sam),
                       "the author slot is proven, so it can never be contested")
        XCTAssertFalse(registry.isContestedActorKey(foreignKey()),
                       "a key no record mentions is not contested — it is "
                       + "unheard of, which is what a stranger is")
    }

    /// The table's own question and the registry's read the SAME set, so a
    /// sheet and a pane cannot disagree about which keys this book has heard
    /// of.
    func test_theTableAndTheRegistryNameTheSameKeys() {
        let sam = foreignKey()
        let itsAssistant = foreignKey()
        let registry = Registry(
            devices: [deviceRecord(
                sam, actors: [DeviceActor.assistant.rawValue: itsAssistant])],
            people: [rootRecord(mine.author.fingerprint)])

        let table = TrustTable.resolve(registry: registry, mine: mine, joinedRoot: nil)

        for key in registry.keysNamedByADeviceRecord {
            XCTAssertTrue(table.aDeviceRecordNames(key), key)
        }
        XCTAssertTrue(table.aDeviceRecordNames(itsAssistant))
        XCTAssertFalse(table.aDeviceRecordNames(foreignKey()))
    }

    // MARK: - Who started a piece (P3c plan 2, Option A)

    /// A book this device roots, with its own person record labelled
    /// "Denver", her OTHER device admitted under the same label, and Sam's
    /// device admitted under his — the three answers `starter(ofPieceStartedBy:)`
    /// has, plus the shut-out ones.
    private func starterTable(
        other: String, sam: String,
        otherRevoked: Bool = false, otherRetired: Bool = false
    ) -> TrustTable {
        let me = mine.author.fingerprint
        return TrustTable.resolve(
            registry: Registry(
                devices: [
                    deviceRecord(me, name: "Denver's MacBook", kind: .mac),
                    otherRetired
                        ? retiredDeviceRecord(
                            other, at: Date(timeIntervalSince1970: 40),
                            name: "Denver's iMac", kind: .mac)
                        : deviceRecord(other, name: "Denver's iMac", kind: .mac),
                    deviceRecord(sam, name: "Sam's Mac", kind: .mac),
                ],
                people: [
                    rootRecord(me),
                    admittedRecord(
                        other, under: me, label: "Denver", ownName: "Denver's iMac",
                        revokedAt: otherRevoked ? Date(timeIntervalSince1970: 50) : nil,
                        revokedBy: otherRevoked ? me : nil),
                    admittedRecord(sam, under: me, label: "Sam", ownName: "Sam's Mac"),
                ]),
            mine: mine, joinedRoot: nil)
    }

    private func authorId(_ fingerprint: String) -> String {
        DeviceIdentity.deviceId(actor: DeviceActor.author.rawValue, fingerprint: fingerprint)
    }

    /// Both directions of *whose device started this piece*: this Mac, her
    /// other Mac (the same writer by the root's label), and everybody else.
    func test_aPiecesStarterIsThisDeviceHerOtherDeviceOrSomebodyElse() {
        let (other, sam) = (foreignKey(), foreignKey())
        let table = starterTable(other: other, sam: sam)

        XCTAssertEqual(table.starter(ofPieceStartedBy: mine.author.deviceId), .thisDevice)
        XCTAssertEqual(table.starter(ofPieceStartedBy: authorId(other)),
                       .anotherOfThisWritersDevices, "her two Macs are both hers")
        XCTAssertEqual(table.starter(ofPieceStartedBy: authorId(sam)), .somebodyElse,
                       "a device of another person is not hers")
        XCTAssertEqual(table.starter(ofPieceStartedBy: mine.assistant.deviceId),
                       .somebodyElse, "a piece is started by a writer's hand, never MCP")
        XCTAssertEqual(table.starter(ofPieceStartedBy: authorId(foreignKey())),
                       .somebodyElse, "a device this register never heard of")
        XCTAssertEqual(table.starter(ofPieceStartedBy: "author-not-a-device"), .somebodyElse)

        XCTAssertTrue(table.isThisWriters(sealKey: mine.author.fingerprint))
        XCTAssertTrue(table.isThisWriters(sealKey: mine.assistant.fingerprint))
        XCTAssertTrue(table.isThisWriters(sealKey: other))
        XCTAssertFalse(table.isThisWriters(sealKey: sam))
    }

    /// **A device the root shut out, or that stopped, starts nothing of hers**
    /// — revoked and retired, each on its own.
    func test_aRevokedOrRetiredDeviceOfHersIsNotHerStarter() {
        let (other, sam) = (foreignKey(), foreignKey())
        let revoked = starterTable(other: other, sam: sam, otherRevoked: true)
        XCTAssertEqual(revoked.starter(ofPieceStartedBy: authorId(other)), .somebodyElse)
        let retired = starterTable(other: other, sam: sam, otherRetired: true)
        XCTAssertEqual(retired.starter(ofPieceStartedBy: authorId(other)), .somebodyElse)
    }

    /// **The other device must be the same WRITER, by the root's label** — the
    /// same machine under a different label is somebody else.
    func test_aDeviceUnderAnotherLabelIsSomebodyElsesStarter() {
        let me = mine.author.fingerprint
        let other = foreignKey()
        let table = TrustTable.resolve(
            registry: Registry(
                devices: [deviceRecord(other, name: "Denver's iMac", kind: .mac)],
                people: [
                    rootRecord(me),
                    admittedRecord(other, under: me, label: "Studio", ownName: "iMac"),
                ]),
            mine: mine, joinedRoot: nil)
        XCTAssertEqual(table.starter(ofPieceStartedBy: authorId(other)), .somebodyElse)
        XCTAssertFalse(table.isThisWriters(sealKey: other))
    }
}
