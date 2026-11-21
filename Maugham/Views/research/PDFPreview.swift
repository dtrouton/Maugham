import SwiftUI
import PDFKit

struct PDFPreview: NSViewRepresentable {
    let fileURL: URL
    /// **A page to go to** (shell p4 Task 5): the edition's book scrolls to
    /// where the faced piece starts. Applied when it CHANGES (or a new book
    /// loads), never on every update — the writer's own scrolling stands until
    /// they ask for another piece. Nil leaves the page alone.
    var page: Int? = nil

    final class Coordinator {
        /// The last (file, page) applied, so an unrelated update re-applies nothing.
        var applied: (url: URL, page: Int)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: fileURL)
        go(view, context: context)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != fileURL {
            nsView.document = PDFDocument(url: fileURL)
            context.coordinator.applied = nil
        }
        go(nsView, context: context)
    }

    /// **Go to `page` once per (file, page).** Nil asks nothing.
    static func shouldGo(to page: Int?, in url: URL, applied: (url: URL, page: Int)?) -> Bool {
        guard let page else { return false }
        return applied.map { $0.url == url && $0.page == page } != true
    }

    private func go(_ view: PDFView, context: Context) {
        guard Self.shouldGo(to: page, in: fileURL, applied: context.coordinator.applied),
              let page, let target = view.document?.page(at: page) else { return }
        context.coordinator.applied = (fileURL, page)
        view.go(to: target)
    }
}
