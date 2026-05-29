import Foundation
import MaughamCore

/// Detects and mutates Claude Desktop's config file. Variant-aware via the
/// optional `serverKey` parameter on each entry point — defaults to the
/// current build variant's MCP server key.
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

    public static func detect(
        configURL: URL,
        expectedBinary: String,
        serverKey: String = BuildVariant.current.mcpServerKey
    ) -> State {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: configURL) else { return .corrupt }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { return .corrupt }
        let servers = dict["mcpServers"] as? [String: Any] ?? [:]
        guard let entry = servers[serverKey] as? [String: Any],
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

    /// Atomically merge a server entry into the config. Creates the file if
    /// absent. Throws if the existing file is unparseable JSON.
    ///
    /// `socketPath` (if non-nil) is written as `"env": ["MAUGHAM_MCP_SOCKET": <path>]`
    /// so the embedded binary doesn't rely on its hardcoded default.
    public static func merge(
        configURL: URL,
        maughamBinary: String,
        serverKey: String = BuildVariant.current.mcpServerKey,
        socketPath: String? = nil
    ) throws {
        let parent = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

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
        var entry: [String: Any] = ["command": maughamBinary]
        if let socketPath {
            entry["env"] = ["MAUGHAM_MCP_SOCKET": socketPath]
        }
        servers[serverKey] = entry
        dict["mcpServers"] = servers

        let out = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmpURL = configURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try out.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmpURL)
    }

    /// Remove this variant's entry from `mcpServers`, preserving other servers.
    public static func removeMaughamEntry(
        configURL: URL,
        serverKey: String = BuildVariant.current.mcpServerKey
    ) throws {
        let data = try Data(contentsOf: configURL)
        guard let any = try? JSONSerialization.jsonObject(with: data),
              var dict = any as? [String: Any] else {
            throw MergeError.existingConfigCorrupt
        }
        var servers = dict["mcpServers"] as? [String: Any] ?? [:]
        servers.removeValue(forKey: serverKey)
        dict["mcpServers"] = servers
        let out = try JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        let tmpURL = configURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try out.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmpURL)
    }
}
