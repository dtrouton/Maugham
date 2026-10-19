import SwiftUI
import MaughamCore
import AppKit

/// The one honest-save decision both ⌘S sites route through —
/// `CheckpointModifier`'s key command and the Shift-⌘S label sheet in
/// `ProjectWindow.body`. A landed checkpoint runs `onSuccess` (the flash); a
/// thrown one runs neither `onSuccess` nor the caller's own success path,
/// and posts a notice explaining why instead of staying silent. Never both,
/// never neither — a ⌘S flash must not fire over a checkpoint that failed or
/// wrote nothing.
///
/// A free type so both views can share it, and internal so
/// `SaveFlashHonestyTests` can pin both directions without mounting either.
enum CheckpointFlashDecision {
    @MainActor
    static func run(
        projectURL: URL,
        onSuccess: () -> Void = {},
        capture: () async throws -> Void
    ) async {
        do {
            try await capture()
            onSuccess()
        } catch CheckpointRefusal.notYourText {
            // **⌘S always flashes** (plan ruling R5): the refusal wrote NOTHING —
            // no op, no entry — by design, so it is not a failure to explain.
            // Exactly this refusal and no other error.
            onSuccess()
        } catch {
            MaughamEvent.postNotice(
                "Couldn’t save a checkpoint — \(error.localizedDescription)",
                projectURL: projectURL)
        }
    }
}

extension CheckpointFlashDecision {
    /// **⇧⌘S's Confirm** — the labelled checkpoint, through the same honest
    /// decision ⌘S takes, and flashing as ⌘S does. A demotion arriving between
    /// opening the sheet and Confirm reaches the capture's door, which writes
    /// NOTHING, and the flash still fires — ⌘S always flashes. Any other error
    /// posts its notice and does not flash. A free function so the Confirm path
    /// is pinned without mounting the sheet (tripwire 33).
    ///
    /// **And it backs up, as ⌘S does** (#90, Denver's ruling): after the
    /// capture, whether or not it landed, it runs `backUp` — the one backup
    /// call every checkpoint key shares, so a named save point gets the same
    /// integrity gate and the same skip-if-unchanged signature.
    @MainActor
    static func labelled(
        _ label: String, projectURL: URL, activeDocId: String, allDocIds: [String],
        device: String, session: String, activeDocument: Document?,
        posture: @escaping @MainActor (String) async -> Posture,
        backups: BackupCoordinator,
        flash: () -> Void
    ) async {
        await run(projectURL: projectURL, onSuccess: flash) {
            _ = try await CheckpointCapture.run(
                projectURL: projectURL,
                activeDocId: activeDocId,
                allDocIds: allDocIds,
                device: device,
                session: session,
                label: label,
                activeDocument: activeDocument,
                posture: posture)
        }
        await backUp(projectURL: projectURL, using: backups)
    }

    /// **The backup a checkpoint runs** — ⌘S, ⇧⌘S's Confirm and ⇧⌘S's
    /// refusal all call this, never `backupNow` directly (#90). Runs whether or
    /// not a checkpoint landed: `run` catches its own throw, so a refused
    /// checkpoint (a reviewer's, a read-only recovery document) still reaches
    /// this attempt. The coordinator hops off-main internally and records
    /// status; its own gate (`blocksBackup`) decides whether THIS backup
    /// proceeds, and an unchanged project is skipped by its signature.
    @MainActor
    static func backUp(projectURL: URL, using coordinator: BackupCoordinator) async {
        await coordinator.backupNow(
            projectURL: projectURL,
            generationId: ULID.generate(),
            at: Date())
    }
}

/// The ⌘S / Shift-⌘S checkpoint notification handlers, kept out of
/// `ProjectWindow.body` for the type-check ceiling.
struct CheckpointModifier: ViewModifier {
    let documentStore: DocumentStore?
    let store: ProjectStore?
    /// The owning project window. Key-window commands (ADR 0021):
    /// `.onKeyWindowCommand` scopes ⌘S / Shift-⌘S delivery to the key window,
    /// so ⌘S checkpoints + backs up the front project only. The store /
    /// documentStore checks below are action preconditions, not scope guards.
    let window: NSWindow?
    /// Fallback project URL, threaded to RewindModifier for its project scope
    /// when `store` hasn't loaded yet (ADR 0021).
    let url: URL
    /// The item the tree names, already converted at `ProjectWindow`'s
    /// boundary — `nil` for the project and for no selection alike.
    let selectedItemId: String?
    /// The breadcrumb's stream id, from the same boundary — taken, never
    /// re-derived here.
    let activeDocId: String
    @Binding var showingCheckpointLabelSheet: Bool
    let onSaveFlash: () -> Void
    @Environment(BackupCoordinator.self) private var backupCoordinator

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamSaveCheckpoint, window: window) { _ in
                guard let store, let documentStore else { return }
                let allDocIds = ProjectWindow.documentIds(in: store.manifest.structure)
                let activeDoc = activeDocument(
                    selectedItemId: selectedItemId,
                    structure: store.manifest.structure,
                    documentStore: documentStore)
                Task { @MainActor in
                    try? await activeDoc?.flushBurstNow()
                    await CheckpointFlashDecision.run(
                        projectURL: store.url, onSuccess: onSaveFlash
                    ) {
                        _ = try await CheckpointCapture.run(
                            projectURL: store.url,
                            activeDocId: activeDocId,
                            allDocIds: allDocIds,
                            device: _checkpointDeviceId,
                            session: _checkpointSessionId,
                            label: nil,
                            activeDocument: activeDoc,
                            posture: { await documentStore.settledPosture(forDocId: $0) })
                    }
                    // The one backup every checkpoint key shares (#90) — runs
                    // whether or not the checkpoint above landed.
                    await CheckpointFlashDecision.backUp(
                        projectURL: store.url, using: backupCoordinator)
                }
            }
            .onKeyWindowCommand(.maughamNamedCheckpoint, window: window) { _ in
                guard let store, let documentStore else { return }
                let allDocIds = ProjectWindow.documentIds(in: store.manifest.structure)
                // **⇧⌘S over text this Mac may not change says why instead of
                // opening** (plan ruling R5). An ACTING decision — the sheet is
                // the first half of a write — so it asks the settled door.
                guard let subject = CheckpointCapture.documentSubject(
                    of: activeDocId, in: allDocIds) else {
                    showingCheckpointLabelSheet = true
                    return
                }
                Task { @MainActor in
                    let posture = await documentStore.settledPosture(forDocId: subject)
                    if posture.allows(.checkpoint) {
                        showingCheckpointLabelSheet = true
                    } else {
                        MaughamEvent.postNotice(
                            PostureStandingLine.checkpointRefusal, projectURL: store.url)
                        // A refused ⌘S still backs up, so a refused ⇧⌘S does
                        // too (#90): no save point, the same backup.
                        await CheckpointFlashDecision.backUp(
                            projectURL: store.url, using: backupCoordinator)
                    }
                }
            }
            .modifier(RewindModifier(
                documentStore: documentStore,
                store: store,
                window: window,
                url: url,
                selectedItemId: selectedItemId))
    }

    private func activeDocument(
        selectedItemId: String?,
        structure: [StructureItem],
        documentStore: DocumentStore
    ) -> Document? {
        guard let id = selectedItemId,
              let item = TreeWalk.find(id: id, in: structure),
              let path = item.path else { return nil }
        return documentStore.document(for: path)
    }
}
