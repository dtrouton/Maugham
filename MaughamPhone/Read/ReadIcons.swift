import Foundation
import MaughamCore

/// Pure SF-Symbol mapping for the Read-tab navigation (E.3). Kept out of the
/// view bodies so it's trivially unit-testable and the same icon vocabulary is
/// reused across the projects list, the binder, and research rows.
enum ReadIcons {

    /// Icon for a project row, keyed by its writing form.
    static func projectSymbol(_ type: ProjectType) -> String {
        switch type {
        case .shortStory: return "doc.text"
        case .novel: return "book.closed"
        case .screenplay: return "film"
        case .collection: return "books.vertical"
        }
    }

    /// Icon for a binder structure node. Groups are folders; documents take an
    /// extension-derived icon (screenplay pages get the film clapper). An
    /// unreadable/path-less document falls back to a generic page.
    static func structureSymbol(_ item: StructureItem) -> String {
        guard item.type == .document else { return "folder" }
        guard let url = BinderRouting.isReadableDocument(item)
            ? URL(fileURLWithPath: item.path ?? "")
            : nil
        else { return "doc" }
        switch BinderRouting.kind(of: url) {
        case .markdown: return "doc.text"
        case .fountain: return "film"
        case .other: return "doc"
        }
    }

    /// Icon for a research asset, keyed by its declared kind. nil kind → page.
    static func researchSymbol(_ kind: ResearchItem.AssetKind?) -> String {
        switch kind {
        case .image: return "photo"
        case .document: return "doc.text"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .link: return "link"
        case nil: return "doc"
        }
    }

    /// Whether a research asset is openable in the reader: only text-like
    /// documents (`.document`/nil kind with a real path). Images, PDFs, audio
    /// and links are listed but disabled — the reader renders text, not media.
    static func isReadableResearch(_ item: ResearchItem) -> Bool {
        guard item.type == .asset else { return false }
        guard let path = item.path, !path.isEmpty else { return false }
        switch item.kind {
        case .document, .none: return true
        case .image, .pdf, .audio, .link: return false
        }
    }
}
