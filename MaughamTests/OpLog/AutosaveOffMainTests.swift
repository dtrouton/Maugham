import XCTest
@testable import Maugham
@testable import MaughamCore

/// Typing loop plan 1, Task 2: `performAutosave` renders and writes off the
/// main actor, and keeps every data-safety property it had on it. Writes are
/// gated, failed or observed through `Document.autosaveWriteHook`; no test
/// waits on a timer for an effect.
@MainActor
final class AutosaveOffMainTests: XCTestCase {

    // MARK: - Fixture

    private func makeDoc(body: String = "Opening line.\n") async throws -> Document {
        let projectURL = TestTemp.root
            .appendingPathComponent("autosave-off-main-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let url = projectURL.appendingPathComponent("manuscript/piece.md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return try await Document.load(
            url: url, device: "autosave-mac", session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
    }

    private func onDisk(_ doc: Document) throws -> String {
        try String(contentsOf: doc.url, encoding: .utf8)
    }

    private func cleanRender(_ doc: Document) -> String {
        MarkdownDisplayFilter.stripAnchors(doc.materialize())
    }

    /// Lets the main actor run queued work until `condition` holds. Not a
    /// timer: the condition is a counter the code under test moves.
    private func yieldUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("never happened: \(what)")
    }

    // MARK: - Tests

    func test_theRenderAndWriteRunOffTheMainThread() async throws {
        let doc = try await makeDoc()
        let gate = WriteGate()
        doc.autosaveWriteHook = gate.hook
        doc.setFullText("Written from a worker thread.")
        try await doc.performAutosave()
        XCTAssertEqual(gate.mainThreadFlags, [false],
            "the .md write must run off the main thread")
        XCTAssertEqual(try onDisk(doc), cleanRender(doc))
    }

    func test_twoAutosavesLandInOrder_andTheOlderNeverReplacesTheNewer() async throws {
        let doc = try await makeDoc()
        let gate = WriteGate(hold: [1])
        doc.autosaveWriteHook = gate.hook

        doc.setFullText("First text.")
        let first = Task { try await doc.performAutosave() }
        await gate.waitForEntry(1)

        doc.setFullText("Second text.")
        let second = Task { try await doc.performAutosave() }
        await yieldUntil("the second autosave is queued") { doc.autosaveRunsQueued == 2 }
        // Give an unserialised second write every chance to overtake the held
        // first one. Asserts an absence, so a correct build can never fail it;
        // this is where the disable experiment (no run queue) goes red.
        let overtook = await gate.waitForEntry(2, bound: .milliseconds(300), expected: false)
        XCTAssertFalse(overtook, "the second write must wait for the first to land")

        gate.release(1)
        try await first.value
        try await second.value

        XCTAssertEqual(try onDisk(doc), cleanRender(doc))
        XCTAssertTrue(try onDisk(doc).contains("Second text."),
            "the older snapshot must never land over the newer one")
        XCTAssertEqual(doc.lastDiskEcho.bytes, try onDisk(doc))
    }

    func test_aCallbackForThePreviousWriteWhileTheNextIsInFlightIsOurOwn() async throws {
        let doc = try await makeDoc()
        let gate = WriteGate(hold: [2])
        doc.autosaveWriteHook = gate.hook

        doc.setFullText("Write one.")
        try await doc.performAutosave()
        let writeOne = try onDisk(doc)

        doc.setFullText("Write two.")
        let second = Task { try await doc.performAutosave() }
        await gate.waitForEntry(2)
        let writeTwo = cleanRender(doc)

        // A presenter callback for write one, arriving while write two is held.
        let callbackOne = await deliverCallback(writeOne, to: doc)
        // The writer types on; a callback carrying write two's bytes (the ones
        // in flight) is ours too, though they now match neither the landed
        // echo nor the current render.
        doc.setFullText("Write three.")
        let callbackTwo = await deliverCallback(writeTwo, to: doc)

        XCTAssertEqual(doc.displayText, "Write three.")
        XCTAssertEqual(conflictBackups(of: doc), [],
            "our own bytes, landed or in flight, must never be taken for an outside edit")

        gate.release(2)
        try await callbackOne.value
        try await callbackTwo.value
        try await second.value
        XCTAssertEqual(doc.lastDiskEcho.bytes, writeTwo)
        XCTAssertEqual(try onDisk(doc), writeTwo)
    }

    func test_aFailedWriteThrows_leavesTheEchoOnTheLandedBytes_andTheNextOneWrites() async throws {
        let doc = try await makeDoc()
        let gate = WriteGate(fail: [2])
        doc.autosaveWriteHook = gate.hook

        doc.setFullText("Landed.")
        try await doc.performAutosave()
        let landed = try onDisk(doc)

        doc.setFullText("Never landed.")
        do {
            try await doc.performAutosave()
            XCTFail("a failed write must throw out of performAutosave")
        } catch {}
        XCTAssertEqual(try onDisk(doc), landed)
        XCTAssertEqual(doc.lastDiskEcho.bytes, landed,
            "the echo must describe what is really on disk")
        XCTAssertFalse(doc.lastDiskEcho.isOurOwn(cleanRender(doc)),
            "the failed write's bytes must be dropped from the echo")

        doc.setFullText("Written after the failure.")
        try await doc.performAutosave()
        XCTAssertEqual(try onDisk(doc), cleanRender(doc))
        XCTAssertTrue(try onDisk(doc).contains("Written after the failure."))
    }

    func test_closeAwaitsTheWriteInFlight_andNothingWritesAfter() async throws {
        let doc = try await makeDoc()
        let gate = WriteGate(hold: [1])
        doc.autosaveWriteHook = gate.hook

        doc.setFullText("Held write.")
        let held = Task { try await doc.performAutosave() }
        await gate.waitForEntry(1)

        // The writer's last words: scheduled, so close's flush owes them a write.
        doc.setFullText("The last text.")
        let expected = cleanRender(doc)
        let close = Task { () -> Int in
            await doc.close()
            return gate.completedWrites
        }
        await yieldUntil("close queues its trailing autosave") { doc.autosaveRunsQueued == 2 }
        XCTAssertFalse(doc.isClosed, "close must not husk while a write is in flight")

        gate.release(1)
        try await held.value
        let completedWhenCloseReturned = await close.value

        XCTAssertEqual(completedWhenCloseReturned, 2)
        XCTAssertEqual(try onDisk(doc), expected)
        try await doc.performAutosave()
        XCTAssertEqual(gate.enteredWrites, 2, "nothing writes after close() returns")
        XCTAssertEqual(try onDisk(doc), expected)
    }

    func test_closeWithNothingPendingStillAwaitsTheWriteInFlight() async throws {
        let doc = try await makeDoc()
        let gate = WriteGate(hold: [1])
        doc.autosaveWriteHook = gate.hook

        // The scheduler's own run is the one held — as when its 750 ms timer
        // fired — so it holds no payload, and close's `flush()` finds nothing.
        doc.setFullText("Only write.")
        let expected = cleanRender(doc)
        let held = Task { await doc.autosaveScheduler.flush() }
        await gate.waitForEntry(1)

        let close = Task { () -> Int in
            await doc.close()
            return gate.completedWrites
        }
        await yieldUntil("close starts") { doc.closeBodyRuns == 1 }
        for _ in 0..<200 { await Task.yield() }
        XCTAssertFalse(doc.isClosed, "close must not husk while a write is in flight")

        gate.release(1)
        await held.value
        let completedWhenCloseReturned = await close.value
        XCTAssertEqual(completedWhenCloseReturned, 1)
        XCTAssertEqual(gate.enteredWrites, 1)
        XCTAssertEqual(try onDisk(doc), expected)
    }

    func test_aPieceThatStoppedRenderingWhileQueuedIsNotWritten() async throws {
        let doc = try await makeDoc()
        let gate = WriteGate(hold: [1])
        doc.autosaveWriteHook = gate.hook

        doc.setFullText("Before the move.")
        let first = Task { try await doc.performAutosave() }
        await gate.waitForEntry(1)

        doc.setFullText("After the move.")
        let second = Task { try await doc.performAutosave() }
        await yieldUntil("the second autosave is queued") { doc.autosaveRunsQueued == 2 }
        // Another device moved the piece away while write two waited its turn.
        doc.stopRendering()

        gate.release(1)
        try await first.value
        try await second.value
        XCTAssertEqual(gate.enteredWrites, 1,
            "a write queued before the piece stopped rendering must not land")
    }

    // MARK: - Helpers

    /// Delivers a presenter callback and returns once its synchronous part —
    /// the echo guard and, for an outside edit, the conflict backup — has run.
    /// A callback taken for an outside edit goes on to rewrite the `.md`, which
    /// queues behind a held write; awaiting it inline would hang the test
    /// instead of failing it, so the caller awaits the task after releasing.
    private func deliverCallback(_ bytes: String, to doc: Document) async
        -> Task<Void, Error> {
        var started = false
        let task = Task {
            started = true
            try await doc.handleExternalDiskChange(diskMd: bytes)
        }
        await yieldUntil("the callback runs") { started }
        return task
    }

    private func conflictBackups(of doc: Document) -> [String] {
        let dir = Document.conflictsDir(for: doc.url)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
    }
}

/// Stands in for the `.md` write: counts calls, records the thread, holds a
/// numbered call on a semaphore until the test releases it, or fails one.
/// Every field is under `lock`, hence `@unchecked Sendable`.
private final class WriteGate: @unchecked Sendable {
    struct Injected: Error {}

    private let lock = NSLock()
    private let failing: Set<Int>
    private var semaphores: [Int: DispatchSemaphore] = [:]
    private var entered = 0
    private var completed = 0
    private var flags: [Bool] = []
    private var waiters: [(Int, UUID, CheckedContinuation<Bool, Never>)] = []

    init(hold: Set<Int> = [], fail: Set<Int> = []) {
        failing = fail
        for n in hold { semaphores[n] = DispatchSemaphore(value: 0) }
    }

    var enteredWrites: Int { lock.withLock { entered } }
    var completedWrites: Int { lock.withLock { completed } }
    var mainThreadFlags: [Bool] { lock.withLock { flags } }

    var hook: @Sendable (Data, URL) throws -> Void {
        { [self] data, url in try self.write(data, url) }
    }

    private func write(_ data: Data, _ url: URL) throws {
        let onMain = Thread.isMainThread
        let (n, semaphore, ready) = lock.withLock {
            entered += 1
            flags.append(onMain)
            let n = entered
            let ready = waiters.filter { $0.0 <= n }.map(\.2)
            waiters.removeAll { $0.0 <= n }
            return (n, semaphores[n], ready)
        }
        ready.forEach { $0.resume(returning: true) }
        semaphore?.wait()
        if failing.contains(n) { throw Injected() }
        try data.write(to: url, options: .atomic)
        lock.withLock { completed += 1 }
    }

    /// Returns when call `n` has entered the hook. A failure bound, not a
    /// wait for an effect: if the call never comes (the hook is not wired),
    /// the test fails after `bound` instead of hanging the gate.
    @discardableResult
    func waitForEntry(_ n: Int, bound: Duration = .seconds(20), expected: Bool = true,
                      file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let token = UUID()
        let entered: Bool = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let now = lock.withLock { () -> Bool in
                if self.entered >= n { return true }
                waiters.append((n, token, c))
                return false
            }
            if now { c.resume(returning: true) }
            Task.detached { [self] in
                try? await Task.sleep(for: bound)
                let late = self.lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                    guard let i = self.waiters.firstIndex(where: { $0.1 == token }) else { return nil }
                    return self.waiters.remove(at: i).2
                }
                late?.resume(returning: false)
            }
        }
        if !entered && expected { XCTFail("write \(n) never reached the hook", file: file, line: line) }
        return entered
    }

    func release(_ n: Int) {
        lock.withLock { semaphores[n] }?.signal()
    }
}
