import Foundation
import CryptoKit
import MaughamCore

/// Loads the bundled agent skills (`docs/skills/<name>/SKILL.md`,
/// agentskills.io format). The single seam every skills surface reads
/// through — SEP-2640 extension, get_help topics, and the bootstrap-skill
/// installer. Modeled on HelpTopicIndex: injected directory for tests,
/// `.bundled()` in production.
///
/// Frontmatter is deliberately restricted to flat `key: value` string
/// pairs (`name`, `description`) so a hand-rolled parser suffices — no
/// third-party YAML dependency (repo rule: Apple frameworks only).
struct SkillIndex {
    struct SkillFile: Equatable {
        let relativePath: String
        let bytes: Data
        let sha256Hex: String
    }
    struct Skill: Equatable {
        let name: String
        let description: String
        let body: String
        let raw: String
        let files: [SkillFile]
    }
    enum LoadError: Error, Equatable {
        case directoryMissing
        case malformedFrontmatter(String)
    }

    /// The router template installed into ~/.claude/skills — not served.
    static let bootstrapFolderName = "maugham-bootstrap"

    let skills: [Skill]
    let bootstrapTemplate: Skill?

    init(directory: URL, strict: Bool) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw LoadError.directoryMissing
        }
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        var loaded: [Skill] = []
        var bootstrap: Skill?
        for folder in folders {
            do {
                let skill = try Self.loadSkill(at: folder)
                if folder.lastPathComponent == Self.bootstrapFolderName {
                    bootstrap = skill
                } else {
                    loaded.append(skill)
                }
            } catch {
                // A broken skill must not take the MCP server down in
                // release; dev builds fail loudly so authoring errors are
                // caught immediately (spec: error handling).
                if strict { throw error }
                NSLog("SkillIndex: skipping malformed skill %@: %@",
                      folder.lastPathComponent, "\(error)")
            }
        }
        self.skills = loaded
        self.bootstrapTemplate = bootstrap
    }

    /// Production loader: the `skills/` folder bundled by `project.yml`.
    static func bundled() throws -> SkillIndex {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("skills") else {
            throw LoadError.directoryMissing
        }
        return try SkillIndex(directory: url, strict: BuildVariant.current == .dev)
    }

    func skill(named name: String) -> Skill? {
        skills.first(where: { $0.name == name })
    }

    // MARK: - Loading

    private static func loadSkill(at folder: URL) throws -> Skill {
        let folderName = folder.lastPathComponent
        let skillURL = folder.appendingPathComponent("SKILL.md")
        guard let raw = try? String(contentsOf: skillURL, encoding: .utf8) else {  // adr-0018-ok: bundled skill read, not manuscript
            throw LoadError.malformedFrontmatter(folderName)
        }
        let (frontmatter, body) = try parseFrontmatter(raw, folderName: folderName)
        guard let name = frontmatter["name"], !name.isEmpty,
              let description = frontmatter["description"], !description.isEmpty else {
            throw LoadError.malformedFrontmatter(folderName)
        }

        var files: [SkillFile] = []
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        for fileURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let bytes = try? Data(contentsOf: fileURL) else { continue }  // adr-0018-ok: bundled skill read, not manuscript
            let digest = SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }.joined()
            files.append(SkillFile(
                relativePath: fileURL.lastPathComponent,
                bytes: bytes, sha256Hex: digest))
        }
        // SKILL.md leads; siblings follow in name order.
        files.sort { a, b in
            if a.relativePath == "SKILL.md" { return true }
            if b.relativePath == "SKILL.md" { return false }
            return a.relativePath < b.relativePath
        }
        return Skill(name: name, description: description,
                     body: body, raw: raw, files: files)
    }

    /// Flat `key: value` frontmatter between `---` fences.
    static func parseFrontmatter(
        _ raw: String, folderName: String
    ) throws -> (fields: [String: String], body: String) {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first == "---",
              let closeIdx = lines.dropFirst().firstIndex(of: "---") else {
            throw LoadError.malformedFrontmatter(folderName)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<closeIdx] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let colon = trimmed.firstIndex(of: ":") else {
                throw LoadError.malformedFrontmatter(folderName)
            }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        let body = lines[(closeIdx + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        return (fields, body)
    }
}
