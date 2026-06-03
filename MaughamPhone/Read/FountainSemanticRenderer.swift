import SwiftUI
import MaughamCore

/// Pure translation of a `FountainLineStyle.Align` into the SwiftUI types the
/// renderer needs. Kept as a free enum (not inline in the view) so the mapping
/// is unit-testable without rendering — mirrors why `FountainLineStyle` itself
/// avoids SwiftUI types. The Mac styler decides the alignment; this is the thin
/// translator the spec calls for.
enum FountainAlignMapper {
    /// Frame alignment for `.frame(maxWidth: .infinity, alignment:)`.
    static func frameAlignment(_ align: FountainLineStyle.Align) -> Alignment {
        switch align {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// Multiline text alignment so a wrapped line keeps its column.
    static func textAlignment(_ align: FountainLineStyle.Align) -> TextAlignment {
        switch align {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Inline span rendering

/// Builds an `AttributedString` from a parsed `FountainLine`, applying the inline
/// emphasis spans (`.italic` / `.bold` / `.underline` / `.note`) that the SHARED
/// `FountainTokenizer` already produced in `line.inlineSpans`. This is a pure
/// function — no SwiftUI rendering side-effects — so it is fully unit-testable.
///
/// CONTRACT — this is the iOS half of the cross-surface emphasis contract; it
/// MUST mirror `ScreenplayMode.applyInlineSpan` (Mac) span-for-span. Both surfaces
/// consume the SAME `FountainInlineSpan` values from MaughamCore; there is NO
/// second emphasis parser here. The tokenizer's span `range` covers the FULL
/// marked run (markers included), so `inner` is derived by trimming `markerLen`
/// characters off each end exactly as the Mac does:
///   .italic    → markerLen 1; italic on inner; fade 1 char each end
///   .bold      → markerLen 2; bold   on inner; fade 2 chars each end
///   .underline → markerLen 1; underline on inner; fade 1 char each end
///   .note      → italic + ~40 % opacity over the WHOLE span (markers included)
///
/// `FountainInlineSpan.range` is DOCUMENT-relative (same coordinate space as
/// `line.range`). It is converted to a `line.content`-relative range by
/// subtracting `line.range.location` (length unchanged). Ranges that fall outside
/// `line.content` (e.g. when content was trimmed/forced-marker-stripped relative
/// to the raw source line) are skipped via the `Range(_:in:)` bounds check —
/// matching the Mac's `guard NSMaxRange(span.range) <= storage.length`.
///
/// `.note` ELEMENT lines are skipped entirely — the whole line is already styled
/// as a note at the element level (matching Mac: `if line.element == .note { continue }`).
///
/// `style.uppercased` is applied BEFORE spans are mapped; marker characters are
/// ASCII so uppercasing does not shift offsets.
enum FountainInlineEmphasisRenderer {

    /// Returns an `AttributedString` for `line.content` with inline emphasis
    /// applied from `line.inlineSpans`, or a plain `AttributedString` when there
    /// are no spans / the line is a `.note` element.
    ///
    /// The caller applies the element-level base font, weight, and italic as
    /// SwiftUI view-/Text-modifiers on top.
    static func attributedContent(
        for line: FountainLine,
        style: FountainLineStyle
    ) -> AttributedString {
        let content = style.uppercased ? line.content.uppercased() : line.content

        // No spans → nothing to layer. `.note` element lines are styled wholesale
        // at the element level, so skip the per-span pass (mirrors the Mac).
        guard !line.inlineSpans.isEmpty, line.element != .note else {
            return AttributedString(content)
        }

        var attr = AttributedString(content)
        let lineOrigin = line.range.location

        for span in line.inlineSpans {
            // Document-relative → line.content-relative.
            let local = NSRange(
                location: span.range.location - lineOrigin,
                length: span.range.length)
            apply(span.kind, over: local, content: content, to: &attr)
        }

        return attr
    }

    // MARK: - Per-span application (mirrors ScreenplayMode.applyInlineSpan)

    private static func apply(
        _ kind: FountainInlineSpan.Kind,
        over span: NSRange,
        content: String,
        to attr: inout AttributedString
    ) {
        switch kind {
        case .note:
            // Italic + dim over the WHOLE span (markers included) — no inner split.
            if let r = attrRange(span, in: content, attr: attr) {
                attr[r].font = Font.body.italic()
                attr[r].foregroundColor = Color.primary.opacity(0.4)
            }

        case .italic:
            applyTrait(.italic, markerLen: 1, span: span, content: content, to: &attr)

        case .bold:
            applyTrait(.bold, markerLen: 2, span: span, content: content, to: &attr)

        case .underline:
            // Underline decoration on inner; fade the single-char markers.
            let inner = NSRange(location: span.location + 1, length: span.length - 2)
            if let r = attrRange(inner, in: content, attr: attr) {
                attr[r].underlineStyle = Text.LineStyle(pattern: .solid)
            }
            fadeMarkers(span: span, markerLen: 1, content: content, to: &attr)
        }
    }

    /// Bold / italic: apply the font trait to the inner range and fade the
    /// `markerLen`-character markers at each end. `inner = [loc+markerLen,
    /// len-2*markerLen]` — identical to the Mac's computation.
    private static func applyTrait(
        _ trait: EmphasisTrait,
        markerLen: Int,
        span: NSRange,
        content: String,
        to attr: inout AttributedString
    ) {
        let inner = NSRange(
            location: span.location + markerLen,
            length: span.length - markerLen * 2)
        if let r = attrRange(inner, in: content, attr: attr) {
            // Layer the trait on whatever base font the run already has; fall back
            // to .body (the element-level base font is applied by the Text modifier
            // in the caller and does not appear as a run attribute here).
            let base = attr[r].font ?? Font.body
            attr[r].font = trait == .bold ? base.bold() : base.italic()
        }
        fadeMarkers(span: span, markerLen: markerLen, content: content, to: &attr)
    }

    /// Fade the leading + trailing `markerLen` characters of `span` to 30 % opacity.
    private static func fadeMarkers(
        span: NSRange,
        markerLen: Int,
        content: String,
        to attr: inout AttributedString
    ) {
        let leading = NSRange(location: span.location, length: markerLen)
        if let r = attrRange(leading, in: content, attr: attr) {
            attr[r].foregroundColor = Color.primary.opacity(0.3)
        }
        let trailing = NSRange(
            location: span.location + span.length - markerLen, length: markerLen)
        if let r = attrRange(trailing, in: content, attr: attr) {
            attr[r].foregroundColor = Color.primary.opacity(0.3)
        }
    }

    /// Convert a `content`-relative NSRange to a `Range<AttributedString.Index>`.
    /// Returns nil for out-of-bounds ranges (the bounds guard that mirrors the
    /// Mac's `NSMaxRange(span.range) <= storage.length`).
    private static func attrRange(
        _ nsRange: NSRange,
        in content: String,
        attr: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard nsRange.location >= 0, nsRange.length >= 0,
              let strRange = Range(nsRange, in: content) else { return nil }
        return Range(strRange, in: attr)
    }
}

/// Font trait to apply for bold / italic spans.
private enum EmphasisTrait { case bold, italic }

// MARK: - View

/// Renders an already-parsed `FountainScript` with semantic screenplay styling.
///
/// TRIPWIRE 4: the script is parsed ONCE upstream (in `DocumentReaderView.task`)
/// and handed in fully-formed. This view does NO parsing — it only maps each
/// pre-parsed `FountainLine` through the O(1) pure `FountainStyler` and builds a
/// `Text`. Never call `FountainTokenizer().parse` from a row body.
struct FountainSemanticRenderer: View {
    let script: FountainScript

    /// Optional in-document search query. When non-empty, lines whose content
    /// contains the query (case-insensitive) get a highlight background.
    var searchQuery: String = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                titlePageBlock

                ForEach(visibleLines, id: \.range.location) { line in
                    row(for: line)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Lines actually drawn — hidden elements (page breaks etc.) are dropped so
    /// they leave no empty row. `range.location` is unique + ascending, a stable
    /// `ForEach` id.
    private var visibleLines: [FountainLine] {
        script.lines.filter { !FountainStyler.style(for: $0).hidden }
    }

    /// Simple key: value header drawn from `script.titlePage` when present.
    @ViewBuilder
    private var titlePageBlock: some View {
        if let titlePage = script.titlePage, !titlePage.isEmpty {
            VStack(spacing: 4) {
                ForEach(titlePage, id: \.range.location) { field in
                    Text("\(field.key): \(field.value)")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.bottom, 24)
        }
    }

    /// One styled line. `FountainStyler.style(for:)` is a pure O(1) mapping, so
    /// calling it per row is fine (tripwire 4 forbids *parsing* in the body, not
    /// this constant-time descriptor lookup).
    @ViewBuilder
    private func row(for line: FountainLine) -> some View {
        let style = FountainStyler.style(for: line)

        styledText(line, style: style)
            .multilineTextAlignment(FountainAlignMapper.textAlignment(style.align))
            .foregroundStyle(style.dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity,
                   alignment: FountainAlignMapper.frameAlignment(style.align))
            .padding(.leading, style.leadingIndent)
            .padding(.trailing, style.trailingIndent)
            .padding(.top, style.topPadding)
            .background(highlightBackground(for: line))
    }

    /// Builds the base `Text` with font / weight / italic / monospace from the
    /// style descriptor.  When the line has inline spans the content is built
    /// as an `AttributedString` so per-span traits layer on top; otherwise a
    /// plain `String`-based `Text` is returned (fast path).
    ///
    /// Element-level weight / italic / foreground are applied as view-modifiers
    /// in `row(for:)` and compose cleanly over any span-level font overrides
    /// already baked into the `AttributedString`.
    private func styledText(_ line: FountainLine, style: FountainLineStyle) -> Text {
        guard !line.inlineSpans.isEmpty, line.element != .note else {
            // Fast path — no spans or a .note element (styled at element level).
            let content = style.uppercased ? line.content.uppercased() : line.content
            var t = Text(content).font(font(for: style.role))
            if style.weight == .bold { t = t.bold() }
            if style.italic { t = t.italic() }
            if style.monospaced { t = t.monospaced() }
            return t
        }

        // Span path: AttributedString carries per-span italic / bold / underline.
        // `.font(baseFont)` on Text sets the default for runs without an explicit
        // font; span-level font overrides (set by FountainInlineEmphasisRenderer)
        // win because they are stored as AttributedString run attributes.
        let attr = FountainInlineEmphasisRenderer.attributedContent(for: line, style: style)
        var t = Text(attr).font(font(for: style.role))
        if style.weight == .bold { t = t.bold() }
        if style.italic { t = t.italic() }
        if style.monospaced { t = t.monospaced() }
        return t
    }

    private func font(for role: FountainLineStyle.Role) -> Font {
        switch role {
        case .body: return .body
        case .callout: return .callout
        case .headline: return .headline
        }
    }

    /// Yellow wash behind any line matching the active search query. Empty query
    /// → clear. v1 is whole-line highlight (not per-range) — simple + good
    /// enough to find a passage while reading.
    @ViewBuilder
    private func highlightBackground(for line: FountainLine) -> some View {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty, line.content.range(of: q, options: .caseInsensitive) != nil {
            Color.yellow.opacity(0.35)
        } else {
            Color.clear
        }
    }
}
