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

    public private(set) var openDocumentPath: String?
    public private(set) var lastWrittenText: String = ""

    private var saveScheduler: DebounceScheduler<SavePayload>!

    private struct SavePayload: Sendable {
        let path: String
        let text: String
    }

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
        try? await flushPendingSave()
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

    /// Bind to a new document. Reads from disk, sets lastWrittenText, flushes
    /// any pending save for the previously-open document.
    public func openDocument(at path: String) async throws -> String {
        if openDocumentPath != nil {
            try? await flushPendingSave()
        }
        let url = projectURL.appendingPathComponent(path)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        openDocumentPath = path
        lastWrittenText = text
        // Lazy-init save scheduler on first openDocument.
        if saveScheduler == nil {
            saveScheduler = DebounceScheduler<SavePayload>(
                delay: .milliseconds(750)
            ) { [weak self] payload in
                try? await self?.performSave(path: payload.path, text: payload.text)
            }
        }
        return text
    }

    public func scheduleSave(for path: String, text: String) {
        guard saveScheduler != nil else { return }
        saveScheduler.schedule(SavePayload(path: path, text: text))
    }

    public func flushPendingSave() async throws {
        guard let saveScheduler else { return }
        await saveScheduler.flush()
    }

    private func performSave(path: String, text: String) async throws {
        let url = projectURL.appendingPathComponent(path)
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var saveError: Error?
        coordinator.coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordError
        ) { writeURL in
            do {
                try text.data(using: .utf8)?
                    .write(to: writeURL, options: [.atomic])
                self.lastWrittenText = text
            } catch {
                saveError = error
            }
        }
        if let coordError { throw coordError }
        if let saveError { throw saveError }
    }

    /// Coordinated atomic manifest write. Uses the same coordinator as
    /// document writes so external watchers see the change cleanly.
    public func writeManifest(_ data: Data) async throws {
        let manifestURL = projectURL.appendingPathComponent("project.maugham.json")
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(
            writingItemAt: manifestURL, options: .forReplacing, error: &coordError
        ) { writeURL in
            do {
                let tmpURL = writeURL.appendingPathExtension("tmp")
                try data.write(to: tmpURL, options: [.atomic])
                _ = try FileManager.default.replaceItemAt(writeURL, withItemAt: tmpURL)
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    /// Coordinated read for callers outside ProjectStore.
    public func readManifest() async throws -> Data {
        let manifestURL = projectURL.appendingPathComponent("project.maugham.json")
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var data: Data?
        var readError: Error?
        coordinator.coordinate(
            readingItemAt: manifestURL, options: [], error: &coordError
        ) { readURL in
            do {
                data = try Data(contentsOf: readURL)
            } catch {
                readError = error
            }
        }
        if let coordError { throw coordError }
        if let readError { throw readError }
        return data ?? Data()
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
