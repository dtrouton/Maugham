import SwiftUI

struct ProjectWindow: View {
    @State private var store: ProjectStore?
    @State private var loadError: String?
    @Environment(ThemeManager.self) private var themeManager

    let url: URL

    var body: some View {
        Group {
            if let store {
                EditorSurface(
                    text: Binding(
                        get: { store.manuscriptText },
                        set: { newValue in
                            store.manuscriptText = newValue
                            Task { try? await store.save() }
                        }
                    ),
                    theme: themeManager.theme,
                    typography: themeManager.typography,
                    mode: ProseMode(),
                    typewriterScroll: themeManager.typewriterScroll
                )
                .navigationTitle(store.manifest.title)
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Couldn't open project")
                        .font(.headline)
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(48)
            } else {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        do {
            store = try await ProjectStore.load(from: url)
            loadError = nil
        } catch ProjectStoreError.manifestNotFound {
            loadError = "No project.maugham.json was found in this folder."
        } catch ProjectStoreError.manifestUnreadable(let msg) {
            loadError = "Manifest is corrupt or unreadable: \(msg)"
        } catch ProjectStoreError.manuscriptUnreadable(let msg) {
            loadError = "Manuscript file couldn't be read: \(msg)"
        } catch {
            loadError = error.localizedDescription
        }
    }
}
