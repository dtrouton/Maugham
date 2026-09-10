import Foundation

/// What one seal's key is to THIS device.
///
/// Six words, because the reader has six genuinely different things to do with
/// a line: apply it as its own (`mine`), apply it as somebody's (`admitted`),
/// HOLD it until the writer says (`stranger` — pending, spec §3), quarantine it
/// by opId (`revoked`), quarantine it as another claimant's (`otherRoot`), or
/// fall back to P1 and apply it as unsigned history because there is no chain
/// to judge by (`noChain`, decision B3).
///
/// The payloads are the fingerprints a surface needs to name somebody: a person
/// for the two admitted states, the device record naming the key for a stranger
/// (nil when nothing on disk describes it), the claimant's own root for
/// `otherRoot`.
public enum TrustVerdict: Equatable, Hashable, Sendable {
    /// One of this device's own actor keys.
    case mine
    /// An actor key of a device admitted under this device's root.
    case admitted(person: String)
    /// A key this device's chain says nothing about. Held, not quarantined.
    case stranger(device: String?)
    /// Admitted, then revoked. `highestOpIdSeen` is the line between what the
    /// root had already applied and what arrived after (spec §5).
    case revoked(person: String, highestOpIdSeen: String?)
    /// A second self-signed root, or anyone it admitted. Listed, never merged.
    case otherRoot(root: String)
    /// This device belongs to no chain here, so it judges nobody (B3).
    case noChain
}

/// Who this device trusts in one project, resolved once from a verified
/// registry and this device's own keys.
///
/// **It answers verdicts and counts nothing.** How many lines are pending from
/// which device is the WALK's question (the reader that classifies each line);
/// a table that counted would have to be rebuilt whenever a file grew, and it
/// is rebuilt only when the registry changes.
///
/// **Pure.** No I/O, no clock, no `LocalIdentities.current`: every input is an
/// argument, which is what lets every arm below be pinned as a value.
public struct TrustTable: Equatable, Sendable {

    /// The root whose chain this device judges by, or `nil` — decision B3's
    /// *no chain*, in which every foreign key answers `.noChain`.
    ///
    /// The caller persists this as the cache's `joinedRoot` (B1: joined once,
    /// stays) and hands it back on the next resolve.
    public let myRoot: String?

    /// This device's own actor keys.
    private let mine: Set<String>
    /// Actor key → the device record that names it. One hop, spelled once.
    private let deviceByActorKey: [String: String]
    /// Person fingerprint → the record, for the revoked/admitted split.
    private let personByFingerprint: [String: PersonRecord]
    /// Everyone under `myRoot`, transitively, the root included.
    private let myChain: Set<String>
    /// Person fingerprint → the OTHER root whose chain holds them.
    private let otherRootByMember: [String: String]

    // MARK: - Resolving

    /// Reads a verified registry as this device.
    ///
    /// **Which root is mine**, in order, and the order is the argument:
    ///
    /// 1. `joinedRoot`, when the caller remembers one. B1 — a device never
    ///    switches roots on its own, so a root once joined outranks everything
    ///    the folder says today.
    /// 2. A self-signed root record for one of MY keys. Under labels-only a
    ///    person is a device's author key, and a root record is signed by the
    ///    key it names — so a root record for my fingerprint is the one claim
    ///    in this registry that nobody else could have written. It therefore
    ///    outranks (3), which is merely somebody's assertion about me.
    /// 3. A root whose chain names one of my keys: somebody admitted this
    ///    device, and this is how the phone joins the Mac (spec §4.3).
    /// 4. Otherwise nil — no chain, and P1's behaviour (B3).
    ///
    /// Ties inside (2) and (3) are broken by fingerprint, so a registry that
    /// arrives in a different order answers the same.
    nonisolated public static func resolve(
        registry: Registry, mine: LocalIdentities, joinedRoot: String?
    ) -> TrustTable {
        // `fingerprints` ENUMERATES: it answers over the keys this device has
        // already written with and mints none. A read path must not mint.
        let myKeys = mine.fingerprints
        let roots = registry.roots.sorted { $0.person < $1.person }

        let myRoot: String? =
            joinedRoot
            ?? roots.first { myKeys.contains($0.person) }?.person
            ?? roots.first { !registry.chain(under: $0).isDisjoint(with: myKeys) }?.person

        var deviceByActorKey: [String: String] = [:]
        for device in registry.devices.sorted(by: { $0.device < $1.device }) {
            for key in device.actorFingerprints.sorted()
            where deviceByActorKey[key] == nil {
                deviceByActorKey[key] = device.device
            }
        }

        var personByFingerprint: [String: PersonRecord] = [:]
        for person in registry.people where personByFingerprint[person.person] == nil {
            personByFingerprint[person.person] = person
        }

        let myChain = myRoot.map { registry.chain(underRoot: $0) } ?? []

        var otherRootByMember: [String: String] = [:]
        for root in roots where root.person != myRoot {
            for member in registry.chain(under: root).sorted()
            where otherRootByMember[member] == nil && !myChain.contains(member) {
                otherRootByMember[member] = root.person
            }
        }

        return TrustTable(
            myRoot: myRoot, mine: myKeys, deviceByActorKey: deviceByActorKey,
            personByFingerprint: personByFingerprint, myChain: myChain,
            otherRootByMember: otherRootByMember)
    }

    // MARK: - Answering

    /// What the key that made this seal is to this device.
    ///
    /// The one mapping worth reading slowly is key → person. A seal is made by
    /// an ACTOR key; admission is granted to a PERSON; and under labels-only a
    /// person is a device's author key, which is the device record's own
    /// `device` field (the reader refuses a record whose `actors["author"]`
    /// says otherwise). So an actor key finds its device, and the device IS the
    /// person. A key no device record names might still be a person named
    /// directly — a root whose device record was never written — so it stands
    /// for itself.
    nonisolated public func verdict(forSealKey fingerprint: String) -> TrustVerdict {
        if mine.contains(fingerprint) { return .mine }
        guard myRoot != nil else { return .noChain }

        let device = deviceByActorKey[fingerprint]
        let person = device ?? fingerprint

        if myChain.contains(person) {
            if let record = personByFingerprint[person], record.isRevoked {
                return .revoked(person: person, highestOpIdSeen: record.highestOpIdSeen)
            }
            return .admitted(person: person)
        }
        if let claimant = otherRootByMember[person] {
            return .otherRoot(root: claimant)
        }
        return .stranger(device: device)
    }
}
