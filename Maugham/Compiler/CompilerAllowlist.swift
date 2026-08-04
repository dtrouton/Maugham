import Foundation

/// Enumerated read-only MCP tool allowlist for the compiler's spawned Claude.
/// The compiler is a peer MCP client spawned as a separate process; this allowlist
/// restricts it to the tools it needs for analysis, excluding all write tools.
public enum CompilerAllowlist {
    /// The full list of allowed tools, prefixed with "mcp__maugham__" for MCP transport.
    public static let tools: [String] = [
        "mcp__maugham__list_projects",
        "mcp__maugham__get_metadata",
        "mcp__maugham__get_outline",
        "mcp__maugham__read_document",
        "mcp__maugham__search_text",
        "mcp__maugham__list_scenes",
        "mcp__maugham__find_references",
        "mcp__maugham__get_session_stats",
        "mcp__maugham__list_research",
        "mcp__maugham__list_documents_by_tag",
        "mcp__maugham__list_all_links",
        "mcp__maugham__list_annotations",
        "mcp__maugham__get_annotation",
        "mcp__maugham__list_tasks",
        "mcp__maugham__get_task",
        "mcp__maugham__get_publish_config",
        "mcp__maugham__list_publish_files",
        "mcp__maugham__read_publish_file",
        "mcp__maugham__read_publish_image",
        "mcp__maugham__preview_compile",
        "mcp__maugham__compile_status",
        "mcp__maugham__list_publications",
        "mcp__maugham__read_publication_page",
        "mcp__maugham__read_preview_page",
        "mcp__maugham__list_inbox",
        "mcp__maugham__read_inbox_entry",
        "mcp__maugham__list_maugham_tools",
        "mcp__maugham__read_craft_intent",
        "mcp__maugham__read_visual_language",
        "mcp__maugham__list_palette_cards",
        "mcp__maugham__read_palette_card",
        "mcp__maugham__get_help",
        "mcp__maugham__read_translation",
        "mcp__maugham__translation_status",
        "mcp__maugham__list_canvas"
    ]

    /// Returns the CLI arguments to pass to the spawned Claude process.
    /// Format: ["--allowedTools", "<comma-separated list>"]
    public static func cliArguments() -> [String] {
        let joinedTools = tools.joined(separator: ",")
        return ["--allowedTools", joinedTools]
    }
}
