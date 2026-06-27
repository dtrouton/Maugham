import Foundation

/// Applies a suggested-change replacement to a paragraph. Shared by the Mac
/// (`Document.acceptAnnotation`) and the phone (`AnnotationWriter.makeAccept`)
/// so the accept op's materialised `next` is computed identically on both
/// surfaces (cross-surface contract).
///
/// The op stores the BARE suggested text (so the review UI shows just the
/// replacement, e.g. `→ furious`, not the whole resulting paragraph). The full
/// paragraph is produced HERE, at accept time, by splicing the bare text into
/// the span — so a one-word suggestion replaces one word, not the paragraph.
/// A paragraph-level suggestion (no span) replaces the whole paragraph, which
/// is what the bare text already is.
public enum SuggestionSplice {

    /// The full paragraph text after applying `bare` to `paragraph`.
    ///
    /// - Span-anchored (sub-paragraph): the span is re-resolved against
    ///   `paragraph` at call time and only that range is replaced — robust if the
    ///   paragraph was edited between authoring and accept.
    /// - No span / empty quote / span no longer resolvable: the bare text IS the
    ///   whole paragraph (the Claude/MCP `add_suggested_change` contract, and the
    ///   safe fallback for a lost anchor).
    public static func apply(
        suggestion bare: String, span: SpanAnchor?, to paragraph: String
    ) -> String {
        guard let span,
              let range = SpanAnchorResolver.resolve(anchor: span, in: paragraph)
        else { return bare }
        let chars = Array(paragraph)
        return String(chars[..<range.lowerBound])
            + bare
            + String(chars[range.upperBound...])
    }

    /// Reconstruct the `SpanAnchor` an annotation op was created with from its
    /// persisted provenance. Returns nil for a paragraph-level annotation (no
    /// span quote).
    public static func spanAnchor(from provenance: Op.Provenance?) -> SpanAnchor? {
        guard let provenance,
              let quote = provenance.spanQuote, !quote.isEmpty else { return nil }
        return SpanAnchor(
            quote: quote,
            prefix: provenance.spanPrefix ?? "",
            suffix: provenance.spanSuffix ?? "",
            posHint: provenance.spanPosHint ?? 0)
    }
}
