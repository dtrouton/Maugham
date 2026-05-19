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
             "Return text + metadata for a manuscript or text-research document. For an image research item (kind=image), returns a downscaled JPEG (default 2048 px longest edge, quality 85). Use `region` to crop into a sub-area at higher effective resolution — useful for hard-to-read handwriting or marginalia. `region` coordinates are normalized 0–1 with top-left origin.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"max_dimension\":{\"type\":\"integer\",\"description\":\"Longest-edge cap for image research items (256–4096, default 2048). Ignored for text documents.\"},\"quality\":{\"type\":\"integer\",\"description\":\"JPEG quality 10–100 for image research items (default 85). Ignored for text documents.\"},\"region\":{\"type\":\"object\",\"description\":\"Optional crop for image research items, normalized 0–1, top-left origin. e.g. {x:0.3,y:0.5,width:0.2,height:0.1} = 20% × 10% slice 30% from the left, 50% down. Ignored for text documents.\",\"properties\":{\"x\":{\"type\":\"number\"},\"y\":{\"type\":\"number\"},\"width\":{\"type\":\"number\"},\"height\":{\"type\":\"number\"}},\"required\":[\"x\",\"y\",\"width\",\"height\"]}},\"required\":[\"project_id\",\"document_id\"]}"),

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
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"}},\"required\":[\"project_id\"]}"),

            ("add_comment",
             "Attach an editorial comment to a manuscript paragraph. Comments do not modify the manuscript; the user accepts or rejects them via the Annotations pane. Reject reasoning is captured for future sessions.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"paragraph_id\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\",\"paragraph_id\",\"body\"]}"),

            ("add_suggested_change",
             "Propose a specific replacement for a paragraph. `body` is the editorial justification; `suggested_text` is the proposed new paragraph. The user accepts (applies the change) or rejects (with reasoning).",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"paragraph_id\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"},\"suggested_text\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\",\"paragraph_id\",\"body\",\"suggested_text\"]}"),

            ("add_query",
             "Ask the writer a question about a paragraph (intent, ambiguity, character motivation). The writer replies via the Annotations pane; the reply is persisted in the annotation history.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"paragraph_id\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\",\"paragraph_id\",\"body\"]}"),

            ("add_craft_note",
             "Record a document-scoped craft observation (e.g., character voice rule, structural pattern). Doc-scoped; no paragraph anchor. Accepted craft notes surface in `list_annotations(kind: craft_note, status: accepted)` for next-session reference.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\",\"body\"]}"),

            ("list_annotations",
             "List annotations on a document. Defaults to status=open. Filter by `kinds` (any of comment/suggested_change/query/craft_note), `statuses` (open/accepted/rejected/archived), `paragraph_id`. Use this to check prior editorial conversation on a paragraph before adding new suggestions.",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"kinds\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"statuses\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"paragraph_id\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\"]}"),

            ("get_annotation",
             "Return a full annotation record including its lifecycle history (creation + accept/reject/archive ops).",
             "{\"type\":\"object\",\"properties\":{\"project_id\":{\"type\":\"string\"},\"document_id\":{\"type\":\"string\"},\"annotation_id\":{\"type\":\"string\"}},\"required\":[\"project_id\",\"document_id\",\"annotation_id\"]}")
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
