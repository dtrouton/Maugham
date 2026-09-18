import Foundation

/// **What this device is to one book, said in one sentence** (P2 spec §4.3).
///
/// The phone's Settings row and the Mac's People & Devices ask the same
/// question about themselves — *am I on this book's chain, under what name,
/// since when* — and a writer comparing the two screens is the whole of how an
/// admission is checked. Two implementations of that answer would let the
/// phone and the Mac describe the same state in different words, which is
/// exactly the comparison failing (tripwire 19), so the facts and the sentence
/// live here and every surface asks.
///
/// **Facts, never a control.** Nothing here admits, revokes or joins: this is
/// a projection over a verified registry and this device's own memory of it.
/// Admission is a Mac act at a surface, and in P2 the phone shows the state
/// and offers nothing to press (§4.11).
///
/// **A refusal is a state of its own.** A registry record that is present and
/// cannot be read must not answer *not yet admitted* (RULING-54): the writer
/// would read a permissions error or a half-downloaded iCloud file as a Mac
/// that has not got round to it, and wait. `refused(mine:error:)` carries the
/// read's own sentence instead, which already says that none of the writer's
/// words are in the file and what Maugham is refusing to do over it.
public struct DeviceStanding: Equatable, Sendable {

    /// This device's own four-character code, whatever the folder says. It is
    /// here even in the refusal and the not-yet cases, because a code exists to
    /// be read off one screen and compared with another.
    public let code: String

    /// The writer's word for this device on this chain — the person record's
    /// `label` — or nil when no record names it.
    public let label: String?

    /// The label of the root whose chain this device is on, or nil when it is
    /// on none.
    public let rootLabel: String?

    /// When this device JOINED that root, if it joined one. A device admitted
    /// by a folder it had already verified has no join stamp (P2a recorded one
    /// only where the join happened here), and the sentence simply omits the
    /// date rather than inventing one.
    public let joinedAt: Date?

    /// Is this device admitted to a chain right now? False for a device
    /// nobody has named, for a revoked one, and for a refused read.
    public let admitted: Bool

    /// Is this device the root of this book's chain — the Mac that owns the
    /// folder? A root is on nobody's chain but its own, and saying *X on X's
    /// chain* would read as an admission it never needed.
    public let isRoot: Bool

    /// A person record names this device and it has been revoked. Distinct
    /// from never having been admitted: what this device writes from now on is
    /// held, and a writer told *not yet* would wait for a sheet that is not
    /// coming.
    public let revoked: Bool

    /// When THIS device said it had stopped writing in this book (spec §5),
    /// off its own device record. Nil for a device still at work.
    ///
    /// **It is not the opposite of `admitted`, and it is the one fact this type
    /// carries that the machine holding it must be told about.** A retired
    /// device's key removes its own future AUTHORITY and not its ability to
    /// write: `TrustTable` answers `.mine` before it answers `.retired`, so
    /// this device goes on appending and goes on applying its own lines, while
    /// every peer quarantines them as *after retirement*. The divergence is
    /// permanent, and the only machine that can see both halves of it is this
    /// one — which is why `retirementNotice` exists and why two surfaces draw
    /// it (fix round 1, Important 2).
    public let retiredAt: Date?

    /// **This book holds a record naming this device that does not verify**
    /// (P2 smoke find 1).
    ///
    /// A record present and unreadable is not a record absent (RULING-54), and
    /// the two used to answer the same sentence here: a tampered or
    /// half-written own record contributes nothing to the registry, so this
    /// device fell out of every chain and read *Not yet admitted — the Mac will
    /// ask*. It is the worst possible answer, because nobody is going to ask:
    /// the record IS there, and until somebody puts it back or replaces it the
    /// writer is waiting for a sheet that is not coming.
    public let ownRecordUnverified: Bool

    /// The registry read's own sentence, when the read refused. Nil otherwise.
    public let refusal: String?

    public init(
        code: String,
        label: String? = nil,
        rootLabel: String? = nil,
        joinedAt: Date? = nil,
        admitted: Bool = false,
        isRoot: Bool = false,
        revoked: Bool = false,
        retiredAt: Date? = nil,
        ownRecordUnverified: Bool = false,
        refusal: String? = nil
    ) {
        self.code = code
        self.label = label
        self.rootLabel = rootLabel
        self.joinedAt = joinedAt
        self.admitted = admitted
        self.isRoot = isRoot
        self.revoked = revoked
        self.retiredAt = retiredAt
        self.ownRecordUnverified = ownRecordUnverified
        self.refusal = refusal
    }

    // MARK: - Resolving

    /// This device's standing in `projectURL`, off a registry somebody else
    /// has already read and verified.
    ///
    /// **It reads no folder and mints no key but this device's own author
    /// key**, which is minted because showing the writer their own code is
    /// naming it. Everything after that enumerates: no other actor's key is
    /// brought into existence by looking at a Settings row.
    ///
    /// The root is `TrustTable`'s decision, taken with the memory's joined
    /// root exactly as every reader takes it, so this surface cannot disagree
    /// with what the op log applies.
    nonisolated public static func resolve(
        registry: Registry,
        cache: RegistryCache,
        mine: LocalIdentities,
        for projectURL: URL
    ) -> DeviceStanding {
        let author = mine.author
        let code = DeviceCode.short(author.fingerprint)
        let table = TrustTable.resolve(
            registry: registry, mine: mine,
            joinedRoot: cache.joinedRoot(for: projectURL))

        // **Read before the chain guard, on purpose.** A retirement is a
        // device's word about ITSELF, signed by its own key, and it is true
        // whether or not anybody admitted it: a Mac that retired and was then
        // dropped from every chain has still stopped, and the sentence it is
        // owed does not depend on a root.
        let retiredAt = registry.devices
            .first { $0.device == author.fingerprint }?.retiredAt

        // A record naming THIS device that is present and will not verify.
        // Read alongside the retirement and for its reason: it is true whether
        // or not any chain here counts this device, and it is the difference
        // between *nobody has got round to you* and *the file that says who you
        // are is damaged* (smoke find 1). Records are named by the device's
        // author key, which is why one fingerprint answers both directories.
        let ownRecordUnverified = registry.malformed.contains { fault in
            guard let ref = fault.ref else { return false }
            return ref.fingerprint == author.fingerprint
                && (ref.directory == .people || ref.directory == .devices)
        }

        guard let root = table.myRoot,
              registry.chain(underRoot: root).contains(author.fingerprint)
        else {
            return DeviceStanding(
                code: code, retiredAt: retiredAt,
                ownRecordUnverified: ownRecordUnverified)
        }

        let record = registry.person(author.fingerprint)
        let rootLabel = registry.person(root)?.label
        let isRoot = root == author.fingerprint
        let revoked = record?.isRevoked ?? false

        return DeviceStanding(
            code: code,
            label: record?.label,
            rootLabel: rootLabel,
            // A join stamp is about joining somebody else's chain; a root
            // joined nothing.
            joinedAt: isRoot ? nil : cache.joinedAt(for: projectURL),
            admitted: !revoked,
            isRoot: isRoot,
            revoked: revoked,
            retiredAt: retiredAt,
            ownRecordUnverified: ownRecordUnverified)
    }

    /// The standing of a device whose registry could not be read: its own code,
    /// and the read's own sentence in place of every other answer.
    nonisolated public static func refused(
        mine: LocalIdentities, error: Error
    ) -> DeviceStanding {
        DeviceStanding(
            code: DeviceCode.short(mine.author.fingerprint),
            refusal: error.localizedDescription)
    }

    // MARK: - Saying it

    /// The one sentence a surface draws. The code is NOT in it: a surface
    /// shows the code in its own right (the phone's Settings row, the Mac's
    /// People & Devices header), and repeating it inside the sentence would
    /// give the writer two things to compare where there is one.
    /// **Started on, not rooted** (Denver's wording ruling, 2026-09-18). Every
    /// arm below used to speak the registry's own words — *root*, *chain*,
    /// *record*, *vouches* — which name real things and name nothing a writer
    /// has. They are all one fact said four ways, so all four now say that
    /// fact: **a book is started on a Mac, and that Mac decides who is in it.**
    /// Nothing about which arm is reached moved; only the words did.
    public var sentence: String {
        if let refusal { return refusal }
        if revoked {
            // Where to go is half of what a removed device needs, so the
            // sentence still names the Mac even though it no longer calls it a
            // root.
            return "No longer admitted — this book was started on "
                + "\(rootLabel ?? label ?? code)"
        }
        guard admitted else {
            // **Nobody is going to ask** (smoke find 1). The file is there; it
            // is the file that is wrong. A device told *not yet* over one waits
            // for a sheet that is not coming. No noun for the machine here,
            // because this type is shared and a phone saying *this Mac* about
            // itself is the two screens failing to compare (tripwire 19).
            if ownRecordUnverified {
                return "This book’s file about this device doesn’t check out, "
                    + "so nothing here confirms it"
            }
            return "Not yet admitted — the Mac will ask"
        }
        // **This Mac's own sentence names no machine** (P2 smoke find 2). It is
        // drawn at the head of a list in which this device already has a person
        // row and a device row, and naming it a third time had one Mac read as
        // three machines.
        if isRoot { return "This book was started on this Mac" }
        // Two facts for a device somebody else took in — what this book calls
        // it, and where that was decided — because the second is the one that
        // says which Mac to go to, and a phone with several books needs it.
        let me = label ?? code
        let startedOn = "Started on \(rootLabel ?? code)."
        guard let joinedAt else { return "In this book as \(me). \(startedOn)" }
        return "In this book as \(me) since "
            + "\(Self.dayFormatter.string(from: joinedAt)). \(startedOn)"
    }

    // MARK: - What retirement means, on the machine that did it

    /// **What every retirement sentence ends in**, so the notice and the
    /// warning cannot drift apart: two surfaces and a confirmation alert all
    /// describe one consequence, and a writer who reads it before pressing and
    /// again afterwards must meet the same words.
    ///
    /// `device` is the machine's own noun — *Mac*, *iPhone* — because this type
    /// is shared (tripwire 19) and a phone saying *this Mac* about itself is
    /// the comparison between two screens failing.
    nonisolated public static func retirementTail(device: String) -> String {
        "stays on this \(device) and is set aside everywhere else"
    }

    /// The standing fact, for the machine that retired: what it is still doing,
    /// and what nobody else is doing with it.
    nonisolated public static func retirementNotice(
        device: String, retiredAt: Date
    ) -> String {
        "This \(device) retired on \(dayFormatter.string(from: retiredAt)); "
        + "what it writes now \(retirementTail(device: device))."
    }

    /// This device's own notice, or nil while it is still at work.
    nonisolated public func retirementNotice(device: String) -> String? {
        guard let retiredAt else { return nil }
        return Self.retirementNotice(device: device, retiredAt: retiredAt)
    }

    /// The same consequence in the future tense, for the confirmation the
    /// writer meets BEFORE the act (fix round 1, Important 3a). Retirement has
    /// no inverse — a device that retired can only come back as a new key — and
    /// the sentence says so rather than leaving the writer to find out.
    nonisolated public static func retirementConsequence(device: String) -> String {
        "From then on, what this \(device) writes \(retirementTail(device: device)). "
        + "A \(device) can’t be un-retired."
    }

    /// *9 Sep* — day and month, localized, because a chain a writer joined
    /// this year is dated by the day they did it and never by a timestamp.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }()
}
