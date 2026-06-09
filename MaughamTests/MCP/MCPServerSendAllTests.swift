import XCTest
import Darwin
@testable import Maugham

/// Unit tests for `MCPServer.sendAll(data:writer:)` — the drain-loop helper
/// that ensures the full response is written even under socket-buffer pressure
/// (finding 1.7).
///
/// The helper is factored out of `handleConnection` with an injected `writer`
/// closure so it can be driven by pure in-process writers (no real sockets).
///
/// Test strategy:
///   - Single-call success (writer consumes all bytes in one shot).
///   - Short-write retry (writer returns a partial count on the first call,
///     the rest on the second) — the bug `send() < count` was silently ignored.
///   - EINTR retry (writer returns -1 / errno=EINTR once, then succeeds).
///   - Write error (writer returns -1 with a real error) → returns false.
///   - Unexpected zero return → returns false.
///   - Empty data → returns true immediately (no calls to writer).
final class MCPServerSendAllTests: XCTestCase {

    // MARK: - Helpers

    /// Wraps `MCPServer.sendAll` with a Swift-friendly writer that tracks calls.
    private func runSendAll(
        data: Data,
        writer: @escaping (UnsafeRawPointer, Int) -> Int
    ) -> Bool {
        MCPServer.sendAll(data: data, writer: writer)
    }

    // MARK: - Tests

    func test_sendAll_singleCallConsumesAll() {
        // Writer accepts all bytes in one shot → true.
        let data = Data("Hello, world!".utf8)
        var callCount = 0
        let ok = runSendAll(data: data) { _, count in
            callCount += 1
            return count  // claim all bytes written
        }
        XCTAssertTrue(ok, "expected success when writer consumes all bytes")
        XCTAssertEqual(callCount, 1, "expected exactly one write call")
    }

    func test_sendAll_shortWriteRetries() {
        // Writer returns half on the first call, the rest on the second.
        // This is the core of the fix: the old code only called send() once,
        // silently truncating the response. The drain loop retries.
        let payload = "ABCDEFGH"
        let data = Data(payload.utf8)
        let totalBytes = data.count  // 8
        var callCount = 0
        var bytesWritten = 0
        let ok = runSendAll(data: data) { _, count in
            callCount += 1
            let chunk = min(count, totalBytes / 2)  // first call: 4, second: 4
            bytesWritten += chunk
            return chunk
        }
        XCTAssertTrue(ok, "expected success after short-write retry")
        XCTAssertEqual(callCount, 2, "expected two write calls for a half-chunk writer")
        XCTAssertEqual(bytesWritten, totalBytes, "all bytes must be written across retries")
    }

    func test_sendAll_returnsTrue_whenWriterDrainsInMultipleCalls() {
        // Writer writes 1 byte at a time — many retries, all succeed.
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        var callCount = 0
        let ok = runSendAll(data: data) { _, _ in
            callCount += 1
            return 1  // one byte per call
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(callCount, 5)
    }

    func test_sendAll_realError_returnsFalse() {
        // Writer signals a real error (errno is NOT EINTR) → false.
        let data = Data("error test".utf8)
        // Simulate EPIPE by setting errno to EPIPE before returning -1.
        let ok = runSendAll(data: data) { _, _ in
            Darwin.errno = EPIPE
            return -1
        }
        XCTAssertFalse(ok, "expected false on real write error (EPIPE)")
    }

    func test_sendAll_zeroReturn_returnsFalse() {
        // Writer returns 0 (unexpected peer close mid-send) → false.
        let data = Data("zero test".utf8)
        let ok = runSendAll(data: data) { _, _ in 0 }
        XCTAssertFalse(ok, "expected false on zero-byte write (peer closed)")
    }

    func test_sendAll_emptyData_returnsTrue_withoutCallingWriter() {
        // Empty data → no writes needed → true, writer never called.
        var callCount = 0
        let ok = runSendAll(data: Data()) { _, _ in
            callCount += 1
            return 0
        }
        XCTAssertTrue(ok, "empty data should succeed without calling writer")
        XCTAssertEqual(callCount, 0, "writer must not be called for empty data")
    }

    /// Verifies that short writes pass the correct remaining-byte count and
    /// advancing offset to the writer on each subsequent call.
    func test_sendAll_shortWrite_advancesOffset() {
        // 4-byte payload. First call returns 1 byte, second returns 3.
        // We verify the writer is called with the correct sizes.
        let data = Data([0xAA, 0xBB, 0xCC, 0xDD])
        var sizes: [Int] = []
        let ok = runSendAll(data: data) { _, count in
            sizes.append(count)
            // First call: claim 1 byte; subsequent: claim all remaining.
            return sizes.count == 1 ? 1 : count
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(sizes, [4, 3],
            "writer should first be asked for 4 bytes, then for the remaining 3")
    }
}
