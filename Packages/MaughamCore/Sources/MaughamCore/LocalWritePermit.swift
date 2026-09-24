import Foundation

/// **What this device's own hand may write into one stream** (P3a Task 8).
///
/// Every other permit question in this milestone is asked of a line that
/// already exists: a seal names a key, the key names a person, the person's
/// timeline says what they could write when they wrote it. This one is asked
/// BEFORE a line exists — by the load seam, which must not mint a `bootstrap`
/// this device may not sign, and by P3c's membrane, which must not let a
/// keystroke become an op the next read sets aside. It is the same table
/// (`Permit.allows`); what differs is that the answer is wanted in advance.
///
/// **Resolved once and carried**, rather than asked per op. The two inputs are
/// a folder read (the registry, behind `OpLogStore`'s own cached table) and a
/// manifest decode (the document class), and one document emits many lines. A
/// `Document` stamps one of these at load and every later question is a switch.
///
/// **The neutral case costs nothing at all.** A book with no permit events —
/// which is every book written before P3, every keyless book, and every book
/// this Mac roots — answers `PermitTimeline.bookAuthor`, and the writer's own
/// hand under that permit may write every class, so the document class is never
/// resolved and no manifest is read. That is what makes this behaviour-neutral
/// for every project already on disk rather than merely equivalent.
public struct LocalWritePermit: Equatable, Sendable {

    /// This device's own permit in this book, as of the load.
    public let permit: Permit

    /// **The key this value answers for.** A device is four writers and they do
    /// not share a permit (spec §2), so the narrowing is part of the question
    /// rather than an argument to it — which is what lets `documentClass` be
    /// nil safely: *nil* means *no question THIS value can be asked turns on
    /// where the stream sits*, and that is only decidable once the actor is
    /// fixed.
    public let actor: DeviceActor

    /// Where this stream sits — resolved ONLY when an answer could turn on it.
    public let documentClass: DocumentClass?

    /// **Whether this Mac started the piece** (P3c plan 2, Option A; rulings
    /// OA-1 and OA-2) — `true` where this very device is the piece's recorded
    /// starter, `false` where some other device is, and **nil where the
    /// starter rule does not bind**: a book in which nobody is narrowed, a
    /// piece with no starter recorded (made before this build), or a stream
    /// that is not a piece. Nil is today's rule, exactly.
    ///
    /// Read by `mayMintOpening` alone.
    public let startedHere: Bool?

    /// **Option A's arm** (ruling OA-3): an author of some pieces, in a piece
    /// one of her own devices started, which is outside her scope and which
    /// no book author has written a word of. Her manuscript text there is
    /// `.yes` on her own Mac — the same line the partition applies on her Mac
    /// and holds on every other one — until the root says whose it is.
    ///
    /// Decided once, by `OpLogStore.localWritePermit`, from the three facts
    /// the partition's arm asks (`PermitPartition.appliesOnItsWritersOwnMac`),
    /// and false everywhere else — every book nobody is narrowed in included.
    public let writesAsItsStarter: Bool

    public init(
        permit: Permit, actor: DeviceActor, documentClass: DocumentClass?,
        startedHere: Bool? = nil, writesAsItsStarter: Bool = false
    ) {
        self.permit = permit
        self.actor = actor
        self.documentClass = documentClass
        self.startedHere = startedHere
        self.writesAsItsStarter = writesAsItsStarter
    }

    /// The answer every book already on disk gives the writer's own hand:
    /// author of the whole book, from the start, with nothing to place.
    public static let unrestricted = LocalWritePermit(
        permit: .bookAuthor, actor: .author, documentClass: nil)

    /// **The most restrictive class there is.**
    ///
    /// A project statement is the book author's alone (spec §2): `authors` is
    /// true for `.author(.book)` and false for every other permit, and no other
    /// class refuses anything this one allows. So it is the class to stand in
    /// when there is none — and for the one permit the nil arm is ever built
    /// under, the whole book's, it gives the same answer every class does.
    /// Pinned by `LocalWritePermitTests`.
    public static let hardestClass: DocumentClass = .projectStatement

    /// May this device's own `actor` key write `what` here?
    public func allows(_ what: Written) -> Allowed {
        answer(what, signedBy: actor)
    }

    /// **The table's answer, and Option A's one widening of it.**
    ///
    /// The widening moves a `.no` to `.yes` and nothing else, and only where
    /// `writesAsItsStarter` AND the permit layer's own §4.5 shape
    /// (`Permit.startsAPieceNobodyHasClaimed`) both say so — so it reaches
    /// manuscript text signed by her own hand and never a disposition, a
    /// checkpoint, a task, a translation, or any key but the author's.
    private func answer(_ what: Written, signedBy key: DeviceActor) -> Allowed {
        let cls = documentClass ?? Self.hardestClass
        let answer = permit.allows(what, in: cls, actor: key)
        guard writesAsItsStarter, case .no = answer,
              permit.startsAPieceNobodyHasClaimed(what, in: cls, actor: key)
        else { return answer }
        return .yes
    }

    /// **Is the `.yes` for her words here Option A's, rather than her scope's?**
    /// — what makes a posture say *waiting for the root to say this piece is
    /// yours* while every writing verb is offered. Asked of the one line
    /// typing writes, so it is true exactly where the widening decided it.
    public var isWaitingToBeClaimed: Bool {
        guard writesAsItsStarter else { return false }
        let cls = documentClass ?? Self.hardestClass
        let text = Written.op(.typingBurst)
        return permit.allows(text, in: cls, actor: actor) != .yes
            && answer(text, signedBy: actor) == .yes
    }

    /// **May this Mac mint the piece's opening?** — the ONE predicate the
    /// load's bootstrap guard asks (P3c plan 2, Option A; rulings OA-1, OA-2).
    ///
    /// - **The starter rule, in a narrowed book**: only the device the piece
    ///   records as its starter mints its opening — the root included (OA-2),
    ///   and her own OTHER Mac included (Review Focus 1: it waits, then
    ///   applies her lines when they arrive). And even there only where this
    ///   Mac may write the opening at all, so a reviewer named as a starter
    ///   by an unsigned manifest mints nothing.
    /// - **No starter recorded, or a book nobody is narrowed in**: today's
    ///   rule exactly — whoever may write the piece's text mints it.
    public var mayMintOpening: Bool {
        let opening = allows(.op(.bootstrap)) == .yes
        guard let startedHere else { return opening }
        return startedHere && opening
    }

    /// **May this key start a piece at all?** — the `.startAPiece` verb's
    /// question (P3c plan 2, Option A widens ruling R3).
    ///
    /// The table's answer in the hardest class says *yes* for a book author's
    /// hand, whose every piece is already theirs. An author of some pieces is
    /// refused there, and she may now open a piece of her own
    /// (`Permit.mayOpenAPieceOfTheirOwn`, the permit layer's one spelling of
    /// which key on which rung may): that is a `.yes`. A reviewer, a narrowed
    /// actor and a permit this build cannot read keep the table's answer.
    public func allowsStartingAPiece() -> Allowed {
        let answer = permit.allows(
            .op(.typingBurst), in: Self.hardestClass, actor: actor)
        guard case .no = answer, permit.mayOpenAPieceOfTheirOwn(actor: actor)
        else { return answer }
        return .yes
    }

    /// **The same question of another of this device's keys.**
    ///
    /// For the one caller that signs with a key other than the one the permit
    /// was resolved under: the task rebalance is `maugham`'s act, on a document
    /// the writer's hand opened. Only the VERDICT is reliable here — where the
    /// class was not resolved, a refusal's NOUN is computed against the stand-in
    /// class and could name *a statement* where *the manuscript* is the truer
    /// word — so no surface reads this; its caller compares against `.yes`.
    public func allows(_ what: Written, signedBy other: DeviceActor) -> Allowed {
        answer(what, signedBy: other)
    }

    /// **Whether the class need not be resolved at all** — asked of a bare
    /// permit, because the caller that asks it (`OpLogStore.localWritePermit`)
    /// is deciding whether to PAY for a manifest decode and has no class yet.
    ///
    /// One condition, and deliberately not a per-kind probe: the writer's own
    /// hand under a whole-book permit gives the same answer in every class, for
    /// every kind, so nothing that can be asked of the resulting value can be
    /// answered wrongly by the stand-in class. A narrowed actor is excluded
    /// even under that permit — the assistant's refusals name a NOUN, and the
    /// noun is the one thing the class still changes.
    public static func answersWithoutTheClass(
        _ permit: Permit, as actor: DeviceActor
    ) -> Bool {
        permit == .bookAuthor && actor == .author
    }
}
