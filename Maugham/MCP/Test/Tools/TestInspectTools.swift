import Foundation
import MaughamCore

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
