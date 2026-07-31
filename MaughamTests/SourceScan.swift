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
/// span.
///
/// **What it cannot see, and the two cases fail in OPPOSITE directions** — which
/// is the whole of what a reader needs from this paragraph:
///
/// - **A `//` inside a string literal** truncates that line early. Whatever
///   followed it on that line stops being visible, so a token there goes
///   *missing*: a required-token census reports it absent and goes **red**.
///   Loud, and therefore safe.
/// - **A `/*` inside a string literal, or in prose naming a path like
///   `.maugham/sessions/*`,** opens a block that never closes, and **everything
///   after it in the file is invisible**. For a required-token census that is
///   still red. For a **forbidden**-token ban it is the opposite: the offender is
///   hidden and the ban passes **quietly** — the exact failure this type was
///   written to close, arriving one layer underneath it.
///
/// Several files in this repo end their scan inside a block today, in both trees
/// this suite scans and in two it does not — **read the expectations in
/// `TripwireGrepTests.test_noScannedFileIsTruncatedByAnUnclosedBlockComment`
/// rather than a number written here**, which is this directory's own rule about
/// prose counts. What that guard pins is the part that matters: `Maugham/Canvas/`
/// holds at **zero**, because it is the one tree a *forbidden*-token ban reads
/// through, and the rest of `Maugham/` is a census with its reasons.
///
/// A guard rather than a smarter stripper, deliberately: one that understood
/// string literals would be a small Swift lexer with nothing to test it against,
/// guarding a suite of censuses.
enum SourceScan {

    /// Every line of `text` with its comments stripped. Lines that were entirely
    /// comment are dropped; the rest keep their code.
    static func codeLines(of text: String) -> [String] {
        scan(text).lines
    }

    /// Whether the scan of `text` ran off the end still inside a `/* … */` block
    /// — i.e. whether some tail of the file was invisible to `codeLines`.
    ///
    /// The guard test's instrument. Same scan as `codeLines`, reported from the
    /// same loop rather than by a second implementation that could disagree with
    /// it about where a block begins.
    static func endsInsideABlock(_ text: String) -> Bool {
        scan(text).endedInsideBlock
    }

    private static func scan(_ text: String) -> (lines: [String], endedInsideBlock: Bool) {
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
        return (out, inBlock)
    }

    /// Whether `text` names `token` **in code**.
    static func namesInCode(_ token: String, in text: String) -> Bool {
        codeLines(of: text).contains { $0.contains(token) }
    }
}
