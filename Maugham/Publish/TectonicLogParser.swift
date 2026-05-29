import Foundation

public enum TectonicLogParser {

    public struct Diagnostic: Equatable, Sendable {
        public let level: Level
        public let file: String?
        public let line: Int?
        public let message: String
        public let contextLines: [String]
    }

    public enum Level: String, Equatable, Sendable {
        case error
        case warning
    }

    public static func parse(log: String) -> [Diagnostic] {
        var result: [Diagnostic] = []
        let lines = log.components(separatedBy: "\n")

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            // Errors start with "! "
            if raw.hasPrefix("! ") {
                let message = String(raw.dropFirst(2))
                var line: Int? = nil
                var context: [String] = []
                var j = i + 1
                // Look for "l.N " on the next non-blank line.
                while j < lines.count {
                    let next = lines[j]
                    if next.isEmpty {
                        j += 1
                        continue
                    }
                    if next.hasPrefix("l.") {
                        let numStr = next.dropFirst(2)
                            .prefix(while: { $0.isNumber })
                        line = Int(numStr)
                        // Collect up to 4 indented context lines after this.
                        var k = j + 1
                        while k < lines.count, k - j <= 4,
                              !lines[k].hasPrefix("!"),
                              !lines[k].isEmpty
                        {
                            context.append(lines[k])
                            k += 1
                        }
                        j = k
                        break
                    } else {
                        break
                    }
                }
                result.append(.init(
                    level: .error, file: nil, line: line,
                    message: message, contextLines: context))
                i = j
                continue
            }
            // Warnings. Beyond LaTeX's own "LaTeX Warning" and the box-fit
            // "Overfull/Underfull \hbox ... at lines N--M", tectonic surfaces
            // package/class/font warnings as "<Name> Warning:" lines (e.g.
            // "Package hyperref Warning:"). Match any line carrying "Warning"
            // here — error lines were already consumed by the "! " branch
            // above, so this can't swallow an error.
            if raw.hasPrefix("Overfull") || raw.hasPrefix("Underfull") ||
               raw.contains("Warning") {
                var line: Int? = nil
                if let lr = raw.range(of: "at lines? ") {
                    let after = raw[lr.upperBound...]
                    let n = after.prefix(while: { $0.isNumber })
                    line = Int(n)
                }
                result.append(.init(
                    level: .warning, file: nil, line: line,
                    message: raw, contextLines: []))
                i += 1
                continue
            }
            i += 1
        }
        return result
    }
}
