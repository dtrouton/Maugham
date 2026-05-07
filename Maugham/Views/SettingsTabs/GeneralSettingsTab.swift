import SwiftUI

struct GeneralSettingsTab: View {
    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 8) {
                Text("General settings")
                    .font(.headline)
                Text("Default project location, default author name, and other "
                     + "general preferences arrive in milestone 1d.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
