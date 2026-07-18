import Foundation

/// SEP-2640 "Skills Extension" surface — Maugham-served agent skills over
/// MCP, built on the Resources primitives per the draft's direction.
///
/// // SEP-2640 pin: PR #2640 diff fetched 2026-07-18
/// (patch-diff.githubusercontent.com/raw/modelcontextprotocol/modelcontextprotocol/pull/2640.diff).
/// Shapes confirmed against that diff: capability = capabilities.extensions
/// ["io.modelcontextprotocol/skills"] = {} (empty object = supported, no
/// optional features; `directoryRead: true` is the only optional flag and we
/// don't implement resources/directory/read); skills/list result =
/// {skills:[{uri, frontmatter:{name,description}, resources:[{uri,
/// digest:"sha256:<hex>"}]}]}; skills/get param {uri} → {skill:{…}};
/// resources/read is the base primitive (we serve skill:// only; UTF-8
/// files → `text` + extension-derived mimeType, non-UTF-8 → base64 `blob`
/// + application/octet-stream, per the base Resources contract); unknown
/// skill URI MUST return -32602 Invalid params (MCPError.invalidArgument).
/// Identity is the URI, not the name (SEP: names are not unique ids) —
/// skills/get resolves by URI, and because the skill:// namespace derives
/// from the frontmatter name, SkillIndex refuses colliding names at load
/// (strict throws duplicateSkillName; lenient keeps first).
/// Deviation from the diff: entries also carry top-level `name`/`description`
/// (the diff nests them only under `frontmatter`). This is a compatible
/// superset — extra fields, no renamed/removed ones — kept so Maugham clients
/// can read them without unwrapping frontmatter. The divergent
/// experimental-ext-skills repo draft (skill://index.json, `url`, no digest)
/// is OLDER and was NOT followed; PR #2640 is canonical.
///
/// This file is the ONLY place SEP shapes live (spec: one seam, expect
/// drift while the SEP is unmerged). These are protocol methods like
/// tools/list — NOT tools; the tool catalog is unaffected.
public enum SkillsExtension {
    public static let extensionId = "io.modelcontextprotocol/skills"
    public static let listMethod = "skills/list"
    public static let getMethod = "skills/get"
    public static let readMethod = "resources/read"

    static func uri(for skill: SkillIndex.Skill, file: SkillIndex.SkillFile) -> String {
        "skill://\(skill.name)/\(file.relativePath)"
    }

    // MARK: - skills/list

    static func handleList(paramsJSON: Data?, index: SkillIndex) throws -> Data {
        let entries: [[String: Any]] = index.skills.map { skill in
            let (frontmatter, _) = (try? SkillIndex.parseFrontmatter(
                skill.raw, folderName: skill.name)) ?? ([:], "")
            return [
                "name": skill.name,
                "description": skill.description,
                "uri": uri(for: skill, file: skill.files[0]),
                "frontmatter": frontmatter,
                "resources": skill.files.map { file in
                    ["uri": uri(for: skill, file: file),
                     "digest": "sha256:\(file.sha256Hex)"]
                },
            ]
        }
        return try JSONSerialization.data(
            withJSONObject: ["skills": entries], options: [.sortedKeys])
    }

    // MARK: - skills/get

    private struct URIParams: Codable { let uri: String }

    static func handleGet(paramsJSON: Data?, index: SkillIndex) throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(URIParams.self, from: data) else {
            // Draft: unknown skill URI → invalid params (-32602). MCPError
            // .invalidArgument maps to that class at the router boundary.
            throw MCPError.invalidArgument(
                "Unknown skill URI. Call skills/list for served skills.")
        }
        let entryData = try handleList(paramsJSON: nil, index: index)
        let obj = try JSONSerialization.jsonObject(with: entryData) as! [String: Any]
        // Match by URI, not name — per the SEP, names are not unique
        // identifiers; the URI is the identity. (Belt-and-braces: the URI
        // namespace derives from the frontmatter name, so SkillIndex also
        // refuses colliding names at load — LoadError.duplicateSkillName —
        // keeping URIs unique by construction.)
        guard let entry = (obj["skills"] as! [[String: Any]])
            .first(where: { ($0["uri"] as? String) == params.uri }) else {
            throw MCPError.invalidArgument(
                "Unknown skill URI. Call skills/list for served skills.")
        }
        return try JSONSerialization.data(
            withJSONObject: ["skill": entry], options: [.sortedKeys])
    }

    // MARK: - resources/read (skill:// only)

    static func handleRead(paramsJSON: Data?, index: SkillIndex) throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(URIParams.self, from: data) else {
            throw MCPError.invalidArgument("resources/read requires a uri")
        }
        guard params.uri.hasPrefix("skill://") else {
            throw MCPError.invalidArgument(
                "Maugham serves resources only under skill:// (agent skills). Got: \(params.uri)")
        }
        for skill in index.skills {
            for file in skill.files where uri(for: skill, file: file) == params.uri {
                // Base Resources contract: UTF-8 files return `text` with an
                // extension-derived mimeType; non-UTF-8 bytes return `blob`
                // (base64) — never a silently-lossy empty `text`.
                var content: [String: Any] = ["uri": params.uri]
                if let text = String(data: file.bytes, encoding: .utf8) {
                    content["mimeType"] = mimeType(forRelativePath: file.relativePath)
                    content["text"] = text
                } else {
                    content["mimeType"] = "application/octet-stream"
                    content["blob"] = file.bytes.base64EncodedString()
                }
                return try JSONSerialization.data(
                    withJSONObject: ["contents": [content]], options: [.sortedKeys])
            }
        }
        throw MCPError.invalidArgument("Unknown skill resource: \(params.uri)")
    }

    /// mimeType for a UTF-8 skill file, by extension. Unknown text-decodable
    /// extensions fall back to text/plain (binary never reaches this — it
    /// takes the blob branch above).
    private static func mimeType(forRelativePath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown": return "text/markdown"
        case "json":           return "application/json"
        default:               return "text/plain"
        }
    }
}
