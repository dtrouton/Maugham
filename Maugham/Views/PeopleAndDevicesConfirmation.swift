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
/// **A value, not a sheet.** Everything on the alert is decided here and
/// compared in a test with nothing mounted (tripwire 33: no test presses a
/// mounted control and waits for its effect). The host presents it and calls
/// the verb when the writer confirms; this type never acts.
struct PeopleAndDevicesConfirmation: Identifiable, Equatable {

    /// Which act is being confirmed. The host switches on it to call the verb,
    /// so a third act is a compile error there rather than a silent no-op.
    enum Verb: String, Equatable {
        case revoke
        case retire
    }

    let verb: Verb
    /// The person (Revoke) or the device (Retire) the act is about. Under
    /// labels-only these are the same key and are still not the same argument.
    let fingerprint: String
    let title: String
    /// The consequence, in the words the surface uses for it afterwards.
    let message: String
    let confirmTitle: String

    /// Keyed on the verb AND the subject, so a writer who dismisses one and
    /// opens another gets a new alert rather than the old one's identity.
    var id: String { "\(verb.rawValue)-\(fingerprint)" }

    /// **Revoke**, carrying spec §5's own sentence — the one that says what
    /// Maugham will stop doing and what it cannot do.
    static func revoke(person fingerprint: String, named name: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .revoke,
            fingerprint: fingerprint,
            title: "Stop applying what \(name) writes?",
            message: PeopleAndDevicesModel.revokeSentence
                + " You can let them back in from this Mac.",
            confirmTitle: "Revoke")
    }

    /// **Retire**, carrying `DeviceStanding`'s own consequence — the same
    /// clause the standing notice uses afterwards, in the future tense, plus
    /// the fact that there is no way back.
    static func retire(device fingerprint: String, named name: String,
                       kind: String) -> Self {
        PeopleAndDevicesConfirmation(
            verb: .retire,
            fingerprint: fingerprint,
            title: "Retire \(name)?",
            message: DeviceStanding.retirementConsequence(device: kind),
            confirmTitle: "Retire")
    }
}
