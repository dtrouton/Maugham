import Foundation

/// What one seal's key is to THIS device.
///
/// One word per genuinely different thing the reader can do with a line — count
/// the cases below, never a number in prose: apply it as its own (`mine`),
/// apply it as somebody's (`admitted`), HOLD it until the writer says
/// (`stranger` — pending, spec §3), refuse it and split the refusal by opId
/// (`revoked`), refuse what a stopped machine wrote after it stopped
/// (`retired`), refuse it as another claimant's (`otherRoot`), or fall back to
/// P1 and apply it as unsigned history because there is no chain to judge by
/// (`noChain`, decision B3).
///
/// The payloads are the fingerprints a surface needs to name somebody: a person
/// for the two admitted states, the device record naming the key for a stranger
/// (nil when nothing on disk describes it), the claimant's own root for
/// `otherRoot`, the device and the moment for `retired` — the one payload that
/// is not a name, because that verdict is answered against the seal's own date.
public enum TrustVerdict: Equatable, Hashable, Sendable {
    /// One of this device's own actor keys.
    case mine
    /// An actor key of a device admitted under this device's root.
    case admitted(person: String)
    /// A key this device's chain says nothing about. Held, not quarantined.
    ///
    /// `device` is the DEVICE record that names the key, nil when nothing on
    /// disk describes it. It is what the walk counts held lines under: one
    /// device holds four actor keys, and a phone that wrote as both its author
    /// and its assistant is one device waiting for admission, not two.
    case stranger(device: String?)
    /// Admitted, then revoked. `highestOpIdSeen` is the line between what the
    /// root had already applied and what arrived after (spec §5).
    case revoked(person: String, highestOpIdSeen: String?)
    /// Admitted, and then the DEVICE said it had stopped (spec §5). Dated,
    /// because this is the one verdict whose answer depends on WHEN a seal was
    /// made: its past stays verified and its future is quarantined, so the
    /// table carries the moment and the walk — which knows each seal's own
    /// date — decides. A revocation outranks it: that is the root refusing,
    /// and it is not softened by the machine having stopped politely.
    case retired(device: String, retiredAt: Date)
    /// A second self-signed root, or anyone it admitted. Listed, never merged.
    case otherRoot(root: String)
    /// This device belongs to no chain here, so it judges nobody (B3).
    case noChain
}

/// Who this device trusts in one project, resolved once from a verified
/// registry and this device's own keys.
///
/// **Since P3 it answers two questions, not one**: what a seal's key IS to this
/// device (`verdict`), and what the person behind it was allowed to WRITE
/// (`timeline`, narrowed by `actor`). Both come off the same verified registry,
/// resolved once — a second table built from the events would be the parallel
/// trust table tripwire 39 forbids, and the permit half is where such a pair
/// would disagree in silence.
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

    /// This device's OWN self-signed root record, if it has one — whatever
    /// `myRoot` ended up being.
    ///
    /// B1 has a half that `myRoot` cannot state on its own: **a device with
    /// its own root record is on its own root, and never switches.** A device
    /// that answers this non-nil must therefore never JOIN anybody, however
    /// many other roots name it — each of those is a claimant. `myRoot` is the
    /// root that WON and would name the remembered join for a device that had
    /// both, so the join decision asks this instead.
    public let ownRootRecord: String?

    /// Every root OTHER than this device's own that admitted it, by
    /// fingerprint, whether or not one of them is the root this device is on.
    ///
    /// Separate from `myRoot` because B1 has two halves and this is the loud
    /// one: once a device has joined a root, a SECOND root that names it is
    /// somebody claiming a book this device already belongs to someone else's
    /// copy of. `myRoot` cannot say so — it answers the join, which by B1 does
    /// not move — so a claimant would be invisible without this.
    ///
    /// A LIST rather than the first of them, because which one is joined is
    /// decided by WHEN this device saw it and the rest are claimants: an answer
    /// of one would name whichever sorts lowest, and if that happened to be the
    /// joined root the claimant beside it would go unrecorded. Sorted by
    /// fingerprint, so a registry that arrives in a different order answers the
    /// same, and `first` is arm 3 of `myRoot`.
    public let admittingRoots: [String]

    /// Every OTHER root whose chain this device's root has adopted, sorted —
    /// transitively, so a root adopted by a root I adopted is here too.
    ///
    /// **Adoption is the claim's primitive and it is symmetric** (plan decision
    /// P2). A claim written by MY root naming R takes R's chain in under mine:
    /// on a keyless restore that is the whole claim, and between two live Macs
    /// it is each saying *this is also me*. What it never is is somebody else's
    /// decision — a claim by R adopting me is R's word about R, and until this
    /// device writes its own claim R stays exactly the claimant it was (B1).
    ///
    /// Here rather than left to a surface to re-derive, because the closure it
    /// takes is the same one `verdict` judges by, and People & Devices draws
    /// these roots as *merged* off it (P2b Task 6).
    public let adoptedRoots: [String]

    /// This device's own actor keys.
    private let mine: Set<String>
    /// **Who this device IS**, as a person: its own author key's fingerprint,
    /// because under labels-only a person is a device's author key.
    ///
    /// Nil for a device that has never written as `author` at all — an actor
    /// key exists only once a writer has named it, so a machine that has only
    /// ever run the rebalance holds no author key and is nobody in particular
    /// yet. Such a key stands for itself, which is what it did before P3.
    private let myPerson: String?
    /// Actor key → the device record that names it. One hop, spelled once.
    private let deviceByActorKey: [String: String]
    /// Actor key → WHICH of the four writers it is (P3 spec §2's last
    /// paragraph). A device is four writers and they do not share a permit:
    /// `assistant` is the reviewer row on every device including the root's,
    /// because *MCP never mutates manuscript text* — so a reader that knows
    /// only whose key this is cannot judge the line. Nil for a key no record
    /// names an actor for, and for an actor word a later build invented.
    private let actorByKey: [String: DeviceActor]
    /// **A `device` string → the actor key it names** (P3a Task 6). An op and
    /// an inbox capture name their writer as `<actor>-<16 hex of the key>` and
    /// nothing else, while the permit, the person and the actor are all lookups
    /// on the KEY — so something has to turn one into the other, and it is this
    /// rather than a scan a caller writes for itself.
    ///
    /// Built from every key a verified device record MENTIONS, contested ones
    /// included, because *named but nobody's* and *not here at all* are two
    /// different answers (see `deviceKey(forDeviceId:)`).
    private let keyByDeviceId: [String: String]
    /// Person fingerprint → their permit history, built from this registry's
    /// events (spec §3.4). Absent for everybody with no events, which is
    /// everybody in every book written before P3 — and absent answers the
    /// author-of-the-whole-book default, which is what those admissions meant.
    private let timelineByPerson: [String: PermitTimeline]
    /// Person fingerprint → the chain positions their newest revocation EVENT
    /// recorded (P3a Task 7). Absent for every P2-era revocation, where the
    /// record's `highestOpIdSeen` is still the only line there is.
    private let revocationMarkByPerson: [String: PermitMark]
    /// **The photograph this book took of its unsigned streams the first time
    /// anybody was narrowed** (P3b Task 1), or nil where nothing narrows it.
    ///
    /// **Nil exactly when `hasNarrowingPermits` is false**, and that is a
    /// property rather than a coincidence: both are derived here, from the one
    /// root-filtered collection of events, so a book cannot be narrowed
    /// according to one and un-narrowed according to the other. The failure
    /// that equivalence prevents is silent and total — a book whose table says
    /// *narrowed* while no event names a governing snapshot holds every
    /// unsigned line ever written in it.
    public let unsignedSnapshot: UnsignedSnapshot?
    /// Person fingerprint → the record, for the revoked/admitted split.
    private let personByFingerprint: [String: PersonRecord]
    /// Every fingerprint this book holds a person record for — `Registry
    /// .knownPeople`, carried so `isStrangerDevice` can answer without the
    /// registry the table deliberately does not keep.
    private let knownPeople: Set<String>
    /// Every fingerprint ANY verified device record mentions, whether or not
    /// that record ended up OWNING it. The two sets differ by exactly the
    /// contested keys — the ones two records claim, which
    /// `Registry.actorKeyOwners` awards to nobody — and that difference is the
    /// whole point: a contested key is one the registry has an opinion about
    /// even though the opinion is *nobody's*, so nothing else may step in and
    /// name it (fix round 3, minor 2).
    private let keysNamedByADeviceRecord: Set<String>
    /// Device fingerprint → the moment that device said it had stopped. Keyed
    /// on the DEVICE, because retirement is a machine's own act and every actor
    /// key it holds retires with it.
    private let retiredAtByDevice: [String: Date]
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
    ///
    /// **And then whose chain that root took in.** A `ClaimRecord` written by
    /// my root adopting R admits R's chain under mine, transitively through R's
    /// own adoptions (`adoptedRoots`). It moves none of the four answers above:
    /// adoption says whose history this device VERIFIES, and the root it is on
    /// is a different question with a different rule (B1).
    nonisolated public static func resolve(
        registry: Registry, mine: LocalIdentities, joinedRoot: String?
    ) -> TrustTable {
        // `existingActors` ENUMERATES: it answers over the actors this device
        // has already written as and mints none, and the subscript of one that
        // exists mints nothing either. A read path must not mint. (`mine
        // .fingerprints` is exactly this set — it is spelled out here because
        // P3 needs the actor beside each key, not only the key.)
        let myIdentityByActor = Dictionary(
            uniqueKeysWithValues: mine.existingActors.map { ($0, mine[$0]) })
        let myKeys = Set(myIdentityByActor.values.map(\.fingerprint))
        let roots = registry.roots.sorted { $0.person < $1.person }

        // The two arms are kept as named values rather than folded into one
        // `??` chain, because the CALLER has to tell them apart: arm 2 is this
        // device being its own root, arm 3 is somebody else taking it in, and
        // only the second is ever joined.
        let ownRecord = roots.first { myKeys.contains($0.person) }?.person
        let admittingRoots = roots.filter {
            $0.person != ownRecord && !registry.chain(under: $0).isDisjoint(with: myKeys)
        }.map(\.person)

        let myRoot: String? = joinedRoot ?? ownRecord ?? admittingRoots.first

        // The roots MY root adopted, followed through their own adoptions. A
        // root that adopted THIS one is not here: only claims written by a root
        // in the closure widen it, which is what keeps the widening this
        // device's own act.
        //
        // **Resolved here, above the events**, because who may narrow this book
        // is a question about the adopted closure (P3b Task 2's ruling A) and
        // `myChain` below is not the only reader of it any more.
        var adoptedRoots: [String] = []
        if let myRoot {
            var reached: Set<String> = [myRoot]
            var frontier: [String] = [myRoot]
            while let root = frontier.popLast() {
                for adopted in registry.adopted(by: root).sorted()
                where reached.insert(adopted).inserted {
                    adoptedRoots.append(adopted)
                    frontier.append(adopted)
                }
            }
            adoptedRoots.sort()
        }

        // **Whose each actor key is, asked of the registry and never derived a
        // second time here** (fix round 2). `Registry.actorKeyOwners` is the
        // one rule — the author slot is proven, only standing records contest,
        // and a contested key belongs to nobody — and this table and
        // `Registry.device(withActorFingerprint:)` now cannot disagree about
        // it, which they could while each kept a first-wins scan of its own.
        let deviceByActorKey = registry.actorKeyOwners

        var actorByKey: [String: DeviceActor] = [:]
        for device in registry.devices.sorted(by: { $0.device < $1.device }) {
            // Only the OWNER's record says what one of its keys is FOR: a
            // record that does not own a key it lists cannot name its row
            // either. And an actor word this build does not know is left
            // unmapped rather than guessed — the permit narrows by actor, and
            // guessing would narrow it by the wrong row.
            for (word, key) in device.actors.sorted(by: { $0.key < $1.key }) {
                guard deviceByActorKey[key] == device.device,
                      let actor = DeviceActor(rawValue: word),
                      actorByKey[key] == nil else { continue }
                actorByKey[key] = actor
            }
        }
        // **This device's own keys win.** A device record vouches for its own
        // actors, and the reader checks only that its `author` entry is
        // itself — so a foreign record could name one of MY keys as its
        // translator and, unopposed, decide which row my own line is judged
        // on. What my key is for is something this device knows first-hand.
        for (actor, identity) in myIdentityByActor {
            actorByKey[identity.fingerprint] = actor
        }

        // **The same walk, one hop the other way** (P3a Task 6): every key a
        // record NAMES, under the device id that key would be written as.
        // Contested keys are in here on purpose — the register has an opinion
        // about one (*nobody's*), and a reader that could not find it at all
        // would read its lines as unsigned history instead of refusing them.
        // This device's own ids win for `actorByKey`'s reason, first-hand.
        var keyByDeviceId: [String: String] = [:]
        for device in registry.devices.sorted(by: { $0.device < $1.device }) {
            for (word, key) in device.actors.sorted(by: { $0.key < $1.key }) {
                let id = DeviceIdentity.deviceId(actor: word, fingerprint: key)
                if keyByDeviceId[id] == nil { keyByDeviceId[id] = key }
            }
        }
        // **And a PERSON record names one id all by itself** (fix round 2). A
        // person record and a device record are two files that sync separately
        // and `RegistryAdmission.admit` writes only the first, so a book
        // routinely knows who somebody is before it knows what her keys are
        // for. Under labels-only a person IS a device's author key, so her
        // `author-<hex>` id is derivable from the person record alone — and
        // without this the window in which only that record has arrived made
        // her look like a device this register had never heard of, which is a
        // quite different thing and is treated differently (`mayAmend`).
        //
        // Her other three actor keys are NOT derivable here, and must not be
        // guessed: only a device record says what they are. An amendment from
        // one of them is *named-shaped but unknown*, which `mayAmend` refuses
        // in a book with events rather than waving through.
        for person in registry.people.sorted(by: { $0.person < $1.person }) {
            let id = DeviceIdentity.deviceId(
                actor: DeviceActor.author.rawValue, fingerprint: person.person)
            if keyByDeviceId[id] == nil { keyByDeviceId[id] = person.person }
        }
        for identity in myIdentityByActor.values {
            keyByDeviceId[identity.deviceId] = identity.fingerprint
        }

        var personByFingerprint: [String: PersonRecord] = [:]
        for person in registry.people where personByFingerprint[person.person] == nil {
            personByFingerprint[person.person] = person
        }

        // **The permit history, per person** (spec §3.4). Built here because
        // this is where the verified registry already is: a second place that
        // read the events would be the parallel trust table tripwire 39
        // forbids, and the two would disagree the first time one of them
        // learned a rule.
        //
        // **A root is skipped**, and so answers the author-of-the-whole-book
        // default however many events name it. `RegistryReader` already lists
        // such an event malformed, so on disk this is unreachable; it is here
        // because `resolve` is pure and takes a `Registry` from wherever the
        // caller got one, and a device must not be talked out of its own
        // root's authority by a value somebody handed it.
        //
        // **And only a root of MY OWN chain is heard** (P3b Task 2's ruling A,
        // out of Task 1's review). `RegistryReader.entitled` lets ANY root in
        // the folder sign an event about a subject this registry holds no
        // person record for — deliberately, because the spec's write order
        // (the event, then the record) leaves a crash window in which exactly
        // that is the honest state. What it cannot tell is whether the root
        // doing the signing is one this device has anything to do with. A
        // CLAIMANT — a second Mac claiming a book this device already belongs
        // to somebody else's copy of, whose every seal this table answers
        // `.otherRoot` about — could therefore write one event about a
        // fingerprint nobody here has a record for and narrow the book: it
        // would count in `hasNarrowingPermits`, it would build a timeline, and
        // (P3b) an event dated 1970 carrying an EMPTY snapshot would become the
        // governing photograph, which holds every unsigned Mac's whole history
        // in a book that never trusted the device that said so.
        //
        // So the population is filtered by SIGNER as well as by subject: the
        // root this device is on (`myRoot` — its own record, or the one that
        // admitted it, or the one it remembers joining) and the roots that root
        // has adopted, transitively. The moment a claimant is ADOPTED its
        // events count, which is the other direction and is what makes the
        // two-roots exit work.
        //
        // **`.retired` keeps its own rule**, exactly as `entitled` states it: a
        // retirement is the device's own word about itself, signed by the
        // subject, and it installs no permit — so it narrows nothing and
        // belongs in the timeline whoever this device is on a chain with.
        //
        // **All three readers move together**, and that is the point of doing
        // it here: the timelines, `hasNarrowingPermits` and
        // `UnsignedSnapshot.governing` are all derived from this one
        // collection, so the pinned *nil iff not narrowed* equivalence survives
        // and a filter cannot be applied to one of them alone — which is the
        // worst direction, a book that counts as narrowed with no governing
        // photograph in it.
        let rootFingerprints = Set(roots.map(\.person))
        let rootsIAmOn: Set<String> = myRoot.map { Set([$0]).union(adoptedRoots) } ?? []
        var eventsByPerson: [String: [PermitEvent]] = [:]
        for event in registry.events where !rootFingerprints.contains(event.subject) {
            if case .retired = event.kind {
                guard event.subject == event.by else { continue }
            } else {
                guard rootsIAmOn.contains(event.by) else { continue }
            }
            eventsByPerson[event.subject, default: []].append(event)
        }
        let timelineByPerson = eventsByPerson.mapValues { PermitTimeline(events: $0) }

        // **Where a revocation drew its line, as chain POSITIONS** (P3a Task 7,
        // spec §3.3's last paragraph). The person record's `highestOpIdSeen`
        // stays exactly as it is, for every P2-era reader; where a revocation
        // EVENT exists it carries a map the writer of the ops cannot forge, and
        // that map is what `RevocationSplit` cuts on.
        //
        // The NEWEST revocation event wins, by event id — a revocation is
        // idempotent so there is normally one, and a person revoked, re-admitted
        // and revoked again has two, of which only the latest drew the line that
        // still holds.
        var revocationMarkByPerson: [String: PermitMark] = [:]
        for (person, events) in eventsByPerson {
            guard let latest = events
                .filter({ $0.kind == .revoked || $0.kind == .revokedEntirely })
                .max(by: { $0.event < $1.event })
            else { continue }
            revocationMarkByPerson[person] = PermitMark(latest.mark)
        }

        var retiredAtByDevice: [String: Date] = [:]
        for device in registry.devices {
            guard let retiredAt = device.retiredAt else { continue }
            // The EARLIEST, where a folder somehow holds two records for one
            // device: the moment it said it had stopped is the moment it
            // stopped, and taking the later one would apply lines written after
            // it said so.
            if let known = retiredAtByDevice[device.device], known <= retiredAt { continue }
            retiredAtByDevice[device.device] = retiredAt
        }

        // Everyone under my root — and under every root it adopted. An adopted
        // root that this registry holds no self-signed record for has no chain
        // to take in (`chain(underRoot:)` answers empty for a non-root), so a
        // claim naming a stranger admits nobody.
        var myChain = myRoot.map { registry.chain(underRoot: $0) } ?? []
        for adopted in adoptedRoots {
            myChain.formUnion(registry.chain(underRoot: adopted))
        }

        var otherRootByMember: [String: String] = [:]
        for root in roots where root.person != myRoot {
            for member in registry.chain(under: root).sorted()
            where otherRootByMember[member] == nil && !myChain.contains(member) {
                otherRootByMember[member] = root.person
            }
        }

        return TrustTable(
            myRoot: myRoot, ownRootRecord: ownRecord,
            admittingRoots: admittingRoots, adoptedRoots: adoptedRoots,
            mine: myKeys, myPerson: myIdentityByActor[.author]?.fingerprint,
            deviceByActorKey: deviceByActorKey,
            actorByKey: actorByKey, keyByDeviceId: keyByDeviceId,
            timelineByPerson: timelineByPerson,
            revocationMarkByPerson: revocationMarkByPerson,
            // From the SAME root-filtered events the timelines are built from,
            // so `unsignedSnapshot != nil` and `hasNarrowingPermits` cannot
            // disagree — see the property.
            unsignedSnapshot: UnsignedSnapshot.governing(
                events: eventsByPerson.values.flatMap { $0 }),
            personByFingerprint: personByFingerprint,
            knownPeople: registry.knownPeople,
            // The registry's own derivation, asked rather than repeated (P3b
            // Task 4): `Registry.isContestedActorKey` reads the same set, and
            // two spellings of *which keys this book has heard of* is how a
            // sheet comes to offer a key a pane calls contested.
            keysNamedByADeviceRecord: registry.keysNamedByADeviceRecord,
            retiredAtByDevice: retiredAtByDevice, myChain: myChain,
            otherRootByMember: otherRootByMember)
    }

    // MARK: - Answering

    /// **The line a revocation drew**: the highest opId the root had applied
    /// from `person` when it revoked them (spec §5), or nil where it had
    /// applied nothing and where nobody by that fingerprint is here at all.
    ///
    /// Asked by exactly one reader — `OpLogStore`'s tail classification, which
    /// splits a refused span into what arrived after the revocation and what
    /// was written before it and only reached this Mac later. Two lines, two
    /// sentences, and the same refusal.
    nonisolated public func highestOpIdSeen(forPerson person: String) -> String? {
        personByFingerprint[person]?.highestOpIdSeen
    }

    /// **The same line, drawn where the writer of the ops cannot move it** —
    /// the chain positions this person's newest revocation EVENT recorded
    /// (spec §3.3), or nil where their revocation predates events.
    ///
    /// Asked by the same one reader as `highestOpIdSeen`, and asked FIRST: an
    /// opId carries a timestamp its own writer chose, so a demoted device could
    /// stamp new text with an old id and slip under the mark. A position is a
    /// hash of bytes everybody holds. Where there is no event — every book
    /// revoked before P3 — the opId is still the only answer there is, and the
    /// P2 path is unchanged.
    ///
    /// **An EMPTY mark is a real answer and not nil.** It is what *Set aside
    /// everything it wrote* records, and it judges every line NEW, which is the
    /// same thing `nothingAppliedMark` means one wire format over.
    nonisolated public func revocationMark(forPerson person: String) -> PermitMark? {
        revocationMarkByPerson[person]
    }

    /// What the key that made this seal is to this device.
    ///
    /// The one mapping worth reading slowly is key → person, and since fix
    /// round 1 it is `owner(ofSealKey:)`'s and not spelled here: a seal is made
    /// by an ACTOR key, admission is granted to a PERSON, and this device's own
    /// keys are its own before any record is consulted.
    nonisolated public func verdict(forSealKey fingerprint: String) -> TrustVerdict {
        let (person, device, isMine) = owner(ofSealKey: fingerprint)
        if isMine { return .mine }
        guard myRoot != nil else { return .noChain }

        if myChain.contains(person) {
            if let record = personByFingerprint[person], record.isRevoked {
                return .revoked(person: person, highestOpIdSeen: record.highestOpIdSeen)
            }
            // Retirement is dated and revocation is not, so revocation is asked
            // first: a device that stopped politely and was then shut out is
            // shut out, whatever the date on the seal in hand.
            if let retiredAt = retiredAtByDevice[person] {
                return .retired(device: person, retiredAt: retiredAt)
            }
            return .admitted(person: person)
        }
        if let claimant = otherRootByMember[person] {
            return .otherRoot(root: claimant)
        }
        return .stranger(device: device)
    }

    // MARK: - Whose a key is — the one resolution

    /// **Who a seal key belongs to, and whether it is this device's own.**
    ///
    /// The one place the question is answered, because `verdict` and
    /// `person(forSealKey:)` answering it separately is a bug rather than a
    /// duplication (fix round 1, Critical). The order is what matters and it is
    /// the order `verdict` has always used:
    ///
    /// 1. **One of MY keys is MY person**, before any record is consulted. A
    ///    device record vouches for its own author key and nothing else — the
    ///    reader checks `actors["author"] == device` and the other three actor
    ///    fingerprints are unsigned strings anybody's record may list. So an
    ///    admitted device whose record names one of my actor keys among its own
    ///    (sorting before mine, or with my own device record not yet written)
    ///    would otherwise resolve my key to THAT person — `verdict` would still
    ///    say `.mine` while the permit lookup handed Task 5's partition and
    ///    Task 8's bootstrap gate somebody else's history to judge my own lines
    ///    by. What this device's own keys are is something it knows first-hand;
    ///    that is the same rule `actorByKey` is built under.
    /// 2. Otherwise the record: an actor key finds its device, and under
    ///    labels-only the device IS the person (its own `device` field).
    /// 3. Otherwise the key stands for itself — a person named directly, a root
    ///    whose device record was never written.
    ///
    /// `device` is deliberately the raw join in every case, because it is what
    /// `.stranger(device:)` counts held lines under and arm 1 cannot be reached
    /// with a verdict of `.stranger`.
    nonisolated private func owner(
        ofSealKey fingerprint: String
    ) -> (person: String, device: String?, isMine: Bool) {
        let device = deviceByActorKey[fingerprint]
        if mine.contains(fingerprint) {
            return (myPerson ?? fingerprint, device, true)
        }
        return (device ?? fingerprint, device, false)
    }

    // MARK: - The permit (P3)

    /// **Whose a seal key is** — `owner`'s answer, which is the same answer
    /// `verdict` is built on. One of this device's own keys is this device's
    /// own person, whatever any record says.
    nonisolated public func person(forSealKey fingerprint: String) -> String {
        owner(ofSealKey: fingerprint).person
    }

    /// **Which of the four writers made this seal**, or nil where nothing on
    /// disk says (an unrecorded key, or an actor word a later build invented).
    ///
    /// Asked beside the verdict, never instead of it: the person's permit says
    /// what that PERSON may write, and the actor narrows it (spec §2) — the
    /// assistant is the reviewer row on every device including the root's own
    /// Mac, which is the storage-layer form of *AI is never the author*. A
    /// caller that cannot name the actor cannot apply that narrowing, which is
    /// why this is an `Optional` rather than a defaulted `.author`.
    nonisolated public func actor(forSealKey fingerprint: String) -> DeviceActor? {
        actorByKey[fingerprint]
    }

    /// **One person's permit history**, from this project's verified events.
    ///
    /// The role check reads this and never `PersonRecord.role` (spec §3.4): a
    /// record is re-signed in place and forgets its own past, so a check made
    /// from one would let a demotion reach backwards and a promotion pardon.
    ///
    /// Everybody this registry has no events for — everybody in every book
    /// written before P3, and every root — answers `PermitTimeline.bookAuthor`:
    /// author of the whole book, from the start, no mark. That default is what
    /// makes a permit check behaviour-neutral for every book already on disk.
    nonisolated public func timeline(forPerson person: String) -> PermitTimeline {
        timelineByPerson[person] ?? .bookAuthor
    }

    /// The same, for a caller holding a seal's key rather than a person.
    ///
    /// **Including one of this device's own keys**, and safely: the key
    /// resolves through `owner(ofSealKey:)`, so a key of mine is MY person's
    /// history and no record can make it somebody else's. A second Mac of an
    /// admitted person answers `.mine` about itself and may perfectly well be a
    /// reviewer — the verdict says whose hand a line is, and this says what
    /// that hand was allowed to write. A keyless book resolves through
    /// `TrustResolution.keyless`, whose registry is empty, so every key here
    /// answers the author-of-the-whole-book default: P1's behaviour exactly.
    nonisolated public func timeline(forSealKey fingerprint: String) -> PermitTimeline {
        timeline(forPerson: person(forSealKey: fingerprint))
    }

    /// **This device's OWN permit history** — what the writer sitting at this
    /// Mac has been allowed to write in this book, and when (P3a Task 8).
    ///
    /// The read paths ask `timeline(forSealKey:)` about a key they found on a
    /// seal; the WRITE side has no seal to ask about — it is about to make one
    /// — so it asks this. The answer is the same one `timeline(forSealKey:)`
    /// gives for any of this device's four keys, because `owner(ofSealKey:)`
    /// resolves every one of them to `myPerson`: under labels-only a person IS
    /// a device's author key, and the actor narrows *within* that person's
    /// permit rather than having one of its own.
    ///
    /// **It mints nothing.** `myPerson` was resolved in `resolve` from
    /// `LocalIdentities.existingActors`, which enumerates — so a device that
    /// has never written as `author` has no person here and takes the
    /// author-of-the-whole-book default, exactly as it did before P3.
    nonisolated public var myTimeline: PermitTimeline {
        guard let myPerson else { return .bookAuthor }
        return timeline(forPerson: myPerson)
    }

    /// **Is a device holding lines back a STRANGER?** — `Registry
    /// .isStrangerDevice`'s rule, asked of the set `resolve` already took off
    /// the registry, so the load can answer it without keeping a registry.
    ///
    /// Read the registry's own doc comment for why a held line and a line
    /// *waiting for admission* stopped being the same fact in P3a.
    nonisolated public func isStrangerDevice(_ fingerprint: String) -> Bool {
        !HeldLines.isUnsignedHolder(fingerprint) && !knownPeople.contains(fingerprint)
    }

    /// **Does a verified device record NAME this key**, whatever it calls it
    /// and whoever ends up owning it?
    ///
    /// The question a reader asks before it falls back to reading an actor off
    /// a filename (fix round 1's I5). `actor(forSealKey:)` answers nil for
    /// **three** quite different situations, and only the last of them may be
    /// narrowed by anything else:
    ///
    /// 1. **A record owns the key and calls it an actor word this build cannot
    ///    read** — a later build's fifth writer. It must stay nil, or the word
    ///    would be guessed at.
    /// 2. **Two records claim the key, so it is nobody's** (round 2 of Task 3's
    ///    review: *a disputed actor key belongs to nobody for good*). It must
    ///    stay nil too, and this is why the question is NAMES rather than
    ///    OWNS: `Registry.actorKeyOwners` drops a contested key, so an
    ///    ownership test would hand it to the filename — letting the one thing
    ///    the dispute rule refuses to decide be decided by a file's name.
    /// 3. **No record mentions the key at all** — a person admitted before
    ///    their device record has synced. Only here does the filename narrow.
    ///
    /// (In practice a contested key's lines are usually never seen by the
    /// partition at all: with no owner it resolves to itself, and a key no
    /// person record names is a `.stranger`, held. But a contested key CAN
    /// carry a person record — the admission sheet offers a held span under
    /// `device ?? sealKey` — and then its lines are applied and do reach here,
    /// which is why this is a rule and not an observation.)
    nonisolated public func aDeviceRecordNames(_ fingerprint: String) -> Bool {
        keysNamedByADeviceRecord.contains(fingerprint)
    }

    /// **What a `device` string turns out to be** — the key it names, which of
    /// the four writers it is, and whether anybody owns that key (P3a Task 6).
    ///
    /// A `device` string is `<actor>-<16 hex of the key>` and is written by the
    /// device that chose it, so it is a CLAIM. It is believed only where a
    /// verified device record names that very key under that very actor word,
    /// or where the key is one of this device's own — so the claim can only
    /// ever be matched, never taken at face value.
    public struct DeviceKey: Equatable, Sendable {
        /// The fingerprint every other question on this table is asked about.
        public let key: String
        /// The writer it is, or nil for an actor word this build cannot read.
        public let actor: DeviceActor?
        /// **Does the register attribute this key to somebody?**
        ///
        /// False in exactly one situation, and it is the one that matters:
        /// **two verified device records claim the key**, which
        /// `Registry.actorKeyOwners` awards to nobody for good. The register
        /// has an opinion about such a key and the opinion is *nobody's*, so a
        /// reader must not act on it — and that is not the same as a key
        /// nothing here has ever heard of, which answers nil above.
        ///
        /// A device record decides wherever one NAMES the key (present ⇒ its
        /// owner, absent ⇒ contested). Where none does, a person record is
        /// enough: under labels-only a person is a device's author key, so a
        /// record admitting that fingerprint attributes it by saying so.
        public let isOwned: Bool
    }

    /// **The seal key a `device` string names**, or nil where nothing in this
    /// register mentions one.
    ///
    /// Nil is the answer for every line P3 must not start judging: an op
    /// carrying a pre-P1 hostname sentinel, a device that has never written a
    /// record here, a book with no register at all. Those are decision B3's
    /// world — the permit partition does not judge their lines either, because
    /// no seal it can attribute covers them — so a caller meeting nil should
    /// do what P1 did and not what a refusal would do.
    nonisolated public func deviceKey(forDeviceId deviceId: String) -> DeviceKey? {
        guard let key = keyByDeviceId[deviceId] else { return nil }
        let owned: Bool
        if mine.contains(key) {
            owned = true
        } else if keysNamedByADeviceRecord.contains(key) {
            // A device record has an opinion: present means its owner, absent
            // means two records claimed it and it is nobody's.
            owned = deviceByActorKey[key] != nil
        } else {
            // No device record mentions it, so a person record is what
            // attributes it — and where neither does, this line is unreachable
            // (the id would not be in the map at all).
            owned = knownPeople.contains(key)
        }
        return DeviceKey(key: key, actor: actorByKey[key], isOwned: owned)
    }

    /// **The writer's word for the device whose files carry this slug** (P3a
    /// Task 9), or nil where nothing in this register names one.
    ///
    /// A file is named for a SLUG and everything else here is keyed on a
    /// fingerprint, so something has to join the two — and the join is
    /// `DeviceSlug.make` over the device ids this register already holds,
    /// never a parse of the slug back into an id. A slug is lossy by
    /// construction (`make` caps its length and folds every character outside
    /// `[a-z0-9]`), so the only honest direction is forwards.
    ///
    /// The answer is `TrustEventSentence.name`'s: the label the root wrote
    /// into the person record, else that person's four-character code.
    nonisolated public func label(forDeviceSlug slug: String) -> String? {
        guard let key = key(forDeviceSlug: slug) else { return nil }
        let owner = person(forSealKey: key)
        return personByFingerprint[owner]?.label ?? DeviceCode.short(owner)
    }

    /// **The seal key this register can name for a file carrying this slug**,
    /// or nil where nothing here names one — the ONE slug → key join, and the
    /// one `label(forDeviceSlug:)` is now written over (Task 11).
    ///
    /// It is arm 2 of *the file's key*: a file that holds no usable seal of its
    /// own is still named for a device, and the filename's slug is the only
    /// thing about it this device can check against a record. `keyByDeviceId`
    /// is what does the checking — a device record's own actor entries, a
    /// person record's derivable `author-<hex>` id (Task 6), and this device's
    /// own four ids, which win — so the CLAIM a filename makes is only ever
    /// matched against something signed, never believed.
    ///
    /// Forwards only, for `label`'s reason: `DeviceSlug.make` caps length and
    /// folds every character outside `[a-z0-9]`, so a slug cannot be parsed
    /// back into an id. Sorted, so a slug two ids somehow collide on answers
    /// the same key on every device rather than whichever the dictionary
    /// happened to hand back first.
    nonisolated public func key(forDeviceSlug slug: String) -> String? {
        for deviceId in keyByDeviceId.keys.sorted()
        where DeviceSlug.make(from: deviceId).raw == slug {
            if let key = keyByDeviceId[deviceId] { return key }
        }
        return nil
    }

    /// **Are these two keys the same WRITER?** (P3a Task 6.)
    ///
    /// `person(forSealKey:)` answers a FINGERPRINT, and under labels-only a
    /// person is a device's author key — so Sam's Mac and Sam's phone are two
    /// person records and two fingerprints. That is the right answer for a
    /// verdict (each machine's word is its own) and the wrong one for *may she
    /// withdraw her own note*, which is about the writer and not the machine.
    ///
    /// So the join is the fingerprint, **or** the LABEL both person records
    /// carry. A label is not a coincidence and it is not the device's own word
    /// for itself (that is `ownName`): it is **the ROOT's word for whose
    /// machine this is**, written by the root into a signed record, and P2b's
    /// admission already merges a typed label matching a known one under that
    /// label's own spelling. Same label therefore means *the root said these
    /// are the same person*, which is the only person-level identity this
    /// format has.
    ///
    /// **A RENAME splits them again, and that is the root's act too**
    /// (`RegistryAdmission.rename`, the one registry verb that moves no
    /// verdict). Relabel one of her machines and its amendments stop counting
    /// as hers — which is correct, because the writer has just said it is
    /// somebody else's.
    ///
    /// **Exact strings, and an unnamed machine is nobody.** No case folding and
    /// no trimming beyond whatever admission itself applied before signing the
    /// record: the comparison must be the one the root made, not a looser one
    /// invented here. An EMPTY or absent label never equals another empty or
    /// absent label — two machines nobody has named are two machines, and
    /// folding them together would make *unnamed* an identity.
    ///
    /// **Not a general-purpose answer.** It is asked by the ownership rule and
    /// by Option A's *whose piece did she start* (`isThisWriters`,
    /// `isAStarter`), and
    /// nothing else: a verdict, a permit and a mark are all about the machine,
    /// and widening any of those to a label would let a name decide what a
    /// signature means. Option A's use is the ownership rule's own shape — a
    /// question about the WRITER — and it widens nothing but which of her own
    /// Macs shows her own words while the root decides.
    nonisolated public func sameWriter(
        _ fingerprint: String, _ other: String
    ) -> Bool {
        let (a, b) = (person(forSealKey: fingerprint), person(forSealKey: other))
        if a == b { return true }
        return TrustTable.sharesLabel(
            personByFingerprint[a]?.label, personByFingerprint[b]?.label)
    }

    // MARK: - Who started a piece (P3c plan 2, Option A)

    /// **Whose device a piece's recorded starter is, to this device** (ruling
    /// OA-1). `StructureItem.startedBy` carries an AUTHOR device id; this is
    /// the one place that id is turned into an answer.
    public enum PieceStarter: Equatable, Sendable {
        /// This very Mac started it — the one device that may mint its
        /// opening (`LocalWritePermit.mayMintOpening`).
        case thisDevice
        /// Another of this writer's own devices started it: her other Mac.
        /// Her words from there are hers here too; the opening is not this
        /// Mac's to mint (Review Focus 1 — it waits for the ops).
        case anotherOfThisWritersDevices
        /// Somebody else, or a device this register cannot vouch for — a
        /// contested key, a revoked or retired device, one nobody names.
        case somebodyElse
    }

    /// **Is this seal key one of THIS writer's?** — ANY of this device's own
    /// four keys (author, assistant, translator, maugham — not only the
    /// writer's hand), or a key `sameWriter` joins to this device's own author
    /// key (her other Mac, which the root labelled as hers). Every caller that
    /// means *her hand* must also require the `.author` actor, as Option A's
    /// arm does through `Permit.startsAPieceNobodyHasClaimed`.
    ///
    /// The second caller `sameWriter`'s note anticipates: Option A asks it
    /// about the piece a writer STARTED, which is a question about the writer
    /// and not the machine, exactly as *may she withdraw her own note* is.
    /// False where this device has never written as its author: it then has
    /// no person here to be the same as.
    nonisolated public func isThisWriters(sealKey fingerprint: String) -> Bool {
        if mine.contains(fingerprint) { return true }
        guard let myPerson else { return false }
        return sameWriter(fingerprint, myPerson)
    }

    /// **Whose device `deviceId` — a piece's recorded starter — is.**
    ///
    /// The id is a CLAIM written into an unsigned manifest, so it is matched
    /// forwards against keys this register already vouches for
    /// (`deviceKey(forDeviceId:)`) and never believed on its face:
    ///
    /// - it must name an AUTHOR key — a piece is started by a writer's own
    ///   hand, never by the assistant or the pipeline;
    /// - it must be owned — a contested key is nobody's (`DeviceKey.isOwned`);
    /// - one of this device's own keys is `.thisDevice`, first-hand;
    /// - otherwise it must be this writer's (`isThisWriters`) AND still
    ///   standing here — `.admitted`, never `.revoked` or `.retired`: a device
    ///   the root shut out, or that stopped, starts nothing of hers.
    ///
    /// Everything else is `.somebodyElse`, which is the waiting answer.
    nonisolated public func starter(ofPieceStartedBy deviceId: String) -> PieceStarter {
        guard let key = starterKey(deviceId) else { return .somebodyElse }
        if mine.contains(key) { return .thisDevice }
        guard isThisWriters(sealKey: key),
              case .admitted = verdict(forSealKey: key)
        else { return .somebodyElse }
        return .anotherOfThisWritersDevices
    }

    /// **Where a piece's recorded starter stands in this register** (controller
    /// Rulings L (b) and M, P3c plan 2 Task 4).
    public enum StarterStanding: Equatable, Sendable {
        /// This device, or a device this register shows as admitted: the
        /// starter rule binds, and only it mints the opening.
        case standing
        /// A device the register shows will never mint here — revoked,
        /// retired, a stranger nobody admitted, a claimant of another root, a
        /// contested key, or a key that is not a writer's hand. The starter
        /// rule does not bind: today's rule applies (whoever may write the
        /// piece's text mints it), so the piece is not unopenable for good.
        case gone
        /// A device id this register has never heard of — most likely its
        /// device record has not synced yet. Treated as still COMING
        /// (Ruling M): the starter rule binds and this Mac waits, which keeps
        /// OA-2's race closed while her record is on its way.
        case unknown
    }

    /// **Where the starter `deviceId` stands** — the one answer the write-side
    /// builder (`OpLogStore.localWritePermit`) asks before the starter rule
    /// may bind. This device's own ids are always `.standing`
    /// (`keyByDeviceId` holds them before any record of its own is written).
    nonisolated public func starterStanding(_ deviceId: String) -> StarterStanding {
        guard deviceKey(forDeviceId: deviceId) != nil else { return .unknown }
        guard let key = starterKey(deviceId) else { return .gone }
        switch verdict(forSealKey: key) {
        case .mine, .admitted: return .standing
        case .stranger, .revoked, .retired, .otherRoot, .noChain: return .gone
        }
    }

    /// **Is `deviceId` — a piece's recorded starter — the same writer as the
    /// key `fingerprint`?** (controller ruling G.) Asked of a book author's
    /// `bootstrap` by §4.5's pass 1: her opening counts as writing the piece's
    /// text unless the piece was started by somebody else. The same forwards
    /// match `starter(ofPieceStartedBy:)` makes, then `sameWriter`; a starter
    /// this register cannot resolve is nobody's, so the answer is false.
    nonisolated public func isAStarter(
        _ deviceId: String, ofTheSameWriterAs fingerprint: String
    ) -> Bool {
        guard let key = starterKey(deviceId) else { return false }
        return sameWriter(key, fingerprint)
    }

    /// The owned AUTHOR key a recorded starter names, or nil — the one match
    /// of a starter id against this register.
    nonisolated private func starterKey(_ deviceId: String) -> String? {
        guard let named = deviceKey(forDeviceId: deviceId), named.isOwned,
              (named.actor ?? DeviceIdentity.claimedActor(ofDeviceId: deviceId)) == .author
        else { return nil }
        return named.key
    }

    /// **Do two person records name the same writer?** — the label rule above,
    /// as a function, because a second caller arrived (P3a Task 7, fix round 1).
    ///
    /// `RegistryAdmission.records(sharingLabelWith:in:)` asks it to find every
    /// record a permit change must reach: a person whose Mac and phone were
    /// both admitted is two records under one label, and moving one of them
    /// leaves her writing manuscript text from the other. That is the same
    /// question `sameWriter` asks and it must not become a second answer to
    /// it — so the rule is spelled here, once.
    ///
    /// Exact strings, for `sameWriter`'s reason: the comparison must be the
    /// one the ROOT made when it signed the records, not a looser one invented
    /// afterwards. **An empty or absent label shares with nobody** — two
    /// machines nobody has named are two machines, and folding them together
    /// would make *unnamed* an identity, which for a permit means a demotion
    /// reaching a device the writer never named.
    nonisolated public static func sharesLabel(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right, !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }

    /// **Has anybody in this book ever been anything but an author of the whole
    /// book?** (Final fix wave, W1 — the whole-branch review's Critical.)
    ///
    /// This is the question every neutrality gate means, and it is NOT *are
    /// there permit events*. P3a ships three verbs that write events —
    /// `admit`, `revoke`, `retire` — and the admission ones fire on the first
    /// phone or second Mac the writer lets in. Every event P3a can write
    /// carries the book-author permit, because no surface exists yet that
    /// produces another; gating on their EXISTENCE therefore flipped a book
    /// into *judge everything* for a reason that has nothing to do with
    /// permits, and took three things with it: the annotation ownership rule
    /// stopped honouring an unsigned Mac's edits and withdrawals (reversing
    /// P1's decision B3 for a state the constitution calls first-class), the
    /// per-file and whole-file fast paths went off on around thirty
    /// synchronous translation reads and every inbox refresh, and every
    /// applied op line paid a second JSON decode.
    ///
    /// Asked of the permits, the answer comes back to exactly what P2 did —
    /// and turns to *yes* the moment anybody is a reviewer, an author of some
    /// pieces, or carries a role word this build cannot read. See
    /// `PermitTimeline.narrows`.
    ///
    /// **What this is not.** It is not a licence for the ACTOR rows: the
    /// assistant, the translator and the task rebalance are narrowed in every
    /// book, evented or not, and every gate below keeps a condition of its own
    /// for them. *MCP never mutates manuscript text* is a sentence of the
    /// constitution rather than a thing that waits for a permit event.
    nonisolated public var hasNarrowingPermits: Bool {
        timelineByPerson.values.contains { $0.narrows }
    }
}
