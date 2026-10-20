import SwiftUI

struct InspectorTagsField: View {
    @Binding var tags: [String]
    let suggestions: [String]
    let onCommit: () -> Void
    var placeholder: String = "Add tag…"
    /// Tags split a typed line on commas; a citation's authors do not, since
    /// "Surname, Given" is one author (`CitationStyle` reads the surname
    /// before the comma).
    var splitsOnCommas: Bool = true

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chipRow
            HStack(spacing: 6) {
                TextField(placeholder, text: $draft, onCommit: commitDraft)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
            }
            if !filteredSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(filteredSuggestions, id: \.self) { s in
                            Button(s) {
                                draft = s
                                commitDraft()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var chipRow: some View {
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag).font(.caption)
                    Button {
                        tags.removeAll { $0 == tag }
                        onCommit()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15),
                            in: Capsule())
            }
        }
    }

    private var filteredSuggestions: [String] {
        let alreadyTagged = Set(tags.map { $0.lowercased() })
        let typed = draft.trimmingCharacters(in: .whitespaces).lowercased()
        return suggestions
            .filter { !alreadyTagged.contains($0.lowercased()) }
            .filter { typed.isEmpty ||
                $0.lowercased().hasPrefix(typed) }
            .prefix(6)
            .map { $0 }
    }

    /// The entries a typed line adds: trimmed, blanks dropped, split on
    /// commas only when the field asks for it.
    static func entries(from draft: String, splitsOnCommas: Bool) -> [String] {
        let pieces = splitsOnCommas ? draft.split(separator: ",").map(String.init) : [draft]
        return pieces
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func commitDraft() {
        let parts = Self.entries(from: draft, splitsOnCommas: splitsOnCommas)
        var changed = false
        for part in parts where !tags.contains(where: { $0.lowercased() == part.lowercased() }) {
            tags.append(part)
            changed = true
        }
        draft = ""
        if changed { onCommit() }
    }
}

/// Simple flow layout — wraps children to multiple lines if they overflow
/// horizontally. Standard SwiftUI doesn't ship one for macOS 14, so include
/// a lightweight implementation.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout Void
    ) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
