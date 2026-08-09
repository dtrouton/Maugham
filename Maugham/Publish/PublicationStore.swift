import Foundation
import MaughamCore

/// Append-only JSONL of every publication compiled from this project,
/// **partitioned per device** (ADR 0012's pattern, applied here by FM-1 —
/// `.maugham/publications.jsonl` had the same unpartitioned-shared-file shape as
/// `.maugham/checkpoints.jsonl`, and the same whole-file-replace loss). This
/// device writes only to `.maugham/publications.<deviceSlug>.jsonl`; `load()`
/// globs every sibling, including the legacy unsuffixed file, and merges.
///
/// **Ordered by `compiledAt`, not by id.** `publicationID` is a random
/// `pub-<uuid prefix>` rather than a ULID, so unlike `CheckpointStore` it
/// carries no chronology; consumers do rely on chronology (`ListPublications`
/// takes `suffix(limit)` for the most recent, `GetPublication` resolves a
/// non-unique version by first-write-wins). `compiledAt` with the id as a
/// tiebreak is a total order that agrees with single-device append order.
@MainActor
public final class PublicationStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    /// The `.maugham/`-relative stem of the publication stream. The one place
    /// the name is spelled; the sidecar classifier matches against it through
    /// `PartitionedJSONLFile` rather than restating it.
    public nonisolated static let stemPath = ".maugham/publications"

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    public func load() async throws -> [Publication] {
        var merged: [Publication] = []
        for url in Self.fileURLs(in: projectURL) {
            let store = JSONLAppendStore<Publication>(fileURL: url, presenter: presenter)
            merged.append(contentsOf: try await store.load())
        }
        var seen = Set<String>()
        return merged
            .sorted {
                $0.compiledAt == $1.compiledAt
                    ? $0.publicationID < $1.publicationID
                    : $0.compiledAt < $1.compiledAt
            }
            .filter { seen.insert($0.publicationID).inserted }
    }

    /// Append to THIS device's file — never to another device's, and never to
    /// the legacy unsuffixed one.
    public func append(_ pub: Publication) async throws {
        let url = Self.fileURL(
            deviceSlug: DeviceSlug.make(from: MacDeviceID.current), in: projectURL)
        try await JSONLAppendStore<Publication>(fileURL: url, presenter: presenter).append(pub)
    }

    /// The `Publication` a given snapshot was first compiled as. Single
    /// source of truth for the "prior publication" lookup `republish` needs —
    /// both `Republisher.republish` and its caller (`RepublishTool.handle`,
    /// which must know the prior edition's `language` before building the
    /// astSource) resolve through here, so the two can't disagree.
    public func publication(forSnapshotID snapshotID: String) async throws -> Publication? {
        try await load().first(where: { $0.snapshotID == snapshotID })
    }

    /// The file a writer on `deviceSlug` appends to. SINGLE SOURCE OF TRUTH for
    /// publication filename construction — the producer-side twin of `fileURLs`.
    public nonisolated static func fileURL(deviceSlug: DeviceSlug, in projectURL: URL) -> URL {
        PartitionedJSONLFile.url(
            stem: (stemPath as NSString).lastPathComponent,
            deviceSlug: deviceSlug,
            in: projectURL.appendingPathComponent(".maugham", isDirectory: true))
    }

    /// Every publication file for the project (legacy + per-device).
    public nonisolated static func fileURLs(in projectURL: URL) -> [URL] {
        PartitionedJSONLFile.urls(
            stem: (stemPath as NSString).lastPathComponent,
            in: projectURL.appendingPathComponent(".maugham", isDirectory: true))
    }
}
