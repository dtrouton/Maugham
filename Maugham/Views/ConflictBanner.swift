import SwiftUI

struct ConflictBanner: View {
    let conflict: ConflictState
    let onKeepMine: () -> Void
    let onUseCloud: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text("Outside change detected.")
                    .font(.callout)
                    .fontWeight(.medium)
                Text(conflict.phrasing)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Keep mine", action: onKeepMine)
                    .buttonStyle(.borderedProminent)
                Button("Use cloud", action: onUseCloud)
                    .buttonStyle(.bordered)
                Button("Show diff") { /* Phase 2 */ }
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .help("Available in Phase 2")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5),
            alignment: .bottom)
    }
}
