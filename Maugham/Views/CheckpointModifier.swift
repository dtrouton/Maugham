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
        figureIds: [String], device: String, session: String, activeDocument: Document?,
        posture: @escaping @MainActor (String) async -> Posture,
        backups: BackupCoordinator,
        flash: () -> Void
    ) async {
        switch await labelledCapture(
            label, projectURL: projectURL, activeDocId: activeDocId, allDocIds: allDocIds,
            figureIds: figureIds, device: device, session: session,
            activeDocument: activeDocument, posture: posture) {
        case .landed, .refused:
            flash()
        case .failed(let error):
            MaughamEvent.postNotice(
                "Couldn’t save a checkpoint — \(error.localizedDescription)",
                projectURL: projectURL)
        }
        await backUp(projectURL: projectURL, using: backups)
    }

    /// What a labelled capture came to: the checkpoint written, the door's
    /// refusal (nothing written), or a thrown error.
    enum LabelledOutcome {
        case landed(Checkpoint)
        case refused
        case failed(Error)
    }

    /// **The labelled capture alone** — no flash, no notice, no backup — so a
    /// caller that must say something else (read-through's Start, which names
    /// the read-through in its notice) decides from the outcome. `labelled` is
    /// this plus ⇧⌘S's flash, notice and backup.
    @MainActor
    static func labelledCapture(
        _ label: String, projectURL: URL, activeDocId: String, allDocIds: [String],
        figureIds: [String], device: String, session: String, activeDocument: Document?,
        posture: @escaping @MainActor (String) async -> Posture
    ) async -> LabelledOutcome {
        do {
            return .landed(try await CheckpointCapture.run(
                projectURL: projectURL,
                activeDocId: activeDocId,
                allDocIds: allDocIds,
                figureIds: figureIds,
                device: device,
                session: session,
                label: label,
                activeDocument: activeDocument,
                posture: posture))
        } catch CheckpointRefusal.notYourText {
            return .refused
        } catch {
            return .failed(error)
        }
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
    /// The window's subject. ⌘S and ⇧⌘S read its OPEN piece, never the
    /// faces (`CheckpointTarget.of`, shell closing A1).
    let subject: WindowSubject
    @Binding var showingCheckpointLabelSheet: Bool
    let onSaveFlash: () -> Void
    @Environment(BackupCoordinator.self) private var backupCoordinator

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamSaveCheckpoint, window: window) { _ in
                guard let store, let documentStore else { return }
                let allDocIds = ProjectWindow.documentIds(in: store.manifest.structure)
                let figureIds = (store.manifest.figures ?? []).map(\.id)
                let target = CheckpointTarget.of(subject, structure: store.manifest.structure)
                let activeDoc = target.document(in: documentStore)
                Task { @MainActor in
                    try? await activeDoc?.flushBurstNow()
                    await CheckpointFlashDecision.run(
                        projectURL: store.url, onSuccess: onSaveFlash
                    ) {
                        _ = try await CheckpointCapture.run(
                            projectURL: store.url,
                            activeDocId: target.docId,
                            allDocIds: allDocIds,
                            figureIds: figureIds,
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
                let target = CheckpointTarget.of(subject, structure: store.manifest.structure)
                guard let subjectDoc = CheckpointCapture.documentSubject(
                    of: target.docId, in: allDocIds) else {
                    showingCheckpointLabelSheet = true
                    return
                }
                Task { @MainActor in
                    let posture = await documentStore.settledPosture(forDocId: subjectDoc)
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
                url: url))
    }
}

/// **What a checkpoint key acts on: the piece OPEN in the centre** (shell
/// closing A1). The faces can sit on another piece (a Brief link), the Book
/// or an edition (⌘⌥K) while the writer types in the open one; a checkpoint
/// keyed on the faces flushed the wrong burst, breadcrumbed the wrong stream
/// and asked the wrong piece's posture. Both checkpoint keys and ⌘⌥C build
/// this one value, from `WindowSubject.openPiece`, so the flushed document,
/// the breadcrumb and the posture question cannot name different pieces.
struct CheckpointTarget: Equatable {
    /// The breadcrumb's stream id — `BinderSubject.noDocumentSubject` when no
    /// structure item is open (`CheckpointCapture` then writes no breadcrumb).
    let docId: String
    /// The open piece's manuscript path, whose live `Document` is flushed.
    let path: String?

    static func of(_ subject: WindowSubject, structure: [StructureItem]) -> CheckpointTarget {
        CheckpointTarget(docId: subject.openDocId, path: subject.openPiece(in: structure)?.path)
    }

    /// The open piece's live `Document`, when the editor registry holds one.
    @MainActor
    func document(in documentStore: DocumentStore) -> Document? {
        path.flatMap { documentStore.document(for: $0) }
    }
}
