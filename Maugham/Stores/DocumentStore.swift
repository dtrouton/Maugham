import Foundation
import MaughamCore
import AppKit
import os

// Subsystem from the running bundle id so dev/stable logs separate without
// hardcoding "com.maugham" (tripwire 13 spirit).
private let documentStoreLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "DocumentStore")

/// Project-scoped store that owns the NSFilePresenter, the registry of
/// per-document `Document` actors, session tracking, UI state, manifest IO,
/// and rename/copy/move file orchestration. The op-log, autosave, conflict
/// detection, and burst scheduling all live on `Document` (Stage 3 of the
/// document-first-class refactor); DocumentStore routes external presenter
/// callbacks to the matching Document via the registry.
@MainActor
@Observable
public final class DocumentStore {

    public let projectURL: URL

    /// Loaded from `.maugham/ui-state.json` on open; nil-defaulted if absent.
    public private(set) var uiState: UIState

    internal var presenter: NSFilePresenter? { return _presenter }
    private var _presenter: ProjectFolderPresenter?

    /// The capture inbox for this project window (MaughamPhone sync target).
    /// Lazily created on first access; the InboxPane reads `entries`, the
    /// `.inbox` presenter arm refreshes it, and (Phase C) the transcription
    /// worker writes Whisper results back. MainActor-isolated because InboxStore
    /// is `@MainActor @Observable`.
    @MainActor private var _inboxStore: InboxStore?
    @MainActor var inboxStore: InboxStore {
        if let s = _inboxStore { return s }
        let s = InboxStore(projectURL: projectURL)
        _inboxStore = s
        return s
    }

    @MainActor private var _transcriptionWorker: InboxTranscriptionWorker?
    @MainActor var transcriptionWorker: InboxTranscriptionWorker {
        if let w = _transcriptionWorker { return w }
        let w = InboxTranscriptionWorker(
            inboxStore: inboxStore,
            transcriber: Self.makeTranscriber())
        _transcriptionWorker = w
        return w
    }

    /// Production transcriber. Returns a WhisperKitTranscriber on Apple Silicon;
    /// nil on Intel so the worker stays inert there. Fully testable via injection.
    @MainActor private static func makeTranscriber() -> Transcriber? {
        #if arch(arm64)
        return WhisperKitTranscriber()
        #else
        return nil
        #endif
    }

    private var uiStateScheduler: DebounceScheduler<UIState>!

    private var lastObservedManifestModified: Date?

    /// Tracks the active writing session in-memory. Driven by
    /// `recordSessionActivity(...)` and the idle timer below; flushed on
    /// app quit via `flushSessionOnQuit()`.
    private let sessionTracker = SessionTracker()

    /// Start timestamp of the in-memory writing session, or nil if no
    /// session is active. Consumed by the editor status footer to render
    /// the session time range (e.g. `session 18:00–19:07`).
    public var currentSessionStart: Date? {
        sessionTracker.activeSession?.startedAt
    }

    /// Net word delta of the currently-active session — the live count of
    /// words added (or removed, if negative) since the session started.
    /// Returns 0 when no session is active. Updated implicitly each time
    /// `recordSessionActivity(...)` is called (which writes the observable
    /// `lastKnownProjectWordCount`), so SwiftUI views reading this property
    /// re-render correctly while the user types.
    public var liveSessionWordsNet: Int {
        guard let session = sessionTracker.activeSession else { return 0 }
        return lastKnownProjectWordCount - session.startWordCount
    }

    private var idleTimerToken: DispatchWorkItem?
    /// Snapshot of the most recent project-wide word count seen on a
    /// `recordSessionActivity` call. Used by `flushSessionOnQuit` so the
    /// session's net delta is computed against the live total even when
    /// the caller can't pass one in.
    private var lastKnownProjectWordCount: Int = 0
    private static let sessionIdleThreshold: TimeInterval = 30 * 60

    /// Debounced save scheduler used by callers that aren't Documents —
    /// today that's `ResearchNoteEditor` and `PartialRestorePicker`. Documents
    /// run their own autosave internally (see `Document.performAutosave`).
    private var fileSaveScheduler: DebounceScheduler<FileSavePayload>!

    private struct FileSavePayload: Sendable {
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
        store.fileSaveScheduler = DebounceScheduler<FileSavePayload>(
            delay: .milliseconds(750)
        ) { [weak store] payload in
            do {
                try await store?.performFileSave(path: payload.path, text: payload.text)
            } catch {
                documentStoreLog.error("Research-note autosave failed for \(payload.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Log scratch stragglers from a previous crashed multi-rename.
        // 2a accepts manual cleanup; future milestone may auto-recover.
        let scratchDir = url.appendingPathComponent(".maugham/scratch")
        if let entries = try? FileManager.default
            .contentsOfDirectory(atPath: scratchDir.path),
           !entries.isEmpty {
            documentStoreLog.warning("WARNING: \(entries.count, privacy: .public) stragglers in \(scratchDir.path, privacy: .public) — likely from a crashed reorder/tidy. Manual inspection recommended.")
        }

        // Seed lastObservedManifestModified so the first presenter callback
        // doesn't trigger a spurious archive of an unchanged manifest.
        let manifestURL = url.appendingPathComponent(ProjectManifest.fileName)
        if let data = try? Data(contentsOf: manifestURL) {
            if let m = try? ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: data) {
                store.lastObservedManifestModified = m.modified
            }
        }

        let presenter = ProjectFolderPresenter(
            projectURL: url, delegate: store)
        NSFileCoordinator.addFilePresenter(presenter)
        store._presenter = presenter

        // Transcribe audio that synced while the app was closed: the presenter
        // only fires for changes after open, so pre-existing eligible captures
        // (the common phone-captured-while-Mac-closed case) need one initial
        // scan. Inert when there's no transcriber (non-Apple-Silicon) or no
        // eligible `.none`/`.onDeviceDraft` audio.
        store.transcriptionWorker.onInboxChanged()

        return store
    }

    public func close() async {
        // Flush an in-progress session first so it lands in sessions.json
        // before the presenter is removed and writes become uncoordinated.
        await flushSessionOnQuit()
        try? await flushPendingSave()
        await uiStateScheduler.flush()
        if let presenter = _presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self._presenter = nil
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

    // MARK: - Non-Document file save path (research notes, partial-restore)

    /// Schedule a coordinated write of `text` to `path` on a 750ms debounce.
    /// Used by `ResearchNoteEditor` and `PartialRestorePicker` — anything
    /// that isn't a manuscript `Document` (Documents autosave internally).
    public func scheduleFileSave(for path: String, text: String) {
        guard fileSaveScheduler != nil else { return }
        fileSaveScheduler.schedule(FileSavePayload(path: path, text: text))
    }

    /// Flush any pending `scheduleFileSave` immediately.
    public func flushPendingSave() async throws {
        guard let fileSaveScheduler else { return }
        await fileSaveScheduler.flush()
    }

    private func performFileSave(path: String, text: String) async throws {
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
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
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

        // Mirror the just-saved manifest into a verified shadow so a later corrupt
        // or truncated `project.maugham.json` can be recovered without a full restore
        // (`ProjectStore.load` falls back to it). Best-effort — never fail the save.
        try? ManifestShadow.write(data, in: projectURL)
    }

    /// Coordinated read for callers outside ProjectStore.
    public func readManifest() async throws -> Data {
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
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

    /// Read sessions.json from disk via NSFileCoordinator. Returns
    /// `.empty` if the file doesn't exist or doesn't decode.
    public func loadSessionLog() async throws -> SessionLog {
        let logURL = projectURL.appendingPathComponent(".maugham/sessions.json")
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var loaded: SessionLog = .empty
        coordinator.coordinate(
            readingItemAt: logURL, options: [], error: &coordError
        ) { url in
            guard let data = try? Data(contentsOf: url),
                  let log = try? {
                      let decoder = JSONDecoder()
                      decoder.dateDecodingStrategy = .iso8601
                      return try decoder.decode(SessionLog.self, from: data)
                  }(),
                  log.schemaVersion <= SessionLog.currentSchemaVersion else {
                loaded = .empty
                return
            }
            loaded = log
        }
        if let coordError { throw coordError }
        return loaded
    }

    /// Append an event by reading the existing log, merging the new event,
    /// and writing back. Coordinated through NSFileCoordinator. Safe under
    /// iCloud divergence — append-only logs union-merge correctly.
    public func appendSessionEvent(_ event: SessionEvent) async throws {
        let scratchDir = projectURL.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(
            at: scratchDir, withIntermediateDirectories: true)

        let existing = try await loadSessionLog()
        let next = SessionLog.merged(
            existing,
            SessionLog(events: [event]))

        let logURL = projectURL.appendingPathComponent(".maugham/sessions.json")
        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordError: NSError?
        var writeError: Error?
        coordinator.coordinate(
            writingItemAt: logURL, options: .forReplacing, error: &coordError
        ) { url in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(next)
                try data.write(to: url, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
        NotificationCenter.default.post(
            name: .maughamSessionLogChanged, object: nil)
    }

    /// Records all the side-effects that must fire when the editor writes
    /// new text into a Document. Computes the word count for `newText`,
    /// updates the project's per-document word-count cache, and pings the
    /// SessionTracker so live session metrics tick.
    ///
    /// **Load-bearing.** This is the single bridge between the editor and
    /// the project-level word/session bookkeeping. Skipping this call (or
    /// any of its three operations) means:
    ///
    /// - `ProjectStore.projectWordCount` returns stale data.
    /// - `DocumentStore.sessionTracker.activeSession` never starts.
    /// - `SessionLog` stays empty (no events appended on idle/quit).
    /// - The status footer's `wordsToday` and `liveSessionWordsNet` show 0.
    ///
    /// The document-first-class refactor (commit `b37609a`, 2026-05-19)
    /// silently lost these calls when text writes moved from EditorHost
    /// into `Document.setFullText`; the regression hid for three days. If
    /// you're considering removing this method or its call site in
    /// `EditorHost`, the same regression returns.
    public func recordEditorTextWrite(
        documentId: String,
        newText: String,
        mode: any WritingMode,
        store: ProjectStore
    ) {
        let count = mode.metrics(newText).wordCount
        store.recordWordCount(forDocumentId: documentId, wordCount: count)
        recordSessionActivity(
            documentId: documentId,
            projectWordCount: store.projectWordCount)
    }

    /// Called by EditorHost on every text change. Records activity with the
    /// SessionTracker and (re)arms the 30-minute idle timer. When the timer
    /// fires without further activity, the session is finalised and appended
    /// to `.maugham/sessions.json`.
    public func recordSessionActivity(
        documentId: String,
        projectWordCount: Int
    ) {
        lastKnownProjectWordCount = projectWordCount
        sessionTracker.recordTextChange(
            at: Date(), projectWordCount: projectWordCount)

        idleTimerToken?.cancel()
        let snapshotWordCount = projectWordCount
        let token = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let event = self.sessionTracker.endSessionIfIdle(
                    at: Date(),
                    currentProjectWordCount: snapshotWordCount) {
                    try? await self.appendSessionEvent(event)
                }
            }
        }
        idleTimerToken = token
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.sessionIdleThreshold,
            execute: token)
    }

    /// Called from app-quit hook. Finalises any active session immediately
    /// using the most recently observed project word count and appends it
    /// to the log. Best-effort — quit may interrupt the write.
    public func flushSessionOnQuit() async {
        idleTimerToken?.cancel()
        idleTimerToken = nil
        if let event = sessionTracker.endSessionImmediately(
            at: Date(),
            currentProjectWordCount: lastKnownProjectWordCount) {
            try? await appendSessionEvent(event)
        }
    }

    /// Execute a RenamePlan. Phase 1 moves colliding items to scratch; Phase 2
    /// moves scratch items to final destinations and direct items to their
    /// final destinations. Coordinated through NSFileCoordinator.
    public func executeRenamePlan(_ plan: RenamePlan) async throws {
        guard !plan.steps.isEmpty else { return }

        // Close any open Documents at the paths the plan is about to move.
        // The 750ms autosave on an open Document would otherwise race the
        // coordinated move and re-create the file at the OLD path — same
        // race class as renameStructureItem / renamePiece, surfaced here
        // when a binder reorder renumbers multiple siblings at once. The
        // doc re-loads via EditorHost.loadDocumentIfNeeded after the move
        // when the writer re-selects it.
        for step in plan.steps {
            if let openDoc = openDocuments[step.oldRelativePath] {
                await openDoc.close()
                openDocuments.removeValue(forKey: step.oldRelativePath)
            }
        }

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

    // MARK: - Document registry

    /// Open `Document` instances keyed by manuscript-relative path. Populated
    /// by `EditorHost` when it loads a document, cleared when the editor
    /// switches away. The presenter routes external change callbacks through
    /// this registry to the owning Document.
    private var openDocuments: [String: Document] = [:]

    public func register(document: Document, for path: String) {
        openDocuments[path] = document
    }

    public func unregister(path: String) {
        openDocuments.removeValue(forKey: path)
    }

    public func document(for path: String) -> Document? {
        openDocuments[path]
    }

    public func document(forDocId docId: String) -> Document? {
        openDocuments.values.first(where: { $0.docId == docId })
    }

    /// All currently-open `Document` instances. Used by `ProjectStore` for
    /// cross-project task aggregation (it sums their `tasksVersion`s into
    /// the aggregation cache key, and calls `tasks(filter:)` on each).
    /// Closed documents are out-of-scope for this read — their inline tasks
    /// only surface after the user opens the doc. Pane-created project-scope
    /// tasks live in `.maugham/ops/__project__.jsonl` and are read via
    /// `ProjectStore.projectTasksOpLog()` instead.
    public func allOpenDocuments() -> [Document] {
        Array(openDocuments.values)
    }
}

extension DocumentStore: ProjectFolderPresenterDelegate {

    public func presenterDidChangeSubitem(at url: URL) {
        switch MaughamSidecarPath.classify(url: url, projectURL: projectURL) {

        case .manifest:
            handleManifestChanged()

        case .opLog(let docId):
            if let doc = document(forDocId: docId) {
                Task { @MainActor in
                    try? await doc.handleExternalLogChange()
                }
            }
            NotificationCenter.default.post(
                name: .maughamOpLogChanged, object: nil,
                userInfo: ["docId": docId])

        case .checkpoints:
            NotificationCenter.default.post(
                name: .maughamCheckpointAdded, object: nil)

        case .otherProjectFile(let relativePath):
            // Manuscripts live alongside research notes and binder content
            // outside `.maugham/`. The registry's path-keyed lookup is the
            // authoritative way to recognize a manuscript here — anything
            // not registered is research, binder metadata, or user-dropped
            // files we don't react to via the presenter.
            guard let doc = document(for: relativePath) else { return }
            let projectRoot = projectURL
            Task { @MainActor in
                let mdURL = projectRoot.appendingPathComponent(relativePath)
                guard let data = try? Data(contentsOf: mdURL),
                      let diskText = String(data: data, encoding: .utf8)
                else { return }
                try? await doc.handleExternalDiskChange(diskMd: diskText)
            }

        case .inbox(let kind, _):
            // A capture (or a Mac-side status transition) landed in
            // `.maugham/inbox/`. `object: self` scopes the post to this project
            // window so multiple windows don't cross-talk. See spec §3.3.
            NotificationCenter.default.post(
                name: .maughamInboxChanged, object: self,
                userInfo: ["kind": kind.rawValue])
            Task { @MainActor in
                await inboxStore.refresh()
                // Poke the transcription worker on ANY inbox change, not just
                // `.audio` file events: a new audio capture surfaces as both an
                // `.m4a` and a manifest row, arriving as separate sync events in
                // either order. If the audio file event fires before its manifest
                // row exists, an audio-only trigger would scan, find nothing
                // eligible, and never re-run. The worker filters to eligible
                // audio internally, so non-audio pokes are cheap no-ops.
                transcriptionWorker.onInboxChanged()
            }

        case .sessionLog, .uiState, .conflictBackup, .scratch, .trash,
             .publishTemplate, .publishStyles, .publishConfig, .publishAsset,
             .publishBuild, .publicationsLog, .publicationSnapshot,
             .unknownSidecar, .outsideProject:
            // No presenter routing today. Each case has a named owner in
            // `Maugham/Stores/AREA.md`; wiring one up is "add a case branch"
            // rather than "extend a string cascade".
            return
        }
    }

    public func presenterDidObserveDirectoryChange() {
        // Phase 1e doesn't react to directory-level changes; the per-file
        // callbacks handle our cases. Phase 2+ may use this for binder
        // refresh on external file additions.
    }

    private func handleManifestChanged() {
        let manifestURL = projectURL.appendingPathComponent(ProjectManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        guard let diskManifest = try? ProjectManifest.makeDecoder().decode(
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
