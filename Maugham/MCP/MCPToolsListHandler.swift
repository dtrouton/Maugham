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
             "Search the manuscript for text matches. Supports case_sensitive and whole_word options.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"query\":{\"type\":\"string\"},\"case_sensitive\":{\"type\":\"boolean\"},\"whole_word\":{\"type\":\"boolean\"}},\"required\":[\"project_id\",\"query\"]}"),

            ("list_scenes",
             "Return scenes parsed from a Fountain screenplay. Empty array for non-screenplay projects.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"}},\"required\":[\"project_id\"]}"),

            ("find_references",
             "Find back-references to a document or research item ([[wiki links]] in manuscript text + research-link backrefs).",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"target\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"target\"]}"),

            ("get_session_stats",
             "Aggregate writing session stats over a window (default 30 days): per-day words + minutes, totals.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"days\":{\"type\":\"integer\"}},\"required\":[\"project_id\"]}"),

            ("add_note",
             "Create a research note (.md) under the project's research folder. Optionally placed in an existing group.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"parent_group_id\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"title\",\"body\"]}")
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
