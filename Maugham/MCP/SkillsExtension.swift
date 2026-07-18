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
/// resources/read is the base primitive (we serve skill:// only); unknown
/// skill URI MUST return -32602 Invalid params (MCPError.invalidArgument).
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
              let params = try? JSONDecoder().decode(URIParams.self, from: data),
              let skill = skillFor(skillMdURI: params.uri, in: index) else {
            // Draft: unknown skill URI → invalid params (-32602). MCPError
            // .invalidArgument maps to that class at the router boundary.
            throw MCPError.invalidArgument(
                "Unknown skill URI. Call skills/list for served skills.")
        }
        let entryData = try handleList(paramsJSON: nil, index: index)
        let obj = try JSONSerialization.jsonObject(with: entryData) as! [String: Any]
        let entry = (obj["skills"] as! [[String: Any]])
            .first { ($0["name"] as? String) == skill.name }!
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
                let text = String(data: file.bytes, encoding: .utf8) ?? ""
                return try JSONSerialization.data(withJSONObject: [
                    "contents": [[
                        "uri": params.uri,
                        "mimeType": "text/markdown",
                        "text": text,
                    ]]
                ], options: [.sortedKeys])
            }
        }
        throw MCPError.invalidArgument("Unknown skill resource: \(params.uri)")
    }

    private static func skillFor(
        skillMdURI: String, in index: SkillIndex
    ) -> SkillIndex.Skill? {
        index.skills.first { skill in
            uri(for: skill, file: skill.files[0]) == skillMdURI
        }
    }
}
