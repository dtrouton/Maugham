import SwiftUI
import MaughamCore
import AppKit

/// **The rows under a folded piece row** — the piece's material (shell p3
/// Task 7; stage-2a Task 6 before it): its research, its canvas cards, its
/// palette pins, its figures and its links in both directions.
///
/// **What a fold holds is not decided here.** It is `PieceFoldIndex`, built
/// once per `PieceFoldIndex.Key` in the hosts' `.task`
/// (`PieceFoldIndexing`) and looked up per row (tripwire 4); this view only
/// draws the layout it is handed. One implementation for both hosts
/// (`BinderView`, `CollectionPiecesPane`) for the reason `BinderTreeSections`
/// is one: a copy drifts.
///
/// **Research is the book's or a piece's, never both** (shell p5 Task 4a,
/// `ResearchHomes`). A fold holds what the piece's folder files (a
/// Collection's) and what the piece links (a novel's), drawn alike — as the
/// Research section draws research, its groups opening — since neither has a
/// twin in the section any more. A root whose group lives elsewhere names
/// that group beside its title (`ResearchHomes.place`); a note two chapters
/// link is a row in each fold, its tag naming the fold (`TreeRowTag.inFold`),
/// and renames only where it is drawn once.
///
/// **How each row acts** (`act(of:)`, the click rule): research is a `List`
/// tag, as anywhere in the tree; a card, a region, a palette pin or a figure
/// is pulled up beside by a `Button(.plain)` (tripwire 9), and a second click
/// on the one pulled up puts it away (a region's chevron opens to its cards);
/// a link travels to its piece. A double-click, or the row's Open in Centre,
/// always opens it in the centre: a research row's through the tree's
/// double-click watcher (`TreeTravel`), a pull-up row's by the pair its
/// presses make (`press`), so the second click of a double-click opens and
/// never toggles the row back.
///
/// **It is mounted inside a `DisclosureGroup` by the host**, never on its own:
/// the chevron belongs to the piece row, which stays the unchanged
/// `BinderRow`/`PieceRow` — still draggable, still renamable — and shows only
/// when the index has entries for the piece.
struct BinderPieceFold: View {
    @Bindable var store: ProjectStore
    @Bindable var state: BinderTreeSectionsState
    @Binding var subject: WindowSubject
    @Environment(\.rowThumbnailRoot) private var thumbnailRoot
    /// This window's canvas, where Open in Centre selects (`windowCanvas`).
    @Environment(\.windowCanvas) private var windowCanvas
    /// The document this fold hangs under — and the *scope* a note made from a
    /// row in it belongs to. See `actions`.
    let documentId: String
    /// The index's layout for this piece, looked up by the host.
    let layout: PieceFoldLayout

    var body: some View {
        // Built once for the fold rather than once per row: the bundle is a
        // pile of closures over the same store, and nothing in it varies by
        // item (`ResearchTreeNode` passes the row in at call time).
        let actions = actions
        // Asked once per fold, not per row: may this piece's links be edited,
        // the research items the rows draw (one walk, never one per row), and
        // the piece's own title for its link rows' help.
        let fold = FoldContext(mayEditLinks: mayEditLinks,
                               items: Self.researchItems(for: layout, in: store.manifest.research),
                               homes: state.researchHomes(in: store.manifest),
                               pieceTitle: TreeWalk.find(id: documentId, in: store.manifest.structure)?.title
                                   ?? "")
        switch layout {
        case .rows(let entries):
            ForEach(entries) { entry in
                row(entry, actions: actions, fold: fold)
            }
        case .groups(let runs):
            ForEach(runs, id: \.group) { run in
                DisclosureGroup(isExpanded: groupExpansion(run.group)) {
                    ForEach(run.entries) { entry in
                        row(entry, actions: actions, fold: fold)
                    }
                } label: {
                    Text(Self.groupTitle(run))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Rows

    /// What every row of one fold shares, worked out once per fold.
    private struct FoldContext {
        let mayEditLinks: Bool
        let items: [String: ResearchItem]
        /// The window's homes: each row's place, and whether it is drawn twice.
        let homes: ResearchHomes
        let pieceTitle: String
    }

    /// The research items a layout's research rows name, by id — one walk of
    /// the research tree per fold (a 200-item group is not 200 walks).
    static func researchItems(for layout: PieceFoldLayout,
                              in research: [ResearchItem]) -> [String: ResearchItem] {
        let entries: [PieceFoldEntry]
        switch layout {
        case .rows(let rows): entries = rows
        case .groups(let runs): entries = runs.flatMap(\.entries)
        }
        var wanted = Set<String>()
        for case .research(let id, _, _) in entries { wanted.insert(id) }
        var out: [String: ResearchItem] = [:]
        func walk(_ items: [ResearchItem]) {
            for item in items where !wanted.isEmpty {
                if wanted.remove(item.id) != nil { out[item.id] = item }
                walk(item.children ?? [])
            }
        }
        walk(research)
        return out
    }

    @ViewBuilder
    private func row(_ entry: PieceFoldEntry, actions: ResearchTreeActions,
                     fold: FoldContext) -> some View {
        switch entry {
        case .research(let id, _, _):
            if let item = fold.items[id] {
                ResearchTreeNode(
                    item: item,
                    renamingItemId: $state.renamingItemId,
                    findParentId: { findParentId(of: $0) },
                    actions: actions,
                    // A folded row is a subject of the window exactly like a
                    // row in the Research section — same case, same id — and
                    // its tag names this fold (`TreeRowTag.inFold`), so the
                    // same note under two chapters is two rows.
                    tagFor: { BinderSubject.research($0.id) },
                    inFold: documentId,
                    // One `renamingItemId` matching two rows mounts two rename
                    // fields (finding I2): a note two chapters hold renames in
                    // the first of them, in tree order, and nowhere else. (A
                    // single-document project's fold lists the book's research,
                    // whose row in the Research section renames it.)
                    offersRename: { [homes = fold.homes, documentId] in
                        homes.homes(of: $0).first == documentId
                    },
                    caption: fold.homes.place(of: id),
                    // **The fold's own groups share the tree's set of open
                    // ids** (stage-3b Task 7), so a reveal can open them.
                    expandedGroups: $state.expandedResearchGroups,
                    appliesScrollIdentity: true)
            }
        case .card(let ref):
            cardRow(entry, ref: ref)
        case .region(let id, let title, let cards):
            // A group row (owner, 2026-11-20): its chevron opens its cards in
            // the shelf's order; its label pulls the region up beside.
            DisclosureGroup(isExpanded: regionExpansion(id)) {
                ForEach(entry.regionCards) { card in
                    if case .card(let ref) = card { cardRow(card, ref: ref) }
                }
            } label: {
                pullUpRow(entry, glyph: state.foldIndex.glyph(of: entry), title: title,
                          caption: Self.regionCount(cards.count))
            }
        case .palette(_, let title):
            pullUpRow(entry, glyph: state.foldIndex.glyph(of: entry), title: title, caption: nil)
        case .figure(_, let name):
            // Pulled up beside, like every other fold row (appraisal 8); the
            // Figures section's row is the one that takes the centre.
            pullUpRow(entry, glyph: Self.figureGlyph, title: name, caption: nil)
        case .scene(let docId, let paragraphId, let heading):
            // A place in the script, as a slugline in the Scenes navigator is:
            // a button that travels, never a tag (arrowing onto it would move
            // the centre).
            Button {
                ResolveNavigation.go(toDocId: docId, paragraphId: paragraphId)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.sceneGlyph)
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Text(heading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.sceneHelp(heading))
            .accessibilityLabel(Self.sceneAccessibilityLabel(heading))
        case .link(let pieceId, let title, let incoming):
            Button {
                subject = Self.clicked(entry, subject: subject,
                                       structure: store.manifest.structure,
                                       projectType: store.manifest.type)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: incoming ? Self.incomingLinkGlyph : Self.outgoingLinkGlyph)
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.linkHelp(incoming: incoming, piece: fold.pieceTitle, other: title))
            .contextMenu {
                if Self.offersRemoveLink(entry, mayEditLinks: fold.mayEditLinks) {
                    Button(Self.removeLinkTitle) { removeLink(to: pieceId) }
                }
            }
        }
    }

    /// A card row, in the fold or under its region's chevron.
    private func cardRow(_ entry: PieceFoldEntry, ref: PinnedReference) -> some View {
        pullUpRow(entry, glyph: state.foldIndex.glyph(of: entry), title: ref.title,
                  caption: nil)
    }

    /// A card, a region, a palette pin or a figure: pulled up beside by a
    /// click, put away by a second click on the one pulled up, opened in the
    /// centre by a double-click, and drawn outlined while it is pulled up.
    private func pullUpRow(_ entry: PieceFoldEntry, glyph: String, title: String,
                           caption: String?) -> some View {
        Button {
            pressed(entry)
        } label: {
            HStack(spacing: 6) {
                // A picture's thumbnail in the glyph's place, one line high.
                RowThumbnail(source: thumbnailSource(of: entry), glyph: glyph,
                             side: RowThumbnail.treeSide)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver names what the row is and what activating it does
        // (Return, Space or a click pulls it up; ⌘↓ or a double-click opens it
        // in the centre — `TreeRowKeys`).
        .accessibilityLabel(Self.accessibilityLabel(entry, title: title))
        .accessibilityHint(Self.accessibilityHint(entry, subject: subject))
        .accessibilityAction(named: BesideHeader.openInCentreLabel) { openInCentre(entry) }
        .overlay {
            if Self.drawsOutline(entry, inFoldOf: documentId, subject: subject, state: state) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            Button(BesideHeader.openInCentreLabel) { openInCentre(entry) }
        }
        // **The keys reach it** (shell p4 Task 10, plan call 5): a tree-local
        // tag, so arrowing onto the row is a `List` write the binding answers
        // with `ClickRule.pullUp` — the row pulled up beside, the centre and
        // the faces untouched. The button above stays the mouse's: it takes
        // the click, so the table never selects on it and nothing fires twice.
        .tag(Self.tag(of: entry, inFoldOf: documentId))
    }

    private func thumbnailSource(of entry: PieceFoldEntry) -> RowThumbnails.Source? {
        guard let thumbnailRoot, let path = state.foldIndex.thumbnail(of: entry) else { return nil }
        return RowThumbnails.Source(path: path, root: thumbnailRoot)
    }

    private func groupExpansion(_ group: PieceFoldGroup) -> Binding<Bool> {
        let key = PieceFoldGroupKey(docId: documentId, group: group)
        return Binding(
            get: { state.expandedFoldGroups.contains(key) },
            set: { open in
                if open { state.expandedFoldGroups.insert(key) }
                else { state.expandedFoldGroups.remove(key) }
            })
    }

    /// A region row's chevron, remembered as the groups' are.
    private func regionExpansion(_ regionId: String) -> Binding<Bool> {
        let key = PieceFoldRegionKey(docId: documentId, regionId: regionId)
        return Binding(
            get: { state.expandedFoldRegions.contains(key) },
            set: { open in
                if open { state.expandedFoldRegions.insert(key) }
                else { state.expandedFoldRegions.remove(key) }
            })
    }

    /// Whether this piece's links may be edited here: the piece's structure
    /// door, as Rename and Brief's line ask (`TreeStructureVerbs.mayRestructure`).
    private var mayEditLinks: Bool {
        guard let documentStore = store.documentStore,
              let item = TreeWalk.find(id: documentId, in: store.manifest.structure)
        else { return false }
        return TreeStructureVerbs.mayRestructure(
            item, postureOf: { documentStore.posture(forDocId: $0) })
    }

    private func removeLink(to target: String) {
        guard let item = TreeWalk.find(id: documentId, in: store.manifest.structure) else { return }
        let links = (item.links ?? []).filter { $0 != target }
        verbs.perform { [store, documentId] in
            try await store.updateInspector(id: documentId, links: links)
        }
    }

    /// **A press on a pull-up row**: the first of a pair pulls the row up
    /// (or puts it away), the second opens it in the centre
    /// (`press`, pure). The button fires once per click, so the pair is read
    /// from the presses themselves, never from a gesture (tripwire 9).
    private func pressed(_ entry: PieceFoldEntry) {
        let outcome = Self.buttonPress(
            entry, at: ProcessInfo.processInfo.systemUptime, last: state.lastFoldPress,
            interval: NSEvent.doubleClickInterval, subject: subject,
            structure: store.manifest.structure, projectType: store.manifest.type)
        state.lastFoldPress = outcome.lastFoldPress
        state.lastRowPress = outcome.rowPress
        // The press is the click's act: a selection waiting to settle on this
        // row (the keys', or a misread pointer's) waits no more.
        state.pendingSettle = nil
        switch outcome.press {
        case .single:
            guard let next = outcome.subject,
                  let row = Self.foldRow(of: entry, inFoldOf: documentId) else { return }
            // The keyboard carries on from the row clicked (review Minor 8).
            state.record(selection: [], subject: next, foldRow: row)
            subject = next
        case .double:
            openInCentre(entry)
        }
    }

    /// Every press on a pull-up row: which row (what it pulls up) and when.
    struct RowPress: Equatable {
        let pulled: PulledUp
        let at: TimeInterval
    }

    /// What a press on a pull-up row does, worked out from the state BEFORE
    /// the click (shell p4 Task 10 fix round 1, review I1).
    struct ButtonPress: Equatable {
        let press: Press
        /// A single press's subject: the click rule's toggle. Nil for a
        /// double (Open in Centre, performed by the view).
        let subject: WindowSubject?
        let lastFoldPress: LastPress?
        let rowPress: RowPress?
    }

    /// **A press on a pull-up row, pure.** The click's one act: whether the
    /// table also selected the row (before or after) never changes it, since
    /// a pointer's selection only selects (`BinderTreeSelection.resolvedTags`)
    /// and a selection arriving within `interval` of this press waits for
    /// nothing (`pressedJustNow`). A double is the pair's second press.
    static func buttonPress(_ entry: PieceFoldEntry, at now: TimeInterval, last: LastPress?,
                            interval: TimeInterval, subject: WindowSubject,
                            structure: [StructureItem], projectType: ProjectType) -> ButtonPress {
        let press = Self.press(entry.id, at: now, last: last, interval: interval)
        let rowPress = entry.pulledUp.map { RowPress(pulled: $0, at: now) }
        switch press {
        case .single:
            // A double-click's pair is spent: a third click starts a new one.
            return ButtonPress(press: .single,
                               subject: clicked(entry, subject: subject, structure: structure,
                                                projectType: projectType),
                               lastFoldPress: LastPress(entryId: entry.id, at: now),
                               rowPress: rowPress)
        case .double:
            return ButtonPress(press: .double, subject: nil, lastFoldPress: nil, rowPress: rowPress)
        }
    }

    /// Whether `pulled`'s row was pressed within the system's double-click
    /// interval — a selection of it now is that click's other arrival. The
    /// pairing's own clock, read; never a timer of its own.
    static func pressedJustNow(_ pulled: PulledUp, last: RowPress?, now: TimeInterval,
                               interval: TimeInterval = NSEvent.doubleClickInterval) -> Bool {
        guard let last, last.pulled == pulled, now >= last.at else { return false }
        return now - last.at <= interval
    }

    /// Open in Centre from a pulled-up row's menu, or its double-click: what
    /// the pulled-up view's own Open in Centre does (`PulledUpView.opening`).
    /// A picture's node is found on whichever canvas is real (the live model,
    /// else the sidecar), so it is selected when the canvas was not open; the
    /// selection itself is parked on THIS window's model (`windowCanvas`)
    /// until the canvas loads (`CanvasModel.revealAndSelect`).
    private func openInCentre(_ entry: PieceFoldEntry) {
        guard let pulled = entry.pulledUp else { return }
        Self.openInCentre(pulled, subject: $subject, store: store, windowCanvas: windowCanvas)
    }

    /// **Open in Centre for a pulled-up fold row** — its double-click, its
    /// menu item, its VoiceOver action and ⌘↓ (`TreeRowKeys`), one body.
    @MainActor
    static func openInCentre(_ pulled: PulledUp, subject: Binding<WindowSubject>,
                             store: ProjectStore, windowCanvas: CanvasModel?) {
        let opening = Self.opening(
            pulled, subject: subject.wrappedValue,
            structure: store.manifest.structure, projectType: store.manifest.type,
            photoNode: { path in PulledUpView.photoNode(path, store: store) })
        switch opening {
        case .subject(let next):
            subject.wrappedValue = next
        case .canvas(let next, let target):
            subject.wrappedValue = next
            if let target { windowCanvas?.revealAndSelect(target) }
        case .centreItem:
            // No fold row pulls up a statement or History.
            break
        }
    }

    // MARK: - The decisions, pure

    /// What a click on a fold row does.
    enum Act: Equatable {
        /// A `List` tag: the `List`'s selection carries it through the click
        /// rule (`BinderTreeSelection`), as every tagged tree row.
        case listTag(BinderSubject)
        /// Reference material: pulled up, or put away when it is the one up.
        case pullUp(PulledUp)
        /// A link: travel to the piece (`ClickRule.navigate`).
        case navigate(BinderSubject)
        /// A slugline: open the script at its paragraph (`ResolveNavigation.go`).
        case goToScene(docId: String, paragraphId: String)
    }

    static func act(of entry: PieceFoldEntry) -> Act {
        switch entry {
        case .research(let id, _, _): return .listTag(.research(id))
        case .link(let pieceId, _, _): return .navigate(.item(pieceId))
        case .scene(let docId, let paragraphId, _):
            return .goToScene(docId: docId, paragraphId: paragraphId)
        case .card, .region, .palette, .figure:
            // Each always names something to pull up (`PieceFoldEntry.pulledUp`).
            return entry.pulledUp.map(Act.pullUp) ?? .navigate(.project)
        }
    }

    /// The subject after a click on `entry` — the click rule for each kind.
    static func clicked(_ entry: PieceFoldEntry, subject: WindowSubject,
                        structure: [StructureItem], projectType: ProjectType) -> WindowSubject {
        switch act(of: entry) {
        case .listTag(let row):
            return ClickRule.resolve(row, gesture: .click, current: subject,
                                     structure: structure, projectType: projectType)
        case .pullUp(let pulled):
            return subject.beside == pulled
                ? ClickRule.putAway(current: subject)
                : ClickRule.pullUp(pulled, current: subject)
        case .navigate(let target):
            return ClickRule.navigate(to: target, current: subject,
                                      structure: structure, projectType: projectType)
        case .goToScene:
            // A place, posted by the row (`ResolveNavigation.go`): the
            // window's receiver opens the script there.
            return subject
        }
    }

    /// **The `List` tag a pull-up row carries** (shell p4 Task 10): what it
    /// pulls up and, since p5 Task 4, the piece whose fold lists it — one
    /// card in two open folds is two rows. Every row `pullUpRow` draws names
    /// something to pull up (`PieceFoldEntry.pulledUp`); the fallback is
    /// never reached.
    static func tag(of entry: PieceFoldEntry, inFoldOf piece: String) -> TreeRowTag {
        foldRow(of: entry, inFoldOf: piece).map(TreeRowTag.pullUp) ?? .subject(.project)
    }

    /// The fold row `entry` is in `piece`'s fold; nil for a row that travels.
    static func foldRow(of entry: PieceFoldEntry, inFoldOf piece: String) -> TreeRowTag.FoldRow? {
        entry.pulledUp.map { TreeRowTag.FoldRow(pulled: $0, piece: piece) }
    }

    /// Whether a pull-up row draws its outline: it is what is beside, and the
    /// `List` is not already drawing it selected (`BinderTreeSelection.outlined`'s
    /// rule for the rows the tree tags with a subject).
    @MainActor
    static func drawsOutline(_ entry: PieceFoldEntry, inFoldOf piece: String,
                             subject: WindowSubject,
                             state: BinderTreeSectionsState) -> Bool {
        guard isPulledUp(entry, subject: subject) else { return false }
        // A pull-up row's tag is never a research subject's, so where a
        // research row is drawn (`rowFold`) changes nothing asked here.
        return !BinderTreeSelection.shownTags(
            state.selection, foldRow: state.selectedFoldRow, subject: subject,
            clickedAt: state.subjectAtLastClick, rowFold: { _ in nil })
            .contains(tag(of: entry, inFoldOf: piece))
    }

    /// What VoiceOver calls a pull-up row: its kind, then its name.
    static func accessibilityLabel(_ entry: PieceFoldEntry, title: String) -> String {
        "\(kindName(entry)): \(title)"
    }

    /// What activating a pull-up row does, in VoiceOver's words.
    static func accessibilityHint(_ entry: PieceFoldEntry, subject: WindowSubject) -> String {
        isPulledUp(entry, subject: subject)
            ? "Beside the centre. Activate to put it away; Command-Down Arrow opens it in the centre."
            : "Activate to pull it up beside the centre; Command-Down Arrow opens it in the centre."
    }

    /// A pull-up row's kind, as a writer names it.
    static func kindName(_ entry: PieceFoldEntry) -> String {
        switch entry {
        case .region: return "Region"
        case .palette: return "Palette card"
        case .figure: return "Figure"
        case .research: return "Research"
        case .link: return "Link"
        case .scene: return "Scene"
        case .card(let ref):
            switch ref.kind {
            case .scrap: return "Card"
            case .photo: return "Picture"
            case .palette: return "Palette card"
            case .research: return "Research card"
            }
        }
    }

    /// Where a scene row goes: the script, at the paragraph its slugline
    /// begins. Nil for every other row. Pure.
    static func sceneDestination(_ entry: PieceFoldEntry) -> (docId: String, paragraphId: String)? {
        guard case .goToScene(let docId, let paragraphId) = act(of: entry) else { return nil }
        return (docId, paragraphId)
    }

    static let sceneGlyph = "film"
    static func sceneHelp(_ heading: String) -> String { "Open the script at “\(heading)”" }
    static func sceneAccessibilityLabel(_ heading: String) -> String { "Scene: \(heading)" }

    /// Whether `entry` is what is pulled up — its row draws the outlined
    /// state plan 1 settled for the row beside.
    static func isPulledUp(_ entry: PieceFoldEntry, subject: WindowSubject) -> Bool {
        guard let pulled = entry.pulledUp else { return false }
        return subject.beside == pulled
    }

    /// What a press on a pull-up row is: the first of a pair, or the second.
    enum Press: Equatable { case single, double }

    /// The last single press on a pull-up row: which row, and when (system
    /// uptime, seconds).
    struct LastPress: Equatable {
        let entryId: String
        let at: TimeInterval
    }

    /// **A double-click on a pull-up row** is a second press on the SAME row
    /// within the system's double-click interval of a single one. Anything
    /// else — another row, too late, no press before — is a single press.
    /// Pure.
    static func press(_ entryId: String, at now: TimeInterval, last: LastPress?,
                      interval: TimeInterval) -> Press {
        guard let last, last.entryId == entryId, now >= last.at,
              now - last.at <= interval else { return .single }
        return .double
    }

    /// **What a double-click on a pull-up row opens**: Open in Centre on the
    /// row pulled up (`PulledUpView.opening`) — a research item or a figure
    /// takes the centre; a scrap, a picture or a region opens the canvas with
    /// it selected. The first click of the pair pulled it up or put it away;
    /// either way this is the same act, and it leaves nothing beside. Pure;
    /// nil for a link, which is not a pull-up row.
    static func doubleClicked(_ entry: PieceFoldEntry, subject: WindowSubject,
                              structure: [StructureItem], projectType: ProjectType,
                              photoNode: (String) -> CanvasNodeID?) -> PulledUpView.Opening? {
        guard let pulled = entry.pulledUp else { return nil }
        return opening(pulled, subject: subject, structure: structure,
                       projectType: projectType, photoNode: photoNode)
    }

    /// Open in Centre on `pulled`, as if pulled up first — the one spelling
    /// the double-click, the menu, VoiceOver and ⌘↓ share. Pure.
    static func opening(_ pulled: PulledUp, subject: WindowSubject,
                        structure: [StructureItem], projectType: ProjectType,
                        photoNode: (String) -> CanvasNodeID?) -> PulledUpView.Opening {
        PulledUpView.opening(pulled, subject: ClickRule.pullUp(pulled, current: subject),
                             structure: structure, projectType: projectType,
                             photoNode: photoNode)
    }

    /// A figure row's glyph, the Figures section's.
    static let figureGlyph = "photo.artframe"

    /// A link row's Remove Link: an OUTGOING link only (an incoming one is
    /// the other piece's), and only where this piece's structure door allows.
    static func offersRemoveLink(_ entry: PieceFoldEntry, mayEditLinks: Bool) -> Bool {
        guard case .link(_, _, let incoming) = entry else { return false }
        return !incoming && mayEditLinks
    }

    static func groupName(_ group: PieceFoldGroup) -> String {
        switch group {
        case .scenes: return "Scenes"
        case .research: return "Research"
        case .cards: return "Cards"
        case .palette: return "Palette"
        case .figures: return "Figures"
        case .links: return "Links"
        }
    }

    /// A region row's count of its cards, saying what it counts ("3 cards",
    /// "1 card") — a bare number beside a title reads as an index. A
    /// picture or a note on the canvas is a card too, as the fold's Cards
    /// group says.
    static func regionCount(_ count: Int) -> String { count == 1 ? "1 card" : "\(count) cards" }

    /// "Research (3)".
    static func groupTitle(_ run: PieceFoldGroupRun) -> String {
        "\(groupName(run.group)) (\(run.entries.count))"
    }

    static let outgoingLinkGlyph = "link"
    static let incomingLinkGlyph = "arrow.uturn.backward.circle"
    /// A link row's help, naming both ends so the direction cannot be read
    /// backwards: an outgoing row is the fold's piece linking to the other,
    /// an incoming row the other linking here.
    static func linkHelp(incoming: Bool, piece: String, other: String) -> String {
        incoming ? "“\(other)” links to “\(piece)”" : "“\(piece)” links to “\(other)”"
    }
    static let removeLinkTitle = "Remove Link"

    /// The tree's own action bundle, with **one verb re-routed**.
    ///
    /// `BinderTreeVerbs` is the bundle, and this asks it for one rather than
    /// building a second — three copies of the store wiring is precisely what
    /// `BinderTreeSections` warns about. It asks the *verbs* and not the
    /// sections view, deliberately: constructing the view to reach its bundle
    /// put a `BinderTreeSections(` call in this file, which is the token
    /// `TripwireGrepTests`' pairing census reads as a host mounting section
    /// rows without their presentations. The census caught it, and the fix was
    /// to make the verbs a value.
    ///
    /// **Why `newNote` is the exception.** Every verb on a fold row that names a
    /// parent group is already right: the piece's groups are in
    /// `manifest.research` like any other, so `New Note` inside one, and the
    /// group-only verbs (`New Group`, `Add File…`, `Add Link…`, which
    /// `ResearchTreeNode` offers on group rows only), all pass a real parent id
    /// and land in it. The one hole is a fold row at the piece's root, whose
    /// parent id is `nil` — and `nil` means the SHARED root. A writer
    /// right-clicking a note inside a chapter's fold and asking for another one
    /// would have got a note in shared research, unlinked from the chapter they
    /// asked from. So the nil case routes through `ResearchScope` instead, which
    /// is the seam that already knows what `.document(id)` means for each
    /// project type: a note in the piece's folder for a collection, a shared
    /// note plus a link for a novel chapter. Both land in this fold, which is
    /// what the writer asked for. The rule itself is never restated here.
    var actions: ResearchTreeActions {
        let base = verbs.bundle
        var actions = base
        // **A group this piece does not hold is the same hole** (shell p5
        // Task 4a): a fold's root may sit in a whole-book group (its place is
        // named beside it), and New Note beside it there would file the note
        // in that group — the Research section's, not this fold's. It is made
        // there and linked to this chapter, as its neighbour is; in a
        // Collection, in the piece's own folder.
        let homes = state.researchHomes(in: store.manifest)
        actions.newNote = { [verbs, documentId, store] parentId in
            switch Self.creation(under: parentId, inFoldOf: documentId, homes: homes) {
            case .asAsked: base.newNote(parentId)
            case .piecesScope:
                verbs.create { try await store.createResearchNote(scope: .document(documentId)) }
            case .inGroupLinked(let group):
                verbs.create {
                    let note = try await store.addResearchTextNote(parentId: group, title: "Untitled Note")
                    try await store.linkResearch(researchId: note.id, toDocumentId: documentId)
                    return note
                }
            }
        }
        // New Table, for New Note's reason (D8b-2) — offered where the bundle offers it.
        actions.newTable = base.newTable.map { baseNewTable in
            { [verbs, documentId, store] parentId in
                switch Self.creation(under: parentId, inFoldOf: documentId, homes: homes) {
                case .asAsked: return baseNewTable(parentId)
                case .piecesScope:
                    return verbs.create { try await store.createResearchTable(scope: .document(documentId)) }
                case .inGroupLinked(let group):
                    return verbs.create {
                        let table = try await store.addResearchTable(parentId: group)
                        try await store.linkResearch(researchId: table.id, toDocumentId: documentId)
                        return table
                    }
                }
            }
        }
        // **The second re-routed verb, and the same reason** (Task 7): a drop
        // on a row in this fold is aimed at THIS document. Without the
        // document, `TreeDropIntent` would read the row as an ordinary shared
        // research row and answer "reorder" — so a note dropped into chapter
        // three's fold would silently change the order of shared research and
        // never reach chapter three. The fold is a near-miss of the piece row
        // above it and means the same thing.
        actions.internalDrop = { [verbs, documentId] draggedId, position, target in
            verbs.routeResearchRowDrop(draggedId: draggedId, position: position,
                                       target: target, inFoldOf: documentId)
        }
        // **The third re-routed verb, and it fails the same silent way**
        // (stage-2b Task 4): a Finder file dropped in chapter three's fold is
        // chapter three's. Without the document, the classifier reads the row
        // as an ordinary shared research row and the file lands in shared
        // research, unlinked — no error, nothing missing on screen, and the
        // chapter the writer aimed at simply never gets it.
        actions.externalDrop = { [verbs, documentId] providers, position, target in
            verbs.routeExternalDrop(
                providers: providers, position: position,
                target: .foldRow(rowId: target.id, documentId: documentId))
        }
        // **And its feedback, for the same reason** (shell p4 Task 10): the
        // row shows what the fold's drop does, never the shared row's.
        actions.dropAnswers = { [verbs, documentId] item in
            verbs.dropAnswers(on: .foldRow(rowId: item.id, documentId: documentId))
        }
        return actions
    }

    private var verbs: BinderTreeVerbs {
        BinderTreeVerbs(store: store, state: state, subject: $subject)
    }

    /// Where a fold's New Note or New Table goes, so it lands in this fold.
    enum Creation: Equatable {
        /// Into the group asked for: this piece holds it.
        case asAsked
        /// The piece's own research (`ResearchScope.document`).
        case piecesScope
        /// Into a group this chapter does not hold, then linked to it.
        case inGroupLinked(String)
    }

    /// **Where a creation from this fold lands** (shell p5 Task 4a, G): at the
    /// fold's top, the piece's own; inside a group this piece holds, there;
    /// inside a group that is not its (a linked note's whole-book group), in
    /// that group and linked to the chapter — or, a Collection piece taking no
    /// links, its own folder. Pure.
    static func creation(under parentId: String?, inFoldOf piece: String,
                         homes: ResearchHomes) -> Creation {
        guard let parentId else { return .piecesScope }
        // A single-document project's piece keeps no fold of its own: its
        // fold lists the book's research, so every group is its.
        if homes.homes(of: parentId).contains(piece) || !homes.isAHome(piece) { return .asAsked }
        return homes.takesLinks(piece) ? .inGroupLinked(parentId) : .piecesScope
    }

    private func findParentId(of childId: String) -> String? {
        verbs.findParentId(of: childId)
    }
}

/// **Every piece's fold, built once per change** (tripwire 4) — the one place
/// `PieceFoldIndex.build` runs, attached by both fold hosts (`BinderView`,
/// `CollectionPiecesPane`) with `.pieceFoldIndex(store:state:)`. Keyed on
/// `PieceFoldIndex.key`: the manifest's stamp, the live canvas's structural
/// revision, and the window's count of `.maughamCanvasNodesAdded` (Claude's
/// write into a closed canvas's sidecar, which moves neither of the others),
/// counted by `TreeWindowWiring` so the pulled-up views read the same count.
struct PieceFoldIndexing: ViewModifier {
    let store: ProjectStore
    @Bindable var state: BinderTreeSectionsState

    func body(content: Content) -> some View {
        content
            .task(id: PieceFoldIndex.key(store: store, canvasWrites: state.closedCanvasWrites)) {
                state.foldIndexBase = PieceFoldIndex.build(store: store, projectRoot: store.url)
                state.foldIndex = state.foldIndexBase.withScenes(state.foldScenes)
                state.foldIndexIsBuilt = true
            }
            // **A Collection script's Scenes, on their own key** (shell p4
            // Task 10): the manifest's stamp and the window's count of script
            // re-parses (`.maughamScriptDidUpdate`, the editor's own debounced
            // signal) and closed scripts' arrivals, so typing re-reads the
            // sluglines and never the canvas.
            .task(id: PieceFoldScenesKey(modified: store.manifest.modified,
                                         scriptRevision: state.scriptRevision)) {
                let scenes = PieceFoldIndex.scenes(store: store)
                guard scenes != state.foldScenes else { return }
                state.foldScenes = scenes
                state.foldIndex = state.foldIndexBase.withScenes(scenes)
            }
            .onProjectEvent(.maughamScriptDidUpdate, url: store.url, window: nil) { _ in
                state.scriptRevision += 1
            }
            // A peer's sync into a closed script (`arrivalMovesScenes`).
            .onProjectEvent(.maughamAnnotationsChanged, url: store.url, window: nil) { note in
                let docId = note.userInfo?[MaughamEvent.annotationDocIdKey] as? String
                if PieceFoldIndex.arrivalMovesScenes(
                    docId: docId,
                    isOpen: docId.flatMap { store.documentStore?.document(forDocId: $0) } != nil,
                    structure: store.manifest.structure, projectType: store.manifest.type) {
                    state.scriptRevision += 1
                }
            }
    }
}

/// What a Collection script's Scenes are read on (`PieceFoldIndexing`).
struct PieceFoldScenesKey: Hashable {
    let modified: Date
    let scriptRevision: Int
}

extension View {
    /// Builds the window's fold index for this tree (`PieceFoldIndexing`).
    func pieceFoldIndex(store: ProjectStore, state: BinderTreeSectionsState) -> some View {
        modifier(PieceFoldIndexing(store: store, state: state))
    }
}

private struct WindowCanvasKey: EnvironmentKey {
    static let defaultValue: CanvasModel? = nil
}

extension EnvironmentValues {
    /// **This window's canvas model**, set on the tree's column by
    /// `ProjectWindow`, so a fold row's Open in Centre selects on the canvas
    /// of the window it was pressed in. `store.liveCanvas` is the newest
    /// window's (review M1). Nil selects nothing.
    var windowCanvas: CanvasModel? {
        get { self[WindowCanvasKey.self] }
        set { self[WindowCanvasKey.self] = newValue }
    }
}
