import Foundation

/// Resolves a project-relative path supplied by an untrusted sidecar — trash
/// `meta.json`'s `originalRelativePath`, a manifest research item's `path`,
/// an inbox entry's `sourceFilename` — into an absolute URL guaranteed to
/// stay inside `root`. A hostile or merely corrupted sidecar value carrying
/// an absolute path or a `..` escape could otherwise read or move files
/// anywhere on disk (A5). Callers wrap `resolve` in their own surface's loud
/// error (`MCPError`, a store's own `Error` enum, …) rather than depend on
/// `PathError` directly.
public enum SafeRelativePath {
    public enum PathError: Error, LocalizedError, Equatable {
        case emptyPath
        case absolutePath(String)
        case emptyComponent(String)
        case escapesRoot(String)

        public var errorDescription: String? {
            switch self {
            case .emptyPath:
                return "Relative path is empty"
            case .absolutePath(let path):
                return "Path must be relative, not absolute: \(path)"
            case .emptyComponent(let path):
                return "Path contains an empty component: \(path)"
            case .escapesRoot(let path):
                return "Path escapes the project root: \(path)"
            }
        }
    }

    /// Resolve `relative` under `root`. Throws for an empty path, an
    /// absolute path, a path with an empty component (`a//b`), or a path
    /// that, once `.`/`..` components are collapsed, nets outside `root`.
    ///
    /// `"a/../b.md"` is allowed — only a NET escape is rejected, since the
    /// containment check is what actually protects the filesystem; rejecting
    /// every literal `..` segment would also reject harmless paths that
    /// happen to net back inside.
    ///
    /// `root` may itself be reached through a symlink (e.g. macOS temp dirs,
    /// `/var` → `/private/var`) — it is resolved once up front via
    /// `resolvingSymlinksInPath()` so containment is checked against the
    /// canonical root, not the symlinked spelling. The relative portion is
    /// then only lexically standardized (`standardizedFileURL`, which
    /// collapses `.`/`..` without touching the filesystem) so this also
    /// works for destinations that don't exist yet (e.g. a trash-restore
    /// target). The containment comparison guards the root-path prefix with
    /// a trailing separator so a sibling directory that merely shares a
    /// string prefix (`/project-evil` vs `/project`) can't pass as contained.
    ///
    /// The returned URL is built from the ORIGINAL (unresolved) `root`, so
    /// callers see exactly the URL a bare `appendingPathComponent` would
    /// have produced — this only adds a containment gate on top.
    public static func resolve(_ relative: String, under root: URL) throws -> URL {
        guard !relative.isEmpty else { throw PathError.emptyPath }
        guard !relative.hasPrefix("/"), !relative.contains("\0") else {
            throw PathError.absolutePath(relative)
        }

        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty }) else {
            throw PathError.emptyComponent(relative)
        }

        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = canonicalRoot.appendingPathComponent(relative).standardizedFileURL

        var rootPrefix = canonicalRoot.path
        if !rootPrefix.hasSuffix("/") { rootPrefix += "/" }

        guard candidate.path.hasPrefix(rootPrefix) else {
            throw PathError.escapesRoot(relative)
        }

        return root.appendingPathComponent(relative)
    }
}
