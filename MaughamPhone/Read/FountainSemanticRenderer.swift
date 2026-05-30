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
        let text = style.uppercased ? line.content.uppercased() : line.content

        styledText(text, style: style)
            .multilineTextAlignment(FountainAlignMapper.textAlignment(style.align))
            .foregroundStyle(style.dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity,
                   alignment: FountainAlignMapper.frameAlignment(style.align))
            .padding(.leading, style.leadingIndent)
            .padding(.trailing, style.trailingIndent)
            .padding(.top, style.topPadding)
            .background(highlightBackground(for: line))
    }

    /// Builds the base `Text` with font/weight/italic/monospace from the
    /// descriptor. Font modifiers chain off `Text` so they compose before the
    /// view-level modifiers above.
    private func styledText(_ content: String, style: FountainLineStyle) -> Text {
        var t = Text(content).font(font(for: style.role))
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
