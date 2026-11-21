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

    /// Whether Back has anything to bring up — hidden, never disabled, when
    /// not. Pure.
    func offersBack(from current: PulledUp?, resolves: (PulledUp) -> Bool) -> Bool {
        back(from: current, resolves: resolves).target != nil
    }

    /// **Whether a pulled-up thing still resolves**, read in a body: the
    /// manifest's answer (`WindowSubject.validated`), a canvas card or region
    /// counted as present, because the canvas is read off the body path. Back
    /// itself asks `resolvesFully`.
    @MainActor
    static func resolves(_ pulled: PulledUp, in store: ProjectStore) -> Bool {
        ProjectWindow.validatedSubject(
            WindowSubject(open: .project, faces: .project, beside: pulled),
            structure: store.manifest.structure, research: store.manifest.research,
            figures: store.manifest.figures ?? [], parked: [], editionLanguages: []).beside == pulled
    }

    /// The same, with a canvas card or region checked against whichever
    /// canvas is real (the window sweep's own answer). A disk read for a
    /// closed canvas: call it on a press, never in a body.
    @MainActor
    static func resolvesFully(_ pulled: PulledUp, in store: ProjectStore) -> Bool {
        ProjectWindow.validatedSubject(
            WindowSubject(open: .project, faces: .project, beside: pulled), in: store).beside == pulled
    }
}

/// **The window's pulled-up memory** (appraisal wave): what was pulled up
/// before (`PulledUpHistory`) and whether the centre's details stand open
/// above what is pulled up (`RightColumnContent.centreDetailsAbovePulledUp`).
/// Owned by `ProjectWindow`, for the window's session; never persisted.
@MainActor
@Observable
final class PulledUpMemory {
    var history = PulledUpHistory()
    /// The centre's details over a pulled-up thing: collapsed until the
    /// writer opens them, then open for the rest of the window's session.
    var centreDetailsExpanded = false
    /// The entry Back is bringing up — read once by the observer, so the
    /// arrival does not record what it left.
    @ObservationIgnored var arrivingByBack: PulledUp?

    /// The observer's write: `beside` moved from `old` to `new`.
    func record(from old: PulledUp?, to new: PulledUp?) {
        let byBack = new != nil && arrivingByBack == new
        arrivingByBack = nil
        history = history.recording(from: old, to: new, byBack: byBack)
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
/// (View ▸ Pull Up Previous), and the focused value that enables it.
struct PulledUpHistoryWiring: ViewModifier {
    let store: ProjectStore?
    let window: NSWindow?
    @Binding var subject: WindowSubject
    let memory: PulledUpMemory
    @Binding var showInspector: Bool
    @Binding var position: RightColumnPosition

    func body(content: Content) -> some View {
        content
            .onChange(of: subject.beside) { old, new in
                memory.record(from: old, to: new)
            }
            .onKeyWindowCommand(.maughamPullUpPrevious, window: window) { _ in
                guard let store,
                      let target = memory.takeBack(from: subject.beside, store: store) else { return }
                ProjectWindow.pullUp(target, subject: $subject, showInspector: $showInspector,
                                     position: $position)
            }
            .focusedSceneValue(\.pulledUpBackIsOffered,
                               store.map { store in
                                   memory.history.offersBack(from: subject.beside) {
                                       PulledUpHistory.resolves($0, in: store)
                                   }
                               } ?? false)
    }
}
