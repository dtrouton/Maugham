import Foundation

/// The three records a project's registry is made of (P2 spec §2), and the one
/// thing they have in common: each is named on disk by a fingerprint it carries
/// itself, and each is SIGNED over its own canonical bytes.
///
/// **Labels only** (Denver, 2026-09-07). There is no person key in this
/// milestone: a person IS a device, `personFingerprint == authorFingerprint`,
/// and "Denver" is a label the author's key attaches to devices. The shapes
/// below carry `person` as a fingerprint of its own precisely so a synced
/// person key can arrive later without a format change.
///
/// Nothing here decides TRUST. These are the facts on disk; who is admitted,
/// pending, revoked or another claimant is `TrustTable`'s question, and it asks
/// it of a `Registry` the reader already verified.

// MARK: - Where a record lives

/// Which of the registry's three directories a record belongs to. A CASE rather
/// than a path, so the paths themselves live in exactly one file
/// (`RegistryWriter`) and a census can say so.
public enum RegistryDirectory: String, Sendable, CaseIterable {
    case devices
    case people
    case claims
}

// MARK: - The common shape

/// What the writer and the reader need of any record: the fingerprint that
/// names its file, the key expected to have signed it, the directory it lives
/// in, and a signature slot the canonical encoding omits while it is nil.
public protocol RegistryRecordProtocol: Codable, Equatable, Sendable {
    /// The record's own fingerprint field — `<this>.json` is its filename.
    var fingerprint: String { get }
    /// The signature over this record's canonical bytes, nil before signing.
    var sig: OpLogChain.Credentials? { get set }
    /// Which directory this kind of record lives in.
    static var directory: RegistryDirectory { get }
    /// Whose key must have signed it: the fingerprint the record itself names
    /// as its signer — its own `device`, the `newRoot` of a claim, or the root
    /// a person record says admitted it. `PersonRecord` is the only one of the
    /// three whose signer is not itself, and the reader asks a second question
    /// of it: that the named signer IS a root here.
    var expectedSigner: String { get }
}

// MARK: - Device record (spec §2.1)

/// What kind of machine a device record describes. Lossless about a value this
/// build does not know: a device record is re-signed by its own device when a
/// new actor key is minted, so a reader that silently rewrote an unfamiliar
/// `kind` into a familiar one would invalidate a signature it was only passing
/// through (ADR 0015's evolution rule, in its strictest form).
public enum DeviceKind: Codable, Equatable, Hashable, Sendable {
    case mac
    case phone
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "mac": self = .mac
        case "phone": self = .phone
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .mac: return "mac"
        case .phone: return "phone"
        case .unknown(let raw): return raw
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One device, as it describes itself: `.maugham/devices/<authorFingerprint>.json`,
/// signed by that device's own **author** key.
///
/// This is what lets a reader verify the assistant's seal on some other Mac as
/// *that Mac's assistant* rather than as a stranger — the actor keys are listed
/// here, under a fingerprint the author's signature vouches for, so admitting a
/// device admits every actor it lists (spec §4.4).
public struct DeviceRecord: RegistryRecordProtocol {
    /// The device's author-key fingerprint. Also its filename.
    public let device: String
    public let name: String
    public let kind: DeviceKind
    /// `DeviceActor.rawValue` → that actor's key fingerprint. A `[String: String]`
    /// rather than a keyed-by-enum dictionary because this is a wire format:
    /// an actor a later build adds must survive a read here unchanged.
    public let actors: [String: String]
    public let madeAt: Date
    /// Set by the device itself when it retires (spec §5). Its past stays
    /// verified; its future seals are quarantined.
    public let retiredAt: Date?
    public var sig: OpLogChain.Credentials?

    public init(
        device: String, name: String, kind: DeviceKind,
        actors: [String: String], madeAt: Date,
        retiredAt: Date? = nil, sig: OpLogChain.Credentials? = nil
    ) {
        self.device = device
        self.name = name
        self.kind = kind
        self.actors = actors
        self.madeAt = madeAt
        self.retiredAt = retiredAt
        self.sig = sig
    }

    public var fingerprint: String { device }
    public var expectedSigner: String { device }
    public static var directory: RegistryDirectory { .devices }

    /// This device's actor keys as a set — the record's own answer, before any
    /// question of trust.
    public var actorFingerprints: Set<String> {
        Set(actors.values).union([device])
    }
}

// MARK: - Person record (spec §2.2)

/// One admitted person: `.maugham/people/<personFingerprint>.json`.
///
/// The **root**'s record is self-signed (`admittedBy == person`); every other
/// record is signed by the root's author key, which is the whole admission
/// mechanism. `role` is written `"author"` for everyone and read by nothing
/// until P3 adds `reviewer` and the per-op-kind check.
public struct PersonRecord: RegistryRecordProtocol {
    public let person: String
    /// The author's word for this person — the name a surface shows.
    public let label: String
    /// The device's own name at admission, shown as `<label> (<ownName>)`
    /// wherever the two differ.
    public let ownName: String
    public let role: String
    public let admittedAt: Date
    /// The root that admitted them; equal to `person` on a root's own record.
    public let admittedBy: String
    public let revokedAt: Date?
    public let revokedBy: String?
    /// The highest opId this root had applied from that device when it revoked
    /// them — the line between "before revocation" and "after" (spec §5).
    public let highestOpIdSeen: String?
    public var sig: OpLogChain.Credentials?

    public init(
        person: String, label: String, ownName: String, role: String = "author",
        admittedAt: Date, admittedBy: String,
        revokedAt: Date? = nil, revokedBy: String? = nil,
        highestOpIdSeen: String? = nil, sig: OpLogChain.Credentials? = nil
    ) {
        self.person = person
        self.label = label
        self.ownName = ownName
        self.role = role
        self.admittedAt = admittedAt
        self.admittedBy = admittedBy
        self.revokedAt = revokedAt
        self.revokedBy = revokedBy
        self.highestOpIdSeen = highestOpIdSeen
        self.sig = sig
    }

    public var fingerprint: String { person }
    /// A root vouches for itself; everyone else is vouched for by the root they
    /// name. Either way the expected signer is stated by the record, and the
    /// reader additionally requires that a non-self signer BE a verified root.
    public var expectedSigner: String { admittedBy }
    public static var directory: RegistryDirectory { .people }

    /// Self-signed: this person is a root of this project's registry.
    public var isRoot: Bool { admittedBy == person }

    public var isRevoked: Bool { revokedAt != nil }
}

// MARK: - Claim record (spec §2.3)

/// A new root's record of adopting history it could not verify:
/// `.maugham/people/claims/<newRootFingerprint>.json`, signed by the new root.
///
/// It has no cryptographic authority over the old chain and does not pretend to
/// (parent spec §4.7). It exists so that history stays attributed and every
/// surviving device can say *a new Mac claimed this book on 9 Sep*.
public struct ClaimRecord: RegistryRecordProtocol {
    public let newRoot: String
    public let adopted: [String]
    public let claimedAt: Date
    public var sig: OpLogChain.Credentials?

    public init(
        newRoot: String, adopted: [String], claimedAt: Date,
        sig: OpLogChain.Credentials? = nil
    ) {
        self.newRoot = newRoot
        self.adopted = adopted
        self.claimedAt = claimedAt
        self.sig = sig
    }

    public var fingerprint: String { newRoot }
    public var expectedSigner: String { newRoot }
    public static var directory: RegistryDirectory { .claims }
}
