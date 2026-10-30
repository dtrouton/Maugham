import SwiftUI
import MaughamCore

struct ResearchPreview: View {
    let projectURL: URL
    let item: ResearchItem

    /// The item's file, when its synced path stays inside the project
    /// (tripwire 58); otherwise the empty state shows.
    private var fileURL: URL? {
        item.path.flatMap { try? SafeRelativePath.resolve($0, under: projectURL) }
    }

    var body: some View {
        switch item.kind {
        case .image:
            if let fileURL {
                ImagePreview(fileURL: fileURL)
            } else {
                emptyState
            }
        case .pdf:
            if let fileURL {
                PDFPreview(fileURL: fileURL)
            } else {
                emptyState
            }
        // A Research table opens in the grid (`ResearchTableGrid`); its CSV
        // is shown as text here only where no window store is at hand.
        case .document, .table:
            if let path = item.path, fileURL != nil {
                TextPreview(notePath: path, projectURL: projectURL)
            } else {
                emptyState
            }
        case .audio:
            if let fileURL {
                AudioPreview(fileURL: fileURL)
            } else {
                emptyState
            }
        case .link:
            if let urlString = item.url {
                LinkPreview(urlString: urlString)
            } else {
                emptyState
            }
        case .none:
            emptyState
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Select an item to preview",
            systemImage: "doc.text.magnifyingglass")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
