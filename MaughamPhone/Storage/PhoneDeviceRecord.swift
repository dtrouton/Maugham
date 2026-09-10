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
@MainActor
enum PhoneDeviceRecord {

    /// Declare this phone in `projectRoot`, if it has anything new to say.
    ///
    /// Idempotent and quiet: with a matching record already on disk this
    /// touches no file, which is what makes it safe on a path every write
    /// takes.
    static func ensure(in projectRoot: URL, identity: DeviceIdentity) {
        do {
            try RegistryPresence.ensureDeviceRecord(
                in: projectRoot,
                identities: .forAuthor(identity),
                // The phone's own name, as a display string — what People &
                // Devices shows beside the label the writer chooses. Never an
                // identity: this device IS its key's fingerprint (tripwire 35).
                name: UIDevice.current.name,
                kind: .phone)
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
}
