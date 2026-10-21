import Foundation

/// Escaping for the Word export's XML parts. Every string the DOCX emitter
/// writes passes through here: the markup characters are escaped, and a
/// character XML 1.0 forbids (a C0 control other than tab, newline and
/// carriage return; U+FFFE; U+FFFF) is dropped, since one such character is
/// enough for Word to call the file corrupt.
enum OOXMLEscape {

    /// Text content: `& < > "` escaped, illegal characters dropped. Tab and
    /// newline pass through; the emitter turns them into `w:tab`/`w:br`
    /// before text reaches a `w:t`.
    static func text(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in input.unicodeScalars where isLegal(scalar) {
            switch scalar {
            case "&":  out.append(contentsOf: "&amp;".unicodeScalars)
            case "<":  out.append(contentsOf: "&lt;".unicodeScalars)
            case ">":  out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
            default:   out.append(scalar)
            }
        }
        return String(out)
    }

    /// An attribute value: `text`, with tab, newline and carriage return as
    /// character references, which attribute normalisation would otherwise
    /// turn into spaces.
    static func attribute(_ input: String) -> String {
        text(input)
            .replacingOccurrences(of: "\t", with: "&#9;")
            .replacingOccurrences(of: "\n", with: "&#10;")
            .replacingOccurrences(of: "\r", with: "&#13;")
    }

    /// XML 1.0's `Char` production. Swift strings hold no surrogates, so the
    /// only scalars to refuse are the C0 controls and U+FFFE/U+FFFF.
    static func isLegal(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD:  return true
        case 0x0..<0x20:     return false
        case 0xFFFE, 0xFFFF: return false
        default:             return true
        }
    }
}
