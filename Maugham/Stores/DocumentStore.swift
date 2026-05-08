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

    /// Per-document cursor positions kept in-memory for the lifetime of this
    /// DocumentStore. Restored when the user revisits a document; lost on
    /// project window close. Persistence to .maugham/ui-state.json can come
    /// in a later milestone.
    private var cursorPositions: [String: Int] = [:]

    /// Read the saved cursor location for a document path.
    public func cursor(for path: String) -> Int? {
        cursorPositions[path]
    }

    /// Save a cursor location for a document path.
    public func setCursor(_ position: Int, for path: String) {
        cursorPositions[path] = position
    }

    /// Set when an external change is detected while the user has unsaved
    /// edits. Cleared on resolution.
    public private(set) var pendingConflict: ConflictState?

    /// Used by EditorHost to know what the editor's currently-displayed text
    /// is, so the conflict-detection pass can compare local vs disk vs
    /// last-written. Set by EditorHost on every keystroke.
    public var currentDocumentText: String = ""

    /// Polling helper for tests: wait until predicate(pendingConflict) is true.
    public func waitForConflictState(
        _ predicate: @escaping (ConflictState?) -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws {
        let start = Date()
        while !predicate(pendingConflict) {
            if Date().timeIntervalSince(start) > Double(timeout.components.seconds) {
                struct Timeout: Error {}
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Polling helper for tests: wait until predicate(lastWrittenText) is true.
    public func waitForLastWrittenText(
        _ predicate: @escaping (String) -> Bool,
        timeout: Duration = .seconds(2)
    ) async throws {
        let start = Date()
        while !predicate(lastWrittenText) {
            if Date().timeIntervalSince(start) > Double(timeout.components.seconds) {
                struct Timeout: Error {}
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    public func resolveConflictKeepMine() async throws {
        guard let conflict = pendingConflict else { return }
        // 1. Preserve external version
        try writeConflictBackup(
            for: conflict.path,
            text: conflict.externalText,
            kind: "cloud")
        // 2. Write local version through coordinator
        try await performSave(path: conflict.path, text: conflict.localText)
        // 3. Clear conflict
        pendingConflict = nil
    }

    public func resolveConflictUseCloud() async throws {
        guard let conflict = pendingConflict else { return }
        // 1. Preserve local version
        try writeConflictBackup(
            for: conflict.path,
            text: conflict.localText,
            kind: "local")
        // 2. The disk already has externalText. Update lastWrittenText so
        //    subsequent presenter callbacks classify correctly.
        lastWrittenText = conflict.externalText
        currentDocumentText = conflict.externalText
        // 3. Clear conflict
        pendingConflict = nil
    }

    /// Write a backup copy of one side of a conflict to .maugham/conflicts/.
    /// Filename: `<stem>-<kind>-<ISO8601>.<ext>`.
    private func writeConflictBackup(
        for path: String, text: String, kind: String
    ) throws {
        let conflictsDir = projectURL.appendingPathComponent(".maugham/conflicts")
        try FileManager.default.createDirectory(
            at: conflictsDir, withIntermediateDirectories: true)

        let filename = (path as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupName = ext.isEmpty
            ? "\(stem)-\(kind)-\(stamp)"
            : "\(stem)-\(kind)-\(stamp).\(ext)"
        let backupURL = conflictsDir.appendingPathComponent(backupName)
        try text.data(using: .utf8)?.write(to: backupURL, options: [.atomic])
    }

    private var lastObservedManifestModified: Date?

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

        // Log scratch stragglers from a previous crashed multi-rename.
        // 2a accepts manual cleanup; future milestone may auto-recover.
        let scratchDir = url.appendingPathComponent(".maugham/scratch")
        if let entries = try? FileManager.default
            .contentsOfDirectory(atPath: scratchDir.path),
           !entries.isEmpty {
            print("[DocumentStore] WARNING: \(entries.count) stragglers in \(scratchDir.path) — likely from a crashed reorder/tidy. Manual inspection recommended.")
        }

        // Seed lastObservedManifestModified so the first presenter callback
        // doesn't trigger a spurious archive of an unchanged manifest.
        let manifestURL = url.appendingPathComponent("project.maugham.json")
        if let data = try? Data(contentsOf: manifestURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let m = try? decoder.decode(ProjectManifest.self, from: data) {
                store.lastObservedManifestModified = m.modified
            }
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

    /// Execute a RenamePlan. Phase 1 moves colliding items to scratch; Phase 2
    /// moves scratch items to final destinations and direct items to their
    /// final destinations. Coordinated through NSFileCoordinator.
    public func executeRenamePlan(_ plan: RenamePlan) async throws {
        guard !plan.steps.isEmpty else { return }

        let scratchDir = projectURL.appendingPathComponent(".maugham/scratch")
        try FileManager.default.createDirectory(
            at: scratchDir, withIntermediateDirectories: true)

        // Phase 1: move colliding items to scratch with unique names.
        var scratchMap: [(scratchURL: URL, finalRelativePath: String)] = []
        for step in plan.scratchSteps {
            let oldURL = projectURL.appendingPathComponent(step.oldRelativePath)
            let scratchURL = scratchDir.appendingPathComponent(UUID().uuidString)
            try await coordinatedMove(from: oldURL, to: scratchURL)
            scratchMap.append((scratchURL, step.newRelativePath))
        }

        // Phase 2a: direct (non-colliding) renames.
        for step in plan.directSteps {
            let oldURL = projectURL.appendingPathComponent(step.oldRelativePath)
            let newURL = projectURL.appendingPathComponent(step.newRelativePath)
            try await coordinatedMove(from: oldURL, to: newURL)
        }

        // Phase 2b: scratch items to final destinations.
        for entry in scratchMap {
            let finalURL = projectURL.appendingPathComponent(entry.finalRelativePath)
            try await coordinatedMove(from: entry.scratchURL, to: finalURL)
        }

        // Phase 3: caller saves the manifest.

        // Best-effort cleanup of empty scratch dir.
        if let contents = try? FileManager.default
            .contentsOfDirectory(atPath: scratchDir.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: scratchDir)
        }
    }

    /// Coordinated copy of a file or folder. Used by Duplicate.
    public func executeCopy(from sourceURL: URL, to destinationURL: URL) async throws {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var copyError: Error?
        coordinator.coordinate(
            readingItemAt: sourceURL, options: [],
            writingItemAt: destinationURL, options: .forReplacing,
            error: &coordError
        ) { readURL, writeURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: writeURL)
            } catch {
                copyError = error
            }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
    }

    /// Coordinated move of a file or folder. Wraps NSFileCoordinator's
    /// reading + writing pair for the source/destination.
    private func coordinatedMove(from sourceURL: URL, to destinationURL: URL) async throws {
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var moveError: Error?
        coordinator.coordinate(
            writingItemAt: sourceURL, options: .forMoving,
            writingItemAt: destinationURL, options: .forReplacing,
            error: &coordError
        ) { fromURL, toURL in
            do {
                try FileManager.default.moveItem(at: fromURL, to: toURL)
            } catch {
                moveError = error
            }
        }
        if let coordError { throw coordError }
        if let moveError { throw moveError }
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

extension DocumentStore: ProjectFolderPresenterDelegate {

    public func presenterDidChangeSubitem(at url: URL) {
        // Compute the relative path from projectURL.
        let project = projectURL.standardizedFileURL.path
        let changed = url.standardizedFileURL.path
        guard changed.hasPrefix(project + "/") else { return }
        let relativePath = String(changed.dropFirst(project.count + 1))

        if relativePath == "project.maugham.json" {
            handleManifestChanged()
        } else if relativePath == openDocumentPath {
            handleOpenDocumentChanged(path: relativePath)
        }
    }

    public func presenterDidObserveDirectoryChange() {
        // Phase 1e doesn't react to directory-level changes; the per-file
        // callbacks handle our cases. Phase 2+ may use this for binder
        // refresh on external file additions.
    }

    // MARK: - Document conflict handling

    private func handleOpenDocumentChanged(path: String) {
        let url = projectURL.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url),
              let diskText = String(data: data, encoding: .utf8) else { return }

        // Disk text equals our last write → echo from our own coordinated save.
        if diskText == lastWrittenText { return }

        // Disk text differs. Are there pending local edits?
        if currentDocumentText == lastWrittenText {
            // Case A: silent reload. No banner.
            lastWrittenText = diskText
            currentDocumentText = diskText
        } else {
            // Case B: conflict. Capture both versions, surface to UI.
            pendingConflict = ConflictState(
                path: path,
                localText: currentDocumentText,
                externalText: diskText,
                externalModifiedAt: (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.modificationDate]
                    as? Date) ?? Date())
        }
    }

    private func handleManifestChanged() {
        let manifestURL = projectURL.appendingPathComponent("project.maugham.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let diskManifest = try? decoder.decode(
            ProjectManifest.self, from: data) else { return }

        // Per master spec: "Last-writer-wins by `modified` timestamp; the loser
        // is preserved as `.maugham/conflicts/manifest-<timestamp>.json`."
        // We archive the disk version when it's newer than what we last saw.
        if let last = lastObservedManifestModified, diskManifest.modified > last {
            archiveManifestForConflict(data: data)
        }
        lastObservedManifestModified = diskManifest.modified
    }

    private func archiveManifestForConflict(data: Data) {
        let conflictsDir = projectURL.appendingPathComponent(".maugham/conflicts")
        try? FileManager.default.createDirectory(
            at: conflictsDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = conflictsDir
            .appendingPathComponent("manifest-\(stamp).json")
        try? data.write(to: backupURL, options: [.atomic])
    }
}
