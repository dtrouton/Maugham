import CryptoKit
import Foundation
import XCTest
@testable import MaughamCore

/// One writer, one reader. Everything the reader cannot vouch for is LISTED
/// (`Registry.malformed`) and never read as a record — and a file that is
/// present but unreadable stops the read outright (RULING-54), because a
/// registry that silently shrinks is a trust decision made by a permissions
/// error.
final class RegistryReaderWriterTests: XCTestCase {

    private var projectURL: URL!
    private var root: DeviceIdentity!
    private var phone: DeviceIdentity!

    override func setUp() {
        super.setUp()
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        root = .softwareForTesting()
        phone = .softwareForTesting()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func rootRecord(_ identity: DeviceIdentity, label: String = "Denver") -> PersonRecord {
        PersonRecord(
            person: identity.fingerprint, label: label, ownName: "Denver's MacBook",
            admittedAt: Date(timeIntervalSince1970: 10), admittedBy: identity.fingerprint)
    }

    private func admittedRecord(
        _ identity: DeviceIdentity, under rootIdentity: DeviceIdentity, label: String = "Denver"
    ) -> PersonRecord {
        PersonRecord(
            person: identity.fingerprint, label: label, ownName: "Denver's iPhone",
            admittedAt: Date(timeIntervalSince1970: 20),
            admittedBy: rootIdentity.fingerprint)
    }

    private func deviceRecord(
        _ identity: DeviceIdentity, kind: DeviceKind = .mac, actors: [String: String]? = nil
    ) -> DeviceRecord {
        DeviceRecord(
            device: identity.fingerprint, name: "Denver's MacBook", kind: kind,
            actors: actors ?? ["author": identity.fingerprint],
            madeAt: Date(timeIntervalSince1970: 5))
    }

    // MARK: - Round trip

    func test_aDeviceRecordSurvivesTheTripThroughDisk() throws {
        let written = deviceRecord(root)
        let url = try RegistryWriter.write(written, signedBy: root, in: projectURL)

        XCTAssertEqual(url.lastPathComponent, "\(root.fingerprint).json",
                       "a record is named by its own fingerprint")
        XCTAssertEqual(
            url.deletingLastPathComponent().path,
            projectURL.appendingPathComponent(".maugham/devices").path)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.malformed, [])
        let read = try XCTUnwrap(registry.devices.first)
        XCTAssertEqual(read.device, written.device)
        XCTAssertEqual(read.name, written.name)
        XCTAssertEqual(read.actors, written.actors)
        XCTAssertEqual(read.madeAt, written.madeAt)
        XCTAssertEqual(read.sig?.key, root.fingerprint, "signed by the device's author key")
    }

    func test_aRootAndTheDeviceItAdmittedBothRead() throws {
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        try RegistryWriter.write(admittedRecord(phone, under: root), signedBy: root, in: projectURL)

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.malformed, [])
        XCTAssertEqual(Set(registry.people.map(\.person)),
                       [root.fingerprint, phone.fingerprint])
        XCTAssertEqual(registry.roots.map(\.person), [root.fingerprint],
                       "the root is the one who admitted themselves")
    }

    func test_aClaimSurvivesTheTripThroughDisk() throws {
        let claim = ClaimRecord(
            newRoot: phone.fingerprint, adopted: [root.fingerprint],
            claimedAt: Date(timeIntervalSince1970: 30))
        let url = try RegistryWriter.write(claim, signedBy: phone, in: projectURL)

        XCTAssertEqual(
            url.deletingLastPathComponent().path,
            projectURL.appendingPathComponent(".maugham/people/claims").path)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.malformed, [])
        XCTAssertEqual(registry.claims.first?.adopted, [root.fingerprint])
        XCTAssertEqual(registry.people, [], "a claim is not a person record")
    }

    /// The signature verifies on the way back in — the point of the whole file.
    func test_aReadRecordsSignatureStillVerifies() throws {
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        let read = try XCTUnwrap(
            try RegistryReader.load(projectURL: projectURL).people.first)

        var unsigned = read
        unsigned.sig = nil
        let credentials = try XCTUnwrap(read.sig)
        XCTAssertTrue(OpLogChain.credentialsVerify(
            credentials, over: try RegistryCanonical.digestHex(ofRecord: unsigned)))
    }

    /// Re-signing a device record (a new actor key was minted) replaces the
    /// file rather than leaving two.
    func test_rewritingADeviceRecordReplacesIt() throws {
        try RegistryWriter.write(deviceRecord(root), signedBy: root, in: projectURL)
        try RegistryWriter.write(
            deviceRecord(root, actors: ["author": root.fingerprint, "assistant": "bbbb"]),
            signedBy: root, in: projectURL)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertEqual(registry.devices.count, 1)
        XCTAssertEqual(registry.devices.first?.actors["assistant"], "bbbb")
    }

    // MARK: - The writer refuses

    /// A device with no key cannot make a record. `.unsigned` is a first-class
    /// state, never a trap and never an unsigned file on disk.
    func test_aKeylessDeviceWritesNoRecordAtAll() throws {
        let keyless = DeviceIdentity.unsignedForTesting(token: Data(repeating: 7, count: 32))

        XCTAssertThrowsError(
            try RegistryWriter.write(rootRecord(keyless), signedBy: keyless, in: projectURL)
        ) { XCTAssertEqual($0 as? DeviceIdentityError, .unsigned) }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectURL.appendingPathComponent(".maugham/people").path),
            "nothing is created on the refusing path")
    }

    // MARK: - Malformed: listed, never read

    func test_aFlippedByteIsMalformedAndNotAPerson() throws {
        let url = try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"label\":\"Denver\"",
                                         with: "\"label\":\"Someone\"")
        try text.write(to: url, atomically: true, encoding: .utf8)

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.people, [], "a record that does not verify is not a record")
        XCTAssertEqual(registry.malformed.map(\.reason), [.signatureDoesNotVerify])
        XCTAssertEqual(registry.malformed.first?.url.lastPathComponent, url.lastPathComponent)
    }

    func test_aRecordRenamedToAnotherFingerprintIsMalformed() throws {
        let url = try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        let moved = url.deletingLastPathComponent()
            .appendingPathComponent("\(phone.fingerprint).json")
        try FileManager.default.moveItem(at: url, to: moved)

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.people, [])
        XCTAssertEqual(registry.malformed.map(\.reason),
                       [.filenameMismatch(named: root.fingerprint)])
    }

    /// The admission rule: a person record that is not self-signed must be
    /// signed by a ROOT — otherwise anyone who can write the folder could
    /// admit themselves by signing their own admission with a second key.
    func test_aPersonAdmittedByANonRootIsMalformed() throws {
        let stranger = DeviceIdentity.softwareForTesting()
        // `stranger` has no record of its own anywhere, so it is nobody's root.
        try RegistryWriter.write(
            admittedRecord(phone, under: stranger), signedBy: stranger, in: projectURL)

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.people, [])
        XCTAssertEqual(registry.malformed.map(\.reason),
                       [.signerIsNotARoot(named: stranger.fingerprint)])
    }

    /// And the signer must be the root it NAMES: a record admitted by the root
    /// but signed by somebody else is not that root's word.
    func test_aPersonRecordSignedByOtherThanTheRootItNamesIsMalformed() throws {
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        let impostor = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            admittedRecord(phone, under: root), signedBy: impostor, in: projectURL)

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.people.map(\.person), [root.fingerprint])
        XCTAssertEqual(registry.malformed.map(\.reason),
                       [.signerIsNotTheExpectedKey(expected: root.fingerprint,
                                                   found: impostor.fingerprint)])
    }

    /// A root record signed by anything but the person it names is not a root.
    func test_aSelfSignedRecordSignedByAnotherKeyIsMalformed() throws {
        try RegistryWriter.write(rootRecord(root), signedBy: phone, in: projectURL)

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.roots, [])
        XCTAssertEqual(registry.malformed.map(\.reason),
                       [.signerIsNotTheExpectedKey(expected: root.fingerprint,
                                                   found: phone.fingerprint)])
    }

    /// A device record must be signed by that device's own author key.
    func test_aDeviceRecordSignedByAnotherDeviceIsMalformed() throws {
        try RegistryWriter.write(deviceRecord(root), signedBy: phone, in: projectURL)

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.devices, [])
        XCTAssertEqual(registry.malformed.map(\.reason),
                       [.signerIsNotTheExpectedKey(expected: root.fingerprint,
                                                   found: phone.fingerprint)])
    }

    func test_aRecordWithNoSignatureAtAllIsMalformed() throws {
        let dir = projectURL.appendingPathComponent(".maugham/people")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unsigned = rootRecord(root)
        try RegistryCanonical.bytes(of: unsigned)
            .write(to: dir.appendingPathComponent("\(root.fingerprint).json"))

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.people, [])
        XCTAssertEqual(registry.malformed.map(\.reason), [.unsigned])
    }

    func test_gibberishIsListedAndTheRestOfTheRegistryStillReads() throws {
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        try Data("not json at all".utf8).write(
            to: projectURL.appendingPathComponent(".maugham/people/zzzz.json"))

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.people.map(\.person), [root.fingerprint],
                       "one bad file costs its own record and nothing else")
        XCTAssertEqual(registry.malformed.count, 1)
        XCTAssertEqual(registry.malformed.first?.url.lastPathComponent, "zzzz.json")
        if case .undecodable = registry.malformed.first?.reason {} else {
            XCTFail("expected .undecodable, got \(String(describing: registry.malformed.first?.reason))")
        }
    }

    /// Malformed is a state with a sentence a surface can print.
    func test_everyMalformedReasonSaysWhatIsWrong() {
        let reasons: [MalformedRecord.Reason] = [
            .undecodable("the decoder's own words"), .unsigned,
            .filenameMismatch(named: "aaaa"), .signatureDoesNotVerify,
            .signerIsNotTheExpectedKey(expected: "aaaa", found: "bbbb"),
            .signerIsNotARoot(named: "cccc")]
        for reason in reasons {
            XCTAssertFalse(reason.sentence.isEmpty, "\(reason) says nothing")
        }
    }

    // MARK: - Present and unreadable (RULING-54)

    func test_aPresentButUnreadableRecordRefusesTheWholeRead() throws {
        let url = try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: url.path)

        XCTAssertThrowsError(try RegistryReader.load(projectURL: projectURL)) { error in
            guard let refusal = error as? OpLogStore.ReadError else {
                return XCTFail("expected the op log's own refusal, got \(error)")
            }
            XCTAssertTrue(
                refusal.errorDescription?.contains(url.lastPathComponent) == true,
                "the refusal must NAME the file the writer has to go and fix")
        }
    }

    // MARK: - Nothing there

    func test_aProjectWithNoRegistryReadsEmptyAndThrowsNothing() throws {
        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.people, [])
        XCTAssertEqual(registry.devices, [])
        XCTAssertEqual(registry.claims, [])
        XCTAssertEqual(registry.malformed, [])
        XCTAssertEqual(registry.roots, [])
    }

    /// The claims directory lives INSIDE `people/`; it is not a person record
    /// with a broken name.
    func test_theClaimsDirectoryIsNotReadAsAPerson() throws {
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        try RegistryWriter.write(
            ClaimRecord(newRoot: phone.fingerprint, adopted: [root.fingerprint],
                        claimedAt: Date(timeIntervalSince1970: 1)),
            signedBy: phone, in: projectURL)

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.malformed, [])
        XCTAssertEqual(registry.people.count, 1)
        XCTAssertEqual(registry.claims.count, 1)
    }

    // MARK: - The two derivations

    func test_theChainUnderARootIsEveryoneItAdmittedTransitively() throws {
        let second = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        try RegistryWriter.write(admittedRecord(phone, under: root), signedBy: root, in: projectURL)
        try RegistryWriter.write(admittedRecord(second, under: root), signedBy: root, in: projectURL)

        let registry = try RegistryReader.load(projectURL: projectURL)
        let theRoot = try XCTUnwrap(registry.roots.first)

        XCTAssertEqual(registry.chain(under: theRoot),
                       [root.fingerprint, phone.fingerprint, second.fingerprint],
                       "the root is in its own chain")
    }

    func test_anotherRootsChainIsNotThisOnes() throws {
        let otherRoot = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        try RegistryWriter.write(admittedRecord(phone, under: root), signedBy: root, in: projectURL)
        try RegistryWriter.write(
            rootRecord(otherRoot, label: "Someone else"), signedBy: otherRoot, in: projectURL)

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.roots.count, 2, "a second claimant is listed, never merged")
        XCTAssertEqual(registry.chain(underRoot: otherRoot.fingerprint),
                       [otherRoot.fingerprint])
        XCTAssertEqual(registry.chain(underRoot: root.fingerprint),
                       [root.fingerprint, phone.fingerprint])
    }

    func test_aChainUnderAnUnknownFingerprintIsEmpty() throws {
        try RegistryWriter.write(rootRecord(root), signedBy: root, in: projectURL)
        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.chain(underRoot: "nobody"), [])
    }

    /// Admitting a device admits every actor key its record lists — that is
    /// what lets Claude's seal on this Mac read as this Mac's (spec §4.4).
    func test_aDevicesActorKeysAreEveryKeyItsRecordLists() throws {
        try RegistryWriter.write(
            deviceRecord(root, actors: ["author": root.fingerprint,
                                        "assistant": "bbbb", "translator": "cccc"]),
            signedBy: root, in: projectURL)

        let registry = try RegistryReader.load(projectURL: projectURL)

        XCTAssertEqual(registry.actorFingerprints(ofDevice: root.fingerprint),
                       [root.fingerprint, "bbbb", "cccc"])
        XCTAssertEqual(registry.actorFingerprints(ofDevice: phone.fingerprint), [],
                       "a device with no record has no actors we can vouch for")
    }
}
