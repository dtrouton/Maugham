import Foundation
import MaughamCore

/// **A figure listing with no window** (report plan 9b Task 6): the rows the
/// window's Figures section shows, for the MCP `list_figures` tool. It points
/// a throwaway `ReferenceIndexHost` at the project the way a window does
/// (`Project.window`), so the text sources (an open `Document`, else the
/// derived cache, tripwire 20) and the element words are spelled once, waits
/// for the build, and runs `FigureListing.build`. Nothing is written back; the
/// host is detached before returning.
@MainActor
enum FigureListingSource {
    static func rows(store: ProjectStore) async -> [FigureListing.Row] {
        guard let documentStore = store.documentStore else {
            NSLog("FigureListingSource: no DocumentStore for %@; listing no figures", store.url.path)
            return []
        }
        let host = ReferenceIndexHost()
        host.attach(.window(store: store, documentStore: documentStore))
        await host.idle()
        let index = host.index
        host.attach(nil)
        let paths = FigureListingModel.documentPaths(in: store)
        return FigureListing.build(index: index, records: store.manifest.figures ?? [],
                                   documentPathOf: { paths[$0] })
    }
}
