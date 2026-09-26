import Foundation

public enum TestWorkspaceError: Error, Equatable {
    case outsideWorkspace(String)
}

/// Dev-only throwaway root for automated test projects. Mutating test MCP
/// tools fence every target URL through `require(_:)` so they can never touch
/// the writer's real manuscripts (which live in ~/Documents).
public enum TestWorkspace {
    /// `~/Library/Application Support/<supportFolderName>/TestWorkspace` —
    /// plus a per-process leaf under XCTest, and ONLY under XCTest.
    /// Uses the same support-folder idiom as `BuildVariant.mcpSocketPath`.
    ///
    /// **Why the leaf:** the parallel test suite runs classes across worker
    /// PROCESSES, `reset()` deletes this entire tree, and `TestProjectToolsTests`
    /// resets in seven of its tests — so a shared root means one worker's reset
    /// deletes another worker's live fixture mid-test. Measured 2026-08-08, first
    /// parallel gates: `test_checkpoint_capturesAndReportsCount` failed at 0.131s
    /// (fixture gone from under it) and `test_openProject_returnsDocIdsFromDisk`
    /// the same way in another run — a different victim each gate, every one
    /// green in isolation. A per-worker leaf gives each process its own tree, so
    /// a reset can only ever hit the resetter's own fixtures. The live app
    /// (Claude Desktop driving the dev build's test tools) is one process and
    /// keeps the bare root, unchanged.
    public static var root: URL {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return base
        }
        return base.appendingPathComponent(
            "xctest-worker-\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// The workspace directory itself — the live app's root, and the parent
    /// of every `xctest-worker-<pid>` leaf.
    public static var base: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Application Support")
            .appendingPathComponent(BuildVariant.current.supportFolderName)
            .appendingPathComponent("TestWorkspace")
    }

    /// Remove the leaves of test workers that are gone — `DeviceState`'s pid
    /// rule over this tree (plan 3's C17: 943 leaves had piled up here, one per
    /// worker of every gate, because nothing ever removed one). Never the bare
    /// root's own projects, and never a live worker's leaf.
    public static func sweepDeadWorkerLeaves() {
        DeviceState.sweepDeadWorkerLeaves(in: base)
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

    /// Delete everything under the workspace root, the root included. Only
    /// ever touches paths under `root`.
    ///
    /// It does not recreate the root empty (plan 3's C17): every writer into
    /// the workspace creates the directories it writes into
    /// (`TestCreateProjectTool` creates the root, `ProjectFactory` creates with
    /// intermediates), and an empty leaf re-made at the end of a test was the
    /// one thing each worker was sure to leave behind.
    public static func reset() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }
}
