import Foundation

/// **What this Mac may OFFER for the document shown** (P3 spec §8; P3c Task 1).
///
/// P3a enforced the permit where lines are READ: a line its signer could not
/// write is set aside, whoever's Mac it came from. That makes the book safe and
/// leaves the writer's own Mac rude — a reviewer can still press Accept, and the
/// next read quietly sets her own act aside. `Posture` is the other half: the
/// one value every Mac surface asks *may I draw this verb?*, so a verb the table
/// would refuse is never offered in the first place.
///
/// **Asked of the permit, never re-derived.** A posture is built from a
/// `LocalWritePermit` — `OpLogStore.localWritePermit` is the one answer to *may
/// this device's actor write here* (tripwire 46) — and every verb is answered
/// by that permit's own `allows`, which is `Permit.allows`, the one table
/// (tripwire 44). What lives here is ONE switch from a surface's verb to the
/// line that verb would write, and nothing else. No rung is compared to decide
/// a verb (tripwire 47); the rung is read once, in `reason`, only to NAME why.
///
/// **Behaviour-neutral where nothing is narrowed.** `.unrestricted` — every book
/// on disk before P3, every keyless book, every book this Mac roots — allows
/// every verb, so `Posture.author` is P1's posture exactly.
///
/// **What it is not.** It is not a storage guard: *roles guard the words, not
/// the binder* (ADR 0032's limits), so the structural verbs are hidden
/// COOPERATIVELY and nothing at storage refuses a reviewer's manifest write.
/// And it is not a sharing role — an iCloud read-only share is a separate,
/// OS-level lock that claims no role.
public struct Posture: Equatable, Sendable {

    /// The permit the posture was built from. Private on purpose: a surface
    /// that could read it could ask it a question of its own, which is the
    /// second table this type exists to prevent.
    private let permit: LocalWritePermit

    /// **The root's cooperative review posture** (spec §2, §8): the name of the
    /// person whose piece this is, when this Mac — a whole-book author — has
    /// chosen to yield to them. While it is set every verb but `annotate`
    /// answers false. The Mac's override (plan ruling R2) builds the posture
    /// WITHOUT it; nothing here knows about the override.
    public let yieldingTo: String?

    /// True only for `settling`: nothing is decided yet, and only the
    /// reviewer row is offered.
    private let undecided: Bool

    public init(_ permit: LocalWritePermit, yieldingTo: String? = nil) {
        self.permit = permit
        self.yieldingTo = yieldingTo
        self.undecided = false
    }

    private init(undecidedOver permit: LocalWritePermit) {
        self.permit = permit
        self.yieldingTo = nil
        self.undecided = true
    }

    /// The writer's own hand, author of the whole book: every verb.
    public static let author = Posture(.unrestricted)

    /// **Not yet decided** (P3c Task 2, fix round 1) — the Mac's door's answer
    /// for a document it has never answered, in a book that HAS a register,
    /// in the moments before its off-main table lands. Only `annotate` is
    /// offered, because the reviewer row is every rung's: a verb appearing a
    /// frame late is fine, and a verb appearing that must not is not. `reason`
    /// is nil — nothing is known to name — and `isSettling` says so. Never
    /// the answer in a book with no register, and never the answer a verb's
    /// own door acts on (`settledPosture` does not return it).
    public static let settling = Posture(undecidedOver: .unrestricted)

    /// This is `settling`: an answer still on its way, not a refusal.
    public var isSettling: Bool { undecided }

    // MARK: - The verbs

    /// **Every verb a Mac surface gates on.** Count the cases, not a comment.
    ///
    /// A new surface verb joins by adding a case here and an arm to `probe`,
    /// whose switch carries no `default:` so the compiler asks which line the
    /// new verb would write.
    public enum Verb: CaseIterable, Sendable {
        /// Typing in the editor.
        case writeText
        /// Accepting or rejecting a suggestion — moves the words.
        case acceptOrReject
        /// Stet, archive, triage, reopen — settling somebody's note.
        case dispose
        /// A review pass's state on a piece (a manifest field; plan ruling R3).
        case setPassState
        /// Editing a statement's prose — intent, visual language, lessons, a
        /// first reader, an edition brief, a piece's own intent.
        case editStatement
        /// Rename, reorder, move, trash in the tree (cooperative; ruling R3).
        case restructure
        /// New Document / New Group at the root of the tree (ruling R3).
        case startAPiece
        /// Review's Run — a round, which stamps a pass and moves its lane
        /// (ruling R4). Author's check is not gated: it writes the reviewer row.
        case runRound
        /// ⌘S's labelled checkpoint (ruling R5 — ⌘S still flashes).
        case checkpoint
        /// Making or changing a task.
        case task
        /// Writing a translation.
        case translate
        /// Leaving a note: comment, query, suggestion, craft note. The reviewer
        /// row — everybody's.
        case annotate
    }

    /// Why a posture refuses the words of the document it was built for.
    public enum Reason: Equatable, Sendable {
        /// A reviewer: notes, never the manuscript. Also the answer where the
        /// ACTOR key narrows a permit that would otherwise write here — the
        /// assistant is the reviewer row on every device.
        case reviewer
        /// An author of some pieces, and this is not one of them.
        case notYourPiece
        /// The root, yielding cooperatively to the person whose piece it is.
        case yielding(to: String)
        /// A permit this build cannot read (a later build's rung or scope), or a
        /// statement it cannot place. Nothing is decided about the words.
        case cannotJudge
    }

    // MARK: - The one switch

    /// What a verb would write, and where it is asked.
    private struct Probe {
        let what: Written
        /// Asked of `LocalWritePermit.hardestClass` instead of this document's
        /// class: starting a piece is a book-author's act until plan 2 widens
        /// it (ruling R3).
        let asAnyNewPiece: Bool
    }

    /// **The ONE verb → line table.** No `default:`. Pass state, structure and a
    /// round are not ops; each is probed as *may you write this piece's text*
    /// (ruling R3/R4), because that is what a pass state and a structural verb
    /// are ABOUT and there is no op a later build could disagree with.
    private static func probe(_ verb: Verb) -> Probe {
        switch verb {
        case .writeText, .setPassState, .restructure, .runRound, .editStatement:
            return Probe(what: .op(.typingBurst), asAnyNewPiece: false)
        case .acceptOrReject:
            return Probe(what: .op(.claudeAccept), asAnyNewPiece: false)
        case .dispose:
            return Probe(what: .op(.annotationStet), asAnyNewPiece: false)
        case .startAPiece:
            return Probe(what: .op(.typingBurst), asAnyNewPiece: true)
        case .checkpoint:
            return Probe(what: .op(.checkpoint), asAnyNewPiece: false)
        case .task:
            return Probe(what: .op(.taskCreate), asAnyNewPiece: false)
        case .translate:
            return Probe(what: .translationRecord, asAnyNewPiece: false)
        case .annotate:
            return Probe(what: .op(.claudeComment), asAnyNewPiece: false)
        }
    }

    /// The table's answer for `verb`, handed to `read`. The permit layer alone
    /// PRODUCES an `Allowed` (tripwire 44); this file only reads one.
    private func withAnswer<T>(to verb: Verb, _ read: (Allowed) -> T) -> T {
        let probe = Self.probe(verb)
        if probe.asAnyNewPiece {
            return read(permit.permit.allows(
                probe.what, in: LocalWritePermit.hardestClass, actor: permit.actor))
        }
        return read(permit.allows(probe.what))
    }

    // MARK: - Asking

    /// **May a surface offer this verb?**
    ///
    /// - `.yes` offers it, unless the root is yielding (then only `annotate`).
    /// - `.no` never does.
    /// - `.cannotJudge` offers `annotate` alone: a permit this build cannot
    ///   read still lets her leave a note — the reviewer row, which every rung
    ///   contains — and NEVER lets her change text.
    public func allows(_ verb: Verb) -> Bool {
        if undecided { return verb == .annotate }
        return withAnswer(to: verb) { answer in
            switch answer {
            case .yes: return verb == .annotate || yieldingTo == nil
            case .no: return false
            case .cannotJudge: return verb == .annotate
            }
        }
    }

    /// Any verb refused. NB: an author of some pieces, inside her own piece, is
    /// restricted (she may not start a piece — ruling R3) while `reason` is nil,
    /// because the words she is looking at are hers.
    public var isRestricted: Bool {
        !Verb.allCases.allSatisfy { allows($0) }
    }

    /// **Why the words of this document are not hers to change**, or nil when
    /// they are. Derived here and nowhere else; the rung is read only to NAME
    /// the reason, never to decide a verb.
    public var reason: Reason? {
        if undecided { return nil }
        if let yieldingTo { return .yielding(to: yieldingTo) }
        let text = Self.probe(.writeText).what
        return withAnswer(to: .writeText) { answer -> Reason? in
            switch answer {
            case .yes:
                return nil
            case .cannotJudge:
                return .cannotJudge
            case .no:
                // The writer's own hand would be allowed: the refusal is the
                // ACTOR's narrowing, which is at most the reviewer row.
                if permit.allows(text, signedBy: .author) == .yes { return .reviewer }
                // Otherwise it is the rung's. A whole-book author's hand is
                // refused nothing, and an unreadable rung answered
                // `.cannotJudge` above, so those two arms name what they would
                // mean rather than a case `PostureTests` can build.
                switch Permit.rung(of: permit.permit) {
                case .somePieces: return .notYourPiece
                case .reviewer, .wholeBook: return .reviewer
                case nil: return .cannotJudge
                }
            }
        }
    }
}
