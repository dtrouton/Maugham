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
}
