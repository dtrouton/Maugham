import Foundation
import Darwin

public enum MCPServerStartError: Error {
    case socketCreateFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// MCPServer owns one AF_UNIX listening socket and runs an accept loop. Each
/// accepted connection reads line-delimited JSON-RPC requests, dispatches via
/// MCPRouter, and writes responses back. Disabled preference short-circuits
/// every request with mcp_disabled (-32003).
///
/// Blocking POSIX calls (accept, recv) run on **dedicated `Thread`s** via
/// withCheckedContinuation, so Swift's cooperative thread pool is never
/// starved by blocking syscalls — and neither is libdispatch's.
///
/// These used to be `DispatchQueue.global(qos: .utility).async`, which is the
/// documented anti-pattern: a blocking syscall on a dispatch worker occupies
/// that worker for the whole call, and the global pool has a hard 64-thread
/// soft limit. When something else in the process reaches that limit, the
/// accept loop simply never gets a thread and **the server silently stops
/// answering** — no error, no log, no connection refused. Measured 2026-08-15
/// in the xctest host, which reaches the ceiling during launch: the server
/// could not accept a connection at all, and `MCPServerLifecycleTests` failed
/// or hung depending on which side lost the race. The shipping app has one
/// blocked thread rather than 64, so this was latent there rather than live —
/// but "MCP stops responding if some unrelated subsystem saturates GCD" is not
/// a property worth keeping. A `Thread` is created by the kernel, costs one
/// 512 KB stack, and cannot be starved by the dispatch pool. One thread per
/// server for the accept loop, one per open connection.
@MainActor
public final class MCPServer {
    private let socketPath: String
    private let router: MCPRouter
    private let preferences: UserPreferences
    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    /// Process-wide SIGPIPE ignore. Installed lazily on first server start;
    /// idempotent. Writing to a peer-closed socket would otherwise terminate
    /// Maugham silently (no crash report on Darwin).
    nonisolated(unsafe) private static var sigpipeIgnored = false
    private static let sigpipeIgnoredLock = NSLock()

    private static func installSIGPIPEIgnoreOnce() {
        sigpipeIgnoredLock.lock()
        defer { sigpipeIgnoredLock.unlock() }
        if sigpipeIgnored { return }
        signal(SIGPIPE, SIG_IGN)
        sigpipeIgnored = true
    }

    public init(socketPath: String, router: MCPRouter, preferences: UserPreferences) {
        self.socketPath = socketPath
        self.router = router
        self.preferences = preferences
    }

    public func start() async throws {
        // Block SIGPIPE for the entire process. Writing to a peer-closed socket
        // would otherwise terminate Maugham silently (no crash report on Darwin).
        Self.installSIGPIPEIgnoreOnce()

        let parent = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true)
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPServerStartError.socketCreateFailed(errno) }
        listenFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                _ = strlcpy(
                    UnsafeMutableRawPointer(dst).assumingMemoryBound(to: CChar.self),
                    src,
                    MemoryLayout.size(ofValue: dst.pointee))
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let saved = errno
            close(fd)
            listenFD = -1
            throw MCPServerStartError.bindFailed(saved)
        }
        guard listen(fd, 5) == 0 else {
            let saved = errno
            close(fd)
            listenFD = -1
            throw MCPServerStartError.listenFailed(saved)
        }

        let listenFDCopy = fd
        let routerRef = router
        let prefsRef = preferences
        acceptTask = Task.detached(priority: .utility) {
            await Self.acceptLoop(
                listenFD: listenFDCopy, router: routerRef, preferences: prefsRef)
        }
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        if listenFD >= 0 {
            // Closing the listening FD breaks the blocking accept() call.
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Private helpers

    /// Runs a blocking syscall on a dedicated thread so neither Swift's
    /// cooperative pool nor libdispatch's worker pool is occupied by it.
    /// See the type's doc comment for why this is not a dispatch queue.
    private static func onBlockingThread<T: Sendable>(
        _ name: String, _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: work()) }
            thread.name = name
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    private static func blockingAccept(listenFD: Int32) async -> Int32 {
        await onBlockingThread("mcp-accept") {
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            return accept(listenFD, &clientAddr, &len)
        }
    }

    private static func acceptLoop(
        listenFD: Int32, router: MCPRouter, preferences: UserPreferences
    ) async {
        while !Task.isCancelled {
            let clientFD = await blockingAccept(listenFD: listenFD)
            if clientFD < 0 {
                if errno == EBADF || errno == EINVAL { break }
                continue
            }
            Task.detached(priority: .utility) {
                await Self.handleConnection(
                    clientFD: clientFD, router: router, preferences: preferences)
                close(clientFD)
            }
        }
    }

    private static func blockingRecv(fd: Int32, count: Int) async -> (data: Data, n: Int) {
        let result: RecvResult = await onBlockingThread("mcp-recv") {
            var buf = [UInt8](repeating: 0, count: count)
            let n = recv(fd, &buf, count, 0)
            return RecvResult(data: n > 0 ? Data(buf.prefix(Int(n))) : Data(), n: Int(n))
        }
        return (result.data, result.n)
    }

    /// `onBlockingThread` needs a `Sendable` return; a tuple of `(Data, Int)`
    /// is one in principle but not one the compiler will infer here.
    private struct RecvResult: Sendable {
        let data: Data
        let n: Int
    }

    private static func handleConnection(
        clientFD: Int32, router: MCPRouter, preferences: UserPreferences
    ) async {
        var pending = Data()
        while !Task.isCancelled {
            let (chunk, n) = await blockingRecv(fd: clientFD, count: 8192)
            if n <= 0 { return }
            pending.append(chunk)
            while let newlineIdx = pending.firstIndex(of: 0x0A) {
                let lineData = Data(pending[..<newlineIdx])
                pending.removeSubrange(...newlineIdx)
                let response = await Self.dispatch(
                    lineData: lineData,
                    router: router,
                    preferences: preferences)
                if response.isEmpty { continue }
                var out = response
                out.append(0x0A)
                // Drain loop — see `sendAll(data:writer:)` for the algorithm
                // and its unit-testable pure form. Mirrors the bridge's
                // `writeLine` drain shape so the two stay consistent.
                let drained = Self.sendAll(data: out) { ptr, count in
                    Darwin.send(clientFD, ptr, count, 0)
                }
                if !drained {
                    // Peer closed (EPIPE) or connection reset (ECONNRESET) — exit
                    // this connection's loop cleanly. Listening socket stays up.
                    return
                }
            }
        }
    }

    /// Drain-write `data` by calling `writer` repeatedly until all bytes are
    /// sent. Returns `true` when all bytes are sent; `false` on a real write
    /// error (EPIPE, ECONNRESET, or an unexpected zero-byte return). EINTR is
    /// retried transparently.
    ///
    /// This is a pure helper (no socket coupling) so it can be exercised by
    /// unit tests with an injected writer closure — e.g. one that returns a
    /// short count on the first call and the remainder on the second.
    ///
    /// Mirrors the bridge's `writeLine` drain loop exactly so the two stay
    /// in sync: both treat `w <= 0` (after EINTR retry) as connection-close.
    ///
    /// `nonisolated` because the helper touches no actor state — it is a pure
    /// byte-pumping loop over the supplied `writer` closure.
    nonisolated static func sendAll(data: Data, writer: (UnsafeRawPointer, Int) -> Int) -> Bool {
        data.withUnsafeBytes { rawBytes -> Bool in
            guard let base = rawBytes.baseAddress, !rawBytes.isEmpty else { return true }
            var sent = 0
            while sent < data.count {
                let w = writer(base + sent, data.count - sent)
                if w < 0 {
                    if errno == EINTR { continue }
                    return false  // EPIPE / ECONNRESET / other real error
                }
                if w == 0 { return false }  // unexpected: peer closed mid-send
                sent += w
            }
            return true
        }
    }

    private static func dispatch(
        lineData: Data, router: MCPRouter, preferences: UserPreferences
    ) async -> Data {
        let req: MCPRequest
        do {
            req = try JSONDecoder().decode(MCPRequest.self, from: lineData)
        } catch {
            let resp = MCPResponse.failure(id: nil, code: -32700, message: "Parse error")
            return (try? JSONEncoder().encode(resp)) ?? Data()
        }

        // JSON-RPC notification: no id, no response. Per spec, server MUST NOT reply.
        // Claude Desktop sends `notifications/initialized` after handshake; replying
        // would be a protocol error.
        if req.id == nil { return Data() }

        let enabled = await MainActor.run { preferences.mcpEnabled }
        if !enabled {
            let resp = MCPResponse.failure(
                id: req.id,
                code: MCPError.mcpDisabled.code,
                message: MCPError.mcpDisabled.message)
            return (try? JSONEncoder().encode(resp)) ?? Data()
        }

        do {
            let resultJSON = try await router.dispatch(
                method: req.method, paramsJSON: req.paramsJSON)
            let resp = MCPResponse.success(id: req.id, resultJSON: resultJSON)
            return (try? JSONEncoder().encode(resp)) ?? Data()
        } catch let MCPRouterError.methodNotFound(method) {
            let resp = MCPResponse.failure(
                id: req.id, code: -32601, message: "Method not found: \(method)")
            return (try? JSONEncoder().encode(resp)) ?? Data()
        } catch let e as MCPError {
            let resp = MCPResponse.failure(
                id: req.id, code: e.code, message: e.message)
            return (try? JSONEncoder().encode(resp)) ?? Data()
        } catch {
            let resp = MCPResponse.failure(
                id: req.id,
                code: MCPError.internalError("").code,
                message: "Internal error: \(error.localizedDescription)")
            return (try? JSONEncoder().encode(resp)) ?? Data()
        }
    }
}
