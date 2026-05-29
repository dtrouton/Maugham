import Foundation

/// Converts a human-readable title into a filesystem-safe slug:
/// lowercase, ASCII-only, dashes for spaces, max 40 chars, fallback "untitled".
public enum Slugifier {

    private static let maxLength = 40
    private static let fallback = "untitled"

    public static func slug(from title: String) -> String {
        // Step 1: NFD-normalise then strip combining marks (decomposes "ü" → "u" + combining diaeresis)
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)

        // Step 2: lowercased
        let lowered = folded.lowercased()

        // Step 3: keep only [a-z 0-9 space dash].
        // Whitespace/separator scalars become a space (word boundary → dash later).
        // Everything else (punctuation, apostrophes, etc.) is simply dropped.
        let alphanumeric = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let wordBreak = CharacterSet(charactersIn: " -").union(.whitespacesAndNewlines)
        var filtered = ""
        for scalar in lowered.unicodeScalars {
            if alphanumeric.contains(scalar) || scalar == Unicode.Scalar("-") {
                filtered.append(Character(scalar))
            } else if wordBreak.contains(scalar) {
                filtered.append(" ")
            }
            // else: drop (punctuation, apostrophes, symbols, etc.)
        }

        // Step 4: collapse runs of whitespace/dashes to single dash, trim
        var collapsed = ""
        var prevDash = false
        for ch in filtered {
            if ch == " " || ch == "-" {
                if !prevDash && !collapsed.isEmpty {
                    collapsed.append("-")
                    prevDash = true
                }
            } else {
                collapsed.append(ch)
                prevDash = false
            }
        }
        if collapsed.hasSuffix("-") {
            collapsed.removeLast()
        }

        // Step 5: truncate, then strip trailing dash if truncation landed on one
        var truncated = String(collapsed.prefix(maxLength))
        while truncated.hasSuffix("-") {
            truncated.removeLast()
        }

        return truncated.isEmpty ? fallback : truncated
    }
}
