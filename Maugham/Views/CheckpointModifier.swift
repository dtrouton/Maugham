import SwiftUI
import MaughamCore
import AppKit
import os

/// The one honest-save decision both ⌘S sites route through — `CheckpointModifier`'s
/// key command below and the Shift-⌘S label sheet in `ProjectWindow.body`. A
/// landed checkpoint runs `onSuccess` (the flash); a thrown one runs neither
/// `onSuccess` nor the caller's own success path, and posts a notice
/// explaining why instead of staying silent. Never both, never neither — the
/// whole-branch review's finding was a ⌘S flash that fired even when the
/// checkpoint write failed or, in a read-only recovery state, wrote nothing.
///
/// A free type rather than a method on `ProjectWindow` or `CheckpointModifier`
/// (different structs, so a method could not serve both) — and internal, not
/// `private`, so `SaveFlashHonestyTests` can pin both directions without
/// mounting either view.
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
            // **⌘S always flashes** (P3c Task 3, plan ruling R5): the refusal
            // wrote NOTHING — no op, no entry — by design, so it is not a
            // failure to explain. Exactly this refusal and no other error.
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
    /// decision ⌘S takes, and flashing as ⌘S does (P3c Task 3 fix round 1).
    /// The sheet only opens where the posture allowed a checkpoint; a demotion
    /// arriving between opening it and Confirm reaches the capture's door,
    /// which writes NOTHING, and the flash still fires — ⌘S always flashes.
    /// Any other error posts its notice and does not flash. A free function so
    /// the Confirm path is pinned without mounting the sheet (tripwire 33).
    @MainActor
    static func labelled(
        _ label: String, projectURL: URL, activeDocId: String, allDocIds: [String],
        device: String, session: String, activeDocument: Document?,
        posture: @escaping @MainActor (String) async -> Posture,
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
    }
}

/// Breaks the ⌘S / Shift-⌘S checkpoint notification handlers out of the
/// main body chain so Swift's type-checker doesn't time out.
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
    /// The breadcrumb's stream id, from the same boundary. Taken rather than
    /// re-derived: this modifier used to spell the `?? "__no-selection__"` rule
    /// a second time, three hops from the two other spellings of it.
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
                    // Runs regardless of whether the checkpoint above landed —
                    // CheckpointFlashDecision.run catches its own throw rather
                    // than propagating one, so a refused checkpoint (e.g. a
                    // read-only recovery document) still reaches this backup
                    // attempt. The coordinator hops off-main internally and
                    // records status; its own gate (blocksBackup) is what
                    // decides whether THIS backup proceeds.
                    await backupCoordinator.backupNow(
                        projectURL: store.url,
                        generationId: ULID.generate(),
                        at: Date())
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
