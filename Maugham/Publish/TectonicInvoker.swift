import Foundation

/// Spawns `tectonic` to compile a single `.tex` file. Captures stdout+stderr
/// into a combined log. Allows cancellation via the returned task.
public final class TectonicInvoker {

    public enum OutputFormat: String {
        case pdf
        case html
        case xdv
    }

    public struct Result: Sendable {
        public let exitCode: Int32
        public let combinedLog: String
    }

    public let binaryURL: URL
    public let cacheURL: URL

    public init(binaryURL: URL, cacheURL: URL) {
        self.binaryURL = binaryURL
        self.cacheURL = cacheURL
    }

    /// Compile `texFile`. The compile runs in `workingDirectory` with output
    /// placed alongside the input file.
    public func compile(
        texFile: URL,
        workingDirectory: URL,
        outputFormat: OutputFormat = .pdf
    ) async throws -> Result {
        let process = Process()
        process.executableURL = binaryURL
        process.currentDirectoryURL = workingDirectory
        process.arguments = [
            "-X", "compile",
            "--keep-intermediates",
            "--keep-logs",
            "--outdir", workingDirectory.path,
            texFile.path
        ]
        var env = ProcessInfo.processInfo.environment
        env["TECTONIC_CACHE_DIR"] = cacheURL.path
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { proc in
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let combined = (String(data: outData, encoding: .utf8) ?? "")
                    + (String(data: errData, encoding: .utf8) ?? "")
                cont.resume(returning: Result(
                    exitCode: proc.terminationStatus,
                    combinedLog: combined))
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
