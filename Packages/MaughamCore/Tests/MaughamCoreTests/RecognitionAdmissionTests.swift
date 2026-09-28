import Foundation
import XCTest
@testable import MaughamCore

/// **The root recognises** (your devices are you, plan 1 Task 6):
/// `RegistryPresence.admitRecognised` on real temp books, with software keys
/// for the devices and `InMemoryPersonKeyStore` person keys — never a real
/// keychain.
///
/// A silent admission of the wrong device is the risk, so every silent case
/// here has a twin that must leave the device to the sheet.
final class RecognitionAdmissionTests: XCTestCase {

    private var projectURL: URL!
    /// The root's Mac.
    private var mine: LocalIdentities!
    private var denverKey: PersonKey!
    private var samKey: PersonKey!
    private var cache: RegistryCache!
    private var memory: AdmissionMemory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = TestTemp.root.appendingPathComponent("recognise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        mine = .softwareForTesting()
        denverKey = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver Trouton"))
        samKey = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Sam"))
        cache = RegistryCache(
            fileURL: TestTemp.root.appendingPathComponent("cache-\(UUID().uuidString).json"),
            identity: mine.author.fingerprint)
        memory = AdmissionMemory(
            fileURL: TestTemp.root.appendingPathComponent("memory-\(UUID().uuidString).json"),
            identity: mine.author.fingerprint)
    }

    // MARK: - Helpers

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    private func claim(_ key: PersonKey?, for identities: LocalIdentities) throws -> PersonClaimIntent {
        guard let key else { return .keep }
        return .set(try RegistryWriter.personClaim(
            forDevice: identities.author.fingerprint, signedBy: key))
    }

    /// This Mac declares itself (with Denver's claim, unless told otherwise)
    /// and roots the empty book as "Denver".
    private func rootHere(claimBy key: PersonKey? = nil, noClaim: Bool = false) throws {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Denver's MacBook", kind: .mac,
            personClaim: try claim(noClaim ? nil : (key ?? denverKey), for: mine))
        try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: mine, writerName: "Denver")
    }

    @discardableResult
    private func declare(
        _ name: String, kind: DeviceKind = .phone, claimBy key: PersonKey?
    ) throws -> LocalIdentities {
        let device = LocalIdentities.softwareForTesting()
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: device, name: name, kind: kind,
            personClaim: try claim(key, for: device))
        return device
    }

    private func recognise(as identities: LocalIdentities? = nil) throws -> RegistryPresence.RecognitionPass {
        try RegistryPresence.admitRecognised(
            in: projectURL, identities: identities ?? mine, cache: cache)
    }

    private func events(about fingerprint: String) throws -> [PermitEvent] {
        try registry().events.filter { $0.subject == fingerprint }
    }

    private func currentPermit(of fingerprint: String) throws -> Permit {
        TrustTable.resolve(registry: try registry(), mine: mine, joinedRoot: nil)
            .timeline(forPerson: fingerprint).current
    }

    // MARK: - The root links its own key (PK-3)

    func test_theRootsOwnKeyIsLinkedToItsRootRecordAtOpen() throws {
        try rootHere()
        XCTAssertNil(try registry().person(mine.author.fingerprint)?.personKey,
                     "precondition: the root record starts unlinked")

        let pass = try recognise()

        XCTAssertEqual(try registry().person(mine.author.fingerprint)?.personKey,
                       denverKey.fingerprint)
        XCTAssertEqual(pass.linked.map(\.person), [mine.author.fingerprint])
        XCTAssertTrue(pass.admitted.isEmpty)
        // And a second pass is quiet.
        XCTAssertEqual(try recognise(), .nothing)
    }

    func test_aRootWithNoClaimLinksNothing() throws {
        try rootHere(noClaim: true)
        XCTAssertEqual(try recognise(), .nothing)
        XCTAssertNil(try registry().person(mine.author.fingerprint)?.personKey)
    }

    // MARK: - Own device (PK-2)

    func test_denversPhoneIsAdmittedSilentlyAsDenverAndRecordsWhy() throws {
        try rootHere()
        let phone = try declare("Denver's iPhone", claimBy: denverKey)

        let pass = try recognise()

        let record = try XCTUnwrap(try registry().person(phone.author.fingerprint))
        XCTAssertEqual(record.label, "Denver", "the ROOT's label")
        XCTAssertEqual(record.ownName, "Denver's iPhone")
        XCTAssertEqual(record.admittedBy, mine.author.fingerprint)
        XCTAssertEqual(pass.admitted.map(\.person), [phone.author.fingerprint])
        XCTAssertEqual(try currentPermit(of: phone.author.fingerprint), .bookAuthor,
                       "the root's own standing: author of the whole book")
        let arrivals = try events(about: phone.author.fingerprint)
        XCTAssertEqual(arrivals.map(\.kind), [.silentlyAdmitted])
        XCTAssertEqual(arrivals.first?.reason, PermitEvent.recognisedReason)
        XCTAssertTrue(arrivals.first?.isRecognition ?? false)
        XCTAssertEqual(record.personKey, denverKey.fingerprint,
                       "the record just written is linked in the same pass")
        XCTAssertTrue(try registry().malformed.isEmpty)
        // **Not remembered** (whole-branch review, Critical): the label memory
        // is only ever a SHEET decision. A recognised admission is not the
        // writer naming a device, and remembering it would let the memory
        // path admit it with the whole book into every other book this Mac
        // roots.
        XCTAssertNil(memory.label(for: phone.author.fingerprint))
    }

    /// The whole-branch review's scenario: Sam is a reviewer in book 1, her
    /// iPhone is recognised there; book 2, rooted by the same Mac, has never
    /// admitted Sam. Her iPhone must reach book 2's SHEET, never be let in by
    /// the memory path as an author of the whole book.
    func test_aRecognisedAdmissionInOneBookIsNotRememberedIntoAnother() throws {
        try rootHere()
        let samsMac = try declare("Sam's Mac", kind: .mac, claimBy: samKey)
        try RegistryAdmission.admit(
            device: samsMac.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
            in: projectURL, by: mine.author, cache: cache, memory: memory)
        try RegistryAdmission.changePermit(
            person: samsMac.author.fingerprint, role: Permit.reviewerRole,
            scope: Permit.bookScope, pieces: [], mark: .nothingApplied,
            unsigned: .nothingApplied,
            in: projectURL, by: mine.author, cache: cache)
        let samsPhone = try declare("Sam's iPhone", claimBy: samKey)
        let bookOne = try recognise()
        XCTAssertEqual(bookOne.admitted.map(\.person), [samsPhone.author.fingerprint],
                       "precondition: recognised in book 1")

        // Book 2: this Mac roots it; Sam has never been admitted there.
        let bookTwo = TestTemp.root.appendingPathComponent("recognise-two-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bookTwo, withIntermediateDirectories: true)
        try RegistryPresence.ensureDeviceRecord(
            in: bookTwo, identities: mine, name: "Denver's MacBook", kind: .mac,
            personClaim: try claim(denverKey, for: mine))
        try RegistryPresence.ensureRootIfEmpty(
            in: bookTwo, identities: mine, writerName: "Denver")
        try RegistryPresence.ensureDeviceRecord(
            in: bookTwo, identities: samsPhone, name: "Sam's iPhone", kind: .phone,
            personClaim: try claim(samKey, for: samsPhone))

        // The open's order: recognition, then the memory.
        let recognised = try RegistryPresence.admitRecognised(
            in: bookTwo, identities: mine, cache: cache)
        let remembered = try RegistryPresence.admitRemembered(
            in: bookTwo, identities: mine, cache: cache, memory: memory)

        XCTAssertTrue(recognised.admitted.isEmpty, "nobody in book 2 holds Sam's key")
        XCTAssertTrue(remembered.isEmpty, "the recognition in book 1 was never remembered")
        XCTAssertNil(try RegistryReader.load(projectURL: bookTwo)
            .person(samsPhone.author.fingerprint), "the sheet asks")
    }

    // MARK: - Known person (PK-2): the CURRENT permit, off the timeline

    func test_samsSecondDeviceJoinsAsSamWithSamsCurrentDemotedPermit() throws {
        try rootHere()
        let samsMac = try declare("Sam's Mac", kind: .mac, claimBy: samKey)
        try RegistryAdmission.admit(
            device: samsMac.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
            in: projectURL, by: mine.author, cache: cache, memory: memory)
        // Demote Sam first.
        try RegistryAdmission.changePermit(
            person: samsMac.author.fingerprint, role: Permit.reviewerRole,
            scope: Permit.bookScope, pieces: [], mark: .nothingApplied,
            unsigned: .nothingApplied,
            in: projectURL, by: mine.author, cache: cache)
        let samsPermit = try currentPermit(of: samsMac.author.fingerprint)
        XCTAssertNotEqual(samsPermit, .bookAuthor, "precondition: Sam is narrowed")
        let samsPhone = try declare("Sam's iPhone", claimBy: samKey)

        let pass = try recognise()

        let record = try XCTUnwrap(try registry().person(samsPhone.author.fingerprint))
        XCTAssertEqual(record.label, "Sam")
        XCTAssertEqual(pass.admitted.map(\.person), [samsPhone.author.fingerprint])
        XCTAssertEqual(try currentPermit(of: samsPhone.author.fingerprint), samsPermit,
                       "Sam's CURRENT permit, not the author default")
        let arrival = try XCTUnwrap(try events(about: samsPhone.author.fingerprint).first)
        XCTAssertTrue(arrival.isRecognition)
        XCTAssertNotNil(arrival.unsigned,
                        "a narrowing admission carries the book's photograph forward")
        XCTAssertEqual(Set(pass.linked.map(\.person)),
                       [mine.author.fingerprint, samsMac.author.fingerprint,
                        samsPhone.author.fingerprint])
    }

    // MARK: - Strangers still ask

    func test_aStrangerWithASelfGeneratedClaimIsNotAdmitted() throws {
        try rootHere()
        // Her own key, named exactly as the root's person.
        let impostorKey = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver Trouton"))
        let stranger = try declare("Denver's iPhone", claimBy: impostorKey)

        let pass = try recognise()

        XCTAssertNil(try registry().person(stranger.author.fingerprint))
        XCTAssertTrue(pass.admitted.isEmpty)
        XCTAssertTrue(try events(about: stranger.author.fingerprint).isEmpty)
    }

    func test_aDeviceWithNoClaimIsNotAdmitted() throws {
        try rootHere()
        let phone = try declare("Denver's iPhone", claimBy: nil)
        _ = try recognise()
        XCTAssertNil(try registry().person(phone.author.fingerprint))
    }

    // MARK: - Review Focus 5: a Mac that is not the root

    func test_aMacThatIsNotTheBooksRootAdmitsAndLinksNothing() throws {
        // Theirs is the root, with Denver's key on its record (the worst
        // case: a phone claiming that key would be the root's own device).
        let theirs = LocalIdentities.softwareForTesting()
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: theirs, name: "Their Mac", kind: .mac,
            personClaim: try claim(denverKey, for: theirs))
        try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: theirs, writerName: "Them")
        let theirCache = RegistryCache(
            fileURL: TestTemp.root.appendingPathComponent("their-\(UUID().uuidString).json"),
            identity: theirs.author.fingerprint)
        try RegistryAdmission.linkPersonKey(
            person: theirs.author.fingerprint, to: denverKey.fingerprint,
            in: projectURL, by: theirs.author, cache: theirCache)
        // This Mac, admitted by them, claiming Sam's key; a phone claiming
        // the root's key.
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "My Mac", kind: .mac,
            personClaim: try claim(samKey, for: mine))
        try RegistryAdmission.admit(
            device: mine.author.fingerprint, label: "Me", ownName: "My Mac",
            in: projectURL, by: theirs.author, cache: theirCache, memory: memory)
        let phone = try declare("Their iPhone", claimBy: denverKey)
        let before = try registry()

        let pass = try recognise(as: mine)

        XCTAssertEqual(pass, .nothing)
        let after = try registry()
        XCTAssertNil(after.person(phone.author.fingerprint), "admits nobody")
        XCTAssertNil(after.person(mine.author.fingerprint)?.personKey, "links nothing")
        XCTAssertEqual(after.events.count, before.events.count)
    }

    // MARK: - Linking an already-admitted device (PK-3)

    func test_anAlreadyAdmittedDevicesClaimLinksItsKey() throws {
        try rootHere()
        // Sam's Mac admitted by the sheet, before its build made a claim.
        let samsMac = try declare("Sam's Mac", kind: .mac, claimBy: nil)
        try RegistryAdmission.admit(
            device: samsMac.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
            in: projectURL, by: mine.author, cache: cache, memory: memory)
        // Its next open on the new build writes the claim.
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: samsMac, name: "Sam's Mac", kind: .mac,
            personClaim: try claim(samKey, for: samsMac))

        let pass = try recognise()

        XCTAssertEqual(try registry().person(samsMac.author.fingerprint)?.personKey,
                       samKey.fingerprint)
        XCTAssertTrue(pass.linked.map(\.person).contains(samsMac.author.fingerprint))
        XCTAssertTrue(pass.admitted.isEmpty, "linking admits nobody")
    }

    func test_aClaimWhoseKeyIsAnotherLabelsIsRefusedAndNotThrown() throws {
        try rootHere()
        // Sam's Mac claims DENVER's key (Denver signed into Sam's Mac, say).
        let samsMac = try declare("Sam's Mac", kind: .mac, claimBy: denverKey)
        try RegistryAdmission.admit(
            device: samsMac.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
            in: projectURL, by: mine.author, cache: cache, memory: memory)

        let pass = try recognise()

        XCTAssertNil(try registry().person(samsMac.author.fingerprint)?.personKey,
                     "the key is Denver's; the label rules refuse it for Sam")
        XCTAssertEqual(pass.refusedLinks.count, 1)
        XCTAssertEqual(try registry().person(mine.author.fingerprint)?.personKey,
                       denverKey.fingerprint)
    }

    func test_aKeyClaimedUnderTwoLabelsLinksToNeither() throws {
        try rootHere()
        let samsMac = try declare("Sam's Mac", kind: .mac, claimBy: samKey)
        let alexsMac = try declare("Alex's Mac", kind: .mac, claimBy: samKey)
        for (device, label) in [(samsMac, "Sam"), (alexsMac, "Alex")] {
            try RegistryAdmission.admit(
                device: device.author.fingerprint, label: label, ownName: "\(label)'s Mac",
                in: projectURL, by: mine.author, cache: cache, memory: memory)
        }

        let pass = try recognise()

        XCTAssertNil(try registry().person(samsMac.author.fingerprint)?.personKey)
        XCTAssertNil(try registry().person(alexsMac.author.fingerprint)?.personKey)
        XCTAssertEqual(pass.refusedLinks.count, 2)
    }

    func test_aRevokedDevicesClaimLinksNothing() throws {
        try rootHere()
        let samsMac = try declare("Sam's Mac", kind: .mac, claimBy: samKey)
        try RegistryAdmission.admit(
            device: samsMac.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
            in: projectURL, by: mine.author, cache: cache, memory: memory)
        try RegistryAdmission.revoke(
            person: samsMac.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: nil, cache: cache)

        _ = try recognise()

        XCTAssertNil(try registry().person(samsMac.author.fingerprint)?.personKey,
                     "a device this book let go is no evidence about a key")
    }

    // MARK: - Review Focus 4: an older build drops the claim

    func test_aClaimDroppedByAnOlderBuildIsRestoredAndNothingIsAdmittedTwice() throws {
        try rootHere()
        let phone = try declare("Denver's iPhone", claimBy: denverKey)
        _ = try recognise()
        XCTAssertEqual(try events(about: phone.author.fingerprint).count, 1)

        // A v0.41 build rewrites the phone's record: a fresh DeviceRecord with
        // no claim, signed by the phone itself.
        let old = try XCTUnwrap(try registry().devices.first {
            $0.device == phone.author.fingerprint })
        try RegistryWriter.write(
            DeviceRecord(device: old.device, name: "Denver's iPhone (renamed)",
                         kind: old.kind, actors: old.actors, madeAt: old.madeAt),
            signedBy: phone.author, in: projectURL)
        XCTAssertNil(try registry().verifiedPersonClaim(forDevice: phone.author.fingerprint))
        XCTAssertEqual(try recognise().admitted, [], "nothing to admit: it is already in")

        // Its next new-build open writes the claim back.
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: phone, name: "Denver's iPhone", kind: .phone,
            personClaim: try claim(denverKey, for: phone))
        XCTAssertNotNil(try registry().verifiedPersonClaim(forDevice: phone.author.fingerprint))

        let pass = try recognise()
        XCTAssertTrue(pass.admitted.isEmpty)
        XCTAssertEqual(try events(about: phone.author.fingerprint).count, 1,
                       "admitted once, ever")
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    // MARK: - Both silent paths on one open

    func test_aDeviceBothRememberedAndRecognisedIsAdmittedOnceByRecognition() throws {
        try rootHere()
        let phone = try declare("Denver's iPhone", claimBy: denverKey)
        memory.remember(phone.author.fingerprint, label: "Denver", ownName: "Denver's iPhone")

        // The order the open and the refresh use (C1b): recognition first.
        let pass = try recognise()
        let remembered = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: cache, memory: memory)

        XCTAssertEqual(pass.admitted.map(\.person), [phone.author.fingerprint])
        XCTAssertTrue(remembered.isEmpty)
        let arrivals = try events(about: phone.author.fingerprint)
        XCTAssertEqual(arrivals.count, 1, "one admission, one event")
        XCTAssertTrue(arrivals[0].isRecognition)
    }

    // MARK: - C1b: the memory path never hands a narrowed person the whole book

    /// Sam's Mac is in the book; `sam` is its fingerprint.
    private func admitSamsMac(narrowed: Bool) throws -> LocalIdentities {
        let samsMac = try declare("Sam's Mac", kind: .mac, claimBy: nil)
        try RegistryAdmission.admit(
            device: samsMac.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
            in: projectURL, by: mine.author, cache: cache, memory: memory)
        if narrowed {
            try RegistryAdmission.changePermit(
                person: samsMac.author.fingerprint, role: Permit.reviewerRole,
                scope: Permit.bookScope, pieces: [], mark: .nothingApplied,
                unsigned: .nothingApplied,
                in: projectURL, by: mine.author, cache: cache)
        }
        return samsMac
    }

    func test_aRememberedLabelOfANarrowedPersonIsLeftToTheSheet() throws {
        try rootHere()
        _ = try admitSamsMac(narrowed: true)
        let samsPhone = try declare("Sam's iPhone", claimBy: nil)
        memory.remember(samsPhone.author.fingerprint, label: "Sam", ownName: "Sam's iPhone")

        let admitted = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: cache, memory: memory)

        XCTAssertTrue(admitted.isEmpty)
        XCTAssertNil(try registry().person(samsPhone.author.fingerprint),
                     "never the whole book for a narrowed Sam: the sheet asks")
    }

    func test_aRememberedLabelOfAnUnnarrowedPersonIsStillSilent() throws {
        try rootHere()
        _ = try admitSamsMac(narrowed: false)
        let samsPhone = try declare("Sam's iPhone", claimBy: nil)
        memory.remember(samsPhone.author.fingerprint, label: "Sam", ownName: "Sam's iPhone")
        let newcomer = try declare("Kit's iPhone", claimBy: nil)
        memory.remember(newcomer.author.fingerprint, label: "Kit", ownName: "Kit's iPhone")

        let admitted = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: cache, memory: memory)

        XCTAssertEqual(Set(admitted.map(\.person)),
                       [samsPhone.author.fingerprint, newcomer.author.fingerprint],
                       "an unnarrowed person, and a label nobody here holds, are as today")
    }

    // MARK: - C2: Forget is durable

    func test_aForgottenKeyIsNotRelinkedAndItsNextDeviceIsAsked() throws {
        try rootHere()
        let phone = try declare("Denver's iPhone", claimBy: denverKey)
        _ = try recognise()
        XCTAssertEqual(try registry().person(mine.author.fingerprint)?.personKey,
                       denverKey.fingerprint)

        try RegistryAdmission.forgetPersonKey(
            person: mine.author.fingerprint, in: projectURL, by: mine.author, cache: cache)
        let root = try XCTUnwrap(try registry().person(mine.author.fingerprint))
        XCTAssertNil(root.personKey)
        XCTAssertEqual(root.forgottenPersonKeys, [denverKey.fingerprint])
        XCTAssertEqual(try registry().person(phone.author.fingerprint)?.forgottenPersonKeys,
                       [denverKey.fingerprint], "label-wide, in the same re-sign")

        // The next open: both admitted devices still claim the key.
        let pass = try recognise()
        XCTAssertTrue(pass.linked.isEmpty, "not re-linked")
        XCTAssertNil(try registry().person(mine.author.fingerprint)?.personKey)

        let next = try declare("Denver's iPad", claimBy: denverKey)
        _ = try recognise()
        XCTAssertNil(try registry().person(next.author.fingerprint),
                     "a forgotten key is unknown: the next device goes to the sheet")
    }

    func test_linkingAForgottenKeyIsRefusedAndAReadmissionKeepsTheForget() throws {
        try rootHere()
        _ = try recognise()
        try RegistryAdmission.forgetPersonKey(
            person: mine.author.fingerprint, in: projectURL, by: mine.author, cache: cache)

        XCTAssertThrowsError(try RegistryAdmission.linkPersonKey(
            person: mine.author.fingerprint, to: denverKey.fingerprint,
            in: projectURL, by: mine.author, cache: cache)) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .personKeyForgotten(person: mine.author.fingerprint))
        }
        // A different key is still linkable.
        try RegistryAdmission.linkPersonKey(
            person: mine.author.fingerprint, to: samKey.fingerprint,
            in: projectURL, by: mine.author, cache: cache)

        // Sam's record, forgotten, then re-admitted under another label.
        let samsMac = try declare("Sam's Mac", kind: .mac, claimBy: nil)
        try RegistryAdmission.admit(
            device: samsMac.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
            in: projectURL, by: mine.author, cache: cache, memory: memory)
        try RegistryAdmission.linkPersonKey(
            person: samsMac.author.fingerprint, to: String(repeating: "a", count: 64),
            in: projectURL, by: mine.author, cache: cache)
        try RegistryAdmission.forgetPersonKey(
            person: samsMac.author.fingerprint, in: projectURL, by: mine.author, cache: cache)
        try RegistryAdmission.admit(
            device: samsMac.author.fingerprint, label: "Samantha", ownName: "Sam's Mac",
            in: projectURL, by: mine.author, cache: cache, memory: memory)
        XCTAssertEqual(try registry().person(samsMac.author.fingerprint)?.forgottenPersonKeys,
                       [String(repeating: "a", count: 64)],
                       "a Forget is about the key and survives a relabel")
    }

    func test_aRecordThatForgotNothingCarriesNoForgottenField() throws {
        try rootHere()
        let url = RegistryWriter.url(.people, fingerprint: mine.author.fingerprint, in: projectURL)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("forgottenPersonKeys"))
    }

    // MARK: - Fix round: only THIS root's chain says anything about a key

    /// A share participant's self-signed root record, labelled as the root's
    /// person, carrying whatever key facts it likes.
    private func plantForeignRoot(
        label: String = "Denver", personKey: String? = nil, forgotten: [String]? = nil
    ) throws {
        let foreign = LocalIdentities.softwareForTesting()
        try RegistryWriter.write(
            PersonRecord(
                person: foreign.author.fingerprint, label: label, ownName: "Mallory's Mac",
                admittedAt: Date(timeIntervalSince1970: 1),
                admittedBy: foreign.author.fingerprint,
                personKey: personKey, forgottenPersonKeys: forgotten),
            signedBy: foreign.author, in: projectURL)
        XCTAssertNotNil(try registry().person(foreign.author.fingerprint),
                        "precondition: the planted root verifies")
    }

    func test_aForeignRootForgettingTheRootsKeyChangesNothing() throws {
        try rootHere()
        try plantForeignRoot(forgotten: [denverKey.fingerprint])

        _ = try recognise()
        XCTAssertEqual(try registry().person(mine.author.fingerprint)?.personKey,
                       denverKey.fingerprint, "the root still links its own key")
        let phone = try declare("Denver's iPhone", claimBy: denverKey)
        let pass = try recognise()
        XCTAssertEqual(pass.admitted.map(\.person), [phone.author.fingerprint],
                       "and its next device is its own")
    }

    func test_aForeignRootHoldingTheRootsKeyChangesNothing() throws {
        try rootHere()
        // Under ANOTHER label, so the label rule cannot excuse it: only the
        // chain rule can.
        try plantForeignRoot(label: "Mallory", personKey: denverKey.fingerprint)

        _ = try recognise()
        XCTAssertEqual(try registry().person(mine.author.fingerprint)?.personKey,
                       denverKey.fingerprint, "the link is not refused as held elsewhere")
        let phone = try declare("Denver's iPhone", claimBy: denverKey)
        let pass = try recognise()
        XCTAssertEqual(pass.admitted.map(\.person), [phone.author.fingerprint])
        XCTAssertEqual(try registry().person(phone.author.fingerprint)?.label, "Denver")
    }

    func test_aForeignRootNamedAfterTheClaimChangesNothing() throws {
        try rootHere()
        _ = try recognise()
        // The claim's own name ("Denver Trouton") as a foreign root's label:
        // under a folder-wide name check this made the root's own device ask.
        try plantForeignRoot(label: "Denver Trouton")
        let phone = try declare("Denver's iPhone", claimBy: denverKey)

        let pass = try recognise()

        XCTAssertEqual(pass.admitted.map(\.person), [phone.author.fingerprint])
    }

    // MARK: - Fix round: a declined recognition never falls through

    /// Sam demoted by an event with NO photograph — the shape a narrowing
    /// written before P3b's snapshot takes — or, with `role`, to a word this
    /// build cannot read.
    private func samNarrowedWithNoPhotograph(role: String = Permit.reviewerRole) throws -> LocalIdentities {
        let samsMac = try declare("Sam's Mac", kind: .mac, claimBy: samKey)
        try RegistryAdmission.admit(
            device: samsMac.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
            in: projectURL, by: mine.author, cache: cache, memory: memory)
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: samsMac.author.fingerprint),
                kind: .roleChanged, subject: samsMac.author.fingerprint,
                role: role, at: Date(), by: mine.author.fingerprint),
            signedBy: mine.author, in: projectURL)
        XCTAssertNotEqual(try currentPermit(of: samsMac.author.fingerprint), .bookAuthor)
        return samsMac
    }

    /// **The review's "no photograph" case is not a decline, and that is the
    /// sheet's answer too.** A narrowed book whose governing event carries no
    /// `unsigned` reads as an EMPTY photograph (`PermitEvent.unsigned`'s doc,
    /// `UnsignedSnapshot.governing`), so `table.unsignedSnapshot` is non-nil
    /// and the recognised admission carries that governing mark forward —
    /// exactly what `DocumentStore.sweptUnsignedSnapshot` hands the sheet's
    /// Admit for the same book (Ruling Q). The nil-photograph decline is a
    /// defensive arm no narrowed book reaches.
    func test_aNarrowedBookWithNoPhotographCarriesTheGoverningEmptyOneForward() throws {
        try rootHere()
        _ = try samNarrowedWithNoPhotograph()
        _ = try recognise()   // links Sam's key onto Sam's record
        let samsPhone = try declare("Sam's iPhone", claimBy: samKey)

        let pass = try recognise()

        XCTAssertEqual(pass.admitted.map(\.person), [samsPhone.author.fingerprint])
        let arrival = try XCTUnwrap(try events(about: samsPhone.author.fingerprint).first)
        XCTAssertEqual(arrival.unsigned, [:], "the governing photograph, empty, carried forward")
        XCTAssertEqual(try currentPermit(of: samsPhone.author.fingerprint),
                       try currentPermit(of: try XCTUnwrap(try registry().people
                           .first { $0.label == "Sam" && $0.ownName == "Sam's Mac" }).person))
    }

    /// A permit this build cannot read is DECLINED: no record, and the sheet.
    func test_aPermitThisBuildCannotReadIsDeclined() throws {
        try rootHere()
        _ = try samNarrowedWithNoPhotograph(role: "editor-from-the-future")
        _ = try recognise()
        let samsPhone = try declare("Sam's iPhone", claimBy: samKey)

        let pass = try recognise()

        XCTAssertTrue(pass.admitted.isEmpty)
        XCTAssertEqual(pass.declined.count, 1)
        XCTAssertNil(try registry().person(samsPhone.author.fingerprint))
    }

    func test_aDeclinedRecognitionIsNotLetInByTheMemoryPath() throws {
        try rootHere()
        _ = try samNarrowedWithNoPhotograph(role: "editor-from-the-future")
        _ = try recognise()
        let samsPhone = try declare("Sam's iPhone", claimBy: samKey)
        // Remembered under a label nobody here holds, so C1b's label rule
        // does not catch it: only the recognition rule can.
        memory.remember(samsPhone.author.fingerprint, label: "Sam P", ownName: "Sam's iPhone")

        XCTAssertEqual(try recognise().declined.count, 1, "precondition: declined")
        let remembered = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: cache, memory: memory)

        XCTAssertTrue(remembered.isEmpty, "never the whole book for a declined device")
        XCTAssertNil(try registry().person(samsPhone.author.fingerprint))
    }

    // MARK: - History (PK-4)

    func test_historyDrawsARecognitionInTheWritersWords() throws {
        try rootHere()
        let phone = try declare("Denver's iPhone", claimBy: denverKey)
        let samsMac = try declare("Sam's Mac", kind: .mac, claimBy: samKey)
        try RegistryAdmission.admit(
            device: samsMac.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
            in: projectURL, by: mine.author, cache: cache, memory: memory)
        _ = try recognise()
        let samsPhone = try declare("Sam's iPhone", claimBy: samKey)
        _ = try recognise()

        let events = TrustEvents.derive(
            registry: try registry(), cache: cache, mine: mine, for: projectURL)
        let labels = Dictionary(
            try registry().people.map { ($0.person, $0.label) }, uniquingKeysWith: { a, _ in a })
        let denversRow = try XCTUnwrap(events.first { $0.subject == phone.author.fingerprint })
        XCTAssertEqual(denversRow.kind, .recognised)
        XCTAssertEqual(TrustEventSentence.sentence(for: denversRow, labels: labels),
                       "Denver's iPhone joined as you \u{2014} recognised by your Apple ID.")
        let samsRow = try XCTUnwrap(events.first { $0.subject == samsPhone.author.fingerprint })
        XCTAssertEqual(samsRow.kind, .recognised)
        XCTAssertEqual(TrustEventSentence.sentence(for: samsRow, labels: labels),
                       "Sam's iPhone joined as Sam \u{2014} recognised by their Apple ID.")
        // Sam's own sheet admission is still an ordinary admission.
        let samsMacRow = try XCTUnwrap(events.first { $0.subject == samsMac.author.fingerprint })
        XCTAssertEqual(samsMacRow.kind, .admitted)
    }

    func test_aRecognisedEventsBytesAreReadableAndTheReasonIsOmittedElsewhere() throws {
        try rootHere()
        let phone = try declare("Denver's iPhone", claimBy: denverKey)
        memory.remember(phone.author.fingerprint, label: "Denver", ownName: "Denver's iPhone")
        _ = try RegistryPresence.admitRemembered(
            in: projectURL, identities: mine, cache: cache, memory: memory)
        let remembered = try XCTUnwrap(try events(about: phone.author.fingerprint).first)
        let url = RegistryWriter.url(.events, fingerprint: remembered.event, in: projectURL)
        let bytes = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(bytes.contains("\"reason\""),
                       "a memory admission's event is byte-for-byte what it was")
    }
}
