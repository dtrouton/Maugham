import Foundation
import MaughamCore

/// read_lessons — the fourth spine reader, on `read_craft_intent`'s exact
/// shape minus `item_id`: the lessons ledger is project scope only
/// (`StatementConvention.newPath` has no row for `(.lessons, .document)` —
/// what the writer has learned about their own writing is one ledger for
/// the book, never a chapter's private copy).
///
/// The ledger holds three things in the writer's own prose, under
/// `## Rulings`: open lessons the writer is working on, choices
/// (`Choice: <heading>`) they made deliberately and do not want flagged
/// again, and retired lessons. **Claude never writes it** — it moves only
/// through the writer's own verbs in Maugham (Keep as lesson / These are
/// all choices / retire), the same membrane rule as craft intent and
/// visual language: a read-only MCP surface over writer-owned prose.
public enum ReadLessonsTool: MCPTool {
    public static let method = "read_lessons"
    public static let description =
        "Read the project's lessons ledger — the writer's own record of what they are "
        + "working on as a writer: open lessons/habits, choices they have made "
        + "deliberately (and do not want raised again), and lessons they have retired. "
        + "A coach or editor reading a piece should read this ledger before the piece, "
        + "and cite a habit by its heading VERBATIM when it applies. Returns exists:false "
        + "when the writer has not started a ledger yet; that is a valid, deliberate "
        + "state — do not invent one on their behalf. Claude never writes to this ledger; "
        + "it moves only through the writer's own verbs in Maugham. Project scope only — "
        + "there is no item_id, because what a writer is working on is not per-chapter."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    public struct Params: Codable {
        public let project_id: String
    }
    public struct Result: Codable, Equatable {
        public let exists: Bool
        public let markdown: String?
        public let path: String?
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        guard let statement = entry.store.statement(kind: .lessons, scope: .project) else {
            // Absence is valid and mints nothing — the same posture as every
            // other statement reader (`read_craft_intent`, `read_visual_language`,
            // `read_edition_brief`): a read that created the ledger would put a
            // file in a project the writer never opened.
            return try JSONEncoder().encode(Result(exists: false, markdown: nil, path: nil))
        }
        // Derived, never the `.md` (tripwire 20) — `statementText(of:)` is the
        // one spelling of ADR 0018's two branches, shared by every statement
        // reader so none of them can disagree about which text is real.
        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(Result(
                exists: true,
                markdown: entry.store.statementText(of: statement),
                path: statement.path)),
            hint: "The lessons ledger is too large to return in one MCP response. "
                + "Open it directly on disk at \(statement.path).")
    }
}
