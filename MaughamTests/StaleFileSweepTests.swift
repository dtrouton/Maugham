import XCTest
@testable import Maugham

/// **The one bounded sweep two leaks share.**
///
/// Both the compiler's per-session `--mcp-config` files and a test host's own
/// MCP socket live in the machine's shared temp root, and both are removed by
/// the process that made them — on `shutdown()`/`detach()` for the config, at
/// `willTerminate` for the socket. Neither removal is guaranteed: a crashed
/// `claude` session, an orchestrator released without a shutdown, an app macOS
/// kills before the observer runs. What is left behind is a dead file nothing
/// will ever reclaim, and 235 of them had accumulated by 2026-09-06.
///
/// The floor is deliberately a whole day. The point is not tidiness — it is
/// that a sweep short enough to reach a LIVE peer's file is worse than the
/// leak: seven gate workers share this directory, and a compiler session can
/// sit warm between a writer's keystrokes for as long as they are writing.
final class StaleFileSweepTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-sweep-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, ageInHours: Double) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url, options: .atomic)
        let when = Date().addingTimeInterval(-ageInHours * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: when], ofItemAtPath: url.path)
        return url
    }

    /// The whole contract in one case: what is old goes, what is fresh stays,
    /// and a file that is neither this prefix nor this suffix is not ours to
    /// delete however old it is.
    func test_theSweepTakesTheOldAndLeavesEverythingElse() throws {
        let old = try write("compiler-mcp-\(UUID().uuidString).json", ageInHours: 48)
        let fresh = try write("compiler-mcp-\(UUID().uuidString).json", ageInHours: 1)
        let foreign = try write("someone-elses-ancient.json", ageInHours: 500)
        let wrongSuffix = try write("compiler-mcp-old.txt", ageInHours: 500)

        let removed = StaleFileSweep.sweep(
            in: dir, prefix: "compiler-mcp-", suffix: ".json")

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: old.path),
            "a config a crashed session left behind a day ago is the only thing that "
            + "can be here")
        XCTAssertTrue(fm.fileExists(atPath: fresh.path),
            "a fresh file belongs to a live session — deleting it is worse than the leak")
        XCTAssertTrue(fm.fileExists(atPath: foreign.path),
            "the sweep is bounded by prefix; another tool's temp file is not ours")
        XCTAssertTrue(fm.fileExists(atPath: wrongSuffix.path),
            "…and by suffix")
        XCTAssertEqual(removed.map(\.lastPathComponent), [old.lastPathComponent],
            "the sweep reports what it took, so a caller can say so")
    }

    /// The socket half of the same job. A `.sock` is not a regular file and
    /// the sweep must still reach it, or fix 1's own per-process sockets
    /// become the next 235-file directory.
    func test_theSweepReachesASocketAsWellAsAFile() throws {
        let old = dir.appendingPathComponent("maugham-host-4242.sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        old.path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strlcpy(
                    UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self),
                    src, MemoryLayout.size(ofValue: dst.pointee))
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try XCTSkipUnless(bound == 0, "could not bind a fixture socket (errno \(errno))")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-48 * 3600)],
            ofItemAtPath: old.path)

        let removed = StaleFileSweep.sweep(
            in: dir, prefix: "maugham-host-", suffix: ".sock")

        XCTAssertEqual(removed.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    /// A directory that does not exist is the ordinary case on a fresh
    /// machine, and it is not an error.
    func test_anAbsentDirectorySweepsNothingAndDoesNotThrow() {
        let missing = dir.appendingPathComponent("never-made", isDirectory: true)

        XCTAssertTrue(StaleFileSweep.sweep(
            in: missing, prefix: "compiler-mcp-", suffix: ".json").isEmpty)
    }

    /// The default floor is a whole day, stated once. A caller that wanted a
    /// shorter one would be reaching for a live peer's file.
    func test_theDefaultFloorIsADay() {
        XCTAssertEqual(StaleFileSweep.defaultAge, 24 * 60 * 60)
    }
}
