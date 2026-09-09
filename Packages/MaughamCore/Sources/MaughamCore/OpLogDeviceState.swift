import CryptoKit
import Foundation
import os

/// Diagnostic channel for the one failure this type can suffer quietly: the
/// state file could not be persisted, so a crash after the next append will
/// look like the adopt case rather than a known head.
private let deviceStateLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.core",
    category: "OpLogDeviceState")

/// What this device remembers about the op-log files it has written: the chain
/// head it last wrote into each file, and the sealed segments it has already
/// verified.
///
/// **Why a remembered head at all.** The chain alone catches a line that names
/// the wrong `prev`. It does not catch a line that names the RIGHT one — an
/// agent that reads the file, computes the hash of the last line and appends a
/// correctly-chained op of its own is indistinguishable from Maugham by the
/// chain rules. The head this device remembers is the extra fact only this
/// device has: anything after it arrived from somewhere else, however well it
/// chains (`OpLogChain.BreakReason.afterRememberedHead`).
///
/// **Why it is keyed by project-path hash rather than by absolute path.** A
/// project that moves gets a new key, so the device forgets its heads for that
/// project and ADOPTS whatever the file's head is — the same fall-back a first
/// run after this upgrade takes. Forgetting is the safe direction: the writer's
/// own history is never quarantined because they dragged a folder.
///
/// **Isolation.** Deliberately nonisolated — the synchronous read path
/// (`OpLogStore.loadSyncMerged`) has to ask it a question without an actor hop,
/// and the write path is on the MainActor. An `NSLock` around a plain value is
/// what makes both safe, which is what `@unchecked Sendable` is asserting.
public final class OpLogDeviceState: @unchecked Sendable {

    /// The whole persisted value. One file, three dictionaries and the
    /// fingerprint of the device they belong to; no schema version, because
    /// every field is additive and a missing one decodes empty.
    private struct Stored: Codable {
        /// Whose memory this is (`DeviceIdentity.fingerprint`). A file whose
        /// identity is not the one it is opened for is not this device's word
        /// about anything — see `init(fileURL:identity:)`.
        var identity: String = ""
        var heads: [String: String] = [:]
        /// The head each file had BEFORE the current one. The crash window's
        /// only signature: `chainedAppend` persists a head before writing the
        /// line that hashes to it, so a crash between the two leaves a
        /// remembered head no line carries and a file whose own head is this.
        var previousHeads: [String: String] = [:]
        var verifiedSegments: Set<String> = []
        /// The project each head's hash was taken over: the hash half of a
        /// `fileKey` to the root's path. It is what makes an entry ATTRIBUTABLE,
        /// and so prunable — the key alone is a hash and names nothing that can
        /// be looked for on disk. Absent for every entry written before this
        /// field, which is why a head with no record here is kept.
        var roots: [String: String] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            identity = try container.decodeIfPresent(String.self, forKey: .identity) ?? ""
            heads = try container.decodeIfPresent([String: String].self, forKey: .heads) ?? [:]
            previousHeads = try container.decodeIfPresent(
                [String: String].self, forKey: .previousHeads) ?? [:]
            verifiedSegments = try container.decodeIfPresent(
                Set<String>.self, forKey: .verifiedSegments) ?? []
            roots = try container.decodeIfPresent([String: String].self, forKey: .roots) ?? [:]
        }
    }

    public let fileURL: URL
    /// The fingerprint this memory belongs to.
    public let identity: String
    private let lock = NSLock()
    private var stored: Stored
    private var persists = 0
    /// How many times the file has been rewritten. The performance step pins it
    /// (`OpLogDeviceStateTests.test_aBatchPersistsOnce`): one write per
    /// `remember`, one per `markVerified`, and an append is one `remember` for
    /// the whole batch. Read under the lock, like everything else here.
    internal var persistCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return persists
    }

    /// Loads whatever is at `fileURL` **and belongs to `identity`**, or starts
    /// empty. An unreadable or undecodable file starts empty rather than
    /// throwing: this is a memory, not a source of truth, and an empty memory
    /// is exactly the adopt case the load path already handles.
    ///
    /// **A file belonging to another identity starts empty too, and is
    /// rewritten.** The heads are keyed by project-path hash and filename; the
    /// DEVICE is not in the key. Application Support is what Migration
    /// Assistant copies, and the enclave blob it copies is not loadable on the
    /// new Mac — so `DeviceIdentity.load` mints a new identity while every
    /// remembered head for the OLD slug's files survives. With the old Mac
    /// still appending to `<doc>.<oldSlug>.jsonl`, the migrated Mac would find
    /// its stale head mid-file and quarantine everything after it: the writer's
    /// own synced ops, held back under "written by something that is not
    /// Maugham". No migration (tripwire 11) — a state file predating this field
    /// reads as a mismatch, which is the adopt case.
    public init(fileURL: URL, identity: String = DeviceIdentity.author.fingerprint) {
        self.fileURL = fileURL
        self.identity = identity
        let bytes = try? Data(contentsOf: fileURL)  // adr-0018-ok: this device's own chain-head memory — derived bookkeeping, never manuscript text
        let decoded = bytes.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        if let decoded, decoded.identity == identity {
            self.stored = decoded
            if Self.prune(&self.stored) { persistLocked() }
            return
        }
        var fresh = Stored()
        fresh.identity = identity
        self.stored = fresh
        // Rewritten, not merely ignored: a memory left on disk under a name
        // this device does not answer to would come back the moment anything
        // else opened it.
        if bytes != nil { persistLocked() }
    }

    /// The process-wide memory, beside this device's key material.
    public static let shared = OpLogDeviceState(
        fileURL: DeviceState.directory.appendingPathComponent("op-log-state.json"),
        identity: DeviceIdentity.author.fingerprint)

    // MARK: - Heads

    public func head(for fileKey: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored.heads[fileKey]
    }

    /// The head this file had before the one `head(for:)` answers. Nil until a
    /// second head has been remembered for it.
    public func previousHead(for fileKey: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored.previousHeads[fileKey]
    }

    /// Remember (or, with `nil`, forget) the head this device last wrote into
    /// the file `fileKey` names, and persist it before answering. Remembering
    /// SHIFTS the head it replaces into `previousHead`, which is the one
    /// signature the crash window has (`OpLogChain.resolveAbsentHead`).
    /// Forgetting forgets both — a file this device has no head for has no
    /// predecessor either.
    ///
    /// The persist is inside the lock so two threads cannot interleave a
    /// mutation and a write and leave the file describing neither state.
    /// `root` is the project the key's hash was taken over, recorded so the
    /// entry can be pruned when that project is gone. Nil records nothing and
    /// leaves any existing record alone: a head nothing can attribute is a head
    /// nothing may delete. Forgetting (`head == nil`) keeps the record too —
    /// the project's other op-log files are still keyed on the same hash.
    public func remember(head: String?, for fileKey: String, root: URL? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let root {
            stored.roots[Self.scopeHash(ofKey: fileKey)] = root.standardizedFileURL.path
        }
        if let head {
            if let outgoing = stored.heads[fileKey], outgoing != head {
                stored.previousHeads[fileKey] = outgoing
            }
            stored.heads[fileKey] = head
        } else {
            stored.heads.removeValue(forKey: fileKey)
            stored.previousHeads.removeValue(forKey: fileKey)
        }
        persistLocked()
    }

    // MARK: - Verified segments

    public func isVerified(segmentDigest: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored.verifiedSegments.contains(segmentDigest)
    }

    public func markVerified(segmentDigest: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.verifiedSegments.insert(segmentDigest)
        persistLocked()
    }

    // MARK: - The key

    /// `<SHA-256 hex of the project root path>/<filename>`.
    ///
    /// The project root is the nearest ancestor directory whose child is
    /// `.maugham`. A file with no such ancestor — a bare temp file in a test,
    /// or an op log outside a project — keys on its own parent directory
    /// instead, so two files in one directory still get distinct keys and two
    /// directories never collide.
    public nonisolated static func fileKey(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        let scope = (projectRoot(of: url) ?? standardized.deletingLastPathComponent()).path
        return "\(hex(SHA256.hash(data: Data(scope.utf8))))/\(standardized.lastPathComponent)"
    }

    /// The project `fileKey` scopes this file to: the nearest ancestor
    /// directory with a `.maugham` child, or nil for a file outside a project.
    ///
    /// Exists as a function of its own because the load path has a URL and no
    /// project handle, and the root it records beside a head must be the very
    /// directory the key's hash was taken over — two spellings of "the project
    /// this file is in" would prune entries the key does not name.
    nonisolated static func projectRoot(of url: URL) -> URL? {
        var directory = url.standardizedFileURL.deletingLastPathComponent()
        while directory.path != "/" && !directory.path.isEmpty {
            let candidate = directory.appendingPathComponent(".maugham")
            if FileManager.default.fileExists(atPath: candidate.path) { return directory }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    private nonisolated static func hex(_ digest: SHA256Digest) -> String {
        Hex.encode(digest)
    }

    // MARK: - Pruning

    /// The hash half of a `fileKey` — everything before the first `/`. One
    /// project, one hash, however many op-log files it holds.
    private nonisolated static func scopeHash(ofKey fileKey: String) -> String {
        String(fileKey.prefix { $0 != "/" })
    }

    /// Drops every head whose recorded project is no longer on disk, and
    /// answers whether anything went.
    ///
    /// Without it the memory only grows: a head per op-log file per project
    /// ever opened, in one file read on every load. The test is the narrowest
    /// one that answers the question asked — is the recorded root still
    /// there — and NOT whether it still has a `.maugham` child. The wider test
    /// reads every condition that makes one directory read fail (a folder
    /// outside an active security scope on iOS, a permissions or ownership
    /// change on the Mac) as a deleted project, and drops every head for it
    /// silently: the adopt path logs nothing, so the loss would never be
    /// reported. A root that is present but has lost its `.maugham` has no
    /// lines for those heads to protect, so keeping them costs nothing.
    ///
    /// An entry pruned by mistake is still the ADOPT case, the same fall-back a
    /// moved project already takes — the safe direction — but the narrower
    /// predicate reaches for it far less often.
    ///
    /// `verifiedSegments` is untouched — a segment digest is a hash of bytes
    /// and belongs to no project — and so is any head whose hash has no
    /// recorded root, which is every head written before this field existed.
    private nonisolated static func prune(_ stored: inout Stored) -> Bool {
        let dead = stored.roots.filter { _, path in
            !FileManager.default.fileExists(atPath: path)
        }
        guard !dead.isEmpty else { return false }
        let hashes = Set(dead.keys)
        stored.heads = stored.heads.filter { !hashes.contains(scopeHash(ofKey: $0.key)) }
        stored.previousHeads = stored.previousHeads.filter {
            !hashes.contains(scopeHash(ofKey: $0.key))
        }
        for hash in hashes { stored.roots.removeValue(forKey: hash) }
        return true
    }

    // MARK: - Persistence

    /// Call with `lock` held. Atomic, so a crash mid-write leaves the previous
    /// memory rather than a truncated one.
    private func persistLocked() {
        persists += 1
        do {
            try DeviceState.ensureDirectory(fileURL.deletingLastPathComponent())
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            deviceStateLog.error("""
                Could not persist the op-log device state at \
                \(self.fileURL.path, privacy: .public): \
                \(String(describing: error), privacy: .public).
                """)
        }
    }
}

/// What a chained append needs to know: who is writing, what it remembers,
/// and where to file anything it finds that it did not write.
///
/// A value, not a service — `JSONLAppendStore` holds one or holds nil, and
/// nil is the unchained store every non-op-log caller still gets.
public struct ChainPolicy: Sendable {
    /// The key this store SIGNS with: one actor, never a set. A seal names one
    /// device and one moment, and a line is written by one writer.
    public let identity: DeviceIdentity
    /// The keys this store TRUSTS on read: every actor on this device
    /// (`LocalIdentities.fingerprints`). Signing and trusting are different
    /// questions and P1b is where they stop having the same answer — the
    /// assistant's seal over the assistant's file is this device's own word,
    /// and a trust set of one fingerprint would file it as another device's
    /// unsigned history.
    ///
    /// Defaulted to the signer alone, so every caller that has one identity and
    /// means it (the inbox, the phone's annotation writer) keeps P1's shape.
    public let trustedFingerprints: Set<String>
    public let state: OpLogDeviceState
    public let docId: String
    public let projectURL: URL

    public init(
        identity: DeviceIdentity,
        state: OpLogDeviceState,
        docId: String,
        projectURL: URL,
        trustedFingerprints: Set<String>? = nil
    ) {
        self.identity = identity
        self.trustedFingerprints = trustedFingerprints ?? [identity.fingerprint]
        self.state = state
        self.docId = docId
        self.projectURL = projectURL
    }
}
