import Foundation
import MaughamCore

/// MCP tool: `get_help` — read-only access to Maugham's user documentation,
/// the same topic files the writer reads in Help → Maugham Help. Lets Claude
/// answer "how do I X in Maugham?" from authoritative text.
public enum GetHelpTool: MCPTool {
    public static let method = "get_help"
    public static let description =
        "Read Maugham's own user documentation. Omit `topic` to get the list of available help topics (slug + title); pass a `topic` slug to get that topic's full markdown. Use this to answer questions about how to use Maugham (focus mode, the binder, screenplays, publishing, Claude integration, keyboard shortcuts, on-disk layout, troubleshooting)."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"topic":{"type":"string","description":"Optional help topic slug (e.g. \\"getting-started\\", \\"editor-and-focus\\"). Omit to list all topics."}}}
    """

    struct Params: Codable { let topic: String? }

    /// Pure responder — unit-testable with an injected index.
    static func respond(paramsJSON: Data?, index: HelpTopicIndex) throws -> Data {
        let topic = paramsJSON
            .flatMap { try? JSONDecoder().decode(Params.self, from: $0) }?
            .topic

        if let topic, !topic.isEmpty {
            let md = try index.markdown(for: topic)   // throws topicMissing on unknown
            return try JSONSerialization.data(withJSONObject: [
                "slug": topic, "markdown": md
            ], options: [.sortedKeys])
        }

        let topics = index.topics.map { ["slug": $0.slug, "title": $0.title] }
        return try JSONSerialization.data(withJSONObject: [
            "topics": topics, "count": topics.count
        ], options: [.sortedKeys])
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let index = try HelpTopicIndex.bundled()
        return try respond(paramsJSON: paramsJSON, index: index)
    }
}
