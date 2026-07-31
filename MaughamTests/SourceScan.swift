import Foundation

/// **Source text with its comments taken out** — the one reader every census in
/// this suite scans through.
///
/// **Why it is shared rather than copied.** A census that matches a token
/// anywhere in a file matches it *in a comment*, and this repo's house style is
/// to quote call shapes verbatim in doc comments — `ProjectWindow.swift` has a
/// five-line comment block sitting directly above a censused call. One future
/// comment naming a token while the real call goes away leaves the census green
/// and the feature unreachable, which is precisely the failure every one of
/// these censuses was built to catch. It was a raw `text.contains` in
/// `PromotionCommandTests` for seven entries and sixteen tokens until 1C-d Task
/// 11's fix round, and it was measured: block-commenting a censused argument out
/// left the census green.
///
/// **What it removes:** whole-line `//` comments, the tail of any line after a
/// `//`, `*`-continuation lines, and `/* … */` blocks including the lines they
/// span. **What it cannot see:** a `//` inside a string literal, which would
/// truncate that line early. No censused token lives in one; if one ever does,
/// the census goes red rather than quiet, which is the right direction.
enum SourceScan {

    /// Every line of `text` with its comments stripped. Lines that were entirely
    /// comment are dropped; the rest keep their code.
    static func codeLines(of text: String) -> [String] {
        var out: [String] = []
        var inBlock = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)

            if inBlock {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                inBlock = false
            }

            // A block that opens on this line: keep what came before it, and
            // keep what comes after it if it also closes here.
            while let open = line.range(of: "/*") {
                if let close = line.range(of: "*/", range: open.upperBound..<line.endIndex) {
                    line = String(line[..<open.lowerBound]) + String(line[close.upperBound...])
                } else {
                    line = String(line[..<open.lowerBound])
                    inBlock = true
                    break
                }
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
            if let comment = line.range(of: "//") {
                line = String(line[..<comment.lowerBound])
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            out.append(line)
        }
        return out
    }

    /// Whether `text` names `token` **in code**.
    static func namesInCode(_ token: String, in text: String) -> Bool {
        codeLines(of: text).contains { $0.contains(token) }
    }
}
