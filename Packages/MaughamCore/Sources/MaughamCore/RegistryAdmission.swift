import Foundation

/// Why an admission did not happen. Both are refusals of AUTHORITY rather than
/// of form, which is what separates them from `RegistryWriteError.wrongSigner`:
/// the record would have been perfectly well-formed, and writing it anyway is
/// how a device loses its place quietly.
public enum RegistryAdmissionError: Error, Equatable {
    /// This device has no verified self-signed root record in this project, so
    /// nothing it signs is an admission. A person record naming a non-root as
    /// its admitter is one every reader lists as malformed — the device would
    /// stay a stranger, and the writer would have watched themselves admit it.
    case notARoot
    /// A person record for that fingerprint already exists under a DIFFERENT
    /// root. Taking it over is exactly the change of hands `RegistryCache`
    /// refuses one layer down (`malformed(.signerChanged)`); merging two chains
    /// is adoption's own act, with a claim record saying who did it and when.
    case alreadyAdmittedElsewhere(root: String)
    /// A person record for that fingerprint is **present on disk and did not
    /// verify**. Present and unreadable is not absent (Denver, 2026-09-10) —
    /// the distinction `RegistryPresence.ensureRootIfEmpty` already keeps, and
    /// the reachable case is a sync ordering rather than tampering: another Mac
    /// admitted that device, and until its own root record lands, everything it
    /// signed reads `signerIsNotARoot`. Writing here would destroy their
    /// admission. It is a refusal that resolves itself the moment the missing
    /// record arrives.
    case recordUnreadable(fingerprint: String)
}

/// **The author's key names a device** (spec §4).
///
/// Under labels-only there is no person key: a person IS a device's author
/// fingerprint, and "Denver" is a word this Mac's root key attaches to one. So
/// the whole of admission is a signature — the root writes a `PersonRecord` for
/// somebody else's fingerprint, and every reader that verifies the root
/// verifies the admission, including the phone itself, which reads the record
/// naming it and joins that chain (B1).
///
/// Three properties are worth stating because each fails in a direction that is
/// hard to see:
///
/// - **It refuses rather than writing a record nobody accepts.** A device that
///   is not a root here can produce a syntactically perfect person record; no
///   reader will take it, and the writer would be left believing a phone had
///   been let in.
/// - **It is idempotent.** Re-signing a record that already says what it should
///   makes a new file for iCloud to carry and a new signature for every peer to
///   check, for no change at all. Only a changed LABEL re-signs, and it keeps
///   the original `admittedAt` — renaming somebody is not admitting them again.
/// - **A label is a word, not an identity.** Typing a name that matches an
///   existing one gives that device the same `label` and its own record.
///   Nobody is admitted AS an existing person by asking, which is the sentence
///   §4.1 ends on.
///
/// **The caller invalidates trust.** Admission changes who this device's
/// `TrustTable` admits, and the tables in flight were resolved before the
/// record existed. The Mac side (`DocumentStore`) calls
/// `OpLogStore.invalidateTrust()` on every open document's store afterwards and
/// re-reads what was held; this function knows about a folder and a memory, not
/// about open documents.
public enum RegistryAdmission {

    /// Admit `fingerprint` to this project under `label`, signed by my root.
    ///
    /// - Parameters:
    ///   - fingerprint: the device's author-key fingerprint — its person, under
    ///     labels-only.
    ///   - label: the author's word for whoever that device belongs to.
    ///   - ownName: the device's own name at admission, shown as
    ///     `<label> (<ownName>)` wherever the two differ.
    ///   - root: this device's **author** identity. It must have a verified
    ///     self-signed root record here.
    ///   - cache: this device's memory of the registry, updated with the
    ///     admission just written. An admission nothing remembers is one a
    ///     dropped file can undo in silence — the cache is what puts a deleted
    ///     record back and says who took it away (spec §2.4).
    ///   - memory: the label memory, so no later book asks about this device
    ///     again (decision B2).
    /// - Returns: the person record that now stands for that device, whether it
    ///   was written now or already there — read back from the folder, so it
    ///   carries the signature a reader verifies rather than the unsigned shape
    ///   this function decided on.
    /// - Throws: `RegistryAdmissionError`, or whatever the read and the write
    ///   throw. A registry that is present and unreadable refuses the whole
    ///   thing (RULING-54): admitting somebody over a folder this device could
    ///   only half read is deciding something by accident.
    @discardableResult
    nonisolated public static func admit(
        device fingerprint: String,
        label: String,
        ownName: String,
        in projectURL: URL,
        by root: DeviceIdentity,
        cache: RegistryCache,
        memory: AdmissionMemory,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> PersonRecord {
        let registry = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        let decided = try admit(
            device: fingerprint, label: label, ownName: ownName,
            in: projectURL, by: root, within: registry,
            memory: memory, now: now, presenter: presenter)
        // The re-read the cache needs is also the read that turns the record
        // this function DECIDED into the record a reader VERIFIES: the writer
        // signs a copy of its own, so what was built above carries no
        // signature. The fallback is for a record that vanished between the
        // write and the read, which is the cache's own subject.
        let verified = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        return verified.person(fingerprint) ?? decided
    }

    /// The same act over a registry the caller has already read, and without
    /// the re-read that refreshes the cache.
    ///
    /// `admitRemembered` admits several devices in one open and would otherwise
    /// pay a whole verified read of the folder per device and another per
    /// admission. It reads once, calls this per device, and refreshes the cache
    /// once at the end — which is also the only way the cache ends up holding
    /// every new record rather than the last one.
    ///
    /// The record it answers is the one it DECIDED — unsigned, because the
    /// writer signs a copy of its own. Both public entry points read the folder
    /// back afterwards and answer the verified record instead.
    ///
    /// `internal` rather than public: a caller outside this module cannot be
    /// held to having read the registry it passes from THIS project a moment
    /// ago, and a stale one is an admission decided against a folder that has
    /// since changed.
    @discardableResult
    nonisolated static func admit(
        device fingerprint: String,
        label: String,
        ownName: String,
        in projectURL: URL,
        by root: DeviceIdentity,
        within registry: Registry,
        memory: AdmissionMemory,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> PersonRecord {
        guard registry.roots.contains(where: { $0.person == root.fingerprint }) else {
            throw RegistryAdmissionError.notARoot
        }

        // A root's `admittedBy` is its own fingerprint, so this refusal covers
        // a fingerprint that is itself a self-signed ROOT here as well as one
        // somebody else admitted — admitting a root would be re-signing their
        // own record under my key.
        let existing = registry.person(fingerprint)
        if let existing, existing.admittedBy != root.fingerprint {
            throw RegistryAdmissionError.alreadyAdmittedElsewhere(root: existing.admittedBy)
        }

        // Nothing verified stands for this fingerprint, and yet a file does:
        // present and unreadable, which is not absent. Every question above
        // read it as absent, and the write below would go straight over it.
        //
        // The order is load-bearing. A record the folder shows under another
        // root is ALSO listed malformed — that is the takeover `reconcile`
        // refuses — but there the record this device verified still stands, so
        // `existing` answers it and this is not that case.
        if existing == nil, unreadablePeople(in: registry).contains(fingerprint) {
            throw RegistryAdmissionError.recordUnreadable(fingerprint: fingerprint)
        }

        // Already admitted under my root, and the record still says what it
        // should — the writer's label AND the device's own name. Nothing to
        // write, but the memory is stated either way, because a device admitted
        // before this Mac remembered anything is exactly the one a later book
        // would ask about again.
        //
        // `ownName` counts here (fix round 1, M6): keying idempotence on the
        // label alone would leave a renamed phone carrying a name nobody uses
        // in the one record every surface reads it from.
        if let existing, existing.label == label, existing.ownName == ownName {
            memory.remember(fingerprint, label: label, ownName: ownName, at: existing.admittedAt)
            return existing
        }

        // A relabel — or a rename — keeps everything the record already decided:
        // when they were admitted, and, if they have been, that they are
        // revoked. Renaming somebody is not admitting them again, and it is
        // certainly not un-revoking them; that is Revoke's own verb.
        let record = PersonRecord(
            person: fingerprint, label: label, ownName: ownName, role: "author",
            admittedAt: existing?.admittedAt ?? now(),
            admittedBy: root.fingerprint,
            revokedAt: existing?.revokedAt, revokedBy: existing?.revokedBy,
            highestOpIdSeen: existing?.highestOpIdSeen)
        try RegistryWriter.write(
            record, signedBy: root, in: projectURL, presenter: presenter)
        memory.remember(fingerprint, label: label, ownName: ownName, at: now())
        return record
    }

    /// The fingerprints whose person record is **present on disk and did not
    /// verify** — named by the FILE, because what the bytes claim is exactly
    /// what a malformed listing cannot tell you.
    ///
    /// The one definition of *a person record this device cannot vouch for*,
    /// asked by both admission paths and by `ensureRootIfEmpty`. A second
    /// opinion about it would be a second answer to whether a thing that is
    /// present is absent, which is the whole of the ruling it serves.
    nonisolated static func unreadablePeople(in registry: Registry) -> Set<String> {
        Set(registry.malformed.compactMap { fault in
            guard let ref = fault.ref, ref.directory == .people else { return nil }
            return ref.fingerprint
        })
    }
}
