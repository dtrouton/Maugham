import Foundation

/// Escapes the ten special LaTeX characters so that arbitrary text from
/// the manuscript renders correctly inside the document body.
///
/// Order matters: backslash MUST be escaped first (its replacement contains
/// `\`), then the rest in any order. Each replacement either uses a
/// printable LaTeX command (e.g. `\textbackslash{}`) or a backslash-prefix
/// (e.g. `\%`).
public enum LaTeXEscape {

    public static func escape(_ input: String) -> String {
        var s = input
        // Backslash FIRST. Use a placeholder so we don't re-match the inserted
        // backslashes during subsequent replacements.
        s = s.replacingOccurrences(of: "\\", with: "\u{0001}")
        // Now the rest. Order doesn't matter.
        s = s.replacingOccurrences(of: "&",  with: "\\&")
        s = s.replacingOccurrences(of: "%",  with: "\\%")
        s = s.replacingOccurrences(of: "$",  with: "\\$")
        s = s.replacingOccurrences(of: "#",  with: "\\#")
        s = s.replacingOccurrences(of: "_",  with: "\\_")
        s = s.replacingOccurrences(of: "{",  with: "\\{")
        s = s.replacingOccurrences(of: "}",  with: "\\}")
        s = s.replacingOccurrences(of: "~",  with: "\\textasciitilde{}")
        s = s.replacingOccurrences(of: "^",  with: "\\textasciicircum{}")
        // Restore backslashes as the command.
        s = s.replacingOccurrences(of: "\u{0001}", with: "\\textbackslash{}")
        return s
    }
}
