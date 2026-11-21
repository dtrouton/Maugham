import SwiftUI
import MaughamCore

/// **A piece's row menu: Tags…, Add Link…, Target…, Publishing…** (shell p3
/// Task 8), then History (appraisal 6) — where the old Inspector's tags
/// field, its add-link search, its
/// target steppers and its per-piece publishing section went. Each opens the
/// existing control in a sheet: `InspectorTagsField`, `PieceLinkSearch`,
/// `PieceTargetField` (the status line's own, so a target can be set with the
/// status bar hidden), `PiecePublishSettings`.
///
/// **Offered by the row's own `TreeStructureVerbs`** (hidden, never disabled;
/// tripwires 47, 51): a piece's manifest fields are edited by whoever may
/// restructure it — the question Rename (`verbs.rename`), Brief's line and the
/// fold's Remove Link already ask. A group has none of these fields, and a
/// Collection's reference piece is another project's.
///
/// **Presented from the tree's sections, never from a row** — the row sets
/// `BinderTreeSectionsState.pieceRowSheet` and `BinderTreeSectionsPresentations`
/// mounts the sheet, for `linkPickerDocumentId`'s reason: a sheet attached to a
/// row inside a lazy `List` is presented from a view the list may unmount.
enum PieceRowMenus {

    enum Item: Equatable, CaseIterable {
        case tags, addLink, target, publishing

        var title: String {
            switch self {
            case .tags: return "Tags…"
            case .addLink: return "Add Link…"
            case .target: return "Target…"
            case .publishing: return "Publishing…"
            }
        }
    }

    /// What `item`'s row menu offers. `publishingIsSetUp` is the tree's cached
    /// `PublishStarter.isInitialized` (`BinderTreeSectionsState`), never a
    /// per-row disk read (tripwire 4); the inspector drew its Publishing
    /// section only there.
    ///
    /// `offersTarget` is whether the status line would offer this piece a
    /// target (`PieceTargetMenu.decide` — a screenplay's is the PROJECT's and
    /// asks the project stream). `offersLinks` is false for a screenplay's one
    /// script, which has no other document to link to.
    static func items(for item: StructureItem, verbs: TreeStructureVerbs,
                      publishingIsSetUp: Bool, offersTarget: Bool = false,
                      offersLinks: Bool = true) -> [Item] {
        guard item.type == .document, item.pieceKind != .reference else { return [] }
        var items: [Item] = []
        if verbs.rename {
            items.append(.tags)
            if offersLinks { items.append(.addLink) }
        }
        if offersTarget { items.append(.target) }
        if verbs.rename, publishingIsSetUp { items.append(.publishing) }
        return items
    }

    /// **The row's History** (appraisal 6): offered on every piece that has
    /// a History here — a document, never a group or a Collection's reference
    /// piece (another project's). Reading a History needs no write, so no
    /// posture enters; Rewind inside it asks its own.
    static let historyTitle = "History"

    static func offersHistory(for item: StructureItem) -> Bool {
        item.type == .document && item.pieceKind != .reference
    }

    /// The target the row's "Target…" sets — the status line's own decision,
    /// asked of the window's posture door; no door, no target (fails closed).
    @MainActor
    static func target(for item: StructureItem, store: ProjectStore) -> PieceTargetMenu? {
        guard let documentStore = store.documentStore else { return nil }
        return PieceTargetMenu.decide(
            piece: item, projectType: store.manifest.type,
            projectPageTarget: store.manifest.targets?.pageTarget,
            postureOf: { documentStore.posture(forDocId: $0) })
    }

    /// The links after adding `target`: appended once, never twice — the
    /// inspector's rule.
    static func links(adding target: String, to existing: [String]?) -> [String] {
        let links = existing ?? []
        return links.contains(target) ? links : links + [target]
    }

    /// Every tag in the book, sorted — the tags field's suggestions (the
    /// inspector's pool, moved).
    static func tagSuggestions(in structure: [StructureItem]) -> [String] {
        var pool = Set<String>()
        for item in TreeWalk.collect(in: structure, where: { _ in true }) {
            for t in item.tags ?? [] { pool.insert(t) }
        }
        return Array(pool).sorted()
    }
}

/// Which row sheet is open, and for which piece.
enum PieceRowSheet: Identifiable, Equatable {
    case tags(String)
    case addLink(String)
    case target(String)
    case publishing(String)

    init(_ item: PieceRowMenus.Item, pieceId: String) {
        switch item {
        case .tags: self = .tags(pieceId)
        case .addLink: self = .addLink(pieceId)
        case .target: self = .target(pieceId)
        case .publishing: self = .publishing(pieceId)
        }
    }

    var pieceId: String {
        switch self {
        case .tags(let id), .addLink(let id), .target(let id), .publishing(let id): return id
        }
    }

    var id: String {
        switch self {
        case .tags(let id): return "tags:\(id)"
        case .addLink(let id): return "addLink:\(id)"
        case .target(let id): return "target:\(id)"
        case .publishing(let id): return "publishing:\(id)"
        }
    }
}

/// The menu items, for every tree's piece rows (`BinderView`,
/// `CollectionPiecesPane`, and a screenplay's script row in
/// `SceneNavigatorPane`). Each press only names the sheet.
struct PieceRowMenuButtons: View {
    let item: StructureItem
    let verbs: TreeStructureVerbs
    let state: BinderTreeSectionsState
    /// Whether "Target…" is offered (`PieceRowMenus.target` is non-nil).
    var offersTarget: Bool = false
    /// False for a screenplay's one script.
    var offersLinks: Bool = true

    var body: some View {
        let items = PieceRowMenus.items(
            for: item, verbs: verbs, publishingIsSetUp: state.publishingIsSetUp,
            offersTarget: offersTarget, offersLinks: offersLinks)
        if !items.isEmpty || PieceRowMenus.offersHistory(for: item) {
            Divider()
        }
        ForEach(items, id: \.title) { menuItem in
            Button(menuItem.title) {
                state.pieceRowSheet = PieceRowSheet(menuItem, pieceId: item.id)
            }
        }
        // That row's piece's History, by ⌘⌥H's route — never the faces'.
        if PieceRowMenus.offersHistory(for: item) {
            Button(PieceRowMenus.historyTitle) {
                MaughamEvent.postPullUpHistory(ofPiece: item.id)
            }
        }
    }
}

/// The sheet a row menu item opens. Each write is the inspector's store call,
/// routed through the tree's `perform` so a failure reaches the tree's alert.
struct PieceRowSheetView: View {
    @Bindable var store: ProjectStore
    let sheet: PieceRowSheet
    let perform: (@escaping () async throws -> Void) -> Void
    let onDone: () -> Void

    @State private var tags: [String] = []
    @State private var suggestions: [String] = []

    private var piece: StructureItem? {
        TreeWalk.find(id: sheet.pieceId, in: store.manifest.structure)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(piece?.title ?? "")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            switch sheet {
            case .tags(let id):
                InspectorTagsField(
                    tags: $tags, suggestions: suggestions,
                    onCommit: { commitTags(id) })
                    .onAppear {
                        tags = piece?.tags ?? []
                        suggestions = PieceRowMenus.tagSuggestions(in: store.manifest.structure)
                    }
            case .addLink(let id):
                PieceLinkSearch(
                    store: store, currentItemId: id, existing: piece?.links ?? [],
                    onPick: { target in addLink(target, to: id) })
            case .target:
                if let piece, let menu = PieceRowMenus.target(for: piece, store: store) {
                    PieceTargetField(
                        menu: menu,
                        onSet: { value in
                            perform { [store] in
                                try await PieceTargetMenu.perform(menu.write, value: value, store: store)
                            }
                        },
                        onDone: onDone)
                }
            case .publishing(let id):
                PiecePublishSettings(projectURL: store.url, selectedPieceID: id)
            }
            HStack {
                Spacer()
                // Not the default where the sheet's field takes Return
                // itself: Return in Tags… adds the tag and keeps the sheet
                // (final wave), and the target field's Set is its own.
                Button("Done", action: onDone)
                    .keyboardShortcut(Self.doneIsDefault(for: sheet) ? .defaultAction : nil)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    /// Whether Done answers Return: only where no field of the sheet does.
    static func doneIsDefault(for sheet: PieceRowSheet) -> Bool {
        switch sheet {
        case .tags, .target: return false
        case .addLink, .publishing: return true
        }
    }

    private func commitTags(_ id: String) {
        let value = tags
        perform { [store] in try await store.updateInspector(id: id, tags: value) }
    }

    private func addLink(_ target: String, to id: String) {
        let links = PieceRowMenus.links(adding: target, to: piece?.links)
        perform { [store] in try await store.updateInspector(id: id, links: links) }
        onDone()
    }
}
