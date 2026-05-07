import Foundation

/// Computes optional auto-replacements for typographic input:
/// `--` -> em dash, `...` -> ellipsis, `"` / `'` -> curly quotes.
public enum SmartTypography {

    /// Returns a substitution string if the user's replacement should be
    /// auto-transformed; otherwise nil. Caller (the editor coordinator)
    /// applies the substitution by re-issuing the text replacement.
    public static func transform(
        currentText: String,
        replacementRange: NSRange,
        replacement: String,
        settings: TypographySettings
    ) -> String? {
        // Em dash: replacement "-" preceded by another "-"
        if settings.emDashAutoReplace, replacement == "-",
           replacementRange.location > 0 {
            let nsText = currentText as NSString
            let prevRange = NSRange(location: replacementRange.location - 1, length: 1)
            if nsText.substring(with: prevRange) == "-" {
                // Caller is responsible for replacing the previous "-" too;
                // we return the em dash as the substitute for the just-typed "-",
                // and a separate convention is that the coordinator deletes
                // the preceding "-" before inserting our value.
                return "—"
            }
        }

        // Ellipsis: replacement "." preceded by ".."
        if settings.ellipsisAutoReplace, replacement == ".",
           replacementRange.location >= 2 {
            let nsText = currentText as NSString
            let prevRange = NSRange(location: replacementRange.location - 2, length: 2)
            if nsText.substring(with: prevRange) == ".." {
                // Don't transform "1.0.0" — only when not preceded by a digit
                if replacementRange.location >= 3 {
                    let beforeDots = NSRange(
                        location: replacementRange.location - 3, length: 1)
                    let prefixChar = nsText.substring(with: beforeDots)
                    if let scalar = prefixChar.unicodeScalars.first,
                       CharacterSet.decimalDigits.contains(scalar) {
                        return nil
                    }
                }
                return "…"
            }
        }

        // Smart double quote
        if settings.smartQuotes, replacement == "\"" {
            return isOpeningContext(text: currentText, at: replacementRange.location)
                ? "\u{201C}" : "\u{201D}"
        }

        // Smart single quote
        if settings.smartQuotes, replacement == "'" {
            return isOpeningContext(text: currentText, at: replacementRange.location)
                ? "\u{2018}" : "\u{2019}"
        }

        return nil
    }

    /// True when the cursor is at the start of input or after whitespace —
    /// we should produce an opening curly quote. Otherwise, closing.
    private static func isOpeningContext(text: String, at location: Int) -> Bool {
        guard location > 0 else { return true }
        let nsText = text as NSString
        guard location <= nsText.length else { return true }
        let prev = nsText.substring(
            with: NSRange(location: location - 1, length: 1))
        if prev.isEmpty { return true }
        if let scalar = prev.unicodeScalars.first,
           CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return true
        }
        return false
    }
}
