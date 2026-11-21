import SwiftUI
import PDFKit

struct PDFPreview: NSViewRepresentable {
    let fileURL: URL
    /// **A page to go to, and which ask it answers** (shell p4 Task 5): the
    /// edition's book scrolls to where the faced piece starts. Applied once
    /// per ask — a new ask for the same page goes there again, an unrelated
    /// update re-applies nothing, and the writer's own scrolling stands until
    /// they ask. Nil leaves the page alone.
    var target: Target? = nil

    struct Target: Equatable {
        let page: Int
        let ask: Int
    }

    final class Coordinator {
        /// The last (file, target) applied.
        var applied: (url: URL, target: Target)?
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

    /// **Go to `target` once per (file, ask).** Nil asks nothing.
    static func shouldGo(to target: Target?, in url: URL, applied: (url: URL, target: Target)?) -> Bool {
        guard let target else { return false }
        return applied.map { $0.url == url && $0.target == target } != true
    }

    private func go(_ view: PDFView, context: Context) {
        guard Self.shouldGo(to: target, in: fileURL, applied: context.coordinator.applied),
              let target, let page = view.document?.page(at: target.page) else { return }
        context.coordinator.applied = (fileURL, target)
        view.go(to: page)
    }
}
