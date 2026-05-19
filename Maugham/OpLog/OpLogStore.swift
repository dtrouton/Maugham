// Maugham/OpLog/OpLogStore.swift
import Foundation

/// Per-document append-only JSONL op log. One file per document at
/// `.maugham/ops/<doc-id>.jsonl`. Dedupes by `op_id` and sorts by
/// `op_id` (timestamp-prefixed ULID gives deterministic cross-device
/// order). Thin facade over `JSONLAppendStore<Op>`.
@MainActor
public final class OpLogStore {
    public let projectURL: URL
    public let presenter: NSFilePresenter?

    public init(projectURL: URL, presenter: NSFilePresenter? = nil) {
        self.projectURL = projectURL
        self.presenter = presenter
    }

    public func load(docId: String) async throws -> [Op] {
        try await store(for: docId).load()
    }

    public func append(_ op: Op) async throws {
        try await store(for: op.docId).append(op)
    }

    private func store(for docId: String) -> JSONLAppendStore<Op> {
        JSONLAppendStore<Op>(
            fileURL: projectURL.appendingPathComponent(".maugham/ops/\(docId).jsonl"),
            presenter: presenter,
            dedupKey: { $0.opId },
            sortedBy: { $0.opId < $1.opId })
    }
}
