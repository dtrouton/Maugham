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
            return actor.map { "\(subject) admitted by \($0)." } ?? "\(subject) admitted."
        case .silentlyAdmitted:
            return actor.map { "\(subject) admitted automatically by \($0)." }
                ?? "\(subject) admitted automatically."
        case .revoked:
            return actor.map { "\(subject) revoked by \($0)." } ?? "\(subject) revoked."
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

    /// `Sam` → `Sam’s`. A typographic apostrophe, because every other sentence
    /// in these surfaces uses one, and no special case for a name ending in s:
    /// the writer chose the name, and second-guessing their spelling of
    /// *Charles's* is not this function's business.
    nonisolated private static func possessive(_ name: String) -> String { "\(name)’s" }
}
