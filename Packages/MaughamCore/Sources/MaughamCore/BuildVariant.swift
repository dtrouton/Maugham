import Foundation

/// Stable vs. Dev build differentiation. Drives all variant-aware identity
/// (display name, support folder, MCP socket path, Claude Desktop config key,
/// MCP serverInfo.name, updater enabled).
///
/// See docs/superpowers/specs/2026-05-22-production-release-design.md §3.1.
public enum BuildVariant: Equatable {
    case stable
    case dev

    public static let current: BuildVariant = {
        #if MAUGHAM_DEV_BUILD
        return .dev
        #else
        return .stable
        #endif
    }()

    public var displayName: String       { self == .dev ? "Maugham Dev" : "Maugham" }
    public var supportFolderName: String { self == .dev ? "Maugham Dev" : "Maugham" }
    public var mcpServerKey: String      { self == .dev ? "maugham-dev" : "maugham" }
    public var updaterEnabled: Bool      { self == .stable }

    public var mcpSocketPath: String {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib
            .appendingPathComponent("Application Support")
            .appendingPathComponent(supportFolderName)
            .appendingPathComponent("mcp.sock")
            .path
    }
}
