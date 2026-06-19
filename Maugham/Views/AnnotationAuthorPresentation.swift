import Foundation
import MaughamCore

/// Pure (testable) derivation of how an annotation's author is presented in the
/// AnnotationsPane. Provenance is source-agnostic on the annotation; a nil
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

/// Pure predicate for filtering annotations by author display label. Extracted
/// so it can be unit-tested without a Document. `selected == nil` (or "All")
/// matches every annotation; otherwise it matches by the author's display
/// label (with nil author → "Claude").
enum AnnotationAuthorFilter {
    /// The sentinel label meaning "no author filter".
    static let all = "All"

    static func matches(_ annotation: Annotation, selected: String?) -> Bool {
        guard let selected, selected != all else { return true }
        return AnnotationAuthorPresentation.label(for: annotation.author) == selected
    }

    /// The distinct author labels present among `annotations`, sorted with
    /// "Claude" first (the historical default) then the rest alphabetically.
    static func distinctLabels(in annotations: [Annotation]) -> [String] {
        let labels = Set(annotations.map { AnnotationAuthorPresentation.label(for: $0.author) })
        let rest = labels.subtracting(["Claude"]).sorted()
        return (labels.contains("Claude") ? ["Claude"] : []) + rest
    }
}
