import SwiftUI

struct TypographySettingsTab: View {
    @Bindable var themeManager: UserPreferences

    var body: some View {
        Form {
            Toggle("Smart quotes (\u{201C}\u{2026}\u{201D} instead of \"\u{2026}\")",
                   isOn: $themeManager.typography.smartQuotes)
            Toggle("Em-dash auto-replace (-- becomes —)",
                   isOn: $themeManager.typography.emDashAutoReplace)
            Toggle("Ellipsis auto-replace (... becomes …)",
                   isOn: $themeManager.typography.ellipsisAutoReplace)

            Text("These transformations happen as you type and respect undo. "
                 + "Disable them if you prefer raw ASCII.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
