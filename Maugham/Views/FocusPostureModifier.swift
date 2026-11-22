import SwiftUI
import MaughamCore
import AppKit

/// Focus-posture wiring (distraction-free chrome): ⌘\ no-chrome (key-window
/// only), persisted to UIState. Kept off `ProjectWindow.body` for the
/// type-check ceiling (the extracted-ViewModifier pattern). The writer's own
/// refusal of typing is per piece now: read-through (`ReadThroughModifier`).
struct FocusPostureModifier: ViewModifier {
    let window: NSWindow?
    let documentStore: DocumentStore?
    @Binding var isNoChromeOn: Bool
    let applyNoChrome: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyWindowCommand(.maughamToggleNoChrome, window: window) { _ in
                isNoChromeOn.toggle()
                applyNoChrome()
            }
            .onChange(of: isNoChromeOn) { _, newValue in
                applyNoChrome()
                documentStore?.updateUIState { $0.isNoChromeOn = newValue }
            }
    }
}
