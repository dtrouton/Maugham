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

    /// The whole persisted value. One file, two dictionaries, no schema
    /// version: every field is additive and a missing one decodes empty.
    private struct Stored: Codable {
        var heads: [String: String] = [:]
        var verifiedSegments: Set<String> = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            heads = try container.decodeIfPresent([String: String].self, forKey: .heads) ?? [:]
            verifiedSegments = try container.decodeIfPresent(
                Set<String>.self, forKey: .verifiedSegments) ?? []
        }
    }

    public let fileURL: URL
    private let lock = NSLock()
    private var stored: Stored

    /// Loads whatever is at `fileURL`, or starts empty. An unreadable or
    /// undecodable file starts empty rather than throwing: this is a memory,
    /// not a source of truth, and an empty memory is exactly the adopt case
    /// the load path already handles.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let bytes = try? Data(contentsOf: fileURL)  // adr-0018-ok: this device's own chain-head memory — derived bookkeeping, never manuscript text
        self.stored = bytes.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    /// The process-wide memory, beside this device's key material.
    public static let shared = OpLogDeviceState(
        fileURL: DeviceState.directory.appendingPathComponent("op-log-state.json"))

    // MARK: - Heads

    public func head(for fileKey: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored.heads[fileKey]
    }

    /// Remember (or, with `nil`, forget) the head this device last wrote into
    /// the file `fileKey` names, and persist it before answering.
    ///
    /// The persist is inside the lock so two threads cannot interleave a
    /// mutation and a write and leave the file describing neither state.
    public func remember(head: String?, for fileKey: String) {
        lock.lock()
        defer { lock.unlock() }
        if let head {
            stored.heads[fileKey] = head
        } else {
            stored.heads.removeValue(forKey: fileKey)
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
        var directory = standardized.deletingLastPathComponent()
        var root: URL?
        while directory.path != "/" && !directory.path.isEmpty {
            let candidate = directory.appendingPathComponent(".maugham")
            if FileManager.default.fileExists(atPath: candidate.path) {
                root = directory
                break
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        let scope = (root ?? standardized.deletingLastPathComponent()).path
        return "\(hex(SHA256.hash(data: Data(scope.utf8))))/\(standardized.lastPathComponent)"
    }

    private nonisolated static func hex(_ digest: SHA256Digest) -> String {
        Hex.encode(digest)
    }

    // MARK: - Persistence

    /// Call with `lock` held. Atomic, so a crash mid-write leaves the previous
    /// memory rather than a truncated one.
    private func persistLocked() {
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
    public let identity: DeviceIdentity
    public let state: OpLogDeviceState
    public let docId: String
    public let projectURL: URL

    public init(
        identity: DeviceIdentity,
        state: OpLogDeviceState,
        docId: String,
        projectURL: URL
    ) {
        self.identity = identity
        self.state = state
        self.docId = docId
        self.projectURL = projectURL
    }
}
