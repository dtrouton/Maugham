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
/// **Linked and owned research look different.** A Collection piece's fold
/// holds research in the piece's own folder (owned): drawn as the Research
/// section draws it, renamable, its groups expanding. A novel chapter's fold
/// holds LINKS to shared research: a quieter title, a trailing link glyph and
/// "Linked from Research" (`ResearchRow.linkedFromResearch`), flat and never
/// renamed here — its twin in the Research section is where it lives.
///
/// **How each row acts** (`act(of:)`, the click rule): research is a `List`
/// tag, as anywhere in the tree; a card, a region or a palette pin is
/// reference material, pulled up beside by a `Button(.plain)` (tripwire 9),
/// and a second click on the one pulled up puts it away (a region's chevron
/// opens to its cards); a figure is a `List` tag
/// that takes the centre; a link travels to its piece. A double-click, or the
/// row's Open in Centre, always opens it in the centre.
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
        case .research(let id, _, let owned):
            if let item = fold.items[id] {
                ResearchTreeNode(
                    item: item,
                    renamingItemId: $state.renamingItemId,
                    findParentId: { findParentId(of: $0) },
                    actions: actions,
                    // A folded row is a subject of the window exactly like a
                    // row in the Research section below — same case, same id.
                    //
                    // **In a novel that is the SAME tag twice in one `List`**,
                    // on this row and on its twin in the shared Research
                    // section, and that is intended: both rows are the one
                    // subject. What the duplicate must NOT duplicate is a
                    // control — see `offersRename`.
                    tagFor: { BinderSubject.research($0.id) },
                    // A linked group's children are not linked to the piece by
                    // anything, so a linked fold renders flat.
                    expandsGroups: owned,
                    // A linked row is drawn a second time in the shared
                    // section, and one `renamingItemId` matching two rows
                    // mounts two rename fields (finding I2).
                    offersRename: owned,
                    // **The fold's own groups share the tree's set of open
                    // ids** (stage-3b Task 7), so a reveal can open them.
                    expandedGroups: $state.expandedResearchGroups,
                    linkedFromResearch: !owned)
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
                          caption: Self.regionCount(cards.count), doubleClick: nil)
            }
        case .palette(_, let title):
            pullUpRow(entry, glyph: state.foldIndex.glyph(of: entry), title: title, caption: nil,
                      doubleClick: Self.doubleClickSubject(of: entry))
        case .figure(let id, let name):
            // A `List` tag: a figure takes the centre (the click rule).
            HStack(spacing: 6) {
                Image(systemName: "photo.artframe")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .treeTravelOnDoubleClick(.figure(id))
                Spacer()
            }
            .contentShape(Rectangle())
            .tag(BinderSubject.figure(id))
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
                  caption: nil, doubleClick: Self.doubleClickSubject(of: entry))
    }

    /// A card, a region or a palette pin: pulled up beside by a click, put
    /// away by a second click on the one pulled up, and drawn outlined while
    /// it is.
    private func pullUpRow(_ entry: PieceFoldEntry, glyph: String, title: String,
                           caption: String?, doubleClick: BinderSubject?) -> some View {
        Button {
            subject = Self.clicked(entry, subject: subject,
                                   structure: store.manifest.structure,
                                   projectType: store.manifest.type)
        } label: {
            HStack(spacing: 6) {
                // A picture's thumbnail in the glyph's place, one line high.
                RowThumbnail(source: thumbnailSource(of: entry), glyph: glyph,
                             side: RowThumbnail.treeSide)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The double-click's mark on the LABEL LEAF (tripwire 9):
                    // a view that takes no hits, read by the window's one
                    // double-click watcher (`TreeTravel`). A canvas scrap has
                    // no tree subject; its Open in Centre is the menu's.
                    .background { if let doubleClick { TreeTravelTarget(subject: doubleClick) } }
                Spacer(minLength: 4)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            if Self.isPulledUp(entry, subject: subject) {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            Button(BesideHeader.openInCentreLabel) { openInCentre(entry) }
        }
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

    /// Open in Centre from a pulled-up row's menu: what the pulled-up view's
    /// own Open in Centre does (`PulledUpView.opening`).
    private func openInCentre(_ entry: PieceFoldEntry) {
        guard let pulled = entry.pulledUp else { return }
        let opening = PulledUpView.opening(
            pulled, subject: ClickRule.pullUp(pulled, current: subject),
            structure: store.manifest.structure, projectType: store.manifest.type,
            photoNode: { path in store.liveCanvas.flatMap { PulledUpView.photoNode(path, in: $0.scene) } })
        switch opening {
        case .subject(let next):
            subject = next
        case .canvas(let next, let target):
            subject = next
            if let target { store.liveCanvas?.revealAndSelect(target) }
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
    }

    static func act(of entry: PieceFoldEntry) -> Act {
        switch entry {
        case .research(let id, _, _): return .listTag(.research(id))
        case .figure(let id, _): return .listTag(.figure(id))
        case .link(let pieceId, _, _): return .navigate(.item(pieceId))
        case .card, .region, .palette:
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
        }
    }

    /// Whether `entry` is what is pulled up — its row draws the outlined
    /// state plan 1 settled for the row beside.
    static func isPulledUp(_ entry: PieceFoldEntry, subject: WindowSubject) -> Bool {
        guard let pulled = entry.pulledUp else { return false }
        return subject.beside == pulled
    }

    /// The tree subject a double-click on a pulled-up row opens in the
    /// centre: the research item (or card) it holds. nil for a canvas scrap or
    /// picture, which have no tree row; their Open in Centre is the menu's.
    static func doubleClickSubject(of entry: PieceFoldEntry) -> BinderSubject? {
        entry.pulledUp?.treeSubject
    }

    /// A link row's Remove Link: an OUTGOING link only (an incoming one is
    /// the other piece's), and only where this piece's structure door allows.
    static func offersRemoveLink(_ entry: PieceFoldEntry, mayEditLinks: Bool) -> Bool {
        guard case .link(_, _, let incoming) = entry else { return false }
        return !incoming && mayEditLinks
    }

    static func groupName(_ group: PieceFoldGroup) -> String {
        switch group {
        case .research: return "Research"
        case .cards: return "Cards"
        case .palette: return "Palette"
        case .figures: return "Figures"
        case .links: return "Links"
        }
    }

    /// A region row's count of its cards.
    static func regionCount(_ count: Int) -> String { "\(count)" }

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
        actions.newNote = { [verbs, documentId, store] parentId in
            guard parentId == nil else { return base.newNote(parentId) }
            verbs.create {
                try await store.createResearchNote(scope: .document(documentId))
            }
        }
        // New Table, for New Note's reason (D8b-2) — offered where the bundle offers it.
        actions.newTable = base.newTable.map { baseNewTable in
            { [verbs, documentId, store] parentId in
                guard parentId == nil else { return baseNewTable(parentId) }
                return verbs.create {
                    try await store.createResearchTable(scope: .document(documentId))
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
        return actions
    }

    private var verbs: BinderTreeVerbs {
        BinderTreeVerbs(store: store, state: state, subject: $subject)
    }

    private func findParentId(of childId: String) -> String? {
        verbs.findParentId(of: childId)
    }
}

/// **Every piece's fold, built once per change** (tripwire 4) — the one place
/// `PieceFoldIndex.build` runs, attached by both fold hosts (`BinderView`,
/// `CollectionPiecesPane`) with `.pieceFoldIndex(store:state:)`. Keyed on
/// `PieceFoldIndex.key`: the manifest's stamp, the live canvas's structural
/// revision, and this count of `.maughamCanvasNodesAdded` (Claude's write into
/// a closed canvas's sidecar, which moves neither of the others).
struct PieceFoldIndexing: ViewModifier {
    let store: ProjectStore
    @Bindable var state: BinderTreeSectionsState
    /// For the event's liveness filter (ADR 0021).
    @State private var window: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor(window: $window))
            .task(id: PieceFoldIndex.key(store: store, canvasWrites: state.foldCanvasWrites)) {
                state.foldIndex = PieceFoldIndex.build(store: store, projectRoot: store.url)
                state.foldIndexIsBuilt = true
            }
            .onProjectEvent(.maughamCanvasNodesAdded, url: store.url, window: window) { _ in
                state.foldCanvasWrites += 1
            }
    }
}

extension View {
    /// Builds the window's fold index for this tree (`PieceFoldIndexing`).
    func pieceFoldIndex(store: ProjectStore, state: BinderTreeSectionsState) -> some View {
        modifier(PieceFoldIndexing(store: store, state: state))
    }
}
