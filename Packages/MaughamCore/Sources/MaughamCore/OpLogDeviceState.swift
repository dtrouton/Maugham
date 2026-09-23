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
        /// **Where ANOTHER device's streams stood** (P3a Task 9, spec §4.7).
        /// Keyed `<project-root hash>/<stream key>` — the same hash half the
        /// heads use, so one `prune` pass covers both.
        var foreignStreams: [String: ForeignStreamMemory] = [:]
        /// Streams this device has found SHORTER than it remembered them,
        /// keyed the same way. One entry per stream: a stream truncated twice
        /// is one standing fact, not two rows.
        var foreignTruncations: [String: StreamTruncation] = [:]
        /// **Losses the writer has been shown and put down** (P3b Task 6),
        /// keyed the same way again, with the day they put it down.
        ///
        /// It is device-local and it never leaves this machine: a mark is
        /// computed from the shared bytes alone, so what this Mac has been
        /// told cannot be allowed to change what a mark says — only whether
        /// the act that would write one is refused.
        var acknowledgedLosses: [String: Date] = [:]

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
            // Optional, like every field above: a state file written before
            // P3a decodes with these empty, which is the never-seen-anybody
            // case and is exactly right. A synthesized `KeyedDecodingContainer`
            // ignores keys it has no case for, so an OLDER build reading a file
            // this one wrote drops these two and keeps everything else.
            foreignStreams = try container.decodeIfPresent(
                [String: ForeignStreamMemory].self, forKey: .foreignStreams) ?? [:]
            foreignTruncations = try container.decodeIfPresent(
                [String: StreamTruncation].self, forKey: .foreignTruncations) ?? [:]
            acknowledgedLosses = try container.decodeIfPresent(
                [String: Date].self, forKey: .acknowledgedLosses) ?? [:]
        }
    }

    // MARK: - What another device's stream looked like

    /// **What this device remembers about one OTHER device's stream** (P3a
    /// Task 9, spec §4.7).
    ///
    /// Keyed by STREAM and never by filename. A rotation copies the live tail
    /// into a `.mzseg` and deletes it, so the line this device last settled
    /// MOVES from one filename to another while staying in the same stream —
    /// and a memory keyed on the filename would read that ordinary maintenance
    /// as the file having been shortened.
    public struct ForeignStreamMemory: Codable, Equatable, Sendable {
        /// The slug that stream's files are named for. Carried rather than
        /// re-derived from the key, so asking *which streams are this person's*
        /// is a lookup and not a second parse of a filename
        /// (`PermitMark.stream(of:)` is the one parse and it takes a URL).
        public let deviceSlug: String
        /// The hash of the last line of the live TAIL that this device saw the
        /// chain verify. **Nil is a real answer** — a stream with no tail, an
        /// empty one, or one that has just rotated everything away — and it
        /// means *nothing to check*, never *nothing was ever there*.
        public let head: String?
        /// The digest of every sealed segment of this stream this device has
        /// taken in WHOLE — the same value `PermitMark.StreamMark.segments`
        /// is built from, so a mark and this memory cannot disagree about what
        /// the stream is made of.
        ///
        /// Two jobs. It is the **rotation tolerance**: a tail that no longer
        /// holds the remembered line while the stream has taken in a digest
        /// this device had not seen has rotated, which is maintenance and not a
        /// truncation. And a digest here that no segment of the stream carries
        /// any more is a **segment that went missing**, which the count this
        /// replaced could not see at all.
        public let segmentDigests: Set<String>

        public init(deviceSlug: String, head: String?, segmentDigests: Set<String>) {
            self.deviceSlug = deviceSlug
            self.head = head
            self.segmentDigests = segmentDigests
        }

        /// **An entry written before the digests decodes, and reads as *no
        /// digests known*** (tripwire 11: no migration, just tolerate). Such an
        /// entry carries a `segments` COUNT this build has no property for, so
        /// the synthesized decoder would simply ignore it — this one is written
        /// out because `segmentDigests` has to be optional, and an absent set
        /// is the honest answer: the first load after the upgrade learns the
        /// digests, and until it does the stream is watched by its head alone.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceSlug = try container.decode(String.self, forKey: .deviceSlug)
            head = try container.decodeIfPresent(String.self, forKey: .head)
            segmentDigests = try container.decodeIfPresent(
                Set<String>.self, forKey: .segmentDigests) ?? []
        }
    }

    /// **A foreign stream found shorter than this device remembered it.**
    ///
    /// Nothing is refused over one and no line is set aside: the lines that
    /// remain are good (spec §4.7). This is the fact P3b dates under History's
    /// Project heading — dated when it is NOTICED, because dating it when a
    /// pane opens would stamp last week's loss with this morning.
    public struct StreamTruncation: Codable, Equatable, Sendable {
        /// **What went missing**, because the two are different losses and a
        /// writer can act on knowing which. An entry written before this field
        /// reads `.line`, which is the only kind that build could record.
        public enum Loss: String, Codable, Equatable, Sendable {
            /// The last line this device settled in the live tail is nowhere in
            /// the stream any more.
            case line
            /// A whole sealed segment this device had taken in is gone. Every
            /// line it held that is still applied stays applied; what is lost
            /// is the history's own copy of them.
            case segment
        }

        public let streamKey: String
        public let deviceSlug: String
        public let loss: Loss
        /// The line hash (`.line`) or the segment digest (`.segment`) that is
        /// no longer anywhere in the stream.
        public let lost: String
        public let noticedAt: Date

        public init(
            streamKey: String, deviceSlug: String,
            loss: Loss = .line, lost: String, noticedAt: Date
        ) {
            self.streamKey = streamKey
            self.deviceSlug = deviceSlug
            self.loss = loss
            self.lost = lost
            self.noticedAt = noticedAt
        }

        /// Tolerates an entry written before `loss`/`lost` existed — its hash
        /// lived under `lostHead` and its kind could only be `.line`.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            streamKey = try container.decode(String.self, forKey: .streamKey)
            deviceSlug = try container.decode(String.self, forKey: .deviceSlug)
            loss = try container.decodeIfPresent(Loss.self, forKey: .loss) ?? .line
            lost = try container.decodeIfPresent(String.self, forKey: .lost) ?? ""
            noticedAt = try container.decode(Date.self, forKey: .noticedAt)
        }
    }

    /// One stream's new memory and, where there is one, the finding that came
    /// with it. A whole load's worth is settled in ONE call, so a document
    /// spread over six foreign files costs one file write rather than six.
    public struct ForeignStreamUpdate: Sendable {
        public let streamKey: String
        public let root: URL
        /// **Nil is *keep what is remembered***, which is how a stream that
        /// answered nothing this load keeps the position it once answered with
        /// — the position whose absence IS the finding (fix round 1).
        public let memory: ForeignStreamMemory?
        public let truncation: StreamTruncation?
        /// The stream found everything it was remembered by, so a standing
        /// finding about it is over: the file came back, or iCloud finished.
        public let clearsTruncation: Bool

        public init(
            streamKey: String, root: URL,
            memory: ForeignStreamMemory?, truncation: StreamTruncation?,
            clearsTruncation: Bool = false
        ) {
            self.streamKey = streamKey
            self.root = root
            self.memory = memory
            self.truncation = truncation
            self.clearsTruncation = clearsTruncation
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

    // MARK: - Foreign streams (P3a Task 9)

    /// What this device remembers about `streamKey` in this project, or nil
    /// where it has never settled a line of it.
    public func foreignStream(_ streamKey: String, inRoot root: URL) -> ForeignStreamMemory? {
        lock.lock()
        defer { lock.unlock() }
        return stored.foreignStreams[Self.foreignKey(streamKey, root: root)]
    }

    /// **Settle a whole load's foreign observations at once.**
    ///
    /// One lock and at most one file write, for the reason `remember` batches a
    /// chained append: a diagnosed load of a chapter with four other devices in
    /// it must not become four rewrites of this file. And a write is skipped
    /// entirely where nothing moved — the steady state, since a foreign stream
    /// that has not changed answers the same memory it already holds.
    public func settleForeign(_ updates: [ForeignStreamUpdate]) {
        guard !updates.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for update in updates {
            let key = Self.foreignKey(update.streamKey, root: update.root)
            let hash = Self.scopeHash(ofKey: key)
            let path = update.root.standardizedFileURL.path
            if stored.roots[hash] != path {
                stored.roots[hash] = path
                changed = true
            }
            if let memory = update.memory, stored.foreignStreams[key] != memory {
                stored.foreignStreams[key] = memory
                changed = true
            }
            if let truncation = update.truncation {
                // **The same loss is the same finding**, keeping the day it
                // was noticed. A stream that stays short is re-detected on
                // every load — it has nothing left to move its memory on to —
                // and re-dating it would put this morning on last week's loss
                // and make *once* mean *every open*.
                let standing = stored.foreignTruncations[key]
                if standing?.loss != truncation.loss || standing?.lost != truncation.lost {
                    stored.foreignTruncations[key] = truncation
                    changed = true
                    // **A DIFFERENT loss is a different fact** (P3b Task 6),
                    // so the writer's acknowledgement of the last one does not
                    // cover it: putting down one loss must never make this Mac
                    // blind to the next.
                    if stored.acknowledgedLosses.removeValue(forKey: key) != nil {
                        changed = true
                    }
                }
            } else if update.clearsTruncation {
                // What came back is not missing. A finding is a fact that holds
                // now, so a project whose evicted chapter iCloud has restored
                // stops being unhealthy rather than being unhealthy for ever.
                if stored.foreignTruncations.removeValue(forKey: key) != nil {
                    changed = true
                }
                // And the acknowledgement goes with it: the stream is whole
                // again, so it is expected again (P3b Task 6, both
                // directions). This is also the clause that covers a stream
                // whose files were wholly ABSENT — a load says nothing about
                // one of those, so it records no truncation, but the load that
                // finds it back settles it here.
                if stored.acknowledgedLosses.removeValue(forKey: key) != nil {
                    changed = true
                }
            }
        }
        if changed { persistLocked() }
    }

    /// Every stream this device remembers in `root` that one of `slugs` wrote.
    ///
    /// This is `expectedStreams`' source (spec §3.3's marks, P3a Task 7's
    /// `ReadError.streamMissingFromSweep`): a stream a mark does not NAME is
    /// judged wholly new, so a sweep that cannot see a stream this device has
    /// applied must refuse rather than draw the line at the beginning of it.
    /// A stream this device has never seen is legitimately absent — honest late
    /// sync — and is deliberately not here.
    ///
    /// **It answers the MEMORIES, not the names** (final fix wave, W2). A name
    /// is enough to catch a stream that has vanished and nothing else, and the
    /// case that costs words is the one where the name is there and the
    /// CONTENTS are short: a rotation whose tail deletion syncs ahead of its
    /// segment. The sweep asks `ForeignStreamWatch.loss` of these, which is the
    /// same predicate the load settles by.
    /// **`slugs` nil is *every foreign stream this device remembers here***
    /// (P3b Task 2), which is what the unsigned snapshot's sweep needs: that
    /// sweep starts from no person at all — its whole subject is streams
    /// nobody's record names — so it cannot narrow by slug and must expect
    /// everything this device has applied from anybody. An empty SET stays
    /// what it was, *nobody, so nothing is expected*.
    public func foreignStreams(
        inRoot root: URL, writtenBy slugs: Set<String>?
    ) -> [String: ForeignStreamMemory] {
        if let slugs, slugs.isEmpty { return [:] }
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(Self.scopeHash(ofRoot: root))/"
        var out: [String: ForeignStreamMemory] = [:]
        for (key, memory) in stored.foreignStreams
        where key.hasPrefix(prefix) && (slugs?.contains(memory.deviceSlug) ?? true) {
            out[String(key.dropFirst(prefix.count))] = memory
        }
        return out
    }

    /// **What a sweep may still be refused over** — everything remembered,
    /// LESS every loss the writer has been shown and put down (P3b Task 6).
    ///
    /// This is the escape, and it is one function rather than a rule each
    /// caller remembers: `DocumentStore.expectedStreams` and
    /// `everyExpectedStream` are the only two things that build an `expecting:`
    /// in production, and both come through here, so a person's position sweep
    /// and the unsigned snapshot's take the same way out.
    ///
    /// **Why there is a way out at all.** A stream this Mac remembers and
    /// cannot find refuses every marking verb, because a mark that omits a
    /// stream judges the whole of it new — right while the file might come
    /// back, and wrong for ever once it cannot. Without this, one permanently
    /// lost file stops a book from ever revoking, re-admitting or narrowing
    /// anybody again, naming a filename the writer can do nothing about.
    ///
    /// **The other direction is the default.** A loss nobody has been shown
    /// refuses exactly as it did; an acknowledgement is cleared the moment the
    /// bytes come back or the loss changes; and it never enters a mark — the
    /// positions are read from the shared bytes either way, so a fresh Mac and
    /// this one compute the same mark for every stream both can read.
    ///
    /// *The cost, which the confirmation states*: history that returns AFTER a
    /// verb was pressed over an acknowledged loss is outside that verb's mark,
    /// and so is judged as written after that change.
    public func expectedStreams(
        inRoot root: URL, writtenBy slugs: Set<String>?
    ) -> [String: ForeignStreamMemory] {
        let remembered = foreignStreams(inRoot: root, writtenBy: slugs)
        guard !remembered.isEmpty else { return remembered }
        let put = acknowledgedLosses(inRoot: root)
        guard !put.isEmpty else { return remembered }
        return remembered.filter { put[$0.key] == nil }
    }

    /// Every truncation this device has noticed in `root`, oldest first.
    public func truncations(inRoot root: URL) -> [StreamTruncation] {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(Self.scopeHash(ofRoot: root))/"
        return stored.foreignTruncations
            .filter { $0.key.hasPrefix(prefix) }
            .values
            .sorted { ($0.noticedAt, $0.streamKey) < ($1.noticedAt, $1.streamKey) }
    }

    /// **The writer has been shown this loss and has put it down** (P3b Task
    /// 6). Idempotent, and dated with the day they pressed.
    ///
    /// It records nothing about the BOOK — no event, no record, nothing any
    /// other device will ever read. What it changes is what this Mac is
    /// willing to be refused over.
    public func acknowledgeLoss(
        _ streamKey: String, inRoot root: URL, at when: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.foreignKey(streamKey, root: root)
        let hash = Self.scopeHash(ofKey: key)
        let path = root.standardizedFileURL.path
        var changed = false
        if stored.roots[hash] != path {
            stored.roots[hash] = path
            changed = true
        }
        if stored.acknowledgedLosses[key] == nil {
            stored.acknowledgedLosses[key] = when
            changed = true
        }
        if changed { persistLocked() }
    }

    /// Every loss put down in `root`, by stream key.
    public func acknowledgedLosses(inRoot root: URL) -> [String: Date] {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "\(Self.scopeHash(ofRoot: root))/"
        var out: [String: Date] = [:]
        for (key, when) in stored.acknowledgedLosses where key.hasPrefix(prefix) {
            out[String(key.dropFirst(prefix.count))] = when
        }
        return out
    }

    /// `<project-root hash>/<stream key>` — the heads' key shape with a stream
    /// where a filename goes, so `prune`'s one pass covers both.
    private nonisolated static func foreignKey(_ streamKey: String, root: URL) -> String {
        "\(scopeHash(ofRoot: root))/\(streamKey)"
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
        let scope = projectRoot(of: url) ?? standardized.deletingLastPathComponent()
        return "\(scopeHash(ofRoot: scope))/\(standardized.lastPathComponent)"
    }

    /// The hash half of a `fileKey`, taken over a project root directly.
    ///
    /// Exists so that a device-local memory keyed by PROJECT rather than by
    /// file (`RegistryCache`) can key on the very same hash instead of taking a
    /// second hash of the same path. Two spellings of "which project this is"
    /// is how one memory prunes an entry another memory still needs.
    nonisolated static func scopeHash(ofRoot root: URL) -> String {
        hex(SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)))
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

    /// D3′ in one predicate, so every device-local memory prunes on the same
    /// two clauses: **a recorded root is dead only when the root is absent AND
    /// its parent is present.** A deleted project leaves its enclosing folder
    /// behind; an unmounted volume takes its whole path with it. Without the
    /// second clause the two are indistinguishable, and a volume that happens
    /// to be absent at launch costs a project a memory nothing ever touched.
    nonisolated static func rootIsGone(atPath path: String) -> Bool {
        guard !FileManager.default.fileExists(atPath: path) else { return false }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return FileManager.default.fileExists(atPath: parent)
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
    /// **D3′ (Denver's ruling): a root is dead only when the root is absent
    /// AND its parent is present.** A deleted project leaves its parent
    /// directory behind — the enclosing folder is still there, only the
    /// project inside it is gone. An unmounted volume takes its whole path
    /// with it: the parent is gone too, not just the leaf. Without the second
    /// clause an unmounted volume reads exactly like a deleted project and
    /// loses its heads on every launch it happens to be absent for, silently
    /// giving up one launch's worth of tamper detection for a project that was
    /// never touched at all.
    ///
    /// An entry pruned by mistake is still the ADOPT case, the same fall-back a
    /// moved project already takes — the safe direction — but the narrower
    /// predicate reaches for it far less often.
    ///
    /// `verifiedSegments` is untouched — a segment digest is a hash of bytes
    /// and belongs to no project — and so is any head whose hash has no
    /// recorded root, which is every head written before this field existed.
    private nonisolated static func prune(_ stored: inout Stored) -> Bool {
        let dead = stored.roots.filter { _, path in rootIsGone(atPath: path) }
        guard !dead.isEmpty else { return false }
        let hashes = Set(dead.keys)
        stored.heads = stored.heads.filter { !hashes.contains(scopeHash(ofKey: $0.key)) }
        stored.previousHeads = stored.previousHeads.filter {
            !hashes.contains(scopeHash(ofKey: $0.key))
        }
        // The foreign memory prunes on the same clause from its first day
        // (P3a Task 9): it is keyed by the same project hash, and a memory
        // whose project is gone is a memory of nothing. `verifiedSegments`
        // stays untouched for its own reason — a digest is a hash of bytes and
        // belongs to no project.
        stored.foreignStreams = stored.foreignStreams.filter {
            !hashes.contains(scopeHash(ofKey: $0.key))
        }
        stored.foreignTruncations = stored.foreignTruncations.filter {
            !hashes.contains(scopeHash(ofKey: $0.key))
        }
        // An acknowledgement is a fact about one book's history; a book that
        // is gone takes it with it (P3b Task 6).
        stored.acknowledgedLosses = stored.acknowledgedLosses.filter {
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
    /// What a key that sealed something in this store's file is to this
    /// device — the `TrustTable`'s own question, as a closure, so a store can
    /// be built without one and a caller that has one passes it straight in.
    ///
    /// **Its two readers ask different things of it.** The chained WRITE asks
    /// only whether a key is `.mine`: this file has one writer by ADR 0012, so
    /// anything else in it is a quarantine whatever the registry says. The
    /// chained READ (`loadVerifiedStrict`) takes the full verdict, which is
    /// what lets the inbox hold a stranger's entries rather than applying them.
    ///
    /// Defaulted to *the signer is this device and nobody else is judged* —
    /// P1's shape exactly — so every caller that has one identity and means it
    /// keeps what it had.
    public let trust: @Sendable (String) -> TrustVerdict
    public let state: OpLogDeviceState
    public let docId: String
    public let projectURL: URL

    public init(
        identity: DeviceIdentity,
        state: OpLogDeviceState,
        docId: String,
        projectURL: URL,
        trust: (@Sendable (String) -> TrustVerdict)? = nil
    ) {
        let signer = identity.fingerprint
        self.identity = identity
        self.trust = trust ?? { $0 == signer ? .mine : .noChain }
        self.state = state
        self.docId = docId
        self.projectURL = projectURL
    }
}
