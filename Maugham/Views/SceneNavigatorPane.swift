import SwiftUI

struct SceneNavigatorPane: View {
    let script: FountainScript?
    /// Called with the line range location when the user clicks a scene.
    let onSelect: (Int) -> Void

    var body: some View {
        if let scenes = scenes, !scenes.isEmpty {
            List {
                ForEach(Array(scenes.enumerated()), id: \.offset) { _, scene in
                    sceneRow(for: scene)
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

    private var scenes: [FountainLine]? {
        script?.lines.filter { $0.element == .sceneHeading }
    }

    @ViewBuilder
    private func sceneRow(for scene: FountainLine) -> some View {
        Button {
            onSelect(scene.range.location)
        } label: {
            HStack(spacing: 8) {
                Text(scene.content)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(rowCaption(for: scene))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Returns the compact "p1 · ¼" trailing caption. Empty when no length info.
    private func rowCaption(for scene: FountainLine) -> String {
        let page = pageNumber(for: scene)
        let length = Self.formatPagesCompact(lengthValue(for: scene))
        if length.isEmpty {
            return "p\(page)"
        }
        return "p\(page) · \(length)"
    }

    private func lengthValue(for scene: FountainLine) -> Double {
        script?.sceneLength(startingAt: scene) ?? 0
    }

    private func pageNumber(for scene: FountainLine) -> Int {
        script?.pageNumber(at: scene) ?? 1
    }

    private func lengthLabel(for scene: FountainLine) -> String {
        guard let script else { return "" }
        let pages = script.sceneLength(startingAt: scene)
        return Self.formatPages(pages)
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
