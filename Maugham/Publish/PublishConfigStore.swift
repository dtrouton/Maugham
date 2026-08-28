import Foundation

/// Read/write `.maugham/publish/config.json`. Pretty-printed, snake_case keys.
/// Atomic writes (write to temp + rename).
public actor PublishConfigStore {
    public let projectURL: URL

    public init(projectURL: URL) {
        self.projectURL = projectURL
    }

    public var fileURL: URL { Self.fileURL(in: projectURL) }

    /// The config's path, spelled once. `nonisolated` and static because a
    /// caller outside the actor may legitimately need the LOCATION without
    /// reading the file — the department desk reads its modification date on a
    /// body path to know when its imprint picker is stale — and a second
    /// spelling of `.maugham/publish/config.json` is a path that can drift.
    public nonisolated static func fileURL(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/publish/config.json")
    }

    public func load() throws -> PublishConfig? { try Self.read(in: projectURL) }

    /// **The same read, without the actor hop.**
    ///
    /// One implementation with two doors: `load()` above is the ordinary one,
    /// and this is for a caller already pinned to another executor for whom a
    /// hop is not free. The department desk is that caller — its `derive()` is
    /// MainActor-confined and already reads `DesignProposalStore.list()`
    /// synchronously, and putting a foreign-actor suspension in front of the
    /// language walk measurably delayed the rows past the point a mounted test
    /// pressed one (imprints P3 Task 5).
    ///
    /// **Safe to read outside the actor** because `save` above replaces the
    /// file atomically: a concurrent writer gives this reader the whole old
    /// document or the whole new one, never a torn one. What the actor protects
    /// is read-modify-write ordering, and this does not write.
    public nonisolated static func read(in projectURL: URL) throws -> PublishConfig? {
        let url = fileURL(in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)  // adr-0018-ok: publish config JSON read, not manuscript
        return try JSONDecoder().decode(PublishConfig.self, from: data)
    }

    public func save(_ config: PublishConfig) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)

        let tmp = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }
}

public struct ApplyPatchResult: Sendable {
    public let config: PublishConfig
    public let errors: [PublishConfigValidator.ValidationError]
}

extension PublishConfigStore {
    /// Merge `patch` into the persisted config, validate the result, and save
    /// it only if it validates.
    ///
    /// - Parameter additionalValidation: a second, project-aware pass over the
    ///   MERGED config — `PublishConfigValidator.validate(_:publishDir:pieceIDs:)`
    ///   in production, which is the only place a filesystem is read. It runs
    ///   after the pure rules and before `save`; a non-empty result means the
    ///   errors come back in `ApplyPatchResult.errors` and nothing is written,
    ///   exactly as a pure failure does. It is skipped when the pure rules
    ///   already refused — the project-aware validator runs those rules itself,
    ///   so running both over a refused config would report each pure error
    ///   twice. Callers that pass nothing get today's behaviour unchanged.
    public func applyPatch(
        _ patch: Data,
        additionalValidation: (@Sendable (PublishConfig) -> [PublishConfigValidator.ValidationError])? = nil
    ) throws -> ApplyPatchResult {
        let current = try load() ?? PublishConfig()
        let currentData = try JSONEncoder().encode(current)
        let mergedData = try JSONMergePatch.apply(patch: patch, to: currentData)
        let merged = try JSONDecoder().decode(PublishConfig.self, from: mergedData)

        var errs = PublishConfigValidator.validate(merged)
        if errs.isEmpty, let additionalValidation {
            errs = additionalValidation(merged)
        }
        if errs.isEmpty {
            try save(merged)
        }
        return ApplyPatchResult(config: merged, errors: errs)
    }
}
