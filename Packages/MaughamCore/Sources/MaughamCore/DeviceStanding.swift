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
        refusal: String? = nil
    ) {
        self.code = code
        self.label = label
        self.rootLabel = rootLabel
        self.joinedAt = joinedAt
        self.admitted = admitted
        self.isRoot = isRoot
        self.revoked = revoked
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

        guard let root = table.myRoot,
              registry.chain(underRoot: root).contains(author.fingerprint)
        else {
            return DeviceStanding(code: code)
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
            revoked: revoked)
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
    public var sentence: String {
        if let refusal { return refusal }
        if revoked {
            return "No longer admitted to \(rootLabel ?? label ?? code)’s chain"
        }
        guard admitted else { return "Not yet admitted — the Mac will ask" }
        let me = label ?? code
        if isRoot { return "\(me), the root of this book’s chain" }
        let chain = "\(me) on \(rootLabel ?? code)’s chain"
        guard let joinedAt else { return chain }
        return "\(chain) since \(Self.dayFormatter.string(from: joinedAt))"
    }

    /// *9 Sep* — day and month, localized, because a chain a writer joined
    /// this year is dated by the day they did it and never by a timestamp.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }()
}
