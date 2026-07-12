import Foundation
import Darwin

/// Bridges Claude Desktop's stdio JSON-RPC to Maugham's Unix socket.
/// Single-threaded line loop with auto-reconnect: when the socket dies
/// (Maugham crashed or was rebuilt) or was never up (Maugham launched after
/// Claude Desktop spawned us), the binary holds stdin/stdout open and, when a
/// request can't be forwarded, polls for the socket to (re)appear within a
/// bounded budget before forwarding. When the app is genuinely absent the
/// budget is exhausted and we synthesize maugham_not_running.
final class JSONRPCBridge {
    private let socketPath: String
    private var socketFD: Int32 = -1
    /// Buffer of bytes read from socket that haven't yet been parsed into a complete line.
    private var socketReadBuffer = Data()

    /// How long a single request will wait for the socket to (re)appear before
    /// we give up and synthesize maugham_not_running, and how often we re-probe
    /// within that window. Bounded (no retry-forever) per ADR 0003. A cold
    /// launch under load routinely takes >5s; the default comfortably covers
    /// it. Tests override the budget via env so absent-socket synthesis stays
    /// fast.
    private let reconnectBudget: TimeInterval
    private let reconnectPollInterval: TimeInterval

    init(socketPath: String,
         reconnectBudget: TimeInterval = 15.0,
         reconnectPollInterval: TimeInterval = 0.25) {
        self.socketPath = socketPath
        self.reconnectBudget = reconnectBudget
        self.reconnectPollInterval = reconnectPollInterval
    }

    func run() {
        // Try an initial connect (non-fatal if it fails — a failed request will
        // poll for the socket to come up).
        connectIfNeeded()

        // Single-threaded line loop on stdin.
        var stdinBuffer = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(0, &buf, buf.count)
            if n <= 0 {
                // stdin closed — Claude Desktop quit or shut us down. Exit cleanly.
                closeSocket()
                return
            }
            stdinBuffer.append(buf, count: Int(n))

            // Process all complete lines in the buffer.
            while let newlineIdx = stdinBuffer.firstIndex(of: 0x0A) {
                let line = stdinBuffer[..<newlineIdx]
                stdinBuffer.removeSubrange(...newlineIdx)
                handleStdinLine(Data(line))
            }
        }
    }

    /// Handle one complete JSON-RPC line from Claude Desktop.
    private func handleStdinLine(_ line: Data) {
        // JSON-RPC notifications (id-less requests like notifications/initialized)
        // get no response. Don't block waiting for one.
        let isNotification = Self.isNotification(line: line)

        // First attempt: forward on whatever connection we have (open one now if
        // we have none — no backoff on the first try).
        connectIfNeeded()
        if socketFD >= 0, tryForward(line: line, isNotification: isNotification) {
            return
        }

        // First attempt failed: either our cached fd was stale (Maugham
        // restarted and the old process is gone) or we never had a connection
        // (Maugham launched after Claude Desktop spawned us). Both look
        // identical from here, and both must survive a cold launch — this is
        // the "first call after the app (re)starts" flake. Poll for the socket
        // to come up within a bounded budget, then forward. When Maugham is
        // genuinely not running we exhaust the budget and synthesize below.
        closeSocket()
        let deadline = Date().addingTimeInterval(reconnectBudget)
        while Date() < deadline {
            let fd = openSocket()
            if fd >= 0 {
                socketFD = fd
                socketReadBuffer.removeAll()
                if tryForward(line: line, isNotification: isNotification) {
                    return
                }
                closeSocket()
            }
            Thread.sleep(forTimeInterval: reconnectPollInterval)
        }

        // Budget exhausted. For notifications: silent (Claude doesn't expect bytes).
        // For requests: synthesize a maugham_not_running error.
        if isNotification { return }
        if let response = Self.errorResponseFor(line: line) {
            writeStdoutLine(response)
        }
    }

    /// Forward one line on the current socketFD, and for requests read+write
    /// the response back to stdout. Returns true if the round completed
    /// without a socket-level failure; false otherwise (caller should
    /// closeSocket + retry or synthesize).
    private func tryForward(line: Data, isNotification: Bool) -> Bool {
        if !writeLine(line, toFD: socketFD) { return false }
        if isNotification { return true }
        guard let response = readSocketLine() else { return false }
        writeStdoutLine(response)
        return true
    }

    /// JSON-RPC notification = no `id` field. We inspect the raw bytes once
    /// to decide whether to wait for a response. Conservative: if the line
    /// doesn't parse cleanly, treat it as a request (we'll either get a
    /// response or synthesize one).
    private static func isNotification(line: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return false
        }
        // Present-but-null id is still "no id" per JSON-RPC 2.0; treat as
        // notification.
        if obj["id"] == nil { return true }
        if obj["id"] is NSNull { return true }
        return false
    }

    /// Open a connection if we don't already have one. No backoff — used for
    /// the immediate first-attempt and startup; the polled reconnect in
    /// handleStdinLine owns the timed cadence.
    private func connectIfNeeded() {
        if socketFD >= 0 { return }
        let fd = openSocket()
        if fd >= 0 {
            socketFD = fd
            socketReadBuffer.removeAll()
        }
    }

    private func closeSocket() {
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        socketReadBuffer.removeAll()
    }

    /// Connect to the Unix socket. Returns fd ≥ 0 on success, -1 on failure.
    private func openSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
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
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if r != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    /// Write a line (followed by newline) to the given fd. Returns true on success.
    private func writeLine(_ line: Data, toFD fd: Int32) -> Bool {
        var out = line
        out.append(0x0A)
        var written = 0
        return out.withUnsafeBytes { rawBytes -> Bool in
            let base = rawBytes.baseAddress!
            while written < out.count {
                let w = write(fd, base + written, out.count - written)
                if w <= 0 { return false }
                written += w
            }
            return true
        }
    }

    private func writeStdoutLine(_ line: Data) {
        _ = writeLine(line, toFD: 1)
    }

    /// Read one line from the socket. Returns nil if the socket died mid-read.
    private func readSocketLine() -> Data? {
        // If buffer already has a complete line, return it.
        if let newlineIdx = socketReadBuffer.firstIndex(of: 0x0A) {
            let line = socketReadBuffer[..<newlineIdx]
            socketReadBuffer.removeSubrange(...newlineIdx)
            return Data(line)
        }
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(socketFD, &buf, buf.count)
            if n <= 0 { return nil }
            socketReadBuffer.append(buf, count: Int(n))
            if let newlineIdx = socketReadBuffer.firstIndex(of: 0x0A) {
                let line = socketReadBuffer[..<newlineIdx]
                socketReadBuffer.removeSubrange(...newlineIdx)
                return Data(line)
            }
        }
    }

    /// Build a JSON-RPC error response for a request whose id we can extract.
    /// Returns nil if the incoming line has no valid id — in that case we drop
    /// the response silently (Claude Desktop can't match null-id responses to
    /// outstanding requests; a missed response is treated as a timeout, which
    /// is graceful, while a malformed reply corrupts the connection).
    private static func errorResponseFor(line: Data) -> Data? {
        let idLiteral: String
        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
            if let i = obj["id"] as? Int { idLiteral = "\(i)" }
            else if let s = obj["id"] as? String { idLiteral = "\"\(s)\"" }
            else { return nil }
        } else {
            return nil
        }
        let body = """
        {"jsonrpc":"2.0","id":\(idLiteral),"error":{"code":-32001,"message":"Maugham isn't running."}}
        """
        return Data(body.utf8)
    }
}
