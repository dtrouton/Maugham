import SwiftUI

struct GeneralSettingsTab: View {
    @Bindable var themeManager: UserPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Allow Claude to connect (MCP)", isOn: $themeManager.mcpEnabled)
                Text("When on and Maugham is running, Claude Desktop can read your open projects and add research notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Claude integration")
            }

            Section {
                TextField(
                    "Your name (for review comments)",
                    text: $themeManager.collaboratorDisplayName,
                    prompt: Text(UserPreferences.defaultCollaboratorDisplayName))
                Text("Attributed on review comments and suggestions you make in the editor. Leave blank to use your macOS account name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Reviewer identity")
            }
        }
        .formStyle(.grouped)
    }
}
