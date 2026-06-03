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

/// Inline-emphasis patterns mirroring the tokenizer's scanRegex calls. Used to
/// re-locate span markers within `line.content` at render time (we re-scan the
/// content string rather than mapping the source-document-relative NSRanges
/// stored in `FountainInlineSpan.range`, which would require knowing leading-
/// whitespace and forced-marker offsets that aren't preserved in FountainLine).
private enum InlineEmphasisPattern {
    static let bold    = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*"#)
    static let italic  = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#)
    static let underline = try! NSRegularExpression(pattern: #"_([^_\n]+)_"#)
    static let note    = try! NSRegularExpression(pattern: #"\[\[.*?\]\]"#)
}

/// Font trait to apply for bold / italic spans.
private enum EmphasisTrait { case bold, italic }

/// Builds an `AttributedString` from a parsed `FountainLine`, applying inline
/// emphasis (italic / bold / underline / note) on top of the element-level base
/// style. This is a pure function — no SwiftUI rendering side-effects — so it is
/// fully unit-testable.
///
/// CONTRACT (mirrors `ScreenplayMode.applyInlineSpan` on Mac):
///   .italic    → italic trait on inner text; markers faded to 30 % opacity
///   .bold      → bold trait on inner text; markers faded to 30 % opacity
///   .underline → underline decoration on inner text; markers faded to 30 % opacity
///   .note      → italic + ~40 % opacity over the full [[...]] span (incl. brackets)
///
/// Lines whose element is `.note` are skipped — the whole line is already styled
/// as a note at the element level (matching Mac: `if line.element == .note { continue }`).
///
/// `style.uppercased` is applied BEFORE span-scanning so ASCII marker characters
/// survive uppercasing unchanged.
enum FountainInlineEmphasisRenderer {

    /// Returns an `AttributedString` for `line.content` with inline emphasis
    /// applied, or a plain `AttributedString(raw)` when no spans are present /
    /// the line is a `.note` element.
    ///
    /// The caller is responsible for applying the element-level base font,
    /// weight, and italic as SwiftUI view-/Text-modifiers on top.
    static func attributedContent(
        for line: FountainLine,
        style: FountainLineStyle
    ) -> AttributedString {
        let raw = style.uppercased ? line.content.uppercased() : line.content

        guard line.element != .note, !line.inlineSpans.isEmpty else {
            return AttributedString(raw)
        }

        var attr = AttributedString(raw)
        let fullNS = NSRange(location: 0, length: (raw as NSString).length)

        // Note spans first — dim + italic over [[...]] including brackets.
        applyMatches(InlineEmphasisPattern.note, in: raw, range: fullNS) { outer, _ in
            applyNoteSpan(outerNS: outer, raw: raw, to: &attr)
        }

        // Bold (**text**): bold trait on inner, fade ** markers.
        applyMatches(InlineEmphasisPattern.bold, in: raw, range: fullNS) { outer, inner in
            applyTraitSpan(outerNS: outer, innerNS: inner,
                           markerLength: 2, trait: .bold,
                           raw: raw, to: &attr)
        }

        // Italic (*text*): italic trait on inner, fade * markers.
        applyMatches(InlineEmphasisPattern.italic, in: raw, range: fullNS) { outer, inner in
            applyTraitSpan(outerNS: outer, innerNS: inner,
                           markerLength: 1, trait: .italic,
                           raw: raw, to: &attr)
        }

        // Underline (_text_): underline on inner, fade _ markers.
        applyMatches(InlineEmphasisPattern.underline, in: raw, range: fullNS) { outer, inner in
            applyUnderlineSpan(outerNS: outer, innerNS: inner,
                               markerLength: 1, raw: raw, to: &attr)
        }

        return attr
    }

    // MARK: - Private helpers

    /// Enumerate all matches of `pattern` in `raw` within `range`.
    /// Calls `handler(outerRange, innerRange)` where `inner` is capture group 1
    /// when present, or equals `outer` otherwise (note pattern has no group).
    private static func applyMatches(
        _ pattern: NSRegularExpression,
        in raw: String,
        range: NSRange,
        handler: (NSRange, NSRange) -> Void
    ) {
        pattern.enumerateMatches(in: raw, options: [], range: range) { match, _, _ in
            guard let match else { return }
            let outer = match.range
            let inner = match.numberOfRanges > 1 ? match.range(at: 1) : outer
            handler(outer, inner)
        }
    }

    /// Convert an NSRange in `raw` to a `Range<AttributedString.Index>`.
    private static func attrRange(
        _ nsRange: NSRange,
        in raw: String,
        attr: AttributedString
    ) -> Range<AttributedString.Index>? {
        guard let strRange = Range(nsRange, in: raw) else { return nil }
        return Range(strRange, in: attr)
    }

    /// [[...]] span: italic + dimmed over the full bracket pair.
    private static func applyNoteSpan(
        outerNS: NSRange,
        raw: String,
        to attr: inout AttributedString
    ) {
        guard let r = attrRange(outerNS, in: raw, attr: attr) else { return }
        // Match Mac: italic + syntax-punctuation-dimmed color (0.4 opacity).
        attr[r].font = Font.body.italic()
        attr[r].foregroundColor = Color.primary.opacity(0.4)
    }

    /// Bold or italic span: apply the trait to inner text, fade the markers.
    private static func applyTraitSpan(
        outerNS: NSRange,
        innerNS: NSRange,
        markerLength: Int,
        trait: EmphasisTrait,
        raw: String,
        to attr: inout AttributedString
    ) {
        if let innerR = attrRange(innerNS, in: raw, attr: attr) {
            // Layer trait on whatever base font the run already has; fall back
            // to .body (the element-level base font is set by the Text modifier
            // in the caller and doesn't appear as a run attribute here yet).
            let base = attr[innerR].font ?? Font.body
            attr[innerR].font = trait == .bold ? base.bold() : base.italic()
        }
        fadeMarker(NSRange(location: outerNS.location, length: markerLength),
                   raw: raw, in: &attr)
        fadeMarker(NSRange(location: outerNS.location + outerNS.length - markerLength,
                           length: markerLength),
                   raw: raw, in: &attr)
    }

    /// Underline span: underline on inner text, fade the markers.
    private static func applyUnderlineSpan(
        outerNS: NSRange,
        innerNS: NSRange,
        markerLength: Int,
        raw: String,
        to attr: inout AttributedString
    ) {
        if let innerR = attrRange(innerNS, in: raw, attr: attr) {
            attr[innerR].underlineStyle = Text.LineStyle(pattern: .solid)
        }
        fadeMarker(NSRange(location: outerNS.location, length: markerLength),
                   raw: raw, in: &attr)
        fadeMarker(NSRange(location: outerNS.location + outerNS.length - markerLength,
                           length: markerLength),
                   raw: raw, in: &attr)
    }

    /// Fade `nsRange` to 30 % opacity (marker-character treatment).
    private static func fadeMarker(
        _ nsRange: NSRange,
        raw: String,
        in attr: inout AttributedString
    ) {
        guard let r = attrRange(nsRange, in: raw, attr: attr) else { return }
        attr[r].foregroundColor = Color.primary.opacity(0.3)
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
