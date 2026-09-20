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

    public init(permit: Permit, actor: DeviceActor, documentClass: DocumentClass?) {
        self.permit = permit
        self.actor = actor
        self.documentClass = documentClass
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
        permit.allows(what, in: documentClass ?? Self.hardestClass, actor: actor)
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
        permit.allows(what, in: documentClass ?? Self.hardestClass, actor: other)
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
