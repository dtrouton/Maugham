import Foundation

public enum TestWorkspaceError: Error, Equatable {
    case outsideWorkspace(String)
}

/// Dev-only throwaway root for automated test projects. Mutating test MCP
/// tools fence every target URL through `require(_:)` so they can never touch
/// the writer's real manuscripts (which live in ~/Documents).
public enum TestWorkspace {
    /// `~/Library/Application Support/<supportFolderName>/TestWorkspace`.
    /// Uses the same support-folder idiom as `BuildVariant.mcpSocketPath`.
    public static var root: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib
            .appendingPathComponent("Application Support")
            .appendingPathComponent(BuildVariant.current.supportFolderName)
            .appendingPathComponent("TestWorkspace")
    }

    /// Throw unless `url` is `root` itself or a descendant. Compares resolved
    /// path components (not string prefixes) so `<root>Evil` can't slip past.
    public static func require(_ url: URL) throws {
        let rootComps = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlComps = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlComps.count >= rootComps.count,
              Array(urlComps.prefix(rootComps.count)) == rootComps else {
            throw TestWorkspaceError.outsideWorkspace(url.path)
        }
    }

    /// Delete everything under the workspace root (creating a clean, empty
    /// root). Only ever touches paths under `root`.
    public static func reset() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
