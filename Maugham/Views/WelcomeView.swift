import SwiftUI
import MaughamCore

struct WelcomeView: View {
    let recents: [URL]
    let onNewProject: () -> Void
    let onOpenProject: () -> Void
    let onOpenRecent: (URL) -> Void
    let onForgetRecent: (URL) -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 320)
            Divider()
            recentsList
                .frame(minWidth: 320)
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(BuildVariant.current.displayName)
                .font(.system(size: 36, weight: .light, design: .serif))
                .padding(.bottom, 4)
            Text("A focus text editor for serious creative writing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)

            Button(action: onNewProject) {
                Label("New project…", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: onOpenProject) {
                Label("Open project…", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.large)

            Spacer()
        }
        .padding(32)
    }

    @ViewBuilder
    private var recentsList: some View {
        if recents.isEmpty {
            VStack {
                Spacer()
                Text("No recent projects.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(recents, id: \.self) { url in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .font(.headline)
                        Text(url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { onOpenRecent(url) }
                .contextMenu {
                    Button("Open", action: { onOpenRecent(url) })
                    Button("Remove from Recents", action: { onForgetRecent(url) })
                }
            }
            .listStyle(.inset)
        }
    }
}

#Preview {
    WelcomeView(
        recents: [
            URL(fileURLWithPath: "/Users/example/Documents/My Story"),
            URL(fileURLWithPath: "/Users/example/iCloud/Razor's Edge")
        ],
        onNewProject: {},
        onOpenProject: {},
        onOpenRecent: { _ in },
        onForgetRecent: { _ in }
    )
}
