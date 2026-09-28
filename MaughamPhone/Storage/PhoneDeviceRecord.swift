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
    /// A name the writer changed in iOS Settings, an actor key that did not
    /// exist last time, or a person key that synced in since, are exactly the
    /// things `RegistryPresence` re-signs for — so they are what the memory is
    /// keyed on.
    private struct Declaration: Equatable {
        let device: String
        /// `DeviceActor.rawValue`s, in `allCases` order. The fingerprints
        /// themselves are not read here: naming an actor MINTS its key
        /// (`LocalIdentities`' lazy rule), and a memo lookup must not.
        let actors: [String]
        let name: String
        /// The person key this phone found, and the name its item carries —
        /// the claim's facts (your devices are you, plan 2 Task 1). Nil where
        /// there was no key: an item that syncs in mid-run changes these, so
        /// the phone declares again, once.
        let personKey: String?
        let personName: String?
    }

    /// Project root path → what this run last declared there.
    private static var declared: [String: Declaration] = [:]

    /// Declare this phone in `projectRoot`, if it has anything new to say —
    /// and, where it holds the writer's person key, say whose it is.
    ///
    /// Idempotent and quiet in two layers: with facts this run has already
    /// declared here nothing is read at all, and with a matching record already
    /// on disk nothing is written — which is what makes it safe on a path
    /// every write takes (P2-1: the claim rides on the phone's first WRITE in a
    /// book, as its record always has; there is no open-time write).
    ///
    /// **The person key is found OFF the main actor** (a keychain query), on
    /// every call, BEFORE the memo is consulted: the memo holds the claim's
    /// facts, so a key that syncs in mid-run must be looked for to be noticed.
    /// A phone that cannot sign (no enclave) writes no record and never
    /// reaches for the key — it would only mint an item for nothing.
    ///
    /// The claim intent mirrors the Mac's open exactly: a key → `.set`, signed
    /// through `RegistryWriter.personClaim` for THIS phone's author key; no key
    /// → `.keep`; never `.remove` (plan 1's rule — a keychain that cannot
    /// answer is not evidence the writer left). A claim the record refuses
    /// (`PersonClaimError`) is logged and the record written again with
    /// `.keep`; nothing reaches the writer's path.
    ///
    /// `declare` is the seam the memo is pinned through; production is
    /// `RegistryPresence.ensureDeviceRecord`, and nothing else calls it.
    static func ensure(
        in projectRoot: URL,
        identity: DeviceIdentity,
        identities: LocalIdentities? = nil,
        // The phone's own name as iOS gives it — what People & Devices shows
        // beside the label the writer chooses. Never an identity: this device
        // IS its key's fingerprint (tripwire 35). Nil is this device's own
        // name, read in the body. Both callers are `@MainActor` (the two
        // writers' `appendChained` hops), so reading it is safe either way;
        // the warning came from Swift evaluating a DEFAULT-ARGUMENT expression
        // isolation-blind, which flags the main-actor-isolated
        // `UIDevice.current` there. In the body it is checked against this
        // `@MainActor` enum's own isolation. `model` is the same, for the
        // generic-name rule (`deviceName`).
        name: String? = nil,
        model: String? = nil,
        declare: (URL, LocalIdentities, String, PersonClaimIntent) throws -> URL? = {
            try RegistryPresence.ensureDeviceRecord(
                in: $0, identities: $1, name: $2, kind: .phone, personClaim: $3)
        }
    ) async {
        let identities = identities ?? .forAuthor(identity)
        let systemName = name ?? UIDevice.current.name
        let model = model ?? UIDevice.current.model

        // The writer's person key, if this phone can reach it.
        let personKey: PersonKey?
        if identity.canSign {
            let store = PhonePersonKeyAccess.store
            personKey = await Task.detached(priority: .userInitiated) {
                // The seed is EMPTY: iOS gives an app no owner name, and an
                // empty-named item is filled in later by a Mac
                // (`PersonKey.findOrCreate` never overwrites a name).
                PersonKey.findOrCreate(in: store, seedName: "")
            }.value
        } else {
            personKey = nil
        }

        let name = deviceName(
            system: systemName, model: model, personName: personKey?.name ?? "")
        let key = projectRoot.standardizedFileURL.path
        let facts = Declaration(
            device: identity.fingerprint,
            actors: identities.existingActors.map(\.rawValue),
            name: name,
            personKey: personKey?.fingerprint,
            personName: personKey?.name)
        guard declared[key] != facts else { return }

        let intent = claimIntent(for: identity.fingerprint, personKey: personKey)
        do {
            do {
                _ = try declare(projectRoot, identities, name, intent)
            } catch let refused as PersonClaimError {
                phoneRecordLog.fault("""
                    This phone's person claim was refused by its own record: \
                    \(String(describing: refused), privacy: .public) — in \
                    \(projectRoot.lastPathComponent, privacy: .public); the \
                    record keeps the claim it had.
                    """)
                _ = try declare(projectRoot, identities, name, .keep)
            }
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

    /// What this phone asks its record to say about whose it is — the Mac's
    /// `DocumentStore.claimIntent`, for the phone's author key. A key →
    /// `.set`; no key, or a claim that could not be signed → `.keep`. Never
    /// `.remove`.
    nonisolated static func claimIntent(
        for device: String, personKey: PersonKey?
    ) -> PersonClaimIntent {
        guard let personKey else { return .keep }
        do {
            return .set(try RegistryWriter.personClaim(forDevice: device, signedBy: personKey))
        } catch {
            phoneRecordLog.fault("""
                This phone's person claim could not be signed: \
                \(String(describing: error), privacy: .public); the record \
                keeps the claim it had.
                """)
            return .keep
        }
    }

    /// **The name this phone goes by** (P2-2). iOS 16 and later hand an app
    /// the bare model (`"iPhone"`) rather than the name the writer gave the
    /// phone, so a book would otherwise list every phone as *iPhone*.
    ///
    /// - The system name is kept unless it is GENERIC — exactly equal to the
    ///   model. A name the writer chose (*Kitchen phone*, *Denver's iPhone*)
    ///   is never overwritten, whoever the key says the person is.
    /// - A generic name with a person name becomes *"<first name>'s <model>"*,
    ///   the first name being the first whitespace-delimited word of the key
    ///   item's name (seeded on the Mac from `NSFullUserName()`).
    /// - With no person name, the system name stands.
    nonisolated static func deviceName(
        system: String, model: String, personName: String
    ) -> String {
        guard system == model,
              let first = personName
                .split(whereSeparator: { $0.isWhitespace })
                .first
        else { return system }
        return "\(first)'s \(model)"
    }

    /// Forget what this run has declared. Test-only: the memo is process-wide
    /// state, and a suite's temp project must not inherit another's.
    static func forgetDeclarationsForTesting() { declared.removeAll() }
}
