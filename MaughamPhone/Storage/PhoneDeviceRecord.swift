import Foundation
import MaughamCore
import UIKit
import os

/// Diagnostic channel for the one thing declaring yourself can fail at
/// quietly: a registry folder that will not read or will not be written.
private let phoneRecordLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.phone",
    category: "PhoneDeviceRecord")

/// **This phone, saying who it is in a book it writes into** (P2 spec §2.1).
///
/// One place, reached from BOTH phone writers, because the answer must not
/// differ between an annotation and a capture: the same key, the same name,
/// the same kind. The record itself is MaughamCore's — `RegistryPresence` is
/// the one thing that decides what a device record says and the one thing that
/// signs it, on the Mac and here alike (tripwire 19). Nothing in this target
/// spells a record, a fingerprint or a path under `.maugham/`.
///
/// **It never writes a root.** The first root record is the Mac's (spec §3):
/// it owns the folder and there is nobody else to ask. The phone declares
/// itself and waits — until the Mac admits it, what it writes is held there as
/// pending, and what it reads is P1's unsigned history.
///
/// **Best-effort, and deliberately.** The writer's accept, reject or capture is
/// the decision; this is bookkeeping beside it. A folder that will not read
/// must never cost the writer their note — it costs a line in the log and, for
/// as long as it lasts, an admission sheet the Mac has not been able to offer.
///
/// **And it remembers what it declared** (P2b §4.11). `ensureDeviceRecord` is
/// idempotent but not free: it READS and verifies the whole registry folder
/// before deciding it has nothing to add, and this runs on every capture and
/// every annotation. So the facts it would declare are memoized per project —
/// this phone's key, the actors it holds, the name it goes by — and a second
/// write into the same book with nothing new to say touches the disk not at
/// all. The memory is in-process and per-project, which is the honest scope:
/// it says what THIS run has already declared, and a relaunch declares again.
@MainActor
enum PhoneDeviceRecord {

    /// What was declared in one project, as facts rather than as a moment.
    /// A name the writer changed in iOS Settings, or an actor key that did not
    /// exist last time, are exactly the two things `RegistryPresence` re-signs
    /// for — so they are what the memory is keyed on.
    private struct Declaration: Equatable {
        let device: String
        /// `DeviceActor.rawValue`s, in `allCases` order. The fingerprints
        /// themselves are not read here: naming an actor MINTS its key
        /// (`LocalIdentities`' lazy rule), and a memo lookup must not.
        let actors: [String]
        let name: String
    }

    /// Project root path → what this run last declared there.
    private static var declared: [String: Declaration] = [:]

    /// Declare this phone in `projectRoot`, if it has anything new to say.
    ///
    /// Idempotent and quiet in two layers: with facts this run has already
    /// declared here nothing is read at all, and with a matching record already
    /// on disk nothing is written — which is what makes it safe on a path
    /// every write takes.
    ///
    /// `declare` is the seam the memo is pinned through; production is
    /// `RegistryPresence.ensureDeviceRecord`, and nothing else calls it.
    static func ensure(
        in projectRoot: URL,
        identity: DeviceIdentity,
        identities: LocalIdentities? = nil,
        // The phone's own name, as a display string — what People & Devices
        // shows beside the label the writer chooses. Never an identity: this
        // device IS its key's fingerprint (tripwire 35).
        name: String = UIDevice.current.name,
        declare: (URL, LocalIdentities, String) throws -> URL? = {
            try RegistryPresence.ensureDeviceRecord(
                in: $0, identities: $1, name: $2, kind: .phone)
        }
    ) {
        let identities = identities ?? .forAuthor(identity)
        let key = projectRoot.standardizedFileURL.path
        let facts = Declaration(
            device: identity.fingerprint,
            actors: identities.existingActors.map(\.rawValue),
            name: name)
        guard declared[key] != facts else { return }

        do {
            _ = try declare(projectRoot, identities, name)
            // Remembered only on success: a read that threw declared nothing,
            // and skipping the next attempt would leave this phone undeclared
            // for the rest of the run over a transient iCloud fault.
            declared[key] = facts
        } catch {
            phoneRecordLog.error("""
                This phone could not declare itself in the project at \
                \(projectRoot.lastPathComponent, privacy: .public): \
                \(String(describing: error), privacy: .public). \
                The write itself goes ahead; until the record lands, the Mac \
                has nothing to admit.
                """)
        }
    }

    /// Forget what this run has declared. Test-only: the memo is process-wide
    /// state, and a suite's temp project must not inherit another's.
    static func forgetDeclarationsForTesting() { declared.removeAll() }
}
