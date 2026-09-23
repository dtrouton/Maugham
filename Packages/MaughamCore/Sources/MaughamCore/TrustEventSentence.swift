import Foundation

/// One `TrustEvent`, in the writer's words.
///
/// **Shared, because two surfaces draw the same day's events** (tripwire 19).
/// History's project section is the Mac's; the phone's Settings tab shows this
/// device's own chain and what happened to it. Two spellings of *Sam revoked by
/// Denver* would be two answers to one question, and the writer comparing a Mac
/// against a phone is exactly the moment a difference would matter.
///
/// **No date in any sentence.** Every one of these is drawn in a dated row, so
/// a sentence carrying the day would print it twice — and the undated events
/// (a claimant; a join from a memory written before the stamp existed) would
/// then need a second grammar of their own. The row draws `TrustEvent.date`
/// when there is one and nothing when there is not; the sentence is the same
/// either way.
public enum TrustEventSentence {

    /// The sentence for one event.
    ///
    /// `labels` maps a fingerprint to the name its record gives it. It is the
    /// second chance at a name: the event already carries its SUBJECT's names,
    /// so this is what resolves the other half — the root that admitted, the
    /// hand that revoked, the Mac that adopted — and what names a subject whose
    /// record this registry does not hold.
    nonisolated public static func sentence(
        for event: TrustEvent, labels: [String: String]
    ) -> String {
        let subject = name(of: event, labels: labels)
        let actor = event.by.map { name($0, labels: labels) }

        switch event.kind {
        case .admitted:
            let rung = rung(of: event)
            return actor.map { "\(subject) admitted by \($0)\(rung)." }
                ?? "\(subject) admitted\(rung)."
        case .silentlyAdmitted:
            let rung = rung(of: event)
            return actor.map { "\(subject) admitted automatically by \($0)\(rung)." }
                ?? "\(subject) admitted automatically\(rung)."
        case .readmitted:
            let rung = rung(of: event)
            return actor.map { "\(subject) let back in by \($0)\(rung)." }
                ?? "\(subject) let back in\(rung)."
        case .roleChanged, .scopeChanged:
            // **Both directions, in one sentence** (spec §5). What the permit
            // became, and then what did NOT move because of it — which is the
            // half a writer comes to History to check, and the half that is
            // opposite for a demotion and a promotion.
            let became = event.permit.map { "became \(phrase(for: $0))" }
                ?? "had their permission changed"
            return "\(subject) \(became).\(consequence(of: event))"
        case .revoked:
            return actor.map { "\(subject) revoked by \($0)." } ?? "\(subject) revoked."
        case .revokedEntirely:
            // The sentence says what the writer chose, because the difference
            // is the whole of what they will come here to check: one left the
            // draft as they had read it and one did not.
            return actor.map {
                "\(subject) revoked by \($0), and everything it wrote set aside."
            } ?? "\(subject) revoked, and everything it wrote set aside."
        case .retired:
            return "\(subject) retired."
        case .claimed:
            return "\(subject) claimed this book."
        case .adopted:
            // The claimant leads: it is the one who acted, and the subject is
            // the history it took in. **The one arm where the subject is not
            // sentence-initial** (P2b Task 8), which is why *This Mac* is said
            // in lower case here: the reciprocal half of a merge reads
            // *Denver's MacBook adopted this Mac's history* on the other
            // machine, and a capital in the middle of that sentence is the
            // shape a writer reads twice.
            let inSentence = event.isMine ? "this Mac" : subject
            return actor.map { "\($0) adopted \(possessive(inSentence)) history." }
                ?? "\(possessive(inSentence)) history was adopted."
        case .joined:
            return "This Mac joined \(possessive(subject)) chain."
        case .anotherClaimant:
            // The unnamed case is the one that actually happens — another Mac
            // this book holds no record for — and its code is what that Mac
            // shows for itself, so the writer can check one screen against the
            // other.
            return event.label == nil && labels[event.subject] == nil
                ? "Another Mac (\(DeviceCode.short(event.subject))) also claims this book."
                : "\(subject) also claims this book."
        case .recordRestored:
            return "\(possessive(subject)) record was missing and has been put back."
        }
    }

    // MARK: - The permit, in words

    /// What to call a permit in a sentence.
    ///
    /// **Never the wire word.** `"author"` and `"pieces"` are what a signed file
    /// carries; what a writer reads is what it means, and the middle rung is
    /// meaningless without a count. An `.unjudgeable` permit is a word a LATER
    /// build wrote, and the honest thing to say about it is that this one
    /// cannot read it — never a guess at a rung, because the guess would be
    /// read as a fact about somebody's access.
    nonisolated static func phrase(for permit: Permit) -> String {
        switch permit {
        case .reviewer:
            return "a reviewer"
        case .author(.book):
            return "an author of the whole book"
        case .author(.pieces(let pieces)):
            if pieces.isEmpty { return "an author of no pieces yet" }
            return pieces.count == 1
                ? "an author of one piece"
                : "an author of \(pieces.count) pieces"
        case .unjudgeable:
            return "something this version of Maugham doesn’t recognise"
        }
    }

    /// `, as a reviewer` — the rung an arrival was let in at, or nothing at all
    /// where it is the one every P2 admission meant.
    ///
    /// Empty for an author of the whole book so that every sentence a book
    /// written before P3 draws is unchanged to the character: adding *as an
    /// author of the whole book* to every admission in every existing project
    /// would be a milestone announcing itself in rows about the past.
    nonisolated static func rung(of event: TrustEvent) -> String {
        guard let permit = event.permit, permit != .bookAuthor else { return "" }
        return ", as \(phrase(for: permit))"
    }

    /// **What did not move**, which is the other half of every permit change.
    ///
    /// A NARROWING leaves what was already applied in the book — *a demotion
    /// does not reach back*. A WIDENING leaves what was already refused out of
    /// it — *a promotion is not a pardon*. They are opposite sentences about
    /// the same mark, and a surface that carried one of them would be telling
    /// the writer the wrong thing half the time.
    ///
    /// A change that is neither wider nor narrower — two disjoint piece lists,
    /// a word this build cannot read — gets the conservative half, because the
    /// one thing true of every such change is that the mark does not reach
    /// backwards.
    nonisolated static func consequence(of event: TrustEvent) -> String {
        guard let permit = event.permit, let previous = event.previousPermit
        else { return "" }
        let widened = permit.covers(previous) && !previous.covers(permit)
        return widened
            ? " Anything set aside before then stays set aside."
            : " What they wrote before then stays in the book."
    }

    // MARK: - Naming

    /// What to call the event's subject: *This Mac* when it is this device,
    /// else `<label> (<ownName>)` where a person's two names differ (spec §3),
    /// else the one name there is, else the four-character code.
    nonisolated static func name(of event: TrustEvent, labels: [String: String]) -> String {
        if event.isMine { return "This Mac" }
        guard let label = event.label ?? labels[event.subject] else {
            return DeviceCode.short(event.subject)
        }
        guard let ownName = event.ownName, ownName != label else { return label }
        return "\(label) (\(ownName))"
    }

    /// A fingerprint the event carries no names for — the admitting root, the
    /// revoking hand, the claimant that adopted.
    nonisolated static func name(_ fingerprint: String, labels: [String: String]) -> String {
        labels[fingerprint] ?? DeviceCode.short(fingerprint)
    }

    /// **Why this row names four characters and nothing else** (P3b Task 7),
    /// or nil where it names somebody.
    ///
    /// A bare code is honest and useless on its own: it cannot be told from *a
    /// Mac I have never heard of*, and the case that actually happens is the
    /// opposite one — a root admits somebody, the EVENT syncs, and the person
    /// record lands a minute later. Until it does, every surface that resolves
    /// a name off the registry has nothing, and History drew a row that
    /// explained none of it.
    ///
    /// **Beside the sentence, not inside it.** `sentence(for:labels:)` is
    /// shared with the phone and pinned to the byte in both surfaces' tests;
    /// the row composes the two, so the clause can be drawn where there is
    /// room for it and left out where there is not.
    ///
    /// **Not every kind wants it**, and the switch has no `default:` so a
    /// fourteenth kind has to decide. A claimant is another Mac's root by
    /// definition, and a claim, an adoption and a join are all about somebody
    /// outside this chain — telling the writer their record has not arrived
    /// would be telling them to wait for something that is not coming.
    nonisolated public static func unknownSubject(
        for event: TrustEvent, labels: [String: String]
    ) -> String? {
        guard !event.isMine,
              event.label == nil, labels[event.subject] == nil
        else { return nil }
        switch event.kind {
        case .admitted, .silentlyAdmitted, .readmitted, .roleChanged,
             .scopeChanged, .revoked, .revokedEntirely, .retired,
             .recordRestored:
            return "This Mac hasn’t received their record yet."
        case .claimed, .adopted, .joined, .anotherClaimant:
            return nil
        }
    }

    /// `Sam` → `Sam’s`. A typographic apostrophe, because every other sentence
    /// in these surfaces uses one, and no special case for a name ending in s:
    /// the writer chose the name, and second-guessing their spelling of
    /// *Charles's* is not this function's business.
    nonisolated private static func possessive(_ name: String) -> String { "\(name)’s" }
}
