import SwiftUI
import MaughamCore

struct SceneNavigatorPane: View {
    let script: FountainScript?
    /// Called with the line range location when the user clicks a scene.
    let onSelect: (Int) -> Void

    var body: some View {
        // Compute every scene's page number + length in ONE O(document) pass,
        // here, instead of two O(document) walks per row per render (tripwire
        // 4). With N scenes this turns O(N × document) per render into
        // O(document). The rows read pre-computed values only.
        let summaries = script?.sceneSummaries() ?? []
        if !summaries.isEmpty {
            List {
                ForEach(Array(summaries.enumerated()), id: \.offset) { _, summary in
                    sceneRow(for: summary)
                }
            }
            .listStyle(.sidebar)
        } else {
            VStack {
                Text("No scenes yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Type INT. or EXT. to add one.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func sceneRow(for summary: FountainScript.SceneSummary) -> some View {
        Button {
            onSelect(summary.line.range.location)
        } label: {
            HStack(spacing: 8) {
                Text(summary.line.content)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(Self.rowCaption(for: summary))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Returns the compact "p1 · ¼" trailing caption from pre-computed scene
    /// metrics. Empty length info collapses to just "p\(page)". Format is
    /// pixel-identical to the prior per-scene version.
    static func rowCaption(for summary: FountainScript.SceneSummary) -> String {
        let length = formatPagesCompact(summary.length)
        if length.isEmpty {
            return "p\(summary.pageNumber)"
        }
        return "p\(summary.pageNumber) · \(length)"
    }

    /// Formats fractional pages compactly: "0" hidden as "—", "0.25" as "¼p",
    /// "0.5" as "½p", "0.75" as "¾p", whole numbers as "1p" / "2p", and
    /// mixed as "1¼p" / "2½p" using nearest quarter rounding.
    static func formatPages(_ pages: Double) -> String {
        if pages <= 0 { return "—" }
        let quarters = (pages * 4).rounded()
        let whole = Int(quarters / 4)
        let frac = Int(quarters.truncatingRemainder(dividingBy: 4))
        let fracGlyph: String
        switch frac {
        case 0: fracGlyph = ""
        case 1: fracGlyph = "¼"
        case 2: fracGlyph = "½"
        case 3: fracGlyph = "¾"
        default: fracGlyph = ""
        }
        if whole == 0 && frac == 0 {
            // Tiny scene that rounds below ¼ — show "<¼p"
            return "<¼p"
        }
        if whole == 0 {
            return "\(fracGlyph)p"
        }
        return "\(whole)\(fracGlyph)p"
    }

    /// Compact form of `formatPages` for inline display next to the page
    /// number. Drops the trailing "p" since the prefix already implies pages.
    /// Returns "" for ≤0; "¼", "½", "¾", "1" / "1¼" / "2½" otherwise.
    static func formatPagesCompact(_ pages: Double) -> String {
        if pages <= 0 { return "" }
        let quarters = (pages * 4).rounded()
        let whole = Int(quarters / 4)
        let frac = Int(quarters.truncatingRemainder(dividingBy: 4))
        let fracGlyph: String
        switch frac {
        case 1: fracGlyph = "¼"
        case 2: fracGlyph = "½"
        case 3: fracGlyph = "¾"
        default: fracGlyph = ""
        }
        if whole == 0 && frac == 0 { return "<¼" }
        if whole == 0 { return fracGlyph }
        return "\(whole)\(fracGlyph)"
    }
}
