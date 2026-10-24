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
        case notAPlainFileName(String)
        case notADocId(String)

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
            case .notAPlainFileName(let name):
                return "Not one plain file name: \(name.debugDescription)"
            case .notADocId(let id):
                return "Not a document id that can name a file: \(id.debugDescription)"
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
    ///
    /// This is a LEXICAL check: `standardizedFileURL` collapses `.`/`..`
    /// segments in the path string without touching the filesystem, so it
    /// cannot see a symlink planted somewhere inside the relative subtree
    /// itself (as opposed to `root`, which IS resolved). A legitimately-
    /// spelled relative path whose leaf — or an intermediate component — is,
    /// on disk, a symlink pointing outside `root` will pass this check, and
    /// a caller that then opens the returned URL for I/O can still be
    /// redirected outside `root` at open time. A caller for whom that
    /// distinction matters should re-verify after resolving: call
    /// `resolvingSymlinksInPath()` on the returned URL and re-check
    /// containment immediately before the actual read/write/move. None of
    /// its call sites need that (count them with a grep rather than trusting
    /// a number here) — they
    /// all operate within a project tree the user already has local write
    /// access to, so planting such a symlink requires the same access this
    /// check exists to withhold from an untrusted sidecar value. The A5
    /// audit (2026-07-11) scored this gap Low and deferred it.
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

    /// **Is `name` one plain file name** — non-empty, no `/`, `\` or NUL,
    /// and not dot-leading (so never `.` or `..`, and never a hidden file)?
    /// Such a name joined onto a folder stays in that folder. The one rule
    /// for a name that arrives in synced data (an op payload, a manifest
    /// record) and becomes a file name: `FigureImageRef.isAPlainFileName`
    /// and `FigureRender.renderPath` ask it.
    public static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    /// **One plain file name inside one project-relative folder**:
    /// `<root>/<folder>/<name>`. Throws `.notAPlainFileName` unless
    /// `isPlainFileName(name)`, and whatever `resolve(_:under:)` throws for
    /// `folder`. Unlike `resolve`, the folder is also checked on disk: its
    /// deepest existing ancestor is resolved through any symlinks and the
    /// rest of the folder appended, and a result outside `root` throws
    /// `.escapesRoot` — so `figures` linked outside the root is refused even
    /// when `figures/sub` does not exist yet, and a file written to the
    /// returned URL lands inside the root. The returned URL is built from the
    /// original `root`.
    public static func resolveFile(
        named name: String, in folder: String, under root: URL
    ) throws -> URL {
        guard isPlainFileName(name) else { throw PathError.notAPlainFileName(name) }
        let folderURL = try resolve(folder, under: root)
        var rootPrefix = root.resolvingSymlinksInPath().standardizedFileURL.path
        if !rootPrefix.hasSuffix("/") { rootPrefix += "/" }
        guard (canonicalPath(of: folderURL) + "/").hasPrefix(rootPrefix) else {
            throw PathError.escapesRoot(folder)
        }
        return folderURL.appendingPathComponent(name)
    }

    /// `url` with its deepest existing ancestor resolved through symlinks and
    /// the not-yet-existing remainder appended. An entry counts as existing
    /// when it is there itself, even a symlink whose target is missing
    /// (`attributesOfItem` does not follow the last link).
    private static func canonicalPath(of url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        let fm = FileManager.default
        while (try? fm.attributesOfItem(atPath: existing.path)) == nil, existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in missing { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL.path
    }

    /// **`id`, when it becomes part of a file name**: today the op log's
    /// `<docId>.<slug>.jsonl` and sealed segments (`OpLogFiles`) and a
    /// quarantine record (`IntegrityQuarantine.record`). The rule of
    /// `isPlainFileName` plus no `.` at all: a doc id comes from synced data
    /// (a manifest record, an op, an MCP argument), one carrying a `/` or a
    /// leading `..` would climb out of its folder, and the read side
    /// (`OpLogFiles.docId(fromOpLogFilename:)`, which cuts at the first dot)
    /// already assumes an id has no dot. Every id the apps mint passes
    /// (`doc-<hex>`, `scene-<hex>`, `d_…`, `fig-…`, `stmt-…`, `res-…`,
    /// `__project__`). Throws `.notADocId`.
    @discardableResult
    public static func requireDocId(_ id: String) throws -> String {
        guard isPlainFileName(id), !id.contains(".") else { throw PathError.notADocId(id) }
        return id
    }
}
