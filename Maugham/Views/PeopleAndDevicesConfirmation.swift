// Maugham/Views/PeopleAndDevicesConfirmation.swift
import Foundation
import MaughamCore

/// **What the writer is asked before an act there is no way back from**
/// (signed op log P2b Task 7, fix round 1, Important 3a).
///
/// Revoke and Retire are one click and, today, one direction: a revocation can
/// be undone only by the root re-admitting, and a retirement cannot be undone
/// at all. Both sit on a row beside the control the writer presses to rename a
/// device. So each is confirmed first, and the confirmation carries the
/// CONSEQUENCE rather than a restatement of the verb — *are you sure* tells a
/// writer nothing they did not know when they pressed.
///
/// **Merge is the third** (Task 8), for the same reason from the other
/// direction: it is not destructive, it is ADMITTING — a whole chain of
/// somebody's devices begins applying in this book at once — and there is no
/// un-adopt verb anywhere in this milestone.
///
/// **A value, not a sheet.** Everything on the alert is decided here and
/// compared in a test with nothing mounted (tripwire 33: no test presses a
/// mounted control and waits for its effect). The host presents it and calls
/// the verb when the writer confirms; this type never acts.
struct PeopleAndDevicesConfirmation: Identifiable, Equatable {

    /// Which act is being confirmed. The host switches on it to call the verb,
    /// so a further act is a compile error there rather than a silent no-op.
    enum Verb: String, Equatable {
        case revoke
        case retire
        case merge
        case rename
        case restore
    }

    /// **The one thing the writer types** (P2 smoke find 3).
    ///
    /// Revoke, Retire and Merge need a yes; a rename needs a word, and the word
    /// is the whole act. It is carried here rather than kept in the host's own
    /// `@State` beside the confirmation, so *what the writer is asked, and what
    /// the field starts with* is part of the value a test compares with nothing
    /// mounted — the same reason everything else on the alert is.
    struct Field: Equatable {
        let prompt: String
        let initialValue: String
    }

    let verb: Verb
    /// The person (Revoke) or the device (Retire) the act is about. Under
    /// labels-only these are the same key and are still not the same argument.
    let fingerprint: String
    /// **Which FILE the act is about**, for the one verb that is about a file
    /// rather than a person (Restore, P2 smoke find 1). A fingerprint is half
    /// of a record — the same key can name a person record and a device record,
    /// and putting back the wrong one is putting back a record nobody asked
    /// for. Nil for every other verb, which are all about a key.
    let record: RecordRef?
    let title: String
    /// The consequence, in the words the surface uses for it afterwards.
    let message: String
    let confirmTitle: String
    /// What the writer types, for the one act that is about a word. Nil for
    /// every verb that only needs a yes.
    let field: Field?

    /// Keyed on the verb AND the subject, so a writer who dismisses one and
    /// opens another gets a new alert rather than the old one's identity — and
    /// on the DIRECTORY too where there is one, because one fingerprint can
    /// name a record in two of them.
    var id: String {
        guard let record else { return "\(verb.rawValue)-\(fingerprint)" }
        return "\(verb.rawValue)-\(record.directory.rawValue)-\(fingerprint)"
    }

    /// **Revoke**, carrying spec §5's own sentence — the one that says what
    /// Maugham will stop doing and what it cannot do.
    static func revoke(person fingerprint: String, named name: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .revoke,
            fingerprint: fingerprint,
            record: nil,
            title: "Stop applying what \(name) writes?",
            message: PeopleAndDevicesModel.revokeSentence
                + " You can let them back in from this Mac.",
            confirmTitle: "Revoke",
            field: nil)
    }

    /// **Merge**, carrying the consequence in the words the row uses for it
    /// afterwards: what this Mac will start applying, and the thing a writer
    /// might otherwise assume it means — that one of the two roots gives way.
    /// Neither does (B1).
    static func merge(root fingerprint: String, named name: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .merge,
            fingerprint: fingerprint,
            record: nil,
            title: "Is \(name) also you?",
            message: PeopleAndDevicesModel.mergeSentence,
            confirmTitle: "Merge",
            field: nil)
    }

    /// **Retire**, carrying `DeviceStanding`'s own consequence — the same
    /// clause the standing notice uses afterwards, in the future tense, plus
    /// the fact that there is no way back.
    static func retire(device fingerprint: String, named name: String,
                       kind: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .retire,
            fingerprint: fingerprint,
            record: nil,
            title: "Retire \(name)?",
            message: DeviceStanding.retirementConsequence(device: kind),
            confirmTitle: "Retire",
            field: nil)
    }

    /// **Rename**, the fourth and the only one that asks for a word rather than
    /// a yes (P2 smoke find 3).
    ///
    /// It is confirmed like the other three, for the opposite reason: not
    /// because it cannot be undone — it is the one act here that can, by
    /// renaming again — but because it is the one that needs something typed,
    /// and the message is where a writer learns what a label is and is not
    /// before they change one. A rename admits nobody and shuts nobody out.
    ///
    /// The field starts at the name that stands, so the ordinary edit is a
    /// correction rather than a re-typing, and Cancel and an untouched field
    /// come to the same thing.
    static func rename(person fingerprint: String, named name: String,
                       currently label: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .rename,
            fingerprint: fingerprint,
            record: nil,
            title: "What should this book call \(name)?",
            message: "A name is this book's word for them — every device on this "
                + "chain will see it. Changing it admits nobody and shuts nobody "
                + "out.",
            confirmTitle: "Rename",
            field: Field(prompt: "Name", initialValue: label))
    }

    /// **Restore**, the fifth, and the only one that writes over a file
    /// somebody else signed (P2 smoke find 1).
    ///
    /// It is confirmed because that is a decision, and because the writer is
    /// about to replace bytes Maugham has just told them do not verify. The
    /// message says what putting a record back is — the version this device saw
    /// verify, not a version it wrote — and what it is not: it forges nothing
    /// and admits nobody, because the next read checks the signature on it like
    /// any other.
    static func restore(record: RecordRef, named name: String, kind: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .restore,
            fingerprint: record.fingerprint,
            record: record,
            title: "Put back the \(kind) record for \(name)?",
            message: "This writes back the exact bytes this Mac last saw verify, "
                + "over the version that doesn\u{2019}t. It signs nothing and admits "
                + "nobody \u{2014} the next read checks it like any other record.",
            confirmTitle: "Restore",
            field: nil)
    }
}
