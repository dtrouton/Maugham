// MaughamTests/AdmissionClaimHintTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **What the admission sheet says about a device's own claim** (your devices
/// are you, plan 1 Task 7): the label it starts with, and the hint lines.
///
/// A device that is NOT recognised still reaches the sheet; this is what the
/// sheet makes of the claim it carries. Every value is decided with no window
/// (tripwire 33). Registries are built in memory — the verified claims are a
/// function of `devices` alone — and person keys come from
/// `InMemoryPersonKeyStore`, never a real keychain.
final class AdmissionClaimHintTests: XCTestCase {

    private var rootMac: DeviceIdentity!
    private var denverKey: PersonKey!
    private var samKey: PersonKey!
    private var ruizKey: PersonKey!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootMac = .softwareForTesting()
        denverKey = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver"))
        samKey = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Sam"))
        ruizKey = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Sam Ruiz"))
    }

    // MARK: - Fixtures

    private var root: String { rootMac.fingerprint }

    private func person(
        _ fingerprint: String, label: String, key: PersonKey? = nil,
        admittedBy: String? = nil, revoked: Bool = false
    ) -> PersonRecord {
        PersonRecord(
            person: fingerprint, label: label, ownName: "\(label)'s machine",
            admittedAt: Date(timeIntervalSince1970: 10),
            admittedBy: admittedBy ?? root,
            revokedAt: revoked ? Date(timeIntervalSince1970: 20) : nil,
            revokedBy: revoked ? root : nil,
            personKey: key?.fingerprint)
    }

    /// A newly seen device, its claim signed by `key` where there is one.
    private func device(
        name: String, claimBy key: PersonKey?
    ) throws -> DeviceRecord {
        let fp = DeviceIdentity.softwareForTesting().fingerprint
        let claim = try key.map { try RegistryWriter.personClaim(forDevice: fp, signedBy: $0) }
        return DeviceRecord(
            device: fp, name: name, kind: .phone,
            actors: [DeviceActor.author.rawValue: fp],
            madeAt: Date(timeIntervalSince1970: 30), personClaim: claim)
    }

    /// The root's own record, carrying Denver's key unless told otherwise.
    private func rootRecord(key: PersonKey?? = .none) -> PersonRecord {
        let resolved: PersonKey? = key ?? denverKey
        return person(root, label: "Denver", key: resolved, admittedBy: root)
    }

    private func request(
        for arrival: DeviceRecord, people: [PersonRecord],
        malformed: [MalformedRecord] = [],
        memory: [String: AdmissionMemory.Label] = [:]
    ) throws -> AdmissionRequest {
        let registry = Registry(
            devices: [arrival], people: people, malformed: malformed)
        let requests = AdmissionDecision.requests(
            pending: [:], registry: registry, memory: memory,
            myRoot: AdmissionDecision.askingRoot(in: registry, thisDevice: root),
            thisDevice: root)
        return try XCTUnwrap(requests.first { $0.fingerprint == arrival.device })
    }

    private func unreadablePerson(_ fp: String) -> MalformedRecord {
        MalformedRecord(
            url: URL(fileURLWithPath: "/book/x")
                .appendingPathComponent(RegistryDirectory.people.rawValue)
                .appendingPathComponent("\(fp).json"),
            reason: .signatureDoesNotVerify)
    }

    // MARK: - Behaviour-neutral with no claim

    func test_aDeviceWithNoClaimIsAskedAboutExactlyAsBefore() throws {
        let arrival = try device(name: "Kit’s iPad", claimBy: nil)

        let asked = try request(for: arrival, people: [rootRecord()])

        XCTAssertNil(asked.hint, "no claim, no hint")
        XCTAssertEqual(asked.proposedLabel, "Kit’s iPad", "today's proposal")
        XCTAssertEqual(AdmissionSheet.hintLines(for: asked), [])
    }

    // MARK: - The first-time collaborator

    /// Sam's first device in this book: a key nobody here holds, a name no
    /// label here has. The field starts at the name her own key carries.
    func test_aFirstTimeCollaboratorIsProposedUnderTheNameHerClaimCarries() throws {
        let arrival = try device(name: "Sam’s MacBook Air", claimBy: ruizKey)

        let asked = try request(for: arrival, people: [rootRecord()])

        XCTAssertEqual(asked.hint, ClaimHint(
            personName: "Sam Ruiz", deviceName: "Sam’s MacBook Air",
            linkedElsewhere: false))
        XCTAssertEqual(asked.proposedLabel, "Sam Ruiz")
        XCTAssertNil(asked.sharesItsNameWith)
        XCTAssertEqual(AdmissionDecision.outcome(for: asked, typedLabel: asked.proposedLabel),
                       .admit(label: "Sam Ruiz"), "a new person, never a merge")
        XCTAssertEqual(AdmissionSheet.hintLines(for: asked), [
            "It calls itself Sam’s MacBook Air, belonging to Sam Ruiz.",
            AdmissionSheet.claimAttribution,
        ])
    }

    // MARK: - The pre-fill, both directions

    /// **A claimed name that is a label here under a DIFFERENT key is not
    /// proposed** — pre-filling it would be one press of Admit merging a
    /// stranger into that person (F1). Today's proposal stands.
    func test_aClaimedNameCollidingWithALabelUnderADifferentKeyIsNotProposed() throws {
        let impostor = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver"))
        let arrival = try device(name: "iPhone", claimBy: impostor)

        let asked = try request(for: arrival, people: [rootRecord()])

        XCTAssertEqual(asked.proposedLabel, "iPhone", "today's proposal: its own name")
        XCTAssertNotEqual(
            AdmissionDecision.outcome(for: asked, typedLabel: asked.proposedLabel),
            .mergeUnder(label: "Denver"))
    }

    /// A label with NO linked key is "under a different key" too: absence is
    /// not a match, so a claim naming a person who has no key here proves
    /// nothing about being them.
    func test_aClaimedNameCollidingWithALabelThatHasNoKeyIsNotProposed() throws {
        let arrival = try device(name: "Denver", claimBy: denverKey)

        let asked = try request(for: arrival, people: [rootRecord(key: .some(nil))])

        XCTAssertEqual(asked.proposedLabel, "", "today's proposal: its own name collides too")
        XCTAssertEqual(asked.sharesItsNameWith, "Denver")
    }

    /// And the other direction: where the colliding label's standing records
    /// hold exactly this claim's key, the claim is proposed in that label's
    /// spelling — the key says it is them. Reached when recognition still
    /// asks: here, an unreadable person record (RULING-54) forces the sheet.
    func test_aClaimedNameWhoseLabelHoldsThisVeryKeyIsProposedInThatSpelling() throws {
        let lower = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "denver"))
        let root = person(self.root, label: "Denver", key: lower, admittedBy: self.root)
        let arrival = try device(name: "Denver’s iPhone", claimBy: lower)

        let asked = try request(
            for: arrival, people: [root], malformed: [unreadablePerson("zzzz9999")])

        XCTAssertEqual(asked.proposedLabel, "Denver")
        XCTAssertEqual(AdmissionDecision.outcome(for: asked, typedLabel: asked.proposedLabel),
                       .mergeUnder(label: "Denver"))
    }

    /// A label whose every record holding the key is REVOKED is not proposed:
    /// recognition does not stand on a revoked record, and neither does the
    /// field.
    func test_aClaimedNameWhoseOnlyHoldersAreRevokedIsNotProposed() throws {
        let samMac = DeviceIdentity.softwareForTesting().fingerprint
        let sam = person(samMac, label: "Sam", key: samKey, revoked: true)
        let arrival = try device(name: "New Phone", claimBy: samKey)

        let asked = try request(for: arrival, people: [rootRecord(), sam])

        XCTAssertEqual(asked.proposedLabel, "New Phone")
        XCTAssertEqual(asked.hint?.linkedElsewhere, true,
                       "recognition's own answer: every record of that label revoked")
    }

    /// A remembered label (this Mac named a device the folder has no record
    /// of) has no key at all, so a claim naming it is not proposed.
    func test_aClaimedNameMatchingOnlyARememberedLabelIsNotProposed() throws {
        let arrival = try device(name: "Tablet", claimBy: ruizKey)

        let asked = try request(
            for: arrival, people: [rootRecord()],
            memory: ["elsewhere": AdmissionMemory.Label(
                label: "Sam Ruiz", ownName: "Sam’s Mac",
                labelledAt: Date(timeIntervalSince1970: 5))])

        XCTAssertEqual(asked.proposedLabel, "Tablet")
    }

    func test_anUnnamedClaimProposesWhatItAlwaysDid() throws {
        let unnamed = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "  "))
        let arrival = try device(name: "Kit’s iPad", claimBy: unnamed)

        let asked = try request(for: arrival, people: [rootRecord()])

        XCTAssertEqual(asked.proposedLabel, "Kit’s iPad")
        XCTAssertEqual(AdmissionSheet.hintLines(for: asked).first,
                       "It calls itself Kit’s iPad.")
    }

    // MARK: - Linked elsewhere

    /// Review Focus 3's shape: a key linked to Sam on a device that says it is
    /// Denver's. The sheet says the key is somebody else's, and the field does
    /// not start at "Denver".
    func test_aKeyLinkedToSomebodyElseSaysSoAndIsNotProposedAsTheClaimedPerson() throws {
        // A claim's name is its key's own, so the key linked to Sam is one
        // whose item calls itself "Denver".
        let samMac = DeviceIdentity.softwareForTesting().fingerprint
        let samAsDenver = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver"))
        let samRecord = person(samMac, label: "Sam", key: samAsDenver)
        let arrival = try device(name: "Denver’s iPhone", claimBy: samAsDenver)

        let asked = try request(for: arrival, people: [rootRecord(), samRecord])

        XCTAssertEqual(asked.hint?.linkedElsewhere, true)
        XCTAssertEqual(asked.proposedLabel, "Denver’s iPhone",
                       "never Denver: that label's key is a different one")
        XCTAssertEqual(AdmissionSheet.hintLines(for: asked), [
            "It calls itself Denver’s iPhone, belonging to Denver.",
            AdmissionSheet.claimAttribution,
            AdmissionSheet.linkedElsewhereLine,
        ])
    }

    // MARK: - A forced sheet is not an alarm (Task 5's carry)

    /// An unreadable person record forces a sheet over a device recognition
    /// would otherwise have let in. The sheet says what the device says and
    /// nothing more — no warning, no "linked elsewhere".
    func test_aSheetForcedByAnUnreadableRecordReadsPlainly() throws {
        let arrival = try device(name: "Denver’s iPhone", claimBy: denverKey)

        let asked = try request(
            for: arrival, people: [rootRecord()],
            malformed: [unreadablePerson("zzzz9999")])

        XCTAssertEqual(asked.hint?.linkedElsewhere, false)
        let lines = AdmissionSheet.hintLines(for: asked)
        XCTAssertEqual(lines, [
            "It calls itself Denver’s iPhone, belonging to Denver.",
            AdmissionSheet.claimAttribution,
        ])
        for word in ["warning", "unreadable", "can’t", "danger", "!"] {
            XCTAssertFalse(lines.joined().localizedCaseInsensitiveContains(word), word)
        }
    }

    /// A key only a FOREIGN root's record holds is ignored by recognition
    /// (Task 6's ruling), so it reads exactly as an unknown key does.
    func test_aSheetForcedByAForeignRootsRecordReadsPlainly() throws {
        let foreign = DeviceIdentity.softwareForTesting().fingerprint
        let theirs = person(foreign, label: "Sam", key: samKey, admittedBy: foreign)
        let arrival = try device(name: "Sam’s iPad", claimBy: samKey)

        let asked = try request(for: arrival, people: [rootRecord(), theirs])

        XCTAssertEqual(asked.hint?.linkedElsewhere, false)
        XCTAssertFalse(AdmissionSheet.hintLines(for: asked)
            .contains(AdmissionSheet.linkedElsewhereLine))
        XCTAssertEqual(asked.proposedLabel, "Sam’s iPad",
                       "the foreign root's label holds no key of THIS chain")
    }
}
