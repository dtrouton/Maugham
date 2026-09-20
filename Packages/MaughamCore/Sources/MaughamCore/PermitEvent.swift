import Foundation

/// **The book's history of who could write what** (P3 spec §3.2).
///
/// The registry's other three records say what is true NOW: this device exists,
/// this person is admitted, this root adopted that chain. None of them can
/// answer the question P3 actually asks of a line — *was its signer allowed to
/// write this, at the moment they wrote it?* A record that is re-signed in place
/// forgets its own past, so a demotion would reach backwards through everything
/// that person ever wrote and a promotion would pardon what they wrote before
/// it. The history has to be its own, durable thing.
///
/// So: **one signed file per event**, under `.maugham/people/events/`. One file
/// because a shared append-only file across devices is tripwire 17 — iCloud's
/// reconciler cannot line-merge concurrent appends and drops the loser as a
/// conflict twin nobody opens. A file per event has no merge to get wrong.
///
/// **Who may sign one** is the whole of its authority and is checked by
/// `RegistryReader`, not here: a root of the chain the subject is on, except a
/// retirement, which a device signs for itself exactly as `retire` already does.
/// An event signed by anybody else is listed malformed and counts for nothing —
/// the ladder rests on that and on nothing else.
///
/// **Every field is a string or a collection of strings** (tripwire 42):
/// the serializer the canonical form goes through normalizes numbers, so a
/// number is not a safe thing to sign. `at` is a `Date` in memory and an
/// ISO8601 string on the wire — the encoding every other registry record
/// already uses, so the canonical path moves a string here too.
///
/// (This file names none of the three spellings `RegistryCanonical` owns, and
/// `RegistryCanonicalCensusTests` walks it by name, `Permit*` being in the
/// population since P3a.)
///
/// **Nothing in production writes one yet.** The verbs that do are the root's
/// (`RegistryAdmission`, tripwire 41); this task builds the record, the
/// directory, the reader's verification and the cache's memory of it.
public struct PermitEvent: RegistryRecordProtocol {

    // MARK: - What happened

    /// The eight things that can happen to somebody's permit.
    ///
    /// **Lossless about a value this build does not know** (ADR 0015, and the
    /// strict form `DeviceKind` takes): an event is a signed file that this
    /// build may one day pass through a cache restore, and a reader that
    /// silently rewrote an unfamiliar kind into a familiar one would either
    /// invalidate a signature it was only carrying or — far worse — decide
    /// somebody's permit from a kind nobody wrote. An unrecognised kind is
    /// PRESERVED and, per the global constraint, holds that person's lines
    /// pending rather than setting them aside: an older Mac must not quarantine
    /// what a newer one would apply.
    public enum Kind: Codable, Equatable, Hashable, Sendable {
        /// Admitted by the root, at a sheet the writer answered.
        case admitted
        /// Admitted without a sheet, because this writer has already said what
        /// this machine is called (`AdmissionMemory`). The one `TrustEvent.Kind`
        /// that had no writer at all until events existed.
        case silentlyAdmitted
        /// Author ⇄ reviewer.
        case roleChanged
        /// Whole book ⇄ some pieces, or the set of pieces itself.
        case scopeChanged
        /// Revoked, keeping what this Mac had already applied.
        case revoked
        /// Revoked with *Set Aside Everything* — the writer's second choice.
        case revokedEntirely
        /// Let back in after a revocation.
        case readmitted
        /// A device saying it has stopped writing. The one kind a device signs
        /// for itself.
        case retired
        /// A kind a later build wrote, carried through under its own name.
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "admitted": self = .admitted
            case "silentlyAdmitted": self = .silentlyAdmitted
            case "roleChanged": self = .roleChanged
            case "scopeChanged": self = .scopeChanged
            case "revoked": self = .revoked
            case "revokedEntirely": self = .revokedEntirely
            case "readmitted": self = .readmitted
            case "retired": self = .retired
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .admitted: return "admitted"
            case .silentlyAdmitted: return "silentlyAdmitted"
            case .roleChanged: return "roleChanged"
            case .scopeChanged: return "scopeChanged"
            case .revoked: return "revoked"
            case .revokedEntirely: return "revokedEntirely"
            case .readmitted: return "readmitted"
            case .retired: return "retired"
            case .unknown(let raw): return raw
            }
        }

        /// The eight this build knows — everything but `.unknown`. A caller
        /// enumerating kinds asks this rather than restating the list.
        public static let known: [Kind] = [
            .admitted, .silentlyAdmitted, .roleChanged, .scopeChanged,
            .revoked, .revokedEntirely, .readmitted, .retired,
        ]

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    // MARK: - Where the old permit stopped

    /// **One stream's position, as the root that made the event saw it** —
    /// defined in `PermitMark.swift` and spelled here for the record's own
    /// readers.
    ///
    /// The wire form of a mark, and no more than that: the digests of the whole
    /// segments the root had applied, and the `OpLogChain.lineHash` of the last
    /// line it applied. What they MEAN — which file is under the old permit and
    /// which under the new — is `PermitMark.judge`'s, and is deliberately not
    /// spelled on the record, so that the file this build reads and the rule a
    /// later one applies cannot become two opinions living in one type. A
    /// typealias rather than a second struct for the same reason (P3a Task 2).
    public typealias StreamMark = PermitMark.StreamMark

    // MARK: - The record

    /// This event's own id, and the name of its file: `<subject>.<ULID>`.
    ///
    /// Two parts, because both jobs matter. The subject prefix puts one
    /// person's events together in a directory listing; the ULID orders them
    /// and, being 26 characters of monotonic randomness, does not collide with
    /// the event the same root wrote a millisecond earlier.
    public let event: String
    public let kind: Kind
    /// The person (or, labels-only, the device) whose permit this is about.
    public let subject: String
    /// The role the subject has AFTER this event: `"author"` / `"reviewer"`.
    public let role: String
    /// The scope the subject has after this event: `"book"` / `"pieces"`.
    public let scope: String
    /// The pieces the subject may write, meaningful under `"pieces"` alone and
    /// legitimately empty — *she may write what she starts* is a real state.
    public let pieces: [String]
    /// Where the old permit stopped, per stream of the subject's. Empty on an
    /// event with nothing to divide: the first admission has no past.
    public let mark: [String: StreamMark]
    public let at: Date
    /// Who signed it. A root of the subject's chain, or — for `.retired` — the
    /// subject itself.
    public let by: String
    public var sig: OpLogChain.Credentials?

    public init(
        event: String, kind: Kind, subject: String,
        role: String = "author", scope: String = "book", pieces: [String] = [],
        mark: [String: StreamMark] = [:],
        at: Date, by: String, sig: OpLogChain.Credentials? = nil
    ) {
        self.event = event
        self.kind = kind
        self.subject = subject
        self.role = role
        self.scope = scope
        self.pieces = pieces
        self.mark = mark
        self.at = at
        self.by = by
        self.sig = sig
    }

    public var fingerprint: String { event }
    /// The signature must be `by`'s. That `by` was ENTITLED to make this event
    /// is a second question, and `RegistryReader` asks it: a root of the
    /// subject's chain, or the subject itself for a retirement.
    public var expectedSigner: String { by }
    public static var directory: RegistryDirectory { .events }

    /// Mint an id for a new event about `subject`.
    ///
    /// The one place the two-part shape is spelled, so `id(ofSubject:)` below
    /// can take it apart again without a second opinion about where the dot is.
    nonisolated public static func mintID(subject: String) -> String {
        "\(subject).\(ULID.generate())"
    }

    /// **An id for this subject that sorts strictly AFTER one they already
    /// have** (P3a Task 7, fix round 1).
    ///
    /// `mintID(subject:)` reads the clock, and a ULID is monotonic within a
    /// PROCESS only. A Mac relaunched after its clock stepped back — a manual
    /// correction, an NTP jump, a VM resumed from a snapshot — mints an id
    /// that sorts BEFORE yesterday's, and everything that reads this history
    /// in order then reads it wrong: `PermitTimeline` would put an older
    /// permit last, and the revocation mark would be taken from the wrong
    /// event. Neither fails loudly; both decide what a reader APPLIES.
    ///
    /// So the writer checks, and where the fresh id does not sort after, it
    /// mints one a millisecond past the latest. The timestamp is the first ten
    /// characters of a 26-character ULID, so a strictly greater millisecond is
    /// a strictly greater id whatever the random half says.
    ///
    /// An `existing` id this build cannot parse — a later build's shape — is
    /// answered with an ordinary fresh id: there is nothing to step past that
    /// can be computed, and inventing one would be worse than the clock.
    nonisolated public static func mintID(subject: String, after existing: String) -> String {
        guard let dot = existing.lastIndex(of: "."),
              let millis = ULID.timestampMillis(
                  of: String(existing[existing.index(after: dot)...]))
        else { return mintID(subject: subject) }
        return "\(subject).\(ULID.generate(atMillis: millis + 1))"
    }

    /// The subject an event id names, or nil if it is not of that shape. A
    /// convenience for a surface listing a folder; the record's own `subject`
    /// is the truth, and the reader checks the two agree about nothing — the id
    /// is a filename, not a claim.
    nonisolated public static func subject(ofID id: String) -> String? {
        guard let dot = id.lastIndex(of: "."), dot != id.startIndex else { return nil }
        return String(id[id.startIndex..<dot])
    }
}
