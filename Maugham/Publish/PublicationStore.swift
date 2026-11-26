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

    /// The catalogue's read, run detached by `load` — `catalogue` in
    /// production; a test hands in one that also notes where it ran.
    typealias Read = @Sendable (_ projectURL: URL, _ presenter: NSFilePresenter?) throws -> [Publication]
    private let read: Read

    public convenience init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.init(projectURL: projectURL, presenter: presenter,
                  read: { try PublicationStore.catalogue(in: $0, presenter: $1) })
    }

    init(projectURL: URL, presenter: NSFilePresenter?, read: @escaping Read) {
        self.projectURL = projectURL
        self.presenter = presenter
        self.read = read
    }

    /// RULING-54: an unreadable-yet-present publication device file THROWS,
    /// naming the file. Unlike checkpoints (a notice) this is a REFUSAL,
    /// because every substantive consumer of this list is write-adjacent: the
    /// compile's occupied-destination refusal, republish's prior-edition
    /// lookup, and the starter's version high-water mark each read it before
    /// writing — a silently shorter catalog arms a version collision or an
    /// overwrite of a publication the writer already shipped.
    public enum ReadError: Error, LocalizedError {
        case unreadableFile(name: String, underlying: String)
        public var errorDescription: String? {
            switch self {
            case .unreadableFile(let name, let underlying):
                return "The publications catalog “\(name)” exists but can't be read (\(underlying)). "
                     + "Compiling without it could overwrite or collide with an edition you already "
                     + "published — check the file's permissions or wait for iCloud to finish "
                     + "syncing, then try again."
            }
        }
    }

    /// **Read off the main actor** (shell p5a closing round B): the folder
    /// listing and every device file's read run detached, so a slow folder —
    /// a macOS consent prompt, an iCloud folder not yet downloaded — never
    /// holds a window's first frame. The result is the caller's, on its actor.
    public func load() async throws -> [Publication] {
        let projectURL = self.projectURL
        let presenter = self.presenter
        let read = self.read
        return try await Task.detached(priority: .userInitiated) {
            try read(projectURL, presenter)
        }.value
    }

    /// The catalogue, read: every device file, merged. Never call it on the
    /// main actor (`load` runs it detached).
    nonisolated static func catalogue(in projectURL: URL,
                                      presenter: NSFilePresenter?) throws -> [Publication] {
        var merged: [Publication] = []
        for url in Self.fileURLs(in: projectURL) {
            do {
                merged.append(contentsOf: try JSONLAppendStore<Publication>.loadStrictPlain(
                    fileURL: url, presenter: presenter))
            }
            catch {
                throw ReadError.unreadableFile(
                    name: url.lastPathComponent,
                    underlying: error.localizedDescription)
            }
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
            deviceSlug: DeviceIdentity.author.slug, in: projectURL)
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
