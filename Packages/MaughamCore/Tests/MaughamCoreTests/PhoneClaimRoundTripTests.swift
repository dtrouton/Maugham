import Foundation
import XCTest
@testable import MaughamCore

/// **A phone-written claim, read on the Mac** (your devices are you, plan 2
/// Task 1; Review Focus 1; `MaughamPhone/AREA.md`, Rules → iCloud and the folder: phone-written rows are byte-compatible).
///
/// The bytes below were WRITTEN BY THE PHONE: `MaughamPhoneTests`'
/// `PhoneClaimFixtureDump` (opt-in — its header says how to run it to
/// regenerate these) ran a capture on the iOS simulator through the real
/// `InboxCaptureWriter` → `PhoneDeviceRecord.ensure` → Core's device
/// declaration, with an `InMemoryPersonKeyStore` holding the item below, and
/// this is the device record that landed on disk, verbatim, together with that
/// store's item. (The record's claim format is unchanged by the fix round that
/// moved the claim rule into Core, so these bytes stand.) This
/// suite runs on macOS, so what it proves is the cross-platform half the
/// phone's own in-process round trip
/// (`PhonePersonClaimTests.test_thePhonesClaimIsRecognisedByTheRootsMac`)
/// cannot: that iOS Foundation's encoding of a signed record and its claim is
/// read, verified and recognised by the Mac's reader, byte for byte.
///
/// The simulator reported its name as *iPhone 17* — not the generic model —
/// so the record keeps it (P2-2's rule never overwrites a real name).
///
/// The keys are throwaway software keys minted for the fixture; no keychain
/// was reached on either side.
final class PhoneClaimRoundTripTests: XCTestCase {

    /// The phone's device record, as the phone wrote it.
    static let phoneRecord = #"""
    {"actors":{"author":"c48bd80985cf833f1eba167fa2a894249b3e42b8c07d0f92a3528ecbc6c99efa"},"device":"c48bd80985cf833f1eba167fa2a894249b3e42b8c07d0f92a3528ecbc6c99efa","kind":"phone","madeAt":"2026-09-28T08:12:12.324Z","name":"iPhone 17","personClaim":{"name":"Denver Trouton","personKey":"df78034ca965fd748aa3b150c98a0410a20753a4208832800f0726973a0785d6","personPub":"BNpZ2WsCiGuoi0j4xj4+q4hZIhuWqP52WqTggoFQ4iT0R91KuoLyLrdHII9Ye18cWXvg9As1eR/CqZBSXuEb8FE=","sig":{"key":"df78034ca965fd748aa3b150c98a0410a20753a4208832800f0726973a0785d6","pub":"BNpZ2WsCiGuoi0j4xj4+q4hZIhuWqP52WqTggoFQ4iT0R91KuoLyLrdHII9Ye18cWXvg9As1eR/CqZBSXuEb8FE=","sig":"eqFg4HtsiYtwayqvy4QcStL5+MDKNeGdei/T6IlXcjWA4Vqmgm+x10NkjaAfCXJ8V+q8/Pk2/4ZIhvzgVAUrmA=="}},"sig":{"key":"c48bd80985cf833f1eba167fa2a894249b3e42b8c07d0f92a3528ecbc6c99efa","pub":"BCSmT26qlBKoMP1X+Le1GBswt2wu8ScguhzA9XbHd/ycQ45Mp6IyK/Gg5jmgcchhHKbB5f2/5HoRv8qDNfVS4Xw=","sig":"Bei4ME4hQ+Dc9l02Q4byJwG3PsYZZugcbQPWjmV1Z/oXGGkvnVhodZtzVzpHCvp8QPlWhoKFZFUuNGscNCB9ew=="}}
    """#

    /// The phone's author fingerprint — the record's filename.
    static let phoneFingerprint = "c48bd80985cf833f1eba167fa2a894249b3e42b8c07d0f92a3528ecbc6c99efa"

    /// The person key's item as the phone's store held it (the Mac's store
    /// holds the same item: that is what iCloud Keychain syncs).
    static let personItem = #"""
    {"privateKey":"H\/5etZMGzA\/nZnrCXqHpBXLPynlFakpftIw6s1VPcs0=","name":"Denver Trouton","publicKey":"BNpZ2WsCiGuoi0j4xj4+q4hZIhuWqP52WqTggoFQ4iT0R91KuoLyLrdHII9Ye18cWXvg9As1eR\/CqZBSXuEb8FE="}
    """#

    private var projectURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = TestTemp.root.appendingPathComponent("phone-claim-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
        super.tearDown()
    }

    /// Put the phone's bytes where the phone put them.
    private func placeThePhonesRecord() throws {
        let url = RegistryWriter.url(.devices, fingerprint: Self.phoneFingerprint, in: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.phoneRecord.utf8).write(to: url)
    }

    func test_aPhoneWrittenClaimVerifiesOnTheMac() throws {
        try placeThePhonesRecord()

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertTrue(registry.malformed.isEmpty, "the phone's record verifies on the Mac")
        let record = try XCTUnwrap(registry.devices.first)
        XCTAssertEqual(record.device, Self.phoneFingerprint)
        XCTAssertEqual(record.kind, .phone)
        let claim = try XCTUnwrap(registry.verifiedPersonClaims[Self.phoneFingerprint],
                                  "and so does the claim it carries")
        XCTAssertEqual(claim.name, "Denver Trouton")
    }

    /// The root's Mac holds the same person key, links it at open, and then
    /// recognises the phone as its own device and admits it silently.
    func test_theRootsMacRecognisesThePhoneAsItsOwnDevice() throws {
        let item = try JSONDecoder().decode(PersonKeyItem.self, from: Data(Self.personItem.utf8))
        let denver = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(item: item), seedName: "Denver Trouton"))
        let mac = LocalIdentities.softwareForTesting()
        try RegistryPresence.ensureDeviceRecord(
            in: projectURL, identities: mac, name: "Denver's MacBook", kind: .mac,
            personClaim: .set(try RegistryWriter.personClaim(
                forDevice: mac.author.fingerprint, signedBy: denver)))
        try RegistryPresence.ensureRootIfEmpty(
            in: projectURL, identities: mac, writerName: "Denver")
        let cache = RegistryCache(
            fileURL: TestTemp.root.appendingPathComponent("cache-\(UUID().uuidString).json"),
            identity: mac.author.fingerprint)
        _ = try RegistryPresence.admitRecognised(in: projectURL, identities: mac, cache: cache)

        try placeThePhonesRecord()
        let registry = try RegistryReader.load(projectURL: projectURL)
        let root = try XCTUnwrap(registry.person(mac.author.fingerprint))
        XCTAssertEqual(root.personKey, denver.fingerprint, "premise: the root's key is linked")
        let phone = try XCTUnwrap(registry.devices.first { $0.device == Self.phoneFingerprint })
        XCTAssertEqual(Recognition.recognise(
            device: phone, verifiedClaim: registry.verifiedPersonClaims[Self.phoneFingerprint],
            registry: registry, thisRoot: mac.author.fingerprint), .ownDevice(root: root))

        let pass = try RegistryPresence.admitRecognised(in: projectURL, identities: mac, cache: cache)
        XCTAssertEqual(pass.admitted.map(\.person), [Self.phoneFingerprint])
        XCTAssertEqual(try RegistryReader.load(projectURL: projectURL)
            .person(Self.phoneFingerprint)?.label, "Denver")
    }

    /// The control: the same bytes with the claim's name altered no longer
    /// verify as a claim — and the record's own signature, which covers the
    /// claim, refuses the record too. So the test above is reading real
    /// signatures, not a shape.
    func test_theFixtureIsSignedNotMerelyShaped() throws {
        let tampered = Self.phoneRecord.replacingOccurrences(
            of: #""name":"Denver Trouton""#, with: #""name":"Sam Trouton""#)
        XCTAssertNotEqual(tampered, Self.phoneRecord, "premise: the edit landed")
        let url = RegistryWriter.url(.devices, fingerprint: Self.phoneFingerprint, in: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(tampered.utf8).write(to: url)

        let registry = try RegistryReader.load(projectURL: projectURL)
        XCTAssertNil(registry.verifiedPersonClaims[Self.phoneFingerprint])
        XCTAssertTrue(registry.devices.isEmpty)
    }
}
