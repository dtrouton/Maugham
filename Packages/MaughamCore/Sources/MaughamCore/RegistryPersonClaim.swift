import Foundation

/// **The person claim** (your devices are you, plan 1 Task 3; PK-1): a device
/// record's statement that *this device belongs to person key P, whose name is
/// N*, signed by P.
///
/// It lives INSIDE the device record (`DeviceRecord.personClaim`), so the
/// device's own author key signs the record and therefore covers the claim,
/// while the person key signs the claim's own canonical form. Two signatures,
/// two questions: the device's says *this Mac wrote this record*, the person
/// key's says *the person holding P says this Mac is theirs*.
///
/// **Bound to the device.** What P signs names the record's `device`
/// fingerprint (`SignedContent.device`), and the reader rebuilds that content
/// from the CONTAINING record's `device` rather than from anything the claim
/// carries. A claim copied out of one device's record into another's therefore
/// fails to verify there — the one property the silent admission the later
/// tasks build rests on (Review Focus 1).
///
/// **A claim never costs a device its record.** An absent, unverifiable or
/// misshapen claim leaves the device record exactly as valid as it would be
/// without one, and the registry simply has no verified claim for that device
/// (`Registry.verifiedPersonClaims`). An old build rewriting the record drops
/// the claim; nothing refuses (Review Focus 4).
///
/// This file decides the SHAPE of what is signed and nothing about the bytes:
/// the bytes and the digest are `RegistryCanonical`'s (tripwire 42), the
/// signature is made in `RegistryWriter.personClaim(forDevice:signedBy:)` and
/// checked in `RegistryReader.verifiedPersonClaim(of:)` — the two places the
/// census lets ask for a digest.
public struct PersonClaim: Codable, Equatable, Hashable, Sendable {
    /// P's fingerprint — `DeviceIdentity.fingerprint(of:)` over `personPub`.
    public let personKey: String
    /// P's public key: base64 of its X9.63 bytes, `Credentials.pub`'s form.
    public let personPub: String
    /// The person's name as the key item carries it. May be empty.
    public let name: String
    /// P's signature over `signedContent(forDevice:)`'s canonical bytes.
    public let sig: OpLogChain.Credentials

    public init(personKey: String, personPub: String, name: String,
                sig: OpLogChain.Credentials) {
        self.personKey = personKey
        self.personPub = personPub
        self.name = name
        self.sig = sig
    }

    /// What P signs: the claim's three facts plus the device they are about.
    /// Encodable only — it is never read back, only canonicalized.
    struct SignedContent: Encodable, Equatable {
        let device: String
        let personKey: String
        let personPub: String
        let name: String
    }

    /// The content this claim must have been signed over to hold for `device`.
    /// The device comes from the CALLER — the record the claim sits in — and
    /// never from the claim, which is what binds a claim to its device.
    func signedContent(forDevice device: String) -> SignedContent {
        SignedContent(device: device, personKey: personKey,
                      personPub: personPub, name: name)
    }

    /// The claim's three facts, for EQUALITY only: CryptoKit's ECDSA is
    /// randomized, so two honest claims of one fact differ in `sig`, and
    /// `ensureDeviceRecord` compares THIS rather than the claim.
    ///
    /// Deliberately its own type, neither `Encodable` nor a `SignedContent`:
    /// it carries no device, so it must never be something a signature can be
    /// made or checked over — only `signedContent(forDevice:)` is.
    struct Facts: Equatable {
        let personKey: String
        let personPub: String
        let name: String
    }

    var facts: Facts { Facts(personKey: personKey, personPub: personPub, name: name) }
}
