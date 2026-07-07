import SwiftUI
import MaughamCore

struct LinkedResearchRow: View {
    let item: ResearchItem
    let onUnlink: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
            Text(item.title)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let onUnlink {
                Button(action: onUnlink) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Unlink")
            }
        }
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch item.kind {
        case .document: return "doc.text"
        case .image:    return "photo"
        case .pdf:      return "doc.richtext"
        case .audio:    return "waveform"
        case .link:     return "link"
        case .none:     return "folder"
        }
    }
}
