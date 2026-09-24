import Foundation

/// A record on disk that this device cannot vouch for, and why.
///
/// It is **listed, never read**. A malformed record contributes nothing to the
/// registry — no person, no device, no claim, no permit event — because the
/// alternative is to
/// let anybody who can write the folder decide who is admitted. It is carried
/// out of the read so Integrity can show it (spec §6): a record silently
/// dropped is a trust decision nobody made.
public struct MalformedRecord: Equatable, Hashable, Sendable {
    public enum Reason: Equatable, Hashable, Sendable {
        /// The bytes are not a record of the shape this directory holds.
        case undecodable(String)
        /// A record with no signature at all is not a record (spec §2).
        case unsigned
        /// The file was renamed: its name is not the fingerprint it carries.
        /// The payload is the fingerprint the RECORD holds — the name on disk
        /// is the `url` beside it.
        case filenameMismatch(recordFingerprint: String)
        /// The signature does not hold together over these bytes — a flipped
        /// byte, or a record edited after it was signed.
        case signatureDoesNotVerify
        /// A valid signature, from the wrong key: not the device's own author
        /// key, not the root the record names.
        case signerIsNotTheExpectedKey(expected: String, found: String)
        /// A person admitted — or a chain adopted — by someone who is not a
        /// root of this registry. Anybody can sign; only a root admits, and
        /// only a root claims (P2b Task 2).
        case signerIsNotARoot(named: String)
        /// A device record whose `actors["author"]` is not the device itself
        /// (`nil` when it lists no author at all). The author key's fingerprint
        /// IS the device's identity, so a record naming another key there asks
        /// a reader to trust an actor the signer never vouched for as itself —
        /// and admitting a device admits every actor its record lists (spec
        /// §4.4), which is what makes this worth refusing rather than ignoring.
        case authorActorIsNotTheDevice(named: String?)
        /// A record for a fingerprint this device already verified, signed by
        /// a DIFFERENT key than the one that signed the copy it remembers.
        ///
        /// Not a fault in the file — it is a well-formed record on its own
        /// terms, which is precisely the danger. A person record's expected
        /// signer is the root it NAMES, so another root can write a valid
        /// admission of somebody this device already knows and, on the folder's
        /// word alone, take over their record and the whole chain hanging off
        /// it. A record changes hands only under the same key; anything else is
        /// a claim, and a claim is listed (`RegistryCache.reconcile`, spec §2.4
        /// P4, B1).
        case signerChanged(expected: String, found: String)
        /// **A permit event whose signer was not entitled to make it** (P3
        /// spec §3.2).
        ///
        /// A well-formed, correctly signed record — which is exactly the
        /// danger, and why it is refused rather than read. An event is what a
        /// later reader judges somebody's lines by, so anybody who can write
        /// the folder and mint a key could otherwise promote themselves to
        /// author of the whole book and have every device apply what they
        /// wrote. The entitlement is one of two things and never anything
        /// else: a root of the chain the subject is on, or — for a retirement
        /// — the subject itself, which is what `retire` already is.
        ///
        /// Separate from `.signerIsNotARoot`, which is about a root that does
        /// not exist here at all: this one also catches a real root of this
        /// registry signing about somebody in ANOTHER root's chain, and a
        /// retirement signed by a Mac that is not the one retiring.
        case eventSignerHasNoAuthority(kind: String, subject: String, signer: String)
        /// **A permit event that would make a root anything but an author of
        /// the whole book** (P3 spec §2).
        ///
        /// The root alone admits, revokes and changes a permit, and a book must
        /// not end up with no author — so the root's own permit is not a thing
        /// that changes. An event saying otherwise is correctly signed by a key
        /// entitled to sign about that subject (a root may write about itself,
        /// since a root record names itself as its admitter), which is what
        /// makes it worth refusing by name rather than leaving to the
        /// entitlement check: it is the one well-formed file that could talk
        /// this book out of having an author at all.
        ///
        /// Refused rather than held pending, which is the opposite of the rule
        /// for an unrecognised role elsewhere. A root's permit is already the
        /// maximum permit — there is nothing a later build could widen it to —
        /// so the cautious answer here is the loud one, and holding the root's
        /// own lines pending is the one case where caution costs the writer
        /// their own book.
        case eventDemotesARoot(kind: String, subject: String, role: String, scope: String)
        /// The bytes are not a JSON object, so there is nothing that could have
        /// been signed — the canonical form has no object to take a signature
        /// slot out of (`RegistryCanonicalError.notAJSONObject`).
        ///
        /// Near-unreachable through `load`, because `decode` runs first and
        /// answers such a file `.undecodable`. It is named anyway rather than
        /// folded into `.signatureDoesNotVerify`: *was changed after it was
        /// signed* is a sentence about somebody's edit, and this file was never
        /// a record at all (fix round 1, M7).
        case notAJSONObject

        /// One sentence a surface can print.
        public var sentence: String {
            switch self {
            case .undecodable(let underlying):
                return "isn't a record Maugham can read (\(underlying))"
            case .unsigned:
                return "carries no signature, so nothing vouches for it"
            case .filenameMismatch(let recordFingerprint):
                return "was renamed — it carries the fingerprint \(recordFingerprint)"
            case .signatureDoesNotVerify:
                return "was changed after it was signed"
            case .signerIsNotTheExpectedKey(let expected, let found):
                return "was signed by \(found), not by \(expected)"
            case .signerIsNotARoot(let named):
                return "was signed by \(named), who admits nobody here"
            case .authorActorIsNotTheDevice(let named):
                return named.map { "names \($0) as its own author key, which is another device" }
                    ?? "names no author key of its own"
            case .signerChanged(let expected, let found):
                return "is now signed by \(found), where this device verified \(expected)"
            case .eventSignerHasNoAuthority(let kind, let subject, let signer):
                return "records “\(kind)” for \(DeviceCode.short(subject)) over "
                    + "the signature of \(DeviceCode.short(signer)), who is not "
                    + "entitled to say so"
            case .eventDemotesARoot(let kind, let subject, let role, let scope):
                return "records “\(kind)” making \(DeviceCode.short(subject)) "
                    + "“\(role)” of “\(scope)”, where the Mac this book was "
                    + "started on is an author of the whole book"
            case .notAJSONObject:
                return "isn't a record at all — its bytes are not a JSON object"
            }
        }
    }

    public let url: URL
    public let reason: Reason

    public init(url: URL, reason: Reason) {
        self.url = url
        self.reason = reason
    }

    /// Which record this FILE stands in the place of — where it sits and what
    /// it is named — or nil when it is not in one of the registry's
    /// directories at all.
    ///
    /// The one thing a malformed listing still says for certain is that a file
    /// is THERE. `RegistryCache.reconcile` asks it for exactly that: a record
    /// it remembers and the folder no longer verifies must be left alone,
    /// because a device cannot tell *tampered with* from *written by a later
    /// build*, and restoring over it would silently downgrade a newer device's
    /// signed record. Only an ABSENT file is restored.
    ///
    /// Named by the FILE rather than by what the bytes claim: a renamed record
    /// (`.filenameMismatch`) occupies the name on disk, and the fingerprint it
    /// carries has no file of its own.
    ///
    /// The directory is read off the path rather than re-spelled: every
    /// `RegistryDirectory` case is named exactly as its folder is, so
    /// this asks the same enum `RegistryWriter.directoryURL` builds from and
    /// cannot become a second opinion about where a record lives.
    public var ref: RecordRef? {
        guard let directory = RegistryDirectory(
            rawValue: url.deletingLastPathComponent().lastPathComponent)
        else { return nil }
        return RecordRef(
            directory: directory,
            fingerprint: url.deletingPathExtension().lastPathComponent)
    }
}

extension MalformedRecord {

    /// The listing for a record whose file is PRESENT and whose signature holds
    /// — but under a key other than the one that signed the copy this device
    /// verified (`RegistryCache.reconcile`, spec §2.4 P4).
    ///
    /// It is minted here rather than at the point that decides it, because
    /// naming a record's file is `RegistryWriter`'s one spelling and this is the
    /// file that may ask for it (tripwire 40). The cache decides WHETHER; where
    /// the file is stays one answer.
    nonisolated static func signerChanged(
        _ ref: RecordRef, expected: String, found: String, in projectURL: URL
    ) -> MalformedRecord {
        MalformedRecord(
            url: RegistryWriter.url(
                ref.directory, fingerprint: ref.fingerprint, in: projectURL),
            reason: .signerChanged(expected: expected, found: found))
    }
}

/// Everything a project's registry says, once every signature has been checked:
/// the devices, the people, the claims, the permit events — and, separately,
/// what could not be vouched for.
///
/// It holds FACTS, not trust. Which root is this device's, who is pending and
/// who is revoked are `TrustTable`'s questions; this value is what it asks them
/// of.
public struct Registry: Equatable, Sendable {
    public let devices: [DeviceRecord]
    public let people: [PersonRecord]
    public let claims: [ClaimRecord]
    /// The permit history, oldest id first (P3 spec §3.2). Empty for every
    /// book written before P3 — and an empty history means *author, book, from
    /// the start* for everybody, which is what every P2 admission meant.
    public let events: [PermitEvent]
    public let malformed: [MalformedRecord]
    /// Each verified record's own bytes as they were on disk, by ref.
    ///
    /// Present because a record is not always something this build can write
    /// back: one from a later build carries a field it has no property for, and
    /// re-encoding it would rewrite another build's record into this one's
    /// vocabulary and break the signature it was passing through. The bytes are
    /// what was signed, so they are what a memory of this registry keeps
    /// (`RegistryCache`) and what a restore puts down.
    ///
    /// Empty on a registry built in memory rather than read from disk; a caller
    /// that finds no entry falls back to encoding the record it holds.
    public let sourceBytes: [RecordRef: Data]

    /// **Actor key fingerprint → the device that OWNS it** — the one answer to
    /// *whose key is this*, derived once here and asked by everything that
    /// needs it (fix round 2, the controller's ruling).
    ///
    /// Derived rather than passed: it is a function of `devices` alone — who
    /// is admitted, revoked or retired does not enter into it (fix round 3) —
    /// and two places computing it separately was the whole defect
    /// (`TrustTable`'s own loop and `device(withActorFingerprint:)` were each
    /// a first-wins scan of its own).
    public let actorKeyOwners: [String: String]

    public init(
        devices: [DeviceRecord] = [], people: [PersonRecord] = [],
        claims: [ClaimRecord] = [], events: [PermitEvent] = [],
        malformed: [MalformedRecord] = [],
        sourceBytes: [RecordRef: Data] = [:]
    ) {
        self.devices = devices
        self.people = people
        self.claims = claims
        self.events = events
        self.malformed = malformed
        self.sourceBytes = sourceBytes
        self.actorKeyOwners = Registry.resolveActorKeyOwners(devices: devices)
    }

    /// **Who owns each actor key, and what happens when two records claim one**
    /// (fix round 2; P3's reason for caring, P2's silent hazard).
    ///
    /// A device record is signed **once**, by its own author key, and its
    /// `actors` map is otherwise a list of unsigned strings: nothing in the
    /// format proves a record's holder possesses the `assistant`, `translator`
    /// or `maugham` fingerprints it lists. Before permits, a second record
    /// claiming somebody else's actor key cost a LABEL. Now it would decide
    /// which person's permit history a line is judged under — so the rule is
    /// stated here, once, in three clauses:
    ///
    /// 1. **The author slot is proven.** A device's author key IS its `device`
    ///    fingerprint and is the key that signed the record, so a fingerprint
    ///    that equals some verified record's `device` belongs to THAT device
    ///    and every other record's claim on it is ignored. This holds whatever
    ///    the owner's standing: a retired or revoked device still made that
    ///    signature, and its verdict is then computed about the right person.
    /// 2. **One claimant owns it.** A non-author key exactly one verified
    ///    record lists belongs to that record's device, **whatever its
    ///    standing**. A retired or revoked device keeps its own keys — that is
    ///    what makes its `.retired`/`.revoked` verdict land on the right
    ///    person, and it is P2's behaviour unchanged.
    /// 3. **Two or more claimants mean NOBODY, for good.** Such a key is absent
    ///    here, so it resolves to itself, answers `.stranger(device: nil)` and
    ///    is held PENDING. Nothing is applied under a guessed permit and
    ///    nothing is set aside.
    ///
    /// **Standing plays no part, and that is the amendment** (fix round 3,
    /// re-review). Letting only *standing* records contest looks like it cures
    /// the hostage — revoke the liar and the owner has its key back — but it is
    /// half of a two-sided rule, and the other half is worse than the thing it
    /// cures. Revoke or retire the OWNER and the liar becomes the sole standing
    /// claimant, so a line the revoked owner signs with that key resolves
    /// `.admitted(person: liar)` instead of `.revoked(person: owner, …)`: a
    /// revoked person's writing applied, under somebody else's name. The
    /// hostage costs AVAILABILITY (lines held, nothing lost); that costs
    /// INTEGRITY. Possession is unprovable from these records, so nothing here
    /// can tell the liar from the owner — therefore a disputed key is awarded
    /// to nobody, ever, and no later revocation or retirement moves it.
    ///
    /// It follows that ownership is a function of `devices` alone: who is
    /// admitted, revoked or retired does not enter into it.
    ///
    /// **Neutral for an honest book**: every key has exactly one claimant, and
    /// clause 3 never fires.
    ///
    /// The residual, stated rather than hidden: any admitted device can make
    /// another person's NON-author actor lines pending by listing that key, and
    /// revocation does not cure it. The lines are held — never lost, never
    /// misattributed. The cure is per-actor possession proofs in the device
    /// record, a format change filed with the signed-structure roadmap item.
    /// **The author key — the writer's own hand — can never be disputed**,
    /// because clause 1 is a signature rather than a claim.
    nonisolated private static func resolveActorKeyOwners(
        devices: [DeviceRecord]
    ) -> [String: String] {
        var owners: [String: String] = [:]

        // Clause 1, first and unconditionally: the signature decides.
        for device in devices { owners[device.device] = device.device }

        var claimants: [String: Set<String>] = [:]
        for device in devices {
            for key in device.actors.values where key != device.device {
                claimants[key, default: []].insert(device.device)
            }
        }

        for (key, claiming) in claimants {
            // Clause 1 again: an author slot outranks every claim on it.
            guard owners[key] == nil else { continue }
            // Clause 3 before clause 2: a dispute is never resolved, only a
            // sole claim is honoured.
            guard claiming.count == 1 else { continue }
            owners[key] = claiming.first
        }
        return owners
    }

    /// The self-signed person records: everyone who admitted themselves. More
    /// than one means more than one claimant — they are listed, never merged
    /// (decision B1).
    public var roots: [PersonRecord] { people.filter(\.isRoot) }

    /// **Does this key hold a root record here?** — the one test of *may this
    /// Mac let anybody in*. `RegistryAdmission.admit` refuses `.notARoot`
    /// without it, `RegistryPresence.admitRemembered` admits nobody without
    /// it, and the admission sheet asks nobody without it (P3c Task 9, Ruling
    /// AA): an ADMITTED Mac has a root to judge by (`TrustTable.myRoot`) but
    /// none of its own, and a question only a root can answer is not put to
    /// it. One spelling, so the three can never disagree about who is a root.
    public func holdsARootRecord(_ fingerprint: String) -> Bool {
        roots.contains { $0.person == fingerprint }
    }

    /// Every person admitted under this root, transitively, the root included.
    ///
    /// A revoked person is still IN the chain: revocation is a state of a
    /// member, not an absence, and the distinction is what lets the reader say
    /// *after revocation* about a late-arriving op instead of *a stranger's*.
    public func chain(under root: PersonRecord) -> Set<String> {
        chain(underRoot: root.person)
    }

    /// The same answer from a fingerprint, for a caller holding one. An
    /// unknown fingerprint has an empty chain — it is nobody's root here.
    public func chain(underRoot fingerprint: String) -> Set<String> {
        guard people.contains(where: { $0.person == fingerprint && $0.isRoot })
        else { return [] }

        var reached: Set<String> = [fingerprint]
        var frontier: [String] = [fingerprint]
        while let admitter = frontier.popLast() {
            for person in people
            where person.admittedBy == admitter && !person.isRoot {
                if reached.insert(person.person).inserted {
                    frontier.append(person.person)
                }
            }
        }
        return reached
    }

    /// Every key fingerprint that belongs to this device — its author key and
    /// each actor its record lists. Admitting a device admits all of them,
    /// because they ARE that device (spec §4.4); a device with no record has
    /// none we can vouch for.
    public func actorFingerprints(ofDevice fingerprint: String) -> Set<String> {
        guard let record = devices.first(where: { $0.device == fingerprint })
        else { return [] }
        return record.actorFingerprints
    }

    /// The device record that OWNS this key, if any — how a seal finds the
    /// device it was written on.
    ///
    /// `actorKeyOwners`' answer and nothing of its own, so this and
    /// `TrustTable`'s join cannot differ about whose a key is. It used to be a
    /// first-wins scan of its own, which is one of the two sites the fix-round-2
    /// ruling closed.
    public func device(withActorFingerprint fingerprint: String) -> DeviceRecord? {
        guard let owner = actorKeyOwners[fingerprint] else { return nil }
        return devices.first { $0.device == owner }
    }

    /// The person record for a fingerprint, if this registry holds one.
    public func person(_ fingerprint: String) -> PersonRecord? {
        people.first { $0.person == fingerprint }
    }

    /// Every fingerprint this book holds a person record for.
    public var knownPeople: Set<String> { Set(people.map(\.person)) }

    /// **Every key some verified device record NAMES**, whoever ends up owning
    /// it — the set `TrustTable.aDeviceRecordNames` answers from, spelled here
    /// because it is a fact about the registry and two derivations of it would
    /// be two opinions about which keys this book has heard of.
    public var keysNamedByADeviceRecord: Set<String> {
        devices.reduce(into: Set()) { $0.formUnion($1.actorFingerprints) }
    }

    /// **Is this key one two device records both claim?** (P3b Task 4.)
    ///
    /// `actorKeyOwners` awards a contested key to NOBODY, for good (rule 3
    /// above), and *nobody's* is not the same answer as *nothing here has
    /// heard of it*: a key no record mentions may perfectly well be an
    /// unadmitted person's own author key, which is exactly who the admission
    /// sheet is for. A contested one is the opposite — the register has an
    /// opinion and the opinion is that nobody may act on it — so it must never
    /// be offered as somebody to let in, and a writer who admitted it would be
    /// naming a key two machines claim.
    ///
    /// Both clauses are necessary in both directions: named-and-owned is an
    /// ordinary key (its device's, offered under its device), and unnamed is
    /// the stranger case P2b shipped.
    public func isContestedActorKey(_ fingerprint: String) -> Bool {
        keysNamedByADeviceRecord.contains(fingerprint)
            && actorKeyOwners[fingerprint] == nil
    }

    /// **Is a device holding lines back a STRANGER — somebody this book has no
    /// record of?** THE predicate behind every sentence that says *waiting for
    /// admission* (P3a Task 5's D5).
    ///
    /// P2 had one reason to hold a line and it was this one, so *held* and
    /// *waiting to be admitted* were the same fact and every surface could read
    /// `pendingByDevice` raw. P3a adds a second reason — a permit this build
    /// cannot judge (`Permit.Allowed.cannotJudge`) — and it reuses the same
    /// `Line.State.pending(device:)`, deliberately: it is the same STORAGE
    /// state, held and not refused, and a second arm would fork the walk, the
    /// tallies and every reader of them for a difference only the words turn
    /// on. So the words are what narrows, here, once.
    ///
    /// An admitted person whose line this build cannot judge is **not** waiting
    /// for admission — she is already in the book — and telling the writer to
    /// admit her would offer a sheet that would change nothing. Under P3a her
    /// line is held SILENTLY; P3b gives it a surface of its own.
    ///
    /// `AdmissionDecision.requests` asks this, and so does everything that
    /// counts or announces: `TrustTable.isStrangerDevice` is the same rule
    /// asked of the set this registry already handed the table.
    /// **And P3b adds a third reason**, which is the one this predicate has to
    /// exclude by SHAPE rather than by lookup: a line held because the file it
    /// is in is one no key can name (`UnsignedSnapshot`, after the first
    /// narrowing). It is held under `HeldLines.unsignedHolder`'s own string —
    /// never a fingerprint — so no person record could ever name it and this
    /// predicate would otherwise call every one of them a stranger and offer
    /// an Admit… sheet about a Mac that has no key to admit.
    public func isStrangerDevice(_ fingerprint: String) -> Bool {
        !HeldLines.isUnsignedHolder(fingerprint) && person(fingerprint) == nil
    }

    /// The admission-worded subset of a held-lines map: the devices with no
    /// person record, and their counts.
    public func strangersAwaitingAdmission(among held: [String: Int]) -> [String: Int] {
        held.filter { isStrangerDevice($0.key) }
    }

    /// The roots this root has ADOPTED — the fingerprints named in the claims
    /// it signed (spec §5, plan decision P2).
    ///
    /// **Directly, not transitively.** Adoption composes, but composing it is a
    /// decision about whose chain THIS device verifies, and that decision is
    /// `TrustTable`'s. This answers only what the folder says: these are the
    /// roots that root wrote down.
    ///
    /// **One-way, by construction.** A claim is signed by its own `newRoot`, so
    /// asking this of a root answers with what that root said about others and
    /// never with what others said about it — which is the whole of B1 at the
    /// level of a projection: nothing widens on somebody else's say-so.
    public func adopted(by root: String) -> Set<String> {
        Set(claims.filter { $0.newRoot == root }.flatMap(\.adopted))
    }
}

/// The one reader of the registry's four directories.
///
/// **What it refuses and what it merely lists.** A file it cannot verify is
/// listed in `Registry.malformed` and contributes nothing — the read carries
/// on, because one bad file must not cost a project its people. A file that is
/// PRESENT but cannot be READ throws (RULING-54): a permissions error or a
/// half-downloaded iCloud file would otherwise silently shrink the registry,
/// and a registry that shrinks silently is admission decided by accident.
public enum RegistryReader {

    nonisolated public static func load(
        projectURL: URL, presenter: NSFilePresenter? = nil
    ) throws -> Registry {
        var malformed: [MalformedRecord] = []
        // Every verified record's own file bytes, carried out with it. What
        // was signed and what a memory of this registry must restore are the
        // same bytes, and neither is anything this build could re-encode.
        var sourceBytes: [RecordRef: Data] = [:]
        func keep(_ record: some RegistryRecordProtocol, _ bytes: Data) {
            sourceBytes[RecordRef(directory: type(of: record).directory,
                                  fingerprint: record.fingerprint)] = bytes
        }

        // Devices vouch for themselves: each is signed by its own author key.
        var devices: [DeviceRecord] = []
        for url in try files(in: .devices, projectURL: projectURL) {
            let record: DeviceRecord
            let bytes: Data
            switch try decode(DeviceRecord.self, at: url, presenter: presenter) {
            case .malformed(let fault): malformed.append(fault); continue
            case .record(let decoded, let read): record = decoded; bytes = read
            }
            if let fault = verify(record, bytes: bytes, at: url) {
                malformed.append(fault); continue
            }
            devices.append(record)
            keep(record, bytes)
        }

        // People are read in two passes, because a non-root record is only a
        // record if a ROOT signed it — and which fingerprints are roots is not
        // known until every self-signed record has been verified.
        var candidates: [(url: URL, record: PersonRecord, bytes: Data)] = []
        for url in try files(in: .people, projectURL: projectURL) {
            switch try decode(PersonRecord.self, at: url, presenter: presenter) {
            case .malformed(let fault): malformed.append(fault)
            case .record(let decoded, let bytes): candidates.append((url, decoded, bytes))
            }
        }
        var people: [PersonRecord] = []
        var rootFingerprints: Set<String> = []
        for (url, record, bytes) in candidates where record.isRoot {
            if let fault = verify(record, bytes: bytes, at: url) {
                malformed.append(fault); continue
            }
            people.append(record)
            keep(record, bytes)
            rootFingerprints.insert(record.person)
        }
        for (url, record, bytes) in candidates where !record.isRoot {
            if let fault = verify(record, bytes: bytes, at: url) {
                malformed.append(fault); continue
            }
            guard rootFingerprints.contains(record.admittedBy) else {
                malformed.append(.init(
                    url: url, reason: .signerIsNotARoot(named: record.admittedBy)))
                continue
            }
            people.append(record)
            keep(record, bytes)
        }

        var claims: [ClaimRecord] = []
        for url in try files(in: .claims, projectURL: projectURL) {
            let record: ClaimRecord
            let bytes: Data
            switch try decode(ClaimRecord.self, at: url, presenter: presenter) {
            case .malformed(let fault): malformed.append(fault); continue
            case .record(let decoded, let read): record = decoded; bytes = read
            }
            if let fault = verify(record, bytes: bytes, at: url) {
                malformed.append(fault); continue
            }
            // A claim ADOPTS a chain — it widens whose history a device
            // verifies — so the rule that governs admission governs it too:
            // only a root claims. Without this, anybody who can write the
            // folder mints a key, signs a claim adopting the book's real root,
            // and every reader of that claim takes in the chain hanging off a
            // fingerprint nobody vouched for. Read after the people, because
            // which fingerprints are roots is not known until every self-signed
            // record has been verified.
            guard rootFingerprints.contains(record.newRoot) else {
                malformed.append(.init(
                    url: url, reason: .signerIsNotARoot(named: record.newRoot)))
                continue
            }
            claims.append(record)
            keep(record, bytes)
        }

        // Events are read LAST, for the reason the people are read in two
        // passes: whether an event's signer was entitled to make it is a
        // question about the chains, and the chains are not known until every
        // self-signed record has been verified. The partial registry below is
        // what that question is asked of — `roots` and `chain(underRoot:)` are
        // the answer this module already has, and a second walk here would be a
        // second opinion about who admitted whom.
        var events: [PermitEvent] = []
        let sofar = Registry(people: people)
        for url in try files(in: .events, projectURL: projectURL) {
            let record: PermitEvent
            let bytes: Data
            switch try decode(PermitEvent.self, at: url, presenter: presenter) {
            case .malformed(let fault): malformed.append(fault); continue
            case .record(let decoded, let read): record = decoded; bytes = read
            }
            if let fault = verify(record, bytes: bytes, at: url) {
                malformed.append(fault); continue
            }
            guard entitled(record, in: sofar) else {
                malformed.append(.init(url: url, reason: .eventSignerHasNoAuthority(
                    kind: record.kind.rawValue, subject: record.subject,
                    signer: record.by)))
                continue
            }
            // The second authority question, and the only one about the
            // SUBJECT rather than the signer: a root is an author of the whole
            // book unconditionally (`Permit.contradictsARoot`, which owns the
            // rule). Entitlement cannot catch this — `chain(underRoot:)`
            // includes the root itself, so a root writing about itself is
            // perfectly entitled, and the file it would write is the one that
            // leaves a book with no author.
            if sofar.person(record.subject)?.isRoot == true,
               Permit.contradictsARoot(record) {
                malformed.append(.init(url: url, reason: .eventDemotesARoot(
                    kind: record.kind.rawValue, subject: record.subject,
                    role: record.role, scope: record.scope)))
                continue
            }
            events.append(record)
            keep(record, bytes)
        }

        return Registry(
            devices: devices.sorted { $0.device < $1.device },
            people: people.sorted { $0.person < $1.person },
            claims: claims.sorted { $0.newRoot < $1.newRoot },
            events: events.sorted { $0.event < $1.event },
            malformed: malformed.sorted { $0.url.path < $1.url.path },
            sourceBytes: sourceBytes)
    }

    /// **Was `event`'s signer entitled to make it?** (P3 spec §3.2.)
    ///
    /// Two answers and no third. A **retirement** is the device's own word
    /// about itself — exactly what `RegistryAdmission.retire` already is — so
    /// the signer must BE the subject; a root retiring somebody else's Mac on
    /// their behalf is not a thing, and letting one through would give any root
    /// a way to say *she stopped writing on the 4th* about a Mac that did not.
    /// **Everything else** is the root's act, and it is the act that decides
    /// what a person may write, so the signer must be a root of the chain that
    /// person is on: a real root of this registry reaching into ANOTHER root's
    /// chain is refused here as firmly as a stranger is.
    ///
    /// The one softening is the write order the spec fixes — *the event, then
    /// the record* — which leaves a crash window in which an admission's event
    /// exists and its person record does not. A subject this registry holds no
    /// record for is that window: a root's word stands, because refusing it
    /// would make a one-step gap a permanent hole in the history. The moment a
    /// record exists, the chain is what decides.
    nonisolated private static func entitled(
        _ event: PermitEvent, in registry: Registry
    ) -> Bool {
        if case .retired = event.kind { return event.subject == event.by }
        guard registry.roots.contains(where: { $0.person == event.by }) else {
            return false
        }
        guard registry.person(event.subject) != nil else { return true }
        return registry.chain(underRoot: event.by).contains(event.subject)
    }

    // MARK: - One record

    /// The three checks every record answers on its own terms: it is named by
    /// the fingerprint it carries, it is signed, and the signature holds
    /// together over these exact bytes — the FILE's, canonicalized — under the
    /// key the record's own shape expects. Whether that key is TRUSTED is not
    /// asked here.
    nonisolated private static func verify(
        _ record: some RegistryRecordProtocol, bytes: Data, at url: URL
    ) -> MalformedRecord? {
        let named = url.deletingPathExtension().lastPathComponent
        guard named == record.fingerprint else {
            return .init(url: url,
                         reason: .filenameMismatch(recordFingerprint: record.fingerprint))
        }
        guard let credentials = record.sig else {
            return .init(url: url, reason: .unsigned)
        }
        // Over the FILE's bytes, never over a re-encode of what was decoded: a
        // record from a later build carries a field this one has no property
        // for, and hashing this build's vocabulary of it would refuse an honest
        // record (P2b Task 1).
        //
        // The two failures are kept apart: bytes that are not an object were
        // never a record, and saying *changed after it was signed* about one
        // would name an edit nobody made.
        let digest: String
        do { digest = try RegistryCanonical.digestHex(ofJSON: bytes) }
        catch { return .init(url: url, reason: .notAJSONObject) }
        guard OpLogChain.credentialsVerify(credentials, over: digest) else {
            return .init(url: url, reason: .signatureDoesNotVerify)
        }
        guard credentials.key == record.expectedSigner else {
            return .init(url: url, reason: .signerIsNotTheExpectedKey(
                expected: record.expectedSigner, found: credentials.key))
        }
        // A device is the one record that vouches for OTHER keys, and the
        // author entry is the one it cannot be wrong about: it is the key that
        // just signed. A record listing another device there would have a
        // reader trust actors on the strength of a signature that never
        // claimed them.
        if let device = record as? DeviceRecord,
           device.actors[DeviceActor.author.rawValue] != device.device {
            return .init(url: url, reason: .authorActorIsNotTheDevice(
                named: device.actors[DeviceActor.author.rawValue]))
        }
        return nil
    }

    /// Bytes → record, or the malformed listing that replaces it.
    ///
    /// The READ throws out of here rather than becoming a malformed listing:
    /// a file that cannot be read is not a file that says something wrong, and
    /// treating one as the other is exactly how a permissions error would
    /// quietly un-admit a device (RULING-54).
    nonisolated private static func decode<R: RegistryRecordProtocol>(
        _ type: R.Type, at url: URL, presenter: NSFilePresenter?
    ) throws -> Decoded<R> {
        let bytes = try readCoordinated(url: url, presenter: presenter)
        do {
            return .record(try RegistryCanonical.decoder().decode(R.self, from: bytes),
                           bytes: bytes)
        } catch {
            return .malformed(.init(url: url, reason: .undecodable(shortReason(error))))
        }
    }

    /// A record — **with the bytes it was read from** — or the listing that
    /// stands in for it. Not a `Result`, because a malformed record is not an
    /// error: it is a fact the registry carries.
    ///
    /// The bytes travel with the record for two reasons and both are about
    /// losing nothing. The signature is checked over them, so a field this
    /// build has no property for is still part of what was signed; and they are
    /// what `RegistryCache` remembers, so a record this build could not
    /// re-encode faithfully is still restored faithfully.
    private enum Decoded<R: RegistryRecordProtocol> {
        case record(R, bytes: Data)
        case malformed(MalformedRecord)
    }

    nonisolated private static func shortReason(_ error: Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _): return "no “\(key.stringValue)”"
        case .typeMismatch, .valueNotFound: return "a field is the wrong shape"
        case .dataCorrupted: return "the bytes aren't JSON"
        default: return error.localizedDescription
        }
    }

    // MARK: - Files

    /// The `.json` files in one registry directory, by name. An absent
    /// directory is not a failure (there is no registry yet); a directory that
    /// EXISTS and cannot be listed is, for RULING-54's reason.
    ///
    /// Skips by NAME only (`DotfileScan`) — the BSD hidden flag is not a fact
    /// about a file under `.maugham/` — and skips directories, which is how
    /// `people/claims/` survives being inside `people/`.
    nonisolated private static func files(
        in directory: RegistryDirectory, projectURL: URL
    ) throws -> [URL] {
        let dir = RegistryWriter.directoryURL(directory, in: projectURL)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        } catch {
            throw OpLogStore.ReadError.unreadableFile(
                name: dir.lastPathComponent, underlying: error.localizedDescription,
                kind: .registry)
        }
        return entries
            .filter { !DotfileScan.isDotfile($0) }
            .filter { $0.pathExtension == "json" }
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The coordinated read of one record's exact bytes. A present-but-
    /// unreadable file throws, by name — the op log's own rule and its own
    /// error, so the writer meets one sentence for one condition wherever
    /// Maugham reads a file it must not read only half of.
    ///
    /// `internal` rather than private since P2b Task 7: `RegistryWriter.resign`
    /// reads a record's file before editing its object, and a second spelling
    /// of *read one record's bytes* is a second answer to what a half-read
    /// registry file means.
    nonisolated static func readCoordinated(
        url: URL, presenter: NSFilePresenter?
    ) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var readError: Error?
        var bytes: Data?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            do { bytes = try Data(contentsOf: target) }  // adr-0018-ok: a signed registry record, never manuscript text
            catch { readError = error }
        }
        return try resolveRead(
            bytes: bytes, coordinationError: coordinationError,
            readError: readError, name: url.lastPathComponent)
    }

    /// What the coordinator's outcomes mean, as a decision with no file in it.
    ///
    /// Three of them, not two. The third — no bytes, no error, because the
    /// block never ran — is the one worth naming: answering it with empty bytes
    /// would make the record read as MALFORMED, and a device silently
    /// un-admitted by an accident is exactly the shape RULING-54 exists to
    /// forbid. A file that is there is read whole or refused by name.
    nonisolated static func resolveRead(
        bytes: Data?, coordinationError: NSError?, readError: Error?, name: String
    ) throws -> Data {
        if let failure = (coordinationError as Error?) ?? readError {
            throw OpLogStore.ReadError.unreadableFile(
                name: name, underlying: failure.localizedDescription, kind: .registry)
        }
        guard let bytes else {
            throw OpLogStore.ReadError.unreadableFile(
                name: name, underlying: "the read never ran", kind: .registry)
        }
        return bytes
    }
}
