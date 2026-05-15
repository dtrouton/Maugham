import Foundation

/// Detects (and in T15 will mutate) Claude Desktop's config file.
public enum ClaudeDesktopConfig {
    public enum State: Equatable {
        case missing
        case corrupt
        case unconfigured
        case stalePath(currentPath: String)
        case configured(path: String)
    }

    public static let defaultConfigURL: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Application Support/Claude/claude_desktop_config.json")
    }()

    public static func detect(configURL: URL, expectedBinary: String) -> State {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: configURL) else { return .corrupt }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { return .corrupt }
        let servers = dict["mcpServers"] as? [String: Any] ?? [:]
        guard let entry = servers["maugham"] as? [String: Any],
              let cmd = entry["command"] as? String else {
            return .unconfigured
        }
        if cmd == expectedBinary { return .configured(path: cmd) }
        return .stalePath(currentPath: cmd)
    }
}
