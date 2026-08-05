import SwiftUI

/// The muscle-memory acknowledgment: a capsule at the top of the window that
/// says the key did something, then goes away.
///
/// Parameterised rather than copied for the compiler's run key (M2): the
/// register is the whole point of reusing it — ⌘S and ⌘R acknowledge the same
/// way because they are the same kind of promise, and a second overlay with its
/// own timing and typography would be a different one.
struct SaveFlashOverlay: View {
    @Binding var isShowing: Bool
    var label: String = "Saved"
    var systemImage: String = "checkmark"

    var body: some View {
        Group {
            if isShowing {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                    Text(label)
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
