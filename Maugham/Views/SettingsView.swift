import SwiftUI

struct SettingsView: View {
    @Environment(UserPreferences.self) private var themeManager

    var body: some View {
        TabView {
            EditorSettingsTab(themeManager: themeManager)
                .tabItem { Label("Editor", systemImage: "textformat") }
            ThemeSettingsTab(themeManager: themeManager)
                .tabItem { Label("Theme", systemImage: "paintbrush") }
            TypographySettingsTab(themeManager: themeManager)
                .tabItem { Label("Typography", systemImage: "quote.bubble") }
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 540, minHeight: 360)
        .padding(20)
    }
}
