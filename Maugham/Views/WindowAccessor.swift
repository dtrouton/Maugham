import SwiftUI
import AppKit

/// Injects the underlying `NSWindow` into a SwiftUI binding by embedding a
/// zero-size NSView and reading its `window` property on the main queue.
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.window = view.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if self.window == nil { self.window = nsView.window }
        }
    }
}
