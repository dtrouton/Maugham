import Foundation
import Darwin

/// Bridges Claude Desktop's stdio JSON-RPC to Maugham's Unix socket.
/// Single-threaded line loop with auto-reconnect: when the socket dies
/// (Maugham crashed or was rebuilt), the binary holds stdin/stdout open,
/// synthesizes maugham_not_running for incoming requests, and periodically
/// attempts reconnect with exponential backoff. When the connection is
/// restored, request forwarding resumes transparently.
final class JSONRPCBridge {
    private let socketPath: String
    private var socketFD: Int32 = -1
    /// Buffer of bytes read from socket that haven't yet been parsed into a complete line.
    private var socketReadBuffer = Data()

    /// Reconnect cadence in seconds. Starts fast, backs off, settles at
    /// 8s. The binary stays alive indefinitely; each new stdin line
    /// triggers a reconnect attempt if the socket is dead.
    private let reconnectDelays: [TimeInterval] = [0.5, 1.0, 2.0, 4.0, 8.0]
    private var nextReconnectIdx = 0

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func run() {
        // Try initial connect (non-fatal if it fails — we'll keep trying as
        // requests arrive).
        _ = tryConnect()

        // Single-threaded line loop on stdin.
        var stdinBuffer = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(0, &buf, buf.count)
            if n <= 0 {
                // stdin closed — Claude Desktop quit or shut us down. Exit cleanly.
                if socketFD >= 0 { close(socketFD); socketFD = -1 }
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
        // Ensure we have a socket connection (try to reconnect if dead).
        if socketFD < 0 {
            _ = tryConnect()
        }

        // JSON-RPC notifications (id-less requests like notifications/initialized)
        // get no response. Don't block waiting for one.
        let isNotification = Self.isNotification(line: line)

        if socketFD >= 0 {
            if writeLine(line, toFD: socketFD) {
                if isNotification {
                    // Fire-and-forget; server stays silent per JSON-RPC spec.
                    return
                }
                if let response = readSocketLine() {
                    writeStdoutLine(response)
                    return
                }
                // Socket died mid-exchange. Close and synthesize.
                closeSocket()
            } else {
                // Write failed (peer reset). Close and synthesize.
                closeSocket()
            }
        }
        // Socket is dead. For notifications we have no response obligation,
        // so just return — Claude Desktop doesn't expect bytes back.
        if isNotification { return }
        // For requests, synthesize a maugham_not_running response so Claude
        // Desktop sees a clean error instead of a hang.
        if let response = Self.errorResponseFor(line: line) {
            writeStdoutLine(response)
        }
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

    /// Try to connect to the socket. Returns true on success; updates
    /// socketFD. Implements exponential backoff: each call advances the
    /// delay index; on success the index resets.
    private func tryConnect() -> Bool {
        if socketFD >= 0 { return true }
        // Apply backoff for repeated failed attempts.
        if nextReconnectIdx > 0 {
            let delay = reconnectDelays[min(nextReconnectIdx - 1, reconnectDelays.count - 1)]
            Thread.sleep(forTimeInterval: delay)
        }
        let fd = openSocket()
        if fd >= 0 {
            socketFD = fd
            socketReadBuffer.removeAll()
            nextReconnectIdx = 0
            return true
        }
        nextReconnectIdx = min(nextReconnectIdx + 1, reconnectDelays.count)
        return false
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
