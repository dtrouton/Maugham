import Foundation

/// Why an admission did not happen. Both are refusals of AUTHORITY rather than
/// of form, which is what separates them from `RegistryWriteError.wrongSigner`:
/// the record would have been perfectly well-formed, and writing it anyway is
/// how a device loses its place quietly.
/// **How much a revocation takes back** (find 5, ruled 2026-09-18).
///
/// Two choices, and the writer makes them at the confirmation: the default
/// leaves in the book everything this Mac had already applied from that device,
/// and the other takes the whole of their history out of it until they are
/// re-admitted.
///
/// It is a choice rather than a setting because the two have different costs
/// and neither is always right. A collaborator who left is a `.whatWasApplied`
/// revocation — their contributions are part of the draft and removing them
/// would silently rewrite chapters the writer has read. A machine that was
/// never theirs, or one they no longer trust anything from, is `.nothing`.
///
/// **It reaches the record as the presence or absence of `highestOpIdSeen`**,
/// which is the shape the reader has always understood: no mark means nothing
/// of theirs was ever *already here*. So there is exactly one wire-level
/// spelling, and this enum is the vocabulary the surfaces and the store share
/// rather than a second one (`RevocationSplit` reads the record).
public enum RevocationScope: Equatable, Sendable {
    /// Keep every line at or below the mark this Mac records. The default.
    case whatWasApplied
    /// Keep none of it. What a revocation did before the ruling.
    case nothing

    /// **The mark a gentle revocation records when this book applies nothing
    /// of theirs** (find-5 review, the High).
    ///
    /// A nil `highestOpIdSeen` is the ONE spelling of *set aside everything it
    /// wrote*, and it used to be written by the gentle press too whenever the
    /// sweep found nothing — so History narrated the writer's gentle choice as
    /// the harsh one, and a later read could not tell which button was pressed.
    ///
    /// The lowest ULID keeps exactly nothing, which is the truth here, while
    /// leaving a mark on the record. Every real op id is 26 Crockford base32
    /// characters and `0` is the lowest of them, so `opId <= this` is false for
    /// all of them by plain string comparison.
    public static let nothingAppliedMark = String(repeating: "0", count: 26)
}

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
    /// There is no verified record for that fingerprint at all — nobody to
    /// revoke, no device to retire. A refusal rather than a record minted out
    /// of nothing: writing one would admit the device in the same act that was
    /// meant to shut it out, and would name a device this book has never heard
    /// of as having been here.
    case notAdmitted(fingerprint: String)
    /// A file this device had to read to answer *how far had I got with them*
    /// is present and will not read (find-5 review, the High). It refuses the
    /// whole revocation rather than recording a mark that came back short: a
    /// short mark silently widens what the revocation takes back, and the
    /// shortest of all — nil — is wire-identical to the writer having asked for
    /// everything to be set aside.
    case historyUnreadable(name: String)
    /// The target is a self-signed ROOT. A root answers to itself (spec §5:
    /// *a root is claimed over, never revoked*), so revoking one would be this
    /// Mac re-signing somebody else’s own word about themselves — which
    /// is the change of hands `RegistryCache` refuses one layer down.
    case cannotRevokeARoot(fingerprint: String)
    /// A claim whose `adopted` list names the claimant itself. A root cannot
    /// adopt its own chain: the record would say nothing, and the only way to
    /// arrive here is a surface offering *this is also me* on the writer's own
    /// row — a question about a row that should never have asked it. Refused
    /// with the rest of the list untouched, because a claim is one act and
    /// silently dropping the offending half would write something the writer
    /// did not ask for.
    case cannotAdoptItself(root: String)
    /// A retirement signed by something that is not that device. A device
    /// record is signed by the device it describes, so any other signature
    /// makes a file every reader lists as malformed — a machine’s whole
    /// history left unattributable by an act meant to be orderly.
    case notThatDevice(device: String)
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
        //
        // **A REVOKED record is never the idempotent case** (P2b Task 7 fix
        // round 1, Important 3b): admitting somebody this root revoked is the
        // inverse act, and answering "nothing to write" would leave the writer
        // pressing Re-admit at a device that stays shut out.
        if let existing, !existing.isRevoked,
           existing.label == label, existing.ownName == ownName {
            memory.remember(fingerprint, label: label, ownName: ownName, at: existing.admittedAt)
            return existing
        }

        // **An admission written by the root that revoked them is the
        // revocation's inverse** (fix round 1, Important 3b). The three
        // revocation fields are CLEARED rather than carried: this is the same
        // authority saying the opposite thing, explicitly, at a surface, and a
        // record that said both would leave every reader quarantining a device
        // the writer has just let back in. `admittedAt` is preserved — they
        // were admitted the day they were admitted, and the return is a second
        // fact rather than a rewriting of the first.
        //
        // History pays for it: the events derive from the records, so a cleared
        // `revokedAt` takes the revoked event with it. The carry is named in
        // the fix report — a durable event log would keep both.
        let record = PersonRecord(
            person: fingerprint, label: label, ownName: ownName, role: "author",
            admittedAt: existing?.admittedAt ?? now(),
            admittedBy: root.fingerprint,
            revokedAt: nil, revokedBy: nil,
            highestOpIdSeen: nil)
        try RegistryWriter.write(
            record, signedBy: root, in: projectURL, presenter: presenter)
        memory.remember(fingerprint, label: label, ownName: ownName, at: now())
        return record
    }

    // MARK: - Revocation and retirement (spec §5)

    /// **Revoke a person: the root’s act** (spec §5).
    ///
    /// The person record keeps every word it had and gains three facts —
    /// `revokedAt`, `revokedBy`, and `highestOpIdSeen`, the highest opId this
    /// Mac had APPLIED from that device when the writer pressed the button.
    /// The third is what lets a reader tell two genuinely different things
    /// apart afterwards: a line that arrived after the revocation, and a line
    /// that was written before it and only reached this Mac later. Both are
    /// refused; they are not the same accusation, and the split is
    /// `OpLogStore`’s to make from this number.
    ///
    /// **It is idempotent, and that matters more here than for admission.** A
    /// second press would re-sign with a later date and a newer
    /// `highestOpIdSeen` — moving the line the first revocation drew, which is
    /// the one fact the record exists to hold still.
    ///
    /// Four refusals, each a refusal of AUTHORITY rather than of form: this
    /// Mac is not the root here; the target is a root (claimed over, never
    /// revoked); the target was admitted by somebody else’s root, whose
    /// record is not mine to re-sign; and the record is present on disk and
    /// unreadable, which is not absent (RULING-54).
    ///
    /// **The caller invalidates trust**, exactly as after an admission, and for
    /// the same reason: the tables in flight were resolved before the record
    /// said this.
    @discardableResult
    nonisolated public static func revoke(
        person fingerprint: String,
        in projectURL: URL,
        by root: DeviceIdentity,
        highestOpIdSeen: String?,
        cache: RegistryCache,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> PersonRecord {
        let registry = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        guard registry.roots.contains(where: { $0.person == root.fingerprint }) else {
            throw RegistryAdmissionError.notARoot
        }
        guard let existing = registry.person(fingerprint) else {
            // Present and unreadable is not absent, and it is the reachable
            // case: another Mac admitted them and its own root record has not
            // landed yet. Writing here would destroy their admission.
            if unreadablePeople(in: registry).contains(fingerprint) {
                throw RegistryAdmissionError.recordUnreadable(fingerprint: fingerprint)
            }
            throw RegistryAdmissionError.notAdmitted(fingerprint: fingerprint)
        }
        guard !existing.isRoot else {
            throw RegistryAdmissionError.cannotRevokeARoot(fingerprint: fingerprint)
        }
        guard existing.admittedBy == root.fingerprint else {
            throw RegistryAdmissionError.alreadyAdmittedElsewhere(root: existing.admittedBy)
        }
        // Already revoked: the line is drawn, and drawing it again would move
        // it. The record that stands is the answer.
        guard !existing.isRevoked else { return existing }

        let at = try RegistryCanonical.dateString(now())
        try RegistryWriter.resign(
            existing, signedBy: root, in: projectURL, presenter: presenter
        ) { object in
            object["revokedAt"] = at
            object["revokedBy"] = root.fingerprint
            if let highestOpIdSeen {
                object["highestOpIdSeen"] = highestOpIdSeen
            } else {
                object.removeValue(forKey: "highestOpIdSeen")
            }
        }

        let verified = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        guard let record = verified.person(fingerprint) else {
            // The record was written and did not read back: the one shape that
            // must not be reported as success, because the device would go on
            // being applied while the writer believed it stopped.
            throw RegistryAdmissionError.recordUnreadable(fingerprint: fingerprint)
        }
        return record
    }

    /// **Rename a person: a WORD about somebody, written by the root that
    /// vouches for them** (P2 smoke find 3).
    ///
    /// A label is the one thing in this registry the writer chose rather than
    /// derived, and until now it could only be chosen once — at the admission
    /// sheet, or by whatever a first root was called when the book began. A
    /// writer who mistyped it, or who let a Mac name itself, had no way back.
    ///
    /// **It changes nothing about authority.** The record keeps its
    /// `admittedAt`, its `admittedBy`, its revocation if it has one, and every
    /// field this build has no property for: the FILE's object is edited and
    /// re-signed (`RegistryWriter.resign`, P2b Task 1's rule), so a record a
    /// later build wrote survives being renamed rather than being quietly
    /// rewritten into this build's vocabulary and failing to verify everywhere
    /// that understands it.
    ///
    /// **Who may.** The root that admitted them, and nobody else — a person
    /// record is signed by the root it names, so any other signature makes a
    /// file every reader lists as malformed, which is a device un-admitted in
    /// silence rather than renamed. A root's own record names ITSELF as its
    /// admitter, which is exactly why a root may rename itself and may not
    /// rename another root.
    ///
    /// **A revoked person may be renamed.** Their label is a word about who
    /// they were, and correcting it neither lets them back in nor shuts them
    /// out further.
    ///
    /// Idempotent, for admission's reason: a label that already says this
    /// writes no file and makes no signature for every peer to check. The
    /// memory is stated either way, because a device renamed here is one a
    /// later book should meet under its new name.
    ///
    /// **An empty label is not a rename.** It is a writer who cleared a field,
    /// and the surface that offers this disables its button on one — mirroring
    /// `AdmissionDecision.outcome`, where an empty label means *nothing
    /// happens* rather than a refusal. Nothing here writes a person with no
    /// name.
    ///
    /// **The caller invalidates trust** — not because a rename moves a verdict
    /// (it moves none) but because every surface reading the label resolved it
    /// with the old one.
    /// **Who may rename whom, decided over a registry and nothing else** — the
    /// one definition, shared by the verb below and by every surface that draws
    /// a Rename control (whole-branch review, Minor 1).
    ///
    /// Two rules, and the first is the one a surface is most likely to forget:
    ///
    /// 1. **The signer must itself be a root of this book.** A rename RE-SIGNS
    ///    the record, and a signature from a Mac no root record names is one
    ///    every reader lists as malformed — a person un-admitted in silence by
    ///    a correction to their name. A Mac whose own root record was deleted
    ///    is in exactly that position while it still holds records naming it as
    ///    their admitter, which is how People & Devices came to offer a live
    ///    button that threw the moment it was pressed.
    /// 2. **And it must be the root that admitted them**, the same signature
    ///    rule Revoke keeps. A root's own record names ITSELF as its admitter,
    ///    so one rule covers *a root renames itself* with no clause of its own.
    ///
    /// The present-and-unreadable arm is RULING-54's, and it is the reachable
    /// case rather than tampering: another Mac's admission whose own root
    /// record has not landed reads as `signerIsNotARoot` until it does, and
    /// writing over it would destroy their admission.
    ///
    /// Answering the RECORD on success is what keeps the verb from asking the
    /// registry the same question twice, and keeps this from having an arm
    /// nothing can reach.
    nonisolated public static func renameOutcome(
        person fingerprint: String, by root: String, in registry: Registry
    ) -> Result<PersonRecord, RegistryAdmissionError> {
        guard registry.roots.contains(where: { $0.person == root }) else {
            return .failure(.notARoot)
        }
        guard let existing = registry.person(fingerprint) else {
            return .failure(unreadablePeople(in: registry).contains(fingerprint)
                ? .recordUnreadable(fingerprint: fingerprint)
                : .notAdmitted(fingerprint: fingerprint))
        }
        guard existing.admittedBy == root else {
            return .failure(.alreadyAdmittedElsewhere(root: existing.admittedBy))
        }
        return .success(existing)
    }

    @discardableResult
    nonisolated public static func rename(
        person fingerprint: String,
        to label: String,
        in projectURL: URL,
        by root: DeviceIdentity,
        cache: RegistryCache,
        memory: AdmissionMemory,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> PersonRecord {
        let registry = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        let existing = try renameOutcome(
            person: fingerprint, by: root.fingerprint, in: registry).get()

        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != existing.label else {
            memory.remember(
                fingerprint, label: existing.label, ownName: existing.ownName,
                at: existing.admittedAt)
            return existing
        }

        try RegistryWriter.resign(
            existing, signedBy: root, in: projectURL, presenter: presenter
        ) { object in
            object["label"] = trimmed
        }

        let verified = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        guard let record = verified.person(fingerprint) else {
            // Written and did not read back: the one shape that must not be
            // reported as success, because the writer would go on reading the
            // old name and believing they had changed it.
            throw RegistryAdmissionError.recordUnreadable(fingerprint: fingerprint)
        }
        memory.remember(
            fingerprint, label: record.label, ownName: record.ownName, at: now())
        return record
    }

    /// **Retire a device: the device’s own act** (spec §5).
    ///
    /// A device record is signed by the device it describes, so this is the one
    /// verb in the registry that nobody else can perform on your behalf — a
    /// root cannot retire a phone, and a phone cannot retire a Mac. What it
    /// writes is one date. Its past stays verified on every reader; its future
    /// seals are quarantined as *after retirement*, which is `TrustTable`’s
    /// reading of that date against the moment each seal was made.
    ///
    /// Idempotent for revocation’s reason: the date is the line.
    @discardableResult
    nonisolated public static func retire(
        device fingerprint: String,
        in projectURL: URL,
        by identity: DeviceIdentity,
        cache: RegistryCache,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> DeviceRecord {
        guard identity.fingerprint == fingerprint else {
            throw RegistryAdmissionError.notThatDevice(device: fingerprint)
        }
        let registry = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        guard let existing = registry.devices.first(where: { $0.device == fingerprint })
        else {
            if unreadableDevices(in: registry).contains(fingerprint) {
                throw RegistryAdmissionError.recordUnreadable(fingerprint: fingerprint)
            }
            throw RegistryAdmissionError.notAdmitted(fingerprint: fingerprint)
        }
        guard existing.retiredAt == nil else { return existing }

        let at = try RegistryCanonical.dateString(now())
        try RegistryWriter.resign(
            existing, signedBy: identity, in: projectURL, presenter: presenter
        ) { object in
            object["retiredAt"] = at
        }

        let verified = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        guard let record = verified.devices.first(where: { $0.device == fingerprint })
        else {
            throw RegistryAdmissionError.recordUnreadable(fingerprint: fingerprint)
        }
        return record
    }

    // MARK: - The claim, and the two-roots exit (spec §5)

    /// **This book is mine** — the one act by which a Mac that is in no chain
    /// here takes the history it is holding (parent spec §4.7, spec §5).
    ///
    /// Two writes, and the order is the contract:
    ///
    /// 1. This device's own **self-signed root record**, when it has none.
    ///    `RegistryPresence.ensureRootIfEmpty` refuses a book that already has
    ///    people in it, which is right for an OPEN — adopting somebody's book
    ///    is never something an open decides — and this is the one path that
    ///    roots a device in a registry that is not empty, because here the
    ///    writer has been asked and has answered. The label and the own name
    ///    are this device's own name, from the device record it wrote when it
    ///    declared itself; a device with no record here falls back to its code,
    ///    so the row a reader draws says something a human can check against a
    ///    screen rather than nothing at all.
    /// 2. A **`ClaimRecord`** naming the roots taken in. It has no
    ///    cryptographic authority over the old chain and does not pretend to:
    ///    it is why the history stays attributed and why every surviving device
    ///    can say *a new Mac claimed this book on 9 Sep*.
    ///
    /// The root record must land FIRST, because `RegistryReader` refuses a
    /// claim whose `newRoot` is not a verified root here (Task 2). A claim
    /// written before it would be listed malformed and adopt nobody — and the
    /// writer would be looking at a book that had accepted their claim and gone
    /// on quarantining everything in it.
    ///
    /// **Adoption is symmetric, and that is the whole of the two-roots exit**
    /// (plan decision P2, P2a review I3). Two Macs that both rooted an empty
    /// book before sync converged quarantine each other, and nothing may
    /// overwrite either root record — that is the change of hands this layer
    /// refuses everywhere. So each Mac calls THIS SAME FUNCTION naming the
    /// other: *this is also me*. A root I adopted is in my chain; a root that
    /// adopted me without my reciprocating is exactly the claimant it was
    /// (B1 — nothing here ever moves `joinedRoot`, and the surfaces draw the
    /// unreciprocated half as a claimant with the offer still open).
    ///
    /// **Idempotent**, for admission's reason one directory over: adopting a
    /// root already adopted writes nothing at all. A root adopted LATER joins
    /// the claim this device already wrote — one claim record per root, since
    /// the file is named by the root — and `claimedAt` stays the day the book
    /// was claimed, because that is what the date means.
    ///
    /// **Three refusals.** A list naming this device itself; a device already
    /// admitted under somebody ELSE's root, whose record the root write would
    /// go straight over; and a record of this device's own that is present and
    /// will not read (RULING-54), which is the sync ordering that fixes itself.
    ///
    /// **The caller invalidates trust**, exactly as after an admission: every
    /// table in flight was resolved before this device had a chain at all.
    @discardableResult
    nonisolated public static func claim(
        adopting roots: [String],
        in projectURL: URL,
        by me: DeviceIdentity,
        cache: RegistryCache,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> ClaimRecord {
        let adopting = Set(roots)
        guard !adopting.contains(me.fingerprint) else {
            throw RegistryAdmissionError.cannotAdoptItself(root: me.fingerprint)
        }
        let registry = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)

        if let existing = registry.person(me.fingerprint) {
            // Already on somebody's chain: there is no root record to write
            // that would not be written over theirs, and a device that is not a
            // root signs no claim any reader takes (`signerIsNotARoot`). The
            // honest answer is the takeover refusal, not a file.
            guard existing.isRoot else {
                throw RegistryAdmissionError.alreadyAdmittedElsewhere(
                    root: existing.admittedBy)
            }
        } else {
            if unreadablePeople(in: registry).contains(me.fingerprint) {
                throw RegistryAdmissionError.recordUnreadable(fingerprint: me.fingerprint)
            }
            let name = registry.devices.first { $0.device == me.fingerprint }?.name
                ?? DeviceCode.short(me.fingerprint)
            try RegistryWriter.write(
                PersonRecord(
                    person: me.fingerprint, label: name, ownName: name, role: "author",
                    admittedAt: now(), admittedBy: me.fingerprint),
                signedBy: me, in: projectURL, presenter: presenter)
        }

        if let standing = registry.claims.first(where: { $0.newRoot == me.fingerprint }) {
            let already = Set(standing.adopted)
            guard !adopting.isSubset(of: already) else { return standing }
            let widened = already.union(adopting).sorted()
            // `resign` rather than a fresh record, for Task 1's reason: a claim
            // a LATER build wrote carries fields this one has no property for,
            // and re-encoding what this build decoded would quietly drop them.
            // The FILE's object is what is edited, and `claimedAt` is not part
            // of the edit.
            try RegistryWriter.resign(
                standing, signedBy: me, in: projectURL, presenter: presenter
            ) { object in
                object["adopted"] = widened
            }
        } else {
            try RegistryWriter.write(
                ClaimRecord(
                    newRoot: me.fingerprint, adopted: adopting.sorted(),
                    claimedAt: now()),
                signedBy: me, in: projectURL, presenter: presenter)
        }

        // The re-read refreshes this device's memory of the folder and turns
        // the record this function DECIDED into the record a reader VERIFIES.
        // A claim that did not read back is the one shape that must not be
        // reported as success: the writer would believe a book was theirs.
        let verified = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        guard let record = verified.claims.first(where: { $0.newRoot == me.fingerprint })
        else {
            throw RegistryAdmissionError.recordUnreadable(fingerprint: me.fingerprint)
        }
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
        unreadable(in: registry, directory: .people)
    }

    /// The same question of the DEVICES directory, which retirement asks: a
    /// device record present and unverified is a record this Mac must not write
    /// over, for the reason its person twin must not be.
    nonisolated static func unreadableDevices(in registry: Registry) -> Set<String> {
        unreadable(in: registry, directory: .devices)
    }

    nonisolated private static func unreadable(
        in registry: Registry, directory: RegistryDirectory
    ) -> Set<String> {
        Set(registry.malformed.compactMap { fault in
            guard let ref = fault.ref, ref.directory == directory else { return nil }
            return ref.fingerprint
        })
    }
}
