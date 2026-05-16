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
/// Blocking POSIX calls (accept, recv) run on DispatchQueue.global() via
/// withCheckedContinuation so Swift's cooperative thread pool is never
/// starved by blocking syscalls.
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

    /// Wraps blocking accept() in a GCD dispatch so Swift's cooperative thread
    /// pool thread is not permanently occupied by a blocking syscall.
    private static func blockingAccept(listenFD: Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var clientAddr = sockaddr()
                var len = socklen_t(MemoryLayout<sockaddr>.size)
                let clientFD = accept(listenFD, &clientAddr, &len)
                continuation.resume(returning: clientFD)
            }
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

    /// Wraps blocking recv() in a GCD dispatch so Swift's cooperative thread
    /// pool thread is not permanently occupied.
    private static func blockingRecv(fd: Int32, count: Int) async -> (data: Data, n: Int) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var buf = [UInt8](repeating: 0, count: count)
                let n = recv(fd, &buf, count, 0)
                let data = n > 0 ? Data(buf.prefix(Int(n))) : Data()
                continuation.resume(returning: (data, Int(n)))
            }
        }
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
                let sent = out.withUnsafeBytes { send(clientFD, $0.baseAddress, out.count, 0) }
                if sent < 0 {
                    // Peer closed (EPIPE) or connection reset (ECONNRESET) — exit this
                    // connection's loop cleanly. The listening socket stays up.
                    return
                }
            }
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
