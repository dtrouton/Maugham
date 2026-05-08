import SwiftUI

struct ConflictBanner: View {
    let conflict: ConflictState
    let onKeepMine: () -> Void
    let onUseCloud: () -> Void
    /// nil = hide the Show diff button (e.g. for manifest conflicts).
    let onShowDiff: (() -> Void)?

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
                if let onShowDiff {
                    Button("Show diff", action: onShowDiff)
                        .buttonStyle(.bordered)
                }
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
