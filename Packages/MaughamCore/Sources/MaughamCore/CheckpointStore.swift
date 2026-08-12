// Maugham/OpLog/CheckpointStore.swift
import Foundation

/// The result of `CheckpointStore.load()` — RULING-54's checkpoint shape.
///
/// A device file that EXISTS but cannot be read is REPORTED beside the rows
/// that could be read: never silently dropped (an unreadable file used to
/// contribute zero checkpoints with no trace, thinning History/Rewind and
/// *reducing* `ProjectIntegrity` findings), and never a refusal of the whole
/// list — unlike the op log, nothing derives manuscript text from this read,
/// so the readable devices' checkpoints are still true and still useful.
/// The notice-not-refusal split is the inbox's (M8-IN-012, RULING-7).
public struct CheckpointLoad: Equatable, Sendable {
    public struct UnreadableFile: Equatable, Sendable {
        public let name: String
        public let reason: String
        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }
    public let checkpoints: [Checkpoint]
    /// Sorted by filename, so two loads over the same broken state agree.
    public let unreadableFiles: [UnreadableFile]
    public init(checkpoints: [Checkpoint], unreadableFiles: [UnreadableFile]) {
        self.checkpoints = checkpoints
        self.unreadableFiles = unreadableFiles
    }
}

/// Project-wide append-only JSONL of named checkpoints, **partitioned per
/// device** (ADR 0012's pattern, applied here by FM-1). Each device writes only
/// to its own `.maugham/checkpoints.<deviceSlug>.jsonl`; readers glob every
/// sibling — including the legacy unsuffixed `.maugham/checkpoints.jsonl` — and
/// merge.
///
/// **The write target is derived from `cp.device`**, exactly as `OpLogStore`
/// derives it from `op.device`: a checkpoint self-describes the device that
/// created it, which is the file it belongs in, so no caller threads a slug
/// through. The legacy file is a merge source and never a write target
/// (`PartitionedJSONLFile.url` cannot name it).
///
/// The logical log is unchanged: the merged, `checkpointId`-deduped,
/// `checkpointId`-sorted set of every device's rows. `checkpointId` is a ULID,
/// so that order is both chronological and identical on every device regardless
/// of which file each row arrived in — and for a single device it is the append
/// order this store returned before partitioning.
@MainActor
public final class CheckpointStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    /// The `.maugham/`-relative stem of the checkpoint stream. The one place the
    /// name is spelled; `BackupSignature` and the Mac's sidecar classifier match
    /// against it through `PartitionedJSONLFile` rather than restating it.
    public nonisolated static let stemPath = ".maugham/checkpoints"

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    /// Every device's checkpoints, merged. Deduped by `checkpointId` and sorted
    /// by it, so two devices holding the same rows derive the same list.
    ///
    /// RULING-54: a per-device file that exists but cannot be read lands in
    /// `unreadableFiles` — named, with the underlying reason — while every
    /// readable device's rows still load. Absent files still read as empty
    /// (the legitimate no-checkpoints-yet state). Nothing throws: every
    /// failure this read can meet is a per-file one, and per-file failures
    /// are the result's own vocabulary.
    public func load() async -> CheckpointLoad {
        var merged: [Checkpoint] = []
        var unreadable: [CheckpointLoad.UnreadableFile] = []
        for url in Self.fileURLs(in: projectURL) {
            let store = JSONLAppendStore<Checkpoint>(fileURL: url, presenter: presenter)
            do { merged.append(contentsOf: try await store.loadStrict()) }
            catch {
                unreadable.append(.init(
                    name: url.lastPathComponent,
                    reason: error.localizedDescription))
            }
        }
        // checkpointIds are distinct in every reachable case (ULIDs), so sorting
        // on one is already a total order and `sorted`'s instability cannot
        // surface. A same-id pair whose CONTENT diverged would be a corruption
        // signal rather than a merge question — unlike the op log, no derived
        // manuscript text hangs on which row survives, so this deliberately does
        // not carry `OpLogStore.mergeSortedDedup`'s canonical-encoding tiebreak.
        var seen = Set<String>()
        return CheckpointLoad(
            checkpoints: merged
                .sorted { $0.checkpointId < $1.checkpointId }
                .filter { seen.insert($0.checkpointId).inserted },
            unreadableFiles: unreadable.sorted { $0.name < $1.name })
    }

    /// Append to THIS checkpoint's device's file — never to another device's,
    /// and never to the legacy unsuffixed one.
    public func append(_ cp: Checkpoint) async throws {
        let url = Self.fileURL(deviceSlug: DeviceSlug.make(from: cp.device), in: projectURL)
        try await JSONLAppendStore<Checkpoint>(fileURL: url, presenter: presenter).append(cp)
    }

    /// The file a writer on `deviceSlug` appends to. SINGLE SOURCE OF TRUTH for
    /// checkpoint filename construction — the producer-side twin of `fileURLs`.
    public nonisolated static func fileURL(deviceSlug: DeviceSlug, in projectURL: URL) -> URL {
        PartitionedJSONLFile.url(
            stem: (stemPath as NSString).lastPathComponent,
            deviceSlug: deviceSlug,
            in: projectURL.appendingPathComponent(".maugham", isDirectory: true))
    }

    /// Every checkpoint file for the project (legacy + per-device).
    public nonisolated static func fileURLs(in projectURL: URL) -> [URL] {
        PartitionedJSONLFile.urls(
            stem: (stemPath as NSString).lastPathComponent,
            in: projectURL.appendingPathComponent(".maugham", isDirectory: true))
    }
}
