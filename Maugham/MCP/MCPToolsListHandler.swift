import Foundation

/// MCP `tools/list` handler. Returns the catalog of available tools with
/// JSON-Schema-shaped `inputSchema` for each. Claude Desktop consumes this
/// to know which tools to expose and how to render arguments.
public enum MCPToolsListHandler {
    public static let method = "tools/list"

    public static func handle(paramsJSON: Data?) async throws -> Data {
        let schemas: [(name: String, description: String, schemaJSON: String)] = [
            ("list_projects",
             "List currently-open Maugham projects.",
             "{\"type\":\"object\",\"properties\":{}}"),

            ("get_metadata",
             "Return project-level metadata: title, type, author, dates, targets, tags, research count.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"}},\"required\":[\"project_id\"]}"),

            ("get_outline",
             "Return the hierarchical manuscript structure with status, synopsis, and word counts.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"}},\"required\":[\"project_id\"]}"),

            ("read_document",
             "Return the text and metadata of a manuscript document. Live in-memory text if the doc is open in Maugham.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\"]}"),

            ("search_text",
             "Search manuscript document text for matches. Manuscript-only — does not scan [[wiki-link]] tokens, linked-research backrefs, or research note bodies. Use find_references for those.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"query\":{\"type\":\"string\"},\"case_sensitive\":{\"type\":\"boolean\"},\"whole_word\":{\"type\":\"boolean\"}},\"required\":[\"project_id\",\"query\"]}"),

            ("list_scenes",
             "Return scenes parsed from a Fountain screenplay. Empty array for non-screenplay projects.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"}},\"required\":[\"project_id\"]}"),

            ("find_references",
             "Find back-references to a document or research item. The `target` can be an id (returned by get_outline / list_research) or a title (case-insensitive match). Returns [[wiki link]] matches in manuscript text + research-link backrefs.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"target\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"target\"]}"),

            ("get_session_stats",
             "Aggregate writing session stats over a window (default 30 days): per-day words + minutes, totals.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"days\":{\"type\":\"integer\"}},\"required\":[\"project_id\"]}"),

            ("add_note",
             "Create a research note (.md) under the project's research folder. Optionally placed in an existing group.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"parent_group_id\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"title\",\"body\"]}"),

            ("list_research",
             "List the project's research tree hierarchically. Each item has id, title, type (group/asset), kind, path. Use this to discover research items before calling find_references or read_document.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"}},\"required\":[\"project_id\"]}"),

            ("list_documents_by_tag",
             "List manuscript documents whose tags include the given tag (case-insensitive). Returns id, title, path, tags.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"tag\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"tag\"]}"),

            ("link_research",
             "Link a research item to a manuscript document so it shows up in the Inspector. Idempotent. Use get_outline + list_research to find ids.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"research_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"research_id\",\"document_id\"]}"),

            ("unlink_research",
             "Remove a research-to-document link. Idempotent (no-op if the link doesn't exist).",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"research_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"research_id\",\"document_id\"]}"),

            ("list_all_links",
             "Return the full reference graph as edges: every manuscript document's linked-research and [[wiki-link]] targets. Each edge has from_id/from_title, to_id (null for unresolved wiki targets) / to_title, and kind ('linked_research' / 'wiki' / 'wiki_unresolved').",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"}},\"required\":[\"project_id\"]}")
        ]

        var tools: [AnyJSON] = []
        for entry in schemas {
            let schemaAny = try JSONDecoder().decode(
                AnyJSON.self, from: Data(entry.schemaJSON.utf8))
            tools.append(.object([
                "name": .string(entry.name),
                "description": .string(entry.description),
                "inputSchema": schemaAny
            ]))
        }
        let result = AnyJSON.object(["tools": .array(tools)])
        return try JSONEncoder().encode(result)
    }
}
