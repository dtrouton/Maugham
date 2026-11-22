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

    /// **The one notice for a Start whose checkpoint did not land**, whatever
    /// stopped it — the door's refusal, an I/O error, no project: read-through
    /// is on, the version is not saved, and why. Starting again takes the
    /// missing checkpoint: where the line over the text offers it as Save one
    /// (`offersSaveOne`), the notice names that button; where it cannot land
    /// (a refused posture, a view-only share, no project) the notice names
    /// nothing the writer cannot press.
    static func unsavedCheckpointNotice(why: String, offersSaveOne: Bool) -> String {
        "Read-through is on, but no checkpoint was saved — \(why)"
            + (offersSaveOne ? " Press \(ReadThroughLine.saveTitle) over the text to save it." : "")
    }

    /// **Start a read-through.** `store.begin` runs at once, so the tree, the
    /// line and the padlock show in the same turn. Then, in the returned task,
    /// the piece's burst is flushed and a labelled project-scope checkpoint is
    /// taken with the piece as its subject (`CheckpointFlashDecision
    /// .labelledCapture`); it flashes and backs up as ⇧⌘S does (#90), and its
    /// id is recorded in the store. A checkpoint that does not land leaves
    /// read-through on and says so (`unsavedCheckpointNotice`).
    ///
    /// A piece already in read-through WITH its checkpoint takes no second one
    /// (nil). One without — a refusal, an error, a ⌘Q before the capture
    /// landed — takes the missing checkpoint, so Start again recovers. A Start
    /// while one is capturing is nil too.
    ///
    /// `mayTakeCheckpoint` is the window's answer for this piece
    /// (`ReadThroughOffer.mayTakeCheckpoint`): whether a failed capture's
    /// notice may point at Save one. A posture's refusal never does.
    @MainActor @discardableResult
    static func start(
        docId: String, mayTakeCheckpoint: Bool, session: String = _checkpointSessionId,
        store: ReadThroughStore, documentStore: DocumentStore,
        backups: BackupCoordinator, flash: @escaping () -> Void,
        now: Date = Date(), record: (@MainActor (Step) -> Void)? = nil
    ) -> Task<Void, Never>? {
        let isOn = ReadThrough.isOn(docId, in: store.pieceIds)
        guard !(isOn && store.hasCheckpoint(docId)) else { return nil }
        if !isOn {
            store.begin(docId, at: now)
            record?(.began)
        }
        let projectURL = documentStore.projectURL
        guard let projectStore = documentStore.projectStore else {
            MaughamEvent.postNotice(
                unsavedCheckpointNotice(why: "the project isn’t open.", offersSaveOne: false),
                projectURL: projectURL)
            return nil
        }
        guard store.beginCapturing(docId) else { return nil }
        let structure = projectStore.manifest.structure
        let allDocIds = ProjectWindow.documentIds(in: structure)
        let figureIds = (projectStore.manifest.figures ?? []).map(\.id)
        let title = TreeWalk.find(id: docId, in: structure)?.title ?? docId
        let label = ReadThrough.checkpointLabel(at: now, title: title)
        return Task { @MainActor in
            defer { store.endCapturing(docId) }
            let document = documentStore.document(forDocId: docId)
            try? await document?.flushBurstNow()
            record?(.flushed)
            let outcome = await CheckpointFlashDecision.labelledCapture(
                label, projectURL: projectURL,
                activeDocId: docId, allDocIds: allDocIds, figureIds: figureIds,
                device: _checkpointDeviceId, session: session,
                activeDocument: document,
                posture: { await documentStore.settledPosture(forDocId: $0) })
            record?(.checkpointed)
            switch outcome {
            case .landed(let checkpoint):
                store.recordCheckpoint(checkpoint.checkpointId, for: docId)
                flash()
            case .refused:
                // ⌘S flashes over this refusal (muscle memory); here the writer
                // believes the version is protected, so it is said instead.
                MaughamEvent.postNotice(
                    unsavedCheckpointNotice(why: PostureStandingLine.checkpointRefusal,
                                            offersSaveOne: false),
                    projectURL: projectURL)
            case .failed(let error):
                MaughamEvent.postNotice(
                    unsavedCheckpointNotice(why: Self.sentence(error.localizedDescription),
                                            offersSaveOne: mayTakeCheckpoint),
                    projectURL: projectURL)
            }
            await CheckpointFlashDecision.backUp(projectURL: projectURL, using: backups)
        }
    }

    /// An error's description as a sentence: ending in its full stop.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "it couldn’t be written." }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    /// **Resume writing**: the piece leaves read-through. Always allowed.
    @MainActor
    static func resume(docId: String, store: ReadThroughStore) {
        store.end(docId)
    }

}

/// **The window's read-through receiver**: `.maughamSetReadThrough` from every
/// route, and the prune that drops a piece that left the structure (deleted,
/// trashed, promoted) while keeping a renamed or moved one. It also publishes
/// the open piece's offer to the menu bar (`FocusedValues.readThroughOffer`)
/// and writes the tree's lock marks (`BinderTreeSectionsState.readThrough`).
/// Kept out of `ProjectWindow.body` for the type-check ceiling.
struct ReadThroughModifier: ViewModifier {
    /// **What the window knows about read-through and its open piece**,
    /// gathered once per `ProjectWindow.body` pass (one structure walk, one
    /// posture read, one route) and handed to this modifier, the mirror and
    /// the Insert menu alike.
    struct Facts {
        /// The piece open in the centre (`subject.open`, a document), and its item.
        let docId: String?
        let item: StructureItem?
        /// The drawing posture of that piece.
        let posture: Posture?
        let shareIsReadOnly: Bool
        let isReadingTranslation: Bool
        /// The centre's route (`ProjectWindow.centreRoute`), and whether it
        /// shows the piece's text bare (`ProjectWindow.manuscriptIsVisible`).
        let route: CentreRoute?
        var isTextVisible: Bool { ProjectWindow.manuscriptIsVisible(route: route) }
        /// The session's pieces in read-through, and those without a checkpoint.
        let pieces: Set<String>
        let lackingCheckpoint: Set<String>

        /// Whether the open piece is in read-through.
        var openIsOn: Bool { ReadThrough.isOn(docId, in: pieces) }

        /// Whether a Start's checkpoint for the open piece could land.
        var mayTakeCheckpoint: Bool {
            ReadThroughOffer.mayTakeCheckpoint(posture: posture, shareIsReadOnly: shareIsReadOnly)
        }
    }

    let readThrough: ReadThroughStore?
    let store: ProjectStore?
    let documentStore: DocumentStore?
    let window: NSWindow?
    let facts: Facts
    /// The tree the lock marks are written to.
    let treeState: BinderTreeSectionsState?
    let onSaveFlash: () -> Void
    @Environment(BackupCoordinator.self) private var backupCoordinator

    /// **The open piece's offer, from the window's facts** — what the menu
    /// bar reads through `FocusedValues.readThroughOffer`.
    @MainActor
    static func offer(_ facts: Facts) -> ReadThroughOffer? {
        ReadThroughOffer.of(
            docId: facts.docId, item: facts.item, posture: facts.posture,
            shareIsReadOnly: facts.shareIsReadOnly,
            isReadingTranslation: facts.isReadingTranslation,
            isTextVisible: facts.isTextVisible,
            pieces: facts.pieces, lackingCheckpoint: facts.lackingCheckpoint)
    }

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.readThroughOffer, Self.offer(facts))
            .onKeyWindowCommand(.maughamSetReadThrough, window: window) { note in
                guard let request = ReadThrough.request(of: note.userInfo),
                      let readThrough, let documentStore else { return }
                if request.on {
                    ReadThroughVerbs.start(
                        docId: request.docId,
                        mayTakeCheckpoint: request.docId == facts.docId && facts.mayTakeCheckpoint,
                        store: readThrough,
                        documentStore: documentStore, backups: backupCoordinator,
                        flash: onSaveFlash)
                } else {
                    ReadThroughVerbs.resume(docId: request.docId, store: readThrough)
                }
            }
            // Keyed on the structure itself, so the walk runs only when it
            // changes; never before the manifest has loaded (`keeping` is nil).
            .onChange(of: store?.manifest.structure, initial: true) { _, structure in
                guard let keeping = ReadThrough.keeping(for: structure),
                      let readThrough else { return }
                readThrough.prune(keeping: keeping)
            }
            // The tree's lock: one set, written only when it moved (as the
            // presence marks are), and looked up by each row.
            .onChange(of: facts.pieces, initial: true) { _, pieces in
                if let treeState, treeState.readThrough != pieces { treeState.readThrough = pieces }
            }
    }
}
