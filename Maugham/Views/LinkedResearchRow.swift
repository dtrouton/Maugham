import SwiftUI
import AppKit

struct LinkedResearchRow: View {
    @Bindable var store: ProjectStore
    let item: ResearchItem
    let onUnlink: () -> Void

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.body)
                Spacer()
                if isExpandable {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onUnlink) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Unlink")
            }
            if expanded {
                preview
                    .padding(.leading, 24)
            }
        }
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

    private var isExpandable: Bool {
        item.kind == .document || item.kind == .image || item.kind == .link
    }

    /// Resolve the item's relative path against the project root.
    private var absolutePath: String? {
        guard let path = item.path else { return nil }
        return store.url.appendingPathComponent(path).path
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .document:
            if let abs = absolutePath,
               let text = try? String(contentsOfFile: abs, encoding: .utf8) {
                ScrollView {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        case .image:
            if let abs = absolutePath,
               let img = NSImage(contentsOfFile: abs) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
            }
        case .link:
            if let urlStr = item.url {
                Text(urlStr)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        default:
            EmptyView()
        }
    }
}
