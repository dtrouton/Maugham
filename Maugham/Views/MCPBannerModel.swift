import Foundation

/// Owns the transient "Claude added a note" banner state, extracted from
/// ProjectWindow so the four fields + dismiss task no longer thread through a
/// ViewModifier purely to dodge the SwiftUI type-checker.
///
/// Behavior matches the original ProjectWindow inline logic exactly:
/// - Each note added increments `count` (not sets it) and updates `title`/`latestId`.
/// - A new call cancels any existing 8-second auto-dismiss and starts a fresh one.
/// - `dismiss()` resets all fields and cancels the task.
@MainActor @Observable
final class MCPBannerModel {
    var title: String?
    var count: Int = 0
    var latestId: String?
    private var dismissTask: Task<Void, Never>?

    /// Called each time an MCP note-added notification fires for this project.
    /// Increments the count, updates title and latest id, and restarts the 8s
    /// auto-dismiss timer.
    func bump(title: String, latestId: String) {
        self.title = title
        self.count += 1
        self.latestId = latestId
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismiss() }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        title = nil
        count = 0
        latestId = nil
    }
}
