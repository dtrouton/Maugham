import Foundation
import Darwin

/// Stdio↔Unix-socket relay. If the socket connects, forwards line-delimited
/// JSON-RPC bytes in both directions until either side closes. If the socket
/// is absent, reads stdin requests and synthesizes maugham_not_running
/// responses (-32001), preserving the request id when present.
final class JSONRPCBridge {
    private let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func run() {
        let fd = openSocket()
        if fd >= 0 {
            relay(socketFD: fd)
            close(fd)
        } else {
            synthesizeErrors()
        }
    }

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

    private func relay(socketFD: Int32) {
        // Two threads: stdin → socket, socket → stdout. Either ends causes shutdown.
        let group = DispatchGroup()
        let stdinFD: Int32 = 0
        let stdoutFD: Int32 = 1

        group.enter()
        DispatchQueue.global().async {
            Self.pipe(from: stdinFD, to: socketFD)
            // stdin → socket finished (stdin EOF or socket write failed). Half-close
            // the socket write side so the server sees EOF. Also shut down the read
            // side so the other pipe's blocked recv returns.
            shutdown(socketFD, SHUT_RDWR)
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            Self.pipe(from: socketFD, to: stdoutFD)
            // socket → stdout finished (socket closed or stdout write failed).
            // Close stdin so the other pipe's blocked read returns.
            close(stdinFD)
            group.leave()
        }
        group.wait()
    }

    private static func pipe(from: Int32, to: Int32) {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(from, &buf, buf.count)
            if n <= 0 { return }
            var written = 0
            while written < Int(n) {
                let w = buf.withUnsafeBufferPointer { ptr in
                    write(to, ptr.baseAddress! + written, Int(n) - written)
                }
                if w <= 0 { return }
                written += w
            }
        }
    }

    private func synthesizeErrors() {
        // Read stdin line-by-line, return a maugham_not_running error for each.
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(0, &buf, buf.count)
            if n <= 0 { return }
            pending.append(buf, count: Int(n))
            while let newlineIdx = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newlineIdx]
                pending.removeSubrange(...newlineIdx)
                let response = Self.errorResponseFor(line: Data(line))
                _ = response.withUnsafeBytes { write(1, $0.baseAddress, response.count) }
                let newline: [UInt8] = [0x0A]
                _ = newline.withUnsafeBufferPointer { write(1, $0.baseAddress, 1) }
            }
        }
    }

    private static func errorResponseFor(line: Data) -> Data {
        // Extract the id field if present. We don't fully parse the request —
        // just enough to preserve the id so the client matches the response.
        let idLiteral: String
        if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
            if let intId = json["id"] as? Int { idLiteral = "\(intId)" }
            else if let strId = json["id"] as? String { idLiteral = "\"\(strId)\"" }
            else { idLiteral = "null" }
        } else {
            idLiteral = "null"
        }
        let body = """
        {"jsonrpc":"2.0","id":\(idLiteral),"error":{"code":-32001,"message":"Maugham isn't running."}}
        """
        return Data(body.utf8)
    }
}
