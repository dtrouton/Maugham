import Foundation
import MaughamCore

/// Pure (testable) derivation of how an annotation's author is presented in the
/// Annotations pane. Provenance is source-agnostic on the annotation; a nil
/// author is treated as Claude, because historically every annotation was
/// Claude's (pre-provenance), and Claude-without-author still arrives nil.
enum AnnotationAuthorPresentation {
    /// The display label for an author. nil author → "Claude". Human authors
    /// with an empty display name fall back to "Reviewer".
    static func label(for author: AnnotationAuthor?) -> String {
        guard let author else { return "Claude" }
        switch author.sourceKind {
        case .claude:
            let name = author.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Claude" : name
        case .human:
            let name = author.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Reviewer" : name
        }
    }

    /// True when the annotation should be attributed to Claude: an explicit
    /// `.claude` source, or a nil author (pre-provenance Claude annotations).
    static func isClaude(_ author: AnnotationAuthor?) -> Bool {
        guard let author else { return true }
        return author.sourceKind == .claude
    }
}
