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

    /// The outcome of attempting to apply `bare` to `paragraph`. There is no
    /// String-returning variant: a lost anchor must be impossible to conflate
    /// with a paragraph-level suggestion at the type level, because the old
    /// `apply` did exactly that — its shared fallback returned the bare
    /// span-sized replacement as the WHOLE paragraph, a measured data-loss
    /// path on the writer's prose (M5-AN-049, RULING-5).
    public enum Outcome: Equatable, Sendable {
        /// The full paragraph text after the suggestion is applied.
        case applied(String)
        /// The suggestion carries a span whose quoted phrase can no longer be
        /// found in the paragraph. RULING-5: it MUST NOT be applied — the
        /// caller refuses, tells the writer why, and they may ask again.
        case anchorLost
    }

    /// Attempt to apply `bare` to `paragraph`.
    ///
    /// - Span-anchored (sub-paragraph): the span is re-resolved against
    ///   `paragraph` at call time and only that range is replaced — robust if the
    ///   paragraph was edited between authoring and accept.
    /// - No span / empty quote: the bare text IS the whole paragraph (the
    ///   Claude/MCP `add_suggested_change` contract).
    /// - Span present but no longer resolvable: `.anchorLost` — never a guess.
    /// - Span resolvable but `bare` detected as whole-paragraph grain (it embeds
    ///   the span's surrounding context): `bare` is used verbatim instead of
    ///   spliced — see `isWholeParagraphGrain`.
    public static func attempt(
        suggestion bare: String, span: SpanAnchor?, to paragraph: String
    ) -> Outcome {
        guard let span, !span.quote.isEmpty else { return .applied(bare) }
        guard let range = SpanAnchorResolver.resolve(anchor: span, in: paragraph)
        else { return .anchorLost }
        let chars = Array(paragraph)
        let prefix = String(chars[..<range.lowerBound])
        let suffix = String(chars[range.upperBound...])
        // Grain salvage: a bare text that already carries the paragraph's
        // surrounding context was authored at whole-paragraph grain (the
        // pre-v2 add_suggested_change contract read that way). Splicing it
        // into the span would duplicate the surroundings — use it verbatim.
        if isWholeParagraphGrain(bare: bare, prefix: prefix, suffix: suffix) {
            return .applied(bare)
        }
        return .applied(prefix + bare + suffix)
    }

    /// Minimum context length (in characters, whitespace-trimmed) for a match
    /// to count as whole-paragraph evidence: required of the single side of a
    /// ONE-SIDED match, and of the COMBINED length of a BOTH-SIDES match.
    /// Guards against coincidences like a suffix of "." matching a
    /// replacement that ends in a period — which would silently delete the
    /// rest of the paragraph.
    static let grainContextMinLength = 12

    /// True when `bare` was authored at whole-paragraph grain: it embeds the
    /// text surrounding the span. Trimmed comparison so a trailing newline or
    /// space difference doesn't defeat detection.
    ///
    /// The both-sides branch ALSO requires the combined trimmed context to
    /// reach `grainContextMinLength`: a false positive deletes the
    /// paragraph's surrounding text (worse than the duplication bug this
    /// salvage fixes), and short both-sides coincidences — prefix "She",
    /// suffix "." on a sentence-shaped span replacement — are common in real
    /// prose. When the floor blocks salvage on a genuinely whole-grain short
    /// paragraph, the damage is bounded small duplication — the safer failure.
    static func isWholeParagraphGrain(
        bare: String, prefix: String, suffix: String
    ) -> Bool {
        let b = bare.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixMatches = !p.isEmpty && b.hasPrefix(p)
        let suffixMatches = !s.isEmpty && b.hasSuffix(s)
        if prefixMatches && suffixMatches,
           p.count + s.count >= grainContextMinLength { return true }
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
