import SwiftUI
import MaughamCore
import AppKit

/// Owns the .maughamOpenRewind notification listener and the RewindWindow
/// sheet, kept out of `ProjectWindow.body` for the type-check ceiling.
struct RewindModifier: ViewModifier {
    let documentStore: DocumentStore?
    let store: ProjectStore?
    /// The owning project window, for the ADR 0021 `.onProjectEvent`
    /// liveness guard on `.maughamOpenRewind`.
    let window: NSWindow?
    /// Fallback project URL naming this window's project scope while `store`
    /// hasn't loaded yet (threaded from CheckpointModifier, ADR 0021).
    let url: URL
    let selectedItemId: String?
    @State private var showingRewindModal: Bool = false
    @State private var rewindInitialCursor: RewindCursor = .now
    /// The post-restore report (RULING-28's after half) — rendered from
    /// `RewindImpact.toast(for:)`, auto-dismissing; carries Revert when the
    /// restore resolved a vanished moment to the nearest surviving one
    /// (RULING-27's notice).
    @State private var restoreToast: String?
    @State private var restoreToastOffersRevert: Bool = false
    @State private var restoreToastUndoManager: UndoManager?
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = restoreToast {
                    HStack(spacing: 12) {
                        Text(toast).font(.callout)
                        if restoreToastOffersRevert {
                            Button("Revert") {
                                restoreToastUndoManager?.undo()
                                restoreToast = nil
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                        Button {
                            restoreToast = nil
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        // A notice with an action lingers; a plain report
                        // dismisses itself.
                        try? await Task.sleep(nanoseconds: restoreToastOffersRevert
                                              ? 12_000_000_000 : 6_000_000_000)
                        restoreToast = nil
                    }
                }
            }
            .onProjectEvent(.maughamDocumentNotice,
                            url: store?.url ?? url, window: window) { note in
                // The Document's one writer-facing channel (RULING-7, RULING-22,
                // RULING-32), rendered in this modifier's own toast rather than a
                // second overlay that could stack with a restore report. No Revert —
                // none of these notices has an action, and a stale manager from an
                // earlier restore must not be left armed behind one.
                guard let message =
                    note.userInfo?[MaughamEvent.noticeMessageKey] as? String,
                      !message.isEmpty else { return }
                restoreToastOffersRevert = false
                restoreToastUndoManager = nil
                restoreToast = message
            }
            .onProjectEvent(.maughamOpenRewind,
                            url: store?.url ?? url, window: window) { note in
                // Project-scoped (ADR 0021): HistoryPane posts to
                // `.project(for: projectURL)`, so with multiple ProjectWindows
                // open only the window on the originating project — and only
                // while live — presents the modal. `selectedItemId != nil` is
                // an action precondition (need a doc to rewind), not a scope.
                guard selectedItemId != nil else { return }
                if let opId = note.userInfo?["scrub_op_id"] as? String,
                   let at = note.userInfo?["scrub_op_at"] as? Date {
                    rewindInitialCursor = .atOp(opId: opId, at: at)
                } else {
                    rewindInitialCursor = .now
                }
                showingRewindModal = true
            }
            .sheet(isPresented: $showingRewindModal) {
                rewindSheet
            }
    }

    @ViewBuilder
    private var rewindSheet: some View {
        if let store, let documentStore, let docId = selectedItemId {
            // Snapshot the window's undo manager before the escaping onComplete
            // closure so the restore registers a ⌘Z action (EditorHost's idiom).
            let um = undoManager
            let allIds = ProjectWindow.documentIds(in: store.manifest.structure)
            let paths = ProjectWindow.documentPaths(in: store.manifest.structure)
            let title = paths[docId]?.components(separatedBy: "/").last ?? docId
            RewindWindow(
                projectURL: store.url,
                activeDocId: docId,
                allDocIds: allIds,
                device: _checkpointDeviceId,
                session: _checkpointSessionId,
                docPaths: paths,
                documentStore: documentStore,
                docTitle: title,
                initialCursor: rewindInitialCursor,
                scope: .thisDoc,
                onComplete: { action in
                    showingRewindModal = false
                    switch action {
                    case .cancel:
                        break
                    case .snapshotHere:
                        MaughamEvent.post(
                            .maughamCheckpointAdded, to: .project(for: store.url))
                    case .restoreHere(let opId):
                        Task { @MainActor in
                            // The result is RENDERED, never discarded (RULING-28's after
                            // half): the toast reports what the restore did, and a
                            // `.nearest` resolution carries Revert in the notice (RULING-27).
                            let result: RewindRestoreResult
                            do {
                                guard let restored = try await documentStore
                                    .document(forDocId: docId)?
                                    .restoreToOpUndoable(opId: opId, undoManager: um)
                                else { return }
                                result = restored
                            } catch is Document.PostureRefusal {
                                // The restore door refused: a sheet drawn before a demotion
                                // landed. Said, not swallowed.
                                restoreToast = RewindWindow.refusedRestoreSentence
                                restoreToastOffersRevert = false
                                return
                            } catch {
                                return
                            }
                            restoreToast = RewindImpact.toast(for: result)
                            // Revert is the surfaced undo — offered only when the restore
                            // actually registered one. A Revert that pops the writer's own
                            // typing stack would be silent prose loss.
                            if case .nearest = result.targetResolution,
                               result.restoreOp != nil {
                                restoreToastOffersRevert = true
                            } else {
                                restoreToastOffersRevert = false
                            }
                            restoreToastUndoManager = um
                        }
                    }
                })
        }
    }

}
