import Foundation

/// A configured backup target: where to write and how many generations to keep.
/// Plain URL — security-scoped bookmark resolution and config persistence are the
/// Mac layer's job; this stays pure and testable.
public struct BackupDestination: Equatable, Sendable {
    public let url: URL
    public let retention: Int
    public init(url: URL, retention: Int) {
        self.url = url
        self.retention = retention
    }
}

/// The result of attempting a backup to one destination. `run` returns one per
/// destination; status UI will consume these.
public enum BackupOutcome: Sendable, Equatable {
    case written(destination: URL, generation: BackupGeneration)
    case skippedUnchanged(destination: URL)
    case failed(destination: URL, message: String)

    public var destination: URL {
        switch self {
        case .written(let d, _), .skippedUnchanged(let d), .failed(let d, _): return d
        }
    }
}

public enum BackupRunner {
    /// The content root hash of the newest committed generation at `destination`,
    /// or nil if there are none (or the newest has no readable manifest). Used to
    /// decide whether the source has changed since the last backup.
    public static func latestRootHash(at destination: URL) throws -> String? {
        guard let id = try BackupWriter.generationIds(at: destination).last else { return nil }
        let manifestURL = destination
            .appendingPathComponent(id)
            .appendingPathComponent(BackupWriter.manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let manifest = try JSONDecoder().decode(
            MerkleManifest.self, from: Data(contentsOf: manifestURL))
        return manifest.rootHash
    }

    /// Back up `projectURL` to each destination. Best-effort and independent: a
    /// failing destination becomes a `.failed` outcome and never aborts the others.
    /// A destination whose newest generation already matches the current source is
    /// `.skippedUnchanged` (so idle saves don't churn retention). After a write, the
    /// destination is pruned to its retention. Never throws. `generationId` is a
    /// caller-supplied ULID stamped onto every destination written this run.
    public static func run(
        projectURL: URL,
        destinations: [BackupDestination],
        generationId: String,
        at builtAt: Date
    ) -> [BackupOutcome] {
        // Surface an unreadable source as a per-destination failure (rather than a
        // silently empty signature).
        do {
            _ = try BackupWriter.relativeFilePaths(under: projectURL)
        } catch {
            return destinations.map {
                .failed(destination: $0.url, message: "source unreadable: \(error)")
            }
        }

        // Change-detection uses a content signature that ignores per-save bookkeeping
        // (the `.checkpoint` breadcrumb op, checkpoints.jsonl, sessions, ui-state…),
        // so an idle ⌘S that only wrote a checkpoint does NOT spawn a new generation.
        let signature = BackupSignature.compute(projectURL: projectURL)

        return destinations.map { dest in
            do {
                if let last = try latestSignature(at: dest.url), last == signature {
                    return .skippedUnchanged(destination: dest.url)
                }
                let gen = try BackupWriter.write(
                    source: projectURL, to: dest.url, generationId: generationId, at: builtAt)
                // Record the signature alongside the generation so the next run can
                // compare against it. (Excluded from the generation's own manifest
                // and from future signatures.)
                try Data(signature.utf8).write(
                    to: dest.url.appendingPathComponent(generationId)
                        .appendingPathComponent(BackupSignature.signatureName),
                    options: .atomic)
                try BackupWriter.prune(destination: dest.url, keeping: dest.retention)
                return .written(destination: dest.url, generation: gen)
            } catch {
                return .failed(destination: dest.url, message: "\(error)")
            }
        }
    }

    /// The content signature recorded with the newest committed generation at
    /// `destination`, or nil if there are none / it has no signature marker.
    public static func latestSignature(at destination: URL) throws -> String? {
        guard let id = try BackupWriter.generationIds(at: destination).last else { return nil }
        let url = destination.appendingPathComponent(id)
            .appendingPathComponent(BackupSignature.signatureName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
