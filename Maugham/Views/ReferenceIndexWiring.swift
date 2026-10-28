import SwiftUI
import MaughamCore

/// **The window's figure index, cached** (report plan 8a Task 2): the
/// `FigureListing` rows the tree's Figures section, the centre grid's bar and
/// the figure inspector read. Observable, so a reader re-renders when the rows
/// change and never builds them in a body (tripwire 4); refreshed by
/// `ReferenceIndexWiring` from the window's `ReferenceIndexHost` and the
/// registry, with or without an editor mounted.
@Observable
@MainActor
final class FigureListingModel {
    /// The figures in listing order (`FigureListing.build`).
    private(set) var rows: [FigureListing.Row] = []

    /// The row for one figure, nil when the registry has none.
    func row(forFigureId id: String) -> FigureListing.Row? { rows.first { $0.figureId == id } }

    /// Rebuild from `index` and `store`'s registry; writes only a change, so a
    /// reader is not invalidated by a rebuild that moved nothing it shows.
    func refresh(index: ReferenceIndex, store: ProjectStore) {
        var paths: [String: String] = [:]
        for item in TreeWalk.collect(in: store.manifest.structure, where: { $0.path != nil }) {
            paths[item.id] = item.path
        }
        let next = FigureListing.build(index: index, records: store.manifest.figures ?? [],
                                       documentPathOf: { paths[$0] })
        if next != rows { rows = next }
    }
}

extension ReferenceIndexHost.Project {
    /// The project as the window reads it: the binder and research off the
    /// manifest, a piece's live text when a `Document` has it open, else its
    /// op-log-derived text behind the derived cache's token (tripwire 20), and
    /// the default book's element words from the publish config.
    @MainActor static func window(store: ProjectStore, documentStore: DocumentStore) -> Self {
        Self(
            structure: { [store] in store.manifest.structure },
            research: { [store] in store.manifest.research },
            liveText: { [documentStore] path in documentStore.document(for: path)?.displayText },
            // Off the main actor, once per rebuild: one listing of the ops
            // directory for every closed piece asked (whole-branch review I2).
            tokens: { [url = store.url] docIds in
                DerivedManuscriptCache.tokens(forDocIds: docIds, in: url)
            },
            derivedText: { [store] docId in
                try? store.derivedCache.displayText(forDocId: docId, in: store.url)
            },
            words: { [url = store.url] in
                let config = (try? PublishConfigStore.read(in: url)) ?? nil
                return ElementWords.forBody(config?.metadata ?? PublishConfig.Metadata())
            })
    }
}

/// **The window's reference index, wired** (report plan 8a Task 2): attaches
/// the window's `ReferenceIndexHost` to the open project and carries the
/// edges that are the project's rather than the editor's — research changed,
/// the binder changed, a closed piece's op log moved — so the index, and the
/// `FigureListingModel` it feeds, stay current in every persona, Plan's
/// canvas centre included. A new version reaches the editor one-way, through
/// `EditorControl.referenceIndexVersion`. The editor's own edges (a settle, a
/// document switch) stay `EditorHost`'s, on the host it is handed.
///
/// Its own modifier because `ProjectWindow.body` has no type-check budget.
struct ReferenceIndexWiring: ViewModifier {
    let url: URL
    let store: ProjectStore?
    let documentStore: DocumentStore?
    let referenceIndex: ReferenceIndexHost
    let figureListing: FigureListingModel
    let control: EditorControl
    let window: NSWindow?

    func body(content: Content) -> some View {
        content
            .onChange(of: store.map(ObjectIdentifier.init), initial: true) { _, _ in attach() }
            .onChange(of: store?.manifest.research) { _, _ in referenceIndex.invalidate(.research) }
            .onChange(of: store?.manifest.structure) { _, _ in
                referenceIndex.invalidate(.all)
                refreshListing()   // a piece's path is what its lines resolve against
            }
            // A figure made, renamed or removed changes the rows with no text moving.
            .onChange(of: store?.manifest.figures) { _, _ in refreshListing() }
            // A piece's op log moved (another device's sync of a closed piece,
            // or a note): the index asks that piece again.
            .onProjectEvent(.maughamAnnotationsChanged, url: url, window: window) { note in
                if let changed = note.userInfo?[MaughamEvent.annotationDocIdKey] as? String {
                    referenceIndex.invalidate(.piece(changed))
                }
            }
    }

    /// Point the host at the window's project, or at none once the window
    /// has let it go (its close scorches the stores), which stops it.
    private func attach() {
        guard let store, let documentStore else {
            referenceIndex.attach(nil)
            return
        }
        let control = control, listing = figureListing, host = referenceIndex
        host.onVersionChange = { control.referenceIndexVersion = $0 }
        host.onPublish = { [weak store, weak host] in
            guard let store, let host else { return }
            listing.refresh(index: host.index, store: store)
        }
        host.attach(.window(store: store, documentStore: documentStore))
        listing.refresh(index: host.index, store: store)
    }

    private func refreshListing() {
        guard let store else { return }
        figureListing.refresh(index: referenceIndex.index, store: store)
    }
}
