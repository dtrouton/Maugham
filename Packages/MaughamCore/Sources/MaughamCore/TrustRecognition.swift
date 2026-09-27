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
    /// | a holder was admitted by another root | `.ask(hint, linkedElsewhere)` |
    /// | the holders span more than one label (an empty label is its own) | `.ask(hint, linkedElsewhere)` |
    /// | any holder is revoked | `.ask(hint, linkedElsewhere)` |
    /// | the holders share the root's label, or include the root record | `.ownDevice(root)` |
    /// | ...and the claim's name names another person (Review Focus 3) | `.ask(hint, linkedElsewhere)` |
    /// | the holders' one label has no name | `.ask(hint)` |
    /// | the claim's name names another person (Review Focus 3) | `.ask(hint, linkedElsewhere)` |
    /// | otherwise | `.knownPerson(lowest-fingerprint holder)` |
    ///
    /// **Only this root's own records count as holders.** A record another
    /// root signed is that root's say-so, and a foreign root can self-sign a
    /// record under ANY label with ANY key — including this root's label with
    /// a key it generated — so a key found on one is linked elsewhere, never
    /// evidence.
    ///
    /// **A revoked holder poisons the key**, whether or not the label keeps
    /// another standing record: a key the root linked to a device it then
    /// revoked may have left with that device, and must not bring new devices
    /// in silently. (Stricter than "every record of the label revoked", which
    /// it subsumes: a standing holder is a standing record of the label.)
    ///
    /// **The representative** is the unrevoked holder with the lowest person
    /// fingerprint — `otherPersonHolding`'s convention, so two runs name the
    /// same record. A HOLDER rather than any record of the label, because the
    /// holder is the record the root actually linked this key to.
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
        guard let claim = verifiedClaim,
              registry.verifiedPersonClaims[device.device] == claim,
              registry.devices.first(where: { $0.device == device.device }) == device
        else { return .ask(hint: nil) }

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
        guard registry.person(device.device) == nil,
              !RegistryAdmission.unreadablePeople(in: registry).contains(device.device)
        else { return .ask(hint: hint) }

        guard device.retiredAt == nil else { return .ask(hint: hint) }

        // Present-but-unreadable is not absent (RULING-54): an unreadable person
        // record might be the key's holder, so nobody can be sure it is not.
        guard RegistryAdmission.unreadablePeople(in: registry).isEmpty
        else { return .ask(hint: hint) }

        let holders = registry.people.filter { $0.personKey == claim.personKey }
        guard let first = holders.first else { return .ask(hint: hint) }

        guard holders.allSatisfy({ $0.admittedBy == thisRoot }) else {
            return .ask(hint: elsewhere)
        }
        let oneRecord = holders.count == 1
        guard oneRecord || holders.allSatisfy({ TrustTable.sharesLabel($0.label, first.label) })
        else { return .ask(hint: elsewhere) }
        guard holders.allSatisfy({ !$0.isRevoked }) else { return .ask(hint: elsewhere) }

        if holders.contains(where: { $0.person == root.person })
            || TrustTable.sharesLabel(first.label, root.label) {
            let excluded = Set(holders.map(\.person)).union([root.person])
            guard !claimNamesAnotherPerson(
                claim, label: root.label, excluding: excluded, in: registry)
            else { return .ask(hint: elsewhere) }
            return .ownDevice(root: root)
        }

        // An unnamed record shares a label with nobody, so a new device can
        // never be "the same person" as it.
        guard TrustTable.sharesLabel(first.label, first.label)
        else { return .ask(hint: hint) }

        guard !claimNamesAnotherPerson(
            claim, label: first.label, excluding: Set(holders.map(\.person)), in: registry)
        else { return .ask(hint: elsewhere) }

        guard let representative = holders.min(by: { $0.person < $1.person })
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
    /// verified claim. Any root's records count — this only ever turns a
    /// silent answer into a question.
    nonisolated private static func claimNamesAnotherPerson(
        _ claim: PersonClaim, label: String,
        excluding: Set<String>, in registry: Registry
    ) -> Bool {
        let claimed = claim.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !claimed.isEmpty else { return false }
        return registry.people.contains { other in
            guard !excluding.contains(other.person),
                  !TrustTable.sharesLabel(other.label, label)
            else { return false }
            return TrustTable.sharesLabel(other.label, claimed)
                || registry.verifiedPersonClaims[other.person]?.name
                    .trimmingCharacters(in: .whitespacesAndNewlines) == claimed
        }
    }
}
