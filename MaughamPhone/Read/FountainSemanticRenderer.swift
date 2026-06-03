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

        case .emphasis(let traits):
            // `span` is content-relative and marker-free. Layer traits on the
            // existing font so they compose.
            if let r = attrRange(span, in: content, attr: attr) {
                var f = attr[r].font ?? Font.body
                if traits.contains(.bold) { f = f.bold() }
                if traits.contains(.italic) { f = f.italic() }
                attr[r].font = f
            }

        case .emphasisMarker:
            if let r = attrRange(span, in: content, attr: attr) {
                attr[r].foregroundColor = Color.primary.opacity(0.3)
            }

        case .underline:
            // Underline decoration on inner; fade the single-char markers.
            let inner = NSRange(location: span.location + 1, length: span.length - 2)
            if let r = attrRange(inner, in: content, attr: attr) {
                attr[r].underlineStyle = Text.LineStyle(pattern: .solid)
            }
            fadeMarkers(span: span, markerLen: 1, content: content, to: &attr)
        }
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

    /// Base point size the title-page `scale` multiplier is applied against on
    /// the phone. `.callout` is roughly 16pt at default Dynamic Type — keeping
    /// this constant means the per-key scales translate directly from the Mac
    /// contract while staying legible on a narrow screen.
    private static let titlePageBaseSize: CGFloat = 16

    /// Per-key styled header drawn from `script.titlePage` when present. Each
    /// field's visual treatment comes from the shared `TitlePageFieldStyle`
    /// contract (Title large/bold, Credit/Source italic, "other" keys dimmed),
    /// the same source the Mac editor consumes.
    @ViewBuilder
    private var titlePageBlock: some View {
        if let titlePage = script.titlePage, !titlePage.isEmpty {
            VStack(spacing: 4) {
                ForEach(titlePage, id: \.range.location) { field in
                    let style = TitlePageFieldStyle.style(forKey: field.key)
                    Text("\(field.key): \(field.value)")
                        .font(Self.titlePageFont(for: style))
                        .multilineTextAlignment(
                            style.alignment == .center ? .center : .leading)
                        .foregroundStyle(style.dimmed ? AnyShapeStyle(.secondary)
                                                       : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity,
                               alignment: style.alignment == .center ? .center : .leading)
                }
            }
            .padding(.bottom, 24)
        }
    }

    /// Translate a `TitlePageFieldStyle` into a SwiftUI `Font` for the phone.
    /// Exposed (internal) so the contract test can assert the phone consumes
    /// `TitlePageFieldStyle.style` for a key.
    static func titlePageFont(for style: TitlePageFieldStyle) -> Font {
        var font = Font.system(
            size: titlePageBaseSize * CGFloat(style.scale),
            weight: style.bold ? .bold : .regular)
        if style.italic { font = font.italic() }
        return font
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
            if style.underline { t = t.underline() }
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
        if style.underline { t = t.underline() }
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
