// Maugham/OpLog/CheckpointStore.swift
import Foundation

/// Project-wide append-only JSONL of named checkpoints. Thin facade
/// over `JSONLAppendStore<Checkpoint>`. No dedup, no sort — entries
/// returned in append order.
@MainActor
public final class CheckpointStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    public func load() async throws -> [Checkpoint] {
        try await backing.load()
    }

    public func append(_ cp: Checkpoint) async throws {
        try await backing.append(cp)
    }

    private var backing: JSONLAppendStore<Checkpoint> {
        JSONLAppendStore<Checkpoint>(
            fileURL: projectURL.appendingPathComponent(".maugham/checkpoints.jsonl"),
            presenter: presenter)
    }
}
