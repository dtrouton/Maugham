import SwiftUI
import MaughamCore
import AppKit
import os

/// Focus-posture wiring (distraction-free chrome + WF1 review posture), pulled
/// off `ProjectWindow.body` to keep the inline modifier chain under SwiftUI's
/// body type-check ceiling (the extracted-ViewModifier pattern; see
/// `Maugham/Views/AREA.md`). Handles ⌘\ no-chrome and ⌘⌥⇧R review (key-window
/// only) and persists both flags to UIState.
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
