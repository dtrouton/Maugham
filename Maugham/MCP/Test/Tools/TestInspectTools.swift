import Foundation
import MaughamCore

#if MAUGHAM_DEV_BUILD

private struct DocParams: Codable {
    let project_id: String
    let doc_id: String
}

@MainActor
private func openDocument(_ p: DocParams, _ registry: ProjectRegistry) throws -> Document {
    let entry = try TestDumpDocumentTool.resolveProject(p.project_id, in: registry)
    guard let doc = entry.store.documentStore?.document(forDocId: p.doc_id) else {
        throw MCPError.invalidArgument("doc not open: \(p.doc_id)")
    }
    return doc
}

/// `test_dump_document` — dev-only read of an open `Document`'s in-memory
/// state (displayText, cursor, paragraph sequence/text, materialized form,
/// and the clean anchor-free disk form). Assertion surface for later
/// drive-tool tasks.
public enum TestDumpDocumentTool: MCPTool {
    public struct Result: Codable {
        public let display_text: String
        public let cursor_location: Int
        public let sequence: [String]
        public let paragraphs: [String: String]
        public let materialized: String
        public let clean_disk_form: String
    }
    public static let method = "test_dump_document"
    public static let description = "Dev-only: dump the in-memory Document (displayText, cursor, paragraphs by sequence, materialized + clean disk form)."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"doc_id":{"type":"string"}},"required":["project_id","doc_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(DocParams.self, from: paramsJSON)
        let doc = try openDocument(p, registry)
        var paras: [String: String] = [:]
        for id in doc.sequence { paras[id] = doc.paragraph(id: id) }
        let materialized = doc.materialize()
        let result = Result(
            display_text: doc.displayText,
            cursor_location: doc.cursorLocation,
            sequence: doc.sequence,
            paragraphs: paras,
            materialized: materialized,
            clean_disk_form: MarkdownDisplayFilter.stripAnchors(materialized))
        return try JSONEncoder().encode(result)
    }
}

/// `test_dump_oplog` — dev-only dump of the in-memory op-log mirror for a
/// doc (kind + summary per op), the source-of-truth assertion surface for
/// drive tools that append ops.
public enum TestDumpOplogTool: MCPTool {
    public struct OpRow: Codable {
        let sequence_index: Int
        let kind: String
        let summary: String
    }
    public struct Result: Codable {
        public let count: Int
        public let ops: [OpRow]
    }
    public static let method = "test_dump_oplog"
    public static let description = "Dev-only: dump the in-memory op-log mirror for a doc (kind + summary per op)."
    public static let inputSchemaJSON = TestDumpDocumentTool.inputSchemaJSON

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(DocParams.self, from: paramsJSON)
        let doc = try openDocument(p, registry)
        let rows = doc.opLogSnapshot.enumerated().map { idx, op in
            OpRow(sequence_index: idx, kind: String(describing: op.kind), summary: String(describing: op))
        }
        return try JSONEncoder().encode(Result(count: rows.count, ops: rows))
    }
}

/// `test_autosave_status` — dev-only read of a doc's autosave/sweep state:
/// whether the pending burst buffer has un-bursted changes
/// (`!doc.pending.isEmpty()`), whether an orphan-annotation sweep is queued
/// (`doc._pendingSweep`), and when the last autosave echo was recorded
/// (`doc.lastDiskEcho.writtenAt`). All three are `internal` members of
/// `Document` (Maugham/OpLog/Document.swift), directly reachable from this
/// app-target tool — no dev-only accessor needed on `Document` itself.
public enum TestAutosaveStatusTool: MCPTool {
    public struct Result: Codable {
        public let has_pending: Bool
        public let pending_sweep: String?
        public let last_echo_written_at: String
    }
    public static let method = "test_autosave_status"
    public static let description = "Dev-only: report a doc's autosave/sweep state (pending burst buffer, pending sweep reason, last disk-echo timestamp)."
    public static let inputSchemaJSON = TestDumpDocumentTool.inputSchemaJSON

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(DocParams.self, from: paramsJSON)
        let doc = try openDocument(p, registry)
        let result = Result(
            has_pending: !doc.pending.isEmpty(),
            pending_sweep: doc._pendingSweep.map { String(describing: $0) },
            last_echo_written_at: ISO8601DateFormatter().string(from: doc.lastDiskEcho.writtenAt))
        return try JSONEncoder().encode(result)
    }
}

/// `test_pending_buffer` — dev-only read of a doc's un-bursted paragraph
/// changes: the durable paragraph order as of the last autosave flush
/// (`doc.pending.sequence`) and the count of un-bursted changes
/// (`doc.pending.snapshot().count`). `PendingBuffer` (Maugham/OpLog/PendingBuffer.swift)
/// exposes both as `public` members already, so no new accessor is needed.
public enum TestPendingBufferTool: MCPTool {
    public struct Result: Codable {
        public let sequence: [String]
        public let change_count: Int
    }
    public static let method = "test_pending_buffer"
    public static let description = "Dev-only: dump the doc's pending burst buffer (durable paragraph order + un-bursted change count)."
    public static let inputSchemaJSON = TestDumpDocumentTool.inputSchemaJSON

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(DocParams.self, from: paramsJSON)
        let doc = try openDocument(p, registry)
        let result = Result(
            sequence: doc.pending.sequence,
            change_count: doc.pending.snapshot().count)
        return try JSONEncoder().encode(result)
    }
}

/// `test_list_checkpoints` — dev-only list of a project's checkpoints
/// (labels, in append order), read straight off `CheckpointStore` — the
/// same store `TestCheckpointTool` appends to.
public enum TestListCheckpointsTool: MCPTool {
    public struct Params: Codable { let project_id: String }
    public struct Result: Codable {
        public let count: Int
        public let labels: [String]
    }
    public static let method = "test_list_checkpoints"
    public static let description = "Dev-only: list project checkpoints (labels, in append order)."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let p = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(p.project_id, in: registry)
        // RULING-54 lenient, reason recorded: a dev-only listing over the
        // TestWorkspace fence — an unreadable device file here is a test
        // fixture problem, and the load names it in its own result type.
        let checkpoints = await CheckpointStore(projectURL: entry.url).load().checkpoints
        return try JSONEncoder().encode(Result(count: checkpoints.count, labels: checkpoints.map { $0.label }))
    }
}
#endif
