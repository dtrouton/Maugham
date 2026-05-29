import SwiftUI
import MaughamCore

/// MaughamPhone — the iOS companion to the Mac writing app.
///
/// Four tabs: Capture (out-and-about text/photo/voice into the project inbox),
/// Read (browse manuscripts + research), Annotations (triage Claude's open
/// annotations), Settings. v1 ships capture + read + annotation review against
/// a security-scoped-bookmarked iCloud Drive projects folder.
///
/// This is the Phase-D0 scaffold: the tabs are placeholders until Phases D/E/F
/// fill them. The storage substrate (DownloadCoordinator / CoordinatedFileIO /
/// RecentsTracker) lands first because iCloud-Drive eviction handling must be in
/// place before any read surface can avoid silently rendering "empty."
@main
struct MaughamPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}

private struct RootTabView: View {
    enum Tab: Hashable { case capture, read, annotations, settings }
    @State private var selection: Tab = .capture

    var body: some View {
        TabView(selection: $selection) {
            placeholder("Capture", systemImage: "plus.circle")
                .tabItem { Label("Capture", systemImage: "plus.circle") }
                .tag(Tab.capture)

            placeholder("Read", systemImage: "book")
                .tabItem { Label("Read", systemImage: "book") }
                .tag(Tab.read)

            placeholder("Annotations", systemImage: "bubble.left.and.bubble.right")
                .tabItem { Label("Annotations", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.annotations)

            placeholder("Settings", systemImage: "gearshape")
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
    }

    private func placeholder(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text("Coming soon."))
    }
}
