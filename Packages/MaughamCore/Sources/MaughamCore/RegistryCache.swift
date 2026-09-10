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
        /// Every other root that has since named it. Listed, never merged.
        var claimants: [String] = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            root = try container.decodeIfPresent(String.self, forKey: .root) ?? ""
            records = try container.decodeIfPresent([Entry].self, forKey: .records) ?? []
            joinedRoot = try container.decodeIfPresent(String.self, forKey: .joinedRoot)
            claimants = try container.decodeIfPresent([String].self, forKey: .claimants) ?? []
        }
    }

    /// One remembered record: where it lives, what names it, and the bytes.
    ///
    /// **The bytes are stored, not the fields.** They are produced by the one
    /// canonical encoder (`RegistryCanonical.bytes`), which is the same
    /// function `RegistryWriter` writes with, so what is kept here is what is on
    /// disk — pinned byte-for-byte by
    /// `RegistryCacheTests.test_aDeletedPersonRecordIsRestoredByteIdenticalAndReported`.
    /// Keeping bytes rather than fields means a later build of this code cannot
    /// re-encode a record into something its own signature no longer covers.
    private struct Entry: Codable {
        /// `RegistryDirectory.rawValue`. A string, so a directory a later build
        /// adds survives a read here rather than failing the whole decode.
        var directory: String
        var fingerprint: String
        var bytes: Data
    }

    public let fileURL: URL
    /// The fingerprint this memory belongs to.
    public let identity: String
    private let lock = NSLock()
    private var stored: Stored

    /// Loads whatever is at `fileURL` **and belongs to `identity`**, or starts
    /// empty. An unreadable or undecodable file starts empty: this is a memory,
    /// not a source of truth, and an empty memory simply restores nothing.
    public init(fileURL: URL, identity: String = DeviceIdentity.author.fingerprint) {
        self.fileURL = fileURL
        self.identity = identity
        let bytes = try? Data(contentsOf: fileURL)  // adr-0018-ok: this device's own registry memory — derived bookkeeping, never manuscript text
        let decoded = bytes.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        if let decoded, decoded.identity == identity {
            self.stored = decoded
            if Self.prune(&self.stored) { persistLocked() }
            return
        }
        var fresh = Stored()
        fresh.identity = identity
        self.stored = fresh
        if bytes != nil { persistLocked() }
    }

    /// The process-wide memory, beside this device's key material and the
    /// op-log heads.
    public static let shared = RegistryCache(
        fileURL: DeviceState.directory.appendingPathComponent("registry-cache.json"),
        identity: DeviceIdentity.author.fingerprint)

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
        guard let project = stored.projects[Self.projectKey(projectURL)],
              !project.records.isEmpty
        else { return nil }
        return Self.registry(from: project.records)
    }

    /// The exact bytes remembered for one record, if any.
    public func rawBytes(of ref: RecordRef, for projectURL: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return stored.projects[Self.projectKey(projectURL)]?
            .records.first { $0.directory == ref.directory.rawValue
                             && $0.fingerprint == ref.fingerprint }?.bytes
    }

    /// Remember `registry` as what this device has verified for `projectURL`,
    /// replacing whatever it remembered before, and persist before answering.
    ///
    /// Malformed listings are NOT remembered: they are facts about the folder
    /// at one moment, not records, and a memory of them would restore nothing
    /// and mislead everything.
    public func remember(_ registry: Registry, for projectURL: URL) {
        let entries = Self.entries(of: registry)
        lock.lock()
        defer { lock.unlock() }
        var project = stored.projects[Self.projectKey(projectURL)] ?? Project()
        project.root = projectURL.standardizedFileURL.path
        project.records = entries
        stored.projects[Self.projectKey(projectURL)] = project
        persistLocked()
    }

    /// Forget everything about one project — the records, the join and the
    /// claimants. Nothing in production calls it yet; pruning is how entries
    /// normally go.
    public func forget(_ projectURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        stored.projects.removeValue(forKey: Self.projectKey(projectURL))
        persistLocked()
    }

    // MARK: - B1: the root this device joined

    /// The root whose chain first named this device in this project, if one
    /// has.
    public func joinedRoot(for projectURL: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored.projects[Self.projectKey(projectURL)]?.joinedRoot
    }

    /// Every other root that has since named this device here. Listed, never
    /// merged — each is somebody claiming a book this device already belongs to
    /// someone else's copy of.
    public func claimants(for projectURL: URL) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored.projects[Self.projectKey(projectURL)]?.claimants ?? []
    }

    /// Record that `root` names this device in this project, and answer the
    /// root this device is actually on.
    ///
    /// **Write-once (B1).** The first root wins. A later, different root is
    /// appended to `claimants` and the join is unchanged: an admission record
    /// cannot prove which Mac signed it, so a device that switched roots on the
    /// strength of one would be handing its history to whoever wrote last. The
    /// writer is shown the claimant and decides.
    @discardableResult
    public func join(root: String, for projectURL: URL) -> String {
        lock.lock()
        defer { lock.unlock() }
        var project = stored.projects[Self.projectKey(projectURL)] ?? Project()
        project.root = projectURL.standardizedFileURL.path
        defer {
            stored.projects[Self.projectKey(projectURL)] = project
            persistLocked()
        }
        guard let joined = project.joinedRoot else {
            project.joinedRoot = root
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
        var project = stored.projects[Self.projectKey(projectURL)] ?? Project()
        guard project.joinedRoot != root, !project.claimants.contains(root) else {
            return false
        }
        project.root = projectURL.standardizedFileURL.path
        project.claimants.append(root)
        stored.projects[Self.projectKey(projectURL)] = project
        persistLocked()
        return true
    }

    // MARK: - Reconciling the folder against the memory

    /// The folder and this device's memory of it, resolved into one registry.
    ///
    /// - A record this device remembers and the folder no longer has is
    ///   **restored** from the remembered bytes and **reported**. That covers
    ///   both ways a record goes: a file that was deleted, and a file that no
    ///   longer verifies — to the registry those are the same event, the record
    ///   is gone, and `folder.malformed` is what says which happened. The
    ///   malformed listing is carried out untouched: a replacement is not an
    ///   explanation, and Integrity shows both.
    /// - A record the folder holds wins over the remembered one, always. The
    ///   folder's copy has already been verified by `RegistryReader`, and a
    ///   record legitimately changes: a device re-signs its own record when it
    ///   mints an actor key, a root re-signs a person's to revoke them.
    /// - Whatever it settles on is then remembered, so the next reconcile
    ///   starts from what this device last verified rather than from something
    ///   older than the folder.
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
        presenter: NSFilePresenter? = nil
    ) throws -> (registry: Registry, restored: [URL], removedBySomeone: [RecordRef]) {
        guard let cached else {
            remember(folder, for: projectURL)
            return (folder, [], [])
        }

        let present = Set(Self.refs(of: folder))
        var restored: [URL] = []
        var removed: [RecordRef] = []
        var devices = folder.devices
        var people = folder.people
        var claims = folder.claims

        for entry in Self.entries(of: cached) {
            guard let directory = RegistryDirectory(rawValue: entry.directory) else { continue }
            let ref = RecordRef(directory: directory, fingerprint: entry.fingerprint)
            guard !present.contains(ref) else { continue }
            // The bytes this device kept when it verified the record, which
            // are the bytes that were on disk; `cached` is decoded from them.
            let bytes = rawBytes(of: ref, for: projectURL) ?? entry.bytes
            restored.append(try RegistryWriter.restore(
                rawBytes: bytes, to: directory, fingerprint: entry.fingerprint,
                in: projectURL, presenter: presenter))
            removed.append(ref)
            switch directory {
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

        let resolved = Registry(
            devices: devices.sorted { $0.device < $1.device },
            people: people.sorted { $0.person < $1.person },
            claims: claims.sorted { $0.newRoot < $1.newRoot },
            malformed: folder.malformed)
        remember(resolved, for: projectURL)
        return (resolved, restored, removed)
    }

    // MARK: - Records ↔ entries

    /// Every record in a registry, as the bytes that were on disk.
    ///
    /// A record whose canonical bytes cannot be produced is dropped and logged
    /// rather than remembered half-formed — a memory it cannot restore from is
    /// worse than no memory of that record at all.
    private static func entries(of registry: Registry) -> [Entry] {
        var entries: [Entry] = []
        entries.append(contentsOf: registry.devices.compactMap(entry(of:)))
        entries.append(contentsOf: registry.people.compactMap(entry(of:)))
        entries.append(contentsOf: registry.claims.compactMap(entry(of:)))
        return entries
    }

    private static func entry(of record: some RegistryRecordProtocol) -> Entry? {
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
        for entry in entries {
            do {
                switch RegistryDirectory(rawValue: entry.directory) {
                case .devices: devices.append(try decoder.decode(DeviceRecord.self, from: entry.bytes))
                case .people: people.append(try decoder.decode(PersonRecord.self, from: entry.bytes))
                case .claims: claims.append(try decoder.decode(ClaimRecord.self, from: entry.bytes))
                case nil: continue
                }
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
            claims: claims.sorted { $0.newRoot < $1.newRoot })
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
    private func persistLocked() {
        do {
            try DeviceState.ensureDirectory(fileURL.deletingLastPathComponent())
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            registryCacheLog.error("""
                Could not persist the registry cache at \
                \(self.fileURL.path, privacy: .public): \
                \(String(describing: error), privacy: .public).
                """)
        }
    }
}
