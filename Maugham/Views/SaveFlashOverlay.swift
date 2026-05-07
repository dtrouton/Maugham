import SwiftUI

struct SaveFlashOverlay: View {
    @Binding var isShowing: Bool

    var body: some View {
        Group {
            if isShowing {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Saved")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                .foregroundStyle(.secondary)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 16)
        .animation(.easeInOut(duration: 0.18), value: isShowing)
    }
}
