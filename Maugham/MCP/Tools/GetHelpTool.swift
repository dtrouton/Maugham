import Foundation
import MaughamCore

/// MCP tool: `get_help` — read-only access to Maugham's user documentation,
/// the same topic files the writer reads in Help → Maugham Help. Lets Claude
/// answer "how do I X in Maugham?" from authoritative text.
public enum GetHelpTool: MCPTool {
    public static let method = "get_help"
    public static let description =
        "Read Maugham's own user documentation. Omit `topic` to get the list of available help topics (slug + title); pass a `topic` slug to get that topic's full markdown. Use this to answer questions about how to use Maugham (focus mode, the binder, screenplays, publishing, Claude integration, keyboard shortcuts, on-disk layout, troubleshooting)." +
        " Topic \"skills\" lists Maugham's agent skills (task procedures like transcribing-notebooks, editing-pass); pass a skill name as topic to load it."
    public static let inputSchemaJSON = """
    {"type":"object","properties":{"topic":{"type":"string","description":"Optional help topic slug (e.g. \\"getting-started\\", \\"editor-and-focus\\"). Omit to list all topics."}}}
    """

    struct Params: Codable { let topic: String? }

    /// Pure responder — unit-testable with an injected index.
    ///
    /// Precedence when `topic` is present: the literal topic id `"skills"`
    /// wins first (there is no help topic named "skills" — keep it that
    /// way), then a matching skill name, then a help topic slug; an unknown
    /// topic still throws.
    static func respond(paramsJSON: Data?, index: HelpTopicIndex, skills: SkillIndex) throws -> Data {
        let topic = paramsJSON
            .flatMap { try? JSONDecoder().decode(Params.self, from: $0) }?
            .topic

        if let topic, !topic.isEmpty {
            if topic == "skills" {
                return try JSONSerialization.data(withJSONObject: [
                    "skills": skills.skills.map {
                        ["name": $0.name, "description": $0.description]
                    },
                    "hint": "Pass a skill name as topic to load its full procedure.",
                ], options: [.sortedKeys])
            }
            if let skill = skills.skill(named: topic) {
                return try JSONSerialization.data(withJSONObject: [
                    "slug": skill.name, "markdown": skill.body,
                ], options: [.sortedKeys])
            }
            let md = try index.markdown(for: topic)   // throws topicMissing on unknown
            return try JSONSerialization.data(withJSONObject: [
                "slug": topic, "markdown": md
            ], options: [.sortedKeys])
        }

        let topics = index.topics.map { ["slug": $0.slug, "title": $0.title] }
        return try JSONSerialization.data(withJSONObject: [
            "topics": topics,
            "count": topics.count,
            "skills": skills.skills.map {
                ["name": $0.name, "description": $0.description]
            },
        ], options: [.sortedKeys])
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let index = try HelpTopicIndex.bundled()
        // User documentation must not be held hostage to the skills bundle: a
        // packaging regression that drops the `skills/` folder should still
        // serve help topics. Degrade only the missing-directory case to an
        // empty skills index (the skills list is then empty); every other
        // load error (malformed frontmatter, duplicate name) still throws.
        let skills: SkillIndex
        do {
            skills = try SkillIndex.bundled()
        } catch SkillIndex.LoadError.directoryMissing {
            skills = SkillIndex.empty
        }
        return try respond(paramsJSON: paramsJSON, index: index, skills: skills)
    }
}
