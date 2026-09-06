import Foundation
import MaughamCore

/// read_first_reader — the fifth spine reader, on `read_lessons`'s exact
/// shape with one addition: a `name` field sourced from the manifest
/// (`ProjectManifest.firstReaderName`) rather than the statement, because
/// naming her is cheaper than describing her and the writer may have named
/// her without yet writing anything down.
///
/// The statement itself holds who she is, what she reads, what she will not
/// sit through, and the writer's own standing instructions for her under
/// `## Rulings`. **Claude never writes it** — same membrane rule as the
/// lessons ledger, craft intent and visual language: a read-only MCP surface
/// over writer-owned prose. Project scope only, for the lessons ledger's
/// reason — a first reader reads the whole book, not a chapter's private copy.
public enum ReadFirstReaderTool: MCPTool {
    public static let method = "read_first_reader"
    public static let description =
        "Read the project's first reader: her name and the writer's own description of "
        + "her (who she is, what she reads, what she will not sit through) with the "
        + "writer's standing instructions under ## Rulings. Project scope only. Read it "
        + "before responding to a piece as a reader; absence of a name is a valid "
        + "state — the writer has not defined one."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    public struct Params: Codable {
        public let project_id: String
    }
    public struct Result: Codable, Equatable {
        public let exists: Bool
        public let name: String?
        public let markdown: String?
        public let path: String?
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let name = entry.store.manifest.firstReaderName
        guard let statement = entry.store.statement(kind: .firstReader, scope: .project) else {
            // Absence is valid and mints nothing — the same posture as every
            // other statement reader. The name can still be present (the
            // writer named her without writing a description yet).
            return try JSONEncoder().encode(Result(exists: false, name: name, markdown: nil, path: nil))
        }
        // Derived, never the `.md` (tripwire 20) — `statementText(of:)` is the
        // one spelling of ADR 0018's two branches, shared by every statement
        // reader so none of them can disagree about which text is real.
        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(Result(
                exists: true,
                name: name,
                markdown: entry.store.statementText(of: statement),
                path: statement.path)),
            hint: "The first reader's description is too large to return in one MCP "
                + "response. Open it directly on disk at \(statement.path).")
    }
}
