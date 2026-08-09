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
            MerkleManifest.self, from: Data(contentsOf: manifestURL))  // adr-0018-ok: backup Merkle manifest read, not manuscript
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
    /// `destination`, or nil if there are none / it has no signature marker / **it
    /// does not verify**.
    ///
    /// The signature marker lives *inside* the generation directory it describes, so
    /// partial corruption — the common kind — rots the content while leaving the
    /// marker readable. Answering with that marker made every later run return
    /// `.skippedUnchanged`: the system reported "backed up", wrote nothing, and never
    /// replaced the corrupt newest generation for as long as the source was
    /// unedited. Returning nil forces exactly one write, after which the newest
    /// generation is intact again and skip-detection resumes.
    ///
    /// **Only the newest generation is consulted, and it must verify.** Walking back
    /// past a corrupt newest to an older intact marker — the shape findings §10.5
    /// item 2 proposed — still admits a skip while the newest is corrupt, which is
    /// what `NoWedgedOnCorruptNewest` forbids: the writer need only revert an edit for
    /// an older marker to match again. Model-checked:
    /// `BackupRetention_NoWedgedOnCorruptNewest` (violated by the unconditional read)
    /// against `BackupRetention_Fixed_NoWedgedOnCorruptNewest` (green with this one).
    /// See `formal/BackupRetention.tla`.
    ///
    /// **Cost: one Merkle pass over the newest generation per run per destination**,
    /// on top of the source-tree hash `BackupSignature.compute` already does — call
    /// it double. Both happen inside `BackupCoordinator`'s `Task.detached`, off the
    /// main actor, once per ⌘S. Only the newest generation is ever read, so the cost
    /// does not grow with retention.
    public static func latestSignature(at destination: URL) throws -> String? {
        guard let id = try BackupWriter.generationIds(at: destination).last else { return nil }
        guard ((try? BackupWriter.verifyGeneration(id: id, at: destination)) ?? ["<unverifiable>"]).isEmpty
        else { return nil }
        let url = destination.appendingPathComponent(id)
            .appendingPathComponent(BackupSignature.signatureName)
        guard let data = try? Data(contentsOf: url) else { return nil }  // adr-0018-ok: backup file bytes read for checksum, not manuscript-as-truth
        return String(data: data, encoding: .utf8)
    }
}
