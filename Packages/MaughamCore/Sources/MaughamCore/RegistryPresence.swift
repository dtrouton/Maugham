import Foundation
import os

/// Diagnostic channel for the one thing this type does quietly: a device with
/// no key, which writes nothing and must still be heard (parent spec §4.1).
private let presenceLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.core",
    category: "RegistryPresence")

/// **What a device writes about itself when it opens a book** (P2 spec §2.1 and
/// §3's *who writes the first root record*).
///
/// Two acts, deliberately separate, and the order between them is the contract:
///
/// 1. `ensureDeviceRecord` — *this is who I am*: my author key, my name, my
///    kind, and every actor key I hold. Written on a first open and RE-SIGNED
///    whenever those facts change, because `LocalIdentities` is lazy — the
///    assistant's key exists only once MCP has written something, and a device
///    record that does not list it has a reader treating this Mac's Claude as a
///    stranger (spec §4.4).
/// 2. `ensureRootIfEmpty` — *and there was nobody here, so I am the root*. Only
///    a **Mac**, and only in a book with no people in it at all. A book that
///    already has a root belongs to somebody; adopting it is a claim, and a
///    claim is the writer's decision, never an open's.
///
/// Both are **idempotent and quiet**: with nothing to say they write nothing at
/// all, which is what lets the Mac call them on every project open and the
/// phone on every write without touching a file.
///
/// Neither DECIDES anything about trust. They put this device's own facts on
/// disk; who is admitted is `TrustTable`'s question, asked of what
/// `RegistryReader` verifies.
public enum RegistryPresence {

    // MARK: - This is who I am

    /// Write — or re-sign — this device's own `DeviceRecord`, and answer the
    /// file if anything was written.
    ///
    /// It writes when there is no record of this device here, and when the
    /// record on disk disagrees with the facts: a name the writer changed, a
    /// kind, or an actor key that did not exist last time. It does NOT write
    /// when the record already says exactly this, so a project's folder is
    /// untouched by an open that had nothing to add.
    ///
    /// `madeAt` survives a re-signing: it is when this device declared itself
    /// in this book, not when it last had something to add.
    ///
    /// A **retired** device is left alone (spec §5). Its record carries its own
    /// signed `retiredAt`, and re-declaring it here would un-retire it — a
    /// device's retirement is its own act and nothing else's.
    ///
    /// An **unsigned** device (no enclave: a VM, CI's runner) writes nothing
    /// and says so once per process. An unsigned record is one every reader
    /// lists as malformed, so writing one would be a device losing its history
    /// to a state nobody chose (spec §2, parent §4.1).
    ///
    /// Throws what the read and the write throw: a registry record that is
    /// present and unreadable refuses the whole thing (RULING-54), because a
    /// device that re-declares itself over a folder it could only half read is
    /// deciding something by accident.
    ///
    /// The bare answer is the file; `ensureDeviceRecordReporting` answers it
    /// with whether the write changed whose device this is.
    @discardableResult
    nonisolated public static func ensureDeviceRecord(
        in projectURL: URL,
        identities: LocalIdentities,
        name: String,
        kind: DeviceKind,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil,
        personClaim intent: PersonClaimIntent = .keep
    ) throws -> URL? {
        try ensureDeviceRecordReporting(
            in: projectURL, identities: identities, name: name, kind: kind,
            now: now, presenter: presenter, personClaim: intent).file
    }

    /// **What `ensureDeviceRecord` did** — the file it wrote, if any, and
    /// whether that write changed whose device this is (#103).
    public struct DeviceRecordOutcome: Equatable, Sendable {
        /// The record written, or nil when nothing was.
        public let file: URL?
        /// A standing VERIFIED claim for one person key was replaced by a
        /// claim for ANOTHER (an Apple ID key reset): every other Mac stops
        /// recognising this device as the old key's person and asks about it
        /// again. Never a first claim (none → a key), never `.keep`, never
        /// `.remove` — dropping a claim is the writer's own act.
        ///
        /// **Known limit:** it compares against the record on disk only, so a
        /// change across a claim-less record is not reported — K1, then a
        /// record written with no claim (an older build, or
        /// `writeOwnRecordAgain`), then K2 at a later open reads as a first
        /// claim, although other Macs knew this device as K1's.
        public let personKeyChanged: Bool

        public init(file: URL?, personKeyChanged: Bool = false) {
            self.file = file
            self.personKeyChanged = personKeyChanged
        }
    }

    /// `ensureDeviceRecord`, answering what it did (`DeviceRecordOutcome`).
    /// The one body: the bare verb is this, less the report.
    nonisolated public static func ensureDeviceRecordReporting(
        in projectURL: URL,
        identities: LocalIdentities,
        name: String,
        kind: DeviceKind,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil,
        personClaim intent: PersonClaimIntent = .keep
    ) throws -> DeviceRecordOutcome {
        // MINTS, and should: this is a write path, and naming an actor is the
        // writer's act (`LocalIdentities`' lazy rule). Everything after this
        // ENUMERATES, so no other actor's key is minted by declaring oneself.
        let author = identities.author
        guard author.canSign else {
            reportUnsigned()
            return DeviceRecordOutcome(file: nil)
        }

        var actors: [String: String] = [:]
        for actor in identities.existingActors {
            actors[actor.rawValue] = identities[actor].fingerprint
        }
        // The author entry IS the device, and the reader refuses a record that
        // says otherwise (`MalformedRecord.Reason.authorActorIsNotTheDevice`).
        // Stated here rather than assumed, so this writer cannot produce a
        // record its own reader would throw away.
        actors[DeviceActor.author.rawValue] = author.fingerprint

        let registry = try RegistryReader.load(projectURL: projectURL, presenter: presenter)
        let existing = registry.devices.first { $0.device == author.fingerprint }
        // The claim already on disk, only if it HOLDS for this device: a
        // tampered or copied claim is not one this device can carry forward,
        // and not one a new claim can be "the same as".
        let standingClaim = existing.flatMap(RegistryReader.verifiedPersonClaim(of:))
        // `keep` is *no claim to make now* (no keychain this launch): losing the
        // keychain for a launch must not strip a true claim from the book.
        // `set` is verified for THIS device through the one verifier before it
        // can replace anything — a claim built for another device would never
        // verify here, and would silently un-recognise this device everywhere.
        let claim: PersonClaim?
        switch intent {
        case .keep:
            claim = standingClaim
        case .remove:
            claim = nil
        case .set(let offered):
            guard let verified = RegistryReader.verifiedPersonClaim(
                offered, forDevice: author.fingerprint)
            else {
                throw PersonClaimError.doesNotVerifyForThisDevice(device: author.fingerprint)
            }
            claim = verified
        }
        if let existing {
            guard existing.retiredAt == nil else { return DeviceRecordOutcome(file: nil) }
            // The claim is compared by its FACTS, never its signature: ECDSA
            // is randomized, so a claim signed afresh at each open would
            // otherwise rewrite the record at every open.
            if existing.name == name, existing.kind == kind, existing.actors == actors,
               standingClaim?.facts == claim?.facts {
                return DeviceRecordOutcome(file: nil)
            }
        }

        // Whose device this is changed only when a claim that HELD names
        // another key than the one replacing it (Denver's ruling on #103):
        // both present, keys differ. A first claim, a kept one and a removed
        // one are all excluded by needing both sides.
        let personKeyChanged: Bool
        if let before = standingClaim?.personKey, let after = claim?.personKey {
            personKeyChanged = before != after
        } else {
            personKeyChanged = false
        }

        let record = DeviceRecord(
            device: author.fingerprint, name: name, kind: kind, actors: actors,
            madeAt: existing?.madeAt ?? now(), personClaim: claim)
        let file = try RegistryWriter.write(
            record, signedBy: author, in: projectURL, presenter: presenter)
        return DeviceRecordOutcome(file: file, personKeyChanged: personKeyChanged)
    }

    // MARK: - A key named after the open (P3b smoke find F6)

    /// **Put an actor key this device has just named on its record here**,
    /// before the first line that key signs — and answer the file if anything
    /// was written.
    ///
    /// `ensureDeviceRecord` runs at OPEN, and `LocalIdentities` is lazy: the
    /// assistant's key exists only once MCP writes, the translator's once the
    /// pipeline runs, Maugham's once a rebalance does. A key minted after the
    /// open signed lines that the record did not name, so every other Mac held
    /// them as a stranger's until this one relaunched and reopened the book —
    /// on the smoke rig, an admitted reviewer's first Claude note. The write
    /// paths that sign as a non-author actor (`OpLogStore.append`,
    /// `TranslationStore.appendBatch`) ask this first.
    ///
    /// **It re-declares; it never declares.** The record on disk is RE-SIGNED
    /// by editing the file's own object (`RegistryWriter.resign`, rename's
    /// door): only `actors` changes, and every field a later build wrote on
    /// this device's record — and any actor it named that this build has no
    /// word for — survives (tripwire 42's rule, applied to a re-sign). The name
    /// and kind are the record's, so this device's name is still decided in
    /// exactly one place (the open). Where there is no record of this device
    /// here at all — a book this Mac never opened, or one whose open could not
    /// write — it writes nothing: the whole device is unknown there, and saying
    /// who it is is the open's act. A retired device is left alone, for
    /// `ensureDeviceRecord`'s reason.
    ///
    /// The AUTHOR is never declared from here: it IS the device, written at
    /// open, and a writer's keystroke path must not pay a registry read to
    /// learn so. It answers before touching the disk.
    ///
    /// An unsigned device writes nothing, quietly — `ensureDeviceRecord` has
    /// already said so once for this process at the open.
    ///
    /// Throws what the read and the write throw. The CALLERS treat a throw as
    /// *not yet* rather than *no*: the line is written regardless (the words
    /// are safe first), and the record catches up on a later line or the next
    /// open.
    @discardableResult
    nonisolated public static func declareActor(
        _ actor: DeviceActor,
        in projectURL: URL,
        identities: LocalIdentities,
        presenter: NSFilePresenter? = nil
    ) throws -> URL? {
        guard actor != .author else { return nil }
        // ENUMERATE before naming: a device whose author key does not exist has
        // declared itself nowhere, and naming the author here would mint a key
        // for an actor nothing is writing as (`LocalIdentities`' lazy rule).
        guard identities.existingActors.contains(.author) else { return nil }
        let author = identities.author
        guard author.canSign else { return nil }
        // A stat before a verified read: a book with no device records at all
        // — a project never opened on a Mac with a key — is answered without
        // reading the registry.
        guard FileManager.default.fileExists(
            atPath: RegistryWriter.directoryURL(.devices, in: projectURL).path)
        else { return nil }

        let registry = try RegistryReader.load(projectURL: projectURL, presenter: presenter)
        guard let existing = registry.devices.first(where: { $0.device == author.fingerprint }),
              existing.retiredAt == nil,
              existing.actors[actor.rawValue] != identities[actor].fingerprint
        else { return nil }

        // What the record says, plus every key this device now holds — an
        // entry this build cannot name is kept, never dropped. The author entry
        // IS the device (`ensureDeviceRecord`'s rule, for its reason).
        var actors = existing.actors
        for held in identities.existingActors {
            actors[held.rawValue] = identities[held].fingerprint
        }
        actors[DeviceActor.author.rawValue] = author.fingerprint
        return try RegistryWriter.resign(
            existing, signedBy: author, in: projectURL, presenter: presenter
        ) { object in
            object["actors"] = actors
        }
    }

    /// **`declareActor`, asked at most once per registry state** (the F6
    /// review's m2) — the door both write paths use.
    ///
    /// A registry that REFUSES — unwritable, or holding a record that will not
    /// read — would otherwise be asked again for every line an actor writes,
    /// and each asking is a verified read of the whole folder plus a write
    /// attempt. So each attempt, whatever it answered, is remembered against
    /// the registry's `TrustResolution.signature` taken AFTER it, per project
    /// and per actor key, for the life of the process: the next line asks only
    /// if the folder has changed since (a record repaired, restored, synced in
    /// — or this Mac's next open writing the record itself).
    ///
    /// **On the caller's actor, and only when due.** Both callers are
    /// `@MainActor` and ask `declarationIsDue` first, which reads no record;
    /// the verified read and the write run here only when that says yes. A
    /// detached hop was tried and measured to reorder what callers of
    /// `OpLogStore.append` observe, so the cost that stays on the main actor
    /// is one verified read (and write) per actor per registry state.
    ///
    /// Throws what `declareActor` throws, AFTER remembering the attempt.
    @discardableResult
    nonisolated public static func declareActorOnce(
        _ actor: DeviceActor,
        in projectURL: URL,
        identities: LocalIdentities,
        presenter: NSFilePresenter? = nil
    ) throws -> URL? {
        guard actor != .author,
              identities.existingActors.contains(actor) else { return nil }
        let key = memoKey(actor, in: projectURL, identities: identities)
        guard declarationMemo.shouldAttempt(
            key, signature: TrustResolution.signature(of: projectURL))
        else { return nil }
        declareAttemptObserverForTesting?(projectURL, actor)
        defer {
            declarationMemo.record(
                key, signature: TrustResolution.signature(of: projectURL))
        }
        return try declareActor(
            actor, in: projectURL, identities: identities, presenter: presenter)
    }

    /// **Would `declareActorOnce` do anything now?** — asked synchronously,
    /// without reading a record, so a caller can skip the hop off its actor
    /// when the answer is no: an author, an actor with no key, a book with no
    /// devices folder at all, or a registry already attempted in exactly this
    /// state. A yes is not a promise that anything will be written; it is only
    /// *the verified read is worth making*.
    nonisolated public static func declarationIsDue(
        _ actor: DeviceActor,
        in projectURL: URL,
        identities: LocalIdentities
    ) -> Bool {
        let existing = identities.existingActors
        guard actor != .author,
              existing.contains(actor), existing.contains(.author),
              identities.author.canSign,
              FileManager.default.fileExists(
                atPath: RegistryWriter.directoryURL(.devices, in: projectURL).path)
        else { return false }
        return declarationMemo.shouldAttempt(
            memoKey(actor, in: projectURL, identities: identities),
            signature: TrustResolution.signature(of: projectURL))
    }

    nonisolated private static func memoKey(
        _ actor: DeviceActor, in projectURL: URL, identities: LocalIdentities
    ) -> String {
        "\(projectURL.standardizedFileURL.path)|\(identities[actor].fingerprint)"
    }

    /// Test-only: told of every attempt `declareActorOnce` actually makes.
    nonisolated(unsafe) static var declareAttemptObserverForTesting:
        (@Sendable (URL, DeviceActor) -> Void)?

    private static let declarationMemo = DeclarationMemo()

    /// Project-and-key → the registry signature after the last attempt.
    private final class DeclarationMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var attempted: [String: String] = [:]

        func shouldAttempt(_ key: String, signature: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return attempted[key] != signature
        }

        func record(_ key: String, signature: String) {
            lock.lock()
            attempted[key] = signature
            lock.unlock()
        }
    }

    // MARK: - Writing this Mac's own record again (P3b Task 5, audit F4)

    /// **Why this device cannot put its own record back.**
    ///
    /// A refusal here is about AUTHORITY or about premise, never about form,
    /// and each arm is one the pane can draw as a reason beside a control that
    /// is not offered. `LocalizedError`, because `AdmissionDecision.sentence`
    /// is `RegistryAdmissionError`'s phrasebook and only that enum's — a second
    /// vocabulary inside it would be the thing the team lead's 2026-09-11
    /// ruling forbids.
    public enum RegistryPresenceError: Error, LocalizedError, Equatable {
        /// The file names a key that is not this device's. A device signs its
        /// own record; nobody signs somebody else's.
        case notThisDevicesRecord
        /// A directory whose records this device does not author at all — a
        /// claim, a permit event. Both have verbs of their own.
        case notADeviceOrPersonRecord
        /// The record on disk reads perfectly well. Writing over it would be
        /// replacing a good file with a guess.
        case theRecordVerifies
        /// This Mac signs nothing (no enclave), so a record it wrote would be
        /// one every reader lists as malformed — the state this is meant to
        /// repair.
        case thisMacSignsNothing
        /// The person record is this device's, but somebody else's root decides
        /// who is in this book. Re-writing it self-signed would make a second
        /// root out of a damaged file.
        case anotherMacDecidesWhoIsInThisBook(rootLabel: String?)
        /// The device record has to read before a person record can be rebuilt
        /// from it — the machine's own name lives there, and this is the one
        /// place this device's name is decided.
        case theDeviceRecordFirst

        public var errorDescription: String? {
            switch self {
            case .notThisDevicesRecord:
                return "Only the Mac a record is about can write it again. "
                    + "Open this book on that machine."
            case .notADeviceOrPersonRecord:
                return "This isn’t a record this Mac writes about itself."
            case .theRecordVerifies:
                return "This record reads correctly now, so nothing was written "
                    + "over it."
            case .thisMacSignsNothing:
                return "This Mac signs nothing it writes, so a record it wrote "
                    + "would be one no other Mac could check."
            case .anotherMacDecidesWhoIsInThisBook(let rootLabel):
                guard let rootLabel else {
                    return "This book was started on another Mac, and that Mac "
                        + "decides who is in it. Open the book there to put this "
                        + "record back."
                }
                return "This book was started on \(rootLabel), and that Mac "
                    + "decides who is in it. Open the book there to put this "
                    + "record back."
            case .theDeviceRecordFirst:
                return "This book’s file about this Mac doesn’t read either, so "
                    + "there is nothing here to rebuild from. Put that one back "
                    + "first."
            }
        }
    }

    /// **Write this device's own record again**, over one the reader refuses
    /// (P3b Task 5; audit PR #65's F4).
    ///
    /// The case this exists for: `RegistryCache.reconcile` short-circuits on a
    /// cold cache, so a Mac that has never verified a record it is now shown as
    /// malformed holds no bytes to Restore — and if that record is its own,
    /// every surface in the app reads *this book's file about this device
    /// doesn't check out* with nothing to press. A device signing its own
    /// record is its authority (spec §2): this is that authority used
    /// deliberately, by the writer, rather than at an open.
    ///
    /// **Two directions, and both are refusals of this verb rather than
    /// conventions of its callers.** It never writes over another device's
    /// record — a device record is signed by the machine it describes, and a
    /// root's person record by the root itself, so a Mac writing somebody
    /// else's would produce a file every reader lists as malformed, which is
    /// the state this repairs. And it never writes over a record that VERIFIES:
    /// the registry is re-read here, so a row the pane drew from a stale read,
    /// or one another Mac repaired while the sheet was up, is refused rather
    /// than overwritten with a guess.
    ///
    /// **The person record is the narrower arm, on purpose.** A device record
    /// says what a machine is and is self-evidently that machine's to write. A
    /// PERSON record says who is in the book, and re-writing one self-signed
    /// makes this Mac a root. Where the book still has a verified root, that is
    /// a second root made out of a damaged file, so it refuses and names the
    /// Mac to go to — which is also the honest answer, because that root is the
    /// one that signed the record and the only one that can re-sign it. Where
    /// the book has NO verified root at all, this device's own damaged root
    /// record is the whole of what is wrong and there is nobody else to ask:
    /// that is audit F4's case exactly.
    ///
    /// It answers the file it wrote.
    @discardableResult
    nonisolated public static func writeOwnRecordAgain(
        _ ref: RecordRef,
        in projectURL: URL,
        identities: LocalIdentities,
        name: String,
        writerName: String,
        kind: DeviceKind,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> URL {
        let author = identities.author
        guard ref.fingerprint == author.fingerprint else {
            throw RegistryPresenceError.notThisDevicesRecord
        }
        guard author.canSign else {
            reportUnsigned()
            throw RegistryPresenceError.thisMacSignsNothing
        }

        let registry = try RegistryReader.load(
            projectURL: projectURL, presenter: presenter)
        // Re-read rather than trust the row: a record repaired since the pane
        // drew it, by another Mac or by a Restore, must not be written over.
        guard registry.malformed.contains(where: { $0.ref == ref }) else {
            throw RegistryPresenceError.theRecordVerifies
        }

        switch ref.directory {
        case .devices:
            var actors: [String: String] = [:]
            for actor in identities.existingActors {
                actors[actor.rawValue] = identities[actor].fingerprint
            }
            // The author entry IS the device; `ensureDeviceRecord`'s own rule,
            // for its own reason (the reader refuses a record saying otherwise).
            actors[DeviceActor.author.rawValue] = author.fingerprint
            let record = DeviceRecord(
                device: author.fingerprint, name: name, kind: kind,
                actors: actors, madeAt: now())
            return try RegistryWriter.write(
                record, signedBy: author, in: projectURL, presenter: presenter)

        case .people:
            // A root that still verifies is the authority here, and it is not
            // this Mac — even where the damaged record is this device's own.
            if let root = registry.roots.first(where: { $0.person != author.fingerprint }) {
                throw RegistryPresenceError
                    .anotherMacDecidesWhoIsInThisBook(rootLabel: root.label)
            }
            guard let mine = registry.devices
                .first(where: { $0.device == author.fingerprint })
            else { throw RegistryPresenceError.theDeviceRecordFirst }
            let record = PersonRecord(
                person: author.fingerprint,
                label: rootLabel(writerName: writerName, deviceName: mine.name),
                ownName: mine.name, role: "author",
                admittedAt: now(), admittedBy: author.fingerprint)
            return try RegistryWriter.write(
                record, signedBy: author, in: projectURL, presenter: presenter)

        case .claims, .events:
            throw RegistryPresenceError.notADeviceOrPersonRecord
        }
    }

    // MARK: - And there was nobody here

    /// Write this device's self-signed root `PersonRecord` when the book has no
    /// people in it at all, and answer the file if one was written.
    ///
    /// **Three conditions, and each is a refusal in its own right.** The book is
    /// EMPTY of people; this device has already said who it is, because the
    /// root's `label`/`ownName` come from that record and this device's name is
    /// decided in exactly one place; and this device is a **Mac**. A phone never
    /// writes a root: it cannot be the device that owns the folder, and a phone
    /// that made itself one would be a second claimant on a book it can only see
    /// through the share (spec §3).
    ///
    /// **Empty means no person record FILE at all** — not one this device could
    /// not verify (Denver, 2026-09-10). A malformed person record is a root
    /// somebody tampered with, or one iCloud brought down half-written, and
    /// rooting beside it would put a second self-signed root next to a damaged
    /// original with nothing on the folder to say which came first. It is the
    /// distinction RULING-54 keeps everywhere else in this milestone: a thing
    /// that is present and unreadable is not a thing that is absent. The
    /// malformed record is already listed for Integrity by the reader, and
    /// claiming a book whose root cannot be read is P2b's, at a surface, by the
    /// writer.
    ///
    /// A book that already has people is somebody's, and adopting it is a claim
    /// — the writer's decision, made at a surface, never at an open (§5).
    ///
    /// The unsigned refusal is `ensureDeviceRecord`'s, for its reason.
    ///
    /// **The label is the WRITER's name; the own name is the MACHINE's** (P2
    /// smoke find 2). A person record's `label` is what this book calls the
    /// human, and labelling the root with the machine's name had People &
    /// Devices say *Denver's MacBook Air* three times over one Mac — header,
    /// person and device — with nothing on the screen distinguishing the writer
    /// from the laptop. `writerName` is the account's own full name, which is a
    /// LABEL and never an identity: this device is still its key's fingerprint
    /// (tripwire 35), and nothing reads this back to decide anything. Required
    /// rather than defaulted, so the registry path reads the account's name in
    /// exactly one place — `DocumentStore.thisWritersName`, beside the machine
    /// name it is paired with. (`NSFullUserName()` is also read, for an
    /// unrelated purpose and by a surface that never touches a record, in
    /// `UserPreferences.defaultCollaboratorDisplayName`.)
    @discardableResult
    nonisolated public static func ensureRootIfEmpty(
        in projectURL: URL,
        identities: LocalIdentities,
        writerName: String,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> URL? {
        let author = identities.author
        guard author.canSign else {
            reportUnsigned()
            return nil
        }

        let registry = try RegistryReader.load(projectURL: projectURL, presenter: presenter)
        guard registry.people.isEmpty,
              !holdsAnUnreadablePerson(registry, in: projectURL) else { return nil }
        guard let mine = registry.devices.first(where: { $0.device == author.fingerprint })
        else { return nil }
        guard mine.kind == .mac else { return nil }

        let record = PersonRecord(
            person: author.fingerprint,
            label: rootLabel(writerName: writerName, deviceName: mine.name),
            ownName: mine.name, role: "author",
            admittedAt: now(), admittedBy: author.fingerprint)
        return try RegistryWriter.write(
            record, signedBy: author, in: projectURL, presenter: presenter)
    }

    /// What a first root calls the person who wrote it: the account's own full
    /// name, and the machine's name where there is none.
    ///
    /// A blank account name is a real state — a Mac set up without one — and
    /// an empty `label` would give every surface a person row with nothing on
    /// it, which is worse than the machine name this replaced. Pure, so the
    /// fallback is pinnable without an account.
    nonisolated static func rootLabel(writerName: String, deviceName: String) -> String {
        let trimmed = writerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? deviceName : trimmed
    }

    // MARK: - And I already know who you are (decision B2)

    /// Admit, without asking, every stranger in this project whose fingerprint
    /// this writer has already named — and answer the records it wrote.
    ///
    /// The sheet in §4.1 is worth putting up once per device. A phone syncs
    /// into a second book, a third, a tenth, and the honest answer to the
    /// second sheet is *you already told me*: the label is in `AdmissionMemory`,
    /// so the person record is written at open and History says *admitted as
    /// Denver, remembered from Playlist*.
    ///
    /// **Only a root does this.** A device with no root record of its own here
    /// signs nothing any reader takes as an admission, and a remembered label
    /// is this writer's word rather than authority over somebody else's chain
    /// — so on another writer's book this admits nobody and says nothing.
    ///
    /// **A device the folder already has a person record for is left alone**,
    /// whoever admitted it — and a record that is present but did NOT verify
    /// counts as one (fix round 1, I1). Under my own root there is nothing to
    /// do; under ANOTHER root it is a second claimant, and merging chains is
    /// the writer's own act at a surface (Task 8's claim), never an open's.
    /// An unreadable record is the same ruling `ensureRootIfEmpty` keeps below:
    /// present and unreadable is not absent, and the reachable case is another
    /// Mac's admission whose root record has not landed yet.
    ///
    /// A **retired** device is admitted like any other if it is remembered:
    /// retirement quarantines what it writes AFTER retiring, and refusing it a
    /// person record would instead take its whole past out of the chain, which
    /// is a different and much larger claim.
    ///
    /// `ownName` comes from the device record in this folder — the device
    /// saying its own name now — rather than from the memory's copy, which is
    /// what a surface falls back to when there is no record here at all.
    ///
    /// The CALLER invalidates trust afterwards (`OpLogStore.invalidateTrust()`
    /// on every open document's store) and logs what came back: this function
    /// knows about a folder and a memory, not about open documents or History.
    ///
    /// Throws what the read and the writes throw. It reads the folder ONCE and
    /// refreshes the cache once at the end, so an open that admits three
    /// devices costs one verified read, three writes and one more read — not
    /// two reads per device.
    ///
    /// **Each admission writes a `silentlyAdmitted` event** (P3a Task 7) —
    /// the `TrustEvent.Kind` that has existed since P2b with nothing to write
    /// it (C11), and the one word that tells History *this Mac let it in
    /// because you had already named it* apart from *you were asked*. The event
    /// is minted inside `RegistryAdmission`, which stays the registry's one
    /// event writer (tripwire 41).
    ///
    /// `mark` is asked **per device actually admitted**, never per device
    /// present: where the root had read to in somebody's streams is a sweep of
    /// every op-log file in the project, and an open with nobody to admit —
    /// which is every open of every book — must not pay for one.
    ///
    /// **It THROWS rather than shortening** (fix round 1, I2). A sweep that
    /// could not list a folder or could not read a file must not answer with
    /// the positions it happened to find: a stream a mark does not name is
    /// judged wholly NEW. A throw here admits nobody else this time and leaves
    /// the devices already admitted standing — the open is not blocked, the
    /// caller logs it, and the next open runs the whole thing again.
    @discardableResult
    nonisolated public static func admitRemembered(
        in projectURL: URL,
        identities: LocalIdentities,
        cache: RegistryCache,
        memory: AdmissionMemory,
        mark: (String) throws -> PermitMark = { _ in .nothingApplied },
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> [PersonRecord] {
        let author = identities.author
        guard author.canSign else {
            reportUnsigned()
            return []
        }

        // The folder reconciled against what this device last verified, never a
        // raw read (fix round 1, C1): a root record iCloud has not brought down
        // yet would otherwise make this device a stranger on its own book.
        let registry = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        guard registry.holdsARootRecord(author.fingerprint) else { return [] }
        let unreadable = RegistryAdmission.unreadablePeople(in: registry)

        var admitted: [PersonRecord] = []
        // Resolved only once a remembered device is actually met, so an open
        // with nobody to admit — every open of every book — pays nothing.
        var narrowingTable: TrustTable?
        // Sorted, so an open that admits several devices writes them in the
        // same order whatever order the folder was read in — History reads the
        // same twice.
        for device in registry.devices.sorted(by: { $0.device < $1.device })
        where registry.person(device.device) == nil {
            // **A RETIRED device is never silently admitted** (P3c whole-branch
            // fix wave, I2; controller ruling AB). The mid-session pre-check
            // already filtered retirement out, so the same remembered machine
            // was refused mid-session and admitted — as an author of the whole
            // book — at the next open: one question, two answers, decided by
            // which event came first. The rule lands HERE, where the write is
            // (one of tripwire 41's three writers); the pre-check's filter is
            // belt over this brace. A retired machine that wants back in asks
            // through the sheet like any stranger.
            guard device.retiredAt == nil else { continue }
            guard let remembered = memory.label(for: device.device),
                  !unreadable.contains(device.device) else { continue }
            // **A remembered label that names a person this book has narrowed
            // is the sheet's** (Task 6, C1b): this path installs the whole
            // book, and a narrowed Sam's new machine must not arrive with more
            // than Sam holds. A recognised one has already been let in, with
            // Sam's own permit, by `admitRecognised`, which runs first.
            let table = narrowingTable ?? TrustTable.resolve(
                registry: registry, mine: identities,
                joinedRoot: cache.joinedRoot(for: projectURL))
            narrowingTable = table
            guard !RegistryAdmission.labelNamesANarrowedPerson(
                remembered.label, in: registry, table: table,
                thisRoot: author.fingerprint) else { continue }
            // **A device recognition RECOGNISES is recognition's business**
            // (Task 6 fix round). `admitRecognised` runs first, so a recognised
            // device still waiting here is one it DECLINED — a permit it could
            // not install silently — and the memory path must not let it in
            // with the whole book instead. The sheet decides.
            if let claim = registry.verifiedPersonClaim(forDevice: device.device) {
                switch Recognition.recognise(
                    device: device, verifiedClaim: claim, registry: registry,
                    thisRoot: author.fingerprint) {
                case .ownDevice, .knownPerson: continue
                case .ask: break
                }
            }
            admitted.append(try RegistryAdmission.admit(
                device: device.device, label: remembered.label, ownName: device.name,
                mark: mark, silently: true,
                in: projectURL, by: author, within: registry,
                memory: memory, now: now, presenter: presenter))
        }

        guard !admitted.isEmpty else { return [] }
        // One read for the cache and for the answer both: the records above are
        // the ones this open DECIDED, and a caller deriving History from them
        // should hold what a reader verifies.
        let verified = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        return admitted.map { verified.person($0.person) ?? $0 }
    }

    // MARK: - And I know whose device you are (your devices are you, Task 6)

    /// What one recognition pass did — the records it admitted, the records it
    /// linked a person key to, and every link the rules refused.
    public struct RecognitionPass: Equatable, Sendable {
        /// Devices let in without a sheet, as the records a reader verifies.
        public let admitted: [PersonRecord]
        /// Person records that gained a linked key in this pass.
        public let linked: [PersonRecord]
        /// Links `RegistryAdmission.linkPersonKey` refused, in its own words.
        /// Logged by the caller, never thrown: a refusal means *do not link*.
        public let refusedLinks: [String]
        /// Recognised devices NOT admitted, and why — a permit this build
        /// cannot write for them, or a person whose devices hold different
        /// permits (`RegistryAdmission.permitsAgree`). They reach the sheet
        /// like any stranger.
        public let declined: [String]

        public static let nothing = RecognitionPass(
            admitted: [], linked: [], refusedLinks: [], declined: [])

        /// Did the pass change who this book admits or recognises?
        public var changedTheRegister: Bool { !admitted.isEmpty || !linked.isEmpty }
    }

    /// **Admit, without asking, every newly seen device whose verified person
    /// claim this book already knows — and link the keys the rules allow**
    /// (spec *Your devices are you*; PK-2, PK-3).
    ///
    /// `admitRemembered`'s sibling, called right BEFORE it at open and
    /// mid-session (the controller's C1b): a device both recognised and
    /// remembered is let in here with its person's own permit, never by the
    /// memory path's whole book. Two acts, in this order:
    ///
    /// 1. **Link.** A person record gains a linked key only where a device
    ///    ALREADY admitted under that record shows a VERIFIED claim with that
    ///    key (PK-3) — which, for this Mac's own root record, is this Mac's own
    ///    claim, written by `ensureDeviceRecord` a moment before. Linking goes
    ///    through `RegistryAdmission.linkPersonKey`, whose label rules and
    ///    refusals are not relaxed here; a refusal is collected, never thrown.
    ///    A revoked or retired device links nothing: a machine this book has
    ///    let go is no evidence about anybody's key.
    /// 2. **Recognise.** Every device with no person record, not retired, not
    ///    shadowed by an unreadable person file, and carrying a verified claim
    ///    is put to `Recognition.recognise` with THIS Mac's own author
    ///    fingerprint as the root (never `TrustTable.myRoot`, which on an
    ///    admitted Mac names somebody else's root), and the answer is handed
    ///    to `RegistryAdmission.admitRecognised`, which reads the permit off
    ///    the timeline and writes the event — this file names no rung
    ///    (tripwire 49). Then act 1 again, so the record just written is
    ///    linked in the same pass.
    ///
    /// **Only a root does this** (Review Focus 5): a Mac with no root record of
    /// its own here admits nobody and links nothing, exactly as
    /// `admitRemembered` refuses — the check is the same `holdsARootRecord`.
    ///
    /// What a recognised person's permit may be, and when it is declined, is
    /// `RegistryAdmission.admitRecognised`'s.
    ///
    /// **It takes no label memory** (whole-branch review, Critical): the
    /// memory is only ever a sheet decision, and a recognition written into it
    /// would reach every other book this Mac roots through `admitRemembered`.
    ///
    /// The CALLER invalidates trust when `changedTheRegister`, and logs.
    /// Throws what the reads and the admissions throw, `admitRemembered`'s
    /// rule: a throw admits nobody else this time and the next open retries.
    @discardableResult
    nonisolated public static func admitRecognised(
        in projectURL: URL,
        identities: LocalIdentities,
        cache: RegistryCache,
        mark: (String) throws -> PermitMark = { _ in .nothingApplied },
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> RecognitionPass {
        let author = identities.author
        guard author.canSign else {
            reportUnsigned()
            return .nothing
        }
        var registry = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        // Review Focus 5, and the same test `admitRemembered` makes.
        guard registry.holdsARootRecord(author.fingerprint) else { return .nothing }

        var linked: [String] = []
        var refused: [String] = []
        if try linkClaimedKeys(
            in: projectURL, registry: registry, by: author, cache: cache,
            presenter: presenter, linked: &linked, refused: &refused) {
            registry = try TrustResolution.verifiedRegistry(
                projectURL: projectURL, presenter: presenter, cache: cache)
        }

        let unreadable = RegistryAdmission.unreadablePeople(in: registry)
        // The timeline is read off the same registry the decision is made
        // from, so the permit and the recognition cannot disagree.
        let table = TrustTable.resolve(
            registry: registry, mine: identities,
            joinedRoot: cache.joinedRoot(for: projectURL))
        var admitted: [String] = []
        var declined: [String] = []
        for device in registry.devices.sorted(by: { $0.device < $1.device })
        where registry.person(device.device) == nil {
            guard device.retiredAt == nil,
                  !unreadable.contains(device.device),
                  let claim = registry.verifiedPersonClaim(forDevice: device.device)
            else { continue }
            let recognition = Recognition.recognise(
                device: device, verifiedClaim: claim, registry: registry,
                thisRoot: author.fingerprint)
            // The permit is the permit layer's to install (tripwire 49): this
            // file hands over WHO, and `RegistryAdmission` reads WHAT off the
            // timeline and writes the event.
            switch try RegistryAdmission.admitRecognised(
                device: device, as: recognition, table: table,
                mark: mark, in: projectURL, by: author, within: registry,
                now: now, presenter: presenter) {
            case .admitted(let record): admitted.append(record.person)
            case .declined(let why):
                declined.append("\(DeviceCode.short(device.device)): \(why)")
            case .notRecognised: continue
            }
        }

        if !admitted.isEmpty {
            registry = try TrustResolution.verifiedRegistry(
                projectURL: projectURL, presenter: presenter, cache: cache)
            _ = try linkClaimedKeys(
                in: projectURL, registry: registry, by: author, cache: cache,
                presenter: presenter, linked: &linked, refused: &refused)
        }
        guard !admitted.isEmpty || !linked.isEmpty else {
            return RecognitionPass(
                admitted: [], linked: [], refusedLinks: refused, declined: declined)
        }
        let verified = try TrustResolution.verifiedRegistry(
            projectURL: projectURL, presenter: presenter, cache: cache)
        return RecognitionPass(
            admitted: admitted.compactMap { verified.person($0) },
            linked: linked.compactMap { verified.person($0) },
            refusedLinks: refused, declined: declined)
    }

    /// Act 1 of `admitRecognised`: link each admitted, standing device's
    /// verified claim key onto that device's own person record, where the
    /// record holds none (PK-3). Answers whether anything was written.
    ///
    /// **This Mac's own record goes first.** Its claim is the one claim here
    /// this Mac KNOWS is true — it holds that key — so the root's key reaches
    /// the root's record before any other device's claim can reach for it.
    /// Linked in fingerprint order instead, a device the root admitted as Sam
    /// whose claim names the root's key would take it, and the root's own
    /// record would then be refused its own key.
    ///
    /// **A key claimed under two labels links to neither** (outside this
    /// Mac's own). Which of two people a key is cannot be read off two
    /// devices that disagree, and whichever linked first would decide who
    /// every later device carrying it is recognised as. The refusal is listed;
    /// the writer settles it at People & Devices.
    ///
    /// Only records THIS root admitted are tried — `linkPersonKey` refuses any
    /// other (`renameOutcome`), and asking would only fill the log. Every
    /// other refusal (the key under another label, an unreadable person file,
    /// a malformed key) is collected in its own words.
    nonisolated private static func linkClaimedKeys(
        in projectURL: URL, registry: Registry, by author: DeviceIdentity,
        cache: RegistryCache, presenter: NSFilePresenter?,
        linked: inout [String], refused: inout [String]
    ) throws -> Bool {
        // **A key this chain has FORGOTTEN is not a candidate at all**
        // (whole-branch review, minor 5). `linkPersonKey` would refuse it,
        // and it would go on refusing at every open for ever, because the
        // devices already admitted keep carrying the claim: a Forget is a
        // settled decision, not a refusal to report. The same chain rule
        // `linkPersonKey` and `Recognition.recognise` read.
        let chain = TrustTable.chain(ofRoot: author.fingerprint, in: registry)
        let forgotten: (String) -> Bool = { key in
            registry.people.contains { chain.contains($0.person) && $0.hasForgotten(key) }
        }
        var candidates: [(person: PersonRecord, key: String)] = []
        for device in registry.devices.sorted(by: { $0.device < $1.device }) {
            guard device.retiredAt == nil,
                  let claim = registry.verifiedPersonClaim(forDevice: device.device),
                  let person = registry.person(device.device),
                  !person.isRevoked,
                  person.admittedBy == author.fingerprint,
                  person.personKey == nil,
                  !forgotten(claim.personKey)
            else { continue }
            candidates.append((person, claim.personKey))
        }
        let mineFirst = candidates.filter { $0.person.person == author.fingerprint }
            + candidates.filter { $0.person.person != author.fingerprint }
        let myKey = registry.verifiedPersonClaim(forDevice: author.fingerprint)?.personKey

        var wrote = false
        for candidate in mineFirst {
            let isMine = candidate.person.person == author.fingerprint
            if !isMine, candidate.key != myKey {
                let claimants = candidates.filter { $0.key == candidate.key }.map(\.person.label)
                let disagree = claimants.contains {
                    !TrustTable.sharesLabel($0, candidate.person.label)
                }
                if disagree {
                    refused.append(
                        "\(DeviceCode.short(candidate.person.person)): its key is claimed under more than one label")
                    continue
                }
            }
            do {
                try RegistryAdmission.linkPersonKey(
                    person: candidate.person.person, to: candidate.key,
                    in: projectURL, by: author, cache: cache, presenter: presenter)
                linked.append(candidate.person.person)
                wrote = true
            } catch let refusal as RegistryAdmissionError {
                refused.append("\(DeviceCode.short(candidate.person.person)): \(refusal)")
            }
        }
        return wrote
    }

    /// Is there a person record here this device could not vouch for?
    ///
    /// One definition, `RegistryAdmission.unreadablePeople`, asked by this and
    /// by both admission paths — because it answers whether a thing that is
    /// PRESENT counts as absent, and two answers to that is two different
    /// rulings about the same file.
    nonisolated private static func holdsAnUnreadablePerson(
        _ registry: Registry, in projectURL: URL
    ) -> Bool {
        !RegistryAdmission.unreadablePeople(in: registry).isEmpty
    }

    // MARK: - The loud unsigned

    /// Once per process, whatever a device opens. The condition is a fact about
    /// the MACHINE, not about a project, so saying it once per project would be
    /// the same sentence forty times on a busy morning — and saying it never is
    /// how a Mac quietly writes history nothing can vouch for.
    nonisolated private static func reportUnsigned() {
        unsignedNotice.once {
            presenceLog.error("""
                This device holds no signing key, so it declares itself in no \
                project: it writes no device record and no root record, and \
                every line it appends is unsigned history. That is a state, \
                not a failure — but it is one nothing else can vouch for.
                """)
        }
    }

    private static let unsignedNotice = OnceNotice()

    /// A said-it flag with a lock around it, so the sentence above survives two
    /// projects opening at once without becoming two sentences.
    private final class OnceNotice: @unchecked Sendable {
        private let lock = NSLock()
        private var said = false

        func once(_ body: () -> Void) {
            lock.lock()
            let first = !said
            said = true
            lock.unlock()
            if first { body() }
        }
    }
}

// MARK: - Whose device this is (your devices are you, plan 2 Task 1 fix round)

extension RegistryPresence {

    /// **What a device asks its record to say about whose it is** — the one
    /// rule, for the Mac's open and the phone's first write alike (tripwire 19).
    ///
    /// - A person key → `.set`, a claim signed for `device` (the device's
    ///   AUTHOR fingerprint — the record's own `device`).
    /// - No key (the store is unavailable, has no item, or the item is
    ///   unreadable) → `.keep`: a keychain that cannot answer now is not
    ///   evidence the writer left, and stripping a true claim would send this
    ///   device back to the sheet in the next book.
    /// - **`.remove` is never chosen here.** No signal either app can read says
    ///   a device left the Apple ID (`ubiquityIdentityToken` answers for iCloud
    ///   DRIVE, not iCloud Keychain). A claim that outlives a sign-out names a
    ///   key the device held; every reader verifies it and recognition links
    ///   only what a root decided, so the cost is a stale hint, never an
    ///   admission.
    ///
    /// The second value is the problem, if signing failed — a programming
    /// defect, answered as `.keep` so it costs the device nothing.
    nonisolated public static func claimIntent(
        forDevice device: String, personKey: PersonKey?
    ) -> (intent: PersonClaimIntent, problem: String?) {
        guard let personKey else { return (.keep, nil) }
        do {
            return (.set(try RegistryWriter.personClaim(
                forDevice: device, signedBy: personKey)), nil)
        } catch {
            return (.keep, "the person claim could not be signed: \(error)")
        }
    }

    /// **A device says who it is — and, where it can, whose it is.**
    /// `ensureDeviceRecord` with the claim `claimIntent` decided. A claim the
    /// record refuses (`PersonClaimError` — made for another device, or with
    /// another key than it names) is never written: the record is written
    /// again with `.keep`, so a broken claim never costs a device its record.
    ///
    /// Answers the problem (signing's or the refusal's), or nil. Saying it is
    /// the surface's — the Mac logs a fault and keeps it for a test, the phone
    /// logs it — and that is all each surface keeps.
    ///
    /// Throws what the registry read and write throw, exactly as the bare
    /// `ensureDeviceRecord` does.
    @discardableResult
    nonisolated public static func declareDevice(
        in projectURL: URL, identities: LocalIdentities, name: String,
        kind: DeviceKind, presenter: NSFilePresenter? = nil,
        claim: (intent: PersonClaimIntent, problem: String?)
    ) throws -> String? {
        try declareDeviceReporting(
            in: projectURL, identities: identities, name: name, kind: kind,
            presenter: presenter, claim: claim).problem
    }

    /// **What a declaration said** — the problem, if any, and whether the
    /// record now names a different person key than the claim that stood
    /// (`DeviceRecordOutcome.personKeyChanged`, #103). The Mac says the
    /// second in People & Devices; the phone has no such pane yet.
    public struct DeviceDeclaration: Equatable, Sendable {
        public let problem: String?
        public let personKeyChanged: Bool

        public init(problem: String?, personKeyChanged: Bool = false) {
            self.problem = problem
            self.personKeyChanged = personKeyChanged
        }
    }

    /// `declareDevice`, answering what it did. A claim the record refuses is
    /// re-written with `.keep`, which never changes the key.
    nonisolated public static func declareDeviceReporting(
        in projectURL: URL, identities: LocalIdentities, name: String,
        kind: DeviceKind, presenter: NSFilePresenter? = nil,
        claim: (intent: PersonClaimIntent, problem: String?)
    ) throws -> DeviceDeclaration {
        do {
            let outcome = try ensureDeviceRecordReporting(
                in: projectURL, identities: identities, name: name, kind: kind,
                presenter: presenter, personClaim: claim.intent)
            return DeviceDeclaration(
                problem: claim.problem, personKeyChanged: outcome.personKeyChanged)
        } catch let refused as PersonClaimError {
            try ensureDeviceRecord(
                in: projectURL, identities: identities, name: name, kind: kind,
                presenter: presenter, personClaim: .keep)
            return DeviceDeclaration(
                problem: "the person claim was refused by this device's own record: \(refused)")
        }
    }
}
