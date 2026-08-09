// Maugham/OpLog/CheckpointStore.swift
import Foundation

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
    public func load() async throws -> [Checkpoint] {
        var merged: [Checkpoint] = []
        for url in Self.fileURLs(in: projectURL) {
            let store = JSONLAppendStore<Checkpoint>(fileURL: url, presenter: presenter)
            merged.append(contentsOf: try await store.load())
        }
        // checkpointIds are distinct in every reachable case (ULIDs), so sorting
        // on one is already a total order and `sorted`'s instability cannot
        // surface. A same-id pair whose CONTENT diverged would be a corruption
        // signal rather than a merge question — unlike the op log, no derived
        // manuscript text hangs on which row survives, so this deliberately does
        // not carry `OpLogStore.mergeSortedDedup`'s canonical-encoding tiebreak.
        var seen = Set<String>()
        return merged
            .sorted { $0.checkpointId < $1.checkpointId }
            .filter { seen.insert($0.checkpointId).inserted }
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
