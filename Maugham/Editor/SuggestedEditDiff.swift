import Foundation

/// Task 4: pure helper turning a reviewer's replacement of selected text into
/// the (body, suggestedText) pair for a `.suggestedChange` annotation. No
/// AppKit — testable in isolation.
///
/// `original` is the selected manuscript text; `edited` is the reviewer's
/// replacement. The body stays empty for v1 — the suggestion *is* the
/// replacement; a rationale field can come later.
enum SuggestedEditDiff {
    /// Returns nil if there's nothing to suggest: the edit is empty, or it's
    /// unchanged from the original under a whitespace-trimmed comparison.
    /// Otherwise returns `(body: "", suggestedText: edited)` with `edited`
    /// preserved verbatim.
    static func make(original: String, edited: String) -> (body: String, suggestedText: String)? {
        let o = original, e = edited
        guard e.trimmingCharacters(in: .whitespacesAndNewlines)
            != o.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty else { return nil }
        return (body: "", suggestedText: e)
    }
}
