import SwiftUI
import MaughamCore

struct ResearchPreview: View {
    let projectURL: URL
    let item: ResearchItem

    var body: some View {
        switch item.kind {
        case .image:
            if let path = item.path {
                ImagePreview(fileURL: projectURL.appendingPathComponent(path))
            } else {
                emptyState
            }
        case .pdf:
            if let path = item.path {
                PDFPreview(fileURL: projectURL.appendingPathComponent(path))
            } else {
                emptyState
            }
        case .document:
            if let path = item.path {
                TextPreview(notePath: path, projectURL: projectURL)
            } else {
                emptyState
            }
        case .audio:
            if let path = item.path {
                AudioPreview(fileURL: projectURL.appendingPathComponent(path))
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
