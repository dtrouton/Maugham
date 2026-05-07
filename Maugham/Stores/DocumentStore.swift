import Foundation
import AppKit

@MainActor
@Observable
public final class DocumentStore {

    public let projectURL: URL

    /// Loaded from `.maugham/ui-state.json` on open; nil-defaulted if absent.
    public private(set) var uiState: UIState

    private var presenter: ProjectFolderPresenter?
    private var uiStateScheduler: DebounceScheduler<UIState>!

    private init(projectURL: URL, uiState: UIState) {
        self.projectURL = projectURL
        self.uiState = uiState
    }

    public static func open(url: URL) async throws -> DocumentStore {
        let uiStateURL = url
            .appendingPathComponent(".maugham")
            .appendingPathComponent("ui-state.json")
        let uiState = UIState.loadOrEmpty(from: uiStateURL)

        let store = DocumentStore(projectURL: url, uiState: uiState)
        store.uiStateScheduler = DebounceScheduler<UIState>(
            delay: .milliseconds(500)
        ) { [weak store] state in
            await store?.persistUIState(state)
        }

        let presenter = ProjectFolderPresenter(
            projectURL: url, delegate: store)
        NSFileCoordinator.addFilePresenter(presenter)
        store.presenter = presenter

        return store
    }

    public func close() async {
        await uiStateScheduler.flush()
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self.presenter = nil
        }
    }

    /// Mutate UI state. The new value is persisted on a 500ms debounce.
    public func updateUIState(_ transform: (inout UIState) -> Void) {
        var draft = uiState
        transform(&draft)
        guard draft != uiState else { return }
        uiState = draft
        uiStateScheduler.schedule(draft)
    }

    private func persistUIState(_ state: UIState) async {
        let dotDir = projectURL.appendingPathComponent(".maugham")
        let url = dotDir.appendingPathComponent("ui-state.json")
        do {
            try FileManager.default.createDirectory(
                at: dotDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            // UI state is best-effort; log but don't surface to user.
        }
    }
}

// MARK: - ProjectFolderPresenterDelegate (skeleton)

extension DocumentStore: ProjectFolderPresenterDelegate {
    public func presenterDidChangeSubitem(at url: URL) {
        // Filled in by Task 9
    }

    public func presenterDidObserveDirectoryChange() {
        // Filled in by Task 9
    }
}
