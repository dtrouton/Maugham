import SwiftUI
import MaughamCore
import UniformTypeIdentifiers

/// Shared recursive research tree node used by ResearchView (novel/short
/// story/screenplay) and CollectionResearchPane (per-section). Extracted so
/// collections get real nesting + drop-into-group instead of the flat fork
/// that made groups decorative (2026-07-16 research-restructuring spec).
/// A single "Move to ▸" submenu entry: a stable menu identity, a display
/// title (nested groups flattened as "Outer / Inner"), and the typed move
/// destination the store consumes.
struct ResearchMoveMenuTarget: Identifiable {
    let id: String          // stable menu identity, e.g. "shared" / "group-<id>" / "piece-<id>"
    let title: String       // "Shared", "World / Maps", piece title
    let target: ResearchMoveTarget
}

struct ResearchTreeActions {
    var rename: (String, String) -> Void
    /// Returns whether the drop is ACCEPTED. `ResearchRow` returns exactly this
    /// from its `.dropDestination`, so a surface whose routing is not built yet
    /// says `false` and the writer's drag bounces back, rather than being
    /// animated home and silently discarded (fix round 1; see `ResearchRow`).
    var internalDrop: (_ draggedId: String, _ position: DropIntent.Position, _ target: ResearchItem) -> Bool
    /// Returns whether the drop is accepted — see `internalDrop`.
    var externalDrop: (_ providers: [NSItemProvider], _ position: DropIntent.Position, _ target: ResearchItem) -> Bool
    var newNote: (_ parentId: String?) -> Void
    /// **New Table** (D8b-2), beside every New Note: a blank table, selected
    /// and in rename; its work, which a test awaits. Nil where it is not
    /// offered — a view-only share (`BinderTreeSectionsState.offersNewTable`).
    var newTable: ((_ parentId: String?) -> Task<Void, Never>)? = nil
    var newGroup: (_ parentId: String?) -> Void
    var addFile: (_ parentId: String?) -> Void
    var addLink: (_ parentId: String?) -> Void
    var duplicate: (String) -> Void
    /// **Whether the row offers New Note and New Table** (fix round 2): not
    /// where what they would make cannot be made — a chapter's fold on a Mac
    /// that may not change its links (`BinderPieceFold.actions`).
    var offersMaking: (ResearchItem) -> Bool = { _ in true }
    /// Whether the row offers Duplicate, by the same rule.
    var offersDuplicate: (ResearchItem) -> Bool = { _ in true }
    var delete: (String) -> Void
    /// Ordered ids the context menu should act on for `rowId`: the whole
    /// selection when `rowId` is inside a multi-selection, else just `rowId`.
    var selectionForRow: (_ rowId: String) -> [String]
    /// Valid "Move to" destinations for `forIds` (empty ⇒ hide the submenu).
    var moveTargets: (_ forIds: [String]) -> [ResearchMoveMenuTarget]
    /// `fold`: the fold the row is drawn in (nil: the Research section).
    var move: (_ ids: [String], _ target: ResearchMoveTarget, _ fold: String?) -> Void
    var deleteMany: (_ ids: [String]) -> Void
    /// **A drag of a row began** (shell p5 Task 4a): the row's id and the
    /// fold it is drawn in (nil: the Research section) — what lets a drop
    /// unlink a note from the one chapter it was dragged out of.
    var dragStarted: (_ id: String, _ fold: String?) -> Void
    /// The row's link verbs (`ResearchHomeMenu`), or nil where it offers none.
    var homeMenu: (_ item: ResearchItem, _ fold: String?) -> ResearchHomeMenu?
    /// **Whether the row offers Rename, Delete, Move to ▸ and its link verbs**
    /// (closing round A): not for research a chapter in read-through holds.
    var offersChanging: (ResearchItem) -> Bool
    /// Performs one of them.
    var performHome: (_ verb: ResearchHomeMenu.Verb) -> Void
    /// **The row's verb toward Figures** (report plan 8b Task 4) — *Use in
    /// Document*, or *Bring Back to Figures* for a parked figure's working
    /// copy — nil where none is offered (`FigureActions.researchVerb`).
    var figureVerb: (ResearchItem) -> FigureActions.ResearchVerb? = { _ in nil }
    var performFigureVerb: (ResearchItem) -> Task<Void, Never>? = { _ in nil }
    /// Why the verb toward Figures is withheld, named — Bring Back over a
    /// figure whose piece is in read-through (`FigureActions.bringBackRefusal`).
    var figureVerbRefusal: (ResearchItem) -> String? = { _ in nil }
    /// **What a row shows while a drag is over it** (shell p4 Task 10) — the
    /// same classification `internalDrop`/`externalDrop` perform; a fold
    /// re-routes it with its document, as it re-routes those.
    var dropAnswers: (ResearchItem) -> TreeDropAnswers = { _ in .none }
    /// **The click's twin and the double-click's** (shell p5 Task 7, rows
    /// 64–66): the menu holds what the row's click and ⌘↓ do — Pull Up (or
    /// Put Away, the row being the one up) and Open in Centre. Nil offers
    /// neither (a fixture with no window behind it).
    var pullUpTitle: ((String) -> String)? = nil
    var pullUp: ((String) -> Void)? = nil
    var openInCentre: ((String) -> Void)? = nil
}

extension ResearchTreeActions {
    /// Row 65: "Add Link…" meant a web link here and another piece in the
    /// binder's piece rows — one title, two meanings.
    static let addWebLinkTitle = "Add Web Link\u{2026}"
}

struct ResearchTreeNode: View {
    let item: ResearchItem
    @Binding var renamingItemId: String?
    let findParentId: (String) -> String?
    let actions: ResearchTreeActions
    /// The subject each row is, for the enclosing `List`'s selection: the
    /// binder tree tags `.research(item.id)`. Its `List` tag is this subject as
    /// a `TreeRowTag` — `.subject` in the Research section, `.inFold` in a
    /// piece's fold (`inFold`).
    let tagFor: (ResearchItem) -> BinderSubject
    /// **The piece whose fold draws this row, or nil for the Research
    /// section** (shell p5 Task 4a). A note two chapters link is a row under
    /// each, and each row's tag names its fold (`TreeRowTag.inFold`), so the
    /// `List` selects one and not both; a drag records it as its source.
    let inFold: String?
    /// **Whether a row can go into inline rename** — asked per item, because
    /// it is about there being TWO rows: a note two chapters link is drawn in
    /// both folds, in one `List`, off one `renamingItemId`, and two matching
    /// rows would mount two `TextField`s, each running `claimFocus()`'s 30ms
    /// deferral against the other — tripwire 16's exact race (final-review
    /// finding I2). A row that is its item's only row renames.
    let offersRename: (String) -> Bool
    /// **Where this row sits in the research tree, said beside its title** —
    /// a fold's root row whose group is elsewhere (`ResearchHomes.place`): a
    /// linked note inside a whole-book group is drawn flat under the chapter,
    /// and this names the group it lives in. The root's own; its children are
    /// drawn inside it and say nothing.
    let caption: String?
    /// **Where a group row's open/closed flag lives** — the ids that are OPEN,
    /// held by whoever mounts the tree (stage-3a Task 4).
    ///
    /// `nil` keeps SwiftUI's own private flag. The binder tree's Research
    /// section and every per-piece fold pass
    /// `BinderTreeSectionsState.expandedResearchGroups`, because `reveal` has
    /// to be able to open the groups between a revealed item and the root.
    var expandedGroups: Binding<Set<String>>? = nil
    /// **Whether this row carries a scroll identity** (stage-3b Task 8):
    /// `.id(tagFor(item))` in the Research section, `.id` of its fold tag in a
    /// fold (`TreeScrollTarget.foldRow`) — one per row since either/or (shell
    /// p5 Task 4a), when no row is ever drawn twice under one id. Propagated
    /// to every descendant in `childNodes` — a nested item three groups down
    /// is exactly as reachable as a root one.
    var appliesScrollIdentity: Bool = false

    /// The row's `List` tag (`inFold`).
    private var rowTag: TreeRowTag {
        let row = tagFor(item)
        return inFold.map { .inFold(row, piece: $0) } ?? .subject(row)
    }

    @ViewBuilder
    var body: some View {
        if appliesScrollIdentity, inFold != nil {
            coreBody.id(rowTag)
        } else if appliesScrollIdentity {
            coreBody.id(tagFor(item))
        } else {
            coreBody
        }
    }

    @ViewBuilder
    private var coreBody: some View {
        if item.type == .group {
            // Two spellings of one row, because the two initialisers are
            // genuinely different views: a `.constant` binding would make a
            // fold's groups permanently closed, and there is no binding that
            // means "hold it yourself".
            if let isExpanded = expansion(of: item.id) {
                DisclosureGroup(isExpanded: isExpanded) {
                    AnyView(childNodes)
                } label: {
                    row
                }
            } else {
                DisclosureGroup {
                    AnyView(childNodes)
                } label: {
                    row
                }
            }
        } else {
            row
        }
    }

    /// One group's flag, projected out of the set of open ids — `nil` where the
    /// caller holds no set and SwiftUI keeps its own.
    private func expansion(of id: String) -> Binding<Bool>? {
        guard let expandedGroups else { return nil }
        return Binding(
            get: { expandedGroups.wrappedValue.contains(id) },
            set: { open in
                if open { expandedGroups.wrappedValue.insert(id) }
                else { expandedGroups.wrappedValue.remove(id) }
            })
    }

    private var childNodes: some View {
        ForEach(item.children ?? []) { child in
            AnyView(ResearchTreeNode(
                item: child,
                renamingItemId: $renamingItemId,
                findParentId: findParentId,
                actions: actions,
                tagFor: tagFor,
                inFold: inFold,
                offersRename: offersRename,
                caption: nil,
                // A nested group is reached by opening its parent, so the whole
                // subtree reads the same set — a reveal names every ancestor and
                // one of them may be three levels down.
                expandedGroups: expandedGroups,
                // Propagated, not re-decided: a nested item is exactly as
                // scroll-reachable as a root one.
                appliesScrollIdentity: appliesScrollIdentity))
        }
    }

    /// The binding the row renames through — **a dead one where the row does not
    /// offer rename**, so the `TextField` branch cannot mount at all. Hiding
    /// only the menu item would leave the duplicate field to be opened by the
    /// other path that sets this id: `pendingRenameId`, committed for every
    /// newly created note (`BinderTreeVerbs.create`).
    private var renameBinding: Binding<String?> {
        offersRename(item.id) ? $renamingItemId : .constant(nil)
    }

    private var row: some View {
        ResearchRow(
            item: item,
            renamingItemId: renameBinding,
            onRename: actions.rename,
            onDrop: { draggedId, position in
                actions.internalDrop(draggedId, position, item)
            },
            onExternalDrop: { providers, position in
                actions.externalDrop(providers, position, item)
            },  // both pass the bundle's accept/refuse straight back to the row
            dropAnswers: { actions.dropAnswers(item) },
            caption: caption,
            onDragStart: { [actions, item, inFold] in actions.dragStarted(item.id, inFold) })
            .tag(rowTag)
            .contextMenu {
                // What the row's click and double-click do, first (row 65).
                if item.type != .group, let pullUp = actions.pullUp, let title = actions.pullUpTitle,
                   let openInCentre = actions.openInCentre {
                    Button(title(item.id)) { pullUp(item.id) }
                    Button(BesideHeader.openInCentreLabel) { openInCentre(item.id) }
                    Divider()
                }
                if actions.offersMaking(item) {
                    Button("New Note") {
                        actions.newNote(item.type == .group ? item.id : findParentId(item.id))
                    }
                    if let newTable = actions.newTable {
                        Button("New Table") {
                            _ = newTable(item.type == .group ? item.id : findParentId(item.id))
                        }
                    }
                }
                if item.type == .group {
                    Button("New Group") { actions.newGroup(item.id) }
                    Button("Add File…") { actions.addFile(item.id) }
                    Button(ResearchTreeActions.addWebLinkTitle) { actions.addLink(item.id) }
                    Divider()
                }
                let acting = actions.selectionForRow(item.id)
                // Read-through holds it: nothing that changes it is offered.
                let changes = actions.offersChanging(item)
                // Where it belongs, in words (shell p5 Task 4a): one row's.
                if changes, acting.count == 1, let home = actions.homeMenu(item, inFold) {
                    homeMenuItems(home)
                    Divider()
                }
                let targets = changes ? actions.moveTargets(acting) : []
                if !targets.isEmpty {
                    Menu("Move to") {
                        ForEach(targets) { t in
                            Button(t.title) { actions.move(acting, t.target, inFold) }
                        }
                    }
                    Divider()
                }
                if acting.count > 1 {
                    if changes {
                    Button("Delete \(acting.count) Items", role: .destructive) {
                        actions.deleteMany(acting)
                    }
                    }
                } else {
                    if let verb = actions.figureVerb(item) {
                        Button(verb.title) { _ = actions.performFigureVerb(item) }
                        Divider()
                    } else if let refusal = actions.figureVerbRefusal(item) {
                        Text(refusal)
                        Divider()
                    }
                    if actions.offersDuplicate(item) {
                        Button("Duplicate") { actions.duplicate(item.id) }
                    }
                    // Absent on a row drawn twice (two chapters' folds):
                    // renaming there opens a second field — see `offersRename`.
                    if offersRename(item.id) {
                        Button("Rename") { renamingItemId = item.id }
                    }
                    if changes {
                        Button("Delete", role: .destructive) { actions.delete(item.id) }
                    }
                }
            }
    }
}

extension ResearchTreeNode {
    /// `ResearchHomeMenu`'s items: Move to ▸, Remove from, Make Whole-Book,
    /// and the line naming the other chapters.
    @ViewBuilder
    fileprivate func homeMenuItems(_ home: ResearchHomeMenu) -> some View {
        if !home.moveTargets.isEmpty {
            Menu(home.moveTitle) {
                ResearchHomeMoveItems(nodes: home.moveTree, perform: actions.performHome)
            }
        }
        if let remove = home.removeFromThis {
            Button(remove.title) { actions.performHome(remove.verb) }
        }
        if let whole = home.makeWholeBook {
            Button(whole.title) { actions.performHome(whole.verb) }
        }
        if let alsoIn = home.alsoIn {
            Text(alsoIn)
        }
    }
}

/// Move to Chapter ▸'s items: a chapter's button, a Part's submenu
/// (`ResearchHomeMenu.MoveNode`).
private struct ResearchHomeMoveItems: View {
    let nodes: [ResearchHomeMenu.MoveNode]
    let perform: (ResearchHomeMenu.Verb) -> Void

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case .target(let target):
                Button(target.title) { perform(target.verb) }
            case .part(_, let title, let children):
                Menu(title) { ResearchHomeMoveItems(nodes: children, perform: perform) }
            }
        }
    }
}

/// Selection⇄preview sync + drag-expansion rules shared by the two research
/// surfaces. Pure functions — unit-tested in ResearchSelectionTests.
enum ResearchSelectionSync {
    /// The preview pane shows a single item or nothing.
    static func previewId(for selection: Set<String>) -> String? {
        selection.count == 1 ? selection.first : nil
    }

    /// Selection ordered by depth-first manifest tree position (visual order).
    static func orderedSelection(
        _ selection: Set<String>, in research: [ResearchItem]
    ) -> [String] {
        TreeWalk.collect(in: research, where: { selection.contains($0.id) })
            .map(\.id)
    }

    /// Selection with ids that no longer exist in `research` dropped —
    /// post-delete hygiene (2026-07-19 sweep W6): a stale id left behind
    /// drives `previewId(for:)` to a ghost item in the single-preview pane.
    static func pruned(
        _ selection: Set<String>, in research: [ResearchItem]
    ) -> Set<String> {
        selection.intersection(TreeWalk.collectIds(in: research))
    }

    /// Standard Mac behavior: dragging a row inside the selection drags the
    /// whole selection; dragging an unselected row drags just that row.
    static func expandedDragIds(
        draggedId: String, selection: Set<String>, in research: [ResearchItem]
    ) -> [String] {
        guard selection.contains(draggedId), selection.count > 1 else {
            return [draggedId]
        }
        return orderedSelection(selection, in: research)
    }

    /// Insertion index for a batch drop beside `targetId`, computed against
    /// the destination sibling list WITH the moving ids filtered out. This
    /// matches `moveResearchItems(atIndex:)` semantics: the store removes the
    /// whole batch first, then inserts at `destIndex` — so an index taken
    /// against the pre-removal list drifts right by however many moved items
    /// preceded the target. `.top` inserts before the target; `.bottom` and
    /// `.middle` (non-group) insert after. Returns nil when the target is
    /// itself part of the batch or absent from `siblings` (callers treat nil
    /// as append/bail).
    static func postRemovalInsertionIndex(
        targetId: String, position: DropIntent.Position,
        movingIds: [String], siblings: [ResearchItem]
    ) -> Int? {
        let moving = Set(movingIds)
        guard !moving.contains(targetId) else { return nil }
        let remaining = siblings.filter { !moving.contains($0.id) }
        guard let idx = remaining.firstIndex(where: { $0.id == targetId }) else {
            return nil
        }
        return position == .top ? idx : idx + 1
    }

    /// Menu targets for moving `ids`: Shared root, every group (nested titles
    /// flattened as "Outer / Inner"), and — in collections — every loose
    /// piece. Excludes invalid destinations: groups inside a moving group
    /// (cycle), the moving groups themselves (no-op / self), and everything
    /// cross-scope for role-bearing items.
    static func moveTargets(
        forIds ids: [String], manifest: ProjectManifest
    ) -> [ResearchMoveMenuTarget] {
        let movingItems = ids.compactMap { TreeWalk.find(id: $0, in: manifest.research) }
        guard !movingItems.isEmpty else { return [] }
        let movingGroupIds = Set(movingItems.filter { $0.type == .group }.map(\.id))
        let anyRoleBearing = movingItems.contains { $0.role != nil }

        func isInsideMovingGroup(_ id: String) -> Bool {
            movingItems.contains { g in
                g.type == .group && TreeWalk.contains(id: id, in: g.children ?? [])
            }
        }

        var targets: [ResearchMoveMenuTarget] = [
            .init(id: "shared", title: "Shared", target: .sharedRoot)
        ]
        // Groups, flattened titles.
        func walkGroups(_ items: [ResearchItem], prefix: String) {
            for item in items where item.type == .group {
                let title = prefix.isEmpty ? item.title : "\(prefix) / \(item.title)"
                if !movingGroupIds.contains(item.id), !isInsideMovingGroup(item.id) {
                    targets.append(.init(
                        id: "group-\(item.id)", title: title, target: .group(item.id)))
                }
                walkGroups(item.children ?? [], prefix: title)
            }
        }
        walkGroups(manifest.research, prefix: "")
        // Loose pieces (collections).
        if manifest.type.holdsPieces {
            for piece in manifest.structure
                where piece.type == .document && piece.pieceKind == .loose {
                targets.append(.init(
                    id: "piece-\(piece.id)", title: piece.title,
                    target: .piece(piece.id)))
            }
        }
        // Role-bearing selections may only move within their scope — cheapest
        // honest menu: offer nothing (the store would refuse anyway).
        return anyRoleBearing ? [] : targets
    }
}
