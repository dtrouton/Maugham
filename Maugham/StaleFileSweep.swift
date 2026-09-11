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

    /// **How many entries one sweep will look at.**
    ///
    /// The sweep's own cost has to be bounded by something other than the size
    /// of a directory it does not own. `$TMPDIR` is shared with every process
    /// on the machine, and by 2026-09-10 this one held 543,002 entries — at
    /// which point `contentsOfDirectory` materialising the whole listing was
    /// measured (P2b Task 10) as the cause of the *hung before establishing
    /// connection* family: it ran inside `MaughamApp.init()`, on the main
    /// thread, before an XCTest worker could connect, and the worker was
    /// killed waiting for it.
    ///
    /// A cap makes the sweep opportunistic rather than exhaustive, which is
    /// the right trade for a reaper of yesterday's orphans: the next launch
    /// sweeps again, and a directory big enough to exhaust one budget is one
    /// where nothing this process does in half a second is going to matter.
    static let defaultEntryBudget = 2_000

    /// And how long, whatever the count. Two bounds rather than one because
    /// they fail differently: a directory of many small entries is bounded by
    /// the count, and one on a stalled network or iCloud mount is bounded by
    /// the clock while the count is still low.
    static let defaultTimeBudget: TimeInterval = 0.25

    /// Remove every entry directly inside `dir` whose name has both `prefix`
    /// and `suffix` and whose modification date is older than `age`. Answers
    /// what it removed, so a caller can report it. Never throws: a missing
    /// directory is the ordinary case on a fresh machine, and a file another
    /// process reaped between the listing and the delete is not news.
    ///
    /// **Bounded, and lazily enumerated** (whole-branch review, I4). It stops
    /// after `entryBudget` entries or `timeBudget` seconds, whichever comes
    /// first, and sweeps only what it saw. `FileManager.enumerator` is what
    /// makes the bound mean anything: `contentsOfDirectory` builds the entire
    /// listing before the first `hasPrefix` runs, so a cap applied to its
    /// result would have paid the whole cost and then declined to use it.
    @discardableResult
    static func sweep(
        in dir: URL,
        prefix: String,
        suffix: String,
        olderThan age: TimeInterval = defaultAge,
        now: Date = Date(),
        entryBudget: Int = defaultEntryBudget,
        timeBudget: TimeInterval = defaultTimeBudget
    ) -> [URL] {
        let fm = FileManager.default
        guard entryBudget > 0, timeBudget > 0 else { return [] }
        guard let entries = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            // No `.skipsHiddenFiles`: a daemon that flags one of these
            // `UF_HIDDEN` (v0.32.1's cause) would otherwise make it
            // permanently unreapable. The prefix and suffix are the bound.
            options: [.skipsSubdirectoryDescendants],
            errorHandler: nil)
        else { return [] }

        let cutoff = now.addingTimeInterval(-age)
        let deadline = Date().addingTimeInterval(timeBudget)
        var removed: [URL] = []
        var seen = 0
        for case let url as URL in entries {
            seen += 1
            if seen > entryBudget { break }
            // Checked every so often rather than per entry: `Date()` is a
            // syscall and the point of the clock bound is a directory that is
            // slow, not one that is merely large.
            if seen % 64 == 0, Date() >= deadline { break }
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
