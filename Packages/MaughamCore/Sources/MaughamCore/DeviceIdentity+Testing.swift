import CryptoKit
import Foundation

/// The test-only signers, quarantined in a file of their own.
///
/// A software P256 key is exactly what a device key must never be — it lives in
/// process memory, it can be copied off the machine, and a signature made with
/// one proves nothing about which device wrote the op. So the only production
/// signer is the enclave's, and `TripwireGrepTests.test_noSoftwarePrivateKeyInProduction`
/// names THIS FILE as its one allow-list entry. Nothing else under the three
/// production roots may construct a software private key.
///
/// `internal`, so it is reachable only through `@testable import MaughamCore`;
/// a target that imports MaughamCore normally cannot see any of it.
extension DeviceIdentity {
    /// A signing identity backed by an in-process P256 key, so the sign/verify
    /// contract is testable on a machine with no enclave (CI's VM runner).
    static func softwareForTesting() -> DeviceIdentity {
        let key = P256.Signing.PrivateKey()
        return signed(publicKey: key.publicKey) { digest in
            try key.signature(for: digest).rawRepresentation
        }
    }

    /// The unsigned twin over a known token, so a test can pin the
    /// token → fingerprint derivation and the `.unsigned` refusal.
    static func unsignedForTesting(token: Data) -> DeviceIdentity {
        unsigned(token: token)
    }
}
