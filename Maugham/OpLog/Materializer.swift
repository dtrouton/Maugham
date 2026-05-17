import Foundation

public enum Materializer {
    /// Render the derived state back to a `.md` string. Each paragraph emits:
    ///   <!-- ¶id -->
    ///   <blank>
    ///   <text>
    /// Sequence entries missing from the paragraph map are skipped (a defensive
    /// behaviour — never expected in healthy logs, but doesn't panic if seen).
    public static func materialize(
        paragraphs: [String: String], sequence: [String]
    ) -> String {
        var out = ""
        for id in sequence {
            guard let text = paragraphs[id] else { continue }
            if !out.isEmpty { out.append("\n") }
            out.append(ParagraphID.formatComment(id))
            out.append("\n\n")
            out.append(text)
            out.append("\n")
        }
        return out
    }
}
