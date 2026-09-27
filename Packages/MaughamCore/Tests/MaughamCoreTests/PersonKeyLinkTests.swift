import Foundation
import XCTest
@testable import MaughamCore

/// **The linked person key** (your devices are you, Task 4).
///
/// A person record may say *this person owns person key P*, so a later device
/// whose record carries a verifying claim with P can be recognised as theirs.
/// The risk is linking a key to the wrong person, or to two people, so the
/// rule is pinned in both directions:
///
/// - **A key linked to one verified person record is linked, full stop** — to
///   anybody else the link is refused, and that holds while the holder is
///   REVOKED too: a key once linked to a revoked person must not quietly move
///   to somebody else, which is exactly the compromised-Apple-ID case.
/// - **Only the root's Forget releases it.** Once the holder's record no
///   longer carries it, the key is linkable again.
/// - **Only VERIFIED records count.** A file that does not verify says nothing
///   about anybody, so it neither holds a key nor blocks one.
///
/// Root-only by `RegistryAdmission.renameOutcome`'s rule — the one definition
/// of *who may re-sign this person record* — and the re-sign is the FILE's
/// object (`RegistryWriter.resign`), so a later build's fields survive.
final class PersonKeyLinkTests: XCTestCase {

    private var projectURL: URL!
    private var cacheURL: URL!
    private var memoryURL: URL!
    private var mine: LocalIdentities!
    private var phone: LocalIdentities!
    private var sam: LocalIdentities!
    private var otherRoot: LocalIdentities!
    private var denversKey: PersonKey!
    private var samsKey: PersonKey!

    override func setUp() {
        super.setUp()
        projectURL = TestTemp.root
            .appendingPathComponent("person-key-link-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        cacheURL = TestTemp.root
            .appendingPathComponent("person-key-link-cache-\(UUID().uuidString).json")
        memoryURL = TestTemp.root
            .appendingPathComponent("person-key-link-memory-\(UUID().uuidString).json")
        mine = .softwareForTesting()
        phone = .softwareForTesting()
        sam = .softwareForTesting()
        otherRoot = .softwareForTesting()
        denversKey = PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver Trouton")
        samsKey = PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Sam")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: memoryURL)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeCache() -> RegistryCache {
        RegistryCache(fileURL: cacheURL, identity: mine.author.fingerprint)
    }

    private func makeMemory() -> AdmissionMemory {
        AdmissionMemory(fileURL: memoryURL, identity: mine.author.fingerprint)
    }

    private func becomeRoot(_ identities: LocalIdentities, name: String) throws {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: identities, name: name, kind: .mac,
            now: { Date(timeIntervalSince1970: 1) })
        try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: identities, writerName: name,
            now: { Date(timeIntervalSince1970: 2) })
    }

    private func becomeRootBeside(_ identities: LocalIdentities, name: String) throws {
        try declare(identities, name: name, kind: .mac)
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: name, ownName: name,
                admittedAt: Date(timeIntervalSince1970: 3),
                admittedBy: identities.author.fingerprint),
            signedBy: identities.author, in: projectURL)
    }

    private func declare(
        _ identities: LocalIdentities, name: String, kind: DeviceKind = .phone
    ) throws {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: identities, name: name, kind: kind,
            now: { Date(timeIntervalSince1970: 3) })
    }

    @discardableResult
    private func admit(
        _ identities: LocalIdentities, label: String, ownName: String
    ) throws -> PersonRecord {
        try declare(identities, name: ownName)
        return try RegistryAdmission.admit(
            device: identities.author.fingerprint, label: label, ownName: ownName,
            in: projectURL, by: mine.author, cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 10) })
    }

    @discardableResult
    private func link(
        _ person: LocalIdentities, to key: PersonKey, by root: LocalIdentities? = nil
    ) throws -> PersonRecord {
        try RegistryAdmission.linkPersonKey(
            person: person.author.fingerprint, to: key.fingerprint, in: projectURL,
            by: (root ?? mine).author, cache: makeCache())
    }

    @discardableResult
    private func forget(
        _ person: LocalIdentities, by root: LocalIdentities? = nil
    ) throws -> PersonRecord {
        try RegistryAdmission.forgetPersonKey(
            person: person.author.fingerprint, in: projectURL,
            by: (root ?? mine).author, cache: makeCache())
    }

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    private func personFile(_ fingerprint: String) -> URL {
        RegistryWriter.url(.people, fingerprint: fingerprint, in: projectURL)
    }

    private func bytes(of person: LocalIdentities) throws -> Data {
        try Data(contentsOf: personFile(person.author.fingerprint))
    }

    private func object(of person: LocalIdentities) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try bytes(of: person)) as? [String: Any])
    }

    /// A later build's field, re-signed over the whole object as that build
    /// would have signed it.
    private func plantUnknownField(_ key: String, _ value: Int, in person: LocalIdentities) throws {
        let url = personFile(person.author.fingerprint)
        var object = try object(of: person)
        object[key] = value
        object.removeValue(forKey: "sig")
        let unsigned = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let credentials = try OpLogChain.credentials(
            signing: try RegistryCanonical.digestHex(ofJSON: unsigned),
            identity: mine.author)
        object["sig"] = try JSONSerialization.jsonObject(
            with: try RegistryCanonical.bytes(of: credentials))
        try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        ).write(to: url, options: .atomic)
    }

    // MARK: - The field is optional and absent by default

    /// Records stay readable by v0.41 builds and existing bytes do not move:
    /// a record with no linked key carries no `personKey` key at all.
    func test_aRecordWithNoLinkedKeyCarriesNoKeyForIt() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try admit(phone, label: "Denver", ownName: "Denver's iPhone")

        XCTAssertNil(try object(of: mine)["personKey"])
        XCTAssertNil(try object(of: phone)["personKey"])
        XCTAssertNil(try registry().person(phone.author.fingerprint)?.personKey)
    }

    // MARK: - Link

    func test_theRootLinksAKeyToSomebodyItAdmitted() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        let admitted = try admit(phone, label: "Denver", ownName: "Denver's iPhone")

        let linked = try link(phone, to: denversKey)

        XCTAssertEqual(linked.personKey, denversKey.fingerprint)
        XCTAssertEqual(try registry().person(phone.author.fingerprint)?.personKey,
                       denversKey.fingerprint)
        XCTAssertEqual(linked.label, admitted.label)
        XCTAssertEqual(linked.admittedAt, admitted.admittedAt)
        XCTAssertEqual(linked.admittedBy, mine.author.fingerprint)
        XCTAssertTrue(try registry().malformed.isEmpty, "the re-signed record verifies")
    }

    /// The root's own record names itself as its admitter, so the root links
    /// its own key by the same rule (spec: *the root's own record is linked to
    /// the root Mac's own P*).
    func test_theRootLinksItsOwnRecord() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        let linked = try link(mine, to: denversKey)

        XCTAssertEqual(linked.personKey, denversKey.fingerprint)
        XCTAssertTrue(linked.isRoot)
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    func test_linkingTheSameKeyAgainWritesNothing() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try admit(phone, label: "Denver", ownName: "Denver's iPhone")
        try link(phone, to: denversKey)
        let before = try bytes(of: phone)

        let again = try link(phone, to: denversKey)

        XCTAssertEqual(again.personKey, denversKey.fingerprint)
        XCTAssertEqual(try bytes(of: phone), before, "the file was not touched")
    }

    // MARK: - Nobody is linked twice (Review Focus 3)

    /// Direction 1: a key a standing person holds is refused for anybody else.
    func test_aKeyLinkedToSomebodyElseIsRefused() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try admit(sam, label: "Sam", ownName: "Sam's Mac")
        try admit(phone, label: "Denver", ownName: "Denver's iPhone")
        try link(sam, to: samsKey)
        let before = try bytes(of: phone)

        XCTAssertThrowsError(try link(phone, to: samsKey)) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .personKeyLinkedElsewhere(person: sam.author.fingerprint))
        }
        XCTAssertEqual(try bytes(of: phone), before)
        XCTAssertNil(try registry().person(phone.author.fingerprint)?.personKey)
    }

    /// Direction 1, revoked: a key once linked to a revoked person does not
    /// silently move to somebody else. Revocation is a state of a member, not
    /// an absence; releasing the key is Forget's act, explicitly.
    func test_aKeyLinkedToARevokedPersonIsStillRefusedForAnybodyElse() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try admit(sam, label: "Sam", ownName: "Sam's Mac")
        try admit(phone, label: "Denver", ownName: "Denver's iPhone")
        try link(sam, to: samsKey)
        try RegistryAdmission.revoke(
            person: sam.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01J0000000000000000000000A", cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })
        XCTAssertEqual(try registry().person(sam.author.fingerprint)?.personKey,
                       samsKey.fingerprint, "a revocation keeps the link")

        XCTAssertThrowsError(try link(phone, to: samsKey)) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .personKeyLinkedElsewhere(person: sam.author.fingerprint))
        }
        XCTAssertNil(try registry().person(phone.author.fingerprint)?.personKey)
    }

    /// Direction 2: once the holder's record no longer carries it — the root
    /// pressed Forget, revoked or not — the key is linkable again.
    func test_aForgottenKeyIsLinkableToSomebodyElse() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try admit(sam, label: "Sam", ownName: "Sam's Mac")
        try admit(phone, label: "Denver", ownName: "Denver's iPhone")
        try link(sam, to: samsKey)
        try RegistryAdmission.revoke(
            person: sam.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01J0000000000000000000000A", cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })

        try forget(sam)
        let linked = try link(phone, to: samsKey)

        XCTAssertEqual(linked.personKey, samsKey.fingerprint)
        XCTAssertNil(try registry().person(sam.author.fingerprint)?.personKey)
    }

    /// Only VERIFIED records count: a person file that does not verify (here,
    /// signed by a device that is no root) holds no key and blocks nobody.
    func test_aRecordThatDoesNotVerifyHoldsNoKey() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try admit(phone, label: "Denver", ownName: "Denver's iPhone")
        try declare(sam, name: "Sam's Mac")
        try RegistryWriter.write(
            PersonRecord(
                person: otherRoot.author.fingerprint, label: "Mallory", ownName: "?",
                admittedAt: Date(timeIntervalSince1970: 5),
                admittedBy: sam.author.fingerprint,
                personKey: denversKey.fingerprint),
            signedBy: sam.author, in: projectURL)
        XCTAssertFalse(try registry().malformed.isEmpty, "premise: it does not verify")
        XCTAssertNil(try registry().person(otherRoot.author.fingerprint))

        let linked = try link(phone, to: denversKey)

        XCTAssertEqual(linked.personKey, denversKey.fingerprint)
    }

    /// A record holds ONE key. A second, different key is refused rather than
    /// silently replacing the first — which would change who is recognised as
    /// this person with nothing saying so. Forget first.
    func test_aPersonAlreadyLinkedToAnotherKeyIsNotRelinked() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try admit(phone, label: "Denver", ownName: "Denver's iPhone")
        try link(phone, to: denversKey)
        let before = try bytes(of: phone)

        XCTAssertThrowsError(try link(phone, to: samsKey)) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .personLinkedToAnotherKey(person: phone.author.fingerprint))
        }
        XCTAssertEqual(try bytes(of: phone), before)
    }

    // MARK: - Root only (rename's rule)

    func test_aDeviceThatIsNotARootLinksNobody() throws {
        try becomeRoot(otherRoot, name: "Amelia's MacBook")
        try declare(mine, name: "Denver's MacBook", kind: .mac)

        XCTAssertThrowsError(try link(otherRoot, to: denversKey, by: mine)) { error in
            XCTAssertEqual(error as? RegistryAdmissionError, .notARoot)
        }
        XCTAssertNil(try registry().person(otherRoot.author.fingerprint)?.personKey)
    }

    func test_anotherRootsPersonIsNotThisMacsToLink() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try becomeRootBeside(otherRoot, name: "Amelia's MacBook")

        XCTAssertThrowsError(try link(otherRoot, to: samsKey)) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .alreadyAdmittedElsewhere(root: otherRoot.author.fingerprint))
        }
        XCTAssertNil(try registry().person(otherRoot.author.fingerprint)?.personKey)
    }

    func test_linkingSomebodyThisBookHasNoRecordOfIsRefused() throws {
        try becomeRoot(mine, name: "Denver's MacBook")

        XCTAssertThrowsError(try link(phone, to: denversKey)) { error in
            XCTAssertEqual(error as? RegistryAdmissionError,
                           .notAdmitted(fingerprint: phone.author.fingerprint))
        }
    }

    // MARK: - Forget

    func test_forgetRemovesTheField() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        let admitted = try admit(phone, label: "Denver", ownName: "Denver's iPhone")
        try link(phone, to: denversKey)

        let forgotten = try forget(phone)

        XCTAssertNil(forgotten.personKey)
        XCTAssertNil(try object(of: phone)["personKey"], "the key is gone from the file")
        XCTAssertEqual(forgotten.label, admitted.label)
        XCTAssertEqual(forgotten.admittedAt, admitted.admittedAt)
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    func test_forgettingAnUnlinkedPersonWritesNothing() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try admit(phone, label: "Denver", ownName: "Denver's iPhone")
        let before = try bytes(of: phone)

        let same = try forget(phone)

        XCTAssertNil(same.personKey)
        XCTAssertEqual(try bytes(of: phone), before)
    }

    func test_aDeviceThatIsNotARootForgetsNothing() throws {
        try becomeRoot(otherRoot, name: "Amelia's MacBook")
        try RegistryAdmission.linkPersonKey(
            person: otherRoot.author.fingerprint, to: samsKey.fingerprint,
            in: projectURL, by: otherRoot.author,
            cache: RegistryCache(
                fileURL: cacheURL.appendingPathExtension("other"),
                identity: otherRoot.author.fingerprint))
        try declare(mine, name: "Denver's MacBook", kind: .mac)

        XCTAssertThrowsError(try forget(otherRoot, by: mine)) { error in
            XCTAssertEqual(error as? RegistryAdmissionError, .notARoot)
        }
        XCTAssertEqual(try registry().person(otherRoot.author.fingerprint)?.personKey,
                       samsKey.fingerprint)
    }

    // MARK: - A later build's fields survive

    func test_anUnknownFieldSurvivesALinkAndAForget() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try admit(phone, label: "Denver", ownName: "Denver's iPhone")
        try plantUnknownField("future", 1, in: phone)

        try link(phone, to: denversKey)
        XCTAssertEqual(try object(of: phone)["future"] as? Int, 1, "survived the link")
        XCTAssertTrue(try registry().malformed.isEmpty)

        try forget(phone)
        XCTAssertEqual(try object(of: phone)["future"] as? Int, 1, "survived the forget")
        XCTAssertTrue(try registry().malformed.isEmpty)
    }

    // MARK: - The other writers of a person record keep the link

    /// `admit` over a standing record whose device renamed itself rewrites the
    /// record; the link is the root's decision about that person and must not
    /// be dropped by a correction to a machine's name.
    func test_anAdmissionOverALinkedRecordKeepsTheLink() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try admit(phone, label: "Denver", ownName: "Denver's iPhone")
        try link(phone, to: denversKey)

        let renamed = try RegistryAdmission.admit(
            device: phone.author.fingerprint, label: "Denver", ownName: "iPhone 17",
            in: projectURL, by: mine.author, cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 20) })

        XCTAssertEqual(renamed.ownName, "iPhone 17", "premise: the record was rewritten")
        XCTAssertEqual(renamed.personKey, denversKey.fingerprint)
    }

    /// A re-admission is the revocation's inverse; the key stayed linked
    /// through the revocation and stays linked after it.
    func test_aReadmissionKeepsTheLink() throws {
        try becomeRoot(mine, name: "Denver's MacBook")
        try admit(sam, label: "Sam", ownName: "Sam's Mac")
        try link(sam, to: samsKey)
        try RegistryAdmission.revoke(
            person: sam.author.fingerprint, in: projectURL, by: mine.author,
            highestOpIdSeen: "01J0000000000000000000000A", cache: makeCache(),
            now: { Date(timeIntervalSince1970: 100) })

        let back = try RegistryAdmission.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam's Mac",
            in: projectURL, by: mine.author, cache: makeCache(), memory: makeMemory(),
            now: { Date(timeIntervalSince1970: 200) })

        XCTAssertFalse(back.isRevoked, "premise: re-admitted")
        XCTAssertEqual(back.personKey, samsKey.fingerprint)
    }
}
