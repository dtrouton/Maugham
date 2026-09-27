import Foundation

/// What a device's claim told us about itself, for a sheet that must still ask
/// (your devices are you, Task 5). A HINT and nothing more: nothing here is
/// identity, and `personName` is whatever the claim's key item was called —
/// anybody can mint a key named "Denver Trouton".
public struct ClaimHint: Equatable, Hashable, Sendable {
    /// The name the verified claim carries — the device's own word for whose
    /// it is. May be empty.
    public let personName: String
    /// The device record's own name.
    public let deviceName: String
    /// The claim's key is already linked to somebody this device will not
    /// silently admit it as — another label, another root's record, or a
    /// revoked one — so the sheet says the key is linked elsewhere.
    public let linkedElsewhere: Bool

    public init(personName: String, deviceName: String, linkedElsewhere: Bool) {
        self.personName = personName
        self.deviceName = deviceName
        self.linkedElsewhere = linkedElsewhere
    }
}

/// **May the root's Mac admit this newly seen device WITHOUT asking?** — the
/// one pure decision (spec *Your devices are you*, "The decision").
///
/// A wrong `.ownDevice` or `.knownPerson` is a stranger admitted silently, so
/// every answer that is not provably one of those two is `.ask`: the cost of a
/// wrong `.ask` is one sheet, the cost of a wrong silent answer is the book.
///
/// It decides WHO, never WHAT they may write: it reads no permit rung and no
/// record's `role`/`scope`/`pieces` (tripwires 43, 47). It returns records, and
/// the caller admits `.ownDevice` with the root's own standing (PK-2) and
/// `.knownPerson` with that person's CURRENT permit, read from the timeline.
public enum Recognition: Equatable, Sendable {
    /// The claim's key is the root's own person's: admit under the root's
    /// label. Carries the root's record.
    case ownDevice(root: PersonRecord)
    /// The claim's key is linked to exactly one other person (one LABEL) this
    /// root admitted, none of whose key-holding records is revoked. Carries a
    /// representative record of that person — see `recognise`.
    case knownPerson(PersonRecord)
    /// Ask the writer. The hint is nil where there is no verified claim.
    case ask(hint: ClaimHint?)

    /// The decision, as a table (a person is a LABEL — `TrustTable.sharesLabel`
    /// — so one key legitimately sits on several records of one person):
    ///
    /// | Condition, checked in this order | Answer |
    /// |---|---|
    /// | no claim, or `verifiedClaim` is not `registry.verifiedPersonClaims[device]` | `.ask(nil)` |
    /// | the device record passed is not the one the registry verified | `.ask(nil)` |
    /// | `thisRoot` holds no root record here | `.ask(hint)` |
    /// | the device already has a person record (the caller filters these) | `.ask(hint)` |
    /// | the device is retired | `.ask(hint)` |
    /// | any person record is present but unreadable (RULING-54) | `.ask(hint)` |
    /// | nobody holds the key | `.ask(hint)` |
    /// | a record of this chain has FORGOTTEN the key (C2) | `.ask(hint)` |
    /// | (a holder outside this book's chain is IGNORED — it neither helps nor blocks) | — |
    /// | the holders span more than one label (an empty label is its own) | `.ask(hint, linkedElsewhere)` |
    /// | the holders include the root record or share the root's label, and the claim names another person (Review Focus 3) | `.ask(hint, linkedElsewhere)` |
    /// | the holders include the root record or share the root's label | `.ownDevice(root)` |
    /// | the holders' one label has no name | `.ask(hint)` |
    /// | every record of that label in the chain is revoked | `.ask(hint, linkedElsewhere)` |
    /// | the claim's name names another person (Review Focus 3) | `.ask(hint, linkedElsewhere)` |
    /// | otherwise | `.knownPerson(representative)` |
    ///
    /// **Only records this book's chain vouches for count as holders** — this
    /// root's and every root it adopted, `TrustTable.myChain`'s rule, asked of
    /// `TrustTable.chain(ofRoot:in:)` so the two cannot differ. An adopted root
    /// is this root's own act (a claim it signed), and the table already
    /// applies every line such a record's devices write. A record a
    /// NON-adopted root signed is that root's say-so: a foreign root can
    /// self-sign a record under ANY label with ANY key — including this root's
    /// label with a key it generated — so a key found on one is never
    /// evidence, and (Task 6 fix round, controller ruling) never an obstacle
    /// either: it is ignored, exactly as if the record were not there.
    ///
    /// **Revoked records neither help nor block** (controller ruling, fix
    /// round 1). Revoking a device says that device is gone, not that the key
    /// is compromised — Forget is the verb for that. So a person stands while
    /// any record of their label in the chain stands; the root always stands,
    /// so a revoked record under the root's label never blocks `.ownDevice`;
    /// every record of another label revoked is `.ask`.
    ///
    /// **The representative** is the lowest-fingerprint STANDING holder (the
    /// record the root actually linked), else the lowest-fingerprint standing
    /// record of the label — `otherPersonHolding`'s convention, so two runs
    /// name the same record, and never a revoked one, whose timeline would be
    /// the wrong permit.
    ///
    /// The claim is taken from the caller only as the registry's own verified
    /// answer: a claim that is not `registry.verifiedPersonClaims[device]` is
    /// treated as no claim, so a raw `DeviceRecord.personClaim` passed here by
    /// mistake can never be trusted.
    nonisolated public static func recognise(
        device: DeviceRecord,
        verifiedClaim: PersonClaim?,
        registry: Registry,
        thisRoot: String
    ) -> Recognition {
        // Named sub-expressions: the type-checker flagged the combined guard.
        guard let claim = verifiedClaim else { return .ask(hint: nil) }
        let registrysClaim: PersonClaim? = registry.verifiedPersonClaims[device.device]
        let registrysRecord: DeviceRecord? = registry.devices.first { $0.device == device.device }
        let claimIsVerified: Bool = registrysClaim == claim
        let recordIsVerified: Bool = registrysRecord == device
        guard claimIsVerified, recordIsVerified else { return .ask(hint: nil) }

        let hint = ClaimHint(
            personName: claim.name, deviceName: device.name, linkedElsewhere: false)
        let elsewhere = ClaimHint(
            personName: claim.name, deviceName: device.name, linkedElsewhere: true)

        guard registry.holdsARootRecord(thisRoot),
              let root = registry.person(thisRoot), root.isRoot
        else { return .ask(hint: hint) }

        // Already somebody here (admitted, revoked or itself a root): not a
        // question for silent admission — a revoked device must never come
        // back in on a claim.
        let unreadable = RegistryAdmission.unreadablePeople(in: registry)
        guard registry.person(device.device) == nil, !unreadable.contains(device.device)
        else { return .ask(hint: hint) }

        guard device.retiredAt == nil else { return .ask(hint: hint) }

        // Present-but-unreadable is not absent (RULING-54): an unreadable person
        // record might be the key's holder, so nobody can be sure it is not.
        guard unreadable.isEmpty else { return .ask(hint: hint) }

        // **A forgotten key is nobody's** (Task 6, C2): a record anywhere in
        // this book's chain that Forget took the key off makes it unknown, so
        // every device carrying it is asked about again — which is what
        // Forget, the answer to a compromised Apple ID, promises.
        let chain = TrustTable.chain(ofRoot: thisRoot, in: registry)
        let forgotten = registry.people.contains {
            chain.contains($0.person) && $0.hasForgotten(claim.personKey)
        }
        guard !forgotten else { return .ask(hint: hint) }

        // Only records this book's chain vouches for are evidence — this root's
        // and every root it adopted, `TrustTable.myChain`'s rule exactly. A
        // holder OUTSIDE the chain is IGNORED (Task 6 fix round, controller
        // ruling), never a reason to ask: a foreign self-signed root can write
        // any key's fingerprint on a record, and letting that turn an answer
        // into a question is the same denial the forgotten-key rule would be.
        let holders = registry.people.filter {
            chain.contains($0.person) && $0.personKey == claim.personKey
        }
        guard let first = holders.first else { return .ask(hint: hint) }
        let oneLabel = holders.count == 1
            || holders.allSatisfy { TrustTable.sharesLabel($0.label, first.label) }
        guard oneLabel else { return .ask(hint: elsewhere) }

        let holdersIncludeRoot = holders.contains { $0.person == root.person }
        if holdersIncludeRoot || TrustTable.sharesLabel(first.label, root.label) {
            // The root's own record never is revoked, so a revoked record
            // under the root's label (a lost phone) neither helps nor blocks.
            let excluded = Set(holders.map(\.person)).union([root.person])
            let contradicted = claimNamesAnotherPerson(
                claim, label: root.label, excluding: excluded, chain: chain,
                in: registry)
            guard !contradicted else { return .ask(hint: elsewhere) }
            return .ownDevice(root: root)
        }

        // An unnamed record shares a label with nobody, so a new device can
        // never be "the same person" as it.
        guard TrustTable.sharesLabel(first.label, first.label)
        else { return .ask(hint: hint) }

        // Revoking a device says that device is gone, not that the key is
        // compromised (Forget is that verb): the person stands while ANY record
        // of their label in the chain stands. Every one revoked → ask.
        let standing = registry.people.filter {
            chain.contains($0.person) && !$0.isRevoked
                && TrustTable.sharesLabel($0.label, first.label)
        }
        guard !standing.isEmpty else { return .ask(hint: elsewhere) }

        let contradicted = claimNamesAnotherPerson(
            claim, label: first.label, excluding: Set(holders.map(\.person)),
            chain: chain, in: registry)
        guard !contradicted else { return .ask(hint: elsewhere) }

        // The representative: a standing HOLDER if any (the record the root
        // actually linked), else a standing record of the label; lowest
        // fingerprint either way.
        let standingHolders = standing.filter { $0.personKey == claim.personKey }
        let pool = standingHolders.isEmpty ? standing : standingHolders
        guard let representative = pool.min(by: { $0.person < $1.person })
        else { return .ask(hint: hint) }
        return .knownPerson(representative)
    }

    /// **Does the claim NAME somebody other than the person its key is linked
    /// to?** (Review Focus 3.) The key decides identity and the name never
    /// does — but a claim signed by a key linked to Sam that calls itself
    /// Denver is a contradiction the book cannot resolve: it is Denver's key
    /// mislinked, or a key item renamed, and either way a silent admission
    /// would put one person's writing under the other's name. So it is asked.
    ///
    /// "Names somebody else" is exact, `sharesLabel`'s rule: the claim's name
    /// equals the label of a verified record outside the key's person (and
    /// outside `excluding`), or the name on that record's device's own
    /// verified claim. Only records of this chain count (Task 6 fix round):
    /// a foreign root could otherwise name itself after the claim and turn
    /// every one of this writer's devices into a question.
    nonisolated private static func claimNamesAnotherPerson(
        _ claim: PersonClaim, label: String,
        excluding: Set<String>, chain: Set<String>, in registry: Registry
    ) -> Bool {
        let claimed = claim.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claimed.isEmpty else { return false }
        return registry.people.contains { other in
            guard chain.contains(other.person),
                  !excluding.contains(other.person),
                  !TrustTable.sharesLabel(other.label, label)
            else { return false }
            return TrustTable.sharesLabel(other.label, claimed)
                || registry.verifiedPersonClaims[other.person]?.name
                    .trimmingCharacters(in: .whitespacesAndNewlines) == claimed
        }
    }
}
