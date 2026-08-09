import Foundation

/// Probe output goes to a file — `print` from the test host does not reach
/// `xcodebuild`'s stdout in this toolchain.
enum ProbeLog {
    static let path = "/tmp/claude-501/-Users-denver-src-experiments-Maugham/20d83c29-5f79-4c29-bbba-61d70f1b812d/scratchpad/probe-out.txt"
    static func write(_ line: String) {
        let text = line + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
