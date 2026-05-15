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

extension ClaudeDesktopConfig {
    public enum MergeError: Error {
        case existingConfigCorrupt
    }

    /// Atomically merge a `maugham` mcpServer entry into the config. Creates
    /// the file if absent. Throws if the existing file is unparseable JSON
    /// (we never overwrite content we don't understand).
    public static func merge(configURL: URL, maughamBinary: String) throws {
        let parent = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true)

        var dict: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            if data.isEmpty {
                dict = [:]
            } else if let any = try? JSONSerialization.jsonObject(with: data),
                      let parsed = any as? [String: Any] {
                dict = parsed
            } else {
                throw MergeError.existingConfigCorrupt
            }
        }
        var servers = dict["mcpServers"] as? [String: Any] ?? [:]
        servers["maugham"] = ["command": maughamBinary]
        dict["mcpServers"] = servers

        let out = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmpURL = configURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try out.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmpURL)
    }

    /// Remove the `maugham` entry from `mcpServers`, preserving other servers.
    public static func removeMaughamEntry(configURL: URL) throws {
        let data = try Data(contentsOf: configURL)
        guard let any = try? JSONSerialization.jsonObject(with: data),
              var dict = any as? [String: Any] else {
            throw MergeError.existingConfigCorrupt
        }
        var servers = dict["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: "maugham")
        dict["mcpServers"] = servers
        let out = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmpURL = configURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try out.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmpURL)
    }
}
