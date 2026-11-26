import SwiftUI
import AppKit
import MaughamCore

/// **What was pulled up before** (appraisal wave, 2026-11-21): one thing is
/// pulled up at a time, and a title row inside a pulled-up region replaces
/// the region, so the pulled-up header has a Back that brings the previous
/// thing up again.
///
/// **It remembers; it never answers what is beside.** `subject.beside` is
/// the one answer to what is pulled up. This is a short list of what WAS,
/// written only by the window's observer of `beside`
/// (`PulledUpHistoryWiring`), bounded, in-window and never persisted. Back
/// is an ordinary pull-up (`ClickRule.pullUp`) of the entry it pops.
///
/// The newest entry is last. An entry that no longer resolves (a note
/// deleted, a card gone from the canvas) is skipped and dropped at Back.
struct PulledUpHistory: Equatable {
    /// At most this many entries; the oldest goes first.
    static let limit = 10

    private(set) var entries: [PulledUp]

    init(entries: [PulledUp] = []) {
        self.entries = Array(entries.suffix(Self.limit))
    }

    /// **After `beside` moved from `old` to `new`.** What was up goes on the
    /// end (once: an earlier copy moves up); what is up now is never an
    /// entry. An arrival BY Back records nothing it left: Back walks back,
    /// never round in a pair. Pure.
    func recording(from old: PulledUp?, to new: PulledUp?, byBack: Bool) -> PulledUpHistory {
        guard old != new else { return self }
        var next = entries
        if let new { next.removeAll { $0 == new } }
        if !byBack, let old {
            next.removeAll { $0 == old }
            next.append(old)
        }
        return PulledUpHistory(entries: next)
    }

    /// **What Back brings up**, and the history after it: the newest entry
    /// that is not what is up now and still resolves. Every entry passed over
    /// on the way (gone, or the current one) is dropped. Pure.
    func back(from current: PulledUp?,
              resolves: (PulledUp) -> Bool) -> (target: PulledUp?, rest: PulledUpHistory) {
        var rest = entries
        while let last = rest.popLast() {
            if last != current, resolves(last) {
                return (last, PulledUpHistory(entries: rest))
            }
        }
        return (nil, PulledUpHistory(entries: []))
    }

    /// Whether Back has anything to bring up. Pure.
    func offersBack(from current: PulledUp?, resolves: (PulledUp) -> Bool) -> Bool {
        back(from: current, resolves: resolves).target != nil
    }

    /// **Whether a pulled-up thing still resolves** — Back's one predicate,
    /// asked both by what offers Back (`PulledUpMemory.refreshBack`) and by
    /// the press (`takeBack`): the window sweep's own answer, a canvas card
    /// or region checked against whichever canvas is real. A disk read for a
    /// closed canvas: call it from a task or a press, never in a body.
    @MainActor
    static func resolvesFully(_ pulled: PulledUp, in store: ProjectStore) -> Bool {
        ProjectWindow.validatedSubject(
            WindowSubject(open: .project, faces: .project, beside: pulled), in: store).beside == pulled
    }
}

/// **The window's pulled-up memory** (appraisal wave): what was pulled up
/// before (`PulledUpHistory`), what Back would bring up now, whether the
/// centre's details stand open above what is pulled up
/// (`RightColumnContent.centreDetailsAbovePulledUp`), and whether the canvas's
/// selection is newer than the last pull-up (the cover's arming). Owned by
/// `ProjectWindow`, for the window's session; never persisted.
@MainActor
@Observable
final class PulledUpMemory {
    var history = PulledUpHistory()
    /// The centre's details over a pulled-up thing: collapsed until the
    /// writer opens them, then open for the rest of the window's session.
    var centreDetailsExpanded = false
    /// **What Back brings up now** — the header's Back and ⌘['s menu item
    /// show and enable on it, and the press brings exactly it: both ask
    /// `resolvesFully` (review M3). Kept by `PulledUpWatch`'s task, off the
    /// body path; nil hides Back.
    private(set) var backTarget: PulledUp?
    /// **Whether the canvas's selection was made after the last pull-up**
    /// (owner's ruling on review I1, 2026-11-21): the cover applies only
    /// then. A pull-up disarms it; the next change of the canvas's selection
    /// (`PulledUpWatch`) arms it again. A window opens with neither newer.
    private(set) var canvasSelectionIsNewer = false
    /// The entry Back is bringing up — read once by the observer, so the
    /// arrival does not record what it left.
    @ObservationIgnored var arrivingByBack: PulledUp?

    /// The observer's write: `beside` moved from `old` to `new`. Every
    /// change of what is pulled up is a pull-up the writer should see.
    func record(from old: PulledUp?, to new: PulledUp?) {
        let byBack = new != nil && arrivingByBack == new
        arrivingByBack = nil
        history = history.recording(from: old, to: new, byBack: byBack)
        pulledUp()
    }

    /// **A pull-up was made**: what is pulled up shows over a standing
    /// canvas selection. The observer calls it on every change of `beside`,
    /// and `ProjectWindow.pullUp` on a pull-up of what is already up (which
    /// changes no subject, so no observer sees it).
    func pulledUp() {
        if canvasSelectionIsNewer { canvasSelectionIsNewer = false }
    }

    /// **The canvas's selection changed** (`PulledUpWatch`): the cover arms.
    func canvasSelectionChanged() {
        if !canvasSelectionIsNewer { canvasSelectionIsNewer = true }
    }

    /// Asks Back's predicate again for what Back would bring up now.
    func refreshBack(from current: PulledUp?, store: ProjectStore) {
        let target = history.back(from: current) {
            PulledUpHistory.resolvesFully($0, in: store)
        }.target
        if target != backTarget { backTarget = target }
    }

    /// **Back**: pops the entry to bring up (the full check, so a gone card
    /// is skipped), marks it as arriving by Back, and hands it to the
    /// caller's pull-up act. nil when nothing resolves.
    func takeBack(from current: PulledUp?, store: ProjectStore) -> PulledUp? {
        let (target, rest) = history.back(from: current) {
            PulledUpHistory.resolvesFully($0, in: store)
        }
        history = rest
        arrivingByBack = target
        return target
    }
}

/// **The pulled-up history, wired once on the window** — mounted on
/// `ProjectWindow.body`, so it records whether or not the right column is
/// drawn: the observer of `beside` (the history's one writer), ⌘['s receiver
/// (View ▸ Back), the focused value that enables it, and the
/// leaf that watches the canvas's selection and asks what Back brings
/// (`PulledUpWatch`).
struct PulledUpHistoryWiring: ViewModifier {
    let store: ProjectStore?
    let window: NSWindow?
    @Binding var subject: WindowSubject
    let memory: PulledUpMemory
    @Binding var showInspector: Bool
    @Binding var position: RightColumnPosition
    /// This window's canvas, read only by `PulledUpWatch`.
    let canvasModel: CanvasModel
    /// The tree's count of Claude's writes into a closed canvas; nil in a probe.
    var treeState: BinderTreeSectionsState? = nil

    func body(content: Content) -> some View {
        content
            .onChange(of: subject.beside) { old, new in
                memory.record(from: old, to: new)
            }
            .onKeyWindowCommand(.maughamPullUpPrevious, window: window) { _ in
                guard let store,
                      let target = memory.takeBack(from: subject.beside, store: store) else { return }
                ProjectWindow.pullUp(target, subject: $subject, showInspector: $showInspector,
                                     position: $position, memory: memory)
            }
            .focusedSceneValue(\.pulledUpBackIsOffered, memory.backTarget != nil)
            .background {
                if let store {
                    PulledUpWatch(store: store, model: canvasModel, memory: memory,
                                  beside: subject.beside, treeState: treeState)
                }
            }
    }
}

/// **The leaf that reads the canvas for the pulled-up memory**, so neither
/// the window nor the column does (tripwires 4, 30): it observes
/// `CanvasModel.selection` (its own stored property, written on a click, a
/// drop, a key or a delete, never per drag frame) to arm the cover, and asks
/// Back's predicate in a `.task` keyed on the history, what is pulled up, the
/// manifest and the canvas's STRUCTURAL revision — never the per-frame
/// counter. Draws nothing.
private struct PulledUpWatch: View {
    let store: ProjectStore
    let model: CanvasModel
    let memory: PulledUpMemory
    let beside: PulledUp?
    let treeState: BinderTreeSectionsState?

    private struct BackKey: Equatable {
        let history: PulledUpHistory
        let beside: PulledUp?
        let manifestModified: Date
        let canvas: CanvasCardsRevision
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: model.selection) { _, _ in memory.canvasSelectionChanged() }
            .task(id: BackKey(history: memory.history, beside: beside,
                              manifestModified: store.manifest.modified,
                              canvas: CanvasCardsRevision(
                                sceneRevision: model.sceneRevision,
                                closedCanvasWrites: treeState?.closedCanvasWrites ?? 0))) {
                memory.refreshBack(from: beside, store: store)
            }
    }
}
