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
    @discardableResult
    nonisolated public static func ensureDeviceRecord(
        in projectURL: URL,
        identities: LocalIdentities,
        name: String,
        kind: DeviceKind,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> URL? {
        // MINTS, and should: this is a write path, and naming an actor is the
        // writer's act (`LocalIdentities`' lazy rule). Everything after this
        // ENUMERATES, so no other actor's key is minted by declaring oneself.
        let author = identities.author
        guard author.canSign else {
            reportUnsigned()
            return nil
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
        if let existing {
            guard existing.retiredAt == nil else { return nil }
            if existing.name == name, existing.kind == kind, existing.actors == actors {
                return nil
            }
        }

        let record = DeviceRecord(
            device: author.fingerprint, name: name, kind: kind, actors: actors,
            madeAt: existing?.madeAt ?? now())
        return try RegistryWriter.write(
            record, signedBy: author, in: projectURL, presenter: presenter)
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
        guard registry.roots.contains(where: { $0.person == author.fingerprint })
        else { return [] }
        let unreadable = RegistryAdmission.unreadablePeople(in: registry)

        var admitted: [PersonRecord] = []
        // Sorted, so an open that admits several devices writes them in the
        // same order whatever order the folder was read in — History reads the
        // same twice.
        for device in registry.devices.sorted(by: { $0.device < $1.device })
        where registry.person(device.device) == nil {
            guard let remembered = memory.label(for: device.device),
                  !unreadable.contains(device.device) else { continue }
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
