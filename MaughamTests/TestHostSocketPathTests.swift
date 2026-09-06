import XCTest
import MaughamCore
@testable import Maugham

/// **A test host must not bind — or unlink — the socket the writer's own app
/// is listening on.**
///
/// The Mac gate hosts a full copy of the app in seven parallel worker
/// processes. Each one used to run the Welcome scene's `.task`, which starts
/// an `MCPServer` on `BuildVariant.current.mcpSocketPath`; `MCPServer.start()`
/// unlinks that path before binding, and `MaughamApp`'s `willTerminate`
/// observer unlinks it again on the way out. So a `./scripts/test.sh` run
/// while the developer had the dev app open **deleted the open app's socket
/// file** — the app kept its listening descriptor and never noticed, while
/// every freshly spawned compiler `claude -p` got
/// `mcp_servers: [{maugham-dev, failed}]` and the check came back "couldn't be
/// read as notes". Measured 2026-09-06 from Denver's smoke: the socket
/// directory's mtime matched the gate, and the bridge binary answered
/// "Maugham isn't running."
///
/// The decision lives in one place, `TestHost.mcpSocketPath`, and these pins
/// drive its pure core with an injected "is hosting" flag rather than the real
/// environment — a test cannot ask XCTest to stop injecting
/// `XCTestConfigurationFilePath`, and a pin that could only observe the
/// hosting arm would say nothing about the writer's own launch.
final class TestHostSocketPathTests: XCTestCase {

    private let production = "/Users/w/Library/Application Support/Maugham Dev/mcp.sock"
    private let temp = URL(fileURLWithPath: "/var/folders/xx/T", isDirectory: true)

    /// Outside a test host — the writer's own launch — the effective path is
    /// the variant's, unchanged. Anything else is a build where Claude Desktop
    /// and the app disagree about where to meet.
    func test_aWritersLaunchBindsTheVariantsOwnPath() {
        let path = TestHost.mcpSocketPath(
            production: production, isHosting: false, pid: 4242, temporaryDirectory: temp)

        XCTAssertEqual(path, production,
            "outside a test host nothing may move — the bridge and the setup sheet "
            + "both point at the variant's path")
    }

    /// Inside a test host the path is somewhere else entirely, and carries the
    /// pid, so seven workers of one gate cannot collide with each other either.
    func test_aTestHostBindsItsOwnPerProcessPath() {
        let path = TestHost.mcpSocketPath(
            production: production, isHosting: true, pid: 4242, temporaryDirectory: temp)

        XCTAssertNotEqual(path, production,
            "a gate that binds the production path unlinks the open dev app's socket")
        XCTAssertTrue(path.contains("4242"),
            "the pid is what keeps seven parallel workers off each other's socket; got \(path)")
        XCTAssertTrue(path.hasPrefix(temp.path),
            "a host's socket belongs in the temp directory, not in Application Support; "
            + "got \(path)")
        XCTAssertFalse(path.contains("Application Support"),
            "got \(path)")
    }

    /// Two workers of the same gate get two different paths. The pid is the
    /// only thing that varies between them, so this is the pin that would fail
    /// if the pid were ever dropped from the spelling.
    func test_twoWorkersOfOneGateGetTwoDifferentPaths() {
        let a = TestHost.mcpSocketPath(
            production: production, isHosting: true, pid: 1, temporaryDirectory: temp)
        let b = TestHost.mcpSocketPath(
            production: production, isHosting: true, pid: 2, temporaryDirectory: temp)

        XCTAssertNotEqual(a, b)
    }

    /// A `sockaddr_un.sun_path` holds 104 bytes on Darwin and `bind` fails —
    /// silently, from a writer's point of view — past it. The real temp root is
    /// long (`/var/folders/<2>/<30-odd>/T/`), so the host's spelling is checked
    /// against the real one rather than the short fixture above.
    func test_theHostsPathFitsInASocketAddress() {
        let path = TestHost.mcpSocketPath(
            production: production,
            isHosting: true,
            pid: 999_999,
            temporaryDirectory: FileManager.default.temporaryDirectory)

        XCTAssertLessThan(path.utf8.count, 104,
            "sun_path is 104 bytes on Darwin; got \(path.utf8.count) for \(path)")
    }

    /// The zero-argument property is what production reads, and in THIS process
    /// — an XCTest host — it must already be answering the hosting arm. This is
    /// the one pin that observes the real environment, and it is an
    /// implication rather than an equality: it says the wiring is live, not
    /// what the developer's temp root happens to be.
    func test_thisProcessIsAHostAndIsAnsweringTheHostArm() {
        XCTAssertTrue(TestHost.isActive,
            "this suite runs in an XCTest host by construction")
        XCTAssertNotEqual(TestHost.mcpSocketPath, BuildVariant.current.mcpSocketPath,
            "the live property must already be off the production path in this process")
    }
}
