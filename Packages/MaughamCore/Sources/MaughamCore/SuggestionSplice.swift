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
        let prefix = String(chars[..<range.lowerBound])
        let suffix = String(chars[range.upperBound...])
        // Grain salvage: a bare text that already carries the paragraph's
        // surrounding context was authored at whole-paragraph grain (the
        // pre-v2 add_suggested_change contract read that way). Splicing it
        // into the span would duplicate the surroundings — use it verbatim.
        if isWholeParagraphGrain(bare: bare, prefix: prefix, suffix: suffix) {
            return bare
        }
        return prefix + bare + suffix
    }

    /// Minimum context length (in characters, whitespace-trimmed) for a
    /// ONE-SIDED match to count as whole-paragraph evidence. Guards against
    /// coincidences like a suffix of "." matching a replacement that ends in
    /// a period — which would silently delete the rest of the paragraph.
    /// A match on BOTH sides is strong evidence at any length.
    static let grainContextMinLength = 12

    /// True when `bare` was authored at whole-paragraph grain: it embeds the
    /// text surrounding the span. Trimmed comparison so a trailing newline or
    /// space difference doesn't defeat detection.
    static func isWholeParagraphGrain(
        bare: String, prefix: String, suffix: String
    ) -> Bool {
        let b = bare.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixMatches = !p.isEmpty && b.hasPrefix(p)
        let suffixMatches = !s.isEmpty && b.hasSuffix(s)
        if prefixMatches && suffixMatches { return true }
        if prefixMatches && p.count >= grainContextMinLength { return true }
        if suffixMatches && s.count >= grainContextMinLength { return true }
        return false
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
