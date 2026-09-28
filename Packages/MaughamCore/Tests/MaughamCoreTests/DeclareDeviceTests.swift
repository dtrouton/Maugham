import Foundation
import XCTest
@testable import MaughamCore

/// **The claim rule, once** (your devices are you, plan 2 Task 1 fix round;
/// tripwire 19): `RegistryPresence.claimIntent` and `declareDevice`, which the
/// Mac's open and the phone's first write both call; `PersonKey.find`, the
/// phone's find-only entry; and `PersonKeyStoreChoice`, the store decision
/// both surfaces build from. Person keys are `InMemoryPersonKeyStore`s — never
/// a keychain.
final class DeclareDeviceTests: XCTestCase {

    private var projectURL: URL!
    private var device: LocalIdentities!

    override func setUpWithError() throws {
        try super.setUpWithError()
        projectURL = TestTemp.root.appendingPathComponent("declare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        device = .softwareForTesting()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: projectURL)
        super.tearDown()
    }

    private func denver() throws -> PersonKey {
        try XCTUnwrap(PersonKey.findOrCreate(in: InMemoryPersonKeyStore(), seedName: "Denver"))
    }

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectURL)
    }

    // MARK: - claimIntent

    func test_aKeyIsASetClaimForThisDevice() throws {
        let decided = RegistryPresence.claimIntent(
            forDevice: device.author.fingerprint, personKey: try denver())
        guard case .set(let claim) = decided.intent else { return XCTFail("a claim") }
        XCTAssertNotNil(RegistryReader.verifiedPersonClaim(
            claim, forDevice: device.author.fingerprint))
        XCTAssertNil(decided.problem)
    }

    /// No key → `.keep`, never `.remove`.
    func test_noKeyKeepsAndNeverRemoves() {
        let decided = RegistryPresence.claimIntent(
            forDevice: device.author.fingerprint, personKey: nil)
        XCTAssertEqual(decided.intent, .keep)
        XCTAssertNil(decided.problem)
    }

    // MARK: - declareDevice

    func test_aClaimIsWrittenAndVerifies() throws {
        let problem = try RegistryPresence.declareDevice(
            in: projectURL, identities: device, name: "Denver's iPhone", kind: .phone,
            claim: RegistryPresence.claimIntent(
                forDevice: device.author.fingerprint, personKey: try denver()))
        XCTAssertNil(problem)
        XCTAssertNotNil(try registry().verifiedPersonClaims[device.author.fingerprint])
    }

    /// A claim the record refuses (made for another device) is said, never
    /// written, and the record is written anyway with `.keep` — carrying the
    /// claim it already had.
    func test_aRefusedClaimIsSaidAndTheRecordWrittenWithKeep() throws {
        let key = try denver()
        try RegistryPresence.declareDevice(
            in: projectURL, identities: device, name: "iPhone", kind: .phone,
            claim: RegistryPresence.claimIntent(
                forDevice: device.author.fingerprint, personKey: key))
        let standing = try XCTUnwrap(try registry().verifiedPersonClaims[device.author.fingerprint])

        let other = LocalIdentities.softwareForTesting()
        let wrong = try RegistryWriter.personClaim(
            forDevice: other.author.fingerprint, signedBy: try denver())
        let problem = try RegistryPresence.declareDevice(
            in: projectURL, identities: device, name: "Kitchen phone", kind: .phone,
            claim: (.set(wrong), nil))

        XCTAssertNotNil(problem, "said, not swallowed")
        XCTAssertEqual(try registry().devices.first?.name, "Kitchen phone",
                       "the record is still written")
        XCTAssertEqual(try registry().verifiedPersonClaims[device.author.fingerprint], standing,
                       "with the claim it had")
    }

    // MARK: - PersonKey.find

    /// The phone's entry never creates and never names.
    func test_findNeverCreatesAndNeverNames() throws {
        let empty = InMemoryPersonKeyStore()
        XCTAssertNil(PersonKey.find(in: empty))
        XCTAssertEqual(empty.createCount, 0)
        XCTAssertEqual(empty.find(), .absent)

        let unnamed = InMemoryPersonKeyStore()
        let minted = try XCTUnwrap(PersonKey.findOrCreate(in: unnamed, seedName: ""))
        let found = try XCTUnwrap(PersonKey.find(in: unnamed))
        XCTAssertEqual(found.fingerprint, minted.fingerprint)
        XCTAssertEqual(found.name, "")
        XCTAssertEqual(unnamed.setNameCount, 0)
    }

    func test_findRefusesAnItemThatIsNotAKey() {
        let broken = InMemoryPersonKeyStore(item: PersonKeyItem(
            privateKey: Data(repeating: 1, count: 32), publicKey: Data([4, 1, 2]), name: "X"))
        XCTAssertNil(PersonKey.find(in: broken))
    }

    // MARK: - PersonKeyStoreChoice

    func test_theStoreChoiceBothWays() {
        let injected = InMemoryPersonKeyStore()
        guard case .injected(let s) = PersonKeyStoreChoice.choose(injected: injected, isTestHost: false),
              s as? InMemoryPersonKeyStore === injected
        else { return XCTFail("an injected store wins") }
        guard case .injected = PersonKeyStoreChoice.choose(injected: injected, isTestHost: true)
        else { return XCTFail("over the host arm too") }
        guard case .testHost = PersonKeyStoreChoice.choose(injected: nil, isTestHost: true)
        else { return XCTFail("a test host never gets the keychain") }
        guard case .keychain(let group) = PersonKeyStoreChoice.choose(injected: nil, isTestHost: false)
        else { return XCTFail("production is the keychain") }
        XCTAssertEqual(group, "FF3XH4ZJ45.com.maugham.person")
    }
}
