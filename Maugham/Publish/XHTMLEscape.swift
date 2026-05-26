import Foundation

/// XHTML character escaping. `escape` is for text content; `attribute` is for
/// attribute values (slightly different needs but we use the strict set for
/// both to keep behavior obvious).
public enum XHTMLEscape {

    public static func escape(_ input: String) -> String {
        var s = input
        s = s.replacingOccurrences(of: "&",  with: "&amp;")  // MUST be first
        s = s.replacingOccurrences(of: "<",  with: "&lt;")
        s = s.replacingOccurrences(of: ">",  with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        s = s.replacingOccurrences(of: "'",  with: "&apos;")
        return s
    }

    public static func attribute(_ input: String) -> String {
        // Same set is safe for attributes. Kept separate so callers can read
        // intent at the call site.
        escape(input)
    }
}
