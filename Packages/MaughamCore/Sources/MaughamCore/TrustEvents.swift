import Foundation

/// Something that HAPPENED to this book's people, with the day it happened on.
///
/// **Why events at all, beside the banners** (spec §6, Denver's ruling C,
/// 2026-09-10). A banner is a fact that holds now — *14 notes from iPhone are
/// waiting*, *this Mac is on Denver's chain* — present while true and gone when
/// not. That is the right shape for a live number with a button beside it, and
/// the wrong shape for everything else, because a fact that has stopped holding
/// leaves nothing behind: a person admitted in June and revoked in September
/// reads, under banners alone, exactly like a person who was never here. So
/// trust has two shapes, and this is the second one: dated entries, written
/// once, in a project-scope section of History's timeline.
///
/// **Derived, never stored.** Every event below is read out of records the
/// registry already carries (`admittedAt`, `revokedAt`, `retiredAt`,
/// `claimedAt`) or out of this device's own memory of the project
/// (`RegistryCache`'s join and its claimants). Nothing here writes a log, and
/// nothing is asked to: a log would be a second account of who was admitted,
/// able to disagree with the records themselves.
public struct TrustEvent: Equatable, Hashable, Sendable, Identifiable {

    /// What happened. `CaseIterable` so a test can hold every kind to the same
    /// standard — a sentence, and no internal vocabulary in it.
    public enum Kind: String, Sendable, CaseIterable {
        /// A person record somebody else signed: they were let in.
        case admitted
        /// Let in with no sheet shown, under a label this Mac had already
        /// granted. **Not derived yet** — see `TrustEvents.derive`.
        case silentlyAdmitted
        /// A person record carrying `revokedAt`.
        case revoked
        /// A device record carrying `retiredAt`.
        case retired
        /// A `ClaimRecord`: this root claimed the book.
        case claimed
        /// One root a claim took in. One event per adopted root.
        case adopted
        /// This device joined a root's chain (`RegistryCache.joinedRoot`).
        case joined
        /// Another root that has since named this device (B1). Undated.
        case anotherClaimant
        /// A record this device remembered and the folder had lost, put back
        /// from the memory — dated from `RegistryCache.restores` (P2b Task 10).
        case recordRestored
    }

    /// When, or nil where nothing stamps it. Two kinds are honestly undated —
    /// a claimant (the cache records that it happened, not when) and a join
    /// from a memory written before P2b stamped one — and an undated event is
    /// drawn without a date rather than dropped or given one this surface
    /// invented.
    public let date: Date?
    public let kind: Kind
    /// Whom the event is ABOUT: a person fingerprint for admission, revocation,
    /// a claim, a join and a claimant; a device fingerprint for a retirement.
    public let subject: String
    /// The subject's own name from its record — a person's `label`, a device's
    /// `name` — nil when this registry holds no record for it.
    public let label: String?
    /// A person's `ownName`, shown beside the label where the two differ (spec
    /// §3). Always nil for a device, whose record carries one name.
    public let ownName: String?
    /// Whose act it was, where a record names one: the root that admitted or
    /// revoked, the claimant that adopted. Nil where the record names nobody.
    public let by: String?
    /// The subject is one of THIS device's own actor keys, so a surface says
    /// *This Mac* rather than reading the writer their own machine's label.
    public let isMine: Bool

    public init(
        date: Date?, kind: Kind, subject: String, label: String? = nil,
        ownName: String? = nil, by: String? = nil, isMine: Bool = false
    ) {
        self.date = date
        self.kind = kind
        self.subject = subject
        self.label = label
        self.ownName = ownName
        self.by = by
        self.isMine = isMine
    }

    /// Stable across a re-derivation of the same facts, and distinct between
    /// the two events one record can carry — a person admitted and later
    /// revoked is two rows, and a `ForEach` that saw one id would draw one.
    public var id: String {
        "\(kind.rawValue):\(subject):\(by ?? "")"
    }
}

/// Registry records plus this device's memory of one project, read as a dated
/// history.
///
/// **Pure over its inputs.** No clock, no `LocalIdentities.current`, no read of
/// the folder: the registry is handed in already verified and the cache is
/// handed in already loaded, which is what lets every arm below be pinned as a
/// value. It is also what makes it safe to call from a surface — the disk work
/// happened before it.
public enum TrustEvents {

    /// Every event this project's records and this device's memory of it can
    /// account for, newest first, the undated last.
    ///
    /// **Two of `TrustEvent.Kind`'s nine are not derived here**, and both are
    /// deliberate rather than forgotten:
    ///
    /// - `.silentlyAdmitted` cannot be told from `.admitted` by records alone.
    ///   A person record says a root admitted somebody; it does not say whether
    ///   a sheet was shown. Denver's ruling for this task is that both emit
    ///   `.admitted`. The heuristic that would separate them is a label
    ///   remembered BEFORE this project's admission — `AdmissionMemory`'s
    ///   `labelledAt` against the record's `admittedAt` — and the hook is here:
    ///   when that type lands, this is the one place that has to change, and
    ///   the sentence it needs is already written.
    /// - `.recordRestored` is dated from `RegistryCache.restores(for:)`, the
    ///   bounded list `reconcile` writes as it puts records back (P2b Task 10).
    ///   Reading it here rather than re-deriving it is the whole point: a
    ///   restoration is not visible in the folder afterwards — the file is back,
    ///   and looks exactly as it did before somebody deleted it — so this is the
    ///   only place the fact survives, and dating it at read time would stamp a
    ///   week-old deletion with the moment History was opened.
    nonisolated public static func derive(
        registry: Registry, cache: RegistryCache, mine: LocalIdentities, for projectURL: URL
    ) -> [TrustEvent] {
        // ENUMERATES this device's keys; it mints none. A read path that minted
        // would create a key because the writer opened a pane
        // (`LocalIdentities`' lazy rule).
        let myKeys = mine.fingerprints
        var events: [TrustEvent] = []

        for person in registry.people {
            // A root vouched for itself. Drawing that as an admission would put
            // *Denver admitted by Denver* at the foot of every project that has
            // ever had a registry — an event in which nothing happened.
            if !person.isRoot {
                events.append(TrustEvent(
                    date: person.admittedAt, kind: .admitted, subject: person.person,
                    label: person.label, ownName: person.ownName,
                    by: person.admittedBy, isMine: myKeys.contains(person.person)))
            }
            if let revokedAt = person.revokedAt {
                events.append(TrustEvent(
                    date: revokedAt, kind: .revoked, subject: person.person,
                    label: person.label, ownName: person.ownName,
                    by: person.revokedBy, isMine: myKeys.contains(person.person)))
            }
        }

        for device in registry.devices {
            guard let retiredAt = device.retiredAt else { continue }
            events.append(TrustEvent(
                date: retiredAt, kind: .retired, subject: device.device,
                label: device.name, isMine: myKeys.contains(device.device)))
        }

        for claim in registry.claims {
            events.append(TrustEvent(
                date: claim.claimedAt, kind: .claimed, subject: claim.newRoot,
                label: registry.person(claim.newRoot)?.label,
                ownName: registry.person(claim.newRoot)?.ownName,
                isMine: myKeys.contains(claim.newRoot)))
            for adopted in claim.adopted {
                // Dated by the claim that carried it: adoption is not an act of
                // its own, it is what a claim SAYS, so it happened when the
                // claim was written.
                events.append(TrustEvent(
                    date: claim.claimedAt, kind: .adopted, subject: adopted,
                    label: registry.person(adopted)?.label,
                    ownName: registry.person(adopted)?.ownName,
                    by: claim.newRoot, isMine: myKeys.contains(adopted)))
            }
        }

        if let joined = cache.joinedRoot(for: projectURL) {
            events.append(TrustEvent(
                date: cache.joinedAt(for: projectURL), kind: .joined, subject: joined,
                label: registry.person(joined)?.label,
                ownName: registry.person(joined)?.ownName))
        }
        // **A root this device has adopted is merged, and is not still
        // claiming** (whole-branch review H1). `RegistryCache.claimants` never
        // forgets — that a second root was seen here is a fact, and a merge
        // does not unsay it — so the answer to *is it still claiming* is made
        // at the derivation instead.
        //
        // The adopted set is asked of a `TrustTable` rather than re-derived off
        // `registry.claims`, because People & Devices reads `adoptedRoots` and
        // two spellings of *merged* is exactly how the pane comes to say merged
        // while History goes on warning. The table is pure over these same
        // three inputs (`DeviceStanding.resolve`'s own shape, for its reason),
        // so this costs no disk and no second opinion.
        //
        // **One-way, and that is the point.** `adoptedRoots` is the closure of
        // claims written by MY root, so a root that adopted mine without my
        // reciprocating stays a claimant and stays offered (B1): nothing
        // widens on somebody else's say-so, and the merge that silences this
        // warning is the writer's own.
        let adopted = Set(TrustTable.resolve(
            registry: registry, mine: mine,
            joinedRoot: cache.joinedRoot(for: projectURL)).adoptedRoots)
        for claimant in cache.claimants(for: projectURL) where !adopted.contains(claimant) {
            events.append(TrustEvent(
                date: nil, kind: .anotherClaimant, subject: claimant,
                label: registry.person(claimant)?.label,
                ownName: registry.person(claimant)?.ownName))
        }

        // Every restoration this device has made here, each dated by the day it
        // made it. A record that was deleted and put back TWICE is two events,
        // because it was two deletions.
        for restore in cache.restores(for: projectURL) {
            let fingerprint = restore.ref.fingerprint
            events.append(TrustEvent(
                date: restore.restoredAt, kind: .recordRestored, subject: fingerprint,
                // A restored DEVICE record is named by the device, a person's
                // by the person; either may be absent from a registry read
                // later than the restore, and an unnamed subject draws by code.
                label: registry.person(fingerprint)?.label
                    ?? registry.devices.first { $0.device == fingerprint }?.name,
                ownName: registry.person(fingerprint)?.ownName,
                isMine: myKeys.contains(fingerprint)))
        }

        return sorted(events)
    }

    /// Newest first, the undated last, and every tie broken by name so that a
    /// registry arriving in another order reads the same way.
    ///
    /// Undated LAST rather than first: an event with no day is the oldest thing
    /// this device can say about the project (a join from before the stamp
    /// existed) or a standing condition with no day at all (a claimant), and
    /// neither belongs above this morning's revocation.
    nonisolated static func sorted(_ events: [TrustEvent]) -> [TrustEvent] {
        events.sorted { a, b in
            switch (a.date, b.date) {
            case let (x?, y?) where x != y: return x > y
            case (nil, .some): return false
            case (.some, nil): return true
            default:
                if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
                return a.subject < b.subject
            }
        }
    }
}
