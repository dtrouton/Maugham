import SwiftUI
import AppKit
import MaughamCore

/// **The two read-through verbs**, free of any view so the order they keep is
/// pinned without a window (`ReadThroughVerbsTests`).
enum ReadThroughVerbs {
    /// What `start` has done, in order — reported to an injected recorder so a
    /// test can see that the state lands first and the burst is flushed before
    /// the checkpoint. Production passes none.
    enum Step: Equatable { case began, flushed, checkpointed }

    /// The notice when the checkpoint was refused at its door: read-through is
    /// on, and the version it protects was not saved.
    static let refusedCheckpointNotice =
        "The read-through started, but no checkpoint was saved — "
        + PostureStandingLine.checkpointRefusal

    /// **Start a read-through.** `store.begin` runs at once, so the tree, the
    /// line and the padlock show in the same turn. Then, in the returned task,
    /// the piece's burst is flushed and a labelled project-scope checkpoint is
    /// taken with the piece as its subject — through `CheckpointFlashDecision
    /// .labelled`, so it backs up and flashes as ⇧⌘S does (#90). A failed
    /// checkpoint leaves read-through on; its notice says why. A piece already
    /// in read-through takes no second checkpoint (nil).
    @MainActor @discardableResult
    static func start(
        docId: String, session: String = _checkpointSessionId,
        store: ReadThroughStore, documentStore: DocumentStore,
        backups: BackupCoordinator, flash: @escaping () -> Void,
        now: Date = Date(), record: (@MainActor (Step) -> Void)? = nil
    ) -> Task<Void, Never>? {
        guard !ReadThrough.isOn(docId, in: store.pieceIds) else { return nil }
        store.begin(docId, at: now)
        record?(.began)
        let projectURL = documentStore.projectURL
        guard let projectStore = documentStore.projectStore else {
            MaughamEvent.postNotice(
                "The read-through started, but no checkpoint was saved — the project isn’t open.",
                projectURL: projectURL)
            return nil
        }
        let structure = projectStore.manifest.structure
        let allDocIds = ProjectWindow.documentIds(in: structure)
        let figureIds = (projectStore.manifest.figures ?? []).map(\.id)
        let title = TreeWalk.find(id: docId, in: structure)?.title ?? docId
        let label = ReadThrough.checkpointLabel(at: now, title: title)
        return Task { @MainActor in
            let document = documentStore.document(forDocId: docId)
            try? await document?.flushBurstNow()
            record?(.flushed)
            let refusal = Refusal()
            await CheckpointFlashDecision.labelled(
                label, projectURL: projectURL,
                activeDocId: docId, allDocIds: allDocIds, figureIds: figureIds,
                device: _checkpointDeviceId, session: session,
                activeDocument: document,
                posture: { id in
                    let posture = await documentStore.settledPosture(forDocId: id)
                    if id == docId, !posture.allows(.checkpoint) { refusal.refused = true }
                    return posture
                },
                backups: backups,
                flash: { if !refusal.refused { flash() } })
            record?(.checkpointed)
            // `labelled` swallows the door's refusal for ⌘S's muscle memory;
            // here the writer believes the version is protected, so say it.
            if refusal.refused {
                MaughamEvent.postNotice(refusedCheckpointNotice, projectURL: projectURL)
            }
        }
    }

    /// **Resume writing**: the piece leaves read-through. Always allowed.
    @MainActor
    static func resume(docId: String, store: ReadThroughStore) {
        store.end(docId)
    }

    /// Whether the checkpoint's door refused, carried from the posture
    /// question to the flash and the notice inside one task.
    private final class Refusal: @unchecked Sendable { var refused = false }
}

/// **The window's read-through receiver**: `.maughamSetReadThrough` from every
/// route, and the prune that drops a piece that left the structure (deleted,
/// trashed, promoted) while keeping a renamed or moved one. Kept out of
/// `ProjectWindow.body` for the type-check ceiling.
struct ReadThroughModifier: ViewModifier {
    let readThrough: ReadThroughStore?
    let store: ProjectStore?
    let documentStore: DocumentStore?
    let window: NSWindow?
    let onSaveFlash: () -> Void
    @Environment(BackupCoordinator.self) private var backupCoordinator

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamSetReadThrough, window: window) { note in
                guard let request = ReadThrough.request(of: note.userInfo),
                      let readThrough, let documentStore else { return }
                if request.on {
                    ReadThroughVerbs.start(
                        docId: request.docId, store: readThrough,
                        documentStore: documentStore, backups: backupCoordinator,
                        flash: onSaveFlash)
                } else {
                    ReadThroughVerbs.resume(docId: request.docId, store: readThrough)
                }
            }
            // Never before the manifest has loaded: `keeping` is nil then.
            .onChange(of: ReadThrough.keeping(for: store?.manifest.structure),
                      initial: true) { _, keeping in
                guard let keeping, let readThrough else { return }
                readThrough.prune(keeping: keeping)
            }
    }
}
