import Foundation

/// Display helpers for a suggested change's before/after, shared by the Mac
/// `AnnotationsPane` and the phone `AnnotationDetailView` so both read the same
/// (cross-surface contract).
///
/// The op stores the BARE replacement as `suggestedText` (the "after"); the
/// "before" must match its grain. For a SUB-PARAGRAPH span suggestion the
/// "before" is the span's original text (`span.quote`) — so the diff reads
/// `very angry → furious`, not `<whole paragraph> → furious` (which mis-reads as
/// "the whole paragraph will be replaced"). For a paragraph-level suggestion
/// (no span) the "before" is the whole prior paragraph.
public enum SuggestionDisplay {

    /// The "before" text to pair with `annotation.suggestedText` in a before/after
    /// diff. Returns nil for a non-suggestion. The span's `quote` is the original
    /// span text captured at creation; falls back to the whole prior paragraph.
    public static func before(for annotation: Annotation) -> String? {
        guard annotation.kind == .suggestedChange else { return nil }
        if let span = annotation.span, !span.quote.isEmpty {
            // Mirror SuggestionSplice.apply's grain decision so the previewed
            // diff is exactly what accept will do. Resolve against priorText —
            // the paragraph as it was when the suggestion was authored.
            if let prior = annotation.priorText,
               let bare = annotation.suggestedText,
               let range = SpanAnchorResolver.resolve(anchor: span, in: prior) {
                let chars = Array(prior)
                if SuggestionSplice.isWholeParagraphGrain(
                    bare: bare,
                    prefix: String(chars[..<range.lowerBound]),
                    suffix: String(chars[range.upperBound...])) {
                    return prior
                }
            }
            return span.quote
        }
        return annotation.priorText
    }
}
