import SwiftUI

/// Transient banner displayed at the top of the editor pane when Claude
/// creates a research note via MCP. Mirrors the SaveFlashOverlay glass
/// material style from milestone 1c. Auto-dismisses after 8s (caller-managed).
///
/// **Three callers, one banner.** 1C-c2's promotion confirmation reuses this
/// rather than inventing a second transient-banner look; the Claude sentence
/// moved into the first initialiser so that call site is unchanged (it lives in
/// `ProjectWindow.body`, which has no expression budget to spare) and the second
/// takes a message and a dismiss and nothing else. 1C-c3's canvas arrival is the
/// third, and it is the first caller that needs both halves — a sentence of its
/// own AND somewhere to go — because what it announces is neither a research note
/// (the first initialiser's own noun) nor something that happened in this window
/// a moment ago.
struct MCPNoteBanner: View {
    private let message: String
    private let systemImage: String
    /// Nil when there is nowhere to go — the promotion banner names what it
    /// produced and does not navigate.
    private let actionTitle: String?
    private let onShow: (() -> Void)?
    private let onDismiss: () -> Void

    init(title: String, count: Int,          // 1 for single, >1 when multiple within window
         onShow: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.message = count > 1
            ? "Claude added \(count) notes to research."
            : "Claude added \"\(title)\" to research."
        self.systemImage = "sparkles"
        self.actionTitle = count > 1 ? "Show latest" : "Show"
        self.onShow = onShow
        self.onDismiss = onDismiss
    }

    /// One sentence, somewhere to go, and a dismiss — for an arrival whose own
    /// wording belongs to the caller.
    ///
    /// **Why the first initialiser could not serve.** It composes its sentence
    /// itself and names *research*, and it decides the action title from the
    /// count; a canvas arrival is a number of cards in a named region and its
    /// sentence is a fact about the CANVAS. Composing it here would put a second
    /// wording of "what Claude added" inside a view that cannot see the region —
    /// so the sentence arrives resolved, and this initialiser adds nothing to it.
    init(message: String, actionTitle: String,
         onShow: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.message = message
        // The same glyph the research sentence carries: one mark for "this is
        // Claude" wherever a banner says so.
        self.systemImage = "sparkles"
        self.actionTitle = actionTitle
        self.onShow = onShow
        self.onDismiss = onDismiss
    }

    /// One sentence and a dismiss — a confirmation for something that already
    /// happened in this window.
    init(message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.systemImage = "checkmark.circle"
        self.actionTitle = nil
        self.onShow = nil
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            if let actionTitle, let onShow {
                Button(actionTitle, action: onShow)
                    .buttonStyle(.borderless)
            }
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
}
