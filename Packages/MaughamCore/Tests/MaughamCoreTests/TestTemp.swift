// TestTemp.swift — the ONE temp root every test in this bundle builds under.
//
// Three byte-identical copies live in the three test targets (MaughamTests,
// MaughamPhoneTests, MaughamCoreTests); a test bundle cannot import another's
// sources, and XCTest cannot live in MaughamCore's production library.
// `TripwireGrepTests.test_theThreeTestTempFilesAreIdentical` keeps them one
// file in three places. The pid rule is NOT copied: it is
// `DeviceState.sweepDeadWorkerLeaves`, generalised by prefix.
//
// Why (signed op log P3 plan 3, Task 1): `$TMPDIR` reached 208,937 entries and
// its link-count cap, almost all of them this project's own test fixtures, and
// at 543,002 entries a launch-time enumeration of it hung whole gates. Every
// test named the machine's temp directory itself, so every fixture that forgot
// a `removeItem` — or whose `removeItem` raced an async write — lived for ever.
//
// The layout:
//
//     $TMPDIR/MaughamTests-worker-<pid>/            one per test PROCESS
//         <uuid>/                                   `root` — one per TEST
//         shared/                                   `workerRoot`
//
// - `root` is removed when its test finishes (`testCaseDidFinish`), whatever
//   the test did or forgot to do.
// - `workerRoot` is for fixtures built in `class func setUp()` and used across
//   every test in the class. It lives until the bundle ends.
// - The whole worker folder is removed at `testBundleDidFinish`.
// - A worker folder whose process is dead (a crash, a killed gate) is swept the
//   first time any later process in the same temp directory asks for a root.
//
// **Registration** is lazy, on the first `root`/`workerRoot` access in the
// process: there is no bundle-load hook in a SwiftPM test target, and one
// mechanism in all three bundles beats two. That access is always inside the
// test run (a class setUp, an instance setUp, a test body, or a test-case
// property initialiser at suite construction), so every later
// `testCaseDidFinish` and the `testBundleDidFinish` are observed.
//
// **What a test that has not started gets.** A root asked for before the test
// that will use it has STARTED — in `class func setUp()`, or in a stored
// property's initialiser, which XCTest runs for every test of a class when it
// builds the suite — is set loose at the next `testCaseWillStart` rather than
// deleted: it lives until the bundle ends, exactly like `workerRoot`. So a
// class-level fixture is never deleted between tests even where it was written
// against `root`; `workerRoot` is still the right spelling, because it says so.
//
// Swift Testing (`@Test`) sends no XCTest observation. None of these bundles
// has a Swift Testing test; if one is added, its roots live until the process
// ends and the next process's dead-worker sweep removes them.

import Foundation
import XCTest
@testable import MaughamCore

enum TestTemp {
    /// This test's own temp root, created on first use and removed when the
    /// test finishes. Build every fixture under it.
    static var root: URL { TestTempSession.shared.root() }

    /// A root shared by every test in this process, for fixtures built once in
    /// `class func setUp()`. Removed when the bundle ends.
    static var workerRoot: URL { TestTempSession.shared.workerRoot() }

    /// The name every per-process folder starts with.
    static let workerFolderPrefix = "MaughamTests-worker-"

    /// Remove every `MaughamTests-worker-<pid>` folder under `base` whose
    /// process is gone. `DeviceState`'s pid rule, with this tree's prefix.
    static func sweepDeadWorkers(
        in base: URL,
        isAlive: ((Int32) -> Bool)? = nil
    ) {
        if let isAlive {
            DeviceState.sweepDeadWorkerLeaves(
                in: base, prefix: workerFolderPrefix, isAlive: isAlive)
        } else {
            DeviceState.sweepDeadWorkerLeaves(in: base, prefix: workerFolderPrefix)
        }
    }
}

/// The state behind `TestTemp`, and the observer that clears it. Internal so
/// `TestTempTests` can drive a private session through a fake lifecycle.
final class TestTempSession: NSObject, XCTestObservation, @unchecked Sendable {

    static let shared = TestTempSession(
        workerFolder: FileManager.default.temporaryDirectory.appendingPathComponent(
            TestTemp.workerFolderPrefix + "\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true),
        registers: true)

    let workerFolder: URL
    private let registers: Bool
    private let lock = NSLock()
    private var registered = false
    private var current: URL?

    init(workerFolder: URL, registers: Bool = false) {
        self.workerFolder = workerFolder
        self.registers = registers
    }

    func root() -> URL {
        registerIfNeeded()
        lock.lock(); defer { lock.unlock() }
        if let current { return current }
        let url = workerFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        current = url
        return url
    }

    func workerRoot() -> URL {
        registerIfNeeded()
        let url = workerFolder.appendingPathComponent("shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: XCTestObservation

    func testCaseWillStart(_ testCase: XCTestCase) {
        // Whatever was made before this test started belongs to the worker.
        lock.lock(); current = nil; lock.unlock()
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        lock.lock()
        let finished = current
        current = nil
        lock.unlock()
        if let finished { try? FileManager.default.removeItem(at: finished) }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        lock.lock(); current = nil; lock.unlock()
        try? FileManager.default.removeItem(at: workerFolder)
    }

    // MARK: Registration

    private func registerIfNeeded() {
        guard registers else { return }
        lock.lock()
        let first = !registered
        registered = true
        lock.unlock()
        guard first else { return }
        // XCTest drives its observers from the main thread; add ours there.
        if Thread.isMainThread {
            XCTestObservationCenter.shared.addTestObserver(self)
        } else {
            DispatchQueue.main.async { XCTestObservationCenter.shared.addTestObserver(self) }
        }
        // Yesterday's crashed or killed workers. Off this thread: `$TMPDIR` is
        // the whole machine's, and its size is not ours to bound.
        let base = workerFolder.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).async {
            TestTemp.sweepDeadWorkers(in: base)
        }
    }
}
