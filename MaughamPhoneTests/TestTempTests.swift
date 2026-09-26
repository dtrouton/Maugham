// TestTempTests.swift — the lifecycle `TestTemp` promises, pinned in both
// directions (plan 3's Review Focus 5): a per-test root is gone once its test
// finishes, and a class-level fixture survives every test of its class.
// Byte-identical in the three test targets, like `TestTemp.swift` itself.

import Foundation
import XCTest
@testable import MaughamCore

/// A private session driven through a fake lifecycle — the observer's rules,
/// with no dependence on which process ran which test.
final class TestTempSessionTests: XCTestCase {

    private var session: TestTempSession!

    override func setUp() {
        super.setUp()
        session = TestTempSession(workerFolder: TestTemp.root
            .appendingPathComponent(TestTemp.workerFolderPrefix + "1", isDirectory: true))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func plant(in dir: URL) throws -> URL {
        let file = dir.appendingPathComponent("fixture.txt")
        try Data("words".utf8).write(to: file)
        return file
    }

    func test_aTestsRootIsRemovedWhenTheTestFinishes() throws {
        session.testCaseWillStart(self)
        let root = session.root()
        XCTAssertEqual(session.root(), root, "one root for the whole test")
        let file = try plant(in: root)

        session.testCaseDidFinish(self)

        XCTAssertFalse(exists(file), "the fixture went with its test")
        XCTAssertFalse(exists(root), "and so did the test's own folder")
        session.testCaseWillStart(self)
        XCTAssertNotEqual(session.root(), root, "the next test gets a root of its own")
    }

    func test_theWorkerRootSurvivesEveryTestAndGoesWithTheBundle() throws {
        let shared = session.workerRoot()
        let file = try plant(in: shared)

        for _ in 0..<3 {
            session.testCaseWillStart(self)
            _ = session.root()
            session.testCaseDidFinish(self)
        }
        XCTAssertTrue(exists(file), "a class fixture outlives every test of its class")

        session.testBundleDidFinish(Bundle(for: Self.self))
        XCTAssertFalse(exists(file))
        XCTAssertFalse(exists(session.workerFolder), "the worker's whole folder goes at bundle end")
    }

    /// A root asked for before its test started — `class func setUp()`, or a
    /// stored property's initialiser at suite construction — is the class's,
    /// not the first test's.
    func test_aRootAskedForBeforeATestStartsIsNotTheFirstTestsToDelete() throws {
        let early = session.root()
        let file = try plant(in: early)

        session.testCaseWillStart(self)
        let own = session.root()
        XCTAssertNotEqual(own, early, "the test that starts gets its own root")
        session.testCaseDidFinish(self)

        XCTAssertTrue(exists(file), "the class-level root survives the first test")
        XCTAssertFalse(exists(own))
        session.testBundleDidFinish(Bundle(for: Self.self))
        XCTAssertFalse(exists(file), "and goes with the bundle")
    }

    func test_aDeadWorkersFolderIsSweptAndALiveOneKept() throws {
        let base = TestTemp.root.appendingPathComponent("tmpdir", isDirectory: true)
        let fm = FileManager.default
        func folder(_ name: String) throws -> URL {
            let url = base.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            _ = try plant(in: url)
            return url
        }
        let dead = try folder(TestTemp.workerFolderPrefix + "424242")
        let alive = try folder(TestTemp.workerFolderPrefix
            + "\(ProcessInfo.processInfo.processIdentifier)")
        let legacy = try folder("MaughamTests-\(UUID().uuidString)")
        let device = try folder("xctest-worker-424242")

        TestTemp.sweepDeadWorkers(in: base, isAlive: { $0 != 424242 })

        XCTAssertFalse(exists(dead), "a worker folder whose process is gone is rubbish")
        XCTAssertTrue(exists(alive), "a live worker's folder is in use")
        XCTAssertTrue(exists(legacy), "a name with no readable pid is left alone")
        XCTAssertTrue(exists(device), "another tree's prefix is not this sweep's")
    }
}

/// The dead-worker sweep lists the machine's whole temp directory, so it runs
/// at most once in ten minutes across every process that asks.
final class TestTempSweepThrottleTests: XCTestCase {
    func test_oneSweepInTenMinutesWhateverTheNumberOfProcesses() {
        let stamp = TestTemp.root.appendingPathComponent("sweep.stamp")
        let start = Date()
        XCTAssertTrue(TestTempSession.claimSweep(stamp: stamp, now: start), "the first asks")
        XCTAssertFalse(TestTempSession.claimSweep(stamp: stamp, now: start.addingTimeInterval(5)),
            "the next process in the same gate does not list the directory again")
        XCTAssertTrue(TestTempSession.claimSweep(stamp: stamp, now: start.addingTimeInterval(601)),
            "a later gate does")
    }
}

/// The real observer, end to end. XCTest runs a class's tests in name order in
/// one process; where a runner hosts each test in a process of its own
/// (`swift test --parallel`), the second test has nothing to compare and skips.
final class TestTempLifecycleTests: XCTestCase {

    private static var classFixture: URL?
    private static var firstTestsRoot: (pid: Int32, url: URL)?

    override class func setUp() {
        super.setUp()
        let url = TestTemp.workerRoot.appendingPathComponent(
            "class-fixture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        classFixture = url
    }

    func test_1_recordsItsRoot() throws {
        let root = TestTemp.root
        try Data("x".utf8).write(to: root.appendingPathComponent("f.txt"))
        Self.firstTestsRoot = (ProcessInfo.processInfo.processIdentifier, root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.classFixture!.path))
    }

    func test_2_theFirstTestsRootIsGoneAndTheClassFixtureIsNot() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.classFixture!.path),
            "a class-level fixture survives between tests")
        guard let first = Self.firstTestsRoot,
              first.pid == ProcessInfo.processInfo.processIdentifier else {
            throw XCTSkip("test_1 ran in another process")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path),
            "the previous test's root was removed when it finished")
        XCTAssertNotEqual(TestTemp.root, first.url)
    }
}
