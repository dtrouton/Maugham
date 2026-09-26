import XCTest
import MaughamCore
@testable import Maugham

/// Pins the per-worker TestWorkspace leaf that keeps parallel test workers out
/// of each other's fixtures.
///
/// `TestWorkspace.reset()` deletes the whole workspace tree, and
/// `TestProjectToolsTests` resets inside seven of its tests. Under per-class
/// parallel workers a SHARED root meant one worker's reset deleted another
/// worker's live fixture mid-test (measured 2026-08-08: `test_checkpoint_…`
/// and `test_openProject_…` each failed one gate that way, both green in
/// isolation). If this suite ever sees the bare root again, that collision is
/// back — with a different victim every gate and no red test naming the cause.
final class TestWorkspaceIsolationTests: XCTestCase {

    func test_underXCTest_theWorkspaceRootIsPerProcess() {
        XCTAssertNotNil(
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"],
            "this test exists to pin the under-XCTest shape; if XCTest stops "
            + "setting this variable the seam needs a new discriminator, not "
            + "deletion")
        XCTAssertEqual(
            TestWorkspace.root.lastPathComponent,
            "xctest-worker-\(ProcessInfo.processInfo.processIdentifier)",
            "the workspace root has lost its per-worker leaf — a parallel "
            + "worker's reset() can once again delete another worker's live "
            + "fixture mid-test")
    }

    func test_resetOnlyTouchesThisWorkersLeaf() throws {
        // A sibling worker's tree, simulated: same parent, different leaf.
        let sibling = TestWorkspace.root
            .deletingLastPathComponent()
            .appendingPathComponent("xctest-worker-sibling-fixture")
        let fm = FileManager.default
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sibling) }
        let marker = sibling.appendingPathComponent("alive.txt")
        try Data("alive".utf8).write(to: marker)

        try TestWorkspace.reset()

        XCTAssertTrue(fm.fileExists(atPath: marker.path),
                      "reset() reached outside its own worker leaf and deleted "
                      + "a sibling worker's files — the cross-worker collision "
                      + "this seam exists to prevent")
    }

    /// `reset()` removes the leaf and does not make it again (plan 3's C17):
    /// every writer into the workspace creates what it writes into, so an empty
    /// leaf re-made at a test's end was the one thing each worker left behind.
    func test_resetLeavesNoLeafBehind() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: TestWorkspace.root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: TestWorkspace.root.appendingPathComponent("f.txt"))

        try TestWorkspace.reset()

        XCTAssertFalse(fm.fileExists(atPath: TestWorkspace.root.path),
            "reset() re-made an empty leaf that nothing will ever remove")
    }

    /// The test host's launch sweep removes a dead worker's leaf under BOTH
    /// per-process trees in Application Support, and keeps a live one.
    func test_theHostsLaunchSweepRemovesDeadWorkersLeavesAndKeepsLiveOnes() throws {
        let fm = FileManager.default
        // Asked FIRST: `DeviceState.directory` sweeps once a process on its
        // first use, and that sweep must not be what removes the planted leaf.
        let liveDevice = DeviceState.directory
        try fm.createDirectory(at: liveDevice, withIntermediateDirectories: true)
        // No process has this pid: macOS's pid_max is 99,998.
        let deadName = "xctest-worker-2000000000"
        var dead: [URL] = []
        for base in [TestWorkspace.base, DeviceState.base] {
            let leaf = base.appendingPathComponent(deadName, isDirectory: true)
            try fm.createDirectory(at: leaf, withIntermediateDirectories: true)
            try Data("blob".utf8).write(to: leaf.appendingPathComponent("device-key.blob"))
            dead.append(leaf)
        }
        defer { for leaf in dead { try? fm.removeItem(at: leaf) } }
        let liveWorkspace = TestWorkspace.root
        try fm.createDirectory(at: liveWorkspace, withIntermediateDirectories: true)
        defer { try? TestWorkspace.reset() }

        TestHost.sweepDeadWorkerLeaves()

        for leaf in dead {
            XCTAssertFalse(fm.fileExists(atPath: leaf.path),
                "a leaf whose process is gone is rubbish: \(leaf.path)")
        }
        XCTAssertTrue(fm.fileExists(atPath: liveWorkspace.path),
            "this worker's own workspace leaf is in use")
        XCTAssertTrue(fm.fileExists(atPath: liveDevice.path),
            "and so is its device leaf")
    }
}
