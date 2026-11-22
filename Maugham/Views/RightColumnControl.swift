import SwiftUI
import AppKit
import MaughamCore

/// **The right column's control** (shell plan 3 Task 9): three positions in
/// one row — To resolve, Brief and the pulled-up thing — in place of the pane
/// picker. The pulled-up segment carries its item's title, truncated in the
/// middle, and is hidden (never disabled) while the position would show
/// nothing (`RightColumnContent.offersPulledUp`).
///
/// **It holds no shortcut.** ⌘1/⌘2/⌘3 and every ⌘⌥ key are the View menu's
/// (`MaughamApp`), so each reveals a hidden column through the window's one
/// receiver (`PaneKeyspaceTests`).
///
/// **A dot, never a number**: on To resolve while the faces' checks are
/// unread, on Brief while a visual-language proposal waits.
struct RightColumnControl: View {
    let store: ProjectStore
    @Binding var position: RightColumnPosition
    let subject: WindowSubject
    let diagnostics: DiagnosticsStore?
    /// The pane's width (the column's less the resize handle), a value: the
    /// title is drawn only where it has room (`showsTitle`).
    let width: CGFloat
    /// The window's count of Claude's writes into a closed canvas — with
    /// the scene revision, what a pulled-up region's title is re-read on
    /// (`CanvasCardsRevision`, the fold's own signal).
    var closedCanvasWrites: Int = 0
    /// THIS window's canvas, whose structural revision re-reads a pulled-up
    /// region's title — never `store.liveCanvas`, the newest window's
    /// (review M1). Read only while a region is pulled up.
    var canvasModel: CanvasModel? = nil
    /// The language the faces are read in (`ReadingLanguage.of`) and the
    /// book's own — what To resolve's scope is asked over, so the dot is.
    var readIn: String? = nil
    var sourceLanguage: String = PublishConfig.Metadata().language

    @State private var visualLanguageProposed = false
    /// Edition briefs a proposal waits for (fix round I4).
    @State private var editionBriefsProposed: Set<String> = []
    /// This control's hosting window, for the proposal event's liveness guard
    /// (`MaughamEvent.isLive`).
    @State private var window: NSWindow?
    /// `unreadDocId(subject:readIn:sourceLanguage:store:)`, resolved once per
    /// subject or reading-language change, never
    /// per render: at the Book `ResolveScope.of` walks the tree (tripwire 4).
    @State private var unreadDocId: String?
    /// A pulled-up region's title, read in a `.task` keyed on the canvas's
    /// structural revision: the scene is never read in a body (tripwires 4, 30).
    @State private var regionTitle: String?

    // MARK: - The decisions, pure

    /// The positions drawn, in the one order (`RightColumnPosition.allCases`):
    /// the pulled-up position only while it would show something, or while it
    /// is the one selected (a restored window opens on its remembered
    /// position).
    static func segments(offersPulledUp: Bool,
                         selected: RightColumnPosition) -> [RightColumnPosition] {
        RightColumnPosition.allCases.filter {
            $0 != .pulledUp || offersPulledUp || selected == .pulledUp
        }
    }

    /// The pane width below which the pulled-up segment is its icon alone.
    static let titleFloor: CGFloat = 200

    /// Whether the pulled-up segment draws its title: there is one, and the
    /// pane is wide enough to give it room.
    static func showsTitle(_ title: String?, paneWidth: CGFloat) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return paneWidth >= titleFloor
    }

    /// **When To resolve and Brief are written out, not only drawn as icons**
    /// (appraisal 3): the two names the design is built on, whenever the row
    /// has room for them beside what else it draws. With only the two
    /// segments they fit across the column's whole range; beside the
    /// pulled-up segment's icon they need `namesFloorBesideIcon`; beside its
    /// title, `namesFloorBesideTitle` — below that the title keeps the room
    /// and the names go back to icons. Pure.
    static func showsNames(paneWidth: CGFloat, segmentCount: Int,
                           pulledUpTitleDrawn: Bool) -> Bool {
        let floor: CGFloat
        if segmentCount < RightColumnPosition.allCases.count {
            floor = namesFloorAlone
        } else {
            floor = pulledUpTitleDrawn ? namesFloorBesideTitle : namesFloorBesideIcon
        }
        return paneWidth >= floor
    }

    static let namesFloorAlone: CGFloat = 200
    static let namesFloorBesideIcon: CGFloat = 260
    static let namesFloorBesideTitle: CGFloat = 340

    /// The pulled-up thing's title, nil with nothing pulled up.
    @MainActor
    static func pulledUpTitle(subject: WindowSubject, store: ProjectStore,
                              regionTitle: String? = nil) -> String? {
        subject.beside.map { PulledUpView.title(of: $0, store: store, regionTitle: regionTitle) }
    }

    /// Which position carries a dot. A proposal's dot is Brief's (the Book's
    /// Brief leads to Visual Language); unread checks' is To resolve's.
    static func showsDot(on position: RightColumnPosition,
                         checksUnread: Bool, proposalPending: Bool) -> Bool {
        switch position {
        case .resolve: return checksUnread
        case .brief: return proposalPending
        case .pulledUp: return false
        }
    }

    /// The faces' piece the unread dot is about (`ResolvePane.unreadDocId`):
    /// the doc id To resolve clears, asked over the SAME scope the pane shows
    /// — the faces read in `readIn` (`ReadingLanguage.of`, the pane's own
    /// answer) — so a dot never stands where the list could not clear it. A
    /// piece read in a language lists no checks, so it carries no checks dot
    /// (plan 4 closing review, I1).
    @MainActor
    static func unreadDocId(subject: WindowSubject, readIn: String?, sourceLanguage: String,
                            store: ProjectStore) -> String? {
        ResolvePane.unreadDocId(scope: ResolveScope.of(
            subject.faces, readIn: readIn, sourceLanguage: sourceLanguage,
            structure: store.manifest.structure, projectType: store.manifest.type))
    }

    /// A segment's tooltip: the position's own, or the pulled-up item's name.
    static func help(for position: RightColumnPosition, title: String?) -> String {
        guard position == .pulledUp, let title, !title.isEmpty else { return position.helpText }
        return "\(title) — pulled up (\u{2318}3)"
    }

    static let unreadDotHelp = "New notes from the last check (\u{2318}\u{2325}D)"
    static let proposalDotHelp =
        "Claude proposed a visual language — open it to adopt or discard (\u{2318}\u{2325}V)"

    /// A segment's accessibility name.
    static func name(of position: RightColumnPosition) -> String {
        switch position {
        case .resolve: return "To resolve"
        case .brief: return "Brief"
        case .pulledUp: return "Pulled up"
        }
    }

    // MARK: - The view

    /// Brief's dot: a visual language proposed, or a brief proposed for the
    /// edition the faces are on (fix round I4).
    private var briefProposalPending: Bool {
        Self.briefProposalPending(visualLanguage: visualLanguageProposed,
                                  editionBriefs: editionBriefsProposed, faces: subject.faces)
    }

    static func briefProposalPending(visualLanguage: Bool, editionBriefs: Set<String>,
                                     faces: BinderSubject) -> Bool {
        if visualLanguage { return true }
        if case .edition(let language) = faces { return editionBriefs.contains(language.lowercased()) }
        return false
    }

    static let editionProposalDotHelp =
        "Claude proposed a brief for this edition \u{2014} open Brief to adopt or discard (\u{2318}2)"

    private var checksUnread: Bool {
        guard let diagnostics, let unreadDocId else { return false }
        return UnreadDot.shows(unreadChecks: diagnostics.unreadCount(docId: unreadDocId))
    }

    var body: some View {
        let title = Self.pulledUpTitle(subject: subject, store: store, regionTitle: regionTitle)
        let drawsTitle = Self.showsTitle(title, paneWidth: width)
        let offered = Self.segments(
            offersPulledUp: RightColumnContent.offersPulledUp(
                subject, structure: store.manifest.structure, projectType: store.manifest.type),
            selected: position)
        let drawsNames = Self.showsNames(
            paneWidth: width, segmentCount: offered.count,
            pulledUpTitleDrawn: drawsTitle && offered.contains(.pulledUp))
        HStack(spacing: 4) {
            ForEach(offered, id: \.self) { segment in
                self.segment(segment, title: title,
                             drawsTitle: drawsTitle && segment == .pulledUp,
                             drawsName: drawsNames && segment != .pulledUp,
                             // With a title drawn, the two leading segments
                             // keep their icon's width and the title takes
                             // the rest; otherwise the row is shared evenly.
                             flexible: !drawsTitle || segment == .pulledUp)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Right column")
        .onChange(of: DotKey(subject: subject, readIn: readIn, sourceLanguage: sourceLanguage),
                  initial: true) { _, new in
            unreadDocId = Self.unreadDocId(subject: new.subject, readIn: new.readIn,
                                           sourceLanguage: new.sourceLanguage, store: store)
        }
        .task(id: regionTitleKey) {
            regionTitle = regionTitleKey.flatMap { PulledUpView.regionTitle($0.regionId, store: store) }
        }
        .background(WindowAccessor(window: $window))
        .modifier(VisualLanguageProposalModifier(
            projectURL: store.url, window: window, proposed: $visualLanguageProposed,
            editionBriefs: $editionBriefsProposed))
    }

    /// What the dot's doc id is resolved on.
    struct DotKey: Equatable {
        let subject: WindowSubject
        let readIn: String?
        /// The book's own language: an edition is the Source by it, so a
        /// config read after the first render asks again (closing review M6).
        let sourceLanguage: String
    }

    private struct RegionTitleKey: Equatable {
        let regionId: String
        let canvas: CanvasCardsRevision
    }

    /// Only a pulled-up region observes the canvas's revision.
    private var regionTitleKey: RegionTitleKey? {
        guard case .canvasRegion(let id)? = subject.beside else { return nil }
        return RegionTitleKey(regionId: id,
                              canvas: CanvasCardsRevision(sceneRevision: canvasModel?.sceneRevision,
                                                          closedCanvasWrites: closedCanvasWrites))
    }

    private func segment(_ segment: RightColumnPosition, title: String?,
                         drawsTitle: Bool, drawsName: Bool, flexible: Bool) -> some View {
        let selected = segment == position
        return Button {
            position = segment
        } label: {
            HStack(spacing: 4) {
                Image(systemName: segment.systemImageName)
                if drawsName {
                    // Whole or not at all: a clipped "To res…" names nothing.
                    Text(Self.name(of: segment))
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(drawsTitle ? (title ?? "") : "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: drawsTitle ? .infinity : 0, alignment: .leading)
                    .opacity(drawsTitle ? 1 : 0)
            }
            .font(.callout)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .frame(minWidth: 36, maxWidth: flexible ? .infinity : nil, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(selected ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            UnreadDot()
                .padding(.trailing, 4)
                .padding(.top, 2)
                .allowsHitTesting(false)
                .opacity(Self.showsDot(on: segment, checksUnread: checksUnread,
                                       proposalPending: briefProposalPending) ? 1 : 0)
                .accessibilityHidden(!Self.showsDot(on: segment, checksUnread: checksUnread,
                                                    proposalPending: briefProposalPending))
        }
        .help(dotHelp(for: segment) ?? Self.help(for: segment, title: title))
        .accessibilityLabel(Self.name(of: segment))
        .accessibilityValue(segment == .pulledUp ? (title ?? "") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("right-column-\(segment.rawValue)")
    }

    private func dotHelp(for segment: RightColumnPosition) -> String? {
        guard Self.showsDot(on: segment, checksUnread: checksUnread,
                            proposalPending: briefProposalPending) else { return nil }
        if segment == .resolve { return Self.unreadDotHelp }
        return visualLanguageProposed ? Self.proposalDotHelp : Self.editionProposalDotHelp
    }
}

/// **Whether a visual-language proposal is standing** (translation pipeline
/// P5) — the Brief segment's dot, read and kept fresh here, and Brief's
/// notice over it (`BriefProposalNotice`, appraisal 10): one source for both.
///
/// The `.task` owns cancellation, not a direct `await` in the notification
/// closure (`StatementPane`'s idiom): the event bumps `reloads`, which
/// re-keys the read.
struct VisualLanguageProposalModifier: ViewModifier {
    let projectURL: URL
    let window: NSWindow?
    @Binding var proposed: Bool
    /// Languages an edition-brief proposal waits for, lowercased (fix round
    /// I4) — read in the same pass; nil where the host does not ask.
    var editionBriefs: Binding<Set<String>>? = nil

    @State private var reloads = 0

    private struct TaskKey: Equatable {
        let projectPath: String
        let reloads: Int
        /// `WindowAccessor` resolves `window` on an async hop after mount, and
        /// `MaughamEvent.shouldDeliver` drops a `.project` post while it is
        /// still nil — so a proposal staged in the first frames is a post
        /// nothing catches. Re-reading the slot when the window arrives costs
        /// one JSON read, once (`StatementPane.ProposalTaskKey`'s field).
        let windowResolved: Bool
    }

    func body(content: Content) -> some View {
        content
            .task(id: TaskKey(projectPath: projectURL.path,
                              reloads: reloads, windowResolved: window != nil)) {
                let pending = StatementProposalStore(projectURL: projectURL).pendingAll()
                proposed = pending.contains { $0.kind == .visualLanguage }
                editionBriefs?.wrappedValue = ResolvePresence.proposedBriefLanguages(pending)
            }
            .onProjectEvent(.maughamStatementProposalsChanged,
                            url: projectURL, window: window) { _ in
                reloads += 1
            }
    }
}
