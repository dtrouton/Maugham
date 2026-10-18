import SwiftUI
import MaughamCore
import AppKit

/// Focus-posture wiring (distraction-free chrome + review posture): ⌘\
/// no-chrome and ⌘⌥⇧R review (key-window only), both flags persisted to
/// UIState. Kept off `ProjectWindow.body` for the type-check ceiling
/// (the extracted-ViewModifier pattern).
struct FocusPostureModifier: ViewModifier {
    let window: NSWindow?
    let documentStore: DocumentStore?
    @Binding var isNoChromeOn: Bool
    @Binding var isReviewModeOn: Bool
    let applyNoChrome: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamToggleNoChrome, window: window) { _ in
                isNoChromeOn.toggle()
                applyNoChrome()
            }
            .onKeyWindowCommand(.maughamToggleReviewMode, window: window) { _ in
                isReviewModeOn.toggle()
            }
            .onChange(of: isNoChromeOn) { _, newValue in
                applyNoChrome()
                documentStore?.updateUIState { $0.isNoChromeOn = newValue }
            }
            .onChange(of: isReviewModeOn) { _, newValue in
                documentStore?.updateUIState { $0.isReviewModeOn = newValue }
            }
    }
}
