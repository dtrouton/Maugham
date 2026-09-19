import Foundation
import os

/// Diagnostic channel for the two failures this type can suffer quietly: the
/// memory could not be persisted, and a remembered record could not be decoded
/// on the way back out.
private let registryCacheLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.core",
    category: "RegistryCache")

/// Which record, in which of the registry's three directories. A pair rather
/// than a URL, so a surface can name a record that no longer has a file.
///
/// Deliberately not `Codable`: what is persisted is the record's own bytes
/// (`RegistryCache.Entry`), and a ref is how a caller and a surface talk about
/// one afterwards.
public struct RecordRef: Equatable, Hashable, Sendable {
    public let directory: RegistryDirectory
    public let fingerprint: String

    public init(directory: RegistryDirectory, fingerprint: String) {
        self.directory = directory
        self.fingerprint = fingerprint
    }
}

/// **A record this device put back, and the day it did** (P2b Task 10).
///
/// A restoration is the loudest thing `RegistryCache.reconcile` does — it
/// writes a file back onto shared storage — and until this existed it was
/// reported only to whoever happened to be calling. History could name the kind
/// (`TrustEvent.Kind.recordRestored`) and had nothing to date it with, so a
/// deletion somebody made last week either went unmentioned or would have been
/// stamped with the moment the pane was opened. The cache keeps the fact
/// because the cache is what noticed it.
public struct RestoredRecord: Equatable, Sendable {
    public let ref: RecordRef
    public let restoredAt: Date

    public init(ref: RecordRef, restoredAt: Date) {
        self.ref = ref
        self.restoredAt = restoredAt
    }
}

/// What this device remembers of the registry it last verified, per project —
/// and the root it joined (decision B1).
///
/// **Why a device-local memory at all.** A registry record is signed, so nobody
/// can forge one; nothing about a signature stops somebody DELETING one. iCloud
/// drops a file, a writer tidies a folder, a restore brings back a snapshot
/// taken before an admission — and a device that was admitted yesterday is a
/// stranger today, with no error anywhere, because absence is indistinguishable
/// from never-was. This memory is the extra fact only this device has: it saw
/// that record, it verified it, and it kept the bytes. Putting them back forges
/// nothing (`RegistryWriter.restore`), and the removal is REPORTED rather than
/// healed in silence — a record that vanishes is somebody's action, and the
/// writer is told (spec §2.4).
///
/// **Keyed like the op-log heads.** One project, one hash — the very hash
/// `OpLogDeviceState.fileKey` takes over the project root — and pruned on the
/// same two clauses (`OpLogDeviceState.rootIsGone`), so the two memories beside
/// each other under `device/` can never disagree about which project is gone.
///
/// **Isolation and identity** are `OpLogDeviceState`'s, verbatim and for its
/// reasons: an `NSLock` around a plain value with the persist inside it, and a
/// file belonging to another fingerprint starts empty and is rewritten. A
/// memory under a name this device does not answer to would otherwise come back
/// the moment anything else opened it.
public final class RegistryCache: @unchecked Sendable {

    /// The whole persisted value. No schema version: every field is additive
    /// and a missing one decodes empty.
    private struct Stored: Codable {
        /// Whose memory this is (`DeviceIdentity.author.fingerprint`).
        var identity: String = ""
        /// Project-root hash → what this device remembers about that project.
        var projects: [String: Project] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identity = try container.decodeIfPresent(String.self, forKey: .identity) ?? ""
            projects = try container.decodeIfPresent(
                [String: Project].self, forKey: .projects) ?? [:]
        }
    }

    private struct Project: Codable {
        /// The project root the key's hash was taken over. What makes an entry
        /// attributable, and so prunable — the key alone is a hash and names
        /// nothing that can be looked for on disk.
        var root: String = ""
        var records: [Entry] = []
        /// B1: the root whose chain first named this device here. Written once.
        var joinedRoot: String?
        /// When that join happened — the FIRST one, written once beside the
        /// root it stamps, because the sentence a surface makes of it (*on
        /// <label>'s chain since 9 Sep*) is about the day this device joined
        /// and not about the day a later claimant turned up.
        ///
        /// Optional for a second reason as well as the obvious one: a memory
        /// written before this field existed has a join and no date, and it
        /// must load rather than fail — a cache that failed to decode would
        /// take every record this device can restore down with it.
        var joinedAt: Date?
        /// Every other root that has since named it. Listed, never merged.
        var claimants: [String] = []
        /// What this device has put back here, and when. Oldest first, capped
        /// at `restoreLimit`.
        var restores: [Restore] = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            root = try container.decodeIfPresent(String.self, forKey: .root) ?? ""
            records = try container.decodeIfPresent([Entry].self, forKey: .records) ?? []
            joinedRoot = try container.decodeIfPresent(String.self, forKey: .joinedRoot)
            joinedAt = try container.decodeIfPresent(Date.self, forKey: .joinedAt)
            claimants = try container.decodeIfPresent([String].self, forKey: .claimants) ?? []
            restores = try container.decodeIfPresent([Restore].self, forKey: .restores) ?? []
        }
    }

    /// One restoration, kept so a surface can say WHEN it happened.
    ///
    /// The directory is a string for `Entry`'s reason: a directory a later
    /// build adds must cost this row and not the whole decode.
    private struct Restore: Codable, Equatable {
        var directory: String
        var fingerprint: String
        var restoredAt: Date
    }

    /// One remembered record: where it lives, what names it, and the bytes.
    ///
    /// **The bytes are the FILE's, not a re-encode.** `RegistryReader` carries
    /// each verified record's own bytes out of the read (`Registry.sourceBytes`)
    /// and they are what is kept here — pinned byte-for-byte by
    /// `RegistryCacheTests.test_aDeletedPersonRecordIsRestoredByteIdenticalAndReported`
    /// and, for the case that makes it matter, by
    /// `test_aRecordFromALaterBuildIsRememberedAndRestoredByteIdentical`.
    /// A record written by a later build carries a field this one has no
    /// property for; remembering the decoded fields would have this device
    /// quietly rewrite that record into its own vocabulary, and the signature it
    /// restored would then verify nowhere. Encoding the record is the fallback,
    /// for a registry assembled in memory rather than read from a folder.
    private struct Entry: Codable, Equatable {
        /// `RegistryDirectory.rawValue`. A string, so a directory a later build
        /// adds survives a read here rather than failing the whole decode.
        var directory: String
        var fingerprint: String
        var bytes: Data
    }

    public let fileURL: URL
    /// The fingerprint this memory belongs to.
    /// The fingerprint this memory belongs to, resolved on the first question
    /// that actually needs it. See `resolveIdentity`.
    public var identity: String {
        lock.lock()
        defer { lock.unlock() }
        return resolveIdentityLocked()
    }

    private let identitySource: () -> String
    private var resolvedIdentity: String?
    private let lock = NSLock()
    /// Nil until `loadLocked()` has run. **Not an empty memory** — the two are
    /// different, and conflating them is how a device forgets what it verified.
    private var loaded: Stored?

    /// A memory of whatever is at `fileURL` **that belongs to `identity`**, or
    /// an empty one. An unreadable or undecodable file starts empty: this is a
    /// memory, not a source of truth, and an empty memory simply restores
    /// nothing.
    ///
    /// **Nothing is read and no identity is resolved here** (P2b Task 10). The
    /// identity is this device's author fingerprint, and asking for it MINTS an
    /// enclave key if there is not one — `LocalIdentities`' lazy rule, where
    /// naming an actor is the writer's act. Constructing this type is not the
    /// writer naming anybody: `TrustResolution` reaches for the shared memory
    /// on the way past every project it opens, including the overwhelming
    /// majority that have no registry and never will. So the file is read on
    /// the first real question (`loadLocked`), and the identity is resolved
    /// only where the answer turns on it — a file that decoded, or a write.
    /// A project with no registry and no cache file resolves it never.
    ///
    /// A caller that already HOLDS the fingerprint hands it over, and there is
    /// nothing lazy left to do about an identity that has been resolved. The
    /// file is still read on first use — a memory nothing asks a question of
    /// reads nothing.
    public init(fileURL: URL, identity: String) {
        self.fileURL = fileURL
        self.identitySource = { identity }
        self.resolvedIdentity = identity
    }

    /// The lazy form. `shared` is the only production caller — a memory
    /// constructed on the way past a project, whose identity must not be asked
    /// for until a question turns on it.
    ///
    /// `internal` rather than private so a test can hand in a COUNTING closure
    /// and assert the count: *a project with no registry resolves no identity*
    /// is a claim about what is never called, and nothing but a seam can pin
    /// one (`RegistryCacheTests.test_aProjectWithNoRegistryNeverReachesForTheEnclave`).
    init(fileURL: URL, resolvingIdentity: @escaping () -> String) {
        self.fileURL = fileURL
        self.identitySource = resolvingIdentity
    }

    /// The process-wide memory, beside this device's key material and the
    /// op-log heads. Constructing it costs nothing; see `init`.
    public static let shared = RegistryCache(
        fileURL: DeviceState.directory.appendingPathComponent("registry-cache.json"),
        resolvingIdentity: { DeviceIdentity.author.fingerprint })

    /// Call with `lock` held. Resolves the identity once and remembers it, so
    /// a memory that has been written to does not ask the enclave again.
    private func resolveIdentityLocked() -> String {
        if let resolvedIdentity { return resolvedIdentity }
        let identity = identitySource()
        resolvedIdentity = identity
        return identity
    }

    /// Call with `lock` held. Reads the file at most once per instance.
    ///
    /// The order is the load-bearing part: the BYTES are read first, and the
    /// identity is asked for only when there are bytes that decoded. A missing
    /// file is the ordinary case and it needs no identity at all — the empty
    /// memory it starts is not persisted, so there is nothing to stamp.
    @discardableResult
    private func loadLocked() -> Stored {
        if let loaded { return loaded }
        let bytes = try? Data(contentsOf: fileURL)  // adr-0018-ok: this device's own registry memory — derived bookkeeping, never manuscript text
        let decoded = bytes.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        if let decoded, decoded.identity == resolveIdentityLocked() {
            var stored = decoded
            let pruned = Self.prune(&stored)
            loaded = stored
            if pruned { persistLocked() }
            return stored
        }
        var fresh = Stored()
        // A file that is there and is somebody else's is TAKEN OVER, which is a
        // write, so this one does resolve the identity — as the old eager init
        // did. A file that is not there is not.
        if bytes != nil {
            fresh.identity = resolveIdentityLocked()
            loaded = fresh
            persistLocked()
            return fresh
        }
        loaded = fresh
        return fresh
    }

    /// Call with `lock` held. The memory as it stands, loading it if need be.
    private var storedLocked: Stored {
        get { loadLocked() }
        set { loaded = newValue }
    }

    // MARK: - The key

    /// The hash this cache keys `projectURL` by: `OpLogDeviceState`'s own,
    /// taken over the project root. Public so a test — and Integrity, later —
    /// can ask which entry a project is.
    nonisolated public static func projectKey(_ projectURL: URL) -> String {
        OpLogDeviceState.scopeHash(ofRoot: projectURL)
    }

    // MARK: - Remembering

    /// What this device last verified for `projectURL`, or nil if it has never
    /// verified anything there.
    ///
    /// The records come back as they went in — signature included — because
    /// they are decoded from the bytes that were kept. A remembered record that
    /// will not decode is dropped and logged: it is this device's own memory,
    /// so a corrupt entry is a bug or a damaged file, never somebody's claim.
    public func cached(for projectURL: URL) -> Registry? {
        lock.lock()
        defer { lock.unlock() }
        guard let project = storedLocked.projects[Self.projectKey(projectURL)],
              !project.records.isEmpty
        else { return nil }
        return Self.registry(from: project.records)
    }

    /// The exact bytes remembered for one record, if any.
    public func rawBytes(of ref: RecordRef, for projectURL: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedLocked.projects[Self.projectKey(projectURL)]?
            .records.first { $0.directory == ref.directory.rawValue
                             && $0.fingerprint == ref.fingerprint }?.bytes
    }

    /// Remember `registry` as what this device has verified for `projectURL`,
    /// replacing whatever it remembered before, and persist before answering.
    ///
    /// Malformed listings are NOT remembered: they are facts about the folder
    /// at one moment, not records, and a memory of them would restore nothing
    /// and mislead everything.
    ///
    /// **It persists only when something moved.** Since every opened project
    /// gains a registry, a walk that resolves per document would otherwise pay
    /// a whole-file atomic write of this shared memory per iteration — sixty
    /// chapters in three languages is 180 of them, several on the main actor
    /// (whole-branch review, I1). Comparing first is what makes the ordinary
    /// case — the folder said what it said last time — cost nothing.
    public func remember(_ registry: Registry, for projectURL: URL) {
        remember(Self.canonical(Self.entries(of: registry)), for: projectURL)
    }

    /// The same act over entries the caller has assembled — `reconcile`'s, which
    /// remembers the registry it settled on PLUS the bytes of records that are
    /// present and will not verify (smoke find, 2026-09-19). Those contribute
    /// nothing to any registry and so appear in none, which is exactly why the
    /// memory has to carry them separately.
    ///
    /// Both doors canonicalize, so the two cannot disagree about order and the
    /// did-anything-move comparison below stays meaningful.
    private func remember(_ entries: [Entry], for projectURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        var project = storedLocked.projects[Self.projectKey(projectURL)] ?? Project()
        let root = projectURL.standardizedFileURL.path
        guard project.root != root || project.records != entries else { return }
        project.root = root
        project.records = entries
        storedLocked.projects[Self.projectKey(projectURL)] = project
        persistLocked()
    }

    /// Forget everything about one project — the records, the join and the
    /// claimants. Nothing in production calls it yet; pruning is how entries
    /// normally go.
    public func forget(_ projectURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        storedLocked.projects.removeValue(forKey: Self.projectKey(projectURL))
        persistLocked()
    }

    // MARK: - B1: the root this device joined

    /// The root whose chain first named this device in this project, if one
    /// has.
    public func joinedRoot(for projectURL: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedLocked.projects[Self.projectKey(projectURL)]?.joinedRoot
    }

    /// When this device joined the root it is on, if it has joined one. The
    /// first join's date: `join` writes it once, beside the root.
    public func joinedAt(for projectURL: URL) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return storedLocked.projects[Self.projectKey(projectURL)]?.joinedAt
    }

    /// Every other root that has since named this device here. Listed, never
    /// merged — each is somebody claiming a book this device already belongs to
    /// someone else's copy of.
    public func claimants(for projectURL: URL) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedLocked.projects[Self.projectKey(projectURL)]?.claimants ?? []
    }

    // MARK: - What this device has put back

    /// How many restorations one project keeps. A restoration is rare and a
    /// storm of them is one event — an iCloud folder that came back empty —
    /// so the cap is about the FILE and not about the history: fifty rows is a
    /// pane full, and the oldest go first.
    static let restoreLimit = 50

    /// Every record this device has put back here, oldest first.
    ///
    /// Read by History (`TrustEvents.derive`, which dates its
    /// `.recordRestored` from this) and by People & Devices, which marks the
    /// rows whose record it holds only because it restored one. Two surfaces,
    /// one list: a second place that decided what *restored* means would let
    /// the timeline and the row disagree about the same record.
    public func restores(for projectURL: URL) -> [RestoredRecord] {
        lock.lock()
        defer { lock.unlock() }
        return (storedLocked.projects[Self.projectKey(projectURL)]?.restores ?? [])
            .compactMap { restore in
                guard let directory = RegistryDirectory(rawValue: restore.directory)
                else { return nil }
                return RestoredRecord(
                    ref: RecordRef(directory: directory, fingerprint: restore.fingerprint),
                    restoredAt: restore.restoredAt)
            }
    }

    /// Record that `refs` were put back into `projectURL` at `when`.
    ///
    /// **A record restored twice is listed twice**, because it was deleted
    /// twice: the second deletion is the news, and collapsing the two would
    /// leave the writer reading a month-old date for something that happened
    /// this morning.
    ///
    /// `when` is an argument rather than a clock read inside, so the stamp can
    /// be pinned as a value; production passes nothing.
    private func recordRestores(
        _ refs: [RecordRef], in projectURL: URL, at when: Date
    ) {
        guard !refs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var project = storedLocked.projects[Self.projectKey(projectURL)] ?? Project()
        project.root = projectURL.standardizedFileURL.path
        project.restores.append(contentsOf: refs.map {
            Restore(directory: $0.directory.rawValue,
                    fingerprint: $0.fingerprint, restoredAt: when)
        })
        if project.restores.count > Self.restoreLimit {
            project.restores.removeFirst(project.restores.count - Self.restoreLimit)
        }
        storedLocked.projects[Self.projectKey(projectURL)] = project
        persistLocked()
    }

    /// Record that `root` names this device in this project, and answer the
    /// root this device is actually on.
    ///
    /// **Write-once (B1).** The first root wins. A later, different root is
    /// appended to `claimants` and the join is unchanged: an admission record
    /// cannot prove which Mac signed it, so a device that switched roots on the
    /// strength of one would be handing its history to whoever wrote last. The
    /// writer is shown the claimant and decides.
    ///
    /// **The date is written once with it**, so History can say *since 9 Sep*
    /// (spec §6). `at` is defaulted rather than read from a clock inside, which
    /// is what lets the stamp be pinned as a value; production passes nothing.
    @discardableResult
    public func join(root: String, for projectURL: URL, at when: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }
        var project = storedLocked.projects[Self.projectKey(projectURL)] ?? Project()
        project.root = projectURL.standardizedFileURL.path
        defer {
            storedLocked.projects[Self.projectKey(projectURL)] = project
            persistLocked()
        }
        guard let joined = project.joinedRoot else {
            project.joinedRoot = root
            project.joinedAt = when
            return root
        }
        if root != joined, !project.claimants.contains(root) {
            project.claimants.append(root)
        }
        return joined
    }

    /// Record `root` as somebody CLAIMING this device, without touching the
    /// join. Deduped; answers whether it was new.
    ///
    /// Separate from `join` because the two are different acts and only one of
    /// them is ever right for a device that is its own root. `join` writes the
    /// join when there is none, which for such a device would hand its book to
    /// the first other Mac that names it — arm 1 outranks arm 2 on the next
    /// resolve, so the device would switch chains and quarantine every peer it
    /// had admitted under its own root. A device with a root record of its own
    /// only ever LISTS a claimant (B1, spec §5).
    @discardableResult
    public func recordClaimant(root: String, for projectURL: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var project = storedLocked.projects[Self.projectKey(projectURL)] ?? Project()
        guard project.joinedRoot != root, !project.claimants.contains(root) else {
            return false
        }
        project.root = projectURL.standardizedFileURL.path
        project.claimants.append(root)
        storedLocked.projects[Self.projectKey(projectURL)] = project
        persistLocked()
        return true
    }

    // MARK: - Putting one record back on the writer's word (smoke find 1)

    /// What a deliberate restore can fail at, in a sentence a writer can read.
    ///
    /// `LocalizedError` because it travels to a surface through the ordinary
    /// fallback (`AdmissionDecision.refusal`, which has nothing to add to an
    /// error that is not a refusal of authority) — and an error with no
    /// description arrives there as an error domain and a number, which is the
    /// defect that fallback was fixed for.
    public enum RestoreError: Error, Equatable, LocalizedError {
        /// This device holds no verified bytes for that record, so there is
        /// nothing to put back. A surface offers Restore only where there are;
        /// this is the race, not the judgment.
        case nothingRemembered(RecordRef)

        public var errorDescription: String? {
            switch self {
            case .nothingRemembered(let ref):
                return "This Mac doesn’t remember a \(ref.directory.rawValue) record "
                    + "for \(DeviceCode.short(ref.fingerprint)) that verified, so "
                    + "there is nothing to put back."
            }
        }
    }

    /// **Put one record back because the writer asked** (P2 smoke find 1).
    ///
    /// `reconcile` restores a record that is ABSENT and deliberately leaves one
    /// that is PRESENT and will not verify exactly where it is: a device cannot
    /// tell *tampered with* from *damaged in transit*, and overwriting somebody
    /// else's signed record on shared storage on its own initiative is not a
    /// decision this app gets to make. A writer looking at the record, told in
    /// words what is wrong with it, is a different thing entirely — so this is
    /// a press, and it exists because until it did an unverifiable record had
    /// no surface and no way back at all.
    ///
    /// It goes through `RegistryWriter.restore` like every other restoration,
    /// which is what keeps the registry's writers three files (tripwire 41) and
    /// what keeps this from signing anything: the bytes were signed when they
    /// were first written and verified when this device kept them, and the next
    /// read verifies them again like any other record.
    ///
    /// It is RECORDED with the automatic ones, so the row says *put back* and
    /// History dates the event — a restoration leaves nothing in the folder
    /// afterwards, and this memory is the only place the fact survives.
    @discardableResult
    public func restore(
        _ ref: RecordRef,
        in projectURL: URL,
        presenter: NSFilePresenter? = nil,
        at when: Date = Date()
    ) throws -> URL {
        guard let bytes = rawBytes(of: ref, for: projectURL) else {
            throw RestoreError.nothingRemembered(ref)
        }
        let url = try RegistryWriter.restore(
            rawBytes: bytes, to: ref.directory, fingerprint: ref.fingerprint,
            in: projectURL, presenter: presenter)
        recordRestores([ref], in: projectURL, at: when)
        return url
    }

    // MARK: - Reconciling the folder against the memory

    /// The folder and this device's memory of it, resolved into one registry.
    ///
    /// - A record this device remembers and the folder no longer HOLDS is
    ///   **restored** from the remembered bytes and **reported**. Absence is
    ///   the whole of that test: present means a file is there, whether or not
    ///   it verified, so the fingerprints of `folder.malformed` count as
    ///   present beside the verified refs.
    /// - A record that is present and does NOT verify is reported malformed and
    ///   **left exactly as it is — and the bytes this device once verified for
    ///   it stay in the memory** (smoke find, 2026-09-19), so People & Devices
    ///   can offer Restore over it. It is in no registry, here or afterwards;
    ///   what it keeps is a way back, not any standing. A device cannot tell *tampered with* from
    ///   *damaged in transit*, and overwriting it would silently downgrade
    ///   another device's signed record on shared storage. The defence would
    ///   buy nothing anyway: a malformed record already contributes nothing to
    ///   the registry. The malformed listing is carried out untouched, and
    ///   Integrity shows it. (A record from a LATER build is no longer in this
    ///   population — the digest is over the file's own bytes since P2b Task 1,
    ///   so an unfamiliar field verifies rather than failing.)
    /// - A record the folder holds wins over the remembered one **when the
    ///   same key signed both**. A record legitimately changes: a device
    ///   re-signs its own record when it mints an actor key, a root re-signs a
    ///   person's to revoke them. What is not legitimate is a record changing
    ///   HANDS. A person record's expected signer is the root it names, so
    ///   another root can write a perfectly valid admission of somebody this
    ///   device already verified — and on the folder's word alone the second
    ///   Mac to open the book would take over the first one's record and the
    ///   whole chain hanging off it. So a folder record for a remembered
    ///   fingerprint under a DIFFERENT `sig.key` is listed
    ///   `malformed(.signerChanged)`, the remembered record stands, and the
    ///   folder's file is left exactly where it is (it is present; only an
    ///   absent record is restored). The claimant is shown, never merged — B1's
    ///   rule, one record down.
    ///
    ///   **The listing is where this ends.** Refusing the folder's copy takes it
    ///   out of the registry, and the registry is where `TrustResolution` looks
    ///   to find the roots that name this device — so a refusal that said
    ///   nothing would close the hole and silence B1's claimant list in the same
    ///   stroke. But recording the claimant is not this function's act: which
    ///   fingerprints are THIS device's is a question about four actor keys
    ///   (`LocalIdentities`), and this type holds one. `TrustResolution.resolve`
    ///   reads these listings beside the loop where it already decides the join
    ///   and the claimants, so there is one place that records a claimant rather
    ///   than two with different ideas of *me* (fix round 1, I1).
    /// - Whatever it settles on is then remembered — together with those
    ///   preserved bytes, which belong to no registry and would otherwise be
    ///   dropped by the very read that noticed the tampering — so the next
    ///   reconcile starts from what this device last verified rather than from
    ///   something older than the folder.
    ///
    /// `cached` is passed in rather than read here so the caller states which
    /// memory it means — nil is *nothing remembered*, and the answer is the
    /// folder unchanged.
    ///
    /// Throws only what the restore write throws: a record that could not be
    /// put back must not be reported as if it had been.
    @discardableResult
    public func reconcile(
        folder: Registry,
        cached: Registry?,
        in projectURL: URL,
        presenter: NSFilePresenter? = nil,
        at when: Date = Date()
    ) throws -> (registry: Registry, restored: [URL], removedBySomeone: [RecordRef]) {
        guard let cached else {
            remember(folder, for: projectURL)
            return (folder, [], [])
        }

        // The files that EXIST. A verified record has one by definition; a
        // malformed one has the file its listing names, which is precisely why
        // it is not restored over (whole-branch review, C2).
        let present = Set(Self.refs(of: folder) + folder.malformed.compactMap(\.ref))
        var restored: [URL] = []
        var removed: [RecordRef] = []
        var displaced: [MalformedRecord] = []
        /// Remembered records the folder still holds and can no longer vouch
        /// for: in no registry, and kept in the memory anyway.
        var preserved: [Entry] = []
        var devices = folder.devices
        var people = folder.people
        var claims = folder.claims
        var sourceBytes = folder.sourceBytes

        for entry in Self.entries(of: cached) {
            guard let directory = RegistryDirectory(rawValue: entry.directory) else { continue }
            let ref = RecordRef(directory: directory, fingerprint: entry.fingerprint)

            guard present.contains(ref) else {
                // Gone from the folder: put it back, byte for byte, and say so.
                // The bytes this device kept when it verified the record, which
                // are the bytes that were on disk; `cached` is decoded from them.
                let bytes = rawBytes(of: ref, for: projectURL) ?? entry.bytes
                restored.append(try RegistryWriter.restore(
                    rawBytes: bytes, to: directory, fingerprint: entry.fingerprint,
                    in: projectURL, presenter: presenter))
                removed.append(ref)
                sourceBytes[ref] = bytes
                Self.take(ref, from: cached, into: &devices, &people, &claims)
                continue
            }

            // **Present, and the folder's copy did not verify** (smoke find,
            // 2026-09-19). It is left exactly where it is and listed, and it
            // contributes nothing to the registry — all of that is right. What
            // was wrong is that the memory then dropped the good bytes it held,
            // because what is remembered is derived from the settled REGISTRY
            // and a malformed record is in no registry. So Restore, which
            // exists for precisely this, answered *this Mac doesn't remember an
            // earlier version of it* on the first read after the tampering —
            // and the bytes it needed had been thrown away by the read that
            // noticed. A deleted record survived only because an ABSENT ref is
            // carried through the branch above.
            //
            // Kept here, in the memory alone. Nothing is taken into `resolved`:
            // a record this device cannot vouch for must go on vouching for
            // nobody, and the ONE thing this changes is that the writer still
            // has a way back.
            guard let theirs = Self.signer(of: ref, in: folder) else {
                preserved.append(entry)
                continue
            }

            // Present and verified. The only question left is whose it is now.
            guard let mine = Self.signer(of: ref, in: cached),
                  mine != theirs
            else { continue }

            displaced.append(.signerChanged(
                ref, expected: mine, found: theirs, in: projectURL))
            Self.drop(ref, from: &devices, &people, &claims)
            sourceBytes[ref] = entry.bytes
            Self.take(ref, from: cached, into: &devices, &people, &claims)
        }

        let resolved = Registry(
            devices: devices.sorted { $0.device < $1.device },
            people: people.sorted { $0.person < $1.person },
            claims: claims.sorted { $0.newRoot < $1.newRoot },
            malformed: (folder.malformed + displaced).sorted { $0.url.path < $1.url.path },
            sourceBytes: sourceBytes)
        remember(Self.canonical(Self.entries(of: resolved) + preserved),
                 for: projectURL)
        // Dated AFTER the writes, and only for what actually went back: a
        // restore that threw took the whole reconcile with it, and a list
        // claiming a record was put back that is not on disk would send the
        // writer looking for a file nothing wrote.
        recordRestores(removed, in: projectURL, at: when)
        return (resolved, restored, removed)
    }

    /// Whose signature stands on the copy of `ref` this registry holds, if it
    /// holds one at all. A record with no signature never got this far — the
    /// reader lists it `.unsigned` — so nil here means *no such record*.
    private static func signer(of ref: RecordRef, in registry: Registry) -> String? {
        switch ref.directory {
        case .devices:
            return registry.devices.first { $0.device == ref.fingerprint }?.sig?.key
        case .people:
            return registry.people.first { $0.person == ref.fingerprint }?.sig?.key
        case .claims:
            return registry.claims.first { $0.newRoot == ref.fingerprint }?.sig?.key
        }
    }

    /// Move the remembered copy of `ref` into the answer being assembled.
    private static func take(
        _ ref: RecordRef, from cached: Registry,
        into devices: inout [DeviceRecord], _ people: inout [PersonRecord],
        _ claims: inout [ClaimRecord]
    ) {
        switch ref.directory {
        case .devices:
            if let record = cached.devices.first(where: { $0.device == ref.fingerprint }) {
                devices.append(record)
            }
        case .people:
            if let record = cached.people.first(where: { $0.person == ref.fingerprint }) {
                people.append(record)
            }
        case .claims:
            if let record = cached.claims.first(where: { $0.newRoot == ref.fingerprint }) {
                claims.append(record)
            }
        }
    }

    /// Take the folder's copy of `ref` out of the answer. The FILE is untouched
    /// — this decides only what the registry says, and the bytes on shared
    /// storage are somebody else's to explain.
    private static func drop(
        _ ref: RecordRef, from devices: inout [DeviceRecord],
        _ people: inout [PersonRecord], _ claims: inout [ClaimRecord]
    ) {
        switch ref.directory {
        case .devices: devices.removeAll { $0.device == ref.fingerprint }
        case .people: people.removeAll { $0.person == ref.fingerprint }
        case .claims: claims.removeAll { $0.newRoot == ref.fingerprint }
        }
    }

    // MARK: - Records ↔ entries

    /// Every record in a registry, as the bytes that were on disk.
    ///
    /// A record whose canonical bytes cannot be produced is dropped and logged
    /// rather than remembered half-formed — a memory it cannot restore from is
    /// worse than no memory of that record at all.
    private static func entries(of registry: Registry) -> [Entry] {
        var entries: [Entry] = []
        entries.append(contentsOf: registry.devices.compactMap { entry(of: $0, in: registry) })
        entries.append(contentsOf: registry.people.compactMap { entry(of: $0, in: registry) })
        entries.append(contentsOf: registry.claims.compactMap { entry(of: $0, in: registry) })
        return entries
    }

    private static func entry(
        of record: some RegistryRecordProtocol, in registry: Registry
    ) -> Entry? {
        let ref = RecordRef(directory: type(of: record).directory,
                            fingerprint: record.fingerprint)
        if let onDisk = registry.sourceBytes[ref] {
            return Entry(directory: ref.directory.rawValue,
                         fingerprint: ref.fingerprint, bytes: onDisk)
        }
        do {
            return Entry(
                directory: type(of: record).directory.rawValue,
                fingerprint: record.fingerprint,
                bytes: try RegistryCanonical.bytes(of: record))
        } catch {
            registryCacheLog.error("""
                Could not remember the registry record \
                \(record.fingerprint, privacy: .public): \
                \(String(describing: error), privacy: .public).
                """)
            return nil
        }
    }

    /// One order for the remembered list, whoever assembled it: by directory,
    /// then by fingerprint. Both `remember` doors pass through here so that a
    /// memory written by `reconcile` and one written from a registry compare
    /// equal when they hold the same records — without which the two would
    /// rewrite this shared file past each other on every read.
    ///
    /// A ref that somehow arrived twice keeps its FIRST entry: the settled
    /// registry's copy is assembled before anything preserved, and a record
    /// that is in the registry is one the folder vouched for.
    private static func canonical(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        return entries
            .filter { seen.insert("\($0.directory)/\($0.fingerprint)").inserted }
            .sorted {
                $0.directory == $1.directory
                    ? $0.fingerprint < $1.fingerprint
                    : $0.directory < $1.directory
            }
    }

    private static func refs(of registry: Registry) -> [RecordRef] {
        registry.devices.map { RecordRef(directory: .devices, fingerprint: $0.device) }
            + registry.people.map { RecordRef(directory: .people, fingerprint: $0.person) }
            + registry.claims.map { RecordRef(directory: .claims, fingerprint: $0.newRoot) }
    }

    /// The remembered entries, decoded back into a registry. Nothing is
    /// re-verified here: these are the records `RegistryReader` verified before
    /// they were remembered, and a second verifier would be a second opinion
    /// about what a record is. A record restored from a memory somebody edited
    /// is caught the same way every other record is — the next read lists it
    /// malformed and it contributes nothing.
    private static func registry(from entries: [Entry]) -> Registry {
        let decoder = RegistryCanonical.decoder()
        var devices: [DeviceRecord] = []
        var people: [PersonRecord] = []
        var claims: [ClaimRecord] = []
        // The remembered bytes travel back out with the records they decode to,
        // so a registry that came from this memory is as byte-faithful as one
        // that came from the folder — and remembering it again keeps the same
        // bytes rather than re-encoding them.
        var sourceBytes: [RecordRef: Data] = [:]
        for entry in entries {
            guard let directory = RegistryDirectory(rawValue: entry.directory) else { continue }
            do {
                switch directory {
                case .devices: devices.append(try decoder.decode(DeviceRecord.self, from: entry.bytes))
                case .people: people.append(try decoder.decode(PersonRecord.self, from: entry.bytes))
                case .claims: claims.append(try decoder.decode(ClaimRecord.self, from: entry.bytes))
                }
                sourceBytes[RecordRef(directory: directory,
                                      fingerprint: entry.fingerprint)] = entry.bytes
            } catch {
                registryCacheLog.error("""
                    A remembered registry record (\(entry.fingerprint, privacy: .public)) \
                    could not be read back: \(String(describing: error), privacy: .public).
                    """)
            }
        }
        return Registry(
            devices: devices.sorted { $0.device < $1.device },
            people: people.sorted { $0.person < $1.person },
            claims: claims.sorted { $0.newRoot < $1.newRoot },
            sourceBytes: sourceBytes)
    }

    // MARK: - Pruning

    /// Drops every project whose root is gone, on `OpLogDeviceState`'s own
    /// two-clause rule (D3′) — the root absent AND its parent present — so that
    /// a deleted project is forgotten and an unmounted volume is waited for.
    /// Answers whether anything went.
    private static func prune(_ stored: inout Stored) -> Bool {
        let dead = stored.projects.filter { _, project in
            !project.root.isEmpty && OpLogDeviceState.rootIsGone(atPath: project.root)
        }
        guard !dead.isEmpty else { return false }
        for key in dead.keys { stored.projects.removeValue(forKey: key) }
        return true
    }

    // MARK: - Persistence

    /// Call with `lock` held. Atomic, so a crash mid-write leaves the previous
    /// memory rather than a truncated one.
    ///
    /// **The identity is stamped HERE**, which is the one place it is certainly
    /// needed: a file on disk under no name would be read back by any identity
    /// at all, so writing is exactly when this device has to say whose memory
    /// this is. A memory that is only ever read resolves no identity and mints
    /// no key.
    private func persistLocked() {
        do {
            var out = loaded ?? Stored()
            out.identity = resolveIdentityLocked()
            loaded = out
            try DeviceState.ensureDirectory(fileURL.deletingLastPathComponent())
            try JSONEncoder().encode(out).write(to: fileURL, options: .atomic)
        } catch {
            registryCacheLog.error("""
                Could not persist the registry cache at \
                \(self.fileURL.path, privacy: .public): \
                \(String(describing: error), privacy: .public).
                """)
        }
    }
}
