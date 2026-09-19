import Foundation

/// **What one person may write in this book** (P3 spec §2, §3.1).
///
/// P2 asked one question of a key — *is this somebody this book admits?* — and
/// that was the whole of the register. P3's question is the next one: admitted
/// to write WHAT. Three rungs, and the ladder is the spec's:
///
/// | rung | may sign |
/// |---|---|
/// | **reviewer** | annotations, their own annotations' edits, inbox rows |
/// | **author of some pieces** | everything, inside their pieces; the reviewer row everywhere else |
/// | **author of the whole book** | everything, project statements included |
///
/// **What it is not.** It is not a role NAME and no surface should ask it for
/// one: *reviewer* is a rung here, and the same word is an English noun in a
/// dozen places in this app. It is also not a decision — `Permit.allows` (P3a
/// Task 4) is the one table that turns a permit plus what was written plus the
/// actor key into *yes* / *no* / *cannot judge*.
///
/// **The fourth case is the one that matters most.** A permit is parsed from
/// strings in a signed file, and a build that meets a `role` or a `scope` it
/// does not recognise has met a LATER build's vocabulary. It must not guess,
/// and above all it must not guess *reviewer*: the global rule (spec §3.1,
/// §4.2) is that an unrecognised role, scope or event kind holds that person's
/// lines PENDING and never sets them aside — an older Mac must not quarantine
/// what a newer one would apply. `.unjudgeable` is how that reaches the table.
public enum Permit: Equatable, Hashable, Sendable {

    /// Annotations and inbox rows; never the manuscript.
    case reviewer

    /// Everything, inside `Scope`.
    case author(Scope)

    /// A role or scope string this build does not recognise, carried under its
    /// own name. Lines under it are held pending, never refused.
    case unjudgeable(raw: String)

    /// How much of the book an author's permit covers.
    public enum Scope: Equatable, Hashable, Sendable {
        /// The whole book, project statements included.
        case book
        /// These document ids and no others. **Legitimately empty**: *she may
        /// write what she starts* is a real state, and it is why the wire
        /// format spells `"pieces"` explicitly rather than hanging the
        /// distinction on an absent key.
        case pieces(Set<String>)
    }

    /// What every P2-era admission meant, and what a person with no events in
    /// their history still means (`PermitTimeline.bookAuthor`).
    public static let bookAuthor: Permit = .author(.book)

    // MARK: - The wire vocabulary

    /// The four strings a record or an event may carry, spelled once.
    ///
    /// Here rather than at the writers, because the reader that parses them and
    /// the verb that writes them (`RegistryAdmission.changePermit`, Task 7) must
    /// not be two opinions about how the word *author* is spelled — a mismatch
    /// would not fail, it would read as an unrecognised role and hold somebody's
    /// whole history pending.
    public static let authorRole = "author"
    public static let reviewerRole = "reviewer"
    public static let bookScope = "book"
    public static let piecesScope = "pieces"

    // MARK: - Reading one

    /// **The one parse**, from the three strings a `PersonRecord` or a
    /// `PermitEvent` carries.
    ///
    /// - A **missing scope** is `"book"` — what every P2-era record means, and
    ///   the reason the field is optional rather than defaulted on the record.
    /// - `"pieces"` **with no list** is the empty set, not the whole book.
    /// - **Anything else** — a role this build does not know, a scope this
    ///   build does not know — is `.unjudgeable`, under the raw word that was
    ///   not recognised.
    ///
    /// A `pieces` list under `"book"` is ignored rather than refused: it is
    /// meaningless there by the format's own definition, and a later build that
    /// gives it a meaning will say so with a scope word of its own.
    public static func parse(role: String, scope: String?, pieces: [String]?) -> Permit {
        let scopeWord = scope ?? bookScope
        guard scopeWord == bookScope || scopeWord == piecesScope else {
            return .unjudgeable(raw: scopeWord)
        }
        switch role {
        case Self.reviewerRole:
            return .reviewer
        case Self.authorRole:
            return scopeWord == piecesScope
                ? .author(.pieces(Set(pieces ?? [])))
                : .author(.book)
        default:
            return .unjudgeable(raw: role)
        }
    }

    /// The permit an event INSTALLS.
    ///
    /// The event's `kind` is deliberately not consulted here — whether a kind
    /// installs a permit at all is `PermitTimeline`'s question, and a revocation
    /// carries a role and a scope it does not mean to change.
    public init(event: PermitEvent) {
        self = Permit.parse(role: event.role, scope: event.scope, pieces: event.pieces)
    }

    /// Nothing can be decided from this permit, so lines under it are PENDING.
    public var isUnjudgeable: Bool {
        if case .unjudgeable = self { return true }
        return false
    }

    // MARK: - The root

    /// **A root is an author of the whole book, unconditionally** (spec §2).
    ///
    /// It alone admits, revokes and changes a permit, and a book must not end
    /// up with no author — so an event that would give the root anything else
    /// is not a demotion this app performs, it is a file nobody should have
    /// written. `RegistryReader` asks this and LISTS such an event malformed
    /// (`MalformedRecord.Reason.eventDemotesARoot`); `TrustTable` answers the
    /// root's timeline as the default whatever the folder holds. Two guards for
    /// one rule, deliberately: the reader's is about the FILE — a `Registry`
    /// built any other way, in a test or from a later build's bytes, must not
    /// be able to talk this device out of its own root's authority.
    ///
    /// An unrecognised role reaches this as `.unjudgeable` and is refused with
    /// the rest. Holding the root's own lines pending would be the one case
    /// where *pending, never set aside* costs the writer their own book, and
    /// the root's permit is the maximum permit anyway: there is nothing a later
    /// build could widen it to.
    public static func contradictsARoot(_ event: PermitEvent) -> Bool {
        Permit(event: event) != .author(.book)
    }
}
