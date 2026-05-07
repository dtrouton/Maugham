import SwiftUI

struct ThemeSettingsTab: View {
    @Bindable var themeManager: UserPreferences

    var body: some View {
        Form {
            Picker("Theme", selection: $themeManager.theme) {
                Text("Follow System").tag(Theme.followSystem)
                Text("Light").tag(Theme.light)
                Text("Dark").tag(Theme.dark)
                Text("Sepia").tag(Theme.sepia)
            }
            .pickerStyle(.radioGroup)

            Text("Light and Dark match the system appearance you expect; "
                 + "Sepia is a paper-like warm neutral. "
                 + "Follow System mirrors macOS's current Light/Dark mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
