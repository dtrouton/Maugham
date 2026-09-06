import Foundation

/// **One bounded sweep for the temp files two subsystems leave behind.**
///
/// Maugham writes two kinds of short-lived file into the machine's shared temp
/// root: the compiler's per-session `--mcp-config` JSON
/// (`ClaudeCLISession.sessionConfigDirectory`) and, in a test host, the MCP
/// socket that host binds instead of the writer's (`TestHost.mcpSocketPath`).
/// Both are removed by the process that made them — an orchestrator's
/// `shutdown()`/`detach()` for the config, `MaughamApp`'s `willTerminate`
/// observer for the socket — and neither removal is guaranteed. A `claude`
/// session whose owner is released without a shutdown, an app macOS kills
/// before the observer runs, a crash: each leaves a file nothing will ever
/// reclaim. By 2026-09-06 there were 235 config files going back days.
///
/// The floor is a whole day, and that is the load-bearing decision rather than
/// the deletion. Seven gate workers share this directory and a warm compiler
/// session lives as long as the writer keeps typing, so a sweep short enough
/// to reach a live peer's file would be a worse defect than the leak it
/// replaces: the config is what a running `claude -p` was spawned against, and
/// the socket is what a sibling worker is listening on. A day is longer than
/// any session and vastly longer than any gate.
enum StaleFileSweep {

    /// Nothing younger than this is ever touched. See the type's note.
    static let defaultAge: TimeInterval = 24 * 60 * 60

    /// Remove every entry directly inside `dir` whose name has both `prefix`
    /// and `suffix` and whose modification date is older than `age`. Answers
    /// what it removed, so a caller can report it. Never throws: a missing
    /// directory is the ordinary case on a fresh machine, and a file another
    /// process reaped between the listing and the delete is not news.
    @discardableResult
    static func sweep(
        in dir: URL,
        prefix: String,
        suffix: String,
        olderThan age: TimeInterval = defaultAge,
        now: Date = Date()
    ) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            // No `.skipsHiddenFiles`: a daemon that flags one of these
            // `UF_HIDDEN` (v0.32.1's cause) would otherwise make it
            // permanently unreapable. The prefix and suffix are the bound.
            options: [.skipsSubdirectoryDescendants])
        else { return [] }

        let cutoff = now.addingTimeInterval(-age)
        var removed: [URL] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            // A socket is not a regular file, so read the date through the
            // resource value rather than assuming `attributesOfItem` shape.
            guard let modified = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff
            else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }
}
