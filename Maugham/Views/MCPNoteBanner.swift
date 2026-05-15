import SwiftUI

/// Transient banner displayed at the top of the editor pane when Claude
/// creates a research note via MCP. Mirrors the SaveFlashOverlay glass
/// material style from milestone 1c. Auto-dismisses after 8s (caller-managed).
struct MCPNoteBanner: View {
    let title: String
    let count: Int          // 1 for single, >1 when multiple within window
    let onShow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            Button(count > 1 ? "Show latest" : "Show", action: onShow)
                .buttonStyle(.borderless)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1))
        .padding(12)
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private var message: String {
        if count > 1 {
            return "Claude added \(count) notes to research."
        } else {
            return "Claude added \"\(title)\" to research."
        }
    }
}
