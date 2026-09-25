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
    /// whole act rather than recording a mark that came back short: a short
    /// mark silently widens what the act takes back, and the shortest of all —
    /// an empty one — means *everything after the beginning*.
    ///
    /// **`act` is which verb refused** (fix round 2, minor C). It arrived as a
    /// revocation's refusal alone and is now four verbs' — a demotion, an
    /// admission and a retirement reach it too — and the sentence must not go
    /// on telling the writer a revocation was refused when what they pressed
    /// was *make Sam a reviewer*. It carries a DEFAULT rather than widening
    /// every construction site, so every `.historyUnreadable(name:)` written
    /// before this still compiles and still means what it meant.
    case historyUnreadable(name: String, act: Act = .revocation)
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
    /// A permit change whose subject is a self-signed ROOT (P3 spec §2, §6).
    ///
    /// **A root is an author of the whole book, unconditionally**, and it alone
    /// admits, revokes and changes a permit — so the one permit change nobody
    /// may make is the one that would leave the book with no author. It is
    /// refused here rather than caught downstream because every layer below
    /// already refuses it in a way that costs something: `RegistryReader` would
    /// list the event malformed (`eventDemotesARoot`) and `TrustTable` would
    /// answer the root's own default anyway, so the writer would have pressed a
    /// button, written a file, and changed nothing.
    ///
    /// Distinct from `cannotRevokeARoot`, which is the same asymmetry one verb
    /// over: a root is claimed over, never revoked, and never narrowed either.
    case cannotChangeARoot(fingerprint: String)
    /// A claim whose `adopted` list names a fingerprint that is not a verified
    /// root of this book (C8).
    ///
    /// Adoption takes in a ROOT's chain, and `Registry.chain(underRoot:)`
    /// answers empty for anything that is not one — so a claim naming a
    /// stranger used to be written, verified and adopt nobody, leaving the
    /// writer looking at a book that had accepted their merge and gone on
    /// quarantining everything in it. A refusal says so at the press.
    ///
    /// (`Act`, below, is the vocabulary `historyUnreadable` names its verb by.)
    ///
    /// **It therefore also refuses a root whose own record has not synced
    /// yet**, and that is by design rather than an edge it missed (fix round
    /// 1, minor 5). Such a Mac is indistinguishable here from one that never
    /// rooted this book at all, and the two want the same answer: adopt it now
    /// and the claim records a merge with a chain nothing can verify. Like
    /// `recordUnreadable`, it is a refusal that resolves itself — the sentence
    /// says *nothing needs merging*, and pressing again once the record has
    /// landed works.
    case cannotAdoptANonRoot(fingerprint: String)

    /// **A narrowing event was asked for with no photograph of the book's
    /// unsigned streams** (P3b Task 1).
    ///
    /// The first event that makes somebody anything other than an author of
    /// the whole book has to carry an `UnsignedSnapshot` — where every stream
    /// no seal and no device record can name stood at that moment — because
    /// that mark is what keeps narrowing from reaching back through an
    /// enclave-less Mac's whole history. An event written without one reads as
    /// an EMPTY snapshot, which is *everything unattributable is after*: the
    /// exact, total, silent withdrawal the ruling exists to prevent.
    ///
    /// It is a door rather than call-site discipline for the reason every
    /// other refusal here is: the mark is the CALLER's to compute — it needs a
    /// sweep of every op-log file in the project — and a verb that merely
    /// hoped its callers had done so would fail in the one direction nothing
    /// goes red for.
    ///
    /// A NON-narrowing event needs none and never refuses, so no existing
    /// admission, revocation, retirement or rename can meet this.
    case narrowingWithoutASnapshot(fingerprint: String)

    /// **The manifest could not be raised to this build's schema before the
    /// narrowing event was written** (P3b Task 3).
    ///
    /// The first narrowing changes what READING this book means: every line has
    /// to be judged against a permit, and a build with no permit layer cannot
    /// do it. A v0.40 Mac in a narrowed book applies the reviewer's refused
    /// text, folds it into the manuscript and re-asserts those words under its
    /// own book-author key, where every signed Mac then has to take them — the
    /// writer's demotion undone by the oldest machine in the house, silently.
    /// `ProjectManifest.decodeGuardingSchema` is the only thing that stops it,
    /// and it stops it by refusing the project.
    ///
    /// So the order is **gate, then event, then record**, and a gate that could
    /// not be written refuses the act. A crash between the gate and the event
    /// leaves a gated, un-narrowed book, which costs one old build one project;
    /// the other order costs the book its permits with nothing to say so.
    ///
    /// `reason` is the underlying failure's own words — a folder that would not
    /// read, a disk that would not take the write — because *the manifest could
    /// not be written* tells the writer nothing they can act on.
    case manifestNotGated(reason: String, act: Act)

    /// **Which act a refusal is about** (fix round 2, minor C).
    ///
    /// The four verbs that compute a mark all refuse over a short reading, and
    /// they refused in a revocation's words because a revocation was the first
    /// of them. It is a noun the writer reads, not a verb name from the code:
    /// each says what did not happen, in the vocabulary of the control that
    /// was pressed.
    public enum Act: String, Equatable, Sendable {
        case admission, permitChange, revocation, retirement

        /// The phrase the one sentence puts in the middle of itself.
        public var phrase: String {
            switch self {
            case .admission: return "letting a device in"
            case .permitChange: return "a change to what a device may write"
            case .revocation: return "a revocation"
            case .retirement: return "standing a device down"
            }
        }
    }
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
    ///   - role: which rung of the ladder (spec §2). Defaults to `"author"`,
    ///     which is what every P2 admission meant and what every existing
    ///     caller still asks for.
    ///   - scope: `"book"` or `"pieces"`. Defaults to the whole book.
    ///   - pieces: the document ids, under `"pieces"` alone. Legitimately
    ///     empty — *she may write what she starts*.
    ///   - mark: where this root had READ TO in that person's streams when it
    ///     let them in (`OpLogStore.seenPositions`). Informational for an
    ///     admission and load-bearing for a RE-admission, and the difference is
    ///     `PermitTimeline.opening(before:)`'s: an `admitted` event's permit
    ///     governs everything the person ever wrote, on both sides of its mark,
    ///     because there is nothing before an admission — whereas a
    ///     `readmitted` one is a change like any other and its mark is where
    ///     the change begins.
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
        role: String = Permit.authorRole,
        scope: String = Permit.bookScope,
        pieces: [String] = [],
        mark: PermitMark = .nothingApplied,
        unsigned: PermitMark? = nil,
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
            role: role, scope: scope, pieces: pieces, mark: { _ in mark },
            unsigned: unsigned,
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
    ///
    /// **`mark` is a CLOSURE here and a value at the public door.** This is the
    /// one called in a loop (`RegistryPresence.admitRemembered` admits every
    /// remembered device at a project open), and computing where the root had
    /// read to in somebody's streams is a sweep of every op-log file in the
    /// project. Asked per device actually admitted, a book with nobody to admit
    /// — which is every open of every book — pays nothing.
    ///
    /// **`silently` is the memory path's, and it decides one word.** A device
    /// this writer has already named elsewhere is let in with no sheet, and
    /// `silentlyAdmitted` is the `TrustEvent.Kind` that has existed since P2b
    /// with nothing to write it (C11). A RE-admission outranks it: what matters
    /// to the timeline is that there was something before.
    @discardableResult
    nonisolated static func admit(
        device fingerprint: String,
        label: String,
        ownName: String,
        role: String = Permit.authorRole,
        scope: String = Permit.bookScope,
        pieces: [String] = [],
        mark: (String) throws -> PermitMark = { _ in .nothingApplied },
        /// Where every unattributable stream in the book stands
        /// (`OpLogStore.unattributablePositions`). Required for a NARROWING
        /// admission and refused without one; meaningless and dropped for any
        /// other, so `admitRemembered`'s loop — which admits book authors —
        /// never computes it. **A value rather than a closure**, unlike
        /// `mark`: the photograph is of the BOOK and not of one person's
        /// streams, so a caller admitting several devices in one open sweeps
        /// for it once or not at all.
        unsigned: PermitMark? = nil,
        silently: Bool = false,
        in projectURL: URL,
        by root: DeviceIdentity,
        within registry: Registry,
        memory: AdmissionMemory,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> PersonRecord {
        guard registry.holdsARootRecord(root.fingerprint) else {
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
        // History no longer pays for it (P3a Task 7). Under P2 the events were
        // derived from the records, so a cleared `revokedAt` took the revoked
        // row with it; the revocation's own signed EVENT survives the clearing,
        // and `TrustEvents` reads it.
        //
        // **A RE-admission is `readmitted`, never `admitted`** (Task 7's first
        // ruling), and the difference is the whole of `PermitTimeline
        // .opening(before:)`: an `admitted` event's permit governs everything
        // the person ever wrote, so writing one here would judge a P2 author's
        // pre-revocation chapters under whatever permit she is let back in
        // with. A demotion at the door would reach back through the book.
        let readmission = existing?.isRevoked == true
        let kind: PermitEvent.Kind = readmission
            ? .readmitted
            : (silently ? .silentlyAdmitted : .admitted)

        // **A standing person's permit is not `admit`'s to move.** This arm is
        // reached only for a label or an own-name that drifted (the guard above
        // returns otherwise), and that is a rename: carrying the parameters in
        // would let a correction to a machine's name silently rewrite what its
        // owner may write, with no event behind it and no timeline to say so.
        // `changePermit` is the verb for that, and it writes the history.
        let standing = standingRecord(existing)
        let writtenRole: String
        let writtenScope: String?
        let writtenPieces: [String]?
        if let standing {
            writtenRole = standing.role
            writtenScope = standing.scope
            writtenPieces = standing.pieces
        } else {
            writtenRole = role
            // **A book author's record carries neither key**, exactly as every
            // P2-era record does. The format's own rule is that a missing
            // `scope` MEANS `"book"` (spec §3.1), so writing the two keys onto
            // an ordinary admission would move the bytes of every new record to
            // state a fact they already state. A permit that is anything else
            // writes both, explicitly, because *an author of no pieces yet* is
            // a real state and must not hang on an absent key.
            let asked = Permit.parse(role: role, scope: scope, pieces: pieces)
            writtenScope = asked == .bookAuthor ? nil : scope
            writtenPieces = asked == .bookAuthor ? nil : pieces
        }

        // **The event, THEN the record** (spec §3.2). A crash between the two
        // leaves the history whole and the current-state record one step
        // behind, which `recordBehindEvents` detects and a root's pane offers
        // to re-sign — where the other order would leave a person admitted with
        // no history saying what they may write, and the timeline reads the
        // history and nothing else.
        //
        // **And only where it is not already there** (fix round 1, minor 2).
        // The record is the half that fails, so the arrival event can be on
        // disk while `registry.person(fingerprint)` still answers nil — and
        // for `admitRemembered` that state is re-entered at every PROJECT
        // OPEN, which would have written one `silentlyAdmitted` event per open
        // for as long as the record failed to land.
        let eventPermit = Permit.parse(
            role: writtenRole, scope: writtenScope, pieces: writtenPieces)
        if standing == nil,
           !eventAlreadyWritten(kind, permit: eventPermit,
                                about: fingerprint, in: registry) {
            // Before the sweep and before the write: a refusal here has left
            // nothing on disk and nothing in the label memory.
            try refuseANarrowingWithNoSnapshot(
                eventPermit, unsigned: unsigned, subject: fingerprint)
            try writeEvent(
                kind, about: fingerprint,
                role: writtenRole, scope: writtenScope ?? Permit.bookScope,
                pieces: writtenPieces ?? [],
                mark: try mark(fingerprint), unsigned: unsigned,
                in: projectURL, by: root,
                within: registry, now: now, presenter: presenter)
        }

        let record = PersonRecord(
            person: fingerprint, label: label, ownName: ownName, role: writtenRole,
            scope: writtenScope, pieces: writtenPieces,
            admittedAt: existing?.admittedAt ?? now(),
            admittedBy: root.fingerprint,
            revokedAt: nil, revokedBy: nil,
            highestOpIdSeen: nil)
        try RegistryWriter.write(
            record, signedBy: root, in: projectURL, presenter: presenter)
        memory.remember(fingerprint, label: label, ownName: ownName, at: now())
        return record
    }

    /// **The record whose permit `admit` may not move** — one already standing.
    ///
    /// A person record that is here and not revoked is a person this book has
    /// already decided about: `admit` over them is a rename at most, it writes
    /// NO event, and it carries their own stored role and scope back into the
    /// record rather than whatever it was asked for. A revoked record is the
    /// opposite case — a re-admission is the revocation's inverse and installs
    /// the permit it is given — and a fingerprint with no record at all is an
    /// ordinary admission.
    ///
    /// Public and spelled here rather than at the caller (Task 1's review,
    /// Minor 7) because a CALLER has to know it too: `DocumentStore.admit`
    /// takes the book's unsigned photograph and gates older builds out before
    /// it calls in, and both of those are the price of writing an EVENT. Asked
    /// of the permit it was handed rather than of the one that will be written,
    /// a rename of a standing person's machine would sweep every op-log file in
    /// the project and raise the book's schema for an act that writes neither.
    /// One spelling, so the two cannot disagree about which act is happening.
    nonisolated public static func standingRecord(
        _ existing: PersonRecord?
    ) -> PersonRecord? {
        existing.flatMap { $0.isRevoked ? nil : $0 }
    }

    // MARK: - Changing a permit (spec §6)

    /// **Change what one person may write** — the root's verb, and the only one
    /// that moves a permit (P3 spec §6).
    ///
    /// What it writes is an EVENT and then a re-signed record, in that order and
    /// for the reason the whole of §3.2 exists: the role check reads the
    /// timeline and never the record, so the history is what enforces and the
    /// record is the convenience. A crash between the two leaves enforcement
    /// correct and the record one step behind, which `recordBehindEvents`
    /// detects; the other order would leave a moment in which the record says
    /// *reviewer* and every reader still applies her manuscript text.
    ///
    /// **Both directions are the mark's** (spec §5, and it is the sentence this
    /// verb exists to make true). Everything at or before the mark stays under
    /// the permit that held when it was written — so a demotion does not reach
    /// back through chapters the writer has read, and a promotion does not
    /// pardon what was refused while the permit said no. Nothing here decides
    /// either; the mark selects which permit judges a line and
    /// `PermitPartition` does the judging.
    ///
    /// **The mark is the CALLER's**, exactly as a revocation's is, and for the
    /// same reason: it is a fact about how far THIS Mac has read, which needs a
    /// sweep of the project's op-log files and a look at the documents this
    /// window has open. `DocumentStore.changePermit` computes it through
    /// `OpLogStore.seenPositions` — *seen*, not *applied*: a mark does not bless
    /// lines, it selects which permit judges them (spec §3.3, corrected).
    ///
    /// **Monotonic, by construction and by carry-forward.** A new event's mark
    /// for a stream never sits before an older event's mark for the same stream,
    /// because both are *everything this root has read so far* and the root's
    /// view only grows. Where a stream is missing from the new mark and present
    /// in an older one — a file this Mac's copy of the folder has lost —
    /// `writeEvent` carries the older position forward rather than dropping it,
    /// because a dropped stream judges as wholly NEW and a demotion would reach
    /// back through the whole of it.
    ///
    /// **Four refusals**, each of authority rather than of form: this Mac is not
    /// a root here; the subject is a root, and a book must not end up with no
    /// author; the subject was admitted by somebody else's root, whose record is
    /// not mine to re-sign; and the record is present on disk and unreadable,
    /// which is not absent (RULING-54).
    ///
    /// **Idempotent against the TIMELINE, not the record** (Task 7's fifth
    /// ruling). A permit somebody already holds writes no event and no record:
    /// an event would be a second, identical entry in the history with a fresh
    /// mark, which moves nothing but costs every peer a signature to check, and
    /// a re-signed record would be a file for iCloud to carry for no change.
    /// The timeline is what it is asked of, because the record can be one step
    /// ahead of the history and that window is not a permit change.
    ///
    /// **`settling` names the pieces whose §4.5 question this act answers**
    /// (P3b smoke find F9, Denver's ruling of 2026-09-23: *Theirs* re-judges by
    /// REASON, not by position). It is written onto the event as `settled`,
    /// and `PermitTimeline` reads it: every line of hers in those pieces that
    /// an EARLIER permit refused only because the piece was not in it is
    /// judged as though it had been, wherever it sits. The mark stays the
    /// ordinary one — the answer moves no position, it moves which pieces the
    /// past permits are read as having held. Empty for every other caller, and
    /// then the event's bytes are what they always were.
    ///
    /// **The caller invalidates trust**, exactly as after an admission: this one
    /// moves what every open document APPLIES.
    @discardableResult
    nonisolated public static func changePermit(
        person fingerprint: String,
        role: String,
        scope: String,
        pieces: [String],
        mark: PermitMark,
        unsigned: PermitMark? = nil,
        settling: Set<String> = [],
        in projectURL: URL,
        by root: DeviceIdentity,
        cache: RegistryCache,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> PersonRecord {
        let registry = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        let existing = try changePermitOutcome(
            person: fingerprint, by: root.fingerprint, in: registry).get()

        let asked = Permit.parse(role: role, scope: scope, pieces: pieces)
        let timeline = PermitTimeline(events: events(about: fingerprint, in: registry))
        let recordSays = Permit.permit(recordedIn: existing)

        // **Two questions, not one** (fix round 1, I1). *Nothing to do* is the
        // history AND the record both saying this already. Asking only the
        // history — which is what R5's idempotence rule said, and what this
        // read until now — made the crash window permanent and silent: the
        // event lands, `resign` throws, and every later press finds the
        // timeline already saying *reviewer*, returns the STALE author record
        // with no error and no write, and P3b's pane draws *author* over a
        // person every reader is enforcing as a reviewer, forever.
        //
        // Asking only the record would be the mirror mistake — it would write
        // a second event every time the record was the half that failed.
        let eventDone = timeline.current == asked
        let recordDone = recordSays == asked
        guard !(eventDone && recordDone) else { return existing }

        if !eventDone {
            // Which of the two words for it: the ROLE moved, or only how much
            // of the book it covers. Both install a permit and both carry a
            // mark — the distinction is History's, so the writer reads *became
            // a reviewer* rather than *their pieces changed* when what
            // happened was the first.
            let kind: PermitEvent.Kind =
                timeline.current.wireRole == asked.wireRole ? .scopeChanged : .roleChanged
            // Before the write, so a refusal leaves the record un-re-signed
            // too: this verb's own contract is event-then-record, and neither
            // half may land without the other's premise.
            try refuseANarrowingWithNoSnapshot(
                asked, unsigned: unsigned, subject: fingerprint)
            try writeEvent(
                kind, about: fingerprint, role: role, scope: scope, pieces: pieces,
                mark: mark, unsigned: unsigned, settling: settling,
                in: projectURL, by: root, within: registry,
                now: now, presenter: presenter)
        }

        if !recordDone {
            try RegistryWriter.resign(
                existing, signedBy: root, in: projectURL, presenter: presenter
            ) { object in
                object["role"] = role
                object["scope"] = scope
                object["pieces"] = pieces
            }
        }

        let verified = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        guard let record = verified.person(fingerprint) else {
            // Written and did not read back — the one shape that must not be
            // reported as success, because the writer would believe a permit
            // had moved while every surface went on reading the old one.
            throw RegistryAdmissionError.recordUnreadable(fingerprint: fingerprint)
        }
        return record
    }

    /// **Who may change whose permit, decided over a registry and nothing
    /// else** — `renameOutcome`'s twin, and the one definition (fix round 1).
    ///
    /// Four refusals, each of AUTHORITY rather than of form: this Mac is not a
    /// root here; the subject is a root, and a book must not end up with no
    /// author; the subject was admitted by somebody else's root, whose record
    /// is not mine to re-sign; and the record is present on disk and will not
    /// read, which is not absent (RULING-54).
    ///
    /// It is a value rather than a throw because `DocumentStore.changePermit(
    /// everyRecordOf:to:)` asks it of EVERY record under one label before it
    /// moves any of them: a demotion that refused halfway would leave Sam a
    /// reviewer on her Mac and an author on her phone, which is the state this
    /// whole verb exists to prevent.
    nonisolated public static func changePermitOutcome(
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
        guard !existing.isRoot else {
            return .failure(.cannotChangeARoot(fingerprint: fingerprint))
        }
        guard existing.admittedBy == root else {
            return .failure(.alreadyAdmittedElsewhere(root: existing.admittedBy))
        }
        return .success(existing)
    }

    /// **Every record a permit change must reach** (fix round 1, I3).
    ///
    /// A permit lives on a person RECORD and a record is one device, but P2b's
    /// admission merges a typed label matching a known one under that label's
    /// own spelling — so a writer with a Mac and a phone is two records the
    /// root has said are one person. Demote the Mac alone and she goes on
    /// writing manuscript text from the phone, with every reader applying it,
    /// and nothing anywhere saying why.
    ///
    /// The label rule is `TrustTable.sharesLabel` and is not restated here:
    /// exact strings, because the comparison must be the one the ROOT made
    /// when it signed the records, and an empty label shares with nobody.
    ///
    /// The subject's own record is always first and is always present (where
    /// this registry holds one); the rest are sorted by fingerprint, so two
    /// runs over one folder move them in the same order and a half-applied
    /// change reports the same list twice.
    nonisolated public static func records(
        sharingLabelWith person: String, in registry: Registry
    ) -> [PersonRecord] {
        guard let mine = registry.person(person) else { return [] }
        let others = registry.people
            .filter { $0.person != person && TrustTable.sharesLabel($0.label, mine.label) }
            .sorted { $0.person < $1.person }
        return [mine] + others
    }

    /// **Is this person's record a step behind their history?** — the crash
    /// window of spec §3.2's write order, made detectable (P3a Task 7).
    ///
    /// The event lands first and the record second, so a process that dies
    /// between them leaves a history that says *reviewer* and a record that
    /// still says *author*. **Nothing is wrong about what is APPLIED** — the
    /// role check reads the timeline and never the record — so this is not a
    /// refusal and no load blocks on it. It is a fact a surface states and a
    /// root re-signs (P3b), and it is here because this is the file that knows
    /// what the two are meant to agree about.
    ///
    /// True in the other direction too, and deliberately: a record naming a
    /// permit that no event installed disagrees with the history whichever way
    /// round the disagreement happened, and the answer — re-sign the record
    /// from the timeline — is the same.
    ///
    /// False for everybody with no events, which is every person in every book
    /// written before P3, and false for a person whose only events are a
    /// revocation or a retirement, which install no permit and so have nothing
    /// for a record to be behind.
    nonisolated public static func recordBehindEvents(
        person fingerprint: String, in registry: Registry
    ) -> Bool {
        let own = events(about: fingerprint, in: registry)
        guard !own.isEmpty else { return false }
        let timeline = PermitTimeline(events: own)
        guard timeline.hasEvents else { return false }
        guard let record = registry.person(fingerprint) else {
            // The event arrived and the record did not — the write order's own
            // window, seen from the far side.
            return true
        }
        return Permit.permit(recordedIn: record) != timeline.current
    }

    /// **Bring a person's record up to their history** — the crash window of
    /// spec §3.2's write order, closed by a press (P3b Task 5).
    ///
    /// Every permit verb writes the EVENT first and the record second, so a
    /// process that dies between them leaves a history saying *reviewer* and a
    /// record still saying *author*. Nothing about what is APPLIED is wrong —
    /// the role check reads the timeline (tripwire 43) — so no load blocks on
    /// it and there is nothing to refuse. What is wrong is that every surface
    /// drawing the record shows a permit the book is not enforcing, and there
    /// was no way to correct it: `changePermit` finds the timeline already
    /// saying what it was asked for, so it re-signs the record — but only
    /// where the caller happens to ask for exactly the permit the history
    /// already holds, which the pane cannot know to do.
    ///
    /// **It writes a RECORD and never an event**, which is the whole of why it
    /// is a verb of its own. There is no permit change here: the book's
    /// history is untouched, nothing narrows, and so nothing owes the
    /// photograph or the schema gate that a narrowing verb owes. It re-signs
    /// one file to say what the events already say.
    ///
    /// **`RegistryCanonical.resigned` keeps a later build's unknown fields**
    /// (tripwire 42), so a record written by a newer Maugham survives this
    /// press with everything but its three permit words intact.
    ///
    /// Its authority is `changePermitOutcome`'s exactly — the root that
    /// admitted them, never a root subject, never somebody else's chain —
    /// because re-signing a record IS the second half of a permit change and
    /// a Mac that may not perform one may not perform half of one either.
    ///
    /// Idempotent: a record already agreeing with its history is answered
    /// unchanged and no file is touched.
    @discardableResult
    nonisolated public static func resignFromTimeline(
        person fingerprint: String,
        in projectURL: URL,
        by root: DeviceIdentity,
        cache: RegistryCache,
        presenter: NSFilePresenter? = nil
    ) throws -> PersonRecord {
        let registry = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        let existing = try changePermitOutcome(
            person: fingerprint, by: root.fingerprint, in: registry).get()

        let timeline = PermitTimeline(events: events(about: fingerprint, in: registry))
        guard timeline.hasEvents else { return existing }
        let says = timeline.current
        guard Permit.permit(recordedIn: existing) != says else { return existing }

        try RegistryWriter.resign(
            existing, signedBy: root, in: projectURL, presenter: presenter
        ) { object in
            object["role"] = says.wireRole
            object["scope"] = says.wireScope
            object["pieces"] = says.wirePieces
        }

        let verified = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        guard let record = verified.person(fingerprint) else {
            // Written and did not read back — the one shape that must not be
            // reported as success, because the pane would redraw the row it
            // has just told the writer it corrected.
            throw RegistryAdmissionError.recordUnreadable(fingerprint: fingerprint)
        }
        return record
    }

    /// **Is the event this act would write already on disk?** (fix round 1, I1
    /// and minor 2.)
    ///
    /// Every verb here used to ask one question — *does the RECORD already say
    /// this?* — and write both files when the answer was no. The write order is
    /// event, then record (spec §3.2), so a process that dies between them
    /// leaves a state where the record still says no and the event is already
    /// there: the next press, or for the silent admission the next PROJECT
    /// OPEN, wrote a SECOND event. Two `admitted` rows in History for one
    /// admission, two revocations for one revocation, and — because
    /// `PermitTimeline` reads the newest — a second mark drawn at a later
    /// position than the writer ever chose.
    ///
    /// So the question is two-part now: is the event there, is the record
    /// behind, write only what is missing. This is the first half.
    ///
    /// **The subject's NEWEST event, by kind and by the permit it carries.**
    /// Not *any* event of that kind: a person admitted, revoked and admitted
    /// again has two arrivals, and only the last of them is the one a repeat
    /// of today's act would duplicate. The permit is compared too, so a second
    /// `roleChanged` to a DIFFERENT rung is not mistaken for a retry.
    nonisolated private static func eventAlreadyWritten(
        _ kind: PermitEvent.Kind, permit: Permit,
        about subject: String, in registry: Registry
    ) -> Bool {
        guard let latest = events(about: subject, in: registry)
            .max(by: { $0.event < $1.event })
        else { return false }
        return latest.kind == kind && Permit(event: latest) == permit
    }

    /// One subject's events, which is every event whose `subject` names them.
    ///
    /// Spelled once because three verbs ask it and a filter written per caller
    /// is a filter that can drift — and the one that drifts silently is the one
    /// that MISSES an event, which reads as a permit nobody ever changed.
    nonisolated static func events(
        about fingerprint: String, in registry: Registry
    ) -> [PermitEvent] {
        registry.events.filter { $0.subject == fingerprint }
    }

    /// **Write one signed event.** The one place in production a `PermitEvent`
    /// is made (tripwire 41), and the one place the monotonicity carry-forward
    /// happens.
    ///
    /// **A stream present in an older mark and absent from this one is carried
    /// forward.** The two marks are both *everything this root had read*, so the
    /// new one is a superset of the old by construction — unless this Mac's copy
    /// of the folder has LOST a file, in which case the sweep cannot name a
    /// position in it. Dropping the stream would then judge the whole of it as
    /// NEW under the new permit, which for a demotion is a reach-back through
    /// every line of that file. Carrying the old position forward is the answer
    /// that cannot be wrong in that direction: at worst it keeps lines under the
    /// old permit that a complete sweep would have kept there anyway.
    ///
    /// Newest older event first, so the most recent position for a missing
    /// stream is the one that survives.
    ///
    /// **It applies to PERMIT events only**, and the exclusion is not tidiness.
    /// The two kinds of mark answer two different questions — a permit event
    /// records what the root had SEEN, a revocation what it had APPLIED — so
    /// carrying one into the other would mix them. And an EMPTY revocation mark
    /// is a first-class value: it is what *Set aside everything it wrote*
    /// means, and a carry-forward would quietly fill it with the admission's
    /// position and keep the whole of somebody's history the writer had just
    /// asked to have taken out.
    @discardableResult
    nonisolated private static func writeEvent(
        _ kind: PermitEvent.Kind,
        about subject: String,
        role: String,
        scope: String,
        pieces: [String],
        mark: PermitMark,
        unsigned: PermitMark? = nil,
        settling: Set<String> = [],
        in projectURL: URL,
        by signer: DeviceIdentity,
        within registry: Registry,
        now: () -> Date,
        presenter: NSFilePresenter?
    ) throws -> PermitEvent {
        let own = events(about: subject, in: registry)
        var streams = mark.streams
        if carriesForward(kind) {
            for older in own
                .filter({ carriesForward($0.kind) })
                .sorted(by: { $0.event > $1.event }) {
                for (key, position) in older.mark {
                    // **Per KEY was not enough** (final fix wave, W2). A
                    // carry-forward that only filled in whole streams left the
                    // case where a stream came back NAMED and SHORT: a rotation
                    // whose tail deletion syncs ahead of its segment answers
                    // with the new tail's line and none of the digests, and
                    // this event would then have recorded a position that
                    // forgets segments an earlier event had already listed —
                    // so every line in them judges NEW under the permit this
                    // event installs. These marks only ever GROW (see
                    // `carriesForward`), so the union is the honest merge.
                    //
                    // The LINE is a position in the live tail and there is only
                    // ever one of it, so an older one is kept only where this
                    // sweep found none at all.
                    guard let existing = streams[key] else {
                        streams[key] = position
                        continue
                    }
                    streams[key] = .init(
                        segments: Set(existing.segments)
                            .union(position.segments).sorted(),
                        line: existing.line ?? position.line)
                }
            }
        }

        // **The new id must sort strictly after this subject's latest one**
        // (fix round 1, minor 6). A ULID is monotonic within a PROCESS and
        // nowhere else, so a Mac relaunched after its clock stepped back mints
        // an id that sorts BEFORE the one it wrote yesterday — and everything
        // that reads this history in order then reads it backwards:
        // `PermitTimeline` puts the older permit last, and
        // `TrustTable.revocationMark`'s `max` takes the wrong revocation's
        // mark. Both decide what a reader APPLIES and neither goes red.
        //
        // The check is here because this is the one place an id is minted for
        // a subject, and it is a CHECK rather than a rule about clocks: where
        // the clock is honest — every ordinary write — nothing changes.
        var id = PermitEvent.mintID(subject: subject)
        if let latest = own.map(\.event).max(), id <= latest {
            id = PermitEvent.mintID(subject: subject, after: latest)
        }

        // **Only a NARROWING event carries the photograph** (P3b Task 1). A
        // book-author admission, a revocation and a retirement change nothing
        // about who may write what, so writing the field onto one would move
        // the bytes of an ordinary record to state something it does not mean
        // — and `UnsignedSnapshot.governing` would then have a second
        // candidate to choose between where the ruling names exactly one.
        //
        // **A later narrowing carries the GOVERNING photograph forward**
        // (P3c Task 7, Ruling Q — this comment used to say the opposite). The
        // earliest narrowing governs by `(at, event)`, and `at` is the
        // narrowing root's own clock, so a later event can govern: two
        // adopted roots whose clocks disagree, a clock that stepped back, or
        // simply a fresh Mac whose sync delivered the later event first. A
        // second identical answer is therefore exactly what is wanted — the
        // photograph is the same whichever event a reader picks, and the
        // cliff cannot move. The Mac's verbs pass the governor's mark in
        // (`DocumentStore.sweptUnsignedSnapshot`); this writer just records
        // what it is handed, and `refuseANarrowingWithNoSnapshot` still
        // refuses a narrowing handed nothing at all.
        let at = now()
        func made(
            unsigned unsignedStreams: [String: PermitEvent.StreamMark]?
        ) -> PermitEvent {
            PermitEvent(
                event: id, kind: kind, subject: subject,
                role: role, scope: scope, pieces: pieces, mark: streams,
                unsigned: unsignedStreams,
                // Nil unless this act answered §4.5's question, so every other
                // event's bytes are what they were (P3b smoke find F9).
                settled: settling.isEmpty ? nil : settling.sorted(),
                at: at, by: signer.fingerprint)
        }
        let draft = made(unsigned: nil)
        let event = PermitTimeline.narrows(draft)
            ? made(unsigned: (unsigned ?? .nothingApplied).streams)
            : draft
        try RegistryWriter.write(
            event, signedBy: signer, in: projectURL, presenter: presenter)
        return event
    }

    /// **The door on a narrowing written without its photograph** (P3b Task 1).
    ///
    /// Asked of the permit the EVENT will install rather than of the one the
    /// caller asked for, because `admit` deliberately does not move a standing
    /// person's permit: a re-admission that carries the parameters in and one
    /// that carries the record's own forward must be judged on what actually
    /// gets written.
    ///
    /// Called at the write, so a refusal leaves NOTHING behind — no event, no
    /// record, no remembered label.
    nonisolated private static func refuseANarrowingWithNoSnapshot(
        _ permit: Permit, unsigned: PermitMark?, subject: String
    ) throws {
        guard permit.narrows, unsigned == nil else { return }
        throw RegistryAdmissionError.narrowingWithoutASnapshot(fingerprint: subject)
    }

    /// Does this kind's mark say *everything the root has read*, and therefore
    /// only ever grow? True for the five that install a permit; false for a
    /// revocation (*what it had applied*) and a retirement (*what this device
    /// has written*), whose marks are their own and whose empty is a meaning.
    ///
    /// `.unknown` — a later build's verb — carries nothing forward, because
    /// this build cannot say which of the two its mark is.
    nonisolated private static func carriesForward(_ kind: PermitEvent.Kind) -> Bool {
        switch kind {
        case .admitted, .silentlyAdmitted, .roleChanged, .scopeChanged, .readmitted:
            return true
        case .revoked, .revokedEntirely, .retired, .unknown:
            return false
        }
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
    ///
    /// **`mark` is the same line, drawn where nobody can move it** (P3a Task 7,
    /// spec §3.3). `highestOpIdSeen` stays exactly as it was, written as today,
    /// for every P2-era reader — and the event beside it carries the CHAIN
    /// POSITIONS this Mac had APPLIED, which is the one act whose mark means
    /// applied rather than seen. An opId carries a timestamp its own writer
    /// chose; a position is a hash of bytes everybody holds, so a device shut
    /// out cannot backdate its way under the line. `RevocationSplit` reads the
    /// positions where an event exists and the opId where none does.
    ///
    /// **`RevocationScope.nothing` arrives as an EMPTY mark**, which judges
    /// every line NEW and so keeps nothing — the same thing a nil
    /// `highestOpIdSeen` has always meant, said in the other format.
    @discardableResult
    nonisolated public static func revoke(
        person fingerprint: String,
        in projectURL: URL,
        by root: DeviceIdentity,
        highestOpIdSeen: String?,
        mark: PermitMark = .nothingApplied,
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

        // **The event, THEN the record** (spec §3.2), for the order's own
        // reason one verb over: `RevocationSplit` reads the event's positions
        // where there is one, so a crash between the two leaves the line drawn
        // in the stronger of the two places and the record catching up.
        //
        // The role and scope it carries are the state it FOUND, not a change it
        // makes: a revocation installs no permit (`PermitTimeline` skips it),
        // and the fields are there so a surface reading the history knows what
        // the person was when they were shut out.
        //
        // **And only where it is not already there** (fix round 1, minor 2):
        // the guard above is about the RECORD, which is the half that fails,
        // so a retry after the event landed would draw a second line — at a
        // later position than the writer ever chose, because the mark is swept
        // again.
        let revocation: PermitEvent.Kind =
            highestOpIdSeen == nil ? .revokedEntirely : .revoked
        if !eventAlreadyWritten(
            revocation,
            permit: Permit.parse(
                role: existing.role, scope: existing.scope, pieces: existing.pieces),
            about: fingerprint, in: registry) {
            try writeEvent(
                revocation, about: fingerprint,
                role: existing.role,
                scope: existing.scope ?? Permit.bookScope,
                pieces: existing.pieces ?? [],
                mark: mark, in: projectURL, by: root, within: registry,
                now: now, presenter: presenter)
        }

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
    ///
    /// **Its event is signed by the device too** (P3a Task 7, spec §6), which
    /// is why `RegistryReader.entitled` lets a `retired` event through on
    /// `subject == by` alone and on nothing else. The mark it carries is this
    /// device's own positions in its own files — everything it wrote, it both
    /// saw and applied, so `seenPositions` over its own ids is the whole of it.
    /// That is what ruling 2C's *written while retired* is derived from: a line
    /// of its own after the mark is one it wrote after it said it had stopped.
    @discardableResult
    nonisolated public static func retire(
        device fingerprint: String,
        in projectURL: URL,
        by identity: DeviceIdentity,
        mark: PermitMark = .nothingApplied,
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

        // The event first, the record second (spec §3.2). Its role and scope
        // are the person record's where this book holds one — a retirement
        // changes no permit, and a root's own retirement must carry the root's
        // own permit or `RegistryReader` lists it malformed
        // (`eventDemotesARoot`).
        //
        // Written once, for the revocation's reason (fix round 1, minor 2):
        // the guard above reads the device RECORD, which is the half that
        // fails, so a retry after the event landed would file a second
        // retirement.
        let person = registry.person(fingerprint)
        let standing = Permit.parse(
            role: person?.role ?? Permit.authorRole,
            scope: person?.scope, pieces: person?.pieces)
        if !eventAlreadyWritten(
            .retired, permit: standing, about: fingerprint, in: registry) {
            try writeEvent(
                .retired, about: fingerprint,
                role: person?.role ?? Permit.authorRole,
                scope: person?.scope ?? Permit.bookScope,
                pieces: person?.pieces ?? [],
                mark: mark, in: projectURL, by: identity, within: registry,
                now: now, presenter: presenter)
        }

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

        // **A root taken in has to BE one** (C8). `Registry.chain(underRoot:)`
        // answers empty for anything that is not a self-signed root here, so a
        // claim naming a stranger used to be written, verified and adopt
        // nobody — leaving the writer looking at a book that had accepted their
        // merge and gone on quarantining everything in it. Sorted, so a list
        // with two bad names refuses on the same one twice running.
        let rootsHere = Set(registry.roots.map(\.person))
        for candidate in adopting.sorted() where !rootsHere.contains(candidate) {
            throw RegistryAdmissionError.cannotAdoptANonRoot(fingerprint: candidate)
        }

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
            // **The root write is gated on MY ROOT, not on the folder** (C8).
            // `TrustTable.myRoot` is `joinedRoot ?? ownRecord ?? admittingRoots
            // .first`, and the registry answers the last two — a root record
            // for one of my keys, or a chain that holds one — but not the
            // first. A device that has JOINED somebody's chain and whose person
            // record has not come down yet reads as absent from the folder, so
            // this arm would write it a self-signed root of its own: a second
            // root in a book it is already on somebody else's chain in, which
            // is the two-roots quarantine created by the act meant to leave it.
            if let joined = cache.joinedRoot(for: projectURL),
               joined != me.fingerprint {
                throw RegistryAdmissionError.alreadyAdmittedElsewhere(root: joined)
            }
            let name = registry.devices.first { $0.device == me.fingerprint }?.name
                ?? DeviceCode.short(me.fingerprint)
            try RegistryWriter.write(
                PersonRecord(
                    person: me.fingerprint, label: name, ownName: name, role: "author",
                    admittedAt: now(), admittedBy: me.fingerprint),
                signedBy: me, in: projectURL, presenter: presenter)
        }

        // **A claim file that is present and will not verify is LISTED, never
        // written over** (C8, and RULING-54's rule everywhere else in this
        // milestone). Without this the `else` branch below wrote a fresh claim
        // straight over it: a record this device could not read, replaced by
        // one that adopts only what THIS press named, silently dropping every
        // root the unreadable one had taken in. The reachable case is a
        // half-synced file, and it fixes itself.
        if unreadableClaims(in: registry).contains(me.fingerprint) {
            throw RegistryAdmissionError.recordUnreadable(fingerprint: me.fingerprint)
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
            //
            // **C8's fifth minor is NOT done, and that is a ruling** (P3a Task
            // 7, fix round 0). The handoff's one-line finding says the date
            // should move on a later adoption; `RegistryAdmissionTests
            // .test_adoptingASecondRootKeepsTheDayTheBookWasClaimed` is a
            // deliberately named P2 test saying it should not. A test outranks
            // a line of prose, and *the day the book was claimed* not moving
            // reads as intent rather than accident. The cost is real and is
            // stated rather than fixed: `TrustEvents` dates every `.adopted`
            // row off this one field, so a root taken in a week later is drawn
            // as having been adopted the day the book was claimed. Closing it
            // properly wants a date per adopted root, which this record has no
            // room for; surfaced to Denver.
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

    /// And of the CLAIMS directory, which `claim` asks (C8): a claim record
    /// present and unverified is one this Mac must not write over, because what
    /// it would replace is a list of adopted roots nobody can read back.
    nonisolated static func unreadableClaims(in registry: Registry) -> Set<String> {
        unreadable(in: registry, directory: .claims)
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
