import SwiftUI
import MaughamCore

/// **A piece's row menu: Tags…, Add Link…, Publishing…** (shell p3 Task 8) —
/// where the old Inspector's tags field, its add-link search and its
/// per-piece publishing section went. Each opens the existing control in a
/// sheet, unchanged: `InspectorTagsField`, `PieceLinkSearch`,
/// `PiecePublishSettings`.
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
        case tags, addLink, publishing

        var title: String {
            switch self {
            case .tags: return "Tags…"
            case .addLink: return "Add Link…"
            case .publishing: return "Publishing…"
            }
        }
    }

    /// What `item`'s row menu offers. `publishingIsSetUp` is the tree's cached
    /// `PublishStarter.isInitialized` (`BinderTreeSectionsState`), never a
    /// per-row disk read (tripwire 4); the inspector drew its Publishing
    /// section only there.
    static func items(for item: StructureItem, verbs: TreeStructureVerbs,
                      publishingIsSetUp: Bool) -> [Item] {
        guard item.type == .document, item.pieceKind != .reference, verbs.rename else {
            return []
        }
        return publishingIsSetUp ? [.tags, .addLink, .publishing] : [.tags, .addLink]
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
    case publishing(String)

    init(_ item: PieceRowMenus.Item, pieceId: String) {
        switch item {
        case .tags: self = .tags(pieceId)
        case .addLink: self = .addLink(pieceId)
        case .publishing: self = .publishing(pieceId)
        }
    }

    var pieceId: String {
        switch self {
        case .tags(let id), .addLink(let id), .publishing(let id): return id
        }
    }

    var id: String {
        switch self {
        case .tags(let id): return "tags:\(id)"
        case .addLink(let id): return "addLink:\(id)"
        case .publishing(let id): return "publishing:\(id)"
        }
    }
}

/// The menu items, for both trees' piece rows (`BinderView`,
/// `CollectionPiecesPane`). Each press only names the sheet.
struct PieceRowMenuButtons: View {
    let item: StructureItem
    let verbs: TreeStructureVerbs
    let state: BinderTreeSectionsState

    var body: some View {
        let items = PieceRowMenus.items(
            for: item, verbs: verbs, publishingIsSetUp: state.publishingIsSetUp)
        if !items.isEmpty {
            Divider()
            ForEach(items, id: \.title) { menuItem in
                Button(menuItem.title) {
                    state.pieceRowSheet = PieceRowSheet(menuItem, pieceId: item.id)
                }
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
            case .publishing(let id):
                PiecePublishSettings(projectURL: store.url, selectedPieceID: id)
            }
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
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
