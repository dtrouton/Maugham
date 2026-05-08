import SwiftUI
import WebKit

struct LinkPreview: NSViewRepresentable {
    let urlString: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        if let url = URL(string: urlString) {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if let url = URL(string: urlString),
           nsView.url != url {
            nsView.load(URLRequest(url: url))
        }
    }
}
