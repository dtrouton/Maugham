import CryptoKit
import XCTest
@testable import MaughamCore

/// The ONE enclave test on the phone: does an iOS process actually get a
/// signing identity out of `DeviceIdentity.load(from:)`?
///
/// Everything else about the chain is tested against the software signer, which
/// proves the sign/verify contract and nothing about the hardware. This proves
/// the hardware — and the §7 spike (2026-09-07) predicted it would RUN rather
/// than skip, because the iOS simulator exposes a Secure Enclave through the
/// host's. The skip is therefore a MEASUREMENT: if it fires, the simulator on
/// this machine has no enclave and the phone writes unsigned ops, which is a
/// state and not a failure (spec §4.1).
///
/// It writes into a temp directory of its own, never `DeviceState.directory`,
/// so it cannot disturb the identity the rest of the suite (or the app on this
/// simulator) is using.
final class PhoneDeviceIdentityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            SecureEnclave.isAvailable,
            "no Secure Enclave in this simulator — the phone writes unsigned ops here")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-identity-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    /// Mint, then sign, then verify — the whole contract in one pass. A key
    /// that mints but cannot sign, or signs unverifiably, is worse than no key
    /// at all, so all three are asserted together.
    func test_theSimulatorMintsAKeyThatSignsAndVerifies() throws {
        let identity = try DeviceIdentity.load(from: directory, actor: .author)

        XCTAssertTrue(identity.canSign,
                      "an enclave is available, so this device must hold a signing key")
        let publicKey = try XCTUnwrap(identity.publicKey)
        XCTAssertEqual(identity.fingerprint, DeviceIdentity.fingerprint(of: publicKey))
        XCTAssertEqual(identity.actor, .author,
                       "the phone is the writer on its own device and nothing else")
        XCTAssertEqual(identity.deviceId, "author-\(identity.fingerprint.prefix(16))")

        let digest = Data(SHA256.hash(data: Data("the words are safe".utf8)))
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: try identity.sign(digest))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: digest))
    }

    /// The key is PERSISTED, not minted per launch: a second load reads the
    /// blob back off disk and answers the same device. If it did not, every
    /// launch would be a new device and the op log would fill with strangers.
    func test_aSecondLoadReusesThePersistedBlob() throws {
        let first = try DeviceIdentity.load(from: directory, actor: .author)
        let blob = directory.appendingPathComponent(DeviceIdentity.blobFilename(for: .author))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path),
                      "the enclave-wrapped blob is written beside the state")

        let second = try DeviceIdentity.load(from: directory, actor: .author)
        XCTAssertTrue(second.canSign)
        XCTAssertEqual(second.fingerprint, first.fingerprint)
        XCTAssertEqual(second.deviceId, first.deviceId)
        XCTAssertEqual(second.publicKey?.x963Representation,
                       first.publicKey?.x963Representation,
                       "the same key, not a fresh one that happens to work")

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, [DeviceIdentity.blobFilename(for: .author)],
                       "the phone mints ONE key on first launch — the author's. "
                       + "Found: \(names)")
    }
}
