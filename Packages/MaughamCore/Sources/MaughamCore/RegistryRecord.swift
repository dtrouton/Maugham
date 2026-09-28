import Foundation

/// The records a project's registry is made of (P2 spec §2; P3 §3.2 adds the
/// permit event, which lives in `PermitEvent.swift`), and the one
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

/// Which of the registry's directories a record belongs to. A CASE rather
/// than a path, so the paths themselves live in exactly one file
/// (`RegistryWriter`) and a census can say so.
///
/// **The raw values are the folder names**, which is what lets
/// `MalformedRecord.ref` read a directory off a path rather than spelling one.
public enum RegistryDirectory: String, Sendable, CaseIterable {
    case devices
    case people
    case claims
    /// P3's history: one signed file per permit event (`PermitEvent`), under
    /// `people/events`. Fourth because it was added fourth — nothing orders
    /// these but declaration.
    case events
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
///
/// Its decoding is hand-written (a misshapen `personClaim` must not fail the
/// record), so a new field must be added both to `CodingKeys` — which the
/// synthesized encoding follows — and to `init(from:)`.
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
    /// *This device belongs to person key P* — signed by P over a form that
    /// names THIS record's `device` (`PersonClaim`, your devices are you).
    ///
    /// **Optional and omitted when nil** — the `PersonRecord.scope` pattern —
    /// so a record with no claim encodes to exactly the bytes a v0.41 build
    /// writes and signs. Whether it VERIFIES is never this record's validity:
    /// the reader answers it separately (`Registry.verifiedPersonClaims`).
    public let personClaim: PersonClaim?
    public var sig: OpLogChain.Credentials?

    public init(
        device: String, name: String, kind: DeviceKind,
        actors: [String: String], madeAt: Date,
        retiredAt: Date? = nil, personClaim: PersonClaim? = nil,
        sig: OpLogChain.Credentials? = nil
    ) {
        self.device = device
        self.name = name
        self.kind = kind
        self.actors = actors
        self.madeAt = madeAt
        self.retiredAt = retiredAt
        self.personClaim = personClaim
        self.sig = sig
    }

    /// **A new field goes in THREE places**: a property, a case here, and the
    /// hand-written `init(from:)` below. The compiler catches a property the
    /// decoder forgets to assign; it does NOT catch a missing case here — the
    /// synthesized `encode(to:)` follows these keys, so the field would
    /// silently never be written.
    private enum CodingKeys: String, CodingKey {
        case device, name, kind, actors, madeAt, retiredAt, personClaim, sig
    }

    /// The synthesized decoding in every field but one: a `personClaim` that
    /// is not a claim's SHAPE decodes as no claim rather than failing the
    /// record. A record that fails to decode is listed malformed, and a bad
    /// claim must never un-admit a device (your devices are you, Task 3). The
    /// signature is checked over the FILE's bytes, so what the file said about
    /// the claim is still covered by it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.decode(String.self, forKey: .device)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(DeviceKind.self, forKey: .kind)
        actors = try container.decode([String: String].self, forKey: .actors)
        madeAt = try container.decode(Date.self, forKey: .madeAt)
        retiredAt = try container.decodeIfPresent(Date.self, forKey: .retiredAt)
        personClaim = try? container.decodeIfPresent(PersonClaim.self, forKey: .personClaim)
        sig = try container.decodeIfPresent(OpLogChain.Credentials.self, forKey: .sig)
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
    /// `"book"` | `"pieces"` — whether this person writes the whole book or
    /// some pieces of it (P3 spec §3.1).
    ///
    /// **Absent on every P2-era record, and absent MEANS `"book"`** — what
    /// every one of them was written to mean. Optional rather than defaulted
    /// to a string for exactly that reason: a non-optional property would be
    /// encoded, and a P2 record re-signed by this build would then carry a key
    /// it did not carry when it was signed. Written as an explicit string
    /// whenever it is written at all, because a frozen signed format must not
    /// hang two opposite meanings on a missing key: *an author of some pieces
    /// with none yet* is a real state and is `"pieces"` with an empty list.
    public let scope: String?
    /// The document ids this person may write, meaningful under `"pieces"`
    /// alone. Absent on a P2-era record, and legitimately empty on a P3 one.
    public let pieces: [String]?
    public let admittedAt: Date
    /// The root that admitted them; equal to `person` on a root's own record.
    public let admittedBy: String
    public let revokedAt: Date?
    public let revokedBy: String?
    /// The highest opId this root had applied from that device when it revoked
    /// them — the line between "before revocation" and "after" (spec §5).
    public let highestOpIdSeen: String?
    /// **The person key this person owns** — its fingerprint
    /// (`PersonKey.fingerprint`), linked by the root so a later device whose
    /// record carries a verifying claim with this key can be recognised as
    /// theirs (your devices are you, Task 4).
    ///
    /// Absent on every record written before it, and absent means *no key is
    /// linked*: optional and omitted when nil, `scope`'s pattern, so no
    /// existing record's bytes move and a v0.41 build reads a linked record
    /// as it reads any other. Written and removed ONLY by
    /// `RegistryAdmission.linkPersonKey`/`forgetPersonKey`, which re-sign the
    /// file's object; `admit` carries it across the records it rewrites.
    public let personKey: String?
    /// **Person keys this person's record has FORGOTTEN** — fingerprints the
    /// root's Forget took off this record (your devices are you, Task 6; the
    /// controller's C2 ruling). Forget is durable because of this: a device
    /// already admitted still carries a claim with the key, and without a
    /// record of the Forget the next open would link it straight back.
    ///
    /// Read in two places and nowhere else: `RegistryAdmission.linkPersonKey`
    /// never links a key any record has forgotten, and `Recognition.recognise`
    /// treats a key forgotten anywhere in the chain as unknown. Written only by
    /// `forgetPersonKey`, in the same label-wide re-sign as the unlink; `admit`
    /// carries it across the records it rewrites. Omitted when nil, `scope`'s
    /// pattern, so no existing record's bytes move. Re-trusting a forgotten
    /// key is not a verb in plan 1.
    ///
    /// **Each entry is dated** (whole-branch review, Important 2): the spec
    /// asks for a History entry per Forget, and `TrustEvents.derive` reads it
    /// from here — `{key, at}` rather than a parallel date map, so the one
    /// question the chain asks (`hasForgotten`) stays one spelling over one
    /// list. Unreleased when the date was added, so no older shape is read.
    public let forgottenPersonKeys: [ForgottenPersonKey]?
    public var sig: OpLogChain.Credentials?

    public init(
        person: String, label: String, ownName: String, role: String = "author",
        scope: String? = nil, pieces: [String]? = nil,
        admittedAt: Date, admittedBy: String,
        revokedAt: Date? = nil, revokedBy: String? = nil,
        highestOpIdSeen: String? = nil, personKey: String? = nil,
        forgottenPersonKeys: [ForgottenPersonKey]? = nil,
        sig: OpLogChain.Credentials? = nil
    ) {
        self.person = person
        self.label = label
        self.ownName = ownName
        self.role = role
        self.scope = scope
        self.pieces = pieces
        self.admittedAt = admittedAt
        self.admittedBy = admittedBy
        self.revokedAt = revokedAt
        self.revokedBy = revokedBy
        self.highestOpIdSeen = highestOpIdSeen
        self.personKey = personKey
        self.forgottenPersonKeys = forgottenPersonKeys
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

    /// Has this record forgotten `key`? The one spelling of the question.
    public func hasForgotten(_ key: String) -> Bool {
        forgottenPersonKeys?.contains { $0.key == key } ?? false
    }
}

/// **One Forget, as a person record remembers it** — the key's fingerprint
/// and the day the root forgot it (whole-branch review, Important 2). The
/// root that forgot it is the record's own `admittedBy`: only that root may
/// re-sign the record (`RegistryAdmission.renameOutcome`), so the signature
/// already says whose act it was and nothing stores it twice.
public struct ForgottenPersonKey: Codable, Equatable, Hashable, Sendable {
    public let key: String
    public let at: Date

    public init(key: String, at: Date) {
        self.key = key
        self.at = at
    }
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
