import Foundation
import MaughamCore

/// Installs the bundled bootstrap ("router") skill into Claude Code's
/// personal skills directory and detects staleness — the same
/// detect/act/state pattern as ClaudeDesktopConfig, for a file instead of
/// JSON. detect() never writes; install() is the only mutation and only
/// runs on explicit user action from the setup sheet.
///
/// This writes OUTSIDE any Maugham project (app-config class, like the
/// Claude Desktop config) — plain FileManager by design, not the typed
/// user-content mover.
public enum ClaudeCodeSkillInstall {
    public enum State: Equatable {
        case notInstalled
        case installedCurrent
        case stale
    }

    public static let defaultSkillURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/maugham/SKILL.md")
    }()

    public static func detect(installURL: URL, template: String) -> State {
        guard let installed = try? String(contentsOf: installURL, encoding: .utf8) else {  // adr-0018-ok: app-config read, not manuscript
            return .notInstalled
        }
        return installed == template ? .installedCurrent : .stale
    }

    public static func install(installURL: URL, template: String) throws {
        try FileManager.default.createDirectory(
            at: installURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try template.write(to: installURL, atomically: true, encoding: .utf8)
    }

    public static func cliCommand(
        serverKey: String, binaryPath: String, socketPath: String?
    ) -> String {
        if let socketPath {
            return "claude mcp add \(serverKey) --env \"MAUGHAM_MCP_SOCKET=\(socketPath)\" -- \"\(binaryPath)\""
        }
        return "claude mcp add \(serverKey) \"\(binaryPath)\""
    }
}
