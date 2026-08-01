import Foundation
import MaughamCore

/// read_craft_intent — the writer's optional statement of what a piece needs
/// sensorially. ABSENCE IS VALID: returns {exists: false}, never an error.
///
/// **It answers off a `Statement` since M1A**, which is what widened `item_id`
/// from a Collection loose piece to any manuscript document: the old seam looked
/// its doc up by the piece's research path prefix, which is nil for anything
/// else, so a novel chapter's intent read as absent even when it existed. A
/// statement is found by scope in the manifest, so there is no prefix to be nil.
public enum ReadCraftIntentTool: MCPTool {
    public static let method = "read_craft_intent"
    public static let description =
        "Read the writer's craft-intent doc — an optional freeform statement of what "
        + "the story (or one document in it) needs, e.g. sensory groundedness goals. "
        + "Returns exists:false when the writer has not declared one; that is a valid, "
        + "deliberate state — do not invent a standard on their behalf. Pass item_id "
        + "for a particular manuscript document; omit for project scope."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"item_id":{"type":"string"}},"required":["project_id"]}"#

    public struct Params: Codable {
        public let project_id: String
        public let item_id: String?
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
        let scope: Statement.Scope =
            params.item_id.map { .document($0) } ?? .project
        guard let statement = entry.store.statement(kind: .intent, scope: scope) else {
            // Absence, including for an `item_id` this project does not hold —
            // an undeclared scope, not an error. Nothing is minted on the way.
            return try JSONEncoder().encode(Result(exists: false, markdown: nil, path: nil))
        }
        return try MCPResponseBudget.enforce(
            try JSONEncoder().encode(Result(
                exists: true, markdown: text(of: statement, in: entry), path: statement.path)),
            hint: "The craft-intent doc is too large to return in one MCP response. "
                + "Open it directly on disk at \(statement.path).")
    }

    /// What the statement says, **derived rather than read off the `.md`**
    /// (tripwire 20). The old annotation here was `// adr-0018-ok: craft-intent
    /// note read, not manuscript`, and that justification held only while intent
    /// was a plain research note; a statement is a `Document` with an op log, so
    /// the file beside it is derived output and lags whenever an op lands out of
    /// band.
    ///
    /// ADR 0018's two branches, with the open one reached by a seam of its own:
    /// a statement is deliberately in no `DocumentStore` registry (spec §8 — it
    /// would join `allOpenDocuments()` and pollute the project Tasks
    /// aggregation), so `documentStore.document(forDocId:)` answers nil for one
    /// and the branch `read_document` and `find_references` take is unavailable
    /// here. `ProjectStore.openStatementDocument(id:)` — built by Task 7 for
    /// promotion's own collision on this path — is what finds the Intent pane's
    /// live `Document`, and it is the fresher answer by up to one debounce
    /// window: a burst the writer is still typing has not reached
    /// `.maugham/ops/` yet, and the derived branch cannot see it.
    @MainActor
    private static func text(of statement: Statement, in entry: ProjectRegistry.Entry) -> String {
        if let live = entry.store.openStatementDocument(id: statement.id) {
            return live.displayText
        }
        // Display form, not the materialised one: an intent carries no
        // annotations, so nothing on this surface anchors to a `¶id`, and what
        // the writer sees in the pane is what Claude should read.
        return entry.store.derivedCache.displayText(
            forDocId: statement.id, in: entry.url)
    }
}
