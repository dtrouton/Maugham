import Foundation
import XCTest
@testable import MaughamCore

/// **The person claim** (your devices are you, plan 1 Task 3). A device record
/// may carry a claim, signed by a person key, that the device belongs to that
/// person. The whole risk is a claim that verifies where it should not, so
/// every negative below is a claim the reader must leave UNVERIFIED — and
/// every one of them must leave the device record itself VALID, because an old
/// or bad claim must never un-admit a device.
///
/// Person keys come from `InMemoryPersonKeyStore`, never a real keychain.
final class RegistryPersonClaimTests: XCTestCase {

    private var projectURL: URL!
    private var mine: LocalIdentities!
    private var stranger: LocalIdentities!
    private var denver: PersonKey!
    private var sam: PersonKey!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = TestTemp.root.appendingPathComponent("claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        mine = .softwareForTesting()
        stranger = .softwareForTesting()
        denver = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver Trouton"))
        sam = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Sam"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
        super.tearDown()
    }

    // MARK: - Helpers

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    private func claim(for identities: LocalIdentities, by key: PersonKey) throws -> PersonClaim {
        try RegistryWriter.personClaim(forDevice: identities.author.fingerprint, signedBy: key)
    }

    /// A device record for `identities`, carrying `claim`, signed by that
    /// device's own author key — a record every reader must accept as a record.
    @discardableResult
    private func writeRecord(
        for identities: LocalIdentities, name: String, claim: PersonClaim?
    ) throws -> DeviceRecord {
        let record = DeviceRecord(
            device: identities.author.fingerprint, name: name, kind: .mac,
            actors: [DeviceActor.author.rawValue: identities.author.fingerprint],
            madeAt: Date(timeIntervalSince1970: 100), personClaim: claim)
        try RegistryWriter.write(record, signedBy: identities.author, in: projectURL)
        return record
    }

    /// The device is a valid record here, nothing is malformed, and the
    /// registry holds no verified claim for it.
    private func assertValidButUnverified(
        _ identities: LocalIdentities, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let registry = try registry()
        XCTAssertTrue(registry.malformed.isEmpty,
                      "a claim must never land its record in malformed: \(registry.malformed)",
                      file: file, line: line)
        XCTAssertTrue(registry.devices.contains { $0.device == identities.author.fingerprint },
                      "the device record stays valid", file: file, line: line)
        XCTAssertNil(registry.verifiedPersonClaim(forDevice: identities.author.fingerprint),
                     "the claim must not verify", file: file, line: line)
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - The round trip

    func test_aClaimRoundTripsAndVerifiesForItsOwnDevice() throws {
        let made = try claim(for: mine, by: denver)
        XCTAssertEqual(made.personKey, denver.fingerprint)
        XCTAssertEqual(made.personPub, denver.publicKey.x963Representation.base64EncodedString())
        XCTAssertEqual(made.name, "Denver Trouton")
        XCTAssertEqual(made.sig.key, denver.fingerprint)

        try writeRecord(for: mine, name: "Denver's MacBook", claim: made)

        let registry = try registry()
        XCTAssertTrue(registry.malformed.isEmpty)
        let record = try XCTUnwrap(registry.devices.first { $0.device == mine.author.fingerprint })
        XCTAssertEqual(record.personClaim, made, "the claim is read back exactly")
        XCTAssertEqual(registry.verifiedPersonClaim(forDevice: mine.author.fingerprint), made)
        XCTAssertEqual(registry.verifiedPersonClaims, [mine.author.fingerprint: made])
        XCTAssertEqual(RegistryReader.verifiedPersonClaim(of: record), made)
    }

    /// A registry built in memory answers the same question the loaded one
    /// does — the verified claims are a function of `devices` alone.
    func test_anInMemoryRegistryDerivesTheSameVerifiedClaims() throws {
        let made = try claim(for: mine, by: denver)
        let record = DeviceRecord(
            device: mine.author.fingerprint, name: "Mac", kind: .mac,
            actors: [DeviceActor.author.rawValue: mine.author.fingerprint],
            madeAt: Date(timeIntervalSince1970: 0), personClaim: made)
        let unclaimed = DeviceRecord(
            device: stranger.author.fingerprint, name: "Other", kind: .mac,
            actors: [DeviceActor.author.rawValue: stranger.author.fingerprint],
            madeAt: Date(timeIntervalSince1970: 0))

        let registry = Registry(devices: [record, unclaimed])

        XCTAssertEqual(registry.verifiedPersonClaims, [mine.author.fingerprint: made])
        XCTAssertNil(registry.verifiedPersonClaim(forDevice: stranger.author.fingerprint))
    }

    // MARK: - The negatives (Review Focus 1 and its siblings)

    /// Denver's phone's claim, copied into a stranger's own validly-signed
    /// record. The claim names Denver's device, so it holds for Denver's
    /// device alone.
    func test_aClaimCopiedIntoAnotherDevicesRecordDoesNotVerifyThere() throws {
        let denversClaim = try claim(for: mine, by: denver)
        try writeRecord(for: mine, name: "Denver's iPhone", claim: denversClaim)
        try writeRecord(for: stranger, name: "Denver's iPhone", claim: denversClaim)

        try assertValidButUnverified(stranger)
        XCTAssertEqual(try registry().verifiedPersonClaim(forDevice: mine.author.fingerprint),
                       denversClaim, "and it still holds where it was made")
    }

    func test_aClaimSignedByAKeyOtherThanItsPersonPubDoesNotVerify() throws {
        let signedBySam = try claim(for: mine, by: sam)
        let forged = PersonClaim(
            personKey: denver.fingerprint,
            personPub: denver.publicKey.x963Representation.base64EncodedString(),
            name: "Denver Trouton", sig: signedBySam.sig)
        try writeRecord(for: mine, name: "Mac", claim: forged)

        try assertValidButUnverified(mine)
    }

    /// Sam signs a claim that honestly names HER pub, but says it is Denver's
    /// fingerprint: the fingerprint must be the pub's own.
    func test_aClaimWhosePersonKeyIsNotItsPubsFingerprintDoesNotVerify() throws {
        let honest = try claim(for: mine, by: sam)
        let mislabelled = PersonClaim(
            personKey: denver.fingerprint, personPub: honest.personPub,
            name: honest.name, sig: honest.sig)
        try writeRecord(for: mine, name: "Mac", claim: mislabelled)

        try assertValidButUnverified(mine)
    }

    /// The fingerprint is Sam's and the signature is Sam's, but the pub the
    /// claim states is Denver's.
    func test_aClaimWhosePersonPubIsNotTheSignersDoesNotVerify() throws {
        let honest = try claim(for: mine, by: sam)
        let mislabelled = PersonClaim(
            personKey: honest.personKey,
            personPub: denver.publicKey.x963Representation.base64EncodedString(),
            name: honest.name, sig: honest.sig)
        try writeRecord(for: mine, name: "Mac", claim: mislabelled)

        try assertValidButUnverified(mine)
    }

    /// Sam's key really signs a claim that names DENVER's fingerprint beside
    /// her own pub — the signature is genuine over exactly what the claim
    /// says. Only *personKey is the fingerprint of personPub* refuses it.
    func test_aKeyThatSignsALieAboutItsFingerprintDoesNotVerify() throws {
        let samsPub = sam.publicKey.x963Representation.base64EncodedString()
        let lie = try signedBySam(personKey: denver.fingerprint, personPub: samsPub)
        try writeRecord(for: mine, name: "Mac", claim: lie)

        try assertValidButUnverified(mine)
    }

    /// Sam's key really signs a claim that names her own fingerprint beside
    /// DENVER's pub. The stated pub must be the one that signed.
    func test_aKeyThatSignsALieAboutItsPubDoesNotVerify() throws {
        let denversPub = denver.publicKey.x963Representation.base64EncodedString()
        let lie = try signedBySam(personKey: sam.fingerprint, personPub: denversPub)
        try writeRecord(for: mine, name: "Mac", claim: lie)

        try assertValidButUnverified(mine)
    }

    /// A claim whose fields say whatever the caller likes, genuinely signed by
    /// Sam's key over exactly those fields and this test's device — the
    /// forger's best effort, since she holds only her own key.
    private func signedBySam(personKey: String, personPub: String) throws -> PersonClaim {
        let content = PersonClaim.SignedContent(
            device: mine.author.fingerprint, personKey: personKey,
            personPub: personPub, name: "Denver Trouton")
        let digest = try RegistryCanonical.digestHex(
            ofJSON: try RegistryCanonical.bytes(of: content))
        return PersonClaim(personKey: personKey, personPub: personPub,
                           name: "Denver Trouton", sig: try sam.sign(digest))
    }

    func test_aClaimWithATamperedNameDoesNotVerify() throws {
        let honest = try claim(for: mine, by: sam)
        let renamed = PersonClaim(
            personKey: honest.personKey, personPub: honest.personPub,
            name: "Denver Trouton", sig: honest.sig)
        try writeRecord(for: mine, name: "Mac", claim: renamed)

        try assertValidButUnverified(mine)
    }

    /// A claim of the wrong SHAPE — written by a build that got it wrong, or by
    /// hand — must not make the device record undecodable. It is signed into
    /// the record by the device's own key, so the record verifies; the claim
    /// is simply absent.
    func test_aMisshapenClaimNeverLandsTheRecordInMalformed() throws {
        let device = mine.author.fingerprint
        let object: [String: Any] = [
            "device": device, "name": "Mac", "kind": "mac",
            "actors": [DeviceActor.author.rawValue: device],
            "madeAt": try RegistryCanonical.dateString(Date(timeIntervalSince1970: 100)),
            "personClaim": ["personKey": 42, "surprise": true],
        ]
        let unsigned = try JSONSerialization.data(withJSONObject: object)
        let bytes = try RegistryCanonical.resigned(
            fileBytes: unsigned, editing: { _ in },
            signing: { try OpLogChain.credentials(signing: $0, identity: self.mine.author) })
        let url = RegistryWriter.url(.devices, fingerprint: device, in: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)

        try assertValidButUnverified(mine)
        XCTAssertNil(try registry().devices.first { $0.device == device }?.personClaim)
    }

    // MARK: - The signature's domain

    /// The canonical form carries the constant domain, frozen with the format.
    func test_theSignedContentCarriesTheClaimDomain() throws {
        let made = try claim(for: mine, by: denver)
        let bytes = try RegistryCanonical.canonicalBytes(ofJSON: try RegistryCanonical.bytes(
            of: made.signedContent(forDevice: mine.author.fingerprint)))
        XCTAssertEqual(PersonClaim.signedKind, "maugham.personClaim.v1")
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self)
            .contains(#""kind":"maugham.personClaim.v1""#))
    }

    /// Denver's own key, genuinely signing the right device, key, pub and name
    /// — under another domain. Not a claim.
    func test_aSignatureUnderAnotherDomainDoesNotVerify() throws {
        var content = PersonClaim.SignedContent(
            device: mine.author.fingerprint, personKey: denver.fingerprint,
            personPub: denver.publicKey.x963Representation.base64EncodedString(),
            name: denver.name)
        content.kind = "maugham.somethingElse.v1"
        try writeRecord(for: mine, name: "Mac", claim: try signed(content, by: denver))

        try assertValidButUnverified(mine)
    }

    /// The same four facts signed with no domain at all. Not a claim.
    func test_aSignatureWithNoDomainDoesNotVerify() throws {
        struct Undomained: Encodable {
            let device, personKey, personPub, name: String
        }
        let pub = denver.publicKey.x963Representation.base64EncodedString()
        let content = Undomained(device: mine.author.fingerprint, personKey: denver.fingerprint,
                                 personPub: pub, name: denver.name)
        let digest = try RegistryCanonical.digestHex(
            ofJSON: try RegistryCanonical.bytes(of: content))
        let claim = PersonClaim(personKey: denver.fingerprint, personPub: pub,
                                name: denver.name, sig: try denver.sign(digest))
        try writeRecord(for: mine, name: "Mac", claim: claim)

        try assertValidButUnverified(mine)
    }

    private func signed(_ content: PersonClaim.SignedContent, by key: PersonKey) throws -> PersonClaim {
        let digest = try RegistryCanonical.digestHex(
            ofJSON: try RegistryCanonical.bytes(of: content))
        return PersonClaim(personKey: content.personKey, personPub: content.personPub,
                           name: content.name, sig: try key.sign(digest))
    }

    // MARK: - Old records keep their bytes

    /// A P2-era device record — the exact shape a v0.41 build writes, laid down
    /// as a JSON object rather than through this build's type — still
    /// verifies, carries no claim, and re-encodes under this build to the SAME
    /// bytes, so its signature is untouched.
    func test_anOldShapeRecordKeepsItsBytesAndItsSignature() throws {
        let device = mine.author.fingerprint
        let object: [String: Any] = [
            "device": device, "name": "Denver's MacBook", "kind": "mac",
            "actors": [DeviceActor.author.rawValue: device],
            "madeAt": try RegistryCanonical.dateString(Date(timeIntervalSince1970: 100)),
        ]
        let bytes = try RegistryCanonical.resigned(
            fileBytes: try JSONSerialization.data(withJSONObject: object),
            editing: { _ in },
            signing: { try OpLogChain.credentials(signing: $0, identity: self.mine.author) })
        let url = RegistryWriter.url(.devices, fingerprint: device, in: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)

        let registry = try registry()
        XCTAssertTrue(registry.malformed.isEmpty)
        let record = try XCTUnwrap(registry.devices.first { $0.device == device })
        XCTAssertNil(record.personClaim)
        XCTAssertTrue(registry.verifiedPersonClaims.isEmpty)
        XCTAssertEqual(try RegistryCanonical.bytes(of: record), bytes,
                       "a claim-less record re-encodes byte for byte — no personClaim key appears")
        XCTAssertFalse(String(decoding: try RegistryCanonical.bytes(of: record), as: UTF8.self)
            .contains("personClaim"))
    }

    // MARK: - ensureDeviceRecord

    func test_ensureDeviceRecordWritesTheClaim() throws {
        let made = try claim(for: mine, by: denver)
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .set(made))

        XCTAssertEqual(try registry().verifiedPersonClaim(forDevice: mine.author.fingerprint), made)
    }

    func test_ensureDeviceRecordRewritesARecordMissingItsClaim() throws {
        let url = try XCTUnwrap(try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac))
        XCTAssertNil(try registry().verifiedPersonClaim(forDevice: mine.author.fingerprint))

        let made = try claim(for: mine, by: denver)
        let rewrote = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .set(made))

        XCTAssertEqual(rewrote, url, "a record missing its claim is rewritten")
        XCTAssertEqual(try registry().verifiedPersonClaim(forDevice: mine.author.fingerprint), made)
    }

    /// ECDSA is randomized, so a Mac minting its claim afresh at every open
    /// hands over a different signature over the same facts each time. That
    /// is the same claim, and the folder is left alone.
    func test_ensureDeviceRecordLeavesTheSameClaimAloneEvenFreshlySigned() throws {
        let first = try claim(for: mine, by: denver)
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .set(first))
        let url = RegistryWriter.url(.devices, fingerprint: mine.author.fingerprint, in: projectURL)
        let before = try Data(contentsOf: url)

        let again = try claim(for: mine, by: denver)
        XCTAssertNotEqual(again.sig, first.sig, "precondition: the signatures differ")
        let wrote = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .set(again))

        XCTAssertNil(wrote, "the same claim is not a reason to write")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func test_ensureDeviceRecordRewritesAChangedClaim() throws {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac,
            personClaim: .set(try claim(for: mine, by: denver)))

        let other = try claim(for: mine, by: sam)
        let wrote = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .set(other))

        XCTAssertNotNil(wrote, "a different person key is a different claim")
        XCTAssertEqual(try registry().verifiedPersonClaim(forDevice: mine.author.fingerprint), other)
    }

    /// A record whose stored claim does not verify (tampered in the folder) is
    /// rewritten with the good one, even though its facts would compare equal
    /// field by field — a claim that does not hold is not "the same claim".
    func test_ensureDeviceRecordReplacesAStoredClaimThatDoesNotVerify() throws {
        let honest = try claim(for: mine, by: denver)
        let signedBySam = try claim(for: mine, by: sam)
        let broken = PersonClaim(personKey: honest.personKey, personPub: honest.personPub,
                                 name: honest.name, sig: signedBySam.sig)
        // The record ensureDeviceRecord would write — same name, kind and
        // actors — so the CLAIM is the only thing that can make it rewrite.
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac)
        let written = try XCTUnwrap(try registry().devices.first {
            $0.device == mine.author.fingerprint })
        try RegistryWriter.write(
            DeviceRecord(device: written.device, name: written.name, kind: written.kind,
                         actors: written.actors, madeAt: written.madeAt, personClaim: broken),
            signedBy: mine.author, in: projectURL)
        XCTAssertNil(try registry().verifiedPersonClaim(forDevice: mine.author.fingerprint))

        let wrote = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .set(honest))

        XCTAssertNotNil(wrote)
        XCTAssertEqual(try registry().verifiedPersonClaim(forDevice: mine.author.fingerprint), honest)
    }

    /// No claim to make now (keychain off, not signed in) is not a reason to
    /// write, and a rewrite for ANOTHER reason keeps the verified claim the
    /// record already carries — losing the keychain for a launch must not
    /// strip a true claim from the book.
    func test_noClaimNowNeitherStripsNorForcesAWrite() throws {
        let made = try claim(for: mine, by: denver)
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .set(made))

        let unchanged = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac)
        XCTAssertNil(unchanged, "nil is no claim to make, not a claim to remove")

        let renamed = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Renamed Mac", kind: .mac)
        XCTAssertNotNil(renamed)
        let registry = try registry()
        XCTAssertEqual(registry.devices.first { $0.device == mine.author.fingerprint }?.name,
                       "Renamed Mac")
        XCTAssertEqual(registry.verifiedPersonClaim(forDevice: mine.author.fingerprint), made,
                       "the rename carried the verified claim forward")
    }

    // MARK: - The three intents

    /// A claim built for ANOTHER device (a caller's mix-up) is refused loudly:
    /// it neither replaces the verified claim already there nor is written
    /// where there was none.
    func test_aClaimForAnotherDeviceIsRefusedAndNeverWritten() throws {
        let mineClaim = try claim(for: mine, by: denver)
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .set(mineClaim))
        let url = RegistryWriter.url(.devices, fingerprint: mine.author.fingerprint, in: projectURL)
        let before = try Data(contentsOf: url)

        let wrongDevice = try claim(for: stranger, by: denver)
        XCTAssertThrowsError(try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Renamed", kind: .mac,
            personClaim: .set(wrongDevice))) { error in
            XCTAssertEqual(error as? PersonClaimError,
                           .doesNotVerifyForThisDevice(device: self.mine.author.fingerprint))
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "nothing was written — not even the rename")
        XCTAssertEqual(try registry().verifiedPersonClaim(forDevice: mine.author.fingerprint), mineClaim)

        // And on a book with no record of this device yet, no record appears.
        let fresh = TestTemp.root.appendingPathComponent("claim-fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fresh) }
        XCTAssertThrowsError(try RegistryPresence.ensureDeviceRecord(
            in: fresh, identities: mine, name: "Mac", kind: .mac, personClaim: .set(wrongDevice)))
        XCTAssertTrue(try RegistryReader.load(projectURL: fresh).devices.isEmpty)
    }

    func test_removeStripsTheClaim() throws {
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac,
            personClaim: .set(try claim(for: mine, by: denver)))

        let wrote = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .remove)

        XCTAssertNotNil(wrote, "removing a claim is a change")
        let registry = try registry()
        XCTAssertNil(registry.devices.first { $0.device == mine.author.fingerprint }?.personClaim)
        XCTAssertTrue(registry.malformed.isEmpty)
        XCTAssertNil(try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .remove),
            "and removing nothing writes nothing")
    }

    func test_keepIsTheDefaultAndKeepsTheStandingClaim() throws {
        let made = try claim(for: mine, by: denver)
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .set(made))

        XCTAssertNil(try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac, personClaim: .keep))
        XCTAssertNotNil(try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Renamed", kind: .mac, personClaim: .keep))
        XCTAssertEqual(try registry().verifiedPersonClaim(forDevice: mine.author.fingerprint), made)
    }

    // MARK: - A change of person key is reported (#103)

    private func report(
        _ intent: PersonClaimIntent, name: String = "Mac"
    ) throws -> RegistryPresence.DeviceRecordOutcome {
        try RegistryPresence.ensureDeviceRecordReporting(
            in: projectURL, identities: mine, name: name, kind: .mac, personClaim: intent)
    }

    /// K1 → K2: a claim that held is replaced by one for another person key.
    /// Every other Mac now asks about this one again, so the write says so.
    func test_aDifferentPersonKeyReplacingAVerifiedClaimIsReported() throws {
        try report(.set(try claim(for: mine, by: denver)))

        let outcome = try report(.set(try claim(for: mine, by: sam)))

        XCTAssertNotNil(outcome.file)
        XCTAssertTrue(outcome.personKeyChanged)
    }

    /// None of these change whose device this is: a first claim, the same key
    /// signed afresh, the same key carried through a rename, no claim to make
    /// now, and a claim removed (the writer's own act).
    func test_noOtherWriteReportsAChangeOfPersonKey() throws {
        let first = try report(.set(try claim(for: mine, by: denver)))
        XCTAssertNotNil(first.file)
        XCTAssertFalse(first.personKeyChanged, "nil → K is a first claim")

        let renamedSameKey = try report(.set(try claim(for: mine, by: denver)), name: "Renamed")
        XCTAssertNotNil(renamedSameKey.file)
        XCTAssertFalse(renamedSameKey.personKeyChanged, "K → K")

        let kept = try report(.keep, name: "Renamed Again")
        XCTAssertNotNil(kept.file)
        XCTAssertFalse(kept.personKeyChanged, ".keep carries the claim")

        let removed = try report(.remove)
        XCTAssertNotNil(removed.file)
        XCTAssertFalse(removed.personKeyChanged, ".remove is the writer's act")

        let claimedAgain = try report(.set(try claim(for: mine, by: sam)))
        XCTAssertNotNil(claimedAgain.file)
        XCTAssertFalse(claimedAgain.personKeyChanged, "no claim stood, so this is a first claim")
    }

    /// Only a VERIFIED claim stands: a tampered one names nobody, so replacing
    /// it is a first claim, not a change of key.
    func test_replacingAClaimThatDoesNotVerifyIsNotAChangeOfPersonKey() throws {
        try report(.keep)
        let written = try XCTUnwrap(try registry().devices.first {
            $0.device == mine.author.fingerprint })
        let honest = try claim(for: mine, by: denver)
        let broken = PersonClaim(personKey: honest.personKey, personPub: honest.personPub,
                                 name: honest.name, sig: try claim(for: mine, by: sam).sig)
        try RegistryWriter.write(
            DeviceRecord(device: written.device, name: written.name, kind: written.kind,
                         actors: written.actors, madeAt: written.madeAt, personClaim: broken),
            signedBy: mine.author, in: projectURL)

        let outcome = try report(.set(try claim(for: mine, by: sam)))

        XCTAssertNotNil(outcome.file)
        XCTAssertFalse(outcome.personKeyChanged)
    }

    /// The bare verbs answer as they always did, and `declareDeviceReporting`
    /// carries the change — but never from a claim the record refused.
    func test_theDeclarationCarriesTheChangeAndTheBareVerbsAreUnchanged() throws {
        try report(.set(try claim(for: mine, by: denver)))

        let refused = try RegistryPresence.declareDeviceReporting(
            in: projectURL, identities: mine, name: "Mac", kind: .mac,
            claim: (.set(try claim(for: stranger, by: sam)), nil))
        XCTAssertNotNil(refused.problem)
        XCTAssertFalse(refused.personKeyChanged, "a refused claim is re-written as .keep")

        let declared = try RegistryPresence.declareDeviceReporting(
            in: projectURL, identities: mine, name: "Mac", kind: .mac,
            claim: (.set(try claim(for: mine, by: sam)), nil))
        XCTAssertNil(declared.problem)
        XCTAssertTrue(declared.personKeyChanged)

        let bare = try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mine, name: "Mac", kind: .mac,
            personClaim: .set(try claim(for: mine, by: denver)))
        XCTAssertNotNil(bare, "the bare verb still answers the file")
        XCTAssertNil(try RegistryPresence.declareDevice(
            in: projectURL, identities: mine, name: "Mac", kind: .mac,
            claim: (.set(try claim(for: mine, by: sam)), nil)),
            "the bare declaration still answers the problem only")
    }
}
