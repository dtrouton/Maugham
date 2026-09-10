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
    @discardableResult
    nonisolated public static func ensureRootIfEmpty(
        in projectURL: URL,
        identities: LocalIdentities,
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
            label: mine.name, ownName: mine.name, role: "author",
            admittedAt: now(), admittedBy: author.fingerprint)
        return try RegistryWriter.write(
            record, signedBy: author, in: projectURL, presenter: presenter)
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
    /// whoever admitted it. Under my own root there is nothing to do; under
    /// ANOTHER root it is a second claimant, and merging chains is the writer's
    /// own act at a surface (Task 8's claim), never an open's.
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
    @discardableResult
    nonisolated public static func admitRemembered(
        in projectURL: URL,
        identities: LocalIdentities,
        cache: RegistryCache,
        memory: AdmissionMemory,
        now: () -> Date = { Date() },
        presenter: NSFilePresenter? = nil
    ) throws -> [PersonRecord] {
        let author = identities.author
        guard author.canSign else {
            reportUnsigned()
            return []
        }

        let registry = try RegistryReader.load(projectURL: projectURL, presenter: presenter)
        guard registry.roots.contains(where: { $0.person == author.fingerprint })
        else { return [] }

        var admitted: [PersonRecord] = []
        // Sorted, so an open that admits several devices writes them in the
        // same order whatever order the folder was read in — History reads the
        // same twice.
        for device in registry.devices.sorted(by: { $0.device < $1.device })
        where registry.person(device.device) == nil {
            guard let remembered = memory.label(for: device.device) else { continue }
            admitted.append(try RegistryAdmission.admit(
                device: device.device, label: remembered.label, ownName: device.name,
                in: projectURL, by: author, within: registry,
                memory: memory, now: now, presenter: presenter))
        }

        guard !admitted.isEmpty else { return [] }
        // One read for the cache and for the answer both: the records above are
        // the ones this open DECIDED, and a caller deriving History from them
        // should hold what a reader verifies.
        let verified = try RegistryAdmission.refresh(
            projectURL, cache: cache, presenter: presenter)
        return admitted.map { verified.person($0.person) ?? $0 }
    }

    /// Is there a person record here this device could not vouch for?
    ///
    /// Asked of the malformed listing, by DIRECTORY: a record's own shape is
    /// exactly what a malformed listing cannot tell you — the bytes would not
    /// decode, or the name and the fingerprint disagree — so the only thing
    /// left that says what it was meant to be is where it lives. Claims live
    /// under `people/claims/`, a directory of their own, and are not people.
    nonisolated private static func holdsAnUnreadablePerson(
        _ registry: Registry, in projectURL: URL
    ) -> Bool {
        let people = RegistryWriter.directoryURL(.people, in: projectURL)
            .standardizedFileURL.path
        return registry.malformed.contains {
            $0.url.deletingLastPathComponent().standardizedFileURL.path == people
        }
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
